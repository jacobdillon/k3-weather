//! Screen layout. Everything here draws from a `Screen` value; no I/O.

const std = @import("std");
const cv = @import("canvas.zig");
const icons = @import("icons.zig");
const forecast = @import("forecast.zig");
const mbta = @import("mbta.zig");
const kindle = @import("kindle.zig");

const Weather = forecast.Weather;

/// What the bottom half of the screen shows.
pub const View = enum {
    days,
    mbta,

    pub fn other(v: View) View {
        return if (v == .days) .mbta else .days;
    }
};

/// The status line under the header, at the right.
pub const Status = union(enum) { ok, failed: []const u8, note: []const u8 };

pub const Screen = struct {
    name: []const u8,
    units: forecast.Units,
    weather: *const Weather,
    status: Status = .ok,
    battery: ?kindle.Battery = null,
    /// null when no MBTA rows are configured (no view switching).
    board: ?*const mbta.Board = null,
    view: View = .days,
    /// The Kindle sleeps between updates, so keys need the power switch first.
    sleep: bool = false,
};

const M = 28; // side margin

pub fn render(canvas: *cv.Canvas, s: Screen) void {
    const w = s.weather;
    canvas.clear(cv.white);
    var b1: [64]u8 = undefined;
    var b2: [64]u8 = undefined;
    var b3: [160]u8 = undefined;

    const today = parseDate(&w.days[0].date);
    const wind_unit = if (s.units == .metric) "km/h" else "mph";
    const precip_unit = if (s.units == .metric) "mm" else "in";

    // Header
    cv.text(canvas, .bold, cv.fitSize(.bold, 32, 300, s.name), M, 50, .left, cv.black, s.name);
    const date_s = std.mem.print(&b1, "{s}, {s} {d}", .{ weekdays[weekday(today)], months[today.m - 1], today.d }) catch "";
    cv.text(canvas, .regular, 24, cv.W - M, 48, .right, cv.black, date_s);
    canvas.hline(M, cv.W - M, 68, 3, cv.black);

    // Today: icon + current temp
    icons.draw(canvas, icons.kindFor(w.code, w.is_day), 18, 82, 260);
    cv.text(canvas, .bold, 132, 432, 222, .center, cv.black, tempStr(&b1, w.temp));
    if (w.feels) |f| {
        const t = std.mem.print(&b2, "Feels like {s}", .{tempStr(&b1, f)}) catch "";
        cv.text(canvas, .regular, 26, 432, 268, .center, cv.dark_gray, t);
    }
    {
        var hb: [16]u8 = undefined;
        var lb: [16]u8 = undefined;
        const t = std.mem.print(&b2, "H {s}   L {s}", .{ tempStr(&hb, w.days[0].hi), tempStr(&lb, w.days[0].lo) }) catch "";
        cv.text(canvas, .bold, 32, 432, 318, .center, cv.black, t);
    }

    const cond = icons.describe(w.code);
    cv.text(canvas, .bold, cv.fitSize(.bold, 40, cv.W - 2 * M, cond), cv.W / 2, 392, .center, cv.black, cond);

    // Detail lines
    {
        var parts: [3][]const u8 = undefined;
        var n: usize = 0;
        var pb: [48]u8 = undefined;
        var wb: [32]u8 = undefined;
        var hb: [32]u8 = undefined;
        if (w.days[0].pop) |p| {
            parts[n] = if (w.days[0].precip) |amt| switch (s.units) {
                .metric => std.mem.print(&pb, "Rain {d:.0}% · {d:.1} {s}", .{ p, amt, precip_unit }),
                .imperial => std.mem.print(&pb, "Rain {d:.0}% · {d:.2} {s}", .{ p, amt, precip_unit }),
            } catch "" else std.mem.print(&pb, "Rain {d:.0}%", .{p}) catch "";
            n += 1;
        }
        if (w.wind) |v| {
            parts[n] = std.mem.print(&wb, "Wind {d:.0} {s}", .{ v, wind_unit }) catch "";
            n += 1;
        }
        if (w.humidity) |h| {
            parts[n] = std.mem.print(&hb, "Hum {d:.0}%", .{h}) catch "";
            n += 1;
        }
        const t = joinParts(&b3, parts[0..n], "    ");
        cv.text(canvas, .regular, cv.fitSize(.regular, 24, cv.W - 2 * M, t), cv.W / 2, 440, .center, cv.black, t);
        var rb: [16]u8 = undefined;
        var sb: [16]u8 = undefined;
        const sun = std.mem.print(&b2, "Sunrise {s}    Sunset {s}", .{ timeStr(&rb, &w.days[0].sunrise), timeStr(&sb, &w.days[0].sunset) }) catch "";
        cv.text(canvas, .regular, 24, cv.W / 2, 478, .center, cv.black, sun);
    }

    canvas.hline(M, cv.W - M, 500, 3, cv.black);

    // Bottom half: the next two days, or MBTA departures.
    if (s.board) |board| {
        if (s.view == .mbta) renderMbta(canvas, board) else renderDays(canvas, w);
        const target = if (s.view == .mbta) "forecast" else "MBTA";
        const hint = if (s.sleep)
            std.mem.print(&b3, "Slide the power switch, then press M for {s}", .{target}) catch ""
        else
            std.mem.print(&b3, "Press M for {s}", .{target}) catch "";
        cv.text(canvas, .regular, 16, cv.W / 2, 794, .center, cv.dark_gray, hint);
    } else renderDays(canvas, w);

    // Status, tucked under the header rule
    var tb: [16]u8 = undefined;
    const as_of = timeStr(&tb, &w.as_of);
    const st = switch (s.status) {
        .ok => std.mem.print(&b3, "updated {s}", .{as_of}) catch "",
        .failed => |e| std.mem.print(&b3, "OFFLINE ({s}) · data from {s}", .{ e, as_of }) catch "",
        .note => |n| n,
    };
    cv.text(canvas, if (s.status == .note) .bold else .regular, 16, cv.W - M, 88, .right, if (s.status == .ok) cv.dark_gray else cv.black, st);

    if (s.battery) |bat| drawBattery(canvas, M, 76, bat);
}

