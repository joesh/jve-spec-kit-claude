#include "binding_macros.h"
#include <QTreeWidget>
#include <QHeaderView>
#include <QDropEvent>
#include <QKeyEvent>
#include <QDragEnterEvent>
#include <QDragMoveEvent>
#include <QDebug>
#include <QMimeData>

// Global map to associate QTreeWidgetItems with integer IDs
static QHash<qulonglong, QTreeWidgetItem*> g_treeItemMap;
static QHash<QTreeWidgetItem*, qulonglong> g_treeItemReverseMap;
static qulonglong g_nextTreeItemId = 1;

static lua_Integer makeTreeItemId(QTreeWidgetItem* item)
{
    if (!item) {
        return -1;
    }

    if (g_treeItemReverseMap.contains(item)) {
        return static_cast<lua_Integer>(g_treeItemReverseMap.value(item));
    }

    qulonglong id = g_nextTreeItemId++;
    g_treeItemMap.insert(id, item);
    g_treeItemReverseMap.insert(item, id);
    return static_cast<lua_Integer>(id);
}

static QTreeWidgetItem* getTreeItemById(QTreeWidget* tree, lua_Integer item_id)
{
    Q_UNUSED(tree);
    if (item_id <= 0) {
        return nullptr;
    }
    return g_treeItemMap.value(static_cast<qulonglong>(item_id), nullptr);
}

class LuaTreeWidget : public QTreeWidget {
public:
    explicit LuaTreeWidget(lua_State* state) : QTreeWidget(nullptr), lua_state(state) {
        setRootIsDecorated(true);
    }

    void setDropHandler(const std::string& handler) {
        drop_handler = handler;
    }

    void setKeyHandler(const std::string& handler) {
        key_handler = handler;
    }

protected:
    void dragEnterEvent(QDragEnterEvent* event) override {
        if (dragDropMode() != NoDragDrop) {
            event->acceptProposedAction();
        } else {
            QTreeWidget::dragEnterEvent(event);
        }
    }

    void dragMoveEvent(QDragMoveEvent* event) override {
        if (dragDropMode() != NoDragDrop) {
            event->acceptProposedAction();
        } else {
            QTreeWidget::dragMoveEvent(event);
        }
    }

    void dropEvent(QDropEvent* event) override {
        if (!drop_handler.empty() && lua_state) {
            lua_getglobal(lua_state, drop_handler.c_str());
            if (lua_isfunction(lua_state, -1)) {
                // Arguments: target_item_id, mime_data
                QTreeWidgetItem* item = itemAt(event->position().toPoint());
                lua_pushinteger(lua_state, makeTreeItemId(item));
                
                // Simple text data for now, extend for custom mime types if needed
                if (event->mimeData()->hasText()) {
                    lua_pushstring(lua_state, event->mimeData()->text().toUtf8().constData());
                } else {
                    lua_pushnil(lua_state);
                }

                if (lua_pcall(lua_state, 2, 0, 0) != LUA_OK) {
                    qWarning() << "Error calling Lua drop handler:" << lua_tostring(lua_state, -1);
                    lua_pop(lua_state, 1);
                }
            } else {
                lua_pop(lua_state, 1);
            }
            event->acceptProposedAction();
        } else {
            QTreeWidget::dropEvent(event);
        }
    }

    void keyPressEvent(QKeyEvent* event) override {
        if (!key_handler.empty() && lua_state) {
            lua_getglobal(lua_state, key_handler.c_str());
            if (lua_isfunction(lua_state, -1)) {
                lua_pushinteger(lua_state, event->key());
                lua_pushstring(lua_state, event->text().toUtf8().constData());
                
                if (lua_pcall(lua_state, 2, 1, 0) == LUA_OK) {
                    bool handled = lua_toboolean(lua_state, -1);
                    lua_pop(lua_state, 1);
                    if (handled) {
                        event->accept();
                        return;
                    }
                } else {
                    qWarning() << "Error calling Lua tree key handler:" << lua_tostring(lua_state, -1);
                    lua_pop(lua_state, 1);
                }
            } else {
                lua_pop(lua_state, 1);
            }
        }
        QTreeWidget::keyPressEvent(event);
    }

private:
    lua_State* lua_state;
    std::string drop_handler;
    std::string key_handler;
};

