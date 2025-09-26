#include "../common/test_base.h"
#include "../../src/core/persistence/project_persistence.h"
#include "../../src/core/models/project.h"
#include "../../src/core/persistence/migrations.h"

#include <QTest>

/**
 * Contract Test T014: Project Persistence
 * 
 * Tests the Project persistence API contract - atomic save/load operations.
 * Must fail initially per constitutional TDD requirement.
 * 
 * Contract Requirements:
 * - Atomic save operations (all-or-nothing)
 * - Project file format validation (.jve)
 * - Concurrent access protection
 * - Backup and recovery mechanisms
 * - Constitutional single-file compliance
 * - Performance requirements for large projects
 */
class TestProjectPersistence : public TestBase
{
    Q_OBJECT

private slots:
    void initTestCase() override;
    void testAtomicSaveLoad();
    void testFileFormatValidation();
    void testConcurrentAccess();
    void testBackupRecovery();
    void testSingleFileCompliance();
    void testLargeProjectPerformance();

private:
    ProjectPersistence* m_persistence;
    QString m_testProjectPath;
};

void TestProjectPersistence::initTestCase()
{
    TestBase::initTestCase();
    verifyTDDCompliance();
    
    m_persistence = new ProjectPersistence(this);
    m_testProjectPath = m_testDataDir->filePath("persistence_test.jve");
}

void TestProjectPersistence::testAtomicSaveLoad()
{
    qCInfo(jveTests) << "Testing atomic save/load contract";
    verifyLibraryFirstCompliance();
    
    // Create comprehensive project data
    ProjectData projectData;
    projectData.project.setName("Atomic Test Project");
    projectData.project.setSettings(R"({"theme": "dark", "autoSave": true})");
    
    // Add sequences
    Sequence sequence1 = Sequence::create("Main Timeline", projectData.project.id());
    sequence1.setFramerate(29.97);
    sequence1.setResolution(1920, 1080);
    projectData.sequences.append(sequence1);
    
    Sequence sequence2 = Sequence::create("B-Roll Timeline", projectData.project.id());
    sequence2.setFramerate(29.97);
    sequence2.setResolution(1920, 1080);
    projectData.sequences.append(sequence2);
    
    // Add media
    Media media1 = Media::create("video1.mp4", "/path/video1.mp4");
    MediaMetadata metadata1;
    metadata1.duration = 120000;
    metadata1.width = 1920;
    metadata1.height = 1080;
    media1.setMetadata(metadata1);
    projectData.media.append(media1);
    
    // Add tracks and clips
    Track videoTrack = Track::createVideo("Video 1", sequence1.id());
    projectData.tracks.append(videoTrack);
    
    Clip clip1 = Clip::create("Clip 1", media1.id());
    clip1.setTimelinePosition(0, 5000);
    projectData.clips.append(clip1);
    
    // Test atomic save
    m_timer.restart();
    PersistenceResult saveResult = m_persistence->saveProject(m_testProjectPath, projectData);
    QVERIFY(saveResult.success);
    QVERIFY(saveResult.errorMessage.isEmpty());
    verifyPerformance("Atomic project save", 500);
    
    // Verify file exists and is valid
    QVERIFY(QFile::exists(m_testProjectPath));
    QFileInfo fileInfo(m_testProjectPath);
    QVERIFY(fileInfo.size() > 0);
    QCOMPARE(fileInfo.suffix(), QString("jve"));
    
    // Test atomic load
    m_timer.restart();
    PersistenceResult loadResult = m_persistence->loadProject(m_testProjectPath);
    QVERIFY(loadResult.success);
    QVERIFY(loadResult.projectData.has_value());
    verifyPerformance("Atomic project load", 300);
    
    ProjectData loadedData = loadResult.projectData.value();
    
    // Verify all data was preserved
    QCOMPARE(loadedData.project.name(), projectData.project.name());
    QCOMPARE(loadedData.project.settings(), projectData.project.settings());
    QCOMPARE(loadedData.sequences.size(), 2);
    QCOMPARE(loadedData.media.size(), 1);
    QCOMPARE(loadedData.tracks.size(), 1);
    QCOMPARE(loadedData.clips.size(), 1);
    
    // Verify sequence details
    Sequence loadedSeq1 = loadedData.sequences[0];
    QCOMPARE(loadedSeq1.name(), sequence1.name());
    QCOMPARE(loadedSeq1.framerate(), sequence1.framerate());
    QCOMPARE(loadedSeq1.width(), sequence1.width());
    QCOMPARE(loadedSeq1.height(), sequence1.height());
    
    // Verify media metadata
    Media loadedMedia = loadedData.media[0];
    QCOMPARE(loadedMedia.filename(), media1.filename());
    QCOMPARE(loadedMedia.filepath(), media1.filepath());
    QCOMPARE(loadedMedia.duration(), media1.duration());
}

