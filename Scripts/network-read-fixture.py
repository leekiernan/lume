#!/usr/bin/env python3
"""Out-of-process loopback fixture for NetworkReadBenchmarks, no dependencies.

Run this first, then give its printed URL to TEST_RUNNER_LUME_PERF_HTTP when
running one benchmark test per xcodebuild invocation. Ctrl-C stops the server.
"""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    chunk = b"a" * 65536

    def do_GET(self):
        sizes = {"/accepted": 8 * 1024 * 1024, "/oversized": 64 * 1024 * 1024}
        size = sizes.get(self.path)
        if size is None:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        if self.path == "/accepted":
            self.send_header("Content-Length", str(size))
        else:
            self.send_header("Connection", "close")
            self.close_connection = True
        self.end_headers()
        try:
            for _ in range(size // len(self.chunk)):
                self.wfile.write(self.chunk)
        except (BrokenPipeError, ConnectionResetError):
            self.close_connection = True

    def log_message(self, *_):
        pass


if __name__ == "__main__":
    with ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server:
        print(f"http://127.0.0.1:{server.server_port}", flush=True)
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass
