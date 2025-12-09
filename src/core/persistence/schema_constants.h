#pragma once

/**
 * Schema constants for JVE Editor database system
 * Constitutional requirement: No hardcoded constants (Rule 2.14)
 */

namespace schema {

// Schema versioning
static const int INITIAL_SCHEMA_VERSION = 1;
static const int CURRENT_SCHEMA_VERSION = 1;

// Database configuration
static const char* const WAL_JOURNAL_MODE = "WAL";
static const char* const NORMAL_SYNCHRONOUS = "NORMAL";

// Required tables for schema validation
static const char* const REQUIRED_TABLES[] = {
    "schema_version",
    "projects", 
    "sequences",
    "tracks",
    "media",
    "clips", 
    "properties",
    "commands",
    "snapshots",
    "tag_namespaces",
    "tags",
    "tag_assignments"
};

static const int REQUIRED_TABLES_COUNT = sizeof(REQUIRED_TABLES) / sizeof(REQUIRED_TABLES[0]);

// Required views for debugging support
static const char* const REQUIRED_VIEWS[] = {
    "project_summary",
    "timeline_integrity", 
    "command_replay_status"
};

static const int REQUIRED_VIEWS_COUNT = sizeof(REQUIRED_VIEWS) / sizeof(REQUIRED_VIEWS[0]);

// SQL pragma settings
static const char* const ENABLE_FOREIGN_KEYS = "PRAGMA foreign_keys = ON";
static const char* const CHECK_FOREIGN_KEYS = "PRAGMA foreign_keys";
static const char* const SET_WAL_MODE = "PRAGMA journal_mode = WAL";
static const char* const CHECK_JOURNAL_MODE = "PRAGMA journal_mode";

// Schema version queries
static const char* const CHECK_SCHEMA_TABLE = 
    "SELECT name FROM sqlite_master WHERE type='table' AND name='schema_version'";
static const char* const GET_MAX_VERSION = 
    "SELECT MAX(version) FROM schema_version";
static const char* const CHECK_NULL_SEQUENCES = 
    "SELECT COUNT(*) FROM commands WHERE sequence_number IS NULL";

// Resource paths
static const char* const RESOURCE_SCHEMA_PATH = ":/sql/schema.sql";
static const char* const DEV_SCHEMA_PATH = "../src/core/persistence/schema.sql";

// Migration file patterns  
static const char* const MIGRATION_RESOURCE_PATTERN = ":/sql/migration_v%1.sql";
static const char* const MIGRATION_DEV_PATTERN = "migrations/migration_v%1.sql";

// Database connection naming
static const char* const MIGRATION_CONNECTION_PREFIX = "migration_";

// Performance and validation limits
static const int MAX_VALIDATION_ERRORS = 10;
static const int SCHEMA_VALIDATION_TIMEOUT_MS = 5000;

} // namespace schema
