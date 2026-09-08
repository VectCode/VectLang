const std = @import("std");

// vectc v0.2 — Vect (.vt) bytecode compiler + stack VM, written in Zig.
//
// Pipeline: .vt source -> Lines -> Program (chunks of Instr) -> VM.
// Usage: vectc <file.vt> | vectc --dump <file.vt>

fn fail(lineno: usize, comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("[Vect Runtime Error]: ", .{});
    std.debug.print(fmt, args);
    std.debug.print(" at line {d}\n[Vect Execution Terminated]\n", .{lineno});
    std.process.exit(1);
}

// ---------------- frontend ----------------

const Line = struct {
    text: []const u8, // stripped of indent + cmt comment
    level: i32,
    lineno: usize,
    file: []const u8 = "",
    dir: []const u8 = "",
};

fn isIdent(s: []const u8) bool {
    if (s.len == 0) return false;
    if (!(std.ascii.isAlphabetic(s[0]) or s[0] == '_')) return false;
    for (s[1..]) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    }
    return true;
}

// i64 -> decimal slice (no allocation). Handles minInt exactly.
fn intStr(buf: *[32]u8, v: i64) []const u8 {
    var neg = false;
    var n: u64 = undefined;
    if (v < 0) {
        neg = true;
        n = ~@as(u64, @bitCast(v)) + 1;
    } else {
        n = @intCast(v);
    }
    var i: usize = 32;
    if (n == 0) {
        i -= 1;
        buf[i] = '0';
    } else {
        while (n > 0) {
            i -= 1;
            buf[i] = @intCast((n % 10) + '0');
            n /= 10;
        }
    }
    if (neg) {
        i -= 1;
        buf[i] = '-';
    }
    return buf[i..];
}

fn stripComment(s: []const u8) []const u8 {
    var in_str = false;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '"') {
            in_str = !in_str;
            i += 1;
            continue;
        }
        if (!in_str and i + 3 <= s.len and std.mem.eql(u8, s[i .. i + 3], "cmt")) {
            const before_ok = (i == 0) or (s[i - 1] == ' ' or s[i - 1] == '\t');
            const after_ok = (i + 3 >= s.len) or (s[i + 3] == ' ' or s[i + 3] == '\t');
            if (before_ok and after_ok) return std.mem.trim(u8, s[0..i], " \t\r");
        }
        i += 1;
    }
    return s;
}

fn isIntLit(s: []const u8) bool {
    const t = std.mem.trim(u8, s, " \t");
    if (t.len == 0) return false;
    var k: usize = 0;
    if (t[0] == '-') {
        if (t.len == 1) return false;
        k = 1;
    }
    for (t[k..]) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}

// ---------------- bytecode ----------------

const Op = enum(u8) {
    push_int, // a = value
    push_str, // a = const pool idx
    load, // a = slot
    store, // a = slot
    pop,
    add,
    sub,
    mul,
    div,
    mod,
    eq,
    ne,
    lt,
    le,
    gt,
    ge,
    and_,
    or_,
    xor_,
    shl,
    shr,
    bitnot,
    sqrt,
    newarr, // a = slot ; pops size
    arrget, // a = dst slot, b = arr slot ; pops idx
    arrset, // a = arr slot ; pops idx, then val
    echo, // pops 1
    echow, // pops ms, then val
    input, // a = slot
    vga, // pops mode string
    pout, // pops port, then val (noop)
    jmp, // a = target ip
    jmp_false, // a = target ip ; pops cond
    fopen, // a = dst slot ; pops mode, then path
    fread, // a = dst slot, b = fh slot ; pops nbytes
    fwrite, // a = fh slot ; pops value
    fclose, // a = fh slot
    call, // a = func idx ; pops arity args, pushes return val
    ret, // pops 1 as return value
    halt,
};

const Instr = struct {
    op: Op,
    a: i64 = 0,
    b: i64 = 0,
    line: u32 = 0,
};

const Chunk = struct {
    name: []const u8,
    code: std.ArrayList(Instr),
    arity: u8,
    nslots: u32,
};

const FuncInfo = struct {
    chunk_idx: usize,
    params: [][]const u8,
    body_start: usize,
    body_end: usize, // inclusive; start > end == empty
};

const Program = struct {
    chunks: std.ArrayList(Chunk),
    func_index: std.StringHashMap(usize),
    consts: std.ArrayList([]const u8),
};

// ---------------- compiler ----------------

