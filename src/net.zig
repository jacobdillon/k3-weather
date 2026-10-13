//! Tiny blocking HTTP/1.0 GET over libc sockets, plain or TLS.
//!
//! Deliberately avoids std.net: the Kindle 3 runs Linux 2.6.26, which
//! rejects SOCK_CLOEXEC in socket(). musl's wrappers fall back gracefully;
//! Zig's raw-syscall path does not. Timeouts use non-blocking I/O + poll()
//! so we never have to pass a time_t-sized struct to the kernel.
//!
//! TLS uses std.crypto.tls.Client on top of our own fd reader/writer, with
//! entropy from /dev/urandom and a CA bundle built from embedded roots (the
//! Kindle's own certificate store is years out of date).

const std = @import("std");
const c = std.c;
const tls = std.crypto.tls;
const Certificate = std.crypto.Certificate;
const Io = std.Io;

const timeout_ms = 20_000;

pub const Error = error{ Resolve, Connect, Timeout, Io, Tls, HttpStatus, BadResponse, TooLarge };

/// The underlying error when `getTls` returns error.Tls (for logging).
pub var last_tls_error: anyerror = error.Unexpected;

/// Fetch `http://host/path` into `buf`; returns the response body.
pub fn get(host: [:0]const u8, path: []const u8, buf: []u8) Error![]u8 {
    const fd = try connectHost(host, "80");
    defer _ = c.close(fd);

    var req_buf: [1024]u8 = undefined;
    const req = try request(&req_buf, host, path);
    try writeAll(fd, req);

    var len: usize = 0;
    while (true) {
        if (len == buf.len) return error.TooLarge;
        try waitFd(fd, c.POLL.IN);
        const n = c.read(fd, buf[len..].ptr, buf.len - len);
        if (n < 0) {
            if (errno() == .AGAIN) continue;
            return error.Io;
        }
        if (n == 0) break;
        len += @intCast(n);
    }
    return body(buf[0..len]);
}

// ------------------------------------------------------------------- TLS

/// Root certificates (PEM) trusted for TLS. Set once before `getTls`.
pub var root_pem: []const u8 = "";

var ca_bundle: Certificate.Bundle = .empty;
var ca_loaded = false;
var ca_lock: Io.RwLock = .init;

// TLS needs buffers big enough for a full record; keep them off the stack.
var tls_read_buf: [tls.Client.min_buffer_len + 8192]u8 = undefined;
var tls_write_buf: [1024]u8 = undefined;
var sock_read_buf: [tls.Client.min_buffer_len]u8 = undefined;
var sock_write_buf: [tls.Client.min_buffer_len]u8 = undefined;

/// Fetch `https://host/path` into `buf`; returns the response body.
pub fn getTls(host: [:0]const u8, path: []const u8, buf: []u8) Error![]u8 {
    const now_ns = realtimeNs();
    if (!ca_loaded) {
        loadRoots(@intCast(@divFloor(now_ns, std.time.ns_per_s))) catch |e| return tlsFail(e);
        ca_loaded = true;
    }

    const fd = try connectHost(host, "443");
    defer _ = c.close(fd);
    var sock_r = FdReader.init(fd, &sock_read_buf);
    var sock_w = FdWriter.init(fd, &sock_write_buf);

    var entropy: [tls.Client.Options.entropy_len]u8 = undefined;
    readUrandom(&entropy) catch |e| return tlsFail(e);

    var client = tls.Client.init(&sock_r.interface, &sock_w.interface, .{
        .host = .{ .explicit = host },
        // The lock is only ever taken shared and uncontended, which is a
        // single atomic op that never calls into `io`.
        .ca = .{ .bundle = .{ .gpa = std.heap.c_allocator, .io = Io.failing, .lock = &ca_lock, .bundle = &ca_bundle } },
        .read_buffer = &tls_read_buf,
        .write_buffer = &tls_write_buf,
        .entropy = &entropy,
        .realtime_now = .{ .nanoseconds = now_ns },
        // Fine for HTTP/1.0 + Connection: close, where EOF ends the body.
        .allow_truncation_attacks = true,
    }) catch |e| return tlsFail(cause(sock_r.err, sock_w.err, e));

    var req_buf: [1024]u8 = undefined;
    const req = try request(&req_buf, host, path);
    client.writer.writeAll(req) catch |e| return tlsFail(cause(null, sock_w.err, e));
    client.writer.flush() catch |e| return tlsFail(cause(null, sock_w.err, e));
    sock_w.interface.flush() catch |e| return tlsFail(cause(null, sock_w.err, e));

    var len: usize = 0;
    while (true) {
        if (len == buf.len) return error.TooLarge;
        const n = client.reader.readSliceShort(buf[len..]) catch |e| return tlsFail(cause(sock_r.err, null, e));
        if (n == 0) break;
        len += n;
    }
    return body(buf[0..len]);
}

