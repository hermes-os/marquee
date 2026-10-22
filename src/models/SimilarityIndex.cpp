#include "models/SimilarityIndex.hpp"

#include "models/TasteModel.hpp"
#include "profiles/ContentPolicy.hpp"

#include <QLatin1String>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <limits>
#include <utility>

namespace
{
// BrowseSnapshotStore.swift:2123-2134.
[[nodiscard]] bool isMeaningfulOverviewToken(const QString &token)
{
    static const QSet<QString> stopwords{
        QStringLiteral("about"),   QStringLiteral("after"), QStringLiteral("again"),
        QStringLiteral("against"), QStringLiteral("along"), QStringLiteral("also"),
        QStringLiteral("and"),     QStringLiteral("are"),   QStringLiteral("away"),
        QStringLiteral("because"), QStringLiteral("been"),  QStringLiteral("but"),
        QStringLiteral("can"),     QStringLiteral("for"),   QStringLiteral("from"),
        QStringLiteral("has"),     QStringLiteral("have"),  QStringLiteral("her"),
        QStringLiteral("his"),     QStringLiteral("into"),  QStringLiteral("its"),
        QStringLiteral("new"),     QStringLiteral("not"),   QStringLiteral("off"),
        QStringLiteral("one"),     QStringLiteral("out"),   QStringLiteral("over"),
        QStringLiteral("she"),     QStringLiteral("the"),   QStringLiteral("their"),
        QStringLiteral("them"),    QStringLiteral("then"),  QStringLiteral("they"),
        QStringLiteral("this"),    QStringLiteral("through"), QStringLiteral("two"),
        QStringLiteral("who"),     QStringLiteral("will"),  QStringLiteral("with"),
        QStringLiteral("when")};
    return token.size() >= 3 && !stopwords.contains(token);
}

// :1812-1818.
[[nodiscard]] QSet<QString> overviewTokensOf(const QString &overview)
{
    QSet<QString> tokens;
    const QStringList words = browse::normalizedText(overview).split(QLatin1Char(' '), Qt::SkipEmptyParts);
    for (const QString &word : words) {
        if (isMeaningfulOverviewToken(word)) {
            tokens.insert(word);
        }
    }
    return tokens;
}

// :2559-2561.
[[nodiscard]] double qualityPrior(const std::optional<double> &voteAverage)
{
    return voteAverage.value_or(0.0) * 8;
}

// :2563-2566.
[[nodiscard]] int yearDistance(int year, int sourceYear)
{
    if (year <= 0 || sourceYear <= 0) {
        return std::numeric_limits<int>::max();
    }
    return std::abs(year - sourceYear);
}

// :2313-2324.
[[nodiscard]] int olderGenreWeight(const QString &genre)
{
    static const QSet<QString> high{QStringLiteral("science fiction"), QStringLiteral("sci fi"),
                                    QStringLiteral("fantasy"),         QStringLiteral("animation"),
                                    QStringLiteral("family"),          QStringLiteral("horror"),
                                    QStringLiteral("mystery")};
    static const QSet<QString> middle{QStringLiteral("adventure"), QStringLiteral("comedy"),
                                      QStringLiteral("thriller"),  QStringLiteral("crime"),
                                      QStringLiteral("music"),     QStringLiteral("musical")};
    if (high.contains(genre)) {
        return 70;
    }
    if (middle.contains(genre)) {
        return 46;
    }
    if (genre == QLatin1String("action") || genre == QLatin1String("drama")) {
        return 28;
    }
    return 36;
}
}

namespace
{
std::atomic<int> g_constructed{0};
}

int browse::SimilarityIndex::constructedForTest()
{
    return g_constructed.load(std::memory_order_relaxed);
}

