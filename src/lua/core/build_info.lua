-- Build provenance constants. Single source of truth for the git SHA
-- the running JVE was compiled from. Populated by the C++ binding
-- `qt_get_build_info`, which reads the value from a header generated at
-- build time by cmake/generate_build_info.cmake (feature 027 T001).
--
-- Used by the bug-reporter pipeline so every capture and every cluster
-- signature includes a verifiable version anchor.

local info = qt_get_build_info()
assert(info and info.git_sha and #info.git_sha == 7,
    "core.build_info: qt_get_build_info() returned no valid 7-char git_sha — was generate_build_info CMake target wired?")

return {
    git_sha = info.git_sha,
}
