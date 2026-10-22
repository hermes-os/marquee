#include <algorithm>
#include <clocale>
#include <cmath>
#include <functional>
#include <memory>

#include <QDir>
#include <QElapsedTimer>
#include <QFile>
#include <QGuiApplication>
#include <QImage>
#include <QLinearGradient>
#include <QPainter>
#include <QPointer>
#include <QProcess>
#include <QQmlApplicationEngine>
#include <QQmlComponent>
#include <QQmlContext>
#include <QQuickItem>
#include <QQuickWindow>
#include <QScopeGuard>
#include <QSGRendererInterface>
#include <QSignalSpy>
#include <QStandardPaths>
#include <QTemporaryDir>
#include <QTest>
#include <QUrl>

#include <mpv/client.h>

#include "app/ApplicationController.hpp"
#include "app/AppPaths.hpp"
#include "models/LibraryModel.hpp"
#include "models/ShowsModel.hpp"
#include "navigation/NavigationController.hpp"
#include "playback/MpvVideoItem.hpp"
#include "playback/PlayerController.hpp"
#include "support/RenderProbe.hpp"

namespace {

constexpr int kClipWidth = 160;
constexpr int kClipHeight = 120;

/// Losing the surface mid-wait is a real failure, not an absent result: the
/// contract is that the player holds its surface while a file is playing.
constexpr const char *kSurfaceReleased =
    "The video surface was destroyed while playback was being measured";

/// Writes an uncompressed clip whose top half is white and bottom half black,
/// so a rendered frame proves both that video reached the scene graph and that
/// it arrived the right way up.
bool writeSplitFieldClip(const QString &path, int frames = 20, int framesPerSecond = 10)
{
    QFile file(path);
    if (!file.open(QIODevice::WriteOnly)) {
        return false;
    }

    file.write(QStringLiteral("YUV4MPEG2 W%1 H%2 F%3:1 Ip A1:1 C420mpeg2\n")
                   .arg(kClipWidth)
                   .arg(kClipHeight)
                   .arg(framesPerSecond)
                   .toUtf8());

    const QByteArray brightRows(kClipWidth * kClipHeight / 2, '\xeb');
    const QByteArray darkRows(kClipWidth * kClipHeight / 2, '\x10');
    const QByteArray chromaPlane((kClipWidth / 2) * (kClipHeight / 2), '\x80');

    for (int frame = 0; frame < frames; ++frame) {
        file.write("FRAME\n");
        file.write(brightRows);
        file.write(darkRows);
        file.write(chromaPlane);
        file.write(chromaPlane);
    }

    file.close();
    return file.error() == QFileDevice::NoError;
}

/// An uncompressed one-frame-a-second clip whose whole picture gets brighter
/// by a fixed step every second, so a rendered frame says which second of the
/// film it shows.
constexpr int kRampFrames = 200;
constexpr int kRampFirstLuma = 40;
constexpr int kRampLastLuma = 235;

bool writeBrightnessRampClip(const QString &path)
{
    QFile file(path);
    if (!file.open(QIODevice::WriteOnly)) {
        return false;
    }
    file.write(QStringLiteral("YUV4MPEG2 W%1 H%2 F1:1 Ip A1:1 C420mpeg2\n")
                   .arg(kClipWidth)
                   .arg(kClipHeight)
                   .toUtf8());
    const QByteArray chromaPlane((kClipWidth / 2) * (kClipHeight / 2), '\x80');
    for (int frame = 0; frame < kRampFrames; ++frame) {
        const int luma = kRampFirstLuma
            + frame * (kRampLastLuma - kRampFirstLuma) / (kRampFrames - 1);
        file.write("FRAME\n");
        file.write(QByteArray(kClipWidth * kClipHeight, static_cast<char>(luma)));
        file.write(chromaPlane);
        file.write(chromaPlane);
    }
    file.close();
    return file.error() == QFileDevice::NoError;
}

/// The grey the scene shows for the ramp clip at `seconds` (limited-range luma
/// drawn as full-range RGB).
double rampGreyAt(double seconds)
{
    const double frame = std::clamp(std::floor(seconds), 0.0, double(kRampFrames - 1));
    const double luma = kRampFirstLuma
        + frame * (kRampLastLuma - kRampFirstLuma) / (kRampFrames - 1);
    return (luma - 16.0) * 255.0 / 219.0;
}

/// A 24 fps H.264 clip with a keyframe every two seconds and nothing else
/// (no scene-cut keyframes), the shape of a real film: a seek that does not
/// decode to the exact frame lands on a keyframe up to two seconds early.
bool writeLongKeyframeIntervalClip(const QString &path, int seconds)
{
    QProcess ffmpeg;
    ffmpeg.start(QStringLiteral("ffmpeg"),
                 {"-v", "error", "-y", "-f", "lavfi", "-i",
                  QStringLiteral("testsrc2=s=%1x%2:r=24:d=%3").arg(kClipWidth).arg(kClipHeight).arg(seconds),
                  "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", "-g", "48",
                  "-keyint_min", "48", "-sc_threshold", "0", path});
    return ffmpeg.waitForFinished(120000) && ffmpeg.exitStatus() == QProcess::NormalExit
        && ffmpeg.exitCode() == 0;
}

/// A QQuickFramebufferObject only renders under the OpenGL scene graph, which
/// needs a display-backed platform plugin. Hosts without one skip those cases.
bool rendersWithOpenGl(QQuickWindow *window)
{
    QSGRendererInterface *renderer = window->rendererInterface();
    return renderer != nullptr
        && renderer->graphicsApi() == QSGRendererInterface::OpenGL;
}

/// Averages a small patch of the video surface, addressed as a fraction of the
/// item so the sample follows whatever size the compositor gave the window.
int averageBrightness(const QImage &image,
                      const QQuickItem *item,
                      double horizontalFraction,
                      double verticalFraction)
{
    const QQuickWindow *window = item->window();
    const QPointF origin = item->mapToScene(QPointF(0, 0));
    const double scaleX = double(image.width()) / window->width();
    const double scaleY = double(image.height()) / window->height();
    const int centerX = qBound(
        8, int((origin.x() + item->width() * horizontalFraction) * scaleX),
        image.width() - 9);
    const int centerY = qBound(
        8, int((origin.y() + item->height() * verticalFraction) * scaleY),
        image.height() - 9);

    int total = 0;
    int samples = 0;
    for (int y = centerY - 8; y <= centerY + 8; ++y) {
        for (int x = centerX - 8; x <= centerX + 8; ++x) {
            total += qGray(image.pixel(x, y));
            ++samples;
        }
    }
    return total / samples;
}

/// Offscreen windows are never exposed, so grabbing the window is what drives
/// the scene graph and therefore the libmpv render context. Grabbing also runs
/// the event loop, and PlayerScreen answers the end of a file by navigating
/// away, so the surface the condition reads can be destroyed mid-wait; it is
/// tracked here because a condition that outlives its subject can only read
/// freed memory. Returns the frame that satisfied the condition, or a null
/// image when the wait timed out or lost its surface.
QImage renderUntil(QQuickWindow *window,
                   const QPointer<QQuickItem> &surface,
                   const std::function<bool(const QImage &)> &satisfied,
                   int timeoutMilliseconds = 20000)
{
    QElapsedTimer elapsed;
    elapsed.start();
    while (elapsed.elapsed() < timeoutMilliseconds) {
        const QImage frame = window->grabWindow();
        if (surface.isNull()) {
            return {};
        }
        if (!frame.isNull() && satisfied(frame)) {
            return frame;
        }
        QTest::qWait(16);
    }
    return {};
}

/// Qt tries the platforms in QT_QPA_PLATFORM in order and moves on when one
/// cannot connect, so the chain names every display the session advertises
/// and leaves connecting to the plugins: a stale or unreachable value fails
/// there and still lands on offscreen, where the rendering cases skip.
QByteArray platformFallbackChain(const QString &waylandDisplay, const QString &x11Display)
{
    QByteArrayList platforms;
    if (!waylandDisplay.isEmpty()) {
        platforms.append("wayland");
    }
    if (!x11Display.isEmpty()) {
        platforms.append("xcb");
    }
    platforms.append("offscreen");
    return platforms.join(';');
}

}

class PlaybackTest final : public QObject
{
    Q_OBJECT

private:
    // Loads the shipped Marquee module linked into this binary so these tests
    // exercise qml/Main.qml and qml/screens/PlayerScreen.qml themselves.
    QQuickWindow *loadMainWindow(ApplicationController &controller,
                                 QQmlApplicationEngine &engine)
    {
        controller.setStartFullscreen(false);
        engine.rootContext()->setContextProperty(
            QStringLiteral("appController"), &controller);
        engine.loadFromModule(QStringLiteral("Marquee"), QStringLiteral("Main"));
        if (engine.rootObjects().size() != 1) {
            return nullptr;
        }
        return qobject_cast<QQuickWindow *>(engine.rootObjects().front());
    }

    /// Plays a twenty-minute catalog title (one frame a second keeps the file
    /// small, and 150 s in is outside the final five minutes that would
    /// already count as watched) from the player route, steps it to `seekTo` seconds, stops it
    /// from the remote and returns what the session recorded.
    struct StoppedFilm
    {
        bool ok{false};
        QList<QVariantList> recorded;
        qint64 reachedMs{0};
    };

    StoppedFilm playAndStopFrom(double seekTo)
    {
        StoppedFilm result;
        QTemporaryDir runtimeRoot;
        QTemporaryDir library;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
        // The scanner recognizes a title by its extension and libmpv recognizes
        // a stream by its content, so one clip satisfies both.
        const QString title = QStringLiteral("Arrival (2016)");
        if (!QDir().mkpath(QDir(library.path()).filePath(title))
            || !writeSplitFieldClip(QDir(library.path()).filePath(
                                        title + QStringLiteral("/") + title
                                        + QStringLiteral(".mkv")),
                                    1300, 1)) {
            return result;
        }

        ApplicationController controller;
        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        if (window == nullptr || !rendersWithOpenGl(window)) {
            return result;
        }

        controller.setTemporaryLibraryRoot(library.path());
        if (!QTest::qWaitFor([&] { return controller.library()->rowCount() == 1; })) {
            return result;
        }

        QSignalSpy recorded(controller.player(), &PlayerController::progressRecorded);
        controller.playMediaId(controller.library()
                                   ->data(controller.library()->index(0, 0),
                                          LibraryModel::IdRole)
                                   .toString());

        QPointer<MpvVideoItem> video = qobject_cast<MpvVideoItem *>(
            window->findChild<QQuickItem *>(QStringLiteral("videoSurface")));
        if (video.isNull()
            || renderUntil(window, video, [video](const QImage &) {
                   return !video.isNull() && video->duration() > 1000.0;
               }).isNull()
            || video.isNull()) {
            return result;
        }
        if (seekTo > 0.0) {
            video->seekAbsolute(seekTo);
        }
        if (renderUntil(window, video, [video, seekTo](const QImage &) {
                return !video.isNull() && video->position() >= std::max(seekTo, 1.0);
            }).isNull()
            || video.isNull()) {
            return result;
        }
        result.reachedMs = qint64(video->position() * 1000.0);

        QTest::keyClick(window, Qt::Key_MediaStop);
        if (!QTest::qWaitFor([&] {
                return controller.navigation()->route() != NavigationController::Route::Player;
            })) {
            return result;
        }
        result.recorded = recorded;
        result.ok = true;
        return result;
    }

private slots:
    void showFallbackPaintsTheReleasedDiagonal_data()
    {
        QTest::addColumn<bool>("leanBack");
        QTest::newRow("compact") << false;
        QTest::newRow("lean-back") << true;
    }

    // ShowDetailView.swift:315-322's diagonal below :248-256's vertical
    // shade. Judge the shipped route's pixels against a QPainter reference,
    // not the Canvas properties or an expression read from the implementation.
    void showFallbackPaintsTheReleasedDiagonal()
    {
        QFETCH(bool, leanBack);
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
        QTemporaryDir library;
        QVERIFY(QDir().mkpath(library.filePath(QStringLiteral("The Wire/Season 1"))));
        QVERIFY(writeSplitFieldClip(
            library.filePath(QStringLiteral("The Wire/Season 1/The Wire - S01E01 - The Target.mkv"))));

        ApplicationController controller;
        controller.settings()->setReduceMotion(true);
        controller.settings()->setLeanBackMode(leanBack);
        controller.settings()->setTvShowsRoots({library.path()});
        QTRY_COMPARE(controller.shows()->rowCount(), 1);
        QVERIFY(controller.chooseProfile(controller.profiles()->profiles().at(0).id));
        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY(window != nullptr);
        window->resize(1100, 900);
        controller.navigation()->openShowDetail(QStringLiteral("The Wire"));
        QQuickItem *hero = nullptr;
        QTRY_VERIFY((hero = window->findChild<QQuickItem *>(
                         QStringLiteral("showDetailHero"))) != nullptr);
        QTRY_COMPARE(hero->height(), leanBack ? 500.0 : 350.0);

        // Exercise a live repaint in both directions, not just initial colors.
        for (const int profileIndex : {0, 1, 0}) {
            QTRY_VERIFY(!controller.profileExitInFlight());
            QVERIFY(controller.chooseProfile(controller.profiles()->profiles().at(profileIndex).id));
            QTRY_VERIFY(!controller.profileExitInFlight());
            QCOMPARE(controller.kidsMode(), profileIndex == 1);
            QCOMPARE(controller.navigation()->route(), NavigationController::Route::ShowDetail);
            const QColor background(profileIndex == 1 ? "#140e28" : "#0d0b1a");
            const auto reference = [&](const render_probe::Capture &capture) {
                QImage image(capture.image.size(), QImage::Format_ARGB32_Premultiplied);
                image.fill(Qt::black);
                QPainter painter(&image);
                painter.scale(capture.devicePixelRatio, capture.devicePixelRatio);
                const QRectF rect = capture.geometryOf(hero).sceneRect;
                QLinearGradient diagonal(rect.topLeft(), rect.bottomRight());
                diagonal.setColorAt(0.0, QColor("#1a1525"));
                diagonal.setColorAt(1.0, background);
                painter.fillRect(rect, diagonal);
                QLinearGradient shade(rect.topLeft(), rect.bottomLeft());
                shade.setColorAt(0.0, Qt::transparent);
                QColor middle = background;
                middle.setAlphaF(0.6f);
                shade.setColorAt(0.5, middle);
                shade.setColorAt(1.0, background);
                painter.fillRect(rect, shade);
                return image;
            };
            const auto probe = [&](const render_probe::Capture &capture, qreal x, qreal y) {
                const QRectF rect = capture.geometryOf(hero).sceneRect;
                return QPoint(qRound((rect.left() + x) * capture.devicePixelRatio),
                              qRound((rect.top() + y) * capture.devicePixelRatio));
            };
            bool ready = false;
            const auto capture = render_probe::captureWindowUntil(
                window, {hero}, [&](const render_probe::Capture &candidate) {
                    const QRectF rect = candidate.geometryOf(hero).sceneRect;
                    // The compositor, not the resize above, decides the window's
                    // size: a tiling one hands the window half a screen, where
                    // the lean-back hero is 882 wide behind its sidebar. The
                    // hero has settled once it spans to the window's right
                    // edge, at whatever width that is.
                    if (rect.width() < 100.0
                        || std::abs(rect.right() - candidate.logicalSize.width()) > 1.0) {
                        return false;
                    }
                    const QPoint leading = probe(candidate, 100.0, 6.0);
                    return render_probe::withinTolerance(candidate.image.pixelColor(leading),
                                                         reference(candidate).pixelColor(leading), 2);
                }, 5000, &ready);
            QVERIFY2(ready, "the show hero never painted its leading fallback ink");
            const QImage expected = reference(capture);
            const qreal width = capture.geometryOf(hero).sceneRect.width();
            // Clear of Back, text and poster chrome. A vertical ramp cannot
            // match the mid/trailing samples, which the readiness gate omits.
            for (const qreal x : {100.0, width / 2.0, width - 20.0}) {
                for (const qreal y : {6.0, 32.0, 64.0}) {
                    const QPoint point = probe(capture, x, y);
                    const QColor actual = capture.image.pixelColor(point);
                    const QColor wanted = expected.pixelColor(point);
                    QVERIFY2(render_probe::withinTolerance(actual, wanted, 2),
                             qPrintable(QStringLiteral("show fallback at %1,%2: %3, expected %4")
                                            .arg(x).arg(y).arg(actual.name(), wanted.name())));
                }
            }
        }
    }

    // PlayerView.swift:655-667 applies scale, blur, the black overlay, then
    // the separate vertical shade. Real decoded artwork makes the visibility
    // and composition assertions non-vacuous even on the software backend;
    // this is not a rendered blur-radius or display acceptance test.
    void startupArtworkKeepsTheDimAboveTheBlurSource()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
        QImage artwork(160, 90, QImage::Format_RGB32);
        artwork.fill(QColor(200, 140, 80));
        const QString path = runtimeRoot.filePath(QStringLiteral("backdrop.png"));
        QVERIFY(artwork.save(path));