const Compiler = struct {
    alloc: std.mem.Allocator,
    lines: []Line,
    prog: *Program,

    // per-function state
    chunk_idx: usize = 0,
    vars: std.StringHashMap(u32) = undefined,
    next_slot: u32 = 0,

    fn emit(self: *Compiler, op: Op, a: i64, b: i64, lineno: usize) error{OutOfMemory}!usize {
        const ch = &self.prog.chunks.items[self.chunk_idx];
        const pos = ch.code.items.len;
        try ch.code.append(self.alloc, Instr{ .op = op, .a = a, .b = b, .line = @intCast(lineno) });
        return pos;
    }

    fn intern(self: *Compiler, s: []const u8) error{OutOfMemory}!u32 {
        const idx = self.prog.consts.items.len;
        try self.prog.consts.append(self.alloc, s);
        return @intCast(idx);
    }

    fn slotOf(self: *Compiler, name: []const u8, lineno: usize) error{OutOfMemory}!u32 {
        if (self.vars.get(name)) |s| return s;
        const s = self.next_slot;
        self.next_slot += 1;
        try self.vars.put(name, s);
        _ = lineno;
        return s;
    }

    fn needSlot(self: *Compiler, name: []const u8, lineno: usize) error{OutOfMemory}!u32 {
        if (self.vars.get(name)) |s| return s;
        fail(lineno, "Undefined variable '{s}'", .{name});
    }

    fn tempSlot(self: *Compiler) u32 {
        const s = self.next_slot;
        self.next_slot += 1;
        return s;
    }

    fn splitParts(self: *Compiler, s: []const u8, delim: u8) error{OutOfMemory}![][]const u8 {
        var n: usize = 1;
        for (s) |c| {
            if (c == delim) n += 1;
        }
        const out = try self.alloc.alloc([]const u8, n);
        var it = std.mem.splitScalar(u8, s, delim);
        var k: usize = 0;
        while (it.next()) |p| : (k += 1) {
            out[k] = std.mem.trim(u8, p, " \t");
        }
        return out[0..k];
    }

    fn blockEnd(self: *Compiler, idx: usize) usize {
        const l = self.lines[idx].level;
        var j = idx + 1;
        while (j < self.lines.len and self.lines[j].level > l) : (j += 1) {}
        return j - 1;
    }

    // --- expressions: leave one value on the stack ---

    fn compileOperand(self: *Compiler, s: []const u8, lineno: usize) error{OutOfMemory}!void {
        const t = std.mem.trim(u8, s, " \t");
        if (t.len == 0) fail(lineno, "Empty expression", .{});
        if (t.len >= 2 and t[0] == '"' and t[t.len - 1] == '"') {
            const c = try self.intern(t[1 .. t.len - 1]);
            _ = try self.emit(.push_str, c, 0, lineno);
            return;
        }
        if (std.mem.eql(u8, t, "true")) {
            _ = try self.emit(.push_int, 1, 0, lineno);
            return;
        }
        if (std.mem.eql(u8, t, "false")) {
            _ = try self.emit(.push_int, 0, 0, lineno);
            return;
        }
        if (isIntLit(t)) {
            const v = std.fmt.parseInt(i64, t, 10) catch fail(lineno, "Bad number '{s}'", .{t});
            _ = try self.emit(.push_int, v, 0, lineno);
            return;
        }
        const sl = try self.needSlot(t, lineno);
        _ = try self.emit(.load, sl, 0, lineno);
    }

    fn compileCond(self: *Compiler, s: []const u8, lineno: usize) error{OutOfMemory}!void {
        const t = std.mem.trim(u8, s, " \t");
        if (std.mem.eql(u8, t, "true")) {
            _ = try self.emit(.push_int, 1, 0, lineno);
            return;
        }
        if (std.mem.eql(u8, t, "false")) {
            _ = try self.emit(.push_int, 0, 0, lineno);
            return;
        }
        const ops = [_][]const u8{ "==", "!=", "<=", ">=", "<", ">" };
        for (ops) |op| {
            if (std.mem.indexOf(u8, t, op)) |pos| {
                try self.compileOperand(t[0..pos], lineno);
                try self.compileOperand(t[pos + op.len ..], lineno);
                const o: Op = if (std.mem.eql(u8, op, "==")) .eq else if (std.mem.eql(u8, op, "!=")) .ne else if (std.mem.eql(u8, op, "<=")) .le else if (std.mem.eql(u8, op, ">=")) .ge else if (std.mem.eql(u8, op, "<")) .lt else .gt;
                _ = try self.emit(o, 0, 0, lineno);
                return;
            }
        }
        try self.compileOperand(t, lineno); // nonzero == true
    }

    fn compileTargetRest(self: *Compiler, target: []const u8, rest: []const u8, lineno: usize) error{OutOfMemory}!void {
        const dst = try self.slotOf(target, lineno);
        const r = std.mem.trim(u8, rest, " \t");
        if (std.mem.startsWith(u8, r, "sqrt.")) {
            try self.compileOperand(r["sqrt.".len..], lineno);
            _ = try self.emit(.sqrt, 0, 0, lineno);
            _ = try self.emit(.store, dst, 0, lineno);
            return;
        }
        if (std.mem.startsWith(u8, r, "bit shl")) {
            const parts = try self.splitParts(std.mem.trim(u8, r[7..], " \t"), ',');
            if (parts.len != 2) fail(lineno, "bit shl needs 'val, n'", .{});
            try self.compileOperand(parts[0], lineno);
            try self.compileOperand(parts[1], lineno);
            _ = try self.emit(.shl, 0, 0, lineno);
            _ = try self.emit(.store, dst, 0, lineno);
            return;
        }
        if (std.mem.startsWith(u8, r, "bit shr")) {
            const parts = try self.splitParts(std.mem.trim(u8, r[7..], " \t"), ',');
            if (parts.len != 2) fail(lineno, "bit shr needs 'val, n'", .{});
            try self.compileOperand(parts[0], lineno);
            try self.compileOperand(parts[1], lineno);
            _ = try self.emit(.shr, 0, 0, lineno);
            _ = try self.emit(.store, dst, 0, lineno);
            return;
        }
        if (std.mem.startsWith(u8, r, "bit not")) {
            try self.compileOperand(std.mem.trim(u8, r[7..], " \t"), lineno);
            _ = try self.emit(.bitnot, 0, 0, lineno);
            _ = try self.emit(.store, dst, 0, lineno);
            return;
        }
        if (std.mem.startsWith(u8, r, "fread ") or std.mem.startsWith(u8, r, "fread\t")) {
            const parts = try self.splitParts(std.mem.trim(u8, r[5..], " \t"), ',');
            if (parts.len != 2) fail(lineno, "fread needs 'fh, n'", .{});
            const fh = try self.needSlot(parts[0], lineno);
            try self.compileOperand(parts[1], lineno);
            _ = try self.emit(.fread, dst, fh, lineno);
            return;
        }
        if (std.mem.startsWith(u8, r, "get ") or std.mem.startsWith(u8, r, "get\t")) {
            const parts = try self.splitParts(std.mem.trim(u8, r[3..], " \t"), ',');
            if (parts.len != 2) fail(lineno, "get needs 'arr, idx'", .{});
            const arr = try self.needSlot(parts[0], lineno);
            try self.compileOperand(parts[1], lineno);
            _ = try self.emit(.arrget, dst, arr, lineno);
            return;
        }
        // AND / OR / XOR word operators: (c.a AND b)
        for ([_][]const u8{ " AND ", " OR ", " XOR " }) |wop| {
            if (std.mem.indexOf(u8, r, wop)) |pos| {
                try self.compileOperand(r[0..pos], lineno);
                try self.compileOperand(r[pos + wop.len ..], lineno);
                const o: Op = if (wop[1] == 'A') .and_ else if (wop[1] == 'O') .or_ else .xor_;
                _ = try self.emit(o, 0, 0, lineno);
                _ = try self.emit(.store, dst, 0, lineno);
                return;
            }
        }
        // function call: first word names a known function
        if (std.mem.indexOfAny(u8, r, " \t")) |sp| {
            if (self.prog.func_index.get(r[0..sp])) |fi| {
                const argparts = try self.splitParts(std.mem.trim(u8, r[sp + 1 ..], " \t"), ',');
                var cnt: usize = 0;
                for (argparts) |a| {
                    if (a.len == 0) continue;
                    try self.compileOperand(a, lineno);
                    cnt += 1;
                }
                const want = self.prog.chunks.items[fi].arity;
                if (cnt != want) fail(lineno, "Function expects {d} args, got {d}", .{ want, cnt });
                _ = try self.emit(.call, @intCast(fi), 0, lineno);
                _ = try self.emit(.store, dst, 0, lineno);
                return;
            }
        }
        // arithmetic: strip spaces, single binary op
        const nospace = try self.alloc.alloc(u8, r.len);
        var m: usize = 0;
        for (r) |c| {
            if (c != ' ' and c != '\t') {
                nospace[m] = c;
                m += 1;
            }
        }
        const e = nospace[0..m];
        var oppos: ?usize = null;
        var opch: u8 = 0;
        var k: usize = 1;
        while (k < e.len) : (k += 1) {
            const c = e[k];
            if (c == '+' or c == '-' or c == '*' or c == '/' or c == '%') {
                oppos = k;
                opch = c;
                break;
            }
        }
        if (oppos) |p| {
            try self.compileOperand(e[0..p], lineno);
            try self.compileOperand(e[p + 1 ..], lineno);
            const o: Op = switch (opch) {
                '+' => .add,
                '-' => .sub,
                '*' => .mul,
                '/' => .div,
                else => .mod,
            };
            _ = try self.emit(o, 0, 0, lineno);
            _ = try self.emit(.store, dst, 0, lineno);
            return;
        }
        try self.compileOperand(r, lineno);
        _ = try self.emit(.store, dst, 0, lineno);
    }

    // --- statements ---

    fn compileBody(self: *Compiler, start: usize, end: usize, level: i32) error{OutOfMemory}!void {
        var i = start;
        while (i <= end and i < self.lines.len) {
            const ln = self.lines[i];
            if (ln.level <= level) break;
            if (ln.level > level + 1) fail(ln.lineno, "Bad indentation", .{});
            i = try self.compileStmt(i);
        }
    }

    fn isHeader(t: []const u8) bool {
        if (std.mem.eql(u8, t, "vt.init") or std.mem.eql(u8, t, "branch") or std.mem.eql(u8, t, "vect")) return true;
        if (std.mem.endsWith(u8, t, ".vth")) return true;
        if (t.len >= 2 and t[0] == '(' and t[t.len - 1] == ')' and std.mem.indexOfScalar(u8, t, '.') == null) return true;
        return false;
    }

    fn compileStmt(self: *Compiler, idx: usize) error{OutOfMemory}!usize {
        const ln = self.lines[idx];
        const t = ln.text;
        const end = self.blockEnd(idx);

        if (isHeader(t)) return idx + 1;

        // vectfn at top level: already compiled from FuncInfo; skip body
        if (std.mem.startsWith(u8, t, "vectfn")) return end + 1;

        if (std.mem.eql(u8, t, "rtn") or std.mem.startsWith(u8, t, "rtn ") or std.mem.startsWith(u8, t, "rtn\t")) {
            const after = if (t.len > 3) std.mem.trim(u8, t[3..], " \t") else "";
            if (after.len == 0) fail(ln.lineno, "rtn needs a value", .{});
            try self.compileOperand(after, ln.lineno);
            _ = try self.emit(.ret, 0, 0, ln.lineno);
            return idx + 1;
        }

        if (std.mem.eql(u8, t, "els")) fail(ln.lineno, "els without if", .{});

        if (std.mem.startsWith(u8, t, "if ") or std.mem.startsWith(u8, t, "if\t")) {
            var cond = std.mem.trim(u8, t[2..], " \t");
            if (std.mem.startsWith(u8, cond, "els ") or std.mem.startsWith(u8, cond, "els\t"))
                cond = std.mem.trim(u8, cond[3..], " \t");
            try self.compileCond(cond, ln.lineno);
            const jfalse = try self.emit(.jmp_false, -1, 0, ln.lineno);
            // true block: following deeper lines; optional same-level 'els' + else block
            var j = idx + 1;
            while (j < self.lines.len and self.lines[j].level > ln.level) : (j += 1) {}
            if (j > idx + 1) try self.compileBody(idx + 1, j - 1, ln.level);
            var done: usize = j;
            if (j < self.lines.len and self.lines[j].level == ln.level and std.mem.eql(u8, self.lines[j].text, "els")) {
                const jover = try self.emit(.jmp, -1, 0, ln.lineno);
                const else_start: i64 = @intCast(self.prog.chunks.items[self.chunk_idx].code.items.len);
                self.prog.chunks.items[self.chunk_idx].code.items[jfalse].a = else_start;
                var k = j + 1;
                while (k < self.lines.len and self.lines[k].level > ln.level) : (k += 1) {}
                if (k > j + 1) try self.compileBody(j + 1, k - 1, ln.level);
                const endpos: i64 = @intCast(self.prog.chunks.items[self.chunk_idx].code.items.len);
                self.prog.chunks.items[self.chunk_idx].code.items[jover].a = endpos;
                done = k;
            } else {
                const endpos: i64 = @intCast(self.prog.chunks.items[self.chunk_idx].code.items.len);
                self.prog.chunks.items[self.chunk_idx].code.items[jfalse].a = endpos;
            }
            return done;
        }

        if (std.mem.startsWith(u8, t, "lo")) {
            var p: usize = 2;
            while (p < t.len and t[p] >= '0' and t[p] <= '9') : (p += 1) {}
            if (p == 2) fail(ln.lineno, "Bad loop '{s}'", .{t});
            const max = std.fmt.parseInt(i64, t[2..p], 10) catch fail(ln.lineno, "Bad loop count '{s}'", .{t});
            const rest = std.mem.trim(u8, t[p..], " \t");
            const cnt = self.tempSlot();
            _ = try self.emit(.push_int, 0, 0, ln.lineno);
            _ = try self.emit(.store, cnt, 0, ln.lineno);
            const loop_top: i64 = @intCast(self.prog.chunks.items[self.chunk_idx].code.items.len);
            if (rest.len > 0) {
                if (!(rest[0] == 'w' and (rest.len == 1 or rest[1] == ' ' or rest[1] == '\t')))
                    fail(ln.lineno, "Bad loop '{s}'", .{t});
                const cond = std.mem.trim(u8, rest[1..], " \t");
                if (cond.len > 0) {
                    try self.compileCond(cond, ln.lineno);
                    const j = try self.emit(.jmp_false, -1, 0, ln.lineno);
                    if (end >= idx + 1) try self.compileBody(idx + 1, end, ln.level);
                    // cnt += 1 ; continue while cnt < max
                    _ = try self.emit(.load, cnt, 0, ln.lineno);
                    _ = try self.emit(.push_int, 1, 0, ln.lineno);
                    _ = try self.emit(.add, 0, 0, ln.lineno);
                    _ = try self.emit(.store, cnt, 0, ln.lineno);
                    _ = try self.emit(.load, cnt, 0, ln.lineno);
                    _ = try self.emit(.push_int, max, 0, ln.lineno);
                    _ = try self.emit(.ge, 0, 0, ln.lineno);
                    _ = try self.emit(.jmp_false, loop_top, 0, ln.lineno);
                    const done: i64 = @intCast(self.prog.chunks.items[self.chunk_idx].code.items.len);
                    self.prog.chunks.items[self.chunk_idx].code.items[j].a = done;
                    return end + 1;
                }
            }
            // fixed loop
            if (end >= idx + 1) try self.compileBody(idx + 1, end, ln.level);
            _ = try self.emit(.load, cnt, 0, ln.lineno);
            _ = try self.emit(.push_int, 1, 0, ln.lineno);
            _ = try self.emit(.add, 0, 0, ln.lineno);
            _ = try self.emit(.store, cnt, 0, ln.lineno);
            _ = try self.emit(.load, cnt, 0, ln.lineno);
            _ = try self.emit(.push_int, max, 0, ln.lineno);
            _ = try self.emit(.ge, 0, 0, ln.lineno);
            _ = try self.emit(.jmp_false, loop_top, 0, ln.lineno);
            return end + 1;
        }

        if (std.mem.startsWith(u8, t, "echow")) {
            const after = std.mem.trim(u8, t["echow".len..], " \t");
            const comma = std.mem.indexOfScalar(u8, after, ',') orelse fail(ln.lineno, "echow needs 'val, ms'", .{});
            try self.compileOperand(std.mem.trim(u8, after[0..comma], " \t"), ln.lineno);
            try self.compileOperand(std.mem.trim(u8, after[comma + 1 ..], " \t"), ln.lineno);
            _ = try self.emit(.echow, 0, 0, ln.lineno);
            if (end != idx) fail(ln.lineno, "Unexpected indented block", .{});
            return idx + 1;
        }

        if (std.mem.eql(u8, t, "echo") or std.mem.startsWith(u8, t, "echo ") or std.mem.startsWith(u8, t, "echo\t")) {
            const after = if (t.len > 4) std.mem.trim(u8, t[4..], " \t") else "";
            if (after.len == 0) {
                const c = try self.intern("");
                _ = try self.emit(.push_str, c, 0, ln.lineno);
            } else {
                try self.compileOperand(after, ln.lineno);
            }
            _ = try self.emit(.echo, 0, 0, ln.lineno);
            if (end != idx) fail(ln.lineno, "Unexpected indented block", .{});
            return idx + 1;
        }

        if (std.mem.startsWith(u8, t, "in")) {
            var name: []const u8 = "";
            const after = std.mem.trim(u8, t[2..], " \t");
            if (std.mem.startsWith(u8, after, "(") and std.mem.endsWith(u8, after, ")")) {
                name = std.mem.trim(u8, after[1 .. after.len - 1], " \t");
            } else {
                name = after;
            }
            if (!isIdent(name)) fail(ln.lineno, "Bad input target '{s}'", .{name});
            const sl = try self.slotOf(name, ln.lineno);
            _ = try self.emit(.input, sl, 0, ln.lineno);
            if (end != idx) fail(ln.lineno, "Unexpected indented block", .{});
            return idx + 1;
        }

        if (std.mem.startsWith(u8, t, "set ") or std.mem.startsWith(u8, t, "set\t")) {
            const parts = try self.splitParts(std.mem.trim(u8, t[3..], " \t"), ',');
            if (parts.len != 3) fail(ln.lineno, "set needs 'arr, idx, val'", .{});
            const arr = try self.needSlot(parts[0], ln.lineno);
            try self.compileOperand(parts[2], ln.lineno); // val
            try self.compileOperand(parts[1], ln.lineno); // idx
            _ = try self.emit(.arrset, arr, 0, ln.lineno);
            if (end != idx) fail(ln.lineno, "Unexpected indented block", .{});
            return idx + 1;
        }

        if (std.mem.startsWith(u8, t, "fopen ") or std.mem.startsWith(u8, t, "fopen\t")) {
            const parts = try self.splitParts(std.mem.trim(u8, t[5..], " \t"), ',');
            if (parts.len != 3) fail(ln.lineno, "fopen needs 'fh, path, mode'", .{});
            if (!isIdent(parts[0])) fail(ln.lineno, "Bad file handle '{s}'", .{parts[0]});
            const dst = try self.slotOf(parts[0], ln.lineno);
            try self.compileOperand(parts[1], ln.lineno); // path
            try self.compileOperand(parts[2], ln.lineno); // mode
            _ = try self.emit(.fopen, dst, 0, ln.lineno);
            if (end != idx) fail(ln.lineno, "Unexpected indented block", .{});
            return idx + 1;
        }

        if (std.mem.startsWith(u8, t, "fwrite ") or std.mem.startsWith(u8, t, "fwrite\t")) {
            const parts = try self.splitParts(std.mem.trim(u8, t[6..], " \t"), ',');
            if (parts.len != 2) fail(ln.lineno, "fwrite needs 'fh, val'", .{});
            const fh = try self.needSlot(parts[0], ln.lineno);
            try self.compileOperand(parts[1], ln.lineno);
            _ = try self.emit(.fwrite, fh, 0, ln.lineno);
            if (end != idx) fail(ln.lineno, "Unexpected indented block", .{});
            return idx + 1;
        }

        if (std.mem.startsWith(u8, t, "fclose ") or std.mem.startsWith(u8, t, "fclose\t") or std.mem.eql(u8, t, "fclose")) {
            const after = if (t.len > 6) std.mem.trim(u8, t[6..], " \t") else "";
            if (after.len == 0) fail(ln.lineno, "fclose needs a handle", .{});
            const fh = try self.needSlot(after, ln.lineno);
            _ = try self.emit(.fclose, fh, 0, ln.lineno);
            if (end != idx) fail(ln.lineno, "Unexpected indented block", .{});
            return idx + 1;
        }

        if (std.mem.startsWith(u8, t, "vga")) {
            const c = try self.intern(t);
            _ = try self.emit(.push_str, c, 0, ln.lineno);
            _ = try self.emit(.vga, 0, 0, ln.lineno);
            if (end != idx) fail(ln.lineno, "Unexpected indented block", .{});
            return idx + 1;
        }

        if (std.mem.startsWith(u8, t, "pout")) {
            // pout(port, val): push val, push port, pout pops both
            const lp = std.mem.indexOfScalar(u8, t, '(') orelse fail(ln.lineno, "Bad pout '{s}'", .{t});
            if (t[t.len - 1] != ')') fail(ln.lineno, "Bad pout '{s}'", .{t});
            const parts = try self.splitParts(t[lp + 1 .. t.len - 1], ',');
            if (parts.len != 2) fail(ln.lineno, "pout needs 'port, val'", .{});
            try self.compileOperand(parts[1], ln.lineno);
            try self.compileOperand(parts[0], ln.lineno);
            _ = try self.emit(.pout, 0, 0, ln.lineno);
            if (end != idx) fail(ln.lineno, "Unexpected indented block", .{});
            return idx + 1;
        }

        if (t.len >= 2 and t[0] == '(' and t[t.len - 1] == ')') {
            const inner = t[1 .. t.len - 1];
            const dot = std.mem.indexOfScalar(u8, inner, '.') orelse fail(ln.lineno, "Bad expression '{s}'", .{t});
            const target = std.mem.trim(u8, inner[0..dot], " \t");
            if (!isIdent(target)) fail(ln.lineno, "Bad target '{s}'", .{target});
            try self.compileTargetRest(target, inner[dot + 1 ..], ln.lineno);
            if (end != idx) fail(ln.lineno, "Unexpected indented block", .{});
            return idx + 1;
        }

        if (std.mem.indexOfScalar(u8, t, '(')) |lp| {
            if (t[t.len - 1] == ')') {
                const name = std.mem.trim(u8, t[0..lp], " \t");
                const inner = std.mem.trim(u8, t[lp + 1 .. t.len - 1], " \t");
                if (!isIdent(name)) fail(ln.lineno, "Bad statement '{s}'", .{t});
                if (self.prog.func_index.get(name)) |fi| {
                    if (inner.len > 0) {
                        const argparts = try self.splitParts(inner, ',');
                        var cnt: usize = 0;
                        for (argparts) |a| {
                            if (a.len == 0) continue;
                            try self.compileOperand(a, ln.lineno);
                            cnt += 1;
                        }
                        const want = self.prog.chunks.items[fi].arity;
                        if (cnt != want) fail(ln.lineno, "Function expects {d} args, got {d}", .{ want, cnt });
                    } else if (self.prog.chunks.items[fi].arity != 0) {
                        fail(ln.lineno, "Function expects {d} args, got 0", .{self.prog.chunks.items[fi].arity});
                    }
                    _ = try self.emit(.call, @intCast(fi), 0, ln.lineno);
                    _ = try self.emit(.pop, 0, 0, ln.lineno); // discard return
                    if (end != idx) fail(ln.lineno, "Unexpected indented block", .{});
                    return idx + 1;
                }
                // array alloc NAME(size)
                const parts = try self.splitParts(inner, ',');
                if (parts.len != 1) fail(ln.lineno, "Unknown call '{s}'", .{name});
                const sl = try self.slotOf(name, ln.lineno);
                try self.compileOperand(parts[0], ln.lineno);
                _ = try self.emit(.newarr, sl, 0, ln.lineno);
                if (end != idx) fail(ln.lineno, "Unexpected indented block", .{});
                return idx + 1;
            }
        }

        if (std.mem.indexOfScalar(u8, t, '"')) |qp| {
            const name = std.mem.trim(u8, t[0..qp], " \t");
            if (isIdent(name) and std.mem.endsWith(u8, t, "\"")) {
                const c = try self.intern(t[qp + 1 .. t.len - 1]);
                const sl = try self.slotOf(name, ln.lineno);
                _ = try self.emit(.push_str, c, 0, ln.lineno);
                _ = try self.emit(.store, sl, 0, ln.lineno);
                if (end != idx) fail(ln.lineno, "Unexpected indented block", .{});
                return idx + 1;
            }
        }

        if (std.mem.indexOfAny(u8, t, " \t\"'(),") == null) {
            var q = t.len;
            while (q > 0 and t[q - 1] >= '0' and t[q - 1] <= '9') : (q -= 1) {}
            if (q < t.len and q > 0 and isIdent(t[0..q])) {
                const v = std.fmt.parseInt(i64, t[q..], 10) catch fail(ln.lineno, "Bad number '{s}'", .{t});
                const sl = try self.slotOf(t[0..q], ln.lineno);
                _ = try self.emit(.push_int, v, 0, ln.lineno);
                _ = try self.emit(.store, sl, 0, ln.lineno);
                if (end != idx) fail(ln.lineno, "Unexpected indented block", .{});
                return idx + 1;
            }
        }

        fail(ln.lineno, "Unknown statement '{s}'", .{t});
    }

    fn compileProgram(alloc: std.mem.Allocator, lines: []Line, prog: *Program) error{OutOfMemory}!void {
        // pass 1: collect vectfn signatures at level 0
        var infos: std.ArrayList(FuncInfo) = .empty;
        defer infos.deinit(alloc);
        for (lines, 0..) |ln, i| {
            if (ln.level != 0 or !std.mem.startsWith(u8, ln.text, "vectfn")) continue;
            const after = std.mem.trim(u8, ln.text["vectfn".len..], " \t");
            var fname: []const u8 = after;
            var params: [][]const u8 = &[_][]const u8{};
            if (std.mem.indexOfScalar(u8, after, '.')) |dp| {
                fname = std.mem.trim(u8, after[0..dp], " \t");
                const plist = std.mem.trim(u8, after[dp + 1 ..], " \t");
                if (plist.len > 0) {
                    var n: usize = 1;
                    for (plist) |c| {
                        if (c == ',') n += 1;
                    }
                    const out = try alloc.alloc([]const u8, n);
                    var it = std.mem.splitScalar(u8, plist, ',');
                    var k: usize = 0;
                    while (it.next()) |pp| : (k += 1) out[k] = std.mem.trim(u8, pp, " \t");
                    params = out[0..k];
                }
            }
            if (!isIdent(fname)) fail(ln.lineno, "Bad function name '{s}'", .{fname});
            for (params) |pp| {
                if (!isIdent(pp)) fail(ln.lineno, "Bad param name '{s}'", .{pp});
            }
            // body range
            var j = i + 1;
            while (j < lines.len and lines[j].level > 0) : (j += 1) {}
            const cidx = prog.chunks.items.len;
            try prog.chunks.append(alloc, Chunk{ .name = fname, .code = .empty, .arity = @intCast(params.len), .nslots = 0 });
            try prog.func_index.put(fname, cidx);
            try infos.append(alloc, FuncInfo{ .chunk_idx = cidx, .params = params, .body_start = i + 1, .body_end = j - 1 });
        }
        // pass 2: compile each body
        for (infos.items) |fi| {
            var cc = Compiler{ .alloc = alloc, .lines = lines, .prog = prog, .chunk_idx = fi.chunk_idx, .vars = std.StringHashMap(u32).init(alloc), .next_slot = 0 };
            for (fi.params, 0..) |pp, k| {
                try cc.vars.put(pp, @intCast(k));
                cc.next_slot = @intCast(k + 1);
            }
            if (fi.body_start <= fi.body_end) {
                const lvl: i32 = lines[fi.body_start].level - 1;
                try cc.compileBody(fi.body_start, fi.body_end, lvl);
            }
            const ch = &prog.chunks.items[fi.chunk_idx];
            try ch.code.append(alloc, Instr{ .op = .push_int, .a = 0, .line = 1 });
            try ch.code.append(alloc, Instr{ .op = .ret, .line = 1 });
            ch.nslots = cc.next_slot;
            cc.vars.deinit();
        }
        // pass 3: implicit __top chunk for top-level statements
        {
            const cidx = prog.chunks.items.len;
            try prog.chunks.append(alloc, Chunk{ .name = "__top", .code = .empty, .arity = 0, .nslots = 0 });
            try prog.func_index.put("__top", cidx);
            var cc = Compiler{ .alloc = alloc, .lines = lines, .prog = prog, .chunk_idx = cidx, .vars = std.StringHashMap(u32).init(alloc), .next_slot = 0 };
            if (lines.len > 0) try cc.compileBody(0, lines.len - 1, -1);
            const ch = &prog.chunks.items[cidx];
            try ch.code.append(alloc, Instr{ .op = .halt, .line = 1 });
            ch.nslots = cc.next_slot;
            cc.vars.deinit();
        }
    }
};

