#include "app/ApplicationController.hpp"

#include <QDir>
#include <QEvent>
#include <QEventLoop>
#include <QMouseEvent>
#include <QCoreApplication>
#include <QFileInfo>
#include <QTimer>

#include <algorithm>
#include <iterator>
#include <memory>
#include <optional>
#include <utility>

#include "support/Logging.hpp"
#include "app/AppPaths.hpp"
#include "catalog/CatalogDatabase.hpp"
#include "catalog/CatalogWorker.hpp"
#include "profiles/ContentPolicy.hpp"

namespace
{
// Marquee/Theme/MarqueeTheme.swift:71: the picker's opacity-only exit runs
// 0.24 seconds.
constexpr int kProfileExitDurationMs = 240;

// Marks the stretch in which the shell, not the viewer, changes Home's rows or
// remote, so a focus change announced inside it is not a move.
class ShellDrivesHome
{
public:
    explicit ShellDrivesHome(bool &flag) : m_flag(flag), m_previous(flag) { m_flag = true; }
    ~ShellDrivesHome() { m_flag = m_previous; }
    ShellDrivesHome(const ShellDrivesHome &) = delete;
    ShellDrivesHome &operator=(const ShellDrivesHome &) = delete;

private:
    bool &m_flag;
    bool m_previous;
};

[[nodiscard]] bool isPlayableFile(const QString &path)
{
    const QFileInfo file(path);
    return file.isFile() && file.isReadable();
}
}

ApplicationController::ApplicationController(QObject *parent)
    : QObject(parent),
      m_navigation(this),
      m_settings(this),
      m_player(this),
      m_library(this),
      m_movieRows(this),
      m_homeRows(this),
      m_profiles(AppPaths::profilesFile(), this),
      m_search(&m_library, this),
      m_settingsSession(*this, this),
      m_catalogThread(std::make_unique<QThread>()),
      m_startFullscreen(m_settings.startFullscreen())
{
    QObject::connect(&m_settings, &SettingsStore::storageErrorChanged, this, [this] {
        if (!m_settings.storageError().isEmpty()) {
            raiseError(QStringLiteral("Settings"), m_settings.storageError());
        }
    });
    QObject::connect(&m_profiles, &ProfileStore::storageErrorChanged, this, [this] {
        if (!m_profiles.storageError().isEmpty()) {
            raiseError(QStringLiteral("Profiles"), m_profiles.storageError());
        }
    });
    // A pending restart of Home is for a remote the viewer has not touched. A
    // move behind the picker's fade is not one: the picker still holds the keys.
    const auto remoteMoved = [this] {
        if (!m_shellDrivesHome && !profileExitInFlight()) {
            m_homeRestartPending = false;
        }
    };
    QObject::connect(m_homeRows.focus(), &FocusNavigator::focusChanged, this, remoteMoved);
    QObject::connect(&m_homeRows, &HomeRowsModel::playSomethingFocusedChanged, this, remoteMoved);
    // Down from the hero to the first row, and Up back, change the section
    // without changing the row the focus navigator holds, so only this signal
    // tells that the viewer moved (HomeDetailView.swift:57-60). The hero's own
    // appearing or going with a projection arrives under `ShellDrivesHome`.
    QObject::connect(&m_homeRows, &HomeRowsModel::heroFocusedChanged, this, remoteMoved);
    // Left and Right on the hero turn the carousel and move no focus signal.
    // The timer is stopped while the remote rests on the hero, so a turn then
    // is the viewer's; the reload landing must not snap it back to slide 0.
    // Home's own resets and rebuilds arrive under `ShellDrivesHome`.
    QObject::connect(m_homeRows.hero(), &HeroSpotlightModel::positionChanged, this, remoteMoved);
    // ProfilePickerView.swift:1101, :1107, and :1195: every edit, addition,
    // and deletion is followed by a reconcile so the shell's active profile
    // never shows stale fields or a profile that no longer exists.
    QObject::connect(&m_profiles, &ProfileStore::profilesChanged,
                     this, &ApplicationController::reconcileActiveProfile);

    // The catalog answers where a title resumes only when it is scanned, so the
    // projection on screen has to learn a new resume point as it is recorded.
    connect(&m_player, &PlayerController::progressRecorded, this,
            [this](const QString &mediaId,
                   qint64 positionMs,
                   qint64 durationMs,
                   bool,
                   quint64 sequence) {
                // With no profile nothing is saved (WatchProgressStore is
                // per profile, PlayerController.swift:206), so the screen
                // must not show a resume point that would not survive.
                if (!m_activeProfile) {
                    return;
                }
                m_library.applyWatchProgress(mediaId, positionMs, durationMs, sequence);
                m_movieRows.applyWatchProgress(mediaId, positionMs, durationMs, sequence);
            });
    // The unfiltered projection keeps the same progress, or a profile switch
    // would republish a resume point older than the one just recorded.
    connect(&m_player, &PlayerController::progressRecorded, this,
            [this](const QString &mediaId, qint64 positionMs, qint64 durationMs, bool completed) {
                if (!m_activeProfile) {
                    return;
                }
                const auto match = std::find_if(
                    m_projection.begin(), m_projection.end(),
                    [&mediaId](const MediaItem &item) { return item.id == mediaId; });
                if (match == m_projection.end()) {
                    return;
                }
                match->resumePositionMs = completed ? 0 : positionMs;
                if (durationMs > 0) {
                    match->durationSeconds = durationMs / 1000;
                }
                match->watched = completed;
                match->lastPlayedAt = QDateTime::currentDateTimeUtc();
            });

    // The control and card for the next episode follow what is playing and
    // what the catalog holds.
    connect(&m_player, &PlayerController::currentFileUrlChanged,
            this, &ApplicationController::nextEpisodeChanged);
    connect(&m_shows, &ShowsModel::showsChanged,
            this, &ApplicationController::nextEpisodeChanged);
    if (QCoreApplication::instance() != nullptr) {
        QCoreApplication::instance()->installEventFilter(this);
    }

    // Leaving the player is the end of a viewing, whether the film finished or
    // the viewer walked out of it.
    connect(&m_navigation, &NavigationController::routeChanged, this, [this, remoteMoved] {
        const bool playing = m_navigation.route() == NavigationController::Route::Player;
        // Return on the hero or a card opens the player or Details without a
        // focus signal. That is the viewer acting on the remote's place, so a
        // reload landing while they watch or read must not move it.
        if (playing || m_navigation.route() == NavigationController::Route::Details
            || m_navigation.route() == NavigationController::Route::ShowDetail) {
            remoteMoved();
        }
        if (!playing) {
            m_player.endSession();
        }
        // After endSession, so the viewing it records is in the one hero
        // rebuild that follows the player's close.
        m_homeRows.setPlayerActive(playing);
    });

    try {
        AppPaths::ensureDirectories();
        const QString settingsError = m_settings.storageError();
        if (!settingsError.isEmpty()) {
            raiseError(QStringLiteral("Settings"), settingsError);
        }
        // m_profiles loads in the initializer list, before the connection
        // above exists, so its startup error has to be read here.
        if (const QString profilesError = m_profiles.storageError(); !profilesError.isEmpty()) {
            raiseError(QStringLiteral("Profiles"), profilesError);
        }
        if (bootstrapCatalog()) {
            startCatalogWorker();
        }
    } catch (const std::exception &error) {
        raiseError(QStringLiteral("Filesystem"), QString::fromStdString(error.what()));
    }
    qCInfo(logApp) << "Marquee controller initialized";
}

