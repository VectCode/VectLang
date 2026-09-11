const std = @import("std");
const E = @import("engine.zig");

// vectc native CLI — thin driver over the shared engine.
// All OS interaction lives here; engine.zig never touches it directly.

var nio: std.Io = undefined;
var nalloc: std.mem.Allocator = undefined;
var nfiles: std.ArrayList(?std.Io.File) = .empty;

fn nOut(bytes: []const u8) void {
    std.Io.File.stdout().writeStreamingAll(nio, bytes) catch {};
}

fn nFatal(msg: []const u8) void {
    std.debug.print("{s}", .{msg});
    std.process.exit(1);
}

fn nStdin(buf: []u8) usize {
    const r = std.Io.File.stdin().readStreaming(nio, &[_][]u8{buf}) catch return 0;
    return r;
}

fn nOpenRead(alloc: std.mem.Allocator, path: []const u8) E.FsErr!usize {
    _ = alloc;
    const fh = std.Io.Dir.cwd().openFile(nio, path, .{ .mode = .read_only }) catch return E.FsErr.NotFound;
    const id = nfiles.items.len;
    nfiles.append(nalloc, fh) catch return E.FsErr.IoFail;
    return id;
}

fn nOpenWrite(alloc: std.mem.Allocator, path: []const u8) E.FsErr!usize {
    _ = alloc;
    const fh = std.Io.Dir.cwd().createFile(nio, path, .{}) catch return E.FsErr.Denied;
    const id = nfiles.items.len;
    nfiles.append(nalloc, fh) catch return E.FsErr.IoFail;
    return id;
}

fn nRead(id: usize, buf: []u8) E.FsErr!usize {
    if (id >= nfiles.items.len or nfiles.items[id] == null) return E.FsErr.IoFail;
    const r = nfiles.items[id].?.readStreaming(nio, &[_][]u8{buf}) catch |e| {
        if (e == error.EndOfStream) return 0;
        return E.FsErr.IoFail;
    };
    return r;
}

fn nWrite(id: usize, bytes: []const u8) E.FsErr!void {
    if (id >= nfiles.items.len or nfiles.items[id] == null) return E.FsErr.IoFail;
    nfiles.items[id].?.writeStreamingAll(nio, bytes) catch return E.FsErr.IoFail;
}

fn nClose(id: usize) void {
    if (id < nfiles.items.len) {
        if (nfiles.items[id]) |fh| {
            fh.close(nio);
            nfiles.items[id] = null;
        }
    }
}

fn nReadAll(alloc: std.mem.Allocator, path: []const u8, limit: usize) E.FsErr![]u8 {
    const data = std.Io.Dir.cwd().readFileAlloc(nio, path, alloc, .limited(limit)) catch |e| {
        if (e == error.FileNotFound) return E.FsErr.NotFound;
        if (e == error.StreamTooLong) return E.FsErr.TooBig;
        return E.FsErr.IoFail;
    };
    return data;
}

const nfs = E.FsOps{
    .open_read = &nOpenRead,
    .open_write = &nOpenWrite,
    .read = &nRead,
    .write = &nWrite,
    .close = &nClose,
    .read_all = &nReadAll,
};

pub fn main(init: std.process.Init) !void {
    const alloc = init.arena.allocator();
    nio = init.io;
    nalloc = alloc;
    E.out_hook = &nOut;
    E.fatal_hook = &nFatal;
    E.stdin_hook = &nStdin;
    E.fs_hook = &nfs;

    const args = try init.minimal.args.toSlice(alloc);
    var dump = false;
    var path: []const u8 = "";
    for (args[1..]) |a| {
        if (std.mem.eql(u8, a, "--dump")) dump = true else if (std.mem.eql(u8, a, "--version")) {
            nOut("vectc 0.2.4\n");
            return;
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            nOut(
                \\Usage: vectc [--dump | --version | --help] <file.vt>
                \\
                \\  vectc program.vt    compile to bytecode and run on the VM
                \\  vectc --dump f.vt   print disassembled chunks, don't run
                \\  vectc --version     print version
                \\
                \\Docs: https://vect-7v7s.onrender.com/docs.html
                \\
            );
            return;
        } else path = a;
    }
    if (path.len == 0) {
        nOut("Usage: vectc [--dump] <file.vt>\n");
        std.process.exit(2);
    }

    const lines = try E.buildLines(alloc, nio, path);
    var prog = E.Program{
        .chunks = .empty,
        .func_index = std.StringHashMap(usize).init(alloc),
        .consts = .empty,
    };
    try E.Compiler.compileProgram(alloc, lines, &prog);

    if (dump) {
        E.dumpProg(&prog);
        return;
    }

    const top = prog.func_index.get("__top") orelse E.fail(1, "No code", .{});
    var vm = E.Vm{
        .alloc = alloc,
        .io = nio,
        .prog = &prog,
        .arrays = .empty,
        .kvs = .empty,
    };
    vm.t0 = std.Io.Clock.Timestamp.now(nio, .boot);
    try vm.run(top);
}
