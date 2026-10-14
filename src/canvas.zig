//! 8-bit grayscale drawing surface (0 = black, 255 = white) with
//! anti-aliased shape filling and TrueType text.

const std = @import("std");

pub const W = 600;
pub const H = 800;

pub const black: u8 = 0;
pub const white: u8 = 255;
pub const gray: u8 = 0xA0;
pub const dark_gray: u8 = 0x60;

pub const Canvas = struct {
    px: [W * H]u8 = undefined,

    pub fn clear(c: *Canvas, v: u8) void {
        @memset(&c.px, v);
    }

    /// Blend `color` into pixel (x, y) with coverage `a` (0..255).
    pub inline fn blend(c: *Canvas, x: i32, y: i32, color: u8, a: u32) void {
        if (x < 0 or y < 0 or x >= W or y >= H or a == 0) return;
        const i: usize = @intCast(y * W + x);
        const old: u32 = c.px[i];
        c.px[i] = @intCast((old * (255 - a) + @as(u32, color) * a) / 255);
    }

    pub fn fillRect(c: *Canvas, x: i32, y: i32, w: i32, h: i32, color: u8) void {
        var yy = @max(y, 0);
        while (yy < @min(y + h, H)) : (yy += 1) {
            var xx = @max(x, 0);
            while (xx < @min(x + w, W)) : (xx += 1) c.px[@intCast(yy * W + xx)] = color;
        }
    }

    /// Fill any shape exposing `bbox() [4]f32` and `inside(x, y) bool`,
    /// using 4x4 supersampling for anti-aliasing.
    pub fn fill(c: *Canvas, shape: anytype, color: u8) void {
        const bb = shape.bbox();
        const x0: i32 = @max(0, @as(i32, @intFromFloat(@floor(bb[0]))));
        const y0: i32 = @max(0, @as(i32, @intFromFloat(@floor(bb[1]))));
        const x1: i32 = @min(W, @as(i32, @intFromFloat(@ceil(bb[2]))) + 1);
        const y1: i32 = @min(H, @as(i32, @intFromFloat(@ceil(bb[3]))) + 1);
        var y = y0;
        while (y < y1) : (y += 1) {
            var x = x0;
            while (x < x1) : (x += 1) {
                var n: u32 = 0;
                var sy: u32 = 0;
                while (sy < 4) : (sy += 1) {
                    var sx: u32 = 0;
                    while (sx < 4) : (sx += 1) {
                        const fx = @as(f32, @floatFromInt(x)) + (@as(f32, @floatFromInt(sx)) + 0.5) / 4.0;
                        const fy = @as(f32, @floatFromInt(y)) + (@as(f32, @floatFromInt(sy)) + 0.5) / 4.0;
                        if (shape.inside(fx, fy)) n += 1;
                    }
                }
                if (n > 0) c.blend(x, y, color, n * 255 / 16);
            }
        }
    }

    pub fn hline(c: *Canvas, x0: i32, x1: i32, y: i32, thick: i32, color: u8) void {
        c.fillRect(x0, y, x1 - x0, thick, color);
    }

    pub fn vline(c: *Canvas, x: i32, y0: i32, y1: i32, thick: i32, color: u8) void {
        c.fillRect(x, y0, thick, y1 - y0, color);
    }
};

// ---------------------------------------------------------------- shapes

pub const Circle = struct {
    cx: f32,
    cy: f32,
    r: f32,

    pub fn bbox(s: Circle) [4]f32 {
        return .{ s.cx - s.r, s.cy - s.r, s.cx + s.r, s.cy + s.r };
    }
    pub fn inside(s: Circle, x: f32, y: f32) bool {
        const dx = x - s.cx;
        const dy = y - s.cy;
        return dx * dx + dy * dy <= s.r * s.r;
    }
};