int lua_create_tree_widget(lua_State* L) {
    LuaTreeWidget* tree = new LuaTreeWidget(L);
    lua_push_widget(L, tree);
    return 1;
}

int lua_set_tree_headers(lua_State* L) {
    QTreeWidget* tree = get_widget<QTreeWidget>(L, 1);
    if (tree && lua_istable(L, 2)) {
        QStringList headers;
        int len = lua_objlen(L, 2);
        for (int i = 1; i <= len; i++) {
            lua_rawgeti(L, 2, i);
            if (const char* s = lua_tostring(L, -1)) {
                headers << QString::fromUtf8(s);
            }
            lua_pop(L, 1);
        }
        tree->setHeaderLabels(headers);
        lua_pushboolean(L, 1);
    } else {
        lua_pushboolean(L, 0);
    }
    return 1;
}

LUA_BIND_SETTER_INT(lua_set_tree_indentation, QTreeWidget, setIndentation)

int lua_set_tree_column_width(lua_State* L) {
    QTreeWidget* tree = get_widget<QTreeWidget>(L, 1);
    int col = lua_tointeger(L, 2);
    int width = lua_tointeger(L, 3);
    if (tree) {
        tree->setColumnWidth(col, width);
        lua_pushboolean(L, 1);
    } else {
        lua_pushboolean(L, 0);
    }
    return 1;
}

int lua_add_tree_item(lua_State* L) {
    QTreeWidget* tree = get_widget<QTreeWidget>(L, 1);
    if (!tree || !lua_istable(L, 2)) {
        lua_pushinteger(L, -1);
        return 1;
    }

    QStringList values;
    int len = lua_objlen(L, 2);
    for (int i = 1; i <= len; i++) {
        lua_rawgeti(L, 2, i);
        const char* str = lua_tostring(L, -1);
        values << (str ? QString::fromUtf8(str) : QString());
        lua_pop(L, 1);
    }

    QTreeWidgetItem* item = new QTreeWidgetItem(tree, values);
    tree->addTopLevelItem(item);
    lua_pushinteger(L, makeTreeItemId(item));
    return 1;
}

int lua_add_tree_child_item(lua_State* L) {
    QTreeWidget* tree = get_widget<QTreeWidget>(L, 1);
    lua_Integer parent_id = luaL_checkinteger(L, 2);
    
    if (!tree || !lua_istable(L, 3)) {
        lua_pushinteger(L, -1);
        return 1;
    }

    QTreeWidgetItem* parent = getTreeItemById(tree, parent_id);
    if (!parent) {
        lua_pushinteger(L, -1);
        return 1;
    }

    QStringList values;
    int len = lua_objlen(L, 3);
    for (int i = 1; i <= len; i++) {
        lua_rawgeti(L, 3, i);
        const char* str = lua_tostring(L, -1);
        values << (str ? QString::fromUtf8(str) : QString());
        lua_pop(L, 1);
    }

    QTreeWidgetItem* child = new QTreeWidgetItem(parent, values);
    parent->addChild(child);
    lua_pushinteger(L, makeTreeItemId(child));
    return 1;
}

int lua_get_tree_selected_index(lua_State* L) {
    QTreeWidget* tree = get_widget<QTreeWidget>(L, 1);
    if (!tree) {
        lua_pushinteger(L, -1);
        return 1;
    }
    
    QList<QTreeWidgetItem*> selected = tree->selectedItems();
    if (selected.isEmpty()) {
        lua_pushinteger(L, -1);
    } else {
        // Return ID of first selected item
        lua_pushinteger(L, makeTreeItemId(selected.first()));
    }
    return 1;
}

int lua_clear_tree(lua_State* L) {
    QTreeWidget* tree = get_widget<QTreeWidget>(L, 1);
    if (tree) {
        tree->clear();
        // Note: Clearing tree invalidates pointers in g_treeItemMap.
        // Ideally we should clean them up, but map keys are IDs, values are pointers.
        // Pointers becoming dangling is risky if we access them later by old ID.
        // For now, we rely on IDs being unique and hopefully not reused or accessed after clear.
        // Proper fix: iterate items and remove from map, or clear map if we know this is the only tree.
    }
    return 0;
}

