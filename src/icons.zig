//! Procedurally drawn weather icons, keyed off WMO weather codes.

const cv = @import("canvas.zig");
const Canvas = cv.Canvas;

pub const Kind = enum { sun, moon, partly_day, partly_night, cloud, fog, drizzle, rain, snow, sleet, thunder };

pub fn kindFor(code: i32, is_day: bool) Kind {
    return switch (code) {
        0, 1 => if (is_day) .sun else .moon,
        2 => if (is_day) .partly_day else .partly_night,
        3 => .cloud,
        45, 48 => .fog,
        51, 53, 55 => .drizzle,
        56, 57, 66, 67 => .sleet,
        61, 63, 65, 80, 81, 82 => .rain,
        71, 73, 75, 77, 85, 86 => .snow,
        95, 96, 99 => .thunder,
        else => .cloud,
    };
}

pub fn describe(code: i32) []const u8 {
    return switch (code) {
        0 => "Clear sky",
        1 => "Mainly clear",
        2 => "Partly cloudy",
        3 => "Overcast",
        45 => "Fog",
        48 => "Freezing fog",
        51 => "Light drizzle",
        53 => "Drizzle",
        55 => "Heavy drizzle",
        56, 57 => "Freezing drizzle",
        61 => "Light rain",
        63 => "Rain",
        65 => "Heavy rain",
        66, 67 => "Freezing rain",
        71 => "Light snow",
        73 => "Snow",
        75 => "Heavy snow",
        77 => "Snow grains",
        80 => "Light showers",
        81 => "Showers",
        82 => "Heavy showers",
        85 => "Snow showers",
        86 => "Heavy snow showers",
        95 => "Thunderstorm",
        96, 99 => "Thunderstorm, hail",
        else => "Unknown",
    };
}

/// Icon drawing context: a square box at (x, y) with side `s`. All geometry
/// is expressed in fractions of the box.
const Box = struct {
    x: f32,
    y: f32,
    s: f32,

    fn px(b: Box, fx: f32) f32 {
        return b.x + fx * b.s;
    }
    fn py(b: Box, fy: f32) f32 {
        return b.y + fy * b.s;
    }
    fn d(b: Box, f: f32) f32 {
        return f * b.s;
    }
};

pub fn draw(c: *Canvas, kind: Kind, x: i32, y: i32, size: i32) void {
    const b = Box{ .x = @floatFromInt(x), .y = @floatFromInt(y), .s = @floatFromInt(size) };
    switch (kind) {
        .sun => sun(c, b, 0.5, 0.5, 1.0),
        .moon => moon(c, b, 0.5, 0.5, 1.0),
        .partly_day => {
            sun(c, b, 0.38, 0.36, 0.72);
            cloud(c, b, 0.10, 0.12, 0.85, cv.white);
        },
        .partly_night => {
            moon(c, b, 0.36, 0.34, 0.65);
            cloud(c, b, 0.10, 0.12, 0.85, cv.white);
        },
        .cloud => {
            cloud(c, b, 0.14, -0.10, 0.8, cv.gray);
            cloud(c, b, -0.04, 0.06, 0.95, cv.white);
        },
        .fog => {
            cloud(c, b, 0.0, -0.14, 0.9, cv.white);
            const lines = [_][3]f32{ .{ 0.14, 0.70, 0.74 }, .{ 0.24, 0.84, 0.80 }, .{ 0.18, 0.62, 0.90 } };
            for (lines) |l| c.fill(cv.Capsule{ .ax = b.px(l[0]), .ay = b.py(l[2]), .bx = b.px(l[1]), .by = b.py(l[2]), .r = b.d(0.025) }, cv.black);
        },
        .drizzle => {
            cloud(c, b, 0.0, -0.14, 0.9, cv.white);
            const drops = [_][2]f32{ .{ 0.32, 0.74 }, .{ 0.50, 0.80 }, .{ 0.68, 0.74 }, .{ 0.41, 0.90 }, .{ 0.59, 0.90 } };
            for (drops) |p| c.fill(cv.Circle{ .cx = b.px(p[0]), .cy = b.py(p[1]), .r = b.d(0.028) }, cv.black);
        },
        .rain => {
            cloud(c, b, 0.0, -0.14, 0.9, cv.gray);
            rainLines(c, b);
        },
        .sleet => {
            cloud(c, b, 0.0, -0.14, 0.9, cv.gray);
            const xs = [_]f32{ 0.32, 0.62 };
            for (xs) |fx| c.fill(cv.Capsule{ .ax = b.px(fx + 0.04), .ay = b.py(0.70), .bx = b.px(fx - 0.04), .by = b.py(0.86), .r = b.d(0.022) }, cv.black);
            flake(c, b, 0.47, 0.82, 0.07);
        },
        .snow => {
            cloud(c, b, 0.0, -0.14, 0.9, cv.white);
            flake(c, b, 0.32, 0.76, 0.075);
            flake(c, b, 0.68, 0.76, 0.075);
            flake(c, b, 0.50, 0.88, 0.075);
        },
        .thunder => {
            cloud(c, b, 0.0, -0.16, 0.9, cv.dark_gray);
            const bolt = [_][2]f32{
                .{ b.px(0.52), b.py(0.50) }, .{ b.px(0.38), b.py(0.74) }, .{ b.px(0.49), b.py(0.74) },
                .{ b.px(0.42), b.py(0.96) }, .{ b.px(0.64), b.py(0.66) }, .{ b.px(0.53), b.py(0.66) },
                .{ b.px(0.62), b.py(0.50) },
            };
            c.fill(cv.Polygon{ .pts = &bolt }, cv.black);
        },
    }
}

