//! k3-weather: full-screen weather (and MBTA departures) for a jailbroken
//! Kindle 3.
//!
//! Fetches a blended forecast from Open-Meteo (plain HTTP) and, optionally,
//! MBTA predictions (HTTPS), draws a 600x800 canvas and pushes it to /dev/fb0
//! with a full e-ink refresh. Between updates it either waits for keys or,
//! with --sleep, suspends the Kindle and wakes on a timer.

const std = @import("std");
const c = std.c;
const cv = @import("canvas.zig");
const net = @import("net.zig");
const mbta = @import("mbta.zig");
const display = @import("display.zig");
const forecast = @import("forecast.zig");
const kindle = @import("kindle.zig");
const sys = @import("sys.zig");
const ui = @import("ui.zig");

const log = sys.log;
const Weather = forecast.Weather;

// ----------------------------------------------------------------- config

const Config = struct {
    lat: []const u8 = "42.3647",
    lon: []const u8 = "-71.1042",
    name: []const u8 = "Cambridge, MA",
    units: forecast.Units = .metric,
    interval: u32 = 1800,
    fb: [:0]const u8 = "/dev/fb0",
    invert: ?bool = null,
    png: ?[:0]const u8 = null,
    json: ?[:0]const u8 = null,
    /// Fake battery percentage, for previews.
    battery: ?u8 = null,
    /// Turn wifi on only for each fetch (Kindle only).
    wifi_saver: bool = false,
    /// Suspend between updates, woken by powerd's RTC alarm (Kindle only).
    sleep: bool = false,
    /// Append a CSV row per poll (battery level etc.) to this file.
    battery_log: ?[:0]const u8 = null,
    /// MBTA rows for the alternative bottom-half view (M key toggles).
    board: mbta.Board = .{},
    /// Refresh period while the MBTA view is showing.
    mbta_interval: u32 = 300,
    view: ui.View = .days,
};

fn usage() noreturn {
    log(
        \\usage: k3-weather [options]
        \\  --lat N --lon N        location (default Cambridge, MA)
        \\  --name TEXT            label shown in the header
        \\  --units metric|imperial
        \\  --interval SECONDS     refresh period (default 1800)
        \\  --fb PATH              framebuffer device (default /dev/fb0; "none" = headless)
        \\  --invert / --no-invert override framebuffer polarity
        \\  --wifi-saver           turn wifi on only while fetching (Kindle)
        \\  --sleep                suspend between updates, wake on an RTC alarm (Kindle)
        \\  --png FILE             render once to a PNG instead of the screen
        \\  --json FILE            use a saved API response instead of fetching
        \\  --battery PCT          fake the battery level (for previews)
        \\  --battery-log FILE     append a CSV row (time, battery %, fetch result) per poll
        \\  --mbta "STOP ROUTE DIR LABEL"  MBTA row for the M-key view (up to 3), e.g.
        \\                         "place-cntsq Red 1 Red to Alewife @ Central"
        \\  --mbta-interval SECONDS refresh period in the MBTA view (default 300)
        \\  --view days|mbta       which bottom half to start with (default days)
    , .{});
    std.process.exit(2);
}

fn parseArgs(argv: []const [*:0]const u8) Config {
    var cfg = Config{};
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = std.mem.span(argv[i]);
        // Flags without a value
        if (eql(a, "--invert")) {
            cfg.invert = true;
        } else if (eql(a, "--no-invert")) {
            cfg.invert = false;
        } else if (eql(a, "--sleep")) {
            cfg.sleep = true;
        } else if (eql(a, "--wifi-saver")) {
            cfg.wifi_saver = true;
        } else {
            // Options with a value
            if (i + 1 >= argv.len) usage();
            i += 1;
            const v = std.mem.span(argv[i]);
            if (eql(a, "--lat")) cfg.lat = v //
            else if (eql(a, "--lon")) cfg.lon = v //
            else if (eql(a, "--name")) cfg.name = v //
            else if (eql(a, "--units")) cfg.units = std.meta.stringToEnum(forecast.Units, v) orelse usage() //
            else if (eql(a, "--interval")) cfg.interval = seconds(v) //
            else if (eql(a, "--fb")) cfg.fb = v //
            else if (eql(a, "--png")) cfg.png = v //
            else if (eql(a, "--json")) cfg.json = v //
            else if (eql(a, "--battery")) cfg.battery = @min(100, std.fmt.parseInt(u8, v, 10) catch usage()) //
            else if (eql(a, "--battery-log")) cfg.battery_log = v //
            else if (eql(a, "--mbta")) cfg.board.add(v) catch usage() //
            else if (eql(a, "--mbta-interval")) cfg.mbta_interval = seconds(v) //
            else if (eql(a, "--view")) cfg.view = std.meta.stringToEnum(ui.View, v) orelse usage() //
            else usage();
        }
    }
    return cfg;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// A period in seconds, at least a minute.
