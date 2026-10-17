#include "settings/SettingsSession.hpp"

#include <QDateTime>
#include <QDir>
#include <QDirIterator>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLocale>
#include <QSysInfo>
#include <QUrl>
#include <QtConcurrent/QtConcurrentRun>

#include "app/AppPaths.hpp"
#include "app/ApplicationController.hpp"
#include "settings/SettingsStore.hpp"

namespace
{
// `SettingsDetailView.swift:907-912`: the directories the image cache spans.
[[nodiscard]] QStringList imageCacheDirectories()
{
    return {AppPaths::artworkCacheDirectory(), AppPaths::thumbnailCacheDirectory()};
}

[[nodiscard]] qint64 totalRegularFileBytes(const QStringList &directories)
{
    qint64 total = 0;
    for (const QString &directory : directories) {
        QDirIterator files(directory, QDir::Files | QDir::NoDotAndDotDot,
                           QDirIterator::Subdirectories);
        while (files.hasNext()) {
            total += files.nextFileInfo().size();
        }
    }
    return total;
}

void removeCacheContents(const QStringList &directories)
{
    for (const QString &directory : directories) {
        QDir dir(directory);
        if (!dir.exists()) {
            continue;
        }
        for (const QFileInfo &entry :
             dir.entryInfoList(QDir::AllEntries | QDir::NoDotAndDotDot | QDir::Hidden)) {
            if (entry.isDir()) {
                QDir(entry.absoluteFilePath()).removeRecursively();
            } else {
                QFile::remove(entry.absoluteFilePath());
            }
        }
    }
}

// `ByteCountFormatter` with `.file` writes "Zero KB" for nothing and one
// decimal from megabytes up.
[[nodiscard]] QString formatFileSize(qint64 bytes)
{
    if (bytes == 0) {
        return QStringLiteral("Zero KB");
    }
    return QLocale().formattedDataSize(bytes, 1, QLocale::DataSizeSIFormat);
}

[[nodiscard]] QString writeDiagnosticsSnapshot(const QString &version,
                                               const QStringList &roots)
{
    const QString directory = QDir(AppPaths::dataDirectory()).filePath(QStringLiteral("diagnostics"));
    if (!QDir().mkpath(directory)) {
        throw std::runtime_error("diagnostics directory could not be created");
    }
    const QDateTime now = QDateTime::currentDateTimeUtc();
    const QString path = QDir(directory).filePath(
        QStringLiteral("marquee-diagnostics-%1.json")
            .arg(now.toString(QStringLiteral("yyyyMMdd-HHmmss"))));
    QJsonObject snapshot;
    snapshot.insert(QStringLiteral("app"), QStringLiteral("Marquee"));
    snapshot.insert(QStringLiteral("version"), version);
    snapshot.insert(QStringLiteral("exportedAt"), now.toString(Qt::ISODate));
    snapshot.insert(QStringLiteral("os"), QSysInfo::prettyProductName());
    snapshot.insert(QStringLiteral("kernel"), QSysInfo::kernelVersion());
    snapshot.insert(QStringLiteral("cpu"), QSysInfo::currentCpuArchitecture());
    snapshot.insert(QStringLiteral("libraryRoots"), QJsonArray::fromStringList(roots));
    snapshot.insert(QStringLiteral("catalog"), AppPaths::catalogFile());
    snapshot.insert(QStringLiteral("settings"), AppPaths::settingsFile());
    QFile file(path);
    if (!file.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
        throw std::runtime_error("diagnostics snapshot could not be written");
    }
    file.write(QJsonDocument(snapshot).toJson(QJsonDocument::Indented));
    return path;
}
}

SettingsSession::SettingsSession(ApplicationController &application, QObject *parent)
    : QObject(parent)
    , m_application(application)
{
    // `SettingsDetailView.swift:646-676` and `:951-959`: "Cleared" stays for
    // two seconds.
    m_cacheClearedTimer.setSingleShot(true);
    m_cacheClearedTimer.setInterval(2000);
    m_historyClearedTimer.setSingleShot(true);
    m_historyClearedTimer.setInterval(2000);
    connect(&m_cacheClearedTimer, &QTimer::timeout, this, [this] {
        m_cacheCleared = false;
        emit imageCacheChanged();
    });
    connect(&m_historyClearedTimer, &QTimer::timeout, this, [this] {
        m_historyCleared = false;
        emit historyClearedChanged();
    });

    connect(&m_application, &ApplicationController::scanningChanged,
            this, &SettingsSession::handleScanningChanged);
    connect(&m_application, &ApplicationController::watchHistoryCleared,
            this, &SettingsSession::handleWatchHistoryCleared);

    connect(&m_cacheSizeWatcher, &QFutureWatcher<qint64>::finished, this, [this] {
        // `:928-932`: a measurement the cache was cleared under is stale.
        if (m_cacheSizeWatcher.property("generation").toULongLong() != m_cacheSizeGeneration) {
            return;
        }
        setImageCacheState(formatFileSize(m_cacheSizeWatcher.result()), false);
    });
    connect(&m_cacheClearWatcher, &QFutureWatcher<void>::finished, this, [this] {
        // `:955-962`.
        m_cacheCleared = true;
        setImageCacheState(QStringLiteral("Zero KB"), false);
        m_cacheClearedTimer.start();
    });
    connect(&m_diagnosticsWatcher, &QFutureWatcher<QString>::finished, this, [this] {
        m_exportingDiagnostics = false;
        try {
            m_diagnosticsExportedPath = m_diagnosticsWatcher.result();
        } catch (const std::exception &error) {
            // `:996-1001`.
            m_diagnosticsExportFailed =
                QStringLiteral("Export failed: %1").arg(QString::fromUtf8(error.what()));
        }
        emit diagnosticsChanged();
    });
}

