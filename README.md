# Vect (.vt)

Vect is a minimalist, ultra-compact low-level programming language.
Whole programs in a handful of lines — direct memory, file and hardware
primitives, zero boilerplate.

```vt
vt.init
mvga.vth
(main)
branch
vectfn add.a, b
    (sum.a+b)
    rtn sum
vectfn main
    (result.add 25, 75)
    echo result       cmt 100
main()
```

## Features (v0.2.3)

- **Ultra-compact syntax** — `x10` means `x = 10`, `(c.a+b)` means `c = a + b`
- **Floats** — `y3.14` with int↔float promotion
- **Bytecode compiler + stack VM** (`vectc`) with `--dump` disassembler
- **Control flow** — `if` / `els`, `lo10` fixed and `lo10w` conditional loops
- **Functions** — `vectfn name.a, b` with `rtn`
- **Arrays** — `arr(5)`, `set arr, i, v`, `(x.get arr, i)`
- **Strings** — `(n.len s)`, `(c.char s, i)`, `(ok.cmp a, b)`, `(out.cat a, b)`
- **I/O** — `echo`, `echow`, `in()`, files via `fopen` / `fread` / `fwrite` / `fclose`
- **Header libraries** — reusable `.vth` files (e.g. `mvga.vth`)
- **Immediate-failure errors** with file + line numbers, non-zero exit

## Quick start

Requires [Zig](https://ziglang.org) 0.16.

```powershell
cd vectc
zig build-exe src/main.zig -O ReleaseFast   # produces vectc.exe
.\vectc.exe ..\hello.vt
.\vectc.exe --dump ..\func.vt         # show bytecode instead of running
.\vectc.exe --version                 # vectc 0.2.3
```

Try the examples in the repo root: `hello.vt`, `vars_math.vt`,
`control.vt`, `func.vt`, `array.vt`, `io.vt`, `fileio.vt`, `ifels.vt`,
`inc_test.vt`, `float.vt`, `str.vt`.

## Project layout

| Path | What |
| ---- | ---- |
| `vectc/src/main.zig` | Compiler frontend + bytecode VM (`vectc`) |
| `*.vt` | Example Vect programs |
| `*.vth` | Vect header libraries |
| `site/` | Static website (Render-ready, publish dir `site/`) |

Full language reference: open `site/docs.html` or read it on the
[website](https://vect.onrender.com/docs.html).

## Roadmap

- **v0.2.2** — floats (`y3.14`), string ops (`len`/`char`/`cat`/`cmp`), filenames in errors, tiny stdlib headers
- **Distribution** — direct zip, then Scoop, then Winget
- **v0.3** — native AOT via `zig cc`, real framebuffer VGA backend
- **Self-hosting** — rewrite the Vect lexer/parser in Vect itself

## License

See [LICENSE](LICENSE).
