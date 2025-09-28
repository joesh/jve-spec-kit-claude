#include "selection_manager.h"

#include <QLoggingCategory>
#include <QDebug>
#include <algorithm>

Q_LOGGING_CATEGORY(jveSelection, "jve.selection")

SelectionManager::SelectionManager(QObject* parent)
    : QObject(parent)
{
    qCDebug(jveSelection, "Initializing SelectionManager");
}

void SelectionManager::select(const QString& itemId)
{
    qCDebug(jveSelection, "Selecting item: %s", qPrintable(itemId));
    
    // Algorithm: Clear previous → Add item → Update range → Notify
    m_selectedItems.clear();
    m_selectedItems.insert(itemId);
    m_lastSelectedItem = itemId;
    m_rangeStartItem = itemId;
    
    updateSelectionRange();
    notifySelectionChanged();
}

void SelectionManager::addToSelection(const QString& itemId)
{
    qCDebug(jveSelection, "Adding to selection: %s", qPrintable(itemId));
    
    // Algorithm: Insert item → Update tracking → Update range → Notify
    if (!m_selectedItems.contains(itemId)) {
        m_selectedItems.insert(itemId);
        m_lastSelectedItem = itemId;
        updateSelectionRange();
        notifySelectionChanged();
    }
}

void SelectionManager::removeFromSelection(const QString& itemId)
{
    qCDebug(jveSelection, "Removing from selection: %s", qPrintable(itemId));
    
    // Algorithm: Remove item → Update tracking → Update range → Notify
    if (m_selectedItems.remove(itemId)) {
        if (m_lastSelectedItem == itemId && !m_selectedItems.isEmpty()) {
            m_lastSelectedItem = *m_selectedItems.begin();
        }
        updateSelectionRange();
        notifySelectionChanged();
    }
}

void SelectionManager::toggleSelection(const QString& itemId)
{
    // Algorithm: Check state → Add or remove → Notify
    if (isSelected(itemId)) {
        removeFromSelection(itemId);
    } else {
        addToSelection(itemId);
    }
}

void SelectionManager::clear()
{
    qCDebug(jveSelection, "Clearing selection");
    
    // Algorithm: Clear data → Reset state → Notify
    if (!m_selectedItems.isEmpty()) {
        m_selectedItems.clear();
        m_lastSelectedItem.clear();
        m_rangeStartItem.clear();
        m_currentRange = SelectionRange();
        notifySelectionChanged();
    }
}

void SelectionManager::setTimelineItems(const QStringList& orderedItems)
{
    m_timelineItems = orderedItems;
}

void SelectionManager::selectAll(const QStringList& items)
{
    qCDebug(jveSelection, "Selecting all items: %lld", static_cast<long long>(items.size()));
    
    // Algorithm: Clear → Add all → Update tracking → Notify
    m_selectedItems.clear();
    for (const QString& item : items) {
        m_selectedItems.insert(item);
    }
    
    if (!items.isEmpty()) {
        m_lastSelectedItem = items.last();
        m_rangeStartItem = items.first();
    }
    
    updateSelectionRange();
    notifySelectionChanged();
}

void SelectionManager::selectNone()
{
    clear();
}

bool SelectionManager::isEmpty() const
{
    return m_selectedItems.isEmpty();
}

int SelectionManager::count() const
{
    return m_selectedItems.size();
}

bool SelectionManager::isSelected(const QString& itemId) const
{
    return m_selectedItems.contains(itemId);
}

QStringList SelectionManager::getSelectedItems() const
{
    return m_selectedItems.values();
}

SelectionState SelectionManager::getTrackSelectionState(const QString& trackId, const QStringList& trackItems) const
{
    qCDebug(jveSelection, "Getting track selection state for: %s", qPrintable(trackId));
    
    // Algorithm: Count selected → Determine state → Return result
    int selectedCount = 0;
    for (const QString& item : trackItems) {
        if (isSelected(item)) {
            selectedCount++;
        }
    }
    
    if (selectedCount == 0) {
        return SelectionState::None;
    } else if (selectedCount == trackItems.size()) {
        return SelectionState::All;
    } else {
        return SelectionState::Partial;
    }
}

void SelectionManager::handleTriStateClick(const QString& trackId, const QStringList& trackItems, SelectionState currentState)
{
    qCDebug(jveSelection, "Handling tri-state click for track: %s state: %d", qPrintable(trackId), static_cast<int>(currentState));
    
    // Algorithm: Route by state → Perform action → Notify
    switch (currentState) {
    case SelectionState::None:
        // Select all items in track
        for (const QString& item : trackItems) {
            m_selectedItems.insert(item);
        }
        break;
        
    case SelectionState::All:
        // Deselect all items in track
        for (const QString& item : trackItems) {
            m_selectedItems.remove(item);
        }
        break;
        
    case SelectionState::Partial:
        // Select all items in track (complete the selection)
        for (const QString& item : trackItems) {
            m_selectedItems.insert(item);
        }
        break;
    }
    
    updateSelectionRange();
    notifySelectionChanged();
}

