#include "performance_monitor.h"
#include <QApplication>
#include <QDebug>
#include <QSysInfo>
#include <QThread>
#include <QStandardPaths>
#include <QDir>
#include <QJsonDocument>
#include <QFile>

Q_LOGGING_CATEGORY(jvePerformance, "jve.ui.performance")

PerformanceMonitor::PerformanceMonitor(QObject* parent)
    : QObject(parent)
{
    qCDebug(jvePerformance) << "Initializing PerformanceMonitor";
    
    // Initialize system capabilities
    m_systemCapabilities = detectSystemCapabilities();
    
    // Set up default metric targets
    m_metricTargets[FrameRate] = TARGET_FRAME_RATE;
    m_metricTargets[EventProcessingTime] = TARGET_EVENT_PROCESSING_TIME;
    m_metricTargets[MemoryUsage] = m_systemCapabilities.totalMemory * 0.6; // 60% of total memory
    
    // Enable all metrics by default
    for (int i = FrameRate; i <= BackgroundTaskQueue; ++i) {
        m_enabledMetrics[static_cast<PerformanceMetric>(i)] = true;
    }
    
    // Set up timers
    m_metricsTimer = new QTimer(this);
    m_metricsTimer->setInterval(m_monitoringInterval);
    connect(m_metricsTimer, &QTimer::timeout, this, &PerformanceMonitor::updateMetrics);
    
    m_optimizationTimer = new QTimer(this);
    m_optimizationTimer->setInterval(5000); // Check every 5 seconds
    connect(m_optimizationTimer, &QTimer::timeout, this, &PerformanceMonitor::performAdaptiveOptimization);
    
    // Connect to application state changes
    if (QApplication* app = qobject_cast<QApplication*>(QApplication::instance())) {
        connect(app, &QApplication::applicationStateChanged,
                this, &PerformanceMonitor::onApplicationStateChanged);
    }
    
    qCDebug(jvePerformance) << "System capabilities detected:" 
                           << "CPU cores:" << m_systemCapabilities.cpuCores
                           << "Total memory:" << m_systemCapabilities.totalMemory / (1024*1024) << "MB"
                           << "GPU:" << m_systemCapabilities.gpuName
                           << "Hardware acceleration:" << m_systemCapabilities.hasHardwareAcceleration;
}

PerformanceMonitor::~PerformanceMonitor()
{
    stopMonitoring();
}

void PerformanceMonitor::startMonitoring()
{
    if (!m_isMonitoring) {
        m_isMonitoring = true;
        m_isPaused = false;
        m_sessionTimer.start();
        
        m_metricsTimer->start();
        if (m_adaptiveOptimizationEnabled) {
            m_optimizationTimer->start();
        }
        
        qCDebug(jvePerformance) << "Performance monitoring started";
    }
}

void PerformanceMonitor::stopMonitoring()
{
    if (m_isMonitoring) {
        m_isMonitoring = false;
        m_metricsTimer->stop();
        m_optimizationTimer->stop();
        
        qCDebug(jvePerformance) << "Performance monitoring stopped";
    }
}

void PerformanceMonitor::pauseMonitoring()
{
    if (m_isMonitoring && !m_isPaused) {
        m_isPaused = true;
        m_metricsTimer->stop();
        qCDebug(jvePerformance) << "Performance monitoring paused";
    }
}

void PerformanceMonitor::resumeMonitoring()
{
    if (m_isMonitoring && m_isPaused) {
        m_isPaused = false;
        m_metricsTimer->start();
        qCDebug(jvePerformance) << "Performance monitoring resumed";
    }
}

bool PerformanceMonitor::isMonitoring() const
{
    return m_isMonitoring && !m_isPaused;
}

void PerformanceMonitor::setMonitoringInterval(int milliseconds)
{
    m_monitoringInterval = milliseconds;
    if (m_metricsTimer) {
        m_metricsTimer->setInterval(milliseconds);
    }
    qCDebug(jvePerformance) << "Monitoring interval set to:" << milliseconds << "ms";
}

