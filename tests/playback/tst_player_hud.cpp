#include <clocale>

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QGuiApplication>
#include <QIODevice>
#include <QKeyEvent>
#include <QPointer>
#include <QPointF>
#include <QProcess>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickItem>
#include <QQuickWindow>
#include <QScopeGuard>
#include <QSignalSpy>
#include <QStandardPaths>
#include <QTemporaryDir>
#include <QTest>

#include "app/AppPaths.hpp"
#include "app/ApplicationController.hpp"
#include "models/LibraryModel.hpp"
#include "navigation/NavigationController.hpp"
#include "playback/MpvVideoItem.hpp"
#include "playback/PlayerController.hpp"
#include "playback/SeekScrubber.hpp"

namespace
{
constexpr auto kFilmRelativePath = "Arrival (2016)/Arrival (2016).mkv";

// The HUD is drawn over whatever libmpv is doing, so these cases need a
// cataloged title. On a display-backed session libmpv really opens it, and a
// file it cannot read would latch the failure card, which keeps the HUD up for
// good; so the title is a real clip, a ten-minute 16x16 y4m at one frame a
// second (a few hundred kilobytes) that outlasts every case here.
[[nodiscard]] bool writeMediaFile(const QString &root, const QString &relativePath,
                                  bool withTracks = false)
{
    const QFileInfo target(QDir(root).filePath(relativePath));
    if (!QDir().mkpath(target.absolutePath())) {
        return false;
    }

    // The track cases choose tracks libmpv really has when a display lets it
    // open the file, so there the file is the film kTrackList describes. With
    // no ffmpeg the plain clip stands in, and the list is only delivered
    // through the item's slot, which is all a session without a display needs.
    if (withTracks && !QStandardPaths::findExecutable(QStringLiteral("ffmpeg")).isEmpty()) {
        const QString subtitleOne = target.absolutePath() + QStringLiteral("/one.srt");
        const QString subtitleTwo = target.absolutePath() + QStringLiteral("/two.srt");
        for (const QString &path : {subtitleOne, subtitleTwo}) {
            QFile subtitle(path);
            if (!subtitle.open(QIODevice::WriteOnly)
                || subtitle.write("1\n00:00:00,000 --> 00:00:01,500\nHello\n") <= 0) {
                return false;
            }
        }
        QProcess ffmpeg;
        ffmpeg.start(QStringLiteral("ffmpeg"),
                     {"-v", "error", "-y", "-f", "lavfi", "-i", "color=c=black:s=64x64:d=600:r=1",
                      "-f", "lavfi", "-i", "sine=d=600", "-f", "lavfi", "-i", "sine=f=880:d=600",
                      "-i", subtitleOne, "-i", subtitleTwo,
                      "-map", "0", "-map", "1", "-map", "2", "-map", "3", "-map", "4",
                      "-c:v", "mpeg4", "-c:a:0", "aac", "-c:a:1", "ac3", "-c:s", "srt",
                      "-metadata:s:a:0", "language=eng", "-metadata:s:a:1", "language=spa",
                      "-metadata:s:s:0", "language=eng", "-metadata:s:s:1", "language=fra",
                      target.absoluteFilePath()});
        return ffmpeg.waitForFinished(120000) && ffmpeg.exitStatus() == QProcess::NormalExit
            && ffmpeg.exitCode() == 0;
    }

    QFile file(target.absoluteFilePath());
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
}

namespace
{
// libmpv's `track-list` for a film with two audio and two subtitle tracks, as
// the item reads it once the file has loaded. This host cannot decode, so the
// list is delivered through the item's own slot, the way tst_playback delivers
// its other libmpv reports.
constexpr auto kTrackList = R"([
  {"id":1,"type":"video","codec":"h264"},
  {"id":1,"type":"audio","lang":"eng","codec":"aac"},
  {"id":2,"type":"audio","lang":"spa","codec":"ac3"},
  {"id":1,"type":"sub","lang":"eng","codec":"subrip"},
  {"id":2,"type":"sub","lang":"fra","codec":"subrip"}
])";
}

class PlayerHudTest final : public QObject
{
    Q_OBJECT

private:
    // Loads the shipped Marquee module linked into this binary so these cases
    // drive qml/screens/PlayerScreen.qml itself.
    QQuickWindow *loadMainWindow(ApplicationController &controller,
                                 QQmlApplicationEngine &engine)
    {
        // A fullscreen window has no usable geometry on the test platform.
        controller.setStartFullscreen(false);

        engine.rootContext()->setContextProperty(
            QStringLiteral("appController"), &controller);
        engine.loadFromModule(QStringLiteral("Marquee"), QStringLiteral("Main"));
        if (engine.rootObjects().size() != 1) {
            return nullptr;
        }
        auto *window = qobject_cast<QQuickWindow *>(engine.rootObjects().front());
        if (window != nullptr) {
            // The scene keeps the size Main.qml declares on this platform, so
            // the window is left at it: a resize the scene never hears about
            // would put the HUD outside the window a pointer event targets.
            window->requestActivate();
            // A key sent before the window is active can be dropped, which
            // left the first Down of a case unanswered one run in ten.
            if (!QTest::qWaitForWindowActive(window)) {
                return nullptr;
            }
        }
        return window;
    }

    [[nodiscard]] static QQuickItem *itemNamed(QQuickWindow *window, const char *name)
    {
        return window->findChild<QQuickItem *>(QLatin1String(name));
    }

    /// Opens the one cataloged title in `libraryPath` through the player route
    /// and returns the HUD's restart control once the surface is up.
    [[nodiscard]] QQuickItem *openPlayer(ApplicationController &controller,
                                         QQuickWindow *window,
                                         const QString &libraryPath)
    {
        controller.setTemporaryLibraryRoot(libraryPath);
        // The first scene polish used to hold this thread for about five
        // seconds (the first frame's Canvas shadow blur), which was the
        // default wait. That stall is gone on a GPU scene graph but remains
        // on the software one (see issues.md), which this suite meets
        // offscreen, so the wait stays at 30 s.
        constexpr int kSceneWaitMs = 30000;
        if (!QTest::qWaitFor(
                [&controller] { return controller.library()->rowCount() == 1; },
                kSceneWaitMs)) {
            return nullptr;
        }

        controller.playMediaId(controller.library()
                                   ->data(controller.library()->index(0, 0),
                                          LibraryModel::IdRole)
                                   .toString());

        QQuickItem *control = nullptr;
        if (!QTest::qWaitFor([window, &control] {
                control = itemNamed(window, "restartControl");
                return control != nullptr;
            }, kSceneWaitMs)) {
            return nullptr;
        }
        return control;
    }

