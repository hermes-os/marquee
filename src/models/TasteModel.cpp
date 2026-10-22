#include "models/TasteModel.hpp"

#include "models/BrowseSemantics.hpp"
#include "profiles/ContentPolicy.hpp"

#include <algorithm>

namespace
{
// :359-363: weights accumulate per normalized name; a name that normalizes to
// nothing carries none.
void addWeight(double weight, const QString &name, QHash<QString, double> &weights)
{
    const QString key = browse::normalizedText(name);
    if (key.isEmpty()) {
        return;
    }
    weights[key] += weight;
}

[[nodiscard]] double voteAverageOf(const MediaItem &item)
{
    return item.metadata ? item.metadata->voteAverage.value_or(0.0) : 0.0;
}
}

qint64 browse::effectiveDateMs(const MediaItem &item)
{
    return item.modifiedAt.isValid() ? item.modifiedAt.toMSecsSinceEpoch() : 0;
}

std::optional<browse::TasteModel> browse::TasteModel::build(const QVector<MediaItem> &items)
{
    TasteModel model;
    for (const MediaItem &item : items) {
        if (item.watched) {
            model.m_completedIds.insert(item.id);
        }
    }
    if (model.m_completedIds.isEmpty()) {
        return std::nullopt;
    }

    // :267-280. Every finished title adds, an episode as much as a film, so a
    // show watched through weighs once per episode.
    for (const MediaItem &item : items) {
        if (!item.watched) {
            continue;
        }
        for (const QString &genre : content_policy::displayGenresOf(item)) {
            addWeight(80, genre, model.m_genres);
        }
        if (!item.metadata) {
            continue;
        }
        if (!item.metadata->director.isEmpty()) {
            addWeight(90, item.metadata->director, model.m_directors);
        }
        const qsizetype castCount = std::min<qsizetype>(item.metadata->cast.size(), 5);
        for (qsizetype index = 0; index < castCount; ++index) {
            addWeight(std::max(30.0, 75.0 - static_cast<double>(index) * 10.0),
                      item.metadata->cast.at(index).name, model.m_cast);
        }
        for (const MetadataKeyword &keyword : item.metadata->keywords) {
            addWeight(95, keyword.name, model.m_keywords);
        }
    }
    return model;
}

bool browse::TasteModel::isCompleted(const MediaItem &item) const
{
    return m_completedIds.contains(item.id);
}

bool browse::TasteModel::isUnwatched(const MediaItem &item) const
{
    return !isCompleted(item) && !item.watched;
}

QVector<MediaItem> browse::TasteModel::completedSeeds(const QVector<MediaItem> &items,
                                                      int limit) const
{
    QVector<MediaItem> seeds;
    for (const MediaItem &item : items) {
        if (isCompleted(item)) {
            seeds.push_back(item);
        }
    }
    std::stable_sort(seeds.begin(), seeds.end(), [](const MediaItem &lhs, const MediaItem &rhs) {
        const qint64 lhsDate = effectiveDateMs(lhs);
        const qint64 rhsDate = effectiveDateMs(rhs);
        if (lhsDate != rhsDate) {
            return lhsDate > rhsDate;
        }
        return compareMoviesForBrowsing(lhs, rhs);
    });
    if (seeds.size() > limit) {
        seeds.resize(limit);
    }
    return seeds;
}

QVector<MediaItem> browse::TasteModel::rankedCandidates(const QVector<MediaItem> &items,
                                                        int limit) const
{
    // The browse order is the last tie-break and its key is costly, so each
    // title's key and score are composed once, not once per comparison.
    struct Ranked
    {
        const MediaItem *item;
        double affinity;
        double vote;
        qint64 date;
        MovieBrowseSortKey key;
    };
    QVector<Ranked> ranked;
    ranked.reserve(items.size());
    for (const MediaItem &item : items) {
        ranked.push_back(Ranked{.item = &item,
                                .affinity = affinityScore(item),
                                .vote = voteAverageOf(item),
                                .date = effectiveDateMs(item),
                                .key = movieBrowseSortKey(item)});
    }
    std::stable_sort(ranked.begin(), ranked.end(), [](const Ranked &lhs, const Ranked &rhs) {
        if (lhs.affinity != rhs.affinity) {
            return lhs.affinity > rhs.affinity;
        }
        if (lhs.vote != rhs.vote) {
            return lhs.vote > rhs.vote;
        }
        if (lhs.date != rhs.date) {
            return lhs.date > rhs.date;
        }
        return compareMovieBrowseSortKeys(lhs.key, rhs.key);
    });
    QVector<MediaItem> result;
    for (const Ranked &entry : std::as_const(ranked)) {
        if (result.size() == limit) {
            break;
        }
        result.push_back(*entry.item);
    }
    return result;
}

double browse::TasteModel::affinityScore(const MediaItem &item) const
{
    double score = 0.0;
    for (const QString &genre : content_policy::displayGenresOf(item)) {
        score += m_genres.value(normalizedText(genre), 0.0);
    }
    if (!item.metadata) {
        return score;
    }
    if (!item.metadata->director.isEmpty()) {
        score += m_directors.value(normalizedText(item.metadata->director), 0.0);
    }
    for (const CastMember &member : item.metadata->cast) {
        score += m_cast.value(normalizedText(member.name), 0.0);
    }
    for (const MetadataKeyword &keyword : item.metadata->keywords) {
        score += m_keywords.value(normalizedText(keyword.name), 0.0);
    }
    return score;
}

double browse::TasteModel::clampedAffinityScore(const MediaItem &item) const
{
    return std::min(kAffinityCeiling, affinityScore(item));
}
