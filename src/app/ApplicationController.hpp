#pragma once

#include <QColor>
#include <QObject>
#include <QPointer>
#include <QSet>
#include <QStringList>
#include <QThread>
#include <QUrl>
#include <QVariantMap>
#include <QVector>

#include <functional>
#include <memory>
#include <optional>

#include "catalog/LibraryRoot.hpp"
#include "models/HomeRowsModel.hpp"
#include "models/LibraryModel.hpp"
#include "models/MovieRowsModel.hpp"
#include "models/ShowsModel.hpp"
#include "navigation/NavigationController.hpp"
#include "playback/AutoPlayPolicy.hpp"
#include "playback/PlayerController.hpp"
#include "profiles/ProfileStore.hpp"
#include "search/SearchSession.hpp"
#include "settings/SettingsSession.hpp"
#include "settings/SettingsStore.hpp"
#include "support/FileIdentity.hpp"

class CatalogWorker;

class ApplicationController final : public QObject
{
    Q_OBJECT

    Q_PROPERTY(NavigationController *navigation READ navigation CONSTANT)
    Q_PROPERTY(SettingsStore *settings READ settings CONSTANT)
    Q_PROPERTY(PlayerController *player READ player CONSTANT)
    Q_PROPERTY(LibraryModel *library READ library CONSTANT)
    Q_PROPERTY(MovieRowsModel *movieRows READ movieRows CONSTANT)
    /// Home's titled rows: Continue Watching, Recently Watched, Recently
    /// Added, the decades, and All Movies.
    Q_PROPERTY(HomeRowsModel *homeRows READ homeRows CONSTANT)
    Q_PROPERTY(ShowsModel *shows READ shows CONSTANT)
    Q_PROPERTY(ProfileStore *profiles READ profiles CONSTANT)
    /// `AppState.swift` owns one `searchSession` for the search route;
    /// `ContentView.swift:501` hands it to the view.
    Q_PROPERTY(SearchSession *search READ search CONSTANT)
    /// The Settings route's scan status, cache, and maintenance state.
    Q_PROPERTY(SettingsSession *settingsSession READ settingsSession CONSTANT)
    /// The profile the shell is showing, as `Marquee/Services/ProfileSession.swift:21`
    /// publishes `activeProfile`. Empty fields until a profile has been chosen.
    Q_PROPERTY(QString activeProfileId READ activeProfileId NOTIFY activeProfileChanged)
    Q_PROPERTY(QString activeProfileName READ activeProfileName NOTIFY activeProfileChanged)
    Q_PROPERTY(QString activeProfileAvatarIcon READ activeProfileAvatarIcon NOTIFY activeProfileChanged)
    Q_PROPERTY(QColor activeProfileAvatarColor READ activeProfileAvatarColor NOTIFY activeProfileChanged)
    Q_PROPERTY(int activeProfileMaturity READ activeProfileMaturity NOTIFY activeProfileChanged)
    /// `Marquee/ContentView.swift:25-27`: the kids palette follows a kids
    /// profile.
    Q_PROPERTY(bool kidsMode READ kidsMode NOTIFY activeProfileChanged)
    /// `Marquee/AppState.swift:266-278` and `:280-305`: the picker fades out
    /// over the exit transition after a choice, and only then leaves the
    /// screen. Set while that fade runs.
    Q_PROPERTY(bool profileExitInFlight READ profileExitInFlight NOTIFY profileExitInFlightChanged)
    Q_PROPERTY(QString profileExitSelectionId READ profileExitSelectionId NOTIFY profileExitInFlightChanged)
    Q_PROPERTY(bool startFullscreen READ startFullscreen WRITE setStartFullscreen NOTIFY startFullscreenChanged)
    /// Whether a library scan is in flight, which is what
    /// `Marquee/Catalog/LibraryState.swift:343` and `:412` publish as
    /// `isScanning` and what Home draws its scan state and its header capsule
    /// from.
    Q_PROPERTY(bool scanning READ scanning NOTIFY scanningChanged)
    /// PlayerView.swift:64 resolves the startup overlay's backdrop as the
    /// playing title's display backdrop first, then its display poster. This
    /// is that source: the show backdrop, season poster chain, or title
    /// artwork the projection holds for the playing catalog title, or an
    /// empty URL for a loose file with no catalog row.
    Q_PROPERTY(QUrl playerArtworkUrl READ playerArtworkUrl NOTIFY playerArtworkUrlChanged)
    /// The episode that follows the one playing, in the order Home and the
    /// show page use: `mediaId`, `label` ("S1 E2") and `title`. Empty for a
    /// film, a loose file and the last episode, so the player's Next Episode
    /// control and card are absent there.
    Q_PROPERTY(QVariantMap nextEpisode READ nextEpisode NOTIFY nextEpisodeChanged)
    Q_PROPERTY(bool hasNextEpisode READ hasNextEpisode NOTIFY nextEpisodeChanged)
    Q_PROPERTY(QString errorTitle READ errorTitle NOTIFY errorChanged)
    Q_PROPERTY(QString errorMessage READ errorMessage NOTIFY errorChanged)
    Q_PROPERTY(bool hasError READ hasError NOTIFY errorChanged)
    Q_PROPERTY(QString version READ version CONSTANT)

public:
    explicit ApplicationController(QObject *parent = nullptr);
    ~ApplicationController() override;

