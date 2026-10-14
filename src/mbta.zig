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
    /// Rows whose stop is confirmed to exist, so each stop is looked up once.
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

    /// Fetch every row. Rows on the same stop and route (e.g. both
    /// directions at one station) share a single HTTPS request.
    pub fn refresh(b: *Board, buf: []u8) void {
        var done: [max_lines]bool = @splat(false);
        for (b.rows(), 0..) |first, i| {
            if (done[i]) continue;
            const start = sys.nowMs();
            const body = b.fetchGroup(i, buf);
            const ms = sys.nowMs() - start;
            var shared: usize = 0;
            for (b.rows()[i..], i..) |line, j| {
                if (!sameGroup(first, line)) continue;
                done[j] = true;
                shared += 1;
                const dep = &b.departures[j];
                dep.* = if (body) |json| parse(json, line.direction) catch |e| .{ .err = @errorName(e) } else |e| .{ .err = @errorName(e) };
                if (dep.err) |e| {
                    const detail = if (std.mem.eql(u8, e, "Tls")) @errorName(net.last_tls_error) else "";
                    sys.log("mbta {s}: {s} {s}", .{ line.label, e, detail });
                    continue;
                }
                sys.log("mbta {s}: {d} departures", .{ line.label, dep.n });
                if (dep.utc_offset) |off| b.utc_offset = off;
                if (b.utc_offset) |off| b.updated = sys.localHHMM(off);
            }
            sys.log("mbta {s} @ {s}: 1 request for {d} row(s) in {d} ms", .{ first.route, first.stop, shared, ms });
        }
    }

    fn sameGroup(a: Line, b: Line) bool {
        return std.mem.eql(u8, a.stop, b.stop) and std.mem.eql(u8, a.route, b.route);
    }

    /// Predictions for row `i`'s stop and route, in all directions.
    fn fetchGroup(b: *Board, i: usize, buf: []u8) ![]u8 {
        const line = b.lines[i];
        var path_buf: [384]u8 = undefined;
        // The predictions endpoint silently ignores an unknown stop filter and
        // returns other stops on the route, so make sure the stop exists first.
        if (!b.stopChecked(line.stop)) {
            const stop_path = try std.mem.print(&path_buf, "/stops/{s}?fields%5Bstop%5D=name", .{line.stop});
            _ = net.getTls(host, stop_path, buf) catch |e| return if (e == error.HttpStatus) error.UnknownStop else e;
            b.stop_ok[i] = true;
        }
        // Both directions, sorted by time. Predictions without a time sort
        // first and are skipped by `parse`, so ask for plenty.
        const path = try std.mem.print(&path_buf, "/predictions?filter%5Bstop%5D={s}&filter%5Broute%5D={s}" ++
            "&sort=departure_time&page%5Blimit%5D=20" ++
            "&fields%5Bprediction%5D=departure_time,arrival_time,direction_id", .{ line.stop, line.route });
        return net.getTls(host, path, buf);
    }

    fn stopChecked(b: *const Board, stop: []const u8) bool {
        for (b.rows(), b.stop_ok[0..b.n]) |line, ok| {
            if (ok and std.mem.eql(u8, line.stop, stop)) return true;
        }
        return false;
    }
};

/// Pull "HH:MM" out of each prediction's departure (or arrival) time, e.g.
/// "2026-10-13T15:17:26-04:00", keeping those in `direction` (all if null).
/// The API already returns local times.
pub fn parse(json: []const u8, direction: ?u1) !Departures {
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
        if (direction) |want| {
            const dir = attrs.object.get("direction_id") orelse continue;
            if (dir != .integer or dir.integer != want) continue;
        }
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

test "Line.parse" {
    const l = Line.parse("place-cntsq Red 1 Red to Alewife @ Central").?;
    try std.testing.expectEqualStrings("place-cntsq", l.stop);
    try std.testing.expectEqualStrings("Red", l.route);
    try std.testing.expectEqual(@as(u1, 1), l.direction);
    try std.testing.expectEqualStrings("Red to Alewife @ Central", l.label);
    // The label defaults to the route; the direction must be 0 or 1.
    try std.testing.expectEqualStrings("77", Line.parse("1234 77 0").?.label);
    try std.testing.expect(Line.parse("1234 77 2 x") == null);
    try std.testing.expect(Line.parse("1234 77") == null);
}

test parse {
    // Shaped like a real both-directions response: untimed predictions sort
    // first, and the directions are interleaved.
    const json =
        \\{"data":[
        \\ {"attributes":{"direction_id":0,"departure_time":null,"arrival_time":null}},
        \\ {"attributes":{"direction_id":1,"departure_time":null,"arrival_time":null}},
        \\ {"attributes":{"direction_id":0,"departure_time":"2026-10-14T06:59:10-04:00","arrival_time":null}},
        \\ {"attributes":{"direction_id":1,"departure_time":null,"arrival_time":"2026-10-14T07:01:00-04:00"}},
        \\ {"attributes":{"direction_id":1,"departure_time":"2026-10-14T07:04:00-04:00","arrival_time":null}},
        \\ {"attributes":{"direction_id":0,"departure_time":"2026-10-14T07:06:00-04:00","arrival_time":null}},
        \\ {"attributes":{"direction_id":0,"departure_time":"2026-10-14T07:08:00-04:00","arrival_time":null}},
        \\ {"attributes":{"direction_id":0,"departure_time":"2026-10-14T07:17:00-04:00","arrival_time":null}},
        \\ {"attributes":{"direction_id":1,"departure_time":"2026-10-14T07:08:00-04:00","arrival_time":null}}
        \\]}
    ;
    const south = try parse(json, 0);
    try std.testing.expectEqual(@as(usize, 3), south.n); // capped at max_times
    try std.testing.expectEqualStrings("06:59", &south.times[0]);
    try std.testing.expectEqualStrings("07:06", &south.times[1]);
    try std.testing.expectEqualStrings("07:08", &south.times[2]);
    try std.testing.expectEqual(@as(?i64, -4 * 3600), south.utc_offset);

    const north = try parse(json, 1);
    try std.testing.expectEqual(@as(usize, 3), north.n);
    try std.testing.expectEqualStrings("07:01", &north.times[0]); // arrival when no departure
    try std.testing.expectEqualStrings("07:04", &north.times[1]);

    try std.testing.expectEqual(@as(usize, 3), (try parse(json, null)).n);
    try std.testing.expectEqual(@as(usize, 0), (try parse("{\"data\":[]}", 0)).n);
    try std.testing.expectError(error.BadResponse, parse("{\"errors\":[]}", 0));
}
