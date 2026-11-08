//! rt.zig - the C runtime of the Zig port of EPA SWMM 5.2.4 (imported by the generated engine as R).
//!
//! It reproduces the glibc 2.39 / x86-64 behaviour SWMM's output depends on, in Zig:
//!   * printf/snprintf formatting with glibc's exact decimal rounding (an exact big-integer expansion of the
//!     binary value, rounded half to even, as glibc does in its default rounding mode);
//!   * strtod/atof/atoi/sscanf with glibc's syntax (decimal, hexadecimal, inf, nan(...)), correctly rounded
//!     (the digits go to Zig's std.fmt.parseFloat, an Eisel-Lemire parser with an exact fallback);
//!   * stdio files over positioned reads and writes (C's position, end-of-file flag and buffering);
//!   * strings, memory (zero-filled blocks with a size header, from Zig's own allocator), time;
//!   * x86-64 integer conversions: (int)x of a double is cvttsd2si (NaN or out of range -> INT_MIN);
//!   * libm: exp, log, log10, pow, sin, cos, tan, asin, acos and atan are the system libm's (glibc), which
//!     EPA itself calls; the build passes -fno-builtin so LLVM keeps every call (no pow(x,2) -> x*x,
//!     no pow(2,x) -> exp2(x), no constant folding with the compiler's own library).
//! Only the C library's low-level I/O (open, pread, pwrite, write, close, unlink, getcwd) is called from
//! libc. Written by Claude (Anthropic) for Robert Dickinson; see zig/README.md.
const std = @import("std");

// ================================================================ libm (glibc, as EPA calls it)
pub extern "m" fn exp(x: f64) f64;
pub extern "m" fn log(x: f64) f64;
pub extern "m" fn log10(x: f64) f64;
pub extern "m" fn pow(x: f64, y: f64) f64;
pub extern "m" fn sin(x: f64) f64;
pub extern "m" fn cos(x: f64) f64;
pub extern "m" fn tan(x: f64) f64;
pub extern "m" fn asin(x: f64) f64;
pub extern "m" fn acos(x: f64) f64;
pub extern "m" fn atan(x: f64) f64;

// ================================================================ low-level I/O from libc
extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn pread(fd: c_int, buf: [*]u8, n: usize, off: i64) isize;
extern "c" fn pwrite(fd: c_int, buf: [*]const u8, n: usize, off: i64) isize;
extern "c" fn write(fd: c_int, buf: [*]const u8, n: usize) isize;
extern "c" fn lseek(fd: c_int, off: i64, whence: c_int) i64;
extern "c" fn unlink(path: [*:0]const u8) c_int;
extern "c" fn getcwd(buf: [*]u8, size: usize) ?[*]u8;
extern "c" fn getpid() c_int;
const c_time = @extern(*const fn (?*i64) callconv(.c) i64, .{ .name = "time", .library_name = "c" });

const O_RDONLY: c_int = 0;
const O_WRONLY: c_int = 1;
const O_RDWR: c_int = 2;
const O_CREAT: c_int = 0o100;
const O_EXCL: c_int = 0o200;
const O_TRUNC: c_int = 0o1000;
const O_APPEND: c_int = 0o2000;

pub const nan64: f64 = @bitCast(@as(u64, 0x7ff8000000000000)); // C's NAN
pub const inf64: f64 = std.math.inf(f64);
pub const nan32: f32 = @bitCast(@as(u32, 0x7fc00000));
pub const inf32: f32 = std.math.inf(f32);

// ================================================================ integer and pointer helpers

/// a C index (any integer type) as a Zig index; a negative signed index is sign-extended, as C does
pub inline fn ix(i: anytype) usize {
    const T = @TypeOf(i);
    const ti = @typeInfo(T).int;
    if (ti.signedness == .signed) return @bitCast(@as(isize, i));
    return i;
}

/// (T)x for a double or float x, as x86-64 converts (cvttsd2si: NaN or out of range gives the minimum)
pub inline fn d2i(comptime T: type, x: anytype) T {
    const d: f64 = x;
    switch (T) {
        i32 => {
            if (!(d > -2147483649.0 and d < 2147483648.0)) return std.math.minInt(i32);
            return @intFromFloat(d);
        },
        i64 => {
            if (!(d > -9223372036854775809.0 and d < 9223372036854775808.0)) return std.math.minInt(i64);
            return @intFromFloat(d);
        },
        u32 => return @truncate(@as(u64, @bitCast(d2i(i64, d)))),
        u64 => {
            if (d < 9223372036854775808.0) return @bitCast(d2i(i64, d));
            return @as(u64, @bitCast(d2i(i64, d - 9223372036854775808.0))) ^ 0x8000000000000000;
        },
        i16, i8 => return @truncate(d2i(i32, d)),
        u16, u8 => return @truncate(@as(u32, @bitCast(d2i(i32, d)))),
        else => @compileError("d2i"),
    }
}

fn Unsigned(comptime T: type) type {
    return std.meta.Int(.unsigned, @bitSizeOf(T));
}

inline fn shiftCount(comptime T: type, b: anytype) std.math.Log2Int(T) {
    if (@TypeOf(b) == comptime_int) return @intCast(b & (@bitSizeOf(T) - 1));
    return @truncate(@as(Unsigned(@TypeOf(b)), @bitCast(b)));
}

/// a << b with x86's count masking (C leaves an out-of-range count undefined)
pub inline fn shl(a: anytype, b: anytype) @TypeOf(a) {
    const T = @TypeOf(a);
    const U = Unsigned(T);
    const n = shiftCount(T, b);
    return @bitCast(@as(U, @bitCast(a)) << n);
}

/// a >> b: arithmetic for signed a, logical for unsigned, as gcc on x86-64
pub inline fn shr(a: anytype, b: anytype) @TypeOf(a) {
    return a >> shiftCount(@TypeOf(a), b);
}

fn Elem(comptime P: type) type {
    return @typeInfo(P).pointer.child;
}

/// p + n for a C pointer and any integer n
pub inline fn padd(p: anytype, n: anytype) @TypeOf(p) {
    const P = @TypeOf(p);
    const sz = @sizeOf(Elem(P));
    const off: usize = if (@typeInfo(@TypeOf(n)).int.signedness == .signed) @bitCast(@as(isize, n)) else n;
    return @ptrFromInt(@intFromPtr(p) +% off *% sz);
}

pub inline fn psub(p: anytype, n: anytype) @TypeOf(p) {
    const P = @TypeOf(p);
    const sz = @sizeOf(Elem(P));
    const off: usize = if (@typeInfo(@TypeOf(n)).int.signedness == .signed) @bitCast(@as(isize, n)) else n;
    return @ptrFromInt(@intFromPtr(p) -% off *% sz);
}

/// p - q (in elements)
pub inline fn pdiff(p: anytype, q: anytype) i64 {
    const sz: i64 = @sizeOf(Elem(@TypeOf(p)));
    const d: i64 = @bitCast(@intFromPtr(p) -% @intFromPtr(q));
    return @divExact(d, sz);
}

/// a string literal: a pointer to a static, NUL-terminated copy (one per distinct text)
pub fn s(comptime str: []const u8) [*c]i8 {
    const S = struct {
        var buf: [str.len + 1]i8 = blk: {
            var b: [str.len + 1]i8 = undefined;
            for (str, 0..) |ch, i| b[i] = @bitCast(ch);
            b[str.len] = 0;
            break :blk b;
        };
    };
    return &S.buf;
}

