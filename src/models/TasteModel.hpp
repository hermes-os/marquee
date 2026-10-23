#pragma once

#include <QHash>
#include <QSet>
#include <QString>
#include <QVector>

#include <optional>

#include "catalog/MediaItem.hpp"

namespace browse
{
/// What a profile's finished titles say about its taste, as
/// `BrowseTasteProfile` (BrowseSnapshotStore.swift:53-59) and
/// `BrowseTasteModel` (:244-364) release it.
///
/// The released app builds the profile from the active profile's completion
/// ledger (`LibraryState.currentTasteProfile`, LibraryState.swift:580-584) and
/// rebuilds the rows whenever a recorded viewing or a profile change refreshes
/// them (:588-655). v3 reads the same fact from the items it is handed: a
/// projection carries one profile's progress, so `watched` is that profile's
/// ledger, and the model of two profiles over one library differs.
///
/// One difference, from what v3 stores. The released ledger keeps a title that
/// was finished once however it is played afterwards; a v3 title replayed
/// part-way is no longer watched and leaves the model (issues.md). The
/// released model only reads titles the profile may see, as this one does.
class TasteModel
{
public:
    /// :254-286. Absent where the released initializer returns nil: nothing in
    /// `items` (movies and episodes alike) is watched.
    [[nodiscard]] static std::optional<TasteModel> build(const QVector<MediaItem> &items);

    /// :288-290 `isCompleted`.
    [[nodiscard]] bool isCompleted(const MediaItem &item) const;
    /// :292-294 `isUnwatched`.
    [[nodiscard]] bool isUnwatched(const MediaItem &item) const;

    /// :296-307: the finished titles of `items`, newest file first, browse
    /// order within one date, at most `limit`.
    [[nodiscard]] QVector<MediaItem> completedSeeds(const QVector<MediaItem> &items,
                                                    int limit) const;

    /// :309-324: `items` by affinity, then vote average, then newest file, then
    /// browse order; at most `limit`.
    [[nodiscard]] QVector<MediaItem> rankedCandidates(const QVector<MediaItem> &items,
                                                      int limit) const;

    /// :338-353: the sum of the weights of the title's genres, director, cast
    /// and keywords. It grows with the watch history and has no upper bound.
    [[nodiscard]] double affinityScore(const MediaItem &item) const;

    /// :334-336 and :245. Everything that mixes affinity with other signals
    /// ranks against this ceiling.
    static constexpr double kAffinityCeiling = 260.0;
    [[nodiscard]] double clampedAffinityScore(const MediaItem &item) const;

    /// :326-329: what the Home hero adds to the score of a title the profile
    /// has not finished.
    [[nodiscard]] double heroBoost(const MediaItem &item) const;

private:
    TasteModel() = default;

    QSet<QString> m_completedIds;
    QHash<QString, double> m_genres;
    QHash<QString, double> m_directors;
    QHash<QString, double> m_cast;
    QHash<QString, double> m_keywords;
};

/// MediaItem.effectiveDate (`fileModificationDate ?? dateAdded`) in
/// milliseconds; a title with no recorded file date is the oldest.
[[nodiscard]] qint64 effectiveDateMs(const MediaItem &item);
}
