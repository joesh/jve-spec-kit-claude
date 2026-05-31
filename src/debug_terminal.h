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
#include <QTimer>

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

    // Invoked from a Lua callback (registered as a C function global at
    // start time) each time command_manager bumps the top-level command
    // event counter. Resolves a pending WAIT_BUMP whose snap threshold
    // is now exceeded. No-op otherwise.
    void notifyTopLevelEventBumped(int new_count);

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

    // Deferred-reply state for the WAIT_BUMP protocol verb. While
    // m_wait_active is true, the client is parked waiting for the
    // top-level command counter to exceed m_wait_snap; either the next
    // bump or m_wait_timer's timeout writes the reply and clears the
    // state. Single pending wait at a time (matches single-client
    // protocol invariant). Disconnect resets all of this.
    bool m_wait_active = false;
    int m_wait_snap = 0;
    QTimer* m_wait_timer = nullptr;

    void handleLine(const QByteArray& line);
    void handleWaitBump(int snap, int timeout_ms);
    void completeWait(bool ok, int count);
    void writeError(const QByteArray& msg);
    void writeReply(const QByteArray& body);
};
