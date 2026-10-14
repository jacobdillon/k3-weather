//! The forecast model and the Open-Meteo fetch, blending several weather
//! models into one forecast.

const std = @import("std");
const net = @import("net.zig");
const sys = @import("sys.zig");

pub const Units = enum { metric, imperial };

pub const Day = struct {
    date: [10]u8 = @splat('0'), // YYYY-MM-DD
    code: i32 = 0,
    hi: f64 = 0,
    lo: f64 = 0,
    pop: ?f64 = null, // precipitation probability %
    precip: ?f64 = null,
    wind: ?f64 = null,
    sunrise: [5]u8 = @splat(' '), // HH:MM
    sunset: [5]u8 = @splat(' '),
};

pub const Weather = struct {
    temp: f64 = 0,
    feels: ?f64 = null,
    humidity: ?f64 = null,
    wind: ?f64 = null,
    code: i32 = 0,
    is_day: bool = true,
    as_of: [5]u8 = @splat(' '), // HH:MM local, time of the last update
    utc_offset: ?i64 = null, // seconds, from Open-Meteo
    days: [3]Day = @splat(.{}),

    /// Set `as_of` to the current local time (the time of this update).
    pub fn stampNow(w: *Weather) void {
        if (w.utc_offset) |off| w.as_of = sys.localHHMM(off);
    }
};

// ------------------------------------------------------------------ blend
//
// Every value is a blend of several models fetched in one request. Open-Meteo
// has no server-side cross-model average (best_match picks one model per
// location), so we combine them here:
//   - numbers: mean over the models that returned a value
//   - weather codes: plurality vote; with no majority, the first model wins
//   - "now": the per-model values for the current 15-minute slot
//     (minutely_15), since the `current` block reflects only one model
// With models=a,b,c every key gets a "_<model>" suffix. Plain keys (a
// single-model response, e.g. an old --json file) are used as a fallback.

/// gfs_seamless includes NOAA's HRRR for the US. First = tie-breaker.
const models = [_][]const u8{ "gfs_seamless", "ecmwf_ifs025", "icon_seamless" };
const models_param = blk: {
    var s: []const u8 = models[0];
    for (models[1..]) |m| s = s ++ "," ++ m;
    break :blk s;
};

const JsonObj = std.json.ObjectMap;

fn jsonNum(v: std.json.Value) ?f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => null,
    };
}

/// obj[key][i] (or obj[key] when `i` is null) as a number.
fn numAt(obj: JsonObj, key: []const u8, i: ?usize) ?f64 {
    const v = obj.get(key) orelse return null;
    const idx = i orelse return jsonNum(v);
    if (v != .array or idx >= v.array.items.len) return null;
    return jsonNum(v.array.items[idx]);
}

/// Each model's value for `base`, in `models` order.
fn modelValues(obj: JsonObj, base: []const u8, i: ?usize, out: *[models.len]f64) []f64 {
    var n: usize = 0;
    var kb: [96]u8 = undefined;
    for (models) |m| {
        const key = std.mem.print(&kb, "{s}_{s}", .{ base, m }) catch continue;
        if (numAt(obj, key, i)) |v| {
            out[n] = v;
            n += 1;
        }
    }
    if (n == 0) if (numAt(obj, base, i)) |v| {
        out[0] = v;
        n = 1;
    };
    return out[0..n];
}

fn blendMean(obj: JsonObj, base: []const u8, i: ?usize) ?f64 {
    var buf: [models.len]f64 = undefined;
    const vs = modelValues(obj, base, i, &buf);
    if (vs.len == 0) return null;
    var sum: f64 = 0;
    for (vs) |v| sum += v;
    return sum / @as(f64, @floatFromInt(vs.len));
}

fn blendCode(obj: JsonObj, base: []const u8, i: ?usize) ?i32 {
    var buf: [models.len]f64 = undefined;
    const vs = modelValues(obj, base, i, &buf);
    if (vs.len == 0) return null;
    var best = vs[0];
    var best_n: usize = 0;
    for (vs) |a| {
        var n: usize = 0;
        for (vs) |b| n += @intFromBool(a == b);
        if (n > best_n) { // strict: ties keep the earlier model
            best = a;
            best_n = n;
        }
    }
    return @intFromFloat(best);
}