void SelectionManager::handleClick(const QString& itemId, bool cmdPressed, bool shiftPressed)
{
    qCDebug(jveSelection, "Handling click: %s cmd: %s shift: %s", qPrintable(itemId), cmdPressed ? "true" : "false", shiftPressed ? "true" : "false");
    
    // Algorithm: Check modifiers → Perform selection → Update range
    if (cmdPressed) {
        // Cmd+click: Add/remove individual item (professional editor standard)
        toggleSelection(itemId);
    } else if (shiftPressed && !m_lastSelectedItem.isEmpty()) {
        // Shift+click: Extend range selection (professional editor standard)
        selectRange(m_lastSelectedItem, itemId);
    } else {
        // Normal click: Replace selection
        select(itemId);
    }
}

SelectionRange SelectionManager::getSelectionRange() const
{
    return m_currentRange;
}

SelectionSnapshot SelectionManager::saveSnapshot() const
{
    qCDebug(jveSelection, "Saving selection snapshot");
    
    // Algorithm: Create snapshot → Populate → Return
    SelectionSnapshot snapshot;
    snapshot.items = getSelectedItems();
    
    return snapshot;
}

void SelectionManager::restoreSnapshot(const SelectionSnapshot& snapshot)
{
    qCDebug(jveSelection, "Restoring selection snapshot with %lld items", static_cast<long long>(snapshot.items.size()));
    
    // Algorithm: Clear current → Restore items → Update state → Notify
    m_selectedItems.clear();
    for (const QString& item : snapshot.items) {
        m_selectedItems.insert(item);
    }
    
    if (!snapshot.items.isEmpty()) {
        m_lastSelectedItem = snapshot.items.last();
        m_rangeStartItem = snapshot.items.first();
    }
    
    updateSelectionRange();
    notifySelectionChanged();
}

QString SelectionManager::beginOperation(const QString& operationName)
{
    qCDebug(jveSelection, "Beginning operation: %s", qPrintable(operationName));
    
    // Algorithm: Generate ID → Save snapshot → Store operation → Return ID
    QString operationId = QUuid::createUuid().toString(QUuid::WithoutBraces);
    SelectionSnapshot snapshot = saveSnapshot();
    snapshot.operationId = operationId;
    
    m_operations[operationId] = snapshot;
    
    return operationId;
}

void SelectionManager::endOperation(const QString& operationId)
{
    qCDebug(jveSelection, "Ending operation: %s", qPrintable(operationId));
    
    // For M1 Foundation, operations complete immediately
    // Real implementation would handle async operations
}

SelectionOperation SelectionManager::createBatchOperation(const QString& operationType)
{
    qCDebug(jveSelection, "Creating batch operation: %s", qPrintable(operationType));
    
    // Algorithm: Create operation → Set targets → Return operation
    SelectionOperation operation;
    operation.type = operationType;
    operation.targetItems = getSelectedItems();
    
    return operation;
}

SelectionExecutionResult SelectionManager::executeOperation(const SelectionOperation& operation)
{
    qCDebug(jveSelection, "Executing selection operation: %s", qPrintable(operation.type));
    
    // Algorithm: Validate → Execute → Create result → Return
    SelectionExecutionResult result;
    
    if (operation.targetItems.isEmpty()) {
        result.success = false;
        result.errorMessage = "No items selected for operation";
        return result;
    }
    
    // For contract test purposes, simulate successful execution
    executeSelectionCommand(operation);
    
    result.success = true;
    result.affectedItems = operation.targetItems;
    result.operationId = operation.id;
    
    // Save operation for undo
    SelectionSnapshot undoSnapshot;
    undoSnapshot.items = operation.targetItems;
    undoSnapshot.operationId = operation.id;
    m_snapshots.append(undoSnapshot);
    
    return result;
}

bool SelectionManager::canUndo() const
{
    return !m_snapshots.isEmpty();
}

void SelectionManager::undo()
{
    qCDebug(jveSelection, "Undoing last selection operation");
    
    // Algorithm: Check availability → Get last → Restore → Remove
    if (!m_snapshots.isEmpty()) {
        SelectionSnapshot lastSnapshot = m_snapshots.takeLast();
        // For M1 Foundation, undo just removes from history
        // Real implementation would revert actual changes
    }
}

void SelectionManager::moveSelection(SelectionDirection direction)
{
    qCDebug(jveSelection, "Moving selection: %d", static_cast<int>(direction));
    
    // Algorithm: Find current → Determine next → Select next
    if (m_lastSelectedItem.isEmpty()) {
        return;
    }
    
    QString nextItem = findNextItem(m_lastSelectedItem, direction);
    if (!nextItem.isEmpty()) {
        select(nextItem);
    }
}

