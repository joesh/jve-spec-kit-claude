#pragma once

namespace JVE {

// Ensures JVE_SQLITE3_PATH is set to a valid SQLite dynamic library.
// Safe to call multiple times; first successful detection sticks.
void EnsureSqliteLibraryEnv();

}  // namespace JVE
