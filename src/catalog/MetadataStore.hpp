#pragma once

#include <QDateTime>
#include <QSqlDatabase>
#include <QString>
#include <QStringList>
#include <QVector>

#include <optional>

#include "catalog/CatalogDatabase.hpp"
#include "catalog/MediaItem.hpp"
#include "catalog/TitleMetadata.hpp"

/// Reads and writes the TMDB columns of an already migrated catalog
/// (migration 6): what to ask TMDB about, what it answered, and where its
/// artwork was cached. It owns the connection it queries, so one instance
/// belongs to one thread; the catalog worker's scans use their own. Every
/// operation throws `std::runtime_error` when the catalog rejects a statement.
///
/// The fetch rules are the released ones (`TMDBEnrichmentService.ownerNeedsEnrichment`):
/// a title with no row is fetched; a fetched title is left alone; a title whose
/// artwork was named but never cached is asked for that artwork alone. One
/// rule is new: the released app searched again for a title TMDB could not
/// match on every scan, and here a title that found no match waits a week and
/// one whose details could not be read waits a day before it is tried again.
class MetadataStore final
{
public:
    explicit MetadataStore(const QString &catalogPath);

    MetadataStore(const MetadataStore &) = delete;
    MetadataStore &operator=(const MetadataStore &) = delete;

    /// The directories TMDB images are cached in: `fullDirectory` holds the
    /// downloaded image, `thumbnailDirectory` its thumbnail, whose name is what
    /// the rows record.
    struct CacheDirectories
    {
        QString fullDirectory;
        QString thumbnailDirectory;
    };

    /// The titles of the library in `rootPaths` that need something from TMDB
    /// at `now`, movies first and then shows in name order. A title the
    /// catalog holds under a root that is not listed is left out.
    [[nodiscard]] QVector<MetadataTarget> pendingTargets(const QStringList &rootPaths,
                                                         const QDateTime &now,
                                                         const CacheDirectories &cache);

    void saveTitle(const MetadataTarget &target, const TitleMetadata &metadata,
                   const QDateTime &now);
    /// Records that TMDB found no match (`unmatched`) or that the details of a
    /// match could not be read (`failed`). A title already matched is kept.
    void saveAttempt(const MetadataTarget &target, const QString &state, const QDateTime &now,
                     std::optional<int> tmdbId = std::nullopt);
    /// `poster` or `backdrop`; `thumbnailName` is the cached file's name, empty
    /// when TMDB has no such image any more.
    void saveArtwork(const QString &ownerKey, bool poster, const QString &thumbnailName,
                     bool forgetRemote = false);

    void saveEpisode(const QString &mediaId, const std::optional<EpisodeMetadata> &metadata,
                     const QDateTime &now);
    void saveEpisodeStill(const QString &mediaId, const QString &thumbnailName,
                          bool forgetRemote = false);

    /// Attaches stored TMDB metadata and the cached artwork that exists to
    /// `items`. A title with none keeps what it had; nothing is created for it.
    static void attach(QSqlDatabase &database, QVector<MediaItem> &items,
                       const CacheDirectories &cache);

    static constexpr int unmatchedRetryDays = 7;
    static constexpr int failedRetryDays = 1;

private:
    CatalogDatabase m_database;
};
