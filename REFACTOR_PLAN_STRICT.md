# STRICT REFACTOR PLAN - JVE

**Objective:** Address the critical failures and structural weaknesses identified in `USEFUL-CODE-REVIEW.md` to bring the codebase up to professional engineering standards.

## 1. CRITICAL FIXES (Immediate Action Required)

### 1.1. Fix Data Integrity (Transactions)
**Goal:** Ensure database migrations and batch operations are atomic.
- [ ] **Refactor `SqlExecutor::executeStatementBatch`**:
    -   Modify signature to accept an optional boolean `useTransaction` (default: true).
    -   Wrap the loop in `database.transaction()` and `database.commit()`.
    -   On error, call `database.rollback()` before returning false.
    -   **Verification:** Create a test case `test_migration_rollback.lua` that intentionally fails halfway through a script and asserts the schema version has not changed.

### 1.2. Fix Unbounded Memory Leak
**Goal:** Stop `UuidGenerator` from consuming infinite RAM.
- [ ] **Refactor `UuidGenerator`**:
    -   Remove `m_allGeneratedUuids` QSet completely.
    -   Remove `checkForCollision` logic (statistically unnecessary for v4 UUIDs).
    -   Keep `m_generatedUuids` (history per type) but strictly enforce `MAX_UUID_HISTORY` (e.g., last 100 items) for debugging only.
    -   **Verification:** Run a loop generating 1 million UUIDs and monitor memory usage; it should remain flat.

## 2. STRUCTURAL REFACTORING (High Priority)

### 2.1. Fix Brittle SQL Parsing
**Goal:** Prevent parser errors from malformed comments or string literals.
- [ ] **Refactor `SqlExecutor::parseStatementsFromScript`**:
    -   **Plan A (Preferred):** If SQLite driver supports `exec(script)`, use it directly. (Note: Qt `QSqlQuery::exec` usually handles single statements).
    -   **Plan B (Realistic):** Adopt a strict delimiter standard for migration scripts (e.g., `---- GO ----`).
        -   Update `schema.sql` and all migration files to use this delimiter.
        -   Update parser to split *only* on this delimiter, ignoring semicolons.
        -   This eliminates the need to parse SQL syntax (strings, comments, triggers) manually.

### 2.2. Modularize Qt Bindings (The "God File")
**Goal:** Reduce `src/lua/qt_bindings.cpp` (4600+ lines) to manageable components using macros/templates.
- [ ] **Create `src/lua/bindings/` directory**:
    -   Move `qt_bindings.h` to `src/lua/bindings/binding_macros.h`.
- [ ] **Implement Binding Macros**:
    -   Define macros for common patterns:
        ```cpp
        #define BIND_WIDGET_SETTER(WidgetType, MethodName, ParamType) ...
        #define BIND_WIDGET_GETTER(WidgetType, MethodName) ...
        ```
- [ ] **Split `qt_bindings.cpp`**:
    -   `src/lua/bindings/widget_bindings.cpp` (Basic QWidget)
    -   `src/lua/bindings/layout_bindings.cpp` (Layouts)
    -   `src/lua/bindings/control_bindings.cpp` (Buttons, Edits, etc.)
    -   `src/lua/bindings/view_bindings.cpp` (Trees, Lists)
    -   Keep `qt_bindings.cpp` only for registration/initialization.

### 2.3. Optimize String Lookups
**Goal:** Replace O(N) string comparisons with O(1) lookups.
- [ ] **Refactor Enum Mappings**:
    -   Create `static const QHash<QString, ValueType>` maps for:
        -   Cursor shapes (`arrow`, `hand`, etc.)
        -   Orientations (`horizontal`, `vertical`)
        -   Alignments
    -   Refactor `lua_set_widget_cursor` etc. to use `.value(key, default)` lookups.

### 2.4. Fix Namespace Pollution
**Goal:** Hide internal binding functions.
- [ ] **Static/Anonymous Namespaces**:
    -   Mark all `lua_create_*`, `lua_set_*` functions as `static` in their respective `.cpp` files.
    -   Or wrap them in `namespace { ... }`.

## 3. EXECUTION ORDER

1.  **Task 1:** Fix SQL Transactions (Critical Data Integrity).
2.  **Task 2:** Fix UUID Memory Leak (Critical Stability).
3.  **Task 3:** Refactor SQL Parsing (Stability).
4.  **Task 4:** Optimize String Lookups (Performance/Cleanup).
5.  **Task 5:** Split and Macro-ize Qt Bindings (Maintenance).

## 4. VERIFICATION STRATEGY
-   **Build:** `make -j4` must pass with 0 warnings after every task.
-   **Tests:** `ctest` must pass 100%.
-   **Manual:** Verify UI loads correctly after binding refactors using the FCP7 layout test.
