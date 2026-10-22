#include "models/HomeTasteRows.hpp"

#include "models/PlaySomething.hpp"
#include "models/SeasonalRows.hpp"
#include "models/SimilarityIndex.hpp"

#include <utility>

namespace
{
[[nodiscard]] QVector<MediaItem> moviesOf(const QVector<MediaItem> &items)
{
    QVector<MediaItem> movies;
    for (const MediaItem &item : items) {
        if (item.isMovie()) {
            movies.push_back(item);
        }
    }
    return movies;
}

[[nodiscard]] QStringList idsOf(const QVector<MediaItem> &items)
{
    QStringList ids;
    ids.reserve(items.size());
    for (const MediaItem &item : items) {
        ids.push_back(item.id);
    }
    return ids;
}
}

std::optional<int> home_rows::runtimeSeconds(const MediaItem &item)
{
    if (item.durationSeconds > 0) {
        return static_cast<int>(item.durationSeconds);
    }
    if (item.metadata && item.metadata->runtimeMinutes > 0) {
        return item.metadata->runtimeMinutes * 60;
    }
    return std::nullopt;
}

QVector<home_rows::IdRow> home_rows::becauseYouWatchedRows(const QVector<MediaItem> &movies,
                                                           const browse::TasteModel &taste)
{
    QVector<IdRow> rows;
    const QVector<MediaItem> seeds = taste.completedSeeds(movies, kCompletedSeedLimit);
    if (seeds.isEmpty()) {
        return rows;
    }
    const browse::SimilarityIndex index(movies);
    for (const MediaItem &seed : seeds) {
        // :2951-2958: everything the released ranking names, then the unwatched
        // twelve of it.
        QStringList ids;
        for (const MediaItem &candidate : index.similarMovies(seed, static_cast<int>(movies.size()))) {
            if (!taste.isUnwatched(candidate)) {
                continue;
            }
            ids.push_back(candidate.id);
            if (ids.size() == kBecauseYouWatchedRowLimit) {
                break;
            }
        }
        if (ids.size() < kBecauseYouWatchedMinimumCount) {
            continue;
        }
        rows.push_back(IdRow{.id = QStringLiteral("because-you-watched-") + seed.id,
                             .title = QStringLiteral("Because You Watched ") + seed.title,
                             .mediaIds = std::move(ids)});
    }
    return rows;
}

QVector<home_rows::IdRow> home_rows::tasteRows(const QVector<MediaItem> &movies,
                                               const std::optional<browse::TasteModel> &taste)
{
    QVector<IdRow> rows;
    if (!taste) {
        return rows;
    }

    for (IdRow &row : becauseYouWatchedRows(movies, *taste)) {
        rows.push_back(std::move(row));
    }

    // :2920-2929.
    QVector<MediaItem> hiddenGems;
    for (const MediaItem &item : movies) {
        if (!taste->isUnwatched(item) || !item.metadata) {
            continue;
        }
        if (item.metadata->voteAverage.value_or(0.0) < kHiddenGemMinimumVoteAverage
            || item.metadata->voteCount.value_or(0) < kHiddenGemMinimumVoteCount) {
            continue;
        }
        hiddenGems.push_back(item);
    }
    const QVector<MediaItem> rankedHiddenGems = taste->rankedCandidates(hiddenGems, kRankedRowLimit);
    if (rankedHiddenGems.size() >= kMinimumSmallRowCount) {
        rows.push_back(IdRow{.id = QStringLiteral("hidden-gems"),
                             .title = QStringLiteral("Hidden Gems"),
                             .mediaIds = idsOf(rankedHiddenGems)});
    }

    // :2931-2940.
    QVector<MediaItem> shortTonight;
    for (const MediaItem &item : movies) {
        if (!taste->isUnwatched(item)) {
            continue;
        }
        const std::optional<int> runtime = runtimeSeconds(item);
        if (runtime && *runtime <= kShortTonightLimitSeconds) {
            shortTonight.push_back(item);
        }
    }
    const QVector<MediaItem> rankedShortTonight = taste->rankedCandidates(shortTonight, kRankedRowLimit);
    if (rankedShortTonight.size() >= kMinimumSmallRowCount) {
        rows.push_back(IdRow{.id = QStringLiteral("short-tonight"),
                             .title = QStringLiteral("Short Tonight"),
                             .mediaIds = idsOf(rankedShortTonight)});
    }
    return rows;
}

home_rows::DerivedRows home_rows::deriveRows(const QVector<MediaItem> &items, const QDateTime &now)
{
    DerivedRows derived;
    const QVector<MediaItem> movies = moviesOf(items);

    // The taste reads movies and episodes alike: a show watched through shapes
    // it (:2640 passes `movies + tvEpisodes`).
    const std::optional<browse::TasteModel> taste = browse::TasteModel::build(items);

    derived.playSomething = IdRow{.id = QString::fromLatin1(play_something::kRowId),
                                  .title = QStringLiteral("Play Something"),
                                  .mediaIds = {}};
    for (const MediaItem &item : play_something::candidates(items, play_something::kHomeSalt, taste)) {
        if (derived.playSomething.mediaIds.size() == play_something::kRowLimit) {
            break;
        }
        derived.playSomething.mediaIds.push_back(item.id);
    }

    derived.taste = tasteRows(movies, taste);
    derived.seasonal = seasonalRows(movies, now);
    return derived;
}

const home_rows::DerivedRows &home_rows::DerivedRowsCache::rows(const QVector<MediaItem> &items,
                                                                const QDateTime &now)
{
    const QDate day = now.toLocalTime().date();
    if (!m_rows || m_day != day) {
        m_rows = deriveRows(items, now);
        m_day = day;
        ++m_builds;
    }
    return *m_rows;
}

void home_rows::DerivedRowsCache::invalidate()
{
    m_rows.reset();
}