void PerformanceMonitor::setOptimizationStrategy(OptimizationStrategy strategy)
{
    if (m_strategy != strategy) {
        m_strategy = strategy;
        
        // Apply strategy-specific settings
        switch (strategy) {
        case HighQuality:
            applyHighQualitySettings();
            break;
        case Balanced:
            applyBalancedSettings();
            break;
        case Performance:
            applyPerformanceSettings();
            break;
        case Battery:
            applyBatterySettings();
            break;
        case Professional:
            applyProfessionalSettings();
            break;
        }
        
        emit optimizationApplied(strategy, QStringList());
        qCDebug(jvePerformance) << "Optimization strategy changed to:" << strategy;
    }
}

PerformanceMonitor::PerformanceData PerformanceMonitor::getCurrentMetric(PerformanceMetric metric) const
{
    QMutexLocker locker(&m_dataMutex);
    return m_currentMetrics.value(metric);
}

QList<PerformanceMonitor::PerformanceData> PerformanceMonitor::getMetricHistory(PerformanceMetric metric, int maxEntries) const
{
    QMutexLocker locker(&m_dataMutex);
    QList<PerformanceData> history;
    
    if (m_metricHistory.contains(metric)) {
        const QQueue<PerformanceData>& queue = m_metricHistory[metric];
        int count = qMin(maxEntries, queue.size());
        
        for (int i = queue.size() - count; i < queue.size(); ++i) {
            history.append(queue.at(i));
        }
    }
    
    return history;
}

PerformanceMonitor::PerformanceLevel PerformanceMonitor::getOverallPerformanceLevel() const
{
    QMutexLocker locker(&m_dataMutex);
    
    QList<PerformanceLevel> levels;
    
    // Check critical metrics
    levels << calculatePerformanceLevel(FrameRate, m_currentMetrics.value(FrameRate).value);
    levels << calculatePerformanceLevel(EventProcessingTime, m_currentMetrics.value(EventProcessingTime).value);
    levels << calculatePerformanceLevel(MemoryUsage, m_currentMetrics.value(MemoryUsage).value);
    
    // Find the worst performing metric
    PerformanceLevel worst = Excellent;
    for (PerformanceLevel level : levels) {
        if (level > worst) {
            worst = level;
        }
    }
    
    return worst;
}

void PerformanceMonitor::startTimelineOperation(const QString& operationName)
{
    m_activeOperations[operationName].start();
}

void PerformanceMonitor::endTimelineOperation(const QString& operationName)
{
    if (m_activeOperations.contains(operationName)) {
        qint64 elapsed = m_activeOperations[operationName].elapsed();
        storeMetric(TimelineRenderTime, elapsed);
        m_activeOperations.remove(operationName);
        
        qCDebug(jvePerformance) << "Timeline operation" << operationName << "took" << elapsed << "ms";
    }
}

void PerformanceMonitor::recordTimelineFrameTime(qreal frameTimeMs)
{
    m_recentFrameTimes.enqueue(frameTimeMs);
    if (m_recentFrameTimes.size() > 60) { // Keep last 60 frames (1 second at 60 FPS)
        m_recentFrameTimes.dequeue();
    }
    
    // Calculate current frame rate
    if (!m_recentFrameTimes.isEmpty()) {
        qreal avgFrameTime = 0;
        for (qreal time : m_recentFrameTimes) {
            avgFrameTime += time;
        }
        avgFrameTime /= m_recentFrameTimes.size();
        
        qreal fps = (avgFrameTime > 0) ? 1000.0 / avgFrameTime : 0;
        storeMetric(FrameRate, fps);
    }
}

qint64 PerformanceMonitor::getCurrentMemoryUsage() const
{
    return m_currentMemoryUsage;
}

qint64 PerformanceMonitor::getPeakMemoryUsage() const
{
    return m_peakMemoryUsage;
}

