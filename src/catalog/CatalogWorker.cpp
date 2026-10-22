#include "catalog/CatalogWorker.hpp"

#include <QThread>

#include <stdexcept>
#include <utility>

#include "catalog/CatalogStore.hpp"
#include "catalog/LibraryRoot.hpp"
#include "catalog/LibraryScanner.hpp"
#include "metadata/MetadataSwitch.hpp"
#include "support/Logging.hpp"

CatalogWorker::CatalogWorker(QString catalogPath, MetadataSetup metadata)
    : m_catalogPath(std::move(catalogPath))
    , m_metadataSetup(std::move(metadata))
{
    // The switch is flipped on the GUI thread; the slot runs on this worker's.
    connect(&metadata_switch::notifier(), &metadata_switch::Notifier::enabledChanged, this,
            &CatalogWorker::metadataSwitchChanged);
}

CatalogWorker::~CatalogWorker() = default;

CatalogStore &CatalogWorker::store()
{
    if (!m_store) {
        m_store = std::make_unique<CatalogStore>(m_catalogPath);
        m_store->setMetadataCache(m_metadataSetup.cache);
    }
    return *m_store;
}

void CatalogWorker::refresh(const LibraryRootPaths &rootPaths, const QString &profileId)
{
    emit refreshStarted();
    m_activeProfileId = profileId;

    try {
        store();

        const QVector<LibraryRoot> roots = m_store->registerRoots(rootPaths);
        QStringList unavailable;
        QStringList unavailableIds;
        for (const LibraryRoot &root : roots) {
            const LibraryScanner::ScanResult result = LibraryScanner::scan(root);
            if (result.outcome == LibraryScanner::ScanOutcome::RootUnavailable) {
                unavailable.push_back(root.path);
                unavailableIds.push_back(root.id);
            }
            m_store->applyScan(root, result);
        }

        // The projection goes first so the library is on screen before anything
        // explains why part of it may be stale.
        emit projectionReady(m_store->projection(roots, profileId), profileId);
        emit rootsUnavailable(unavailable, unavailableIds);
        // After the library is on screen: TMDB never holds up browsing.
        startMetadataRun(rootPaths);
    } catch (const std::exception &error) {
        // Drop the connection so a failed write cannot leave the next refresh
        // reusing a catalog handle whose state is unknown.
        m_store.reset();
        const QString message = QString::fromStdString(error.what());
        qCWarning(logScanner) << "library refresh failed:" << message;
        emit scanFailed(message);
    }
}

void CatalogWorker::reloadProjection(const QString &profileId)
{
    m_activeProfileId = profileId;
    try {
        store();
        const QVector<LibraryRoot> roots = m_store->knownRoots();
        // Without registered roots the projection would be empty because no
        // scan has run, not because the library is, and the surface would
        // take it for the answer.
        if (roots.isEmpty()) {
            emit projectionReloadSkipped(profileId);
            return;
        }
        emit projectionReloaded(m_store->projection(roots, profileId), profileId);
    } catch (const std::exception &error) {
        m_store.reset();
        const QString message = QString::fromStdString(error.what());
        qCWarning(logCatalog) << "projection not reloaded:" << message;
        emit projectionReloadFailed(message, profileId);
    }
}

void CatalogWorker::recordProgress(const QString &profileId,
                                   const QString &mediaId,
                                   qint64 positionMs,
                                   qint64 durationMs,
                                   bool completed,
                                   quint64 sequence)
{
    try {
        store();
        m_store->recordWatchProgress(profileId, mediaId, positionMs, durationMs, completed);
        emit watchProgressRecorded(profileId, mediaId, positionMs, durationMs, sequence);
    } catch (const std::exception &error) {
        // A scan that removed the title mid-playback is the ordinary reason
        // this fails, and a lost resume point is not worth interrupting a film
        // the viewer is still watching.
        qCWarning(logCatalog) << "watch progress not recorded for" << mediaId << ":"
                              << error.what();
    }
}

void CatalogWorker::clearWatchHistory(const QString &profileId)
{
    m_activeProfileId = profileId;
    try {
        store();
        m_store->clearWatchProgress(profileId);
        emit projectionReloaded(m_store->projection(m_store->knownRoots(), profileId),
                                profileId);
        emit watchHistoryCleared();
    } catch (const std::exception &error) {
        m_store.reset();
        const QString message = QString::fromStdString(error.what());
        qCWarning(logCatalog) << "watch history not cleared:" << message;
        emit scanFailed(message);
    }
}

void CatalogWorker::deleteProfileProgress(const QString &profileId)
{
    try {
        store();
        m_store->clearWatchProgress(profileId);
    } catch (const std::exception &error) {
        m_store.reset();
        qCWarning(logCatalog) << "progress of a deleted profile not removed:"
                              << error.what();
    }
}

void CatalogWorker::startMetadataRun(const LibraryRootPaths &rootPaths)
{
    m_lastRootPaths = rootPaths;
    if (!m_enrichment) {
        m_enrichment = std::make_unique<MetadataEnrichment>(m_catalogPath, m_metadataSetup);
        // The screens are reloaded once, when a run ends: a reload resets every
        // list the viewer may be scrolling, and a long first run would do that
        // every few seconds. Everything it wrote is already durable, so a
        // quit mid-run loses nothing.
        connect(m_enrichment.get(), &MetadataEnrichment::finished, this,
                [this](MetadataEnrichment::Summary summary) {
                    // A run that wrote nothing leaves the projection as it was.
                    if (summary.titlesSaved + summary.titlesUnmatched + summary.titlesFailed
                            + summary.episodesSaved + summary.imagesCached > 0) {
                        reloadAfterMetadata();
                    }
                    emit metadataRunFinished(summary);
                });
    }
    m_enrichment->start(rootPaths.movies + rootPaths.tvShows);
}

void CatalogWorker::reloadAfterMetadata()
{
    if (m_lastRootPaths == LibraryRootPaths{}) {
        return;
    }
    try {
        CatalogStore &catalog = store();
        const QVector<LibraryRoot> roots = catalog.knownRoots();
        if (roots.isEmpty()) {
            return;
        }
        emit projectionReloaded(catalog.projection(roots, m_activeProfileId), m_activeProfileId);
    } catch (const std::exception &error) {
        m_store.reset();
        qCWarning(logCatalog) << "projection not reloaded after metadata:" << error.what();
    }
}

void CatalogWorker::metadataSwitchChanged(bool enabled)
{
    if (!enabled) {
        // The run itself reads the switch before every request; this is only
        // the tidy half, for a run waiting on its pacing timer.
        if (m_enrichment) {
            m_enrichment->stop();
        }
        return;
    }
    // Nothing was ever scanned, so there is nothing to enrich yet.
    if (m_lastRootPaths == LibraryRootPaths{}) {
        return;
    }
    startMetadataRun(m_lastRootPaths);
}

void CatalogWorker::shutdown()
{
    // The run's network object must die on the thread that made it.
    if (m_enrichment) {
        m_enrichment->stop();
    }
    m_enrichment.reset();
    QThread::currentThread()->quit();
}
