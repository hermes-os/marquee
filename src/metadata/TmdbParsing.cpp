#include "metadata/TmdbParsing.hpp"

#include <QHash>
#include <QJsonValue>
#include <QRegularExpression>
#include <QSet>

#include <algorithm>
#include <cmath>

namespace
{
// A JSON number that holds a whole value, the way Swift's `as? Int` reads it.
[[nodiscard]] std::optional<int> intOf(const QJsonValue &value)
{
    if (!value.isDouble()) {
        return std::nullopt;
    }
    const double number = value.toDouble();
    if (number != std::floor(number) || std::abs(number) > 2'000'000'000.0) {
        return std::nullopt;
    }
    return static_cast<int>(number);
}

// `as? Double` accepts any JSON number.
[[nodiscard]] std::optional<double> doubleOf(const QJsonValue &value)
{
    if (!value.isDouble()) {
        return std::nullopt;
    }
    return value.toDouble();
}

[[nodiscard]] QString stringOf(const QJsonValue &value)
{
    return value.isString() ? value.toString() : QString();
}

[[nodiscard]] QStringList genreNames(const QJsonObject &json)
{
    QStringList genres;
    for (const QJsonValue &entry : json.value(QLatin1String("genres")).toArray()) {
        const QJsonValue name = entry.toObject().value(QLatin1String("name"));
        if (name.isString()) {
            genres.push_back(name.toString());
        }
    }
    return genres;
}

// TMDBService.swift:312-326: the first ten cast entries that carry a name and
// a character, then (TMDBEnrichmentService.makeCast) only those with a TMDB
// person id, because a person without one has no durable key.
[[nodiscard]] QVector<CastMember> castOf(const QJsonObject &json)
{
    QVector<CastMember> cast;
    const QJsonArray entries =
        json.value(QLatin1String("credits")).toObject().value(QLatin1String("cast")).toArray();
    const qsizetype limit = std::min<qsizetype>(entries.size(), tmdb::maxCastMembers);
    for (qsizetype index = 0; index < limit; ++index) {
        const QJsonObject entry = entries.at(index).toObject();
        if (!entry.value(QLatin1String("name")).isString()
            || !entry.value(QLatin1String("character")).isString()) {
            continue;
        }
        const std::optional<int> personId = intOf(entry.value(QLatin1String("id")));
        if (!personId) {
            continue;
        }
        cast.push_back({.name = entry.value(QLatin1String("name")).toString(),
                        .character = entry.value(QLatin1String("character")).toString(),
                        .profilePath = stringOf(entry.value(QLatin1String("profile_path"))),
                        .personId = *personId});
    }
    return cast;
}

[[nodiscard]] QVector<int> idsOf(const QJsonValue &payload)
{
    QVector<int> ids;
    for (const QJsonValue &row : payload.toObject().value(QLatin1String("results")).toArray()) {
        if (const std::optional<int> id = intOf(row.toObject().value(QLatin1String("id")))) {
            ids.push_back(*id);
        }
    }
    return ids;
}

[[nodiscard]] QString movieCertification(const QJsonObject &json)
{
    const QJsonArray countries =
        json.value(QLatin1String("release_dates")).toObject().value(QLatin1String("results")).toArray();
    for (const QJsonValue &countryValue : countries) {
        const QJsonObject country = countryValue.toObject();
        if (country.value(QLatin1String("iso_3166_1")).toString() != QLatin1String("US")) {
            continue;
        }
        for (const QJsonValue &release : country.value(QLatin1String("release_dates")).toArray()) {
            const QString certification =
                stringOf(release.toObject().value(QLatin1String("certification")));
            if (!certification.isEmpty()) {
                return certification;
            }
        }
    }
    return {};
}
}

QString tmdb::normalizeTitle(const QString &title)
{
    static const QRegularExpression leadingArticle(
        QStringLiteral(R"(^(the|a|an)\s+)"), QRegularExpression::UseUnicodePropertiesOption);
    static const QRegularExpression punctuation(
        QStringLiteral(R"([^\w\s])"), QRegularExpression::UseUnicodePropertiesOption);
    static const QRegularExpression whitespace(
        QStringLiteral(R"(\s+)"), QRegularExpression::UseUnicodePropertiesOption);

    QString normalized = title.toLower();
    normalized.remove(leadingArticle);
    normalized.replace(QLatin1Char('&'), QStringLiteral("and"));
    normalized.remove(punctuation);
    normalized.replace(whitespace, QStringLiteral(" "));
    return normalized.trimmed();
}

