#pragma once
// debug_terminal.h — Lua REPL over a Unix socket
//
// Listens on a QLocalSocket (path from --control-socket flag), accepts
// a single client, reads newline-delimited Lua chunks, evaluates each
// in the running JVE's main Lua state, and writes a one-line response.
//
// One connection at a time. Subsequent connect attempts wait until the
// current client disconnects. Gated by CLI flag — production builds
// invoked without the flag never open the server.

#include <QLocalServer>
#include <QLocalSocket>
#include <QObject>
#include <QPointer>
#include <QString>

extern "C" {
#include <lua.h>
}

class DebugTerminal : public QObject {
    Q_OBJECT
public:
    DebugTerminal(const QString& socket_path, lua_State* L, QObject* parent = nullptr);
    ~DebugTerminal() override;

    // Start listening. Returns true if the server bound the path
    // successfully. Logs + returns false on failure (path collision,
    // permissions). Non-fatal — JVE keeps running without the terminal.
    bool start();

private slots:
    void onNewConnection();
    void onReadyRead();
    void onDisconnected();

private:
    QString m_socket_path;
    lua_State* m_lua_state;
    QLocalServer* m_server = nullptr;
    QPointer<QLocalSocket> m_client;
    QByteArray m_pending;  // accumulator for partial lines

    void handleLine(const QByteArray& line);
    void writeError(const QByteArray& msg);
    void writeReply(const QByteArray& body);
};
