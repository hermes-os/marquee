#include <clocale>

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QGuiApplication>
#include <QKeyEvent>
#include <QPointF>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickItem>
#include <QQuickWindow>
#include <QScopeGuard>
#include <QSignalSpy>
#include <QTemporaryDir>
#include <QTest>

#include "app/AppPaths.hpp"
#include "app/ApplicationController.hpp"
#include "models/LibraryModel.hpp"
#include "models/ShowsModel.hpp"
#include "navigation/NavigationController.hpp"
#include "playback/MpvVideoItem.hpp"
#include "playback/PlayerController.hpp"
#include "settings/SettingsStore.hpp"

namespace
{
// A ten-minute 16x16 y4m at one frame a second, which outlasts every case. The
// cases that need the clock at the end of an episode move it by hand through
// the item's own slots, so the length each episode claims is the one set here.
[[nodiscard]] bool writeClip(const QString &path)
{
    if (!QDir().mkpath(QFileInfo(path).absolutePath())) {
        return false;
    }
    QFile file(path);
    if (!file.open(QIODevice::WriteOnly)) {
        return false;
    }
    constexpr int kSide = 16;
    file.write(QByteArrayLiteral("YUV4MPEG2 W16 H16 F1:1 Ip A1:1 C420mpeg2\n"));
    const QByteArray frame = QByteArrayLiteral("FRAME\n")
        + QByteArray(kSide * kSide, '\x80') + QByteArray(kSide * kSide / 2, '\x80');
    for (int index = 0; index < 600; ++index) {
        file.write(frame);
    }
    file.close();
    return file.error() == QFileDevice::NoError;
}

// One show of two seasons (S1 E1-E3, S2 E1-E2) and one film.
[[nodiscard]] bool writeLibrary(const QString &tv, const QString &movies)
{
    const QString show = tv + QStringLiteral("/Show (2020)");
    return writeClip(show + QStringLiteral("/Season 1/Show - S01E01 - Pilot.mkv"))
        && writeClip(show + QStringLiteral("/Season 1/Show - S01E02 - Second.mkv"))
        && writeClip(show + QStringLiteral("/Season 1/Show - S01E03 - Third.mkv"))
        && writeClip(show + QStringLiteral("/Season 2/Show - S02E01 - Return.mkv"))
        && writeClip(show + QStringLiteral("/Season 2/Show - S02E02 - Finale.mkv"))
        && writeClip(movies + QStringLiteral("/Arrival (2016)/Arrival (2016).mkv"));
}

constexpr double kEpisodeSeconds = 22.0 * 60.0;
constexpr qint64 kMinuteMs = 60 * 1000;
}

class NextEpisodeFlowTest final : public QObject
{
    Q_OBJECT

    /// Points the app's paths at the temporary root while the members below it
    /// are built: the controller opens its data directory as it is constructed,
    /// so a root set later would leave it on the real `~/.local/share`.
    struct RuntimeRootScope
    {
        explicit RuntimeRootScope(const QString &path) { AppPaths::setRuntimeRoot(path); }
        ~RuntimeRootScope() { AppPaths::clearRuntimeRoot(); }
        RuntimeRootScope(const RuntimeRootScope &) = delete;
        RuntimeRootScope &operator=(const RuntimeRootScope &) = delete;
    };

    struct Env
    {
        QTemporaryDir runtimeRoot;
        QTemporaryDir tv;
        QTemporaryDir movies;
        RuntimeRootScope paths{runtimeRoot.path()};
        ApplicationController controller;
        QQmlApplicationEngine engine;
        QQuickWindow *window{nullptr};
        QStringList ids; // the show's five episodes in aired order
        QString filmId;
    };

    [[nodiscard]] static QQuickItem *itemNamed(QQuickWindow *window, const char *name)
    {
        return window->findChild<QQuickItem *>(QLatin1String(name));
    }

    [[nodiscard]] static bool glRenders(QQuickWindow *window)
    {
        QSGRendererInterface *renderer = window->rendererInterface();
        return renderer != nullptr && renderer->graphicsApi() == QSGRendererInterface::OpenGL;
    }

    /// Opens the shipped scene on the library above with a profile chosen, so
    /// resume points are kept.
    [[nodiscard]] bool open(Env &env)
    {
        if (!writeLibrary(env.tv.path(), env.movies.path())) {
            return false;
        }
        env.controller.setStartFullscreen(false);
        env.controller.settings()->setTvShowsRoots({env.tv.path()});
        env.controller.setTemporaryLibraryRoot(env.movies.path());
        env.engine.rootContext()->setContextProperty(QStringLiteral("appController"),
                                                     &env.controller);
        env.engine.loadFromModule(QStringLiteral("Marquee"), QStringLiteral("Main"));
        if (env.engine.rootObjects().size() != 1) {
            return false;
        }
        env.window = qobject_cast<QQuickWindow *>(env.engine.rootObjects().front());
        if (env.window == nullptr) {
            return false;
        }
        constexpr int kSceneWaitMs = 30000;
        if (!QTest::qWaitFor([&env] {
                return env.controller.shows()->episodeCount() == 5
                    && env.controller.library()->rowCount() == 1;
            }, kSceneWaitMs)) {
            return false;
        }
        const ShowSummary *show = env.controller.shows()->summary(QStringLiteral("Show"));
        if (show == nullptr || show->episodes.size() != 5) {
            return false;
        }
        for (const MediaItem &episode : show->episodes) {
            env.ids.push_back(episode.id);
        }
        env.filmId = env.controller.library()
                         ->data(env.controller.library()->index(0, 0), LibraryModel::IdRole)
                         .toString();
        if (!env.controller.chooseProfile(env.controller.profiles()
                                              ->profileAt(0)
                                              .value(QStringLiteral("profileId"))
                                              .toString())) {
            return false;
        }
        return QTest::qWaitFor([&env] { return !env.controller.profileExitInFlight(); },
                               kSceneWaitMs);
    }

