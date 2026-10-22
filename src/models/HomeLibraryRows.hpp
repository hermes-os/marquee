#pragma once

#include <QHash>
#include <QString>
#include <QVector>

#include <memory>
#include <optional>

#include "catalog/MediaItem.hpp"
#include "models/HomeRowIds.hpp"
#include "models/SimilarityIndex.hpp"

namespace home_rows
{
/// What Home's rows read from the titles and their metadata alone: nothing
/// here depends on the watch state, the day or the clock. A position recorded
/// during playback changes none of it, and scoring the holiday words of every
/// overview or ranking the library against itself is far too much to repeat
/// for every progress record. The owner calls `invalidate` when the items are
/// replaced (the projection carries the metadata) and `built` and
/// `similarityIndex` build again only then.
class LibraryRows
{
public:
    struct Built
    {
        // `browse::holidayScore` by movie id.
        QHash<QString, int> holidayScores;
        // Holiday Movies in the released order; no ids below two movies.
        IdRow holiday;
        // One row per decade of at least two movies, newest decade first,
        // each in title order ("decade-1990s").
        QVector<IdRow> decades;
    };

    [[nodiscard]] const Built &built(const QVector<MediaItem> &items);
    /// The index over `movies` (the movies of the items `built` was given),
    /// made when first asked for: a library with no history never needs it.
    [[nodiscard]] const browse::SimilarityIndex &similarityIndex(const QVector<MediaItem> &movies);
    void invalidate();

private:
    std::optional<Built> m_built;
    std::unique_ptr<browse::SimilarityIndex> m_index;
};
}
