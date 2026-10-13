//! Output backends: the Kindle e-ink framebuffer, and a PNG file for
//! previewing on a desktop.

const std = @import("std");
const c = std.c;
const cv = @import("canvas.zig");

// <linux/fb.h>
const FBIOGET_VSCREENINFO = 0x4600;
const FBIOGET_FSCREENINFO = 0x4602;
// Kindle 2/3/DX <linux/einkfb.h>
const FBIO_EINK_UPDATE_DISPLAY = 0x46db;
const fx_update_full = 1;

const FbBitfield = extern struct { offset: u32, length: u32, msb_right: u32 };

const FbVarScreeninfo = extern struct {
    xres: u32,
    yres: u32,
    xres_virtual: u32,
    yres_virtual: u32,
    xoffset: u32,
    yoffset: u32,
    bits_per_pixel: u32,
    grayscale: u32,
    red: FbBitfield,
    green: FbBitfield,
    blue: FbBitfield,
    transp: FbBitfield,
    nonstd: u32,
    activate: u32,
    height: u32,
    width: u32,
    accel_flags: u32,
    pixclock: u32,
    left_margin: u32,
    right_margin: u32,
    upper_margin: u32,
    lower_margin: u32,
    hsync_len: u32,
    vsync_len: u32,
    sync: u32,
    vmode: u32,
    rotate: u32,
    colorspace: u32,
    reserved: [4]u32,
};

const FbFixScreeninfo = extern struct {
    id: [16]u8,
    smem_start: c_ulong,
    smem_len: u32,
    type: u32,
    type_aux: u32,
    visual: u32,
    xpanstep: u16,
    ypanstep: u16,
    ywrapstep: u16,
    line_length: u32,
    mmio_start: c_ulong,
    mmio_len: u32,
    accel: u32,
    capabilities: u16,
    reserved: [2]u16,
};

pub const Framebuffer = struct {
    fd: c.fd_t,
    mem: [*]u8,
    len: usize,
    xres: u32,
    yres: u32,
    bpp: u32,
    stride: u32,
    /// Legacy einkfb devices (K2/K3/DX) store 0 as white.
    invert: bool,

    /// `path` "none" gives a headless sink (for testing the main loop).
    pub fn open(path: [:0]const u8, invert: ?bool) !Framebuffer {
        if (std.mem.eql(u8, path, "none"))
            return .{ .fd = -1, .mem = undefined, .len = 0, .xres = 0, .yres = 0, .bpp = 8, .stride = 0, .invert = false };
        const fd = c.open(path, .{ .ACCMODE = .RDWR });
        if (fd < 0) return error.FbOpen;
        errdefer _ = c.close(fd);
        var vinfo: FbVarScreeninfo = undefined;
        var finfo: FbFixScreeninfo = undefined;
        if (c.ioctl(fd, FBIOGET_VSCREENINFO, &vinfo) != 0) return error.FbIoctl;
        if (c.ioctl(fd, FBIOGET_FSCREENINFO, &finfo) != 0) return error.FbIoctl;
        if (vinfo.bits_per_pixel != 4 and vinfo.bits_per_pixel != 8) return error.FbUnsupportedDepth;
        const p = c.mmap(null, finfo.smem_len, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0);
        if (p == c.MAP_FAILED) return error.FbMmap;
        return .{
            .fd = fd,
            .mem = @ptrCast(p),
            .len = finfo.smem_len,
            .xres = vinfo.xres,
            .yres = vinfo.yres,
            .bpp = vinfo.bits_per_pixel,
            .stride = finfo.line_length,
            .invert = invert orelse (vinfo.bits_per_pixel == 4),
        };
    }

    /// Canvas pixel for framebuffer coordinate (x, y). Handles a landscape
    /// framebuffer by rotating the portrait canvas.
    fn sample(fb: *const Framebuffer, canvas: *const cv.Canvas, x: u32, y: u32) u8 {
        if (x >= fb.xres or y >= fb.yres) return cv.white;
        const rotated = fb.xres > fb.yres;
        const cx = if (rotated) y else x;
        const cy = if (rotated) fb.xres - 1 - x else y;
        if (cx >= cv.W or cy >= cv.H) return cv.white;
        const v = canvas.px[cy * cv.W + cx];
        return if (fb.invert) 255 - v else v;
    }

    pub fn show(fb: *Framebuffer, canvas: *const cv.Canvas) void {
        if (fb.fd < 0) return;
        var y: u32 = 0;
        while (y < fb.yres) : (y += 1) {
            const row = fb.mem + y * fb.stride;
            if ((y + 1) * fb.stride > fb.len) break;
            if (fb.bpp == 8) {
                var x: u32 = 0;
                while (x < fb.xres) : (x += 1) row[x] = fb.sample(canvas, x, y);
            } else {
                var x: u32 = 0;
                while (x < fb.xres) : (x += 2) {
                    const hi = fb.sample(canvas, x, y) >> 4;
                    const lo = fb.sample(canvas, x + 1, y) >> 4;
                    row[x / 2] = (hi << 4) | lo;
                }
            }
        }
        fb.refresh();
    }

    /// Full (flashing) e-ink refresh, which also clears ghosting.
    fn refresh(fb: *Framebuffer) void {
        if (c.ioctl(fb.fd, FBIO_EINK_UPDATE_DISPLAY, @as(c_ulong, fx_update_full)) == 0) return;
        // Fallback understood by the K2/K3 einkfb driver.
        const pfd = c.open("/proc/eink_fb/update_display", .{ .ACCMODE = .WRONLY });
        if (pfd >= 0) {
            _ = c.write(pfd, "1", 1);
            _ = c.close(pfd);
        }
    }
};

