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
from protocol import PROTOCOL_VERSION     # noqa: E402
from resolve_handle import ResolveHandle  # noqa: E402
from verbs import dispatch                # noqa: E402

HELPER_VERSION = "0.1.0"


def parse_args(argv):
    p = argparse.ArgumentParser(description="JVE Resolve helper sidecar")
    p.add_argument("--socket", required=True,
        help="Unix socket path to listen on (matches qt_local_socket client)")
    p.add_argument("--log-level", default="INFO",
        choices=["DEBUG", "INFO", "WARNING", "ERROR"])
    p.add_argument("--allow-test-verbs", action="store_true", default=False,
        help="Enable test-only verbs (apply_test_grade). "
             "Never pass in production.")
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


def _recover_envelope_id(line):
    # Best-effort `id` recovery for the crash-during-dispatch path:
    # we want the JVE client to correlate a crash response to its in-flight
    # request rather than drop it as "unknown id". Returns "" if the line
    # isn't parseable as a JSON object with a string id.
    try:
        obj = json.loads(line)
    except (json.JSONDecodeError, ValueError):
        return ""
    if not isinstance(obj, dict):
        return ""
    candidate = obj.get("id")
    return candidate if isinstance(candidate, str) else ""


def handle_line(line, handle, ledger, allow_test_verbs=False):
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

    response = dispatch(verb, args, handle, envelope_id, HELPER_VERSION,
                        allow_test_verbs=allow_test_verbs)
    return response, idem_key


def serve(sock, handle, ledger, allow_test_verbs=False):
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
                    decoded = line.decode("utf-8")
                    try:
                        response, idem_key = handle_line(
                            decoded, handle, ledger,
                            allow_test_verbs=allow_test_verbs)
                    except Exception as exc:
                        # Dispatch crashed mid-verb: helper state past
                        # this point is suspect — the idempotency
                        # ledger may be inconsistent with what the
                        # Resolve API actually committed, and the verb
                        # may have left transient state in `verbs.py`
                        # module globals. Send the in-flight requester
                        # a structured crash envelope so it can
                        # correlate, then re-raise to terminate the
                        # process. The supervisor's finished_cb
                        # (helper_supervisor.lua) clears state and the
                        # next ensure_client call respawns clean —
                        # spec FR-007 "Wire-level corruption … closes
                        # the socket; the supervisor's next request
                        # respawns" applies to verb crashes too. Prior
                        # behavior (synthesize envelope + keep serving)
                        # contradicted that contract; review HIGH E#8.
                        crash_id = _recover_envelope_id(decoded)
                        log.exception("dispatch crashed (id=%r) — "
                            "writing crash envelope and exiting",
                            crash_id)
                        crash_response = make_error(
                            crash_id, "resolve_api_error",
                            f"helper crashed: {exc}")
                        try:
                            write_envelope(conn, crash_response)
                        except OSError:
                            # Client already gone; the supervisor will
                            # see process-exit and surface its own
                            # helper_unavailable to whatever request is
                            # in flight next. Don't mask the original
                            # exception with the write failure.
                            pass
                        raise
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
        serve(sock, handle, ledger,
              allow_test_verbs=args.allow_test_verbs)
    finally:
        sock.close()
        if os.path.exists(args.socket):
            os.unlink(args.socket)


if __name__ == "__main__":
    main(sys.argv[1:])