QString SettingsSession::scanStatusText() const
{
    return m_scanStatusText;
}

bool SettingsSession::hasQueuedScan() const
{
    return m_hasQueuedScan;
}

QString SettingsSession::imageCacheSize() const
{
    return m_imageCacheSize;
}

bool SettingsSession::measuringImageCache() const
{
    return m_measuringImageCache;
}

bool SettingsSession::cacheCleared() const
{
    return m_cacheCleared;
}

bool SettingsSession::historyCleared() const
{
    return m_historyCleared;
}

QString SettingsSession::diagnosticsExportedPath() const
{
    return m_diagnosticsExportedPath;
}

QString SettingsSession::diagnosticsExportFailed() const
{
    return m_diagnosticsExportFailed;
}

bool SettingsSession::exportingDiagnostics() const
{
    return m_exportingDiagnostics;
}

void SettingsSession::addLibraryRoot(const QString &pathOrUrl)
{
    const QUrl url(pathOrUrl);
    const QString path = url.isLocalFile() ? url.toLocalFile() : pathOrUrl;
    const QString trimmed = path.trimmed();
    if (trimmed.isEmpty()) {
        return;
    }
    QStringList roots = m_application.settings()->libraryRoots();
    if (roots.contains(trimmed)) {
        return;
    }
    roots.push_back(trimmed);
    m_application.settings()->setLibraryRoots(roots);
}

void SettingsSession::removeLibraryRoot(int index)
{
    QStringList roots = m_application.settings()->libraryRoots();
    if (index < 0 || index >= roots.size()) {
        return;
    }
    roots.removeAt(index);
    m_application.settings()->setLibraryRoots(roots);
}

void SettingsSession::addTvShowsRoot(const QString &pathOrUrl)
{
    const QUrl url(pathOrUrl);
    const QString path = url.isLocalFile() ? url.toLocalFile() : pathOrUrl;
    const QString trimmed = path.trimmed();
    if (trimmed.isEmpty()) {
        return;
    }
    QStringList roots = m_application.settings()->tvShowsRoots();
    if (roots.contains(trimmed)) {
        return;
    }
    roots.push_back(trimmed);
    m_application.settings()->setTvShowsRoots(roots);
}

void SettingsSession::removeTvShowsRoot(int index)
{
    QStringList roots = m_application.settings()->tvShowsRoots();
    if (index < 0 || index >= roots.size()) {
        return;
    }
    roots.removeAt(index);
    m_application.settings()->setTvShowsRoots(roots);
}

void SettingsSession::rescanLibrary()
{
    // `LibraryState.swift:330-360`: a request during a scan is queued behind
    // it, and the status line says so until the follow-up runs.
    const bool scanning = m_application.scanning();
    m_rescanRequested = true;
    m_application.requestCatalogRefresh();
    if (scanning) {
        m_hasQueuedScan = true;
        m_scanStatusText = QStringLiteral("Finishing current scan, then checking updates...");
    } else {
        m_hasQueuedScan = false;
        m_scanStatusText = m_application.settings()->onlineMetadataEnabled()
            ? QStringLiteral("Refreshing library and metadata...")
            : QStringLiteral("Updating library index...");
    }
    emit scanStateChanged();
}

void SettingsSession::handleScanningChanged()
{
    if (m_application.scanning()) {
        return;
    }
    // `LibraryState.swift:410-414`: idle clears the status line.
    m_rescanRequested = false;
    m_hasQueuedScan = false;
    m_scanStatusText.clear();
    emit scanStateChanged();
}

void SettingsSession::measureImageCache()
{
    if (m_measuringImageCache) {
        return;
    }
    ++m_cacheSizeGeneration;
    m_cacheSizeWatcher.setProperty("generation", m_cacheSizeGeneration);
    setImageCacheState(m_imageCacheSize, true);
    const QStringList directories = imageCacheDirectories();
    m_cacheSizeWatcher.setFuture(
        QtConcurrent::run([directories] { return totalRegularFileBytes(directories); }));
}

void SettingsSession::clearImageCache()
{
    // `:939-941`: clearing outranks a measurement still running.
    ++m_cacheSizeGeneration;
    m_measuringImageCache = false;
    emit imageCacheChanged();
    const QStringList directories = imageCacheDirectories();
    m_cacheClearWatcher.setFuture(
        QtConcurrent::run([directories] { removeCacheContents(directories); }));
}

void SettingsSession::clearWatchHistory()
{
    m_application.clearWatchHistory();
}

void SettingsSession::handleWatchHistoryCleared()
{
    m_historyCleared = true;
    emit historyClearedChanged();
    m_historyClearedTimer.start();
}

void SettingsSession::exportDiagnostics()
{
    if (m_exportingDiagnostics) {
        return;
    }
    m_diagnosticsExportedPath.clear();
    m_diagnosticsExportFailed.clear();
    m_exportingDiagnostics = true;
    emit diagnosticsChanged();
    const QString version = m_application.version();
    const QStringList roots = m_application.effectiveLibraryRoots();
    m_diagnosticsWatcher.setFuture(QtConcurrent::run(
        [version, roots] { return writeDiagnosticsSnapshot(version, roots); }));
}

void SettingsSession::setImageCacheState(const QString &size, bool measuring)
{
    m_imageCacheSize = size;
    m_measuringImageCache = measuring;
    emit imageCacheChanged();
}
