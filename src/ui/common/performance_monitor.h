#pragma once

#include <QObject>
#include <QTimer>
#include <QElapsedTimer>
#include <QMutex>
#include <QThread>
#include <QLoggingCategory>
#include <QHash>
#include <QQueue>
#include <QDateTime>
#include <QJsonObject>
#include <QJsonArray>
#include <QApplication>
#include <QWidget>
#include <QGraphicsView>
#include <QPainter>

Q_DECLARE_LOGGING_CATEGORY(jvePerformance)

/**
 * Professional performance monitoring and optimization system for video editing
 * 
 * Features:
 * - Real-time frame rate monitoring with professional video editing requirements
 * - Memory usage tracking with peak detection and leak monitoring
 * - UI responsiveness analysis with event processing time measurement
 * - Timeline rendering performance optimization and bottleneck detection
 * - Background processing monitoring for media operations and effects
 * - Professional performance profiling with detailed timing breakdowns
 * - Adaptive quality settings based on system performance capabilities
 * - Performance alerts and recommendations for professional workflows
 * 
 * Video Editing Specific Monitoring:
 * - Timeline scrubbing performance and responsiveness
 * - Media decoding and preview generation efficiency
 * - Effect processing and real-time playback capability analysis
 * - Multi-threaded operation monitoring for professional workloads
 * - GPU utilization tracking for accelerated operations
 * - Disk I/O monitoring for high-resolution media access
 * 
 * Professional Performance Standards:
 * - 60 FPS UI rendering for smooth professional interaction
 * - Sub-100ms response times for timeline operations
 * - Efficient memory management for large media files
 * - Optimized rendering pipelines for real-time preview
 * - Background processing that doesn't impact interactive performance
 * 
 * Adaptive Optimization:
 * - Dynamic quality adjustment based on performance metrics
 * - Automatic threading optimization for available CPU cores
 * - Memory management tuning for large project workflows
 * - Preview quality scaling for maintaining responsiveness
 * - Background task prioritization during intensive operations
 * 
 * Performance Reporting:
 * - Detailed performance reports for professional analysis
 * - Bottleneck identification with specific recommendations
 * - System capability assessment for project planning
 * - Performance trend analysis over editing sessions
 * - Professional workflow optimization suggestions
 */
class PerformanceMonitor : public QObject
{
    Q_OBJECT

public:
    enum PerformanceMetric {
        FrameRate,              // UI frame rate (target: 60 FPS)
        MemoryUsage,            // Current memory consumption
        MemoryPeak,             // Peak memory usage
        EventProcessingTime,    // UI event processing latency
        TimelineRenderTime,     // Timeline rendering performance
        MediaDecodingTime,      // Media decode performance
        EffectProcessingTime,   // Effect processing latency
        DiskIOThroughput,       // Disk read/write performance
        GPUUtilization,         // GPU usage percentage
        CPUUtilization,         // CPU usage percentage
        ThreadCount,            // Active thread count
        BackgroundTaskQueue     // Background task queue depth
    };

    enum PerformanceLevel {
        Excellent,              // > 95% of target performance
        Good,                   // 80-95% of target performance
        Acceptable,             // 60-80% of target performance
        Poor,                   // 40-60% of target performance
        Critical                // < 40% of target performance
    };

    enum OptimizationStrategy {
        HighQuality,            // Maximum quality, may impact performance
        Balanced,               // Balance between quality and performance
        Performance,            // Optimize for maximum performance
        Battery,                // Optimize for battery life (laptops)
        Professional            // Professional editing optimizations
    };

    struct PerformanceData {
        PerformanceMetric metric;
        qreal value;
        qreal target;
        qreal minimum;
        qreal maximum;
        QDateTime timestamp;
        QString unit;
        QString description;
    };

    struct PerformanceReport {
        QDateTime timestamp;
        QHash<PerformanceMetric, PerformanceData> metrics;
        PerformanceLevel overallLevel;
        QStringList bottlenecks;
        QStringList recommendations;
        QString summary;
    };

