"""Qt 6.12 adds its own `Color` type, which shadows the shell's palette
singleton when QML names it bare. Every palette reference must go through
the `qs.Commons as Commons` alias, as Omarchy's docs/omarchy-shell.md requires.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BARE = re.compile(r"(?<![\w.])Color\b")


class PaletteTests(unittest.TestCase):
    def test_palette_is_qualified(self):
        for path in sorted(ROOT.glob("*.qml")) + sorted(ROOT.glob("*.js")):
            for n, line in enumerate(path.read_text().splitlines(), 1):
                code = line.split("//", 1)[0]
                self.assertIsNone(BARE.search(code), f"{path.name}:{n}: bare Color: {line.strip()}")

    def test_commons_alias_imported(self):
        text = (ROOT / "Panel.qml").read_text()
        self.assertIn("Commons.Color.", text)
        self.assertRegex(text, r"(?m)^import qs\.Commons as Commons$")


if __name__ == "__main__":
    unittest.main()