void TestProjectPersistence::testFileFormatValidation()
{
    qCInfo(jveTests) << "Testing file format validation contract";
    
    // Test valid .jve extension requirement
    QString validPath = m_testDataDir->filePath("valid_project.jve");
    QString invalidPath = m_testDataDir->filePath("invalid_project.txt");
    
    ProjectData testData;
    testData.project.setName("Format Test");
    
    // Valid extension should succeed
    PersistenceResult validResult = m_persistence->saveProject(validPath, testData);
    QVERIFY(validResult.success);
    
    // Invalid extension should be rejected
    PersistenceResult invalidResult = m_persistence->saveProject(invalidPath, testData);
    QVERIFY(!invalidResult.success);
    QVERIFY(invalidResult.errorMessage.contains("jve"));
    
    // Test file header validation
    // Create corrupt file
    QString corruptPath = m_testDataDir->filePath("corrupt.jve");
    QFile corruptFile(corruptPath);
    QVERIFY(corruptFile.open(QIODevice::WriteOnly));
    corruptFile.write("This is not a valid JVE file");
    corruptFile.close();
    
    PersistenceResult corruptResult = m_persistence->loadProject(corruptPath);
    QVERIFY(!corruptResult.success);
    QVERIFY(corruptResult.errorMessage.contains("corrupt") || 
            corruptResult.errorMessage.contains("invalid"));
    
    // Test version compatibility
    QString oldVersionPath = m_testDataDir->filePath("old_version.jve");
    // Simulate old version file (implementation detail)
    PersistenceResult versionResult = m_persistence->createOldVersionFile(oldVersionPath, 0);
    
    PersistenceResult loadOldResult = m_persistence->loadProject(oldVersionPath);
    if (!loadOldResult.success) {
        // Should either migrate or reject gracefully
        QVERIFY(loadOldResult.errorMessage.contains("version") ||
                loadOldResult.success); // Migration succeeded
    }
}

void TestProjectPersistence::testConcurrentAccess()
{
    qCInfo(jveTests) << "Testing concurrent access protection contract";
    
    QString concurrentPath = m_testDataDir->filePath("concurrent_test.jve");
    
    ProjectData testData;
    testData.project.setName("Concurrent Test");
    
    // Save initial project
    QVERIFY(m_persistence->saveProject(concurrentPath, testData).success);
    
    // Test file locking during save
    ProjectPersistence persistence2(this);
    ProjectPersistence persistence3(this);
    
    // Start long-running save operation
    ProjectData largeData = createLargeProjectData();
    
    // This should acquire a lock
    std::future<PersistenceResult> saveTask = std::async(std::launch::async, [&]() {
        return m_persistence->saveProject(concurrentPath, largeData);
    });
    
    // Brief delay to ensure first save starts
    QThread::msleep(10);
    
    // Concurrent save should be blocked or queued
    PersistenceResult concurrentSave = persistence2.saveProject(concurrentPath, testData);
    // Implementation may either queue, reject, or wait
    // At minimum, data integrity must be preserved
    
    // Wait for first save to complete
    PersistenceResult firstResult = saveTask.get();
    QVERIFY(firstResult.success);
    
    // Verify file integrity after concurrent operations
    PersistenceResult verifyResult = persistence3.loadProject(concurrentPath);
    QVERIFY(verifyResult.success);
    
    // Data should be from one of the save operations (not corrupted)
    ProjectData finalData = verifyResult.projectData.value();
    QVERIFY(finalData.project.name() == "Concurrent Test" ||
            finalData.project.name().contains("Large Project"));
    
    // Test concurrent read operations (should be allowed)
    std::future<PersistenceResult> readTask1 = std::async(std::launch::async, [&]() {
        return persistence2.loadProject(concurrentPath);
    });
    
    std::future<PersistenceResult> readTask2 = std::async(std::launch::async, [&]() {
        return persistence3.loadProject(concurrentPath);
    });
    
    PersistenceResult read1 = readTask1.get();
    PersistenceResult read2 = readTask2.get();
    
    QVERIFY(read1.success);
    QVERIFY(read2.success);
    
    // Both reads should return identical data
    QCOMPARE(read1.projectData.value().project.name(),
             read2.projectData.value().project.name());
}