int lua_set_tree_item_expanded(lua_State* L) {
    QTreeWidget* tree = get_widget<QTreeWidget>(L, 1);
    lua_Integer item_id = luaL_checkinteger(L, 2);
    bool expanded = lua_toboolean(L, 3);
    
    QTreeWidgetItem* item = getTreeItemById(tree, item_id);
    if (item) {
        item->setExpanded(expanded);
        lua_pushboolean(L, 1);
    } else {
        lua_pushboolean(L, 0);
    }
    return 1;
}

int lua_is_tree_item_expanded(lua_State* L) {
    QTreeWidget* tree = get_widget<QTreeWidget>(L, 1);
    lua_Integer item_id = luaL_checkinteger(L, 2);
    
    QTreeWidgetItem* item = getTreeItemById(tree, item_id);
    if (item) {
        lua_pushboolean(L, item->isExpanded());
    } else {
        lua_pushboolean(L, 0);
    }
    return 1;
}

int lua_set_tree_item_data(lua_State* L) {
    QTreeWidget* tree = get_widget<QTreeWidget>(L, 1);
    lua_Integer item_id = luaL_checkinteger(L, 2);

    QTreeWidgetItem* item = getTreeItemById(tree, item_id);
    if (!item) {
        lua_pushboolean(L, 0);
        return 1;
    }

    // Support both calling patterns:
    // 3 args: (tree, item_id, json_string) - store JSON directly
    // 4 args: (tree, item_id, key, value) - store key-value in map
    if (lua_gettop(L) == 3) {
        // Store JSON string directly
        const char* json_data = luaL_checkstring(L, 3);
        item->setData(0, Qt::UserRole, QString::fromUtf8(json_data));
        lua_pushboolean(L, 1);
    } else if (lua_gettop(L) >= 4) {
        // Store key-value in map
        const char* key = luaL_checkstring(L, 3);
        const char* value = luaL_checkstring(L, 4);
        QVariant current = item->data(0, Qt::UserRole);
        QVariantMap map = current.toMap();
        map[QString::fromUtf8(key)] = QString::fromUtf8(value);
        item->setData(0, Qt::UserRole, map);
        lua_pushboolean(L, 1);
    } else {
        lua_pushboolean(L, 0);
    }
    return 1;
}

int lua_get_tree_item_data(lua_State* L) {
    QTreeWidget* tree = get_widget<QTreeWidget>(L, 1);
    lua_Integer item_id = luaL_checkinteger(L, 2);
    const char* key = luaL_checkstring(L, 3);

    QTreeWidgetItem* item = getTreeItemById(tree, item_id);
    if (item) {
        QVariant current = item->data(0, Qt::UserRole);
        QVariantMap map = current.toMap();
        QString val = map.value(QString::fromUtf8(key)).toString();
        lua_pushstring(L, val.toUtf8().constData());
    } else {
        lua_pushnil(L);
    }
    return 1;
}

int lua_set_tree_item_text(lua_State* L) {
    QTreeWidget* tree = get_widget<QTreeWidget>(L, 1);
    lua_Integer item_id = luaL_checkinteger(L, 2);
    const char* text = luaL_checkstring(L, 3);
    int col = luaL_optinteger(L, 4, 0);

    QTreeWidgetItem* item = getTreeItemById(tree, item_id);
    if (item) {
        item->setText(col, QString::fromUtf8(text));
        lua_pushboolean(L, 1);
    } else {
        lua_pushboolean(L, 0);
    }
    return 1;
}

int lua_set_tree_item_editable(lua_State* L) {
    QTreeWidget* tree = get_widget<QTreeWidget>(L, 1);
    lua_Integer item_id = luaL_checkinteger(L, 2);
    bool editable = lua_toboolean(L, 3);

    QTreeWidgetItem* item = getTreeItemById(tree, item_id);
    if (item) {
        Qt::ItemFlags flags = item->flags();
        if (editable) flags |= Qt::ItemIsEditable;
        else flags &= ~Qt::ItemIsEditable;
        item->setFlags(flags);
        lua_pushboolean(L, 1);
    } else {
        lua_pushboolean(L, 0);
    }
    return 1;
}

