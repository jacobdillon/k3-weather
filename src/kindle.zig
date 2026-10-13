//! Kindle 3 system integration: battery, wifi and powerd (via lipc).

const std = @import("std");
const c = std.c;
const sys = @import("sys.zig");

// ---------------------------------------------------------------- battery

pub const Battery = struct { pct: u8, charging: bool };

const capacity_files = [_][:0]const u8{
    "/sys/devices/system/luigi_battery/luigi_battery0/battery_capacity", // K3: "85%"
    "/sys/devices/system/yoshi_battery/yoshi_battery0/battery_capacity",
    "/sys/class/power_supply/battery/capacity",
};
const charging_files = [_][:0]const u8{
    "/sys/devices/platform/fsl-usb2-udc/charging", // K3: "1" / "0"
    "/sys/class/power_supply/battery/status", // "Charging" / "Discharging"
};

pub fn readBattery() ?Battery {
    var buf: [32]u8 = undefined;
    const pct = for (capacity_files) |f| {
        const s = sys.readFile(f, &buf) catch continue;
        break leadingInt(s) orelse continue;
    } else batteryFromPowerd() orelse return null;
    const charging = for (charging_files) |f| {
        const s = sys.readFile(f, &buf) catch continue;
        break std.mem.startsWith(u8, s, "1") or std.mem.startsWith(u8, s, "Charging");
    } else false;
    return .{ .pct = @min(pct, 100), .charging = charging };
}

/// Fallback: powerd's status dump contains "Battery Level: 42%".
fn batteryFromPowerd() ?u8 {
    var buf: [1024]u8 = undefined;
    const s = sys.output("lipc-get-prop com.lab126.powerd status 2>/dev/null", &buf) orelse return null;
    const key = "Battery Level:";
    const i = std.mem.indexOf(u8, s, key) orelse return null;
    return leadingInt(std.mem.trimStart(u8, s[i + key.len ..], " "));
}

fn leadingInt(s: []const u8) ?u8 {
    var n: usize = 0;
    while (n < s.len and std.ascii.isDigit(s[n])) n += 1;
    return std.fmt.parseInt(u8, s[0..n], 10) catch null;
}

const battery_log_header = "time_utc,epoch,battery_pct,charging,fetch,wifi_ms\n";

/// Append one CSV row to `path`: when, battery level, and how the poll went.
pub fn logBattery(path: [:0]const u8, bat: ?Battery, fetch_result: []const u8, wifi_ms: i64) void {
    const now: u64 = @intCast(sys.realtimeSec());
    const es: std.time.epoch.EpochSeconds = .{ .secs = now };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();

    var buf: [160]u8 = undefined;
    const pct: i32 = if (bat) |b| b.pct else -1;
    const charging = bat != null and bat.?.charging;
    const row = std.fmt.bufPrint(&buf, "{d}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z,{d},{d},{d},{s},{d}\n", .{
        yd.year, md.month.numeric(), md.day_index + 1, // date
        ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(), // time
        now,                  pct,                     @intFromBool(charging),
        fetch_result,         wifi_ms,
    }) catch return;

    const exists = c.access(path, 0) == 0;
    const fd = c.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, @as(c.mode_t, 0o644));
    if (fd < 0) return;
    defer _ = c.close(fd);
    if (!exists) _ = c.write(fd, battery_log_header, battery_log_header.len);
    _ = c.write(fd, row.ptr, row.len);
}

// ------------------------------------------------------------------- wifi

pub fn setWifi(on: bool) void {
    sys.run("lipc-set-prop com.lab126.wifid enable {d}", .{@intFromBool(on)});
}

// ----------------------------------------------------------------- powerd
//
// Between updates the Kindle is put to sleep through powerd, which is the
// only route that works on the K3 (see sleeptest.sh / sleeptest.log):
//   1. go to the screensaver (powerd_test -p = a power-switch press)
//   2. ~60 s later powerd reports "readyToSuspend"; in that window we set
//      rtcWakeup, and powerd programs the PMIC alarm as it suspends.
//      (Writing the alarm ourselves is useless: powerd overwrites it.
//      deferSuspend is rejected with lipcPropErrInvalidState.)
//   3. the alarm wakes the Kindle into the screensaver state, and powerd
//      suspends again ~60 s later, so steps 2-3 repeat.

pub const PowerState = enum { active, screen_saver, ready, other };

/// powerd's state name, e.g. "active", "screenSaver", "readyToSuspend".
fn stateName(buf: *[64]u8) []const u8 {
    const out = sys.output("lipc-get-prop com.lab126.powerd state 2>/dev/null", buf) orelse return "";
    return std.mem.trim(u8, out, " \r\n");
}

