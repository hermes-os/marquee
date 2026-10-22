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
/// dropped, "&" read as "and", punctuation removed, whitespace collapsed. Two
/// changes to the released rules: single-letter initials compare equal with or
/// without dots and spaces ("E.T.", "E T", "ET"), and the cent sign reads as
/// "c" (TMDB lists "Ri¢hie Ri¢h" for "Richie Rich").
/// With `joinInitials` false only the released rules apply ("P.S." is "ps", not joined to a next letter).
[[nodiscard]] QString normalizeTitle(const QString &title, bool joinInitials = true);

/// TMDBService.swift:283-290: shared words over all words of two normalized
/// titles.
[[nodiscard]] double titleSimilarity(const QString &left, const QString &right);

/// TMDBService.swift:241-272: the id of the search result that names `query`,
/// in three passes over TMDB's own order. First a result whose normalized
/// title equals the query's. Then a result holding every word of the query.
/// Last the top result, when it shares more than half its words with the
/// query. The released app never consults the year here, only TMDB's search
/// does. One pass runs before the three: with a `year` and the `dateKey` of
/// the result type, a result with an equal title released in that year wins
/// over an equal title that TMDB ranked higher. One pass runs after the three:
/// with a `year`, a result released in that year whose normalized title the
/// query begins with, followed by a space ("Star Trek" for "Star Trek The
/// Original Series"), matches; "Us" does not match "Between Us Girls".
/// Titles count as equal, or as holding the words, when either their joined or
/// their unjoined initials do.
[[nodiscard]] std::optional<int> bestMatch(const QJsonArray &results,
                                           const QString &query,
                                           const QString &titleKey,
                                           const QString &dateKey = {},
                                           int year = 0);

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