ApplicationController::~ApplicationController()
{
    // Quitting with the player open is still the end of a viewing.
    m_player.endSession();

    if (m_catalogThread != nullptr && m_catalogThread->isRunning()) {
        // The quit request follows the final progress event in the worker's
        // queue, so an idle worker always drains that write before stopping.
        QEventLoop shutdownLoop;
        QObject::connect(m_catalogThread.get(), &QThread::finished,
                         &shutdownLoop, &QEventLoop::quit);
        if (m_catalogWorker != nullptr) {
            QMetaObject::invokeMethod(
                m_catalogWorker, &CatalogWorker::shutdown, Qt::QueuedConnection);
        } else {
            m_catalogThread->quit();
        }
        // Keep the application alive until the worker has drained its queue,
        // while still dispatching GUI events during a delayed refresh.
        shutdownLoop.exec();
    }
}

bool ApplicationController::bootstrapCatalog()
{
    try {
        // Migration 5 gives each profile that exists now a copy of the progress
        // stored before progress was per profile. A profiles file that could
        // not be read yields no trustworthy list, so the old rows are set aside
        // rather than copied to profiles that will not persist; the library
        // still opens.
        QStringList profileIds;
        if (m_profiles.storageError().isEmpty()) {
            for (const Profile &profile : m_profiles.profiles()) {
                profileIds.push_back(profile.id);
            }
        }
        CatalogDatabase catalog(AppPaths::catalogFile());
        catalog.migrate(profileIds);
    } catch (const std::exception &error) {
        raiseError(QStringLiteral("Library catalog"),
                   QString::fromStdString(error.what()));
        return false;
    }
    return true;
}

