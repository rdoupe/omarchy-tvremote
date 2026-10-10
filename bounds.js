.pragma library

// Ceilings for untrusted process output. Past either one the caller kills
// the process and discards what it already buffered, the same rule as a
// reader that stops at the first oversized chunk.
var DAEMON_LINE_MAX = 1024 * 1024       // one JSON line from tvctl
var HOTKEY_BYTE_MAX = 2 * 1024 * 1024   // hyprctl binds -j

// { lines, rest, overflow }. A line or an unfinished tail at the ceiling is
// overflow: the caller must not keep `rest` and must not parse further.
function splitLines(buffer, chunk, maxLine) {
  var limit = maxLine > 0 ? maxLine : DAEMON_LINE_MAX
  var all = String(buffer || "") + String(chunk || "")
  var lines = []
  var at = all.indexOf("\n")
  while (at !== -1) {
    var line = all.substring(0, at)
    if (line.length >= limit) return { lines: [], rest: "", overflow: true }
    lines.push(line)
    all = all.substring(at + 1)
    at = all.indexOf("\n")
  }
  if (all.length >= limit) return { lines: [], rest: "", overflow: true }
  return { lines: lines, rest: all, overflow: false }
}

// Byte cap for a StdioCollector buffer. Equal to the ceiling is still
// accepted; one byte past it is discarded.
function exceedsByteCap(size, cap) {
  var n = Number(size)
  var limit = cap > 0 ? cap : HOTKEY_BYTE_MAX
  return isFinite(n) && n > limit
}
