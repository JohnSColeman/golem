#!/usr/bin/env python3
"""A minimal external HTTP peer for the outgoing-HTTP contract probes (49/50).

`HttpOutgoingClient.send` (`wasi:http/client`, preview 3) issues a real client request
from inside the guest; this process is the plain HTTP server on the other end of that
request, standing in for "some real endpoint under test control" the way
durable-stream-peer.py stands in for the durable-stream protocol's own peer.

POST /echo   echoes the request body back verbatim and mirrors any `x-probe-echo`
             request header onto the response, so both probes can assert the full
             request -> response round-trip, not just that a call returned 200.

Usage: http-echo-peer.py <port>
"""

import sys
from http.server import BaseHTTPRequestHandler, HTTPServer


class Peer(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    # Nagle's algorithm (on by default) batches small writes before sending them, and badly
    # interacts with delayed-ACK on the other end: a multi-MB body with no large-body probe to
    # catch it took over six minutes round-trip over plain loopback before this was set, because
    # without TCP_NODELAY each of this handler's own small socket writes waits out that delay.
    disable_nagle_algorithm = True

    def log_message(self, *args):  # keep the driver's output readable
        pass

    def do_POST(self):
        if not self.path.startswith("/echo"):
            self.send_response(404)
            self.send_header("content-length", "0")
            self.end_headers()
            return
        length = int(self.headers.get("content-length") or 0)
        # Read in bounded chunks rather than one `rfile.read(length)` call: large single reads
        # measured far slower than the same bytes read incrementally, for reasons independent of
        # TCP_NODELAY above (both fixes were needed to get a multi-MB round-trip down from minutes
        # to a fraction of a second).
        chunks = []
        remaining = length
        while remaining > 0:
            chunk = self.rfile.read(min(remaining, 65536))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        body = b"".join(chunks)
        self.send_response(200)
        echoed = self.headers.get("x-probe-echo")
        if echoed is not None:
            self.send_header("x-probe-echo", echoed)
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        if body:
            self.wfile.write(body)


if __name__ == "__main__":
    HTTPServer(("127.0.0.1", int(sys.argv[1])), Peer).serve_forever()
