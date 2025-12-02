#include <QtTest>
#include <QSqlDatabase>
#include <QSqlQuery>
#include <QTemporaryFile>
#include "core/persistence/sql_executor.h"

class TestSqlTransaction : public QObject
{
    Q_OBJECT
private slots:
    void testTransactionRollback()
    {
        // Setup in-memory DB
        QString dbName = "test_transaction_db";
        {
            QSqlDatabase db = QSqlDatabase::addDatabase("QSQLITE", dbName);
            db.setDatabaseName(":memory:");
            QVERIFY(db.open());
            
            QSqlQuery query(db);
            QVERIFY(query.exec("CREATE TABLE test (id INTEGER PRIMARY KEY, val TEXT);"));
        }

        QSqlDatabase db = QSqlDatabase::database(dbName);

        // Create script file
        QTemporaryFile scriptFile;
        scriptFile.setAutoRemove(false);  // Don't delete until we're done

        if (!scriptFile.open()) {
            QFAIL("Failed to open temporary file");
        }
        QString scriptPath = scriptFile.fileName();

        QTextStream stream(&scriptFile);
        stream << "INSERT INTO test (id, val) VALUES (1, 'A');\n";
        stream << "---- GO ----\n";
        stream << "INSERT INTO test (id, val) VALUES (2, 'B');\n";
        stream << "---- GO ----\n";
        stream << "INSERT INTO test (id, val) VALUES (1, 'C');\n"; // Duplicate key
        stream.flush();
        scriptFile.close();

        // Execute - should fail on duplicate key
        bool success = SqlExecutor::executeSqlScript(db, scriptPath);
        QVERIFY(!success);

        // Verify rollback - no data should be committed
        QSqlQuery query(db);
        QVERIFY(query.exec("SELECT COUNT(*) FROM test;"));
        QVERIFY(query.next());
        int count = query.value(0).toInt();
        QCOMPARE(count, 0);

        // Cleanup
        QFile::remove(scriptPath);
    }
};

QTEST_MAIN(TestSqlTransaction)
#include "test_sql_transaction.moc"

