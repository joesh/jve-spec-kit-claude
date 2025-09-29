#include "selection_manager.h"
#include "../common/uuid_generator.h"
#include <QElapsedTimer>
#include <QLoggingCategory>

Q_LOGGING_CATEGORY(jveSelectionAPI, "jve.api.selection")

SelectionAPI::SelectionAPI(QObject* parent)
    : QObject(parent)
{
}

void SelectionAPI::setDatabase(const QSqlDatabase& database)
{
    m_database = database;
}

ClipSelectionResponse SelectionAPI::getClipSelection()
{
    QElapsedTimer timer;
    timer.start();
    
    qCDebug(jveSelectionAPI, "Getting clip selection");
    
    ClipSelectionResponse response;
    
    // Set up response metadata
    response.metadata.timestamp = QDateTime::currentDateTime();
    response.metadata.requestId = UuidGenerator::instance()->generateSystemUuid();
    response.metadata.apiVersion = "1.0";
    
    try {
        // For now, return successful empty selection (TDD - minimal implementation)
        response.success = true;
        response.statusCode = 200;
        response.selectedClips = m_selectedClips;
        response.selectionCount = m_selectedClips.size();
        response.selectionMode = "replace";
        
        // TODO: Populate clip metadata from database
        // This is where real implementation would query database for clip details
        
    } catch (const std::exception& e) {
        response.success = false;
        response.statusCode = 500;
        response.error.code = "INTERNAL_ERROR";
        response.error.message = "Failed to retrieve clip selection";
        response.error.hint = "Check database connection and try again";
        response.error.audience = "developer";
        qCDebug(jveSelectionAPI, "Error getting clip selection: %s", e.what());
    }
    
    response.metadata.processingTimeMs = timer.elapsed();
    return response;
}

ClipSelectionResponse SelectionAPI::setClipSelection(const QJsonObject& request)
{
    QElapsedTimer timer;
    timer.start();
    
    qCDebug(jveSelectionAPI, "Setting clip selection");
    
    ClipSelectionResponse response;
    
    // Set up response metadata
    response.metadata.timestamp = QDateTime::currentDateTime();
    response.metadata.requestId = UuidGenerator::instance()->generateSystemUuid();
    response.metadata.apiVersion = "1.0";
    
    try {
        // Extract request parameters
        QString selectionMode = request["selection_mode"].toString("replace");
        QJsonArray clipIdsArray = request["clip_ids"].toArray();
        
        QStringList newClipIds;
        for (const QJsonValue& value : clipIdsArray) {
            newClipIds << value.toString();
        }
        
        // Apply selection based on mode
        if (selectionMode == "replace") {
            m_selectedClips = newClipIds;
        } else if (selectionMode == "add") {
            for (const QString& clipId : newClipIds) {
                if (!m_selectedClips.contains(clipId)) {
                    m_selectedClips << clipId;
                }
            }
        } else if (selectionMode == "remove") {
            for (const QString& clipId : newClipIds) {
                m_selectedClips.removeAll(clipId);
            }
        } else if (selectionMode == "toggle") {
            for (const QString& clipId : newClipIds) {
                if (m_selectedClips.contains(clipId)) {
                    m_selectedClips.removeAll(clipId);
                } else {
                    m_selectedClips << clipId;
                }
            }
        } else {
            response.success = false;
            response.statusCode = 400;
            response.error.code = "INVALID_SELECTION_MODE";
            response.error.message = QString("Invalid selection mode: %1").arg(selectionMode);
            response.error.hint = "Valid modes are: replace, add, remove, toggle";
            response.error.audience = "developer";
            response.metadata.processingTimeMs = timer.elapsed();
            return response;
        }
        
        // Build successful response
        response.success = true;
        response.statusCode = 200;
        response.selectedClips = m_selectedClips;
        response.selectionCount = m_selectedClips.size();
        response.selectionMode = selectionMode;
        
        qCDebug(jveSelectionAPI, "Selection updated: %d clips selected with mode %s", 
                response.selectionCount, qPrintable(selectionMode));
        
    } catch (const std::exception& e) {
        response.success = false;
        response.statusCode = 500;
        response.error.code = "INTERNAL_ERROR";
        response.error.message = "Failed to set clip selection";
        response.error.hint = "Check request format and try again";
        response.error.audience = "developer";
        qCDebug(jveSelectionAPI, "Error setting clip selection: %s", e.what());
    }
    
    response.metadata.processingTimeMs = timer.elapsed();
    return response;
}

