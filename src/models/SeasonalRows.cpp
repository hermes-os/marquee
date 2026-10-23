#include "models/SeasonalRows.hpp"

#include "models/BrowseSemantics.hpp"
#include "models/StableRandom.hpp"
#include "models/TasteModel.hpp"
#include "profiles/ContentPolicy.hpp"

#include <QSet>
#include <QStringList>

#include <algorithm>

namespace
{
constexpr auto kOctoberHorrorRowId = "seasonal-october-horror";           // :371
constexpr auto kSummerBlockbustersRowId = "seasonal-summer-blockbusters"; // :370

// :667-670: the title, the overview and the genres, each normalized, joined by
// spaces. Matches are by containment, as in the holiday score.
[[nodiscard]] QString semanticHaystack(const MediaItem &item)
{
    QStringList parts{browse::normalizedText(item.title),
                      browse::normalizedText(item.metadata ? item.metadata->overview : QString())};
    for (const QString &genre : content_policy::displayGenresOf(item)) {
        parts.push_back(browse::normalizedText(genre));
    }
    return parts.join(QLatin1Char(' '));
}

[[nodiscard]] QSet<QString> normalizedGenres(const MediaItem &item)
{
    QSet<QString> genres;
    for (const QString &genre : content_policy::displayGenresOf(item)) {
        genres.insert(browse::normalizedText(genre));
    }
    return genres;
}

// :690-694: unpadded year, month and day.
[[nodiscard]] QString dateKey(const QDate &date)
{
    return QStringLiteral("%1-%2-%3").arg(date.year()).arg(date.month()).arg(date.day());
}

// :591-607.
[[nodiscard]] QStringList sortedSeasonalIds(const QVector<MediaItem> &movies,
                                            const QDate &date,
                                            const QString &rowSalt)
{
    qint64 newest = -1;
    for (const MediaItem &item : movies) {
        newest = std::max(newest, browse::effectiveDateMs(item));
    }
    const QString salt = rowSalt + QLatin1Char('-') + dateKey(date);

    struct Scored
    {
        double score;
        browse::MovieBrowseSortKey key;
        const MediaItem *item;
    };
    QVector<Scored> scored;
    scored.reserve(movies.size());
    for (const MediaItem &item : movies) {
        scored.push_back(Scored{
            .score = home_rows::heroScore(item, newest)
                + stable_random::deterministicUnitInterval(item.id + QLatin1Char('|') + salt),
            .key = browse::movieBrowseSortKey(item),
            .item = &item});
    }
    std::stable_sort(scored.begin(), scored.end(), [](const Scored &lhs, const Scored &rhs) {
        if (lhs.score != rhs.score) {
            return lhs.score > rhs.score;
        }
        return browse::compareMovieBrowseSortKeys(lhs.key, rhs.key);
    });
    QStringList ids;
    ids.reserve(scored.size());
    for (const Scored &entry : std::as_const(scored)) {
        ids.push_back(entry.item->id);
    }
    return ids;
}
}

double home_rows::heroScore(const MediaItem &item, qint64 newestMs)
{
    double score = (item.metadata ? item.metadata->voteAverage.value_or(0.0) : 0.0) * 100;
    if (!item.displayBackdropPath().isEmpty()) {
        score += 180;
    }
    if (!item.displayPosterPath().isEmpty()) {
        score += 50;
    }
    // A length of zero is the catalog's "unknown", the released `nil`.
    if (item.durationSeconds > 0) {
        if (item.durationSeconds >= kHeroLongSeconds) {
            score += 30;
        }
        if (item.durationSeconds < kHeroShortSeconds) {
            score -= 180;
        }
    }
    if (newestMs >= 0) {
        const double ageSeconds = std::max(0.0, static_cast<double>(newestMs - browse::effectiveDateMs(item)) / 1000.0);
        const double thirtyDays = 60.0 * 60.0 * 24.0 * 30.0;
        score += std::max(0.0, 70 - (ageSeconds / thirtyDays) * 70);
    }
    return score;
}

bool home_rows::isOctoberHorror(const MediaItem &item)
{
    const QString haystack = semanticHaystack(item);
    return normalizedGenres(item).contains(QStringLiteral("horror"))
        || haystack.contains(QLatin1String("halloween"))
        || haystack.contains(QLatin1String("haunted"))
        || haystack.contains(QLatin1String("ghost"));
}

bool home_rows::isSummerBlockbuster(const MediaItem &item)
{
    static const QSet<QString> blockbusterGenres{
        QStringLiteral("action"), QStringLiteral("adventure"), QStringLiteral("science fiction"),
        QStringLiteral("sci fi"), QStringLiteral("fantasy")};
    const QSet<QString> genres = normalizedGenres(item);
    const bool matches = std::any_of(blockbusterGenres.cbegin(), blockbusterGenres.cend(),
                                     [&genres](const QString &genre) { return genres.contains(genre); });
    if (!matches) {
        return false;
    }
    const int voteCount = item.metadata ? item.metadata->voteCount.value_or(0) : 0;
    const double popularity = item.metadata ? item.metadata->popularity.value_or(0.0) : 0.0;
    const double voteAverage = item.metadata ? item.metadata->voteAverage.value_or(0.0) : 0.0;
    return voteCount >= 100 || popularity >= 10 || voteAverage >= 7.0;
}

QVector<home_rows::IdRow> home_rows::seasonalRows(const QVector<MediaItem> &movies,
                                                  const QDateTime &now)
{
    QVector<IdRow> rows;
    if (movies.isEmpty()) {
        return rows;
    }
    const QDate date = now.toLocalTime().date();
    const int month = date.month();

    const auto collect = [&movies](bool (*matches)(const MediaItem &)) {
        QVector<MediaItem> chosen;
        for (const MediaItem &item : movies) {
            if (matches(item)) {
                chosen.push_back(item);
            }
        }
        return chosen;
    };

    if (month == 10) {
        const QVector<MediaItem> horror = collect(isOctoberHorror);
        if (horror.size() >= 2) {
            rows.push_back(IdRow{.id = QString::fromLatin1(kOctoberHorrorRowId),
                                 .title = QStringLiteral("October Horror"),
                                 .mediaIds = sortedSeasonalIds(horror, date,
                                                               QString::fromLatin1(kOctoberHorrorRowId))});
            return rows;
        }
    }

    if (month >= 6 && month <= 8) {
        const QVector<MediaItem> blockbusters = collect(isSummerBlockbuster);
        if (blockbusters.size() >= 2) {
            rows.push_back(IdRow{.id = QString::fromLatin1(kSummerBlockbustersRowId),
                                 .title = QStringLiteral("Summer Blockbusters"),
                                 .mediaIds = sortedSeasonalIds(blockbusters, date,
                                                               QString::fromLatin1(kSummerBlockbustersRowId))});
        }
    }
    return rows;
}
