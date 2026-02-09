#include "binding_macros.h"
#include <QDialog>
#include <QFileDialog>
#include <QMessageBox>
#include <QPushButton>

// File Dialog Bindings
int lua_file_dialog_open(lua_State* L) {
    QWidget* parent = get_widget<QWidget>(L, 1);
    const char* title = luaL_optstring(L, 2, "Open File");
    const char* filter = luaL_optstring(L, 3, "All Files (*)");
    const char* dir = luaL_optstring(L, 4, "");

    QString filename = QFileDialog::getOpenFileName(parent, QString::fromUtf8(title), QString::fromUtf8(dir), QString::fromUtf8(filter));
    if (filename.isEmpty()) lua_pushnil(L);
    else lua_pushstring(L, filename.toUtf8().constData());
    return 1;
}

int lua_file_dialog_open_multiple(lua_State* L) {
    QWidget* parent = get_widget<QWidget>(L, 1);
    const char* title = luaL_optstring(L, 2, "Open Files");
    const char* filter = luaL_optstring(L, 3, "All Files (*)");
    const char* dir = luaL_optstring(L, 4, "");

    QStringList filenames = QFileDialog::getOpenFileNames(parent, QString::fromUtf8(title), QString::fromUtf8(dir), QString::fromUtf8(filter));
    if (filenames.isEmpty()) {
        lua_pushnil(L);
    } else {
        lua_newtable(L);
        for (int i = 0; i < filenames.size(); ++i) {
            lua_pushstring(L, filenames[i].toUtf8().constData());
            lua_rawseti(L, -2, i + 1);
        }
    }
    return 1;
}

int lua_file_dialog_directory(lua_State* L) {
    QWidget* parent = get_widget<QWidget>(L, 1);
    const char* title = luaL_optstring(L, 2, "Select Directory");
    const char* dir = luaL_optstring(L, 3, "");

    QString dirname = QFileDialog::getExistingDirectory(parent, QString::fromUtf8(title), QString::fromUtf8(dir));
    if (dirname.isEmpty()) lua_pushnil(L);
    else lua_pushstring(L, dirname.toUtf8().constData());
    return 1;
}

int lua_file_dialog_save(lua_State* L) {
    QWidget* parent = get_widget<QWidget>(L, 1);
    const char* title = luaL_optstring(L, 2, "Save File");
    const char* filter = luaL_optstring(L, 3, "All Files (*)");
    const char* dir = luaL_optstring(L, 4, "");

    QString filename = QFileDialog::getSaveFileName(parent, QString::fromUtf8(title), QString::fromUtf8(dir), QString::fromUtf8(filter));
    if (filename.isEmpty()) lua_pushnil(L);
    else lua_pushstring(L, filename.toUtf8().constData());
    return 1;
}