    /// Opens `mediaId` in the player and returns once the screen is up. Where
    /// libmpv really plays, the clip is opened and held paused so its own
    /// clock cannot move what the cases set by hand.
    [[nodiscard]] MpvVideoItem *play(Env &env, const QString &mediaId)
    {
        env.controller.playMediaId(mediaId);
        MpvVideoItem *video = nullptr;
        if (!QTest::qWaitFor([&] {
                video = env.window->findChild<MpvVideoItem *>(QStringLiteral("videoSurface"));
                return video != nullptr && itemNamed(env.window, "playerScreen") != nullptr
                    && env.controller.player()->mediaId() == mediaId;
            }, 30000)) {
            return nullptr;
        }
        return hold(env, video) ? video : nullptr;
    }

    [[nodiscard]] bool hold(Env &env, MpvVideoItem *video)
    {
        video->useNullAudioOutputForTest();
        if (glRenders(env.window)) {
            if (!QTest::qWaitFor([video] { return video->duration() > 0.0; }, 30000)) {
                return false;
            }
            video->pause();
        }
        // libmpv answers the item's property subscriptions shortly after it
        // starts, with a length of 0 for a file it has not opened; that
        // answer must be in before the clock is set by hand, or it takes the
        // length away again.
        QTest::qWait(600);
        return true;
    }

    /// The clock the player reports, set by hand: the item's own slots, the
    /// way tst_playback delivers libmpv's reports.
    static bool clockAt(MpvVideoItem *video, double position, double duration = kEpisodeSeconds)
    {
        return QMetaObject::invokeMethod(video, "setDurationValue", Q_ARG(double, duration))
            && QMetaObject::invokeMethod(video, "setPositionValue", Q_ARG(double, position));
    }

    static bool endOfFile(MpvVideoItem *video)
    {
        return QMetaObject::invokeMethod(video, "playbackEnded");
    }

    static void showHud(QQuickWindow *window)
    {
        QQuickItem *screen = itemNamed(window, "playerScreen");
        QMetaObject::invokeMethod(screen, "revealHud");
    }

    [[nodiscard]] static QPoint centreOf(QQuickItem *item)
    {
        return item->mapToScene(QPointF(item->width() / 2, item->height() / 2)).toPoint();
    }

    /// Walks the remote from the picture onto the HUD control called `name`.
    [[nodiscard]] static bool focusControl(QQuickWindow *window, const char *name)
    {
        QQuickItem *screen = itemNamed(window, "playerScreen");
        screen->forceActiveFocus();
        QQuickItem *target = itemNamed(window, name);
        if (screen == nullptr || target == nullptr) {
            return false;
        }
        showHud(window);
        QTest::keyClick(window, Qt::Key_Down);
        for (int step = 0; step < 14; ++step) {
            QTest::keyClick(window, Qt::Key_Left);
        }
        for (int step = 0; step < 14 && !target->hasActiveFocus(); ++step) {
            QTest::keyClick(window, Qt::Key_Right);
        }
        return target->hasActiveFocus();
    }

    [[nodiscard]] static bool cardIsUp(QQuickWindow *window)
    {
        QQuickItem *card = itemNamed(window, "nextEpisodeCard");
        return card != nullptr && card->isVisible() && card->opacity() > 0.99;
    }

    /// An episode saved 300 s into its 22 minutes, as the progress rules keep.
    static void saveResumePoint(Env &env, int index, double seconds)
    {
        const ShowSummary *show = env.controller.shows()->summary(QStringLiteral("Show"));
        env.controller.player()->prepare(show->episodes.at(index).absolutePath,
                                         QStringLiteral("Show"), env.ids.at(index), 0);
        env.controller.player()->reportPlayback(seconds, kEpisodeSeconds, false);
        env.controller.player()->endSession();
    }

    /// Two presses 80 ms apart, the way a double click or a held-down remote
    /// button arrives.
    static void clickTwice(QQuickWindow *window, const QPoint &at)
    {
        QTest::mouseClick(window, Qt::LeftButton, Qt::NoModifier, at);
        QTest::qWait(80);
        QTest::mouseClick(window, Qt::LeftButton, Qt::NoModifier, at);
    }

    /// The second press must not read the episode that just started as the one
    /// to leave: the next episode starts once, and what the viewer watched of
    /// it is the point it is left at.
    static void verifyStartedOnlyTheSecondEpisode(Env &env)
    {
        QTRY_COMPARE(env.controller.player()->mediaId(), env.ids.at(1));
        QTest::qWait(600);
        QCOMPARE(env.controller.player()->mediaId(), env.ids.at(1));
        QCOMPARE(env.controller.player()->subtitle(),
                 QStringLiteral("S1 E2 \u00B7 Second"));
    }

