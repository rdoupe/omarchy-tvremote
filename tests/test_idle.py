"""Closed-panel checks: nothing reaches for the TV until the popup opens.

Every check goes over Wi-Fi, and a TV that is off turns each one into
seconds of retries, or a sweep of the /24. So with the popup closed no timer
may start a helper, except the opt-in hideWhenOff poll, and that one never
discovers.
"""
import importlib.util
import json
import os
import re
import shutil
import tempfile
import unittest
from importlib.machinery import SourceFileLoader
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]


def qml_blocks(qml, opener):
    """Top-level `  <opener> {` blocks of Panel.qml, by brace matching."""
    blocks = []
    for m in re.finditer(r"^  " + re.escape(opener) + r" \{$", qml, re.M):
        depth, i = 0, m.end() - 1
        while True:
            depth += {"{": 1, "}": -1}.get(qml[i], 0)
            i += 1
            if depth == 0:
                break
        blocks.append(qml[m.start():i])
    return blocks


class ClosedPanelTimerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.qml = (ROOT / "Panel.qml").read_text(encoding="utf-8")
        cls.manifest = json.loads((ROOT / "manifest.json").read_text(encoding="utf-8"))
        cls.timers = qml_blocks(cls.qml, "Timer")
        cls.procs = re.findall(r"^  Process \{\n    id: (\w+)$", cls.qml, re.M)

    def spawning_timers(self):
        found = []
        for block in self.timers:
            body = block.split("onTriggered:", 1)[-1]
            if any(p + ".running = true" in body or "root.send(" in body
                   or p + ".write(" in body for p in self.procs):
                found.append(block)
        return found

    def test_processes_are_the_expected_three(self):
        self.assertEqual(sorted(self.procs), ["daemon", "hotkeyProc", "stateProc"])

    def test_with_defaults_no_timer_spawns_while_closed(self):
        defaults = self.manifest["barWidget"]["defaults"]
        self.assertIs(defaults["hideWhenOff"], False)
        spawning = self.spawning_timers()
        self.assertEqual(len(spawning), 1, "only the hideWhenOff poll may start a helper")
        for block in spawning:
            running = re.search(r"running: (.+)", block)
            self.assertIsNotNone(running, "a spawning timer must be gated, not started by hand")
            # Off with the defaults (hideWhenOff false) and whenever the panel
            # is open: opening does its own first contact through the daemon,
            # so the poll is for the closed, opted-in case only.
            self.assertEqual(running.group(1).strip(), "!root.opened && root.hideWhenOff")

    def test_opt_in_poll_never_discovers(self):
        self.assertIn(
            'command: [root.python3Bin, "-I", "-B", root.helper, "state", "--no-discover"]',
            self.qml)

    def test_no_other_timer_restarts_itself_from_start(self):
        # triggeredOnStart on an ungated timer is a spawn at shell launch.
        for block in self.timers:
            if "triggeredOnStart: true" in block:
                self.assertIn("root.hideWhenOff", block)

    def test_bar_key_lets_go_of_the_daemon(self):
        bar_key = self.qml.split("function barKey(key) {", 1)[1].split("\n  }", 1)[0]
        self.assertIn("if (!opened) barIdle.restart()", bar_key)
        idle = [b for b in self.timers if "id: barIdle" in b]
        self.assertEqual(len(idle), 1)
        self.assertIn("onTriggered: root.closeDaemonIfIdle()", idle[0])
        self.assertNotIn("repeat: true", idle[0])

    def test_unknown_state_is_neutral_not_off(self):
        self.assertIn("property bool stateKnown: false", self.qml)
        self.assertIn("opacity: root.reachable || !root.stateKnown ? 1 : 0.45", self.qml)
        self.assertIn("shown: reachable || !stateKnown || !hideWhenOff", self.qml)


class NoDiscoverStateTests(unittest.TestCase):
    def setUp(self):
        self.home = Path(tempfile.mkdtemp(prefix="tvctl-idle-"))
        self.addCleanup(shutil.rmtree, self.home, True)
        env = {"HOME": str(self.home), "TV_APPS_FILE": str(self.home / "apps.json"),
               "TV_HOST": ""}
        patcher = mock.patch.dict(os.environ, env)
        patcher.start()
        self.addCleanup(patcher.stop)
        loader = SourceFileLoader("tvctl_idle", str(ROOT / "tvctl"))
        spec = importlib.util.spec_from_loader("tvctl_idle", loader)
        self.tv = importlib.util.module_from_spec(spec)
        loader.exec_module(self.tv)
        self.tv.HOST = ""

    def run_state(self, argv):
        tv = self.tv
        with mock.patch.object(tv, "load_host", return_value="192.0.2.10"), \
             mock.patch.object(tv, "identify", return_value=None), \
             mock.patch.object(tv, "discover", return_value=[]) as discover, \
             mock.patch.object(tv, "state_payload", return_value={"type": "state"}), \
             mock.patch.object(tv, "emit"):
            self.assertEqual(tv.main(argv), 0)
        return discover

    def test_no_discover_keeps_the_cached_address(self):
        # The cached TV is off: plain `state` sweeps, the panel's poll must not.
        self.assertFalse(self.run_state(["state", "--no-discover"]).called)
        self.assertEqual(self.tv.HOST, "192.0.2.10")

    def test_plain_state_still_discovers(self):
        self.assertTrue(self.run_state(["state"]).called)


if __name__ == "__main__":
    unittest.main()
