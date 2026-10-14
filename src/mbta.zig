//! MBTA departure predictions (api-v3.mbta.com, HTTPS, no API key needed at
//! our request rate).

const std = @import("std");
const net = @import("net.zig");
const sys = @import("sys.zig");

pub const host = "api-v3.mbta.com";
pub const max_lines = 3;
pub const max_times = 3;

/// One configured row: "STOP ROUTE DIRECTION LABEL...", e.g.
/// "place-cntsq Red 1 Red to Alewife @ Central".
pub const Line = struct {
    stop: []const u8,
    route: []const u8,
    direction: u1,
    label: []const u8,

    pub fn parse(spec: []const u8) ?Line {
        var it = std.mem.tokenizeScalar(u8, spec, ' ');
        const stop = it.next() orelse return null;
        const route = it.next() orelse return null;
        const dir = it.next() orelse return null;
        const direction: u1 = if (std.mem.eql(u8, dir, "0")) 0 else if (std.mem.eql(u8, dir, "1")) 1 else return null;
        const label = std.mem.trim(u8, it.rest(), " ");
        return .{ .stop = stop, .route = route, .direction = direction, .label = if (label.len > 0) label else route };
    }
};

pub const Departures = struct {
    /// Local "HH:MM" (24h) of the next departures.
    times: [max_times][5]u8 = undefined,
    n: usize = 0,
    /// UTC offset in seconds, from the "-04:00" suffix of the times.
    utc_offset: ?i64 = null,
    /// Set when the fetch failed.
    err: ?[]const u8 = null,
};

/// The MBTA half of the screen: the configured rows, their latest
/// departures, and when they were fetched.
pub const Board = struct {
    lines: [max_lines]Line = undefined,
    n: usize = 0,
    departures: [max_lines]Departures = @splat(.{}),
    /// Local "HH:MM" of the last refresh where at least one row succeeded.
    updated: ?[5]u8 = null,
    /// Last UTC offset seen in departure times, for refreshes that had none.
    utc_offset: ?i64 = null,
    /// Rows whose stop is confirmed to exist, so each is looked up once.
    stop_ok: [max_lines]bool = @splat(false),

    /// Add a "STOP ROUTE DIRECTION LABEL" row.
    pub fn add(b: *Board, spec: []const u8) !void {
        if (b.n == max_lines) return error.TooManyLines;
        b.lines[b.n] = Line.parse(spec) orelse return error.BadLine;
        b.n += 1;
    }

    pub fn rows(b: *const Board) []const Line {
        return b.lines[0..b.n];
    }

    /// Fetch every row (one HTTPS request each, plus a one-time stop check).
    pub fn refresh(b: *Board, buf: []u8) void {
        for (b.rows(), b.departures[0..b.n], 0..) |line, *dep, i| {
            const start = sys.nowMs();
            dep.* = b.fetch(i, line, buf) catch |e| .{ .err = @errorName(e) };
            const ms = sys.nowMs() - start;
            if (dep.err) |e| {
                const detail = if (std.mem.eql(u8, e, "Tls")) @errorName(net.last_tls_error) else "";
                sys.log("mbta {s}: {s} {s} after {d} ms", .{ line.label, e, detail, ms });
                continue;
            }
            sys.log("mbta {s}: {d} departures in {d} ms", .{ line.label, dep.n, ms });
            if (dep.utc_offset) |off| b.utc_offset = off;
            if (b.utc_offset) |off| b.updated = sys.localHHMM(off);
        }
    }

    fn fetch(b: *Board, i: usize, line: Line, buf: []u8) !Departures {
        var path_buf: [384]u8 = undefined;
        // The predictions endpoint silently ignores an unknown stop filter and
        // returns other stops on the route, so make sure the stop exists first.
        if (!b.stop_ok[i]) {
            const stop_path = try std.mem.print(&path_buf, "/stops/{s}?fields%5Bstop%5D=name", .{line.stop});
            _ = net.getTls(host, stop_path, buf) catch |e| return if (e == error.HttpStatus) error.UnknownStop else e;
            b.stop_ok[i] = true;
        }
        // Ask for a few extra in case some have no time (e.g. skipped stops).
        const path = try std.mem.print(&path_buf, "/predictions?filter%5Bstop%5D={s}&filter%5Broute%5D={s}" ++
            "&filter%5Bdirection_id%5D={d}&sort=departure_time&page%5Blimit%5D=6" ++
            "&fields%5Bprediction%5D=departure_time,arrival_time", .{ line.stop, line.route, line.direction });
        const body = try net.getTls(host, path, buf);
        return parse(body);
    }
};

/// Pull "HH:MM" out of each prediction's departure (or arrival) time,
/// e.g. "2026-10-13T15:17:26-04:00". The API already returns local times.
pub fn parse(json: []const u8) !Departures {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), json, .{});
    if (root != .object) return error.BadResponse;
    const data = root.object.get("data") orelse return error.BadResponse;
    if (data != .array) return error.BadResponse;

    var d = Departures{};
    for (data.array.items) |item| {
        if (d.n == max_times) break;
        if (item != .object) continue;
        const attrs = item.object.get("attributes") orelse continue;
        if (attrs != .object) continue;
        const t = timeOf(attrs.object, "departure_time") orelse timeOf(attrs.object, "arrival_time") orelse continue;
        if (t.len < 16) continue;
        @memcpy(&d.times[d.n], t[11..16]);
        if (d.utc_offset == null) d.utc_offset = parseOffset(t);
        d.n += 1;
    }
    return d;
}

fn timeOf(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

/// "...T15:17:26-04:00" -> -14400.
fn parseOffset(t: []const u8) ?i64 {
    if (t.len < 25) return null;
    const sign: i64 = switch (t[19]) {
        '+' => 1,
        '-' => -1,
        else => return null,
    };
    const h = std.fmt.parseInt(i64, t[20..22], 10) catch return null;
    const m = std.fmt.parseInt(i64, t[23..25], 10) catch return null;
    return sign * (h * 3600 + m * 60);
}

test parseOffset {
    try std.testing.expectEqual(@as(?i64, -14400), parseOffset("2026-10-13T15:17:26-04:00"));
    try std.testing.expectEqual(@as(?i64, 3600), parseOffset("2026-10-13T15:17:26+01:00"));
    try std.testing.expectEqual(@as(?i64, null), parseOffset("2026-10-13T15:17"));
}
