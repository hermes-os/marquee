#pragma once

#include <QString>
#include <QStringList>
#include <QVector>

#include "catalog/CatalogDatabase.hpp"
#include "catalog/LibraryRoot.hpp"
#include "catalog/LibraryScanner.hpp"
#include "catalog/MediaItem.hpp"

/// Reads and writes the library rows of an already migrated catalog. It owns
/// the connection it queries, so one instance belongs to one thread. Every
/// operation throws `std::runtime_error` when the catalog rejects a statement.
class CatalogStore final
{
public:
    /// Opens the catalog at `catalogPath`. Startup migrates the file before the
    /// worker reaches it, so a store that finds an older schema fails loudly on
    /// its first statement instead of writing into a stale shape.
    explicit CatalogStore(const QString &catalogPath);

    CatalogStore(const CatalogStore &) = delete;
    CatalogStore &operator=(const CatalogStore &) = delete;
    CatalogStore(CatalogStore &&) = delete;
    CatalogStore &operator=(CatalogStore &&) = delete;

    /// Returns the stored root for each configured path, creating a row with a
    /// fresh identity for a path the catalog has not seen. A root that is no
    /// longer configured keeps its rows and is simply not returned.
    ///
    /// A configured path is the only identity evidence the catalog has, so a
    /// path it has not seen is always a new library. It is never treated as an
    /// existing root that moved: a stored root missing from disk is the ordinary
    /// unplugged case, so adopting its identity would hand one library's rows,
    /// and later its watch state, to an unrelated directory. Relinking a moved
    /// library needs a settings surface that can state the move outright.
    [[nodiscard]] QVector<LibraryRoot> registerRoots(const QStringList &paths);
    /// Registers both configured lists; each root carries the role of the
    /// list it came from, which the scanner uses to decide what its files are.
    [[nodiscard]] QVector<LibraryRoot> registerRoots(const LibraryRootPaths &paths);

    /// Writes one finished walk in a single transaction. Only a complete walk
    /// may remove rows, and even then it keeps the row of every id in
    /// `result.unreadableIds` (listed files that could not be stat'ed). An
    /// unavailable root records its availability only; a partially readable one
    /// stores what it read. In both cases the rows the root contributed stay
    /// and browsing keeps working.
    void applyScan(const LibraryRoot &root, const LibraryScanner::ScanResult &result);

    /// Every stored item belonging to `roots`, ordered by sort title and then
    /// identity so repeated projections agree. Each item carries the point
    /// playing it should start from and any recorded runtime, as `profileId`
    /// saw them; no other profile's progress is read. An empty `profileId`
    /// projects every title as unwatched.
    [[nodiscard]] QVector<MediaItem> projection(const QVector<LibraryRoot> &roots,
                                                const QString &profileId = {});

    /// Records where `profileId` left `mediaId`. A completed title records a
    /// zero position, because its resume point is the beginning; the row still
    /// says it was watched to the end. Throws when the catalog no longer holds
    /// that title, which is what a scan removing a file mid-playback looks
    /// like, and when `profileId` is empty: with no profile chosen there is no
    /// one to save the progress for.
    void recordWatchProgress(const QString &profileId,
                             const QString &mediaId,
                             qint64 positionMs,
                             qint64 durationMs,
                             bool completed);
    /// Forgets every resume point and completion of `profileId` only,
    /// `WatchProgressStore.swift:126-131`'s `clearAll` on that profile's store;
    /// the titles and every other profile's progress stay. Deleting a profile
    /// removes its progress with the same call.
    void clearWatchProgress(const QString &profileId);
    /// The roots the last `registerRoots` call named, so a projection can be
    /// rebuilt without scanning again.
    [[nodiscard]] QVector<LibraryRoot> knownRoots() const;

private:
    void applyAvailableScan(const LibraryRoot &root, const QVector<MediaItem> &items,
                            const QSet<QString> &unreadableIds, bool removeMissing);
    void markRootUnavailable(const LibraryRoot &root);

    CatalogDatabase m_database;
    QVector<LibraryRoot> m_knownRoots;
};