int lua_edit_tree_item(lua_State* L) {
    QTreeWidget* tree = get_widget<QTreeWidget>(L, 1);
    lua_Integer item_id = luaL_checkinteger(L, 2);
    int col = luaL_optinteger(L, 3, 0);

    QTreeWidgetItem* item = getTreeItemById(tree, item_id);
    if (item) {
        tree->editItem(item, col);
        lua_pushboolean(L, 1);
    } else {
        lua_pushboolean(L, 0);
    }
    return 1;
}

int lua_set_tree_selection_changed_handler(lua_State* L) {
    QTreeWidget* tree = get_widget<QTreeWidget>(L, 1);
    const char* handler_name = luaL_checkstring(L, 2);
    
    if (tree && handler_name) {
        std::string handler(handler_name);
        QObject::connect(tree, &QTreeWidget::itemSelectionChanged, [L, handler, tree]() {
            lua_getglobal(L, handler.c_str());
            if (!lua_isfunction(L, -1)) {
                lua_pop(L, 1);
                return;
            }
            
            QList<QTreeWidgetItem*> selected = tree->selectedItems();
            if (!selected.isEmpty()) {
                QTreeWidgetItem* item = selected.first();
                lua_newtable(L);
                lua_pushstring(L, "item_id");
                lua_pushinteger(L, makeTreeItemId(item));
                lua_settable(L, -3);
                if (lua_pcall(L, 1, 0, 0) != LUA_OK) {
                    qWarning() << "Error in selection handler:" << lua_tostring(L, -1);
                    lua_pop(L, 1);
                }
            } else {
                lua_pushnil(L);
                if (lua_pcall(L, 1, 0, 0) != LUA_OK) {
                    qWarning() << "Error in selection handler:" << lua_tostring(L, -1);
                    lua_pop(L, 1);
                }
            }
        });
        lua_pushboolean(L, 1);
    } else {
        lua_pushboolean(L, 0);
    }
    return 1;
}

int lua_set_tree_item_changed_handler(lua_State* L) {
    QTreeWidget* tree = get_widget<QTreeWidget>(L, 1);
    const char* handler_name = luaL_checkstring(L, 2);
    
    if (tree && handler_name) {
        std::string handler(handler_name);
        QObject::connect(tree, &QTreeWidget::itemChanged, [L, handler](QTreeWidgetItem* item, int column) {
            lua_getglobal(L, handler.c_str());
            if (!lua_isfunction(L, -1)) { lua_pop(L, 1); return; }
            
            lua_newtable(L);
            lua_pushstring(L, "item_id");
            lua_pushinteger(L, makeTreeItemId(item));
            lua_settable(L, -3);
            lua_pushstring(L, "column");
            lua_pushinteger(L, column);
            lua_settable(L, -3);
            lua_pushstring(L, "text");
            lua_pushstring(L, item->text(column).toUtf8().constData());
            lua_settable(L, -3);
            
            if (lua_pcall(L, 1, 0, 0) != LUA_OK) {
                qWarning() << "Error in item changed handler:" << lua_tostring(L, -1);
                lua_pop(L, 1);
            }
        });
        lua_pushboolean(L, 1);
    } else {
        lua_pushboolean(L, 0);
    }
    return 1;
}

int lua_set_tree_close_editor_handler(lua_State* L) {
    (void)L;
    // This usually requires a delegate. For now, we skip complex delegate logic unless critical.
    // We'll return 0 to indicate not implemented or just stub it if needed.
    return 0;
}

int lua_set_tree_selection_mode(lua_State* L) {
    QTreeWidget* tree = get_widget<QTreeWidget>(L, 1);
    const char* mode_str = luaL_checkstring(L, 2);
    
    if (tree && mode_str) {
        if (strcmp(mode_str, "SingleSelection") == 0) tree->setSelectionMode(QAbstractItemView::SingleSelection);
        else if (strcmp(mode_str, "MultiSelection") == 0) tree->setSelectionMode(QAbstractItemView::MultiSelection);
        else if (strcmp(mode_str, "ExtendedSelection") == 0) tree->setSelectionMode(QAbstractItemView::ExtendedSelection);
        else if (strcmp(mode_str, "NoSelection") == 0) tree->setSelectionMode(QAbstractItemView::NoSelection);
        lua_pushboolean(L, 1);
    } else {
        lua_pushboolean(L, 0);
    }
    return 1;
}

