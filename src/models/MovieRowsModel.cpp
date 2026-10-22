#include "models/MovieRowsModel.hpp"

#include "models/BrowseSemantics.hpp"
#include "profiles/ContentPolicy.hpp"

#include <QAbstractItemModel>
#include <QCollator>
#include <QHash>
#include <QLatin1String>
#include <QSet>
#include <QStringList>

#include <algorithm>
#include <utility>

namespace
{
struct KeyedItem
{
    browse::MovieBrowseSortKey key;
    int holidayScore{0};
    QStringList genres;
    MediaItem item;
};

struct ComposedRow
{
    QString id;
    QString title;
    QVector<MediaItem> items;
};

[[nodiscard]] const QCollator &localizedCollator()
{
    static const QCollator collator = [] {
        QCollator built;
        built.setCaseSensitivity(Qt::CaseInsensitive);
        return built;
    }();
    return collator;
}

/// BrowseSnapshotStore.swift:3008-3048 `buildMovieRows`.
[[nodiscard]] QVector<ComposedRow> composeRows(QVector<MediaItem> movies)
{
    // :3009
    if (movies.isEmpty()) {
        return {};
    }

    // Each key, score and genre list is composed once per title rather than
    // inside the comparison, because folding and tokenising a title is far
    // too expensive to repeat for every comparison a sort makes
    // (:2022-2025).
    QVector<KeyedItem> keyed;
    keyed.reserve(movies.size());
    QHash<QString, int> holidayScores;
    for (MediaItem &item : movies) {
        const int score = browse::holidayScore(item);
        holidayScores.insert(item.id, score);
        keyed.push_back(KeyedItem{.key = browse::movieBrowseSortKey(item),
                                  .holidayScore = score,
                                  .genres = content_policy::displayGenresOf(item),
                                  .item = std::move(item)});
    }
    // :3020 `sortedMoviesForBrowsing`; equal keys keep catalog order.
    std::stable_sort(keyed.begin(), keyed.end(),
                     [](const KeyedItem &left, const KeyedItem &right) {
                         return browse::compareMovieBrowseSortKeys(left.key, right.key);
                     });

    // :3010-3018 groups by genre, with "Other" holding a title that names none.
    // The key is the genre as spelled, so "Sci-Fi" and "Science Fiction" are two
    // rows. Walking the already sorted titles fills each row in browse order,
    // which is what :3040 gets by filtering `sortedAll`.
    QHash<QString, QVector<qsizetype>> byGenre;
    QStringList genreOrder;
    for (qsizetype index = 0; index < keyed.size(); ++index) {
        const QStringList &genres = keyed.at(index).genres;
        const QStringList named = genres.isEmpty() ? QStringList{QStringLiteral("Other")} : genres;
        for (const QString &genre : named) {
            if (!byGenre.contains(genre)) {
                genreOrder.push_back(genre);
            }
            byGenre[genre].push_back(index);
        }
    }

    QVector<ComposedRow> rows;

    // :3022-3028 composes Holiday Movies before the rest, and only once at
    // least two titles qualify. The titles are copied, not moved, because
    // :3046 builds All Movies from every movie, so a holiday title is shown
    // in both rows.
    QVector<MediaItem> holidayCandidates;
    for (const KeyedItem &entry : std::as_const(keyed)) {
        if (entry.holidayScore > 0) {
            holidayCandidates.push_back(entry.item);
        }
    }
    QVector<MediaItem> holidayMovies =
        browse::sortedHolidayMovies(std::move(holidayCandidates), holidayScores);
    if (holidayMovies.size() >= 2) {
        rows.push_back(ComposedRow{.id = QStringLiteral("holiday-movies"),
                                   .title = QStringLiteral("Holiday Movies"),
                                   .items = std::move(holidayMovies)});
    }

    // :3030-3044: a row per genre in case-insensitive order, skipping "Other"
    // and a genre that holds every movie.
    std::stable_sort(genreOrder.begin(), genreOrder.end(),
                     [](const QString &left, const QString &right) {
                         return localizedCollator().compare(left, right) < 0;
                     });
    QSet<QString> allIds;
    for (const KeyedItem &entry : std::as_const(keyed)) {
        allIds.insert(entry.item.id);
    }
    for (const QString &genre : std::as_const(genreOrder)) {
        const QVector<qsizetype> &members = byGenre.value(genre);
        if (genre == QLatin1String("Other") || members.isEmpty()) {
            continue;
        }
        QSet<QString> memberIds;
        for (const qsizetype index : members) {
            memberIds.insert(keyed.at(index).item.id);
        }
        if (memberIds == allIds) {
            continue;
        }
        QVector<MediaItem> items;
        items.reserve(members.size());
        for (const qsizetype index : members) {
            items.push_back(keyed.at(index).item);
        }
        rows.push_back(ComposedRow{.id = QStringLiteral("genre-") + genre,
                                   .title = genre,
                                   .items = std::move(items)});
    }

    // :3046.
    QVector<MediaItem> sorted;
    sorted.reserve(keyed.size());
    for (KeyedItem &entry : keyed) {
        sorted.push_back(std::move(entry.item));
    }
    rows.push_back(ComposedRow{.id = QStringLiteral("all-movies"),
                               .title = QStringLiteral("All Movies"),
                               .items = std::move(sorted)});
    return rows;
}
}