    [[nodiscard]] NavigationController *navigation();
    [[nodiscard]] SettingsStore *settings();
    [[nodiscard]] PlayerController *player();
    [[nodiscard]] LibraryModel *library();
    [[nodiscard]] MovieRowsModel *movieRows();
    [[nodiscard]] HomeRowsModel *homeRows();
    [[nodiscard]] ShowsModel *shows();
    [[nodiscard]] ProfileStore *profiles();
    [[nodiscard]] SearchSession *search();
    [[nodiscard]] SettingsSession *settingsSession();

    [[nodiscard]] QString activeProfileId() const;
    [[nodiscard]] QString activeProfileName() const;
    [[nodiscard]] QString activeProfileAvatarIcon() const;
    [[nodiscard]] QColor activeProfileAvatarColor() const;
    [[nodiscard]] int activeProfileMaturity() const;
    [[nodiscard]] bool kidsMode() const;
    [[nodiscard]] bool profileExitInFlight() const;
    [[nodiscard]] QString profileExitSelectionId() const;

    /// `ProfilePickerView.swift:1073-1084` and `AppState.swift:266-278`: a
    /// choice on the picker makes the profile active at once, holds the picker
    /// on screen while it fades over `ProfileExitTransitionPolicy.duration`,
    /// then shows the shell. Returns false while a choice is already in flight.
    Q_INVOKABLE bool chooseProfile(const QString &profileId);
    /// `ProfileSession.swift:88-104`: after the catalog of profiles changed,
    /// keep the active profile's fields current, or fall back to the store's
    /// selection when it was deleted.
    Q_INVOKABLE void reconcileActiveProfile();
    /// `ProfileSession.swift:106-108`: returns to the picker.
    Q_INVOKABLE void switchProfile();

    [[nodiscard]] bool startFullscreen() const;
    void setStartFullscreen(bool value);

    [[nodiscard]] bool scanning() const;

    [[nodiscard]] QUrl playerArtworkUrl() const;

    [[nodiscard]] QVariantMap nextEpisode() const;
    [[nodiscard]] bool hasNextEpisode() const;

    [[nodiscard]] QString errorTitle() const;
    [[nodiscard]] QString errorMessage() const;
    [[nodiscard]] bool hasError() const;
    [[nodiscard]] QString version() const;

    void setTemporaryLibraryRoot(const QString &path);
    /// Adds a TV Shows root for this run only, the `--library` counterpart.
    void setTemporaryTvShowsRoot(const QString &path);
    [[nodiscard]] QStringList effectiveLibraryRoots() const;
    /// Both configured lists, with the temporary roots under Movies.
    [[nodiscard]] LibraryRootPaths effectiveLibraryRootPaths() const;

    Q_INVOKABLE void playLocalFile(const QString &path);

    /// Replaces how a file's identity is read, so a test can make a file
    /// unreadable at the moment `playLocalFile` asks. An empty function
    /// restores the real reader.
    using FileIdentityReader = std::function<std::optional<FileIdentity>(const QString &)>;
    void setFileIdentityReaderForTest(FileIdentityReader reader);

    /// Replaces the stat Play Something makes of a candidate's file, so a test
    /// can count which paths it touches. An empty function restores the real
    /// check.
    using PlayableFileCheck = std::function<bool(const QString &)>;
    void setPlayableFileCheckForTest(PlayableFileCheck check);

