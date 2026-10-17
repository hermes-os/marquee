#pragma once

#include <QAbstractListModel>
#include <QByteArray>
#include <QHash>
#include <QModelIndex>
#include <QString>
#include <QStringList>
#include <QVariant>
#include <QVariantMap>
#include <QVector>

#include <optional>

#include "catalog/MediaItem.hpp"
#include "navigation/FocusNavigator.hpp"

namespace show_order
{
/// BrowseSnapshotStore.swift:3103-3110: season, then episode number.
void sortEpisodes(QVector<MediaItem> &episodes);

/// BrowseSnapshotStore.swift:3112-3124 over `episodes` in `sortEpisodes`
/// order: the last episode with any watch state decides. In progress, it is
/// up next itself; finished, the one after it is, and a show watched through
/// has none. An untouched show starts at the first episode. Home's rows ask
/// the same question, so a card and the show's own page agree.
[[nodiscard]] int upNextIndexOf(const QVector<MediaItem> &episodes);

/// PlayerController.swift:5-18 over `episodes` in `sortEpisodes` order: the
/// index of the episode that follows the one at `index`, crossing from one
/// season into the next. A second file of the same season and episode as the
/// one at `index` is not "the next one"; and at the end of the show, or for
/// an index outside the list, there is none (-1). The player's Next Episode
/// control, its card and auto-play all ask this, so they agree with Home's
/// and the show page's up-next about what comes after.
[[nodiscard]] int nextEpisodeIndexAfter(const QVector<MediaItem> &episodes, int index);
}

/// One show as the TV surfaces see it (`BrowseShowSummary`,
/// BrowseSnapshotStore.swift:28-45): its episodes in season and episode order,
/// the episode to play next, and the genres its rows are keyed on.
struct ShowSummary
{
    QString showName;
    QVector<MediaItem> episodes;
    // Index into `episodes` of the up-next episode, or -1 when the show has
    // been watched through (BrowseSnapshotStore.swift:3112-3124).
    int upNextIndex{-1};
    int seasonCount{0};
    QStringList genres;

    [[nodiscard]] const MediaItem &representative() const { return episodes.first(); }
    [[nodiscard]] QString posterPath() const { return representative().gridShowPosterPath(); }
    [[nodiscard]] QString upNextLabel() const
    {
        return upNextIndex < 0 ? QString() : episodes.at(upNextIndex).episodeLabel();
    }
};

/// One row of the TV Shows grid. Each row publishes its shows as a list model
/// of show cards; the rows model itself lists the rows in the released order.
class ShowRowModel final : public QAbstractListModel
{
    Q_OBJECT
public:
    enum Role {
        ShowNameRole = Qt::UserRole + 1,
        PosterUrlRole,
        // ShowCard.swift:32-34: "N Seasons", which is both the primary
        // metadata line and the badge on the fallback artwork.
        SeasonLabelRole,
        // ShowCard.swift:23: the up-next episode label in the highlight colour.
        UpNextLabelRole
    };
    Q_ENUM(Role)

    explicit ShowRowModel(QObject *parent = nullptr);

    [[nodiscard]] int rowCount(const QModelIndex &parent = QModelIndex{}) const override;
    [[nodiscard]] QVariant data(const QModelIndex &index, int role) const override;
    [[nodiscard]] QHash<int, QByteArray> roleNames() const override;

    void replaceShows(QVector<ShowSummary> shows);
    [[nodiscard]] Q_INVOKABLE QString showNameAt(int column) const;

private:
    QVector<ShowSummary> m_shows;
};

/// The TV Shows route's rows and every show summary behind them.
/// `BrowseSnapshotStore.swift:3078-3101` groups episodes by show name and
/// `:3050-3076` keys one row per genre, alphabetically, then "All Shows";
/// shows with no genre appear only in All Shows. Genres come from the show
/// title alone (CatalogContentPolicy.swift:374-398) until online metadata
/// exists to name them.
class ShowsModel final : public QAbstractListModel
{
    Q_OBJECT
    /// TVShowsDetailView.swift:147-151: the count in the title bar.
    Q_PROPERTY(int showCount READ showCount NOTIFY showsChanged)
    /// SettingsDetailView.swift:114-115 and HomeDetailView.swift:386: the
    /// episode count the overview tiles show.
    Q_PROPERTY(int episodeCount READ episodeCount NOTIFY showsChanged)
    Q_PROPERTY(FocusNavigator *focus READ focus CONSTANT)

public:
    enum Role {
        RowIdRole = Qt::UserRole + 1,
        RowTitleRole,
        ShowCountRole,
        ShowsRole
    };
    Q_ENUM(Role)

