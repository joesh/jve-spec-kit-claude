#pragma once

#include <QObject>
#include <QJsonObject>
#include <QJsonArray>
#include <QStringList>
#include <QSqlDatabase>
#include <QDateTime>

/**
 * Professional API response structures for video editing selection system
 * 
 * Follows REST API best practices with comprehensive error handling,
 * standardized response formats, and professional video editing metadata.
 */

struct APIError {
    QString code;
    QString message;
    QString hint;
    QString audience; // "user" or "developer"
    
    QJsonObject toJson() const {
        QJsonObject obj;
        obj["code"] = code;
        obj["message"] = message;
        obj["hint"] = hint;
        obj["audience"] = audience;
        return obj;
    }
    
    bool isEmpty() const {
        return code.isEmpty() && message.isEmpty();
    }
};

struct ResponseMetadata {
    QDateTime timestamp;
    QString requestId;
    int processingTimeMs = 0;
    QString apiVersion = "1.0";
    
    QJsonObject toJson() const {
        QJsonObject obj;
        obj["timestamp"] = timestamp.toString(Qt::ISODate);
        obj["request_id"] = requestId;
        obj["processing_time_ms"] = processingTimeMs;
        obj["api_version"] = apiVersion;
        return obj;
    }
};

struct ClipEdge {
    QString clipId;
    QString edgeType; // "head" or "tail"
    qint64 timePosition = 0; // Timeline position in milliseconds
    QString trackId;
    
    QJsonObject toJson() const {
        QJsonObject obj;
        obj["clip_id"] = clipId;
        obj["edge_type"] = edgeType;
        obj["time_position"] = timePosition;
        obj["track_id"] = trackId;
        return obj;
    }
};

struct ClipSelectionResponse {
    bool success = false;
    int statusCode = 500;
    QStringList selectedClips;
    int selectionCount = 0;
    QString selectionMode = "replace"; // "replace", "add", "remove", "toggle"
    APIError error;
    ResponseMetadata metadata;
    
    // Professional video editing specific fields
    QHash<QString, QString> clipNames;     // clipId -> name mapping
    QHash<QString, QString> clipTypes;     // clipId -> type (video/audio) mapping
    QHash<QString, qint64> clipDurations;  // clipId -> duration mapping
    QHash<QString, QString> trackIds;      // clipId -> trackId mapping
    
    QJsonObject toJson() const {
        QJsonObject obj;
        obj["success"] = success;
        obj["status_code"] = statusCode;
        
        QJsonArray clips;
        for (const QString& clipId : selectedClips) {
            QJsonObject clipObj;
            clipObj["id"] = clipId;
            clipObj["name"] = clipNames.value(clipId, "");
            clipObj["type"] = clipTypes.value(clipId, "video");
            clipObj["duration"] = clipDurations.value(clipId, 0);
            clipObj["track_id"] = trackIds.value(clipId, "");
            clips.append(clipObj);
        }
        obj["selected_clips"] = clips;
        obj["selection_count"] = selectionCount;
        obj["selection_mode"] = selectionMode;
        
        if (!error.isEmpty()) {
            obj["error"] = error.toJson();
        }
        
        obj["metadata"] = metadata.toJson();
        return obj;
    }
};

struct EdgeSelectionResponse {
    bool success = false;
    int statusCode = 500;
    QList<ClipEdge> selectedEdges;
    int selectionCount = 0;
    QString selectionMode = "replace";
    APIError error;
    ResponseMetadata metadata;
    
    // Professional editing context
    QHash<QString, QString> clipNames;    // clipId -> name mapping
    QHash<QString, qint64> edgePositions; // edge identifier -> timeline position
    
    QJsonObject toJson() const {
        QJsonObject obj;
        obj["success"] = success;
        obj["status_code"] = statusCode;
        
        QJsonArray edges;
        for (const ClipEdge& edge : selectedEdges) {
            QJsonObject edgeObj = edge.toJson();
            edgeObj["clip_name"] = clipNames.value(edge.clipId, "");
            edges.append(edgeObj);
        }
        obj["selected_edges"] = edges;
        obj["selection_count"] = selectionCount;
        obj["selection_mode"] = selectionMode;
        
        if (!error.isEmpty()) {
            obj["error"] = error.toJson();
        }
        
        obj["metadata"] = metadata.toJson();
        return obj;
    }
};

struct PropertyValue {
    QJsonValue value;
    QString state; // "determinate" or "indeterminate"
    bool canUndo = false;
    
    QJsonObject toJson() const {
        QJsonObject obj;
        obj["value"] = value;
        obj["state"] = state;
        obj["can_undo"] = canUndo;
        return obj;
    }
};

struct SelectionPropertiesResponse {
    bool success = false;
    int statusCode = 500;
    QHash<QString, PropertyValue> properties;
    QHash<QString, PropertyValue> metadata;
    QStringList selectedClips;
    int selectionCount = 0;
    APIError error;
    ResponseMetadata responseMetadata;
    
    // Professional property editing context
    bool hasIndeterminateValues = false;
    QStringList editableProperties;    // Properties that can be edited
    QStringList lockedProperties;      // Properties that are locked/read-only
    
    QJsonObject toJson() const {
        QJsonObject obj;
        obj["success"] = success;
        obj["status_code"] = statusCode;
        obj["selection_count"] = selectionCount;
        obj["has_indeterminate_values"] = hasIndeterminateValues;
        
        QJsonObject propsObj;
        for (auto it = properties.constBegin(); it != properties.constEnd(); ++it) {
            propsObj[it.key()] = it.value().toJson();
        }
        
        QJsonObject metaObj;
        for (auto it = metadata.constBegin(); it != metadata.constEnd(); ++it) {
            metaObj[it.key()] = it.value().toJson();
        }
        
        obj["properties"] = propsObj;
        obj["metadata"] = metaObj;
        
        QJsonArray editableArray;
        for (const QString& prop : editableProperties) {
            editableArray.append(prop);
        }
        obj["editable_properties"] = editableArray;
        
        QJsonArray lockedArray;
        for (const QString& prop : lockedProperties) {
            lockedArray.append(prop);
        }
        obj["locked_properties"] = lockedArray;
        
        QJsonArray clipsArray;
        for (const QString& clipId : selectedClips) {
            clipsArray.append(clipId);
        }
        obj["selected_clips"] = clipsArray;
        
        if (!error.isEmpty()) {
            obj["error"] = error.toJson();
        }
        
        obj["metadata"] = responseMetadata.toJson();
        return obj;
    }
};

/**
 * SelectionAPI - High-level selection operations
 * 
 * Implements the REST API contract for selection operations:
 * - GET/POST /selection/clips (multi-clip selection)
 * - GET/POST /selection/edges (edge selection for ripple/roll)
 * - GET/POST /selection/properties (tri-state property editing)
 * 
 * This is a stub implementation that will fail all tests initially
 * per TDD requirements.
 */
class SelectionAPI : public QObject
{
    Q_OBJECT

public:
    explicit SelectionAPI(QObject* parent = nullptr);
    
    void setDatabase(const QSqlDatabase& database);
    ClipSelectionResponse getClipSelection();
    ClipSelectionResponse setClipSelection(const QJsonObject& request);
    EdgeSelectionResponse getEdgeSelection();
    EdgeSelectionResponse setEdgeSelection(const QJsonObject& request);
    SelectionPropertiesResponse getSelectionProperties();
    SelectionPropertiesResponse setSelectionProperty(const QJsonObject& request);
    
private:
    QSqlDatabase m_database;
    QStringList m_selectedClips;
    QList<ClipEdge> m_selectedEdges;
};