#include "core/sqlite_env.h"

#include <QFile>
#include <QLoggingCategory>
#include <QStringList>

Q_LOGGING_CATEGORY(jveSqliteEnv, "jve.sqlite")

namespace JVE {

namespace {

QStringList candidatePaths()
{
    QStringList candidates;
    const QByteArray homebrewPrefix = qgetenv("HOMEBREW_PREFIX");
    if (!homebrewPrefix.isEmpty()) {
        candidates << QString::fromLatin1(homebrewPrefix)
                          .append("/opt/sqlite/lib/libsqlite3.dylib");
    }
    candidates << "/opt/homebrew/opt/sqlite/lib/libsqlite3.dylib"
               << "/usr/local/opt/sqlite/lib/libsqlite3.dylib"
               << "/usr/local/lib/libsqlite3.dylib"
               << "/usr/local/lib/libsqlite3.so"
               << "/usr/lib/libsqlite3.dylib"
               << "/usr/lib/libsqlite3.so"
               << "/lib/x86_64-linux-gnu/libsqlite3.so"
               << "/lib64/libsqlite3.so";
    return candidates;
}

}  // namespace

void EnsureSqliteLibraryEnv()
{
    if (!qEnvironmentVariableIsEmpty("JVE_SQLITE3_PATH")) {
        return;
    }

    const QStringList candidates = candidatePaths();
    for (const QString& candidate : candidates) {
        if (candidate.isEmpty()) {
            continue;
        }
        if (QFile::exists(candidate)) {
            qputenv("JVE_SQLITE3_PATH", candidate.toUtf8());
            qCInfo(jveSqliteEnv, "Auto-selected SQLite library: %s", qPrintable(candidate));
            return;
        }
    }

    qCWarning(jveSqliteEnv,
              "Unable to auto-select SQLite library; set JVE_SQLITE3_PATH manually.");
}

}  // namespace JVE
