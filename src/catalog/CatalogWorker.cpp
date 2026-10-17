#include "catalog/CatalogWorker.hpp"

#include <QThread>

#include <stdexcept>
#include <utility>

#include "catalog/CatalogStore.hpp"
#include "catalog/LibraryRoot.hpp"
#include "catalog/LibraryScanner.hpp"
#include "support/Logging.hpp"

CatalogWorker::CatalogWorker(QString catalogPath)
    : m_catalogPath(std::move(catalogPath))
{
}

CatalogWorker::~CatalogWorker() = default;

void CatalogWorker::refresh(const LibraryRootPaths &rootPaths, const QString &profileId)
{
    emit refreshStarted();

    try {
        if (!m_store) {
            m_store = std::make_unique<CatalogStore>(m_catalogPath);
        }

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
    try {
        if (!m_store) {
            m_store = std::make_unique<CatalogStore>(m_catalogPath);
        }
        const QVector<LibraryRoot> roots = m_store->knownRoots();
        // Without registered roots the projection would be empty because no
        // scan has run, not because the library is, and the surface would
        // take it for the answer.
        if (roots.isEmpty()) {
            return;
        }
        emit projectionReloaded(m_store->projection(roots, profileId), profileId);
    } catch (const std::exception &error) {
        m_store.reset();
        const QString message = QString::fromStdString(error.what());
        qCWarning(logCatalog) << "projection not reloaded:" << message;
        emit scanFailed(message);
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
        if (!m_store) {
            m_store = std::make_unique<CatalogStore>(m_catalogPath);
        }
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
    try {
        if (!m_store) {
            m_store = std::make_unique<CatalogStore>(m_catalogPath);
        }
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
        if (!m_store) {
            m_store = std::make_unique<CatalogStore>(m_catalogPath);
        }
        m_store->clearWatchProgress(profileId);
    } catch (const std::exception &error) {
        m_store.reset();
        qCWarning(logCatalog) << "progress of a deleted profile not removed:"
                              << error.what();
    }
}

void CatalogWorker::shutdown()
{
    QThread::currentThread()->quit();
}