    /// Brings "Still watching?" up at the end of the fourth episode and returns
    /// where the HUD's Next Episode control sits.
    [[nodiscard]] bool askStillWatching(Env &env, qint64 &now, QPoint &controlAt)
    {
        env.controller.setStillWatchingClockForTest([&now] { return now; });
        if (play(env, env.ids.at(0)) == nullptr) {
            return false;
        }
        for (int index = 0; index < 3; ++index) {
            now += 33 * kMinuteMs;
            if (!env.controller.continueAfterPlayback(env.ids.at(index))) {
                return false;
            }
        }
        MpvVideoItem *video = play(env, env.ids.at(3));
        if (video == nullptr || !clockAt(video, kEpisodeSeconds)) {
            return false;
        }
        QQuickItem *control = itemNamed(env.window, "nextEpisodeControl");
        showHud(env.window);
        if (!QTest::qWaitFor([control] { return control->isVisible() && control->width() > 0; },
                             10000)) {
            return false;
        }
        controlAt = centreOf(control);
        if (!endOfFile(video)) {
            return false;
        }
        QQuickItem *prompt = itemNamed(env.window, "stillWatchingPrompt");
        return QTest::qWaitFor([prompt] { return prompt->isVisible() && prompt->opacity() > 0.99; },
                               10000);
    }

private slots:
    void theHudControlIsThereOnlyWhileAnEpisodeWithANextOnePlays()
    {
        Env env;
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
        QVERIFY(open(env));

        MpvVideoItem *video = play(env, env.ids.at(0));
        QVERIFY(video != nullptr);
        QQuickItem *control = itemNamed(env.window, "nextEpisodeControl");
        QVERIFY2(control != nullptr, "The HUD carries no Next Episode control");
        showHud(env.window);
        QTRY_VERIFY(control->isVisible());

        // Into the next season: the second season's first episode follows
        // the first season's last, so S1 E3 still has a control.
        QVERIFY(play(env, env.ids.at(2)) != nullptr);
        showHud(env.window);
        QTRY_VERIFY(control->isVisible());

        // The last episode and a film have none.
        QVERIFY(play(env, env.ids.at(4)) != nullptr);
        showHud(env.window);
        QTRY_VERIFY(!control->isVisible());
        QVERIFY(play(env, env.filmId) != nullptr);
        showHud(env.window);
        QTRY_VERIFY(!control->isVisible());
        QVERIFY(!env.controller.hasNextEpisode());
    }

    void theRemoteReachesTheControlAfterSkipForwardAndBeforeSpeed()
    {
        Env env;
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
        QVERIFY(open(env));
        QVERIFY(play(env, env.ids.at(0)) != nullptr);
        QQuickItem *skipForward = itemNamed(env.window, "skipForwardControl");
        QQuickItem *next = itemNamed(env.window, "nextEpisodeControl");
        QQuickItem *speed = itemNamed(env.window, "speedButton");
        QVERIFY(skipForward && next && speed);

        QVERIFY(focusControl(env.window, "skipForwardControl"));
        QTest::keyClick(env.window, Qt::Key_Right);
        QTRY_VERIFY(next->hasActiveFocus());
        QTest::keyClick(env.window, Qt::Key_Right);
        QTRY_VERIFY(speed->hasActiveFocus());
        QTest::keyClick(env.window, Qt::Key_Left);
        QTRY_VERIFY(next->hasActiveFocus());

        // Where no episode follows the remote steps straight over the gap.
        QVERIFY(play(env, env.ids.at(4)) != nullptr);
        QVERIFY(focusControl(env.window, "skipForwardControl"));
        QTest::keyClick(env.window, Qt::Key_Right);
        QTRY_VERIFY(speed->hasActiveFocus());
    }

    void enterOnTheControlStartsTheNextEpisodeAtItsSavedPosition()
    {
        Env env;
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
        QVERIFY(open(env));
        saveResumePoint(env, 1, 300.0);
        QCOMPARE(env.controller.shows()->episodeForId(env.ids.at(1))->resumePositionMs,
                 5 * kMinuteMs);

        QVERIFY(play(env, env.ids.at(0)) != nullptr);
        QCOMPARE(env.controller.player()->startPosition(), 0.0);
        QVERIFY(focusControl(env.window, "nextEpisodeControl"));
        QTest::keyClick(env.window, Qt::Key_Return);

        QTRY_COMPARE(env.controller.player()->mediaId(), env.ids.at(1));
        QCOMPARE(env.controller.player()->startPosition(), 300.0);
        QCOMPARE(env.controller.player()->subtitle(),
                 QStringLiteral("S1 E2 \u00B7 Second"));
        QCOMPARE(env.controller.navigation()->route(), NavigationController::Route::Player);
    }

    void aTapOnTheControlStartsTheNextEpisodeFromTheStartWhenNothingIsSaved()
    {
        Env env;
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
        QVERIFY(open(env));
        QVERIFY(play(env, env.ids.at(2)) != nullptr);
        QQuickItem *control = itemNamed(env.window, "nextEpisodeControl");
        showHud(env.window);
        QTRY_VERIFY(control->isVisible() && control->width() > 0);

        QTest::mouseClick(env.window, Qt::LeftButton, Qt::NoModifier, centreOf(control));

        // Crossing from S1 E3 into season 2.
        QTRY_COMPARE(env.controller.player()->mediaId(), env.ids.at(3));
        QCOMPARE(env.controller.player()->startPosition(), 0.0);
    }