namespace
{
[[nodiscard]] QSet<QString> wordsOf(const QString &normalized)
{
    const QStringList words = normalized.split(QLatin1Char(' '), Qt::SkipEmptyParts);
    return QSet<QString>(words.cbegin(), words.cend());
}

[[nodiscard]] bool isSubset(const QSet<QString> &subset, const QSet<QString> &superset)
{
    return std::all_of(subset.cbegin(), subset.cend(),
                       [&superset](const QString &word) { return superset.contains(word); });
}
}

double tmdb::titleSimilarity(const QString &left, const QString &right)
{
    const QSet<QString> leftWords = wordsOf(left);
    const QSet<QString> rightWords = wordsOf(right);
    if (leftWords.isEmpty() && rightWords.isEmpty()) {
        return 0;
    }
    const qsizetype shared = QSet<QString>(leftWords).intersect(rightWords).size();
    const qsizetype all = QSet<QString>(leftWords).unite(rightWords).size();
    return static_cast<double>(shared) / static_cast<double>(all);
}

std::optional<int> tmdb::bestMatch(const QJsonArray &results,
                                   const QString &query,
                                   const QString &titleKey)
{
    const QString queryNormalized = normalizeTitle(query);
    const QSet<QString> queryWords = wordsOf(queryNormalized);

    const auto resultId = [](const QJsonObject &result) { return intOf(result.value(QLatin1String("id"))); };
    const auto resultTitle = [&titleKey](const QJsonObject &result) -> std::optional<QString> {
        const QJsonValue title = result.value(titleKey);
        return title.isString() ? std::optional<QString>(title.toString()) : std::nullopt;
    };

    for (const QJsonValue &value : results) {
        const QJsonObject result = value.toObject();
        const auto id = resultId(result);
        const auto title = resultTitle(result);
        if (id && title && normalizeTitle(*title) == queryNormalized) {
            return id;
        }
    }

    for (const QJsonValue &value : results) {
        const QJsonObject result = value.toObject();
        const auto id = resultId(result);
        const auto title = resultTitle(result);
        if (!id || !title) {
            continue;
        }
        const QSet<QString> resultWords = wordsOf(normalizeTitle(*title));
        if (!queryWords.isEmpty() && isSubset(queryWords, resultWords)) {
            return id;
        }
    }

    if (!results.isEmpty()) {
        const QJsonObject first = results.first().toObject();
        const auto id = resultId(first);
        const auto title = resultTitle(first);
        if (id && title && titleSimilarity(normalizeTitle(*title), queryNormalized) > 0.5) {
            return id;
        }
    }
    return std::nullopt;
}

QJsonArray tmdb::resultsNearYear(const QJsonArray &results,
                                 const QString &dateKey,
                                 int year,
                                 int tolerance)
{
    QJsonArray near;
    for (const QJsonValue &value : results) {
        const QString date = value.toObject().value(dateKey).toString();
        bool numeric = false;
        const int resultYear = date.left(4).toInt(&numeric);
        if (numeric && date.size() >= 4 && std::abs(resultYear - year) <= tolerance) {
            near.push_back(value);
        }
    }
    return near;
}

QString tmdb::mostRestrictiveRating(const QStringList &ratings)
{
    static const QHash<QString, int> order{
        {QStringLiteral("TV-Y"), 0},   {QStringLiteral("TV-Y7"), 1}, {QStringLiteral("TV-G"), 2},
        {QStringLiteral("G"), 3},      {QStringLiteral("TV-PG"), 4}, {QStringLiteral("PG"), 5},
        {QStringLiteral("TV-14"), 6},  {QStringLiteral("PG-13"), 7}, {QStringLiteral("TV-MA"), 8},
        {QStringLiteral("R"), 9},      {QStringLiteral("NC-17"), 10}, {QStringLiteral("NR"), 11}};
    if (ratings.isEmpty()) {
        return {};
    }
    QString best = ratings.first();
    for (const QString &rating : ratings) {
        if (order.value(best, 11) < order.value(rating, 11)) {
            best = rating;
        }
    }
    return best;
}

