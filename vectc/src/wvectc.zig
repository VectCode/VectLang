const std = @import("std");
const E = @import("engine.zig");

// wvectc — Vect compiler + VM as WebAssembly (freestanding).
// JS protocol: write UTF-8 source/stdin into the exported buffers,
// call wv_run(), read output bytes. Vect errors trap after appending
// their message to the output buffer, so JS try/catch still shows them.

extern fn vectc_now_ms() u64;

// Freestanding entry point (intentionally empty: the host drives us
// entirely through the wv_* exports, never through program startup).
export fn _start() void {}

var arena_buf: [4 * 1024 * 1024]u8 = undefined;
var src_buf: [256 * 1024]u8 = undefined;
var src_len: usize = 0;
var stdin_buf: [64 * 1024]u8 = undefined;
var stdin_len: usize = 0;
var stdin_pos: usize = 0;
var out_buf: [256 * 1024]u8 = undefined;
var out_len: usize = 0;
var walloc: std.mem.Allocator = undefined;
var wfiles: std.ArrayList(?WFile) = .empty;
var wfs: std.StringHashMap(std.ArrayList(u8)) = undefined;

const WFile = struct {
    name: []const u8,
    pos: usize = 0,
};

const mvga_src =
    \\cmt MVGA standard helper header
    \\vectfn vgaver
    \\    v0
    \\    rtn v
    \\
;

fn wOut(b: []const u8) void {
    const t = @min(b.len, out_buf.len - out_len);
    @memcpy(out_buf[out_len..][0..t], b[0..t]);
    out_len += t;
}

fn wFatal(msg: []const u8) void {
    wOut(msg);
}

fn wClock() u64 {
    return vectc_now_ms();
}

fn wStdin(buf: []u8) usize {
    var n: usize = 0;
    while (stdin_pos < stdin_len and n < buf.len) {
        buf[n] = stdin_buf[stdin_pos];
        stdin_pos += 1;
        n += 1;
    }
    return n;
}

fn wOpenRead(alloc: std.mem.Allocator, path: []const u8) E.FsErr!usize {
    _ = alloc;
    if (!wfs.contains(path)) return E.FsErr.NotFound;
    const name = walloc.dupe(u8, path) catch return E.FsErr.IoFail;
    const id = wfiles.items.len;
    wfiles.append(walloc, WFile{ .name = name }) catch return E.FsErr.IoFail;
    return id;
}

fn wOpenWrite(alloc: std.mem.Allocator, path: []const u8) E.FsErr!usize {
    _ = alloc;
    const name = walloc.dupe(u8, path) catch return E.FsErr.IoFail;
    const entry: std.ArrayList(u8) = .empty;
    wfs.put(name, entry) catch return E.FsErr.IoFail;
    const id = wfiles.items.len;
    wfiles.append(walloc, WFile{ .name = name }) catch return E.FsErr.IoFail;
    return id;
}

fn wRead(id: usize, buf: []u8) E.FsErr!usize {
    if (id >= wfiles.items.len or wfiles.items[id] == null) return E.FsErr.IoFail;
    const w = &wfiles.items[id].?;
    const entry = wfs.get(w.name) orelse return E.FsErr.IoFail;
    if (w.pos >= entry.items.len) return 0;
    const n = @min(buf.len, entry.items.len - w.pos);
    @memcpy(buf[0..n], entry.items[w.pos .. w.pos + n]);
    w.pos += n;
    return n;
}

fn wWrite(id: usize, bytes: []const u8) E.FsErr!void {
    if (id >= wfiles.items.len or wfiles.items[id] == null) return E.FsErr.IoFail;
    const entry = wfs.getPtr(wfiles.items[id].?.name) orelse return E.FsErr.IoFail;
    entry.appendSlice(walloc, bytes) catch return E.FsErr.IoFail;
}

fn wClose(id: usize) void {
    if (id < wfiles.items.len) wfiles.items[id] = null;
}

fn wReadAll(alloc: std.mem.Allocator, path: []const u8, limit: usize) E.FsErr![]u8 {
    _ = alloc;
    const entry = wfs.get(path) orelse return E.FsErr.NotFound;
    if (entry.items.len > limit) return E.FsErr.TooBig;
    return entry.items;
}

const wfsops = E.FsOps{
    .open_read = &wOpenRead,
    .open_write = &wOpenWrite,
    .read = &wRead,
    .write = &wWrite,
    .close = &wClose,
    .read_all = &wReadAll,
};

fn oom() noreturn {
    wOut("[Vect Runtime Error]: out of memory\n[Vect Execution Terminated]\n");
    unreachable;
}