pub fn powerState() PowerState {
    var buf: [64]u8 = undefined;
    return classify(stateName(&buf));
}

fn classify(s: []const u8) PowerState {
    if (std.mem.eql(u8, s, "active")) return .active;
    if (std.mem.eql(u8, s, "screenSaver")) return .screen_saver;
    if (std.mem.eql(u8, s, "readyToSuspend")) return .ready;
    return .other;
}

/// Let powerd take over: allow the screensaver and enter it now.
pub fn enterScreenSaver() void {
    sys.run("lipc-set-prop com.lab126.powerd preventScreenSaver 0", .{});
    sys.run("powerd_test -p >/dev/null", .{});
    // Log where powerd went and how long it plans to stay there.
    sys.sleepMs(2000);
    var buf: [1024]u8 = undefined;
    const status = sys.output("lipc-get-prop com.lab126.powerd status 2>/dev/null", &buf) orelse "";
    var lines = std.mem.tokenizeScalar(u8, status, '\n');
    const state = lines.next() orelse "?";
    const remaining = lines.next() orelse "?";
    sys.log("pressed power button: {s}; {s}", .{ state, remaining });
}

/// Ask powerd to wake us `seconds` from now. Only accepted while ready to
/// suspend.
pub fn armWakeup(seconds: i64) void {
    sys.run("lipc-set-prop -i com.lab126.powerd rtcWakeup {d}", .{seconds});
}

/// Arm the wake-up alarm the moment powerd reports readyToSuspend.
///
/// powerd only accepts rtcWakeup in that state, and with the stock UI paused
/// nothing holds it there: powerd suspends within seconds, so polling for it
/// can miss the window (and then only powerd's own ~9 min alarm wakes us).
/// Instead leave a shell blocked on the event, which arms immediately and
/// records when it did so in `armed_file`.
pub fn armOnReady(seconds: i64) void {
    cancelArm();
    sys.run("rm -f " ++ armed_file ++ "; (lipc-wait-event com.lab126.powerd readyToSuspend >/dev/null" ++
        " && lipc-set-prop -i com.lab126.powerd rtcWakeup {d} && echo $(date +%s) {d} > " ++ armed_file ++ ") &", .{ seconds, seconds });
}

/// Stop a pending armOnReady watcher.
pub fn cancelArm() void {
    sys.run("killall lipc-wait-event 2>/dev/null; true", .{});
}

pub const armed_file = "/tmp/k3-weather.armed";

pub const Armed = struct { at: i64, seconds: i64 };

/// When (epoch seconds) and for how long the alarm was set, if it was.
pub fn armed() ?Armed {
    var buf: [48]u8 = undefined;
    const s = sys.readFile(armed_file, &buf) catch return null;
    var it = std.mem.tokenizeAny(u8, s, " \r\n");
    const at = std.fmt.parseInt(i64, it.next() orelse return null, 10) catch return null;
    const seconds = std.fmt.parseInt(i64, it.next() orelse return null, 10) catch return null;
    return .{ .at = at, .seconds = seconds };
}

pub const SleepResult = union(enum) {
    /// Suspended and resumed; seconds spent asleep.
    resumed: i64,
    /// The screen was woken (power switch) without a suspend.
    woken,
    timeout,
};

/// Wait for the Kindle to suspend and resume (seen as a jump in wall-clock
/// time), logging powerd state changes. If we happen to see readyToSuspend
/// ourselves, arm `fallback_seconds` too, in case the event watcher failed.
pub fn waitForSleep(timeout_s: i64, fallback_seconds: i64) SleepResult {
    const start = sys.nowMs();
    var last = sys.realtimeSec();
    var prev_buf: [64]u8 = undefined;
    var prev: []const u8 = "";
    var tried = false;
    while (sys.nowMs() - start < timeout_s * 1000) {
        const t = sys.realtimeSec();
        if (t - last > 5) return .{ .resumed = t - last };
        last = t;

        var buf: [64]u8 = undefined;
        const name = stateName(&buf);
        if (!std.mem.eql(u8, name, prev)) {
            sys.log("powerd: {s} after {d}s", .{ name, @divTrunc(sys.nowMs() - start, 1000) });
            @memcpy(prev_buf[0..name.len], name);
            prev = prev_buf[0..name.len];
        }
        switch (classify(name)) {
            .active => return .woken,
            // Only if the event watcher has not armed already.
            .ready => if (!tried and armed() == null) {
                armWakeup(fallback_seconds);
                sys.run("echo $(date +%s) {d} > " ++ armed_file, .{fallback_seconds});
                sys.log("watcher missed readyToSuspend; armed rtcWakeup {d}s", .{fallback_seconds});
                tried = true;
            },
            else => {},
        }
        sys.sleepMs(1000);
    }
    return .timeout;
}