void PerformanceMonitor::recordMemoryAllocation(const QString& component, qint64 bytes)
{
    m_componentMemoryUsage[component] += bytes;
    m_currentMemoryUsage += bytes;
    
    if (m_currentMemoryUsage > m_peakMemoryUsage) {
        m_peakMemoryUsage = m_currentMemoryUsage;
    }
    
    // Check for memory pressure
    qreal memoryPressure = static_cast<qreal>(m_currentMemoryUsage) / m_systemCapabilities.totalMemory;
    if (memoryPressure > MEMORY_CRITICAL_THRESHOLD) {
        emit performanceAlert(Critical, QString("Critical memory usage: %1%").arg(memoryPressure * 100, 0, 'f', 1));
    } else if (memoryPressure > MEMORY_WARNING_THRESHOLD) {
        emit performanceAlert(Poor, QString("High memory usage: %1%").arg(memoryPressure * 100, 0, 'f', 1));
    }
}

void PerformanceMonitor::recordMemoryDeallocation(const QString& component, qint64 bytes)
{
    m_componentMemoryUsage[component] -= bytes;
    m_currentMemoryUsage -= bytes;
    
    if (m_currentMemoryUsage < 0) {
        m_currentMemoryUsage = 0;
    }
}

void PerformanceMonitor::updateMetrics()
{
    if (!isMonitoring()) return;
    
    collectFrameRateMetric();
    collectMemoryMetrics();
    collectCPUMetrics();
    collectTimelineMetrics();
    collectBackgroundTaskMetrics();
    
    // Emit updated metrics
    {
        QMutexLocker locker(&m_dataMutex);
        emit metricsUpdated(m_currentMetrics);
    }
    
    // Check performance thresholds
    checkPerformanceThresholds();
    
    // Clean up old data periodically
    if (m_sessionTimer.elapsed() % 60000 < m_monitoringInterval) { // Every minute
        cleanupOldData();
    }
}

void PerformanceMonitor::collectFrameRateMetric()
{
    // Frame rate is updated by recordTimelineFrameTime()
    // This is just a placeholder for additional frame rate analysis
}

void PerformanceMonitor::collectMemoryMetrics()
{
    storeMetric(MemoryUsage, m_currentMemoryUsage);
    storeMetric(MemoryPeak, m_peakMemoryUsage);
}

void PerformanceMonitor::collectCPUMetrics()
{
    // Simplified CPU utilization - in a real implementation,
    // this would use platform-specific APIs
    storeMetric(CPUUtilization, 0.0); // Placeholder
    storeMetric(ThreadCount, QThread::idealThreadCount());
}

void PerformanceMonitor::collectTimelineMetrics()
{
    // Timeline metrics are collected by timeline operations
    // This could include additional timeline-specific analysis
}

void PerformanceMonitor::collectBackgroundTaskMetrics()
{
    storeMetric(BackgroundTaskQueue, getActiveBackgroundTaskCount());
}

void PerformanceMonitor::checkPerformanceThresholds()
{
    QStringList issues;
    
    // Check frame rate
    qreal currentFPS = getCurrentMetric(FrameRate).value;
    if (currentFPS < MINIMUM_FRAME_RATE && currentFPS > 0) {
        issues << QString("Low frame rate: %1 FPS").arg(currentFPS, 0, 'f', 1);
        emit bottleneckDetected(FrameRate, currentFPS, TARGET_FRAME_RATE);
    }
    
    // Check event processing time
    qreal eventTime = getCurrentMetric(EventProcessingTime).value;
    if (eventTime > CRITICAL_EVENT_PROCESSING_TIME) {
        issues << QString("Slow UI response: %1 ms").arg(eventTime, 0, 'f', 1);
        emit bottleneckDetected(EventProcessingTime, eventTime, TARGET_EVENT_PROCESSING_TIME);
    }
    
    // Check memory usage
    qreal memoryPressure = static_cast<qreal>(m_currentMemoryUsage) / m_systemCapabilities.totalMemory;
    if (memoryPressure > MEMORY_WARNING_THRESHOLD) {
        issues << QString("High memory usage: %1%").arg(memoryPressure * 100, 0, 'f', 1);
        emit bottleneckDetected(MemoryUsage, m_currentMemoryUsage, m_systemCapabilities.totalMemory * 0.6);
    }
    
    if (!issues.isEmpty()) {
        PerformanceLevel level = getOverallPerformanceLevel();
        emit performanceAlert(level, issues.join("; "));
    }
}

