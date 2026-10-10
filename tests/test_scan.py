"""Scan and HTTP-reply checks for tvctl.

A scan may drop an app only when the TV answered that it is not installed.
Silence (no HTTP reply at all) must leave that question open. A non-200 is
an answer: it must not be reported as "the TV did not answer".

Redirects are refused. A 3xx body is not read, so a LAN host cannot hold the
helper open by advertising a huge redirect body.
"""
import importlib.util
from importlib.machinery import SourceFileLoader
import json
import os
import socket
import tempfile
import threading
import time
import unittest
from unittest import mock
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TMP = tempfile.mkdtemp(prefix="tvctl-test-")
os.environ["HOME"] = TMP
os.environ["TV_APPS_FILE"] = str(Path(TMP) / "apps.json")
os.environ["TV_HOST"] = "127.0.0.1"

loader = SourceFileLoader("tvctl", str(ROOT / "tvctl"))
spec = importlib.util.spec_from_loader("tvctl", loader)
tvctl = importlib.util.module_from_spec(spec)
loader.exec_module(tvctl)

YOUTUBE = "111299001912"
NETFLIX = "3201907018807"
SPOTIFY = "3201606009684"


def app(app_id, name, key):
    return {
        "key": key,
        "name": name,
        "appId": app_id,
        "color": "#112233",
        "glyph": "x",
        "show": True,
    }


class ScanResultTests(unittest.TestCase):
    def setUp(self):
        self.events = []
        self._emit = tvctl.emit
        tvctl.emit = self.events.append

    def tearDown(self):
        tvctl.emit = self._emit

    def write_apps(self, apps):
        Path(tvctl.APPS_FILE).write_text(
            json.dumps({"apps": apps}) + "\n", encoding="utf-8")

    def saved_ids(self):
        data = json.loads(Path(tvctl.APPS_FILE).read_text(encoding="utf-8"))
        return [a["appId"] for a in data["apps"]]

    def replies(self, table):
        """Map an app id to (status, body) or an exception. Unknown ids are 404."""
        def http(_method, _host, _port, path, body=b"", headers=None, timeout=3):
            reply = table.get(path.rsplit("/", 1)[-1], (404, b""))
            if isinstance(reply, BaseException):
                raise reply
            return reply

        return mock.patch.object(tvctl, "http_request", side_effect=http)

    def test_silence_raises_and_leaves_config(self):
        self.write_apps([app(YOUTUBE, "YouTube", "youtube")])

        def boom(*_a, **_k):
            raise TimeoutError("no reply")

        with mock.patch.object(tvctl, "http_request", side_effect=boom), \
                mock.patch.object(tvctl, "sdb_app_ids", return_value=[]):
            with self.assertRaises(ConnectionError) as caught:
                tvctl.scan_apps(timeout=0.2)
            self.assertEqual(str(caught.exception), "the TV did not answer")
            tvctl._scan_and_report()
        self.assertEqual(self.saved_ids(), [YOUTUBE])
        self.assertTrue(any(
            e.get("type") == "error" and "ConnectionError" in e.get("msg", "")
            for e in self.events))

    def test_all_404_updates_config(self):
        # Every probe got an HTTP answer, none of them 200. That used to
        # raise "the TV did not answer" because `done` only stores 200s.
        self.write_apps([
            app(YOUTUBE, "YouTube", "youtube"),
            app(NETFLIX, "Netflix", "netflix"),
        ])
        with self.replies({}), mock.patch.object(tvctl, "sdb_app_ids", return_value=[]):
            found = tvctl.scan_apps(timeout=0.2)
            self.assertEqual(found, [])
            tvctl._scan_and_report()
        self.assertEqual(self.saved_ids(), [])
        # The empty file must stay empty. Treating it as "first run" would
        # put the default apps back on screen after the TV rejected them.
        self.assertEqual(tvctl.load_apps(), [])
        self.assertFalse(any(e.get("type") == "error" for e in self.events))
        apps_event = [e for e in self.events if e.get("type") == "apps"]
        self.assertEqual(apps_event[-1]["apps"], [])

    def test_missing_config_still_seeds_defaults(self):
        path = Path(tvctl.APPS_FILE)
        path.unlink(missing_ok=True)
        loaded = tvctl.load_apps()
        self.assertEqual(
            [a["appId"] for a in loaded],
            [a["appId"] for a in tvctl.DEFAULT_APPS])
        self.assertTrue(path.is_file())

    def test_404_drops_timeout_keeps_200_keeps(self):
        self.write_apps([
            app(YOUTUBE, "YouTube", "youtube"),
            app(NETFLIX, "Netflix", "netflix"),
            app(SPOTIFY, "Spotify", "spotify"),
        ])
        with self.replies({
            YOUTUBE: TimeoutError("slow"),
            NETFLIX: (404, b""),
            SPOTIFY: (200, json.dumps({
                "name": "Spotify - Music and Podcasts",
                "running": False,
            }).encode()),
        }), mock.patch.object(tvctl, "sdb_app_ids", return_value=[]):
            found = tvctl.scan_apps(timeout=0.2)
        ids = [a["appId"] for a in found]
        self.assertEqual(ids, [YOUTUBE, SPOTIFY])
        by_id = {a["appId"]: a for a in found}
        # A saved name wins over the TV's longer one.
        self.assertEqual(by_id[SPOTIFY]["name"], "Spotify")
        self.assertEqual(by_id[YOUTUBE]["name"], "YouTube")

    def test_unparsed_200_is_still_an_answer(self):
        self.write_apps([app(YOUTUBE, "YouTube", "youtube")])
        with self.replies({YOUTUBE: (200, b"not-json")}), \
                mock.patch.object(tvctl, "sdb_app_ids", return_value=[]):
            found = tvctl.scan_apps(timeout=0.2)
        self.assertEqual(found, [])


