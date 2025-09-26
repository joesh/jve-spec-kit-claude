#include "sql_executor.h"
#include "schema_constants.h"

#include <QFile>
#include <QTextStream>
#include <QSqlQuery>
#include <QSqlError>
#include <QLoggingCategory>
#include <QUuid>

Q_LOGGING_CATEGORY(jveSqlExecutor, "jve.sql.executor")

bool SqlExecutor::executeSqlScript(QSqlDatabase& database, const QString& scriptPath)
{
    qCDebug(jveSqlExecutor) << "Executing SQL script:" << scriptPath;
    
    // Algorithm: Load file → Parse statements → Execute batch → Verify results
    QString script = loadScriptFromFile(scriptPath);
    if (script.isEmpty()) {
        return false;
    }
    
    QStringList statements = parseStatementsFromScript(script);
    if (statements.isEmpty()) {
        qCWarning(jveSqlExecutor) << "No executable statements found in script";
        return false;
    }
    
    bool success = executeStatementBatch(database, statements);
    
    if (success) {
        qCDebug(jveSqlExecutor) << "SQL script executed successfully:" << scriptPath;
    }
    
    return success;
}

bool SqlExecutor::applyMigrationVersion(QSqlDatabase& database, int version)
{
    qCDebug(jveSqlExecutor) << "Applying migration version:" << version;
    
    // Algorithm: Resolve path → Load script → Execute → Log result
    QString scriptPath = resolveMigrationPath(version);
    
    if (scriptPath.isEmpty()) {
        qCCritical(jveSqlExecutor) << "Migration file not found for version" << version;
        return false;
    }
    
    bool success = executeSqlScript(database, scriptPath);
    
    if (success) {
        qCInfo(jveSqlExecutor) << "Migration version" << version << "applied successfully";
    } else {
        qCCritical(jveSqlExecutor) << "Failed to apply migration version" << version;
    }
    
    return success;
}

QSqlDatabase SqlExecutor::createMigrationConnection(const QString& projectPath)
{
    // Algorithm: Generate name → Configure → Open → Verify
    QString connectionName = generateConnectionName(projectPath);
    
    QSqlDatabase database = QSqlDatabase::addDatabase("QSQLITE", connectionName);
    database.setDatabaseName(projectPath);
    
    if (!database.open()) {
        qCCritical(jveSqlExecutor) << "Failed to create database connection:" 
                                   << database.lastError().text();
        QSqlDatabase::removeDatabase(connectionName);
        return QSqlDatabase(); // Return invalid database
    }
    
    qCDebug(jveSqlExecutor) << "Migration connection created:" << connectionName;
    return database;
}

QString SqlExecutor::loadScriptFromFile(const QString& scriptPath)
{
    QFile file(scriptPath);
    
    if (!file.open(QIODevice::ReadOnly | QIODevice::Text)) {
        qCCritical(jveSqlExecutor) << "Failed to open SQL script:" << scriptPath;
        return QString();
    }
    
    QTextStream stream(&file);
    QString script = stream.readAll();
    
    if (script.isEmpty()) {
        qCWarning(jveSqlExecutor) << "Empty SQL script:" << scriptPath;
    }
    
    return script;
}

