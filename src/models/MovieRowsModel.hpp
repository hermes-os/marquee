#pragma once

#include <QAbstractListModel>
#include <QByteArray>
#include <QHash>
#include <QModelIndex>
#include <QString>
#include <QVariant>
#include <QVector>

#include "catalog/MediaItem.hpp"
#include "models/LibraryModel.hpp"
#include "navigation/FocusNavigator.hpp"

/// The Movies route's rows. `BrowseSnapshotStore.swift:3008-3048` composes
/// `movieRows` as a "Holiday Movies" row, then one row per genre, then "All
/// Movies" in browse order, dropping the "Other" bucket and any genre row that
/// holds the whole library. `:2073-2101` recognizes a holiday title from its
/// text alone -- a keyword such as "christmas", or a named film such as Home
/// Alone or Elf -- so that row is composed here from the titles the catalog
/// already holds, and appears once at least two qualify. The v3 catalog models
/// no genre, so every title still falls in the dropped "Other" bucket and the
/// genre rows arrive with the metadata milestone that gives them their input,
/// not by inventing one here.
///
/// Each row publishes its items as a `LibraryModel`, so a row's cards read the
/// same projected roles the library grid reads.
class MovieRowsModel final : public QAbstractListModel
{
    Q_OBJECT

    Q_PROPERTY(int titleCount READ titleCount NOTIFY titleCountChanged)
    Q_PROPERTY(FocusNavigator *focus READ focus CONSTANT)

public:
    enum Role {
        RowIdRole = Qt::UserRole + 1,
        RowTitleRole,
        // The row's whole length, which the released row header counts even
        // while fewer cards are rendered.
        ItemCountRole,
        ItemsRole
    };
    Q_ENUM(Role)

    explicit MovieRowsModel(QObject *parent = nullptr);

    [[nodiscard]] int rowCount(const QModelIndex &parent = QModelIndex{}) const override;
    [[nodiscard]] QVariant data(const QModelIndex &index, int role) const override;
    [[nodiscard]] QHash<int, QByteArray> roleNames() const override;

    /// Every movie the projection holds, which is what the surface's own
    /// "N titles" count and its empty state answer to.
    /// `MoviesDetailView.swift:113-121` counts `filteredLibraryItems` rather
    /// than the composed rows.
    [[nodiscard]] int titleCount() const;

    /// The row and column the remote is on. Owned here because a projection
    /// that shortens or empties a row must not leave focus addressing a card
    /// that is gone, which is what `MoviesDetailView.swift:401-419` keeps true
    /// by clamping on every composition change.
    [[nodiscard]] FocusNavigator *focus();

    /// The identity of the card at `row`/`column`, or an empty string when the
    /// composition no longer holds one there. Surfaces activate by identity so
    /// a projection replaced under them cannot open the wrong title.
    [[nodiscard]] Q_INVOKABLE QString mediaIdAt(int row, int column) const;

public slots:
    /// Recomposes the rows from a fresh projection.
    void replaceItems(QVector<MediaItem> items);

    /// Applies a recorded runtime and resume point to whichever rows carry the
    /// title, so a visible card refreshes its metadata without a rescan.
    void applyWatchProgress(const QString &mediaId,
                            qint64 positionMs,
                            qint64 durationMs,
                            quint64 sequence);

signals:
    void titleCountChanged();

private:
    struct Row
    {
        QString id;
        QString title;
        LibraryModel *items{nullptr};
    };

    FocusNavigator m_focus;
    QVector<Row> m_rows;
    // One items model per row slot, kept across compositions so a row a scan
    // dropped and a later scan restored reuses its model rather than leaving a
    // delegate bound to a deleted one.
    QVector<LibraryModel *> m_rowItems;
    int m_titleCount{0};
};
