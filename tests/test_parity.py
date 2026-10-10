"""Sibling-parity checks: closed launches, output ceilings, no-follow I/O.

Mirrors the contracts in rdoupe/omarchy-pixelbuds (absolute python3 -I -B,
clearEnvironment, PATH=/usr/bin:/bin) and rdoupe-omarchy/omarchy-underpants
(hyprctl only from /usr/bin:/bin, kill-and-discard past a byte ceiling,
directory fds opened O_DIRECTORY|O_NOFOLLOW).
"""
import importlib.util
import json
import os
import shutil
import stat
import subprocess
import tempfile
import unittest
from importlib.machinery import SourceFileLoader
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]


def load_tvctl(home):
    os.environ["HOME"] = str(home)
    os.environ["TV_APPS_FILE"] = str(home / "apps.json")
    os.environ["TV_HOST"] = "127.0.0.1"
    loader = SourceFileLoader("tvctl_parity", str(ROOT / "tvctl"))
    spec = importlib.util.spec_from_loader("tvctl_parity", loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


class LaunchContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.qml = (ROOT / "Panel.qml").read_text(encoding="utf-8")
        cls.tvctl = (ROOT / "tvctl").read_text(encoding="utf-8")
        cls.bounds = (ROOT / "bounds.js").read_text(encoding="utf-8")

    def test_tvctl_launched_with_isolated_absolute_python(self):
        self.assertTrue(self.tvctl.startswith("#!/usr/bin/python3 -I\n"))
        self.assertNotIn("#!/usr/bin/env python3", self.tvctl)
        self.assertIn('readonly property string python3Bin: "/usr/bin/python3"', self.qml)
        self.assertIn(
            'command: [root.python3Bin, "-I", "-B", root.helper, "serve"]', self.qml)
        self.assertIn(
            'command: [root.python3Bin, "-I", "-B", root.helper, "state"]', self.qml)
        self.assertNotIn('["python3"', self.qml)
        self.assertNotIn("[root.helper, \"serve\"]", self.qml)
        self.assertIn("decodeURIComponent(", self.qml)

    def test_hyprctl_resolved_only_from_usr_bin(self):
        self.assertIn('readonly property string hyprctlBin: "/usr/bin/hyprctl"', self.qml)
        self.assertIn('readonly property string trustedPath: "/usr/bin:/bin"', self.qml)
        self.assertIn('command: [root.hyprctlBin, "binds", "-j"]', self.qml)
        self.assertNotIn('["hyprctl"', self.qml)
        self.assertNotIn("Quickshell.env(\"PATH\")", self.qml)

    def test_every_process_clears_environment_with_allowlist(self):
        blocks = []
        rest = self.qml
        while "Process {" in rest:
            rest = rest.split("Process {", 1)[1]
            blocks.append(rest.split("\n  Timer {", 1)[0])
        self.assertEqual(len(blocks), 3, "expected daemon, hotkey, and state processes")
        for block in blocks:
            self.assertIn("clearEnvironment: true", block)
            self.assertIn("environment: root.launchEnvironment()", block)
        self.assertIn("function launchEnvironment()", self.qml)
        self.assertIn("PATH: root.trustedPath", self.qml)
        self.assertIn("TV_HOST: root.host", self.qml)
        self.assertIn('TV_RESUME_APP: root.resumeLastApp ? "1" : "0"', self.qml)
        self.assertIn('"XDG_RUNTIME_DIR"', self.qml)
        self.assertIn('"XDG_STATE_HOME"', self.qml)
        self.assertIn('"XDG_CONFIG_HOME"', self.qml)
        for needle in (
            "PYTHONPATH", "PYTHONHOME", "PYTHONINSPECT", "PYTHONSTARTUP",
            "LD_PRELOAD", "LD_LIBRARY_PATH", "LD_AUDIT",
        ):
            self.assertNotIn(needle, self.qml)
        self.assertEqual(self.qml.count("clearEnvironment: true"), 3)

    def test_output_ceilings_kill_and_discard(self):
        self.assertIn("var DAEMON_LINE_MAX = 1024 * 1024", self.bounds)
        self.assertIn("var HOTKEY_BYTE_MAX = 2 * 1024 * 1024", self.bounds)
        self.assertIn("function splitLines", self.bounds)
        self.assertIn("function exceedsByteCap", self.bounds)
        self.assertEqual(self.qml.count('splitMarker: ""'), 3)
        self.assertIn("Bounds.splitLines", self.qml)
        self.assertIn("Bounds.DAEMON_LINE_MAX", self.qml)
        self.assertIn("if (proc.running) proc.signal(9)", self.qml)
        self.assertIn("return \"\"", self.qml)
        hotkey = self.qml.split("id: hotkeyProc", 1)[1].split("function readHotkey", 1)[0]
        self.assertIn("StdioCollector", hotkey)
        self.assertIn("waitForEnd: false", hotkey)
        self.assertIn("Bounds.exceedsByteCap(data.byteLength, Bounds.HOTKEY_BYTE_MAX)", hotkey)
        self.assertIn("root.discardHotkey()", hotkey)
        self.assertIn("if (hotkeyProc.running) hotkeyProc.signal(9)", self.qml)
        # The finished stream is parsed only when it stayed under the cap.
        self.assertIn("root.hotkeyDiscarded", hotkey)
        self.assertLess(hotkey.index("root.hotkeyDiscarded"), hotkey.index("root.readHotkey(text)"))

    def test_bounds_script(self):
        node = shutil.which("node")
        self.assertIsNotNone(node)
        result = subprocess.run(
            [node, str(ROOT / "tests" / "js" / "bounds-test.js")],
            check=False, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


class NoFollowIoTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="tvctl-io-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.tvctl = load_tvctl(self.tmp)
        self.assertTrue(self.tvctl.DIR_OPEN_FLAGS & os.O_DIRECTORY)
        self.assertTrue(self.tvctl.DIR_OPEN_FLAGS & os.O_NOFOLLOW)
        self.assertTrue(self.tvctl.FILE_READ_FLAGS & os.O_NOFOLLOW)
        self.assertTrue(self.tvctl.FILE_WRITE_FLAGS & os.O_NOFOLLOW)
        self.assertNotIn("follow=True", (ROOT / "tvctl").read_text(encoding="utf-8"))

    def test_follow_argument_is_gone(self):
        with self.assertRaises(TypeError):
            self.tvctl.read_small(str(self.tmp / "apps.json"), follow=True)

    def test_round_trip_is_mode_0600_regular_file(self):
        path = self.tmp / "apps.json"
        self.tvctl.write_private(str(path), "{\"apps\": []}\n")
        self.assertEqual(self.tvctl.read_small(str(path)), "{\"apps\": []}\n")
        info = path.lstat()
        self.assertTrue(stat.S_ISREG(info.st_mode))
        self.assertEqual(stat.S_IMODE(info.st_mode), 0o600)
        self.assertFalse(any(name.startswith(".tv.") for name in os.listdir(self.tmp)))

    def test_replace_uses_the_held_directory_fd(self):
        path = self.tmp / "apps.json"
        path.write_text("old", encoding="utf-8")
        renames = []
        real_rename = os.rename

        def spy(src, dst, *args, **kwargs):
            renames.append(kwargs)
            return real_rename(src, dst, *args, **kwargs)

        opens = []
        real_open = os.open

        def spy_open(file, flags, *args, **kwargs):
            fd = real_open(file, flags, *args, **kwargs)
            opens.append((file, flags, kwargs.get("dir_fd")))
            return fd

        with mock.patch.object(self.tvctl.os, "rename", spy), \
                mock.patch.object(self.tvctl.os, "open", spy_open):
            self.tvctl.write_private(str(path), "new\n")
        self.assertEqual(path.read_text(encoding="utf-8"), "new\n")
        self.assertEqual(len(renames), 1)
        self.assertIsInstance(renames[0].get("src_dir_fd"), int)
        self.assertEqual(renames[0]["src_dir_fd"], renames[0]["dst_dir_fd"])
        dir_opens = [item for item in opens if item[1] & os.O_DIRECTORY]
        self.assertTrue(dir_opens)
        for _path, flags, _dir_fd in dir_opens:
            self.assertTrue(flags & os.O_NOFOLLOW)
            self.assertTrue(flags & os.O_DIRECTORY)
        leaf_opens = [item for item in opens if item[2] is not None and not (item[1] & os.O_DIRECTORY)]
        self.assertTrue(leaf_opens)
        for _path, flags, dir_fd in leaf_opens:
            self.assertIsInstance(dir_fd, int)
            self.assertTrue(flags & os.O_NOFOLLOW)

    def test_leaf_symlink_is_not_followed_on_read_or_write(self):
        secret = self.tmp / "secret"
        secret.write_text("token-value", encoding="utf-8")
        link = self.tmp / "apps.json"
        link.symlink_to(secret)
        with self.assertRaises(OSError):
            self.tvctl.read_small(str(link))
        with self.assertRaises(OSError):
            self.tvctl.write_private(str(link), "replaced\n")
        self.assertTrue(link.is_symlink())
        self.assertEqual(secret.read_text(encoding="utf-8"), "token-value")

    def test_parent_symlink_is_not_followed(self):
        real = self.tmp / "real"
        real.mkdir()
        (real / "apps.json").write_text("secret", encoding="utf-8")
        linked = self.tmp / "linked"
        linked.symlink_to(real, target_is_directory=True)
        with self.assertRaises(OSError):
            self.tvctl.read_small(str(linked / "apps.json"))
        with self.assertRaises(OSError):
            self.tvctl.write_private(str(linked / "apps.json"), "nope\n")
        self.assertEqual((real / "apps.json").read_text(encoding="utf-8"), "secret")

    def test_fifo_does_not_block(self):
        fifo = self.tmp / "apps.json"
        os.mkfifo(fifo)
        started = os.times()
        with self.assertRaises(OSError):
            self.tvctl.read_small(str(fifo))
        self.assertLess(os.times().elapsed - started.elapsed, 1.0)

    def test_oversized_file_is_refused(self):
        path = self.tmp / "apps.json"
        path.write_bytes(b"x" * 32)
        with self.assertRaises(OSError):
            self.tvctl.read_small(str(path), limit=16)

    def test_state_dir_is_sealed_and_token_not_replaced_through_symlink(self):
        token = Path(self.tvctl.TOKEN_FILE)
        self.tvctl.write_private(str(token), "abc123\n")
        self.assertEqual(self.tvctl.read_small(str(token)).strip(), "abc123")
        info = token.parent.lstat()
        self.assertTrue(stat.S_ISDIR(info.st_mode))
        self.assertEqual(stat.S_IMODE(info.st_mode) & 0o077, 0)
        self.assertEqual(stat.S_IMODE(token.lstat().st_mode), 0o600)
        outside = self.tmp / "outside-token"
        outside.write_text("keep", encoding="utf-8")
        token.unlink()
        token.symlink_to(outside)
        with self.assertRaises(OSError):
            self.tvctl.write_private(str(token), "stolen\n")
        self.assertEqual(outside.read_text(encoding="utf-8"), "keep")

    def test_remove_unlinks_symlink_leaf_not_target(self):
        target = self.tmp / "target"
        target.write_text("stay", encoding="utf-8")
        link = self.tmp / "apps.json"
        link.symlink_to(target)
        self.tvctl.remove_private(str(link))
        self.assertFalse(link.exists())
        self.assertFalse(link.is_symlink())
        self.assertEqual(target.read_text(encoding="utf-8"), "stay")

    def test_load_apps_does_not_follow_config_symlink(self):
        secret = self.tmp / "secret.json"
        secret.write_text(json.dumps({"apps": [{
            "key": "youtube", "name": "YouTube", "appId": "111299001912",
            "color": "#ff0033", "glyph": "x", "show": True,
        }]}) + "\n", encoding="utf-8")
        Path(self.tvctl.APPS_FILE).symlink_to(secret)
        loaded = self.tvctl.load_apps()
        # Unreadable config falls back to the defaults and must not rewrite
        # the symlink's target.
        self.assertEqual(
            [a["appId"] for a in loaded],
            [a["appId"] for a in self.tvctl.DEFAULT_APPS])
        self.assertTrue(Path(self.tvctl.APPS_FILE).is_symlink())
        self.assertIn("111299001912", secret.read_text(encoding="utf-8"))
        self.assertNotIn("3201907018807", secret.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