    /// A pause belongs to the episode it was pressed in: the oracle builds a
    /// fresh player per file, and libmpv would otherwise keep it, leaving the
    /// next episode paused and stuck in startup.
    void aPausedEpisodeDoesNotPauseTheNextOne()
    {
        Env env;
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
        QVERIFY(open(env));
        MpvVideoItem *video = play(env, env.ids.at(0));
        QVERIFY(video != nullptr);
        video->pause();
        QTRY_VERIFY_WITH_TIMEOUT(video->paused(), 5000);
        QQuickItem *control = itemNamed(env.window, "nextEpisodeControl");
        showHud(env.window);
        QTRY_VERIFY(control->isVisible() && control->width() > 0);

        QTest::mouseClick(env.window, Qt::LeftButton, Qt::NoModifier, centreOf(control));

        QTRY_COMPARE(env.controller.player()->mediaId(), env.ids.at(1));
        video = env.window->findChild<MpvVideoItem *>(QStringLiteral("videoSurface"));
        QVERIFY(video != nullptr);
        QVERIFY(!video->paused());
        QCOMPARE(video->propertyForTest(QStringLiteral("pause")), QStringLiteral("no"));
        if (glRenders(env.window)) {
            QTRY_VERIFY_WITH_TIMEOUT(!video->startupPending(), 15000);
            QVERIFY(!video->paused());
        }
    }

    void theControlWorksWithAutoPlayOffAndNoCardComes()
    {
        Env env;
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
        QVERIFY(open(env));
        env.controller.settings()->setAutoPlayNextEpisode(false);
        MpvVideoItem *video = play(env, env.ids.at(0));
        QVERIFY(video != nullptr);

        QQuickItem *control = itemNamed(env.window, "nextEpisodeControl");
        showHud(env.window);
        QTRY_VERIFY(control->isVisible());
        QVERIFY(clockAt(video, kEpisodeSeconds - 20.0));
        QTest::qWait(300);
        QVERIFY2(!cardIsUp(env.window), "The card came with Auto-play Next Episode off");

        // The control still starts the next episode, card or no card.
        QVERIFY(focusControl(env.window, "nextEpisodeControl"));
        QTest::keyClick(env.window, Qt::Key_Return);
        QTRY_COMPARE(env.controller.player()->mediaId(), env.ids.at(1));
        QCOMPARE(env.controller.navigation()->route(), NavigationController::Route::Player);
        QVERIFY(!cardIsUp(env.window));

        // The end of that file starts nothing and leaves the player.
        MpvVideoItem *second = env.window->findChild<MpvVideoItem *>(QStringLiteral("videoSurface"));
        QVERIFY(second != nullptr);
        QVERIFY(hold(env, second));
        QVERIFY(clockAt(second, kEpisodeSeconds - 20.0));
        QTest::qWait(300);
        QVERIFY2(!cardIsUp(env.window), "The card came with Auto-play Next Episode off");
        QVERIFY(endOfFile(second));
        QTRY_VERIFY(env.controller.navigation()->route() != NavigationController::Route::Player);
        QVERIFY(env.controller.player()->mediaId().isEmpty());
    }

    void theCardComesAtTheLeadTimeTakesFocusAndCountsDown()
    {
        Env env;
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
        QVERIFY(open(env));
        MpvVideoItem *video = play(env, env.ids.at(0));
        QVERIFY(video != nullptr);
        QQuickItem *playNow = itemNamed(env.window, "nextEpisodeCardPlayNow");
        QQuickItem *hide = itemNamed(env.window, "nextEpisodeCardHide");
        QQuickItem *countdown = itemNamed(env.window, "nextEpisodeCardCountdown");
        QQuickItem *title = itemNamed(env.window, "nextEpisodeCardTitle");
        QVERIFY(playNow && hide && countdown && title);

        // 22 minutes: 30 s before the end. 31 s out there is no card.
        QVERIFY(clockAt(video, kEpisodeSeconds - 31.0));
        QTest::qWait(300);
        QVERIFY(!cardIsUp(env.window));

        QVERIFY(clockAt(video, kEpisodeSeconds - 30.0));
        QTRY_VERIFY(cardIsUp(env.window));
        QCOMPARE(countdown->property("text").toString(), QStringLiteral("Next episode in 30"));
        QCOMPARE(title->property("text").toString(), QStringLiteral("S1 E2 \u00B7 Second"));
        // Play Now takes the remote the moment the card appears.
        QTRY_VERIFY(playNow->hasActiveFocus());

        QVERIFY(clockAt(video, kEpisodeSeconds - 12.0));
        QTRY_COMPARE(countdown->property("text").toString(), QStringLiteral("Next episode in 12"));

        // Left and Right walk the card's two buttons.
        QTest::keyClick(env.window, Qt::Key_Right);
        QTRY_VERIFY(hide->hasActiveFocus());
        QTest::keyClick(env.window, Qt::Key_Left);
        QTRY_VERIFY(playNow->hasActiveFocus());
    }

    void theLeadTimeGrowsWithTheEpisodeLengthAndShortEpisodesGetNoCard()
    {
        Env env;
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
        QVERIFY(open(env));
        MpvVideoItem *video = play(env, env.ids.at(0));
        QVERIFY(video != nullptr);

        const double fortyFive = 45.0 * 60.0;
        QVERIFY(clockAt(video, fortyFive - 36.0, fortyFive));
        QTest::qWait(300);
        QVERIFY(!cardIsUp(env.window));
        QVERIFY(clockAt(video, fortyFive - 35.0, fortyFive));
        QTRY_VERIFY(cardIsUp(env.window));

        const double fiftyFive = 55.0 * 60.0;
        QVERIFY(clockAt(video, 0.0, fiftyFive));
        QTRY_VERIFY(!cardIsUp(env.window));
        QVERIFY(clockAt(video, fiftyFive - 41.0, fiftyFive));
        QTest::qWait(300);
        QVERIFY(!cardIsUp(env.window));
        QVERIFY(clockAt(video, fiftyFive - 40.0, fiftyFive));
        QTRY_VERIFY(cardIsUp(env.window));

        const double nineMinutes = 9.0 * 60.0;
        QVERIFY(clockAt(video, 0.0, nineMinutes));
        QTRY_VERIFY(!cardIsUp(env.window));
        QVERIFY(clockAt(video, nineMinutes - 10.0, nineMinutes));
        QTest::qWait(300);
        QVERIFY2(!cardIsUp(env.window), "A nine-minute episode got a card");
    }