export fn wv_src_ptr() usize {
    return @intFromPtr(&src_buf);
}

export fn wv_src_cap() usize {
    return src_buf.len;
}

export fn wv_src_len_set(n: usize) void {
    src_len = @min(n, src_buf.len);
}

export fn wv_stdin_ptr() usize {
    return @intFromPtr(&stdin_buf);
}

export fn wv_stdin_cap() usize {
    return stdin_buf.len;
}

export fn wv_stdin_len_set(n: usize) void {
    stdin_len = @min(n, stdin_buf.len);
}

export fn wv_out_ptr() usize {
    return @intFromPtr(&out_buf);
}

export fn wv_out_len() usize {
    return out_len;
}

export fn wv_selftest() void {
    wOut("A");
    E.fatal_hook = &wFatal;
    E.out_hook = &wOut;
    wOut("B");
    E.fail(99, "SELFTEST", .{});
}

export fn wv_selftest2() void {
    E.out_hook = &wOut;
    var fb: [64]u8 = undefined;
    const s = std.fmt.bufPrint(&fb, "num={d}", .{@as(i32, 42)}) catch "FMT-ERR";
    wOut(s);
}

export fn wv_selftest3() void {
    E.out_hook = &wOut;
    E.fail_file = "GLOB";
    wOut(E.fail_file);
}

export fn wv_selftest4() void {
    E.out_hook = &wOut;
    E.fatal_hook = &wFatal;
    E.fail(99, "SELFTEST", .{});
}

export fn wv_selftest9() void {
    E.out_hook = &wOut;
    E.fatal_hook = &wFatal;
    if (E.fatal_hook) |h| h("HOOKCALL");
    wOut("AFTER");
}

fn wself_combo(lineno: usize, comptime fmt: []const u8, args: anytype) void {
    var fb: [2048]u8 = undefined;
    const fb0: []u8 = &[_]u8{};
    var n: usize = 0;
    n += (std.fmt.bufPrint(fb[n..], "[Vect Runtime Error]: ", .{}) catch fb0).len;
    n += (std.fmt.bufPrint(fb[n..], fmt, args) catch fb0).len;
    n += (std.fmt.bufPrint(fb[n..], " at line {d}", .{lineno}) catch fb0).len;
    if (E.fatal_hook) |h| h(fb[0..n]);
}

export fn wv_selftest10() void {
    E.out_hook = &wOut;
    E.fatal_hook = &wFatal;
    wself_combo(99, "SELFTEST", .{});
    wOut("AFTER-COMBO");
}

fn wself_nr(lineno: usize, comptime fmt: []const u8, args: anytype) noreturn {
    wself_combo(lineno, fmt, args);
    unreachable;
}

export fn wv_selftest11() void {
    E.out_hook = &wOut;
    E.fatal_hook = &wFatal;
    wself_nr(99, "SELFTEST", .{});
}

fn wself_tup(lineno: usize, comptime fmt: []const u8, args: anytype) void {
    var fb: [2048]u8 = undefined;
    const fb0: []u8 = &[_]u8{};
    const msg = std.fmt.bufPrint(&fb, "E: " ++ fmt ++ " at {d}", args ++ .{lineno}) catch fb0;
    wOut(msg);
}

export fn wv_selftest12() void {
    E.out_hook = &wOut;
    wself_tup(99, "SELFTEST", .{});
}

fn wself_ef(lineno: usize, comptime fmt: []const u8, args: anytype) noreturn {
    var fb: [2048]u8 = undefined;
    const fb0: []u8 = &[_]u8{};
    if (E.fail_file.len > 0) {
        const msg = std.fmt.bufPrint(&fb, "[Vect Runtime Error]: " ++ fmt ++ " at line {d} ({s})\n[Vect Execution Terminated]\n", args ++ .{ lineno, E.fail_file }) catch fb0;
        if (E.fatal_hook) |h| h(msg);
    } else {
        const msg = std.fmt.bufPrint(&fb, "[Vect Runtime Error]: " ++ fmt ++ " at line {d}\n[Vect Execution Terminated]\n", args ++ .{lineno}) catch fb0;
        if (E.fatal_hook) |h| h(msg);
    }
    unreachable;
}

export fn wv_selftest13() void {
    E.out_hook = &wOut;
    E.fatal_hook = &wFatal;
    E.fail_file = "";
    wself_ef(99, "SELFTEST", .{});
}

export fn wv_selftest5() void {
    E.out_hook = &wOut;
    var fb: [2048]u8 = undefined;
    const s = std.fmt.bufPrint(&fb, "SELFTEST-{d}", .{@as(i32, 99)}) catch "ERR";
    wOut(s);
}

