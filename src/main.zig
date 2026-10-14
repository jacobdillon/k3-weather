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
    /// Local time window with no MBTA updates (the T isn't running).
    quiet: ?QuietHours = null,
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
        \\  --quiet-hours HH:MM-HH:MM  no MBTA updates in this local time window
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
            else if (eql(a, "--quiet-hours")) cfg.quiet = QuietHours.parse(v) orelse usage() //
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

/// A daily local-time window such as "02:00-04:30"; it may wrap past
/// midnight ("23:00-05:00").
const QuietHours = struct {
    /// Minutes after midnight.
    start: u32,
    end: u32,

    fn parse(s: []const u8) ?QuietHours {
        const dash = std.mem.findScalar(u8, s, '-') orelse return null;
        const start = minutes(s[0..dash]) orelse return null;
        const end = minutes(s[dash + 1 ..]) orelse return null;
        if (start == end) return null;
        return .{ .start = start, .end = end };
    }

    fn minutes(hhmm: []const u8) ?u32 {
        const colon = std.mem.findScalar(u8, hhmm, ':') orelse return null;
        const h = std.fmt.parseInt(u32, hhmm[0..colon], 10) catch return null;
        const m = std.fmt.parseInt(u32, hhmm[colon + 1 ..], 10) catch return null;
        if (h > 23 or m > 59) return null;
        return h * 60 + m;
    }

    /// Whether `sec` (seconds after local midnight) is inside the window.
    fn contains(q: QuietHours, sec: i64) bool {
        const m: u32 = @intCast(@divTrunc(sec, 60));
        return if (q.start < q.end) m >= q.start and m < q.end else m >= q.start or m < q.end;
    }

    /// Seconds from `sec` (after local midnight) until the window next ends.
    fn untilEnd(q: QuietHours, sec: i64) i64 {
        const d = @as(i64, q.end) * 60 - sec;
        return if (d > 0) d else d + 86400;
    }

    /// The end of the window as "HH:MM".
    fn endHHMM(q: QuietHours) [5]u8 {
        var out: [5]u8 = undefined;
        _ = std.mem.print(&out, "{d:0>2}:{d:0>2}", .{ q.end / 60, q.end % 60 }) catch unreachable;
        return out;
    }
};

