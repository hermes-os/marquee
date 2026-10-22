#pragma once

#include <QObject>
#include <QString>
#include <QStringList>
#include <QVector>

#include <memory>

#include "catalog/LibraryRoot.hpp"
#include "catalog/MediaItem.hpp"
#include "metadata/MetadataEnrichment.hpp"

class CatalogStore;

/// Runs library scans and catalog writes away from the GUI thread. It is
/// created without a parent and moved to its own thread, so the catalog
/// connection it opens is owned by the thread that queries it.
class CatalogWorker final : public QObject
{
    Q_OBJECT

public:
    /// `metadata` says how TMDB is reached and where its artwork is cached; the
    /// default is the application's own, and tests replace it.
    explicit CatalogWorker(QString catalogPath,
                           MetadataSetup metadata = defaultMetadataSetup());
    ~CatalogWorker() override;

public slots:
    /// Scans both configured lists and publishes the projection they add up
    /// to, carrying the progress `profileId` has recorded. Roots the catalog
    /// already knows keep their identity and their stored rows.
    void refresh(const LibraryRootPaths &rootPaths, const QString &profileId);

    /// Publishes the projection of the roots the last refresh registered, with
    /// the progress of `profileId`, without scanning: what choosing another
    /// profile needs. Before a refresh has registered any root it publishes nothing.
    void reloadProjection(const QString &profileId);

    /// Stores where `profileId` left `mediaId` so that profile's next viewing
    /// can start there. `sequence` is the recorder's own ordering and is
    /// echoed back unchanged.
    void recordProgress(const QString &profileId,
                        const QString &mediaId,
                        qint64 positionMs,
                        qint64 durationMs,
                        bool completed,
                        quint64 sequence);

    /// `LibraryState.swift:933-939`: forgets `profileId`'s watch progress and
    /// publishes its projection again so every surface drops its resume
    /// points. Other profiles keep theirs.
    void clearWatchHistory(const QString &profileId);

    /// Removes every progress row of a profile that no longer exists.
    void deleteProfileProgress(const QString &profileId);
    /// Stops the event loop after work queued before this call has run.
    void shutdown();

    /// The Settings switch changed. Turning it on fills in what is missing
    /// for the roots of the last refresh; turning it off stops a run after its
    /// request in flight.
    void metadataSwitchChanged(bool enabled);

signals:
    void refreshStarted();
    /// The end of a `refresh`, with the profile whose progress it carries.
    void projectionReady(QVector<MediaItem> items, QString profileId);
    /// A projection that answers no refresh: a profile change or a cleared
    /// history. Kept apart so it never counts as a scan finishing.
    void projectionReloaded(QVector<MediaItem> items, QString profileId);
    void watchProgressRecorded(QString profileId,
                               QString mediaId,
                               qint64 positionMs,
                               qint64 durationMs,
                               quint64 sequence);
    void scanFailed(QString message);
    /// A `reloadProjection` that threw. Apart from `scanFailed` so a failure
    /// of a scan already running is never taken for the reload's.
    void projectionReloadFailed(QString message, QString profileId);
    void watchHistoryCleared();
    /// A background TMDB run ended; carries what it did.
    void metadataRunFinished(MetadataEnrichment::Summary summary);

    /// The configured roots that could not be reached by this refresh. Their
    /// rows are still projected, so this reports why the library may look stale
    /// rather than why it is empty. `rootIds` names the same roots by catalog
    /// identity. It is emitted after every refresh that finishes, empty
    /// included, so a root that came back leaves the set the receiver keeps.
    void rootsUnavailable(QStringList paths, QStringList rootIds);

private:
    void startMetadataRun(const LibraryRootPaths &rootPaths);
    void reloadAfterMetadata();
    CatalogStore &store();

    QString m_catalogPath;
    MetadataSetup m_metadataSetup;
    std::unique_ptr<CatalogStore> m_store;
    // Created on the worker's thread by the first run, so the network object
    // inside it belongs to the thread that uses it.
    std::unique_ptr<MetadataEnrichment> m_enrichment;
    LibraryRootPaths m_lastRootPaths;
    QString m_activeProfileId;
};
