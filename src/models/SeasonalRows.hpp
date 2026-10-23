#pragma once

#include <QDateTime>
#include <QVector>

#include "catalog/MediaItem.hpp"
#include "models/HomeRowIds.hpp"

namespace home_rows
{
/// The lengths `heroScore` reads (:2108-2113): +30 from the first, -180 under
/// the second. `lengthBucket` (HomeTasteRows.hpp) is built from these, so a
/// threshold the score gains is one place to add.
inline constexpr qint64 kHeroLongSeconds = 4'500;
inline constexpr qint64 kHeroShortSeconds = 1'200;

/// `BrowseLeanBackDelightPolicy.seasonalRows` (BrowseSnapshotStore.swift:
/// 466-498): October Horror in October, and Summer Blockbusters from June to
/// August, each with at least two movies, over `movies`. The month and the day
/// come from `now` in the viewer's local time, as the released
/// `Calendar(identifier: .gregorian)` reads them; the caller supplies the
/// clock, so a test pins the date. The order is stable within a day and
/// changes the next (`dateKey` :690-694 seeds the shuffle, :696-714).
[[nodiscard]] QVector<IdRow> seasonalRows(const QVector<MediaItem> &movies, const QDateTime &now);

/// :609-615: a horror genre, or `halloween`, `haunted` or `ghost` anywhere in
/// the title, the overview or the genres.
[[nodiscard]] bool isOctoberHorror(const MediaItem &item);

/// :617-627: an action, adventure, science fiction or fantasy movie that is
/// well voted, popular or well rated.
[[nodiscard]] bool isSummerBlockbuster(const MediaItem &item);

/// :2103-2121 `heroScore`: the score the seasonal order starts from. The Home
/// hero is out of this file's scope; only the terms the seasonal order reads
/// are here. `newestMs` is the newest file date of the candidates, or -1.
[[nodiscard]] double heroScore(const MediaItem &item, qint64 newestMs);
}
