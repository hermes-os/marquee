#include <clocale>

#include <QCursor>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QGuiApplication>
#include <QImage>
#include <QMetaObject>
#include <QPointF>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQmlProperty>
#include <QQuickItem>
#include <QQuickWindow>
#include <QScopeGuard>
#include <QTemporaryDir>
#include <QTest>

#include "app/AppPaths.hpp"
#include "app/ApplicationController.hpp"
#include "models/LibraryModel.hpp"
#include "navigation/NavigationController.hpp"

namespace
{
constexpr auto kFilmRelativePath = "Arrival (2016)/Arrival (2016).mkv";

// A ten-minute 16x16 y4m at one frame a second: it outlasts every case and
// needs no decoder beyond what libmpv has.
[[nodiscard]] bool writeMediaFile(const QString &root)
{
    const QFileInfo target(QDir(root).filePath(QLatin1String(kFilmRelativePath)));
    if (!QDir().mkpath(target.absolutePath())) {
        return false;
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

// How the player sits in the window: over the whole of it, fullscreen while
// it plays, with the pointer hidden alongside the HUD.
class PlayerWindowTest final : public QObject
{
    Q_OBJECT

private:
    struct Env
    {
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
    };

    [[nodiscard]] static QQuickItem *itemNamed(QQuickWindow *window, const char *name)
    {
        return window->findChild<QQuickItem *>(QLatin1String(name));
    }

    /// Loads the shipped Main.qml; `startFullscreen` is the start option the
    /// window is shown with.
    [[nodiscard]] bool load(Env &env, bool startFullscreen)
    {
        if (!writeMediaFile(env.library.path())) {
            return false;
        }
        env.controller.setStartFullscreen(startFullscreen);
        env.engine.rootContext()->setContextProperty(
            QStringLiteral("appController"), &env.controller);
        env.engine.loadFromModule(QStringLiteral("Marquee"), QStringLiteral("Main"));
        if (env.engine.rootObjects().size() != 1) {
            return false;
        }
        env.window = qobject_cast<QQuickWindow *>(env.engine.rootObjects().front());
        if (env.window == nullptr) {
            return false;
        }
        env.window->requestActivate();
        return QTest::qWaitForWindowActive(env.window);
    }

    [[nodiscard]] bool play(Env &env)
    {
        env.controller.setTemporaryLibraryRoot(env.library.path());
        constexpr int kSceneWaitMs = 30000;
        if (!QTest::qWaitFor([&env] { return env.controller.library()->rowCount() == 1; },
                             kSceneWaitMs)) {
            return false;
        }
        env.controller.playMediaId(env.controller.library()
                                       ->data(env.controller.library()->index(0, 0),
                                              LibraryModel::IdRole)
                                       .toString());
        return QTest::qWaitFor([&env] { return itemNamed(env.window, "restartControl") != nullptr; },
                               kSceneWaitMs);
    }

    static void closePlayer(Env &env)
    {
        env.controller.navigation()->goBack();
    }

private slots:
    // ContentView.swift:52-62: the player is a layer over the whole shell.
    void thePlayerSpansTheWindowWithNoSidebar()
    {
        Env env;
        QVERIFY(load(env, false));
        // The app opens on the profile picker, which has no shell.
        env.controller.navigation()->goHome();
        QQuickItem *sidebar = itemNamed(env.window, "sidebar");
        QQuickItem *content = itemNamed(env.window, "contentFocus");
        QVERIFY(sidebar != nullptr && content != nullptr);
        QTRY_VERIFY(sidebar->isVisible());

        QVERIFY(play(env));
        QCOMPARE(env.controller.navigation()->route(), NavigationController::Route::Player);

        QQuickItem *screen = itemNamed(env.window, "playerScreen");
        QQuickItem *scrim = itemNamed(env.window, "playerScrim");
        QVERIFY(screen != nullptr && scrim != nullptr);
        QVERIFY2(!sidebar->isVisible(), "The sidebar stayed on screen during playback");
        const qreal windowWidth = env.window->contentItem()->width();
        QVERIFY(windowWidth > 0);
        QCOMPARE(screen->mapToScene(QPointF(0, 0)).x(), 0.0);
        QCOMPARE(screen->width(), windowWidth);
        QCOMPARE(scrim->width(), windowWidth);
        QCOMPARE(itemNamed(env.window, "videoSurface")->width(), windowWidth);

        // Closing brings the shell back as it was: the Home route, the
        // sidebar drawn, and the remote on the content, not the sidebar.
        closePlayer(env);
        QTRY_VERIFY(env.controller.navigation()->route() != NavigationController::Route::Player);
        QTRY_VERIFY(sidebar->isVisible());
        QTRY_VERIFY(content->hasActiveFocus());
    }

    void playbackGoesFullscreenAndWindowedAgainOnClose()
    {
        Env env;
        QVERIFY(load(env, false));
        QCOMPARE(env.window->visibility(), QWindow::Windowed);

        QVERIFY(play(env));
        QTRY_COMPARE(env.window->visibility(), QWindow::FullScreen);
        closePlayer(env);
        QTRY_COMPARE(env.window->visibility(), QWindow::Windowed);
    }

    void aWindowThatWasFullscreenStaysFullscreenOnClose()
    {
        Env env;
        QVERIFY(load(env, true));
        QTRY_COMPARE(env.window->visibility(), QWindow::FullScreen);

        QVERIFY(play(env));
        QCOMPARE(env.window->visibility(), QWindow::FullScreen);
        closePlayer(env);
        QTRY_VERIFY(env.controller.navigation()->route() != NavigationController::Route::Player);
        QCOMPARE(env.window->visibility(), QWindow::FullScreen);
    }

    // A fullscreen the viewer set during playback is theirs, however it ends.
    void aViewerChangeDuringPlaybackIsLeftAsSet()
    {
        {
            Env env;
            QVERIFY(load(env, false));
            QVERIFY(play(env));
            QTRY_COMPARE(env.window->visibility(), QWindow::FullScreen);

            // F toggles the HUD's way, and F11 the window's: two changes
            // that end on fullscreen again.
            QTest::keyClick(env.window, Qt::Key_F);
            QTRY_COMPARE(env.window->visibility(), QWindow::Windowed);
            QTest::keyClick(env.window, Qt::Key_F11);
            QTRY_COMPARE(env.window->visibility(), QWindow::FullScreen);
            closePlayer(env);
            QTRY_VERIFY(env.controller.navigation()->route()
                        != NavigationController::Route::Player);
            QTest::qWait(300);
            QCOMPARE(env.window->visibility(), QWindow::FullScreen);
        }
        {
            Env env;
            QVERIFY(load(env, false));
            QVERIFY(play(env));
            QTRY_COMPARE(env.window->visibility(), QWindow::FullScreen);
            QTest::keyClick(env.window, Qt::Key_F);
            QTRY_COMPARE(env.window->visibility(), QWindow::Windowed);
            closePlayer(env);
            QTRY_VERIFY(env.controller.navigation()->route()
                        != NavigationController::Route::Player);
            QTest::qWait(300);
            QCOMPARE(env.window->visibility(), QWindow::Windowed);
        }
    }

    // A window manager's own fullscreen key (Super+F on Hyprland) changes the
    // window without going through toggle(). What is left is decided at close
    // from the state then, never from when or in what order the states were
    // reported.
    void aWindowManagerToggleDuringPlaybackIsLeftAsSet()
    {
        {
            Env env;
            QVERIFY(load(env, false));
            QVERIFY(play(env));
            QTRY_COMPARE(env.window->visibility(), QWindow::FullScreen);

            // Out of fullscreen and back in cannot be told from the window
            // system's late echo of playback's own request, so it is given
            // back like an untouched window.
            env.window->showNormal();
            QTRY_COMPARE(env.window->visibility(), QWindow::Windowed);
            env.window->showFullScreen();
            QTRY_COMPARE(env.window->visibility(), QWindow::FullScreen);
            closePlayer(env);
            QTRY_COMPARE(env.window->visibility(), QWindow::Windowed);
        }
        {
            Env env;
            QVERIFY(load(env, false));
            QVERIFY(play(env));
            QTRY_COMPARE(env.window->visibility(), QWindow::FullScreen);

            // Out of fullscreen to maximized: the viewer's choice, not the
            // windowed state from before.
            env.window->showMaximized();
            QTRY_COMPARE(env.window->visibility(), QWindow::Maximized);
            closePlayer(env);
            QTRY_VERIFY(env.controller.navigation()->route()
                        != NavigationController::Route::Player);
            QCOMPARE(env.window->visibility(), QWindow::Maximized);
        }
        {
            Env env;
            QVERIFY(load(env, false));
            QVERIFY(play(env));
            QTRY_COMPARE(env.window->visibility(), QWindow::FullScreen);

            // Out of fullscreen to windowed and left there.
            env.window->showNormal();
            QTRY_COMPARE(env.window->visibility(), QWindow::Windowed);
            closePlayer(env);
            QTRY_VERIFY(env.controller.navigation()->route()
                        != NavigationController::Route::Player);
            QCOMPARE(env.window->visibility(), QWindow::Windowed);
        }
    }

    // `--play` opens the player before the window is shown.
    void aPlayStartTakesTheWindowFullscreenToo()
    {
        Env env;
        QVERIFY(writeMediaFile(env.library.path()));
        env.controller.playLocalFile(env.library.filePath(QLatin1String(kFilmRelativePath)));
        QCOMPARE(env.controller.navigation()->route(), NavigationController::Route::Player);
        QVERIFY(load(env, false));
        QTRY_COMPARE(env.window->visibility(), QWindow::FullScreen);
        QVERIFY(!itemNamed(env.window, "sidebar")->isVisible());
        closePlayer(env);
        QTRY_COMPARE(env.window->visibility(), QWindow::Windowed);
    }

    // PlayerView.swift:222-257: the pointer goes with the HUD and comes back
    // with any movement.
    void thePointerHidesWithTheHudAndReturnsOnMovement()
    {
        Env env;
        QVERIFY(load(env, false));
        QVERIFY(play(env));
        QQuickItem *scrim = itemNamed(env.window, "playerScrim");
        QVERIFY(scrim != nullptr);

        QTest::mouseMove(env.window, QPoint(300, 300));
        QTest::mouseMove(env.window, QPoint(320, 310));
        QTRY_VERIFY(scrim->isVisible());
        QCOMPARE(env.window->cursor().shape(), Qt::ArrowCursor);

        QTRY_VERIFY_WITH_TIMEOUT(!scrim->isVisible(), 15000);
        QTRY_COMPARE(env.window->cursor().shape(), Qt::BlankCursor);

        QTest::mouseMove(env.window, QPoint(340, 330));
        QTRY_VERIFY(scrim->isVisible());
        QTRY_COMPARE(env.window->cursor().shape(), Qt::ArrowCursor);

        // Back hides the HUD, and the pointer with it.
        QTest::keyClick(env.window, Qt::Key_Escape);
        QTRY_VERIFY(!scrim->isVisible());
        QTRY_COMPARE(env.window->cursor().shape(), Qt::BlankCursor);
        QCOMPARE(env.controller.navigation()->route(), NavigationController::Route::Player);

        // Leaving the player gives the pointer back to the shell.
        closePlayer(env);
        QTRY_VERIFY(env.controller.navigation()->route() != NavigationController::Route::Player);
        QTRY_COMPARE(env.window->cursor().shape(), Qt::ArrowCursor);
    }

    // A press on the progress bar holds the controls and the pointer up, still
    // or dragging, and the wait starts again once it ends.
    void aPressOnTheProgressBarHoldsTheControlsAndPointer()
    {
        Env env;
        QVERIFY(load(env, false));
        QVERIFY(play(env));
        QQuickItem *scrim = itemNamed(env.window, "playerScrim");
        QQuickItem *bar = itemNamed(env.window, "playerProgress");
        QVERIFY(scrim != nullptr && bar != nullptr);

        // The window takes its fullscreen size first, then the bar its place.
        QTRY_COMPARE(env.window->visibility(), QWindow::FullScreen);
        const auto barPoint = [&](qreal fraction) {
            return bar->mapToScene(QPointF(bar->width() * fraction, bar->height() / 2)).toPoint();
        };
        QTRY_VERIFY(QRect(QPoint(0, 0), env.window->size()).contains(barPoint(0.5)));
        QTest::qWait(300);
        QTRY_VERIFY(QRect(QPoint(0, 0), env.window->size()).contains(barPoint(0.5)));
        const QPoint center = barPoint(0.5);
        const QPoint left = barPoint(0.25);
        QTest::mouseMove(env.window, center + QPoint(5, 0));
        QTest::mouseMove(env.window, center);
        QTest::mousePress(env.window, Qt::LeftButton, Qt::NoModifier, center);
        // Still, for longer than the three seconds the controls wait.
        QTest::qWait(3500);
        QVERIFY(scrim->isVisible());
        QCOMPARE(env.window->cursor().shape(), Qt::ArrowCursor);
        QTest::mouseRelease(env.window, Qt::LeftButton, Qt::NoModifier, center);

        // The press ended: the controls wait three seconds more and go.
        QTRY_VERIFY_WITH_TIMEOUT(!scrim->isVisible(), 15000);
        QTRY_COMPARE(env.window->cursor().shape(), Qt::BlankCursor);

        // A drag that stops moving holds them just the same.
        QTest::mouseMove(env.window, center + QPoint(5, 0));
        QTest::mouseMove(env.window, center);
        QTRY_VERIFY(scrim->isVisible());
        QTest::mousePress(env.window, Qt::LeftButton, Qt::NoModifier, center);
        QTest::mouseMove(env.window, center - QPoint(20, 0));
        QTest::mouseMove(env.window, left);
        QTest::qWait(3500);
        QVERIFY(scrim->isVisible());
        QCOMPARE(env.window->cursor().shape(), Qt::ArrowCursor);
        QTest::mouseRelease(env.window, Qt::LeftButton, Qt::NoModifier, left);
        QTRY_VERIFY_WITH_TIMEOUT(!scrim->isVisible(), 15000);
    }

    // An error toast raised over a player whose controls are hidden has a
    // button for the pointer, so the pointer shows while it is up.
    void anErrorToastOverThePlayerShowsThePointer()
    {
        Env env;
        QVERIFY(load(env, false));
        QVERIFY(play(env));
        QQuickItem *scrim = itemNamed(env.window, "playerScrim");
        QVERIFY(scrim != nullptr);
        QTest::mouseMove(env.window, QPoint(300, 300));
        QTest::mouseMove(env.window, QPoint(320, 310));
        QTRY_VERIFY_WITH_TIMEOUT(!scrim->isVisible(), 15000);
        QTRY_COMPARE(env.window->cursor().shape(), Qt::BlankCursor);

        env.controller.raiseError(QStringLiteral("Library scan"),
                                  QStringLiteral("A root went away"));
        QQuickItem *toast = itemNamed(env.window, "errorToast");
        QVERIFY(toast != nullptr);
        QTRY_VERIFY(toast->isVisible() && toast->width() > 0);
        // Over the toast, and over the picture with the toast up.
        const QPoint onToast = toast->mapToScene(QPointF(toast->width() / 2, toast->height() / 2))
                                   .toPoint();
        QTest::mouseMove(env.window, onToast + QPoint(4, 0));
        QTest::mouseMove(env.window, onToast);
        QTRY_COMPARE(env.window->cursor().shape(), Qt::ArrowCursor);
        QTest::mouseMove(env.window, QPoint(340, 330));
        QTRY_COMPARE(env.window->cursor().shape(), Qt::ArrowCursor);
        QTest::mouseMove(env.window, onToast);
        QTest::qWait(3500);
        QCOMPARE(env.window->cursor().shape(), Qt::ArrowCursor);

        // Dismissed, the player's own rule applies again.
        env.controller.dismissError();
        QTest::mouseMove(env.window, QPoint(300, 300));
        QTest::mouseMove(env.window, QPoint(320, 310));
        QTRY_VERIFY_WITH_TIMEOUT(!scrim->isVisible(), 15000);
        QTRY_COMPARE(env.window->cursor().shape(), Qt::BlankCursor);
    }

    // PlayerView.swift:199-217: the title and the episode line sit 2 apart
    // as one block with a shadow, and the top bar has no gradient of its own.
    void theTitleBlockMatchesTheReleasedSpacingAndShadow()
    {
        Env env;
        QVERIFY(load(env, false));
        QVERIFY(play(env));
        QQuickItem *title = itemNamed(env.window, "playerTitle");
        QQuickItem *subtitle = itemNamed(env.window, "playerSubtitle");
        QQuickItem *block = itemNamed(env.window, "playerTitleBlock");
        QQuickItem *topBar = itemNamed(env.window, "playerTopBar");
        QVERIFY(title != nullptr && subtitle != nullptr && block != nullptr && topBar != nullptr);

        // The top bar draws nothing of its own: only its controls and the
        // title block are in it.
        for (QQuickItem *child : topBar->childItems()) {
            QVERIFY2(child->objectName() != QLatin1String("playerTopBarGradient")
                         && !child->property("gradient").isValid(),
                     "The top bar has a gradient behind it");
        }

        // A text is not given a subtitle unless the episode has one, so
        // show one to measure the gap.
        subtitle->setProperty("text", QStringLiteral("S01E02 · Pilot"));
        subtitle->setVisible(true);
        QTRY_VERIFY(subtitle->isVisible());
        const auto gap = [&] {
            return subtitle->mapToScene(QPointF(0, 0)).y()
                - (title->mapToScene(QPointF(0, 0)).y() + title->height());
        };
        // 2, and 4 in lean-back mode.
        QQuickItem *screen = itemNamed(env.window, "playerScreen");
        QVERIFY(screen != nullptr);
        QTRY_COMPARE(gap(), screen->property("leanBack").toBool() ? 4.0 : 2.0);

        // The shadow is a layer effect where there are shaders to draw it:
        // black at 0.7, one down. The picture behind is black, so pixels
        // cannot tell a shadow from none; the effect's own values are
        // checked instead.
        if (!block->property("shadowed").toBool()) {
            QSKIP("The shadow needs a GPU scene graph; the software one draws the block plain");
        }
        QVERIFY(QQmlProperty(block, QStringLiteral("layer.enabled")).read().toBool());
        // The layer's effect item is a sibling the layer creates.
        QObject *effect = nullptr;
        for (QQuickItem *sibling : block->parentItem()->childItems()) {
            if (sibling->objectName() == QLatin1String("playerTitleShadow")) {
                effect = sibling;
            }
        }
        QVERIFY(effect != nullptr);
        // The layer must not swallow the text it shadows: the title still
        // draws white pixels on the black picture.
        QTest::qWait(500);
        const QImage frame = env.window->grabWindow();
        QVERIFY(!frame.isNull());
        const qreal dpr = frame.devicePixelRatio();
        const QPointF at = title->mapToScene(QPointF(0, 0));
        int brightest = 0;
        for (int y = int(at.y() * dpr); y < int((at.y() + title->height()) * dpr); ++y) {
            for (int x = int(at.x() * dpr); x < int((at.x() + 120) * dpr); ++x) {
                brightest = qMax(brightest, qGray(frame.pixel(x, y)));
            }
        }
        QVERIFY2(brightest > 128, "The title block did not draw through its shadow layer");
        QCOMPARE(effect->property("shadowEnabled").toBool(), true);
        QCOMPARE(effect->property("shadowOpacity").toDouble(), 0.7);
        QCOMPARE(effect->property("shadowVerticalOffset").toDouble(), 1.0);
        QCOMPARE(effect->property("shadowColor").value<QColor>(), QColor(Qt::black));
    }

    // PlayerControlsOverlay.swift:517-522 formats a speed with %.2g.
    void theSpeedLabelReadsAsTheReleasedFormat()
    {
        Env env;
        QVERIFY(load(env, false));
        QVERIFY(play(env));
        QQuickItem *screen = itemNamed(env.window, "playerScreen");
        QVERIFY(screen != nullptr);
        const auto label = [&](double speed) {
            QVariant out;
            [&] {
                QVERIFY(QMetaObject::invokeMethod(screen, "speedLabel", Q_RETURN_ARG(QVariant, out),
                                                  Q_ARG(QVariant, speed)));
            }();
            return out.toString();
        };
        QCOMPARE(label(0.5), QStringLiteral("0.5x"));
        QCOMPARE(label(0.75), QStringLiteral("0.75x"));
        QCOMPARE(label(1.0), QStringLiteral("1x"));
        QCOMPARE(label(1.25), QStringLiteral("1.2x"));
        QCOMPARE(label(1.5), QStringLiteral("1.5x"));
        QCOMPARE(label(2.0), QStringLiteral("2x"));
        QCOMPARE(label(3.0), QStringLiteral("3x"));
    }

    // PlayerView.swift:226-233: a failed player keeps its controls and its
    // pointer however long the pointer moves and waits.
    void aFailedPlayerKeepsItsControlsAndPointer()
    {
        Env env;
        QVERIFY(load(env, false));
        QVERIFY(play(env));
        QQuickItem *scrim = itemNamed(env.window, "playerScrim");
        QQuickItem *video = itemNamed(env.window, "videoSurface");
        QVERIFY(scrim != nullptr && video != nullptr);

        // The file's own load clears an earlier error, so the failure comes
        // once playback has started. The offscreen platform has no render
        // context, never starts, and takes the error as it is.
        QTest::qWaitFor([video] { return !video->property("startupPending").toBool(); }, 5000);
        QVERIFY(QMetaObject::invokeMethod(video, "setError",
                                          Q_ARG(QString, QStringLiteral("Cannot open file"))));
        QTRY_VERIFY(video->property("failed").toBool());
        QTest::mouseMove(env.window, QPoint(300, 300));
        QTest::mouseMove(env.window, QPoint(320, 310));
        // Longer than the three seconds the controls wait.
        QTest::qWait(3500);
        QVERIFY(scrim->isVisible());
        QCOMPARE(env.window->cursor().shape(), Qt::ArrowCursor);

        // Moving again restarts the wait; it must still not hide anything.
        QTest::mouseMove(env.window, QPoint(340, 330));
        QTest::qWait(3500);
        QVERIFY(scrim->isVisible());
        QCOMPARE(env.window->cursor().shape(), Qt::ArrowCursor);
    }
};

int main(int argc, char *argv[])
{
    QGuiApplication app(argc, argv);
    // The player surface builds a libmpv core, which refuses to start under a
    // locale whose decimal separator is not a dot.
    std::setlocale(LC_NUMERIC, "C");
    PlayerWindowTest test;
    return QTest::qExec(&test, argc, argv);
}

#include "tst_player_window.moc"
