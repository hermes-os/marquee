#include "models/HomeLibraryRows.hpp"

#include "models/BrowseSemantics.hpp"

#include <QCollator>
#include <QList>

#include <algorithm>
#include <functional>
#include <utility>

namespace
{
// BrowseSnapshotStore.swift:3126-3144.
[[nodiscard]] QVector<home_rows::IdRow> decadeIdRows(const QVector<MediaItem> &items)
{
    QHash<int, QVector<MediaItem>> byDecade;
    for (const MediaItem &item : items) {
        if (item.isMovie() && item.year > 0) {
            byDecade[(item.year / 10) * 10].push_back(item);
        }
    }
    QList<int> decades;
    for (auto it = byDecade.cbegin(); it != byDecade.cend(); ++it) {
        if (it.value().size() >= 2) {
            decades.push_back(it.key());
        }
    }
    std::sort(decades.begin(), decades.end(), std::greater<>());

    QCollator collator;
    collator.setCaseSensitivity(Qt::CaseInsensitive);
    QVector<home_rows::IdRow> rows;
    for (const int decade : std::as_const(decades)) {
        QVector<MediaItem> movies = byDecade.value(decade);
        std::stable_sort(movies.begin(), movies.end(),
                         [&collator](const MediaItem &left, const MediaItem &right) {
                             return collator.compare(left.title, right.title) < 0;
                         });
        home_rows::IdRow row{.id = QStringLiteral("decade-%1s").arg(decade),
                             .title = QStringLiteral("The %1s").arg(decade),
                             .mediaIds = {}};
        for (const MediaItem &movie : std::as_const(movies)) {
            row.mediaIds.push_back(movie.id);
        }
        rows.push_back(std::move(row));
    }
    return rows;
}
}

const home_rows::LibraryRows::Built &home_rows::LibraryRows::built(const QVector<MediaItem> &items)
{
    if (m_built) {
        return *m_built;
    }
    Built built;
    // :2876-2881 puts Holiday Movies after Recently Added and before the
    // decades, from the one holiday score the Movies route reads.
    QVector<MediaItem> holidayCandidates;
    for (const MediaItem &item : items) {
        if (!item.isMovie()) {
            continue;
        }
        const int score = browse::holidayScore(item);
        built.holidayScores.insert(item.id, score);
        if (score > 0) {
            holidayCandidates.push_back(item);
        }
    }
    built.holiday = IdRow{.id = QStringLiteral("holiday-movies"),
                          .title = QStringLiteral("Holiday Movies"),
                          .mediaIds = {}};
    if (holidayCandidates.size() >= 2) {
        for (const MediaItem &movie :
             browse::sortedHolidayMovies(std::move(holidayCandidates), built.holidayScores)) {
            built.holiday.mediaIds.push_back(movie.id);
        }
    }
    built.decades = decadeIdRows(items);
    m_built = std::move(built);
    return *m_built;
}

const browse::SimilarityIndex &home_rows::LibraryRows::similarityIndex(const QVector<MediaItem> &movies)
{
    if (!m_index) {
        // Without `built` having run the index scores holiday titles itself.
        m_index = std::make_unique<browse::SimilarityIndex>(
            movies, m_built ? m_built->holidayScores : QHash<QString, int>{});
    }
    return *m_index;
}

void home_rows::LibraryRows::invalidate()
{
    m_built.reset();
    m_index.reset();
}
