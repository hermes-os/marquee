#pragma once

#include <QAbstractListModel>
#include <QByteArray>
#include <QDateTime>
#include <QHash>
#include <QModelIndex>
#include <QString>
#include <QStringList>
#include <QVariant>
#include <QVariantMap>
#include <QVector>

#include <functional>

#include "catalog/MediaItem.hpp"
#include "navigation/FocusNavigator.hpp"

/// The rules behind Home's titled rows, as plain functions over projected
/// items so they can be judged without a window. Every function reads the
/// watch state the items carry, which is the active profile's alone
/// (`CatalogStore::projection` joins one profile's progress), and none of them
/// filters by maturity: the caller hands in only what the profile may see.
///
/// The row order and the Continue Watching, Recently Watched, and Recently
/// Added membership follow `BrowseSnapshotStore.swift:2832-2892` and
/// `:2978-3006`; the places where they differ from it are named at each rule.
namespace home_rows
{
/// At most this many cards per row on Home (`HomeDetailView.swift:668`). The
/// row's own length is still reported, so a header can say how much more the
/// Movies and TV Shows routes hold.
inline constexpr int kCardsPerRow = 8;

/// A title or show not played for this long leaves Continue Watching. Its
/// watch state is kept; only the row forgets it.
inline constexpr int kIdleDays = 365;

/// One card. A movie card opens the movie's details. An episode card stands
/// for its show and opens the show page at that episode. A show card (Recently
/// Added) opens the show page with no episode asked for.
struct Card
{
    // The movie's id, or the id of the episode the card stands for.
    QString mediaId;
    // Empty for a movie.
    QString showName;
    // True when opening the card should land on `mediaId` inside its show.
    bool opensEpisode{false};
    QString title;
    int year{0};
    QString posterPath;
    // "1h 52m" style runtime for a movie, the "S1 E4" label for an episode.
    QString metadata;
    QString formatBadge;

    [[nodiscard]] bool isEpisode() const { return !showName.isEmpty(); }
    [[nodiscard]] bool operator==(const Card &other) const = default;
};

struct Row
{
    QString id;
    QString title;
    // At most `kCardsPerRow` cards.
    QVector<Card> cards;
    // The row's whole length before the card limit.
    int totalCount{0};
};

/// The episode of `episodes` (season and episode order) a viewer continues
/// with, or -1 when the show has nothing to continue: never started, or
/// watched through. An in-progress episode wins over "the one after the last
/// watched": `show_order::upNextIndexOf` (BrowseSnapshotStore.swift:3112-3124)
/// decides, and when it names an episode that is not in progress while another
/// one is, the most recently played in-progress episode is returned instead.
[[nodiscard]] int continueIndexOf(const QVector<MediaItem> &episodes);

/// Movies with a resume point, plus one card per started show for the episode
/// to continue with, even when that episode is not started (the oracle lists
/// it only once it has progress, so a show vanished after each episode).
/// Most recently played first; anything not played within `kIdleDays` of `now`
/// is left out.
[[nodiscard]] QVector<Card> continueWatching(const QVector<MediaItem> &items,
                                             const QDateTime &now);

/// BrowseSnapshotStore.swift:2992-3006: watched movies, and per show its most
/// recently watched episode, newest first. No idle window applies.
[[nodiscard]] QVector<Card> recentlyWatched(const QVector<MediaItem> &items);

/// One card per movie and per show, newest file date first
/// (BrowseSnapshotStore.swift:2871-2874, :2639). A show is dated by its newest
/// episode file, where the oracle uses its first episode, so a new episode
/// brings a long-running show back to the front. Titles fully watched are
/// left out; a show is left out once every episode is watched.
[[nodiscard]] QVector<Card> recentlyAdded(const QVector<MediaItem> &items);

/// BrowseSnapshotStore.swift:3126-3144: one row per decade of at least two
/// movies, newest decade first, each in title order. The row id carries the
/// decade ("decade-1990s") and its title reads "The 1990s".
[[nodiscard]] QVector<Row> decadeRows(const QVector<MediaItem> &items);

/// BrowseSnapshotStore.swift:369-385: up to `play_something::kRowLimit`
/// unwatched movies in the shuffle of `play_something::kHomeSalt`. Movie cards
/// only; Play Something never offers an episode.
[[nodiscard]] QVector<Card> playSomethingCards(const QVector<MediaItem> &items);

/// Home's rows in the released order (BrowseSnapshotStore.swift:2832-2892)
/// for the rows this milestone builds: Continue Watching, Recently Watched,
/// Play Something, Recently Added, a row per decade, All Movies. An empty row
/// is not returned.
[[nodiscard]] QVector<Row> compose(const QVector<MediaItem> &items, const QDateTime &now);
}

/// One row's cards, with the roles the shared poster card reads.
class HomeCardModel final : public QAbstractListModel
{
    Q_OBJECT
public:
    enum Role {
        MediaIdRole = Qt::UserRole + 1,
        TitleRole,
        YearRole,
        PosterUrlRole,
        MetadataRole,
        FormatBadgeRole,
        ShowNameRole
    };
    Q_ENUM(Role)

