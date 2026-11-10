"""Stand-in for the bridge: records every request, answers per BEHAVIOUR env/file."""
import http.server, json, os, sys, time

LOG = sys.argv[1]
BEHAVIOUR = sys.argv[2]  # file holding JSON: {"event": [status, body], "ask": [status, body, delay], "feed": [status, body, delay]}


class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_POST(self):
        n = int(self.headers.get("content-length", 0))
        body = self.rfile.read(n).decode()
        with open(LOG, "a") as f:
            f.write(json.dumps({"path": self.path, "auth": self.headers.get("authorization"), "body": body}) + "\n")
        key = {"/v1/ask": "ask", "/v1/feed": "feed"}.get(self.path, "event")
        b = json.load(open(BEHAVIOUR)).get(key, [204, ""])
        if len(b) > 2:
            time.sleep(b[2])
        self.send_response(b[0])
        data = b[1].encode()
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
print(srv.server_address[1], flush=True)
srv.serve_forever()