fn wself_fail(lineno: usize, comptime fmt: []const u8, args: anytype) noreturn {
    var fb: [2048]u8 = undefined;
    var n: usize = 0;
    n += (std.fmt.bufPrint(fb[n..], "[Vect Runtime Error]: ", .{}) catch unreachable).len;
    n += (std.fmt.bufPrint(fb[n..], fmt, args) catch unreachable).len;
    n += (std.fmt.bufPrint(fb[n..], " at line {d}", .{lineno}) catch unreachable).len;
    n += (std.fmt.bufPrint(fb[n..], "\n[Vect Execution Terminated]\n", .{}) catch unreachable).len;
    wOut(fb[0..n]);
    unreachable;
}

export fn wv_selftest6() void {
    E.out_hook = &wOut;
    wself_fail(99, "SELFTEST", .{});
}

fn wself_one(lineno: usize, comptime fmt: []const u8, args: anytype) void {
    var fb: [128]u8 = undefined;
    const s = std.fmt.bufPrint(&fb, fmt, args) catch "ERR";
    _ = lineno;
    wOut(s);
}

export fn wv_selftest7() void {
    E.out_hook = &wOut;
    wself_one(99, "SELFTEST", .{});
}

fn wself_multi(lineno: usize, comptime fmt: []const u8, args: anytype) void {
    var fb: [2048]u8 = undefined;
    const fb0: []u8 = &[_]u8{};
    var n: usize = 0;
    n += (std.fmt.bufPrint(fb[n..], "[Vect Runtime Error]: ", .{}) catch fb0).len;
    n += (std.fmt.bufPrint(fb[n..], fmt, args) catch fb0).len;
    n += (std.fmt.bufPrint(fb[n..], " at line {d}", .{lineno}) catch fb0).len;
    wOut(fb[0..n]);
}

export fn wv_selftest8() void {
    E.out_hook = &wOut;
    wself_multi(99, "SELFTEST", .{});
}

export fn wv_run() void {
    var fba = std.heap.FixedBufferAllocator.init(&arena_buf);
    const alloc = fba.allocator();
    walloc = alloc;
    out_len = 0;
    stdin_pos = 0;
    wfiles = .empty;
    wfs = std.StringHashMap(std.ArrayList(u8)).init(alloc);
    E.out_hook = &wOut;
    E.fatal_hook = &wFatal;
    E.clock_hook = &wClock;
    E.stdin_hook = &wStdin;
    E.fs_hook = &wfsops;
    E.fail_file = "";
    // preload the standard header library
    var mv: std.ArrayList(u8) = .empty;
    mv.appendSlice(alloc, mvga_src) catch oom();
    wfs.put("mvga.vth", mv) catch oom();
    // parse main source
    var lines: std.ArrayList(E.Line) = .empty;
    E.parseInto(&lines, alloc, src_buf[0..src_len], "play.vt", "", false) catch oom();
    // resolve .vth includes from the memory filesystem
    var loaded: std.ArrayList([]const u8) = .empty;
    var scan: usize = 0;
    var guard: usize = 0;
    while (scan < lines.items.len) : (scan += 1) {
        guard += 1;
        if (guard > 50000) E.fail(1, "Include loop", .{});
        const ln = lines.items[scan];
        if (!std.mem.endsWith(u8, ln.text, ".vth")) continue;
        var seen = false;
        for (loaded.items) |l| {
            if (std.mem.eql(u8, l, ln.text)) {
                seen = true;
                break;
            }
        }
        if (seen) continue;
        const dup = alloc.dupe(u8, ln.text) catch oom();
        loaded.append(alloc, dup) catch oom();
        const entry = wfs.get(ln.text) orelse E.fail(ln.lineno, "Cannot open header '{s}'", .{ln.text});
        E.parseInto(&lines, alloc, entry.items, ln.text, "", true) catch oom();
    }
    const ls = lines.toOwnedSlice(alloc) catch oom();
    var prog = E.Program{
        .chunks = .empty,
        .func_index = std.StringHashMap(usize).init(alloc),
        .consts = .empty,
    };
    E.Compiler.compileProgram(alloc, ls, &prog) catch oom();
    const top = prog.func_index.get("__top") orelse E.fail(1, "No code", .{});
    var vm = E.Vm{
        .alloc = alloc,
        .io = undefined,
        .prog = &prog,
        .arrays = .empty,
        .kvs = .empty,
    };
    vm.run(top) catch oom();
}