// Show a confirmation dialog with optional customisation
// Accepts either:
//   - table with fields:
//       parent (widget), title, message, informative_text, detail_text,
//       confirm_text, cancel_text, icon ("information","warning","critical","question"),
//       default_button ("confirm"|"cancel")
//   - positional arguments (message [, confirm_text [, cancel_text]])
// Returns: boolean accepted, string result ("confirm"|"cancel")
int lua_show_confirm_dialog(lua_State* L)
{
    QWidget* parent = nullptr;
    QString title = QStringLiteral("Confirm");
    QString message = QStringLiteral("Are you sure?");
    QString informativeText;
    QString detailText;
    QString confirmText = QStringLiteral("OK");
    QString cancelText = QStringLiteral("Cancel");
    QString defaultButton = QStringLiteral("confirm");
    QMessageBox::Icon icon = QMessageBox::Question;

    int argCount = lua_gettop(L);

    if (argCount >= 1) {
        if (lua_istable(L, 1)) {
            lua_getfield(L, 1, "parent");
            if (lua_isuserdata(L, -1)) parent = static_cast<QWidget*>(lua_to_widget(L, -1));
            lua_pop(L, 1);

            lua_getfield(L, 1, "title"); if (lua_isstring(L, -1)) title = QString::fromUtf8(lua_tostring(L, -1)); lua_pop(L, 1);
            lua_getfield(L, 1, "message"); if (lua_isstring(L, -1)) message = QString::fromUtf8(lua_tostring(L, -1)); lua_pop(L, 1);
            lua_getfield(L, 1, "informative_text"); if (lua_isstring(L, -1)) informativeText = QString::fromUtf8(lua_tostring(L, -1)); lua_pop(L, 1);
            lua_getfield(L, 1, "detail_text"); if (lua_isstring(L, -1)) detailText = QString::fromUtf8(lua_tostring(L, -1)); lua_pop(L, 1);
            lua_getfield(L, 1, "confirm_text"); if (lua_isstring(L, -1)) confirmText = QString::fromUtf8(lua_tostring(L, -1)); lua_pop(L, 1);
            lua_getfield(L, 1, "cancel_text"); if (lua_isstring(L, -1)) cancelText = QString::fromUtf8(lua_tostring(L, -1)); lua_pop(L, 1);
            lua_getfield(L, 1, "default_button"); if (lua_isstring(L, -1)) defaultButton = QString::fromUtf8(lua_tostring(L, -1)).toLower(); lua_pop(L, 1);

            lua_getfield(L, 1, "icon");
            if (lua_isstring(L, -1)) {
                QString iconName = QString::fromUtf8(lua_tostring(L, -1)).toLower();
                if (iconName == "information" || iconName == "info") icon = QMessageBox::Information;
                else if (iconName == "warning") icon = QMessageBox::Warning;
                else if (iconName == "critical" || iconName == "error") icon = QMessageBox::Critical;
                else if (iconName == "question") icon = QMessageBox::Question;
            }
            lua_pop(L, 1);
        } else if (lua_isstring(L, 1)) {
            message = QString::fromUtf8(lua_tostring(L, 1));
            if (argCount >= 2 && lua_isstring(L, 2)) confirmText = QString::fromUtf8(lua_tostring(L, 2));
            if (argCount >= 3 && lua_isstring(L, 3)) cancelText = QString::fromUtf8(lua_tostring(L, 3));
        }
    }

    QMessageBox msgBox(icon, title, message, QMessageBox::NoButton, parent);
    // Use ApplicationModal when no parent (e.g., during startup before main window exists)
    msgBox.setWindowModality(parent ? Qt::WindowModal : Qt::ApplicationModal);
    if (!informativeText.isEmpty()) msgBox.setInformativeText(informativeText);
    if (!detailText.isEmpty()) msgBox.setDetailedText(detailText);

    QAbstractButton* confirmButton = msgBox.addButton(confirmText, QMessageBox::AcceptRole);
    QAbstractButton* cancelButton = msgBox.addButton(cancelText, QMessageBox::RejectRole);

    if (defaultButton == "cancel") msgBox.setDefaultButton(qobject_cast<QPushButton*>(cancelButton));
    else msgBox.setDefaultButton(qobject_cast<QPushButton*>(confirmButton));

    msgBox.exec();
    QAbstractButton* clicked = msgBox.clickedButton();
    bool accepted = (clicked == confirmButton);

    lua_pushboolean(L, accepted ? 1 : 0);
    lua_pushstring(L, accepted ? "confirm" : "cancel");
    return 2;
}

// Custom Dialog Bindings
// CREATE(title [, width, height]) -> dialog widget
int lua_create_dialog(lua_State* L) {
    const char* title = luaL_checkstring(L, 1);
    int width = luaL_optinteger(L, 2, 400);
    int height = luaL_optinteger(L, 3, 300);

    QDialog* dialog = new QDialog();
    dialog->setWindowTitle(QString::fromUtf8(title));
    dialog->resize(width, height);
    dialog->setWindowModality(Qt::ApplicationModal);

    lua_push_widget(L, dialog);
    return 1;
}

// SHOW(dialog [, blocking=true])
// blocking=true: calls exec(), waits for close, returns result code (0=rejected, 1=accepted)
// blocking=false: shows modal immediately, returns true
int lua_show_dialog(lua_State* L) {
    QDialog* dialog = get_widget<QDialog>(L, 1);
    if (!dialog) return luaL_error(L, "DIALOG.SHOW: argument must be QDialog");

    bool blocking = lua_isboolean(L, 2) ? lua_toboolean(L, 2) : true;

    if (blocking) {
        int result = dialog->exec();
        lua_pushinteger(L, result);
    } else {
        dialog->setWindowModality(Qt::ApplicationModal);
        dialog->show();
        dialog->raise();
        dialog->activateWindow();
        lua_pushboolean(L, 1);
    }
    return 1;
}

// CLOSE(dialog [, accept=true])
int lua_close_dialog(lua_State* L) {
    QDialog* dialog = get_widget<QDialog>(L, 1);
    if (!dialog) return luaL_error(L, "DIALOG.CLOSE: argument must be QDialog");

    bool accept = lua_isboolean(L, 2) ? lua_toboolean(L, 2) : true;
    if (accept) {
        dialog->accept();
    } else {
        dialog->reject();
    }
    return 0;
}

// SET_LAYOUT(dialog, layout)
int lua_set_dialog_layout(lua_State* L) {
    QDialog* dialog = get_widget<QDialog>(L, 1);
    QLayout* layout = get_widget<QLayout>(L, 2);
    if (!dialog) return luaL_error(L, "DIALOG.SET_LAYOUT: first argument must be QDialog");
    if (!layout) return luaL_error(L, "DIALOG.SET_LAYOUT: second argument must be QLayout");

    dialog->setLayout(layout);
    return 0;
}