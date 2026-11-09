#!/usr/bin/env python3
"""A minimal external durable-stream peer, for the contract-test driver.

The worker executor performs the HTTP itself; the guest only talks to
`golem:agent/durable-streams`. So this server implements the peer side of that
contract, modelled on the fake peer in
`golem-worker-executor/tests/external_durable_stream.rs`:

GET  /stream?offset=<opaque>   read a batch
     offset "-1"               from the beginning
     offset "tail-opaque"      at the tail, so an empty batch
     anything else             410 Gone
     response headers          stream-next-offset, stream-up-to-date, stream-closed

POST /stream                   append one message
     request headers           producer-id, producer-epoch, producer-seq,
                               optional stream-closed: true
     response                  200 for a new producer tuple, 204 for a repeat,
                               echoing producer-epoch / producer-seq and, unless
                               a repeat, stream-next-offset

A repeated (producer, epoch, sequence) tuple must carry an identical body: the
writer retries the exact pending request, so a changed payload is a defect. This
peer asserts that and records it in /appends for the driver to check.

Usage: durable-stream-peer.py <port>
"""

import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

# The batch a reader sees from the beginning. The literals matter: a JSON stream
# must preserve each message's text exactly, so 9007199254740993 must not be
# rounded through a double.
FIRST_BATCH = b'[[7,3],9007199254740993,{"a":false}]'

appends = []  # every attempt, in order
effects = []  # deduplicated by (producer, epoch, sequence)


class Peer(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):  # keep the driver's output readable
        pass

    def _send(self, status, headers=None, body=b""):
        self.send_response(status)
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        if body:
            self.wfile.write(body)

    def do_GET(self):
        if self.path.startswith("/appends"):
            body = json.dumps(appends).encode()
            return self._send(200, {"content-type": "application/json"}, body)
        if not self.path.startswith("/stream"):
            return self._send(404)
        offset = ""
        if "?" in self.path:
            for pair in self.path.split("?", 1)[1].split("&"):
                key, _, value = pair.partition("=")
                if key == "offset":
                    offset = value
        tail = {
            "content-type": "application/json",
            "stream-next-offset": "tail-opaque",
            "stream-up-to-date": "true",
            "stream-closed": "true",
        }
        if offset == "-1":
            return self._send(200, tail, FIRST_BATCH)
        if offset in ("now", "tail-opaque"):
            return self._send(200, tail, b"[]")
        return self._send(410)

    def do_POST(self):
        if not self.path.startswith("/stream"):
            return self._send(404)
        length = int(self.headers.get("content-length") or 0)
        body = self.rfile.read(length) if length else b""
        attempt = {
            "producer": self.headers.get("producer-id", ""),
            "epoch": self.headers.get("producer-epoch", ""),
            "sequence": self.headers.get("producer-seq", ""),
            "body": body.decode("utf-8", "replace"),
            "close": self.headers.get("stream-closed") == "true",
        }
        appends.append(attempt)
        tuple_key = (attempt["producer"], attempt["epoch"], attempt["sequence"])
        previous = next((e for e in effects if e["key"] == tuple_key), None)
        if previous is not None:
            assert previous["attempt"] == attempt, (
                "a producer tuple must never change its payload or close flag: "
                f"{previous['attempt']} then {attempt}"
            )
            duplicate, offset = True, previous["offset"]
        else:
            offset = len(effects) + 1
            effects.append({"key": tuple_key, "attempt": attempt, "offset": offset})
            duplicate = False
        headers = {
            "producer-epoch": attempt["epoch"],
            "producer-seq": attempt["sequence"],
        }
        if not duplicate or attempt["close"]:
            headers["stream-next-offset"] = f"receipt-{offset}"
        if attempt["close"]:
            headers["stream-closed"] = "true"
        self._send(204 if duplicate else 200, headers)


if __name__ == "__main__":
    HTTPServer(("127.0.0.1", int(sys.argv[1])), Peer).serve_forever()