// ---------------- VM ----------------

const VTag = enum { Int, Str, Arr };
const VVal = struct {
    tag: VTag = .Int,
    int: i64 = 0,
    str: []const u8 = "",
    arr: usize = 0,
};

const Frame = struct {
    chunk: *Chunk,
    ip: usize = 0,
    slots: []VVal,
    stack: [512]VVal = undefined,
    sp: usize = 0,
};

const Vm = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    prog: *Program,
    arrays: std.ArrayList([]i64),
    files: std.ArrayList(?std.Io.File),
    frames: [64]Frame = undefined,
    depth: usize = 0,

    fn curLine(self: *Vm) u32 {
        const f = &self.frames[self.depth - 1];
        if (f.ip < f.chunk.code.items.len) return f.chunk.code.items[f.ip].line;
        return 1;
    }

    fn push(self: *Vm, v: VVal) void {
        const f = &self.frames[self.depth - 1];
        if (f.sp >= f.stack.len) fail(self.curLine(), "Stack overflow", .{});
        f.stack[f.sp] = v;
        f.sp += 1;
    }

    fn pop(self: *Vm) VVal {
        const f = &self.frames[self.depth - 1];
        if (f.sp == 0) fail(self.curLine(), "Stack underflow", .{});
        f.sp -= 1;
        return f.stack[f.sp];
    }

    fn popInt(self: *Vm) i64 {
        const v = self.pop();
        switch (v.tag) {
            .Int => return v.int,
            .Str => {
                const st = std.mem.trim(u8, v.str, " \t\r\n");
                if (std.fmt.parseInt(i64, st, 10)) |n| return n else |_| fail(self.curLine(), "Not a number", .{});
            },
            .Arr => fail(self.curLine(), "Array is not a number", .{}),
        }
    }

    fn truthy(v: VVal) bool {
        return switch (v.tag) {
            .Int => v.int != 0,
            .Str => v.str.len != 0,
            .Arr => true,
        };
    }

    fn out(self: *Vm, bytes: []const u8) void {
        std.Io.File.stdout().writeStreamingAll(self.io, bytes) catch {};
    }

    fn outInt(self: *Vm, v: i64) void {
        var buf: [32]u8 = undefined;
        self.out(intStr(&buf, v));
        self.out("\n");
    }

    fn printVal(self: *Vm, v: VVal) void {
        switch (v.tag) {
            .Int => self.outInt(v.int),
            .Str => {
                self.out(v.str);
                self.out("\n");
            },
            .Arr => self.out("[array]\n"),
        }
    }

    fn readLine(self: *Vm, buf: []u8) []u8 {
        var n: usize = 0;
        while (n < buf.len) {
            var b: [1]u8 = undefined;
            const r = std.Io.File.stdin().readStreaming(self.io, &[_][]u8{b[0..]}) catch break;
            if (r == 0 or b[0] == '\n') break;
            buf[n] = b[0];
            n += 1;
        }
        var s = buf[0..n];
        if (s.len > 0 and s[s.len - 1] == '\r') s = s[0 .. s.len - 1];
        return s;
    }

    fn run(self: *Vm, entry: usize) error{OutOfMemory}!void {
        const ech = &self.prog.chunks.items[entry];
        const eslots = try self.alloc.alloc(VVal, @max(ech.nslots, 1));
        for (eslots) |*s| s.* = VVal{};
        self.frames[0] = Frame{ .chunk = ech, .slots = eslots };
        self.depth = 1;
        while (self.depth > 0) {
            const f = &self.frames[self.depth - 1];
            if (f.ip >= f.chunk.code.items.len) fail(self.curLine(), "Fell off chunk '{s}'", .{f.chunk.name});
            const ins = f.chunk.code.items[f.ip];
            f.ip += 1;
            const ln = ins.line;
            switch (ins.op) {
                .push_int => self.push(VVal{ .tag = .Int, .int = ins.a }),
                .push_str => self.push(VVal{ .tag = .Str, .str = self.prog.consts.items[@intCast(ins.a)] }),
                .load => {
                    const s: usize = @intCast(ins.a);
                    if (s >= f.slots.len) fail(ln, "Bad slot {d}", .{s});
                    self.push(f.slots[s]);
                },
                .store => {
                    const s: usize = @intCast(ins.a);
                    if (s >= f.slots.len) fail(ln, "Bad slot {d}", .{s});
                    f.slots[s] = self.pop();
                },
                .pop => _ = self.pop(),
                .add => {
                    const b = self.popInt();
                    const a = self.popInt();
                    self.push(VVal{ .tag = .Int, .int = a + b });
                },
                .sub => {
                    const b = self.popInt();
                    const a = self.popInt();
                    self.push(VVal{ .tag = .Int, .int = a - b });
                },
                .mul => {
                    const b = self.popInt();
                    const a = self.popInt();
                    self.push(VVal{ .tag = .Int, .int = a * b });
                },
                .div => {
                    const b = self.popInt();
                    const a = self.popInt();
                    if (b == 0) fail(ln, "Division by zero", .{});
                    self.push(VVal{ .tag = .Int, .int = @divTrunc(a, b) });
                },
                .mod => {
                    const b = self.popInt();
                    const a = self.popInt();
                    if (b == 0) fail(ln, "Modulo by zero", .{});
                    self.push(VVal{ .tag = .Int, .int = @mod(a, b) });
                },
                .eq, .ne, .lt, .le, .gt, .ge => {
                    const b = self.popInt();
                    const a = self.popInt();
                    const r: i64 = switch (ins.op) {
                        .eq => if (a == b) 1 else 0,
                        .ne => if (a != b) 1 else 0,
                        .lt => if (a < b) 1 else 0,
                        .le => if (a <= b) 1 else 0,
                        .gt => if (a > b) 1 else 0,
                        else => if (a >= b) 1 else 0,
                    };
                    self.push(VVal{ .tag = .Int, .int = r });
                },
                .and_ => {
                    const b = self.popInt();
                    const a = self.popInt();
                    self.push(VVal{ .tag = .Int, .int = a & b });
                },
                .or_ => {
                    const b = self.popInt();
                    const a = self.popInt();
                    self.push(VVal{ .tag = .Int, .int = a | b });
                },
                .xor_ => {
                    const b = self.popInt();
                    const a = self.popInt();
                    self.push(VVal{ .tag = .Int, .int = a ^ b });
                },
                .shl => {
                    const sh = self.popInt() & 63;
                    const base = self.popInt();
                    self.push(VVal{ .tag = .Int, .int = base << @as(u6, @intCast(sh)) });
                },
                .shr => {
                    const sh = self.popInt() & 63;
                    const base = self.popInt();
                    self.push(VVal{ .tag = .Int, .int = base >> @as(u6, @intCast(sh)) });
                },
                .bitnot => {
                    const a = self.popInt();
                    self.push(VVal{ .tag = .Int, .int = ~a });
                },
                .sqrt => {
                    const a = self.popInt();
                    const r: i64 = if (a <= 0) 0 else @intFromFloat(@sqrt(@as(f64, @floatFromInt(a))));
                    self.push(VVal{ .tag = .Int, .int = r });
                },
                .newarr => {
                    const s: usize = @intCast(ins.a);
                    const n = self.popInt();
                    if (n <= 0 or n > 1000000) fail(ln, "Bad array size {d}", .{n});
                    const arr = try self.alloc.alloc(i64, @intCast(n));
                    @memset(arr, 0);
                    const id = self.arrays.items.len;
                    try self.arrays.append(self.alloc, arr);
                    f.slots[s] = VVal{ .tag = .Arr, .arr = id };
                },
                .arrget => {
                    const idx = self.popInt();
                    const arrslot: usize = @intCast(ins.b);
                    const dst: usize = @intCast(ins.a);
                    const av = f.slots[arrslot];
                    if (av.tag != .Arr) fail(ln, "Not an array", .{});
                    const items = self.arrays.items[av.arr];
                    if (idx < 0 or idx >= items.len) fail(ln, "Index {d} out of bounds (len {d})", .{ idx, items.len });
                    f.slots[dst] = VVal{ .tag = .Int, .int = items[@intCast(idx)] };
                },
                .arrset => {
                    const idx = self.popInt();
                    const val = self.popInt();
                    const arrslot: usize = @intCast(ins.a);
                    const av = f.slots[arrslot];
                    if (av.tag != .Arr) fail(ln, "Not an array", .{});
                    const items = self.arrays.items[av.arr];
                    if (idx < 0 or idx >= items.len) fail(ln, "Index {d} out of bounds (len {d})", .{ idx, items.len });
                    items[@intCast(idx)] = val;
                },
                .echo => self.printVal(self.pop()),
                .echow => {
                    _ = self.popInt(); // ms refresh rate (ignored on hosted VM)
                    self.printVal(self.pop());
                },
                .input => {
                    const s: usize = @intCast(ins.a);
                    var buf: [4096]u8 = undefined;
                    const got = self.readLine(&buf);
                    const st = std.mem.trim(u8, got, " \t");
                    if (st.len == 0) {
                        f.slots[s] = VVal{ .tag = .Int, .int = 0 };
                    } else if (std.fmt.parseInt(i64, st, 10)) |v| {
                        f.slots[s] = VVal{ .tag = .Int, .int = v };
                    } else |_| {
                        const dup = try self.alloc.dupe(u8, st);
                        f.slots[s] = VVal{ .tag = .Str, .str = dup };
                    }
                },
                .vga => {
                    const m = self.pop();
                    if (m.tag == .Str) {
                        self.out("[VGA ");
                        self.out(m.str);
                        self.out(" initialized]\n");
                    } else self.out("[VGA initialized]\n");
                },
                .pout => {
                    _ = self.popInt();
                    _ = self.popInt();
                },
                .jmp => {
                    f.ip = @intCast(ins.a);
                },
                .fopen => {
                    const dst: usize = @intCast(ins.a);
                    const modev = self.pop();
                    const pathv = self.pop();
                    if (pathv.tag != .Str) fail(ln, "fopen path must be a string", .{});
                    if (modev.tag != .Str) fail(ln, "fopen mode must be \"r\" or \"w\"", .{});
                    const cwd = std.Io.Dir.cwd();
                    var fh: std.Io.File = undefined;
                    if (std.mem.eql(u8, modev.str, "r")) {
                        fh = cwd.openFile(self.io, pathv.str, .{ .mode = .read_only }) catch fail(ln, "Cannot open '{s}'", .{pathv.str});
                    } else if (std.mem.eql(u8, modev.str, "w")) {
                        fh = cwd.createFile(self.io, pathv.str, .{}) catch fail(ln, "Cannot create '{s}'", .{pathv.str});
                    } else fail(ln, "fopen mode must be \"r\" or \"w\"", .{});
                    const id = self.files.items.len;
                    try self.files.append(self.alloc, fh);
                    f.slots[dst] = VVal{ .tag = .Int, .int = @intCast(id) };
                },
                .fread => {
                    const dst: usize = @intCast(ins.a);
                    const fhslot: usize = @intCast(ins.b);
                    const n = self.popInt();
                    if (n < 0 or n > 1000000) fail(ln, "Bad read size {d}", .{n});
                    const fhv = f.slots[fhslot];
                    if (fhv.tag != .Int) fail(ln, "Bad file handle", .{});
                    const id: usize = @intCast(fhv.int);
                    if (id >= self.files.items.len or self.files.items[id] == null) fail(ln, "File not open", .{});
                    const buf = try self.alloc.alloc(u8, @intCast(n));
                    var got: usize = 0;
                    while (got < buf.len) {
                        const r = self.files.items[id].?.readStreaming(self.io, &[_][]u8{buf[got..]}) catch |e| {
                            if (e == error.EndOfStream) break;
                            fail(ln, "File read failed", .{});
                        };
                        if (r == 0) break;
                        got += r;
                    }
                    f.slots[dst] = VVal{ .tag = .Str, .str = buf[0..got] };
                },
                .fwrite => {
                    const fhslot: usize = @intCast(ins.a);
                    const v = self.pop();
                    const fhv = f.slots[fhslot];
                    if (fhv.tag != .Int) fail(ln, "Bad file handle", .{});
                    const id: usize = @intCast(fhv.int);
                    if (id >= self.files.items.len or self.files.items[id] == null) fail(ln, "File not open", .{});
                    const fh = self.files.items[id].?;
                    switch (v.tag) {
                        .Str => fh.writeStreamingAll(self.io, v.str) catch fail(ln, "File write failed", .{}),
                        .Int => {
                            var nb: [32]u8 = undefined;
                            fh.writeStreamingAll(self.io, intStr(&nb, v.int)) catch fail(ln, "File write failed", .{});
                        },
                        .Arr => fail(ln, "Cannot write array to file", .{}),
                    }
                },
                .fclose => {
                    const fhslot: usize = @intCast(ins.a);
                    const fhv = f.slots[fhslot];
                    if (fhv.tag != .Int) fail(ln, "Bad file handle", .{});
                    const id: usize = @intCast(fhv.int);
                    if (id < self.files.items.len) {
                        if (self.files.items[id]) |fh| {
                            fh.close(self.io);
                            self.files.items[id] = null;
                        }
                    }
                },
                .jmp_false => {
                    const c = self.pop();
                    if (!truthy(c)) f.ip = @intCast(ins.a);
                },
                .call => {
                    const fi: usize = @intCast(ins.a);
                    if (self.depth >= self.frames.len) fail(ln, "Call stack overflow", .{});
                    const cal = &self.prog.chunks.items[fi];
                    const nslots = @max(cal.nslots, 1);
                    const slots = try self.alloc.alloc(VVal, nslots);
                    for (slots) |*s| s.* = VVal{};
                    var k: usize = cal.arity;
                    while (k > 0) {
                        k -= 1;
                        slots[k] = self.pop();
                    }
                    self.frames[self.depth] = Frame{ .chunk = cal, .slots = slots };
                    self.depth += 1;
                },
                .ret => {
                    const rv = self.pop();
                    self.depth -= 1;
                    if (self.depth == 0) return;
                    self.push(rv);
                },
                .halt => return,
            }
        }
    }
};

