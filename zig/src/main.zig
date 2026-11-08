//! main.zig - command-line runner for the Zig port of EPA SWMM 5.2.4: the same arguments, console messages
//! and exit status (always 0) as EPA's run/main.c.   runswmm <input file> <report file> [output file]
//! Written by Claude (Anthropic) for Robert Dickinson; see zig/README.md.
const std = @import("std");
const R = @import("rt.zig");
const S = @import("swmm5.zig");

fn eql(a: [*:0]const u8, b: []const u8) bool {
    return std.mem.eql(u8, std.mem.span(a), b);
}

pub fn main() u8 {
    const argv = std.os.argv;
    const version = S.swmm_getVersion();
    const vMajor = @divTrunc(version, 10000);
    const vMinor = @divTrunc(version - 10000 * vMajor, 1000);
    const vRelease = version - 10000 * vMajor - 1000 * vMinor;
    const start = R.time(null);
    var buf: [512]u8 = undefined;
    if (argv.len == 1) {
        R.conout("\nNot Enough Arguments (See Help --help)\n\n");
    } else if (argv.len == 2) {
        const a = argv[1];
        if (eql(a, "--help") or eql(a, "-h")) {
            R.conout("\n\nSTORMWATER MANAGEMENT MODEL (SWMM) HELP\n\nCOMMANDS:\n\t--help (-h)       SWMM Help\n" ++
                "\t--version (-v)    Build Version\n\nRUNNING A SIMULATION:\n" ++
                "\t runswmm <input file> <report file> <optional output file>\n\n");
        } else if (eql(a, "--version") or eql(a, "-v")) {
            R.conout(R.bprintf(&buf, "\n%d.%d.%0d\n\n", .{ vMajor, vMinor, vRelease }));
        } else {
            R.conout("\nUnknown Argument (See Help --help)\n\n");
        }
    } else {
        var blank = [_]i8{0};
        const inp: [*c]i8 = @ptrCast(argv[1]);
        const rpt: [*c]i8 = @ptrCast(argv[2]);
        const out: [*c]i8 = if (argv.len > 3) @ptrCast(argv[3]) else &blank;
        R.conout(R.bprintf(&buf, "\n... EPA SWMM %d.%d (Build %d.%d.%0d)\n", .{ vMajor, vMinor, vMajor, vMinor, vRelease }));
        _ = S.swmm_run(inp, rpt, out);
        const runTime = R.difftime(R.time(null), start);
        var msg = R.bprintf(&buf, "\n\n... EPA SWMM completed in %.2f seconds.", .{runTime});
        var errMsg: [128]i8 = undefined;
        const tail = if (S.swmm_getError(&errMsg, 127) > 0) " There are errors.\n" else if (S.swmm_getWarnings() > 0) " There are warnings.\n" else "\n";
        @memcpy(buf[msg.len .. msg.len + tail.len], tail);
        msg = buf[0 .. msg.len + tail.len];
        R.conout(msg);
    }
    _ = R.fflush(R.stdout);
    return 0;
}
