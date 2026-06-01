#!/usr/bin/env python3
# Resolve helper — sidecar process that owns the DaVinci Resolve scripting
# handle (spec 023 T021, FR-005, FR-021). JVE spawns this via `qt_process_*`
# and talks to it over a Unix domain socket (`qt_local_socket_*`) using the
# line-delimited JSON envelope from contracts/helper-protocol.md.
#
# This file is the supervisor-facing entry: argv parsing, socket lifecycle,
# the read/dispatch/write loop. Verb implementations live in `verbs.py`;
# Resolve handle management in `resolve_handle.py`; idempotency in `ledger.py`.
#
# Per FR-021 the helper holds NO timeline model state — only its single
# Resolve handle + an in-memory idempotency ledger. State lives in JVE.

import argparse
import json
import logging
import os
import socket
import sys
from pathlib import Path

THIS_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(THIS_DIR))

from ledger import IdempotencyLedger      # noqa: E402
from resolve_handle import ResolveHandle  # noqa: E402
from verbs import dispatch                # noqa: E402

PROTOCOL_VERSION = 1
HELPER_VERSION = "0.1.0"


def parse_args(argv):
    p = argparse.ArgumentParser(description="JVE Resolve helper sidecar")
    p.add_argument("--socket", required=True,
        help="Unix socket path to listen on (matches qt_local_socket client)")
    p.add_argument("--log-level", default="INFO",
        choices=["DEBUG", "INFO", "WARNING", "ERROR"])
    return p.parse_args(argv)


def setup_logging(level):
    logging.basicConfig(
        level=getattr(logging, level),
        format="resolve-helper [%(asctime)s %(levelname)s] %(message)s",
        stream=sys.stderr,
    )


def bind_socket(path):
    # Single-client server, blocking accept (FR-005: separate process,
    # one Resolve owner). Stale socket file at path is removed first —
    # the previous helper crashed or was killed mid-run.
    if os.path.exists(path):
        os.unlink(path)
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.bind(path)
    sock.listen(1)
    return sock


def write_envelope(conn, envelope):
    line = json.dumps(envelope, separators=(",", ":"))
    assert "\n" not in line, "envelope JSON must not contain newline"
    conn.sendall((line + "\n").encode("utf-8"))


def make_error(envelope_id, code, message):
    return {
        "v": PROTOCOL_VERSION,
        "id": envelope_id,
        "ok": False,
        "error": {"code": code, "message": message},
    }


def handle_line(line, handle, ledger):
    # Returns (response_envelope, idempotency_key_or_None).
    # bad_request errors carry the empty correlation id ("") when the
    # client's line was unparseable — documented in helper-protocol.md.
    try:
        req = json.loads(line)
    except json.JSONDecodeError as exc:
        return make_error("", "bad_request",
            f"malformed JSON: {exc}"), None

    if not isinstance(req, dict):
        return make_error("", "bad_request",
            "envelope must be JSON object"), None
    if req.get("v") != PROTOCOL_VERSION:
        return make_error(req.get("id", ""), "bad_request",
            f"unsupported protocol version {req.get('v')!r}"), None
    envelope_id = req.get("id")
    if not isinstance(envelope_id, str) or not envelope_id:
        return make_error("", "bad_request",
            "missing 'id' correlation field"), None
    verb = req.get("verb")
    args = req.get("args")
    if not isinstance(verb, str) or not verb:
        return make_error(envelope_id, "bad_request",
            "missing 'verb'"), None
    if not isinstance(args, dict):
        return make_error(envelope_id, "bad_request",
            "missing 'args' object"), None

    idem_key = ledger.compute_key(verb, args)
    if idem_key is not None:
        cached = ledger.lookup(idem_key)
        if cached is not None:
            cached_resp = dict(cached)
            cached_resp["id"] = envelope_id
            return cached_resp, idem_key

    response = dispatch(verb, args, handle, envelope_id, HELPER_VERSION)
    return response, idem_key


def serve(sock, handle, ledger):
    log = logging.getLogger("helper")
    while True:
        log.info("waiting for client on socket")
        conn, _ = sock.accept()
        log.info("client connected")
        with conn:
            buf = b""
            while True:
                chunk = conn.recv(4096)
                if not chunk:
                    log.info("client disconnected")
                    break
                buf += chunk
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    if not line.strip():
                        continue
                    try:
                        response, idem_key = handle_line(
                            line.decode("utf-8"), handle, ledger)
                    except Exception as exc:
                        log.exception("dispatch crashed")
                        response = make_error("", "resolve_api_error",
                            f"helper crashed: {exc}")
                        idem_key = None
                    write_envelope(conn, response)
                    if idem_key is not None and response.get("ok") is True:
                        ledger.store(idem_key, response)


def main(argv):
    args = parse_args(argv)
    setup_logging(args.log_level)
    log = logging.getLogger("helper")

    sock = bind_socket(args.socket)
    log.info("bound socket %s", args.socket)
    handle = ResolveHandle()
    ledger = IdempotencyLedger()
    try:
        serve(sock, handle, ledger)
    finally:
        sock.close()
        if os.path.exists(args.socket):
            os.unlink(args.socket)


if __name__ == "__main__":
    main(sys.argv[1:])