void PerformanceMonitor::storeMetric(PerformanceMetric metric, qreal value)
{
    if (!m_enabledMetrics.value(metric, false)) return;
    
    QMutexLocker locker(&m_dataMutex);
    
    PerformanceData data;
    data.metric = metric;
    data.value = value;
    data.target = m_metricTargets.value(metric, 0);
    data.timestamp = QDateTime::currentDateTime();
    
    // Set metric-specific properties
    switch (metric) {
    case FrameRate:
        data.unit = "FPS";
        data.description = "User interface frame rate";
        data.minimum = 0;
        data.maximum = 120;
        break;
    case MemoryUsage:
        data.unit = "bytes";
        data.description = "Current memory usage";
        data.minimum = 0;
        data.maximum = m_systemCapabilities.totalMemory;
        break;
    case EventProcessingTime:
        data.unit = "ms";
        data.description = "UI event processing time";
        data.minimum = 0;
        data.maximum = 1000;
        break;
    default:
        data.unit = "";
        data.description = "Performance metric";
        data.minimum = 0;
        data.maximum = 100;
        break;
    }
    
    // Store current metric
    m_currentMetrics[metric] = data;
    
    // Add to history
    if (!m_metricHistory.contains(metric)) {
        m_metricHistory[metric] = QQueue<PerformanceData>();
    }
    
    QQueue<PerformanceData>& history = m_metricHistory[metric];
    history.enqueue(data);
    
    // Limit history size
    while (history.size() > MAX_METRIC_HISTORY) {
        history.dequeue();
    }
}

PerformanceMonitor::PerformanceLevel PerformanceMonitor::calculatePerformanceLevel(PerformanceMetric metric, qreal value) const
{
    qreal target = m_metricTargets.value(metric, 1.0);
    if (target <= 0) return Excellent;
    
    qreal ratio = value / target;
    
    // For metrics where lower is better (like processing time)
    bool lowerIsBetter = (metric == EventProcessingTime || 
                         metric == TimelineRenderTime || 
                         metric == MediaDecodingTime ||
                         metric == EffectProcessingTime);
    
    if (lowerIsBetter) {
        ratio = target / value; // Invert the ratio
    }
    
    if (ratio >= 0.95) return Excellent;
    if (ratio >= 0.80) return Good;
    if (ratio >= 0.60) return Acceptable;
    if (ratio >= 0.40) return Poor;
    return Critical;
}

PerformanceMonitor::SystemCapabilities PerformanceMonitor::detectSystemCapabilities() const
{
    SystemCapabilities caps;
    
    caps.cpuCores = QThread::idealThreadCount();
    caps.totalMemory = 8LL * 1024 * 1024 * 1024; // Default to 8GB, would use platform APIs in real implementation
    caps.gpuName = "Unknown GPU"; // Would detect actual GPU
    caps.hasHardwareAcceleration = detectHardwareAcceleration();
    caps.diskReadSpeed = measureDiskSpeed();
    caps.diskWriteSpeed = caps.diskReadSpeed * 0.8; // Estimate
    caps.operatingSystem = QSysInfo::prettyProductName();
    caps.qtVersion = QT_VERSION_STR;
    
    return caps;
}

bool PerformanceMonitor::detectHardwareAcceleration() const
{
    // Simplified detection - would use platform-specific APIs
    return true;
}

qreal PerformanceMonitor::measureDiskSpeed() const
{
    // Simplified disk speed measurement - would implement actual benchmark
    return 500.0; // MB/s estimate
}

void PerformanceMonitor::applyProfessionalSettings()
{
    qCDebug(jvePerformance) << "Applying professional optimization settings";
    
    // Professional settings optimize for quality and reliability
    optimizeTimelineRendering();
    optimizeMemoryUsage();
    optimizeThreadPool();
}