/// A centred title and message, for when there is no forecast to show yet.
pub fn renderMessage(canvas: *cv.Canvas, title: []const u8, msg: []const u8) void {
    canvas.clear(cv.white);
    cv.text(canvas, .bold, 36, cv.W / 2, 360, .center, cv.black, title);
    cv.text(canvas, .regular, cv.fitSize(.regular, 26, cv.W - 40, msg), cv.W / 2, 420, .center, cv.black, msg);
}

fn renderDays(canvas: *cv.Canvas, w: *const Weather) void {
    var b1: [64]u8 = undefined;
    var b2: [64]u8 = undefined;
    canvas.vline(cv.W / 2 - 1, 516, 756, 2, cv.gray);
    for (w.days[1..3], 0..) |*day, i| {
        const cx: i32 = @intCast(cv.W / 4 + i * cv.W / 2);
        const dt = parseDate(&day.date);
        cv.text(canvas, .bold, 30, cx, 540, .center, cv.black, weekdays[weekday(dt)]);
        icons.draw(canvas, icons.kindFor(day.code, true), cx - 66, 548, 132);
        var hb: [16]u8 = undefined;
        var lb: [16]u8 = undefined;
        const hl = std.mem.print(&b1, "{s} / {s}", .{ tempStr(&hb, day.hi), tempStr(&lb, day.lo) }) catch "";
        cv.text(canvas, .bold, 36, cx, 714, .center, cv.black, hl);
        const d = icons.describe(day.code);
        cv.text(canvas, .regular, cv.fitSize(.regular, 22, cv.W / 2 - 24, d), cx, 744, .center, cv.black, d);
        if (day.pop) |p| {
            const s = std.mem.print(&b2, "Rain {d:.0}%", .{p}) catch "";
            cv.text(canvas, .regular, 20, cx, 768, .center, cv.dark_gray, s);
        }
    }
}

