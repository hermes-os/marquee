#pragma once

#include <QString>
#include <QStringList>
#include <QVector>

#include <optional>

/// Marquee/Models/TMDBMetadata.swift:24-26: one billed cast member. Entries
/// without a TMDB person id are dropped before storage, as
/// TMDBEnrichmentService.makeCast does.
struct CastMember
{
    QString name;
    QString character;
    QString profilePath;
    int personId{0};

    bool operator==(const CastMember &) const = default;
};

/// TMDBMetadata.swift:38-41.
struct MetadataKeyword
{
    int id{0};
    QString name;

    bool operator==(const MetadataKeyword &) const = default;
};

/// What TMDB says about one title, in the shape the released browse code reads
/// as `item.metadata?.…` (TMDBMetadata.swift:5-22). An absent optional is the
/// released `nil`; an empty string or list is "nothing there". Episodes carry
/// their show's metadata, as CatalogProjection.makeShowMetadata does.
///
/// A show leaves `voteCount`, `popularity`, the collection and the keywords
/// empty: TMDBService.parseTVJSON never reads them, and the released rows that
/// score on them treat a show as having none.
struct TitleMetadata
{
    int tmdbId{0};
    QString overview;
    QStringList genres;
    QVector<CastMember> cast;
    /// The movie's director, or a show's first creator
    /// (TMDBService.swift:432-435).
    QString director;
    QString certification;
    std::optional<double> voteAverage;
    std::optional<int> voteCount;
    std::optional<double> popularity;
    std::optional<int> collectionId;
    QString collectionName;
    QVector<MetadataKeyword> keywords;
    /// TMDB ids of the movies TMDB lists as similar to, or recommended after,
    /// this one, in TMDB's order (TMDBService.swift:358-376). The released app
    /// resolves them to library titles when it projects; nothing in the
    /// browse code reads the result yet, so the ids are kept as TMDB gave them.
    QVector<int> similarTmdbIds;
    QVector<int> recommendedTmdbIds;
    /// TMDB's own image paths (`/abc.jpg`), kept so an image that failed to
    /// download can be fetched again without asking TMDB about the title.
    QString posterRemotePath;
    QString backdropRemotePath;
    QString releaseDate;
    /// Minutes; zero when TMDB gave none.
    int runtimeMinutes{0};
};

/// What TMDB says about one episode of a show (TMDBService.EpisodeInfo,
/// TMDBService.swift:473-481). The released browse code reads the episode
/// title (when the file name gave none) and the still; the rest is kept as
/// TMDB gave it.
struct EpisodeMetadata
{
    int tmdbEpisodeId{0};
    QString title;
    QString overview;
    QString airDate;
    std::optional<double> voteAverage;
    /// TMDB's still path, kept so a failed download can be retried without
    /// asking TMDB about the episode again.
    QString stillRemotePath;
};

/// One episode that may need TMDB data.
struct EpisodeTarget
{
    QString mediaId;
    int seasonNumber{0};
    int episodeNumber{0};
    /// False when only the still is missing and the stored fields are fine.
    bool needsDetails{true};
    bool wantStill{false};
    QString stillRemotePath;
};

/// One title the catalog wants TMDB data for, and what is already known
/// about it. A movie is its media item; a show is its name and year, because
/// the catalog stores episodes, not shows.
struct MetadataTarget
{
    enum class Kind { Movie, Show };

    Kind kind{Kind::Movie};
    /// A movie's media id, or the show key of `showOwnerKey`.
    QString ownerKey;
    /// The movie's parsed title, or the show's folder name.
    QString title;
    int year{0};
    /// Set when TMDB already matched this title, so a refresh skips the search.
    std::optional<int> tmdbId;
    /// False when only artwork is missing and the stored fields are fine.
    bool needsDetails{true};
    /// Whether the title has no local sidecar of that kind and no cached TMDB
    /// image yet, so TMDB's image may fill the gap.
    bool wantPoster{false};
    bool wantBackdrop{false};
    /// What TMDB named earlier, for an artwork-only retry.
    QString posterRemotePath;
    QString backdropRemotePath;
    /// A show's episodes, in catalog order.
    QVector<EpisodeTarget> episodes;
};

/// The key a show's metadata is stored under. The scanner derives the name
/// from the show folder, so the same folder always yields the same key.
[[nodiscard]] inline QString showOwnerKey(const QString &showName, int year)
{
    return QStringLiteral("show:%1|%2").arg(showName).arg(year);
}

/// How a stored row records the last attempt for a title.
namespace metadata_state
{
inline const QString matched = QStringLiteral("matched");
/// TMDB answered and nothing in the answer matched the title.
inline const QString unmatched = QStringLiteral("unmatched");
/// TMDB matched the title but the details could not be read.
inline const QString failed = QStringLiteral("failed");
}