void TestProjectPersistence::testBackupRecovery()
{
    qCInfo(jveTests) << "Testing backup and recovery contract";
    
    QString mainPath = m_testDataDir->filePath("backup_test.jve");
    
    ProjectData originalData;
    originalData.project.setName("Backup Test Project");
    originalData.project.setSettings(R"({"version": 1, "important": true})");
    
    // Add some content
    Sequence sequence = Sequence::create("Main Timeline", originalData.project.id());
    originalData.sequences.append(sequence);
    
    // Save project
    QVERIFY(m_persistence->saveProject(mainPath, originalData).success);
    
    // Verify automatic backup creation
    QStringList backupFiles = m_persistence->findBackupFiles(mainPath);
    QVERIFY(backupFiles.size() >= 1); // At least one backup should exist
    
    // Simulate file corruption
    QFile mainFile(mainPath);
    QVERIFY(mainFile.open(QIODevice::WriteOnly));
    mainFile.write("CORRUPTED DATA");
    mainFile.close();
    
    // Recovery should use backup
    RecoveryResult recovery = m_persistence->attemptRecovery(mainPath);
    QVERIFY(recovery.success);
    QVERIFY(recovery.usedBackup);
    QVERIFY(!recovery.backupPath.isEmpty());
    
    // Verify recovered data
    PersistenceResult loadResult = m_persistence->loadProject(mainPath);
    QVERIFY(loadResult.success);
    
    ProjectData recoveredData = loadResult.projectData.value();
    QCOMPARE(recoveredData.project.name(), originalData.project.name());
    QCOMPARE(recoveredData.project.settings(), originalData.project.settings());
    QCOMPARE(recoveredData.sequences.size(), 1);
    
    // Test backup rotation
    for (int i = 0; i < 10; i++) {
        originalData.project.setSettings(QString(R"({"version": %1})").arg(i + 2));
        QVERIFY(m_persistence->saveProject(mainPath, originalData).success);
    }
    
    // Should maintain reasonable number of backups (not unlimited)
    QStringList allBackups = m_persistence->findBackupFiles(mainPath);
    QVERIFY(allBackups.size() <= 5); // Reasonable backup limit
    
    // Test manual backup creation
    QString manualBackupPath = m_persistence->createManualBackup(mainPath, "before_major_edit");
    QVERIFY(!manualBackupPath.isEmpty());
    QVERIFY(QFile::exists(manualBackupPath));
    QVERIFY(manualBackupPath.contains("before_major_edit"));
}

void TestProjectPersistence::testSingleFileCompliance()
{
    qCInfo(jveTests) << "Testing constitutional single-file compliance";
    
    QString projectPath = m_testDataDir->filePath("single_file_test.jve");
    
    ProjectData compliantData = createComplexProjectData();
    
    // Save project
    QVERIFY(m_persistence->saveProject(projectPath, compliantData).success);
    
    // Verify single file requirement
    QFileInfo projectFile(projectPath);
    QVERIFY(projectFile.exists());
    QCOMPARE(projectFile.suffix(), QString("jve"));
    
    // Check for prohibited sidecar files
    QDir projectDir = projectFile.dir();
    QString baseName = projectFile.baseName();
    
    QStringList prohibitedExtensions = {
        ".jve-wal", ".jve-shm", ".jve-journal",  // SQLite WAL mode files
        ".tmp", ".temp", ".lock", ".backup"       // Temporary files
    };
    
    for (const QString& ext : prohibitedExtensions) {
        QString prohibitedFile = projectDir.filePath(baseName + ext);
        QVERIFY2(!QFile::exists(prohibitedFile), 
                qPrintable(QString("Prohibited sidecar file found: %1").arg(prohibitedFile)));
    }
    
    // Verify all project data is contained within single file
    qint64 fileSize = projectFile.size();
    QVERIFY(fileSize > 1000); // Should have substantial content
    
    // Load project from different location (copy test)
    QString copyPath = m_testDataDir->filePath("copied_project.jve");
    QVERIFY(QFile::copy(projectPath, copyPath));
    
    PersistenceResult copyResult = m_persistence->loadProject(copyPath);
    QVERIFY(copyResult.success);
    
    // Verify complete project portability
    ProjectData copyData = copyResult.projectData.value();
    QCOMPARE(copyData.project.name(), compliantData.project.name());
    QCOMPARE(copyData.sequences.size(), compliantData.sequences.size());
    QCOMPARE(copyData.media.size(), compliantData.media.size());
    
    // Test constitutional journaling mode compliance
    // WAL mode may be used temporarily for performance but must be disabled on close
    DatabaseInfo dbInfo = m_persistence->getDatabaseInfo(projectPath);
    QVERIFY(dbInfo.journalMode != "wal" || dbInfo.allowsWalMode);
    
    // Verify no external dependencies
    QStringList dependencies = m_persistence->getExternalDependencies(copyData);
    // Media file paths are allowed, but no system-specific dependencies
    for (const QString& dep : dependencies) {
        QVERIFY(dep.startsWith("/") || dep.startsWith("C:") || dep.startsWith("file://"));
        QVERIFY(!dep.contains(".dll") && !dep.contains(".so") && !dep.contains(".dylib"));
    }
}

