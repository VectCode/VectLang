const fs = require("fs");

const wasmPath = process.argv[2] || "wvectc-static";
const vtPath = process.argv[3] || "../hello.vt";
const stdinText = process.argv[4] || "";

const bytes = fs.readFileSync(wasmPath);
const src = fs.readFileSync(vtPath);

WebAssembly.instantiate(bytes, {
  env: { vectc_now_ms: () => BigInt(Date.now()) },
}).then(({ instance }) => {
  const e = instance.exports;
  if (!e.memory) { console.error("NO EXPORTED MEMORY"); process.exit(1); }
  const mem = () => new Uint8Array(e.memory.buffer);
  const srcPtr = e.wv_src_ptr();
  mem().set(src.subarray(0, Math.min(src.length, e.wv_src_cap())), srcPtr);
  e.wv_src_len_set(Math.min(src.length, e.wv_src_cap()));
  const sb = Buffer.from(stdinText, "utf8");
  const stdinPtr = e.wv_stdin_ptr();
  mem().set(sb.subarray(0, Math.min(sb.length, e.wv_stdin_cap())), stdinPtr);
  e.wv_stdin_len_set(Math.min(sb.length, e.wv_stdin_cap()));
  let trapped = "";
  try {
    e.wv_run();
  } catch (err) {
    trapped = "\n[wasm trap: " + (err && err.message) + "]";
  }
  const out = Buffer.from(mem().subarray(e.wv_out_ptr(), e.wv_out_ptr() + e.wv_out_len()));
  process.stdout.write(out.toString("utf8") + trapped + "\n");
}).catch((err) => { console.error("INSTANTIATE FAIL:", err); process.exit(1); });
