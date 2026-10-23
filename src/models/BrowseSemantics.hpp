#pragma once

#include <QHash>
#include <QString>
#include <QStringList>
#include <QVector>

#include "catalog/MediaItem.hpp"

namespace browse
{
/// BrowseSnapshotStore.swift:1784-1802: folds diacritics and width,
/// lowercases, and reduces every run of non-alphanumerics to one space.
[[nodiscard]] QString normalizedText(const QString &value);

/// BrowseSnapshotStore.swift:1824-1862: the compact franchise rules first,
/// then a leading token long enough to stand on its own, then the first two
/// meaningful tokens. An empty key means the title has no family of its own.
[[nodiscard]] QString franchiseKey(const QString &title);

/// BrowseSnapshotStore.swift:2016-2020 `MovieBrowseSortKey`: a title's family,
/// its year (0 where the released key is nil) and its title.
struct MovieBrowseSortKey
{
    QString family;
    int year{0};
    QString title;
};

/// BrowseSnapshotStore.swift:2026-2032: the franchise key, or the normalized
/// title when the title has no family of its own.
[[nodiscard]] MovieBrowseSortKey movieBrowseSortKey(const MediaItem &item);
/// The same key for a caller that already holds `franchiseKey(item.title)`.
[[nodiscard]] MovieBrowseSortKey movieBrowseSortKey(const MediaItem &item, const QString &franchise);

/// BrowseSnapshotStore.swift:2034-2042: family by locale-aware case-insensitive
/// collation, then year with an unknown year last, then title. Two keys that
/// differ only in how they collate are equivalent, as in the released sort.
[[nodiscard]] bool compareMovieBrowseSortKeys(const MovieBrowseSortKey &lhs,
                                              const MovieBrowseSortKey &rhs);

/// BrowseSnapshotStore.swift:2044-2046.
[[nodiscard]] bool compareMoviesForBrowsing(const MediaItem &lhs, const MediaItem &rhs);

/// BrowseSnapshotStore.swift:2048-2053: `items` in browse order, each key
/// composed once. Titles that compare equal keep their incoming order.
[[nodiscard]] QVector<MediaItem> sortedMoviesForBrowsing(QVector<MediaItem> items);

/// BrowseSnapshotStore.swift:660-665: release date (TMDB's, else the year),
/// then browse order.
[[nodiscard]] bool compareFranchiseOrder(const MediaItem &lhs, const MediaItem &rhs);

/// BrowseSnapshotStore.swift:2073-2101: 100 for a holiday word in the title,
/// the overview or the genres (the genres being `displayGenres`, so TMDB's
/// when it named any), 86 for a named holiday film by its title alone, else 0.
/// The one score every caller reads: the Movies rows, and the Home hero.
[[nodiscard]] int holidayScore(const MediaItem &item);

/// How many times `holidayScore` ran in this process, for tests of what a
/// progress record costs.
[[nodiscard]] int holidayScoreCallsForTest();

/// BrowseSnapshotStore.swift:2055-2057.
[[nodiscard]] bool isHolidayMovie(const MediaItem &item);

/// BrowseSnapshotStore.swift:2059-2071: the strongest signal first, browse
/// order within one score. `scores` holds scores already computed by media
/// id (:2063 `scores:`); a title missing from it is scored here.
[[nodiscard]] QVector<MediaItem> sortedHolidayMovies(QVector<MediaItem> items,
                                                     const QHash<QString, int> &scores = {});
}