void ApplicationController::startCatalogWorker()
{
    // The worker opens its own catalog connection, so it has to reach its thread
    // before anything asks it to scan. It stays parentless and is deleted by the
    // thread it belongs to.
    auto *worker = new CatalogWorker(AppPaths::catalogFile());
    worker->moveToThread(m_catalogThread.get());
    m_catalogWorker = worker;

    connect(m_catalogThread.get(), &QThread::finished, worker, &QObject::deleteLater);
    connect(this, &ApplicationController::catalogRefreshRequested,
            worker, &CatalogWorker::refresh);
    connect(worker, &CatalogWorker::refreshStarted,
            this, &ApplicationController::catalogRefreshStarted,
            Qt::DirectConnection);
    // LibraryState.swift:490-491 hands movies and episodes to different
    // surfaces from one projection; the movie models see only the movies.
    // A projection carries the progress of the profile it was read for. One
    // read for a profile that is no longer active is dropped: the reload that
    // choosing the new profile queued behind it brings the right one.
    const auto adoptProjection = [this](const QVector<MediaItem> &items,
                                        const QString &profileId) {
        if (profileId != activeProfileId()) {
            return;
        }
        m_projection = items;
        m_projectionReceived = true;
        publishProjection();
        // The first projection of a new profile can add rows above the card
        // the remote kept (a Continue Watching row); Home starts at its first
        // target, so the first Return opens the top card, not a lower one.
        // Only for a remote the viewer has not moved since the choice: a
        // reload queued behind a running scan lands while they browse.
        if (m_homeRestartPending) {
            m_homeRestartPending = false;
            const ShellDrivesHome shell(m_shellDrivesHome);
            m_homeRows.resetFocus();
        }
    };
    connect(worker, &CatalogWorker::projectionReady, this, adoptProjection);
    connect(worker, &CatalogWorker::projectionReloaded, this, adoptProjection);
    // A refresh ends when its projection lands or when it fails. Both are
    // queued onto this thread after the model updates connected above, so the
    // library is on screen before Home stops calling itself scanning, which is
    // the order `LibraryState.swift:409-414` publishes them in. A refresh
    // requested while one was already running is a second completion to wait
    // for, so the surface keeps scanning until the last one is answered, as
    // `ScanRequestGate.swift:31-41` and `LibraryState.swift:395-419` do.
    connect(worker, &CatalogWorker::projectionReady, this,
            [this] { finishCatalogRefresh(); });
    connect(worker, &CatalogWorker::scanFailed, this, [this](const QString &message) {
        finishCatalogRefresh();
        raiseError(QStringLiteral("Library scan"), message);
    });
    // A reload that fails or finds no roots brings no projection to restart
    // Home for. Only the active profile's reload disarms it: a scan failing
    // while the reload waits behind it, or the reload of a profile already
    // left, says nothing about the one still to land.
    const auto reloadEnded = [this](const QString &profileId) {
        if (profileId == activeProfileId()) {
            m_homeRestartPending = false;
        }
    };
    connect(worker, &CatalogWorker::projectionReloadSkipped, this, reloadEnded);
    connect(worker, &CatalogWorker::projectionReloadFailed, this,
            [this, reloadEnded](const QString &message, const QString &profileId) {
                reloadEnded(profileId);
                raiseError(QStringLiteral("Library scan"), message);
            });
    connect(worker, &CatalogWorker::rootsUnavailable, this,
            [this](const QStringList &paths, const QStringList &rootIds) {
                m_unavailableRootIds = QSet<QString>(rootIds.cbegin(), rootIds.cend());
                reportUnavailableRoots(paths);
            });
    connect(this, &ApplicationController::projectionReloadRequested,
            worker, &CatalogWorker::reloadProjection);
    connect(this, &ApplicationController::profileProgressRemovalRequested,
            worker, &CatalogWorker::deleteProfileProgress);
    connect(&m_profiles, &ProfileStore::profileDeleted,
            this, &ApplicationController::profileProgressRemovalRequested);
    connect(this, &ApplicationController::watchHistoryClearRequested,
            worker, &CatalogWorker::clearWatchHistory);
    connect(worker, &CatalogWorker::watchHistoryCleared,
            this, &ApplicationController::watchHistoryCleared,
            Qt::QueuedConnection);
    // The profile is read when the progress is recorded, not when the worker
    // gets to it, so a profile chosen in between cannot receive it.
    connect(&m_player, &PlayerController::progressRecorded, this,
            [this](const QString &mediaId, qint64 positionMs, qint64 durationMs,
                   bool completed, quint64 sequence) {
                if (!m_activeProfile) {
                    // WatchProgressStore is per profile and the released app
                    // saves nothing while it has none (PlayerController.swift
                    // :206); a row with no owner could never be read back.
                    qCWarning(logApp) << "watch progress not saved: no profile is chosen";
                    return;
                }
                emit watchProgressRecordRequested(m_activeProfile->id, mediaId, positionMs,
                                                  durationMs, completed, sequence);
            });
    connect(this, &ApplicationController::watchProgressRecordRequested,
            worker, &CatalogWorker::recordProgress);
    connect(&m_player, &PlayerController::progressRecorded, &m_shows,
            [this](const QString &mediaId, qint64 positionMs, qint64 durationMs,
                   bool completed) {
                if (!m_activeProfile) {
                    return;
                }
                m_shows.applyWatchProgress(mediaId, positionMs, durationMs, completed);
                const ShellDrivesHome shell(m_shellDrivesHome);
                m_homeRows.applyWatchProgress(mediaId, positionMs, durationMs, completed);
            });
    // The echo of a write applies only to the profile it was written for; the
    // viewer may have switched profiles while the worker was busy.
    connect(worker, &CatalogWorker::watchProgressRecorded, this,
            [this](const QString &profileId, const QString &mediaId, qint64 positionMs,
                   qint64 durationMs, quint64 sequence) {
                if (profileId == activeProfileId()) {
                    m_library.applyWatchProgress(mediaId, positionMs, durationMs, sequence);
                    m_movieRows.applyWatchProgress(mediaId, positionMs, durationMs, sequence);
                }
                emit catalogProgressPersisted(mediaId, positionMs);
            },
            Qt::QueuedConnection);
    connect(&m_settings, &SettingsStore::libraryRootsChanged,
            this, &ApplicationController::requestCatalogRefresh);
    connect(&m_settings, &SettingsStore::tvShowsRootsChanged,
            this, &ApplicationController::requestCatalogRefresh);
    connect(this, &ApplicationController::effectiveLibraryRootsChanged,
            this, &ApplicationController::requestCatalogRefresh);

    m_catalogThread->start();
    requestCatalogRefresh();
}

