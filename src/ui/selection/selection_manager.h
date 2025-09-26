#pragma once

#include <QObject>
#include <QString>
#include <QStringList>
#include <QSet>
#include <QHash>
#include <QVariantMap>
#include <QKeyEvent>
#include <QElapsedTimer>
#include <QUuid>
#include <QDateTime>

/**
 * Selection data structures for professional editing workflows
 */
enum class SelectionState {
    None,       // No items selected
    Partial,    // Some items selected
    All         // All items selected
};

enum class SelectionDirection {
    Left,
    Right,
    Up,
    Down
};

struct SelectionRange {
    QString startId;
    QString endId;
    int count;
    
    SelectionRange() : count(0) {}
};

struct SelectionSnapshot {
    QStringList items;
    QString timestamp;
    QString operationId;
    
    SelectionSnapshot() : timestamp(QString::number(QDateTime::currentMSecsSinceEpoch())) {}
};

struct TransformData {
    double offsetX = 0.0;
    double offsetY = 0.0;
    double scaleX = 1.0;
    double scaleY = 1.0;
    double rotation = 0.0;
};

struct SelectionOperation {
    QString type;
    QString id;
    QVariantMap parameters;
    TransformData transform;
    QStringList targetItems;
    
    SelectionOperation() : id(QUuid::createUuid().toString(QUuid::WithoutBraces)) {}
    
    void setParameters(const QVariantMap& params) { parameters = params; }
    void setTransform(const TransformData& t) { transform = t; }
};

struct ExecutionResult {
    bool success = false;
    QString errorMessage;
    QStringList affectedItems;
    QString operationId;
};

/**
 * SelectionManager: Professional video editor selection system
 * 
 * Constitutional requirements:
 * - Multi-selection with tri-state controls (none/partial/all)
 * - Edge selection with Cmd+click patterns for range selection
 * - Selection persistence across operations and undo/redo
 * - Professional editor selection behaviors and keyboard navigation
 * - Performance optimization for large timeline selections
 * 
 * Engineering Rules:
 * - Rule 2.14: No hardcoded constants (uses schema_constants.h)
 * - Rule 2.26: Functions read like algorithms calling subfunctions
 * - Rule 2.27: Short, focused functions with single responsibilities
 */
class SelectionManager : public QObject
{
    Q_OBJECT

public:
    explicit SelectionManager(QObject* parent = nullptr);
    
    // Basic selection operations
    void select(const QString& itemId);
    void addToSelection(const QString& itemId);
    void removeFromSelection(const QString& itemId);
    void toggleSelection(const QString& itemId);
    void clear();
    
    // Timeline context for range selection
    void setTimelineItems(const QStringList& orderedItems);
    
    // Batch selection operations
    void selectAll(const QStringList& items);
    void selectNone();
    
    // Selection queries
    bool isEmpty() const;
    int count() const;
    bool isSelected(const QString& itemId) const;
    QStringList getSelectedItems() const;
    
    // Tri-state controls
    SelectionState getTrackSelectionState(const QString& trackId, const QStringList& trackItems) const;
    void handleTriStateClick(const QString& trackId, const QStringList& trackItems, SelectionState currentState);
    
    // Edge selection (Cmd+click patterns)
    void handleClick(const QString& itemId, bool cmdPressed = false, bool shiftPressed = false);
    SelectionRange getSelectionRange() const;
    
    // Selection persistence
    SelectionSnapshot saveSnapshot() const;
    void restoreSnapshot(const SelectionSnapshot& snapshot);
    QString beginOperation(const QString& operationName);
    void endOperation(const QString& operationId);
    
    // Selection-based operations
    SelectionOperation createBatchOperation(const QString& operationType);
    ExecutionResult executeOperation(const SelectionOperation& operation);
    bool canUndo() const;
    void undo();
    
    // Keyboard navigation
    void moveSelection(SelectionDirection direction);
    void extendSelection(SelectionDirection direction);
    void handleKeyPress(int key, Qt::KeyboardModifiers modifiers);

signals:
    void selectionChanged(const QStringList& selectedItems);
    void selectionRangeChanged(const SelectionRange& range);

private:
    // Algorithm implementations
    void updateSelectionRange();
    void notifySelectionChanged();
    QString findNextItem(const QString& currentItem, SelectionDirection direction) const;
    QString findPreviousItem(const QString& currentItem, SelectionDirection direction) const;
    void selectRange(const QString& startId, const QString& endId);
    void executeSelectionCommand(const SelectionOperation& operation);
    
    // Selection state
    QSet<QString> m_selectedItems;
    SelectionRange m_currentRange;
    
    // Operation history
    QList<SelectionSnapshot> m_snapshots;
    QHash<QString, SelectionSnapshot> m_operations;
    
    // Performance tracking
    mutable QElapsedTimer m_performanceTimer;
    
    // Navigation state
    QString m_lastSelectedItem;
    QString m_rangeStartItem;
    
    // Timeline context for range operations
    QStringList m_timelineItems;
};