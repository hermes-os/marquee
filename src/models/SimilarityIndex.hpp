#pragma once

#include <QHash>
#include <QSet>
#include <QString>
#include <QStringList>
#include <QVector>

#include <optional>

#include "catalog/MediaItem.hpp"
#include "models/BrowseSemantics.hpp"

namespace browse
{
/// `BrowseSimilarityIndex` (BrowseSnapshotStore.swift:2329-2624) and the
/// `BrowseRecommendationEngine.similarMovies` that reads it (:2140-2183,
/// :2244-2324), over the movies of one profile.
///
/// The released index scores genres (rarer ones weigh more), director, cast by
/// billing rank, overview words, the year gap, and a shared franchise, and it
/// keeps the twelve best per movie. It does not read TMDB's stored similar
/// and recommended ids (`movieEdges` is stored and never consulted by the
/// browse code), so v3 resolves none of them either.
///
/// The released index ranks every movie against every other once, in the
/// background. Home needs the ranking of at most a few seeds, and one movie's
/// ranking depends only on the shared genre weights, so this scores a movie
/// when it is asked for it. The answers are the same.
///
class SimilarityIndex
{
public:
    /// How many movies the released index keeps per source (:2351 `limit`).
    static constexpr int kIndexedPerMovie = 12;

    /// `holidayScores` are the movies' `holidayScore`s by id when the caller
    /// already holds them; a movie missing from it is scored when needed.
    explicit SimilarityIndex(const QVector<MediaItem> &movies,
                             QHash<QString, int> holidayScores = {});

    /// How many indexes were built in this process, for tests of what a
    /// progress record costs.
    [[nodiscard]] static int constructedForTest();

    /// :2369-2371, built as :2377-2410: the movies most like `sourceId`, best
    /// first, at most `limit`. Empty with fewer than two movies.
    [[nodiscard]] QVector<QString> rankedMovieIds(const QString &sourceId,
                                                  int limit = kIndexedPerMovie) const;

    /// :2140-2173: the indexed neighbours first, then the older rule's ranking
    /// of everything else (:2244-2324), at most `limit`. The source is never
    /// among them.
    [[nodiscard]] QVector<MediaItem> similarMovies(const MediaItem &source, int limit) const;
    /// The ids of `similarMovies`, for a caller that reads the movies' current
    /// state from elsewhere: the index keeps the copies it was built from, and
    /// it is kept across progress records that change a title's watch state.
    [[nodiscard]] QVector<QString> similarMovieIds(const MediaItem &source, int limit) const;

private:
    struct Profile
    {
        QString id;
        int position{0};
        int year{0};
        qint64 effectiveDate{0};
        QString franchise;
        QString director;
        // Sorted, so the genre sum has one order.
        QStringList genres;
        QHash<QString, int> castRank;
        QSet<QString> castNames;
        QSet<QString> overviewTokens;
        std::optional<double> voteAverage;
        int decade{-1};
        MovieBrowseSortKey browseKey;
    };

    [[nodiscard]] bool isHoliday(const MediaItem &item) const;
    [[nodiscard]] double indexScore(const Profile &source, const Profile &candidate) const;
    [[nodiscard]] int olderScore(const Profile &source,
                                 const Profile &candidate,
                                 bool sourceIsHoliday) const;
    [[nodiscard]] bool ranksBefore(double lhsScore,
                                   const Profile &lhs,
                                   double rhsScore,
                                   const Profile &rhs,
                                   const Profile &source) const;

    // An implicitly shared copy: the index outlives no one and costs nothing.
    QVector<MediaItem> m_movies;
    QVector<Profile> m_profiles;
    QHash<QString, int> m_positionById;
    QHash<QString, double> m_genreWeights;
    QHash<QString, int> m_holidayScores;
};
}