    /// The catalog worker, so a test can raise the signals it answers with
    /// while a request is held on its thread.
    [[nodiscard]] CatalogWorker *catalogWorkerForTest() const;

    /// Shows the details of the catalog item carrying `mediaId`. Browse
    /// surfaces activate a title by identity, so a projection replaced under
    /// them cannot make an activation open the wrong title.
    Q_INVOKABLE void showMediaDetails(const QString &mediaId);

    /// Opens the catalog item carrying `mediaId`. Browse surfaces activate a
    /// title by identity, so a projection replaced under them cannot make an
    /// activation open the wrong file.
    Q_INVOKABLE void playMediaId(const QString &mediaId, bool fromStart = false);

    /// AppState.swift:235-245: plays one unwatched movie the active profile may
    /// see, drawn fresh on each call. Nothing happens, with no message, when
    /// the profile has none, as in the released app.
    Q_INVOKABLE void playSomething();

    /// PlayerController.swift:126-137: when the finished title is an episode
    /// and the preference allows it, the next episode of its show starts in
    /// place, at the position it was left at, and counts as started by
    /// auto-play for "Still watching?"; otherwise nothing starts. Returns
    /// whether playback continued.
    Q_INVOKABLE bool continueAfterPlayback(const QString &mediaId);

    /// The viewer asked for the episode after `mediaId` (the HUD control, the
    /// card's Play Now, or Continue on "Still watching?"). It starts at the
    /// position it was left at, whatever the Auto-play preference says, and
    /// is not an auto-play. Returns whether it started.
    Q_INVOKABLE bool playNextEpisode(const QString &mediaId);

    /// Whether the end of `mediaId` should ask "Still watching?" instead of
    /// starting its next episode: Auto-play is on, an episode follows, and
    /// `still_watching::isDue` says three auto-played episodes and 90 minutes
    /// without input have passed.
    [[nodiscard]] Q_INVOKABLE bool stillWatchingDue(const QString &mediaId) const;

    /// Leaves the player after an episode or film ran to its end and nothing
    /// followed it. The last episode of a show returns to the show's page;
    /// anything else goes back to where the player was opened from.
    Q_INVOKABLE void finishPlayback(const QString &mediaId);

    /// Replaces the clock "Still watching?" measures idle time and episodes
    /// with, so a test can move time by hand.
    void setStillWatchingClockForTest(std::function<qint64()> clock);

    Q_INVOKABLE void dismissError();
    Q_INVOKABLE void raiseError(const QString &title, const QString &message);
    /// Asks the catalog worker for another scan of the effective roots. A
    /// request made during a scan keeps the surface scanning until the
    /// follow-up finishes, `LibraryState.swift:395-419`.
    void requestCatalogRefresh();
    /// `LibraryState.swift:933-939`: forgets every resume point. The worker
    /// answers with a fresh projection and then `watchHistoryCleared`.
    void clearWatchHistory();

protected:
    /// Remote keys and pointer input anywhere in the application reset the
    /// "Still watching?" counts.
    bool eventFilter(QObject *watched, QEvent *event) override;

signals:
    void startFullscreenChanged();
    void nextEpisodeChanged();
    void scanningChanged();
    void playerArtworkUrlChanged();
    void errorChanged();
    void activeProfileChanged();
    void profileExitInFlightChanged();
    void effectiveLibraryRootsChanged();
    void catalogRefreshRequested(const LibraryRootPaths &rootPaths, const QString &profileId);
    void catalogRefreshStarted();
    void projectionReloadRequested(const QString &profileId);
    void watchProgressRecordRequested(const QString &profileId,
                                      const QString &mediaId,
                                      qint64 positionMs,
                                      qint64 durationMs,
                                      bool completed,
                                      quint64 sequence);
    void profileProgressRemovalRequested(const QString &profileId);
    void watchHistoryClearRequested(const QString &profileId);
    void watchHistoryCleared();
    void catalogProgressPersisted(QString mediaId, qint64 positionMs);

private:
    [[nodiscard]] bool bootstrapCatalog();
    void startCatalogWorker();
    void reportUnavailableRoots(const QStringList &paths);
    /// The projected movie or episode carrying `mediaId`.
    [[nodiscard]] std::optional<MediaItem> projectedItem(const QString &mediaId) const;
    void finishCatalogRefresh();
    void setScanning(bool value);
    void setActiveProfile(const std::optional<Profile> &profile);
    /// Hands every surface the part of the catalog projection the active
    /// profile may see. Home, Movies, TV Shows, show episodes, and search all
    /// read the models fed from here, and play and details requests resolve
    /// against them, so this is the one place the profile's maturity applies.
    void publishProjection();
    /// Whether the active profile may open `item`. No profile chosen yet means
    /// no restriction, as `LibraryState.recomputeFilteredItems` treats it.
    [[nodiscard]] bool profileAllows(const MediaItem &item) const;
    /// Whether the active profile's ceiling is below Adult. Adult and no
    /// profile hide nothing, so they skip every check that exists only to
    /// find hidden titles.
    [[nodiscard]] bool profileRestricted() const;
    /// A title the active restricted profile may not see, as the catalog
    /// names it and as it last resolved. The device and inode are not kept,
    /// because they change when the disk is remounted under the same path;
    /// they are read from `canonicalPath` on each request.
    struct HiddenTitle
    {
        QString catalogPath;
        QString canonicalPath;
    };
    struct HiddenFileIndex
    {
        QVector<HiddenTitle> titles;
    };
    /// Whether a restricted profile is refused the loose file with this
    /// canonical path and identity: it is, by path or by device and inode,
    /// any title the profile may not see, or some such title cannot be read
    /// now (an offline root), so nothing can say the file is not that title.
    /// Builds the title list on first use after the catalog or the profile
    /// changed, so Adult and no-profile sessions never pay for it.
    [[nodiscard]] bool isRefusedLooseFile(const QString &canonicalPath, const FileIdentity &identity);
    void raiseBlockedOrMissing(const QString &title, const QString &mediaId);
    /// The title in the unfiltered projection, for telling a blocked title
    /// from one that is simply gone.
    [[nodiscard]] std::optional<MediaItem> catalogItem(const QString &mediaId) const;
    void finishProfileExit(quint64 serial);