    void noCardComesForTheLastEpisodeOrAFilm()
    {
        Env env;
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
        QVERIFY(open(env));
        for (const QString &id : {env.ids.at(4), env.filmId}) {
            MpvVideoItem *video = play(env, id);
            QVERIFY(video != nullptr);
            QVERIFY(clockAt(video, kEpisodeSeconds - 10.0));
            QTest::qWait(300);
            QVERIFY(!cardIsUp(env.window));
        }
    }

    void playNowStartsTheNextEpisodeAtOnceAtItsSavedPosition()
    {
        Env env;
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
        QVERIFY(open(env));
        saveResumePoint(env, 1, 400.0);
        MpvVideoItem *video = play(env, env.ids.at(0));
        QVERIFY(video != nullptr);
        QVERIFY(clockAt(video, kEpisodeSeconds - 25.0));
        QTRY_VERIFY(cardIsUp(env.window));
        QQuickItem *playNow = itemNamed(env.window, "nextEpisodeCardPlayNow");
        QTRY_VERIFY(playNow->hasActiveFocus());

        QTest::keyClick(env.window, Qt::Key_Return);

        QTRY_COMPARE(env.controller.player()->mediaId(), env.ids.at(1));
        QCOMPARE(env.controller.player()->startPosition(), 400.0);
    }

    void hideRemovesTheCardAndTheEpisodeStillAutoPlays()
    {
        Env env;
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
        QVERIFY(open(env));
        MpvVideoItem *video = play(env, env.ids.at(0));
        QVERIFY(video != nullptr);
        QVERIFY(clockAt(video, kEpisodeSeconds - 25.0));
        QTRY_VERIFY(cardIsUp(env.window));
        QQuickItem *playNow = itemNamed(env.window, "nextEpisodeCardPlayNow");
        QQuickItem *hide = itemNamed(env.window, "nextEpisodeCardHide");
        QTRY_VERIFY(playNow->hasActiveFocus());

        QTest::keyClick(env.window, Qt::Key_Right);
        QTRY_VERIFY(hide->hasActiveFocus());
        QTest::keyClick(env.window, Qt::Key_Return);
        QTRY_VERIFY(!cardIsUp(env.window));
        QVERIFY(!playNow->hasActiveFocus() && !hide->hasActiveFocus());
        QCOMPARE(env.controller.player()->mediaId(), env.ids.at(0));

        // Seeking back and reaching the lead time again leaves it hidden.
        QVERIFY(clockAt(video, 60.0));
        QVERIFY(clockAt(video, kEpisodeSeconds - 10.0));
        QTest::qWait(300);
        QVERIFY(!cardIsUp(env.window));

        // The end of the file still starts the next episode.
        QVERIFY(endOfFile(video));
        QTRY_COMPARE(env.controller.player()->mediaId(), env.ids.at(1));
        QCOMPARE(env.controller.navigation()->route(), NavigationController::Route::Player);
    }

    void seekingBackRemovesTheCardAndReachingTheLeadTimeShowsItAgain()
    {
        Env env;
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
        QVERIFY(open(env));
        MpvVideoItem *video = play(env, env.ids.at(0));
        QVERIFY(video != nullptr);
        QVERIFY(clockAt(video, kEpisodeSeconds - 20.0));
        QTRY_VERIFY(cardIsUp(env.window));

        QVERIFY(clockAt(video, kEpisodeSeconds - 120.0));
        QTRY_VERIFY(!cardIsUp(env.window));
        QQuickItem *playNow = itemNamed(env.window, "nextEpisodeCardPlayNow");
        QVERIFY2(!playNow->hasActiveFocus(), "The hidden card kept the remote");

        QVERIFY(clockAt(video, kEpisodeSeconds - 29.0));
        QTRY_VERIFY(cardIsUp(env.window));
        QTRY_VERIFY(playNow->hasActiveFocus());
    }

    void backHidesTheCardThenTheHudThenLeaves()
    {
        Env env;
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
        QVERIFY(open(env));
        MpvVideoItem *video = play(env, env.ids.at(0));
        QVERIFY(video != nullptr);
        QQuickItem *screen = itemNamed(env.window, "playerScreen");
        QQuickItem *scrim = itemNamed(env.window, "playerScrim");
        showHud(env.window);
        QVERIFY(clockAt(video, kEpisodeSeconds - 20.0));
        QTRY_VERIFY(cardIsUp(env.window));
        QTRY_VERIFY(itemNamed(env.window, "nextEpisodeCardPlayNow")->hasActiveFocus());
        QVERIFY(screen->property("controlsVisible").toBool());

        // First Back: the card, with the HUD still up.
        QTest::keyClick(env.window, Qt::Key_Escape);
        QTRY_VERIFY(!cardIsUp(env.window));
        QVERIFY(screen->property("controlsVisible").toBool());
        QCOMPARE(env.controller.navigation()->route(), NavigationController::Route::Player);

        // Second: the HUD.
        QTest::keyClick(env.window, Qt::Key_Escape);
        QTRY_VERIFY(!screen->property("controlsVisible").toBool());
        QTRY_VERIFY(!scrim->isVisible());
        QCOMPARE(env.controller.navigation()->route(), NavigationController::Route::Player);

        // Third: leave.
        QTest::keyClick(env.window, Qt::Key_Escape);
        QTRY_VERIFY(env.controller.navigation()->route() != NavigationController::Route::Player);
    }