void ApplicationController::publishProjection()
{
    // The hidden-file index is derived from the projection and the profile's
    // ceiling, the two things this republishes on.
    m_hiddenFiles.reset();
    const QVector<MediaItem> visible = m_activeProfile
        ? content_policy::filtered(m_activeProfile->maturityLevel, m_projection)
        : m_projection;
    QVector<MediaItem> movies;
    movies.reserve(visible.size());
    std::copy_if(visible.cbegin(), visible.cend(), std::back_inserter(movies),
                 [](const MediaItem &item) { return item.isMovie(); });
    m_library.replaceItems(movies);
    m_movieRows.replaceItems(std::move(movies));
    m_shows.replaceItems(visible);
    // Home reads the same visible projection, so a Kids profile's rows hold
    // only what Movies and TV Shows hold for it.
    const ShellDrivesHome shell(m_shellDrivesHome);
    m_homeRows.replaceItems(visible);
}

bool ApplicationController::profileAllows(const MediaItem &item) const
{
    return !m_activeProfile || content_policy::allows(m_activeProfile->maturityLevel, item);
}

bool ApplicationController::profileRestricted() const
{
    return m_activeProfile
        && m_activeProfile->maturityLevel < static_cast<int>(ProfileStore::Maturity::Adult);
}

std::optional<MediaItem> ApplicationController::catalogItem(const QString &mediaId) const
{
    const auto match = std::find_if(
        m_projection.cbegin(), m_projection.cend(),
        [&mediaId](const MediaItem &item) { return item.id == mediaId; });
    return match == m_projection.cend() ? std::nullopt : std::optional<MediaItem>(*match);
}

CatalogWorker *ApplicationController::catalogWorkerForTest() const
{
    return m_catalogWorker;
}

void ApplicationController::requestCatalogRefresh()
{
    if (m_catalogThread == nullptr || !m_catalogThread->isRunning()) {
        return;
    }
    // The worker's own `refreshStarted` crosses a thread boundary and arrives
    // after the request; a surface asked about the scan in between would be
    // told the library was simply empty. The request is what starts the scan,
    // so it is also what marks it as running.
    ++m_outstandingRefreshes;
    setScanning(true);
    emit catalogRefreshRequested(effectiveLibraryRootPaths(), activeProfileId());
}

void ApplicationController::finishCatalogRefresh()
{
    // The worker answers each queued request in turn, so a completion that
    // arrives with nothing outstanding is not this shell's to account for.
    if (m_outstandingRefreshes == 0) {
        return;
    }
    --m_outstandingRefreshes;
    if (m_outstandingRefreshes == 0) {
        setScanning(false);
    }
}

void ApplicationController::setScanning(bool value)
{
    if (m_scanning == value) {
        return;
    }
    m_scanning = value;
    emit scanningChanged();
}

NavigationController *ApplicationController::navigation()
{
    return &m_navigation;
}

SettingsStore *ApplicationController::settings()
{
    return &m_settings;
}

PlayerController *ApplicationController::player()
{
    return &m_player;
}

LibraryModel *ApplicationController::library()
{
    return &m_library;
}

ShowsModel *ApplicationController::shows()
{
    return &m_shows;
}

MovieRowsModel *ApplicationController::movieRows()
{
    return &m_movieRows;
}

HomeRowsModel *ApplicationController::homeRows()
{
    return &m_homeRows;
}

SearchSession *ApplicationController::search()
{
    return &m_search;
}

SettingsSession *ApplicationController::settingsSession()
{
    return &m_settingsSession;
}

void ApplicationController::clearWatchHistory()
{
    if (m_catalogThread == nullptr || !m_catalogThread->isRunning()) {
        return;
    }
    // WatchProgressStore.swift:126-131 clears the active profile's store only,
    // and LibraryState.swift:934 clears nothing while there is none, yet
    // SettingsDetailView.swift:711-717 still confirms. A session with no
    // profile saves and shows no progress, so there is nothing left to clear
    // and the confirmation is true.
    if (!m_activeProfile) {
        qCInfo(logApp) << "no profile is chosen, so there is no watch history to clear";
        QTimer::singleShot(0, this, &ApplicationController::watchHistoryCleared);
        return;
    }
    emit watchHistoryClearRequested(m_activeProfile->id);
}

ProfileStore *ApplicationController::profiles()
{
    return &m_profiles;
}

QString ApplicationController::activeProfileId() const
{
    return m_activeProfile ? m_activeProfile->id : QString();
}

QString ApplicationController::activeProfileName() const
{
    return m_activeProfile ? m_activeProfile->name : QString();
}

QString ApplicationController::activeProfileAvatarIcon() const
{
    return m_activeProfile ? m_activeProfile->avatarIcon : QString();
}

QColor ApplicationController::activeProfileAvatarColor() const
{
    return m_activeProfile ? QColor(m_activeProfile->avatarColor) : QColor(Qt::transparent);
}