    /// Hands the open player the tracks a loaded film would list and returns
    /// the item that carries them.
    [[nodiscard]] MpvVideoItem *giveTracks(QQuickWindow *window)
    {
        auto *video = window->findChild<MpvVideoItem *>(QStringLiteral("videoSurface"));
        if (video == nullptr) {
            return nullptr;
        }
        // A display-backed session really plays the file, and this host has
        // no sound device for it to open.
        video->useNullAudioOutputForTest();
        // libmpv reports its own `track-list` as it opens the clip, and a
        // clip without tracks reports an empty one. Those reports are
        // drained before the loaded film's list is delivered, or they would
        // take the list away again.
        QTest::qWait(1500);
        if (!QMetaObject::invokeMethod(video, "setTrackListValue",
                                       Q_ARG(QByteArray, QByteArray(kTrackList)))) {
            return nullptr;
        }
        return video;
    }

    /// Restart records the film at 0 only once libmpv has the file open, so
    /// the cases that judge it wait for the length. Without an OpenGL scene
    /// graph the item never gets its render context, so the context's arrival
    /// is delivered through the item's own slot, as tst_player_tracks does,
    /// with the null audio output because the host has no sound device.
    [[nodiscard]] static bool fileIsOpen(QQuickWindow *window)
    {
        auto *video = window->findChild<MpvVideoItem *>(QStringLiteral("videoSurface"));
        if (video == nullptr) {
            return false;
        }
        QSGRendererInterface *renderer = window->rendererInterface();
        if (renderer == nullptr || renderer->graphicsApi() != QSGRendererInterface::OpenGL) {
            video->useNullAudioOutputForTest();
            if (!QMetaObject::invokeMethod(video, "onRenderContextReady")) {
                return false;
            }
        }
        return QTest::qWaitFor([video] { return video->duration() > 0.0; }, 30000);
    }

    [[nodiscard]] static QPoint centreOf(QQuickItem *item)
    {
        return item->mapToScene(QPointF(item->width() / 2, item->height() / 2)).toPoint();
    }

    /// One open player: the library, the app, the window and the HUD's items,
    /// so each case below starts from the same place.
    struct Player
    {
        /// Points the app's paths at the temporary root while the members
        /// below it are built: the controller opens its data directory as it
        /// is constructed, so a root set later would leave it on the real
        /// `~/.local/share`.
        struct RuntimeRootScope
        {
            explicit RuntimeRootScope(const QString &path) { AppPaths::setRuntimeRoot(path); }
            ~RuntimeRootScope() { AppPaths::clearRuntimeRoot(); }
            RuntimeRootScope(const RuntimeRootScope &) = delete;
            RuntimeRootScope &operator=(const RuntimeRootScope &) = delete;
        };

        QTemporaryDir runtimeRoot;
        QTemporaryDir library;
        RuntimeRootScope paths{runtimeRoot.path()};
        ApplicationController controller;
        QQmlApplicationEngine engine;
        QQuickWindow *window{nullptr};
        MpvVideoItem *video{nullptr};
        SeekScrubber *scrubber{nullptr};
        QQuickItem *scrim{nullptr};
    };

    /// Walks the remote along the HUD to the control called `name`.
    [[nodiscard]] bool focusControl(QQuickWindow *window, const char *name)
    {
        QQuickItem *target = itemNamed(window, name);
        if (target == nullptr) {
            return false;
        }
        if (target->hasActiveFocus()) {
            return true;
        }
        QQuickItem *restart = itemNamed(window, "restartControl");
        if (restart != nullptr && !restart->hasActiveFocus()) {
            QTest::keyClick(window, Qt::Key_Down);
        }
        // Left to the first control, then right until the target holds it:
        // the remote may already stand past it.
        for (int step = 0; step < 14; ++step) {
            QTest::keyClick(window, Qt::Key_Left);
        }
        for (int step = 0; step < 14 && !target->hasActiveFocus(); ++step) {
            QTest::keyClick(window, Qt::Key_Right);
        }
        return target->hasActiveFocus();
    }

    /// A key repeat, as the keyboard sends it while a key stays down.
    static void repeatKey(QQuickWindow *window, Qt::Key key)
    {
        QKeyEvent repeat(QEvent::KeyPress, key, Qt::NoModifier, QString(), true);
        QGuiApplication::sendEvent(window, &repeat);
    }

    [[nodiscard]] bool openHud(Player &player, bool withTracks = false)
    {
        if (!writeMediaFile(player.library.path(), QLatin1String(kFilmRelativePath), withTracks)) {
            return false;
        }
        player.window = loadMainWindow(player.controller, player.engine);
        if (player.window == nullptr
            || openPlayer(player.controller, player.window, player.library.path()) == nullptr) {
            return false;
        }
        player.video =
            player.window->findChild<MpvVideoItem *>(QStringLiteral("videoSurface"));
        player.scrubber =
            player.window->findChild<SeekScrubber *>(QStringLiteral("seekScrubber"));
        player.scrim = itemNamed(player.window, "playerScrim");
        return player.video != nullptr && player.scrubber != nullptr && player.scrim != nullptr;
    }

private slots:
    void enterRestartsNothingUntilTheRemoteMovesOntoTheControl()
    {
        QTemporaryDir runtimeRoot;
        QTemporaryDir library;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
        // The y4m stand-in fails to play offscreen; the ffmpeg clip does not.
        if (QStandardPaths::findExecutable(QStringLiteral("ffmpeg")).isEmpty()) {
            QSKIP("ffmpeg is not installed, so the test clip cannot be made");
        }
        QVERIFY(writeMediaFile(library.path(), QLatin1String(kFilmRelativePath), true));

        ApplicationController controller;
        QVERIFY2(!controller.hasError(), qPrintable(controller.errorMessage()));
        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY2(window != nullptr, "qml/Main.qml did not load from the module");

        QQuickItem *control = openPlayer(controller, window, library.path());
        QVERIFY2(control != nullptr, "The player HUD carries no restart control");
        QVERIFY2(!control->hasActiveFocus(),
                 "The restart control took the remote before it was asked for");

        QVERIFY2(fileIsOpen(window), "libmpv never opened the file, so a restart has nothing to seek");
        QSignalSpy recorded(controller.player(),
                            &PlayerController::progressRecorded);

        // In front of the film the remote's Enter belongs to the picture, not
        // to a control the viewer has not moved onto.
        QTest::keyClick(window, Qt::Key_Return);
        QTest::keyClick(window, Qt::Key_Down);
        QTRY_VERIFY(control->hasActiveFocus());
        QTest::keyClick(window, Qt::Key_Return);

        QTRY_COMPARE(recorded.count(), 1);
        QCOMPARE(recorded.constFirst().at(1).toLongLong(), 0);
        QCOMPARE(controller.navigation()->route(), NavigationController::Route::Player);
        QVERIFY2(!controller.hasError(), qPrintable(controller.errorMessage()));
    }

