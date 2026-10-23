#pragma once

#include <QAbstractListModel>
#include <QByteArray>
#include <QDateTime>
#include <QHash>
#include <QModelIndex>
#include <QString>
#include <QTimer>
#include <QVariant>
#include <QVariantMap>
#include <QVector>

#include <functional>

#include "catalog/MediaItem.hpp"
#include "models/HomeLibraryRows.hpp"
#include "models/TasteModel.hpp"

/// The titles Home's hero carousel spotlights, as plain functions over
/// projected items. Like `home_rows`, every function reads the watch state the
/// items carry (the active profile's alone) and none of them filters by
/// maturity: the caller hands in only what the profile may see, so a Kids
/// profile is never spotlit a title its policy hides.
///
/// The categories and their order follow `HeroSpotlightBuilder.build`
/// (BrowseSnapshotStore.swift:719-830).
namespace hero_spotlight
{
/// :808-811: the builder tops the carousel up with Smart Picks until it holds
/// this many.
inline constexpr int kTargetCount = 5;

/// HeroCarousel.swift:495-497: the carousel advances itself this often.
inline constexpr int kAdvanceIntervalMs = 15'000;

/// One carousel card (BrowseSnapshotStore.swift:235-240 `HeroSpotlight`).
struct Spotlight
{
    // `<category prefix>-<title id>` (:765-770), unique within a carousel.
    QString id;
    QString category;
    // The SF Symbol name the released badge draws (:772-808).
    QString icon;
    // The playable item: the movie, or for a show the episode to continue
    // with. Playing never opens a page in between (HomeDetailView.swift:1010).
    QString mediaId;
    // Empty for a movie.
    QString showName;
    QString title;
    int year{0};
    // "1h 52m", "47m", or empty when the runtime is unknown.
    QString runtime;
    QString formatBadge;
    QString posterPath;
    QString backdropPath;

    [[nodiscard]] bool operator==(const Spotlight &other) const = default;
};

/// The spotlights for `items` in carousel order: Continue Watching, Featured,
/// Holiday Pick, Recently Added, From the Vault, then Smart Picks up to
/// `kTargetCount`. An empty library has none; a category with nobody to show
/// is skipped. No title appears twice, and a movie or a show is one title (a
/// show is its episodes, spotlit once). The score is `home_rows::heroScore`,
/// the one the seasonal rows rank by, plus `taste`'s boost when the profile has
/// finished anything (:788); the Holiday Pick reads `browse::holidayScore`, the
/// one the Movies and Home rows read. `library` keeps what the titles and their
/// metadata alone decide between builds; without it they are made for this
/// call alone.
[[nodiscard]] QVector<Spotlight> build(const QVector<MediaItem> &items,
                                       const QDateTime &now,
                                       home_rows::LibraryRows *library = nullptr,
                                       const browse::TasteModel *taste = nullptr);
}

/// The carousel as QML sees it: the spotlights, which one is in front, and the
/// timer that moves it on. It owns the position so the remote, the pointer,
/// and the timer all move one value, and a surface only draws it.
class HeroSpotlightModel final : public QAbstractListModel
{
    Q_OBJECT

