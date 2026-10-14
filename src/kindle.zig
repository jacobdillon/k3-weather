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
    const i = std.mem.find(u8, s, key) orelse return null;
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
    const row = std.mem.print(&buf, "{d}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z,{d},{d},{d},{s},{d}\n", .{
        yd.year, md.month.numeric(), md.day_index + 1, // date
        ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(), // time
        now,                  pct,                     @intFromBool(charging),
        fetch_result,         wifi_ms,
    }) catch return;

    var fd = openAppend(path) orelse return;
    // Keep one previous file once this one passes the limit, like weather.log.
    if (c.lseek(fd, 0, c.SEEK.END) > battery_log_max) {
        _ = c.close(fd);
        var ob: [512]u8 = undefined;
        const old = std.mem.printSentinel(&ob, "{s}.old", .{path}, 0) catch return;
        _ = c.rename(path, old);
        fd = openAppend(path) orelse return;
    }
    defer _ = c.close(fd);
    if (c.lseek(fd, 0, c.SEEK.END) == 0) _ = c.write(fd, battery_log_header, battery_log_header.len);
    _ = c.write(fd, row.ptr, row.len);
}

/// About a month of 5-minute rows (~60 bytes each), so the current file plus
/// battery.csv.old cover the last one to two months.
const battery_log_max = 512 * 1024;

fn openAppend(path: [:0]const u8) ?c.fd_t {
    const fd = c.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, @as(c.mode_t, 0o644));
    return if (fd < 0) null else fd;
}

// ------------------------------------------------------------------- wifi

pub fn setWifi(on: bool) void {
    sys.run("lipc-set-prop com.lab126.wifid enable {d}", .{@intFromBool(on)});
}

// ---------------------------------------------------------------- suspend
//
// Sleep between updates by suspending the kernel directly, the way
// kindle-dash does on the Kindle 4: arm Amazon's RTC driver with
// mxc_rtc.0/wakeup_enable (seconds from now), then write "mem" to
// /sys/power/state, which returns once the Kindle wakes.
//
// powerd stays out of it: the launcher keeps preventScreenSaver=1 and the
// stock UI paused, so there is no screensaver (and no flash). Going through
// powerd instead (rtcWakeup in its readyToSuspend window) proved unreliable
// on the K3: with the stock UI paused the alarm was accepted but never
// programmed, and with it resumed powerd never became ready at all.

const wakeup_enable = "/sys/devices/platform/mxc_rtc.0/wakeup_enable";

/// Suspend for about `seconds`. Returns once the Kindle wakes (timer or
/// power switch), or an error if the kernel refused to suspend.
pub fn suspendFor(seconds: i64) !void {
    var buf: [24]u8 = undefined;
    try writeSysfs(wakeup_enable, try std.mem.print(&buf, "{d}", .{seconds}));
    sys.log("suspending for {d}s", .{seconds});
    try writeSysfs("/sys/power/state", "mem");
}

fn writeSysfs(path: [:0]const u8, data: []const u8) !void {
    const fd = c.open(path, .{ .ACCMODE = .WRONLY });
    if (fd < 0) return errnoError(path);
    defer _ = c.close(fd);
    if (c.write(fd, data.ptr, data.len) < 0) return errnoError(path);
}

fn errnoError(path: []const u8) error{SysfsWrite} {
    const e: c.E = @fromBackingInt(@intCast(c._errno().*));
    sys.log("writing {s} failed: {s}", .{ path, @tagName(e) });
    return error.SysfsWrite;
}

pub const WakeSource = enum { power_button, unknown, other };

/// After a resume: log what woke the Kindle (from the kernel log, e.g.
/// "Power Button") and which alarm the PMIC clock holds.
pub fn logWakeInfo() WakeSource {
    var buf: [512]u8 = undefined;
    const line = sys.output("dmesg | grep 'wakeup:source=' | tail -n 1", &buf) orelse "";
    const key = "source=";
    const source = if (std.mem.find(u8, line, key)) |i|
        std.mem.trimEnd(u8, std.mem.sliceTo(line[i + key.len ..], '\n'), ": \r")
    else
        "unknown";
    var rbuf: [512]u8 = undefined;
    const rtc = sys.output("grep -e rtc_time -e alrm_time -e alrm_date /proc/driver/rtc", &rbuf) orelse "";
    var flat: [160]u8 = undefined;
    var n: usize = 0;
    for (rtc) |ch| {
        if (n == flat.len) break;
        flat[n] = if (ch == '\n' or ch == '\t') ' ' else ch;
        n += 1;
    }
    sys.log("woken by: {s}; {s}", .{ source, std.mem.trim(u8, flat[0..n], " ") });
    if (std.mem.eql(u8, source, "unknown")) return .unknown;
    if (std.mem.find(u8, source, "Power") != null) return .power_button;
    return .other;
}