/// char x[n] = "..." : the bytes, then zeros
pub fn arr(comptime n: usize, comptime str: []const u8) [n]i8 {
    var b: [n]i8 = [_]i8{0} ** n;
    for (str, 0..) |ch, i| {
        if (i < n) b[i] = @bitCast(ch);
    }
    return b;
}

// ================================================================ memory
// Every block is zero-filled (EPA reads nothing it has not written, except the matrix of lessons/02
// defect 5, which this makes zero) and carries its size in a 16-byte header for free and realloc.
const gpa = std.heap.smp_allocator;

fn rawAlloc(n0: u64) ?*anyopaque {
    const n = if (n0 == 0) 1 else n0; // calloc(0) still gives a unique block, as glibc's does
    const words: usize = @intCast((n + 15) / 16 + 1);
    const mem = gpa.alloc(u128, words) catch return null;
    @memset(mem, 0);
    mem[0] = words;
    return @ptrCast(&mem[1]);
}

fn header(p: *anyopaque) []u128 {
    const h: [*]u128 = @ptrFromInt(@intFromPtr(p) - 16);
    const words: usize = @intCast(h[0]);
    return h[0..words];
}

pub fn malloc(n: u64) ?*anyopaque {
    return rawAlloc(n);
}

pub fn calloc(n: u64, size: u64) ?*anyopaque {
    return rawAlloc(n *% size);
}

pub fn free(p: ?*anyopaque) void {
    if (p) |q| gpa.free(header(q));
}

pub fn realloc(p: ?*anyopaque, n: u64) ?*anyopaque {
    const q = rawAlloc(n) orelse return null;
    if (p) |old| {
        const h = header(old);
        const have: usize = (h.len - 1) * 16;
        const m: usize = @min(have, @as(usize, @intCast(n)));
        const dst: [*]u8 = @ptrCast(q);
        const src: [*]const u8 = @ptrCast(old);
        @memcpy(dst[0..m], src[0..m]);
        gpa.free(h);
    }
    return q;
}

pub fn memset(p: ?*anyopaque, c: i32, n: u64) ?*anyopaque {
    const b: [*]u8 = @ptrCast(p.?);
    @memset(b[0..@intCast(n)], @as(u8, @truncate(@as(u32, @bitCast(c)))));
    return p;
}

// ================================================================ strings
pub fn strlen(p: [*c]i8) u64 {
    var n: usize = 0;
    while (p[n] != 0) n += 1;
    return n;
}

fn slen(p: [*c]const i8) usize {
    var n: usize = 0;
    while (p[n] != 0) n += 1;
    return n;
}

fn bytes(p: [*c]i8) []u8 {
    const b: [*]u8 = @ptrCast(p);
    return b[0..slen(p)];
}

pub fn strcpy(d: [*c]i8, src: [*c]i8) [*c]i8 {
    const n = slen(src) + 1;
    // C's strcpy may not overlap; copy forwards as glibc's would for the cases SWMM has
    var i: usize = 0;
    while (i < n) : (i += 1) d[i] = src[i];
    return d;
}

pub fn strcat(d: [*c]i8, src: [*c]i8) [*c]i8 {
    _ = strcpy(d + slen(d), src);
    return d;
}

pub fn strcmp(a: [*c]i8, b: [*c]i8) i32 {
    var i: usize = 0;
    while (true) : (i += 1) {
        const x: i32 = @as(u8, @bitCast(a[i]));
        const y: i32 = @as(u8, @bitCast(b[i]));
        if (x != y) return x - y;
        if (x == 0) return 0;
    }
}

pub fn strchr(p: [*c]i8, c: i32) [*c]i8 {
    const ch: i8 = @bitCast(@as(u8, @truncate(@as(u32, @bitCast(c)))));
    var i: usize = 0;
    while (true) : (i += 1) {
        if (p[i] == ch) return p + i;
        if (p[i] == 0) return null;
    }
}

pub fn strrchr(p: [*c]i8, c: i32) [*c]i8 {
    const ch: i8 = @bitCast(@as(u8, @truncate(@as(u32, @bitCast(c)))));
    const n = slen(p);
    if (ch == 0) return p + n;
    var i = n;
    while (i > 0) {
        i -= 1;
        if (p[i] == ch) return p + i;
    }
    return null;
}

pub fn strstr(h: [*c]i8, n: [*c]i8) [*c]i8 {
    const hl = slen(h);
    const nl = slen(n);
    var i: usize = 0;
    outer: while (i + nl <= hl) : (i += 1) {
        var k: usize = 0;
        while (k < nl) : (k += 1) {
            if (h[i + k] != n[k]) continue :outer;
        }
        return h + i;
    }
    return null;
}

pub fn strcspn(p: [*c]i8, rej: [*c]i8) u64 {
    const n = slen(p);
    const m = slen(rej);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        var k: usize = 0;
        while (k < m) : (k += 1) {
            if (p[i] == rej[k]) return i;
        }
    }
    return n;
}

var tok_next: [*c]i8 = null;

fn inSet(c: i8, set: [*c]i8) bool {
    var k: usize = 0;
    while (set[k] != 0) : (k += 1) {
        if (set[k] == c) return true;
    }
    return false;
}

pub fn strtok(p: [*c]i8, delim: [*c]i8) [*c]i8 {
    if (p != null) tok_next = p;
    const b = tok_next;
    if (b == null) return null;
    var i: usize = 0;
    while (b[i] != 0 and inSet(b[i], delim)) i += 1;
    if (b[i] == 0) {
        tok_next = null;
        return null;
    }
    const start = i;
    while (b[i] != 0 and !inSet(b[i], delim)) i += 1;
    if (b[i] != 0) {
        b[i] = 0;
        tok_next = b + i + 1;
    } else {
        tok_next = null;
    }
    return b + start;
}

pub fn toupper(c: i32) i32 {
    if (c >= 'a' and c <= 'z') return c - 32;
    return c;
}

fn isSpace(c: i32) bool {
    return c == ' ' or (c >= 9 and c <= 13);
}

fn low(c: i32) i32 {
    return if (c >= 'A' and c <= 'Z') c | 0x20 else c;
}

fn isHex(c: i32) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

/// atoi is (int)strtol(s, NULL, 10): it keeps the low 32 bits of a long that saturates on overflow
pub fn atoi(p: [*c]i8) i32 {
    var i: usize = 0;
    while (p[i] != 0 and isSpace(p[i])) i += 1;
    var neg = false;
    if (p[i] == '+' or p[i] == '-') {
        neg = p[i] == '-';
        i += 1;
    }
    var v: i64 = 0;
    var over = false;
    while (p[i] >= '0' and p[i] <= '9') : (i += 1) {
        const d: i64 = p[i] - '0';
        if (v > @divTrunc(std.math.maxInt(i64) - d, 10)) over = true else v = v * 10 + d;
    }
    if (over) {
        v = if (neg) std.math.minInt(i64) else std.math.maxInt(i64);
    } else if (neg) v = -v;
    return @truncate(v);
}

// ================================================================ strtod
const Scan = struct { v: f64, end: isize, text_ok: bool, text: [512]u8 = undefined, tlen: usize = 0 };