// ---------------- disassembler ----------------

fn dumpProg(prog: *Program) void {
    for (prog.chunks.items, 0..) |ch, ci| {
        std.debug.print("== {s} (chunk {d}, arity {d}, slots {d}) ==\n", .{ ch.name, ci, ch.arity, ch.nslots });
        for (ch.code.items, 0..) |ins, ip| {
            std.debug.print("{d:0>4}  {s} {d} {d}   ; line {d}\n", .{ ip, @tagName(ins.op), ins.a, ins.b, ins.line });
        }
    }
    std.debug.print("-- consts ({d}) --\n", .{prog.consts.items.len});
    for (prog.consts.items, 0..) |c, i| {
        std.debug.print("[{d}] \"{s}\"\n", .{ i, c });
    }
}

// ---------------- main ----------------

fn joinPath(alloc: std.mem.Allocator, dir: []const u8, name: []const u8) error{OutOfMemory}![]const u8 {
    if (dir.len == 0) return name;
    if (name.len >= 2 and name[1] == ':') return name; // windows absolute
    if (name.len > 0 and (name[0] == '/' or name[0] == '\\')) return name;
    const out = try alloc.alloc(u8, dir.len + name.len);
    @memcpy(out[0..dir.len], dir);
    @memcpy(out[dir.len..], name);
    return out;
}