int ApplicationController::activeProfileMaturity() const
{
    return m_activeProfile ? m_activeProfile->maturityLevel
                           : static_cast<int>(ProfileStore::Maturity::Adult);
}

bool ApplicationController::kidsMode() const
{
    return m_activeProfile
        && m_activeProfile->maturityLevel == static_cast<int>(ProfileStore::Maturity::Kids);
}

bool ApplicationController::profileExitInFlight() const
{
    return !m_profileExitSelectionId.isEmpty();
}

QString ApplicationController::profileExitSelectionId() const
{
    return m_profileExitSelectionId;
}

bool ApplicationController::chooseProfile(const QString &profileId)
{
    // AppState.swift:267: a second choice while one is fading is refused.
    if (profileExitInFlight()) {
        return false;
    }
    const auto profile = m_profiles.profile(profileId);
    if (!profile) {
        return false;
    }
    // ProfileSession.swift:29-86: the profile is active and remembered at
    // once, whichever maturity it carries.
    const bool profileSwitched = activeProfileId() != profile->id;
    setActiveProfile(profile);
    m_profiles.selectProfile(profile->id);
    // ContentView.swift:391-407 rebuilds Home at its top after a choice, so
    // the first Return acts on Home's first target whatever the last viewer
    // left focused, including when the same profile is chosen again.
    {
        const ShellDrivesHome shell(m_shellDrivesHome);
        m_homeRows.resetFocus();
    }
    // A different profile's progress arrives with the reloaded projection and
    // reshapes Home's rows; that projection restarts Home's focus again. A
    // second choice while that reload is in flight leaves it pending: the
    // remote has not moved, and the reload has not landed.
    m_homeRestartPending = m_homeRestartPending || profileSwitched;
    qCInfo(logApp) << "profile selected id=" << profile->id
                   << "maturity=" << profile->maturityLevel;

    // ProfileSession.swift:46 and :80: the shell is composed the moment a
    // profile is chosen. AppState.swift:275-276 and :280-305: the picker
    // stays on screen above it and fades over the released 0.24-second
    // exit, then leaves.
    m_profileExitSelectionId = profile->id;
    const quint64 serial = ++m_profileExitSerial;
    if (m_navigation.route() == NavigationController::Route::ProfilePicker) {
        m_navigation.resetTo(NavigationController::Route::Home);
    }
    emit profileExitInFlightChanged();
    QTimer::singleShot(kProfileExitDurationMs, this, [this, serial] {
        finishProfileExit(serial);
    });
    return true;
}

void ApplicationController::finishProfileExit(quint64 serial)
{
    // AppState.swift:298-299: only the completion that belongs to the choice
    // still in flight ends it.
    if (serial != m_profileExitSerial || m_profileExitSelectionId.isEmpty()) {
        return;
    }
    m_profileExitSelectionId.clear();
    emit profileExitInFlightChanged();
}

void ApplicationController::reconcileActiveProfile()
{
    if (!m_activeProfile) {
        return;
    }
    // ProfileSession.swift:88-104: re-read the active profile, or fall back to
    // the store's own selection when it was deleted.
    if (const auto refreshed = m_profiles.profile(m_activeProfile->id)) {
        setActiveProfile(refreshed);
        m_profiles.selectProfile(refreshed->id);
        return;
    }
    const auto fallback = m_profiles.selectedProfile();
    setActiveProfile(fallback);
    if (fallback) {
        m_profiles.selectProfile(fallback->id);
    }
}

void ApplicationController::switchProfile()
{
    m_navigation.showProfilePicker();
}

void ApplicationController::setActiveProfile(const std::optional<Profile> &profile)
{
    const bool same = (!m_activeProfile && !profile)
        || (m_activeProfile && profile
            && m_activeProfile->id == profile->id
            && m_activeProfile->name == profile->name
            && m_activeProfile->avatarIcon == profile->avatarIcon
            && m_activeProfile->avatarColor == profile->avatarColor
            && m_activeProfile->maturityLevel == profile->maturityLevel);
    if (same) {
        return;
    }
    const auto effectiveMaturity = [](const std::optional<Profile> &candidate) {
        return candidate ? candidate->maturityLevel
                         : static_cast<int>(ProfileStore::Maturity::Adult);
    };
    const bool visibilityChanged = effectiveMaturity(m_activeProfile) != effectiveMaturity(profile);
    const bool profileSwitched = (m_activeProfile ? m_activeProfile->id : QString())
        != (profile ? profile->id : QString());
    m_activeProfile = profile;
    // Progress is per profile, so the previous profile's resume points and
    // watched marks go at once: until the catalog answers for the new profile
    // a title opens from its beginning rather than where someone else left it.
    if (profileSwitched) {
        for (MediaItem &item : m_projection) {
            item.resumePositionMs = 0;
            item.durationSeconds = 0;
            item.watched = false;
            item.lastPlayedAt = {};
        }
    }
    // Published before the change is announced, so a surface reacting to the
    // new profile never reads the previous profile's titles.
    if (visibilityChanged || profileSwitched) {
        publishProjection();
    }
    if (profileSwitched) {
        emit projectionReloadRequested(activeProfileId());
    }
    emit activeProfileChanged();
}

