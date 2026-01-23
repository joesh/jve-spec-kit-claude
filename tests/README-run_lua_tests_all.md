# run_lua_tests_all.sh

Runs every `tests/test_*.lua` (excluding `test_harness.lua`) in its own LuaJIT process and:

- continues past failures (does not stop at first failing test)
- echoes output to the console
- appends failing tests (with full stdout+stderr) to `test-errors.txt` at repo root

## Usage

From repo root:

```bash
./tests/run_lua_tests_all.sh
```

Artifacts:

- `test-errors.txt` (repo root)