/// glibc's strtod syntax at b (at most maxw characters when maxw >= 0): the value, the end offset
/// (-1: no number), and for a decimal or hexadecimal number its text (for %f into a float)
fn scanDouble(b: [*c]const i8, maxw: isize, skip_space: bool, sc: *Scan) void {
    var i: usize = 0;
    if (skip_space) {
        while (b[i] != 0 and isSpace(b[i])) i += 1;
    }
    const lim: usize = if (maxw >= 0) i + @as(usize, @intCast(maxw)) else std.math.maxInt(usize);
    const G = struct {
        b: [*c]const i8,
        lim: usize,
        fn g(self: @This(), k: usize) i32 {
            if (k >= self.lim) return 0;
            return self.b[k];
        }
    };
    const g = G{ .b = b, .lim = lim };
    sc.text_ok = false;
    sc.tlen = 0;
    var neg = false;
    if (g.g(i) == '+' or g.g(i) == '-') {
        neg = g.g(i) == '-';
        i += 1;
    }
    if (low(g.g(i)) == 'i' and low(g.g(i + 1)) == 'n' and low(g.g(i + 2)) == 'f') {
        i += 3;
        if (low(g.g(i)) == 'i' and low(g.g(i + 1)) == 'n' and low(g.g(i + 2)) == 'i' and low(g.g(i + 3)) == 't' and low(g.g(i + 4)) == 'y') i += 5;
        sc.v = if (neg) -inf64 else inf64;
        sc.end = @intCast(i);
        return;
    }
    if (low(g.g(i)) == 'n' and low(g.g(i + 1)) == 'a' and low(g.g(i + 2)) == 'n') {
        i += 3;
        if (g.g(i) == '(') {
            var k = i + 1;
            while (true) {
                const c = g.g(k);
                if ((c >= '0' and c <= '9') or (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or c == '_') {
                    k += 1;
                    continue;
                }
                break;
            }
            if (g.g(k) == ')') {
                // glibc reads the n-char-sequence with strtoull(seq, 0) and keeps it as the payload
                var pl: u64 = 0;
                const ok = if (k == i + 1) true else parsePayload(b + i + 1, k - i - 1, &pl);
                if (ok) {
                    var v: f64 = @bitCast(@as(u64, 0x7ff8000000000000) | (pl & ((@as(u64, 1) << 51) - 1)));
                    if (neg) v = -v;
                    sc.v = v;
                    sc.end = @intCast(k + 1);
                    return;
                }
                i = k + 1;
            }
        }
        sc.v = if (neg) @as(f64, @bitCast(@as(u64, 0xfff8000000000000))) else nan64;
        sc.end = @intCast(i);
        return;
    }
    if (g.g(i) == '0' and low(g.g(i + 1)) == 'x') { // hexadecimal float (C99), as glibc reads it
        var j = i + 2;
        var nh: usize = 0;
        while (isHex(g.g(j))) {
            j += 1;
            nh += 1;
        }
        if (g.g(j) == '.') {
            j += 1;
            while (isHex(g.g(j))) {
                j += 1;
                nh += 1;
            }
        }
        if (nh > 0) {
            var t: usize = 0;
            if (neg) {
                sc.text[t] = '-';
                t += 1;
            }
            sc.text[t] = '0';
            sc.text[t + 1] = 'x';
            t += 2;
            var k = i + 2;
            if (g.g(k) == '.') {
                sc.text[t] = '0';
                t += 1;
            }
            while (k < j and t < 480) : (k += 1) {
                sc.text[t] = @intCast(g.g(k));
                t += 1;
            }
            sc.text[t] = 'p';
            t += 1;
            if (low(g.g(j)) == 'p') {
                var e = j + 1;
                if (g.g(e) == '+' or g.g(e) == '-') e += 1;
                if (g.g(e) >= '0' and g.g(e) <= '9') {
                    while (g.g(e) >= '0' and g.g(e) <= '9') e += 1;
                    var q = j + 1;
                    while (q < e and t < 510) : (q += 1) {
                        sc.text[t] = @intCast(g.g(q));
                        t += 1;
                    }
                    j = e;
                } else {
                    sc.text[t] = '0';
                    t += 1;
                }
            } else {
                sc.text[t] = '0';
                t += 1;
            }
            sc.tlen = t;
            sc.text_ok = true;
            sc.v = std.fmt.parseFloat(f64, sc.text[0..t]) catch 0;
            sc.end = @intCast(j);
            return;
        }
    }
    const ms = i;
    var nd: usize = 0;
    while (g.g(i) >= '0' and g.g(i) <= '9') {
        i += 1;
        nd += 1;
    }
    if (g.g(i) == '.') {
        i += 1;
        while (g.g(i) >= '0' and g.g(i) <= '9') {
            i += 1;
            nd += 1;
        }
    }
    if (nd == 0) {
        sc.v = 0;
        sc.end = -1;
        return;
    }
    if (low(g.g(i)) == 'e') {
        var k = i + 1;
        if (g.g(k) == '+' or g.g(k) == '-') k += 1;
        if (g.g(k) >= '0' and g.g(k) <= '9') {
            while (g.g(k) >= '0' and g.g(k) <= '9') k += 1;
            i = k;
        }
    }
    sc.end = @intCast(i);
    sc.v = parseDec(b + ms, i - ms, neg, f64);
    if (i - ms < 500) {
        var t: usize = 0;
        if (neg) {
            sc.text[0] = '-';
            t = 1;
        }
        for (0..i - ms) |q| sc.text[t + q] = @intCast(b[ms + q]);
        sc.tlen = t + i - ms;
        sc.text_ok = true;
    }
}

fn parsePayload(p: [*c]const i8, n: usize, res: *u64) bool {
    // strtoull(seq, &end, 0) must consume the whole sequence
    var i: usize = 0;
    var base: u64 = 10;
    if (n >= 2 and p[0] == '0' and low(p[1]) == 'x') {
        base = 16;
        i = 2;
    } else if (n >= 1 and p[0] == '0') base = 8;
    var v: u64 = 0;
    if (i >= n) return base != 16;
    while (i < n) : (i += 1) {
        const c = low(p[i]);
        const d: u64 = if (c >= '0' and c <= '9') @intCast(c - '0') else if (c >= 'a' and c <= 'z') @intCast(c - 'a' + 10) else 99;
        if (d >= base) return false;
        v = v *% base +% d;
    }
    res.* = v;
    return true;
}

/// a decimal number's text (digits, optional point, optional exponent), correctly rounded
fn parseDec(p: [*c]const i8, n: usize, neg: bool, comptime F: type) F {
    var buf: [128]u8 = undefined;
    var big: ?[]u8 = null;
    defer if (big) |x| gpa.free(x);
    var dst: []u8 = &buf;
    if (n + 3 > buf.len) {
        big = gpa.alloc(u8, n + 3) catch unreachable;
        dst = big.?;
    }
    var t: usize = 0;
    var k: usize = 0;
    // parseFloat wants a digit before an exponent and no trailing point: "5." -> "5.0", ".5" -> "0.5"
    if (p[0] == '.') {
        dst[t] = '0';
        t += 1;
    }
    while (k < n) : (k += 1) {
        const c: u8 = @bitCast(p[k]);
        dst[t] = c;
        t += 1;
        if (c == '.' and (k + 1 >= n or !(p[k + 1] >= '0' and p[k + 1] <= '9'))) {
            dst[t] = '0';
            t += 1;
        }
    }
    const v = std.fmt.parseFloat(F, dst[0..t]) catch unreachable;
    return if (neg) -v else v;
}

pub fn strtod(p: [*c]i8, end: [*c][*c]i8) f64 {
    var sc: Scan = .{ .v = 0, .end = 0, .text_ok = false };
    scanDouble(p, -1, true, &sc);
    if (end != null) {
        end.* = if (sc.end < 0) p else p + @as(usize, @intCast(sc.end));
    }
    if (sc.end < 0) return 0;
    return sc.v;
}

pub fn atof(p: [*c]i8) f64 {
    return strtod(p, null);
}

// ================================================================ sscanf
const SArg = union(enum) { i32_: *i32, i64_: *i64, u32_: *u32, f64_: *f64, f32_: *f32, str: [*c]i8 };

fn sarg(a: anytype) SArg {
    const P = @TypeOf(a);
    const info = @typeInfo(P).pointer;
    const C = info.child;
    if (info.size == .c or info.size == .many) {
        switch (C) {
            i8 => return .{ .str = @ptrCast(a) },
            i32 => return .{ .i32_ = @ptrCast(a) },
            i64 => return .{ .i64_ = @ptrCast(a) },
            u32 => return .{ .u32_ = @ptrCast(a) },
            f64 => return .{ .f64_ = @ptrCast(a) },
            f32 => return .{ .f32_ = @ptrCast(a) },
            else => @compileError("sscanf target " ++ @typeName(P)),
        }
    }
    switch (C) {
        i8 => return .{ .str = @ptrCast(a) },
        i32 => return .{ .i32_ = a },
        i64 => return .{ .i64_ = a },
        u32 => return .{ .u32_ = a },
        f64 => return .{ .f64_ = a },
        f32 => return .{ .f32_ = a },
        else => switch (@typeInfo(C)) {
            .array => return .{ .str = @ptrCast(a) },
            else => @compileError("sscanf target " ++ @typeName(P)),
        },
    }
}

pub fn sscanf(str: [*c]i8, fmt: [*c]i8, args: anytype) i32 {
    const n = @typeInfo(@TypeOf(args)).@"struct".fields.len;
    var a: [n + 1]SArg = undefined;
    inline for (0..n) |k| a[k] = sarg(args[k]);
    return vsscanf(str, fmt, a[0..n]);
}

fn vsscanf(b: [*c]i8, f: [*c]i8, args: []SArg) i32 {
    var i: usize = 0;
    var k: usize = 0;
    var ai: usize = 0;
    var count: i32 = 0;
    var any_input = false;
    const nf = slen(f);
    while (k < nf) {
        const fc: i32 = f[k];
        if (isSpace(fc)) {
            while (k < nf and isSpace(f[k])) k += 1;
            while (b[i] != 0 and isSpace(b[i])) i += 1;
            continue;
        }
        if (fc != '%') {
            if (b[i] == 0) return if (any_input or count > 0) count else -1;
            if (b[i] != fc) return count;
            i += 1;
            k += 1;
            continue;
        }
        k += 1;
        if (f[k] == '%') {
            while (b[i] != 0 and isSpace(b[i])) i += 1;
            if (b[i] != '%') return count;
            i += 1;
            k += 1;
            continue;
        }
        var suppress = false;
        if (f[k] == '*') {
            suppress = true;
            k += 1;
        }
        var width: usize = 0;
        while (k < nf and f[k] >= '0' and f[k] <= '9') : (k += 1) width = width * 10 + @as(usize, @intCast(f[k] - '0'));
        while (k < nf and (f[k] == 'l' or f[k] == 'h' or f[k] == 'L')) k += 1;
        const conv: i32 = f[k];
        k += 1;
        if (conv != 'c' and conv != '[' and conv != 'n') {
            while (b[i] != 0 and isSpace(b[i])) i += 1;
        }
        if (b[i] == 0 and conv != 'n') return if (count == 0 and !any_input) -1 else count;
        switch (conv) {
            'd', 'i', 'u' => {
                var j = i;
                const lim: usize = if (width != 0) i + width else std.math.maxInt(usize);
                var neg = false;
                if (j < lim and (b[j] == '+' or b[j] == '-')) {
                    neg = b[j] == '-';
                    j += 1;
                }
                const ds = j;
                var v: i64 = 0;
                var over = false;
                while (j < lim and b[j] >= '0' and b[j] <= '9') : (j += 1) {
                    const d: i64 = b[j] - '0';
                    if (v > @divTrunc(std.math.maxInt(i64) - d, 10)) over = true else v = v * 10 + d;
                }
                if (j == ds) return count;
                i = j;
                any_input = true;
                if (over) {
                    v = if (neg) std.math.minInt(i64) else std.math.maxInt(i64);
                } else if (neg) v = -v;
                if (!suppress) {
                    switch (args[ai]) {
                        .i32_ => |p| p.* = @truncate(v),
                        .i64_ => |p| p.* = v,
                        .u32_ => |p| p.* = @truncate(@as(u64, @bitCast(v))),
                        else => @panic("sscanf %d target"),
                    }
                    ai += 1;
                    count += 1;
                }
            },
            'f', 'e', 'g' => {
                var sc: Scan = .{ .v = 0, .end = 0, .text_ok = false };
                scanDouble(b + i, if (width != 0) @intCast(width) else -1, false, &sc);
                if (sc.end < 0) return count;
                i += @intCast(sc.end);
                any_input = true;
                if (!suppress) {
                    switch (args[ai]) {
                        .f64_ => |p| p.* = sc.v,
                        .f32_ => |p| {
                            if (sc.text_ok) {
                                p.* = std.fmt.parseFloat(f32, sc.text[0..sc.tlen]) catch @floatCast(sc.v);
                            } else p.* = @floatCast(sc.v);
                        },
                        else => @panic("sscanf %f target"),
                    }
                    ai += 1;
                    count += 1;
                }
            },
            's' => {
                var j = i;
                const w: usize = if (width != 0) width else std.math.maxInt(usize);
                var m: usize = 0;
                while (b[j] != 0 and !isSpace(b[j]) and m < w) {
                    j += 1;
                    m += 1;
                }
                if (!suppress) {
                    const d = args[ai].str;
                    ai += 1;
                    for (0..m) |q| d[q] = b[i + q];
                    d[m] = 0;
                    count += 1;
                }
                i = j;
                any_input = true;
            },
            'c' => {
                const cnt: usize = if (width != 0) width else 1;
                if (b[i] == 0) return if (count == 0 and !any_input) -1 else count;
                var d: [*c]i8 = null;
                if (!suppress) {
                    d = args[ai].str;
                    ai += 1;
                }
                var t: usize = 0;
                while (t < cnt and b[i] != 0) : (t += 1) {
                    if (!suppress) d[t] = b[i];
                    i += 1;
                }
                any_input = true;
                if (!suppress) count += 1;
            },
            else => @panic("sscanf conversion"),
        }
    }
    return count;
}

// ================================================================ printf
pub const Arg = union(enum) { i: i64, u: u64, is_int: i32, d: f64, str: [*c]i8 };

fn parg(a: anytype) Arg {
    const T = @TypeOf(a);
    switch (T) {
        i32 => return .{ .is_int = a },
        i64 => return .{ .i = a },
        u32 => return .{ .u = a },
        u64 => return .{ .u = a },
        f64 => return .{ .d = a },
        f32 => return .{ .d = a },
        [*c]i8 => return .{ .str = a },
        else => @compileError("printf argument " ++ @typeName(T)),
    }
}

fn argLong(a: Arg) struct { v: i64, int32: bool } {
    return switch (a) {
        .is_int => |x| .{ .v = x, .int32 = true },
        .i => |x| .{ .v = x, .int32 = false },
        .u => |x| .{ .v = @bitCast(x), .int32 = false },
        .d => |x| .{ .v = d2i(i64, x), .int32 = false },
        .str => |x| .{ .v = @bitCast(@intFromPtr(x)), .int32 = false },
    };
}

fn argDouble(a: Arg) f64 {
    return switch (a) {
        .d => |x| x,
        .is_int => |x| @floatFromInt(x),
        .i => |x| @floatFromInt(x),
        .u => |x| @floatFromInt(x),
        .str => 0,
    };
}

/// an output buffer that grows
const Out = struct {
    buf: []u8,
    n: usize = 0,
    heap: bool = false,
    fn put(o: *Out, c: u8) void {
        if (o.n == o.buf.len) o.grow(o.n + 1);
        o.buf[o.n] = c;
        o.n += 1;
    }
    fn puts(o: *Out, x: []const u8) void {
        if (o.n + x.len > o.buf.len) o.grow(o.n + x.len);
        @memcpy(o.buf[o.n .. o.n + x.len], x);
        o.n += x.len;
    }
    fn pad(o: *Out, c: u8, k: usize) void {
        for (0..k) |_| o.put(c);
    }
    fn grow(o: *Out, need: usize) void {
        var m = o.buf.len * 2;
        while (m < need) m *= 2;
        const nb = gpa.alloc(u8, m) catch unreachable;
        @memcpy(nb[0..o.n], o.buf[0..o.n]);
        if (o.heap) gpa.free(o.buf);
        o.buf = nb;
        o.heap = true;
    }
    fn deinit(o: *Out) void {
        if (o.heap) gpa.free(o.buf);
    }
};

// ---------------------------------------------------------------- exact decimal digits of a double
const Big = struct {
    w: [96]u32 = undefined,
    n: usize = 0,
    fn set(b: *Big, v: u64) void {
        b.w[0] = @truncate(v);
        b.w[1] = @truncate(v >> 32);
        b.n = 2;
        b.trim();
    }
    fn trim(b: *Big) void {
        while (b.n > 0 and b.w[b.n - 1] == 0) b.n -= 1;
    }
    fn mulSmall(b: *Big, m: u32) void {
        var carry: u64 = 0;
        for (0..b.n) |k| {
            const t = @as(u64, b.w[k]) * m + carry;
            b.w[k] = @truncate(t);
            carry = t >> 32;
        }
        if (carry != 0) {
            b.w[b.n] = @truncate(carry);
            b.n += 1;
        }
    }
    fn shl(b: *Big, k: usize) void {
        const ws = k / 32;
        const bs: u5 = @intCast(k % 32);
        if (b.n == 0) return;
        var i: usize = b.n + ws + 1;
        while (i > 0) {
            i -= 1;
            var v: u32 = 0;
            if (i >= ws) {
                const src = i - ws;
                const hi: u64 = if (src < b.n) b.w[src] else 0;
                const lo: u64 = if (src >= 1 and src - 1 < b.n) b.w[src - 1] else 0;
                v = @truncate(((hi << 32 | lo) << bs) >> 32);
            }
            b.w[i] = v;
        }
        b.n = b.n + ws + 1;
        b.trim();
    }
    /// divide by 10^9, returning the remainder
    fn divBillion(b: *Big) u32 {
        var r: u64 = 0;
        var i = b.n;
        while (i > 0) {
            i -= 1;
            const t = (r << 32) | b.w[i];
            b.w[i] = @truncate(t / 1000000000);
            r = t % 1000000000;
        }
        b.trim();
        return @truncate(r);
    }
    /// decimal digits (most significant first) into out; returns the count ("" for zero)
    fn toDec(b: *Big, dst: []u8) usize {
        var tmp: [1200]u8 = undefined;
        var t: usize = 0;
        while (b.n > 0) {
            var r = b.divBillion();
            var k: usize = 0;
            while (k < 9) : (k += 1) {
                tmp[t] = @intCast('0' + r % 10);
                r /= 10;
                t += 1;
            }
        }
        while (t > 0 and tmp[t - 1] == '0') t -= 1;
        for (0..t) |k| dst[k] = tmp[t - 1 - k];
        return t;
    }
};

/// the exact decimal expansion of a positive finite double: digits d[0..n] with the decimal point after
/// d[0..p] (p >= 1; the integer part is "0" when it is zero)
const Digits = struct { d: [1500]u8 = undefined, n: usize = 0, p: usize = 0 };

fn exactDigits(v: f64, dg: *Digits) void {
    const bits: u64 = @bitCast(v);
    const ex: i32 = @intCast((bits >> 52) & 0x7ff);
    var m: u64 = bits & ((@as(u64, 1) << 52) - 1);
    var e: i32 = undefined;
    if (ex == 0) {
        e = -1074;
    } else {
        e = ex - 1075;
        m |= @as(u64, 1) << 52;
    }
    var b: Big = .{};
    if (e >= 0) {
        b.set(m);
        b.shl(@intCast(e));
        const k = b.toDec(dg.d[0..]);
        dg.n = k;
        dg.p = k;
        if (k == 0) {
            dg.d[0] = '0';
            dg.n = 1;
            dg.p = 1;
        }
        return;
    }
    const k: u32 = @intCast(-e);
    const ip: u64 = if (k < 64) m >> @intCast(k) else 0;
    const fp: u64 = if (k < 64) m & ((@as(u64, 1) << @intCast(k)) - 1) else m;
    // integer part
    var ib: Big = .{};
    ib.set(ip);
    var ilen = ib.toDec(dg.d[0..]);
    if (ilen == 0) {
        dg.d[0] = '0';
        ilen = 1;
    }
    dg.p = ilen;
    // fraction: fp / 2^k = fp * 5^k / 10^k: k digits
    b.set(fp);
    var r = k;
    while (r >= 13) : (r -= 13) b.mulSmall(1220703125);
    var f5: u32 = 1;
    while (r > 0) : (r -= 1) f5 *= 5;
    b.mulSmall(f5);
    var fd: [1200]u8 = undefined;
    const fl = b.toDec(fd[0..]);
    const lead = k - @as(u32, @intCast(fl));
    var t = ilen;
    for (0..lead) |_| {
        dg.d[t] = '0';
        t += 1;
    }
    for (0..fl) |q| {
        dg.d[t] = fd[q];
        t += 1;
    }
    // drop trailing zeros (they never affect rounding)
    while (t > ilen and dg.d[t - 1] == '0') t -= 1;
    dg.n = t;
}

/// round d[0..n] to its first keep digits, half to even on the exact value; returns true if the carry
/// ran off the front (all nines: the caller prepends a 1). The kept digits are left in d[0..keep].
fn roundDigits(d: []u8, n: usize, keep: usize) bool {
    if (keep >= n) {
        for (n..keep) |k| d[k] = '0';
        return false;
    }
    const next = d[keep];
    var up = false;
    if (next > '5') {
        up = true;
    } else if (next == '5') {
        var rest = false;
        for (keep + 1..n) |k| {
            if (d[k] != '0') {
                rest = true;
                break;
            }
        }
        if (rest) {
            up = true;
        } else {
            up = keep > 0 and (d[keep - 1] - '0') % 2 == 1;
        }
    }
    if (!up) return false;
    var k = keep;
    while (k > 0) {
        k -= 1;
        if (d[k] == '9') {
            d[k] = '0';
        } else {
            d[k] += 1;
            return false;
        }
    }
    return true;
}

/// %.{prec}f of a positive finite value
fn fixedDigits(o: *Out, a: f64, prec: usize, alt: bool) void {
    var dg: Digits = .{};
    exactDigits(a, &dg);
    var keep = dg.p + prec;
    var w: [1700]u8 = undefined;
    @memcpy(w[0..dg.n], dg.d[0..dg.n]);
    var start: usize = 0;
    if (keep > w.len - 2) keep = w.len - 2;
    var buf2: [1701]u8 = undefined;
    var dd: []u8 = w[0..];
    var p = dg.p;
    if (roundDigits(&w, dg.n, keep)) {
        buf2[0] = '1';
        @memcpy(buf2[1 .. keep + 1], w[0..keep]);
        dd = buf2[0..];
        p += 1;
        keep += 1;
    }
    // strip a leading zero of the integer part only if it is the "0" placeholder and more digits exist
    _ = &start;
    o.puts(dd[0..p]);
    if (prec > 0 or alt) o.put('.');
    o.puts(dd[p..keep]);
}

/// the digits of a positive finite value rounded to sig significant digits, and its decimal exponent
fn expRaw(a: f64, sig: usize, res: []u8) i32 {
    var dg: Digits = .{};
    exactDigits(a, &dg);
    var f: usize = 0;
    while (f < dg.n and dg.d[f] == '0') f += 1;
    var x: i32 = @as(i32, @intCast(dg.p)) - 1 - @as(i32, @intCast(f));
    const n = dg.n - f;
    var w: [1700]u8 = undefined;
    @memcpy(w[0..n], dg.d[f..dg.n]);
    if (roundDigits(&w, n, sig)) {
        res[0] = '1';
        for (1..sig) |k| res[k] = '0';
        x += 1;
    } else {
        @memcpy(res[0..sig], w[0..sig]);
    }
    return x;
}

fn expDigits(o: *Out, a: f64, prec: usize, alt: bool, upper: bool) void {
    var d: [1700]u8 = undefined;
    var x: i32 = 0;
    if (a == 0) {
        for (0..prec + 1) |k| d[k] = '0';
    } else {
        x = expRaw(a, prec + 1, &d);
    }
    o.put(d[0]);
    if (prec > 0) {
        o.put('.');
        o.puts(d[1 .. prec + 1]);
    } else if (alt) o.put('.');
    o.put(if (upper) 'E' else 'e');
    if (x < 0) {
        o.put('-');
        x = -x;
    } else o.put('+');
    var tmp: [12]u8 = undefined;
    const xs = std.fmt.bufPrint(&tmp, "{d}", .{x}) catch unreachable;
    if (x < 10) o.put('0');
    o.puts(xs);
}

fn formatFloat(o: *Out, a: f64, conv: u8, prec: usize, alt: bool) void {
    const lc = conv | 0x20;
    if (lc == 'f') return fixedDigits(o, a, prec, alt);
    if (lc == 'e') return expDigits(o, a, prec, alt, conv == 'E');
    const P: usize = if (prec == 0) 1 else prec;
    var X: i32 = 0;
    if (a != 0) {
        var d: [1700]u8 = undefined;
        X = expRaw(a, P, &d);
    }
    var sub: Out = .{ .buf = &([_]u8{0} ** 0) };
    var sb: [512]u8 = undefined;
    sub.buf = &sb;
    defer sub.deinit();
    if (@as(i32, @intCast(P)) > X and X >= -4) {
        fixedDigits(&sub, a, @intCast(@as(i32, @intCast(P)) - 1 - X), alt);
    } else {
        expDigits(&sub, a, P - 1, alt, conv == 'G');
    }
    var r = sub.buf[0..sub.n];
    if (!alt) {
        var ep: usize = r.len;
        for (r, 0..) |c, k| {
            if (c == 'e' or c == 'E') {
                ep = k;
                break;
            }
        }
        var mant = r[0..ep];
        const ex = r[ep..];
        var has_point = false;
        for (mant) |c| {
            if (c == '.') has_point = true;
        }
        if (has_point) {
            var e = mant.len;
            while (e > 0 and mant[e - 1] == '0') e -= 1;
            if (e > 0 and mant[e - 1] == '.') e -= 1;
            mant = mant[0..e];
        }
        o.puts(mant);
        o.puts(ex);
        return;
    }
    r = sub.buf[0..sub.n];
    o.puts(r);
}

fn format(o: *Out, fmt: [*c]i8, args: []const Arg) void {
    var k: usize = 0;
    var ai: usize = 0;
    const f: [*c]u8 = @ptrCast(fmt);
    while (f[k] != 0) {
        if (f[k] != '%') {
            o.put(f[k]);
            k += 1;
            continue;
        }
        k += 1;
        if (f[k] == '%') {
            o.put('%');
            k += 1;
            continue;
        }
        var left = false;
        var plus = false;
        var space = false;
        var alt = false;
        var zero = false;
        while (true) : (k += 1) {
            switch (f[k]) {
                '-' => left = true,
                '+' => plus = true,
                ' ' => space = true,
                '#' => alt = true,
                '0' => zero = true,
                else => break,
            }
        }
        var width: usize = 0;
        var prec: isize = -1;
        if (f[k] == '*') {
            const w = argLong(args[ai]).v;
            ai += 1;
            if (w < 0) {
                left = true;
                width = @intCast(-w);
            } else width = @intCast(w);
            k += 1;
        } else {
            while (f[k] >= '0' and f[k] <= '9') : (k += 1) width = width * 10 + (f[k] - '0');
        }
        if (f[k] == '.') {
            k += 1;
            prec = 0;
            if (f[k] == '*') {
                const pv = argLong(args[ai]).v;
                ai += 1;
                prec = if (pv < 0) -1 else @intCast(pv);
                k += 1;
            } else {
                while (f[k] >= '0' and f[k] <= '9') : (k += 1) prec = prec * 10 + (f[k] - '0');
            }
        }
        while (f[k] == 'l' or f[k] == 'h' or f[k] == 'L' or f[k] == 'z' or f[k] == 'j' or f[k] == 't' or f[k] == 'q') k += 1;
        const conv = f[k];
        k += 1;
        var sign: []const u8 = "";
        var bodybuf: [1800]u8 = undefined;
        var body: Out = .{ .buf = &bodybuf };
        defer body.deinit();
        var numeric = true;
        switch (conv) {
            'd', 'i' => {
                const v = argLong(args[ai]).v;
                ai += 1;
                if (v < 0) sign = "-" else if (plus) sign = "+" else if (space) sign = " ";
                const u: u64 = if (v < 0) @as(u64, @bitCast(-%v)) else @intCast(v);
                intBody(&body, u, 10, false, prec);
                if (prec >= 0) zero = false;
            },
            'u', 'x', 'X', 'o' => {
                const a = argLong(args[ai]);
                ai += 1;
                var u: u64 = @bitCast(a.v);
                if (a.int32) u &= 0xFFFFFFFF;
                const base: u64 = switch (conv) {
                    'u' => 10,
                    'o' => 8,
                    else => 16,
                };
                intBody(&body, u, base, conv == 'X', prec);
                if (prec >= 0) zero = false;
            },
            'c' => {
                numeric = false;
                const v = argLong(args[ai]).v;
                ai += 1;
                body.put(@truncate(@as(u64, @bitCast(v))));
            },
            's' => {
                numeric = false;
                const p = args[ai].str;
                ai += 1;
                var x: []const u8 = "(null)";
                if (p != null) x = bytes(p);
                if (prec >= 0 and x.len > @as(usize, @intCast(prec))) x = x[0..@intCast(prec)];
                body.puts(x);
            },
            'f', 'F', 'e', 'E', 'g', 'G' => {
                const v = argDouble(args[ai]);
                ai += 1;
                const pr: usize = if (prec < 0) 6 else @intCast(prec);
                if (std.math.signbit(v)) sign = "-" else if (plus) sign = "+" else if (space) sign = " ";
                if (std.math.isNan(v) or std.math.isInf(v)) {
                    const upper = conv == 'F' or conv == 'E' or conv == 'G';
                    if (std.math.isNan(v)) body.puts(if (upper) "NAN" else "nan") else body.puts(if (upper) "INF" else "inf");
                    zero = false;
                } else {
                    formatFloat(&body, @abs(v), conv, pr, alt);
                }
            },
            else => @panic("printf conversion"),
        }
        const n = sign.len + body.n;
        if (n >= width) {
            o.puts(sign);
            o.puts(body.buf[0..body.n]);
        } else if (left) {
            o.puts(sign);
            o.puts(body.buf[0..body.n]);
            o.pad(' ', width - n);
        } else if (zero and numeric) {
            o.puts(sign);
            o.pad('0', width - n);
            o.puts(body.buf[0..body.n]);
        } else {
            o.pad(' ', width - n);
            o.puts(sign);
            o.puts(body.buf[0..body.n]);
        }
    }
}

fn intBody(o: *Out, uval: u64, base: u64, upper: bool, prec: isize) void {
    var tmp: [70]u8 = undefined;
    var t: usize = 0;
    var u = uval;
    const digs = if (upper) "0123456789ABCDEF" else "0123456789abcdef";
    while (u != 0) {
        tmp[t] = digs[@intCast(u % base)];
        u /= base;
        t += 1;
    }
    if (prec < 0) {
        if (t == 0) {
            tmp[0] = '0';
            t = 1;
        }
    } else {
        while (t < @as(usize, @intCast(prec))) {
            tmp[t] = '0';
            t += 1;
        }
    }
    var k = t;
    while (k > 0) {
        k -= 1;
        o.put(tmp[k]);
    }
}

fn packArgs(args: anytype, dst: []Arg) []Arg {
    const n = @typeInfo(@TypeOf(args)).@"struct".fields.len;
    inline for (0..n) |k| dst[k] = parg(args[k]);
    return dst[0..n];
}

pub fn fprintf(f: [*c]FILE, fmt: [*c]i8, args: anytype) i32 {
    var a: [@typeInfo(@TypeOf(args)).@"struct".fields.len + 1]Arg = undefined;
    const as = packArgs(args, &a);
    var sb: [1024]u8 = undefined;
    var o: Out = .{ .buf = &sb };
    defer o.deinit();
    format(&o, fmt, as);
    if (f == null) return -1;
    fwriteBytes(f, o.buf[0..o.n]);
    return @intCast(o.n);
}

pub fn snprintf(d: [*c]i8, n: u64, fmt: [*c]i8, args: anytype) i32 {
    var a: [@typeInfo(@TypeOf(args)).@"struct".fields.len + 1]Arg = undefined;
    const as = packArgs(args, &a);
    var sb: [1024]u8 = undefined;
    var o: Out = .{ .buf = &sb };
    defer o.deinit();
    format(&o, fmt, as);
    if (n > 0) {
        const m: usize = @min(o.n, @as(usize, @intCast(n - 1)));
        for (0..m) |k| d[k] = @bitCast(o.buf[k]);
        d[m] = 0;
    }
    return @intCast(o.n);
}

/// printf into a caller's buffer (for the command-line runner); returns the bytes written
pub fn bprintf(buf: []u8, comptime fmt: []const u8, args: anytype) []u8 {
    const n = snprintf(@ptrCast(buf.ptr), buf.len, s(fmt), args);
    return buf[0..@min(@as(usize, @intCast(n)), buf.len - 1)];
}

// ================================================================ stdio
const BUFSZ = 1 << 16;

pub const FILE = extern struct {
    fd: i32 = -1,
    std: i32 = 0,
    eof: i32 = 0,
    append: i32 = 0,
    pos: i64 = 0,
    wpos: i64 = 0,
    wlen: i64 = 0,
    rstart: i64 = 0,
    rlen: i64 = 0,
    wbuf: [*c]u8 = null,
    rbuf: [*c]u8 = null,
};

var stdout_file: FILE = .{ .fd = 1, .std = 1 };
pub var stdout: [*c]FILE = &stdout_file;
pub var stderr: [*c]FILE = &stdout_file;

fn die(msg: []const u8) noreturn {
    _ = write(2, msg.ptr, msg.len);
    std.process.exit(3);
}

fn writeAll(f: *FILE, b: []const u8, at: i64) void {
    var done: usize = 0;
    while (done < b.len) {
        const r = if (f.std != 0) write(f.fd, b.ptr + done, b.len - done) else pwrite(f.fd, b.ptr + done, b.len - done, at + @as(i64, @intCast(done)));
        if (r <= 0) die("write error\n");
        done += @intCast(r);
    }
}

fn flushW(f: *FILE) void {
    if (f.wlen == 0) return;
    writeAll(f, f.wbuf[0..@intCast(f.wlen)], f.wpos);
    f.wlen = 0;
}

fn fwriteBytes(fp: [*c]FILE, src: []const u8) void {
    const f: *FILE = @ptrCast(fp);
    const n: i64 = @intCast(src.len);
    f.rlen = 0;
    if (f.wbuf == null) {
        const b = gpa.alloc(u8, BUFSZ) catch die("out of memory\n");
        f.wbuf = b.ptr;
    }
    if (f.append != 0 and f.std == 0) {
        flushW(f);
        f.pos = fsize(f);
    }
    if (f.wlen > 0 and f.pos != f.wpos + f.wlen) flushW(f);
    if (f.wlen == 0) f.wpos = f.pos;
    if (f.wlen + n > BUFSZ) {
        flushW(f);
        if (n > BUFSZ) {
            writeAll(f, src, f.pos);
            f.pos += n;
            return;
        }
        f.wpos = f.pos;
    }
    @memcpy(f.wbuf[@intCast(f.wlen)..@intCast(f.wlen + n)], src);
    f.wlen += n;
    f.pos += n;
}

fn readBytes(f: *FILE, dst: []u8) usize {
    flushW(f);
    var got: usize = 0;
    while (got < dst.len) {
        if (f.rlen > 0 and f.pos >= f.rstart and f.pos < f.rstart + f.rlen) {
            const a: usize = @intCast(f.pos - f.rstart);
            const m = @min(dst.len - got, @as(usize, @intCast(f.rlen)) - a);
            @memcpy(dst[got .. got + m], f.rbuf[a .. a + m]);
            got += m;
            f.pos += @intCast(m);
            continue;
        }
        if (f.rbuf == null) {
            const b = gpa.alloc(u8, BUFSZ) catch die("out of memory\n");
            f.rbuf = b.ptr;
        }
        f.rstart = f.pos;
        const r = pread(f.fd, f.rbuf, BUFSZ, f.pos);
        f.rlen = if (r > 0) r else 0;
        if (r <= 0) break;
    }
    return got;
}

fn getc(f: *FILE) i32 {
    if (f.wlen == 0 and f.rlen > 0 and f.pos >= f.rstart and f.pos < f.rstart + f.rlen) {
        const c = f.rbuf[@intCast(f.pos - f.rstart)];
        f.pos += 1;
        return c;
    }
    var t: [1]u8 = undefined;
    if (readBytes(f, &t) == 1) return t[0];
    return -1;
}

fn fsize(f: *FILE) i64 {
    flushW(f);
    return lseek(f.fd, 0, 2);
}

pub fn fopen(name: [*c]i8, mode: [*c]i8) [*c]FILE {
    var m: [8]u8 = undefined;
    var ml: usize = 0;
    var k: usize = 0;
    while (mode[k] != 0 and ml < 8) : (k += 1) {
        const c: u8 = @bitCast(mode[k]);
        if (c != 'b' and c != 't') {
            m[ml] = c;
            ml += 1;
        }
    }
    if (ml == 0) return null;
    const plus = ml > 1 and m[1] == '+';
    var flags: c_int = 0;
    switch (m[0]) {
        'r' => flags = if (plus) O_RDWR else O_RDONLY,
        'w' => flags = (if (plus) O_RDWR else O_WRONLY) | O_CREAT | O_TRUNC,
        'a' => flags = (if (plus) O_RDWR else O_WRONLY) | O_CREAT | O_APPEND,
        else => return null,
    }
    const fd = open(@ptrCast(name), flags, @as(c_uint, 0o666));
    if (fd < 0) return null;
    const f = gpa.create(FILE) catch die("out of memory\n");
    f.* = .{ .fd = fd };
    if (m[0] == 'a') {
        f.append = 1;
        f.pos = lseek(fd, 0, 2);
    }
    return f;
}

pub fn fclose(fp: [*c]FILE) i32 {
    if (fp == null) return -1;
    const f: *FILE = @ptrCast(fp);
    flushW(f);
    if (f.std != 0) return 0;
    const r = close(f.fd);
    if (f.wbuf != null) gpa.free(f.wbuf[0..BUFSZ]);
    if (f.rbuf != null) gpa.free(f.rbuf[0..BUFSZ]);
    gpa.destroy(f);
    return if (r == 0) 0 else -1;
}

pub fn fflush(fp: [*c]FILE) i32 {
    if (fp != null) flushW(@ptrCast(fp));
    return 0;
}

pub fn feof(fp: [*c]FILE) i32 {
    return if (fp.*.eof != 0) 1 else 0;
}

pub fn rewind(fp: [*c]FILE) void {
    const f: *FILE = @ptrCast(fp);
    flushW(f);
    f.pos = 0;
    f.eof = 0;
}

pub fn fseek(fp: [*c]FILE, off: i64, whence: i32) i32 {
    const f: *FILE = @ptrCast(fp);
    flushW(f);
    var p = off;
    if (whence == 1) p = f.pos + off else if (whence == 2) p = fsize(f) + off;
    if (p < 0) return -1;
    f.pos = p;
    f.eof = 0;
    return 0;
}

pub fn fseeko(fp: [*c]FILE, off: i64, whence: i32) i32 {
    return fseek(fp, off, whence);
}

pub fn ftell(fp: [*c]FILE) i64 {
    return fp.*.pos;
}

pub fn fgets(b: [*c]i8, n: i32, fp: [*c]FILE) [*c]i8 {
    const f: *FILE = @ptrCast(fp);
    var m: usize = 0;
    while (@as(i64, @intCast(m)) < @as(i64, n) - 1) {
        const c = getc(f);
        if (c < 0) {
            f.eof = 1;
            break;
        }
        b[m] = @bitCast(@as(u8, @intCast(c)));
        m += 1;
        if (c == '\n') break;
    }
    if (m == 0) return null;
    b[m] = 0;
    return b;
}

/// fread: the bytes go straight into the caller's memory, as C's do (a short read fills part of an item)
pub fn fread(p: ?*anyopaque, size: u64, n: u64, fp: [*c]FILE) u64 {
    const f: *FILE = @ptrCast(fp);
    const total: usize = @intCast(size * n);
    if (total == 0) return 0;
    const dst: [*]u8 = @ptrCast(p.?);
    const got = readBytes(f, dst[0..total]);
    if (got < total) f.eof = 1;
    return got / size;
}

pub fn fwrite(p: ?*anyopaque, size: u64, n: u64, fp: [*c]FILE) u64 {
    const total: usize = @intCast(size * n);
    if (total == 0) return 0;
    const src: [*]const u8 = @ptrCast(p.?);
    fwriteBytes(fp, src[0..total]);
    return n;
}

pub fn remove(name: [*c]i8) i32 {
    return if (unlink(@ptrCast(name)) == 0) 0 else -1;
}

var rnd_state: u64 = 0;

/// mkstemp: six random characters, created exclusively (the descriptor is left open, as EPA leaves it)
pub fn mkstemp(tmpl: [*c]i8) i32 {
    const chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    if (rnd_state == 0) rnd_state = (@as(u64, @bitCast(c_time(null))) << 20) ^ @as(u64, @intCast(getpid())) | 1;
    const n = slen(tmpl);
    if (n < 6) return -1;
    var t: usize = 0;
    while (t < 1000) : (t += 1) {
        for (n - 6..n) |i| {
            rnd_state ^= rnd_state << 13;
            rnd_state ^= rnd_state >> 7;
            rnd_state ^= rnd_state << 17;
            tmpl[i] = @intCast(chars[@intCast(rnd_state % chars.len)]);
        }
        const fd = open(@ptrCast(tmpl), O_RDWR | O_CREAT | O_EXCL, @as(c_uint, 0o600));
        if (fd >= 0) return fd;
    }
    return -1;
}

/// realpath: the current directory joined to a relative path, with "." and ".." removed
pub fn realpath(path: [*c]i8, resolved: [*c]i8) [*c]i8 {
    var buf: [8192]u8 = undefined;
    var n: usize = 0;
    const p = bytes(path);
    if (p.len == 0 or p[0] != '/') {
        const cwd = getcwd(&buf, buf.len) orelse return null;
        _ = cwd;
        n = std.mem.indexOfScalar(u8, &buf, 0) orelse return null;
    }
    // components
    var res: [8192]u8 = undefined;
    var on: usize = 0;
    var src: [16384]u8 = undefined;
    var sl: usize = 0;
    @memcpy(src[0..n], buf[0..n]);
    sl = n;
    src[sl] = '/';
    sl += 1;
    @memcpy(src[sl .. sl + p.len], p);
    sl += p.len;
    var it = std.mem.splitScalar(u8, src[0..sl], '/');
    while (it.next()) |comp| {
        if (comp.len == 0 or std.mem.eql(u8, comp, ".")) continue;
        if (std.mem.eql(u8, comp, "..")) {
            while (on > 0 and res[on - 1] != '/') on -= 1;
            if (on > 0) on -= 1;
            continue;
        }
        res[on] = '/';
        on += 1;
        @memcpy(res[on .. on + comp.len], comp);
        on += comp.len;
    }
    if (on == 0) {
        res[0] = '/';
        on = 1;
    }
    for (0..on) |k| resolved[k] = @bitCast(res[k]);
    resolved[on] = 0;
    return resolved;
}

// ================================================================ time
pub fn time(t: [*c]i64) i64 {
    const v = c_time(null);
    if (t != null) t.* = v;
    return v;
}

pub fn difftime(a: i64, b: i64) f64 {
    return @as(f64, @floatFromInt(a)) - @as(f64, @floatFromInt(b));
}

var ctime_buf: [32]i8 = undefined;

/// ctime: "Www Mmm dd hh:mm:ss yyyy\n" (UTC; only the report's clock lines use it)
pub fn ctime(t: [*c]i64) [*c]i8 {
    const secs: u64 = @intCast(@max(t.*, 0));
    const es = std.time.epoch.EpochSeconds{ .secs = secs };
    const day = es.getEpochDay();
    const yd = day.calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    const wd = (day.day + 4) % 7;
    const wn = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
    const mn = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    var b: [32]u8 = undefined;
    const r = std.fmt.bufPrint(&b, "{s} {s} {d:>2} {d:0>2}:{d:0>2}:{d:0>2} {d}\n", .{
        wn[@intCast(wd)], mn[@intFromEnum(md.month) - 1], md.day_index + 1, ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(), yd.year,
    }) catch unreachable;
    for (r, 0..) |c, k| ctime_buf[k] = @bitCast(c);
    ctime_buf[r.len] = 0;
    return &ctime_buf;
}

/// write a Zig string to standard output at once (for the runner)
pub fn conout(x: []const u8) void {
    fwriteBytes(stdout, x);
    flushW(@ptrCast(stdout));
}