browse::SimilarityIndex::SimilarityIndex(const QVector<MediaItem> &movies,
                                         QHash<QString, int> holidayScores)
    : m_movies(movies),
      m_holidayScores(std::move(holidayScores))
{
    g_constructed.fetch_add(1, std::memory_order_relaxed);
    m_profiles.reserve(movies.size());
    QHash<QString, int> documentFrequency;
    for (qsizetype position = 0; position < movies.size(); ++position) {
        const MediaItem &item = movies.at(position);
        Profile profile;
        profile.id = item.id;
        profile.position = static_cast<int>(position);
        profile.year = item.year;
        profile.effectiveDate = effectiveDateMs(item);
        profile.franchise = franchiseKey(item.title);
        profile.decade = item.year > 0 ? (item.year / 10) * 10 : -1;
        profile.browseKey = movieBrowseSortKey(item);

        QSet<QString> genres;
        for (const QString &genre : content_policy::displayGenresOf(item)) {
            genres.insert(normalizedText(genre));
        }
        profile.genres = QStringList(genres.cbegin(), genres.cend());
        profile.genres.sort();
        for (const QString &genre : std::as_const(profile.genres)) {
            ++documentFrequency[genre];
        }

        if (item.metadata) {
            // :2595, :2613-2617: a director that normalizes to nothing is none.
            profile.director = normalizedText(item.metadata->director);
            // :2603-2611: the first billing of a name is its rank.
            for (qsizetype rank = 0; rank < item.metadata->cast.size(); ++rank) {
                const QString name = normalizedText(item.metadata->cast.at(rank).name);
                profile.castNames.insert(name);
                if (!name.isEmpty() && !profile.castRank.contains(name)) {
                    profile.castRank.insert(name, static_cast<int>(rank));
                }
            }
            profile.overviewTokens = overviewTokensOf(item.metadata->overview);
            profile.voteAverage = item.metadata->voteAverage;
        }
        m_positionById.insert(item.id, static_cast<int>(position));
        m_profiles.push_back(std::move(profile));
    }

    // :2481-2496: a genre few movies share weighs more.
    const double total = static_cast<double>(std::max<qsizetype>(m_profiles.size(), 1));
    for (auto it = documentFrequency.cbegin(); it != documentFrequency.cend(); ++it) {
        const double idf = std::log((total + 1) / (static_cast<double>(it.value()) + 1));
        m_genreWeights.insert(it.key(), std::min(96.0, 18 + idf * 72));
    }
}

double browse::SimilarityIndex::indexScore(const Profile &source, const Profile &candidate) const
{
    double baseScore = 0.0;

    // :2419-2425.
    if (!source.franchise.isEmpty() && source.franchise == candidate.franchise) {
        baseScore += 260;
        if (source.year > 0 && candidate.year > 0) {
            baseScore += std::max(0.0, 55 - static_cast<double>(std::abs(candidate.year - source.year)) * 2.5);
        }
    }

    // :2427-2430.
    if (!source.director.isEmpty() && source.director == candidate.director) {
        baseScore += 150;
    }

    // :2453-2465.
    double cast = 0.0;
    for (auto it = source.castRank.cbegin(); it != source.castRank.cend(); ++it) {
        const auto other = candidate.castRank.constFind(it.key());
        if (other == candidate.castRank.cend()) {
            continue;
        }
        const int best = std::min(it.value(), other.value());
        const int worst = std::max(it.value(), other.value());
        cast += std::max(18.0, 135 - static_cast<double>(best) * 22 - static_cast<double>(worst) * 8);
    }
    baseScore += std::min(cast, 240.0);

    // :2434-2437.
    for (const QString &genre : source.genres) {
        if (candidate.genres.contains(genre)) {
            baseScore += m_genreWeights.value(genre, 24.0);
        }
    }

    // :2467-2479.
    if (!source.overviewTokens.isEmpty() && !candidate.overviewTokens.isEmpty()) {
        const QSet<QString> &smaller = source.overviewTokens.size() <= candidate.overviewTokens.size()
            ? source.overviewTokens
            : candidate.overviewTokens;
        const QSet<QString> &larger = &smaller == &source.overviewTokens ? candidate.overviewTokens
                                                                         : source.overviewTokens;
        int shared = 0;
        for (const QString &token : smaller) {
            if (larger.contains(token)) {
                ++shared;
            }
        }
        if (shared > 0) {
            const double denominator = std::sqrt(static_cast<double>(source.overviewTokens.size())
                                                 * static_cast<double>(candidate.overviewTokens.size()));
            baseScore += (static_cast<double>(shared) / denominator) * 90;
        }
    }

    if (baseScore <= 0) {
        return 0;
    }

    // :2443-2450.
    double score = baseScore;
    if (source.voteAverage && candidate.voteAverage) {
        score += std::max(0.0, 22 - std::abs(*source.voteAverage - *candidate.voteAverage) * 3.0);
    }
    score += qualityPrior(candidate.voteAverage);
    return score;
}

bool browse::SimilarityIndex::ranksBefore(double lhsScore,
                                          const Profile &lhs,
                                          double rhsScore,
                                          const Profile &rhs,
                                          const Profile &source) const
{
    // :2498-2518. The released last key is the id's text; here it is the id.
    if (lhsScore != rhsScore) {
        return lhsScore > rhsScore;
    }
    const double lhsPrior = qualityPrior(lhs.voteAverage);
    const double rhsPrior = qualityPrior(rhs.voteAverage);
    if (lhsPrior != rhsPrior) {
        return lhsPrior > rhsPrior;
    }
    if (lhs.effectiveDate != rhs.effectiveDate) {
        return lhs.effectiveDate > rhs.effectiveDate;
    }
    const int lhsDistance = yearDistance(lhs.year, source.year);
    const int rhsDistance = yearDistance(rhs.year, source.year);
    if (lhsDistance != rhsDistance) {
        return lhsDistance < rhsDistance;
    }
    return lhs.id < rhs.id;
}