/// Up to three rows: a label, then the next departure times.
fn renderMbta(canvas: *cv.Canvas, board: *const mbta.Board) void {
    const row_h = 90;

    // "updated 3:29 PM" at the top right of the section, beside the first label.
    var stamp_w: i32 = 0;
    if (board.updated) |*hhmm| {
        var tb: [16]u8 = undefined;
        var sb: [32]u8 = undefined;
        const s = std.mem.print(&sb, "updated {s}", .{timeStr(&tb, hhmm)}) catch "";
        cv.text(canvas, .regular, 16, cv.W - M, 506 + 28, .right, cv.dark_gray, s);
        stamp_w = cv.textWidth(.regular, 16, s) + 16;
    }

    for (board.rows(), board.departures[0..board.n], 0..) |line, dep, i| {
        const y0: i32 = 506 + @as(i32, @intCast(i)) * row_h;
        if (i > 0) canvas.hline(M, cv.W - M, y0 - 4, 1, cv.gray);
        const label_w = cv.W - 2 * M - if (i == 0) stamp_w else 0;
        cv.text(canvas, .bold, cv.fitSize(.bold, 24, label_w, line.label), M, y0 + 28, .left, cv.black, line.label);
        if (dep.err) |e| {
            var eb: [64]u8 = undefined;
            const s = std.mem.print(&eb, "Unavailable ({s})", .{e}) catch "Unavailable";
            cv.text(canvas, .regular, 26, M, y0 + 74, .left, cv.dark_gray, s);
        } else if (dep.n == 0) {
            cv.text(canvas, .regular, 26, M, y0 + 74, .left, cv.dark_gray, "No upcoming departures");
        } else {
            drawDepartures(canvas, dep.times[0..dep.n], y0 + 78);
        }
    }
}

/// "3:25 PM  3:31 PM ...": big bold times, smaller AM/PM, shrunk to fit.
fn drawDepartures(canvas: *cv.Canvas, times: []const [5]u8, baseline: i32) void {
    var size: f32 = 42;
    while (size > 24 and departuresWidth(times, size, null, 0) > cv.W - 2 * M) size -= 1;
    _ = departuresWidth(times, size, canvas, baseline);
}

/// Lay out a row of departures at `size`, drawing it if `canvas` is set.
/// Returns the width, excluding the trailing gap.
fn departuresWidth(times: []const [5]u8, size: f32, canvas: ?*cv.Canvas, baseline: i32) i32 {
    const suffix_size = @round(size * 0.55);
    const suffix_gap: i32 = @intFromFloat(@round(size * 0.12));
    const gap: i32 = @intFromFloat(@round(size * 0.7));
    var x: i32 = M;
    for (times, 0..) |*t, i| {
        if (i > 0) x += gap;
        var buf: [8]u8 = undefined;
        const t12 = time12(&buf, t);
        if (canvas) |cnv| cv.text(cnv, .bold, size, x, baseline, .left, cv.black, t12.hm);
        x += cv.textWidth(.bold, size, t12.hm) + suffix_gap;
        if (canvas) |cnv| cv.text(cnv, .regular, suffix_size, x, baseline, .left, cv.black, t12.suffix);
        x += cv.textWidth(.regular, suffix_size, t12.suffix);
    }
    return x - M;
}

/// Battery outline with proportional fill, followed by "85%". Goes bold
/// with a "charge me" hint when low.
fn drawBattery(canvas: *cv.Canvas, x: i32, y: i32, bat: kindle.Battery) void {
    const bw = 30;
    const bh = 14;
    canvas.fillRect(x, y, bw, bh, cv.black);
    canvas.fillRect(x + 2, y + 2, bw - 4, bh - 4, cv.white);
    canvas.fillRect(x + bw, y + 4, 3, bh - 8, cv.black); // terminal nub
    const fill_w: i32 = @divTrunc((bw - 8) * @as(i32, bat.pct), 100);
    canvas.fillRect(x + 4, y + 4, fill_w, bh - 8, cv.black);

    const low = bat.pct <= 20 and !bat.charging;
    var buf: [32]u8 = undefined;
    const s = std.mem.print(&buf, "{d}%{s}", .{
        bat.pct,
        if (bat.charging) " charging" else if (low) " - charge me" else "",
    }) catch "";
    cv.text(canvas, if (low) .bold else .regular, 16, x + bw + 9, y + 12, .left, if (low) cv.black else cv.dark_gray, s);
}