    void autoPlayAtTheEndResumesTheNextEpisodesOwnSavedPosition()
    {
        Env env;
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
        QVERIFY(open(env));
        saveResumePoint(env, 1, 600.0);
        MpvVideoItem *video = play(env, env.ids.at(0));
        QVERIFY(video != nullptr);
        QVERIFY(clockAt(video, kEpisodeSeconds));

        QVERIFY(endOfFile(video));

        QTRY_COMPARE(env.controller.player()->mediaId(), env.ids.at(1));
        QCOMPARE(env.controller.player()->startPosition(), 600.0);
        QCOMPARE(env.controller.navigation()->route(), NavigationController::Route::Player);

        // The episode after that has nothing saved and starts at 0:00.
        MpvVideoItem *second = env.window->findChild<MpvVideoItem *>(QStringLiteral("videoSurface"));
        QVERIFY(second != nullptr);
        QVERIFY(hold(env, second));
        // A file ends only after it has played; the screen ignores an end
        // that arrives before the episode it just started has begun.
        QVERIFY(clockAt(second, kEpisodeSeconds));
        QVERIFY(endOfFile(second));
        QTRY_COMPARE(env.controller.player()->mediaId(), env.ids.at(2));
        QCOMPARE(env.controller.player()->startPosition(), 0.0);
    }

    void theEndOfTheLastEpisodeReturnsToTheShowPage()
    {
        Env env;
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
        QVERIFY(open(env));
        env.controller.navigation()->resetTo(NavigationController::Route::Home);
        MpvVideoItem *video = play(env, env.ids.at(4));
        QVERIFY(video != nullptr);
        QVERIFY(clockAt(video, kEpisodeSeconds));

        QVERIFY(endOfFile(video));

        QTRY_COMPARE(env.controller.navigation()->route(),
                     NavigationController::Route::ShowDetail);
        QCOMPARE(env.controller.navigation()->selectedMediaId(), QStringLiteral("Show"));
    }

    void aFilmEndingLeavesToWhereItWasOpenedFrom()
    {
        Env env;
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
        QVERIFY(open(env));
        env.controller.navigation()->resetTo(NavigationController::Route::Movies);
        MpvVideoItem *video = play(env, env.filmId);
        QVERIFY(video != nullptr);

        QVERIFY(endOfFile(video));

        QTRY_COMPARE(env.controller.navigation()->route(), NavigationController::Route::Movies);
    }

    void stillWatchingAsksAfterThreeAutoPlaysAndNinetyIdleMinutes()
    {
        Env env;
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
        QVERIFY(open(env));
        qint64 now = 0;
        env.controller.setStillWatchingClockForTest([&now] { return now; });

        // Three episodes handed over by auto-play, 100 minutes in all, with
        // nobody touching a key.
        QVERIFY(play(env, env.ids.at(0)) != nullptr);
        for (int index = 0; index < 3; ++index) {
            now += 33 * kMinuteMs;
            QVERIFY(env.controller.continueAfterPlayback(env.ids.at(index)));
        }
        MpvVideoItem *video = play(env, env.ids.at(3));
        QVERIFY(video != nullptr);
        QVERIFY(clockAt(video, kEpisodeSeconds));
        QVERIFY(env.controller.stillWatchingDue(env.ids.at(3)));

        QVERIFY(endOfFile(video));

        QQuickItem *prompt = itemNamed(env.window, "stillWatchingPrompt");
        QQuickItem *cont = itemNamed(env.window, "stillWatchingContinue");
        QVERIFY(prompt && cont);
        QTRY_VERIFY(prompt->isVisible() && prompt->opacity() > 0.99);
        QCOMPARE(itemNamed(env.window, "stillWatchingTitle")->property("text").toString(),
                 QStringLiteral("Still watching?"));
        // The next episode did not start, and Continue holds the remote.
        QCOMPARE(env.controller.player()->mediaId(), env.ids.at(3));
        QTRY_VERIFY(cont->hasActiveFocus());

        QTest::keyClick(env.window, Qt::Key_Return);
        QTRY_COMPARE(env.controller.player()->mediaId(), env.ids.at(4));
        QCOMPARE(env.controller.navigation()->route(), NavigationController::Route::Player);
    }

    void stopOnStillWatchingLeavesThePlayer()
    {
        Env env;
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
        QVERIFY(open(env));
        qint64 now = 0;
        env.controller.setStillWatchingClockForTest([&now] { return now; });
        QVERIFY(play(env, env.ids.at(0)) != nullptr);
        for (int index = 0; index < 3; ++index) {
            QVERIFY(env.controller.continueAfterPlayback(env.ids.at(index)));
        }
        now += 91 * kMinuteMs;
        MpvVideoItem *video = play(env, env.ids.at(3));
        QVERIFY(video != nullptr);
        QVERIFY(clockAt(video, kEpisodeSeconds));
        QVERIFY(endOfFile(video));
        QQuickItem *cont = itemNamed(env.window, "stillWatchingContinue");
        QQuickItem *stop = itemNamed(env.window, "stillWatchingStop");
        QTRY_VERIFY(cont->hasActiveFocus());

        QTest::keyClick(env.window, Qt::Key_Right);
        QTRY_VERIFY(stop->hasActiveFocus());
        QTest::keyClick(env.window, Qt::Key_Return);

        QTRY_VERIFY(env.controller.navigation()->route() != NavigationController::Route::Player);
    }