QVector<QString> browse::SimilarityIndex::rankedMovieIds(const QString &sourceId, int limit) const
{
    const auto found = m_positionById.constFind(sourceId);
    if (found == m_positionById.cend() || m_profiles.size() < 2 || limit <= 0) {
        return {};
    }
    const Profile &source = m_profiles.at(found.value());

    struct Scored
    {
        double score;
        const Profile *profile;
    };
    QVector<Scored> scored;
    for (const Profile &candidate : m_profiles) {
        if (candidate.id == source.id) {
            continue;
        }
        const double score = indexScore(source, candidate);
        if (score > 0) {
            scored.push_back(Scored{.score = score, .profile = &candidate});
        }
    }
    const auto before = [this, &source](const Scored &lhs, const Scored &rhs) {
        return ranksBefore(lhs.score, *lhs.profile, rhs.score, *rhs.profile, source);
    };
    const qsizetype kept = std::min<qsizetype>(limit, scored.size());
    std::partial_sort(scored.begin(), scored.begin() + kept, scored.end(), before);

    QVector<QString> ids;
    ids.reserve(kept);
    for (qsizetype index = 0; index < kept; ++index) {
        ids.push_back(scored.at(index).profile->id);
    }
    return ids;
}

bool browse::SimilarityIndex::isHoliday(const MediaItem &item) const
{
    const auto known = m_holidayScores.constFind(item.id);
    return (known != m_holidayScores.cend() ? *known : holidayScore(item)) > 0;
}

// :2265-2311, scored on the profiles composed once.
int browse::SimilarityIndex::olderScore(const Profile &source,
                                        const Profile &candidate,
                                        bool sourceIsHoliday) const
{
    int score = 0;

    if (!source.franchise.isEmpty() && source.franchise == candidate.franchise) {
        score += 1'000;
        if (source.year > 0 && candidate.year > 0) {
            score += std::max(0, 80 - std::abs(candidate.year - source.year) * 4);
        }
    }

    for (const QString &genre : source.genres) {
        if (candidate.genres.contains(genre)) {
            score += olderGenreWeight(genre);
        }
    }

    if (!source.director.isEmpty() && source.director == candidate.director) {
        score += 160;
    }

    int sharedCast = 0;
    for (const QString &name : source.castNames) {
        if (candidate.castNames.contains(name)) {
            ++sharedCast;
        }
    }
    score += std::min(160, sharedCast * 32);

    if (source.decade >= 0 && source.decade == candidate.decade) {
        score += 20;
    }

    // The holiday score reads the overview and genres, so only a holiday
    // source pays for scoring its candidates.
    if (sourceIsHoliday && isHoliday(m_movies.at(candidate.position))) {
        score += 120;
    }
    return score;
}

QVector<QString> browse::SimilarityIndex::similarMovieIds(const MediaItem &source, int limit) const
{
    QVector<QString> results;
    const auto found = m_positionById.constFind(source.id);
    if (limit <= 0 || found == m_positionById.cend()) {
        return results;
    }
    const Profile &sourceProfile = m_profiles.at(found.value());
    QSet<QString> seen{source.id};
    const bool sourceIsHoliday = isHoliday(source);

    for (const QString &id : rankedMovieIds(source.id)) {
        if (seen.contains(id)) {
            continue;
        }
        results.push_back(id);
        seen.insert(id);
        if (results.size() == limit) {
            return results;
        }
    }

    // :2244-2263: the older rule's order, for what the index did not name.
    struct Scored
    {
        int score;
        const Profile *profile;
    };
    QVector<Scored> scored;
    for (const Profile &candidate : m_profiles) {
        if (candidate.id == source.id) {
            continue;
        }
        const int score = olderScore(sourceProfile, candidate, sourceIsHoliday);
        if (score > 0) {
            scored.push_back(Scored{.score = score, .profile = &candidate});
        }
    }
    std::stable_sort(scored.begin(), scored.end(), [](const Scored &lhs, const Scored &rhs) {
        if (lhs.score != rhs.score) {
            return lhs.score > rhs.score;
        }
        return compareMovieBrowseSortKeys(lhs.profile->browseKey, rhs.profile->browseKey);
    });
    for (const Scored &entry : std::as_const(scored)) {
        if (seen.contains(entry.profile->id)) {
            continue;
        }
        results.push_back(entry.profile->id);
        seen.insert(entry.profile->id);
        if (results.size() == limit) {
            break;
        }
    }
    return results;
}

QVector<MediaItem> browse::SimilarityIndex::similarMovies(const MediaItem &source, int limit) const
{
    QVector<MediaItem> movies;
    for (const QString &id : similarMovieIds(source, limit)) {
        movies.push_back(m_movies.at(m_positionById.value(id)));
    }
    return movies;
}