fn seconds(v: []const u8) u32 {
    return @max(60, std.fmt.parseInt(u32, v, 10) catch usage());
}

// ------------------------------------------------------------------ input

const KEY_ESC = 1;
const KEY_M = 50;
const KEY_HOME = 102;
const KEY_BACK = 158;
const EV_KEY = 1;

/// struct input_event: a `struct timeval` followed by type/code/value.
const InputEvent = extern struct { tv: [2]c_long, type: u16, code: u16, value: i32 };

const Inputs = struct {
    const max = 8;
    fds: [max]c.pollfd = undefined,
    n: usize = 0,

    const Action = enum { timeout, refresh, toggle, quit };

    fn open() Inputs {
        var in = Inputs{};
        for (0..max) |i| {
            var pb: [32]u8 = undefined;
            const path = std.fmt.bufPrintZ(&pb, "/dev/input/event{d}", .{i}) catch unreachable;
            const fd = c.open(path, .{ .ACCMODE = .RDONLY, .NONBLOCK = true });
            if (fd < 0) continue;
            in.fds[in.n] = .{ .fd = fd, .events = c.POLL.IN, .revents = 0 };
            in.n += 1;
        }
        return in;
    }

    /// The next queued key press on `fd`, if any (other events are skipped).
    fn nextKey(fd: c.fd_t) ?u16 {
        var ev: InputEvent = undefined;
        while (c.read(fd, @ptrCast(&ev), @sizeOf(InputEvent)) == @sizeOf(InputEvent)) {
            if (ev.type == EV_KEY and ev.value == 1) return ev.code;
        }
        return null;
    }

    /// Throw away queued key presses, logging why.
    fn drain(in: *Inputs, why: []const u8) void {
        for (in.fds[0..in.n]) |pfd| {
            while (nextKey(pfd.fd)) |code| log("ignoring key code {d} {s}", .{ code, why });
        }
    }

    /// Wait up to `ms` for a key press. Home/Back quit, M toggles the view,
    /// anything else refreshes.
    fn wait(in: *Inputs, ms: i64) Action {
        const deadline = sys.nowMs() + ms;
        while (true) {
            const left = deadline - sys.nowMs();
            if (left <= 0 or c.poll(&in.fds, @intCast(in.n), @intCast(left)) <= 0) return .timeout;
            var action: Action = .timeout;
            for (in.fds[0..in.n]) |pfd| {
                if (pfd.revents & c.POLL.IN == 0) continue;
                while (nextKey(pfd.fd)) |code| {
                    log("key code {d}", .{code});
                    action = switch (code) {
                        KEY_HOME, KEY_BACK, KEY_ESC => .quit,
                        KEY_M => if (action == .quit) .quit else .toggle,
                        else => if (action == .timeout) .refresh else action,
                    };
                }
            }
            if (action != .timeout) return action;
        }
    }
};

// -------------------------------------------------------------------- app

var screen: cv.Canvas = .{};
var net_buf: [64 * 1024]u8 = undefined;

