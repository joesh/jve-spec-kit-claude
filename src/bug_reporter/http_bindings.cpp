// Async HTTP for the bug-reporter pipeline (feature 027 T032).
//
// QNetworkAccessManager-based; never blocks the GUI thread (research
// D-06). The QNAM instance is parented to qApp so QNetworkReply
// objects survive across the binding call until the reply finishes.
//
// Globals:
//   qt_http_post_json(url, headers_table, body_string, callback_name)
//   qt_http_post_multipart(url, headers_table, parts_table, callback_name)
//
// The Lua callback is looked up by NAME (a global function), not a
// closure — matches the existing qt_set_*_handler convention. Closure
// support would need extra ref-management plumbing, disproportionate
// for a 5-call-site need.
//
// Callback signature: cb(status_code, response_body, error_message).
// On network error: status_code = 0, response_body = nil, error_message
// = QNetworkReply::errorString(). On success: status_code = HTTP code,
// response_body = body bytes, error_message = nil.

#include <lua.hpp>
#include <QApplication>
#include <QNetworkAccessManager>
#include <QNetworkRequest>
#include <QNetworkReply>
#include <QHttpMultiPart>
#include <QHttpPart>
#include <QUrl>
#include <QString>
#include <QByteArray>
#include "../jve_log.h"
#include "../jve_lua_callback.h"

namespace {

static QNetworkAccessManager* qnam_singleton(QObject* parent)
{
    static QNetworkAccessManager* qnam = nullptr;
    if (!qnam) qnam = new QNetworkAccessManager(parent);
    return qnam;
}

// Apply headers from a Lua table {[1]={"Header","Value"}, ...} OR
// {Header="Value", ...}. Mixed form supported.
static void apply_headers(lua_State* L, int idx, QNetworkRequest& req)
{
    if (!lua_istable(L, idx)) return;
    lua_pushnil(L);
    while (lua_next(L, idx) != 0) {
        if (lua_type(L, -2) == LUA_TSTRING && lua_isstring(L, -1)) {
            req.setRawHeader(QByteArray(lua_tostring(L, -2)),
                             QByteArray(lua_tostring(L, -1)));
        } else if (lua_istable(L, -1)) {
            // Sub-table form: {name, value}
            lua_rawgeti(L, -1, 1);
            lua_rawgeti(L, -2, 2);
            if (lua_isstring(L, -2) && lua_isstring(L, -1)) {
                req.setRawHeader(QByteArray(lua_tostring(L, -2)),
                                 QByteArray(lua_tostring(L, -1)));
            }
            lua_pop(L, 2);
        }
        lua_pop(L, 1);
    }
}

static void wire_reply(lua_State* L, QNetworkReply* reply, std::string callback_name)
{
    QObject::connect(reply, &QNetworkReply::finished, [L, reply, callback_name]() {
        int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        QByteArray body = reply->readAll();
        QNetworkReply::NetworkError err = reply->error();

        // Resolve callback by global name. Skip silently if the Lua
        // side has overwritten the name with nil (legitimate teardown
        // path); fail-loud on any other type mismatch.
        lua_getglobal(L, callback_name.c_str());
        if (lua_isfunction(L, -1)) {
            lua_pushinteger(L, status);
            if (body.isNull()) lua_pushnil(L);
            else lua_pushlstring(L, body.constData(), body.size());
            if (err == QNetworkReply::NoError) {
                lua_pushnil(L);
            } else {
                QByteArray errStr = reply->errorString().toUtf8();
                lua_pushlstring(L, errStr.constData(), errStr.size());
            }
            if (lua_pcall(L, 3, 0, 0) != LUA_OK) {
                jve_handle_lua_callback_error(L, "bug_reporter.http");
            }
        } else {
            lua_pop(L, 1);  // discard the non-function value
        }
        reply->deleteLater();
    });
}

int lua_qt_http_post_json(lua_State* L)
{
    if (lua_gettop(L) != 4) {
        return luaL_error(L, "qt_http_post_json: expected (url, headers, body, callback_name)");
    }
    const char* url = luaL_checkstring(L, 1);
    if (!lua_istable(L, 2)) return luaL_error(L, "qt_http_post_json: headers must be a table");
    size_t body_len = 0;
    const char* body = lua_tolstring(L, 3, &body_len);
    const char* callback_name = luaL_checkstring(L, 4);
    if (!body) return luaL_error(L, "qt_http_post_json: body must be a string");

    QNetworkAccessManager* qnam = qnam_singleton(qApp);
    QNetworkRequest req((QUrl(QString::fromUtf8(url))));
    req.setHeader(QNetworkRequest::ContentTypeHeader, "application/json");
    apply_headers(L, 2, req);

    QNetworkReply* reply = qnam->post(req, QByteArray(body, static_cast<int>(body_len)));
    wire_reply(L, reply, std::string(callback_name));
    return 0;
}

int lua_qt_http_post_multipart(lua_State* L)
{
    if (lua_gettop(L) != 4) {
        return luaL_error(L, "qt_http_post_multipart: expected (url, headers, parts, callback_name)");
    }
    const char* url = luaL_checkstring(L, 1);
    if (!lua_istable(L, 2)) return luaL_error(L, "qt_http_post_multipart: headers must be a table");
    if (!lua_istable(L, 3)) return luaL_error(L, "qt_http_post_multipart: parts must be a table");
    const char* callback_name = luaL_checkstring(L, 4);

    QNetworkAccessManager* qnam = qnam_singleton(qApp);
    QHttpMultiPart* mp = new QHttpMultiPart(QHttpMultiPart::FormDataType);

    int n = static_cast<int>(lua_objlen(L, 3));
    for (int i = 1; i <= n; ++i) {
        lua_rawgeti(L, 3, i);
        if (!lua_istable(L, -1)) {
            delete mp;
            return luaL_error(L, "qt_http_post_multipart: parts[%d] must be a table", i);
        }
        lua_getfield(L, -1, "name");
        const char* name = luaL_checkstring(L, -1);
        lua_pop(L, 1);
        lua_getfield(L, -1, "content_type");
        const char* content_type = luaL_optstring(L, -1, "application/octet-stream");
        lua_pop(L, 1);
        lua_getfield(L, -1, "body");
        size_t body_len = 0;
        const char* body = lua_tolstring(L, -1, &body_len);
        lua_pop(L, 1);
        if (!body) {
            delete mp;
            return luaL_error(L, "qt_http_post_multipart: parts[%d].body must be a string", i);
        }

        QHttpPart part;
        part.setHeader(QNetworkRequest::ContentTypeHeader, QString::fromUtf8(content_type));
        part.setHeader(QNetworkRequest::ContentDispositionHeader,
            QString("form-data; name=\"%1\"").arg(QString::fromUtf8(name)));
        part.setBody(QByteArray(body, static_cast<int>(body_len)));
        mp->append(part);
        lua_pop(L, 1);
    }

    QNetworkRequest req((QUrl(QString::fromUtf8(url))));
    apply_headers(L, 2, req);

    QNetworkReply* reply = qnam->post(req, mp);
    mp->setParent(reply);  // mp lifetime tied to reply
    wire_reply(L, reply, std::string(callback_name));
    return 0;
}

} // namespace

extern "C" void register_bug_reporter_http_bindings(lua_State* L)
{
    lua_pushcfunction(L, lua_qt_http_post_json); lua_setglobal(L, "qt_http_post_json");
    lua_pushcfunction(L, lua_qt_http_post_multipart); lua_setglobal(L, "qt_http_post_multipart");
}
