#pragma once

#include <QFutureWatcher>
#include <QObject>
#include <QString>
#include <QStringList>
#include <QTimer>
#include <QtQml/qqmlregistration.h>

class ApplicationController;
class SettingsStore;

/// The Settings route's own state, `Marquee/Features/Settings/Views/
/// SettingsDetailView.swift:11-20` and `:896-1008`: the scan status line,
/// the image cache measurement and its clearing, the watch-history and cache
/// "Cleared" acknowledgements, and the diagnostics export. Folder edits go
/// through here so the settings store keeps its invariant that every root is
/// a trimmed, unique path.
class SettingsSession final : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_UNCREATABLE("SettingsSession is owned by ApplicationController")

    /// `LibraryState.swift:344-358` and `:404-414`.
    Q_PROPERTY(QString scanStatusText READ scanStatusText NOTIFY scanStateChanged)
    Q_PROPERTY(bool hasQueuedScan READ hasQueuedScan NOTIFY scanStateChanged)
    /// `SettingsDetailView.swift:13-14` and `:896-937`.
    Q_PROPERTY(QString imageCacheSize READ imageCacheSize NOTIFY imageCacheChanged)
    Q_PROPERTY(bool measuringImageCache READ measuringImageCache NOTIFY imageCacheChanged)
    Q_PROPERTY(bool cacheCleared READ cacheCleared NOTIFY imageCacheChanged)
    /// `:17` and `:664-676`.
    Q_PROPERTY(bool historyCleared READ historyCleared NOTIFY historyClearedChanged)
    /// `:18-20` and `:983-1005`.
    Q_PROPERTY(QString diagnosticsExportedPath READ diagnosticsExportedPath NOTIFY diagnosticsChanged)
    Q_PROPERTY(QString diagnosticsExportFailed READ diagnosticsExportFailed NOTIFY diagnosticsChanged)
    Q_PROPERTY(bool exportingDiagnostics READ exportingDiagnostics NOTIFY diagnosticsChanged)

public:
    explicit SettingsSession(ApplicationController &application, QObject *parent = nullptr);

    [[nodiscard]] QString scanStatusText() const;
    [[nodiscard]] bool hasQueuedScan() const;
    [[nodiscard]] QString imageCacheSize() const;
    [[nodiscard]] bool measuringImageCache() const;
    [[nodiscard]] bool cacheCleared() const;
    [[nodiscard]] bool historyCleared() const;
    [[nodiscard]] QString diagnosticsExportedPath() const;
    [[nodiscard]] QString diagnosticsExportFailed() const;
    [[nodiscard]] bool exportingDiagnostics() const;

    /// `SettingsDetailView.swift:286-297`: appends a chosen folder unless it
    /// is already listed. Accepts the `file://` form the folder dialog
    /// returns as well as a plain path.
    Q_INVOKABLE void addLibraryRoot(const QString &pathOrUrl);
    /// `:265-267`.
    Q_INVOKABLE void removeLibraryRoot(int index);
    /// SettingsDetailView.swift:194-197: the TV Shows folder list, kept apart
    /// from the movies list because the scanner walks the two differently.
    Q_INVOKABLE void addTvShowsRoot(const QString &pathOrUrl);
    Q_INVOKABLE void removeTvShowsRoot(int index);
    /// `:322` and `LibraryState.swift:330-360`: asks for a scan, or queues one
    /// while a scan is running.
    Q_INVOKABLE void rescanLibrary();
    /// `:901-937`: totals the artwork and thumbnail caches off the UI thread.
    Q_INVOKABLE void measureImageCache();
    /// `:939-963`: empties them and says "Cleared" for two seconds.
    Q_INVOKABLE void clearImageCache();
    /// `:667-676` with `LibraryState.swift:933-939`.
    Q_INVOKABLE void clearWatchHistory();
    /// `:983-1005`: writes a snapshot of app details next to the catalog.
    Q_INVOKABLE void exportDiagnostics();

signals:
    void scanStateChanged();
    void imageCacheChanged();
    void historyClearedChanged();
    void diagnosticsChanged();

private:
    void handleScanningChanged();
    void handleWatchHistoryCleared();
    void setImageCacheState(const QString &size, bool measuring);

    ApplicationController &m_application;
    QString m_scanStatusText;
    bool m_hasQueuedScan{false};
    bool m_rescanRequested{false};
    QString m_imageCacheSize{QStringLiteral("Not measured")};
    bool m_measuringImageCache{false};
    bool m_cacheCleared{false};
    bool m_historyCleared{false};
    QString m_diagnosticsExportedPath;
    QString m_diagnosticsExportFailed;
    bool m_exportingDiagnostics{false};
    quint64 m_cacheSizeGeneration{0};
    QFutureWatcher<qint64> m_cacheSizeWatcher;
    QFutureWatcher<void> m_cacheClearWatcher;
    QFutureWatcher<QString> m_diagnosticsWatcher;
    QTimer m_cacheClearedTimer;
    QTimer m_historyClearedTimer;
};