QStringList SqlExecutor::parseStatementsFromScript(const QString& script)
{
    qCDebug(jveSqlExecutor) << "Parsing SQL script with" << script.length() << "characters";
    
    // Parse SQL statements while preserving execution order and handling blocks
    QStringList cleanStatements;
    QString currentStatement;
    QStringList lines = script.split('\n');
    int blockDepth = 0;
    
    for (const QString& line : lines) {
        QString trimmedLine = line.trimmed();
        
        // Skip empty lines and full-line comments
        if (trimmedLine.isEmpty() || trimmedLine.startsWith("--")) {
            continue;
        }
        
        // Remove inline comments (-- comment)
        int commentPos = trimmedLine.indexOf("--");
        if (commentPos >= 0) {
            trimmedLine = trimmedLine.left(commentPos).trimmed();
            if (trimmedLine.isEmpty()) {
                continue;
            }
        }
        
        // Skip PRAGMA statements that can't be executed inside transactions
        if (trimmedLine.toUpper().startsWith("PRAGMA JOURNAL_MODE") ||
            trimmedLine.toUpper().startsWith("PRAGMA SYNCHRONOUS") ||
            trimmedLine.toUpper().startsWith("PRAGMA FOREIGN_KEYS")) {
            qCDebug(jveSqlExecutor) << "Skipping pragma in transaction:" << trimmedLine;
            continue;
        }
        
        // Accumulate lines until we hit a semicolon
        if (currentStatement.isEmpty()) {
            currentStatement = trimmedLine;
        } else {
            currentStatement += " " + trimmedLine;
        }
        
        // Track block depth for triggers and views
        if (trimmedLine.toUpper().contains("BEGIN")) {
            blockDepth++;
        }
        if (trimmedLine.toUpper().startsWith("END")) {
            blockDepth--;
        }
        
        // Check if statement is complete 
        // Statement ends with semicolon AND we're not inside a block
        if (trimmedLine.endsWith(';') && blockDepth == 0) {
            QString completeStatement = currentStatement.trimmed();
            if (!completeStatement.isEmpty()) {
                qCDebug(jveSqlExecutor) << "Adding statement:" << completeStatement.left(50) + "...";
                cleanStatements.append(completeStatement);
            }
            currentStatement.clear();
        }
    }
    
    // Handle any remaining statement without semicolon
    if (!currentStatement.trimmed().isEmpty()) {
        qCDebug(jveSqlExecutor) << "Adding final statement:" << currentStatement.trimmed().left(50) + "...";
        cleanStatements.append(currentStatement.trimmed());
    }
    
    qCDebug(jveSqlExecutor) << "Parsed" << cleanStatements.size() << "SQL statements";
    return cleanStatements;
}

bool SqlExecutor::executeStatementBatch(QSqlDatabase& database, const QStringList& statements)
{
    QSqlQuery query(database);
    
    qCDebug(jveSqlExecutor) << "Executing" << statements.size() << "statements";
    
    for (int i = 0; i < statements.size(); ++i) {
        const QString& statement = statements[i];
        qCDebug(jveSqlExecutor) << "Statement" << (i+1) << ":" << statement.left(50) + "...";
        
        if (!query.exec(statement)) {
            qCCritical(jveSqlExecutor) << "SQL execution failed:" 
                                       << query.lastError().text()
                                       << "Full Statement:" << statement;
            return false;
        }
    }
    
    return true;
}

QString SqlExecutor::resolveMigrationPath(int version)
{
    if (version == schema::INITIAL_SCHEMA_VERSION) {
        // Check resource path first, then development path
        if (QFile::exists(schema::RESOURCE_SCHEMA_PATH)) {
            return schema::RESOURCE_SCHEMA_PATH;
        }
        if (QFile::exists(schema::DEV_SCHEMA_PATH)) {
            return schema::DEV_SCHEMA_PATH;
        }
        return QString();
    }
    
    // Check for version-specific migration files
    QString resourcePath = QString(schema::MIGRATION_RESOURCE_PATTERN).arg(version);
    if (QFile::exists(resourcePath)) {
        return resourcePath;
    }
    
    QString devPath = QString(schema::MIGRATION_DEV_PATTERN).arg(version);
    if (QFile::exists(devPath)) {
        return devPath;
    }
    
    return QString();
}

QString SqlExecutor::generateConnectionName(const QString& projectPath)
{
    // Generate unique connection name to avoid conflicts
    QString baseName = QString(schema::MIGRATION_CONNECTION_PREFIX) + 
                      QUuid::createUuid().toString(QUuid::WithoutBraces);
    return baseName;
}