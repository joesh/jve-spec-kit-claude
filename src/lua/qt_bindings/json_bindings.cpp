#include "binding_macros.h"
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>
#include <QJsonValue>
#include <QVariant>

// Helper function to convert Lua table to QJsonValue
static QJsonValue luaValueToJsonValue(lua_State* L, int index); // Forward declaration

static QJsonValue luaTableToJsonValue(lua_State* L, int index) {
    // Normalize index to absolute
    if (index < 0) {
        index = lua_gettop(L) + index + 1;
    }

    // Check if it's an array (sequential integer keys starting from 1)
    bool isArray = true;
    lua_pushnil(L);
    while (lua_next(L, index) != 0) {
        if (lua_type(L, -2) != LUA_TNUMBER) {
            isArray = false;
            lua_pop(L, 2); // Pop value and key
            break;
        }
        lua_pop(L, 1); // Pop value
    }

    if (isArray) {
        QJsonArray array;
        int len = lua_objlen(L, index); // LuaJIT uses lua_objlen instead of lua_rawlen
        for (int i = 1; i <= len; i++) {
            lua_rawgeti(L, index, i);
            array.append(luaValueToJsonValue(L, -1));
            lua_pop(L, 1);
        }
        return array;
    } else {
        QJsonObject obj;
        lua_pushnil(L);
        while (lua_next(L, index) != 0) {
            const char* key = lua_tostring(L, -2);
            if (key) {
                obj[QString::fromUtf8(key)] = luaValueToJsonValue(L, -1);
            }
            lua_pop(L, 1);
        }
        return obj;
    }
}

// Helper function to convert Lua value to QJsonValue
static QJsonValue luaValueToJsonValue(lua_State* L, int index) {
    int type = lua_type(L, index);

    switch (type) {
        case LUA_TNIL:
            return QJsonValue(QJsonValue::Null);
        case LUA_TBOOLEAN:
            return QJsonValue(lua_toboolean(L, index) != 0);
        case LUA_TNUMBER:
            return QJsonValue(lua_tonumber(L, index));
        case LUA_TSTRING:
            return QJsonValue(QString::fromUtf8(lua_tostring(L, index)));
        case LUA_TTABLE:
            return luaTableToJsonValue(L, index);
        default:
            return QJsonValue(QJsonValue::Null); // Unsupported types
    }
}


// Helper function to push QJsonValue to Lua stack
static void pushJsonValueToLua(lua_State* L, const QJsonValue& value) {
    switch (value.type()) {
        case QJsonValue::Null:
        case QJsonValue::Undefined:
            lua_pushnil(L);
            break;
        case QJsonValue::Bool:
            lua_pushboolean(L, value.toBool());
            break;
        case QJsonValue::Double:
            lua_pushnumber(L, value.toDouble());
            break;
        case QJsonValue::String:
            lua_pushstring(L, value.toString().toUtf8().constData());
            break;
        case QJsonValue::Array: {
            QJsonArray arr = value.toArray();
            lua_newtable(L);
            for (int i = 0; i < arr.size(); i++) {
                pushJsonValueToLua(L, arr[i]);
                lua_rawseti(L, -2, i + 1);
            }
            break;
        }
        case QJsonValue::Object: {
            QJsonObject obj = value.toObject();
            lua_newtable(L);
            for (auto it = obj.constBegin(); it != obj.constEnd(); ++it) {
                lua_pushstring(L, it.key().toUtf8().constData());
                pushJsonValueToLua(L, it.value());
                lua_settable(L, -3);
            }
            break;
        }
    }
}

// json.encode(table) -> string
int lua_json_encode(lua_State* L) {
    if (lua_gettop(L) < 1 || !lua_istable(L, 1)) {
        return luaL_error(L, "json_encode requires a table argument");
    }

    QJsonValue jsonValue = luaTableToJsonValue(L, 1);
    QJsonDocument doc;

    if (jsonValue.isArray()) {
        doc.setArray(jsonValue.toArray());
    } else if (jsonValue.isObject()) {
        doc.setObject(jsonValue.toObject());
    } else {
        return luaL_error(L, "json_encode: table must convert to object or array");
    }

    QByteArray json = doc.toJson(QJsonDocument::Compact);
    lua_pushlstring(L, json.constData(), json.size());
    return 1;
}

// json.decode(string) -> table
int lua_json_decode(lua_State* L) {
    if (lua_gettop(L) < 1 || !lua_isstring(L, 1)) {
        return luaL_error(L, "json_decode requires a string argument");
    }

    size_t len;
    const char* jsonStr = lua_tolstring(L, 1, &len);
    QByteArray jsonData(jsonStr, len);

    QJsonParseError error;
    QJsonDocument doc = QJsonDocument::fromJson(jsonData, &error);

    if (error.error != QJsonParseError::NoError) {
        return luaL_error(L, "json_decode: parse error at offset %d: %s",
                         error.offset, error.errorString().toUtf8().constData());
    }

    if (doc.isArray()) {
        pushJsonValueToLua(L, doc.array());
    } else if (doc.isObject()) {
        pushJsonValueToLua(L, doc.object());
    } else {
        lua_pushnil(L); // Handle non-array/object JSON (e.g., "null", 123, "string")
    }

    return 1;
}