EdgeSelectionResponse SelectionAPI::getEdgeSelection()
{
    QElapsedTimer timer;
    timer.start();
    
    qCDebug(jveSelectionAPI, "Getting edge selection");
    
    EdgeSelectionResponse response;
    
    // Set up response metadata
    response.metadata.timestamp = QDateTime::currentDateTime();
    response.metadata.requestId = UuidGenerator::instance()->generateSystemUuid();
    response.metadata.apiVersion = "1.0";
    
    try {
        response.success = true;
        response.statusCode = 200;
        response.selectedEdges = m_selectedEdges;
        response.selectionCount = m_selectedEdges.size();
        response.selectionMode = "replace";
        
        // TODO: Populate edge metadata from database
        // This is where real implementation would query database for edge details
        
    } catch (const std::exception& e) {
        response.success = false;
        response.statusCode = 500;
        response.error.code = "INTERNAL_ERROR";
        response.error.message = "Failed to retrieve edge selection";
        response.error.hint = "Check database connection and try again";
        response.error.audience = "developer";
        qCDebug(jveSelectionAPI, "Error getting edge selection: %s", e.what());
    }
    
    response.metadata.processingTimeMs = timer.elapsed();
    return response;
}

EdgeSelectionResponse SelectionAPI::setEdgeSelection(const QJsonObject& request)
{
    QElapsedTimer timer;
    timer.start();
    
    qCDebug(jveSelectionAPI, "Setting edge selection");
    
    EdgeSelectionResponse response;
    
    // Set up response metadata
    response.metadata.timestamp = QDateTime::currentDateTime();
    response.metadata.requestId = UuidGenerator::instance()->generateSystemUuid();
    response.metadata.apiVersion = "1.0";
    
    try {
        // Extract request parameters
        QString selectionMode = request["selection_mode"].toString("replace");
        QJsonArray edgesArray = request["edges"].toArray();
        
        QList<ClipEdge> newEdges;
        for (const QJsonValue& value : edgesArray) {
            QJsonObject edgeObj = value.toObject();
            ClipEdge edge;
            edge.clipId = edgeObj["clip_id"].toString();
            edge.edgeType = edgeObj["edge_type"].toString();
            edge.timePosition = edgeObj["time_position"].toVariant().toLongLong();
            edge.trackId = edgeObj["track_id"].toString();
            newEdges << edge;
        }
        
        // Apply selection based on mode
        if (selectionMode == "replace") {
            m_selectedEdges = newEdges;
        } else if (selectionMode == "add") {
            for (const ClipEdge& edge : newEdges) {
                bool found = false;
                for (const ClipEdge& existing : m_selectedEdges) {
                    if (existing.clipId == edge.clipId && existing.edgeType == edge.edgeType) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    m_selectedEdges << edge;
                }
            }
        } else if (selectionMode == "remove") {
            for (const ClipEdge& edge : newEdges) {
                for (int i = m_selectedEdges.size() - 1; i >= 0; i--) {
                    const ClipEdge& existing = m_selectedEdges[i];
                    if (existing.clipId == edge.clipId && existing.edgeType == edge.edgeType) {
                        m_selectedEdges.removeAt(i);
                    }
                }
            }
        } else if (selectionMode == "toggle") {
            for (const ClipEdge& edge : newEdges) {
                bool found = false;
                for (int i = m_selectedEdges.size() - 1; i >= 0; i--) {
                    const ClipEdge& existing = m_selectedEdges[i];
                    if (existing.clipId == edge.clipId && existing.edgeType == edge.edgeType) {
                        m_selectedEdges.removeAt(i);
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    m_selectedEdges << edge;
                }
            }
        } else {
            response.success = false;
            response.statusCode = 400;
            response.error.code = "INVALID_SELECTION_MODE";
            response.error.message = QString("Invalid selection mode: %1").arg(selectionMode);
            response.error.hint = "Valid modes are: replace, add, remove, toggle";
            response.error.audience = "developer";
            response.metadata.processingTimeMs = timer.elapsed();
            return response;
        }
        
        // Build successful response
        response.success = true;
        response.statusCode = 200;
        response.selectedEdges = m_selectedEdges;
        response.selectionCount = m_selectedEdges.size();
        response.selectionMode = selectionMode;
        
        qCDebug(jveSelectionAPI, "Edge selection updated: %d edges selected with mode %s", 
                response.selectionCount, qPrintable(selectionMode));
        
    } catch (const std::exception& e) {
        response.success = false;
        response.statusCode = 500;
        response.error.code = "INTERNAL_ERROR";
        response.error.message = "Failed to set edge selection";
        response.error.hint = "Check request format and try again";
        response.error.audience = "developer";
        qCDebug(jveSelectionAPI, "Error setting edge selection: %s", e.what());
    }
    
    response.metadata.processingTimeMs = timer.elapsed();
    return response;
}

SelectionPropertiesResponse SelectionAPI::getSelectionProperties()
{
    QElapsedTimer timer;
    timer.start();
    
    qCDebug(jveSelectionAPI, "Getting selection properties");
    
    SelectionPropertiesResponse response;
    
    // Set up response metadata
    response.responseMetadata.timestamp = QDateTime::currentDateTime();
    response.responseMetadata.requestId = UuidGenerator::instance()->generateSystemUuid();
    response.responseMetadata.apiVersion = "1.0";
    
    try {
        response.success = true;
        response.statusCode = 200;
        response.selectedClips = m_selectedClips;
        response.selectionCount = m_selectedClips.size();
        response.hasIndeterminateValues = false;
        
        // For empty selection, return empty properties
        if (m_selectedClips.isEmpty()) {
            response.responseMetadata.processingTimeMs = timer.elapsed();
            return response;
        }
        
        // TODO: Query database for actual clip properties
        // For now, return mock properties for demonstration
        if (m_selectedClips.size() == 1) {
            // Single selection - all values determinate
            PropertyValue enabledValue;
            enabledValue.value = true;
            enabledValue.state = "determinate";
            enabledValue.canUndo = true;
            response.properties["enabled"] = enabledValue;
            
            PropertyValue opacityValue;
            opacityValue.value = 1.0;
            opacityValue.state = "determinate";
            opacityValue.canUndo = true;
            response.properties["opacity"] = opacityValue;
            
            PropertyValue sceneValue;
            sceneValue.value = "Scene 1";
            sceneValue.state = "determinate";
            sceneValue.canUndo = false;
            response.metadata["scene"] = sceneValue;
            
            response.editableProperties = {"enabled", "opacity", "scale", "rotation"};
            response.lockedProperties = {"duration", "format"};
        } else {
            // Multi-selection - might have indeterminate values
            PropertyValue enabledValue;
            enabledValue.value = true;
            enabledValue.state = "determinate"; // Assume all clips have same enabled state
            enabledValue.canUndo = true;
            response.properties["enabled"] = enabledValue;
            
            PropertyValue opacityValue;
            opacityValue.value = QJsonValue(); // Mixed values
            opacityValue.state = "indeterminate";
            opacityValue.canUndo = true;
            response.properties["opacity"] = opacityValue;
            
            response.hasIndeterminateValues = true;
            response.editableProperties = {"enabled", "opacity", "scale", "rotation"};
            response.lockedProperties = {"duration", "format"};
        }
        
    } catch (const std::exception& e) {
        response.success = false;
        response.statusCode = 500;
        response.error.code = "INTERNAL_ERROR";
        response.error.message = "Failed to retrieve selection properties";
        response.error.hint = "Check database connection and try again";
        response.error.audience = "developer";
        qCDebug(jveSelectionAPI, "Error getting selection properties: %s", e.what());
    }
    
    response.responseMetadata.processingTimeMs = timer.elapsed();
    return response;
}

SelectionPropertiesResponse SelectionAPI::setSelectionProperty(const QJsonObject& request)
{
    QElapsedTimer timer;
    timer.start();
    
    qCDebug(jveSelectionAPI, "Setting selection property");
    
    SelectionPropertiesResponse response;
    
    // Set up response metadata
    response.responseMetadata.timestamp = QDateTime::currentDateTime();
    response.responseMetadata.requestId = UuidGenerator::instance()->generateSystemUuid();
    response.responseMetadata.apiVersion = "1.0";
    
    try {
        // Extract request parameters
        QString propertyName = request["property_name"].toString();
        QJsonValue propertyValue = request["property_value"];
        bool applyToMetadata = request["apply_to_metadata"].toBool(false);
        
        if (propertyName.isEmpty()) {
            response.success = false;
            response.statusCode = 400;
            response.error.code = "MISSING_PROPERTY_NAME";
            response.error.message = "Property name is required";
            response.error.hint = "Specify property_name in request";
            response.error.audience = "developer";
            response.responseMetadata.processingTimeMs = timer.elapsed();
            return response;
        }
        
        // TODO: Apply property change to database
        // For now, simulate successful property update
        
        PropertyValue updatedValue;
        updatedValue.value = propertyValue;
        updatedValue.state = "determinate"; // After setting, value becomes determinate
        updatedValue.canUndo = true;
        
        if (applyToMetadata) {
            response.metadata[propertyName] = updatedValue;
        } else {
            response.properties[propertyName] = updatedValue;
        }
        
        response.success = true;
        response.statusCode = 200;
        response.selectedClips = m_selectedClips;
        response.selectionCount = m_selectedClips.size();
        response.hasIndeterminateValues = false; // After setting, no more indeterminate values for this property
        
        response.editableProperties = {"enabled", "opacity", "scale", "rotation", "position_x", "position_y"};
        response.lockedProperties = {"duration", "format"};
        
        qCDebug(jveSelectionAPI, "Property '%s' updated for %d clips", 
                qPrintable(propertyName), response.selectionCount);
        
    } catch (const std::exception& e) {
        response.success = false;
        response.statusCode = 500;
        response.error.code = "INTERNAL_ERROR";
        response.error.message = "Failed to set selection property";
        response.error.hint = "Check request format and try again";
        response.error.audience = "developer";
        qCDebug(jveSelectionAPI, "Error setting selection property: %s", e.what());
    }
    
    response.responseMetadata.processingTimeMs = timer.elapsed();
    return response;
}