    void movingUpHandsTheRemoteBackToThePlayer()
    {
        QTemporaryDir runtimeRoot;
        QTemporaryDir library;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
        QVERIFY(writeMediaFile(library.path(), QLatin1String(kFilmRelativePath)));

        ApplicationController controller;
        QVERIFY2(!controller.hasError(), qPrintable(controller.errorMessage()));
        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY2(window != nullptr, "qml/Main.qml did not load from the module");

        QQuickItem *control = openPlayer(controller, window, library.path());
        QVERIFY2(control != nullptr, "The player HUD carries no restart control");
        QQuickItem *screen = itemNamed(window, "playerScreen");
        QVERIFY(screen != nullptr);

        QTest::keyClick(window, Qt::Key_Down);
        QTRY_VERIFY(control->hasActiveFocus());

        QTest::keyClick(window, Qt::Key_Up);

        // The transport keys are the player's own, so leaving the control has
        // to put the remote back on the surface that reads them.
        QTRY_VERIFY(!control->hasActiveFocus());
        QVERIFY(screen->hasActiveFocus());
    }

    void tappingTheRestartControlRestartsTheFilm()
    {
        QTemporaryDir runtimeRoot;
        QTemporaryDir library;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
        if (QStandardPaths::findExecutable(QStringLiteral("ffmpeg")).isEmpty()) {
            QSKIP("ffmpeg is not installed, so the test clip cannot be made");
        }
        QVERIFY(writeMediaFile(library.path(), QLatin1String(kFilmRelativePath), true));

        ApplicationController controller;
        QVERIFY2(!controller.hasError(), qPrintable(controller.errorMessage()));
        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY2(window != nullptr, "qml/Main.qml did not load from the module");

        QQuickItem *control = openPlayer(controller, window, library.path());
        QVERIFY2(control != nullptr, "The player HUD carries no restart control");
        QTRY_VERIFY(control->width() > 0 && control->height() > 0);

        QVERIFY2(fileIsOpen(window), "libmpv never opened the file, so a restart has nothing to seek");
        QSignalSpy recorded(controller.player(),
                            &PlayerController::progressRecorded);
        const QPointF centre =
            control->mapToScene(QPointF(control->width() / 2, control->height() / 2));
        QTest::mouseClick(window, Qt::LeftButton, Qt::NoModifier, centre.toPoint());

        QTRY_COMPARE(recorded.count(), 1);
        QCOMPARE(recorded.constFirst().at(1).toLongLong(), 0);
        QCOMPARE(controller.navigation()->route(), NavigationController::Route::Player);
    }

    // PlayerControlsOverlay.swift:181: the HUD's controls grow by 1.07 when
    // they take the remote, not by the poster cards' scale.
    void theRestartControlsFocusFrameUsesTheHudScale()
    {
        QTemporaryDir runtimeRoot;
        QTemporaryDir library;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
        QVERIFY(writeMediaFile(library.path(), QLatin1String(kFilmRelativePath)));

        ApplicationController controller;
        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY2(window != nullptr, "qml/Main.qml did not load from the module");
        QQuickItem *control = openPlayer(controller, window, library.path());
        QVERIFY(control != nullptr);

        QQuickItem *frame = nullptr;
        for (QQuickItem *child : control->childItems()) {
            if (child->property("focusScale").isValid()) {
                frame = child;
            }
        }
        QVERIFY2(frame != nullptr, "The restart control carries no focus frame");
        QCOMPARE(frame->property("focusScale").toReal(), 1.07);
    }

    void thePlayerOffersNoTrackMenuForAFileWithoutChoices()
    {
        QTemporaryDir runtimeRoot;
        QTemporaryDir library;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
        QVERIFY(writeMediaFile(library.path(), QLatin1String(kFilmRelativePath)));

        ApplicationController controller;
        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY2(window != nullptr, "qml/Main.qml did not load from the module");
        QVERIFY(openPlayer(controller, window, library.path()) != nullptr);

        // PlayerControlsOverlay.swift:339-344: the subtitle menu needs a
        // subtitle, the audio menu a second audio track.
        QQuickItem *subtitles = itemNamed(window, "subtitlesButton");
        QQuickItem *audio = itemNamed(window, "audioButton");
        QVERIFY(subtitles != nullptr && audio != nullptr);
        QVERIFY(!subtitles->isVisible());
        QVERIFY(!audio->isVisible());
    }