    struct SystemCapabilities {
        int cpuCores;
        qint64 totalMemory;
        QString gpuName;
        bool hasHardwareAcceleration;
        qreal diskReadSpeed;      // MB/s
        qreal diskWriteSpeed;     // MB/s
        QString operatingSystem;
        QString qtVersion;
    };

    explicit PerformanceMonitor(QObject* parent = nullptr);
    ~PerformanceMonitor();

    // Monitoring control
    void startMonitoring();
    void stopMonitoring();
    void pauseMonitoring();
    void resumeMonitoring();
    bool isMonitoring() const;

    // Configuration
    void setMonitoringInterval(int milliseconds);
    void setOptimizationStrategy(OptimizationStrategy strategy);
    void enableMetric(PerformanceMetric metric, bool enabled = true);
    void setMetricTarget(PerformanceMetric metric, qreal target);

    // Data access
    PerformanceData getCurrentMetric(PerformanceMetric metric) const;
    QList<PerformanceData> getMetricHistory(PerformanceMetric metric, int maxEntries = 100) const;
    PerformanceReport generateReport() const;
    SystemCapabilities getSystemCapabilities() const;

    // Performance analysis
    PerformanceLevel getOverallPerformanceLevel() const;
    QStringList getActiveBottlenecks() const;
    QStringList getOptimizationRecommendations() const;
    bool isPerformanceCritical() const;

    // Timeline-specific monitoring
    void startTimelineOperation(const QString& operationName);
    void endTimelineOperation(const QString& operationName);
    void recordTimelineFrameTime(qreal frameTimeMs);
    void recordMediaDecodingTime(const QString& mediaId, qreal decodingTimeMs);

    // Memory monitoring
    void recordMemoryAllocation(const QString& component, qint64 bytes);
    void recordMemoryDeallocation(const QString& component, qint64 bytes);
    qint64 getCurrentMemoryUsage() const;
    qint64 getPeakMemoryUsage() const;

    // Background task monitoring
    void registerBackgroundTask(const QString& taskId, const QString& description);
    void updateBackgroundTaskProgress(const QString& taskId, qreal progress);
    void completeBackgroundTask(const QString& taskId);
    int getActiveBackgroundTaskCount() const;

    // Adaptive optimization
    void enableAdaptiveOptimization(bool enabled = true);
    void triggerOptimization();
    OptimizationStrategy getCurrentStrategy() const;

    // Professional workflow optimization
    void optimizeForTimelineScrolling();
    void optimizeForEffectProcessing();
    void optimizeForMediaImport();
    void optimizeForColorCorrection();
    void optimizeForAudioMixing();

signals:
    // Performance alerts
    void performanceAlert(PerformanceLevel level, const QString& message);
    void bottleneckDetected(PerformanceMetric metric, qreal value, qreal target);
    void performanceImproved(PerformanceMetric metric, qreal improvement);
    void memoryLeakDetected(const QString& component, qint64 leakedBytes);
    void memoryPressureDetected();
    void systemPerformanceChanged(const QString& reason);

    // Optimization notifications
    void optimizationApplied(OptimizationStrategy strategy, const QStringList& changes);
    void adaptiveOptimizationTriggered(const QString& reason);

    // Reporting
    void reportGenerated(const PerformanceReport& report);
    void metricsUpdated(const QHash<PerformanceMetric, PerformanceData>& metrics);

public slots:
    void onApplicationStateChanged(Qt::ApplicationState state);
    void onMemoryPressure();
    void onSystemPerformanceChanged();

private slots:
    void updateMetrics();
    void checkPerformanceThresholds();
    void performAdaptiveOptimization();
    void cleanupOldData();

private:
    // Metric collection
    void collectFrameRateMetric();
    void collectMemoryMetrics();
    void collectCPUMetrics();
    void collectDiskIOMetrics();
    void collectTimelineMetrics();
    void collectBackgroundTaskMetrics();