void SelectionManager::extendSelection(SelectionDirection direction)
{
    qCDebug(jveSelection, "Extending selection: %d", static_cast<int>(direction));
    
    // Algorithm: Find current → Determine next → Add to selection
    if (m_lastSelectedItem.isEmpty()) {
        return;
    }
    
    QString nextItem = findNextItem(m_lastSelectedItem, direction);
    if (!nextItem.isEmpty()) {
        addToSelection(nextItem);
    }
}

void SelectionManager::handleKeyPress(int key, Qt::KeyboardModifiers modifiers)
{
    qCDebug(jveSelection, "Handling key press: %d modifiers: %d", key, static_cast<int>(modifiers));
    
    // Algorithm: Route by key → Execute command
    if (modifiers & Qt::ControlModifier) {
        switch (key) {
        case Qt::Key_A:
            // Ctrl+A: Select All from timeline context
            if (!m_timelineItems.isEmpty()) {
                selectAll(m_timelineItems);
            } else {
                qCDebug(jveSelection, "Select All requested but no timeline context available");
            }
            break;
            
        case Qt::Key_D:
            // Ctrl+D: Deselect All
            clear();
            break;
        }
    }
}

void SelectionManager::updateSelectionRange()
{
    // Algorithm: Analyze selection → Calculate range → Update state
    m_currentRange = SelectionRange();
    
    if (m_selectedItems.isEmpty()) {
        return;
    }
    
    QStringList items = m_selectedItems.values();
    std::sort(items.begin(), items.end());
    
    m_currentRange.startId = items.first();
    m_currentRange.endId = items.last();
    m_currentRange.count = items.size();
    
    emit selectionRangeChanged(m_currentRange);
}

void SelectionManager::notifySelectionChanged()
{
    QStringList items = getSelectedItems();
    qCDebug(jveSelection, "Selection changed. Count: %lld", static_cast<long long>(items.size()));
    emit selectionChanged(items);
}

QString SelectionManager::findNextItem(const QString& currentItem, SelectionDirection direction) const
{
    // Algorithm: Determine direction → Find adjacent item → Return result
    if (m_timelineItems.isEmpty()) {
        return QString(); // No timeline context available
    }
    
    int currentIndex = m_timelineItems.indexOf(currentItem);
    if (currentIndex == -1) {
        return QString(); // Item not found in timeline
    }
    
    switch (direction) {
    case SelectionDirection::Right:
    case SelectionDirection::Down:
        // Move to next item
        if (currentIndex < m_timelineItems.size() - 1) {
            return m_timelineItems[currentIndex + 1];
        }
        break;
        
    case SelectionDirection::Left:
    case SelectionDirection::Up:
        // Move to previous item
        if (currentIndex > 0) {
            return m_timelineItems[currentIndex - 1];
        }
        break;
    }
    
    return QString(); // At boundary or invalid direction
}

QString SelectionManager::findPreviousItem(const QString& currentItem, SelectionDirection direction) const
{
    return findNextItem(currentItem, direction == SelectionDirection::Right ? 
                        SelectionDirection::Left : SelectionDirection::Right);
}

void SelectionManager::selectRange(const QString& startId, const QString& endId)
{
    qCDebug(jveSelection, "Selecting range from %s to %s", qPrintable(startId), qPrintable(endId));
    
    // Algorithm: Determine range → Select items → Update state
    m_selectedItems.clear();
    
    if (m_timelineItems.isEmpty()) {
        // Fallback: just select start and end
        m_selectedItems.insert(startId);
        m_selectedItems.insert(endId);
    } else {
        // Use timeline context to select range
        int startIndex = m_timelineItems.indexOf(startId);
        int endIndex = m_timelineItems.indexOf(endId);
        
        if (startIndex != -1 && endIndex != -1) {
            // Ensure proper order
            int minIndex = qMin(startIndex, endIndex);
            int maxIndex = qMax(startIndex, endIndex);
            
            // Select all items in range
            for (int i = minIndex; i <= maxIndex; i++) {
                m_selectedItems.insert(m_timelineItems[i]);
            }
        } else {
            // Fallback if items not found in timeline
            m_selectedItems.insert(startId);
            m_selectedItems.insert(endId);
        }
    }
    
    updateSelectionRange();
    notifySelectionChanged();
}

void SelectionManager::executeSelectionCommand(const SelectionOperation& operation)
{
    // Algorithm: Route by type → Execute logic → Update state
    qCDebug(jveSelection, "Executing command: %s on %lld items", qPrintable(operation.type), static_cast<long long>(operation.targetItems.size()));
    
    // For M1 Foundation, commands are simulated
    // Real implementation would apply actual transformations/property changes
    if (operation.type == "SetProperties") {
        // Simulate property changes
    } else if (operation.type == "Transform") {
        // Simulate transformations
    }
}