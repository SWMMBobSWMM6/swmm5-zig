//! crtcheck.zig - compare the Zig port's printf, strtod and sscanf (src/rt.zig) with the system glibc's
//! results written by tools/crt/test/mkfmt.c (lines KIND \t FORMAT \t ARG \t RESULT, hex-encoded).
//!   zig/test/run_crtcheck.sh  (builds mkfmt and this program, runs both, prints the summary)
//! Written by Claude (Anthropic) for Robert Dickinson; see zig/README.md.
const std = @import("std");
const R = @import("rt");

fn unhex(src: []const u8, dst: []u8) []u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i + 1 < src.len) : (i += 2) {
        dst[n] = std.fmt.parseInt(u8, src[i .. i + 2], 16) catch unreachable;
        n += 1;
    }
    return dst[0..n];
}

fn cstr(b: []const u8, buf: []i8) [*c]i8 {
    for (b, 0..) |c, k| buf[k] = @bitCast(c);
    buf[b.len] = 0;
    return @ptrCast(buf.ptr);
}

fn hexOf(b: []const u8, dst: []u8) []u8 {
    const digs = "0123456789abcdef";
    for (b, 0..) |c, k| {
        dst[2 * k] = digs[c >> 4];
        dst[2 * k + 1] = digs[c & 15];
    }
    return dst[0 .. 2 * b.len];
}

fn spanI8(p: [*c]i8) []const u8 {
    const b: [*]const u8 = @ptrCast(p);
    var n: usize = 0;
    while (b[n] != 0) n += 1;
    return b[0..n];
}

pub fn main() !void {
    const gpa = std.heap.page_allocator;
    const args = std.os.argv;
    const path = std.mem.span(args[1]);
    const data = try std.fs.cwd().readFileAlloc(gpa, path, 1 << 30);
    var total = [_]usize{0} ** 6;
    var bad = [_]usize{0} ** 6;
    const names = [_][]const u8{ "printf %f", "printf %d", "printf %ld", "printf %s", "strtod", "sscanf" };
    var shown: usize = 0;
    var out: [1024]i8 = undefined;
    var fmtb: [64]i8 = undefined;
    var argb: [256]u8 = undefined;
    var sbuf: [256]i8 = undefined;
    var gotb: [4096]u8 = undefined;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var it = std.mem.splitScalar(u8, line, '\t');
        const kind = it.next().?;
        const fm = it.next().?;
        const arg = it.next().?;
        const want = it.next().?;
        const f = cstr(fm, &fmtb);
        var got: []const u8 = undefined;
        var k: usize = 0;
        switch (kind[0]) {
            'f' => {
                k = 0;
                const x: f64 = @bitCast(try std.fmt.parseInt(u64, arg, 16));
                if (std.mem.eql(u8, fm, "%*.*f")) {
                    _ = R.snprintf(&out, 1024, f, .{ @as(i32, 9), @as(i32, 3), x });
                } else _ = R.snprintf(&out, 1024, f, .{x});
                got = hexOf(spanI8(&out), &gotb);
            },
            'i' => {
                k = 1;
                const v: i32 = @bitCast(try std.fmt.parseInt(u32, arg, 16));
                _ = R.snprintf(&out, 1024, f, .{v});
                got = hexOf(spanI8(&out), &gotb);
            },
            'l' => {
                k = 2;
                const v: i64 = @bitCast(try std.fmt.parseInt(u64, arg, 16));
                _ = R.snprintf(&out, 1024, f, .{v});
                got = hexOf(spanI8(&out), &gotb);
            },
            's' => {
                k = 3;
                const sv = cstr(unhex(arg, &argb), &sbuf);
                _ = R.snprintf(&out, 1024, f, .{sv});
                got = hexOf(spanI8(&out), &gotb);
            },
            'd' => {
                k = 4;
                const sv = cstr(unhex(arg, &argb), &sbuf);
                var end: [*c]i8 = null;
                const v = R.strtod(sv, &end);
                got = try std.fmt.bufPrint(&gotb, "{x:0>16}:{d}", .{ @as(u64, @bitCast(v)), @intFromPtr(end) - @intFromPtr(sv) });
            },
            'n' => {
                k = 5;
                const sv = cstr(unhex(arg, &argb), &sbuf);
                var i_1: i32 = -77;
                var d_1: f64 = -77.0;
                var b: [32]i8 = [_]i8{0} ** 32;
                b[0] = '?';
                const n = R.sscanf(sv, R.s("%d %lf %s"), .{ &i_1, &d_1, @as([*c]i8, &b) });
                var hb: [80]u8 = undefined;
                got = try std.fmt.bufPrint(&gotb, "{d}:{d}:{x:0>16}:{s}", .{ n, i_1, @as(u64, @bitCast(d_1)), hexOf(spanI8(&b), &hb) });
            },
            else => continue,
        }
        total[k] += 1;
        if (!std.mem.eql(u8, got, want)) {
            bad[k] += 1;
            if (shown < 25) {
                shown += 1;
                std.debug.print("  {s} {s} arg={s}  glibc={s}  zig={s}\n", .{ kind, fm, arg, want, got });
            }
        }
    }
    var nb: usize = 0;
    var nt: usize = 0;
    for (0..6) |k| {
        std.debug.print("{s}: {d} cases, {d} differ\n", .{ names[k], total[k], bad[k] });
        nb += bad[k];
        nt += total[k];
    }
    std.debug.print("{d} of {d} cases differ\n", .{ nb, nt });
}
