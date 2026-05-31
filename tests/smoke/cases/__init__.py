"""Smoke-test case package.

Ensures the repo root is on ``sys.path`` so test modules can use the
canonical import path ``from tests.smoke.runner.case import JVESmokeCase``
without each file having to insert it manually.

When run via ``python -m unittest discover -s tests/smoke/cases`` from
the repo root, this ``__init__.py`` runs once at package import. When
run via ``python -m unittest tests.smoke.cases.test_X``, same deal.

Direct file invocation (``python tests/smoke/cases/test_X.py``) is no
longer supported — use the ``python -m unittest tests.smoke.cases.X``
form, which is the standard idiom and what ``make smoke`` already does.
"""

import sys
from pathlib import Path

_REPO_ROOT_STR = str(Path(__file__).resolve().parents[3])
if _REPO_ROOT_STR not in sys.path:
    sys.path.insert(0, _REPO_ROOT_STR)
