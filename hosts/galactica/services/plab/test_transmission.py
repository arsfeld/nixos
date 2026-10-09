import base64
import json
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer

import transmission


class Stub(BaseHTTPRequestHandler):
    """Transmission's RPC: 409 plus a session id until the client echoes it back."""
    requests = []
    reply = {}

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        sid = self.headers.get("X-Transmission-Session-Id")
        Stub.requests.append((sid, body))
        if sid != "abc":
            self.send_response(409)
            self.send_header("X-Transmission-Session-Id", "abc")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        data = json.dumps(Stub.reply).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


class Add(unittest.TestCase):
    def setUp(self):
        Stub.requests = []
        self.server = HTTPServer(("127.0.0.1", 0), Stub)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.url = "http://127.0.0.1:%d/transmission/rpc" % self.server.server_port

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()

    def test_handshake_then_add(self):
        Stub.reply = {"result": "success", "arguments": {"torrent-added": {"name": "Some Release", "id": 7}}}
        name = transmission.add(self.url, b"d4:infoe", "/mnt/storage/media/Downloads/Vault")
        self.assertEqual(name, "Some Release")
        self.assertEqual(len(Stub.requests), 2)
        self.assertEqual(Stub.requests[1][0], "abc")
        body = Stub.requests[1][1]
        self.assertEqual(body["method"], "torrent-add")
        self.assertEqual(base64.b64decode(body["arguments"]["metainfo"]), b"d4:infoe")
        self.assertEqual(body["arguments"]["download-dir"], "/mnt/storage/media/Downloads/Vault")

    def test_duplicate_is_success(self):
        Stub.reply = {"result": "success", "arguments": {"torrent-duplicate": {"name": "Old Release"}}}
        self.assertEqual(transmission.add(self.url, b"d4:infoe", "/x"), "Old Release")

    def test_failure_result_raises(self):
        Stub.reply = {"result": "invalid or corrupt torrent file", "arguments": {}}
        with self.assertRaisesRegex(transmission.TransmissionError, "invalid or corrupt"):
            transmission.add(self.url, b"junk", "/x")


if __name__ == "__main__":
    unittest.main()