    explicit ShowsModel(QObject *parent = nullptr);

    [[nodiscard]] int rowCount(const QModelIndex &parent = QModelIndex{}) const override;
    [[nodiscard]] QVariant data(const QModelIndex &index, int role) const override;
    [[nodiscard]] QHash<int, QByteArray> roleNames() const override;

    [[nodiscard]] int showCount() const;
    [[nodiscard]] int episodeCount() const;
    [[nodiscard]] FocusNavigator *focus();

    /// The show at `row`/`column` of the grid, or an empty name when the
    /// composition no longer holds one there.
    [[nodiscard]] Q_INVOKABLE QString showNameAt(int row, int column) const;

    /// The episode carrying `mediaId`, or nothing for a movie or a stale id.
    [[nodiscard]] std::optional<MediaItem> episodeForId(const QString &mediaId) const;

    /// PlayerController.swift:5-18: the episode that follows `mediaId` in its
    /// show's season-then-episode order (`show_order::nextEpisodeIndexAfter`),
    /// or an empty id at the end of the show or for a movie.
    [[nodiscard]] Q_INVOKABLE QString nextEpisodeId(const QString &mediaId) const;

    /// Asks the next show page that opens to land on the episode carrying
    /// `mediaId`. A Home card for an episode opens its show this way.
    Q_INVOKABLE void requestEpisodeFocus(const QString &mediaId);
    /// Hands the request to the page of `showName` once, as the season and id
    /// of the episode it names, or an empty map when there is none or it
    /// belongs to another show. Any request is spent either way.
    [[nodiscard]] Q_INVOKABLE QVariantMap takeEpisodeFocus(const QString &showName);

    /// The show's summary, or nothing when the projection no longer holds it.
    [[nodiscard]] const ShowSummary *summary(const QString &showName) const;
    [[nodiscard]] const QVector<ShowSummary> &summaries() const;

    /// The facts the show detail surface draws: the seasons, the episodes of
    /// one season, the up-next episode and the artwork. Composed here so the
    /// grid card and the detail page never disagree about a show.
    [[nodiscard]] Q_INVOKABLE QVariantMap showDetails(const QString &showName) const;
    /// BrowseSnapshotStore.swift:173-179, :2220-2242: up to `limit` other
    /// shows ranked by franchise, shared genres, and decade, for "More Like
    /// This". The caller owns the returned row model.
    [[nodiscard]] Q_INVOKABLE ShowRowModel *similarShows(const QString &showName,
                                                          int limit = 10) const;
    /// The episodes of `season` in order, each as the map an episode row
    /// binds to.
    [[nodiscard]] Q_INVOKABLE QVariantList episodesOf(const QString &showName,
                                                      int season) const;

public slots:
    /// Recomposes every show from a fresh projection; movies are ignored.
    void replaceItems(QVector<MediaItem> items);
    /// Re-derives up-next for the show carrying `mediaId` after progress is
    /// recorded, the way `BrowseSnapshotStore.swift:2718-2736` refreshes
    /// summaries without rebuilding them.
    void applyWatchProgress(const QString &mediaId,
                            qint64 positionMs,
                            qint64 durationMs,
                            bool completed);

signals:
    void showsChanged();
    /// A show's up-next changed without the rows changing; open detail pages
    /// re-read their facts on it.
    void showProgressChanged(const QString &showName);

private:
    struct Row
    {
        QString id;
        QString title;
        ShowRowModel *shows{nullptr};
    };

    void recompose();

    FocusNavigator m_focus;
    QVector<ShowSummary> m_summaries;
    QVector<Row> m_rows;
    QVector<ShowRowModel *> m_rowModels;
    int m_episodeCount{0};
    QString m_requestedEpisodeId;
};
