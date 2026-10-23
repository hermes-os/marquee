#pragma once

#include <QDate>
#include <QDateTime>
#include <QVector>

#include <optional>

#include "catalog/MediaItem.hpp"
#include "models/HomeLibraryRows.hpp"
#include "models/HomeRowIds.hpp"
#include "models/SeasonalRows.hpp"
#include "models/TasteModel.hpp"

/// The Home rows that depend on what the profile has watched and on the
/// calendar, as `BrowseSnapshotStore.swift:2855-2869` places them: Play
/// Something, the taste rows (Because You Watched, Hidden Gems, Short Tonight)
/// and the seasonal rows. Like the rest of `home_rows`, every function reads
/// the watch state the items carry, which is the active profile's alone, and
/// none of them filters by maturity: the caller hands in only what the profile
/// may see, so every row respects the Kids filter and a Kids profile's taste
/// is made of Kids titles.
///
/// Without online metadata the rows that need it (Hidden Gems, the rating and
/// cast terms of the rankings) are empty or fall back to what the title and
/// folder name imply, as the released app does.
namespace home_rows
{
/// `BrowseTasteRowsPolicy` (BrowseSnapshotStore.swift:2895-2904).
inline constexpr int kRankedRowLimit = 12;               // :2896
inline constexpr int kMinimumSmallRowCount = 2;          // :2897
inline constexpr double kHiddenGemMinimumVoteAverage = 7.5;   // :2898
inline constexpr int kHiddenGemMinimumVoteCount = 50;    // :2899
inline constexpr int kShortTonightLimitSeconds = 100 * 60;    // :2900
inline constexpr int kCompletedSeedLimit = 3;            // :2901
inline constexpr int kBecauseYouWatchedRowLimit = 12;    // :2902
inline constexpr int kBecauseYouWatchedMinimumCount = 4; // :2903

/// Which side of every length the cached rows read a title is on: 0 for an
/// unknown length (the catalog's zero), then one more for each of the Short
/// Tonight limit (a length over it is not short), `kHeroShortSeconds` and
/// `kHeroLongSeconds` that the length has reached. A length that stays in its
/// bucket cannot change a cached row, so Home rebuilds them when it leaves.
/// Add a threshold the rows start reading here.
[[nodiscard]] constexpr int lengthBucket(qint64 seconds)
{
    if (seconds <= 0) {
        return 0;
    }
    return 1 + (seconds > kShortTonightLimitSeconds ? 1 : 0)
        + (seconds >= kHeroShortSeconds ? 1 : 0)
        + (seconds >= kHeroLongSeconds ? 1 : 0);
}

/// :2945-2966 `becauseYouWatchedRows`: up to three rows, one per newest
/// finished movie, each of the twelve best unwatched matches of that movie by
/// `browse::SimilarityIndex`, shown when it holds four. The row id carries the
/// seed's media id.
[[nodiscard]] QVector<IdRow> becauseYouWatchedRows(const QVector<MediaItem> &movies,
                                                   const browse::TasteModel &taste,
                                                   LibraryRows *library = nullptr);

/// :2906-2943 `tasteRows`: Because You Watched, Hidden Gems, Short Tonight,
/// in that order. `movies` are the profile's visible movies. Empty when
/// `taste` is absent (nothing finished yet).
[[nodiscard]] QVector<IdRow> tasteRows(const QVector<MediaItem> &movies,
                                       const std::optional<browse::TasteModel> &taste,
                                       LibraryRows *library = nullptr);

/// :2968-2976: the file's length when known, else TMDB's runtime.
[[nodiscard]] std::optional<int> runtimeSeconds(const MediaItem &item);

/// Every row of this file for one set of items and one day, ready to be placed
/// by `compose`.
struct DerivedRows
{
    IdRow playSomething;
    // Because You Watched, Hidden Gems, Short Tonight.
    QVector<IdRow> taste;
    // October Horror or Summer Blockbusters.
    QVector<IdRow> seasonal;
};

/// `library`, when given, keeps the similarity index between calls; without
/// it the index is built for this call alone.
[[nodiscard]] DerivedRows deriveRows(const QVector<MediaItem> &items,
                                     const QDateTime &now,
                                     LibraryRows *library = nullptr);

/// Keeps `deriveRows` between recompositions. The rows depend on the items
/// (their metadata, which the projection replaces), on which titles are
/// watched, on a movie's recorded length, and on the day; a position recorded
/// during playback changes none of them. Ranking a library against a profile's
/// history is far too much work to repeat for every progress record, so the
/// owner calls `invalidate` when one of those inputs changes and `rows` builds
/// again only then (or when the day turns, which moves the seasonal rows).
class DerivedRowsCache
{
public:
    [[nodiscard]] const DerivedRows &rows(const QVector<MediaItem> &items,
                                          const QDateTime &now,
                                          LibraryRows *library = nullptr);
    void invalidate();
    /// How many times the rows were built, for tests.
    [[nodiscard]] int buildCount() const { return m_builds; }

private:
    std::optional<DerivedRows> m_rows;
    QDate m_day;
    int m_builds{0};
};
}
