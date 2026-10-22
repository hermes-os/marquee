#include "models/MovieRowsModel.hpp"

#include "models/BrowseSemantics.hpp"

#include <QAbstractItemModel>
#include <QChar>
#include <QLatin1Char>
#include <QLatin1String>
#include <QStringList>

#include <algorithm>
#include <limits>
#include <utility>

namespace
{
// BrowseSnapshotStore.swift:2016-2042: browse order is the title's family, then
// its year, then its title, with an undated title sorted after its dated
// siblings.
struct BrowseSortKey
{
    QString family;
    int year{0};
    QString title;
};

[[nodiscard]] BrowseSortKey browseSortKeyFor(const MediaItem &item)
{
    const QString family = browse::franchiseKey(item.title);
    return BrowseSortKey{.family = family.isEmpty() ? browse::normalizedText(item.title) : family,
                         .year = item.year > 0 ? item.year : std::numeric_limits<int>::max(),
                         .title = item.title};
}

[[nodiscard]] bool isBefore(const BrowseSortKey &left, const BrowseSortKey &right)
{
    if (const int family = QString::compare(left.family, right.family, Qt::CaseInsensitive);
        family != 0) {
        return family < 0;
    }
    if (left.year != right.year) {
        return left.year < right.year;
    }
    return QString::compare(left.title, right.title, Qt::CaseInsensitive) < 0;
}

struct KeyedItem
{
    BrowseSortKey key;
    int holidayScore{0};
    MediaItem item;
};

struct ComposedRow
{
    QString id;
    QString title;
    QVector<MediaItem> items;
};

/// The rows the released Movies surface composes from `movies`. See the header
/// for which of them the v3 catalog can still not compose.
[[nodiscard]] QVector<ComposedRow> composeRows(QVector<MediaItem> movies)
{
    if (movies.isEmpty()) {
        return {};
    }

    // Each key is composed once per title rather than inside the comparison,
    // because folding and tokenising a title is far too expensive to repeat
    // for every comparison a sort makes. The holiday signal folds the same
    // title, so it is scored in the same pass.
    QVector<KeyedItem> keyed;
    keyed.reserve(movies.size());
    for (MediaItem &item : movies) {
        keyed.push_back(KeyedItem{.key = browseSortKeyFor(item),
                                  .holidayScore = browse::holidayScore(item.title),
                                  .item = std::move(item)});
    }
    std::stable_sort(keyed.begin(), keyed.end(),
                     [](const KeyedItem &left, const KeyedItem &right) {
                         return isBefore(left.key, right.key);
                     });

    // BrowseSnapshotStore.swift:2063-2071 orders the holiday row by the
    // strongest signal first and by browse order within one score, which the
    // browse-ordered pass above already holds. The titles are copied rather
    // than moved because :3020 and :3046 build All Movies from every movie,
    // so a holiday title is shown in both rows.
    QVector<KeyedItem> holidayKeyed;
    for (const KeyedItem &keyedItem : std::as_const(keyed)) {
        if (keyedItem.holidayScore > 0) {
            holidayKeyed.push_back(keyedItem);
        }
    }
    std::stable_sort(holidayKeyed.begin(), holidayKeyed.end(),
                     [](const KeyedItem &left, const KeyedItem &right) {
                         return left.holidayScore > right.holidayScore;
                     });

    QVector<MediaItem> sorted;
    sorted.reserve(keyed.size());
    for (KeyedItem &keyedItem : keyed) {
        sorted.push_back(std::move(keyedItem.item));
    }

    QVector<ComposedRow> rows;
    // :3026-3028 composes Holiday Movies before the rest, and only once at
    // least two titles qualify.
    if (holidayKeyed.size() >= 2) {
        QVector<MediaItem> holidayItems;
        holidayItems.reserve(holidayKeyed.size());
        for (KeyedItem &keyedItem : holidayKeyed) {
            holidayItems.push_back(std::move(keyedItem.item));
        }
        rows.push_back(ComposedRow{.id = QStringLiteral("holiday-movies"),
                                   .title = QStringLiteral("Holiday Movies"),
                                   .items = std::move(holidayItems)});
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