/// Prefer the socket-level error (e.g. Timeout) over the generic ReadFailed.
fn cause(r: ?Error, w: ?Error, e: anyerror) anyerror {
    if (r) |x| return x;
    if (w) |x| return x;
    return e;
}

fn tlsFail(e: anyerror) Error {
    last_tls_error = e;
    return switch (e) {
        error.Timeout => error.Timeout,
        else => error.Tls,
    };
}

fn loadRoots(now_sec: i64) !void {
    const gpa = std.heap.c_allocator;
    const begin = "-----BEGIN CERTIFICATE-----";
    const end = "-----END CERTIFICATE-----";
    var it: usize = 0;
    while (std.mem.indexOfPos(u8, root_pem, it, begin)) |b| {
        const start = b + begin.len;
        const stop = std.mem.indexOfPos(u8, root_pem, start, end) orelse return error.BadPem;
        it = stop + end.len;
        // Strip line breaks, then base64-decode into the bundle's byte store.
        var b64: [4096]u8 = undefined;
        var n: usize = 0;
        for (root_pem[start..stop]) |ch| {
            if (ch == '\n' or ch == '\r' or ch == ' ') continue;
            if (n == b64.len) return error.BadPem;
            b64[n] = ch;
            n += 1;
        }
        const dec = std.base64.standard.Decoder;
        const size = try dec.calcSizeForSlice(b64[0..n]);
        const decoded_start: u32 = @intCast(ca_bundle.bytes.items.len);
        try ca_bundle.bytes.ensureUnusedCapacity(gpa, size);
        try dec.decode(ca_bundle.bytes.unusedCapacitySlice()[0..size], b64[0..n]);
        ca_bundle.bytes.items.len += size;
        try ca_bundle.parseCert(gpa, decoded_start, now_sec);
    }
    if (ca_bundle.map.count() == 0) return error.NoRootCertificates;
}

fn realtimeNs() i96 {
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(c.CLOCK.REALTIME, &ts);
    return @as(i96, ts.sec) * std.time.ns_per_s + ts.nsec;
}

fn readUrandom(out: []u8) !void {
    const fd = c.open("/dev/urandom", .{ .ACCMODE = .RDONLY });
    if (fd < 0) return error.NoEntropy;
    defer _ = c.close(fd);
    var n: usize = 0;
    while (n < out.len) {
        const r = c.read(fd, out[n..].ptr, out.len - n);
        if (r <= 0) return error.NoEntropy;
        n += @intCast(r);
    }
}

/// std.Io.Reader over a non-blocking socket, reading into its own buffer.
const FdReader = struct {
    fd: c.fd_t,
    err: ?Error = null,
    interface: Io.Reader,

    fn init(fd: c.fd_t, buffer: []u8) FdReader {
        return .{ .fd = fd, .interface = .{ .vtable = &.{ .stream = stream }, .buffer = buffer, .seek = 0, .end = 0 } };
    }

    fn stream(r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const self: *FdReader = @alignCast(@fieldParentPtr("interface", r));
        const dest = limit.slice(try w.writableSliceGreedy(1));
        waitFd(self.fd, c.POLL.IN) catch |e| {
            self.err = e;
            return error.ReadFailed;
        };
        const n = c.read(self.fd, dest.ptr, dest.len);
        if (n < 0) {
            if (errno() == .AGAIN) return 0;
            self.err = error.Io;
            return error.ReadFailed;
        }
        if (n == 0) return error.EndOfStream;
        w.advance(@intCast(n));
        return @intCast(n);
    }
};