/// A line segment with round caps and radius `r` (half the stroke width).
pub const Capsule = struct {
    ax: f32,
    ay: f32,
    bx: f32,
    by: f32,
    r: f32,

    pub fn bbox(s: Capsule) [4]f32 {
        return .{ @min(s.ax, s.bx) - s.r, @min(s.ay, s.by) - s.r, @max(s.ax, s.bx) + s.r, @max(s.ay, s.by) + s.r };
    }
    pub fn inside(s: Capsule, x: f32, y: f32) bool {
        const px = x - s.ax;
        const py = y - s.ay;
        const dx = s.bx - s.ax;
        const dy = s.by - s.ay;
        const len2 = dx * dx + dy * dy;
        const t = if (len2 == 0) 0 else std.math.clamp((px * dx + py * dy) / len2, 0, 1);
        const ex = px - dx * t;
        const ey = py - dy * t;
        return ex * ex + ey * ey <= s.r * s.r;
    }
};

/// A ring (circle outline) of the given stroke width.
pub const Ring = struct {
    cx: f32,
    cy: f32,
    r: f32,
    w: f32,

    pub fn bbox(s: Ring) [4]f32 {
        return .{ s.cx - s.r - s.w, s.cy - s.r - s.w, s.cx + s.r + s.w, s.cy + s.r + s.w };
    }
    pub fn inside(s: Ring, x: f32, y: f32) bool {
        const d = @sqrt((x - s.cx) * (x - s.cx) + (y - s.cy) * (y - s.cy));
        return @abs(d - s.r) <= s.w / 2;
    }
};

/// Simple (even-odd) polygon.
pub const Polygon = struct {
    pts: []const [2]f32,

    pub fn bbox(s: Polygon) [4]f32 {
        var b = [4]f32{ s.pts[0][0], s.pts[0][1], s.pts[0][0], s.pts[0][1] };
        for (s.pts) |p| {
            b[0] = @min(b[0], p[0]);
            b[1] = @min(b[1], p[1]);
            b[2] = @max(b[2], p[0]);
            b[3] = @max(b[3], p[1]);
        }
        return b;
    }
    pub fn inside(s: Polygon, x: f32, y: f32) bool {
        var in = false;
        var j = s.pts.len - 1;
        for (s.pts, 0..) |pi, i| {
            const pj = s.pts[j];
            if ((pi[1] > y) != (pj[1] > y) and
                x < (pj[0] - pi[0]) * (y - pi[1]) / (pj[1] - pi[1]) + pi[0]) in = !in;
            j = i;
        }
        return in;
    }
};

/// Crescent moon: a disc with an offset disc cut out of it.
pub const Crescent = struct {
    cx: f32,
    cy: f32,
    r: f32,

    pub fn bbox(s: Crescent) [4]f32 {
        return (Circle{ .cx = s.cx, .cy = s.cy, .r = s.r }).bbox();
    }
    pub fn inside(s: Crescent, x: f32, y: f32) bool {
        const outer = Circle{ .cx = s.cx, .cy = s.cy, .r = s.r };
        const cut = Circle{ .cx = s.cx + s.r * 0.45, .cy = s.cy - s.r * 0.30, .r = s.r * 0.80 };
        return outer.inside(x, y) and !cut.inside(x, y);
    }
};

// ------------------------------------------------------------------ text

extern fn ttf_init(idx: c_int, data: [*]const u8) c_int;
extern fn ttf_scale(idx: c_int, px: f32) f32;
extern fn ttf_vmetrics(idx: c_int, ascent: *c_int, descent: *c_int, line_gap: *c_int) void;
extern fn ttf_hmetrics(idx: c_int, cp: c_int, advance: *c_int, lsb: *c_int) void;
extern fn ttf_kern(idx: c_int, a: c_int, b: c_int) c_int;
extern fn ttf_box(idx: c_int, cp: c_int, scale: f32, x0: *c_int, y0: *c_int, x1: *c_int, y1: *c_int) void;
extern fn ttf_render(idx: c_int, out: [*]u8, w: c_int, h: c_int, stride: c_int, scale: f32, cp: c_int) void;

pub const Font = enum(c_int) { regular = 0, bold = 1 };

const regular_ttf = @embedFile("DejaVuSans.ttf");
const bold_ttf = @embedFile("DejaVuSans-Bold.ttf");