/// Write the canvas as an 8-bit grayscale PNG using uncompressed deflate.
pub fn writePng(path: [:0]const u8, canvas: *const cv.Canvas) !void {
    const fd = c.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(c.mode_t, 0o644));
    if (fd < 0) return error.PngOpen;
    defer _ = c.close(fd);

    // zlib stream: header, one stored block per row (filter byte + pixels), adler32
    const row_len = cv.W + 1;
    const block_len = 5 + row_len;
    const zlen = 2 + cv.H * block_len + 4;
    const z = try std.heap.c_allocator.alloc(u8, zlen);
    defer std.heap.c_allocator.free(z);
    z[0] = 0x78;
    z[1] = 0x01;
    var a: u32 = 1;
    var b: u32 = 0;
    var o: usize = 2;
    for (0..cv.H) |y| {
        z[o] = if (y == cv.H - 1) 1 else 0;
        std.mem.writeInt(u16, z[o + 1 ..][0..2], row_len, .little);
        std.mem.writeInt(u16, z[o + 3 ..][0..2], ~@as(u16, row_len), .little);
        o += 5;
        z[o] = 0;
        @memcpy(z[o + 1 ..][0..cv.W], canvas.px[y * cv.W ..][0..cv.W]);
        for (z[o .. o + row_len]) |byte| {
            a = (a + byte) % 65521;
            b = (b + a) % 65521;
        }
        o += row_len;
    }
    std.mem.writeInt(u32, z[o..][0..4], (b << 16) | a, .big);

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], cv.W, .big);
    std.mem.writeInt(u32, ihdr[4..8], cv.H, .big);
    ihdr[8] = 8; // bit depth
    ihdr[9] = 0; // grayscale
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;

    writeAll(fd, "\x89PNG\r\n\x1a\n");
    chunk(fd, "IHDR", &ihdr);
    chunk(fd, "IDAT", z);
    chunk(fd, "IEND", "");
}

fn chunk(fd: c.fd_t, kind: *const [4]u8, data: []const u8) void {
    var hdr: [8]u8 = undefined;
    std.mem.writeInt(u32, hdr[0..4], @intCast(data.len), .big);
    @memcpy(hdr[4..8], kind);
    var crc = std.hash.Crc32.init();
    crc.update(kind);
    crc.update(data);
    var tail: [4]u8 = undefined;
    std.mem.writeInt(u32, &tail, crc.final(), .big);
    writeAll(fd, &hdr);
    writeAll(fd, data);
    writeAll(fd, &tail);
}

fn writeAll(fd: c.fd_t, data: []const u8) void {
    var off: usize = 0;
    while (off < data.len) {
        const n = c.write(fd, data[off..].ptr, data.len - off);
        if (n <= 0) return;
        off += @intCast(n);
    }
}