/// std.Io.Writer over a non-blocking socket.
const FdWriter = struct {
    fd: c.fd_t,
    err: ?Error = null,
    interface: Io.Writer,

    fn init(fd: c.fd_t, buffer: []u8) FdWriter {
        return .{ .fd = fd, .interface = .{ .vtable = &.{ .drain = drain }, .buffer = buffer, .end = 0 } };
    }

    fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const self: *FdWriter = @alignCast(@fieldParentPtr("interface", w));
        self.put(w.buffered()) catch return error.WriteFailed;
        w.end = 0;
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |d| {
            self.put(d) catch return error.WriteFailed;
            n += d.len;
        }
        const last = data[data.len - 1];
        for (0..splat) |_| {
            self.put(last) catch return error.WriteFailed;
            n += last.len;
        }
        return n;
    }

    fn put(self: *FdWriter, bytes: []const u8) Error!void {
        writeAll(self.fd, bytes) catch |e| {
            self.err = e;
            return e;
        };
    }
};

// ---------------------------------------------------------------- shared

fn request(buf: []u8, host: []const u8, path: []const u8) Error![]const u8 {
    return std.fmt.bufPrint(buf, "GET {s} HTTP/1.0\r\nHost: {s}\r\nUser-Agent: k3-weather/1.0\r\nAccept: application/json\r\nConnection: close\r\n\r\n", .{ path, host }) catch error.TooLarge;
}

/// Check for "HTTP/1.x 200" and return what follows the headers.
fn body(resp: []u8) Error![]u8 {
    const hdr_end = std.mem.indexOf(u8, resp, "\r\n\r\n") orelse return error.BadResponse;
    if (resp.len < 12 or !std.mem.eql(u8, resp[9..12], "200")) return error.HttpStatus;
    return resp[hdr_end + 4 ..];
}

fn connectHost(host: [:0]const u8, port: [:0]const u8) Error!c.fd_t {
    var hints = std.mem.zeroes(c.addrinfo);
    hints.family = c.AF.INET;
    hints.socktype = c.SOCK.STREAM;
    var res: ?*c.addrinfo = null;
    if (@intFromEnum(c.getaddrinfo(host, port, &hints, &res)) != 0 or res == null) return error.Resolve;
    defer c.freeaddrinfo(res.?);

    var ai: ?*c.addrinfo = res;
    while (ai) |a| : (ai = a.next) {
        if (connectTimeout(a)) |fd| return fd;
    }
    return error.Connect;
}

fn writeAll(fd: c.fd_t, data: []const u8) Error!void {
    var sent: usize = 0;
    while (sent < data.len) {
        try waitFd(fd, c.POLL.OUT);
        const n = c.write(fd, data[sent..].ptr, data.len - sent);
        if (n < 0) {
            if (errno() == .AGAIN) continue;
            return error.Io;
        }
        sent += @intCast(n);
    }
}

fn errno() c.E {
    return @enumFromInt(c._errno().*);
}

fn connectTimeout(a: *c.addrinfo) ?c.fd_t {
    const fd = c.socket(@intCast(a.family), @intCast(a.socktype), @intCast(a.protocol));
    if (fd < 0) return null;
    const fl = c.fcntl(fd, c.F.GETFL);
    _ = c.fcntl(fd, c.F.SETFL, fl | @as(c_int, @bitCast(c.O{ .NONBLOCK = true })));
    if (c.connect(fd, a.addr.?, a.addrlen) == 0) return fd;
    if (errno() == .INPROGRESS) ok: {
        waitFd(fd, c.POLL.OUT) catch break :ok;
        var err: c_int = 0;
        var elen: c.socklen_t = @sizeOf(c_int);
        if (c.getsockopt(fd, c.SOL.SOCKET, c.SO.ERROR, &err, &elen) == 0 and err == 0) return fd;
    }
    _ = c.close(fd);
    return null;
}

fn waitFd(fd: c.fd_t, events: i16) Error!void {
    var pfd = [_]c.pollfd{.{ .fd = fd, .events = events, .revents = 0 }};
    while (true) {
        const r = c.poll(&pfd, 1, timeout_ms);
        if (r > 0) return;
        if (r == 0) return error.Timeout;
        if (errno() != .INTR) return error.Io;
    }
}
