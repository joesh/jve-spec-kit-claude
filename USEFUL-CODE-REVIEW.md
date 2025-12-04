# 1980s Russian Gymnastics Judge Code Review

**Score: 6.8 / 10.0**
*Deductions applied for: Data integrity risks, unbounded memory growth, brittle parsing logic, and maintenance overhead.*

## 1. CRITICAL FAILURES (The "Fall off the Beam" Errors)

### 1.1. Missing Transactions in SQL Execution
**File:** `src/core/persistence/sql_executor.cpp`
**Location:** `executeStatementBatch`
**Verdict:** **DISQUALIFYING ERROR.**
You are executing a batch of SQL statements (migrations!) one by one without a transaction wrapping them.
-   **Scenario:** You have 10 migration steps. Step 5 fails.
-   **Result:** Steps 1-4 are committed. Step 5 is half-baked. The database is now in a corrupted, undefined state that matches no known schema version. You cannot roll back, and you cannot move forward.
-   **Correction:** You **MUST** wrap `executeStatementBatch` (or its call site) in `database.transaction()` and `database.commit() / rollback()`.

### 1.2. Unbounded Memory Leak in UUID Generation
**File:** `src/core/common/uuid_generator.cpp`
**Location:** `recordGeneratedUuid`
**Verdict:** **SEVERE.**
```cpp
// Add to global set
m_allGeneratedUuids.insert(uuid);
```
You are storing *every single UUID ever generated* in `m_allGeneratedUuids` for the purpose of "collision detection".
-   **Reality:** If this system runs for a week or handles high-frequency events (like timeline playback/rendering), this `QSet` will consume gigabytes of RAM.
-   **Correction:** Remove `m_allGeneratedUuids`. If you trust `QUuid::createUuid()` (which you should, it's 128-bit random), collision checking is statistically unnecessary. If you *must* check, use a Bloom filter or a sliding window, but never an infinite set.

## 2. STRUCTURAL WEAKNESSES (Poor Form)

### 2.1. Brittle SQL Parsing
**File:** `src/core/persistence/sql_executor.cpp`
**Location:** `parseStatementsFromScript`
**Verdict:** **AMATEURISH.**
You are manually parsing SQL with string splitting and ad-hoc state machines (`triggerDepth`, `inTrigger`).
-   **Flaw:** A string literal containing a semicolon (e.g., `INSERT INTO logs VALUES ('Error: ; expected');`) or a comment inside a string will break your parser.
-   **Correction:** Do not write your own SQL parsers. If you must split scripts, enforce a strict delimiter (like `GO` or `####`) that is never valid SQL, or rely on SQLite to execute the script (though Qt's `exec` is statement-based). At minimum, document this fragility strictly.

### 2.2. Monolithic "God File" for Bindings
**File:** `src/lua/qt_bindings.cpp`
**Verdict:** **UNSUSTAINABLE.**
This file is 4,600+ lines of repetitive boilerplate.
-   **Flaw:** You are manually unmarshalling arguments for every single widget method. `lua_to_widget`, `luaL_checkstring`, etc., repeated thousands of times.
-   **Correction:** Use a template-based binding generator or at least macros to define these methods. You are writing C in C++.
    -   *Example:* `BIND_SETTER(QLabel, setText, QString)` could replace 15 lines of code.

## 3. STYLE & EXECUTION (Deductions)

### 3.1. Inefficient String Lookups
**File:** `src/lua/qt_bindings.cpp`
**Location:** `lua_set_widget_cursor` (and others)
**Verdict:** **SLOPPY.**
```cpp
if (strcmp(cursor_type, "arrow") == 0) ...
else if (strcmp(cursor_type, "hand") == 0) ...
```
You are doing O(N) string comparisons for enums every time a property changes.
-   **Correction:** Use a `static const QHash<QString, Qt::CursorShape>` or `std::unordered_map`. Initialize it once, look it up in O(1).

### 3.2. Global Function Pollution
**File:** `src/lua/qt_bindings.cpp`
**Verdict:** **UNDISCIPLINED.**
Functions like `lua_create_main_window` seem to be in the global namespace.
-   **Correction:** These should be `static` (internal linkage) or inside an anonymous namespace if they are only used for registration within this file.
