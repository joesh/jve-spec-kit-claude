#pragma once

#include <QObject>
#include <QJsonObject>
#include <QJsonArray>
#include <QStringList>
#include <QSqlDatabase>

struct ClipEdge {
    QString clipId;
    QString edgeType; // "head" or "tail"
};

struct ClipSelectionResponse {
    int statusCode = 500;
    QStringList selectedClips;
    int selectionCount = 0;
    
    QJsonObject toJson() const {
        QJsonObject obj;
        QJsonArray clips;
        for (const QString& clipId : selectedClips) {
            clips.append(clipId);
        }
        obj["selected_clips"] = clips;
        obj["selection_count"] = selectionCount;
        return obj;
    }
};

struct EdgeSelectionResponse {
    int statusCode = 500;
    QList<ClipEdge> selectedEdges;
    int selectionCount = 0;
    
    QJsonObject toJson() const {
        QJsonObject obj;
        QJsonArray edges;
        for (const ClipEdge& edge : selectedEdges) {
            QJsonObject edgeObj;
            edgeObj["clip_id"] = edge.clipId;
            edgeObj["edge_type"] = edge.edgeType;
            edges.append(edgeObj);
        }
        obj["selected_edges"] = edges;
        obj["selection_count"] = selectionCount;
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
    int statusCode = 500;
    QHash<QString, PropertyValue> properties;
    QHash<QString, PropertyValue> metadata;
    
    QJsonObject toJson() const {
        QJsonObject obj;
        QJsonObject propsObj;
        QJsonObject metaObj;
        
        for (auto it = properties.constBegin(); it != properties.constEnd(); ++it) {
            propsObj[it.key()] = it.value().toJson();
        }
        
        for (auto it = metadata.constBegin(); it != metadata.constEnd(); ++it) {
            metaObj[it.key()] = it.value().toJson();
        }
        
        obj["properties"] = propsObj;
        obj["metadata"] = metaObj;
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
};