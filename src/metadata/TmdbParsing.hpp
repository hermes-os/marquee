#pragma once

#include <QJsonArray>
#include <QJsonObject>
#include <QString>
#include <QStringList>
#include <QVector>

#include <optional>

#include "catalog/TitleMetadata.hpp"

/// The pure half of the TMDB client: matching a title to a search result and
/// reading TMDB's JSON. Everything here is a function of its arguments, so
/// saved responses can be parsed in tests without a network.
namespace tmdb
{
/// TMDBService.swift:274-281: lowercased, a leading "the", "a" or "an"
/// dropped, "&" read as "and", punctuation removed, whitespace collapsed.
[[nodiscard]] QString normalizeTitle(const QString &title);

/// TMDBService.swift:283-290: shared words over all words of two normalized
/// titles.
[[nodiscard]] double titleSimilarity(const QString &left, const QString &right);

/// TMDBService.swift:241-272: the id of the search result that names `query`,
/// in three passes over TMDB's own order. First a result whose normalized
/// title equals the query's. Then a result holding every word of the query.
/// Last the top result, when it shares more than half its words with the
/// query. The year is not consulted here: the released app only passes it to
/// TMDB's search, which narrows what comes back.
[[nodiscard]] std::optional<int> bestMatch(const QJsonArray &results,
                                           const QString &query,
                                           const QString &titleKey);

/// The results whose `dateKey` ("release_date", "first_air_date") names a year
/// within `tolerance` of `year`. A result with no readable date is dropped.
[[nodiscard]] QJsonArray resultsNearYear(const QJsonArray &results,
                                         const QString &dateKey,
                                         int year,
                                         int tolerance);

/// TMDBService.swift:294-397. `tmdbId` is the id the request asked for.
[[nodiscard]] TitleMetadata parseMovie(const QJsonObject &json, int tmdbId);
/// TMDBService.swift:399-463.
[[nodiscard]] TitleMetadata parseShow(const QJsonObject &json, int tmdbId);

struct SeasonEpisode
{
    int episodeNumber{0};
    EpisodeMetadata metadata;
};
/// TMDBService.swift:503-521.
[[nodiscard]] QVector<SeasonEpisode> parseSeason(const QJsonObject &json);

/// TMDBService.swift:529-538: the most restrictive of several US ratings;
/// the first of equally restrictive ones, and an unknown rating counts as
/// "NR".
[[nodiscard]] QString mostRestrictiveRating(const QStringList &ratings);

/// Released `Configuration.maxCastMembers`.
inline constexpr int maxCastMembers = 10;
}