    void anInputBeforeTheEndResetsTheStillWatchingCounts()
    {
        Env env;
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
        QVERIFY(open(env));
        qint64 now = 0;
        env.controller.setStillWatchingClockForTest([&now] { return now; });
        QVERIFY(play(env, env.ids.at(0)) != nullptr);
        for (int index = 0; index < 3; ++index) {
            QVERIFY(env.controller.continueAfterPlayback(env.ids.at(index)));
        }
        now += 120 * kMinuteMs;
        MpvVideoItem *video = play(env, env.ids.at(3));
        QVERIFY(video != nullptr);
        QVERIFY(env.controller.stillWatchingDue(env.ids.at(3)));

        // A remote key; a pointer press would do as well.
        QTest::keyClick(env.window, Qt::Key_Down);
        QVERIFY(!env.controller.stillWatchingDue(env.ids.at(3)));

        QVERIFY(clockAt(video, kEpisodeSeconds));
        QVERIFY(endOfFile(video));
        QTRY_COMPARE(env.controller.player()->mediaId(), env.ids.at(4));
    }

    void aPointerPressAlsoResetsTheStillWatchingCounts()
    {
        Env env;
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
        QVERIFY(open(env));
        qint64 now = 0;
        env.controller.setStillWatchingClockForTest([&now] { return now; });
        QVERIFY(play(env, env.ids.at(0)) != nullptr);
        for (int index = 0; index < 3; ++index) {
            QVERIFY(env.controller.continueAfterPlayback(env.ids.at(index)));
        }
        now += 120 * kMinuteMs;
        QVERIFY(env.controller.stillWatchingDue(env.ids.at(3)));

        QTest::mouseClick(env.window, Qt::LeftButton, Qt::NoModifier, QPoint(5, 5));

        QVERIFY(!env.controller.stillWatchingDue(env.ids.at(3)));
    }

    void anEndOfFileRightAfterPlayNowDoesNotSkipAnEpisode()
    {
        Env env;
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
        QVERIFY(open(env));
        MpvVideoItem *video = play(env, env.ids.at(0));
        QVERIFY(video != nullptr);
        QVERIFY(clockAt(video, kEpisodeSeconds - 25.0));
        QTRY_VERIFY(cardIsUp(env.window));
        QQuickItem *playNow = itemNamed(env.window, "nextEpisodeCardPlayNow");
        QTRY_VERIFY(playNow->hasActiveFocus());

        // Play Now, and the old file's end arrives before the new one plays.
        QTest::keyClick(env.window, Qt::Key_Return);
        QVERIFY(endOfFile(video));

        verifyStartedOnlyTheSecondEpisode(env);
    }

    void aDoubleClickOnPlayNowStartsOnlyTheNextEpisode()
    {
        Env env;
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
        QVERIFY(open(env));
        MpvVideoItem *video = play(env, env.ids.at(0));
        QVERIFY(video != nullptr);
        QVERIFY(clockAt(video, kEpisodeSeconds - 25.0));
        QTRY_VERIFY(cardIsUp(env.window));
        QQuickItem *playNow = itemNamed(env.window, "nextEpisodeCardPlayNow");
        QVERIFY(playNow->width() > 0);

        clickTwice(env.window, centreOf(playNow));

        verifyStartedOnlyTheSecondEpisode(env);

        // The episode that started is the one the session now records.
        MpvVideoItem *second = env.window->findChild<MpvVideoItem *>(QStringLiteral("videoSurface"));
        QVERIFY(second != nullptr);
        QVERIFY(hold(env, second));
        QVERIFY(clockAt(second, 300.0));
        env.controller.player()->endSession();
        QTRY_COMPARE(env.controller.shows()->episodeForId(env.ids.at(1))->resumePositionMs,
                     5 * kMinuteMs);
        QVERIFY(env.controller.shows()->episodeForId(env.ids.at(2))->resumePositionMs == 0);
    }

    void aDoubleClickOnTheHudControlStartsOnlyTheNextEpisode()
    {
        Env env;
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
        QVERIFY(open(env));
        QVERIFY(play(env, env.ids.at(0)) != nullptr);
        QQuickItem *control = itemNamed(env.window, "nextEpisodeControl");
        showHud(env.window);
        QTRY_VERIFY(control->isVisible() && control->width() > 0);

        clickTwice(env.window, centreOf(control));

        verifyStartedOnlyTheSecondEpisode(env);
    }

    void aClickRightAfterTheAutoPlayHandoffDoesNotSkipAnEpisode()
    {
        Env env;
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
        QVERIFY(open(env));
        MpvVideoItem *video = play(env, env.ids.at(0));
        QVERIFY(video != nullptr);
        QQuickItem *control = itemNamed(env.window, "nextEpisodeControl");
        showHud(env.window);
        QTRY_VERIFY(control->isVisible() && control->width() > 0);

        QVERIFY(endOfFile(video));
        QTest::mouseClick(env.window, Qt::LeftButton, Qt::NoModifier, centreOf(control));

        verifyStartedOnlyTheSecondEpisode(env);
    }