        ApplicationController controller;
        QQmlApplicationEngine engine;
        engine.rootContext()->setContextProperty(QStringLiteral("appController"), &controller);
        QQmlComponent component(&engine);
        component.loadFromModule(QStringLiteral("Marquee"), QStringLiteral("TransitionLoading"));
        QVERIFY2(component.isReady(), qPrintable(component.errorString()));
        QQuickWindow window;
        window.resize(640, 360);
        const std::unique_ptr<QObject> created(component.createWithInitialProperties({
            {QStringLiteral("width"), 640}, {QStringLiteral("height"), 360},
            {QStringLiteral("reduceMotion"), true},
            {QStringLiteral("artwork"), QUrl::fromLocalFile(path)}}));
        auto *overlay = qobject_cast<QQuickItem *>(created.get());
        QVERIFY(overlay != nullptr);
        overlay->setParentItem(window.contentItem());
        window.show();
        auto *backdrop = overlay->findChild<QQuickItem *>(QStringLiteral("playerStartupBackdrop"));
        auto *treated = overlay->findChild<QQuickItem *>(QStringLiteral("playerStartupTreatedBackdrop"));
        auto *blur = overlay->findChild<QQuickItem *>(QStringLiteral("playerStartupBackdropBlur"));
        auto *dim = overlay->findChild<QQuickItem *>(QStringLiteral("playerStartupBackdropDim"));
        auto *shade = overlay->findChild<QQuickItem *>(QStringLiteral("playerStartupBackdropShade"));
        QVERIFY(backdrop && treated && blur && dim && shade);
        QTRY_COMPARE(backdrop->property("status").toInt(), 1); // Image.Ready
        QCOMPARE(blur->property("source").value<QQuickItem *>(), treated);
        QCOMPARE(backdrop->parentItem(), treated);
        QCOMPARE(treated->childItems(), QList<QQuickItem *>{backdrop});
        QCOMPARE(blur->parentItem(), overlay);
        QCOMPARE(dim->parentItem(), overlay);
        QCOMPARE(shade->parentItem(), overlay);
        const auto stacksAbove = [overlay](QQuickItem *upper, QQuickItem *lower) {
            return upper->z() > lower->z()
                || (upper->z() == lower->z()
                    && overlay->childItems().indexOf(upper) > overlay->childItems().indexOf(lower));
        };
        QVERIFY(stacksAbove(dim, blur));
        QVERIFY(stacksAbove(shade, dim));
        QTRY_VERIFY(blur->isVisible() && dim->isVisible() && shade->isVisible());
        QCOMPARE(dim->position(), QPointF(0, 0));
        QCOMPARE(dim->size(), overlay->size());
        QCOMPARE(dim->opacity(), 1.0);
        QVERIFY(render_probe::withinTolerance(dim->property("color").value<QColor>(),
                                              QColor::fromRgbF(0, 0, 0, 0.62f), 1));
        QVERIFY(blur->property("blurEnabled").toBool());
        QCOMPARE(blur->property("blur").toReal(), 0.5);
        QCOMPARE(blur->property("blurMax").toInt(), 32);
        QCOMPARE(backdrop->width(), 640.0 * 1.04);
        QCOMPARE(backdrop->height(), 360.0 * 1.04);
        QCOMPARE(backdrop->x() + backdrop->width() / 2.0, 320.0);
        QCOMPARE(backdrop->y() + backdrop->height() / 2.0, 180.0);
        QVERIFY(overlay->setProperty("artwork", QUrl{}));
        QTRY_VERIFY(!blur->isVisible() && !dim->isVisible() && !shade->isVisible());
    }

    // PlayerView.swift:57 draws a failed player as PlayerFailureOverlay over
    // the video layer, and :62-66 covers a starting player with the
    // PlayerStartupOverlay; both live outside the auto-hiding controls
    // layer (:45-67), with the failure Close at :596-606 answering Button
    // activation and Escape/Back bubbling to the shell. PlayerView.swift:57
    // gates the failure card on the .failed lifecycle state — never on the
    // end of playback — so a genuine failure shows the card inside the
    // player; the player is dismissed only from an ordinary end via
    // PlayerController.swift:126-138's handlePlaybackEnded (failure applies
    // .fail, never .ended, at MPVPlayerService.swift:2636-2637). The
    // failure is injected only after the fresh surface's load boundary
    // settled — an earlier injection is cleared by the released new-load
    // boundary (MPVPlayerService.loadFile clears at the boundary, :2817),
    // a state PlayerView.swift:57 never exhibits — and the card is read on
    // its own visible state with no visibility forced or hidden. Judged on
    // the real PlayerScreen with playback stubbed at the item's own slots:
    // headless-safe, object properties only. Display-backed dismissal
    // remains explicitly pending: no rendered gate executes it.
    //
    // The player subtree is destroyed when the route leaves Player, so every
    // item below the screen is tracked through QPointer and re-resolved
    // before each read: a teardown mid-wait fails with a readable message
    // instead of dereferencing a destroyed QQuickItem.
    void playerFailureAndStartupOverlaysFollowTheVideoItem()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        QTemporaryDir library;
        // The clip has to outlast the waits below: reaching its end
        // navigates out of the player and destroys the surface being
        // judged. Headless the clip never plays, so the length is free.
        QVERIFY(writeSplitFieldClip(
            library.filePath(QStringLiteral("Arrival.2016.mkv")), 300));

        ApplicationController controller;
        controller.setStartFullscreen(false);
        controller.playLocalFile(library.filePath(QStringLiteral("Arrival.2016.mkv")));
        QCOMPARE(controller.navigation()->route(), NavigationController::Route::Player);

        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY2(window != nullptr, "qml/Main.qml did not load from the module");
        // Judged with playback stubbed at the item's own slots: the
        // pre-first-frame "Opening video..." premise cannot be expressed
        // while libmpv really plays behind the same item, so this runs
        // headless only.
        if (rendersWithOpenGl(window)) {
            QSKIP("Stubbed startup premises cannot run while libmpv really plays");
        }

        QPointer<QQuickItem> screen;
        QPointer<QQuickItem> video;
        QTRY_VERIFY2(
            (video = window->findChild<QQuickItem *>(
                 QStringLiteral("videoSurface")))
                != nullptr,
            "PlayerScreen did not create the video surface");
        screen = video->parentItem();
        QVERIFY2(!screen.isNull(), "the video surface has no screen");

        QPointer<QQuickItem> stateLayer;
        QPointer<QQuickItem> startupOverlay;
        QPointer<QQuickItem> failureCard;
        QTRY_VERIFY2(!screen.isNull()
                         && (stateLayer = screen->findChild<QQuickItem *>(
                                 QStringLiteral("playerStateLayer"),
                                 Qt::FindDirectChildrenOnly))
                             != nullptr,
                     "PlayerScreen did not create the state layer");
        QTRY_VERIFY2(!stateLayer.isNull()
                         && (startupOverlay = stateLayer->findChild<QQuickItem *>(
                                 QStringLiteral("playerStartupOverlay"),
                                 Qt::FindDirectChildrenOnly))
                             != nullptr,
                     "the state layer does not own the startup overlay");
        QTRY_VERIFY2(!stateLayer.isNull()
                         && (failureCard = stateLayer->findChild<QQuickItem *>(
                                 QStringLiteral("playerFailureCard"),
                                 Qt::FindDirectChildrenOnly))
                             != nullptr,
                     "the state layer does not own the failure card");

        // Starting state first: the startup overlay shows with the opening
        // copy and the failure card hides. Non-vacuous anchor: the failure
        // half below starts from this shown state on the same screen.
        // Every retry predicate carries its own liveness check: the route
        // leaving destroys this whole subtree, and a QPointer nulled
        // mid-wait must fail the predicate instead of dereferencing a
        // destroyed item inside QObject::property.
        const auto screenShowsStartup = [&] {
            return !screen.isNull()
                && screen->property("showingStartupOverlay").toBool();
        };
        const auto screenStartupCleared = [&] {
            return !screen.isNull()
                && !screen->property("showingStartupOverlay").toBool();
        };
        const auto screenFailureShown = [&] {
            return !screen.isNull()
                && screen->property("showingFailureOverlay").toBool();
        };
        const auto cardVisible = [&] {
            return !failureCard.isNull()
                && failureCard->property("visible").toBool();
        };
        QTRY_VERIFY2(!screen.isNull(),
                     "the player screen left before the startup overlay was judged");
        QTRY_VERIFY(screenShowsStartup());
        QVERIFY2(!screen.isNull(), "the player screen left mid-assertion");
        QCOMPARE(screen->property("startupMessage").toString(),
                 QStringLiteral("Opening video..."));
        QVERIFY2(!screen.isNull(), "the player screen left mid-assertion");
        QVERIFY(!screen->property("showingFailureOverlay").toBool());
        QVERIFY2(!failureCard.isNull(),
                 "the failure card left before its hidden state was judged");
        QTRY_VERIFY(cardVisible() == false);

        // The load boundary settles past the startup window before the
        // failure is injected: established playback, the way a real load
        // precedes a real failure.
        QVERIFY2(!video.isNull(), "the video surface left before the load boundary settled");
        QVERIFY(QMetaObject::invokeMethod(video.data(), "setPositionValue",
                                         Q_ARG(double, 1.0)));
        QVERIFY2(!screen.isNull(), "the player screen left before the load boundary settled");
        QTRY_VERIFY(screenStartupCleared());

        // The failure card follows the item: it shows with the item's
        // message and the startup copy leaves with it. A genuine injected
        // failure applies the oracle's .fail transition, never .ended, so
        // the player route stays up and these items stay alive: an
        // unexpected teardown fails here with the navigation state quoted
        // instead of crashing on a dangling pointer.
        QVERIFY2(!video.isNull(), "the video surface left before the failure was injected");
        QVERIFY(QMetaObject::invokeMethod(
            video.data(), "setError", Q_ARG(QString, QStringLiteral("cannot play"))));
        QTRY_VERIFY2(!screen.isNull(),
                     qPrintable(QStringLiteral("the player screen tore down after the injected "
                                                "failure instead of showing the failure card; "
                                                "route=%1")
                                    .arg(static_cast<int>(controller.navigation()->route()))));
        QTRY_VERIFY(screenFailureShown());
        QVERIFY2(!failureCard.isNull(),
                 qPrintable(QStringLiteral("the failure card tore down after the injected failure; "
                                            "route=%1")
                                .arg(static_cast<int>(controller.navigation()->route()))));
        QTRY_VERIFY(cardVisible());
        QVERIFY2(!screen.isNull(), "the player screen left mid-assertion");
        QCOMPARE(screen->property("startupMessage").toString(), QString{});
        QPointer<QQuickItem> failureMessage =
            failureCard->findChild<QQuickItem *>(QStringLiteral("playerFailureMessage"));
        QVERIFY2(!failureMessage.isNull(), "the failure card paints no message");
        QCOMPARE(failureMessage->property("text").toString(),
                 QStringLiteral("cannot play"));
        // The released Close is a plain Button outside the HUD focus
        // model (PlayerHUDControl in PlayerControlsOverlay.swift:5-13 has
        // no failure-close member): the card takes no focus when it
        // appears and answers the pointer only.
        QPointer<QQuickItem> failureClose =
            failureCard->findChild<QQuickItem *>(QStringLiteral("playerFailureClose"));
        QVERIFY2(!failureClose.isNull(), "the failure card paints no Close control");
        QVERIFY(!failureClose->hasActiveFocus());
        // The failure card owns the frame: the route is still the player,
        // the way PlayerView.swift:57 keeps the failed player on screen.
        QCOMPARE(controller.navigation()->route(), NavigationController::Route::Player);
    }

    // The released failure Close is a plain Button outside the HUD focus
    // model: PlayerHUDControl (PlayerControlsOverlay.swift:5-13) has no
    // failure-close member, PlayerHUDFocusPolicy.initialState is .canvas
    // (:84-87), and PlayerView.swift:305-308 routes .select to
    // activateHUDControl(.canvas) — :414-415 answers it with togglePause
    // — while only Escape (:337-339) or the mouse closes. Pinned here on
    // the real PlayerScreen: the card takes no focus when it appears, and
    // while it is shown Return, Enter, and Select each leave the player
    // up (Select toggles pause on the canvas), while Escape leaves
    // through the shell's route pop. The failure is injected past the
    // load boundary settled above, and the card is read on its own
    // visible state. Headless-safe: key delivery on the offscreen
    // platform, no pixels judged. Environment-independent: the failure
    // latch dominates libmpv's reports (a genuine end never dismisses a
    // failed player), so the premise survives real playback behind the
    // same item; the clip still outlasts the waits below.
    void failureCloseOwnsFocusAndActivationContract()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        for (int keyIndex = 0; keyIndex < 3; ++keyIndex) {
            const Qt::Key canvasKey = keyIndex == 0   ? Qt::Key_Return
                : keyIndex == 1 ? Qt::Key_Enter
                                : Qt::Key_Select;

            QTemporaryDir library;
            // The clip has to outlast the waits below: reaching its end
            // navigates out of the player and destroys the surface being
            // judged. Headless the clip never plays, so the length is free.
            QVERIFY(writeSplitFieldClip(
                library.filePath(QStringLiteral("Arrival.2016.mkv")), 300));

            ApplicationController controller;
            controller.setStartFullscreen(false);
            controller.playLocalFile(library.filePath(QStringLiteral("Arrival.2016.mkv")));
            QCOMPARE(controller.navigation()->route(), NavigationController::Route::Player);

            QQmlApplicationEngine engine;
            QQuickWindow *window = loadMainWindow(controller, engine);
            QVERIFY2(window != nullptr, "qml/Main.qml did not load from the module");

            // Escape below pops the route and destroys the player subtree:
            // every item is tracked through QPointer, and every retry
            // predicate carries its own liveness check, so a teardown
            // mid-wait fails with a readable message instead of
            // dereferencing a destroyed QQuickItem.
            QPointer<QQuickItem> screen;
            QPointer<QQuickItem> video;
            QTRY_VERIFY2(
                (video = window->findChild<QQuickItem *>(
                     QStringLiteral("videoSurface")))
                    != nullptr,
                "PlayerScreen did not create the video surface");
            screen = video->parentItem();
            QVERIFY2(!screen.isNull(), "the video surface has no screen");
            const auto screenFailureShown = [&] {
                return !screen.isNull()
                    && screen->property("showingFailureOverlay").toBool();
            };

            // Past the load boundary, then failed: the card shows and
            // takes no focus — the released Close is not in the HUD
            // focus model. Where libmpv really plays, the boundary is
            // the real load — libmpv's own clock past the startup
            // window — because the surface's late first load clears any
            // earlier injection at the new-load boundary
            // (MpvVideoItem::loadCurrentSource clears at a new source).
            // Headless no surface ever arrives, so the boundary is
            // stubbed past the window instead.
            const auto loadBoundarySettled = [&] {
                return !video.isNull()
                    && video->property("position").toDouble() >= 0.35
                    && !video->property("startupPending").toBool();
            };
            QVERIFY2(!video.isNull(), "the video surface left before the failure setup");
            if (rendersWithOpenGl(window)) {
                QTRY_VERIFY_WITH_TIMEOUT(loadBoundarySettled(), 20000);
            } else {
                QVERIFY(QMetaObject::invokeMethod(video.data(), "setPositionValue",
                                                 Q_ARG(double, 1.0)));
            }
            QVERIFY2(!video.isNull(), "the video surface left before the failure setup");
            QVERIFY(QMetaObject::invokeMethod(
                video.data(), "setError", Q_ARG(QString, QStringLiteral("cannot play"))));
            QVERIFY2(!screen.isNull(),
                     "the player screen tore down on the injected failure instead of "
                     "showing the failure card");
            QTRY_VERIFY(screenFailureShown());
            QPointer<QQuickItem> failureClose = window->findChild<QQuickItem *>(
                QStringLiteral("playerFailureClose"));
            QVERIFY2(!failureClose.isNull(), "the failure card paints no Close control");
            QVERIFY(!failureClose->hasActiveFocus());

            // The canvas key does not dismiss: Select stays on the canvas
            // and toggles pause, so the failed player stays up behind its
            // card the way PlayerView.swift:57 keeps it on screen.
            // Non-vacuous: the Escape pass below dismisses from this same
            // failed state, so a handler that dismissed on any key fails
            // here and a handler that never dismisses fails there. The
            // re-shown controls prove the key really arrived through the
            // screen's own handler: the controls are hidden first, and
            // only that handler writes them back. A key that never
            // reached the screen would leave them hidden.
            window->requestActivate();
            QVERIFY2(!screen.isNull(), "the player screen left before the canvas key");
            screen->forceActiveFocus();
            screen->setProperty("controlsVisible", false);
            QTest::keyClick(window, canvasKey);
            const auto screenControlsReshown = [&] {
                return !screen.isNull()
                    && screen->property("controlsVisible").toBool();
            };
            QTRY_VERIFY2(screenControlsReshown(),
                         "the canvas key never reached the player while failed");
            QCOMPARE(controller.navigation()->route(), NavigationController::Route::Player);
            QVERIFY2(!screen.isNull(),
                     "the player screen tore down on a canvas key instead of "
                     "staying behind its failure card");
            QTRY_VERIFY(screenFailureShown());
        }

        // Escape is not answered by the failure card: it keeps bubbling to
        // the shell, which pops one route. Same failed setup, one pass.
        {
            QTemporaryDir library;
            // The clip has to outlast the waits below: reaching its end
            // navigates out of the player and destroys the surface being
            // judged. Headless the clip never plays, so the length is free.
            QVERIFY(writeSplitFieldClip(
                library.filePath(QStringLiteral("Arrival.2016.mkv")), 300));

            ApplicationController controller;
            controller.setStartFullscreen(false);
            controller.playLocalFile(library.filePath(QStringLiteral("Arrival.2016.mkv")));

            QQmlApplicationEngine engine;
            QQuickWindow *window = loadMainWindow(controller, engine);
            QVERIFY2(window != nullptr, "qml/Main.qml did not load from the module");

            QPointer<QQuickItem> screen;
            QPointer<QQuickItem> video;
            QTRY_VERIFY2(
                (video = window->findChild<QQuickItem *>(
                     QStringLiteral("videoSurface")))
                    != nullptr,
                "PlayerScreen did not create the video surface");
            screen = video->parentItem();
            QVERIFY2(!screen.isNull(), "the video surface has no screen");
            const auto screenFailureShown = [&] {
                return !screen.isNull()
                    && screen->property("showingFailureOverlay").toBool();
            };

            // Past the load boundary, then failed: the card shows and the
            // player stays up. Where libmpv really plays, the boundary is
            // the real load — libmpv's own clock past the startup
            // window — because the surface's late first load clears any
            // earlier injection at the new-load boundary
            // (MpvVideoItem::loadCurrentSource clears at a new source).
            // Headless no surface ever arrives, so the boundary is
            // stubbed past the window instead.
            QVERIFY2(!video.isNull(), "the video surface left before the failure setup");
            if (rendersWithOpenGl(window)) {
                const auto loadBoundarySettled = [&] {
                    return !video.isNull()
                        && video->property("position").toDouble() >= 0.35
                        && !video->property("startupPending").toBool();
                };
                QTRY_VERIFY_WITH_TIMEOUT(loadBoundarySettled(), 20000);
            } else {
                QVERIFY(QMetaObject::invokeMethod(video.data(), "setPositionValue",
                                                 Q_ARG(double, 1.0)));
            }
            QVERIFY2(!video.isNull(), "the video surface left before the failure setup");
            QVERIFY(QMetaObject::invokeMethod(
                video.data(), "setError", Q_ARG(QString, QStringLiteral("cannot play"))));
            QVERIFY2(!screen.isNull(),
                     "the player screen tore down on the injected failure instead of "
                     "showing the failure card");
            QTRY_VERIFY(screenFailureShown());

            window->requestActivate();
            QTest::keyClick(window, Qt::Key_Escape);
            QTRY_VERIFY2(controller.navigation()->route()
                             != NavigationController::Route::Player,
                         "Escape did not leave the failed player");
        }
    }

    void playerRouteRendersDecodedVideoRightSideUp()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const QString clip = runtimeRoot.filePath(QStringLiteral("split-field.y4m"));
        // The clip has to outlast the wait below: reaching its end navigates
        // out of the player and destroys the surface being measured.
        QVERIFY(writeSplitFieldClip(clip, 300));

        ApplicationController controller;
        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY2(window != nullptr, "qml/Main.qml did not load from the module");
        if (!rendersWithOpenGl(window)) {
            QSKIP("Scene graph is not running on OpenGL; the libmpv render path cannot run");
        }

        controller.playLocalFile(clip);
        QCOMPARE(controller.navigation()->route(), NavigationController::Route::Player);

        QPointer<QQuickItem> video =
            window->findChild<QQuickItem *>(QStringLiteral("videoSurface"));
        QVERIFY2(!video.isNull(), "PlayerScreen did not create the video surface");

        // mpv pillarboxes the 4:3 clip, so sample the item's horizontal centre
        // where picture rather than padding is drawn, and stay clear of the
        // controls scrim along the bottom.
        // The duration arrives from libmpv on its own schedule, separately
        // from the first decoded raster, so it is waited for alongside the
        // bright half rather than asserted the instant the raster shows.
        const QImage frame = renderUntil(window, video, [video](const QImage &image) {
            if (video.isNull()) {
                return false;
            }
            return video->property("duration").toDouble() > 0.0
                && averageBrightness(image, video, 0.5, 0.25) > 128;
        });
        QVERIFY2(!video.isNull(), kSurfaceReleased);
        QVERIFY2(!frame.isNull(), "No decoded video reached the Qt Quick scene");
        QVERIFY2(averageBrightness(frame, video, 0.5, 0.55) < 64,
                 "The clip's dark half rendered bright: the picture is upside down");
        QVERIFY(video->property("duration").toDouble() > 0.0);
        QCOMPARE(video->property("errorMessage").toString(), QString{});

        AppPaths::clearRuntimeRoot();
    }

    // PlayerView.swift:478-523: while a hold scrubs, the picture shows the
    // frame the clock points at, not the frame the hold began on; letting go
    // lands exactly there and the film plays on from it.
    void aScrubbingHoldShowsTheLiveFrameAndReleaseLandsThere()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
        const QString clip = runtimeRoot.filePath(QStringLiteral("ramp.y4m"));
        QVERIFY(writeBrightnessRampClip(clip));

        ApplicationController controller;
        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY2(window != nullptr, "qml/Main.qml did not load from the module");
        if (!rendersWithOpenGl(window)) {
            QSKIP("Scene graph is not running on OpenGL; the libmpv render path cannot run");
        }

        controller.playLocalFile(clip);
        QPointer<MpvVideoItem> video = qobject_cast<MpvVideoItem *>(
            window->findChild<QQuickItem *>(QStringLiteral("videoSurface")));
        QObject *scrubber = window->findChild<QObject *>(QStringLiteral("seekScrubber"));
        QVERIFY2(!video.isNull() && scrubber != nullptr, "PlayerScreen lacks its video or scrubber");

        // Playing near the start: the first frames are the darkest ones.
        QVERIFY2(!renderUntil(window, video, [video](const QImage &image) {
                     return !video.isNull() && video->duration() > 100.0
                         && video->position() > 0.5
                         && averageBrightness(image, video, 0.5, 0.25) < rampGreyAt(8.0);
                 }).isNull(),
                 "The ramp clip never reached its first frames");
        QVERIFY2(!video.isNull(), kSurfaceReleased);
        QCOMPARE(video->propertyForTest(QStringLiteral("hr-seek")), QStringLiteral("absolute"));
        QSignalSpy seeks(scrubber, SIGNAL(seekRequested(double)));

        QTest::keyPress(window, Qt::Key_Right);
        const double scrubGrey = rampGreyAt(25.0);
        const QImage scrubbed = renderUntil(window, video, [&](const QImage &image) {
            return !video.isNull() && scrubber->property("scrubbing").toBool()
                && averageBrightness(image, video, 0.5, 0.25) > scrubGrey;
        }, 10000);
        QVERIFY2(!video.isNull(), kSurfaceReleased);
        QVERIFY2(!scrubbed.isNull(),
                 "The picture stayed on the frame the hold began on while the scrub moved on");
        // The clock the session stores has not followed the previews.
        QVERIFY2(video->position() < 8.0,
                 qPrintable(QStringLiteral("The playback position followed a preview: %1")
                                .arg(video->position())));
        QCOMPARE(video->propertyForTest(QStringLiteral("hr-seek")), QStringLiteral("no"));
        QVERIFY(video->scrubbing());

        QTest::keyRelease(window, Qt::Key_Right);
        QTRY_COMPARE(seeks.count(), 1);
        const double landing = seeks.at(0).at(0).toDouble();
        QVERIFY(landing > 25.0);
        QVERIFY(!scrubber->property("scrubbing").toBool());
        QVERIFY(!video->scrubbing());

        // The film plays on from the landing and the picture is the landing's.
        QVERIFY2(!renderUntil(window, video, [&](const QImage &image) {
                     if (video.isNull()) {
                         return false;
                     }
                     const double position = video->position();
                     return position >= landing - 0.3 && position < landing + 6.0
                         && std::abs(averageBrightness(image, video, 0.5, 0.25)
                                     - rampGreyAt(position)) < 12.0;
                 }).isNull(),
                 qPrintable(QStringLiteral("The film did not land at %1").arg(landing)));
        QVERIFY2(!video.isNull(), kSurfaceReleased);
        QTRY_COMPARE(video->propertyForTest(QStringLiteral("hr-seek")), QStringLiteral("absolute"));
        QTRY_VERIFY(!video->paused());
        QCOMPARE(video->errorMessage(), QString{});
    }

    // After release the clock shows the landing and nothing else: libmpv
    // answers reads and reports from before the exact seek ran with the
    // previews' keyframe times, and none of them may reach the position the
    // watch-progress writer and the next-episode card read.
    void theClockNeverShowsAPreviewTimeAfterRelease()
    {
        if (QStandardPaths::findExecutable(QStringLiteral("ffmpeg")).isEmpty()) {
            QSKIP("ffmpeg is not installed, so the test clip cannot be made");
        }
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
        const QString clip = runtimeRoot.filePath(QStringLiteral("keyframes.mp4"));
        QVERIFY(writeLongKeyframeIntervalClip(clip, 150));

        ApplicationController controller;
        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY2(window != nullptr, "qml/Main.qml did not load from the module");
        if (!rendersWithOpenGl(window)) {
            QSKIP("Scene graph is not running on OpenGL; the libmpv render path cannot run");
        }

        controller.playLocalFile(clip);
        QPointer<MpvVideoItem> video = qobject_cast<MpvVideoItem *>(
            window->findChild<QQuickItem *>(QStringLiteral("videoSurface")));
        QObject *scrubber = window->findChild<QObject *>(QStringLiteral("seekScrubber"));
        QVERIFY2(!video.isNull() && scrubber != nullptr, "PlayerScreen lacks its video or scrubber");
        QVERIFY2(!renderUntil(window, video, [video](const QImage &) {
                     return !video.isNull() && video->duration() > 100.0
                         && video->position() > 0.5;
                 }).isNull(),
                 "The clip never started");
        QVERIFY2(!video.isNull(), kSurfaceReleased);
        QSignalSpy seeks(scrubber, SIGNAL(seekRequested(double)));

        // Hold and release several times with a different number of previews
        // each: the stale report that slips through after the release depends
        // on where libmpv is in the preview it was running, and it is the
        // previews' keyframe, up to two seconds before the landing.
        QStringList clockJumps;
        for (int attempt = 0; attempt < 8; ++attempt) {
            QTest::keyPress(window, Qt::Key_Right);
            double target = 0.0;
            QVERIFY2(!renderUntil(window, video, [&](const QImage &) {
                         if (video.isNull() || !video->scrubbing()) {
                             return false;
                         }
                         target = scrubber->property("target").toDouble();
                         return video->previewSeeksIssuedForTest() >= 3 + attempt % 3;
                     }, 10000).isNull(),
                     "The hold never settled on a preview between two keyframes");
            QVERIFY2(!video.isNull(), kSurfaceReleased);

            QList<double> shown;
            const QMetaObject::Connection recording = connect(
                video.data(), &MpvVideoItem::positionChanged, this,
                [&] { shown.append(video->position()); });
            seeks.clear();
            QTest::keyRelease(window, Qt::Key_Right);
            QTRY_COMPARE(seeks.count(), 1);
            const double landing = seeks.at(0).at(0).toDouble();

            // Until the film plays on from the landing.
            const bool playingOn = !renderUntil(window, video, [&](const QImage &) {
                return !video.isNull() && !video->paused()
                    && video->position() >= landing + 0.2;
            }, 10000).isNull();
            QVERIFY2(!video.isNull(), kSurfaceReleased);
            disconnect(recording);

            QVERIFY2(playingOn, qPrintable(QStringLiteral("The film did not play on from %1")
                                               .arg(landing)));
            QVERIFY(!shown.isEmpty());
            for (const double position : shown) {
                if (std::abs(position - landing) > 0.3) {
                    clockJumps.append(QStringLiteral("The clock showed %1 after a release landing at %2")
                                          .arg(position)
                                          .arg(landing));
                }
            }
        }
        QVERIFY2(clockJumps.isEmpty(), qPrintable(clockJumps.join(QLatin1Char('\n'))));
    }

    void repeatedPlayerTeardownKeepsPlaybackHealthy()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const QString clip = runtimeRoot.filePath(QStringLiteral("split-field.y4m"));
        // Long enough that only the deliberate goHome() below ends a cycle;
        // reaching the clip's end would navigate away on its own.
        QVERIFY(writeSplitFieldClip(clip, 300));

        ApplicationController controller;
        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY2(window != nullptr, "qml/Main.qml did not load from the module");
        if (!rendersWithOpenGl(window)) {
            QSKIP("Scene graph is not running on OpenGL; the libmpv render path cannot run");
        }

        for (int cycle = 0; cycle < 3; ++cycle) {
            controller.playLocalFile(clip);
            QPointer<QQuickItem> video =
                window->findChild<QQuickItem *>(QStringLiteral("videoSurface"));
            QVERIFY2(!video.isNull(), "PlayerScreen did not create the video surface");

            const QImage frame = renderUntil(window, video, [video](const QImage &image) {
                if (video.isNull()) {
                    return false;
                }
                return video->property("duration").toDouble() > 0.0
                    && averageBrightness(image, video, 0.5, 0.25) > 128;
            });
            QVERIFY2(!video.isNull(), kSurfaceReleased);
            QVERIFY2(!frame.isNull(), "Playback did not render after a teardown cycle");
            QCOMPARE(video->property("errorMessage").toString(), QString{});

            controller.navigation()->goHome();
            QTRY_VERIFY(window->findChild<QQuickItem *>(QStringLiteral("videoSurface"))
                        == nullptr);
            // Releases the scene-graph node, and with it the render context.
            QVERIFY(!window->grabWindow().isNull());
        }

        AppPaths::clearRuntimeRoot();
    }

    void playbackSurvivesLosingAndRegainingItsRenderSurface()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const QString clip = runtimeRoot.filePath(QStringLiteral("split-field.y4m"));
        // The surface must survive the loss below on its own; a clip that ends
        // first would navigate the player away and destroy it instead.
        QVERIFY(writeSplitFieldClip(clip, 300));

        ApplicationController controller;
        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY2(window != nullptr, "qml/Main.qml did not load from the module");
        if (!rendersWithOpenGl(window)) {
            QSKIP("Scene graph is not running on OpenGL; the libmpv render path cannot run");
        }

        controller.playLocalFile(clip);
        QPointer<QQuickItem> video =
            window->findChild<QQuickItem *>(QStringLiteral("videoSurface"));
        QVERIFY2(!video.isNull(), "PlayerScreen did not create the video surface");
        QVERIFY2(!renderUntil(window, video, [video](const QImage &image) {
                     if (video.isNull()) {
                         return false;
                     }
                     return averageBrightness(image, video, 0.5, 0.25) > 128;
                 }).isNull(),
                 "No decoded video reached the Qt Quick scene");

        QTRY_VERIFY_WITH_TIMEOUT(!video.isNull()
                                     && video->property("position").toDouble() > 4.0,
                                 15000);
        QVERIFY2(!video.isNull(), kSurfaceReleased);
        const double positionBeforeLoss = video->property("position").toDouble();

        // Windows keep their scene graph across hide() unless asked not to, so
        // both persistence flags are what actually releases the render context.
        window->setPersistentGraphics(false);
        window->setPersistentSceneGraph(false);
        window->hide();
        QTest::qWait(200);
        QElapsedTimer sinceLoss;
        sinceLoss.start();
        window->show();

        QVERIFY2(!renderUntil(window, video, [video](const QImage &image) {
                     if (video.isNull()) {
                         return false;
                     }
                     return averageBrightness(image, video, 0.5, 0.25) > 128;
                 }).isNull(),
                 "Video did not come back after the render surface was replaced");
        // Losing the render surface must not cost the player its video item.
        QVERIFY2(!video.isNull(), kSurfaceReleased);
        const auto videoReportsNoError = [&] {
            return !video.isNull()
                && video->property("errorMessage").toString() == QString{};
        };
        QTRY_VERIFY(videoReportsNoError());
        QTRY_VERIFY_WITH_TIMEOUT(!video.isNull()
                                     && video->property("position").toDouble()
                                         >= positionBeforeLoss - 0.5,
                                 6000);
        // Restarting would have to replay more than four seconds to reach that
        // position, so only a resume can satisfy this window.
        QVERIFY2(sinceLoss.elapsed() < 3500,
                 qPrintable(QStringLiteral("Playback restarted instead of resuming: "
                                           "regained %1s only after %2ms")
                                .arg(positionBeforeLoss)
                                .arg(sinceLoss.elapsed())));

        AppPaths::clearRuntimeRoot();
    }

    void reachingTheEndOfAFileReportsPlaybackEndedAndLeavesThePlayer()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const QString clip = runtimeRoot.filePath(QStringLiteral("split-field.y4m"));
        QVERIFY(writeSplitFieldClip(clip));

        ApplicationController controller;
        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY2(window != nullptr, "qml/Main.qml did not load from the module");
        if (!rendersWithOpenGl(window)) {
            QSKIP("Scene graph is not running on OpenGL; the libmpv render path cannot run");
        }

        controller.playLocalFile(clip);
        QPointer<MpvVideoItem> video = qobject_cast<MpvVideoItem *>(
            window->findChild<QQuickItem *>(QStringLiteral("videoSurface")));
        QVERIFY2(!video.isNull(), "PlayerScreen did not create the video surface");
        QSignalSpy endedSpy(video.data(), &MpvVideoItem::playbackEnded);

        QTRY_VERIFY_WITH_TIMEOUT(endedSpy.count() > 0, 20000);
        QCOMPARE(endedSpy.count(), 1);
        // PlayerScreen answers the end by navigating back, which unloads the
        // surface, so the item's state after the end is proven on the
        // standalone item below where nothing destroys it.
        QTRY_COMPARE(controller.navigation()->route(),
                     NavigationController::Route::ProfilePicker);
        QTRY_VERIFY(video.isNull());

        AppPaths::clearRuntimeRoot();
    }

    void reloadingTheSurfaceAfterEndDoesNotReemitPlaybackEnded()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const QString clip = runtimeRoot.filePath(QStringLiteral("split-field.y4m"));
        QVERIFY(writeSplitFieldClip(clip));

        QQuickWindow window;
        window.resize(640, 480);
        auto *video = new MpvVideoItem(window.contentItem());
        video->setWidth(640);
        video->setHeight(480);
        window.show();
        if (!rendersWithOpenGl(&window)) {
            QSKIP("Scene graph is not running on OpenGL; the libmpv render path cannot run");
        }

        QSignalSpy endedSpy(video, &MpvVideoItem::playbackEnded);
        video->setSource(QUrl::fromLocalFile(clip));
        QVERIFY2(!renderUntil(&window, video, [video](const QImage &) {
                     return video->duration() > 0.0;
                 }).isNull(),
                 "The standalone video surface never loaded the clip");
        QTRY_VERIFY_WITH_TIMEOUT(endedSpy.count() > 0, 20000);
        // Keep-open leaves the file loaded at EOF; allow a duplicate queued
        // notification to arrive before asserting that the signal is latched.
        QTest::qWait(1500);
        QCOMPARE(endedSpy.count(), 1);
        QCOMPARE(video->errorMessage(), QString{});

        window.setPersistentGraphics(false);
        window.setPersistentSceneGraph(false);
        window.hide();
        QTest::qWait(200);
        window.show();
        QVERIFY2(!renderUntil(&window, video, [video](const QImage &) {
                     return video->duration() > 0.0;
                 }).isNull(),
                 "The standalone video surface did not return after loss");
        QTest::qWait(500);
        QCOMPARE(endedSpy.count(), 1);

        AppPaths::clearRuntimeRoot();
    }

    void aFileOpensAtTheStartPositionItWasGiven()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const QString clip = runtimeRoot.filePath(QStringLiteral("split-field.y4m"));
        QVERIFY(writeSplitFieldClip(clip, 120));

        QQuickWindow window;
        window.resize(640, 480);
        auto *video = new MpvVideoItem(window.contentItem());
        video->setWidth(640);
        video->setHeight(480);
        window.show();
        if (!rendersWithOpenGl(&window)) {
            QSKIP("Scene graph is not running on OpenGL; the libmpv render path cannot run");
        }

        video->setStartPosition(8.0);
        video->setSource(QUrl::fromLocalFile(clip));

        QElapsedTimer sinceOpen;
        sinceOpen.start();
        QVERIFY2(!renderUntil(&window, video, [video](const QImage &) {
                     return video->position() >= 8.0;
                 }).isNull(),
                 "The file never reached the position it was opened at");
        // Playing the eight seconds instead of seeking past them could not have
        // finished this quickly.
        QVERIFY2(sinceOpen.elapsed() < 6000,
                 qPrintable(QStringLiteral("Playback started over: reached the "
                                           "resume point only after %1ms")
                                .arg(sinceOpen.elapsed())));
        QCOMPARE(video->errorMessage(), QString{});

        AppPaths::clearRuntimeRoot();
    }

    void stoppingFromTheRemoteRecordsWhereTheFilmGotTo()
    {
        {
            QTemporaryDir probeRoot;
            AppPaths::setRuntimeRoot(probeRoot.path());
            ApplicationController controller;
            QQmlApplicationEngine engine;
            QQuickWindow *window = loadMainWindow(controller, engine);
            QVERIFY2(window != nullptr, "qml/Main.qml did not load from the module");
            if (!rendersWithOpenGl(window)) {
                AppPaths::clearRuntimeRoot();
                QSKIP("Scene graph is not running on OpenGL; the libmpv render path cannot run");
            }
            AppPaths::clearRuntimeRoot();
        }

        // Past the two minutes a resume point needs.
        const StoppedFilm film = playAndStopFrom(150.0);
        QVERIFY2(film.ok, "The catalog title never played to the point it was stopped at");
        QVERIFY2(!film.recorded.isEmpty(), "Stopping from the remote recorded nothing");
        const qint64 storedMs = film.recorded.constLast().at(1).toLongLong();
        QVERIFY2(storedMs >= film.reachedMs - 500,
                 qPrintable(QStringLiteral("Stopping lost the position: stored %1ms "
                                           "for a film that had reached %2ms")
                                .arg(storedMs)
                                .arg(film.reachedMs)));
    }

    void aPeekThatIsStoppedFromTheRemoteRecordsNothing()
    {
        {
            QTemporaryDir probeRoot;
            AppPaths::setRuntimeRoot(probeRoot.path());
            ApplicationController controller;
            QQmlApplicationEngine engine;
            QQuickWindow *window = loadMainWindow(controller, engine);
            QVERIFY2(window != nullptr, "qml/Main.qml did not load from the module");
            if (!rendersWithOpenGl(window)) {
                AppPaths::clearRuntimeRoot();
                QSKIP("Scene graph is not running on OpenGL; the libmpv render path cannot run");
            }
            AppPaths::clearRuntimeRoot();
        }

        const StoppedFilm film = playAndStopFrom(0.0);
        QVERIFY2(film.ok, "The catalog title never started playing");
        QVERIFY2(film.reachedMs < 120'000, "The peek ran past the two minutes it is meant to be");
        QVERIFY2(film.recorded.isEmpty(),
                 "A few seconds into a title were recorded as a resume point");
    }

    // The counterpart of the dropped tap in
    // startupCoverYieldsToEarlyTerminalPlayerStates: a tap that libmpv really
    // takes is a seek in flight and marks the screen as seeking.
    void aTapWhileTheFileIsLoadedMarksTheScreenAsSeeking()
    {
        QTemporaryDir runtimeRoot;
        QTemporaryDir library;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
        const QString clip = library.filePath(QStringLiteral("Arrival.2016.mkv"));
        QVERIFY(writeSplitFieldClip(clip, 1300, 1));

        ApplicationController controller;
        controller.setStartFullscreen(false);
        controller.playLocalFile(clip);
        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY2(window != nullptr, "qml/Main.qml did not load from the module");
        if (!rendersWithOpenGl(window)) {
            QSKIP("Scene graph is not running on OpenGL; the libmpv render path cannot run");
        }

        QPointer<MpvVideoItem> video;
        QTRY_VERIFY2((video = qobject_cast<MpvVideoItem *>(window->findChild<QQuickItem *>(
                          QStringLiteral("videoSurface")))) != nullptr,
                     "PlayerScreen did not create the video surface");
        QQuickItem *screen = video->parentItem();
        QVERIFY(screen != nullptr);
        QVERIFY2(!renderUntil(window, video, [video](const QImage &) {
                      return !video.isNull() && video->duration() > 1000.0;
                  }).isNull(),
                 "The clip never loaded");

        // No requestActivate: a Wayland compositor refuses a client's
        // activation request without a token, so a window that was not
        // focused when it mapped never becomes active. QTest delivers the key
        // to the window itself, and the item takes Qt Quick focus without it.
        screen->forceActiveFocus();
        QTRY_VERIFY(screen->hasActiveFocus());
        QSignalSpy seeking(screen, SIGNAL(startupSeekingChanged()));
        QVERIFY(seeking.isValid());
        QTest::keyClick(window, Qt::Key_Right);
        QTRY_VERIFY2(!seeking.isEmpty(), "A tap on a loaded file did not mark the screen seeking");
    }

    // Restart pressed while the file is still opening has nothing to seek:
    // the item drops the seek, so the session must not be told the film is
    // back at 0. Headless-safe: with no render path libmpv never opens the
    // file, which is exactly the state under judgement.
    void restartWhileTheVideoIsStillOpeningRecordsNothing()
    {
        QTemporaryDir runtimeRoot;
        QTemporaryDir library;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
        const QString title = QStringLiteral("Arrival (2016)");
        QVERIFY(QDir().mkpath(QDir(library.path()).filePath(title)));
        QVERIFY(writeSplitFieldClip(
            QDir(library.path()).filePath(title + QStringLiteral("/") + title
                                          + QStringLiteral(".mkv")),
            300));

        ApplicationController controller;
        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY2(window != nullptr, "qml/Main.qml did not load from the module");
        if (rendersWithOpenGl(window)) {
            QSKIP("The file would load; this judges the window before it has");
        }

        controller.setTemporaryLibraryRoot(library.path());
        QTRY_COMPARE(controller.library()->rowCount(), 1);
        controller.playMediaId(controller.library()
                                   ->data(controller.library()->index(0, 0),
                                          LibraryModel::IdRole)
                                   .toString());

        QPointer<MpvVideoItem> video;
        QTRY_VERIFY2((video = qobject_cast<MpvVideoItem *>(window->findChild<QQuickItem *>(
                          QStringLiteral("videoSurface")))) != nullptr,
                     "PlayerScreen did not create the video surface");
        QQuickItem *screen = video->parentItem();
        QVERIFY(screen != nullptr);

        QSignalSpy recorded(controller.player(), &PlayerController::progressRecorded);
        QVERIFY(recorded.isValid());
        QVERIFY(QMetaObject::invokeMethod(screen, "restart"));
        QTest::qWait(200);
        QVERIFY2(recorded.isEmpty(),
                 "A restart whose seek was dropped was still recorded as position 0");
    }

    void restartingFromTheHudReturnsTheFilmToItsBeginningWithoutUnloading()
    {
        QTemporaryDir runtimeRoot;
        QTemporaryDir library;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const QString title = QStringLiteral("Arrival (2016)");
        QVERIFY(QDir().mkpath(QDir(library.path()).filePath(title)));
        QVERIFY(writeSplitFieldClip(
            QDir(library.path()).filePath(title + QStringLiteral("/") + title
                                          + QStringLiteral(".mkv")),
            200));

        ApplicationController controller;
        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY2(window != nullptr, "qml/Main.qml did not load from the module");
        if (!rendersWithOpenGl(window)) {
            QSKIP("Scene graph is not running on OpenGL; the libmpv render path cannot run");
        }

        controller.setTemporaryLibraryRoot(library.path());
        QTRY_COMPARE(controller.library()->rowCount(), 1);
        controller.playMediaId(controller.library()
                                   ->data(controller.library()->index(0, 0),
                                          LibraryModel::IdRole)
                                   .toString());

        QPointer<MpvVideoItem> video = qobject_cast<MpvVideoItem *>(
            window->findChild<QQuickItem *>(QStringLiteral("videoSurface")));
        QVERIFY2(!video.isNull(), "PlayerScreen did not create the video surface");
        QVERIFY2(!renderUntil(window, video, [video](const QImage &) {
                     return !video.isNull() && video->position() > 3.0;
                 }).isNull(),
                 "The catalog title never played far enough to be restarted");
        QVERIFY2(!video.isNull(), kSurfaceReleased);
        const double length = video->duration();
        QVERIFY(length > 0.0);

        QTest::keyClick(window, Qt::Key_Down);
        QTest::keyClick(window, Qt::Key_Return);

        QVERIFY2(!renderUntil(window, video, [video](const QImage &) {
                     return !video.isNull() && video->position() < 2.0;
                 }).isNull(),
                 "The HUD's restart control did not take the film back to its start");
        QVERIFY2(!video.isNull(), kSurfaceReleased);
        // The film is playing from its beginning, not reloading from it: the
        // same file is still open at the length it already reported.
        QCOMPARE(video->duration(), length);
        QCOMPARE(video->source(), controller.player()->currentFileUrl());
        QCOMPARE(video->errorMessage(), QString{});
        QCOMPARE(controller.navigation()->route(), NavigationController::Route::Player);

        AppPaths::clearRuntimeRoot();
    }

    void unplayableFileReportsFailureInsteadOfEndingNormally()
    {
        // The oracle applies .fail — never .ended — for a load failure
        // (MPVPlayerService.swift:2636-2637), and PlayerView.swift:57 keeps
        // the failed player on screen behind its failure card: a corrupt
        // file reports its failure and stays in the player, never emitting
        // an ordinary end and never navigating away.
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const QString corrupt = runtimeRoot.filePath(QStringLiteral("Broken Title.mkv"));
        QFile file(corrupt);
        QVERIFY(file.open(QIODevice::WriteOnly));
        file.write(QByteArray(4096, '\0'));
        file.close();

        ApplicationController controller;
        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY2(window != nullptr, "qml/Main.qml did not load from the module");
        if (!rendersWithOpenGl(window)) {
            QSKIP("Scene graph is not running on OpenGL; the libmpv render path cannot run");
        }

        controller.playLocalFile(corrupt);
        QPointer<MpvVideoItem> video = qobject_cast<MpvVideoItem *>(
            window->findChild<QQuickItem *>(QStringLiteral("videoSurface")));
        QVERIFY2(!video.isNull(), "PlayerScreen did not create the video surface");
        QSignalSpy endedSpy(video.data(), &MpvVideoItem::playbackEnded);

        const QImage frame = renderUntil(window, video, [video](const QImage &) {
            if (video.isNull()) {
                return false;
            }
            return !video->errorMessage().isEmpty();
        });
        QVERIFY2(!video.isNull(), kSurfaceReleased);
        QVERIFY2(!frame.isNull(), "A corrupt file never reported a playback error");
        QCOMPARE(endedSpy.count(), 0);
        // The failure card owns the frame: the corrupt file stays in the
        // player the way PlayerView.swift:57 keeps the failed player on
        // screen, instead of dismissing the way an ordinary end does.
        QCOMPARE(controller.navigation()->route(), NavigationController::Route::Player);
        QVERIFY2(!video.isNull(), kSurfaceReleased);
        QVERIFY(video->failed());
        QPointer<QQuickItem> failureCard =
            window->findChild<QQuickItem *>(QStringLiteral("playerFailureCard"));
        QVERIFY2(!failureCard.isNull(), "the failed player shows no failure card");
        const auto cardVisible = [&] {
            return !failureCard.isNull()
                && failureCard->property("visible").toBool();
        };
        QTRY_VERIFY(cardVisible());

        AppPaths::clearRuntimeRoot();
    }

    void sourceWaitsForARenderSurfaceBeforeReachingLibmpv()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const QString clip = runtimeRoot.filePath(QStringLiteral("split-field.y4m"));
        QVERIFY(writeSplitFieldClip(clip));

        MpvVideoItem video;
        video.setSource(QUrl::fromLocalFile(clip));

        // libmpv rejects a file within about a second when it has no video
        // output, so a quiet item here means the file was never handed over.
        QTest::qWait(1500);
        QCOMPARE(video.errorMessage(), QString{});
        QCOMPARE(video.duration(), 0.0);

        AppPaths::clearRuntimeRoot();
    }

    void remoteSourcesAreRejectedBeforeReachingLibmpv()
    {
        MpvVideoItem video;
        QSignalSpy endedSpy(&video, &MpvVideoItem::playbackEnded);

        video.setSource(QUrl(QStringLiteral("https://example.invalid/movie.mkv")));

        QVERIFY(video.errorMessage().contains(QStringLiteral("local file")));
        QCOMPARE(video.duration(), 0.0);
        QCOMPARE(endedSpy.count(), 0);
    }

    // PlayerController::prepare re-announces currentFileUrl for every session,
    // including an unchanged URL for a replay (a replayed episode, a loose
    // file reopened). The item's setSource must therefore reload an unchanged
    // source — clearing the end latch and the load latch, re-arming the
    // startup latch, resetting the previous session's clock — rather than
    // returning early. A genuine same-source render-context reload bypasses
    // setSource and reloads through loadCurrentSource alone, so it keeps its
    // resume path: the clock survives. Headless-safe: no render context ever
    // stands here, so both paths are proven on the latches alone.
    void sameUrlReplayReloadsTheSourceInsteadOfReturningEarly()
    {
        const QUrl clip = QUrl::fromLocalFile(QStringLiteral("/played-clip.mkv"));

        MpvVideoItem replay;
        replay.setSource(clip);
        QVERIFY(QMetaObject::invokeMethod(&replay, "onRenderContextReady"));
        QVERIFY(QMetaObject::invokeMethod(&replay, "handleFileLoaded"));
        // Established playback, matching the failure the early return caused:
        // the end latch fires at EOF and the clock is past the startup window.
        QVERIFY(QMetaObject::invokeMethod(&replay, "setPositionValue",
                                         Q_ARG(double, 90.0)));
        // An eof-reached report through the production event-drain path ends
        // the session exactly once.
        int eofFlag = 1;
        mpv_event eofEvent{};
        eofEvent.event_id = MPV_EVENT_PROPERTY_CHANGE;
        mpv_event_property eofProperty{};
        eofProperty.name = "eof-reached";
        eofProperty.format = MPV_FORMAT_FLAG;
        eofProperty.data = &eofFlag;
        eofEvent.data = &eofProperty;
        QSignalSpy replayEnded(&replay, &MpvVideoItem::playbackEnded);
        QVERIFY(QMetaObject::invokeMethod(&replay, "applyEvent",
                                         Q_ARG(mpv_event *, &eofEvent)));
        QCOMPARE(replayEnded.count(), 1);
        // PlayerController re-announces the unchanged URL for the replay.
        QSignalSpy replaySource(&replay, &MpvVideoItem::sourceChanged);
        replay.setSource(clip);
        QCOMPARE(replaySource.count(), 1);
        QVERIFY(replay.startupPending());
        QCOMPARE(replay.position(), 0.0);

        // The reload itself is proven on the load latch through the same
        // production event-drain path the failure used: FILE_LOADED confirms
        // the replayed file behind the surface, and the next end-of-file
        // reports again rather than staying latched from the previous play.
        mpv_event loadedEvent{};
        loadedEvent.event_id = MPV_EVENT_FILE_LOADED;
        QVERIFY(QMetaObject::invokeMethod(&replay, "applyEvent",
                                         Q_ARG(mpv_event *, &loadedEvent)));
        eofFlag = 1;
        QVERIFY(QMetaObject::invokeMethod(&replay, "applyEvent",
                                         Q_ARG(mpv_event *, &eofEvent)));
        QCOMPARE(replayEnded.count(), 2);

        // The genuine render-context reload keeps its resume path: it
        // reloads without resetting the clock and without re-arming the
        // startup latch.
        MpvVideoItem resumed;
        resumed.setSource(clip);
        QVERIFY(QMetaObject::invokeMethod(&resumed, "onRenderContextReady"));
        QVERIFY(QMetaObject::invokeMethod(&resumed, "handleFileLoaded"));
        QVERIFY(QMetaObject::invokeMethod(&resumed, "setPositionValue",
                                         Q_ARG(double, 90.0)));
        QVERIFY(!resumed.startupPending());
        QVERIFY(QMetaObject::invokeMethod(&resumed, "onRenderContextLost"));
        QVERIFY(QMetaObject::invokeMethod(&resumed, "onRenderContextReady"));
        QCOMPARE(resumed.position(), 90.0);
        QVERIFY(!resumed.startupPending());
    }

    // The playback suite must exercise the production event-drain path, not
    // only the direct handleFileLoaded/handleEndFile slots: drainEvents owns
    // the payload and ordering contract (property payload formats,
    // end-file reason/error codes, and the FILE_LOADED/END_FILE order the
    // same-source replay repair depends on). This drives one representative
    // from each event family through applyEvent — the shared body behind
    // drainEvents — in libmpv's own order, and proves the item's
    // notifications follow: duration and pause apply, the end-of-file
    // classifies by its reason and error codes, and a superseding FILE_LOADED
    // retires only teardown noise. Headless-safe: no render context ever
    // stands here.
    void productionEventDrainAppliesPayloadAndOrder()
    {
        MpvVideoItem video;
        const QUrl clip = QUrl::fromLocalFile(QStringLiteral("/played-clip.mkv"));
        video.setSource(clip);
        QSignalSpy endedSpy(&video, &MpvVideoItem::playbackEnded);

        // libmpv's own property payloads: duration arrives as a double and
        // pause as a flag, each in an mpv_event_property.
        double reportedDuration = 3723.0;
        mpv_event durationEvent{};
        durationEvent.event_id = MPV_EVENT_PROPERTY_CHANGE;
        mpv_event_property durationProperty{};
        durationProperty.name = "duration";
        durationProperty.format = MPV_FORMAT_DOUBLE;
        durationProperty.data = &reportedDuration;
        durationEvent.data = &durationProperty;
        QVERIFY(QMetaObject::invokeMethod(&video, "applyEvent",
                                         Q_ARG(mpv_event *, &durationEvent)));
        QCOMPARE(video.duration(), 3723.0);

        int pausedFlag = 1;
        mpv_event pausedEvent{};
        pausedEvent.event_id = MPV_EVENT_PROPERTY_CHANGE;
        mpv_event_property pausedProperty{};
        pausedProperty.name = "pause";
        pausedProperty.format = MPV_FORMAT_FLAG;
        pausedProperty.data = &pausedFlag;
        pausedEvent.data = &pausedProperty;
        QVERIFY(QMetaObject::invokeMethod(&video, "applyEvent",
                                         Q_ARG(mpv_event *, &pausedEvent)));
        QVERIFY(video.paused());

        int resumedFlag = 0;
        pausedProperty.data = &resumedFlag;
        QVERIFY(QMetaObject::invokeMethod(&video, "applyEvent",
                                         Q_ARG(mpv_event *, &pausedEvent)));
        QVERIFY(!video.paused());

        // A wrong payload format carries no value: the item reports the
        // duration as unavailable instead of reading an unrelated union
        // member.
        mpv_event badDurationEvent{};
        badDurationEvent.event_id = MPV_EVENT_PROPERTY_CHANGE;
        mpv_event_property badDurationProperty{};
        badDurationProperty.name = "duration";
        badDurationProperty.format = MPV_FORMAT_NONE;
        badDurationProperty.data = nullptr;
        badDurationEvent.data = &badDurationProperty;
        QVERIFY(QMetaObject::invokeMethod(&video, "applyEvent",
                                         Q_ARG(mpv_event *, &badDurationEvent)));
        QCOMPARE(video.duration(), 0.0);

        // A non-error END_FILE ends nothing: keep-open holds a finished file
        // open and reports the end through eof-reached instead.
        mpv_event quitEvent{};
        quitEvent.event_id = MPV_EVENT_END_FILE;
        mpv_event_end_file quitEndFile{};
        quitEndFile.reason = MPV_END_FILE_REASON_QUIT;
        quitEndFile.error = MPV_ERROR_SUCCESS;
        quitEvent.data = &quitEndFile;
        QVERIFY(QMetaObject::invokeMethod(&video, "applyEvent",
                                         Q_ARG(mpv_event *, &quitEvent)));
        QCOMPARE(endedSpy.count(), 0);
        QVERIFY(!video.failed());

        // An error END_FILE for a file that never loaded is genuine: with a
        // render context standing and no FILE_LOADED confirming the file
        // behind this surface, the video-output code cannot describe a
        // surface the file provably played behind, so it latches untagged
        // and the superseding FILE_LOADED cannot retire it.
        QVERIFY(QMetaObject::invokeMethod(&video, "onRenderContextReady"));
        mpv_event failedOpenEvent{};
        failedOpenEvent.event_id = MPV_EVENT_END_FILE;
        mpv_event_end_file failedOpenEndFile{};
        failedOpenEndFile.reason = MPV_END_FILE_REASON_ERROR;
        failedOpenEndFile.error = MPV_ERROR_VO_INIT_FAILED;
        failedOpenEvent.data = &failedOpenEndFile;
        QVERIFY(QMetaObject::invokeMethod(&video, "applyEvent",
                                         Q_ARG(mpv_event *, &failedOpenEvent)));
        QVERIFY(video.failed());
        mpv_event loadedEvent{};
        loadedEvent.event_id = MPV_EVENT_FILE_LOADED;
        QVERIFY(QMetaObject::invokeMethod(&video, "applyEvent",
                                         Q_ARG(mpv_event *, &loadedEvent)));
        QVERIFY(video.failed());

        // The same error END_FILE for a file libmpv already confirmed behind
        // this surface is teardown noise, and the superseding FILE_LOADED
        // retires it. The queued notification order - the context still
        // reading ready for a surface that is already gone - is the
        // reacquisition order the reload case below pins end to end, so it
        // is covered there rather than duplicated here: the loss is
        // applied before the report drains, and the superseding load
        // arrives with no context standing.
        MpvVideoItem confirmed;
        confirmed.setSource(clip);
        QVERIFY(QMetaObject::invokeMethod(&confirmed, "onRenderContextReady"));
        mpv_event racedLoaded{};
        racedLoaded.event_id = MPV_EVENT_FILE_LOADED;
        QVERIFY(QMetaObject::invokeMethod(&confirmed, "applyEvent",
                                         Q_ARG(mpv_event *, &racedLoaded)));
        QVERIFY(QMetaObject::invokeMethod(&confirmed, "onRenderContextLost"));
        mpv_event racedFailed{};
        racedFailed.event_id = MPV_EVENT_END_FILE;
        mpv_event_end_file racedEndFile{};
        racedEndFile.reason = MPV_END_FILE_REASON_ERROR;
        racedEndFile.error = MPV_ERROR_NOTHING_TO_PLAY;
        racedFailed.data = &racedEndFile;
        QVERIFY(QMetaObject::invokeMethod(&confirmed, "applyEvent",
                                         Q_ARG(mpv_event *, &racedFailed)));
        QVERIFY(confirmed.failed());
        mpv_event racedHealed{};
        racedHealed.event_id = MPV_EVENT_FILE_LOADED;
        QVERIFY(QMetaObject::invokeMethod(&confirmed, "applyEvent",
                                         Q_ARG(mpv_event *, &racedHealed)));
        QVERIFY(!confirmed.failed());
    }

    // The C++ half of the failure/end split: a genuine eof-reached report
    // arriving while the item is failed must not emit playbackEnded. The
    // oracle applies .fail — never .ended — for an error end
    // (MPVPlayerService.swift:2636-2637), and PlayerView.swift:57 keeps
    // the failed player on screen behind its failure card. Driven through
    // the production event-drain path with no QML standing anywhere, so
    // this pins the item's own guard alone: reverting the `!m_failed`
    // half of the eof-reached gate in MpvVideoItem::applyEvent fails here
    // with one unexpected end, while reverting the QML guard cannot move
    // it. Headless-safe: no render context ever stands here.
    void failedItemSuppressesAnOrdinaryEndAtTheSource()
    {
        const QUrl clip = QUrl::fromLocalFile(QStringLiteral("/played-clip.mkv"));

        MpvVideoItem video;
        video.setSource(clip);
        QSignalSpy endedSpy(&video, &MpvVideoItem::playbackEnded);

        // A genuine failure latches first, the way a real load precedes a
        // real failure.
        QVERIFY(QMetaObject::invokeMethod(&video, "setError",
                                         Q_ARG(QString, QStringLiteral("boom"))));
        QVERIFY(video.failed());
        QCOMPARE(endedSpy.count(), 0);

        // A genuine end-of-file report through the production event-drain
        // path: eof-reached set, the keep-open EOF signal.
        int eofFlag = 1;
        mpv_event eofEvent{};
        eofEvent.event_id = MPV_EVENT_PROPERTY_CHANGE;
        mpv_event_property eofProperty{};
        eofProperty.name = "eof-reached";
        eofProperty.format = MPV_FORMAT_FLAG;
        eofProperty.data = &eofFlag;
        eofEvent.data = &eofProperty;
        QVERIFY(QMetaObject::invokeMethod(&video, "applyEvent",
                                         Q_ARG(mpv_event *, &eofEvent)));

        // No ordinary end escapes a failed item, and the failure stands.
        QCOMPARE(endedSpy.count(), 0);
        QVERIFY(video.failed());
        QCOMPARE(video.errorMessage(), QStringLiteral("boom"));
    }

    // The QML half of the failure/end split: the PlayerScreen handler
    // answers only the ordinary end, so a playbackEnded delivered while
    // the item reads failed must not dismiss the player. The oracle
    // applies .fail — never .ended — for an error end
    // (MPVPlayerService.swift:2636-2637), and PlayerView.swift:57 keeps
    // the failed player on screen behind its failure card. The signal is
    // emitted directly at the item — the handler's own input — so this
    // pins the QML guard alone: reverting the `if (video.failed) return`
    // in PlayerScreen.qml dismisses here, while reverting the C++ guard
    // cannot move it. The failure is deliberately NOT cleared first.
    // The failure is established past the item's own load boundary —
    // stubbed past the startup window where no surface ever arrives,
    // waited on libmpv's own clock where it really plays, since the
    // late surface's first load would otherwise clear the injection at
    // the new-load boundary.
    void failedPlayerIgnoresAnOrdinaryEndSignal()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        QTemporaryDir library;
        // The clip has to outlast the waits below: reaching its end
        // navigates out of the player and destroys the surface being
        // judged. Headless the clip never plays, so the length is free.
        QVERIFY(writeSplitFieldClip(
            library.filePath(QStringLiteral("Arrival.2016.mkv")), 300));

        ApplicationController controller;
        controller.setStartFullscreen(false);
        controller.playLocalFile(library.filePath(QStringLiteral("Arrival.2016.mkv")));
        QCOMPARE(controller.navigation()->route(), NavigationController::Route::Player);

        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY2(window != nullptr, "qml/Main.qml did not load from the module");

        QPointer<QQuickItem> screen;
        QPointer<QQuickItem> video;
        QTRY_VERIFY2(
            (video = window->findChild<QQuickItem *>(
                 QStringLiteral("videoSurface")))
                != nullptr,
            "PlayerScreen did not create the video surface");
        screen = video->parentItem();
        QVERIFY2(!screen.isNull(), "the video surface has no screen");
        const auto screenFailureShown = [&] {
            return !screen.isNull()
                && screen->property("showingFailureOverlay").toBool();
        };

        // Past the load boundary, then failed: the card shows and the
        // player stays up. Where libmpv really plays, the boundary is
        // the real load — libmpv's own clock past the startup
        // window — because the surface's late first load clears any
        // earlier injection at the new-load boundary
        // (MpvVideoItem::loadCurrentSource clears at a new source).
        // Headless no surface ever arrives, so the boundary is
        // stubbed past the window instead.
        QVERIFY2(!video.isNull(), "the video surface left before the failure setup");
        if (rendersWithOpenGl(window)) {
            const auto loadBoundarySettled = [&] {
                return !video.isNull()
                    && video->property("position").toDouble() >= 0.35
                    && !video->property("startupPending").toBool();
            };
            QTRY_VERIFY_WITH_TIMEOUT(loadBoundarySettled(), 20000);
        } else {
            QVERIFY(QMetaObject::invokeMethod(video.data(), "setPositionValue",
                                             Q_ARG(double, 1.0)));
        }
        QVERIFY2(!video.isNull(), "the video surface left before the failure setup");
        QVERIFY(QMetaObject::invokeMethod(
            video.data(), "setError", Q_ARG(QString, QStringLiteral("cannot play"))));
        QVERIFY2(!screen.isNull(),
                 "the player screen tore down on the injected failure instead of "
                 "showing the failure card");
        QTRY_VERIFY(screenFailureShown());

        // The ordinary end arrives while failed: the screen must not
        // dismiss and the card must stay up. The failure stays latched —
        // clearing it first is exactly what would make this vacuous.
        QVERIFY2(!video.isNull(), "the video surface left before the end arrived");
        QVERIFY(video->property("failed").toBool());
        QVERIFY(QMetaObject::invokeMethod(video.data(), "playbackEnded"));
        QTest::qWait(500);
        QCOMPARE(controller.navigation()->route(), NavigationController::Route::Player);
        QVERIFY2(!screen.isNull(),
                 "the player screen dismissed on an ordinary end while failed");
        QTRY_VERIFY(screenFailureShown());
    }

    // A FILE_LOADED with no live failure still confirms the file behind the
    // same-source render-surface reload of this confirmed file carries the
    // pre-reload proof, so the queued teardown echo stays teardown and the
    // reload's FILE_LOADED retires it. Pinned here on the latches (failed,
    // message) rather than only inside the longer reload order below, so a
    // regression that stops confirming clean loads fails here first.
    // Headless-safe: no render context ever stands here.
    void fileLoadedWithoutANewLoadLeavesALiveFailureIntact()
    {
        const QUrl clip = QUrl::fromLocalFile(QStringLiteral("/played-clip.mkv"));

        MpvVideoItem video;
        video.setSource(clip);
        QVERIFY(QMetaObject::invokeMethod(&video, "onRenderContextReady"));
        mpv_event confirmed{};
        confirmed.event_id = MPV_EVENT_FILE_LOADED;
        QVERIFY(QMetaObject::invokeMethod(&video, "applyEvent",
                                         Q_ARG(mpv_event *, &confirmed)));
        QVERIFY(!video.failed());
        QCOMPARE(video.errorMessage(), QString{});

        // A genuine failure latches untagged.
        QVERIFY(QMetaObject::invokeMethod(&video, "setError",
                                         Q_ARG(QString, QStringLiteral("boom"))));
        QVERIFY(video.failed());
        QCOMPARE(video.errorMessage(), QStringLiteral("boom"));

        // A same-source surface-generation reload reissues without passing
        // through setSource, so it must preserve the genuine failure — and
        // the reload's own FILE_LOADED must not retire it
        // (PlaybackStateMachine.swift:87-95 rejects .fileLoaded from
        // .failed). Non-vacuous: removing the early return in
        // handleFileLoaded heals here and fails this.
        QVERIFY(QMetaObject::invokeMethod(&video, "onRenderContextLost"));
        QVERIFY(QMetaObject::invokeMethod(&video, "onRenderContextReady"));
        mpv_event reloaded{};
        reloaded.event_id = MPV_EVENT_FILE_LOADED;
        QVERIFY(QMetaObject::invokeMethod(&video, "applyEvent",
                                         Q_ARG(mpv_event *, &reloaded)));
        QVERIFY(video.failed());
        QCOMPARE(video.errorMessage(), QStringLiteral("boom"));

        // The new-source boundary is the exit that does clear: a new source
        // clears the failure at the boundary, and its FILE_LOADED confirms
        // clean. Non-vacuous companion: the same FILE_LOADED that left the
        // genuine latch above retires nothing but confirms the new load.
        const QUrl next = QUrl::fromLocalFile(QStringLiteral("/next-clip.mkv"));
        video.setSource(next);
        QVERIFY(!video.failed());
        QCOMPARE(video.errorMessage(), QString{});
        QVERIFY(QMetaObject::invokeMethod(&video, "onRenderContextReady"));
        mpv_event nextLoaded{};
        nextLoaded.event_id = MPV_EVENT_FILE_LOADED;
        QVERIFY(QMetaObject::invokeMethod(&video, "applyEvent",
                                         Q_ARG(mpv_event *, &nextLoaded)));
        QVERIFY(!video.failed());
        QCOMPARE(video.errorMessage(), QString{});
    }

    // The render-surface reacquisition order libmpv actually produces: the
    // teardown END_FILE for the superseded surface can arrive after the
    // reload already cleared the FILE_LOADED confirmation, with the render
    // context reading ready for a surface that is already gone. Against the
    // pre-repair classifier that trailing report latches as a genuine open
    // failure, which the reload's own FILE_LOADED can never heal — the
    // poisoned reload behind the display-backed "video did not come back"
    // failure. The repair carries the pre-reload proof across the reload
    // boundary, so the same order classifies teardown, heals on the
    // reload's FILE_LOADED, and leaves every genuine failure latched.
    // Headless-safe: the order is driven through the production event-drain
    // path with no render context standing anywhere in this case.
    void surfaceReloadHealsATrailingTeardownReport()
    {
        const QUrl clip = QUrl::fromLocalFile(QStringLiteral("/played-clip.mkv"));

        MpvVideoItem video;
        video.setSource(clip);
        QVERIFY(QMetaObject::invokeMethod(&video, "onRenderContextReady"));
        mpv_event confirmed{};
        confirmed.event_id = MPV_EVENT_FILE_LOADED;
        QVERIFY(QMetaObject::invokeMethod(&video, "applyEvent",
                                         Q_ARG(mpv_event *, &confirmed)));
        QVERIFY(!video.failed());

        // The scene graph replaces the surface: the destruction of the old
        // renderer queues renderContextLost behind libmpv's own reports,
        // while the new renderer queues renderContextReady just as late.
        // The reload therefore issues while the flag still reads ready.
        QVERIFY(QMetaObject::invokeMethod(&video, "onRenderContextLost"));
        QVERIFY(QMetaObject::invokeMethod(&video, "onRenderContextReady"));

        // libmpv's teardown report for the superseded surface arrives after
        // the reload cleared the confirmation, with the flag reading ready.
        mpv_event supersededTeardown{};
        supersededTeardown.event_id = MPV_EVENT_END_FILE;
        mpv_event_end_file supersededEndFile{};
        supersededEndFile.reason = MPV_END_FILE_REASON_ERROR;
        supersededEndFile.error = MPV_ERROR_VO_INIT_FAILED;
        supersededTeardown.data = &supersededEndFile;
        QVERIFY(QMetaObject::invokeMethod(&video, "applyEvent",
                                         Q_ARG(mpv_event *, &supersededTeardown)));
        // Teardown noise latches until the superseding load retires it, the
        // way the display-backed reacquisition waits on the reload.
        QVERIFY(video.failed());

        // A second queued teardown report — the observed NOTHING_TO_PLAY
        // trailing the first — only moves the pair count on for the
        // load-time guard: the live tagged latch proves the in-flight open
        // is the superseding reload, so the queued report still describes
        // the old surface, not the new open failing.
        mpv_event trailingTeardown{};
        trailingTeardown.event_id = MPV_EVENT_END_FILE;
        mpv_event_end_file trailingEndFile{};
        trailingEndFile.reason = MPV_END_FILE_REASON_ERROR;
        trailingEndFile.error = MPV_ERROR_NOTHING_TO_PLAY;
        trailingTeardown.data = &trailingEndFile;
        QVERIFY(QMetaObject::invokeMethod(&video, "applyEvent",
                                         Q_ARG(mpv_event *, &trailingTeardown)));
        QVERIFY(video.failed());

        // The in-flight reload's own FILE_LOADED supersedes the lost surface
        // and retires the teardown latch: the pair count moved on, but the
        // load arrives behind the reload's still-standing surface, so the
        // load-time guard heals. The pre-repair state fails exactly here
        // only where it promoted the latch at report time; the repaired
        // guard pairs the count with the standing surface instead.
        mpv_event reloaded{};
        reloaded.event_id = MPV_EVENT_FILE_LOADED;
        QVERIFY(QMetaObject::invokeMethod(&video, "applyEvent",
                                         Q_ARG(mpv_event *, &reloaded)));
        QVERIFY(!video.failed());
        QCOMPARE(video.errorMessage(), QString{});

        // The carried proof is subsumed by that FILE_LOADED: a later
        // video-output error for a file that never loaded latches genuine
        // again and no later FILE_LOADED can heal it. Stopping clears the
        // confirmation, and the fresh open's error then describes a file
        // that never loaded.
        video.stop();
        video.setSource(clip);
        QVERIFY(QMetaObject::invokeMethod(&video, "onRenderContextReady"));
        mpv_event brokenReload{};
        brokenReload.event_id = MPV_EVENT_END_FILE;
        mpv_event_end_file brokenEndFile{};
        brokenEndFile.reason = MPV_END_FILE_REASON_ERROR;
        brokenEndFile.error = MPV_ERROR_VO_INIT_FAILED;
        brokenReload.data = &brokenEndFile;
        QVERIFY(QMetaObject::invokeMethod(&video, "applyEvent",
                                         Q_ARG(mpv_event *, &brokenReload)));
        QVERIFY(video.failed());
        mpv_event lateLoaded{};
        lateLoaded.event_id = MPV_EVENT_FILE_LOADED;
        QVERIFY(QMetaObject::invokeMethod(&video, "applyEvent",
                                         Q_ARG(mpv_event *, &lateLoaded)));
        QVERIFY(video.failed());
    }

    // The P1 order repaired here: a genuine failure during the new
    // same-source open — the teardown END_FILE for the superseded surface
    // first, then a second video-output error for the reload's own open —
    // stays latched through the reload's later FILE_LOADED. The two
    // reports carry the same codes and arrive while the reload's surface
    // reads present, so no report-time rule promotes one of them; instead
    // the first stays retiring and the pair count moves on, and the
    // load-time guard in handleFileLoaded pairs that moved-on count with
    // the settled render-context read — the reload's open failing took its
    // surface with it, so the trailing load arrives with no context
    // standing — and holds the latch genuine on that pairing
    // (PlaybackStateMachine.swift:87-95 rejects .fileLoaded from
    // .failed). Non-vacuous: the same order with the second report removed
    // heals (pinned above) — so this fails if the classifier drops the
    // in-flight distinction — and the same two reports with the reload's
    // surface still standing behind the trailing load heal (pinned
    // below), so a pair count alone without the load-time context read
    // can never hold the latch. The trailing load here arrives with no
    // render context standing — the reload's open failing took its
    // surface with it — which is the teardown pair's own load rather than
    // a reload that healed anything.
    // Headless-safe: driven through the production event-drain path with no
    // render context standing anywhere in this case.
    void sameSourceReloadThatFailsBeforeItsNextFileLoadedStaysGenuine()
    {
        const QUrl clip = QUrl::fromLocalFile(QStringLiteral("/played-clip.mkv"));

        MpvVideoItem video;
        video.setSource(clip);
        QVERIFY(QMetaObject::invokeMethod(&video, "onRenderContextReady"));
        mpv_event confirmed{};
        confirmed.event_id = MPV_EVENT_FILE_LOADED;
        QVERIFY(QMetaObject::invokeMethod(&video, "applyEvent",
                                         Q_ARG(mpv_event *, &confirmed)));
        QVERIFY(!video.failed());

        // The surface is replaced; the reload issues while the flag still
        // reads ready, exactly as in the healing case above. The reload's
        // own open then fails before its FILE_LOADED arrives — the second
        // tagged report while the retiring latch is live — so the pair
        // count moves on here and the load-time guard below holds the
        // latch. The reload's open failing takes its surface with it, so
        // the trailing FILE_LOADED below arrives with no context standing
        // and cannot retire the latch the way the healing case's
        // surface-backed load retires teardown noise.
        QVERIFY(QMetaObject::invokeMethod(&video, "onRenderContextLost"));
        QVERIFY(QMetaObject::invokeMethod(&video, "onRenderContextReady"));

        // The superseded surface's teardown report: teardown noise, latched
        // until the reload's own FILE_LOADED retires it.
        mpv_event supersededTeardown{};
        supersededTeardown.event_id = MPV_EVENT_END_FILE;
        mpv_event_end_file supersededEndFile{};
        supersededEndFile.reason = MPV_END_FILE_REASON_ERROR;
        supersededEndFile.error = MPV_ERROR_VO_INIT_FAILED;
        supersededTeardown.data = &supersededEndFile;
        QVERIFY(QMetaObject::invokeMethod(&video, "applyEvent",
                                         Q_ARG(mpv_event *, &supersededTeardown)));
        QVERIFY(video.failed());

        // The reload's own open then fails with the same signature before
        // its FILE_LOADED arrives: the live retiring latch plus the
        // moved-on pair count prove the pair drained here. Nothing
        // promotes the latch at report time — the genuine decision waits
        // for the load-time guard below, which pairs that moved-on count
        // with the lost surface.
        mpv_event reloadFailure{};
        reloadFailure.event_id = MPV_EVENT_END_FILE;
        mpv_event_end_file reloadEndFile{};
        reloadEndFile.reason = MPV_END_FILE_REASON_ERROR;
        reloadEndFile.error = MPV_ERROR_NOTHING_TO_PLAY;
        reloadFailure.data = &reloadEndFile;
        QVERIFY(QMetaObject::invokeMethod(&video, "applyEvent",
                                         Q_ARG(mpv_event *, &reloadFailure)));
        QVERIFY(video.failed());

        // The reload's open failing takes its surface with it: the new
        // renderer's context is lost before the reload's own FILE_LOADED
        // arrives, so that load cannot retire the genuine latch.
        QVERIFY(QMetaObject::invokeMethod(&video, "onRenderContextLost"));

        // The reload's FILE_LOADED must not heal the genuine latch: the
        // pair count moved on and no render context stands behind this
        // load, so the load-time guard holds it. The failure stays with
        // its message intact, and a further teardown-only report cannot
        // downgrade it back to retiring noise either.
        mpv_event reloaded{};
        reloaded.event_id = MPV_EVENT_FILE_LOADED;
        QVERIFY(QMetaObject::invokeMethod(&video, "applyEvent",
                                         Q_ARG(mpv_event *, &reloaded)));
        QVERIFY(video.failed());
        QVERIFY(!video.errorMessage().isEmpty());

        mpv_event lateTeardown{};
        lateTeardown.event_id = MPV_EVENT_END_FILE;
        mpv_event_end_file lateEndFile{};
        lateEndFile.reason = MPV_END_FILE_REASON_ERROR;
        lateEndFile.error = MPV_ERROR_VO_INIT_FAILED;
        lateTeardown.data = &lateEndFile;
        QVERIFY(QMetaObject::invokeMethod(&video, "applyEvent",
                                         Q_ARG(mpv_event *, &lateTeardown)));
        QVERIFY(video.failed());
        QVERIFY(!video.errorMessage().isEmpty());

        // The genuine latch clears only at a real new-load boundary: a new
        // source clears it at the boundary, and the new load then confirms
        // clean. Non-vacuous: without the boundary clear this fails on the
        // line below, because FILE_LOADED never clears a genuine latch.
        const QUrl next = QUrl::fromLocalFile(QStringLiteral("/next-clip.mkv"));
        video.setSource(next);
        QVERIFY(!video.failed());
        QCOMPARE(video.errorMessage(), QString{});
        QVERIFY(QMetaObject::invokeMethod(&video, "onRenderContextReady"));
        mpv_event nextLoaded{};
        nextLoaded.event_id = MPV_EVENT_FILE_LOADED;
        QVERIFY(QMetaObject::invokeMethod(&video, "applyEvent",
                                         Q_ARG(mpv_event *, &nextLoaded)));
        QVERIFY(!video.failed());
        QCOMPARE(video.errorMessage(), QString{});
    }

    // The ordering guard for the one discriminator: the same two
    // teardown-signature reports stay teardown and heal through the
    // reload's FILE_LOADED when that load arrives behind the reload's
    // still-standing surface — the pair count moved on, but the
    // load-time context reads present, so the guard heals. Only the
    // pairing holds the latch; neither fact alone does. Headless-safe:
    // driven through the production event-drain path. The reload's surface
    // reads present here because the new renderer's context notification
    // is still queued behind libmpv's own reports, exactly the way the
    // first echo of the superseded surface arrives in production.
    void secondTeardownReportWhileTheReloadSurfaceStandsStaysTeardown()
    {
        const QUrl clip = QUrl::fromLocalFile(QStringLiteral("/played-clip.mkv"));

        MpvVideoItem video;
        video.setSource(clip);
        QVERIFY(QMetaObject::invokeMethod(&video, "onRenderContextReady"));
        mpv_event confirmed{};
        confirmed.event_id = MPV_EVENT_FILE_LOADED;
        QVERIFY(QMetaObject::invokeMethod(&video, "applyEvent",
                                         Q_ARG(mpv_event *, &confirmed)));
        QVERIFY(!video.failed());

        // The surface is replaced; the reload issues while the flag still
        // reads ready, exactly as in the genuine case above — but the
        // reload's surface is never lost again, so both queued reports
        // arrive while it still stands.
        QVERIFY(QMetaObject::invokeMethod(&video, "onRenderContextLost"));
        QVERIFY(QMetaObject::invokeMethod(&video, "onRenderContextReady"));

        mpv_event supersededTeardown{};
        supersededTeardown.event_id = MPV_EVENT_END_FILE;
        mpv_event_end_file supersededEndFile{};
        supersededEndFile.reason = MPV_END_FILE_REASON_ERROR;
        supersededEndFile.error = MPV_ERROR_VO_INIT_FAILED;
        supersededTeardown.data = &supersededEndFile;
        QVERIFY(QMetaObject::invokeMethod(&video, "applyEvent",
                                         Q_ARG(mpv_event *, &supersededTeardown)));
        QVERIFY(video.failed());

        // The second report arrives with the reload's surface still
        // standing: it only moves the pair count on (see setError) rather
        // than deciding anything, and the reload's FILE_LOADED arrives
        // behind that standing surface, so the load-time guard heals.
        // Non-vacuous: the same second report with the context lost first
        // holds instead (pinned above), so a count-alone regression — one
        // that heals or holds on the count without the load-time context
        // read — fails here by leaving the latch held or by never holding
        // the genuine case above.
        mpv_event secondEcho{};
        secondEcho.event_id = MPV_EVENT_END_FILE;
        mpv_event_end_file secondEndFile{};
        secondEndFile.reason = MPV_END_FILE_REASON_ERROR;
        secondEndFile.error = MPV_ERROR_NOTHING_TO_PLAY;
        secondEcho.data = &secondEndFile;
        QVERIFY(QMetaObject::invokeMethod(&video, "applyEvent",
                                         Q_ARG(mpv_event *, &secondEcho)));
        QVERIFY(video.failed());

        mpv_event reloaded{};
        reloaded.event_id = MPV_EVENT_FILE_LOADED;
        QVERIFY(QMetaObject::invokeMethod(&video, "applyEvent",
                                         Q_ARG(mpv_event *, &reloaded)));
        QVERIFY(!video.failed());
        QCOMPARE(video.errorMessage(), QString{});
    }

    // The single-report surface-loss order still heals: on an ordinary
    // loss/regain libmpv can post a lone VO_INIT_FAILED, and the reload's
    // own FILE_LOADED retires that latch whether the context notification
    // has been drained yet or not. Both event orders end unfailed.
    // Headless-safe: both orders are driven through the item's own slots
    // and the production event-drain path, with no render context
    // standing where the order says none stands.
    void singleTeardownReportOnARegainedSurfaceHealsOnReloadFileLoaded()
    {
        const QUrl clip = QUrl::fromLocalFile(QStringLiteral("/played-clip.mkv"));

        const auto driveSingleReportOrder = [&clip](bool contextBackBeforeReport) {
            MpvVideoItem video;
            video.setSource(clip);
            QVERIFY(QMetaObject::invokeMethod(&video, "onRenderContextReady"));
            mpv_event confirmed{};
            confirmed.event_id = MPV_EVENT_FILE_LOADED;
            QVERIFY(QMetaObject::invokeMethod(&video, "applyEvent",
                                             Q_ARG(mpv_event *, &confirmed)));
            QVERIFY(!video.failed());

            // The surface is lost; the reload issues while the flag still
            // reads ready, exactly as in the two-report cases above.
            QVERIFY(QMetaObject::invokeMethod(&video, "onRenderContextLost"));
            QVERIFY(QMetaObject::invokeMethod(&video, "onRenderContextReady"));

            // Order A regains the surface before the single teardown
            // report; order B reports while the context is still absent.
            // Either way the report is teardown noise for a file that
            // provably played, latched until the reload's FILE_LOADED
            // retires it.
            if (!contextBackBeforeReport) {
                QVERIFY(QMetaObject::invokeMethod(&video, "onRenderContextLost"));
            }
            mpv_event teardown{};
            teardown.event_id = MPV_EVENT_END_FILE;
            mpv_event_end_file teardownEndFile{};
            teardownEndFile.reason = MPV_END_FILE_REASON_ERROR;
            teardownEndFile.error = MPV_ERROR_VO_INIT_FAILED;
            teardown.data = &teardownEndFile;
            QVERIFY(QMetaObject::invokeMethod(&video, "applyEvent",
                                             Q_ARG(mpv_event *, &teardown)));
            QVERIFY(video.failed());
            if (!contextBackBeforeReport) {
                QVERIFY(QMetaObject::invokeMethod(&video, "onRenderContextReady"));
            }

            // The reload's FILE_LOADED retires the single teardown latch:
            // the pair count never moved on, so the load-time guard finds
            // no second report to pair and heals.
            mpv_event reloaded{};
            reloaded.event_id = MPV_EVENT_FILE_LOADED;
            QVERIFY(QMetaObject::invokeMethod(&video, "applyEvent",
                                             Q_ARG(mpv_event *, &reloaded)));
            QVERIFY(!video.failed());
            QCOMPARE(video.errorMessage(), QString{});
        };

        // Order A: FILE_LOADED, contextLost, contextReady, one
        // VO_INIT_FAILED, FILE_LOADED.
        driveSingleReportOrder(true);
        // Order B: FILE_LOADED, contextLost, one VO_INIT_FAILED,
        // contextReady, FILE_LOADED.
        driveSingleReportOrder(false);
    }

    // The headline P1 regression: the ordinary contextLost/regain pair
    // drains while m_fileLoaded is still true, and the item must recover
    // rather than latch. libmpv posts the VO_INIT_FAILED/NOTHING_TO_PLAY
    // pair for the superseded surface. No load boundary runs before the
    // reports, so the confirmation stays live through both — the exact
    // state the removed `|| m_fileLoaded` disjunct read as genuine on the
    // second report — and the trailing FILE_LOADED below is the reload's
    // own superseding load. Headless-safe: both orders are driven through
    // the item's own slots and the production event-drain path, with no
    // render context standing where the order says none stands.
    void teardownPairWhileTheFileStaysLoadedHealsOnReloadFileLoaded()
    {
        const QUrl clip = QUrl::fromLocalFile(QStringLiteral("/played-clip.mkv"));

        const auto drivePairOrder = [&clip](bool regainBeforeReports) {
            MpvVideoItem video;
            video.setSource(clip);
            QVERIFY(QMetaObject::invokeMethod(&video, "onRenderContextReady"));
            mpv_event confirmed{};
            confirmed.event_id = MPV_EVENT_FILE_LOADED;
            QVERIFY(QMetaObject::invokeMethod(&video, "applyEvent",
                                             Q_ARG(mpv_event *, &confirmed)));
            QVERIFY(!video.failed());

            // Order A drains the pair before either notification: both the
            // loss and the regain are still queued behind libmpv's own
            // reports, so the flag reads ready throughout. Order B drains
            // the loss first and the regain after the pair. Neither order
            // issues a load boundary before the reports, so the
            // confirmation stays live through both.
            if (!regainBeforeReports) {
                QVERIFY(QMetaObject::invokeMethod(&video, "onRenderContextLost"));
            }
            mpv_event teardown{};
            teardown.event_id = MPV_EVENT_END_FILE;
            mpv_event_end_file teardownEndFile{};
            teardownEndFile.reason = MPV_END_FILE_REASON_ERROR;
            teardownEndFile.error = MPV_ERROR_VO_INIT_FAILED;
            teardown.data = &teardownEndFile;
            QVERIFY(QMetaObject::invokeMethod(&video, "applyEvent",
                                             Q_ARG(mpv_event *, &teardown)));
            QVERIFY(video.failed());
            if (!regainBeforeReports) {
                QVERIFY(QMetaObject::invokeMethod(&video, "onRenderContextReady"));
            }

            // The second report of the ordinary pair drains while the file
            // confirmation is still live. Against the pre-repair logic this
            // is where the latch turns genuine: m_failed and
            // m_errorIsSurfaceTeardown are live, and the removed
            // `|| m_fileLoaded` disjunct reads true, so the message branch
            // promotes the latch and the trailing FILE_LOADED below can
            // never retire it. The repaired logic keeps every report-time
            // latch retiring and only moves the pair count on here.
            mpv_event secondTeardown{};
            secondTeardown.event_id = MPV_EVENT_END_FILE;
            mpv_event_end_file secondEndFile{};
            secondEndFile.reason = MPV_END_FILE_REASON_ERROR;
            secondEndFile.error = MPV_ERROR_NOTHING_TO_PLAY;
            secondTeardown.data = &secondEndFile;
            QVERIFY(QMetaObject::invokeMethod(&video, "applyEvent",
                                             Q_ARG(mpv_event *, &secondTeardown)));
            QVERIFY(video.failed());

            // Non-vacuous pairing: the genuine case below proves a second
            // tagged report before this load moves the pair count on, so
            // healing here cannot be an unconditional clear — only the
            // repair's load-time context read retires this pair, because
            // the standing surface behind the load shows no open failed.
            // The reload's FILE_LOADED retires the retiring pair latch.
            mpv_event reloaded{};
            reloaded.event_id = MPV_EVENT_FILE_LOADED;
            QVERIFY(QMetaObject::invokeMethod(&video, "applyEvent",
                                             Q_ARG(mpv_event *, &reloaded)));
            QVERIFY(!video.failed());
            QCOMPARE(video.errorMessage(), QString{});
        };

        // Order A: FILE_LOADED, contextLost, contextReady, VO_INIT_FAILED,
        // NOTHING_TO_PLAY, FILE_LOADED — the ordinary loss/regain pair
        // draining with the confirmation live. This is the order the old
        // `|| m_fileLoaded` disjunct latched permanently: the trailing
        // FILE_LOADED below fails pre-repair because the second report
        // already promoted the latch genuine.
        drivePairOrder(true);
        // Order B: FILE_LOADED, contextLost, VO_INIT_FAILED,
        // NOTHING_TO_PLAY, contextReady, FILE_LOADED — the queued-notification
        // order, where the pair drains before the regain notification.
        drivePairOrder(false);
    }

    void playerLayeringKeepsControlsAndScrimAboveTheStateSurface()
    {
        // PlayerView.swift:45-67 composes the failure and startup overlays
        // before controlsLayer in the ZStack and both outside the auto-hiding
        // controls layer, so the full-screen startup layer covers the HUD
        // while it is up and the controls scrim stacks above the state
        // surface. Proved at the real QML object layer, not on pixels: the
        // screen's own children carry the state layer below the scrim, the
        // scrim owns the controls subtree, and both state overlays live
        // inside the state layer. Headless-safe: only object parenting and
        // stacking are judged. Environment-independent: nothing here pins
        // a stubbed copy — the overlay starts up and fills the frame
        // whether or not libmpv really plays behind it.
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        QTemporaryDir library;
        // The clip has to outlast the waits below: reaching its end
        // navigates out of the player and destroys the surface being
        // judged. Headless the clip never plays, so the length is free.
        QVERIFY(writeSplitFieldClip(
            library.filePath(QStringLiteral("Arrival.2016.mkv")), 300));

        ApplicationController controller;
        controller.setStartFullscreen(false);
        controller.playLocalFile(library.filePath(QStringLiteral("Arrival.2016.mkv")));
        QCOMPARE(controller.navigation()->route(), NavigationController::Route::Player);

        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY2(window != nullptr, "qml/Main.qml did not load from the module");

        QPointer<QQuickItem> video;
        QTRY_VERIFY2(
            (video = window->findChild<QQuickItem *>(
                 QStringLiteral("videoSurface")))
                != nullptr,
            "PlayerScreen did not create the video surface");
        QPointer<QQuickItem> screen = video->parentItem();
        QVERIFY2(!screen.isNull(), "the video surface has no screen");

        QPointer<QQuickItem> stateLayer;
        QPointer<QQuickItem> scrim;
        QPointer<QQuickItem> startupOverlay;
        QPointer<QQuickItem> failureCard;
        QTRY_VERIFY2(!screen.isNull()
                         && (stateLayer = screen->findChild<QQuickItem *>(
                                 QStringLiteral("playerStateLayer"),
                                 Qt::FindDirectChildrenOnly))
                             != nullptr,
                     "PlayerScreen did not create the state layer");
        QTRY_VERIFY2(!screen.isNull()
                         && (scrim = screen->findChild<QQuickItem *>(
                                 QStringLiteral("playerScrim"), Qt::FindDirectChildrenOnly))
                             != nullptr,
                     "PlayerScreen did not create the scrim");
        QTRY_VERIFY2(!stateLayer.isNull()
                         && (startupOverlay = stateLayer->findChild<QQuickItem *>(
                                 QStringLiteral("playerStartupOverlay"),
                                 Qt::FindDirectChildrenOnly))
                             != nullptr,
                     "the state layer does not own the startup overlay");
        QTRY_VERIFY2(!stateLayer.isNull()
                         && (failureCard = stateLayer->findChild<QQuickItem *>(
                                 QStringLiteral("playerFailureCard"),
                                 Qt::FindDirectChildrenOnly))
                             != nullptr,
                     "the state layer does not own the failure card");

        // The controls live inside the scrim, never beside the state layer.
        QVERIFY2(scrim->findChild<QQuickItem *>(QStringLiteral("playbackStatus"))
                     != nullptr,
                 "the scrim does not own the controls");
        QVERIFY2(stateLayer->findChild<QQuickItem *>(QStringLiteral("playbackStatus"))
                     == nullptr,
                 "the controls leaked into the state layer");

        // The state layer stacks beneath the scrim at the real object layer:
        // it carries the lower z, which is what decides the paint order
        // for siblings with different z regardless of declaration order.
        QVERIFY2(scrim->z() > stateLayer->z(),
                 "the controls scrim lost its stacking order over the state layer");

        // The startup overlay owns the whole frame while it is up. Every
        // retry predicate carries its own liveness check: the route
        // leaving destroys this whole subtree, and a QPointer nulled
        // mid-wait must fail the predicate instead of dereferencing a
        // destroyed item inside QObject::property.
        const auto overlayVisible = [&] {
            return !startupOverlay.isNull()
                && startupOverlay->property("visible").toBool();
        };
        const auto overlayMatchesScreenWidth = [&] {
            return !startupOverlay.isNull() && !screen.isNull()
                && qRound(startupOverlay->width()) == qRound(screen->width());
        };
        const auto overlayMatchesScreenHeight = [&] {
            return !startupOverlay.isNull() && !screen.isNull()
                && qRound(startupOverlay->height()) == qRound(screen->height());
        };
        QVERIFY2(!startupOverlay.isNull(), "the startup overlay left before it was judged");
        QTRY_VERIFY(overlayVisible());
        QVERIFY2(!startupOverlay.isNull() && !screen.isNull(),
                 "the player screen left before its geometry was judged");
        QTRY_VERIFY(overlayMatchesScreenWidth());
        QVERIFY2(!startupOverlay.isNull() && !screen.isNull(),
                 "the player screen left before its geometry was judged");
        QTRY_VERIFY(overlayMatchesScreenHeight());
    }

    // PlayerView.swift:618-640's PlayerPreparationOverlay behind :642-675's
    // PlayerStartupOverlay: the artwork backdrop treatments (1.04 overscan,
    // black-at-0.62 dim, blur 16, top-to-bottom 0.78/0.48/0.82 gradient),
    // the intrinsically sized card (12/18 stack, 22/34-by-16/24 padding,
    // black-at-0.72 radius-8 fill, white-at-0.12 1px stroke), the small
    // white spinner turning once a second, and the 14/20-medium copy in
    // white at 0.86. Judged on the real TransitionLoading items hosted in
    // the real PlayerScreen — object properties, never pixels — so the
    // artwork treatments are source-backed contracts on named items rather
    // than rendered assertions no headless gate executes. Headless-safe:
    // only properties are read; the artwork URL is judged, never fetched.
    void playerStartupOverlayMatchesTheReleasedPreparationSurface()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        QTemporaryDir library;
        // The clip has to outlast the waits below: reaching its end
        // navigates out of the player and destroys the surface being
        // judged. Headless the clip never plays, so the length is free.
        QVERIFY(writeSplitFieldClip(
            library.filePath(QStringLiteral("Arrival.2016.mkv")), 300));

        ApplicationController controller;
        controller.setStartFullscreen(false);
        controller.settings()->setLeanBackMode(false);
        controller.playLocalFile(library.filePath(QStringLiteral("Arrival.2016.mkv")));
        QCOMPARE(controller.navigation()->route(), NavigationController::Route::Player);

        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY2(window != nullptr, "qml/Main.qml did not load from the module");
        // Judged with playback stubbed at the item's own slots: the
        // pre-first-frame copy and its 0.1/0.35 articulation cannot be
        // expressed while libmpv really drives the same position clock,
        // so this runs headless only.
        if (rendersWithOpenGl(window)) {
            QSKIP("Stubbed startup premises cannot run while libmpv really plays");
        }

        QPointer<QQuickItem> screen;
        QPointer<QQuickItem> video;
        QTRY_VERIFY2(
            (video = window->findChild<QQuickItem *>(
                 QStringLiteral("videoSurface")))
                != nullptr,
            "PlayerScreen did not create the video surface");
        screen = video->parentItem();
        QVERIFY2(!screen.isNull(), "the video surface has no screen");

        // The final setError below applies the oracle's .fail transition,
        // never .ended, so the route stays up; every retry predicate
        // carries its own liveness check, so a teardown mid-wait fails
        // the predicate instead of dereferencing a destroyed QQuickItem.
        const auto screenShowsStartup = [&] {
            return !screen.isNull()
                && screen->property("showingStartupOverlay").toBool();
        };
        const auto screenStartupCleared = [&] {
            return !screen.isNull()
                && !screen->property("showingStartupOverlay").toBool();
        };
        QPointer<QQuickItem> overlay;
        QPointer<QQuickItem> stateLayerLookup =
            screen->findChild<QQuickItem *>(
                QStringLiteral("playerStateLayer"), Qt::FindDirectChildrenOnly);
        overlay = screen->findChild<QQuickItem *>(
            QStringLiteral("playerStartupOverlay"), Qt::FindDirectChildrenOnly);
        // The overlay is found through the state layer that owns it, the
        // same parenting the layering case pins.
        if (overlay.isNull()) {
            QVERIFY2(!stateLayerLookup.isNull(),
                     "PlayerScreen did not create the state layer");
            overlay = stateLayerLookup->findChild<QQuickItem *>(
                QStringLiteral("playerStartupOverlay"), Qt::FindDirectChildrenOnly);
        }
        QVERIFY2(!overlay.isNull(), "the state layer does not own the startup overlay");

        // The startup copy contract: pre-first-frame copy while starting.
        QVERIFY2(!screen.isNull(), "the player screen left before the startup copy was judged");
        QTRY_VERIFY(screenShowsStartup());
        QVERIFY2(!screen.isNull(), "the player screen left mid-assertion");
        QCOMPARE(screen->property("startupMessage").toString(),
                 QStringLiteral("Opening video..."));
        QVERIFY2(!overlay.isNull(), "the startup overlay left mid-assertion");
        QCOMPARE(overlay->property("message").toString(),
                 QStringLiteral("Opening video..."));

        // The articulated copy: a first position past zero but below the
        // 0.35s window names "Starting playback..." without clearing the
        // latch; reaching the window clears it and empties the copy.
        const auto screenStartingCopy = [&] {
            return !screen.isNull()
                && screen->property("startupMessage").toString()
                == QStringLiteral("Starting playback...");
        };
        const auto screenShowsStartupCover = [&] {
            return !screen.isNull()
                && screen->property("showingStartupOverlay").toBool();
        };
        QVERIFY2(!video.isNull(), "the video surface left before the startup copy was judged");
        QVERIFY(QMetaObject::invokeMethod(video.data(), "setPositionValue",
                                         Q_ARG(double, 0.1)));
        QVERIFY2(!screen.isNull(), "the player screen left mid-assertion");
        QTRY_VERIFY(screenStartingCopy());
        QVERIFY2(!screen.isNull(), "the player screen left mid-assertion");
        QVERIFY(screenShowsStartupCover());
        QVERIFY2(!video.isNull(), "the video surface left mid-assertion");
        QVERIFY(QMetaObject::invokeMethod(video.data(), "setPositionValue",
                                         Q_ARG(double, 0.35)));
        QVERIFY2(!screen.isNull(), "the player screen left mid-assertion");
        QTRY_VERIFY(screenStartupCleared());
        QVERIFY2(!screen.isNull(), "the player screen left mid-assertion");
        QCOMPARE(screen->property("startupMessage").toString(), QString{});

        // The card is intrinsically sized: its chrome hugs the column with
        // the released padding, not a wide preparation column. The column
        // itself hugs the message: PlayerView.swift:618-640 carries no
        // .frame(maxWidth:) on the preparation card, so two messages of
        // clearly different lengths must paint clearly different card
        // widths, and the card must equal the message's own ideal width
        // plus the padding — the 520/760 constant belongs to the failure
        // card's Text (:593), never here.
        QPointer<QQuickItem> card =
            overlay->findChild<QQuickItem *>(QStringLiteral("playerStartupCard"));
        QPointer<QQuickItem> column =
            overlay->findChild<QQuickItem *>(QStringLiteral("playerStartupColumn"));
        QVERIFY2(!card.isNull(), "the startup overlay paints no preparation card");
        QVERIFY2(!column.isNull(), "the preparation card paints no column");
        QCOMPARE(card->property("width").toReal(),
                 column->property("width").toReal() + 2 * 22.0);
        QCOMPARE(card->property("height").toReal(),
                 column->property("height").toReal() + 2 * 16.0);
        // The falsifiable half: the card tracks the MESSAGE, not a fixed
        // width. Render a short and a long message through a probe of the
        // shipped component and require the long card to be clearly wider
        // (at least 64 logical pixels — far above font rounding) while each
        // card equals its message's unwrapped ideal width plus the released
        // 22-point padding.
        //
        // The probe's QML source is stated here: the width binding below is
        // the repaired hug binding (intrinsic ideal width clamped by the
        // frame). Against the pre-repair 520/760 width this fails as:
        //   FAIL!  : 'longCardWidth - shortCardWidth >= 64.0' returned FALSE.
        //   (the preparation card does not track its message:
        //    short card 564 (ideal 101.844), long card 564 (ideal 573.656))
        // because a fixed 520-wide column paints identical widths for both
        // messages while the ideals differ. The equality checks below fail
        // there too (564 != ideal + 44). If this binding ever regresses to
        // a constant, the same transcript returns.
        const auto preparationCardWidthFor = [&](const QString &message,
                                                qreal &cardWidth,
                                                qreal &idealWidth) -> bool {
            QQmlComponent probeComponent(&engine);
            probeComponent.setData(
                QByteArrayLiteral("import QtQuick\nimport Marquee 3.0\n"
                                  "TransitionLoading { width: 1600; height: 900; leanBack: false; "
                                  "message: \"\"; artwork: \"\" }\n"),
                QUrl(QStringLiteral("qrc:/playback-preparation-probe.qml")));
            if (probeComponent.isError()) {
                qWarning() << probeComponent.errorString();
                return false;
            }
            const std::unique_ptr<QObject> created(probeComponent.create());
            auto *probe = qobject_cast<QQuickItem *>(created.get());
            if (probe == nullptr) {
                return false;
            }
            probe->setParentItem(window->contentItem());
            probe->setProperty("message", message);
            if (probe->property("width").toReal() != 1600.0) {
                return false;
            }
            auto *probeCard =
                probe->findChild<QQuickItem *>(QStringLiteral("playerStartupCard"));
            auto *probeColumn =
                probe->findChild<QQuickItem *>(QStringLiteral("playerStartupColumn"));
            auto *probeCopy =
                probe->findChild<QQuickItem *>(QStringLiteral("playerStartupMessage"));
            if (probeCard == nullptr || probeColumn == nullptr || probeCopy == nullptr) {
                return false;
            }
            // The probe's own unwrapped measure, not the suite's: the
            // column binds to it, so it is the independent reading of the
            // ideal width the card must hug. Read off the live copy — the
            // probe's hidden measure exists so the column has a
            // wrap-independent, loop-free input to bind to, but both Texts
            // share the font and copy, so both report the same ideal.
            const qreal probeIdeal =
                probeCopy->property("implicitWidth").toReal();
            if (!(probeIdeal > 1.0)) {
                return false;
            }
            cardWidth = probeCard->property("width").toReal();
            idealWidth = probeIdeal;
            return true;
        };
        qreal shortCardWidth = 0.0;
        qreal shortIdealWidth = 0.0;
        QVERIFY2(preparationCardWidthFor(QStringLiteral("Opening video..."), shortCardWidth,
                                         shortIdealWidth),
                 "the preparation probe did not render its short message");
        qreal longCardWidth = 0.0;
        qreal longIdealWidth = 0.0;
        QVERIFY2(preparationCardWidthFor(
                     QStringLiteral("Opening video... this title needs a moment while the "
                                    "library prepares its artwork and chapters"),
                     longCardWidth, longIdealWidth),
                 "the preparation probe did not render its long message");
        QVERIFY2(longCardWidth - shortCardWidth >= 64.0,
                 qPrintable(QStringLiteral("the preparation card does not track its message: "
                                           "short card %1 (ideal %3), long card %2 (ideal %4)")
                                .arg(shortCardWidth)
                                .arg(longCardWidth)
                                .arg(shortIdealWidth)
                                .arg(longIdealWidth)));
        QVERIFY2(std::abs(shortCardWidth - (shortIdealWidth + 2 * 22.0)) < 2.0,
                 qPrintable(QStringLiteral("the short preparation card is %1, not its message "
                                           "ideal %2 plus the 22-point padding")
                                .arg(shortCardWidth)
                                .arg(shortIdealWidth)));
        QVERIFY2(std::abs(longCardWidth - (longIdealWidth + 2 * 22.0)) < 2.0,
                 qPrintable(QStringLiteral("the long preparation card is %1, not its message "
                                           "ideal %2 plus the 22-point padding")
                                .arg(longCardWidth)
                                .arg(longIdealWidth)));
        // Tolerance 1: the QML blends the alpha in float while fromRgbF
        // rounds in double-adjacent arithmetic; both name #b8000000.
        QVERIFY2(render_probe::withinTolerance(
                     card->property("color").value<QColor>(),
                     QColor::fromRgbF(0.0f, 0.0f, 0.0f, 0.72f), 1),
                 qPrintable(card->property("color").value<QColor>().name(QColor::HexArgb)));
        QCOMPARE(card->property("radius").toReal(), 8.0);
        QCOMPARE(card->property("strokeWidth").toInt(), 1);
        QVERIFY2(render_probe::withinTolerance(
                     card->property("strokeColor").value<QColor>(),
                     QColor::fromRgbF(1.0f, 1.0f, 1.0f, 0.12f), 1),
                 qPrintable(card->property("strokeColor").value<QColor>().name(QColor::HexArgb)));
        QCOMPARE(column->property("spacing").toReal(), 12.0);

        // The copy: 14 medium in white at 0.86.
        QPointer<QQuickItem> copy =
            overlay->findChild<QQuickItem *>(QStringLiteral("playerStartupMessage"));
        QVERIFY2(!copy.isNull(), "the preparation card paints no copy");
        // Tolerance 1: 0.86 names #dbffffff on both sides, but the float
        // blend lands on a rounding boundary QCOMPARE's exact equality
        // rejects.
        QVERIFY2(render_probe::withinTolerance(
                     copy->property("color").value<QColor>(),
                     QColor::fromRgbF(1.0f, 1.0f, 1.0f, 0.86f), 1),
                 qPrintable(copy->property("color").value<QColor>().name(QColor::HexArgb)));
        QCOMPARE(copy->property("font").value<QFont>().pixelSize(), 14);
        QCOMPARE(copy->property("font").value<QFont>().weight(), QFont::Medium);

        // The spinner: the released small white progress spinner
        // (PlayerView.swift:624-626, no scaleEffect) draws the released
        // 16-point spokes at full size, turning once a second, still
        // under Reduce Motion.
        QPointer<QQuickItem> spinner =
            overlay->findChild<QQuickItem *>(QStringLiteral("playerStartupSpinner"));
        QVERIFY2(!spinner.isNull(), "the preparation card paints no spinner");
        QCOMPARE(spinner->property("width").toReal(), 16.0);
        QCOMPARE(spinner->property("height").toReal(), 16.0);
        QPointer<QObject> spin =
            overlay->findChild<QObject *>(QStringLiteral("playerStartupSpinnerSpin"));
        QVERIFY2(!spin.isNull(), "the startup spinner never turns");
        QCOMPARE(spin->property("duration").toInt(), 1000);
        QCOMPARE(spin->property("loops").toInt(), -1);

        // Reduce Motion stills the spinner: judged on the run binding, not
        // by watching pixels stop.
        controller.settings()->setReduceMotion(true);
        QTRY_VERIFY2(!spin.isNull(), "the startup spinner left before Reduce Motion was judged");
        const auto spinStilled = [&] {
            return !spin.isNull() && !spin->property("running").toBool();
        };
        QTRY_VERIFY(spinStilled());
        controller.settings()->setReduceMotion(false);

        // Source-backed object contracts only; the loose-file state below
        // has no artwork. The decoded-artwork case separately checks that
        // the dim stays outside the blur source and above its output.
        // Neither case claims rendered blur or display acceptance.
        QPointer<QQuickItem> backdrop =
            overlay->findChild<QQuickItem *>(QStringLiteral("playerStartupBackdrop"));
        QPointer<QQuickItem> dim =
            overlay->findChild<QQuickItem *>(QStringLiteral("playerStartupBackdropDim"));
        QPointer<QQuickItem> treated =
            overlay->findChild<QQuickItem *>(QStringLiteral("playerStartupTreatedBackdrop"));
        QPointer<QQuickItem> blur =
            overlay->findChild<QQuickItem *>(QStringLiteral("playerStartupBackdropBlur"));
        QPointer<QQuickItem> shade =
            overlay->findChild<QQuickItem *>(QStringLiteral("playerStartupBackdropShade"));
        QVERIFY2(!backdrop.isNull(), "the startup overlay paints no backdrop");
        QVERIFY2(!dim.isNull(), "the startup overlay paints no black-at-0.62 dim");
        QVERIFY2(!treated.isNull(), "the startup overlay paints no treated backdrop");
        QVERIFY2(!blur.isNull(), "the startup overlay paints no backdrop blur");
        QVERIFY2(!shade.isNull(), "the startup overlay paints no backdrop shade");
        QCOMPARE(backdrop->property("overscan").toReal(), 1.04);
        QVERIFY2(backdrop->property("width").toReal()
                     >= overlay->property("width").toReal() * 1.03,
                 "the backdrop does not overscan the frame");
        QVERIFY2(render_probe::withinTolerance(
                     dim->property("color").value<QColor>(),
                     QColor::fromRgbF(0.0f, 0.0f, 0.0f, 0.62f), 1),
                 qPrintable(dim->property("color").value<QColor>().name(QColor::HexArgb)));
        // Pin the released stop values directly: ordering alone would let
        // any three alphas with a weaker middle pass. Judged on the shade
        // item's own child stop objects, not through pixels the hidden
        // loose-file composition never paints.
        const QList<QObject *> shadeStopObjects =
            shade->findChildren<QObject *>(QStringLiteral("playerStartupShadeStop"));
        QCOMPARE(shadeStopObjects.size(), 3);
        const auto shadeStopAlphaAt = [&shadeStopObjects](qreal position) -> qreal {
            for (QObject *stop : shadeStopObjects) {
                if (qFuzzyCompare(stop->property("position").toReal() + 1.0, position + 1.0)) {
                    return stop->property("color").value<QColor>().alphaF();
                }
            }
            return -1.0;
        };
        const qreal headAlpha = shadeStopAlphaAt(0.0);
        const qreal midAlpha = shadeStopAlphaAt(0.5);
        const qreal footAlpha = shadeStopAlphaAt(1.0);
        QVERIFY2(headAlpha >= 0.0 && midAlpha >= 0.0 && footAlpha >= 0.0,
                 "the backdrop shade stops are missing");
        QVERIFY2(std::abs(headAlpha - 0.78) < 0.005,
                 qPrintable(QStringLiteral("the backdrop shade head alpha is %1, not 0.78")
                                .arg(headAlpha)));
        QVERIFY2(std::abs(midAlpha - 0.48) < 0.005,
                 qPrintable(QStringLiteral("the backdrop shade middle alpha is %1, not 0.48")
                                .arg(midAlpha)));
        QVERIFY2(std::abs(footAlpha - 0.82) < 0.005,
                 qPrintable(QStringLiteral("the backdrop shade foot alpha is %1, not 0.82")
                                .arg(footAlpha)));
        QVERIFY(!blur->property("brightness").isValid()
                || qFuzzyCompare(blur->property("brightness").toReal() + 1.0, 1.0));
        // PlayerView.swift:655-667: the scaled image is blurred first; the
        // dim is a sibling above the effect, never a child of its source.
        QVERIFY2(blur->property("source").value<QQuickItem *>() == treated,
                 "the backdrop blur does not treat the overscanned artwork");
        QCOMPARE(blur->parentItem(), overlay.data());
        QCOMPARE(dim->parentItem(), overlay.data());
        QCOMPARE(shade->parentItem(), overlay.data());
        QVERIFY2(backdrop->parentItem() == treated,
                 "the overscanned image is not the image the blur treats");
        const QList<QQuickItem *> layers = overlay->childItems();
        const auto above = [&layers](QQuickItem *upper, QQuickItem *lower) {
            return upper->z() > lower->z()
                || (upper->z() == lower->z()
                    && layers.indexOf(upper) > layers.indexOf(lower));
        };
        QVERIFY2(above(dim, blur), "the dim must cover the already-blurred artwork");
        QVERIFY2(above(shade, dim), "the vertical shade must remain above the dim");
        // Centred 1.04x: the image bleeds half the 4% past each edge of the
        // treated frame, judged on the geometry of THAT image.
        QCOMPARE(backdrop->property("width").toReal(),
                 treated->property("width").toReal() * 1.04);
        QCOMPARE(backdrop->property("height").toReal(),
                 treated->property("height").toReal() * 1.04);
        QCOMPARE(backdrop->property("x").toReal(),
                 -(backdrop->property("width").toReal()
                   - treated->property("width").toReal()) / 2.0);
        QCOMPARE(backdrop->property("y").toReal(),
                 -(backdrop->property("height").toReal()
                   - treated->property("height").toReal()) / 2.0);
        QVERIFY(!backdrop->isVisible());
        QVERIFY(!treated->isVisible());
        QVERIFY(!blur->isVisible());
        QVERIFY(!shade->isVisible());

        // The overlay exits through the same terminal path the early-states
        // case pins: a failure leaves no startup copy and the card hides
        // with it. The injected failure applies the oracle's .fail
        // transition, never .ended, so the route stays up.
        QVERIFY2(!video.isNull(), "the video surface left before the terminal failure");
        QVERIFY(QMetaObject::invokeMethod(
            video.data(), "setError", Q_ARG(QString, QStringLiteral("boom"))));
        QVERIFY2(!screen.isNull(),
                 "the player screen tore down on the injected failure instead of "
                 "showing the failure card");
        QTRY_VERIFY(screenStartupCleared());
        QVERIFY2(!overlay.isNull(), "the startup overlay left before its exit was judged");
        const auto overlayHidden = [&] {
            return !overlay.isNull() && !overlay->property("visible").toBool();
        };
        QTRY_VERIFY(overlayHidden());
        QCOMPARE(controller.navigation()->route(), NavigationController::Route::Player);
    }

    // PlayerView.swift:108-124 draws no startup copy for the terminal
    // lifecycle states (.idle, .paused, .seeking, .ended, .failed,
    // .stopped): an early pause, seek, end, or stop leaves neither
    // "Opening video..." nor "Starting playback..." up, even though the
    // item's position-threshold latch has not cleared yet. The screen
    // models that contract on showingStartupOverlay/startupMessage, with
    // the pause yield scoped to the startup window: once the latch
    // clears, an established pause keeps whatever the latch decided.
    // Headless-safe: only object properties are judged, on the real
    // PlayerScreen with playback stubbed at the item's own slots.
    void startupCoverYieldsToEarlyTerminalPlayerStates()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        QTemporaryDir library;
        // The clip has to outlast the waits below: reaching its end
        // navigates out of the player and destroys the surface being
        // judged. Headless the clip never plays, so the length is free.
        QVERIFY(writeSplitFieldClip(
            library.filePath(QStringLiteral("Arrival.2016.mkv")), 300));

        ApplicationController controller;
        controller.setStartFullscreen(false);
        controller.playLocalFile(library.filePath(QStringLiteral("Arrival.2016.mkv")));
        QCOMPARE(controller.navigation()->route(), NavigationController::Route::Player);

        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY2(window != nullptr, "qml/Main.qml did not load from the module");
        // Judged with playback stubbed at the item's own slots: every
        // yield starts from the "still starting" anchor, which real
        // playback advances past on its own clock, so this runs headless
        // only.
        if (rendersWithOpenGl(window)) {
            QSKIP("Stubbed startup premises cannot run while libmpv really plays");
        }

        QPointer<QQuickItem> screen;
        QPointer<QQuickItem> video;
        QTRY_VERIFY2(
            (video = window->findChild<QQuickItem *>(
                 QStringLiteral("videoSurface")))
                != nullptr,
            "PlayerScreen did not create the video surface");
        screen = video->parentItem();
        QVERIFY2(!screen.isNull(), "the video surface has no screen");

        // Each terminal yield below is judged on the screen it belongs to:
        // the end/stop handlers navigate away and destroy the Player
        // screen, so raw item pointers dangle. The accessors track the
        // live video surface through QPointer and re-resolve the screen
        // from it, and every navigation-away step re-enters the player
        // with a fresh surface before the next yield is judged. (The
        // failure yield keeps the player up — the oracle's .fail never
        // dismisses — so it needs no re-entry.)
        QPointer<QQuickItem> videoPtr = video;
        const auto liveScreen = [&]() -> QQuickItem * {
            if (videoPtr.isNull()) {
                return nullptr;
            }
            return videoPtr->parentItem();
        };
        const auto showingStartup = [&] {
            const QQuickItem *live = liveScreen();
            return live != nullptr
                && live->property("showingStartupOverlay").toBool();
        };
        const auto startupCopy = [&] {
            const QQuickItem *live = liveScreen();
            return live == nullptr
                ? QString()
                : live->property("startupMessage").toString();
        };
        const auto startupFlag = [&](const char *name) {
            const QQuickItem *live = liveScreen();
            return live != nullptr && live->property(name).toBool();
        };
        const auto liveScreenHasFocus = [&] {
            const QQuickItem *live = liveScreen();
            return live != nullptr && live->hasActiveFocus();
        };

        // Still starting: the latch holds, nothing terminal is known, and
        // the copy is the pre-first-frame one. Non-vacuous anchor: the
        // terminal cases below each start from this visible state on the
        // same screen, so they fail if the yield below ever stops firing.
        QTRY_VERIFY(showingStartup());
        QCOMPARE(startupCopy(), QStringLiteral("Opening video..."));

        // An early pause yields the cover and its copy while the latch
        // still holds: the oracle's .paused branch draws nothing.
        QVERIFY2(!video.isNull(), "the video surface left before the pause yield");
        QVERIFY(QMetaObject::invokeMethod(video.data(), "setPausedValue", Q_ARG(bool, true)));
        QTRY_VERIFY(!showingStartup());
        QCOMPARE(startupCopy(), QString{});
        // Unpausing before anything established returns the cover: the
        // pause yield is startup-only, not a second latch.
        QVERIFY2(!video.isNull(), "the video surface left before the unpause yield");
        QVERIFY(QMetaObject::invokeMethod(video.data(), "setPausedValue", Q_ARG(bool, false)));
        QTRY_VERIFY(showingStartup());
        QCOMPARE(startupCopy(), QStringLiteral("Opening video..."));

        // A Left or Right tap while the file is still opening has nothing to
        // seek: the item drops it, so it is no in-flight seek and the cover
        // stays. The key is delivered through the window's focus chain the
        // way the passing failure-Close case delivers its keys (a direct
        // sendEvent at the screen object never enters Qt Quick key
        // delivery, so the handler would never run): the screen takes focus
        // first, because the shell otherwise owns Left at its content scope
        // (Main.qml) and the player handler would never fire. The seek that
        // is issued against a loaded file, and so does yield the cover, is
        // judged by aTapWhileTheFileIsLoadedMarksTheScreenAsSeeking.
        QVERIFY2(!screen.isNull(), "the player screen left before the seek yield");
        screen->forceActiveFocus();
        QTRY_VERIFY2(!screen.isNull(), "the player screen left before the seek yield");
        QTRY_VERIFY(liveScreenHasFocus());
        QTest::keyClick(window, Qt::Key_Left);
        QTest::qWait(200);
        QVERIFY(showingStartup());
        QCOMPARE(startupCopy(), QStringLiteral("Opening video..."));
        QVERIFY(!startupFlag("startupSeeking"));
        QVERIFY(!video.isNull() && !video->property("failed").toBool());

        // A reached end yields the cover while the latch still holds: the
        // oracle's .ended branch draws nothing. Driven through the real
        // onPlaybackEnded handler — with auto-play-next disabled so the
        // handoff cannot replace the screen under test — never by writing
        // the flag itself: removing the ended assignment in
        // PlayerScreen.qml fails here by leaving the cover up. A position
        // report first, the path a settled seek ends on, so the flag is
        // known clear.
        QVERIFY2(!video.isNull(), "the video surface left before the ended yield");
        QVERIFY(QMetaObject::invokeMethod(video.data(), "setPositionValue",
                                         Q_ARG(double, 0.1)));
        QVERIFY(!startupFlag("startupSeeking"));
        // The ended yield is judged from a clean session:
        // the same-URL re-announce re-opens the session at the new-load
        // boundary (the oracle's .prepare exit from .failed), clearing the
        // incidental error and re-arming the covered latch.
        QVERIFY2(!video.isNull(), "the video surface left before the ended yield");
        QVERIFY(video->setProperty(
            "source",
            QUrl::fromLocalFile(
                library.filePath(QStringLiteral("Arrival.2016.mkv")))));
        QTRY_VERIFY(showingStartup());
        QCOMPARE(startupCopy(), QStringLiteral("Opening video..."));
        controller.settings()->setAutoPlayNextEpisode(false);
        // The end handler sets the flag before it navigates away, and the
        // navigation destroys this screen — so the yield is captured
        // through the flag's own change signal (a post-navigation property
        // read can land on the outgoing screen's deferred deletion), while
        // the cover-down is judged before the signal, while the screen
        // still stands.
        QSignalSpy endedSpy2(screen.data(), SIGNAL(startupEndedChanged()));
        QVERIFY(endedSpy2.isValid());
        QTRY_VERIFY(showingStartup());
        QVERIFY2(!video.isNull(), "the video surface left before the ended yield");
        QVERIFY(QMetaObject::invokeMethod(video.data(), "playbackEnded"));
        QTRY_VERIFY(!showingStartup());
        QCOMPARE(startupCopy(), QString{});
        QTRY_VERIFY(!endedSpy2.isEmpty());
        QTRY_VERIFY(controller.navigation()->route()
                    != NavigationController::Route::Player);
        controller.playLocalFile(library.filePath(QStringLiteral("Arrival.2016.mkv")));
        QCOMPARE(controller.navigation()->route(), NavigationController::Route::Player);
        QTRY_VERIFY2(
            (video = window->findChild<QQuickItem *>(
                 QStringLiteral("videoSurface")))
                != nullptr,
            "PlayerScreen did not recreate the video surface");
        videoPtr = video;
        screen = video->parentItem();
        QVERIFY2(!screen.isNull(), "the video surface has no screen");
        // The re-entered screen starts covered; the video item behind it
        // is brand new, so settle one event-loop turn before judging —
        // otherwise the first poll can read the outgoing screen's state.
        QTest::qWait(100);
        video = window->findChild<QQuickItem *>(QStringLiteral("videoSurface"));
        QVERIFY2(!video.isNull(), "the player surface left with its screen");
        videoPtr = video;
        screen = video->parentItem();
        QVERIFY2(!screen.isNull(), "the video surface has no screen");
        QTRY_VERIFY(showingStartup());

        // A stop yields the cover while the latch still holds: the
        // oracle's .stopped branch draws nothing (and its guard at :112
        // already excluded it from any copy). Driven through the real
        // MediaStop key handler that sets the flag, never by writing the
        // flag itself: removing the stop assignment in PlayerScreen.qml
        // fails here by leaving the cover up — and the stop also leaves
        // the player, so this yield is the last one judged on this
        // screen. The shell's content scope owns key focus (Main.qml
        // answers Left there), so the key is delivered straight at the
        // player screen — the item that owns the handler — rather than
        // at the window, where the shell would consume it first.
        window->requestActivate();
        QVERIFY2(!screen.isNull(), "the player screen left before the stop yield");
        screen->forceActiveFocus();
        QTRY_VERIFY2(!screen.isNull(), "the player screen left before the stop yield");
        QTRY_VERIFY(liveScreenHasFocus());
        // The stop handler sets the flag before it navigates away and the
        // navigation destroys this screen synchronously inside the key
        // delivery, so the yield is captured through the flag's own change
        // signal — reading the property afterwards would touch a dangling
        // object. The cover-down is judged before the key, while the
        // screen still stands.
        QSignalSpy stoppedSpy(screen.data(), SIGNAL(startupStoppedChanged()));
        QVERIFY(stoppedSpy.isValid());
        // Cover is up right until the stop: the non-vacuous anchor for the
        // yield below (a pre-yielded cover would pass trivially).
        QTRY_VERIFY(showingStartup());
        QTest::keyClick(window, Qt::Key_MediaStop);
        QTRY_VERIFY(!stoppedSpy.isEmpty());
        QTRY_VERIFY(controller.navigation()->route()
                    != NavigationController::Route::Player);

        // A failure yields the cover through the same terminal path the
        // failure card already used: failed implies no startup copy. Back
        // on the player with a fresh surface, so the failure is injected
        // past the new load boundary the way a real load precedes a real
        // failure.
        controller.playLocalFile(library.filePath(QStringLiteral("Arrival.2016.mkv")));
        QCOMPARE(controller.navigation()->route(), NavigationController::Route::Player);
        QTRY_VERIFY2(
            (video = window->findChild<QQuickItem *>(
                 QStringLiteral("videoSurface")))
                != nullptr,
            "PlayerScreen did not recreate the video surface");
        videoPtr = video;
        screen = video->parentItem();
        QVERIFY2(!screen.isNull(), "the video surface has no screen");
        QTRY_VERIFY(showingStartup());
        // The injected failure applies the oracle's .fail transition, never
        // .ended, so the player stays up and the live accessors stay valid.
        QVERIFY2(!video.isNull(), "the video surface left before the failure yield");
        QVERIFY(QMetaObject::invokeMethod(
            video.data(), "setError", Q_ARG(QString, QStringLiteral("boom"))));
        QTRY_VERIFY(!showingStartup());
        QCOMPARE(startupCopy(), QString{});
        QCOMPARE(controller.navigation()->route(), NavigationController::Route::Player);
    }

    void hardwareDecodingPreferenceReachesTheVideoItem()
    {
        // `UserSettings.swift:34` survives on this stack as the libmpv hwdec
        // option: the item defaults to the released on-state and applies the
        // Settings row's value without disturbing playback state. The write
        // goes through libmpv's runtime property path (not the discarded
        // creation-time option call), so the toggle is read back from
        // libmpv itself: with the setter's libmpv call deleted this fails as
        //   FAIL!  : Compared values are not the same
        //      Actual   (video.hwdecForTest()): "auto-safe"
        //      Expected (QStringLiteral("no")): "no"
        // because libmpv still holds the construction value.
        MpvVideoItem video;
        QSignalSpy changedSpy(&video, &MpvVideoItem::hardwareDecodingEnabledChanged);

        QCOMPARE(video.hardwareDecodingEnabled(), true);

        video.setHardwareDecodingEnabled(false);
        QCOMPARE(video.hardwareDecodingEnabled(), false);
        QCOMPARE(changedSpy.count(), 1);
        QCOMPARE(video.errorMessage(), QString{});
        QCOMPARE(video.duration(), 0.0);
        QCOMPARE(video.hwdecForTest(), QStringLiteral("no"));

        video.setHardwareDecodingEnabled(false);
        QCOMPARE(changedSpy.count(), 1);

        video.setHardwareDecodingEnabled(true);
        QCOMPARE(video.hardwareDecodingEnabled(), true);
        QCOMPARE(changedSpy.count(), 2);
        QCOMPARE(video.hwdecForTest(), QStringLiteral("auto-safe"));
    }

    // The released app scales with bilinear filters
    // (`MPVPlayerService.swift:2407-2409`). libmpv's default lanczos pair
    // draws through offscreen passes that, under Mesa's software GL, leave
    // NaN rows in their texture and so a black picture for the life of the
    // render context (the `playbackSurvivesLosingAndRegainingItsRenderSurface`
    // flake), so the item must ask for the released app's filters. Read back
    // from libmpv itself: with the three option calls deleted this fails as
    //   FAIL!  : Compared values are not the same
    //      Actual   (video.scalerForTest(QStringLiteral("scale"))): "lanczos"
    //      Expected (QStringLiteral("bilinear"))                  : "bilinear"
    void videoItemScalesWithTheReleasedAppsBilinearFilters()
    {
        MpvVideoItem video;

        QCOMPARE(video.scalerForTest(QStringLiteral("scale")), QStringLiteral("bilinear"));
        QCOMPARE(video.scalerForTest(QStringLiteral("cscale")), QStringLiteral("bilinear"));
        QCOMPARE(video.scalerForTest(QStringLiteral("dscale")), QStringLiteral("bilinear"));
    }

    // A rejected hardware-decoding write is a preference refusal, not a
    // playback failure: it must neither latch the session failed (which
    // `PlayerScreen.qml:61` gates the full-screen failure card on) nor
    // leave the property reporting a value libmpv never accepted
    // (`UserSettings.swift:34` treats this as a user preference, not
    // lifecycle state). Uses the same seam the setter documents:
    // both `hwdec` values round-trip on every real handle, so a genuine
    // in-harness rejection is unreachable without it; the seam takes the
    // same negative-result path without touching the live handle.
    // Headless-safe: no render context ever stands here.
    // Non-vacuous: against the pre-repair setter (commit-then-write plus
    // `setError` on rejection) the session latches failed below.
    void rejectedHardwareDecodingWriteLeavesTheSessionAlive()
    {
        MpvVideoItem video;
        QSignalSpy changedSpy(&video, &MpvVideoItem::hardwareDecodingEnabledChanged);

        video.failNextHardwareDecodingWriteForTest();
        video.setHardwareDecodingEnabled(false);
        QVERIFY(!video.failed());
        QCOMPARE(video.errorMessage(), QString{});
        QCOMPARE(video.hardwareDecodingEnabled(), true);
        QCOMPARE(changedSpy.count(), 0);
        QCOMPARE(video.hwdecForTest(), QStringLiteral("auto-safe"));

        // The arm is one-shot: the next toggle takes the real write path
        // and commits again.
        video.setHardwareDecodingEnabled(false);
        QCOMPARE(video.hardwareDecodingEnabled(), false);
        QCOMPARE(changedSpy.count(), 1);
        QVERIFY(!video.failed());
        QCOMPARE(video.hwdecForTest(), QStringLiteral("no"));
    }

    void playLocalFileOpensThePlayerRouteWithAPreparedTitle()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const QString clip = runtimeRoot.filePath(QStringLiteral("Some Movie.y4m"));
        QVERIFY(writeSplitFieldClip(clip));

        ApplicationController controller;
        controller.playLocalFile(clip);

        QCOMPARE(controller.navigation()->route(), NavigationController::Route::Player);
        QCOMPARE(controller.player()->title(), QStringLiteral("Some Movie"));
        QCOMPARE(controller.player()->currentFileUrl(), QUrl::fromLocalFile(clip));
        QVERIFY(!controller.hasError());

        AppPaths::clearRuntimeRoot();
    }

    void playLocalFileSurfacesAnErrorForAMissingPath()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());

        ApplicationController controller;
        const NavigationController::Route startingRoute = controller.navigation()->route();

        controller.playLocalFile(runtimeRoot.filePath(QStringLiteral("gone.mkv")));

        QVERIFY(controller.hasError());
        QCOMPARE(controller.navigation()->route(), startingRoute);
        QVERIFY(controller.player()->currentFileUrl().isEmpty());

        AppPaths::clearRuntimeRoot();
    }

    void platformFallbackChainFollowsSessionDisplays_data()
    {
        QTest::addColumn<QString>("waylandDisplay");
        QTest::addColumn<QString>("x11Display");
        QTest::addColumn<QByteArray>("chain");

        QTest::newRow("absent")
            << QString{} << QString{} << QByteArray("offscreen");
        QTest::newRow("local x11")
            << QString{} << QStringLiteral(":0") << QByteArray("xcb;offscreen");
        QTest::newRow("protocol-qualified x11")
            << QString{} << QStringLiteral("localhost/unix:0") << QByteArray("xcb;offscreen");
        QTest::newRow("remote x11")
            << QString{} << QStringLiteral("theater.lan:0") << QByteArray("xcb;offscreen");
        QTest::newRow("stale x11 is left for xcb to reject")
            << QString{} << QStringLiteral(":99") << QByteArray("xcb;offscreen");
        QTest::newRow("wayland")
            << QStringLiteral("wayland-1") << QString{} << QByteArray("wayland;offscreen");
        QTest::newRow("stale wayland is left for the plugin to reject")
            << QStringLiteral("wayland-9") << QString{} << QByteArray("wayland;offscreen");
        QTest::newRow("wayland before x11")
            << QStringLiteral("wayland-1") << QStringLiteral(":0")
            << QByteArray("wayland;xcb;offscreen");
    }

    void platformFallbackChainFollowsSessionDisplays()
    {
        QFETCH(QString, waylandDisplay);
        QFETCH(QString, x11Display);
        QFETCH(QByteArray, chain);

        QCOMPARE(platformFallbackChain(waylandDisplay, x11Display), chain);
    }
};

int main(int argc, char *argv[])
{
    // Qt Quick runs on its software backend under the offscreen platform, where
    // a QQuickFramebufferObject never renders, so prefer the session's displays
    // and fall back to offscreen so a headless host skips instead of aborting.
    if (qEnvironmentVariableIsEmpty("QT_QPA_PLATFORM")) {
        qputenv("QT_QPA_PLATFORM",
                platformFallbackChain(qEnvironmentVariable("WAYLAND_DISPLAY"),
                                      qEnvironmentVariable("DISPLAY")));
    }

    // The libmpv surface only renders under the OpenGL scene graph, which the
    // application entry point selects the same way.
    QQuickWindow::setGraphicsApi(QSGRendererInterface::OpenGL);

    QGuiApplication app(argc, argv);
    // libmpv refuses to start under a locale whose decimal separator is not a
    // dot, exactly as the application entry point guards against.
    std::setlocale(LC_NUMERIC, "C");
    PlaybackTest test;
    return QTest::qExec(&test, argc, argv);
}

#include "tst_playback.moc"