bool ApplicationController::startFullscreen() const
{
    return m_startFullscreen;
}

void ApplicationController::setStartFullscreen(bool value)
{
    if (m_startFullscreen == value) {
        return;
    }
    m_startFullscreen = value;
    emit startFullscreenChanged();
}

bool ApplicationController::scanning() const
{
    return m_scanning;
}

QUrl ApplicationController::playerArtworkUrl() const
{
    // PlayerView.swift:64 resolves the startup overlay's backdrop as the
    // playing title's display backdrop first, then its display poster. The
    // projection stores both as absolute filesystem paths, so an empty path
    // means the title has no local artwork at that scope and the overlay
    // draws its backdrop-less composition instead of a broken image.
    //
    // MediaItem.swift:202-207 resolves a movie to its backdrop sidecars and
    // an episode to the show backdrop chain; :195-200 and :262-272 resolve
    // the corresponding poster chain the same way.
    const QString mediaId = m_player.mediaId();
    if (mediaId.isEmpty()) {
        return {};
    }
    QUrl artwork;
    if (const std::optional<MediaItem> movie = m_library.itemForId(mediaId)) {
        artwork = movie->posterAbsolutePath.isEmpty()
            ? QUrl()
            : QUrl::fromLocalFile(movie->posterAbsolutePath);
    } else if (const std::optional<MediaItem> episode = m_shows.episodeForId(mediaId)) {
        QString path = episode->showBackdropAbsolutePath;
        if (path.isEmpty()) {
            path = episode->showPosterAbsolutePath.isEmpty()
                ? episode->seasonPosterAbsolutePath
                : episode->showPosterAbsolutePath;
        }
        if (path.isEmpty()) {
            path = episode->posterAbsolutePath;
        }
        artwork = path.isEmpty() ? QUrl() : QUrl::fromLocalFile(path);
    }
    return artwork;
}

QString ApplicationController::errorTitle() const
{
    return m_errorTitle;
}

QString ApplicationController::errorMessage() const
{
    return m_errorMessage;
}

bool ApplicationController::hasError() const
{
    return !m_errorTitle.isEmpty() || !m_errorMessage.isEmpty();
}

QString ApplicationController::version() const
{
#ifdef MARQUEE_VERSION
    return QStringLiteral(MARQUEE_VERSION);
#else
    return QStringLiteral("3.0.0");
#endif
}

void ApplicationController::setTemporaryLibraryRoot(const QString &path)
{
    const QString normalized = QDir(path).absolutePath();
    if (normalized.isEmpty() || m_temporaryLibraryRoots.contains(normalized)) {
        return;
    }
    m_temporaryLibraryRoots.push_back(normalized);
    emit effectiveLibraryRootsChanged();
}

void ApplicationController::setTemporaryTvShowsRoot(const QString &path)
{
    const QString normalized = QDir(path).absolutePath();
    if (normalized.isEmpty() || m_temporaryTvShowsRoots.contains(normalized)) {
        return;
    }
    m_temporaryTvShowsRoots.push_back(normalized);
    emit effectiveLibraryRootsChanged();
}

QStringList ApplicationController::effectiveLibraryRoots() const
{
    QStringList result = m_settings.libraryRoots();
    for (const QString &root : m_temporaryLibraryRoots) {
        if (!result.contains(root)) {
            result.push_back(root);
        }
    }
    return result;
}

LibraryRootPaths ApplicationController::effectiveLibraryRootPaths() const
{
    QStringList tvShows = m_settings.tvShowsRoots();
    for (const QString &root : m_temporaryTvShowsRoots) {
        if (!tvShows.contains(root)) {
            tvShows.push_back(root);
        }
    }
    return {.movies = effectiveLibraryRoots(), .tvShows = tvShows};
}

void ApplicationController::playLocalFile(const QString &path)
{
    const QFileInfo file(path);
    if (!file.isFile() || !file.isReadable()) {
        raiseError(QStringLiteral("Playback"),
                   QStringLiteral("No readable media file at %1").arg(path));
        return;
    }

    const QString resolvedPath = file.absoluteFilePath();
    if (profileRestricted()) {
        // Until the first scan lands there is nothing to tell a hidden title
        // from an allowed one, so a restricted profile gets no loose files.
        if (!m_projectionReceived) {
            raiseError(QStringLiteral("Playback"),
                       QStringLiteral("This title is not available on this profile."));
            return;
        }
        // A loose file that is any title this profile may not see answers to
        // the profile like that title. `..` and symlinks are resolved first,
        // and the file's device and inode catch a second name for the same
        // file (a hard link, or the disk mounted at another path) that no
        // path comparison can. A copy is a different file and is not matched.
        // Nothing can say a file is not hidden when its own identity cannot
        // be read, or when a hidden title cannot be read to compare against,
        // so both refuse it. Only a restricted profile pays for this: every
        // hidden title is read again on each request, on the GUI thread, and
        // rows from an unavailable root can stall there.
        const QString canonicalPath = file.canonicalFilePath();
        const std::optional<FileIdentity> identity = canonicalPath.isEmpty()
            ? std::nullopt
            : m_readFileIdentity(canonicalPath);
        if (!identity) {
            raiseError(QStringLiteral("Playback"),
                       QStringLiteral("No readable media file at %1").arg(path));
            return;
        }
        if (isRefusedLooseFile(canonicalPath, *identity)) {
            raiseError(QStringLiteral("Playback"),
                       QStringLiteral("This title is not available on this profile."));
            return;
        }
    }
    m_player.prepare(resolvedPath, file.completeBaseName());
    emit playerArtworkUrlChanged();
    m_navigation.openPlayer(resolvedPath);
}

