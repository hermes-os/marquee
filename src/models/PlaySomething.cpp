#include "models/PlaySomething.hpp"

#include "models/BrowseSemantics.hpp"

#include <QByteArray>
#include <QCollator>
#include <QSet>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>
#include <utility>

namespace
{
// BrowseSnapshotStore.swift:701-708: FNV-1a over the UTF-8 bytes.
[[nodiscard]] std::uint64_t stableHash(const QString &value)
{
    std::uint64_t hash = 1'469'598'103'934'665'603ULL;
    const QByteArray bytes = value.toUtf8();
    for (const char byte : bytes) {
        hash ^= static_cast<std::uint8_t>(byte);
        hash *= 1'099'511'628'211ULL;
    }
    return hash;
}

// :696-699: a number in (0, 1) fixed by the text, so one salt always shuffles
// the same titles the same way.
[[nodiscard]] double deterministicUnitInterval(const QString &value)
{
    return (static_cast<double>(stableHash(value) % 1'000'000ULL) + 1.0) / 1'000'001.0;
}

// :577-585 without the signals the v3 catalog does not hold yet (taste
// affinity, vote average, popularity, backdrop): a title with a poster is
// favoured by the same half step.
[[nodiscard]] double playWeight(const MediaItem &item)
{
    return 1.0 + (item.posterAbsolutePath.isEmpty() ? 0.0 : 0.5);
}

// compareMoviesForBrowsing (BrowseSnapshotStore.swift:2026-2046) breaks equal
// keys: franchise family (or the normalized title), year with an unknown year
// last, then title. The id only settles what the oracle leaves unordered.
[[nodiscard]] bool browsesBefore(const MediaItem &left, const MediaItem &right)
{
    const auto familyOf = [](const MediaItem &item) {
        const QString family = browse::franchiseKey(item.title);
        return family.isEmpty() ? browse::normalizedText(item.title) : family;
    };
    // localizedCaseInsensitiveCompare (BrowseSnapshotStore.swift:2034-2042),
    // through the collator the Movies page orders families with.
    static const QCollator familyCollator = [] {
        QCollator collator;
        collator.setCaseSensitivity(Qt::CaseInsensitive);
        return collator;
    }();
    if (const int byFamily = familyCollator.compare(familyOf(left), familyOf(right));
        byFamily != 0) {
        return byFamily < 0;
    }
    const int leftYear = left.year > 0 ? left.year : std::numeric_limits<int>::max();
    const int rightYear = right.year > 0 ? right.year : std::numeric_limits<int>::max();
    if (leftYear != rightYear) {
        return leftYear < rightYear;
    }
    if (const int byTitle = QString::compare(left.title, right.title, Qt::CaseInsensitive);
        byTitle != 0) {
        return byTitle < 0;
    }
    return left.id < right.id;
}
}

QVector<MediaItem> play_something::candidates(const QVector<MediaItem> &items, const QString &salt)
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
        const double random = deterministicUnitInterval(item.id + QLatin1Char('|') + salt);
        keyed.push_back(Keyed{.item = &item, .key = std::pow(random, 1.0 / std::max(playWeight(item), 1.0))});
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