fn fileDir(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfAny(u8, path, "/\\")) |sp| return path[0 .. sp + 1];
    return "";
}

fn parseInto(list: *std.ArrayList(Line), alloc: std.mem.Allocator, content: []const u8, fname: []const u8, dir: []const u8, is_header: bool) error{OutOfMemory}!void {
    var it = std.mem.splitScalar(u8, content, '\n');
    var lineno: usize = 0;
    while (it.next()) |raw| : (lineno += 1) {
        var indent: usize = 0;
        var p: usize = 0;
        while (p < raw.len and (raw[p] == ' ' or raw[p] == '\t')) : (p += 1) {
            indent += if (raw[p] == '\t') 4 else 1;
        }
        const body = std.mem.trim(u8, raw[p..], " \t\r");
        if (body.len == 0) continue;
        const code = stripComment(body);
        if (code.len == 0) continue;
        const lvl: i32 = @intCast(indent / 4);
        if (is_header and lvl == 0 and !Compiler.isHeader(code) and !std.mem.startsWith(u8, code, "vectfn")) {
            fail(lineno + 1, "Only vectfn definitions allowed in header '{s}'", .{fname});
        }
        try list.append(alloc, Line{ .text = code, .level = lvl, .lineno = lineno + 1, .file = fname, .dir = dir });
    }
}