bool ApplicationController::isRefusedLooseFile(const QString &canonicalPath,
                                               const FileIdentity &identity)
{
    if (!m_hiddenFiles) {
        m_hiddenFiles.emplace();
        for (const MediaItem &item : std::as_const(m_projection)) {
            if (!profileAllows(item)) {
                m_hiddenFiles->titles.push_back({.catalogPath = item.absolutePath, .canonicalPath = {}});
            }
        }
    }
    for (HiddenTitle &title : m_hiddenFiles->titles) {
        // The identity is read on every request and never kept: a disk
        // remounted under the same path gets a new device number, and an
        // identity kept from before would stop matching its hard links.
        std::optional<FileIdentity> hidden = title.canonicalPath.isEmpty()
            ? std::nullopt
            : m_readFileIdentity(title.canonicalPath);
        if (!hidden) {
            // Never resolved, or gone from where it was resolved to (the
            // disk came back at another path): resolve it from the catalog
            // again before giving up on it.
            title.canonicalPath = QFileInfo(title.catalogPath).canonicalFilePath();
            hidden = title.canonicalPath.isEmpty()
                ? std::nullopt
                : m_readFileIdentity(title.canonicalPath);
        }
        if (!hidden) {
            // Whether this file is that title cannot be told, so fail closed.
            return true;
        }
        if (title.canonicalPath == canonicalPath || *hidden == identity) {
            return true;
        }
    }
    return false;
}

void ApplicationController::setPlayableFileCheckForTest(PlayableFileCheck check)
{
    m_playableFileCheck = std::move(check);
}

void ApplicationController::setFileIdentityReaderForTest(FileIdentityReader reader)
{
    m_readFileIdentity = reader ? std::move(reader) : FileIdentityReader(readFileIdentity);
    m_hiddenFiles.reset();
}

std::optional<MediaItem> ApplicationController::projectedItem(const QString &mediaId) const
{
    if (const std::optional<MediaItem> movie = m_library.itemForId(mediaId)) {
        return movie;
    }
    return m_shows.episodeForId(mediaId);
}

void ApplicationController::raiseBlockedOrMissing(const QString &title, const QString &mediaId)
{
    // The surfaces only hold what the profile may see, so a title missing from
    // them is either gone or hidden from this profile. The unfiltered
    // projection tells the two apart without revealing the title's name.
    const std::optional<MediaItem> hidden = catalogItem(mediaId);
    if (hidden && !profileAllows(*hidden)) {
        raiseError(title, QStringLiteral("This title is not available on this profile."));
        return;
    }
    raiseError(title, QStringLiteral("That title is no longer in the library."));
}

void ApplicationController::showMediaDetails(const QString &mediaId)
{
    const std::optional<MediaItem> item = projectedItem(mediaId);
    if (!item) {
        raiseBlockedOrMissing(QStringLiteral("Library"), mediaId);
        return;
    }

    m_navigation.openDetails(item->id);
}

void ApplicationController::playMediaId(const QString &mediaId, bool fromStart)
{
    const std::optional<MediaItem> item = projectedItem(mediaId);
    if (!item) {
        raiseBlockedOrMissing(QStringLiteral("Playback"), mediaId);
        return;
    }

    const QFileInfo file(item->absolutePath);
    if (!file.isFile() || !file.isReadable()) {
        raiseError(QStringLiteral("Title unavailable"),
                   QStringLiteral("%1 is not readable at %2.")
                       .arg(item->title, item->absolutePath));
        return;
    }

    // PlayerView.swift:202-213: an episode plays under its show name with
    // "S1 E4 · Title" beneath; a movie under its title alone.
    const QString subtitle = item->isEpisode()
        ? QStringLiteral("%1 \u00B7 %2").arg(item->episodeLabel(), item->displayEpisodeTitle())
        : QString();
    m_player.prepare(file.absoluteFilePath(), item->isEpisode() ? item->showName : item->title,
                     item->id, fromStart ? 0 : item->resumePositionMs, subtitle);
    emit playerArtworkUrlChanged();
    if (m_navigation.route() != NavigationController::Route::Player) {
        m_navigation.openPlayer(item->id);
    }
}