    void theMenusOpenTakeFocusSelectWithEnterAndCloseWithEscape()
    {
        QTemporaryDir runtimeRoot;
        QTemporaryDir library;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
        QVERIFY(writeMediaFile(library.path(), QLatin1String(kFilmRelativePath), true));

        ApplicationController controller;
        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY2(window != nullptr, "qml/Main.qml did not load from the module");
        QVERIFY(openPlayer(controller, window, library.path()) != nullptr);
        MpvVideoItem *video = giveTracks(window);
        QVERIFY2(video != nullptr, "the player has no video surface");

        QQuickItem *subtitlesButton = itemNamed(window, "subtitlesButton");
        QQuickItem *audioButton = itemNamed(window, "audioButton");
        QQuickItem *subtitleMenu = itemNamed(window, "subtitlesMenu");
        QQuickItem *audioMenu = itemNamed(window, "audioMenu");
        QQuickItem *scrim = itemNamed(window, "playerScrim");
        QQuickItem *restart = itemNamed(window, "restartControl");
        QVERIFY(subtitlesButton && audioButton && subtitleMenu && audioMenu && scrim && restart);
        QTRY_VERIFY(subtitlesButton->isVisible());
        QVERIFY(audioButton->isVisible());
        QVERIFY(!subtitleMenu->isVisible());

        // Down reaches the HUD, Right walks past the transport group
        // (-10, play/pause, +30) to the Subtitles button.
        QTest::keyClick(window, Qt::Key_Down);
        QTRY_VERIFY(restart->hasActiveFocus());
        for (int step = 0; step < 4; ++step) {
            QTest::keyClick(window, Qt::Key_Right);
        }
        QTRY_VERIFY(subtitlesButton->hasActiveFocus());

        // Enter opens the menu and the menu holds the remote.
        QTest::keyClick(window, Qt::Key_Return);
        QTRY_VERIFY(subtitleMenu->isVisible());
        QTRY_VERIFY(subtitleMenu->hasActiveFocus());
        QCOMPARE(video->subtitleTrackId(), 0);

        // The Subtitles menu is "Off" and then every track: the highlight
        // starts on the current choice, Off, and Down walks to English and
        // French (PlayerControlsOverlay.swift:428-452).
        QCOMPARE(subtitleMenu->property("highlighted").toInt(), 0);
        QTest::keyClick(window, Qt::Key_Down);
        QTest::keyClick(window, Qt::Key_Down);
        QCOMPARE(subtitleMenu->property("highlighted").toInt(), 2);

        // The HUD stays up while a menu is open, past its 3-second hide.
        QTest::qWait(4200);
        QVERIFY2(scrim->isVisible(), "The HUD hid under an open track menu");
        QVERIFY(subtitleMenu->isVisible());

        QTest::keyClick(window, Qt::Key_Return);
        QTRY_COMPARE(video->subtitleTrackId(), 2);
        QTRY_VERIFY(!subtitleMenu->isVisible());
        QTRY_VERIFY(subtitlesButton->hasActiveFocus());

        // Reopened, the highlight starts on the track now playing, and Escape
        // closes the menu without leaving the player or changing the track.
        QTest::keyClick(window, Qt::Key_Return);
        QTRY_VERIFY(subtitleMenu->hasActiveFocus());
        QCOMPARE(subtitleMenu->property("highlighted").toInt(), 2);
        QTest::keyClick(window, Qt::Key_Escape);
        QTRY_VERIFY(!subtitleMenu->isVisible());
        QTRY_VERIFY(subtitlesButton->hasActiveFocus());
        QCOMPARE(controller.navigation()->route(), NavigationController::Route::Player);
        QCOMPARE(video->subtitleTrackId(), 2);

        // Audio: one more control to the right; the menu lists the two tracks
        // by language, and Down then Enter takes the second.
        QTest::keyClick(window, Qt::Key_Right);
        QTRY_VERIFY(audioButton->hasActiveFocus());
        QTest::keyClick(window, Qt::Key_Return);
        QTRY_VERIFY(audioMenu->hasActiveFocus());
        QCOMPARE(audioMenu->property("entries").toList().size(), 2);
        QCOMPARE(audioMenu->property("entries").toList().at(1).toMap().value("label").toString(),
                 QStringLiteral("Spanish (ac3)"));
        QTest::keyClick(window, Qt::Key_Down);
        QTest::keyClick(window, Qt::Key_Return);
        QTRY_COMPARE(video->audioTrackId(), 2);
        QTRY_VERIFY(audioButton->hasActiveFocus());

        // Off is the first row of the Subtitles menu.
        QTest::keyClick(window, Qt::Key_Left);
        QTRY_VERIFY(subtitlesButton->hasActiveFocus());
        QTest::keyClick(window, Qt::Key_Return);
        QTRY_VERIFY(subtitleMenu->hasActiveFocus());
        QTest::keyClick(window, Qt::Key_Up);
        QTest::keyClick(window, Qt::Key_Up);
        QTest::keyClick(window, Qt::Key_Up);
        QCOMPARE(subtitleMenu->property("highlighted").toInt(), 0);
        QTest::keyClick(window, Qt::Key_Return);
        QTRY_COMPARE(video->subtitleTrackId(), 0);

        // With the menus shut the HUD ages out again.
        QTest::keyClick(window, Qt::Key_Up);
        QTRY_VERIFY_WITH_TIMEOUT(!scrim->isVisible(), 15000);
        QCOMPARE(controller.navigation()->route(), NavigationController::Route::Player);
    }

    void thePointerOpensTheMenusAndChoosesATrack()
    {
        QTemporaryDir runtimeRoot;
        QTemporaryDir library;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
        QVERIFY(writeMediaFile(library.path(), QLatin1String(kFilmRelativePath), true));

        ApplicationController controller;
        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY2(window != nullptr, "qml/Main.qml did not load from the module");
        QVERIFY(openPlayer(controller, window, library.path()) != nullptr);
        MpvVideoItem *video = giveTracks(window);
        QVERIFY(video != nullptr);

        QQuickItem *audioButton = itemNamed(window, "audioButton");
        QQuickItem *audioMenu = itemNamed(window, "audioMenu");
        QVERIFY(audioButton && audioMenu);
        QTRY_VERIFY(audioButton->isVisible() && audioButton->width() > 0);

        // The buttons appear with the track list and the layout places them
        // a polish later: the click aims at where they come to rest, to the
        // right of the Restart control.
        QQuickItem *restart = itemNamed(window, "restartControl");
        QVERIFY(restart != nullptr);
        QTRY_VERIFY(centreOf(audioButton).x() > centreOf(restart).x() + 400);

        QTest::mouseClick(window, Qt::LeftButton, Qt::NoModifier, centreOf(audioButton));
        QTRY_VERIFY(audioMenu->isVisible());
        QTRY_VERIFY(audioMenu->hasActiveFocus());

        // The second row is Spanish.
        auto *list = audioMenu->findChild<QQuickItem *>(QStringLiteral("trackMenuList"));
        QVERIFY(list != nullptr);
        QTRY_VERIFY(list->height() > 0);
        const QPointF listOrigin = list->mapToScene(QPointF(0, 0));
        const qreal rowHeight = audioMenu->property("rowHeight").toReal();
        QTest::mouseClick(window, Qt::LeftButton, Qt::NoModifier,
                          QPoint(int(listOrigin.x() + list->width() / 2),
                                 int(listOrigin.y() + rowHeight * 1.5)));
        QTRY_COMPARE(video->audioTrackId(), 2);
        QTRY_VERIFY(!audioMenu->isVisible());

        // A tap outside an open menu dismisses it and changes nothing.
        QTest::mouseClick(window, Qt::LeftButton, Qt::NoModifier, centreOf(audioButton));
        QTRY_VERIFY(audioMenu->isVisible());
        // The top left of the picture: the sidebar beside the player is not
        // the player's to dismiss with.
        QQuickItem *screen = itemNamed(window, "playerScreen");
        QVERIFY(screen != nullptr);
        QTest::mouseClick(window, Qt::LeftButton, Qt::NoModifier,
                          screen->mapToScene(QPointF(40, 40)).toPoint());
        QTRY_VERIFY(!audioMenu->isVisible());
        QCOMPARE(video->audioTrackId(), 2);
        QCOMPARE(controller.navigation()->route(), NavigationController::Route::Player);
    }