pub fn main(init: std.process.Init) !void {
    const alloc = init.arena.allocator();

    const args = try init.minimal.args.toSlice(alloc);
    var dump = false;
    var path: []const u8 = "";
    for (args[1..]) |a| {
        if (std.mem.eql(u8, a, "--dump")) dump = true else path = a;
    }
    if (path.len == 0) {
        std.debug.print("Usage: vectc [--dump] <file.vt>\n", .{});
        std.process.exit(2);
    }

    const content = std.Io.Dir.cwd().readFileAlloc(init.io, path, alloc, .limited(10 * 1024 * 1024)) catch {
        fail(1, "Cannot open '{s}'", .{path});
    };

    var lines_list: std.ArrayList(Line) = .empty;
    try parseInto(&lines_list, alloc, content, path, fileDir(path), false);
    // resolve .vth includes (worklist; supports nesting, skips repeats)
    var loaded: std.ArrayList([]const u8) = .empty;
    var scan: usize = 0;
    var guard: usize = 0;
    while (scan < lines_list.items.len) : (scan += 1) {
        guard += 1;
        if (guard > 50000) fail(1, "Include loop", .{});
        const ln = lines_list.items[scan];
        if (!std.mem.endsWith(u8, ln.text, ".vth")) continue;
        const full = try joinPath(alloc, ln.dir, ln.text);
        var seen = false;
        for (loaded.items) |l| {
            if (std.mem.eql(u8, l, full)) {
                seen = true;
                break;
            }
        }
        if (seen) continue;
        try loaded.append(alloc, full);
        const ic = std.Io.Dir.cwd().readFileAlloc(init.io, full, alloc, .limited(2 * 1024 * 1024)) catch {
            fail(ln.lineno, "Cannot open header '{s}'", .{full});
        };
        try parseInto(&lines_list, alloc, ic, full, fileDir(full), true);
    }
    const lines = try lines_list.toOwnedSlice(alloc);

    var prog = Program{
        .chunks = .empty,
        .func_index = std.StringHashMap(usize).init(alloc),
        .consts = .empty,
    };
    try Compiler.compileProgram(alloc, lines, &prog);

    if (dump) {
        dumpProg(&prog);
        return;
    }

    const top = prog.func_index.get("__top") orelse fail(1, "No code", .{});
    var vm = Vm{ .alloc = alloc, .io = init.io, .prog = &prog, .arrays = .empty, .files = .empty };
    try vm.run(top);
}