void ApplicationController::playSomething()
{
    // Home's model holds the projection the profile may see, so the pick can
    // never leave the profile's policy and counts that profile's watch state.
    //
    // Rows of an offline root or a deleted file are kept on purpose, so the
    // first pick may not be playable while others are: take the first
    // candidate whose file is readable and say nothing when there is none.
    //
    // A stat on an unreachable network mount can block the GUI thread for
    // minutes, so no title of a root the last refresh found unavailable is
    // stat'd at all; that refresh learned it off this thread. The first few
    // candidates on reachable roots are tried, which bounds the stats on the
    // roots left.
    constexpr int kMaxCandidatesTried = 5;
    const PlayableFileCheck readable =
        m_playableFileCheck ? m_playableFileCheck : PlayableFileCheck(isPlayableFile);
    const QStringList candidates = m_homeRows.playSomethingCandidates();
    int tried = 0;
    for (const QString &candidate : candidates) {
        if (tried >= kMaxCandidatesTried) {
            break;
        }
        const std::optional<MediaItem> item = projectedItem(candidate);
        if (!item || m_unavailableRootIds.contains(item->libraryRootId)) {
            continue;
        }
        ++tried;
        if (readable(item->absolutePath)) {
            playMediaId(item->id);
            return;
        }
    }
}

QVariantMap ApplicationController::nextEpisode() const
{
    const QString nextId = m_shows.nextEpisodeId(m_player.mediaId());
    if (nextId.isEmpty()) {
        return {};
    }
    const std::optional<MediaItem> next = m_shows.episodeForId(nextId);
    if (!next) {
        return {};
    }
    return {{QStringLiteral("mediaId"), next->id},
            {QStringLiteral("label"), next->episodeLabel()},
            {QStringLiteral("title"), next->displayEpisodeTitle()}};
}

bool ApplicationController::hasNextEpisode() const
{
    return !m_shows.nextEpisodeId(m_player.mediaId()).isEmpty();
}

bool ApplicationController::playNextEpisode(const QString &mediaId)
{
    const QString nextId = m_shows.nextEpisodeId(mediaId);
    if (nextId.isEmpty()) {
        return false;
    }
    const std::optional<MediaItem> next = m_shows.episodeForId(nextId);
    if (!next) {
        return false;
    }
    const QFileInfo file(next->absolutePath);
    if (!file.isFile() || !file.isReadable()) {
        // The viewer pressed Next or Play Now, or the file ended: say why
        // nothing started, as Play does for the same file.
        raiseError(QStringLiteral("Title unavailable"),
                   QStringLiteral("%1 is not readable at %2.")
                       .arg(next->title, next->absolutePath));
        return false;
    }
    // PlayerController.swift:126-137: the next episode opens where it was
    // left; the projection holds a position only for a title past the
    // opening stretch that was not finished.
    playMediaId(nextId);
    return true;
}

bool ApplicationController::continueAfterPlayback(const QString &mediaId)
{
    if (!m_settings.autoPlayNextEpisode()) {
        return false;
    }
    if (!playNextEpisode(mediaId)) {
        return false;
    }
    m_stillWatching.noteAutoPlayed();
    return true;
}

bool ApplicationController::stillWatchingDue(const QString &mediaId) const
{
    return m_settings.autoPlayNextEpisode() && !m_shows.nextEpisodeId(mediaId).isEmpty()
        && m_stillWatching.isDue();
}

void ApplicationController::finishPlayback(const QString &mediaId)
{
    const std::optional<MediaItem> episode = m_shows.episodeForId(mediaId);
    const bool lastOfShow = episode && m_shows.nextEpisodeId(mediaId).isEmpty();
    const QString showName = lastOfShow ? episode->showName : QString();
    m_navigation.goBack();
    if (showName.isEmpty()) {
        return;
    }
    // Opened from Home or Search, the route behind the player is not the
    // show; the viewer who finished its last episode lands on the show.
    if (m_navigation.route() != NavigationController::Route::ShowDetail
        || m_navigation.selectedMediaId() != showName) {
        m_navigation.openShowDetail(showName);
    }
}

void ApplicationController::setStillWatchingClockForTest(std::function<qint64()> clock)
{
    m_stillWatching.setClockForTest(std::move(clock));
}

bool ApplicationController::eventFilter(QObject *watched, QEvent *event)
{
    switch (event->type()) {
    case QEvent::KeyPress:
    case QEvent::MouseButtonPress:
    case QEvent::TouchBegin:
    case QEvent::Wheel:
        m_stillWatching.noteInput();
        break;
    case QEvent::MouseMove:
        // Qt repeats the last pointer position when items move under a still
        // pointer; that is not the viewer.
        if (static_cast<QMouseEvent *>(event)->source() == Qt::MouseEventNotSynthesized) {
            m_stillWatching.noteInput();
        }
        break;
    default:
        break;
    }
    return QObject::eventFilter(watched, event);
}

void ApplicationController::reportUnavailableRoots(const QStringList &paths)
{
    if (paths.isEmpty()) {
        return;
    }

    const QString message = paths.size() == 1
        ? QStringLiteral("%1 is not currently accessible. The existing catalog "
                         "has been preserved.")
              .arg(paths.constFirst())
        : QStringLiteral("%1 library locations are not currently accessible. The "
                         "existing catalog has been preserved.")
              .arg(paths.size());

    raiseError(QStringLiteral("Library unavailable"), message);
}

void ApplicationController::dismissError()
{
    if (!hasError()) {
        return;
    }
    m_errorTitle.clear();
    m_errorMessage.clear();
    emit errorChanged();
}

void ApplicationController::raiseError(const QString &title, const QString &message)
{
    m_errorTitle = title;
    m_errorMessage = message;
    qCWarning(logApp) << "user-safe error" << title << message;
    emit errorChanged();
}
