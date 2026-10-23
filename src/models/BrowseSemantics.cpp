#include "models/BrowseSemantics.hpp"

#include "profiles/ContentPolicy.hpp"

#include <QChar>
#include <QCollator>
#include <QLatin1Char>
#include <QLatin1String>
#include <QStringList>

#include <algorithm>
#include <atomic>
#include <limits>
#include <utility>

namespace browse
{
namespace
{
std::atomic<int> g_holidayScoreCalls{0};
}

int holidayScoreCallsForTest()
{
    return g_holidayScoreCalls.load(std::memory_order_relaxed);
}

// BrowseSnapshotStore.swift:1784-1802 folds diacritics and width, lowercases,
// and reduces every run of non-alphanumerics to one space.
QString normalizedText(const QString &value)
{
    // Compatibility decomposition separates the combining marks the diacritic
    // fold drops and maps the full-width forms the width fold maps.
    const QString decomposed = value.normalized(QString::NormalizationForm_KD).toLower();

    QString normalized;
    normalized.reserve(decomposed.size());
    bool lastWasSpace = true;
    for (const QChar character : decomposed) {
        if (character.isMark()) {
            continue;
        }
        if (character.isLetterOrNumber()) {
            normalized.append(character);
            lastWasSpace = false;
        } else if (!lastWasSpace) {
            normalized.append(QLatin1Char(' '));
            lastWasSpace = true;
        }
    }

    return normalized.trimmed();
}

// BrowseSnapshotStore.swift:1824-1862: the compact franchise rules first, then
// a leading token long enough to stand on its own, then the first two
// meaningful tokens. An empty key means the title has no family of its own.
QString franchiseKey(const QString &title)
{
    const QStringList titleTokens =
        normalizedText(title).split(QLatin1Char(' '), Qt::SkipEmptyParts);
    if (titleTokens.isEmpty()) {
        return {};
    }

    struct CompactRule
    {
        QLatin1String needle;
        QLatin1String key;
    };
    static const CompactRule compactRules[]{
        {QLatin1String("kingsman"), QLatin1String("kingsman")},
        {QLatin1String("harrypotter"), QLatin1String("harry potter")},
        {QLatin1String("starwars"), QLatin1String("star wars")},
        {QLatin1String("missionimpossible"), QLatin1String("mission impossible")},
        {QLatin1String("fastfurious"), QLatin1String("fast furious")},
        {QLatin1String("jurassicpark"), QLatin1String("jurassic")},
        {QLatin1String("jurassicworld"), QLatin1String("jurassic")},
        {QLatin1String("lordoftherings"), QLatin1String("middle earth")},
        {QLatin1String("thehobbit"), QLatin1String("middle earth")},
        {QLatin1String("spiderman"), QLatin1String("spider man")},
        {QLatin1String("spiderverse"), QLatin1String("spider man")},
        {QLatin1String("darkknight"), QLatin1String("batman")},
        {QLatin1String("batman"), QLatin1String("batman")},
        {QLatin1String("xmen"), QLatin1String("x men")},
        {QLatin1String("avengers"), QLatin1String("avengers")},
        {QLatin1String("guardiansofthegalaxy"), QLatin1String("guardians of the galaxy")}};

    const QString compact = titleTokens.join(QString());
    for (const CompactRule &rule : compactRules) {
        if (compact.contains(rule.needle)) {
            return QString(rule.key);
        }
    }

    QStringList meaningful;
    meaningful.reserve(titleTokens.size());
    for (const QString &token : titleTokens) {
        if (token != QLatin1String("a") && token != QLatin1String("an")
            && token != QLatin1String("the")) {
            meaningful.push_back(token);
        }
    }
    if (meaningful.isEmpty()) {
        return {};
    }
    if (meaningful.constFirst().size() >= 5) {
        return meaningful.constFirst();
    }
    if (meaningful.size() >= 2) {
        return meaningful.constFirst() + QLatin1Char(' ') + meaningful.at(1);
    }
    return {};
}

namespace
{
// localizedCaseInsensitiveCompare, which every released browse sort uses:
// locale collation, so a superscript digit sorts as a digit rather than by
// code point.
[[nodiscard]] const QCollator &localizedCollator()
{
    static const QCollator collator = [] {
        QCollator built;
        built.setCaseSensitivity(Qt::CaseInsensitive);
        return built;
    }();
    return collator;
}
}

// BrowseSnapshotStore.swift:2026-2032. The key is composed once per title
// because folding and tokenising a title is far too expensive to repeat inside
// every comparison a sort makes (:2022-2025).
MovieBrowseSortKey movieBrowseSortKey(const MediaItem &item)
{
    return movieBrowseSortKey(item, franchiseKey(item.title));
}

MovieBrowseSortKey movieBrowseSortKey(const MediaItem &item, const QString &franchise)
{
    return MovieBrowseSortKey{.family = franchise.isEmpty() ? normalizedText(item.title) : franchise,
                              .year = item.year,
                              .title = item.title};
}

// BrowseSnapshotStore.swift:2034-2042.
bool compareMovieBrowseSortKeys(const MovieBrowseSortKey &lhs, const MovieBrowseSortKey &rhs)
{
    if (lhs.family != rhs.family) {
        return localizedCollator().compare(lhs.family, rhs.family) < 0;
    }
    if (lhs.year != rhs.year) {
        const auto yearOrMax = [](int year) {
            return year > 0 ? year : std::numeric_limits<int>::max();
        };
        return yearOrMax(lhs.year) < yearOrMax(rhs.year);
    }
    return localizedCollator().compare(lhs.title, rhs.title) < 0;
}

// BrowseSnapshotStore.swift:2044-2046.
bool compareMoviesForBrowsing(const MediaItem &lhs, const MediaItem &rhs)
{
    return compareMovieBrowseSortKeys(movieBrowseSortKey(lhs), movieBrowseSortKey(rhs));
}

// BrowseSnapshotStore.swift:2048-2053. Swift's sort is stable in practice, so
// equal keys keep the catalog's order here too.
QVector<MediaItem> sortedMoviesForBrowsing(QVector<MediaItem> items)
{
    struct Keyed
    {
        MovieBrowseSortKey key;
        MediaItem item;
    };
    QVector<Keyed> keyed;
    keyed.reserve(items.size());
    for (MediaItem &item : items) {
        keyed.push_back(Keyed{.key = movieBrowseSortKey(item), .item = std::move(item)});
    }
    std::stable_sort(keyed.begin(), keyed.end(), [](const Keyed &lhs, const Keyed &rhs) {
        return compareMovieBrowseSortKeys(lhs.key, rhs.key);
    });
    QVector<MediaItem> sorted;
    sorted.reserve(keyed.size());
    for (Keyed &entry : keyed) {
        sorted.push_back(std::move(entry.item));
    }
    return sorted;
}

// BrowseSnapshotStore.swift:660-665: `metadata?.releaseDate ?? displayYear ?? ""`
// compared as text, then browse order.
bool compareFranchiseOrder(const MediaItem &lhs, const MediaItem &rhs)
{
    const auto dateOf = [](const MediaItem &item) {
        if (item.metadata && !item.metadata->releaseDate.isEmpty()) {
            return item.metadata->releaseDate;
        }
        return item.year > 0 ? QString::number(item.year) : QString();
    };
    const QString lhsDate = dateOf(lhs);
    const QString rhsDate = dateOf(rhs);
    if (lhsDate != rhsDate) {
        return lhsDate < rhsDate;
    }
    return compareMoviesForBrowsing(lhs, rhs);
}

// BrowseSnapshotStore.swift:2073-2101. The released haystack is the title, the
// overview and the genres joined by spaces, and both passes match on
// containment rather than whole tokens (:2083, :2096). It reads no keywords.
int holidayScore(const MediaItem &item)
{
    g_holidayScoreCalls.fetch_add(1, std::memory_order_relaxed);
    const QString title = normalizedText(item.title);
    QStringList parts{title};
    if (item.metadata) {
        parts.push_back(normalizedText(item.metadata->overview));
    } else {
        parts.push_back(QString());
    }
    for (const QString &genre : content_policy::displayGenresOf(item)) {
        parts.push_back(normalizedText(genre));
    }
    const QString haystack = parts.join(QLatin1Char(' '));

    static const QLatin1String directSignals[]{
        QLatin1String("christmas"), QLatin1String("xmas"),
        QLatin1String("holiday"),   QLatin1String("santa"),
        QLatin1String("claus"),     QLatin1String("noel"),
        QLatin1String("hanukkah"),  QLatin1String("chanukah"),
        QLatin1String("kwanzaa"),   QLatin1String("thanksgiving"),
        QLatin1String("halloween")};
    for (const QLatin1String &signal : directSignals) {
        if (haystack.contains(signal)) {
            return 100;
        }
    }

    static const QLatin1String knownHolidayTitles[]{
        QLatin1String("home alone"),
        QLatin1String("elf"),
        QLatin1String("scrooged"),
        QLatin1String("polar express"),
        QLatin1String("miracle on 34th street"),
        QLatin1String("its a wonderful life"),
        QLatin1String("nightmare before christmas")};
    for (const QLatin1String &knownTitle : knownHolidayTitles) {
        if (title.contains(knownTitle)) {
            return 86;
        }
    }

    return 0;
}

// BrowseSnapshotStore.swift:2055-2057.
bool isHolidayMovie(const MediaItem &item)
{
    return holidayScore(item) > 0;
}

// BrowseSnapshotStore.swift:2063-2071.
QVector<MediaItem> sortedHolidayMovies(QVector<MediaItem> items, const QHash<QString, int> &scores)
{
    struct Keyed
    {
        int score;
        MovieBrowseSortKey key;
        MediaItem item;
    };
    QVector<Keyed> keyed;
    keyed.reserve(items.size());
    for (MediaItem &item : items) {
        const auto known = scores.constFind(item.id);
        const int score = known != scores.cend() ? *known : holidayScore(item);
        keyed.push_back(Keyed{.score = score, .key = movieBrowseSortKey(item), .item = std::move(item)});
    }
    std::stable_sort(keyed.begin(), keyed.end(), [](const Keyed &lhs, const Keyed &rhs) {
        if (lhs.score != rhs.score) {
            return lhs.score > rhs.score;
        }
        return compareMovieBrowseSortKeys(lhs.key, rhs.key);
    });
    QVector<MediaItem> sorted;
    sorted.reserve(keyed.size());
    for (Keyed &entry : keyed) {
        sorted.push_back(std::move(entry.item));
    }
    return sorted;
}

}
