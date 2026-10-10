// bounds.js line and byte ceilings, run under node.
const fs = require("fs")
const path = require("path")
const assert = require("assert")
const src = fs.readFileSync(path.join(__dirname, "..", "..", "bounds.js"), "utf8")
  .replace(/^\.pragma library\s*/m, "")
const B = {}
new Function("exports", src + "\nexports.splitLines = splitLines\nexports.exceedsByteCap = exceedsByteCap\nexports.DAEMON_LINE_MAX = DAEMON_LINE_MAX\nexports.HOTKEY_BYTE_MAX = HOTKEY_BYTE_MAX\n")(B)

let r = B.splitLines("", '{"type":"a"}\n{"ty', B.DAEMON_LINE_MAX)
assert.deepStrictEqual(r, { lines: ['{"type":"a"}'], rest: '{"ty', overflow: false })
r = B.splitLines(r.rest, 'pe":"b"}\n', B.DAEMON_LINE_MAX)
assert.deepStrictEqual(r.lines, ['{"type":"b"}'])
assert.strictEqual(r.overflow, false)

const max = B.DAEMON_LINE_MAX
assert.strictEqual(B.splitLines("", "x".repeat(max - 1) + "\n", max).overflow, false)
assert.strictEqual(B.splitLines("", "x".repeat(max - 1) + "\n", max).lines[0].length, max - 1)
assert.strictEqual(B.splitLines("", "x".repeat(max), max).overflow, true)
assert.strictEqual(B.splitLines("", "x".repeat(max) + "\n", max).overflow, true)
assert.deepStrictEqual(B.splitLines("", "x".repeat(max) + "\n", max), { lines: [], rest: "", overflow: true })

// A good line followed by an oversized tail in the same chunk is discarded
// whole, so the caller has nothing left to parse.
r = B.splitLines("", "ok\n" + "y".repeat(max), max)
assert.strictEqual(r.overflow, true)
assert.deepStrictEqual(r.lines, [])
assert.strictEqual(r.rest, "")

// Carried buffer plus a new chunk can cross the ceiling without a newline.
r = B.splitLines("x".repeat(max - 5), "yyyyy", max)
assert.strictEqual(r.overflow, true)
assert.strictEqual(r.rest, "")

assert.strictEqual(B.exceedsByteCap(B.HOTKEY_BYTE_MAX, B.HOTKEY_BYTE_MAX), false)
assert.strictEqual(B.exceedsByteCap(B.HOTKEY_BYTE_MAX + 1, B.HOTKEY_BYTE_MAX), true)
assert.strictEqual(B.exceedsByteCap(0, B.HOTKEY_BYTE_MAX), false)
assert.strictEqual(B.exceedsByteCap(NaN, B.HOTKEY_BYTE_MAX), false)

console.log("bounds-test ok")