test QuietHours {
    const q = QuietHours.parse("02:00-04:30").?;
    try std.testing.expect(!q.contains(1 * 3600 + 59 * 60));
    try std.testing.expect(q.contains(2 * 3600));
    try std.testing.expect(q.contains(4 * 3600 + 29 * 60 + 59));
    try std.testing.expect(!q.contains(4 * 3600 + 30 * 60));
    try std.testing.expectEqual(@as(i64, 30 * 60), q.untilEnd(4 * 3600));
    try std.testing.expectEqualStrings("04:30", &q.endHHMM());

    const night = QuietHours.parse("23:00-05:00").?; // wraps past midnight
    try std.testing.expect(night.contains(23 * 3600 + 30 * 60));
    try std.testing.expect(night.contains(3 * 3600));
    try std.testing.expect(!night.contains(12 * 3600));
    try std.testing.expectEqual(@as(i64, 6 * 3600), night.untilEnd(23 * 3600));

    try std.testing.expect(QuietHours.parse("2am-4am") == null);
    try std.testing.expect(QuietHours.parse("02:00-02:00") == null);
    try std.testing.expect(QuietHours.parse("25:00-04:00") == null);
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
            const path = std.mem.printSentinel(&pb, "/dev/input/event{d}", .{i}, 0) catch unreachable;
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
    /// Consecutive failed updates, for backing off while offline.
    fail_streak: u32 = 0,
    /// Local time zone (seconds from UTC), from the latest forecast.
    utc_offset: ?i64 = null,

    fn hasMbta(app: *const App) bool {
        return app.board.n > 0;
    }

    fn showingMbta(app: *const App) bool {
        return app.view == .mbta and app.hasMbta();
    }

    /// Seconds after local midnight, once a forecast has told us the zone.
    fn localSecondOfDay(app: *const App) ?i64 {
        const off = app.utc_offset orelse return null;
        return @mod(sys.realtimeSec() + off, 86400);
    }

    /// Take the time zone from a freshly parsed forecast, before deciding
    /// whether MBTA is live (quiet hours) in the same update.
    fn noteZone(app: *App, w: anyerror!Weather) void {
        const off = ((w catch return).utc_offset) orelse return;
        app.utc_offset = off;
        sys.utc_offset = off; // log timestamps in local time
    }

    fn inQuietHours(app: *const App) bool {
        const q = app.cfg.quiet orelse return false;
        return q.contains(app.localSecondOfDay() orelse return false);
    }

    /// Showing MBTA departures and fetching them (not in quiet hours).
    fn mbtaLive(app: *const App) bool {
        return app.showingMbta() and !app.inQuietHours();
    }

    /// Seconds between updates: the MBTA interval while departures are
    /// live, otherwise the forecast interval.
    fn period(app: *const App) i64 {
        return if (app.mbtaLive()) app.cfg.mbta_interval else app.cfg.interval;
    }

    /// When the next update is due, for an update that began at `started`
    /// (wall-clock seconds). Counting from the start keeps the time spent
    /// waking and fetching from stretching every cycle.
    fn nextDue(app: *const App, started: i64, ok: bool) i64 {
        // After failures, back off (1, 2, 4 ... min, up to the period) so a
        // dead network doesn't keep the radio busy every cycle.
        const delay = if (ok) app.period() else @min(app.period(), @as(i64, 60) << @intCast(@min(app.fail_streak -| 1, 6)));
        var due = started + delay;
        // In quiet hours with the MBTA view up, wake just after they end
        // (a few seconds' margin, since wake-ups can be a second early) so
        // live departures come back on time.
        if (app.showingMbta() and app.inQuietHours()) {
            const end = sys.realtimeSec() + app.cfg.quiet.?.untilEnd(app.localSecondOfDay().?) + 5;
            due = @min(due, end);
        }
        if (!ok) log("update failed {d} time(s) in a row; next try in {d}s", .{ app.fail_streak, due - started });
        return due;
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
            app.noteZone(w);
            if (app.mbtaLive()) app.board.refresh(&net_buf); // MBTA stays live
            return w;
        }
        if (app.cfg.wifi_saver) kindle.setWifi(true);
        defer if (app.cfg.wifi_saver) kindle.setWifi(false);
        const result = app.fetchForecast();
        app.noteZone(result);
        // `result` has been parsed out of net_buf, so the buffer is free again.
        if (app.mbtaLive()) app.board.refresh(&net_buf);
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
            .mbta_paused_until = if (app.showingMbta() and app.inQuietHours()) app.cfg.quiet.?.endHHMM() else null,
        });
    }

    /// Fetch, render and display once. Returns whether the fetch succeeded.
    fn update(app: *App) bool {
        defer app.fb.show(&screen);
        var result = app.fetch();
        if (result) |*w| {
            w.stampNow();
            app.weather = w.*;
            app.fail_streak = 0;
            app.draw(w, .ok);
            const pct: i32 = if (app.battery()) |b| b.pct else -1;
            log("updated: {d:.1}° code {d}, battery {d}%", .{ w.temp, w.code, pct });
            app.logBattery("ok");
            return true;
        } else |err| {
            app.fail_streak += 1;
            log("fetch failed: {s}", .{@errorName(err)});
            app.logBattery(@errorName(err));
            if (app.weather) |*w| app.draw(w, .{ .failed = @errorName(err) }) else {
                var mb: [96]u8 = undefined;
                ui.renderMessage(&screen, app.cfg.name, std.mem.print(&mb, "No data yet ({s}), retrying…", .{@errorName(err)}) catch "No data");
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
            const started = sys.realtimeSec();
            const ok = app.update();
            const due = app.nextDue(started, ok);
            switch (app.inputs.wait((due - sys.realtimeSec()) * 1000)) {
                .quit => return,
                .toggle => app.view = app.view.other(),
                .refresh, .timeout => {},
            }
        }
    }

    /// With --sleep: update, give the user a minute when they are around
    /// (at start, or after the power switch woke us), then suspend the
    /// Kindle until the next update is due.
    fn runAsleep(app: *App) void {
        var due: i64 = 0; // wall-clock time the next update is due
        var user_awake = true; // just started: offer the key window
        // M was pressed: presses during that refresh are impatient repeats,
        // not a request to switch back.
        var drain_after_update = false;

        while (true) {
            if (sys.realtimeSec() >= due - 30) { // close enough: update now rather than sleep again
                const started = sys.realtimeSec();
                const ok = app.update();
                if (drain_after_update) app.inputs.drain("pressed while switching views");
                drain_after_update = false;
                due = app.nextDue(started, ok);
            }

            if (user_awake) {
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
                    .timeout => user_awake = false,
                }
            }

            const asked = @max(60, due - sys.realtimeSec());
            const start = sys.realtimeSec();
            kindle.suspendFor(asked) catch {
                // Could not suspend: stay awake until the next update instead.
                log("suspend failed; staying awake for {d}s", .{asked});
                if (app.inputs.wait(asked * 1000) == .quit) return;
                continue;
            };
            const slept = sys.realtimeSec() - start;
            switch (kindle.logWakeInfo()) {
                .power_button => {
                    log("woken by the power switch after {d}s (asked {d}s)", .{ slept, asked });
                    app.wokenBySwitch();
                    user_awake = true;
                    due = 0;
                },
                else => log("woke after {d}s (asked {d}s, {d}s until due)", .{ slept, asked, due - sys.realtimeSec() }),
            }
        }
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
    _ = display;
    _ = forecast;
}