    // A pointer has no control to hold, so once the viewer has chosen (or
    // dismissed the menu) the HUD ages out like it does after any tap. The
    // remote's behaviour is unchanged: the button keeps the remote and the
    // HUD stays (theMenusOpenTakeFocusSelectWithEnterAndCloseWithEscape).
    void theHudHidesAfterAPointerChoiceAndAfterAPointerDismissal()
    {
        QTemporaryDir runtimeRoot;
        QTemporaryDir library;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
        QVERIFY(writeMediaFile(library.path(), QLatin1String(kFilmRelativePath), true));

        ApplicationController controller;
        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY2(window != nullptr, "qml/Main.qml did not load from the module");
        QVERIFY(openPlayer(controller, window, library.path()) != nullptr);
        MpvVideoItem *video = giveTracks(window);
        QVERIFY(video != nullptr);

        QQuickItem *audioButton = itemNamed(window, "audioButton");
        QQuickItem *audioMenu = itemNamed(window, "audioMenu");
        QQuickItem *scrim = itemNamed(window, "playerScrim");
        QQuickItem *restart = itemNamed(window, "restartControl");
        QQuickItem *screen = itemNamed(window, "playerScreen");
        QVERIFY(audioButton && audioMenu && scrim && restart && screen);
        QTRY_VERIFY(audioButton->isVisible() && audioButton->width() > 0);
        QTRY_VERIFY(centreOf(audioButton).x() > centreOf(restart).x() + 400);

        // The opening HUD ages out first, then a key brings it back with
        // nothing holding the remote, so the taps below start from a HUD the
        // pointer can reach and that is on its own timer.
        QTRY_VERIFY_WITH_TIMEOUT(!scrim->isVisible(), 15000);
        QTest::keyClick(window, Qt::Key_Up);
        QTRY_VERIFY(scrim->isVisible());
        QTRY_VERIFY(centreOf(audioButton).x() > centreOf(restart).x() + 400);

        QTest::mouseClick(window, Qt::LeftButton, Qt::NoModifier, centreOf(audioButton));
        QTRY_VERIFY(audioMenu->isVisible());

        auto *list = audioMenu->findChild<QQuickItem *>(QStringLiteral("trackMenuList"));
        QVERIFY(list != nullptr);
        QTRY_VERIFY(list->height() > 0);
        const QPointF listOrigin = list->mapToScene(QPointF(0, 0));
        const qreal rowHeight = audioMenu->property("rowHeight").toReal();
        QTest::mouseClick(window, Qt::LeftButton, Qt::NoModifier,
                          QPoint(int(listOrigin.x() + list->width() / 2),
                                 int(listOrigin.y() + rowHeight * 1.5)));
        QTRY_COMPARE(video->audioTrackId(), 2);
        QTRY_VERIFY(!audioMenu->isVisible());
        QVERIFY2(!audioButton->hasActiveFocus(),
                 "A pointer choice left the remote on the button it never used");

        QTRY_VERIFY_WITH_TIMEOUT(!scrim->isVisible(), 15000);
        QCOMPARE(controller.navigation()->route(), NavigationController::Route::Player);

        // Dismissing the menu with a tap elsewhere ends the same way.
        QTest::keyClick(window, Qt::Key_Up);
        QTRY_VERIFY(scrim->isVisible());
        QTest::mouseClick(window, Qt::LeftButton, Qt::NoModifier, centreOf(audioButton));
        QTRY_VERIFY(audioMenu->isVisible());
        QTest::mouseClick(window, Qt::LeftButton, Qt::NoModifier,
                          screen->mapToScene(QPointF(40, 40)).toPoint());
        QTRY_VERIFY(!audioMenu->isVisible());
        QTRY_VERIFY_WITH_TIMEOUT(!scrim->isVisible(), 15000);
        QCOMPARE(video->audioTrackId(), 2);
    }

    void theHudStaysOnScreenWhileItsControlHoldsTheRemote()
    {
        QTemporaryDir runtimeRoot;
        QTemporaryDir library;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
        QVERIFY(writeMediaFile(library.path(), QLatin1String(kFilmRelativePath)));

        ApplicationController controller;
        QVERIFY2(!controller.hasError(), qPrintable(controller.errorMessage()));
        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY2(window != nullptr, "qml/Main.qml did not load from the module");

        QQuickItem *control = openPlayer(controller, window, library.path());
        QVERIFY2(control != nullptr, "The player HUD carries no restart control");
        QQuickItem *scrim = itemNamed(window, "playerScrim");
        QVERIFY(scrim != nullptr);

        // The HUD gets out of the film's way on its own.
        QTRY_VERIFY_WITH_TIMEOUT(!scrim->isVisible(), 15000);

        QTest::keyClick(window, Qt::Key_Down);
        QTRY_VERIFY(scrim->isVisible());
        QVERIFY2(control->hasActiveFocus(),
                 "Moving down did not reach the control the HUD came back for");

        QTest::qWait(4200);
        QVERIFY2(scrim->isVisible(),
                 "The HUD hid the control that was holding the remote");

        QTest::keyClick(window, Qt::Key_Up);
        QTRY_VERIFY_WITH_TIMEOUT(!scrim->isVisible(), 15000);
    }

    // Back is a two-step control: a viewer who presses it to get the controls
    // out of the way must not lose the film.
    void theFirstBackHidesTheHudAndTheSecondLeavesThePlayer()
    {
        Player player;
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
        QVERIFY(openHud(player));
        QVERIFY(player.scrim->isVisible());

        QTest::keyClick(player.window, Qt::Key_Escape);
        QTRY_VERIFY(!player.scrim->isVisible());
        QCOMPARE(player.controller.navigation()->route(), NavigationController::Route::Player);

        QTest::keyClick(player.window, Qt::Key_Escape);
        QTRY_VERIFY(player.controller.navigation()->route()
                    != NavigationController::Route::Player);
    }

    void backKeyAndBackspaceTakeTheSameTwoSteps()
    {
        for (const Qt::Key key : {Qt::Key_Back, Qt::Key_Backspace}) {
            Player player;
            const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
            QVERIFY(openHud(player));

            QTest::keyClick(player.window, key);
            QTRY_VERIFY(!player.scrim->isVisible());
            QCOMPARE(player.controller.navigation()->route(),
                     NavigationController::Route::Player);
            QTest::keyClick(player.window, key);
            QTRY_VERIFY(player.controller.navigation()->route()
                        != NavigationController::Route::Player);
        }
    }

    void backLeavesAtOnceWhenTheHudHasAlreadyFaded()
    {
        Player player;
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
        QVERIFY(openHud(player));

        QTRY_VERIFY_WITH_TIMEOUT(!player.scrim->isVisible(), 15000);
        QTest::keyClick(player.window, Qt::Key_Escape);
        QTRY_VERIFY(player.controller.navigation()->route()
                    != NavigationController::Route::Player);
    }