    NavigationController m_navigation;
    SettingsStore m_settings;
    PlayerController m_player;
    LibraryModel m_library;
    MovieRowsModel m_movieRows;
    HomeRowsModel m_homeRows;
    ShowsModel m_shows;
    ProfileStore m_profiles;
    SearchSession m_search;
    SettingsSession m_settingsSession;
    std::optional<Profile> m_activeProfile;
    StillWatchingTracker m_stillWatching;
    // The catalog's latest projection, before any profile filtering, so a
    // profile switch can republish without waiting for a rescan.
    QVector<MediaItem> m_projection;
    // False until the first scan result arrives; an empty m_projection before
    // then is not evidence that a file is outside the catalog.
    bool m_projectionReceived{false};
    // Set from a profile switch until its projection lands, the viewer moves
    // the remote on Home, or the reload fails.
    bool m_homeRestartPending{false};
    bool m_shellDrivesHome{false};
    // Derived from m_projection and the active profile's ceiling; dropped
    // whenever either changes and built again on the next loose-file request.
    std::optional<HiddenFileIndex> m_hiddenFiles;
    FileIdentityReader m_readFileIdentity{readFileIdentity};
    PlayableFileCheck m_playableFileCheck;
    // Roots the latest finished refresh could not reach, by catalog identity.
    // Their rows are kept, but their files are never stat'd on the GUI thread.
    QSet<QString> m_unavailableRootIds;
    // The choice whose fade-out is running, and a serial so a completion
    // scheduled for an earlier choice cannot end a later one
    // (AppState.swift:272 and :294-305).
    QString m_profileExitSelectionId;
    quint64 m_profileExitSerial{0};
    std::unique_ptr<QThread> m_catalogThread;
    QPointer<CatalogWorker> m_catalogWorker;
    QStringList m_temporaryLibraryRoots;
    QStringList m_temporaryTvShowsRoots;
    bool m_startFullscreen{true};
    // Refreshes that have been requested and not yet answered by a projection
    // or a failure. The catalog worker starts its first refresh from
    // `startCatalogWorker`, so Home shows the scan the shell has already asked
    // for rather than an empty library it has not yet looked at, and a request
    // made while one is running keeps the surface scanning until that
    // follow-up finishes too, as `LibraryState.swift:395-419` does.
    int m_outstandingRefreshes{0};
    bool m_scanning{false};
    QString m_errorTitle;
    QString m_errorMessage;
};