class RedirectTests(unittest.TestCase):
    def serve(self, payload, pause=0):
        ready = threading.Event()
        box = {}

        def run():
            srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            srv.bind(("127.0.0.1", 0))
            srv.listen(1)
            box["port"] = srv.getsockname()[1]
            ready.set()
            srv.settimeout(5)
            try:
                conn, _ = srv.accept()
            except socket.timeout:
                srv.close()
                return
            with conn:
                conn.settimeout(2)
                try:
                    conn.recv(4096)
                    conn.sendall(payload)
                    if pause:
                        time.sleep(pause)
                except OSError:
                    pass
            srv.close()

        thread = threading.Thread(target=run, daemon=True)
        thread.start()
        self.assertTrue(ready.wait(2), "test server did not bind")
        return box["port"], thread

    def test_redirect_body_is_not_read(self):
        head = (
            b"HTTP/1.1 302 Found\r\n"
            b"Location: http://127.0.0.1:9/elsewhere\r\n"
            b"Content-Length: 50000000\r\n"
            b"Connection: close\r\n"
            b"\r\n"
        )
        port, thread = self.serve(head + b"R" * 4096, pause=3)
        started = time.monotonic()
        status, body = tvctl.http_request(
            "GET", "127.0.0.1", port, "/api/v2/", timeout=1)
        elapsed = time.monotonic() - started
        # The server keeps the unread body open; the client must already
        # have returned. Don't wait out that stall.
        thread.join(timeout=0.2)
        self.assertEqual(status, 302)
        self.assertEqual(body, b"")
        # Reading the advertised 50 MB would run into the 2 s deadline.
        self.assertLess(elapsed, 1.0)

    def test_success_body_is_returned(self):
        raw = b'{"device":{"type":"Samsung TV"}}'
        payload = (
            b"HTTP/1.1 200 OK\r\n"
            b"Content-Length: " + str(len(raw)).encode() + b"\r\n"
            b"Connection: close\r\n"
            b"\r\n" + raw
        )
        port, thread = self.serve(payload)
        status, body = tvctl.http_request(
            "GET", "127.0.0.1", port, "/api/v2/", timeout=1)
        thread.join(timeout=2)
        self.assertEqual(status, 200)
        self.assertEqual(body, raw)


if __name__ == "__main__":
    unittest.main()