    void twoQuickEntersOnTheControlStartOnlyTheNextEpisode()
    {
        Env env;
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
        QVERIFY(open(env));
        QVERIFY(play(env, env.ids.at(0)) != nullptr);
        QVERIFY(focusControl(env.window, "nextEpisodeControl"));

        QTest::keyClick(env.window, Qt::Key_Return);
        QTest::qWait(80);
        QTest::keyClick(env.window, Qt::Key_Return);

        verifyStartedOnlyTheSecondEpisode(env);
    }

    void thePointerDoesNotReachTheHudThroughStillWatching()
    {
        Env env;
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
        QVERIFY(open(env));
        qint64 now = 0;
        QPoint controlAt;
        QVERIFY(askStillWatching(env, now, controlAt));
        QQuickItem *screen = itemNamed(env.window, "playerScreen");
        QTRY_VERIFY(!screen->property("controlsVisible").toBool());

        // A moving pointer brings the HUD back everywhere else.
        QTest::mouseMove(env.window, QPoint(40, 40));
        QTest::mouseMove(env.window, QPoint(300, 200));
        QTest::mouseMove(env.window, controlAt);
        QTest::qWait(300);
        QVERIFY2(!screen->property("controlsVisible").toBool(),
                 "A moving pointer brought the HUD back under the question");

        QTest::mouseClick(env.window, Qt::LeftButton, Qt::NoModifier, controlAt);
        QTest::qWait(300);
        QCOMPARE(env.controller.player()->mediaId(), env.ids.at(3));
        QVERIFY(!screen->property("controlsVisible").toBool());
        QVERIFY(screen->property("stillWatching").toBool());

        // The question is still the viewer's to answer.
        QQuickItem *cont = itemNamed(env.window, "stillWatchingContinue");
        QTest::mouseClick(env.window, Qt::LeftButton, Qt::NoModifier, centreOf(cont));
        QTRY_COMPARE(env.controller.player()->mediaId(), env.ids.at(4));
    }

    void aDoubleClickOnContinueStartsOnlyTheNextEpisode()
    {
        Env env;
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
        QVERIFY(open(env));
        qint64 now = 0;
        QPoint controlAt;
        QVERIFY(askStillWatching(env, now, controlAt));
        QQuickItem *cont = itemNamed(env.window, "stillWatchingContinue");

        clickTwice(env.window, centreOf(cont));

        // S1 E5 is the last episode: a second Continue read as "leave E5"
        // would end the player.
        QTRY_COMPARE(env.controller.player()->mediaId(), env.ids.at(4));
        QTest::qWait(600);
        QCOMPARE(env.controller.player()->mediaId(), env.ids.at(4));
        QCOMPARE(env.controller.navigation()->route(), NavigationController::Route::Player);
    }

    void anUnreadableNextFileSaysSoOnTheControlAndOnPlayNow()
    {
        Env env;
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
        QVERIFY(open(env));
        MpvVideoItem *video = play(env, env.ids.at(0));
        QVERIFY(video != nullptr);
        QVERIFY(QFile::remove(env.tv.path()
                              + QStringLiteral("/Show (2020)/Season 1/Show - S01E02 - Second.mkv")));
        QVERIFY(!env.controller.hasError());

        QVERIFY(focusControl(env.window, "nextEpisodeControl"));
        QTest::keyClick(env.window, Qt::Key_Return);
        QTRY_VERIFY(env.controller.hasError());
        QCOMPARE(env.controller.errorTitle(), QStringLiteral("Title unavailable"));
        QVERIFY(env.controller.errorMessage().contains(QStringLiteral("Second")));
        QCOMPARE(env.controller.player()->mediaId(), env.ids.at(0));
        QCOMPARE(env.controller.navigation()->route(), NavigationController::Route::Player);

        env.controller.dismissError();
        QVERIFY(!env.controller.hasError());
        QVERIFY(clockAt(video, kEpisodeSeconds - 25.0));
        QTRY_VERIFY(cardIsUp(env.window));
        QQuickItem *playNow = itemNamed(env.window, "nextEpisodeCardPlayNow");
        QTRY_VERIFY(playNow->hasActiveFocus());
        QTest::keyClick(env.window, Qt::Key_Return);
        QTRY_VERIFY(env.controller.hasError());
        QCOMPARE(env.controller.errorTitle(), QStringLiteral("Title unavailable"));
        QCOMPARE(env.controller.player()->mediaId(), env.ids.at(0));
    }

    void stillWatchingNeverAsksWithAutoPlayOff()
    {
        Env env;
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
        QVERIFY(open(env));
        qint64 now = 0;
        env.controller.setStillWatchingClockForTest([&now] { return now; });
        for (int index = 0; index < 3; ++index) {
            QVERIFY(env.controller.continueAfterPlayback(env.ids.at(index)));
        }
        now += 120 * kMinuteMs;
        QVERIFY(env.controller.stillWatchingDue(env.ids.at(3)));
        env.controller.settings()->setAutoPlayNextEpisode(false);
        QVERIFY(!env.controller.stillWatchingDue(env.ids.at(3)));
    }
};

int main(int argc, char *argv[])
{
    QGuiApplication app(argc, argv);
    // The player surface builds a libmpv core, which refuses to start under a
    // locale whose decimal separator is not a dot.
    std::setlocale(LC_NUMERIC, "C");
    NextEpisodeFlowTest test;
    return QTest::qExec(&test, argc, argv);
}

#include "tst_next_episode_flow.moc"