    void backClosesAnOpenMenuFirstThenHidesTheHudThenLeaves()
    {
        Player player;
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
        QVERIFY(openHud(player));

        QVERIFY(focusControl(player.window, "speedButton"));
        QQuickItem *menu = itemNamed(player.window, "speedMenu");
        QVERIFY(menu != nullptr);
        QTest::keyClick(player.window, Qt::Key_Return);
        QTRY_VERIFY(menu->isVisible());

        // The menu goes first and the HUD stays.
        QTest::keyClick(player.window, Qt::Key_Escape);
        QTRY_VERIFY(!menu->isVisible());
        QVERIFY(player.scrim->isVisible());
        QCOMPARE(player.controller.navigation()->route(), NavigationController::Route::Player);

        // Then the HUD, even with the remote still on a control.
        QTest::keyClick(player.window, Qt::Key_Escape);
        QTRY_VERIFY(!player.scrim->isVisible());
        QCOMPARE(player.controller.navigation()->route(), NavigationController::Route::Player);

        QTest::keyClick(player.window, Qt::Key_Escape);
        QTRY_VERIFY(player.controller.navigation()->route()
                    != NavigationController::Route::Player);
    }

    // PlayerView.swift:465-476: Left taps back 10 s, Right forward 30 s.
    void aTapOfLeftOrRightSkipsTenBackOrThirtyForward()
    {
        Player player;
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
        QVERIFY(openHud(player));
        QSignalSpy skipped(player.scrubber, &SeekScrubber::skipRequested);

        QTest::keyClick(player.window, Qt::Key_Right);
        QTRY_COMPARE(skipped.count(), 1);
        QCOMPARE(skipped.at(0).at(0).toDouble(), 30.0);

        QTest::keyClick(player.window, Qt::Key_Left);
        QTRY_COMPARE(skipped.count(), 2);
        QCOMPARE(skipped.at(1).at(0).toDouble(), -10.0);
    }

    // PlayerView.swift:453-523: a hold over half a second scrubs with the
    // film paused, and letting go seeks to where the scrub got to.
    void holdingRightScrubsAndReleaseSeeksThere()
    {
        Player player;
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
        QVERIFY(openHud(player));
        QSignalSpy skipped(player.scrubber, &SeekScrubber::skipRequested);
        QSignalSpy seeks(player.scrubber, &SeekScrubber::seekRequested);
        QSignalSpy pauses(player.scrubber, &SeekScrubber::pauseRequested);

        QTest::keyPress(player.window, Qt::Key_Right);
        QVERIFY(!player.scrubber->scrubbing());
        QTRY_VERIFY_WITH_TIMEOUT(player.scrubber->scrubbing(), 2000);
        QCOMPARE(pauses.constFirst().at(0).toBool(), true);

        // The auto-repeat a held key sends neither presses again nor ends it.
        repeatKey(player.window, Qt::Key_Right);
        repeatKey(player.window, Qt::Key_Right);
        QTRY_VERIFY_WITH_TIMEOUT(player.scrubber->target() >= 4.0, 3000);
        QVERIFY(player.scrubber->scrubbing());

        // The HUD shows where letting go would land and stays up past its
        // 3-second hide while the hold lasts.
        QTest::qWait(3500);
        QVERIFY2(player.scrim->isVisible(), "The HUD hid under a scrubbing hold");

        const double landing = player.scrubber->target();
        QTest::keyRelease(player.window, Qt::Key_Right);
        QTRY_COMPARE(seeks.count(), 1);
        QCOMPARE(skipped.count(), 0);
        QVERIFY(seeks.at(0).at(0).toDouble() >= landing);
        QVERIFY(!player.scrubber->scrubbing());
    }

    /// Opens the film, leaves it paused or playing as asked and holds Right
    /// until the item scrubs with libmpv's seek mode relaxed.
    [[nodiscard]] bool holdRightUntilTheItemScrubs(Player &player, bool pausedBefore)
    {
        if (QStandardPaths::findExecutable(QStringLiteral("ffmpeg")).isEmpty()) {
            return false;
        }
        if (!openHud(player, true) || !fileIsOpen(player.window)) {
            return false;
        }
        if (pausedBefore) {
            player.video->pause();
            if (!QTest::qWaitFor([&] { return player.video->paused(); }, 5000)) {
                return false;
            }
        }
        QTest::keyPress(player.window, Qt::Key_Right);
        return QTest::qWaitFor([&] {
                   return player.scrubber->scrubbing() && player.video->scrubbing()
                       && player.video->propertyForTest(QStringLiteral("hr-seek"))
                           == QStringLiteral("no");
               }, 5000);
    }

    // A menu taking the remote mid-hold ends the scrub the way a release
    // that goes nowhere does: no scrub left, the seek mode back to normal and
    // the film paused or playing as it was before the hold.
    void aMenuOpeningMidHoldEndsTheScrubAndRestoresTheFilmState()
    {
        if (QStandardPaths::findExecutable(QStringLiteral("ffmpeg")).isEmpty()) {
            QSKIP("ffmpeg is not installed, so the test clip cannot be made");
        }
        for (const bool pausedBefore : {false, true}) {
            Player player;
            const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
            QVERIFY2(holdRightUntilTheItemScrubs(player, pausedBefore),
                     pausedBefore ? "paused hold never scrubbed" : "playing hold never scrubbed");

            // The pointer is how a menu opens while a key is down.
            QQuickItem *button = itemNamed(player.window, "speedButton");
            QQuickItem *menu = itemNamed(player.window, "speedMenu");
            QVERIFY(button != nullptr && menu != nullptr);
            QTRY_VERIFY2(button->width() > 0 && player.scrim->isVisible(), "speed button");
            QTest::mouseClick(player.window, Qt::LeftButton, Qt::NoModifier, centreOf(button));
            QTRY_VERIFY(menu->isVisible());

            QTRY_VERIFY(!player.scrubber->scrubbing());
            QVERIFY(!player.video->scrubbing());
            QTRY_COMPARE_WITH_TIMEOUT(player.video->propertyForTest(QStringLiteral("hr-seek")),
                                      QStringLiteral("absolute"), 5000);
            QTRY_COMPARE(player.video->paused(), pausedBefore);

            // The key coming up afterwards seeks nowhere.
            QSignalSpy seeks(player.scrubber, &SeekScrubber::seekRequested);
            QTest::keyRelease(player.window, Qt::Key_Right);
            QTest::qWait(300);
            QCOMPARE(seeks.count(), 0);
            QVERIFY(!player.video->scrubbing());
            QCOMPARE(player.video->paused(), pausedBefore);
        }
    }