int lua_set_tree_drag_drop_mode(lua_State* L) {
    QWidget* w = static_cast<QWidget*>(lua_to_widget(L, 1));
    const char* mode = luaL_checkstring(L, 2);
    
    if (LuaTreeWidget* tree = dynamic_cast<LuaTreeWidget*>(w)) {
        if (strcmp(mode, "drag_drop") == 0) tree->setDragDropMode(QAbstractItemView::DragDrop);
        else if (strcmp(mode, "internal") == 0) tree->setDragDropMode(QAbstractItemView::InternalMove);
        else tree->setDragDropMode(QAbstractItemView::NoDragDrop);
        lua_pushboolean(L, 1);
    } else {
        lua_pushboolean(L, 0);
    }
    return 1;
}

int lua_set_tree_drop_handler(lua_State* L) {
    QWidget* w = static_cast<QWidget*>(lua_to_widget(L, 1));
    const char* handler = luaL_checkstring(L, 2);
    
    if (LuaTreeWidget* tree = dynamic_cast<LuaTreeWidget*>(w)) {
        tree->setDropHandler(handler);
        lua_pushboolean(L, 1);
    } else {
        lua_pushboolean(L, 0);
    }
    return 1;
}

int lua_set_tree_key_handler(lua_State* L) {
    QWidget* w = static_cast<QWidget*>(lua_to_widget(L, 1));
    const char* handler = luaL_checkstring(L, 2);
    
    if (LuaTreeWidget* tree = dynamic_cast<LuaTreeWidget*>(w)) {
        tree->setKeyHandler(handler);
        lua_pushboolean(L, 1);
    } else {
        lua_pushboolean(L, 0);
    }
    return 1;
}

int lua_set_tree_item_icon(lua_State* L) {
    (void)L;
    // Placeholder
    return 0;
}

int lua_set_tree_item_double_click_handler(lua_State* L) {
    QTreeWidget* tree = get_widget<QTreeWidget>(L, 1);
    const char* handler_name = luaL_checkstring(L, 2);
    
    if (tree && handler_name) {
        std::string handler(handler_name);
        QObject::connect(tree, &QTreeWidget::itemDoubleClicked, [L, handler](QTreeWidgetItem* item, int col) {
            lua_getglobal(L, handler.c_str());
            if (!lua_isfunction(L, -1)) { lua_pop(L, 1); return; }
            
            lua_pushinteger(L, makeTreeItemId(item));
            lua_pushinteger(L, col);
            if (lua_pcall(L, 2, 0, 0) != LUA_OK) {
                qWarning() << "Error in double click handler:" << lua_tostring(L, -1);
                lua_pop(L, 1);
            }
        });
        lua_pushboolean(L, 1);
    } else {
        lua_pushboolean(L, 0);
    }
    return 1;
}

int lua_set_tree_current_item(lua_State* L) {
    QTreeWidget* tree = get_widget<QTreeWidget>(L, 1);
    lua_Integer item_id = luaL_checkinteger(L, 2);
    
    if (tree) {
        QTreeWidgetItem* item = getTreeItemById(tree, item_id);
        if (item) {
            tree->setCurrentItem(item);
            lua_pushboolean(L, 1);
            return 1;
        }
    }
    lua_pushboolean(L, 0);
    return 1;
}

int lua_get_tree_item_at(lua_State* L) {
    QTreeWidget* tree = get_widget<QTreeWidget>(L, 1);
    int x = luaL_checkint(L, 2);
    int y = luaL_checkint(L, 3);
    
    if (tree) {
        QTreeWidgetItem* item = tree->itemAt(x, y);
        if (item) {
            lua_pushinteger(L, makeTreeItemId(item));
            return 1;
        }
    }
    lua_pushnil(L);
    return 1;
}

int lua_set_tree_expands_on_double_click(lua_State* L) {
    QTreeWidget* tree = get_widget<QTreeWidget>(L, 1);
    bool enable = lua_toboolean(L, 2);
    if (tree) {
        tree->setExpandsOnDoubleClick(enable);
        lua_pushboolean(L, 1);
    } else {
        lua_pushboolean(L, 0);
    }
    return 1;
}