// ------------------------------------------------------------- formatting

fn tempStr(buf: []u8, v: f64) []const u8 {
    return std.mem.print(buf, "{d}°", .{@as(i32, @intFromFloat(@round(v)))}) catch "?";
}

/// "HH:MM" (24h) as 12-hour "h:MM" plus "AM"/"PM". Unparseable input is
/// passed through with no suffix.
const Time12 = struct { hm: []const u8, suffix: []const u8 };

fn time12(buf: *[8]u8, hhmm: *const [5]u8) Time12 {
    const h = std.fmt.parseInt(u8, hhmm[0..2], 10) catch return .{ .hm = hhmm, .suffix = "" };
    if (h > 23) return .{ .hm = hhmm, .suffix = "" };
    const hm = std.mem.print(buf, "{d}:{s}", .{ if (h % 12 == 0) 12 else h % 12, hhmm[3..5] }) catch unreachable;
    return .{ .hm = hm, .suffix = if (h < 12) "AM" else "PM" };
}

/// "HH:MM" (24h) -> "h:MM AM/PM".
fn timeStr(buf: *[16]u8, hhmm: *const [5]u8) []const u8 {
    var b: [8]u8 = undefined;
    const t = time12(&b, hhmm);
    if (t.suffix.len == 0) return hhmm;
    return std.mem.print(buf, "{s} {s}", .{ t.hm, t.suffix }) catch unreachable;
}

fn joinParts(buf: []u8, parts: []const []const u8, sep: []const u8) []const u8 {
    var n: usize = 0;
    for (parts, 0..) |p, i| {
        if (i > 0 and n + sep.len <= buf.len) {
            @memcpy(buf[n..][0..sep.len], sep);
            n += sep.len;
        }
        if (n + p.len > buf.len) break;
        @memcpy(buf[n..][0..p.len], p);
        n += p.len;
    }
    return buf[0..n];
}

// ------------------------------------------------------------------ dates

const weekdays = [_][]const u8{ "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday" };
const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

const Date = struct { y: i32, m: u32, d: u32 };

fn parseDate(s: *const [10]u8) Date {
    return .{
        .y = std.fmt.parseInt(i32, s[0..4], 10) catch 1970,
        .m = std.math.clamp(std.fmt.parseInt(u32, s[5..7], 10) catch 1, 1, 12),
        .d = std.fmt.parseInt(u32, s[8..10], 10) catch 1,
    };
}

/// 0 = Monday. Uses Howard Hinnant's days_from_civil.
fn weekday(dt: Date) usize {
    const y = if (dt.m <= 2) dt.y - 1 else dt.y;
    const era = @divFloor(y, 400);
    const yoe: i64 = y - era * 400;
    const mp: i64 = @mod(@as(i64, dt.m) + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + dt.d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    const days = @as(i64, era) * 146097 + doe - 719468; // days since 1970-01-01 (a Thursday)
    return @intCast(@mod(days + 3, 7));
}

test time12 {
    var b: [8]u8 = undefined;
    const cases = .{ .{ "00:05", "12:05", "AM" }, .{ "09:30", "9:30", "AM" }, .{ "12:00", "12:00", "PM" }, .{ "23:59", "11:59", "PM" } };
    inline for (cases) |case| {
        const t = time12(&b, case[0]);
        try std.testing.expectEqualStrings(case[1], t.hm);
        try std.testing.expectEqualStrings(case[2], t.suffix);
    }
    var b16: [16]u8 = undefined;
    try std.testing.expectEqualStrings("     ", timeStr(&b16, "     "));
}

test weekday {
    try std.testing.expectEqual(@as(usize, 1), weekday(.{ .y = 2026, .m = 10, .d = 13 })); // a Tuesday
    try std.testing.expectEqual(@as(usize, 3), weekday(.{ .y = 1970, .m = 1, .d = 1 })); // a Thursday
}
