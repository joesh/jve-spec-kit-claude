import os
import time

__all__ = ["now", "is_enabled"]

_ENABLED = os.environ.get("KRONO_TRACE") == "1"

# Allow toggling at runtime for tests

def is_enabled():
    global _ENABLED
    return _ENABLED


def set_enabled(value: bool):
    global _ENABLED
    _ENABLED = bool(value)


def now():
    return time.perf_counter() * 1000