fn sun(c: *Canvas, b: Box, fx: f32, fy: f32, k: f32) void {
    const cx = b.px(fx);
    const cy = b.py(fy);
    c.fill(cv.Circle{ .cx = cx, .cy = cy, .r = b.d(0.17 * k) }, cv.black);
    const dirs = [_][2]f32{ .{ 1, 0 }, .{ 0.7071, 0.7071 }, .{ 0, 1 }, .{ -0.7071, 0.7071 }, .{ -1, 0 }, .{ -0.7071, -0.7071 }, .{ 0, -1 }, .{ 0.7071, -0.7071 } };
    for (dirs) |dv| {
        c.fill(cv.Capsule{
            .ax = cx + dv[0] * b.d(0.26 * k),
            .ay = cy + dv[1] * b.d(0.26 * k),
            .bx = cx + dv[0] * b.d(0.37 * k),
            .by = cy + dv[1] * b.d(0.37 * k),
            .r = b.d(0.03 * k),
        }, cv.black);
    }
}

fn moon(c: *Canvas, b: Box, fx: f32, fy: f32, k: f32) void {
    c.fill(cv.Crescent{ .cx = b.px(fx), .cy = b.py(fy), .r = b.d(0.30 * k) }, cv.black);
}

/// Cloud = union of three circles and a capsule base. Drawn as a black
/// silhouette, then the same shape shrunk by the outline width in `fill`.
const CloudShape = struct {
    parts: [4]cv.Capsule,

    fn init(b: Box, dx: f32, dy: f32, k: f32, grow: f32) CloudShape {
        const base = [_][5]f32{
            .{ 0.30, 0.60, 0.30, 0.60, 0.15 },
            .{ 0.50, 0.47, 0.50, 0.47, 0.21 },
            .{ 0.71, 0.59, 0.71, 0.59, 0.14 },
            .{ 0.28, 0.66, 0.73, 0.66, 0.10 },
        };
        var s: CloudShape = undefined;
        for (base, 0..) |p, i| {
            // scale around the box centre, then offset
            s.parts[i] = .{
                .ax = b.px(0.5 + (p[0] - 0.5) * k + dx),
                .ay = b.py(0.5 + (p[1] - 0.5) * k + dy),
                .bx = b.px(0.5 + (p[2] - 0.5) * k + dx),
                .by = b.py(0.5 + (p[3] - 0.5) * k + dy),
                .r = b.d(p[4] * k) + grow,
            };
        }
        return s;
    }
    pub fn bbox(s: CloudShape) [4]f32 {
        var r = s.parts[0].bbox();
        for (s.parts[1..]) |p| {
            const q = p.bbox();
            r = .{ @min(r[0], q[0]), @min(r[1], q[1]), @max(r[2], q[2]), @max(r[3], q[3]) };
        }
        return r;
    }
    pub fn inside(s: CloudShape, x: f32, y: f32) bool {
        for (s.parts) |p| if (p.inside(x, y)) return true;
        return false;
    }
};

fn cloud(c: *Canvas, b: Box, dx: f32, dy: f32, k: f32, fill: u8) void {
    const stroke = b.d(0.035);
    c.fill(CloudShape.init(b, dx, dy, k, stroke / 2), cv.black);
    c.fill(CloudShape.init(b, dx, dy, k, -stroke / 2), fill);
}

fn rainLines(c: *Canvas, b: Box) void {
    const xs = [_][2]f32{ .{ 0.30, 0.70 }, .{ 0.48, 0.76 }, .{ 0.66, 0.70 } };
    for (xs) |p| c.fill(cv.Capsule{
        .ax = b.px(p[0] + 0.04),
        .ay = b.py(p[1]),
        .bx = b.px(p[0] - 0.04),
        .by = b.py(p[1] + 0.17),
        .r = b.d(0.024),
    }, cv.black);
}

fn flake(c: *Canvas, b: Box, fx: f32, fy: f32, r: f32) void {
    const dirs = [_][2]f32{ .{ 1, 0 }, .{ 0.5, 0.866 }, .{ -0.5, 0.866 } };
    for (dirs) |dv| c.fill(cv.Capsule{
        .ax = b.px(fx) - dv[0] * b.d(r),
        .ay = b.py(fy) - dv[1] * b.d(r),
        .bx = b.px(fx) + dv[0] * b.d(r),
        .by = b.py(fy) + dv[1] * b.d(r),
        .r = b.d(0.016),
    }, cv.black);
}