void PerformanceMonitor::applyPerformanceSettings()
{
    qCDebug(jvePerformance) << "Applying performance optimization settings";
    
    // Performance settings optimize for maximum responsiveness
    adjustPreviewQuality(TARGET_FRAME_RATE);
    cleanupUnusedResources();
    balanceBackgroundTasks();
}

void PerformanceMonitor::applyBalancedSettings()
{
    qCDebug(jvePerformance) << "Applying balanced optimization settings";
    
    // Balanced settings provide good quality with acceptable performance
    adjustPreviewQuality(TARGET_FRAME_RATE * 0.8);
}

void PerformanceMonitor::applyHighQualitySettings()
{
    qCDebug(jvePerformance) << "Applying high quality settings";
    // Quality settings prioritize visual fidelity
}

void PerformanceMonitor::applyBatterySettings()
{
    qCDebug(jvePerformance) << "Applying battery optimization settings";
    // Battery settings reduce power consumption
}

void PerformanceMonitor::optimizeTimelineRendering()
{
    // Timeline rendering optimizations would go here
    qCDebug(jvePerformance) << "Optimizing timeline rendering performance";
}

void PerformanceMonitor::adjustPreviewQuality(qreal targetFPS)
{
    Q_UNUSED(targetFPS)
    // Preview quality adjustments would go here
    qCDebug(jvePerformance) << "Adjusting preview quality for target FPS:" << targetFPS;
}

void PerformanceMonitor::optimizeMemoryUsage()
{
    // Memory usage optimizations would go here
    qCDebug(jvePerformance) << "Optimizing memory usage";
    cleanupUnusedResources();
}

void PerformanceMonitor::cleanupUnusedResources()
{
    // Resource cleanup would go here
    qCDebug(jvePerformance) << "Cleaning up unused resources";
}

void PerformanceMonitor::optimizeThreadPool()
{
    // Thread pool optimizations would go here
    qCDebug(jvePerformance) << "Optimizing thread pool configuration";
}

void PerformanceMonitor::balanceBackgroundTasks()
{
    // Background task balancing would go here
    qCDebug(jvePerformance) << "Balancing background task load";
}

void PerformanceMonitor::performAdaptiveOptimization()
{
    if (!m_adaptiveOptimizationEnabled) return;
    
    // Don't optimize too frequently
    if (m_lastOptimization.isValid() && m_lastOptimization.elapsed() < OPTIMIZATION_COOLDOWN_MS) {
        return;
    }
    
    PerformanceLevel currentLevel = getOverallPerformanceLevel();
    
    // Only optimize if performance is poor or critical
    if (currentLevel >= Poor) {
        QString reason = QString("Performance level: %1").arg(currentLevel);
        emit adaptiveOptimizationTriggered(reason);
        
        // Apply appropriate optimizations based on current strategy
        switch (m_strategy) {
        case Performance:
        case Professional:
            applyPerformanceSettings();
            break;
        case Balanced:
            if (currentLevel == Critical) {
                applyPerformanceSettings();
            } else {
                applyBalancedSettings();
            }
            break;
        default:
            break;
        }
        
        m_lastOptimization.start();
    }
}

void PerformanceMonitor::cleanupOldData()
{
    QMutexLocker locker(&m_dataMutex);
    
    // Clean up metric history older than 1 hour
    QDateTime cutoff = QDateTime::currentDateTime().addSecs(-3600);
    
    for (auto it = m_metricHistory.begin(); it != m_metricHistory.end(); ++it) {
        QQueue<PerformanceData>& queue = it.value();
        while (!queue.isEmpty() && queue.first().timestamp < cutoff) {
            queue.dequeue();
        }
    }
}

int PerformanceMonitor::getActiveBackgroundTaskCount() const
{
    int count = 0;
    for (const BackgroundTask& task : m_backgroundTasks) {
        if (!task.isCompleted) {
            count++;
        }
    }
    return count;
}

void PerformanceMonitor::onApplicationStateChanged(Qt::ApplicationState state)
{
    switch (state) {
    case Qt::ApplicationSuspended:
        pauseMonitoring();
        break;
    case Qt::ApplicationActive:
        resumeMonitoring();
        break;
    default:
        break;
    }
}