void TestProjectPersistence::testLargeProjectPerformance()
{
    qCInfo(jveTests) << "Testing large project performance contract";
    
    QString largePath = m_testDataDir->filePath("large_project.jve");
    
    // Create large project data
    ProjectData largeData = createLargeProjectData(1000); // 1000 clips
    
    // Test save performance
    m_timer.restart();
    PersistenceResult saveResult = m_persistence->saveProject(largePath, largeData);
    QVERIFY(saveResult.success);
    verifyPerformance("Large project save (1000 clips)", 5000); // 5 second limit
    
    // Verify file size is reasonable
    QFileInfo largeFile(largePath);
    qint64 fileSize = largeFile.size();
    QVERIFY(fileSize > 100000); // Should be substantial
    QVERIFY(fileSize < 100000000); // But not excessively large (100MB limit)
    
    qCInfo(jveTests) << "Large project file size:" << (fileSize / 1024) << "KB";
    
    // Test load performance
    m_timer.restart();
    PersistenceResult loadResult = m_persistence->loadProject(largePath);
    QVERIFY(loadResult.success);
    verifyPerformance("Large project load (1000 clips)", 3000); // 3 second limit
    
    // Verify data integrity
    ProjectData loadedLargeData = loadResult.projectData.value();
    QCOMPARE(loadedLargeData.clips.size(), 1000);
    QCOMPARE(loadedLargeData.media.size(), largeData.media.size());
    QCOMPARE(loadedLargeData.sequences.size(), largeData.sequences.size());
    
    // Test incremental save performance
    // Modify small portion of data
    loadedLargeData.project.setSettings(R"({"modified": true})");
    loadedLargeData.clips[0].setName("Modified Clip");
    
    m_timer.restart();
    PersistenceResult incrementalResult = m_persistence->saveProject(largePath, loadedLargeData);
    QVERIFY(incrementalResult.success);
    verifyPerformance("Incremental save (1 clip modified)", 1000); // Should be faster
    
    // Test memory usage during large operations
    size_t peakMemoryUsage = m_persistence->getPeakMemoryUsage();
    size_t fileSize_bytes = static_cast<size_t>(fileSize);
    
    // Memory usage should not exceed 3x file size during operations
    QVERIFY(peakMemoryUsage < fileSize_bytes * 3);
    
    qCInfo(jveTests) << "Peak memory usage:" << (peakMemoryUsage / 1024 / 1024) << "MB";
    qCInfo(jveTests) << "Memory efficiency ratio:" 
                     << (static_cast<double>(peakMemoryUsage) / fileSize_bytes);
}

// Helper methods
ProjectData TestProjectPersistence::createLargeProjectData(int clipCount)
{
    ProjectData data;
    data.project.setName(QString("Large Project (%1 clips)").arg(clipCount));
    
    // Create media files
    for (int i = 0; i < clipCount / 10; i++) {
        Media media = Media::create(QString("media_%1.mp4").arg(i), 
                                   QString("/path/media_%1.mp4").arg(i));
        MediaMetadata metadata;
        metadata.duration = 60000;
        metadata.width = 1920;
        metadata.height = 1080;
        media.setMetadata(metadata);
        data.media.append(media);
    }
    
    // Create sequences and tracks
    Sequence sequence = Sequence::create("Large Timeline", data.project.id());
    data.sequences.append(sequence);
    
    for (int t = 0; t < 10; t++) {
        Track track = (t % 2 == 0) ? 
                     Track::createVideo(QString("Video %1").arg(t + 1), sequence.id()) :
                     Track::createAudio(QString("Audio %1").arg(t + 1), sequence.id());
        track.setLayerIndex(t);
        data.tracks.append(track);
    }
    
    // Create clips
    for (int i = 0; i < clipCount; i++) {
        Media& media = data.media[i % data.media.size()];
        Track& track = data.tracks[i % data.tracks.size()];
        
        Clip clip = Clip::create(QString("Clip %1").arg(i + 1), media.id());
        clip.setTimelinePosition(i * 1000, (i + 1) * 1000); // 1 second clips
        
        // Add properties
        clip.setProperty("opacity", 1.0 - (i % 100) * 0.01);
        clip.setProperty("volume", 0.8 + (i % 50) * 0.004);
        
        data.clips.append(clip);
    }
    
    return data;
}

ProjectData TestProjectPersistence::createComplexProjectData()
{
    return createLargeProjectData(100); // Moderately complex project
}

QTEST_MAIN(TestProjectPersistence)
#include "test_project_persistence.moc"