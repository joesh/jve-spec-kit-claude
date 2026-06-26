# Regenerates ${OUTPUT_HEADER} from ${INPUT_TEMPLATE} substituting the
# current git short SHA. Driven by the `generate_build_info` ALL target
# in the top-level CMakeLists.txt so the SHA is fresh on every build.
#
# Inputs (set on the command line via -D):
#   REPO_ROOT       — absolute path to repo root (passed CMAKE_SOURCE_DIR)
#   INPUT_TEMPLATE  — absolute path to src/jve_build_info.h.in
#   OUTPUT_HEADER   — absolute path to src/jve_build_info.h (final header)
#
# configure_file() compares contents and leaves the output untouched when
# unchanged, so SHA-stable rebuilds do NOT re-stat-invalidate every TU
# that includes jve_build_info.h.

if(NOT DEFINED REPO_ROOT)
    message(FATAL_ERROR "generate_build_info: REPO_ROOT not set")
endif()
if(NOT DEFINED INPUT_TEMPLATE)
    message(FATAL_ERROR "generate_build_info: INPUT_TEMPLATE not set")
endif()
if(NOT DEFINED OUTPUT_HEADER)
    message(FATAL_ERROR "generate_build_info: OUTPUT_HEADER not set")
endif()

execute_process(
    COMMAND git rev-parse --short=7 HEAD
    WORKING_DIRECTORY ${REPO_ROOT}
    OUTPUT_VARIABLE JVE_GIT_SHA
    OUTPUT_STRIP_TRAILING_WHITESPACE
    RESULT_VARIABLE GIT_RESULT
)
if(NOT GIT_RESULT EQUAL 0)
    message(FATAL_ERROR "generate_build_info: git rev-parse failed (exit ${GIT_RESULT}) in ${REPO_ROOT}")
endif()

string(LENGTH "${JVE_GIT_SHA}" SHA_LEN)
if(NOT SHA_LEN EQUAL 7)
    message(FATAL_ERROR "generate_build_info: expected 7-char SHA, got '${JVE_GIT_SHA}' (length ${SHA_LEN})")
endif()

configure_file(${INPUT_TEMPLATE} ${OUTPUT_HEADER} @ONLY)