    explicit HomeCardModel(QObject *parent = nullptr);

    [[nodiscard]] int rowCount(const QModelIndex &parent = QModelIndex{}) const override;
    [[nodiscard]] QVariant data(const QModelIndex &index, int role) const override;
    [[nodiscard]] QHash<int, QByteArray> roleNames() const override;

    void replaceCards(QVector<home_rows::Card> cards);
    [[nodiscard]] const home_rows::Card *cardAt(int column) const;

private:
    QVector<home_rows::Card> m_cards;
};

/// Home's rows as QML sees them. The model owns the items it was given and
/// recomputes every row when the library, the active profile's visible
/// projection, or the watch progress changes, so a surface never decides what
/// belongs in a row.
class HomeRowsModel final : public QAbstractListModel
{
    Q_OBJECT

    Q_PROPERTY(FocusNavigator *focus READ focus CONSTANT)
    /// True while the remote rests on the Play Something capsule in the title
    /// bar, which the released focus tree puts above the rows
    /// (HomeDetailView.swift:47, :1056). While it is true no card is focused.
    Q_PROPERTY(bool playSomethingFocused READ playSomethingFocused NOTIFY playSomethingFocusedChanged)

public:
    enum Role {
        RowIdRole = Qt::UserRole + 1,
        RowTitleRole,
        // The row's whole length, which the row header counts even though
        // Home draws at most `home_rows::kCardsPerRow` cards of it.
        ItemCountRole,
        ItemsRole
    };
    Q_ENUM(Role)

    explicit HomeRowsModel(QObject *parent = nullptr);

    [[nodiscard]] int rowCount(const QModelIndex &parent = QModelIndex{}) const override;
    [[nodiscard]] QVariant data(const QModelIndex &index, int role) const override;
    [[nodiscard]] QHash<int, QByteArray> roleNames() const override;

    [[nodiscard]] FocusNavigator *focus();
    [[nodiscard]] bool playSomethingFocused() const;

    /// The remote's moves over the capsule and the rows as one vertical tree
    /// (HomeDetailView.swift:46-77): Up from the first row reaches the capsule,
    /// Down from it returns to the card it left, and Left and Right on it go
    /// nowhere. Each returns whether the key was spent; Left returns false only
    /// at a row's first card, so the shell can hand the remote to the sidebar.
    Q_INVOKABLE bool moveUp();
    Q_INVOKABLE bool moveDown();
    Q_INVOKABLE bool moveLeft();
    Q_INVOKABLE bool moveRight();
    /// Puts the remote on a card a pointer touched, off the capsule.
    Q_INVOKABLE void focusCard(int row, int column);
    /// The ids one press of Play Something may play, best first: a fresh
    /// shuffle of the unwatched movies the profile may see (AppState.swift:
    /// 238-247). Empty when there is none. It plays nothing itself.
    [[nodiscard]] QStringList playSomethingCandidates() const;
    /// The first of `playSomethingCandidates`, or an empty string.
    [[nodiscard]] Q_INVOKABLE QString playSomethingPick() const;

    /// The card at `row`/`column` as the identity a surface activates by:
    /// `mediaId`, `showName` (empty for a movie), `opensEpisode`, and its
    /// `row` and `column`. An empty
    /// map when the composition no longer holds a card there.
    [[nodiscard]] Q_INVOKABLE QVariantMap cardAt(int row, int column) const;
    /// The same map for the card of `row` carrying `mediaId`, for a pointer
    /// that tapped a card rather than moved the remote to it.
    [[nodiscard]] Q_INVOKABLE QVariantMap cardForId(int row, const QString &mediaId) const;

    /// Replaces the clock the idle window reads, for tests.
    void setClockForTest(std::function<QDateTime()> clock);
    /// Replaces the source of the shuffle salt a press draws, for tests.
    void setPlaySomethingSaltForTest(std::function<QString()> salt);

signals:
    void playSomethingFocusedChanged();

public slots:
    /// Recomposes the rows from the projection the active profile may see.
    void replaceItems(QVector<MediaItem> items);
    /// Applies a recorded resume point to the title carrying `mediaId` and
    /// recomposes, so Continue Watching reflects a viewing without a rescan.
    void applyWatchProgress(const QString &mediaId,
                            qint64 positionMs,
                            qint64 durationMs,
                            bool completed);

private:
    struct RowSlot
    {
        QString id;
        QString title;
        int totalCount{0};
        HomeCardModel *cards{nullptr};
    };

    void recompose();
    void setPlaySomethingFocused(bool focused);
    [[nodiscard]] HomeCardModel *cardModelFor(const QString &rowId);
    [[nodiscard]] QDateTime now() const;

    FocusNavigator m_focus;
    QVector<MediaItem> m_items;
    QVector<RowSlot> m_rows;
    // One card model per row id, kept across compositions so a delegate never
    // holds a model a recomposition deleted.
    QHash<QString, HomeCardModel *> m_cardModels;
    std::function<QDateTime()> m_clock;
    std::function<QString()> m_saltSource;
    bool m_playSomethingFocused{false};
};