TitleMetadata tmdb::parseMovie(const QJsonObject &json, int tmdbId)
{
    TitleMetadata metadata;
    metadata.tmdbId = tmdbId;
    metadata.overview = stringOf(json.value(QLatin1String("overview")));
    metadata.genres = genreNames(json);
    metadata.cast = castOf(json);
    for (const QJsonValue &member :
         json.value(QLatin1String("credits")).toObject().value(QLatin1String("crew")).toArray()) {
        const QJsonObject crew = member.toObject();
        if (crew.value(QLatin1String("job")).toString() == QLatin1String("Director")
            && crew.value(QLatin1String("name")).isString()) {
            metadata.director = crew.value(QLatin1String("name")).toString();
            break;
        }
    }
    metadata.certification = movieCertification(json);
    metadata.voteAverage = doubleOf(json.value(QLatin1String("vote_average")));
    metadata.voteCount = intOf(json.value(QLatin1String("vote_count")));
    metadata.popularity = doubleOf(json.value(QLatin1String("popularity")));

    const QJsonObject collection = json.value(QLatin1String("belongs_to_collection")).toObject();
    metadata.collectionId = intOf(collection.value(QLatin1String("id")));
    metadata.collectionName = stringOf(collection.value(QLatin1String("name")));

    for (const QJsonValue &row :
         json.value(QLatin1String("keywords")).toObject().value(QLatin1String("keywords")).toArray()) {
        const QJsonObject keyword = row.toObject();
        const std::optional<int> id = intOf(keyword.value(QLatin1String("id")));
        const QString name = stringOf(keyword.value(QLatin1String("name")));
        if (id && !name.isEmpty()) {
            metadata.keywords.push_back({.id = *id, .name = name});
        }
    }
    metadata.similarTmdbIds = idsOf(json.value(QLatin1String("similar")));
    metadata.recommendedTmdbIds = idsOf(json.value(QLatin1String("recommendations")));

    metadata.posterRemotePath = stringOf(json.value(QLatin1String("poster_path")));
    metadata.backdropRemotePath = stringOf(json.value(QLatin1String("backdrop_path")));
    metadata.releaseDate = stringOf(json.value(QLatin1String("release_date")));
    metadata.runtimeMinutes = intOf(json.value(QLatin1String("runtime"))).value_or(0);
    return metadata;
}

TitleMetadata tmdb::parseShow(const QJsonObject &json, int tmdbId)
{
    TitleMetadata metadata;
    metadata.tmdbId = tmdbId;
    metadata.overview = stringOf(json.value(QLatin1String("overview")));
    metadata.genres = genreNames(json);
    metadata.cast = castOf(json);
    // The show's "director" is its first creator (TMDBService.swift:432-435).
    const QJsonArray creators = json.value(QLatin1String("created_by")).toArray();
    if (!creators.isEmpty()) {
        metadata.director = stringOf(creators.first().toObject().value(QLatin1String("name")));
    }

    QStringList usRatings;
    for (const QJsonValue &entryValue :
         json.value(QLatin1String("content_ratings")).toObject().value(QLatin1String("results")).toArray()) {
        const QJsonObject entry = entryValue.toObject();
        if (entry.value(QLatin1String("iso_3166_1")).toString() != QLatin1String("US")) {
            continue;
        }
        const QString rating = stringOf(entry.value(QLatin1String("rating")));
        if (!rating.isEmpty()) {
            usRatings.push_back(rating);
        }
    }
    metadata.certification = mostRestrictiveRating(usRatings);

    metadata.voteAverage = doubleOf(json.value(QLatin1String("vote_average")));
    metadata.posterRemotePath = stringOf(json.value(QLatin1String("poster_path")));
    metadata.backdropRemotePath = stringOf(json.value(QLatin1String("backdrop_path")));
    metadata.releaseDate = stringOf(json.value(QLatin1String("first_air_date")));
    const QJsonArray runtimes = json.value(QLatin1String("episode_run_time")).toArray();
    if (!runtimes.isEmpty()) {
        metadata.runtimeMinutes = intOf(runtimes.first()).value_or(0);
    }
    return metadata;
}

QVector<tmdb::SeasonEpisode> tmdb::parseSeason(const QJsonObject &json)
{
    QVector<SeasonEpisode> episodes;
    for (const QJsonValue &value : json.value(QLatin1String("episodes")).toArray()) {
        const QJsonObject episode = value.toObject();
        const std::optional<int> number = intOf(episode.value(QLatin1String("episode_number")));
        if (!number || !episode.value(QLatin1String("name")).isString()) {
            continue;
        }
        SeasonEpisode parsed;
        parsed.episodeNumber = *number;
        parsed.metadata.tmdbEpisodeId = intOf(episode.value(QLatin1String("id"))).value_or(0);
        parsed.metadata.title = episode.value(QLatin1String("name")).toString();
        parsed.metadata.overview = stringOf(episode.value(QLatin1String("overview")));
        parsed.metadata.airDate = stringOf(episode.value(QLatin1String("air_date")));
        parsed.metadata.voteAverage = doubleOf(episode.value(QLatin1String("vote_average")));
        parsed.metadata.stillRemotePath = stringOf(episode.value(QLatin1String("still_path")));
        episodes.push_back(parsed);
    }
    return episodes;
}