    // Media Stop mid-hold closes the player with the scrub undone.
    void mediaStopMidHoldLeavesNoScrubBehind()
    {
        if (QStandardPaths::findExecutable(QStringLiteral("ffmpeg")).isEmpty()) {
            QSKIP("ffmpeg is not installed, so the test clip cannot be made");
        }
        for (const bool pausedBefore : {false, true}) {
            Player player;
            const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
            QVERIFY2(holdRightUntilTheItemScrubs(player, pausedBefore),
                     pausedBefore ? "paused hold never scrubbed" : "playing hold never scrubbed");
            QPointer<MpvVideoItem> video = player.video;
            QPointer<SeekScrubber> scrubber = player.scrubber;

            QTest::keyClick(player.window, Qt::Key_MediaStop);
            QTRY_VERIFY(player.controller.navigation()->route()
                        != NavigationController::Route::Player);
            // Either the screen is gone with the item, or the item is still
            // there with no scrub and libmpv's seek mode back to normal. One
            // of the two must come true, so the case never passes with
            // nothing checked.
            QTRY_VERIFY_WITH_TIMEOUT(
                video.isNull()
                    || (!video->scrubbing()
                        && video->propertyForTest(QStringLiteral("hr-seek"))
                            == QStringLiteral("absolute")),
                5000);
            if (!scrubber.isNull()) {
                QVERIFY(!scrubber->scrubbing());
            }
            QTest::keyRelease(player.window, Qt::Key_Right);
        }
    }

    void theSubtitleMuteSpeedAndFullscreenKeysDoTheirWork()
    {
        Player player;
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
        QVERIFY(openHud(player, true));
        QVERIFY(giveTracks(player.window) != nullptr);

        QTest::keyClick(player.window, Qt::Key_S);
        QTRY_COMPARE(player.video->subtitleTrackId(), 1);
        QTest::keyClick(player.window, Qt::Key_S);
        QTRY_COMPARE(player.video->subtitleTrackId(), 0);

        QVERIFY(!player.video->muted());
        QTest::keyClick(player.window, Qt::Key_M);
        QTRY_VERIFY(player.video->muted());
        QCOMPARE(player.video->propertyForTest(QStringLiteral("mute")), QStringLiteral("yes"));
        QTest::keyClick(player.window, Qt::Key_M);
        QTRY_VERIFY(!player.video->muted());

        QCOMPARE(player.video->speed(), 1.0);
        QTest::keyClick(player.window, Qt::Key_BracketRight);
        QCOMPARE(player.video->speed(), 1.25);
        QTest::keyClick(player.window, Qt::Key_BracketRight);
        QCOMPARE(player.video->speed(), 1.5);
        QTest::keyClick(player.window, Qt::Key_BracketLeft);
        QCOMPARE(player.video->speed(), 1.25);
        QCOMPARE(player.video->propertyForTest(QStringLiteral("speed")).toDouble(), 1.25);

        QVERIFY(player.window->visibility() != QWindow::FullScreen);
        QTest::keyClick(player.window, Qt::Key_F);
        QTRY_COMPARE(player.window->visibility(), QWindow::FullScreen);
        QTest::keyClick(player.window, Qt::Key_F);
        QTRY_VERIFY(player.window->visibility() != QWindow::FullScreen);
    }

    // A key with Control, Alt or Meta is never the player's.
    void aChordedPlayerKeyIsLeftAlone()
    {
        Player player;
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
        QVERIFY(openHud(player));

        QTest::keyClick(player.window, Qt::Key_M, Qt::ControlModifier);
        QTest::qWait(100);
        QVERIFY(!player.video->muted());
    }

    void theHudCarriesTheReleasedControls()
    {
        Player player;
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
        QVERIFY(openHud(player));

        for (const char *name : {"closeControl", "restartControl", "skipBackControl",
                                 "playPauseControl", "skipForwardControl", "speedButton",
                                 "muteControl", "volumeControl", "fullscreenControl"}) {
            QQuickItem *control = itemNamed(player.window, name);
            QVERIFY2(control != nullptr, name);
            QVERIFY2(control->isVisible(), name);
        }
        // The two skip buttons name their step.
        const auto labelOf = [&](const char *control) {
            auto *label = itemNamed(player.window, control)
                              ->findChild<QQuickItem *>(QStringLiteral("playerHudButtonLabel"));
            return label != nullptr ? label->property("text").toString() : QString();
        };
        QCOMPARE(labelOf("skipBackControl"), QStringLiteral("10"));
        QCOMPARE(labelOf("skipForwardControl"), QStringLiteral("30"));
        QCOMPARE(labelOf("speedButton"), QStringLiteral("1x"));

        // The top bar sits above the title and the bottom controls below.
        QQuickItem *topBar = itemNamed(player.window, "playerTopBar");
        QVERIFY(topBar != nullptr);
        QVERIFY(centreOf(itemNamed(player.window, "closeControl")).y()
                < centreOf(itemNamed(player.window, "restartControl")).y());
        QVERIFY(centreOf(itemNamed(player.window, "closeControl")).x()
                < centreOf(itemNamed(player.window, "fullscreenControl")).x());
    }

