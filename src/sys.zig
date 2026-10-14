//! Small libc-based helpers shared by the other modules: logging, clocks,
//! files and shell commands.

const std = @import("std");
const c = std.c;

/// UTC offset (seconds) used for log timestamps; set once a forecast with a
/// time zone has been fetched. Until then timestamps are UTC.
pub var utc_offset: i64 = 0;

/// Log a line to stderr, prefixed with the local wall-clock time.
pub fn log(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const t: u64 = @intCast(@mod(realtimeSec() + utc_offset, 86400));
    const s = std.mem.print(&buf, "{d:0>2}:{d:0>2}:{d:0>2} " ++ fmt ++ "\n", .{ t / 3600, t % 3600 / 60, t % 60 } ++ args) catch return;
    _ = c.write(2, s.ptr, s.len);
}

/// Monotonic milliseconds (does not advance while suspended).
pub fn nowMs() i64 {
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(c.CLOCK.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

/// Wall-clock seconds since the epoch (jumps forward across a suspend).
pub fn realtimeSec() i64 {
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(c.CLOCK.REALTIME, &ts);
    return ts.sec;
}

/// Current local time as "HH:MM", given a UTC offset in seconds.
pub fn localHHMM(offset: i64) [5]u8 {
    const t: u64 = @intCast(@mod(realtimeSec() + offset, 86400));
    var out: [5]u8 = undefined;
    _ = std.mem.print(&out, "{d:0>2}:{d:0>2}", .{ t / 3600, t % 3600 / 60 }) catch unreachable;
    return out;
}

pub fn sleepMs(ms: c_int) void {
    _ = c.poll(&[0]c.pollfd{}, 0, ms);
}

/// Read up to `buf.len` bytes of a file.
pub fn readFile(path: [:0]const u8, buf: []u8) ![]u8 {
    const fd = c.open(path, .{ .ACCMODE = .RDONLY });
    if (fd < 0) return error.FileNotFound;
    defer _ = c.close(fd);
    var len: usize = 0;
    while (len < buf.len) {
        const n = c.read(fd, buf[len..].ptr, buf.len - len);
        if (n <= 0) break;
        len += @intCast(n);
    }
    return buf[0..len];
}

extern "c" fn system(cmd: [*:0]const u8) c_int;
extern "c" fn popen(cmd: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
extern "c" fn pclose(f: *anyopaque) c_int;
extern "c" fn fread(ptr: [*]u8, size: usize, n: usize, f: *anyopaque) usize;

/// Run a shell command, logging if it fails.
pub fn run(comptime fmt: []const u8, args: anytype) void {
    var buf: [320]u8 = undefined;
    const cmd = std.mem.printSentinel(&buf, fmt, args, 0) catch return;
    if (system(cmd) != 0) log("'{s}' failed", .{cmd});
}

/// Run a shell command and return (up to `buf.len` bytes of) its stdout.
pub fn output(cmd: [:0]const u8, buf: []u8) ?[]const u8 {
    const f = popen(cmd, "r") orelse return null;
    const n = fread(buf.ptr, 1, buf.len, f);
    _ = pclose(f);
    return buf[0..n];
}