    // Analysis
    PerformanceLevel calculatePerformanceLevel(PerformanceMetric metric, qreal value) const;
    QStringList identifyBottlenecks() const;
    QStringList generateRecommendations() const;

    // Optimization implementation
    void applyHighQualitySettings();
    void applyBalancedSettings();
    void applyPerformanceSettings();
    void applyBatterySettings();
    void applyProfessionalSettings();

    // Timeline optimization
    void optimizeTimelineRendering();
    void adjustPreviewQuality(qreal targetFPS);
    void optimizeScrollingPerformance();

    // Memory optimization
    void optimizeMemoryUsage();
    void cleanupUnusedResources();
    void adjustCacheSettings();

    // Threading optimization
    void optimizeThreadPool();
    void balanceBackgroundTasks();

    // System capability detection
    SystemCapabilities detectSystemCapabilities() const;
    bool detectHardwareAcceleration() const;
    qreal measureDiskSpeed() const;

    // Data management
    void storeMetric(PerformanceMetric metric, qreal value);
    void trimMetricHistory();
    void exportPerformanceData(const QString& filePath) const;
    
    // Preview quality management
    qreal getCurrentPreviewQuality() const;
    qreal getTargetPreviewQuality() const;

private:
    // Monitoring state
    bool m_isMonitoring = false;
    bool m_isPaused = false;
    int m_monitoringInterval = 1000; // 1 second
    OptimizationStrategy m_strategy = Balanced;

    // Timers and threads
    QTimer* m_metricsTimer = nullptr;
    QTimer* m_optimizationTimer = nullptr;
    QTimer* m_memoryCleanupTimer = nullptr;
    QElapsedTimer m_sessionTimer;

    // Performance data storage
    QHash<PerformanceMetric, QQueue<PerformanceData>> m_metricHistory;
    QHash<PerformanceMetric, PerformanceData> m_currentMetrics;
    QHash<PerformanceMetric, qreal> m_metricTargets;
    QHash<PerformanceMetric, bool> m_enabledMetrics;
    mutable QMutex m_dataMutex;

    // Timeline operation tracking
    QHash<QString, QElapsedTimer> m_activeOperations;
    QQueue<qreal> m_recentFrameTimes;

    // Memory tracking
    QHash<QString, qint64> m_componentMemoryUsage;
    qint64 m_currentMemoryUsage = 0;
    qint64 m_peakMemoryUsage = 0;
    QElapsedTimer m_lastMemoryCheck;

    // Background task tracking
    struct BackgroundTask {
        QString id;
        QString description;
        qreal progress = 0.0;
        QDateTime startTime;
        bool isCompleted = false;
    };
    QHash<QString, BackgroundTask> m_backgroundTasks;

    // System information
    SystemCapabilities m_systemCapabilities;

    // Adaptive optimization
    bool m_adaptiveOptimizationEnabled = true;
    QElapsedTimer m_lastOptimization;
    QHash<PerformanceMetric, PerformanceLevel> m_lastLevels;

    // Performance thresholds
    static constexpr qreal TARGET_FRAME_RATE = 60.0;
    static constexpr qreal MINIMUM_FRAME_RATE = 30.0;
    static constexpr qreal TARGET_EVENT_PROCESSING_TIME = 16.67; // 60 FPS
    static constexpr qreal CRITICAL_EVENT_PROCESSING_TIME = 100.0;
    static constexpr qreal MEMORY_WARNING_THRESHOLD = 0.8; // 80% of available memory
    static constexpr qreal MEMORY_CRITICAL_THRESHOLD = 0.95; // 95% of available memory
    static constexpr int MAX_METRIC_HISTORY = 1000;
    static constexpr int OPTIMIZATION_COOLDOWN_MS = 5000; // 5 seconds
};