const App = struct {
    cfg: Config,
    fb: display.Framebuffer,
    inputs: Inputs,
    board: mbta.Board,
    view: ui.View,
    /// The last forecast fetched successfully.
    weather: ?Weather = null,
    /// How long the last fetch waited for wifi, or -1 (saver off / failed).
    wifi_ms: i64 = -1,

    fn hasMbta(app: *const App) bool {
        return app.board.n > 0;
    }

    fn showingMbta(app: *const App) bool {
        return app.view == .mbta and app.hasMbta();
    }

    /// Seconds between updates for the current view.
    fn period(app: *const App) i64 {
        return if (app.showingMbta()) app.cfg.mbta_interval else app.cfg.interval;
    }

    fn battery(app: *const App) ?kindle.Battery {
        if (app.cfg.battery) |p| return .{ .pct = p, .charging = false };
        return kindle.readBattery();
    }

    /// Fetch the forecast, plus MBTA if that view is showing, within one
    /// wifi session.
    fn fetch(app: *App) !Weather {
        app.wifi_ms = -1;
        if (app.cfg.json) |path| {
            const w = try forecast.parse(try sys.readFile(path, &net_buf));
            if (app.showingMbta()) app.board.refresh(&net_buf); // MBTA stays live
            return w;
        }
        if (app.cfg.wifi_saver) kindle.setWifi(true);
        defer if (app.cfg.wifi_saver) kindle.setWifi(false);
        const result = app.fetchForecast();
        // `result` has been parsed out of net_buf, so the buffer is free again.
        if (app.showingMbta()) app.board.refresh(&net_buf);
        return result;
    }

    /// With the wifi saver, retry for up to a minute while the network
    /// comes up after switching wifi on (or resuming).
    fn fetchForecast(app: *App) !Weather {
        const cfg = &app.cfg;
        const start = sys.nowMs();
        while (true) {
            if (forecast.fetch(cfg.lat, cfg.lon, cfg.units, &net_buf)) |w| {
                if (cfg.wifi_saver) {
                    app.wifi_ms = sys.nowMs() - start;
                    log("fetched {d} ms after enabling wifi", .{app.wifi_ms});
                }
                return w;
            } else |err| switch (err) {
                error.Resolve, error.Connect, error.Timeout => if (!cfg.wifi_saver or sys.nowMs() - start > 60_000) return err,
                else => return err,
            }
            sys.sleepMs(3000);
        }
    }

    fn draw(app: *App, w: *const Weather, status: ui.Status) void {
        ui.render(&screen, .{
            .name = app.cfg.name,
            .units = app.cfg.units,
            .weather = w,
            .status = status,
            .battery = app.battery(),
            .board = if (app.hasMbta()) &app.board else null,
            .view = app.view,
            .sleep = app.cfg.sleep,
        });
    }

    /// Fetch, render and display once. Returns whether the fetch succeeded.
    fn update(app: *App) bool {
        defer app.fb.show(&screen);
        var result = app.fetch();
        if (result) |*w| {
            w.stampNow();
            if (w.utc_offset) |off| sys.utc_offset = off; // log timestamps in local time
            app.weather = w.*;
            app.draw(w, .ok);
            const pct: i32 = if (app.battery()) |b| b.pct else -1;
            log("updated: {d:.1}° code {d}, battery {d}%", .{ w.temp, w.code, pct });
            app.logBattery("ok");
            return true;
        } else |err| {
            log("fetch failed: {s}", .{@errorName(err)});
            app.logBattery(@errorName(err));
            if (app.weather) |*w| app.draw(w, .{ .failed = @errorName(err) }) else {
                var mb: [96]u8 = undefined;
                ui.renderMessage(&screen, app.cfg.name, std.fmt.bufPrint(&mb, "No data yet ({s}), retrying…", .{@errorName(err)}) catch "No data");
            }
            return false;
        }
    }

    fn logBattery(app: *App, result: []const u8) void {
        if (app.cfg.battery_log) |path| kindle.logBattery(path, app.battery(), result, app.wifi_ms);
    }

    /// Redraw the last forecast with `note` in the status line: instant
    /// feedback before a fetch that can take tens of seconds.
    fn showNote(app: *App, note: []const u8) void {
        const w = app.weather orelse return;
        app.draw(&w, .{ .note = note });
        app.fb.show(&screen);
    }

    /// Without --sleep: update, then wait for the period or a key.
    fn runAwake(app: *App) void {
        while (true) {
            const ok = app.update();
            // After a failure with nothing to show, retry sooner.
            const period_ms = if (!ok and app.weather == null) 60_000 else app.period() * 1000;
            switch (app.inputs.wait(period_ms)) {
                .quit => return,
                .toggle => app.view = app.view.other(),
                .refresh, .timeout => {},
            }
        }
    }

    /// With --sleep: update, give the user a minute if the screen is awake,
    /// then let powerd suspend the Kindle until the next update is due.
    fn runAsleep(app: *App) void {
        defer kindle.cancelArm();
        var due: i64 = 0; // wall-clock time the next update is due
        // M was pressed: presses during that refresh are impatient repeats,
        // not a request to switch back.
        var drain_after_update = false;
        // powerd wakes us later than asked, roughly in proportion to the
        // sleep (with the stock UI paused: 1579 s -> 1811 s, 60 s -> 71 s),
        // so ask for (time left) / ratio, and learn the ratio as we go.
        var ratio: f64 = 1.15;
        // From pressing the power button to powerd's readyToSuspend.
        const ready_delay = 60;

        while (true) {
            if (sys.realtimeSec() >= due - 60) { // close enough: update now rather than sleep again
                const ok = app.update();
                if (drain_after_update) app.inputs.drain("pressed while switching views");
                drain_after_update = false;
                due = sys.realtimeSec() + if (ok) app.period() else @min(app.period(), 300);
            }

            const awake = kindle.powerState() == .active;
            if (awake) {
                // Just started, or the user slid the power switch.
                log("awake: Home exits, M switches view, other keys refresh; sleeping in 60 s", .{});
                switch (app.inputs.wait(60_000)) {
                    .quit => return,
                    .refresh => {
                        due = 0;
                        continue;
                    },
                    .toggle => {
                        app.view = app.view.other();
                        app.showNote("Updating…");
                        drain_after_update = true;
                        due = 0;
                        continue;
                    },
                    .timeout => {},
                }
            }

            // Arm on powerd's readyToSuspend event (~ready_delay from now).
            const wake_in = wakeIn(due - sys.realtimeSec() - ready_delay, ratio);
            kindle.armOnReady(wake_in);
            if (awake) kindle.enterScreenSaver();
            app.fb.show(&screen); // repaint in case a screensaver image was drawn
            log("sleeping; rtcWakeup {d}s once powerd is ready (ratio {d:.2})", .{ wake_in, ratio });

            const result = kindle.waitForSleep(900, wakeIn(due - sys.realtimeSec(), ratio));
            const armed = kindle.armed();
            if (kindle.powerState() == .active) {
                if (result == .resumed) log("resumed by the power switch after {d}s asleep", .{result.resumed});
                kindle.cancelArm();
                app.wokenBySwitch();
                due = 0;
                continue;
            }
            switch (result) {
                .resumed => |slept| {
                    const a = armed orelse {
                        log("resumed after {d}s asleep, but the alarm was never armed (powerd's own wake?)", .{slept});
                        continue;
                    };
                    // Timer wake: fold the observed ratio into the estimate.
                    const took: f64 = @floatFromInt(sys.realtimeSec() - a.at);
                    const observed = took / @as(f64, @floatFromInt(a.seconds));
                    ratio = std.math.clamp((ratio + observed) / 2, 1.0, 2.0);
                    log("resumed after {d}s asleep; asked {d}s, took {d:.0}s (x{d:.2}); {d}s until due", .{ slept, a.seconds, took, observed, due - sys.realtimeSec() });
                },
                .woken => {},
                .timeout => log("powerd never suspended within 15 min; retrying", .{}),
            }
        }
    }

    /// Seconds to request from powerd so we wake after `left` seconds.
    fn wakeIn(left: i64, ratio: f64) i64 {
        return @max(60, @as(i64, @intFromFloat(@as(f64, @floatFromInt(left)) / ratio)));
    }

    /// The power switch woke us: drop keys pressed while asleep and show that
    /// we are listening (keys pressed from here on count, even mid-refresh).
    fn wokenBySwitch(app: *App) void {
        app.inputs.drain("pressed while asleep");
        app.showNote(if (!app.hasMbta())
            "Awake: Home to exit"
        else if (app.view == .mbta)
            "Awake: M for forecast, Home to exit"
        else
            "Awake: M for MBTA, Home to exit");
    }
};

pub fn main(init: std.process.Init.Minimal) !void {
    const cfg = parseArgs(init.args.vector);
    try cv.initFonts();
    net.root_pem = @embedFile("mbta-roots.pem");

    var app = App{
        .cfg = cfg,
        .fb = undefined,
        .inputs = .{},
        .board = cfg.board,
        .view = cfg.view,
    };

    if (cfg.png) |png| {
        var w = try app.fetch();
        w.stampNow();
        app.draw(&w, .ok);
        try display.writePng(png, &screen);
        app.logBattery("ok");
        return;
    }

    app.fb = try display.Framebuffer.open(cfg.fb, cfg.invert);
    log("framebuffer {d}x{d} {d}bpp stride {d} invert={}", .{ app.fb.xres, app.fb.yres, app.fb.bpp, app.fb.stride, app.fb.invert });
    app.inputs = Inputs.open();

    ui.renderMessage(&screen, cfg.name, "Fetching weather…");
    app.fb.show(&screen);

    if (cfg.sleep) app.runAsleep() else app.runAwake();
}

test {
    _ = ui;
    _ = mbta;
}