MovieRowsModel::MovieRowsModel(QObject *parent)
    : QAbstractListModel(parent),
      m_focus(this)
{
}

int MovieRowsModel::rowCount(const QModelIndex &parent) const
{
    return parent.isValid() ? 0 : static_cast<int>(m_rows.size());
}

QVariant MovieRowsModel::data(const QModelIndex &index, int role) const
{
    if (!index.isValid() || index.row() < 0 || index.row() >= m_rows.size()) {
        return {};
    }

    const Row &row = m_rows.at(index.row());

    switch (role) {
    case RowIdRole:
        return row.id;
    case RowTitleRole:
        return row.title;
    case ItemCountRole:
        return row.items->rowCount();
    case ItemsRole:
        return QVariant::fromValue(static_cast<QAbstractItemModel *>(row.items));
    default:
        return {};
    }
}

QHash<int, QByteArray> MovieRowsModel::roleNames() const
{
    return {{RowIdRole, "rowId"},
            {RowTitleRole, "rowTitle"},
            {ItemCountRole, "itemCount"},
            {ItemsRole, "items"}};
}

int MovieRowsModel::titleCount() const
{
    return m_titleCount;
}

FocusNavigator *MovieRowsModel::focus()
{
    return &m_focus;
}

QString MovieRowsModel::mediaIdAt(int row, int column) const
{
    if (row < 0 || row >= m_rows.size()) {
        return {};
    }
    const LibraryModel *items = m_rows.at(row).items;
    if (column < 0 || column >= items->rowCount()) {
        return {};
    }
    return items->data(items->index(column, 0), LibraryModel::IdRole).toString();
}

void MovieRowsModel::replaceItems(QVector<MediaItem> items)
{
    const int previousTitleCount = m_titleCount;
    m_titleCount = static_cast<int>(items.size());
    QVector<ComposedRow> composed = composeRows(std::move(items));

    // A row's items model outlives the composition that dropped its row, so a
    // row restored by a later scan finds its model rather than a dangling
    // binding in a delegate the reset has not torn down yet.
    while (m_rowItems.size() < composed.size()) {
        m_rowItems.push_back(new LibraryModel(this));
    }

    beginResetModel();
    m_rows.clear();
    m_rows.reserve(composed.size());
    for (qsizetype index = 0; index < composed.size(); ++index) {
        LibraryModel *itemsModel = m_rowItems.at(index);
        itemsModel->replaceItems(std::move(composed[index].items));
        m_rows.push_back(Row{.id = std::move(composed[index].id),
                             .title = std::move(composed[index].title),
                             .items = itemsModel});
    }
    endResetModel();

    // A shorter or emptied composition must not leave the remote addressing a
    // card that is gone, which is what MoviesDetailView.swift:401-419 keeps
    // true by clamping on every composition change.
    QVector<int> rowLengths;
    rowLengths.reserve(m_rows.size());
    for (const Row &row : std::as_const(m_rows)) {
        rowLengths.push_back(row.items->rowCount());
    }
    m_focus.setRows(std::move(rowLengths));

    if (m_titleCount != previousTitleCount) {
        emit titleCountChanged();
    }
}

void MovieRowsModel::applyWatchProgress(const QString &mediaId,
                                        qint64 positionMs,
                                        qint64 durationMs,
                                        quint64 sequence)
{
    for (const Row &row : std::as_const(m_rows)) {
        row.items->applyWatchProgress(mediaId, positionMs, durationMs, sequence);
    }
}
