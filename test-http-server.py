#!/usr/bin/env python3
import http.server
import socketserver
import sys

if len(sys.argv) < 2:
    print("Usage: python3 test-http-server.py <port>")
    sys.exit(1)

PORT = int(sys.argv[1])

class MyHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-type', 'text/plain')
        self.end_headers()
        self.wfile.write(b'NAT-PMP test server is working!\n')

with socketserver.TCPServer(("", PORT), MyHandler) as httpd:
    print(f"Server running on port {PORT}")
    httpd.serve_forever()