    Q_PROPERTY(int count READ count NOTIFY countChanged)
    /// The slide the carousel is heading to, counted without wrapping so a
    /// card that scrolls off one edge keeps scrolling the same way
    /// (HeroCarousel.swift:19 `scrollPosition`).
    Q_PROPERTY(int position READ position NOTIFY positionChanged)
    /// `position` wrapped into the spotlights (:23-27 `currentIndex`).
    Q_PROPERTY(int currentIndex READ currentIndex NOTIFY positionChanged)
    /// Bumped whenever the spotlights are replaced, so a delegate that reads
    /// one through `spotlightAt` can depend on it.
    Q_PROPERTY(int revision READ revision NOTIFY spotlightsChanged)
    /// True while the carousel is on screen (:228-229 `onAppear`,
    /// `onDisappear`); the timer runs only then.
    Q_PROPERTY(bool active READ active WRITE setActive NOTIFY activeChanged)
    /// True while the remote rests on the carousel; the timer stops then
    /// (:238-244).
    Q_PROPERTY(bool remoteFocused READ remoteFocused WRITE setRemoteFocused NOTIFY remoteFocusedChanged)
    /// :386 withholds the timer under Reduce Motion.
    Q_PROPERTY(bool reduceMotion READ reduceMotion WRITE setReduceMotion NOTIFY reduceMotionChanged)
    Q_PROPERTY(bool timerRunning READ timerRunning NOTIFY timerRunningChanged)
    Q_PROPERTY(int advanceIntervalMs READ advanceIntervalMs CONSTANT)

public:
    enum Role {
        SpotlightIdRole = Qt::UserRole + 1,
        CategoryRole,
        IconRole,
        MediaIdRole,
        ShowNameRole,
        TitleRole,
        YearRole,
        RuntimeRole,
        FormatBadgeRole,
        PosterUrlRole,
        BackdropUrlRole
    };
    Q_ENUM(Role)

    explicit HeroSpotlightModel(QObject *parent = nullptr);

    [[nodiscard]] int rowCount(const QModelIndex &parent = QModelIndex{}) const override;
    [[nodiscard]] QVariant data(const QModelIndex &index, int role) const override;
    [[nodiscard]] QHash<int, QByteArray> roleNames() const override;

    [[nodiscard]] int count() const;
    [[nodiscard]] int position() const;
    [[nodiscard]] int currentIndex() const;
    [[nodiscard]] int revision() const;
    [[nodiscard]] bool active() const;
    [[nodiscard]] bool remoteFocused() const;
    [[nodiscard]] bool reduceMotion() const;
    [[nodiscard]] bool timerRunning() const;
    [[nodiscard]] int advanceIntervalMs() const;

    void setActive(bool active);
    void setRemoteFocused(bool focused);
    void setReduceMotion(bool reduce);

    /// Moves the carousel `delta` slides, wrapping past either end, and
    /// restarts the timer (:300-306 `advance`). Nothing moves with fewer than
    /// two spotlights.
    Q_INVOKABLE void step(int delta);
    /// Moves to `index` by the shorter way round (:308-314 `navigateTo`); a
    /// dot or the remote asks this.
    Q_INVOKABLE void moveTo(int index);

    /// The spotlight `logical` slides along, wrapped (:29-32
    /// `wrappedSpotlight`), as `spotlightId`, `mediaId`, `showName`, `title`,
    /// `year` (text, empty when unknown), `runtime`, `formatBadge`,
    /// `category`, `icon`, `posterUrl`, and `backdropUrl`. Empty when there is
    /// none.
    [[nodiscard]] Q_INVOKABLE QVariantMap spotlightAt(int logical) const;
    /// The spotlight in front.
    [[nodiscard]] Q_INVOKABLE QVariantMap current() const;
    [[nodiscard]] const hero_spotlight::Spotlight *spotlight(int index) const;

    /// Replaces the carousel's contents. A different number of spotlights
    /// returns it to the first (:222-226).
    void replaceSpotlights(QVector<hero_spotlight::Spotlight> spotlights);

    /// Shortens the timer so a test does not wait fifteen seconds.
    void setAdvanceIntervalForTest(int milliseconds);

signals:
    void countChanged();
    void positionChanged();
    void spotlightsChanged();
    void activeChanged();
    void remoteFocusedChanged();
    void reduceMotionChanged();
    void timerRunningChanged();

private:
    void updateTimer();
    void restartTimer();

    QVector<hero_spotlight::Spotlight> m_spotlights;
    QTimer m_timer;
    int m_position{0};
    int m_revision{0};
    int m_interval{hero_spotlight::kAdvanceIntervalMs};
    bool m_active{false};
    bool m_remoteFocused{false};
    bool m_reduceMotion{false};
};