/// obj["<base>_<model>"][i] for the first model that has it, else obj[base][i].
fn blendStr(obj: JsonObj, base: []const u8, i: usize) ?[]const u8 {
    var kb: [96]u8 = undefined;
    for (models) |m| {
        const key = std.mem.print(&kb, "{s}_{s}", .{ base, m }) catch continue;
        if (strAt(obj, key, i)) |s| return s;
    }
    return strAt(obj, base, i);
}

fn strAt(obj: JsonObj, key: []const u8, i: usize) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    if (v != .array or i >= v.array.items.len) return null;
    return switch (v.array.items[i]) {
        .string => |s| s,
        else => null,
    };
}

fn objField(root: std.json.Value, key: []const u8) ?JsonObj {
    if (root != .object) return null;
    const v = root.object.get(key) orelse return null;
    return if (v == .object) v.object else null;
}

fn copyTail(dst: []u8, src: []const u8) void {
    // ISO "YYYY-MM-DDTHH:MM" -> "HH:MM"
    if (src.len >= dst.len) @memcpy(dst, src[src.len - dst.len ..]);
}

pub fn parse(json: []const u8) !Weather {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), json, .{});

    const current = objField(root, "current") orelse return error.BadResponse;
    const daily = objField(root, "daily") orelse return error.BadResponse;
    // Per-model "now" values; older single-model responses only have `current`.
    const now_obj, const now_i: ?usize = if (objField(root, "minutely_15")) |m| .{ m, 0 } else .{ current, null };

    var w = Weather{
        .temp = blendMean(now_obj, "temperature_2m", now_i) orelse return error.BadResponse,
        .feels = blendMean(now_obj, "apparent_temperature", now_i),
        .humidity = blendMean(now_obj, "relative_humidity_2m", now_i),
        .wind = blendMean(now_obj, "wind_speed_10m", now_i),
        .code = blendCode(now_obj, "weather_code", now_i) orelse 0,
        .is_day = (numAt(current, "is_day", null) orelse 1) != 0,
    };
    if (current.get("time")) |t| if (t == .string) copyTail(&w.as_of, t.string);
    if (root.object.get("utc_offset_seconds")) |v| if (jsonNum(v)) |o| {
        w.utc_offset = @intFromFloat(o);
    };

    for (&w.days, 0..) |*day, i| {
        const date = strAt(daily, "time", i) orelse return error.NotEnoughDays;
        if (date.len >= 10) @memcpy(&day.date, date[0..10]);
        day.code = blendCode(daily, "weather_code", i) orelse 0;
        day.hi = blendMean(daily, "temperature_2m_max", i) orelse 0;
        day.lo = blendMean(daily, "temperature_2m_min", i) orelse 0;
        day.pop = blendMean(daily, "precipitation_probability_max", i);
        day.precip = blendMean(daily, "precipitation_sum", i);
        day.wind = blendMean(daily, "wind_speed_10m_max", i);
        if (blendStr(daily, "sunrise", i)) |s| copyTail(&day.sunrise, s);
        if (blendStr(daily, "sunset", i)) |s| copyTail(&day.sunset, s);
    }
    return w;
}

pub fn fetch(lat: []const u8, lon: []const u8, units: Units, buf: []u8) !Weather {
    var path_buf: [640]u8 = undefined;
    const path = try std.mem.print(&path_buf, "/v1/forecast?latitude={s}&longitude={s}" ++
        "&current=is_day" ++
        "&minutely_15=temperature_2m,apparent_temperature,relative_humidity_2m,wind_speed_10m,weather_code&forecast_minutely_15=1" ++
        "&daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,precipitation_sum,wind_speed_10m_max,sunrise,sunset" ++
        "&forecast_days=3&timezone=auto&models=" ++ models_param ++ "{s}", .{
        lat, lon,
        switch (units) {
            .metric => "",
            .imperial => "&temperature_unit=fahrenheit&wind_speed_unit=mph&precipitation_unit=inch",
        },
    });
    return parse(try net.get("api.open-meteo.com", path, buf));
}
