#include "models/PlaySomething.hpp"

#include "models/BrowseSemantics.hpp"
#include "models/StableRandom.hpp"

#include <QSet>

#include <algorithm>
#include <cmath>
#include <utility>

namespace
{
// :581-589. The taste term is the clamped affinity (:334-336) over thirty, so
// a title like the finished ones is favoured by at most about nine steps; the
// rating adds up to five, popularity up to four, and artwork a step and a half.
// A title with no metadata weighs what its artwork weighs.
[[nodiscard]] double playWeight(const MediaItem &item, const std::optional<browse::TasteModel> &taste)
{
    double weight = 1.0;
    if (taste) {
        weight += taste->clampedAffinityScore(item) / 30.0;
    }
    if (item.metadata) {
        weight += item.metadata->voteAverage.value_or(0.0) / 2.0;
        weight += std::min(4.0, item.metadata->popularity.value_or(0.0) / 25.0);
    }
    if (!item.displayBackdropPath().isEmpty()) {
        weight += 1.0;
    }
    if (!item.displayPosterPath().isEmpty()) {
        weight += 0.5;
    }
    return weight;
}

// compareMoviesForBrowsing (BrowseSnapshotStore.swift:2044-2046) breaks equal
// keys. The id only settles what the oracle leaves unordered.
[[nodiscard]] bool browsesBefore(const MediaItem &left, const MediaItem &right)
{
    if (browse::compareMoviesForBrowsing(left, right)) {
        return true;
    }
    if (browse::compareMoviesForBrowsing(right, left)) {
        return false;
    }
    return left.id < right.id;
}
}

QVector<MediaItem> play_something::candidates(const QVector<MediaItem> &items, const QString &salt)
{
    return candidates(items, salt, browse::TasteModel::build(items));
}

QVector<MediaItem> play_something::candidates(const QVector<MediaItem> &items,
                                              const QString &salt,
                                              const std::optional<browse::TasteModel> &taste)
{
    struct Keyed
    {
        const MediaItem *item;
        double key;
    };

    // The id is the identity, so a title listed twice is drawn once
    // (playableCandidates, :551-561).
    QVector<Keyed> keyed;
    QSet<QString> seen;
    for (const MediaItem &item : items) {
        if (!item.isMovie() || item.watched || seen.contains(item.id)) {
            continue;
        }
        seen.insert(item.id);
        const double random
            = stable_random::deterministicUnitInterval(item.id + QLatin1Char('|') + salt);
        keyed.push_back(Keyed{.item = &item, .key = std::pow(random, 1.0 / std::max(playWeight(item, taste), 1.0))});
    }
    std::stable_sort(keyed.begin(), keyed.end(), [](const Keyed &left, const Keyed &right) {
        if (left.key != right.key) {
            return left.key > right.key;
        }
        return browsesBefore(*left.item, *right.item);
    });

    QVector<MediaItem> ordered;
    ordered.reserve(keyed.size());
    for (const Keyed &entry : std::as_const(keyed)) {
        ordered.push_back(*entry.item);
    }
    return ordered;
}

std::optional<MediaItem> play_something::pick(const QVector<MediaItem> &items, const QString &salt)
{
    const QVector<MediaItem> ordered = candidates(items, salt);
    if (ordered.isEmpty()) {
        return std::nullopt;
    }
    return ordered.constFirst();
}