pub fn initFonts() !void {
    if (ttf_init(0, regular_ttf.ptr) == 0) return error.FontInit;
    if (ttf_init(1, bold_ttf.ptr) == 0) return error.FontInit;
}

/// Minimal UTF-8 iterator; invalid bytes come out as '?'.
const Utf8 = struct {
    s: []const u8,
    i: usize = 0,

    fn next(u: *Utf8) ?u21 {
        if (u.i >= u.s.len) return null;
        const len = std.unicode.utf8ByteSequenceLength(u.s[u.i]) catch {
            u.i += 1;
            return '?';
        };
        if (u.i + len > u.s.len) {
            u.i = u.s.len;
            return '?';
        }
        defer u.i += len;
        const b = u.s[u.i..];
        return switch (len) {
            2 => std.unicode.utf8Decode2(b[0..2].*) catch '?',
            3 => std.unicode.utf8Decode3(b[0..3].*) catch '?',
            4 => std.unicode.utf8Decode4(b[0..4].*) catch '?',
            else => b[0],
        };
    }
};

pub fn textWidth(font: Font, size: f32, s: []const u8) i32 {
    const f = @backingInt(font);
    const scale = ttf_scale(f, size);
    var w: f32 = 0;
    var it = Utf8{ .s = s };
    var prev: ?u21 = null;
    while (it.next()) |cp| {
        if (prev) |p| w += @as(f32, @floatFromInt(ttf_kern(f, p, cp))) * scale;
        var adv: c_int = 0;
        var lsb: c_int = 0;
        ttf_hmetrics(f, cp, &adv, &lsb);
        w += @as(f32, @floatFromInt(adv)) * scale;
        prev = cp;
    }
    return @intFromFloat(@round(w));
}

pub const Align = enum { left, center, right };

/// Draw `s` with its baseline at `y`. `x` is the left edge, center or right
/// edge depending on `al`.
pub fn text(c: *Canvas, font: Font, size: f32, x: i32, y: i32, al: Align, color: u8, s: []const u8) void {
    const f = @backingInt(font);
    const scale = ttf_scale(f, size);
    const w = textWidth(font, size, s);
    var pen: f32 = @floatFromInt(switch (al) {
        .left => x,
        .center => x - @divTrunc(w, 2),
        .right => x - w,
    });
    var glyph: [200 * 200]u8 = undefined;
    var it = Utf8{ .s = s };
    var prev: ?u21 = null;
    while (it.next()) |cp| {
        if (prev) |p| pen += @as(f32, @floatFromInt(ttf_kern(f, p, cp))) * scale;
        var x0: c_int = 0;
        var y0: c_int = 0;
        var x1: c_int = 0;
        var y1: c_int = 0;
        ttf_box(f, cp, scale, &x0, &y0, &x1, &y1);
        const gw = x1 - x0;
        const gh = y1 - y0;
        if (gw > 0 and gh > 0 and gw * gh <= glyph.len) {
            ttf_render(f, &glyph, gw, gh, gw, scale, cp);
            const ox: i32 = @as(i32, @intFromFloat(@round(pen))) + x0;
            const oy: i32 = y + y0;
            var gy: i32 = 0;
            while (gy < gh) : (gy += 1) {
                var gx: i32 = 0;
                while (gx < gw) : (gx += 1) {
                    c.blend(ox + gx, oy + gy, color, glyph[@intCast(gy * gw + gx)]);
                }
            }
        }
        var adv: c_int = 0;
        var lsb: c_int = 0;
        ttf_hmetrics(f, cp, &adv, &lsb);
        pen += @as(f32, @floatFromInt(adv)) * scale;
        prev = cp;
    }
}

/// Largest size <= `size` at which `s` fits in `max_w` pixels.
pub fn fitSize(font: Font, size: f32, max_w: i32, s: []const u8) f32 {
    var sz = size;
    while (sz > 10 and textWidth(font, sz, s) > max_w) sz -= 1;
    return sz;
}