    // Every control works from the remote alone.
    void everyHudControlWorksFromTheRemote()
    {
        Player player;
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
        QVERIFY(openHud(player));
        QSignalSpy skipped(player.scrubber, &SeekScrubber::skipRequested);

        QVERIFY(focusControl(player.window, "skipBackControl"));
        QTest::keyClick(player.window, Qt::Key_Return);
        QTRY_COMPARE(skipped.count(), 1);
        QCOMPARE(skipped.at(0).at(0).toDouble(), -10.0);

        QVERIFY(focusControl(player.window, "skipForwardControl"));
        QTest::keyClick(player.window, Qt::Key_Return);
        QTRY_COMPARE(skipped.count(), 2);
        QCOMPARE(skipped.at(1).at(0).toDouble(), 30.0);

        QVERIFY(focusControl(player.window, "playPauseControl"));
        const bool wasPaused = player.video->paused();
        QTest::keyClick(player.window, Qt::Key_Return);
        QTRY_COMPARE(player.video->paused(), !wasPaused);

        QVERIFY(focusControl(player.window, "muteControl"));
        QTest::keyClick(player.window, Qt::Key_Return);
        QTRY_VERIFY(player.video->muted());
        QTest::keyClick(player.window, Qt::Key_Return);
        QTRY_VERIFY(!player.video->muted());

        // Enter takes the slider, Left and Right move the volume, Enter lets
        // it go: Left and Right then walk the HUD again.
        QVERIFY(focusControl(player.window, "volumeControl"));
        QTest::keyClick(player.window, Qt::Key_Return);
        QTest::keyClick(player.window, Qt::Key_Left);
        QTRY_COMPARE(player.video->volume(), 95.0);
        QCOMPARE(player.video->propertyForTest(QStringLiteral("volume")).toDouble(), 95.0);
        QTest::keyClick(player.window, Qt::Key_Left);
        QTRY_COMPARE(player.video->volume(), 90.0);
        QTest::keyClick(player.window, Qt::Key_Right);
        QTRY_COMPARE(player.video->volume(), 95.0);
        QTest::keyClick(player.window, Qt::Key_Return);
        QTest::keyClick(player.window, Qt::Key_Right);
        QTRY_VERIFY(itemNamed(player.window, "fullscreenControl")->hasActiveFocus());
        QCOMPARE(player.video->volume(), 95.0);

        // Speed: Enter opens the menu on the current step, Down then Enter
        // takes the next.
        QVERIFY(focusControl(player.window, "speedButton"));
        QQuickItem *menu = itemNamed(player.window, "speedMenu");
        QTest::keyClick(player.window, Qt::Key_Return);
        QTRY_VERIFY(menu->isVisible());
        QTRY_VERIFY(menu->hasActiveFocus());
        QCOMPARE(menu->property("entries").toList().size(), 7);
        QCOMPARE(menu->property("highlighted").toInt(), 2);

        // The HUD stays up while the menu is open.
        QTest::qWait(4200);
        QVERIFY2(player.scrim->isVisible(), "The HUD hid under the open speed menu");
        QTest::keyClick(player.window, Qt::Key_Down);
        QTest::keyClick(player.window, Qt::Key_Down);
        QTest::keyClick(player.window, Qt::Key_Return);
        QTRY_COMPARE(player.video->speed(), 1.5);
        QCOMPARE(player.video->propertyForTest(QStringLiteral("speed")).toDouble(), 1.5);
        QTRY_VERIFY(itemNamed(player.window, "speedButton")->hasActiveFocus());
        QCOMPARE(itemNamed(player.window, "speedButton")
                     ->findChild<QQuickItem *>(QStringLiteral("playerHudButtonLabel"))
                     ->property("text").toString(),
                 QStringLiteral("1.5x"));

        QVERIFY(focusControl(player.window, "fullscreenControl"));
        QTest::keyClick(player.window, Qt::Key_Return);
        QTRY_COMPARE(player.window->visibility(), QWindow::FullScreen);
        QTest::keyClick(player.window, Qt::Key_Return);
        QTRY_VERIFY(player.window->visibility() != QWindow::FullScreen);
    }

    // Up from the picture lands on the close control; Enter on it leaves.
    void theCloseControlIsReachedWithUpAndLeavesWithEnter()
    {
        Player player;
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
        QVERIFY(openHud(player));
        QQuickItem *close = itemNamed(player.window, "closeControl");
        QVERIFY(close != nullptr);

        QTest::keyClick(player.window, Qt::Key_Up);
        QTRY_VERIFY(close->hasActiveFocus());
        // Down hands the remote back to the picture.
        QTest::keyClick(player.window, Qt::Key_Down);
        QTRY_VERIFY(!close->hasActiveFocus());
        QTest::keyClick(player.window, Qt::Key_Up);
        QTRY_VERIFY(close->hasActiveFocus());

        QTest::keyClick(player.window, Qt::Key_Return);
        QTRY_VERIFY(player.controller.navigation()->route()
                    != NavigationController::Route::Player);
    }

    // Every control works with a pointer.
    void everyHudControlWorksWithAPointer()
    {
        Player player;
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
        QVERIFY(openHud(player));
        QSignalSpy skipped(player.scrubber, &SeekScrubber::skipRequested);
        const auto click = [&](const char *name) {
            QQuickItem *control = itemNamed(player.window, name);
            QVERIFY2(control != nullptr, name);
            QTRY_VERIFY2(control->width() > 0 && player.scrim->isVisible(), name);
            QTest::mouseClick(player.window, Qt::LeftButton, Qt::NoModifier, centreOf(control));
        };

        click("skipBackControl");
        QTRY_COMPARE(skipped.count(), 1);
        QCOMPARE(skipped.at(0).at(0).toDouble(), -10.0);
        click("skipForwardControl");
        QTRY_COMPARE(skipped.count(), 2);
        QCOMPARE(skipped.at(1).at(0).toDouble(), 30.0);

        const bool wasPaused = player.video->paused();
        click("playPauseControl");
        QTRY_COMPARE(player.video->paused(), !wasPaused);

        click("muteControl");
        QTRY_VERIFY(player.video->muted());
        click("muteControl");
        QTRY_VERIFY(!player.video->muted());

        // A tap on the slider sets the level where it lands.
        QQuickItem *slider = itemNamed(player.window, "volumeControl");
        QVERIFY(slider != nullptr);
        const QPoint quarter = slider->mapToScene(QPointF(slider->width() * 0.25,
                                                          slider->height() / 2)).toPoint();
        QTest::mouseClick(player.window, Qt::LeftButton, Qt::NoModifier, quarter);
        QTRY_VERIFY(qAbs(player.video->volume() - 25.0) <= 2.0);
        QVERIFY(qAbs(player.video->propertyForTest(QStringLiteral("volume")).toDouble() - 25.0)
                <= 2.0);

        // The speed menu opens on a tap and takes a tap on a row.
        QQuickItem *menu = itemNamed(player.window, "speedMenu");
        click("speedButton");
        QTRY_VERIFY(menu->isVisible());
        auto *list = menu->findChild<QQuickItem *>(QStringLiteral("trackMenuList"));
        QVERIFY(list != nullptr);
        QTRY_VERIFY(list->height() > 0);
        const QPointF origin = list->mapToScene(QPointF(0, 0));
        const qreal rowHeight = menu->property("rowHeight").toReal();
        // 0.5, 0.75, 1, 1.25, 1.5: the fifth row.
        QTest::mouseClick(player.window, Qt::LeftButton, Qt::NoModifier,
                          QPoint(int(origin.x() + list->width() / 2),
                                 int(origin.y() + rowHeight * 4.5)));
        QTRY_COMPARE(player.video->speed(), 1.5);
        QTRY_VERIFY(!menu->isVisible());

        click("fullscreenControl");
        QTRY_COMPARE(player.window->visibility(), QWindow::FullScreen);
        click("fullscreenControl");
        QTRY_VERIFY(player.window->visibility() != QWindow::FullScreen);

        click("closeControl");
        QTRY_VERIFY(player.controller.navigation()->route()
                    != NavigationController::Route::Player);
    }
};

int main(int argc, char *argv[])
{
    QGuiApplication app(argc, argv);
    // The player surface builds a libmpv core, which refuses to start under a
    // locale whose decimal separator is not a dot.
    std::setlocale(LC_NUMERIC, "C");
    PlayerHudTest test;
    return QTest::qExec(&test, argc, argv);
}

#include "tst_player_hud.moc"
