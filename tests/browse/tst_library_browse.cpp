#include <algorithm>
#include <cmath>
#include <functional>
#include <memory>
#include <numbers>

#include <QDir>
#include <QDateTime>
#include <QFile>
#include <QFileInfo>
#include <QColor>
#include <QFont>
#include <QGuiApplication>
#include <QImage>
#include <QLinearGradient>
#include <QPainter>
#include <QIODevice>
#include <QRectF>
#include <QQmlApplicationEngine>
#include <QQmlComponent>
#include <QQmlContext>
#include <QQmlProperty>
#include <QQuickItem>
#include <QQuickWindow>
#include <QScopeGuard>
#include <QSemaphore>
#include <QSet>
#include <QSignalSpy>
#include <QSqlError>
#include <QSqlQuery>
#include <QStringList>
#include <QTemporaryDir>
#include <QTest>
#include <QUrl>
#include <QVector>

#include "app/AppPaths.hpp"
#include "app/ApplicationController.hpp"
#include "catalog/CatalogDatabase.hpp"
#include "catalog/CatalogStore.hpp"
#include "catalog/LibraryRoot.hpp"
#include "catalog/LibraryScanner.hpp"
#include "catalog/MediaItem.hpp"
#include "models/HomeRowsModel.hpp"
#include "models/LibraryModel.hpp"
#include "navigation/FocusNavigator.hpp"
#include "navigation/NavigationController.hpp"
#include "profiles/ProfileStore.hpp"
#include "settings/SettingsStore.hpp"
#include "support/RenderProbe.hpp"

namespace
{
[[nodiscard]] bool writeFile(const QString &root, const QString &relativePath,
                            const QByteArray &contents)
{
    const QFileInfo target(QDir(root).filePath(relativePath));
    if (!QDir().mkpath(target.absolutePath())) {
        return false;
    }

    QFile file(target.absoluteFilePath());
    if (!file.open(QIODevice::WriteOnly)) {
        return false;
    }
    return file.write(contents) == contents.size();
}

[[nodiscard]] bool writeMediaFile(const QString &root, const QString &relativePath)
{
    return writeFile(root, relativePath, QByteArrayLiteral("media"));
}

// A poster of four flat blocks at the compact card's own size, so the
// backdrop under the focus ring changes along each side. The vertical split
// runs through the centre and crosses the top and bottom bands, where a
// slid centre lands pixels on the wrong side; the horizontal split sits
// twenty points from the top, 92 points from the centre, and crosses the
// left and right bands, where a mapping that ignores the focus scale moves
// pixels by four points at ratio 1 and eight at ratio 2, onto the wrong
// side. A split through the centre would move under scaling by nothing.
[[nodiscard]] bool writeQuadrantPosterFile(const QString &root, const QString &relativePath)
{
    const QFileInfo target(QDir(root).filePath(relativePath));
    if (!QDir().mkpath(target.absolutePath())) {
        return false;
    }

    QImage poster(150, 225, QImage::Format_ARGB32);
    QPainter painter(&poster);
    painter.fillRect(QRect(0, 0, 75, 20), QColor("#c80000"));
    painter.fillRect(QRect(75, 0, 75, 20), QColor("#00c800"));
    painter.fillRect(QRect(0, 20, 75, 205), QColor("#0000c8"));
    painter.fillRect(QRect(75, 20, 75, 205), QColor("#c8c800"));
    painter.end();
    return poster.save(target.absoluteFilePath(), "PNG");
}

// Bytes that no image reader accepts, so a card falls back for that reason.
[[nodiscard]] bool writeUndecodablePosterFile(const QString &root, const QString &relativePath)
{
    return writeFile(root, relativePath, QByteArrayLiteral("<html>not an image</html>"));
}

// A poster of one-point checks in four colours at the compact card's own
// size: drawn at the focus scale with smooth sampling, every pixel under the
// ring is a mixture of up to four texels, which no model of two colours at
// a time can predict.
[[nodiscard]] bool writeCheckerPosterFile(const QString &root, const QString &relativePath)
{
    const QFileInfo target(QDir(root).filePath(relativePath));
    if (!QDir().mkpath(target.absolutePath())) {
        return false;
    }

    QImage poster(150, 225, QImage::Format_ARGB32);
    const QColor colours[] = {QColor(Qt::black), QColor("#ff0000"), QColor("#00ff00"), QColor("#0000ff")};
    for (int y = 0; y < poster.height(); ++y) {
        for (int x = 0; x < poster.width(); ++x) {
            poster.setPixelColor(x, y, colours[(x % 2) + 2 * (y % 2)]);
        }
    }
    return poster.save(target.absoluteFilePath(), "PNG");
}

// A decodable image, so a card that still shows its fallback artwork does so
// for the reason the test is about.
[[nodiscard]] bool writePosterFile(const QString &root, const QString &relativePath,
                                  const QColor &fill = QColor(Qt::darkCyan))
{
    const QFileInfo target(QDir(root).filePath(relativePath));
    if (!QDir().mkpath(target.absolutePath())) {
        return false;
    }

    QImage poster(20, 30, QImage::Format_ARGB32);
    poster.fill(fill);
    return poster.save(target.absoluteFilePath(), "PNG");
}

using render_probe::countEdgePixels;
using render_probe::countPixels;
using render_probe::countPixelsOutside;
using render_probe::Capture;
using render_probe::captureWindowUntil;
using render_probe::ItemGeometry;
using render_probe::imageRectForItem;
using render_probe::pixels;

using render_probe::isAccentGlowPixel;

// Marquee/Theme/ViewModifiers/CardHoverModifier.swift:56-59 blooms the accent
// glow around the artwork at opacity 0.48; the ring itself is far stronger.
[[nodiscard]] bool isRingStrengthAccentPixel(const QColor &pixel)
{
    return pixel.red() > 100 && pixel.blue() > 140;
}

// The band eight points around the artwork, less below where the caption
// begins, in the capture's pixels.
[[nodiscard]] QRect aroundArtwork(const Capture &capture, const QRect &artworkRect)
{
    return artworkRect.adjusted(-pixels(capture, 8), -pixels(capture, 8),
                                pixels(capture, 8), pixels(capture, 4));
}

// The artwork's own rounded surface (#231d30) reads as violet under the glow
// rule, and its aligned rectangle can fall one capture pixel short of the
// painted surface, so that one pixel of alignment slop is not searched.
[[nodiscard]] QRect artworkWithAlignmentSlop(const QRect &artworkRect)
{
    return artworkRect.adjusted(-1, -1, 1, 1);
}

[[nodiscard]] int focusAccentPixelsOutsideArtwork(const Capture &capture,
                                                  const QRect &artworkRect)
{
    return countPixelsOutside(capture.image, aroundArtwork(capture, artworkRect),
                              artworkWithAlignmentSlop(artworkRect), isAccentGlowPixel);
}

[[nodiscard]] int ringStrengthAccentPixelsJustOutsideArtwork(const Capture &capture,
                                                             const QRect &artworkRect)
{
    const int margin = pixels(capture, 3);
    return countPixelsOutside(capture.image,
                              artworkRect.adjusted(-margin, -margin, margin, margin),
                              artworkRect, isRingStrengthAccentPixel);
}

[[nodiscard]] bool isScreenBlendedAccentPixel(const QColor &pixel)
{
    // The fixture artwork is #00c800. A screen-composited structural-focus
    // ring keeps that bright green channel; source-over purple does not.
    return pixel.red() >= 55 && pixel.green() >= 160 && pixel.blue() >= 90;
}

// The structural accent drawn source-over on #00c800 is (117, 99, 159):
// purple that has lost the green. Edge coverage between green and the
// screen result never drops the green channel that far.
[[nodiscard]] bool isSourceOverAccentOnGreen(const QColor &pixel)
{
    return pixel.red() > 100 && pixel.blue() > 140 && pixel.green() < 130;
}

// Marquee/Theme/ViewModifiers/CardHoverModifier.swift:64-66 pads the ring by
// its 2.25-point line width inside the unscaled frame and strokes another
// 2.25 points inward, so the ring occupies the band between 2.25 and 4.5
// points inside the frame the capture sampled, whatever the device pixel
// ratio; one point of margin on each side allows for edge coverage.
[[nodiscard]] int ringBandPixels(const Capture &capture, const QRect &frameRect,
                                 const std::function<bool(const QColor &)> &matches)
{
    const int outer = pixels(capture, 2.25 - 1.0);
    const int inner = pixels(capture, 4.5 + 1.0);
    return countPixelsOutside(capture.image,
                              frameRect.adjusted(outer, outer, -outer, -outer),
                              frameRect.adjusted(inner, inner, -inner, -inner),
                              matches);
}

[[nodiscard]] int screenBlendedRingPixels(const Capture &capture, const QRect &frameRect)
{
    return ringBandPixels(capture, frameRect, isScreenBlendedAccentPixel);
}

// Enough titles that the fixture window lays them out over more than one row
// whatever column count its width allows.
[[nodiscard]] QStringList sampleTitles()
{
    return {QStringLiteral("Arrival.2016.mkv"),  QStringLiteral("Coco.2017.mkv"),
            QStringLiteral("Dune.2021.mkv"),     QStringLiteral("Elemental.2023.mkv"),
            QStringLiteral("Flow.2024.mkv"),     QStringLiteral("Gravity.2013.mkv"),
            QStringLiteral("Heat.1995.mkv"),     QStringLiteral("Interstellar.2014.mkv"),
            QStringLiteral("Jaws.1975.mkv"),     QStringLiteral("Klaus.2019.mkv"),
            QStringLiteral("Moon.2009.mkv"),     QStringLiteral("Nope.2022.mkv"),
            QStringLiteral("Prey.2022.mkv"),     QStringLiteral("Rushmore.1998.mkv"),
            QStringLiteral("Sicario.2015.mkv"),  QStringLiteral("Tenet.2020.mkv")};
}
}

class LibraryBrowseTest final : public QObject
{
    Q_OBJECT

private:
    // Loads the shipped Marquee module linked into this binary so these tests
    // exercise the real Main.qml and its screens, not a replica.
    QQuickWindow *loadMainWindow(ApplicationController &controller,
                                 QQmlApplicationEngine &engine)
    {
        // A fullscreen window has no usable geometry on the test platform, and a
        // grid with no width lays out no cards at all.
        controller.setStartFullscreen(false);
        s_controller = &controller;

        engine.rootContext()->setContextProperty(
            QStringLiteral("appController"), &controller);
        engine.loadFromModule(QStringLiteral("Marquee"), QStringLiteral("Main"));
        if (engine.rootObjects().size() != 1) {
            return nullptr;
        }
        auto *window = qobject_cast<QQuickWindow *>(engine.rootObjects().front());
        if (window != nullptr) {
            window->resize(1600, 900);
            window->requestActivate();
        }
        return window;
    }

    // Home draws titled rows (HomeDetailView.swift:612-648). These tests judge
    // the poster cards on Home, so they address the "All Movies" row, whose
    // cards are the library's titles in browse order and, with the sixteen
    // sample titles, are cut to the eight Home draws.
    static inline ApplicationController *s_controller = nullptr;

    [[nodiscard]] static QQuickItem *homeRowItem(QQuickWindow *window, const QString &rowId)
    {
        QQuickItem *repeater = window->findChild<QQuickItem *>(QStringLiteral("homeRows"));
        if (repeater == nullptr) {
            return nullptr;
        }
        const int count = repeater->property("count").toInt();
        for (int index = 0; index < count; ++index) {
            QQuickItem *row = nullptr;
            if (QMetaObject::invokeMethod(repeater, "itemAt", Q_RETURN_ARG(QQuickItem *, row),
                                          Q_ARG(int, index))
                && row != nullptr
                && row->objectName() == QStringLiteral("homeRow_") + rowId) {
                return row;
            }
        }
        return nullptr;
    }

    // The card list of the All Movies row, or nothing while Home has no movie.
    [[nodiscard]] static QQuickItem *grid(QQuickWindow *window)
    {
        QQuickItem *row = homeRowItem(window, QStringLiteral("all-movies"));
        return row == nullptr ? nullptr
                              : row->findChild<QQuickItem *>(QStringLiteral("movieRow"));
    }

    // The surface the rows live in, which is what is shown or hidden as a whole.
    [[nodiscard]] static QQuickItem *rowsViewport(QQuickWindow *window)
    {
        return window->findChild<QQuickItem *>(QStringLiteral("homeRowsViewport"));
    }

    // The one vertical scroll authority of Home.
    [[nodiscard]] static QQuickItem *scrollOf(QQuickWindow *window)
    {
        return window->findChild<QQuickItem *>(QStringLiteral("homeScroll"));
    }

    [[nodiscard]] static int allMoviesRowIndex()
    {
        HomeRowsModel *rows = s_controller->homeRows();
        for (int row = 0; row < rows->rowCount(); ++row) {
            if (rows->data(rows->index(row), HomeRowsModel::RowIdRole).toString()
                == QStringLiteral("all-movies")) {
                return row;
            }
        }
        return -1;
    }

    // The remote's column in the All Movies row, or -1 when it is elsewhere.
    [[nodiscard]] static int currentIndexOf(QQuickItem *)
    {
        FocusNavigator *focus = s_controller->homeRows()->focus();
        return focus->row() == allMoviesRowIndex() ? focus->column() : -1;
    }

    static void setCurrentIndex(QQuickItem *, int column)
    {
        s_controller->homeRows()->focus()->setPosition(allMoviesRowIndex(), column);
    }

    [[nodiscard]] static bool contentHasFocus(QQuickWindow *window)
    {
        auto *content = window->findChild<QQuickItem *>(QStringLiteral("contentFocus"));
        return content != nullptr && content->hasActiveFocus();
    }

    // The row component a card list belongs to: list -> viewport -> row.
    [[nodiscard]] static QQuickItem *rowOf(QQuickItem *view)
    {
        return view->parentItem()->parentItem();
    }

    // How many whole cards the row's viewport holds at its current width.
    [[nodiscard]] static int columnsOf(QQuickItem *view)
    {
        QVariant whole;
        QMetaObject::invokeMethod(rowOf(view), "visibleSlotCount", Q_RETURN_ARG(QVariant, whole));
        return whole.toInt();
    }

    // One card's pitch and its reserved height, as the row lays them out.
    [[nodiscard]] static int cellWidthOf(QQuickItem *view)
    {
        return qRound(rowOf(view)->property("cardStride").toReal());
    }

    [[nodiscard]] static int cellHeightOf(QQuickItem *view)
    {
        return qRound(rowOf(view)->property("cardHeight").toReal());
    }

    // Puts the remote on the first card of the All Movies row and waits for
    // Home to scroll that row into view and stop. Home is a stack of rows, and
    // the cards these tests judge are in the last of them, which the page
    // brings to the fold only when the remote is there.
    static void revealRow(QQuickWindow *window, QQuickItem *view)
    {
        setCurrentIndex(view, 0);
        QQuickItem *row = rowOf(view);
        QQuickItem *scroll = scrollOf(window);
        QVERIFY(row != nullptr && scroll != nullptr);
        auto *spring = scroll->findChild<QObject *>(QStringLiteral("homeScrollSpring"));
        // The page has come to rest with the row's cards, not its whole halo
        // strip, inside the window: the released placement puts a row at 0.36
        // of the viewport, so the bottom of a tall row may pass the edge.
        const auto settled = [&] {
            QQuickItem *first = nullptr;
            QMetaObject::invokeMethod(view, "itemAtIndex", Q_RETURN_ARG(QQuickItem *, first),
                                      Q_ARG(int, 0));
            QQuickItem *art = first == nullptr ? nullptr : artOf(first);
            if (art == nullptr) {
                return false;
            }
            const qreal top = row->mapToItem(window->contentItem(), QPointF(0, 0)).y();
            const qreal artBottom =
                art->mapToItem(window->contentItem(), QPointF(0, art->height())).y();
            // Clear of the sticky title bar above and of the bottom fade below,
            // which is where the released placement leaves a row the remote is on.
            // The sticky bar collapses past 60 points of scroll over its own
            // 350 ms spring; a grab taken while it moves is not a state.
            QQuickItem *bar = window->findChild<QQuickItem *>(QStringLiteral("homeTitleBar"));
            const bool lean = bar->parentItem()->property("leanBack").toBool();
            const bool compact = bar->parentItem()->property("compactHeader").toBool();
            const qreal barHeight = bar->property("barHeight").toReal();
            const int wanted = compact ? (lean ? 62 : 44) : (lean ? 108 : 78);
            const int wantedPadding = compact ? (lean ? 8 : 4) : (lean ? 12 : 8);
            const qreal padding = bar->property("topPadding").toReal();
            return !(spring != nullptr && spring->property("running").toBool()) && top >= 200
                && artBottom <= window->height() - 90 && qAbs(barHeight - wanted) < 0.001
                && qAbs(padding - wantedPadding) < 0.001;
        };
        QTRY_VERIFY2(settled(),
                     qPrintable(QStringLiteral("rowTop %1 contentY %2 contentHeight %3 height %4 "
                                               "spring %5 art %6")
                                    .arg(row->mapToItem(window->contentItem(), QPointF(0, 0)).y())
                                    .arg(scroll->property("contentY").toReal())
                                    .arg(scroll->property("contentHeight").toReal())
                                    .arg(scroll->height())
                                    .arg(spring != nullptr && spring->property("running").toBool())
                                    .arg(cardAt(view, 0) != nullptr)));
    }

    // The shell starts with the sidebar focused, and its first Right is that
    // hand-off; the remote then rests on the first card of the All Movies row,
    // which is scrolled into view.
    static void focusFirstCard(QQuickWindow *window, QQuickItem *view)
    {
        QTest::keyClick(window, Qt::Key_Right);
        QTRY_VERIFY(contentHasFocus(window));
        revealRow(window, view);
    }


    [[nodiscard]] static QString idAt(const LibraryModel *model, int row)
    {
        return model->data(model->index(row, 0), LibraryModel::IdRole).toString();
    }

    [[nodiscard]] static int rowForTitle(const LibraryModel *model,
                                         const QString &title)
    {
        for (int row = 0; row < model->rowCount(); ++row) {
            if (model->data(model->index(row, 0), LibraryModel::TitleRole)
                    .toString()
                == title) {
                return row;
            }
        }
        return -1;
    }

    // Delegates hang off the view rather than the window's object tree, and
    // the view answers model changes once per frame, so it is asked to catch
    // up before it is asked for a delegate.
    [[nodiscard]] static QQuickItem *cardAt(QQuickItem *view, int index)
    {
        QQuickItem *card = nullptr;
        if (!QMetaObject::invokeMethod(view, "forceLayout")) {
            return nullptr;
        }
        if (!QMetaObject::invokeMethod(view, "itemAtIndex",
                                       Q_RETURN_ARG(QQuickItem *, card),
                                       Q_ARG(int, index))) {
            return nullptr;
        }
        return card;
    }

    [[nodiscard]] static QQuickItem *artOf(QQuickItem *card)
    {
        return card == nullptr
            ? nullptr
            : card->findChild<QQuickItem *>(QStringLiteral("posterArt"));
    }

    // A browse grid whose last column has as little slack past its cell as
    // the platform allows. The caller owns the controller and engine so the
    // scene outlives this setup.
    struct BoundaryScene
    {
        QQuickWindow *window = nullptr;
        QQuickItem *view = nullptr;
        QQuickItem *viewport = nullptr;
        QQuickItem *sidebar = nullptr;
        // HomeDetailView.swift:245-246 draws the sticky title bar and the
        // bottom fade over the scrolled surface, so both are part of what a
        // boundary comparison must account for.
        QQuickItem *titleBar = nullptr;
        QQuickItem *bottomFade = nullptr;
        int columns = 0;
        int cellWidth = 0;
        int gap = 0;
        int halo = 0;
        bool unsupported = false;
    };

    // The layout a before/after comparison of this scene depends on. Two
    // captures are only comparable when this held for both. Delegates keep
    // their layout slot in both states; only the poster frame inside scales.
    struct SceneGeometry
    {
        QSize logicalSize;
        qreal devicePixelRatio = 1.0;
        QRectF viewRect;
        QRectF viewportRect;
        QRectF firstCardRect;
        QRectF targetCardRect;
        int columns = 0;

        bool operator==(const SceneGeometry &) const = default;
    };

    [[nodiscard]] static SceneGeometry sceneGeometry(const BoundaryScene &scene, QQuickItem *target)
    {
        SceneGeometry geometry;
        geometry.logicalSize = scene.window->size();
        geometry.devicePixelRatio = scene.window->devicePixelRatio();
        QQuickItem *content = scene.window->contentItem();
        geometry.viewRect = scene.view->mapRectToItem(content, scene.view->boundingRect());
        geometry.viewportRect =
            scene.viewport->mapRectToItem(content, scene.viewport->boundingRect());
        if (QQuickItem *first = cardAt(scene.view, 0)) {
            geometry.firstCardRect = first->mapRectToItem(content, first->boundingRect());
        }
        if (target != nullptr) {
            geometry.targetCardRect = target->mapRectToItem(content, target->boundingRect());
        }
        geometry.columns = columnsOf(scene.view);
        return geometry;
    }

    [[nodiscard]] static QQuickItem *frameOf(QQuickItem *card)
    {
        return card == nullptr
            ? nullptr
            : card->findChild<QQuickItem *>(QStringLiteral("posterFrame"));
    }

    [[nodiscard]] static QQuickItem *chromeOf(QQuickItem *card)
    {
        return card == nullptr
            ? nullptr
            : card->findChild<QQuickItem *>(QStringLiteral("posterFocusFrame"));
    }

    [[nodiscard]] static QQuickItem *haloOf(QQuickItem *card)
    {
        return card == nullptr
            ? nullptr
            : card->findChild<QQuickItem *>(QStringLiteral("focusHalo"));
    }

    [[nodiscard]] static QQuickItem *ringOf(QQuickItem *card)
    {
        return card == nullptr
            ? nullptr
            : card->findChild<QQuickItem *>(QStringLiteral("focusRing"));
    }

    [[nodiscard]] static QQuickItem *fallbackOf(QQuickItem *card)
    {
        return card == nullptr
            ? nullptr
            : card->findChild<QQuickItem *>(QStringLiteral("posterFallback"));
    }

    // PosterCard.qml names the layers inside its poster but not the poster
    // itself; the artwork item's visual parent is that surface.
    [[nodiscard]] static QQuickItem *posterSurfaceOf(QQuickItem *card)
    {
        QQuickItem *art = artOf(card);
        return art == nullptr ? nullptr : art->parentItem();
    }

    // Everything a boundary comparison measures, sampled with each grab.
    [[nodiscard]] static QList<QQuickItem *> measuredItems(const BoundaryScene &scene,
                                                           QQuickItem *card)
    {
        return {scene.sidebar, scene.view, scene.viewport, scene.titleBar,
                scene.bottomFade, card, artOf(card), frameOf(card),
                chromeOf(card), ringOf(card)};
    }

    // Every poster the grid has realised, in index order. A whole-window
    // comparison is a comparison of all of them, so a readiness check that
    // speaks only for the card taking focus leaves the rest of the grid free
    // to paint between the two grabs.
    [[nodiscard]] static QList<QQuickItem *> realisedArtwork(QQuickItem *view)
    {
        // Every row of Home paints its posters asynchronously and the page
        // shows the ones above and below the row under test through the bar's
        // fade and the bottom fade, so readiness speaks for all of them, with
        // the row under test first in its own index order.
        QList<QQuickItem *> arts;
        QQuickItem *repeater = view->window()->findChild<QQuickItem *>(QStringLiteral("homeRows"));
        const int rows = repeater == nullptr ? 0 : repeater->property("count").toInt();
        const auto collect = [&arts](QQuickItem *list) {
            const int count = list->property("count").toInt();
            for (int index = 0; index < count; ++index) {
                if (QQuickItem *art = artOf(cardAt(list, index))) {
                    arts.append(art);
                }
            }
        };
        collect(view);
        for (int index = 0; index < rows; ++index) {
            QQuickItem *row = nullptr;
            if (!QMetaObject::invokeMethod(repeater, "itemAt", Q_RETURN_ARG(QQuickItem *, row),
                                           Q_ARG(int, index))
                || row == nullptr) {
                continue;
            }
            QQuickItem *list = row->findChild<QQuickItem *>(QStringLiteral("movieRow"));
            if (list != nullptr && list != view) {
                collect(list);
            }
        }
        return arts;
    }

    // The widest per-channel difference along any judged row of a poster.
    // PosterArt.qml:146-160 runs the fallback gradient from the surface layer
    // through the accent to the elevated surface, top-leading to
    // bottom-trailing, so every row of a painted poster is a ramp across its
    // width, while PosterArt.qml:110's bare plate is one colour the whole way.
    // Rows are taken from the poster's upper half, above the centred fallback
    // symbol and clear of the caption below it, at three depths so a poster
    // whose top is off screen can still be judged; a row is judged only where
    // at least three of its samples landed in the image. Anything drawn over
    // the poster down the page -- the bottom fade, the focus wash, the hover
    // wash -- covers a single row evenly and can shrink a ramp but never turn
    // a flat row into one. A poster with no judgeable row reports -1 rather
    // than a spread.
    [[nodiscard]] static int paintedRowSpread(const Capture &capture, QQuickItem *art)
    {
        const QRectF scene = capture.geometryOf(art).sceneRect;
        const QRect visible = imageRect(capture, scene);
        if (scene.isEmpty() || visible.isEmpty()) {
            return -1;
        }
        const qreal dpr = capture.devicePixelRatio;
        const QRect full(qRound(scene.x() * dpr), qRound(scene.y() * dpr),
                         qRound(scene.width() * dpr), qRound(scene.height() * dpr));
        int widest = -1;
        for (const qreal depth : {0.125, 0.25, 0.375}) {
            const int y = full.top() + qRound(full.height() * depth);
            if (y < visible.top() || y > visible.bottom()) {
                continue;
            }
            int lowest[3] = {255, 255, 255};
            int highest[3] = {0, 0, 0};
            int sampled = 0;
            for (const qreal across : {0.02, 0.26, 0.5, 0.74, 0.98}) {
                const int x = full.left() + qRound(full.width() * across);
                if (x < visible.left() || x > visible.right()) {
                    continue;
                }
                const QColor pixel = capture.image.pixelColor(x, y);
                const int channels[3] = {pixel.red(), pixel.green(), pixel.blue()};
                for (int channel = 0; channel < 3; ++channel) {
                    lowest[channel] = std::min(lowest[channel], channels[channel]);
                    highest[channel] = std::max(highest[channel], channels[channel]);
                }
                ++sampled;
            }
            if (sampled < 3) {
                continue;
            }
            for (int channel = 0; channel < 3; ++channel) {
                widest = std::max(widest, highest[channel] - lowest[channel]);
            }
        }
        return widest;
    }

    // The narrowest ramp the fallback gradient leaves on a judged row, well
    // clear of a flat plate's nothing. Measured across both card sizes, both
    // device pixel ratios, and the focused wash and the bottom fade lying over
    // it, the ramp does not fall below this; a bare plate spreads by 0.
    static constexpr int minimumPaintedRowSpread = 4;

    // A grab stands for a state of the whole grid only when every poster the
    // grid has realised has painted its own artwork into it. Qt's Canvas
    // paints asynchronously, so a delegate realised for this frame shows the
    // bare plate for one or more frames before its fallback gradient lands;
    // a check that samples one pixel of one card cannot see that, and the
    // grab it accepts is a mixture of two states. Every realised poster must
    // be measured in the capture and hold real geometry, at least one must be
    // on screen to be judged, and no judged one may still be flat, so neither
    // an empty capture nor a coherent grab that sampled nothing can satisfy
    // this.
    [[nodiscard]] static bool gridArtworkPainted(const Capture &capture,
                                                 const QList<QQuickItem *> &arts)
    {
        if (!capture.coherent() || arts.isEmpty()) {
            return false;
        }
        int judged = 0;
        for (QQuickItem *art : arts) {
            if (art == nullptr || !capture.items.contains(art)
                || capture.geometryOf(art).sceneRect.isEmpty()) {
                return false;
            }
            const int spread = paintedRowSpread(capture, art);
            if (spread < 0) {
                continue;
            }
            if (spread < minimumPaintedRowSpread) {
                return false;
            }
            ++judged;
        }
        return judged > 0;
    }

    // Marquee/Theme/ViewModifiers/CardHoverModifier.swift:50 draws a focused
    // poster at 1.045 and Marquee/Theme/MarqueeTheme.swift:252 gets it there
    // over a quarter-second spring, while the chrome paints for the new state
    // at once. A grabbed frame stands for a state only when the frame in it
    // is at that state's final scale and the chrome in it is that state's.
    [[nodiscard]] static bool cardSettled(const Capture &capture, QQuickItem *card, bool focused)
    {
        const render_probe::ItemGeometry frame = capture.geometryOf(frameOf(card));
        QQuickItem *chrome = chromeOf(card);
        return chrome != nullptr && chrome->property("active").toBool() == focused
            && !frame.sceneRect.isEmpty()
            && qFuzzyCompare(frame.scale, focused ? 1.045 : 1.0);
    }

    // Home's All Movies row with the sidebar, title bar and bottom fade it is
    // drawn under. The row is cut to eight cards and holds focus on its first,
    // so the cards a boundary comparison reaches stand still when focus moves:
    // `columns` is how many cards from the start the tests use (the focused one
    // and the neighbour beside it), all of them inside the row's viewport at
    // either card size.
    void prepareBoundaryScene(bool leanBack, ApplicationController &controller,
                              QQmlApplicationEngine &engine, BoundaryScene &scene)
    {
        controller.settings()->setLeanBackMode(leanBack);
        QTRY_COMPARE(controller.library()->rowCount(), 16);

        scene.window = loadMainWindow(controller, engine);
        QVERIFY2(scene.window != nullptr, "qml/Main.qml did not load from the module");
        controller.navigation()->goHome();
        QVERIFY(QTest::qWaitForWindowExposed(scene.window));

        QTRY_VERIFY((scene.view = grid(scene.window)) != nullptr);
        QTRY_COMPARE(scene.view->property("count").toInt(), 8);
        revealRow(scene.window, scene.view);
        scene.viewport = scene.view->parentItem();
        scene.sidebar = scene.window->findChild<QQuickItem *>(QStringLiteral("sidebar"));
        scene.titleBar = scene.window->findChild<QQuickItem *>(QStringLiteral("homeTitleBar"));
        scene.bottomFade =
            scene.window->findChild<QQuickItem *>(QStringLiteral("homeBottomFade"));
        QVERIFY(scene.viewport != nullptr);
        QVERIFY(scene.sidebar != nullptr);
        QVERIFY(scene.titleBar != nullptr);
        QVERIFY(scene.bottomFade != nullptr);

        scene.cellWidth = cellWidthOf(scene.view);
        QCOMPARE(scene.cellWidth, leanBack ? 241 : 160);
        scene.gap = leanBack ? 16 : 10;
        scene.halo = leanBack ? 52 : 36;
        scene.columns = 2;
        QVERIFY2(columnsOf(scene.view) >= 3,
                 "the fixture window must hold three cards of the row");

        auto *first = cardAt(scene.view, 0);
        auto *last = cardAt(scene.view, scene.columns - 1);
        auto *next = cardAt(scene.view, scene.columns);
        QVERIFY(first != nullptr);
        QVERIFY(last != nullptr);
        QVERIFY(next != nullptr);
        QCOMPARE(last->y(), first->y());
        QCOMPARE(next->y(), first->y());
        // These titles have no sidecar, so their cards show the fallback
        // artwork rather than an image.
        QVERIFY(fallbackOf(first) != nullptr && fallbackOf(first)->isVisible());
        QVERIFY(fallbackOf(last) != nullptr && fallbackOf(last)->isVisible());
    }

    struct CapturePair
    {
        Capture idle;
        Capture focused;
        SceneGeometry geometry;
        int attempts = 0;
    };

    // Takes the idle grab, applies `focus`, and takes the focused grab, each
    // only once the target card has settled in that state, its chrome has
    // painted for it, and every poster the grid has realised has painted its
    // own artwork, then retakes the whole pair when the scene's layout or the
    // buffers' extent changed anywhere in between: a platform re-configuring
    // the window between the two grabs otherwise produces a comparison of two
    // layouts, and a delegate whose Canvas has not yet painted otherwise
    // produces a comparison of two paint states.
    void captureIdleAndFocused(BoundaryScene &scene,
                               const std::function<QQuickItem *()> &target,
                               const std::function<void()> &focus,
                               const render_probe::CapturePredicate &idlePainted,
                               const render_probe::CapturePredicate &focusedPainted,
                               CapturePair &pair)
    {
        for (int attempt = 1; attempt <= 4; ++attempt) {
            pair.attempts = attempt;
            QQuickItem *card = target();
            QQuickItem *halo = haloOf(card);
            QQuickItem *chrome = chromeOf(card);
            QVERIFY(card != nullptr);
            QVERIFY(halo != nullptr);
            QVERIFY(chrome != nullptr);
            // The whole grid is measured with each grab, so a comparison of
            // two captures is a comparison of the same painted grid rather
            // than of one card in two states and its neighbours in whichever
            // state each happened to reach.
            const QList<QQuickItem *> arts = realisedArtwork(scene.view);
            QVERIFY2(!arts.isEmpty(), "the fixture grid realised no poster artwork");
            QList<QQuickItem *> items = measuredItems(scene, card);
            for (QQuickItem *art : arts) {
                if (!items.contains(art)) {
                    items.append(art);
                }
            }
            const auto gridPainted = [&](const Capture &capture) {
                return gridArtworkPainted(capture, arts);
            };

            // Back to idle. A chrome that was focused repaints for its idle
            // state before the idle frame is grabbed.
            const bool wasFocused = chrome->property("active").toBool();
            QSignalSpy idlePaints(halo, SIGNAL(painted()));
            scene.sidebar->forceActiveFocus();
            QTRY_VERIFY(!contentHasFocus(scene.window));
            if (wasFocused) {
                QTRY_VERIFY(idlePaints.count() > 0);
            }
            const SceneGeometry before = sceneGeometry(scene, card);
            const auto moved = [&] { return sceneGeometry(scene, target()) != before; };

            pair.idle = captureWindowUntil(scene.window, items, [&](const Capture &capture) {
                return moved()
                    || (cardSettled(capture, card, false) && gridPainted(capture)
                        && idlePainted(capture));
            });
            if (moved() || !pair.idle.coherent() || !cardSettled(pair.idle, card, false)
                || !gridPainted(pair.idle) || !idlePainted(pair.idle)) {
                continue;
            }

            QSignalSpy focusPaints(halo, SIGNAL(painted()));
            focus();
            if (QTest::currentTestFailed()) {
                return;
            }
            if (target() != card) {
                continue;
            }
            QTRY_VERIFY(focusPaints.count() > 0 || moved());
            pair.focused = captureWindowUntil(scene.window, items, [&](const Capture &capture) {
                return moved()
                    || (cardSettled(capture, card, true) && gridPainted(capture)
                        && focusedPainted(capture));
            });
            if (moved() || !pair.focused.coherent() || !cardSettled(pair.focused, card, true)
                || !gridPainted(pair.focused) || !focusedPainted(pair.focused)
                || !pair.idle.sameGeometryAs(pair.focused)) {
                continue;
            }
            pair.geometry = before;
            return;
        }
        QFAIL("the scene's layout kept changing between the idle and focused grabs");
    }

    // A capture of the scene with the target card in the given state, its
    // frame and chrome sampled with the grab, for tests that need one state
    // rather than a pair.
    [[nodiscard]] Capture captureSettled(QQuickWindow *window, QQuickItem *card, bool focused,
                                         const render_probe::CapturePredicate &painted)
    {
        const QList<QQuickItem *> items{card, artOf(card), frameOf(card), chromeOf(card), ringOf(card)};
        return captureWindowUntil(window, items, [&](const Capture &capture) {
            return cardSettled(capture, card, focused) && painted(capture);
        });
    }

    // A strip `from`..`to` logical points beside the captured artwork.
    [[nodiscard]] static QRect stripBeside(const Capture &capture, const QRect &art,
                                           qreal from, qreal to, bool leftSide)
    {
        const int fromPx = pixels(capture, from);
        const int toPx = pixels(capture, to);
        return leftSide
            ? QRect(art.left() - toPx, art.top(), toPx - fromPx, art.height())
            : QRect(art.right() + 1 + fromPx, art.top(), toPx - fromPx, art.height());
    }

    // The halo above a card is never at a horizontal boundary, so it is the
    // sign that the focus chrome has been painted at all.
    [[nodiscard]] static bool glowPaintedAbove(const Capture &capture, QQuickItem *art)
    {
        const QRect artRect = imageRectForItem(capture, art);
        return !artRect.isEmpty()
            && countPixels(capture.image,
                           QRect(artRect.left(), artRect.top() - pixels(capture, 12),
                                 artRect.width(), pixels(capture, 10)),
                           isAccentGlowPixel) > 0;
    }

    // The animation the poster frame's scale Behavior runs, so a test can hold
    // the frame part way through the spring on purpose. A Behavior creates
    // its animation on its first write, so the named spring exists only once
    // the frame has been asked to scale.
    [[nodiscard]] static QObject *scaleAnimationOf(QQuickItem *card)
    {
        QQuickItem *frame = frameOf(card);
        return frame == nullptr
            ? nullptr
            : frame->findChild<QObject *>(QStringLiteral("posterScaleSpring"));
    }

    // A capture counts as the selected card refused in an unsettled state
    // only when it is a real, measured frame of that card on its way to
    // focus: coherent, with the frame sampled, the chrome already active,
    // the frame at or above idle and below the focused scale, and not
    // accepted as focused. An empty or unmeasured capture reads a default
    // scale, and a card at rest is idle; neither is a refusal.
    [[nodiscard]] static bool refusedAsUnsettled(const Capture &capture, QQuickItem *card)
    {
        QQuickItem *frame = frameOf(card);
        QQuickItem *chrome = chromeOf(card);
        if (frame == nullptr || chrome == nullptr || !capture.coherent()
            || !capture.items.contains(frame) || !chrome->property("active").toBool()) {
            return false;
        }
        const qreal scale = capture.geometryOf(frame).scale;
        return scale >= 1.0 && scale < 1.045 && !cardSettled(capture, card, true);
    }

    // Marquee/Theme/ViewModifiers/CardHoverModifier.swift:61-69 draws the
    // ring, 2.25 points wide, screen blended at 0.95, over whatever the
    // scaled poster shows beneath it, which MovieCard.swift:226-227 has
    // already washed with black at 0.28. Every fully covered ring pixel is
    // judged against the screen blend of the idle backdrop found under it.
    [[nodiscard]] static render_probe::StrokeBlendModel ringBlendModel(const Capture &focused,
                                                                        QQuickItem *card)
    {
        render_probe::StrokeBlendModel model;
        model.colour = QColor("#7b5ea7");
        model.opacity = 0.95;
        model.washOpacity = 0.28;
        const QRectF artRect = focused.geometryOf(artOf(card)).sceneRect;
        model.centre = artRect.center() * focused.devicePixelRatio;
        model.scale = focused.geometryOf(frameOf(card)).scale;
        return model;
    }

    [[nodiscard]] static QList<QPoint> ringPixels(const Capture &focused, QQuickItem *card)
    {
        return render_probe::fullyCoveredStrokePixels(
            focused, focused.geometryOf(ringOf(card)).sceneRect, 2.25, 8.0);
    }

    // The ring band, every fully covered pixel on the straight runs and on
    // the four corner arcs, must be the screen blend of what the product
    // itself renders beneath it. That backdrop is not modelled: the same
    // settled focused scene is captured again with the ring alone hidden,
    // which leaves the scaled artwork, its smooth sampling, the fallback
    // layers, the wash, and the halo exactly as rendered. The reference is
    // validated before it is trusted: hiding the ring changes nothing outside
    // the band, and on flat backdrop it agrees with the idle capture mapped
    // through the focus scale. Then every covered pixel must be that
    // backdrop screen-blended and none may be its source-over, and the audit
    // is checked against an independent painter oracle: all wrong, one
    // straight pixel wrong, one corner pixel wrong, one transition pixel
    // wrong where the backdrop varies, the classifier told the wrong rule,
    // and a reference whose correspondence is shifted.
    void verifyRingBlendedOverRenderedBackdrop(QQuickWindow *window, const Capture &focused,
                                               const Capture &idle, QQuickItem *card,
                                               bool backdropVariesUnderBand,
                                               bool backdropHasFlatRuns = true)
    {
        QVERIFY(focused.coherent());
        QVERIFY(idle.coherent());
        QVERIFY(idle.sameGeometryAs(focused));
        QQuickItem *ring = ringOf(card);
        QVERIFY(ring != nullptr);
        QVERIFY(focused.items.contains(ring));
        const QColor ringColour("#7b5ea7");
        const qreal ringOpacity = 0.95;
        const QRectF ringRect = focused.geometryOf(ring).sceneRect;
        const QList<QPoint> covered = ringPixels(focused, card);
        const QList<QPoint> corners = render_probe::cornerPixelsOf(focused, covered, ringRect, 8.0);
        QVERIFY2(covered.size() >= 4 * 100,
                 qPrintable(QStringLiteral("only %1 fully covered ring pixels").arg(covered.size())));
        QVERIFY2(corners.size() >= 4,
                 qPrintable(QStringLiteral("only %1 fully covered corner pixels").arg(corners.size())));

        // The same frame with the ring hidden. Nothing else may move: the
        // scene stays focused and settled, and the items sit where they did.
        ring->setVisible(false);
        const auto restoreRing = qScopeGuard([ring] { ring->setVisible(true); });
        const Capture hidden = captureWindowUntil(
            window, {card, artOf(card), frameOf(card), chromeOf(card), ring}, [&](const Capture &capture) {
                // Settled, unmoved, and the ring really gone: a covered pixel
                // no longer shows what the focused frame showed there.
                return cardSettled(capture, card, true) && !ring->isVisible()
                    && capture.geometryOf(artOf(card)) == focused.geometryOf(artOf(card))
                    && capture.geometryOf(ring) == focused.geometryOf(ring)
                    && !render_probe::withinTolerance(capture.image.pixelColor(covered.first()),
                                                      focused.image.pixelColor(covered.first()), 6);
            });
        ring->setVisible(true);
        QVERIFY(hidden.coherent());
        QVERIFY(hidden.sameGeometryAs(focused));
        QCOMPARE(hidden.geometryOf(artOf(card)).sceneRect, focused.geometryOf(artOf(card)).sceneRect);
        QCOMPARE(hidden.geometryOf(ring).sceneRect, ringRect);

        // Validation one: outside the band, the hidden frame is the focused
        // frame. The band, corner arcs included, is skipped one point wider
        // than the stroke on each side.
        const qreal dpr = focused.devicePixelRatio;
        const QRectF ringPhysical(ringRect.x() * dpr, ringRect.y() * dpr, ringRect.width() * dpr,
                                  ringRect.height() * dpr);
        const QRect ringPx = render_probe::imageRect(focused, ringRect);
        const qreal bandOuter = dpr;
        const qreal bandInner = -(2.25 * dpr + dpr);
        int differingOutsideBand = 0;
        QStringList differingDescribed;
        const QRect around = ringPx.adjusted(-pixels(focused, 6), -pixels(focused, 6), pixels(focused, 6), pixels(focused, 6))
                                 .intersected(focused.image.rect());
        for (int y = around.top(); y <= around.bottom(); ++y) {
            for (int x = around.left(); x <= around.right(); ++x) {
                const QPoint pixel(x, y);
                const qreal distance = render_probe::roundedRectSignedDistance(
                    QPointF(x + 0.5, y + 0.5), ringPhysical, 8.0 * dpr);
                const bool inBand = distance >= bandInner - 1.0 && distance <= bandOuter + 1.0;
                if (!inBand
                    && !render_probe::withinTolerance(focused.image.pixelColor(pixel), hidden.image.pixelColor(pixel), 6)) {
                    ++differingOutsideBand;
                    if (differingDescribed.size() < 12) {
                        differingDescribed << QStringLiteral("(%1,%2) %3/%4").arg(x).arg(y)
                                                  .arg(focused.image.pixelColor(pixel).name())
                                                  .arg(hidden.image.pixelColor(pixel).name());
                    }
                }
            }
        }
        QVERIFY2(differingOutsideBand == 0,
                 qPrintable(QStringLiteral("%1 pixels outside the band changed when the ring was hidden "
                                           "(ring %2): %3")
                                .arg(differingOutsideBand).arg(QTest::toString(ringPx))
                                .arg(differingDescribed.join(QLatin1Char(' ')))));

        // Validation two: on flat backdrop the hidden frame agrees with the
        // idle capture mapped through the focus scale and washed.
        const render_probe::StrokeBlendModel model = ringBlendModel(focused, card);
        int flatCompared = 0;
        int flatDisagreements = 0;
        for (const QPoint &pixel : covered) {
            if (render_probe::backdropIsFlatAt(idle, model, pixel, 6)) {
                ++flatCompared;
                if (!render_probe::withinTolerance(hidden.image.pixelColor(pixel),
                                                   render_probe::backdropAt(idle, model, pixel), 6)) {
                    ++flatDisagreements;
                }
            }
        }
        // A fixture whose every texel differs from its neighbours has no flat
        // run for this model to speak about; the other validations still hold.
        QCOMPARE(flatCompared > 0, backdropHasFlatRuns);
        QCOMPARE(flatDisagreements, 0);

        // The audit itself, corners included.
        const render_probe::StrokeReferenceAudit painted = render_probe::auditStrokeAgainstReference(
            focused.image, hidden.image, covered, ringColour, ringOpacity);
        QCOMPARE(painted.covered, int(covered.size()));
        QVERIFY2(painted.mismatches == 0,
                 qPrintable(QStringLiteral("%1 of %2 ring pixels are not the screen blend of the rendered "
                                           "backdrop at ratio %3; first %4")
                                .arg(painted.mismatches).arg(painted.covered)
                                .arg(focused.devicePixelRatio).arg(painted.firstMismatch)));
        QCOMPARE(painted.sourceOverMatches, 0);
        QVERIFY2(painted.distinguishable >= painted.covered / 2,
                 qPrintable(QStringLiteral("only %1 of %2 ring pixels can tell screen from source-over")
                                .arg(painted.distinguishable).arg(painted.covered)));
        const QList<QPoint> &distinguishable = painted.distinguishablePixels;

        // Independent oracle: the painter's source-over ring on the hidden
        // frame, wrong on every distinguishable pixel; then one straight
        // pixel, one corner pixel, and where the backdrop varies one
        // transition pixel, each mixed alone into the real band and each
        // flagged as exactly one.
        const QImage wrong = render_probe::paintedSourceOverStroke(
            hidden.image, ringRect, 2.25, 8.0, focused.devicePixelRatio, ringColour, ringOpacity);
        // The controls are judged over the distinguishable pixels, where a
        // wrong blend has a colour of its own.
        const render_probe::StrokeReferenceAudit allWrong = render_probe::auditStrokeAgainstReference(
            wrong, hidden.image, distinguishable, ringColour, ringOpacity);
        QCOMPARE(allWrong.mismatches, int(distinguishable.size()));
        QCOMPARE(allWrong.sourceOverMatches, int(distinguishable.size()));
        const auto exactlyOneWrong = [&](const QPoint &pixel, const char *what) {
            const render_probe::StrokeReferenceAudit oneWrong = render_probe::auditStrokeAgainstReference(
                render_probe::withOnePixelFrom(focused.image, wrong, pixel), hidden.image, distinguishable,
                ringColour, ringOpacity);
            QVERIFY2(oneWrong.mismatches == 1 && oneWrong.sourceOverMatches == 1,
                     qPrintable(QStringLiteral("%1 pixel %2 corrupted: %3 mismatches, %4 source-over")
                                    .arg(QString::fromLatin1(what)).arg(QTest::toString(pixel))
                                    .arg(oneWrong.mismatches).arg(oneWrong.sourceOverMatches)));
        };
        QList<QPoint> straight;
        QList<QPoint> cornerCandidates;
        for (const QPoint &pixel : distinguishable) {
            if (corners.contains(pixel)) {
                cornerCandidates.append(pixel);
            } else {
                straight.append(pixel);
            }
        }
        QVERIFY(!straight.isEmpty());
        QVERIFY2(!cornerCandidates.isEmpty(), "no corner pixel can tell screen from source-over");
        exactlyOneWrong(straight.at(straight.size() / 2), "straight");
        if (QTest::currentTestFailed()) {
            return;
        }
        exactlyOneWrong(cornerCandidates.first(), "corner");
        if (QTest::currentTestFailed()) {
            return;
        }
        if (backdropVariesUnderBand) {
            QList<QPoint> transitions;
            for (const QPoint &pixel : distinguishable) {
                if (!render_probe::backdropIsFlatAt(idle, model, pixel, 6)) {
                    transitions.append(pixel);
                }
            }
            QVERIFY2(!transitions.isEmpty(), "the fixture put no transition under the band");
            exactlyOneWrong(transitions.first(), "transition");
            if (QTest::currentTestFailed()) {
                return;
            }
            // A reference whose correspondence to the frame is shifted by
            // three points reads the wrong backdrop across the transitions.
            const render_probe::StrokeReferenceAudit shifted = render_probe::auditStrokeAgainstReference(
                focused.image, render_probe::shiftedBy(hidden.image, QPoint(pixels(focused, 3), 0)),
                distinguishable, ringColour, ringOpacity);
            QVERIFY(shifted.mismatches > 0);
        }
        // Corrupted composition: told to expect source-over, the audit rejects
        // every real pixel.
        const render_probe::StrokeReferenceAudit wrongRule = render_probe::auditStrokeAgainstReference(
            focused.image, hidden.image, distinguishable, ringColour, ringOpacity, 6,
            render_probe::BlendRule::SourceOver);
        QCOMPARE(wrongRule.mismatches, int(distinguishable.size()));
    }

    [[nodiscard]] static bool artworkPainted(const Capture &capture, QQuickItem *art)
    {
        const QRect artRect = imageRectForItem(capture, art);
        return !artRect.isEmpty()
            && capture.image.pixelColor(artRect.center()) != QColor("#0d0b1a");
    }

    // What a bottom fade is drawn over, captured from the same settled scene
    // with the band alone hidden. Nothing else may move: the band is the only
    // difference between the two frames, so the grid beneath it must already
    // have painted here too, exactly as it had when the faded frame was
    // grabbed. `ready` carries that requirement from the caller, which knows
    // which posters the scene realised.
    [[nodiscard]] Capture captureWithoutFade(QQuickWindow *window, QQuickItem *fade,
                                             const QList<QQuickItem *> &items,
                                             const Capture &faded,
                                             const render_probe::CapturePredicate &ready)
    {
        fade->setVisible(false);
        const Capture unfaded = captureWindowUntil(
            window, items, [&](const Capture &capture) {
                return capture.sameGeometryAs(faded) && !fade->isVisible()
                    && capture.geometryOf(fade) == faded.geometryOf(fade) && ready(capture);
            });
        fade->setVisible(true);
        return unfaded;
    }

    // Whether the surface really paints something under the band, judged from
    // the frame with the band hidden rather than from the faded pixels. The
    // threshold is the audit's own tolerance, so a band whose content the
    // audit can still distinguish is never classified as clear page.
    [[nodiscard]] static int contentPixelsUnderBand(const Capture &unfaded, const QRect &band)
    {
        return countPixels(unfaded.image, band, [](const QColor &pixel) {
            return render_probe::departureFrom(pixel, QColor("#0d0b1a"))
                > render_probe::fadeBandTolerance;
        });
    }

    // BottomFadeView.swift:14-24 runs the page background from transparent at
    // the top of the band to opaque at its bottom, so every pixel of the band
    // is that mixture of what the surface paints beneath it and the
    // background. `unfaded` is the same settled frame with the band alone
    // hidden, so what lies beneath it is the product's own rendering rather
    // than a model of it. The reference is validated first -- hiding the band
    // changes nothing above it -- and then the whole band is judged pixel by
    // pixel at the capture's own ratio. `expectContent` states which of the
    // two real states this band is in, so an empty band cannot stand in for a
    // populated one: where content lies under the band, the audit's own
    // controls must also reject an opaque cover at the head and an undrawn
    // band at the foot.
    void verifyBottomFadeMixesTheSurfaceIntoTheBackground(const Capture &faded,
                                                          const Capture &unfaded,
                                                          QQuickItem *fade, bool expectContent)
    {
        QVERIFY(faded.coherent());
        QVERIFY(unfaded.coherent());
        QVERIFY(unfaded.sameGeometryAs(faded));
        QVERIFY(fade != nullptr);
        const QRect band = imageRectForItem(faded, fade);
        QVERIFY(!band.isEmpty());
        QCOMPARE(band.bottom(), faded.image.height() - 1);
        // The released 80-point band, in this capture's pixels. A scene
        // rectangle can start on a fractional row, so its aligned extent may
        // carry one pixel of rounding.
        QVERIFY2(qAbs(band.height() - pixels(faded, 80)) <= 1,
                 qPrintable(QStringLiteral("the fade band is %1 px tall, not the released 80 "
                                           "points at ratio %2")
                                .arg(band.height()).arg(faded.devicePixelRatio)));

        // Validation: the band is the only thing that changed. Everything
        // above it is identical in both frames, so the reference really is
        // what this band is drawn over.
        const QRect above(0, 0, faded.image.width(), band.top());
        QCOMPARE(render_probe::changedPixels(faded, unfaded, above), 0);

        const QColor background("#0d0b1a");
        const render_probe::FadeBandAudit audit =
            render_probe::auditBottomFadeBand(faded.image, unfaded.image, band, background);
        QCOMPARE(audit.judged, band.width() * band.height());
        QVERIFY2(audit.mismatches == 0,
                 qPrintable(QStringLiteral("%1 of %2 band pixels are not the band's own mixture "
                                           "of the surface and the page background at ratio %3; "
                                           "first %4")
                                .arg(audit.mismatches).arg(audit.judged)
                                .arg(faded.devicePixelRatio).arg(audit.firstMismatch)));

        if (!expectContent) {
            // Clear page under the band: over the background every rule agrees,
            // so this case says only what it can -- that nothing is painted
            // there and the band invents nothing.
            QCOMPARE(contentPixelsUnderBand(unfaded, band), 0);
            QCOMPARE(countPixels(faded.image, band,
                                 [&background](const QColor &pixel) {
                                     return render_probe::departureFrom(pixel, background) > 8;
                                 }),
                     0);
            return;
        }

        // Content under the band, proven from the frame without it, and enough
        // of it at both ends for the controls below to mean something.
        QVERIFY2(audit.strongInHead > 0,
                 "the fixture painted nothing under the head of the fade");
        QVERIFY2(audit.strongInFoot > 0,
                 "the fixture painted nothing under the foot of the fade");
        // An opaque band would show the page background at its head instead of
        // what is drawn beneath it.
        QVERIFY2(audit.opaqueMatches == 0,
                 qPrintable(QStringLiteral("%1 of %2 pixels under the band's head are the page "
                                           "background rather than the surface beneath them")
                                .arg(audit.opaqueMatches).arg(audit.strongInHead)));
        // A band that was never drawn would leave its foot showing that
        // surface instead of the page background.
        QVERIFY2(audit.unfadedMatches == 0,
                 qPrintable(QStringLiteral("%1 of %2 pixels under the band's foot are the "
                                           "unfaded surface rather than the page background")
                                .arg(audit.unfadedMatches).arg(audit.strongInFoot)));
    }

private slots:
    void gridShowsOneCardPerProjectedTitle()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        QTemporaryDir library;
        for (const QString &name : sampleTitles()) {
            QVERIFY(writeMediaFile(library.path(), name));
        }

        ApplicationController controller;
        controller.setTemporaryLibraryRoot(library.path());
        QTRY_COMPARE(controller.library()->rowCount(), 16);

        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY2(window != nullptr, "qml/Main.qml did not load from the module");
        controller.navigation()->goHome();

        QQuickItem *view = nullptr;
        QTRY_VERIFY((view = grid(window)) != nullptr);
        QTRY_COMPARE(view->property("count").toInt(), 8);
        revealRow(window, view);
        QVERIFY(view->isVisible());

        auto *empty = window->findChild<QQuickItem *>(QStringLiteral("libraryEmptyState"));
        QVERIFY(empty != nullptr);
        QVERIFY(!empty->isVisible());

        // Delegates hang off the view rather than the window's object tree.
        auto *card = cardAt(view, 0);
        QVERIFY(card != nullptr);

        // A title without a sidecar draws no artwork; the fallback artwork
        // beneath must be there, or every card renders an empty rectangle.
        auto *art = card->findChild<QQuickItem *>(QStringLiteral("posterArt"));
        QVERIFY(art != nullptr);
        QCOMPARE(art->property("source").toUrl(), QUrl());
        QVERIFY(fallbackOf(card) != nullptr);
        QVERIFY(fallbackOf(card)->isVisible());
    }

    void posterCardsMatchReleasedGeometryTypographyAndFocusTreatment()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        QTemporaryDir library;
        QVERIFY(writeMediaFile(library.path(), QStringLiteral("Arrival.2016.mkv")));
        QVERIFY(writeMediaFile(library.path(), QStringLiteral("Coco.2017.mkv")));

        ApplicationController controller;
        controller.settings()->setLeanBackMode(false);
        controller.setTemporaryLibraryRoot(library.path());
        QTRY_COMPARE(controller.library()->rowCount(), 2);

        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY2(window != nullptr, "qml/Main.qml did not load from the module");
        controller.navigation()->goHome();

        QQuickItem *view = nullptr;
        QTRY_VERIFY((view = grid(window)) != nullptr);
        QTRY_COMPARE(view->property("count").toInt(), 2);
        revealRow(window, view);
        focusFirstCard(window, view);

        auto *card = cardAt(view, 0);
        QVERIFY(card != nullptr);
        auto *posterFrame = card->findChild<QQuickItem *>(QStringLiteral("posterFrame"));
        auto *art = artOf(card);
        auto *title = card->findChild<QQuickItem *>(QStringLiteral("posterTitle"));
        auto *metadata =
            card->findChild<QQuickItem *>(QStringLiteral("posterMetadata"));
        auto *caption =
            card->findChild<QQuickItem *>(QStringLiteral("posterCaption"));
        auto *focusFrame =
            card->findChild<QQuickItem *>(QStringLiteral("posterFocusFrame"));
        auto *ring =
            focusFrame == nullptr
                ? nullptr
                : focusFrame->findChild<QQuickItem *>(QStringLiteral("focusRing"));
        auto *halo =
            focusFrame == nullptr
                ? nullptr
                : focusFrame->findChild<QQuickItem *>(QStringLiteral("focusHalo"));
        QVERIFY(posterFrame != nullptr);
        QVERIFY(art != nullptr);
        QVERIFY(title != nullptr);
        QVERIFY(metadata != nullptr);
        QVERIFY(caption != nullptr);
        QVERIFY(focusFrame != nullptr);
        QVERIFY(ring != nullptr);
        QVERIFY(halo != nullptr);

        // Marquee/Features/Home/Views/HomeDetailView.swift:1263-1268 supplies
        // 150/225-point artwork, and Marquee/Theme/MarqueeTheme.swift:226-232
        // supplies the 10/16-point pitch gap plus vertical halo room. The
        // ArrowedScrollRow oracle cancels horizontal halo padding at :87.
        QCOMPARE(cellWidthOf(view), 160);
        QCOMPARE(cellHeightOf(view), 373);
        QCOMPARE(qRound(posterFrame->width()), 150);
        QCOMPARE(qRound(art->width()), 150);
        QCOMPARE(qRound(art->height()), 225);
        auto *nextCard = cardAt(view, 1);
        QVERIFY(nextCard != nullptr);
        QCOMPARE(qRound(nextCard->x() - card->x()), 160);

        const QFont titleFont = title->property("font").value<QFont>();
        QCOMPARE(titleFont.pixelSize(), 13);
        QCOMPARE(titleFont.weight(), QFont::Medium);
        QCOMPARE(title->property("color").value<QColor>(), QColor("#f5f0eb"));
        QCOMPARE(title->property("horizontalAlignment").toInt(),
                 int(Qt::AlignLeft));
        QCOMPARE(title->property("lineHeight").toReal(), 16.0);

        const QFont metadataFont = metadata->property("font").value<QFont>();
        QCOMPARE(metadataFont.pixelSize(), 11);
        QCOMPARE(metadata->property("color").value<QColor>(), QColor("#6b6178"));
        QCOMPARE(metadata->property("horizontalAlignment").toInt(),
                 int(Qt::AlignLeft));
        QCOMPARE(metadata->property("lineHeight").toReal(), 13.0);
        QCOMPARE(metadata->property("maximumLineCount").toInt(), 1);
        QCOMPARE(metadata->property("text").toString(), QStringLiteral("2016"));
        QCOMPARE(caption->height(), 62.0);

        // Marquee/Theme/ViewModifiers/CardHoverModifier.swift:48-60 applies
        // the shadows after the scaled content, and
        // Marquee/SharedViews/MovieCard.swift:160-171 applies focusChrome
        // after the clip, so the halo extends beyond the artwork. The ring
        // overlay at :61-69 is padded by its own line width inside the
        // unscaled frame and strokes inward from there, so it stays inside
        // the artwork that scales beneath it.
        QVERIFY(std::abs(focusFrame->scale() - 1.0) < 0.001);
        QCOMPARE(focusFrame->mapRectToItem(card, focusFrame->boundingRect()),
                 QRectF(posterFrame->x(), posterFrame->y(),
                        posterFrame->width(), posterFrame->height()));
        QCOMPARE(ring->x(), 2.25);
        QCOMPARE(ring->y(), 2.25);
        QCOMPARE(ring->width(), focusFrame->width() - 4.5);
        QCOMPARE(ring->height(), focusFrame->height() - 4.5);
        QCOMPARE(ring->property("lineWidth").toReal(), 2.25);
        QCOMPARE(ring->property("cornerRadius").toReal(), 8.0);
        const QRectF ringBounds =
            ring->mapRectToItem(art, ring->boundingRect());
        const QRectF haloBounds =
            halo->mapRectToItem(art, halo->boundingRect());
        QVERIFY(ringBounds.left() > 0.0);
        QVERIFY(ringBounds.top() > 0.0);
        QVERIFY(ringBounds.right() < art->width());
        QVERIFY(ringBounds.bottom() < art->height());
        QVERIFY(haloBounds.left() < 0.0);
        QVERIFY(haloBounds.top() < 0.0);
        QVERIFY(haloBounds.right() > art->width());
        QVERIFY(haloBounds.bottom() > art->height());

        const QRectF haloInDelegate =
            halo->mapRectToItem(card, halo->boundingRect());
        QVERIFY(haloInDelegate.left() < 0.0);
        QVERIFY(haloInDelegate.top() >= 0.0);
        QVERIFY(haloInDelegate.right() > card->width());
        QVERIFY(haloInDelegate.bottom() <= card->height());
        QCOMPARE(focusFrame->property("haloPadding").toReal(), 36.0);
        // Marquee/Theme/ViewModifiers/CardHoverModifier.swift:64-67 specifies
        // the 2.25-point ring, 0.95 opacity, and screen blend behavior.
        QCOMPARE(focusFrame->property("ringOpacity").toReal(), 0.95);
        QVERIFY(ring->isVisible());
        QVERIFY(ring->opacity() > 0.0);
        QVERIFY(halo->isVisible());
        QVERIFY(halo->opacity() > 0.0);

        QTRY_VERIFY(std::abs(posterFrame->scale() - 1.045) < 0.001);
        QCOMPARE(focusFrame->property("ringWidth").toReal(), 2.25);
        QCOMPARE(posterFrame->z(), 1.0);
        QCOMPARE(focusFrame->property("focusedShadowRadius").toReal(), 26.0);
        QCOMPARE(focusFrame->property("focusedShadowOffsetY").toReal(), 14.0);
        QCOMPARE(focusFrame->property("focusedShadowOpacity").toReal(), 0.68);
        QCOMPARE(focusFrame->property("focusedGlowRadius").toReal(), 28.0);
        QCOMPARE(focusFrame->property("focusedGlowOpacity").toReal(), 0.48);
        QCOMPARE(focusFrame->property("focusScale").toReal(), 1.045);
        // Marquee/Theme/ViewModifiers/CardHoverModifier.swift:51-55 keeps a
        // resting shadow under an idle card.
        QCOMPARE(focusFrame->property("idleShadowRadius").toReal(), 4.0);
        QCOMPARE(focusFrame->property("idleShadowOffsetY").toReal(), 2.0);
        QCOMPARE(focusFrame->property("idleShadowOpacity").toReal(), 0.22);

        controller.settings()->setLeanBackMode(true);
        // The same sources yield a 225 + 16 = 241 horizontal pitch and
        // 448 + (2 * 52) = 552 vertical cell extent.
        QTRY_COMPARE(cellWidthOf(view), 241);
        QTRY_COMPARE(cellHeightOf(view), 552);

        card = cardAt(view, 0);
        QVERIFY(card != nullptr);
        posterFrame = card->findChild<QQuickItem *>(QStringLiteral("posterFrame"));
        art = artOf(card);
        title = card->findChild<QQuickItem *>(QStringLiteral("posterTitle"));
        metadata =
            card->findChild<QQuickItem *>(QStringLiteral("posterMetadata"));
        caption =
            card->findChild<QQuickItem *>(QStringLiteral("posterCaption"));
        focusFrame = card->findChild<QQuickItem *>(QStringLiteral("posterFocusFrame"));
        ring =
            focusFrame == nullptr
                ? nullptr
                : focusFrame->findChild<QQuickItem *>(QStringLiteral("focusRing"));
        halo =
            focusFrame == nullptr
                ? nullptr
                : focusFrame->findChild<QQuickItem *>(QStringLiteral("focusHalo"));
        QVERIFY(posterFrame != nullptr);
        QVERIFY(art != nullptr);
        QVERIFY(title != nullptr);
        QVERIFY(metadata != nullptr);
        QVERIFY(caption != nullptr);
        QVERIFY(focusFrame != nullptr);
        QVERIFY(ring != nullptr);
        QVERIFY(halo != nullptr);

        QCOMPARE(qRound(posterFrame->width()), 225);
        QCOMPARE(qRound(art->width()), 225);
        QCOMPARE(qRound(art->height()), 338);
        nextCard = cardAt(view, 1);
        QVERIFY(nextCard != nullptr);
        QTRY_COMPARE(qRound(nextCard->x() - card->x()), 241);

        const QFont leanBackTitleFont = title->property("font").value<QFont>();
        QCOMPARE(leanBackTitleFont.pixelSize(), 18);
        QCOMPARE(leanBackTitleFont.weight(), QFont::Medium);

        const QFont leanBackMetadataFont = metadata->property("font").value<QFont>();
        QCOMPARE(leanBackMetadataFont.pixelSize(), 15);
        QCOMPARE(metadata->property("color").value<QColor>(), QColor("#6b6178"));
        QCOMPARE(metadata->property("horizontalAlignment").toInt(),
                 int(Qt::AlignLeft));
        QCOMPARE(metadata->property("lineHeight").toReal(), 18.0);
        QCOMPARE(metadata->property("maximumLineCount").toInt(), 1);
        QCOMPARE(caption->height(), 88.0);

        QTRY_VERIFY(std::abs(posterFrame->scale() - 1.045) < 0.001);
        QCOMPARE(focusFrame->property("ringWidth").toReal(), 2.25);
        const QRectF leanBackRingBounds =
            ring->mapRectToItem(art, ring->boundingRect());
        const QRectF leanBackHaloBounds =
            halo->mapRectToItem(art, halo->boundingRect());
        QVERIFY(leanBackRingBounds.left() > 0.0);
        QVERIFY(leanBackRingBounds.top() > 0.0);
        QVERIFY(leanBackRingBounds.right() < art->width());
        QVERIFY(leanBackRingBounds.bottom() < art->height());
        QVERIFY(leanBackHaloBounds.left() < 0.0);
        QVERIFY(leanBackHaloBounds.top() < 0.0);
        QVERIFY(leanBackHaloBounds.right() > art->width());
        QVERIFY(leanBackHaloBounds.bottom() > art->height());
        QCOMPARE(focusFrame->property("haloPadding").toReal(), 52.0);
        // Marquee/Theme/ViewModifiers/CardHoverModifier.swift:64-67 specifies
        // the 2.25-point ring, 0.95 opacity, and screen blend behavior.
        QCOMPARE(focusFrame->property("ringOpacity").toReal(), 0.95);
        QVERIFY(ring->isVisible());
        QVERIFY(ring->opacity() > 0.0);
        QVERIFY(halo->isVisible());
        QVERIFY(halo->opacity() > 0.0);
    }

    void posterMetadataUsesProductionWatchProgressProjection()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        QTemporaryDir library;
        QVERIFY(writeMediaFile(library.path(), QStringLiteral("Arrival.2016.mkv")));
        QVERIFY(writeMediaFile(library.path(), QStringLiteral("NoRuntime.mkv")));
        QVERIFY(writeMediaFile(library.path(), QStringLiteral("NoYear.mkv")));

        AppPaths::ensureDirectories();
        // MediaItem.swift:143-151 formats a recorded duration in seconds; the
        // catalog source stores the same player value in milliseconds.
        const qint64 recordedDurationMs = qint64{95 * 60 * 1000};
        QString arrivalId;
        QString noYearId;
        {
            CatalogDatabase catalog(AppPaths::catalogFile());
            catalog.migrate();
            CatalogStore store(AppPaths::catalogFile());
            const QVector<LibraryRoot> roots =
                store.registerRoots({library.path()});
            for (const LibraryRoot &root : roots) {
                store.applyScan(root, LibraryScanner::scan(root));
            }
            const QVector<MediaItem> scanned = store.projection(roots);
            QCOMPARE(scanned.size(), 3);
            for (const MediaItem &item : scanned) {
                if (item.title == QStringLiteral("Arrival")) {
                    arrivalId = item.id;
                } else if (item.title == QStringLiteral("NoYear")) {
                    noYearId = item.id;
                }
            }
            QVERIFY(!arrivalId.isEmpty());
            QVERIFY(!noYearId.isEmpty());

            // CatalogWorker::recordProgress writes this same production row;
            // the controller below must recover it through its normal projection.
            // Progress belongs to a profile; the controller below chooses the
            // seeded first profile and must recover what that profile recorded.
            const ProfileStore seeded(AppPaths::profilesFile());
            const QString profileId = seeded.profiles().at(0).id;
            store.recordWatchProgress(profileId, arrivalId, 0, recordedDurationMs, false);
            store.recordWatchProgress(profileId, noYearId, 0, recordedDurationMs, false);
        }

        ApplicationController controller;
        QVERIFY(controller.chooseProfile(controller.profiles()->profiles().at(0).id));
        controller.setTemporaryLibraryRoot(library.path());
        QTRY_COMPARE(controller.library()->rowCount(), 3);

        const std::optional<MediaItem> arrival =
            controller.library()->itemForId(arrivalId);
        const std::optional<MediaItem> noYear =
            controller.library()->itemForId(noYearId);
        QVERIFY(arrival.has_value());
        QVERIFY(noYear.has_value());
        QCOMPARE(arrival->durationSeconds, recordedDurationMs / 1000);
        QCOMPARE(noYear->durationSeconds, recordedDurationMs / 1000);

        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY2(window != nullptr, "qml/Main.qml did not load from the module");
        controller.navigation()->goHome();

        QQuickItem *view = nullptr;
        QTRY_VERIFY((view = grid(window)) != nullptr);
        QTRY_COMPARE(view->property("count").toInt(), 3);
        revealRow(window, view);

        const int arrivalRow = rowForTitle(controller.library(),
                                           QStringLiteral("Arrival"));
        const int noRuntimeRow = rowForTitle(controller.library(),
                                             QStringLiteral("NoRuntime"));
        const int noYearRow = rowForTitle(controller.library(),
                                          QStringLiteral("NoYear"));
        QVERIFY(arrivalRow >= 0);
        QVERIFY(noRuntimeRow >= 0);
        QVERIFY(noYearRow >= 0);

        auto *metadata = cardAt(view, arrivalRow)->findChild<QQuickItem *>(
            QStringLiteral("posterMetadata"));
        QVERIFY(metadata != nullptr);
        QTRY_COMPARE(metadata->property("text").toString(),
                     QStringLiteral("2016 1h 35m"));

        metadata = cardAt(view, noYearRow)->findChild<QQuickItem *>(
            QStringLiteral("posterMetadata"));
        QVERIFY(metadata != nullptr);
        QTRY_COMPARE(metadata->property("text").toString(), QStringLiteral("1h 35m"));

        metadata = cardAt(view, noRuntimeRow)->findChild<QQuickItem *>(
            QStringLiteral("posterMetadata"));
        QVERIFY(metadata != nullptr);
        QTRY_COMPARE(metadata->property("text").toString(), QString());
        QVERIFY(!metadata->isVisible());
    }

    void visiblePosterMetadataRefreshesWhenPlaybackRecordsRuntime()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        QTemporaryDir library;
        QVERIFY(writeMediaFile(library.path(), QStringLiteral("Arrival.2016.mkv")));

        ApplicationController controller;
        // Progress is saved for a profile, so the viewer has chosen one.
        QVERIFY(controller.chooseProfile(controller.profiles()->profiles().at(0).id));
        QTRY_VERIFY(!controller.profileExitInFlight());
        controller.setTemporaryLibraryRoot(library.path());
        QTRY_COMPARE(controller.library()->rowCount(), 1);

        const QString mediaId = idAt(controller.library(), 0);
        const auto item = controller.library()->itemForId(mediaId);
        QVERIFY(item.has_value());

        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY2(window != nullptr, "qml/Main.qml did not load from the module");
        controller.navigation()->goHome();

        QQuickItem *view = nullptr;
        QTRY_VERIFY((view = grid(window)) != nullptr);
        QTRY_COMPARE(view->property("count").toInt(), 1);
        revealRow(window, view);
        auto *metadata = cardAt(view, 0)->findChild<QQuickItem *>(
            QStringLiteral("posterMetadata"));
        QVERIFY(metadata != nullptr);
        QTRY_COMPARE(metadata->property("text").toString(),
                     QStringLiteral("2016"));

        // PlayerController emits this through the production progress path;
        // the visible card must receive the new duration without a rescan.
        QSignalSpy persisted(&controller,
                             &ApplicationController::catalogProgressPersisted);
        controller.player()->prepare(item->absolutePath, item->title, item->id);
        controller.player()->reportPlayback(420.0, 7200.0, false);
        controller.player()->reportPlayback(420.0, 7200.0, true);

        QTRY_COMPARE(persisted.count(), 1);
        QCOMPARE(persisted.constFirst().at(0).toString(), mediaId);
        QCOMPARE(persisted.constFirst().at(1).toLongLong(), qint64{420'000});
        QTRY_COMPARE(metadata->property("text").toString(),
                     QStringLiteral("2016 2h 0m"));
        const auto updated = controller.library()->itemForId(mediaId);
        QVERIFY(updated.has_value());
        QCOMPARE(updated->durationSeconds, qint64{7200});
    }

    void focusedPosterPaintsOutsideArtworkAndCompositesAgainstIt()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        QTemporaryDir library;
        QVERIFY(writeMediaFile(library.path(), QStringLiteral("Arrival.2016.mkv")));
        QVERIFY(writePosterFile(library.path(),
                                QStringLiteral("Arrival.2016-poster.png"),
                                QColor("#00c800")));

        ApplicationController controller;
        // Progress is saved for a profile, so the viewer has chosen one.
        QVERIFY(controller.chooseProfile(controller.profiles()->profiles().at(0).id));
        QTRY_VERIFY(!controller.profileExitInFlight());
        controller.setTemporaryLibraryRoot(library.path());
        QTRY_COMPARE(controller.library()->rowCount(), 1);
        const auto item = controller.library()->itemForId(
            idAt(controller.library(), 0));
        QVERIFY(item.has_value());

        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY2(window != nullptr, "qml/Main.qml did not load from the module");
        controller.navigation()->goHome();

        QQuickItem *view = nullptr;
        QTRY_VERIFY((view = grid(window)) != nullptr);
        QTRY_COMPARE(view->property("count").toInt(), 1);
        revealRow(window, view);
        auto *card = cardAt(view, 0);
        QVERIFY(card != nullptr);
        auto *focusFrame = card->findChild<QQuickItem *>(
            QStringLiteral("posterFocusFrame"));
        auto *metadata = card->findChild<QQuickItem *>(
            QStringLiteral("posterMetadata"));
        QVERIFY(focusFrame != nullptr);
        QVERIFY(metadata != nullptr);
        auto *ring = focusFrame->findChild<QQuickItem *>(
            QStringLiteral("focusRing"));
        auto *halo = focusFrame->findChild<QQuickItem *>(
            QStringLiteral("focusHalo"));
        QVERIFY(ring != nullptr);
        QVERIFY(halo != nullptr);
        auto *art = artOf(card);
        QVERIFY(art != nullptr);
        QTRY_COMPARE(art->property("status").toInt(), 1); // Image.Ready

        window->show();
        QVERIFY(!focusFrame->property("active").toBool());
        QVERIFY(!ring->isVisible());
        const auto greenPainted = [&](const Capture &capture) {
            const QRect artRect = imageRectForItem(capture, art);
            return !artRect.isEmpty()
                && capture.image.pixelColor(artRect.center()) == QColor("#00c800");
        };
        const Capture unfocused = captureSettled(window, card, false, greenPainted);
        QVERIFY2(unfocused.coherent() && greenPainted(unfocused),
                 "the default browse test platform did not paint the artwork");
        const QRect unfocusedArtRect = imageRectForItem(unfocused, art);
        const int idleAccent = focusAccentPixelsOutsideArtwork(unfocused, unfocusedArtRect);
        QVERIFY2(idleAccent == 0,
                 qPrintable(QStringLiteral("%1 accent pixels around idle artwork %2 at ratio %3: %4")
                                .arg(idleAccent).arg(QTest::toString(unfocusedArtRect))
                                .arg(unfocused.devicePixelRatio)
                                .arg(render_probe::describePixelsOutside(
                                    unfocused.image, aroundArtwork(unfocused, unfocusedArtRect),
                                    artworkWithAlignmentSlop(unfocusedArtRect), isAccentGlowPixel))));

        focusFirstCard(window, view);
        QTRY_VERIFY(focusFrame->property("active").toBool());
        QVERIFY(focusFrame->isVisible());
        QVERIFY(focusFrame->opacity() > 0.0);
        QTRY_VERIFY(ring->isVisible());
        QVERIFY(ring->opacity() > 0.0);
        QTRY_VERIFY(halo->isVisible());
        QVERIFY(halo->opacity() > 0.0);
        const auto focusChromePainted = [&](const Capture &capture) {
            const QRect artRect = imageRectForItem(capture, art);
            const QRect frameRect = imageRectForItem(capture, focusFrame);
            return !artRect.isEmpty() && !frameRect.isEmpty()
                && focusAccentPixelsOutsideArtwork(capture, artRect) > 0
                && screenBlendedRingPixels(capture, frameRect) > 0;
        };
        const Capture focused = captureSettled(window, card, true, focusChromePainted);
        QVERIFY(focused.coherent());
        QVERIFY(cardSettled(focused, card, true));
        const QRect focusedArtRect = imageRectForItem(focused, art);
        const QRect focusedFrameRect = imageRectForItem(focused, focusFrame);
        QVERIFY(!focusedArtRect.isEmpty());
        QVERIFY(!focusedFrameRect.isEmpty());
        QVERIFY2(focusAccentPixelsOutsideArtwork(focused, focusedArtRect) > 0,
                 "focused chrome did not paint accent pixels outside artwork");
        QVERIFY2(screenBlendedRingPixels(focused, focusedFrameRect) > 0,
                 "the focus ring was not screen-composited against artwork");
        // Source-over purple over the green fixture loses the green channel;
        // a screen blend keeps it, so none of that purple is in the band.
        QCOMPARE(ringBandPixels(focused, focusedFrameRect, isSourceOverAccentOnGreen), 0);
        // The ring is padded inside the frame, so nothing at ring strength
        // is painted across or beyond the artwork edge.
        QCOMPARE(ringStrengthAccentPixelsJustOutsideArtwork(focused, focusedArtRect), 0);
        // And the whole band, pixel by pixel, over the washed green.
        verifyRingBlendedOverRenderedBackdrop(window, focused, unfocused, card, false);

        controller.player()->prepare(item->absolutePath, item->title, item->id);
        controller.player()->reportPlayback(420.0, 7200.0, false);
        controller.player()->reportPlayback(420.0, 7200.0, true);
        QTRY_COMPARE(metadata->property("text").toString(),
                     QStringLiteral("2016 2h 0m"));
    }

    // Marquee/SharedViews/MovieCard.swift:204-224 draws the elevated surface
    // and PosterFallbackArtwork beneath the artwork, so a sidecar with
    // transparent pixels reveals that stack: MovieCard.swift:309-351 runs a
    // gradient from the surface layer at 0.96 through the accent at 0.22 to
    // the elevated surface at 0.98 from the top-leading corner to the
    // bottom-trailing one. CardHoverModifier.swift:61-69 then blends the ring
    // over that painted, varied surface, not over the file's raw pixels.
    void focusRingBlendsOverTheRenderedPosterSurfaceNotTheRawArtwork()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        QTemporaryDir library;
        QVERIFY(writeMediaFile(library.path(), QStringLiteral("Arrival.2016.mkv")));
        QVERIFY(writePosterFile(library.path(),
                                QStringLiteral("Arrival.2016-poster.png"),
                                Qt::transparent));

        ApplicationController controller;
        controller.setTemporaryLibraryRoot(library.path());
        controller.settings()->setLeanBackMode(false);
        QTRY_COMPARE(controller.library()->rowCount(), 1);

        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY2(window != nullptr, "qml/Main.qml did not load from the module");
        controller.navigation()->goHome();

        QQuickItem *view = nullptr;
        QTRY_VERIFY((view = grid(window)) != nullptr);
        QTRY_COMPARE(view->property("count").toInt(), 1);
        revealRow(window, view);
        auto *card = cardAt(view, 0);
        QVERIFY(card != nullptr);
        auto *art = artOf(card);
        auto *fallback = fallbackOf(card);
        QVERIFY(art != nullptr);
        QVERIFY(fallback != nullptr);
        QTRY_COMPARE(art->property("status").toInt(), 1); // Image.Ready
        QVERIFY(fallback->isVisible());
        QCOMPARE(fallback->findChild<QQuickItem *>(QStringLiteral("posterFallbackTitle"))
                     ->property("text").toString(),
                 QStringLiteral("Arrival"));

        window->show();
        // The gradient's ends composited over the elevated surface: the
        // surface layer near the top-leading corner, the elevated surface
        // near the bottom-trailing one, and neither is the flat colour of
        // the other.
        const QColor topLeading = render_probe::sourceOverOn(QColor("#1a1525"), QColor("#231d30"), 0.96);
        const QColor bottomTrailing = render_probe::sourceOverOn(QColor("#1a1525"), QColor("#1a1525"), 0.98);
        const auto fallbackPainted = [&](const Capture &capture) {
            const QRect artRect = imageRectForItem(capture, art);
            if (artRect.isEmpty()) {
                return false;
            }
            const int inset = pixels(capture, 6);
            return render_probe::withinTolerance(
                       capture.image.pixelColor(artRect.topLeft() + QPoint(inset, inset)), topLeading, 4)
                && render_probe::withinTolerance(
                       capture.image.pixelColor(artRect.bottomRight() - QPoint(inset, inset)), bottomTrailing, 4);
        };
        const Capture idle = captureSettled(window, card, false, fallbackPainted);
        QVERIFY2(idle.coherent() && fallbackPainted(idle),
                 "the transparent poster did not reveal the fallback artwork beneath it");
        const QRect idleArtRect = imageRectForItem(idle, art);
        QVERIFY(!render_probe::withinTolerance(
            idle.image.pixelColor(idleArtRect.topLeft() + QPoint(pixels(idle, 6), pixels(idle, 6))),
            bottomTrailing, 4));

        focusFirstCard(window, view);
        const auto ringPainted = [&](const Capture &capture) {
            return glowPaintedAbove(capture, art) && capture.items.contains(ringOf(card));
        };
        const Capture focused = captureSettled(window, card, true, ringPainted);
        QVERIFY2(focused.coherent() && ringPainted(focused),
                 "the focus ring was not painted over the fallback artwork");
        verifyRingBlendedOverRenderedBackdrop(window, focused, idle, card, false);
    }

    // A backdrop that changes under the band, so the audit's mapping from a
    // focused ring pixel to the idle artwork beneath it is itself under test:
    // the classifier must agree with Qt's own transform, and a lookup that
    // ignores the focus scale or slides the centre must be flagged.
    void focusRingBlendIsJudgedAgainstTheMappedQuadrantBackdrop()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        QTemporaryDir library;
        QVERIFY(writeMediaFile(library.path(), QStringLiteral("Arrival.2016.mkv")));
        QVERIFY(writeQuadrantPosterFile(library.path(), QStringLiteral("Arrival.2016-poster.png")));

        ApplicationController controller;
        controller.setTemporaryLibraryRoot(library.path());
        controller.settings()->setLeanBackMode(false);
        QTRY_COMPARE(controller.library()->rowCount(), 1);

        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY2(window != nullptr, "qml/Main.qml did not load from the module");
        controller.navigation()->goHome();

        QQuickItem *view = nullptr;
        QTRY_VERIFY((view = grid(window)) != nullptr);
        QTRY_COMPARE(view->property("count").toInt(), 1);
        revealRow(window, view);
        auto *card = cardAt(view, 0);
        QVERIFY(card != nullptr);
        auto *art = artOf(card);
        QVERIFY(art != nullptr);
        QTRY_COMPARE(art->property("status").toInt(), 1); // Image.Ready

        window->show();
        const auto quadrantsPainted = [&](const Capture &capture) {
            const QRect artRect = imageRectForItem(capture, art);
            if (artRect.isEmpty()) {
                return false;
            }
            const int inset = pixels(capture, 10);
            return capture.image.pixelColor(artRect.topLeft() + QPoint(inset, inset)) == QColor("#c80000")
                && capture.image.pixelColor(artRect.bottomLeft() + QPoint(inset, -inset)) == QColor("#0000c8")
                && capture.image.pixelColor(artRect.bottomRight() - QPoint(inset, inset)) == QColor("#c8c800");
        };
        const Capture idle = captureSettled(window, card, false, quadrantsPainted);
        QVERIFY2(idle.coherent() && quadrantsPainted(idle), "the quadrant poster was not painted");

        focusFirstCard(window, view);
        const auto ringPainted = [&](const Capture &capture) {
            return glowPaintedAbove(capture, art) && capture.items.contains(ringOf(card));
        };
        const Capture focused = captureSettled(window, card, true, ringPainted);
        QVERIFY2(focused.coherent() && ringPainted(focused),
                 "the focus ring was not painted over the quadrant poster");
        verifyRingBlendedOverRenderedBackdrop(window, focused, idle, card, true);
    }

    void paintedBackdropUsesPhysicalPixelsWhateverTheSourceTag_data()
    {
        QTest::addColumn<qreal>("captureRatio");
        QTest::addColumn<qreal>("imageTag");
        QTest::newRow("ratio 1, tagged 1") << 1.0 << 1.0;
        QTest::newRow("ratio 1, tagged 2") << 1.0 << 2.0;
        QTest::newRow("ratio 2, tagged 1") << 2.0 << 1.0;
        QTest::newRow("ratio 2, tagged 2") << 2.0 << 2.0;
    }

    // A grab is tagged with the window's ratio, and Qt's painter honours
    // that tag when an image is drawn by position: a source tagged 2 drawn
    // into a ratio-1 scratch paints a quarter of its pixels. The painter
    // oracle must place a known physical pixel where the focus scale puts
    // it, whatever the capture's ratio and whatever the image is tagged,
    // and the classifier's lookup must agree.
    void paintedBackdropUsesPhysicalPixelsWhateverTheSourceTag()
    {
        QFETCH(qreal, captureRatio);
        QFETCH(qreal, imageTag);

        QImage synthetic(100, 80, QImage::Format_ARGB32_Premultiplied);
        synthetic.fill(Qt::black);
        const QRect block(60, 30, 10, 10);
        for (int y = block.top(); y <= block.bottom(); ++y) {
            for (int x = block.left(); x <= block.right(); ++x) {
                synthetic.setPixelColor(x, y, Qt::red);
            }
        }
        Capture idle;
        idle.image = render_probe::taggedWithRatio(synthetic, imageTag);
        idle.imageDevicePixelRatio = imageTag;
        idle.devicePixelRatio = captureRatio;
        idle.logicalSize = QSize(qRound(100 / captureRatio), qRound(80 / captureRatio));
        QVERIFY(idle.coherent());

        render_probe::StrokeBlendModel model;
        model.centre = QPointF(50, 40);
        model.scale = 1.045;
        model.washOpacity = 0.0;
        // The block's centre pixel, scaled about the centre by the focus scale.
        const QPointF blockCentre(65.5, 35.5);
        const QPointF mapped = model.centre + (blockCentre - model.centre) * model.scale;
        const QPoint mappedPixel(int(std::floor(mapped.x())), int(std::floor(mapped.y())));

        const QImage painted = render_probe::paintedFocusedBackdrop(idle, model);
        QCOMPARE(painted.size(), synthetic.size());
        QCOMPARE(painted.pixelColor(mappedPixel), QColor(Qt::red));
        QCOMPARE(painted.pixelColor(QPoint(75, 60)), QColor(Qt::black));
        QCOMPARE(render_probe::backdropAt(idle, model, mappedPixel), QColor(Qt::red));
        QCOMPARE(render_probe::backdropDisagreements(idle, model, {mappedPixel, QPoint(10, 10)}, painted), 0);

        // The mechanism the oracle guards against, kept as a control: drawn by
        // position, the tag scales the source down and the block moves or
        // vanishes.
        QImage byPosition(synthetic.size(), QImage::Format_ARGB32_Premultiplied);
        byPosition.fill(Qt::black);
        {
            QPainter painter(&byPosition);
            painter.drawImage(QPoint(0, 0), idle.image);
        }
        QCOMPARE(byPosition.pixelColor(QPoint(65, 35)) == QColor(Qt::red), imageTag == 1.0);
    }

    void coveredStrokePixelsIncludeTheStraightArcTangents_data()
    {
        QTest::addColumn<qreal>("dpr");
        QTest::newRow("ratio 1") << 1.0;
        QTest::newRow("ratio 2") << 2.0;
    }

    // The covered-pixel enumeration is the audit's reach: a pixel it omits is
    // never judged, however wrong the renderer painted it. Where a straight
    // run meets a corner arc the band's edges are still the two straight
    // sides, so a pixel lying wholly between them is wholly covered even
    // though it is tangent to the corner radius. The enumeration is checked
    // against a containment oracle written from the rounded-rectangle
    // distance rather than from the enumeration's own decomposition: the
    // distance grows with each coordinate's distance from the centre, so
    // over a pixel square it is largest at the corner farthest from the
    // centre and smallest at the point of the square nearest it, and the
    // pixel is wholly covered exactly when the largest is at or inside the
    // outer edge and the smallest at or outside the inner edge.
    void coveredStrokePixelsIncludeTheStraightArcTangents()
    {
        QFETCH(qreal, dpr);

        // FocusFrame.qml:144-149 insets the ring by its own line width inside
        // the 150 by 225-point poster frame and keeps Theme.radiusMD.
        const qreal lineWidth = 2.25;
        const qreal cornerRadius = 8.0;
        const QRectF ringRect(0.0, 0.0, 150.0 - 2 * lineWidth, 225.0 - 2 * lineWidth);
        const QRectF outer(0.0, 0.0, ringRect.width() * dpr, ringRect.height() * dpr);
        const qreal band = lineWidth * dpr;
        const qreal radius = cornerRadius * dpr;

        Capture capture;
        capture.devicePixelRatio = dpr;
        capture.logicalSize = QSize(int(std::ceil(ringRect.width())) + 4,
                                    int(std::ceil(ringRect.height())) + 4);
        capture.image = QImage(capture.expectedImageSize(), QImage::Format_ARGB32_Premultiplied);
        capture.image.fill(Qt::black);
        QVERIFY(capture.coherent());

        const QList<QPoint> covered =
            render_probe::fullyCoveredStrokePixels(capture, ringRect, lineWidth, cornerRadius);
        QVERIFY(!covered.isEmpty());

        // Whether the whole of a pixel lies in the stroke band, from the
        // distance function alone.
        const auto whollyCovered = [&](const QPoint &pixel) {
            const QPointF centre = outer.center();
            const qreal farX = std::abs(pixel.x() - centre.x()) > std::abs(pixel.x() + 1 - centre.x())
                ? pixel.x() : pixel.x() + 1;
            const qreal farY = std::abs(pixel.y() - centre.y()) > std::abs(pixel.y() + 1 - centre.y())
                ? pixel.y() : pixel.y() + 1;
            const qreal nearX = std::clamp(centre.x(), qreal(pixel.x()), qreal(pixel.x() + 1));
            const qreal nearY = std::clamp(centre.y(), qreal(pixel.y()), qreal(pixel.y() + 1));
            return render_probe::roundedRectSignedDistance(QPointF(farX, farY), outer, radius) <= 0.0
                && render_probe::roundedRectSignedDistance(QPointF(nearX, nearY), outer, radius) >= -band;
        };

        // The tangent witness: one pixel in from the left edge, on the row
        // the corner radius falls on, wholly inside the left straight stroke
        // and tangent to where that run meets the top-left arc. The straight
        // run once began a point past it and the arc quadrant rejects it, so
        // it went unjudged.
        const QPoint tangent(qRound(1.0 * dpr), qRound(cornerRadius * dpr));
        QVERIFY2(whollyCovered(tangent),
                 qPrintable(QStringLiteral("the witness %1 is not wholly inside the band at ratio %2")
                                .arg(QTest::toString(tangent)).arg(dpr)));
        QVERIFY2(tangent.y() <= outer.top() + radius && outer.top() + radius <= tangent.y() + 1,
                 "the witness is not on the row the straight run meets the arc on");
        QVERIFY2(covered.contains(tangent),
                 qPrintable(QStringLiteral("the enumeration omits the tangent witness %1 at ratio %2")
                                .arg(QTest::toString(tangent)).arg(dpr)));

        // The band's inner edge on that same row is not admitted: full-pixel
        // containment is not weakened to reach the witness.
        const QPoint pastInnerEdge(int(std::floor(band)), tangent.y());
        QVERIFY(!whollyCovered(pastInnerEdge));
        QVERIFY2(!covered.contains(pastInnerEdge),
                 qPrintable(QStringLiteral("the enumeration admits the partly covered %1 at ratio %2")
                                .arg(QTest::toString(pastInnerEdge)).arg(dpr)));

        // Sound and free of duplicates: every enumerated pixel is wholly
        // covered, and no arc pixel is listed again as a straight one.
        QSet<QPoint> enumerated;
        QStringList unsound;
        int duplicates = 0;
        for (const QPoint &pixel : covered) {
            if (enumerated.contains(pixel)) {
                ++duplicates;
            }
            enumerated.insert(pixel);
            if (!whollyCovered(pixel) && unsound.size() < 8) {
                unsound << QTest::toString(pixel);
            }
        }
        QVERIFY2(unsound.isEmpty(),
                 qPrintable(QStringLiteral("partly covered pixels enumerated at ratio %1: %2")
                                .arg(dpr).arg(unsound.join(QLatin1Char(' ')))));
        QCOMPARE(duplicates, 0);

        // Complete along the straight runs: every wholly covered pixel that
        // lies clear of both arcs on its side is enumerated, the witnesses
        // included.
        QStringList missing;
        for (int y = -1; y <= capture.image.height(); ++y) {
            for (int x = -1; x <= capture.image.width(); ++x) {
                const QPoint pixel(x, y);
                const bool onVerticalRun = y >= outer.top() + radius && y + 1 <= outer.bottom() - radius;
                const bool onHorizontalRun = x >= outer.left() + radius && x + 1 <= outer.right() - radius;
                if (!(onVerticalRun || onHorizontalRun) || !whollyCovered(pixel)
                    || !capture.image.rect().contains(pixel)) {
                    continue;
                }
                if (!enumerated.contains(pixel) && missing.size() < 8) {
                    missing << QTest::toString(pixel);
                }
            }
        }
        QVERIFY2(missing.isEmpty(),
                 qPrintable(QStringLiteral("wholly covered straight-run pixels omitted at ratio %1: %2")
                                .arg(dpr).arg(missing.join(QLatin1Char(' ')))));

        // The witness is a straight-run pixel, not an arc one: reaching it
        // did not reclassify a corner.
        QVERIFY(!render_probe::cornerPixelsOf(capture, covered, ringRect, cornerRadius).contains(tangent));
    }

    void anOmittedTangentPixelLeavesACorruptedRingUnjudged_data()
    {
        coveredStrokePixelsIncludeTheStraightArcTangents_data();
    }

    // What the omission cost: on a band that is right everywhere but the
    // tangent witness, the audit reports the corruption only because the
    // witness is enumerated. Judged over the enumeration the wrong pixel is
    // flagged as exactly one; judged over that same enumeration with the
    // witness dropped, or with it moved to the partly covered pixel beside
    // it, the corrupted band passes clean.
    void anOmittedTangentPixelLeavesACorruptedRingUnjudged()
    {
        QFETCH(qreal, dpr);

        const qreal lineWidth = 2.25;
        const qreal cornerRadius = 8.0;
        const QRectF ringRect(0.0, 0.0, 150.0 - 2 * lineWidth, 225.0 - 2 * lineWidth);
        const QColor ringColour("#7b5ea7");
        const qreal ringOpacity = 0.95;
        // A backdrop light enough that the screen and source-over results
        // differ well past the audit's tolerance.
        const QColor backdropColour("#808080");

        Capture capture;
        capture.devicePixelRatio = dpr;
        capture.logicalSize = QSize(int(std::ceil(ringRect.width())) + 4,
                                    int(std::ceil(ringRect.height())) + 4);
        capture.image = QImage(capture.expectedImageSize(), QImage::Format_ARGB32_Premultiplied);
        capture.image.fill(backdropColour);
        QVERIFY(capture.coherent());

        const QList<QPoint> covered =
            render_probe::fullyCoveredStrokePixels(capture, ringRect, lineWidth, cornerRadius);
        const QPoint tangent(qRound(1.0 * dpr), qRound(cornerRadius * dpr));
        QVERIFY(covered.contains(tangent));

        // A ring painted right, over the flat backdrop the audit reads as its
        // reference. Every pixel is the screen blend, so whichever pixels an
        // enumeration names, only a corrupted one can be a mismatch.
        const QImage reference = capture.image;
        QImage focused = reference;
        focused.fill(render_probe::screenOn(backdropColour, ringColour, ringOpacity));
        const render_probe::StrokeReferenceAudit clean = render_probe::auditStrokeAgainstReference(
            focused, reference, covered, ringColour, ringOpacity);
        QCOMPARE(clean.covered, int(covered.size()));
        QCOMPARE(clean.mismatches, 0);
        QCOMPARE(clean.distinguishable, int(covered.size()));

        // The same band with the tangent witness alone painted source-over.
        QImage corrupted = focused;
        corrupted.setPixelColor(tangent, render_probe::sourceOverOn(backdropColour, ringColour, ringOpacity));
        const render_probe::StrokeReferenceAudit caught = render_probe::auditStrokeAgainstReference(
            corrupted, reference, covered, ringColour, ringOpacity);
        QVERIFY2(caught.mismatches == 1 && caught.sourceOverMatches == 1,
                 qPrintable(QStringLiteral("tangent %1 corrupted at ratio %2: %3 mismatches, %4 source-over")
                                .arg(QTest::toString(tangent)).arg(dpr)
                                .arg(caught.mismatches).arg(caught.sourceOverMatches)));

        // Dropped from the enumeration, the same corruption is invisible.
        QList<QPoint> withoutTangent = covered;
        QCOMPARE(withoutTangent.removeAll(tangent), 1);
        const render_probe::StrokeReferenceAudit blind = render_probe::auditStrokeAgainstReference(
            corrupted, reference, withoutTangent, ringColour, ringOpacity);
        QCOMPARE(blind.covered, int(covered.size()) - 1);
        QCOMPARE(blind.mismatches, 0);

        // Misclassified as the partly covered pixel beside it, likewise: the
        // audit judges one pixel of the band it has no business judging and
        // still never reaches the wrong one.
        QList<QPoint> slid = withoutTangent;
        slid.append(QPoint(int(std::floor(lineWidth * dpr)), tangent.y()));
        const render_probe::StrokeReferenceAudit misclassified = render_probe::auditStrokeAgainstReference(
            corrupted, reference, slid, ringColour, ringOpacity);
        QCOMPARE(misclassified.covered, int(covered.size()));
        QCOMPARE(misclassified.mismatches, 0);
    }

    void coveredStrokePixelsReachFractionalStraightArcJoins_data()
    {
        QTest::addColumn<QRectF>("ringRect");
        QTest::addColumn<qreal>("dpr");
        // FocusFrame.qml:144-149 insets the ring by its own 2.25-point line
        // width inside the 150 by 225-point poster frame, so the ring is
        // 145.5 by 220.5 points at a 2.25-point offset and every join between
        // a straight run and a corner arc falls inside a pixel. At ratio 1
        // the rectangle placed at the origin already has fractional joins on
        // its right and bottom sides, which is where the reported witness
        // lies; at ratio 2 that placement doubles to whole pixels, so the
        // ratio-2 row keeps the offset the frame actually gives the ring.
        QTest::newRow("ratio 1") << QRectF(0.0, 0.0, 145.5, 220.5) << 1.0;
        QTest::newRow("ratio 2") << QRectF(2.25, 2.25, 145.5, 220.5) << 2.0;
    }

    // The enumeration must reach every wholly covered pixel of a fractional
    // ring, joins included. Where a side's length is not a whole number of
    // device pixels the line at which a straight run ends and its corner arc
    // begins falls inside a pixel: that pixel lies on neither the run's
    // whole-pixel interval nor inside the arc's quadrant, yet its whole
    // extent can still be inside the stroke band, and an unenumerated pixel
    // is never judged however wrong the renderer painted it.
    //
    // The expected set comes from a containment oracle that knows nothing of
    // straight runs, arcs, or joins: a rounded rectangle of radius r is the
    // set of points within r of its core rectangle inset by r, so a point is
    // inside the outer edge exactly when its distance to that core is at most
    // the outer radius, and outside the inner edge exactly when that distance
    // is at least the inner radius. A pixel square's largest such distance is
    // attained at one of its four corners and its smallest is the square's
    // own distance to the core, so the whole pixel lies in the band exactly
    // when all four corners are within the outer radius and the square as a
    // whole is no nearer than the inner one.
    void coveredStrokePixelsReachFractionalStraightArcJoins()
    {
        QFETCH(QRectF, ringRect);
        QFETCH(qreal, dpr);

        const qreal lineWidth = 2.25;
        const qreal cornerRadius = 8.0;
        const QRectF outer(ringRect.x() * dpr, ringRect.y() * dpr, ringRect.width() * dpr,
                           ringRect.height() * dpr);
        const qreal band = lineWidth * dpr;
        const qreal outerRadius = cornerRadius * dpr;
        const qreal innerRadius = outerRadius - band;

        Capture capture;
        capture.devicePixelRatio = dpr;
        capture.logicalSize = QSize(int(std::ceil(ringRect.right())) + 4,
                                    int(std::ceil(ringRect.bottom())) + 4);
        capture.image = QImage(capture.expectedImageSize(), QImage::Format_ARGB32_Premultiplied);
        capture.image.fill(Qt::black);
        QVERIFY(capture.coherent());

        const QRectF core = outer.adjusted(outerRadius, outerRadius, -outerRadius, -outerRadius);
        QVERIFY(core.width() > 0.0 && core.height() > 0.0);
        const auto distanceToCore = [&](qreal x, qreal y) {
            const qreal dx = std::max({core.left() - x, x - core.right(), qreal(0.0)});
            const qreal dy = std::max({core.top() - y, y - core.bottom(), qreal(0.0)});
            return std::hypot(dx, dy);
        };
        const auto whollyCovered = [&](const QPoint &pixel) {
            const qreal x = pixel.x();
            const qreal y = pixel.y();
            for (const QPointF &corner :
                 {QPointF(x, y), QPointF(x + 1, y), QPointF(x, y + 1), QPointF(x + 1, y + 1)}) {
                if (distanceToCore(corner.x(), corner.y()) > outerRadius) {
                    return false;
                }
            }
            const qreal nearestX = std::max({core.left() - (x + 1), x - core.right(), qreal(0.0)});
            const qreal nearestY = std::max({core.top() - (y + 1), y - core.bottom(), qreal(0.0)});
            return std::hypot(nearestX, nearestY) >= innerRadius;
        };

        // The joins themselves, and whether a pixel straddles one.
        const qreal joinsX[] = {outer.left() + outerRadius, outer.right() - outerRadius};
        const qreal joinsY[] = {outer.top() + outerRadius, outer.bottom() - outerRadius};
        const auto crossesAJoin = [&](const QPoint &pixel) {
            const auto straddles = [](qreal join, int start) {
                return qreal(start) < join && join < qreal(start + 1);
            };
            return std::any_of(std::begin(joinsX), std::end(joinsX),
                               [&](qreal join) { return straddles(join, pixel.x()); })
                || std::any_of(std::begin(joinsY), std::end(joinsY),
                               [&](qreal join) { return straddles(join, pixel.y()); });
        };
        QVERIFY2(std::any_of(std::begin(joinsX), std::end(joinsX),
                             [](qreal join) { return join != std::floor(join); })
                     || std::any_of(std::begin(joinsY), std::end(joinsY),
                                    [](qreal join) { return join != std::floor(join); }),
                 "this row's geometry has no fractional join to test");

        // The witness, derived rather than assumed: the topmost wholly
        // covered pixel of the column the top-right join runs through. At
        // ratio 1 with the ring at the origin that is the reported (137,1).
        const int joinColumn = int(std::floor(outer.right() - outerRadius));
        QPoint witness(-1, -1);
        for (int y = 0; y < capture.image.height() && witness.x() < 0; ++y) {
            if (whollyCovered(QPoint(joinColumn, y))) {
                witness = QPoint(joinColumn, y);
            }
        }
        QVERIFY2(witness.x() >= 0, "no wholly covered pixel in the top-right join column");
        QVERIFY2(crossesAJoin(witness),
                 qPrintable(QStringLiteral("the witness %1 does not straddle a join at ratio %2")
                                .arg(QTest::toString(witness)).arg(dpr)));
        if (qFuzzyCompare(dpr, 1.0) && ringRect.topLeft() == QPointF(0.0, 0.0)) {
            QCOMPARE(witness, QPoint(137, 1));
        }

        const QList<QPoint> covered =
            render_probe::fullyCoveredStrokePixels(capture, ringRect, lineWidth, cornerRadius);
        QVERIFY(!covered.isEmpty());
        QVERIFY2(covered.contains(witness),
                 qPrintable(QStringLiteral("the enumeration omits the join witness %1 at ratio %2")
                                .arg(QTest::toString(witness)).arg(dpr)));

        // Its neighbour one step out of the band is only partly covered, and
        // is refused: reaching the witness did not weaken containment.
        const QPoint partlyCovered = witness + QPoint(0, -1);
        QVERIFY2(!whollyCovered(partlyCovered),
                 qPrintable(QStringLiteral("the neighbour %1 is wholly covered at ratio %2")
                                .arg(QTest::toString(partlyCovered)).arg(dpr)));
        QVERIFY2(!covered.contains(partlyCovered),
                 qPrintable(QStringLiteral("the enumeration admits the partly covered %1 at ratio %2")
                                .arg(QTest::toString(partlyCovered)).arg(dpr)));

        // Sound and free of duplicates.
        QSet<QPoint> enumerated;
        QStringList unsound;
        int duplicates = 0;
        for (const QPoint &pixel : covered) {
            if (enumerated.contains(pixel)) {
                ++duplicates;
            }
            enumerated.insert(pixel);
            if (!whollyCovered(pixel) && unsound.size() < 8) {
                unsound << QTest::toString(pixel);
            }
        }
        QVERIFY2(unsound.isEmpty(),
                 qPrintable(QStringLiteral("partly covered pixels enumerated at ratio %1: %2")
                                .arg(dpr).arg(unsound.join(QLatin1Char(' ')))));
        QCOMPARE(duplicates, 0);

        // Complete: every wholly covered pixel of the capture is enumerated,
        // and the join-straddling ones are counted separately so a geometry
        // that happens to have none cannot pass this vacuously.
        QStringList missing;
        int joinPixels = 0;
        int missingJoinPixels = 0;
        for (int y = 0; y < capture.image.height(); ++y) {
            for (int x = 0; x < capture.image.width(); ++x) {
                const QPoint pixel(x, y);
                if (!whollyCovered(pixel)) {
                    continue;
                }
                const bool onJoin = crossesAJoin(pixel);
                if (onJoin) {
                    ++joinPixels;
                }
                if (enumerated.contains(pixel)) {
                    continue;
                }
                if (onJoin) {
                    ++missingJoinPixels;
                }
                if (missing.size() < 8) {
                    missing << QTest::toString(pixel);
                }
            }
        }
        QVERIFY2(joinPixels > 0, "no wholly covered pixel straddles a join in this geometry");
        QVERIFY2(missing.isEmpty(),
                 qPrintable(QStringLiteral("wholly covered pixels omitted at ratio %1 (%2 of them on a "
                                           "join): %3")
                                .arg(dpr).arg(missingJoinPixels).arg(missing.join(QLatin1Char(' ')))));

        // The blend audit splits its controls into corner and straight
        // pixels and requires one of each, so the widened enumeration must
        // still yield both classes rather than collapsing into one.
        const QList<QPoint> corners =
            render_probe::cornerPixelsOf(capture, covered, ringRect, cornerRadius);
        QVERIFY2(!corners.isEmpty(), "no covered pixel is classified as a corner");
        QVERIFY2(corners.size() < covered.size(), "every covered pixel is classified as a corner");
    }

    void anOmittedFractionalJoinPixelLeavesACorruptedRingUnjudged_data()
    {
        coveredStrokePixelsReachFractionalStraightArcJoins_data();
    }

    // What omitting a join pixel costs: on a band that is right everywhere
    // but the join witness, the audit reports the corruption only because the
    // witness is enumerated. Judged over the enumeration the wrong pixel is
    // flagged as exactly one; judged over that same enumeration with the
    // witness dropped, or with it moved to the partly covered pixel beside
    // it, the corrupted band passes clean.
    void anOmittedFractionalJoinPixelLeavesACorruptedRingUnjudged()
    {
        QFETCH(QRectF, ringRect);
        QFETCH(qreal, dpr);

        const qreal lineWidth = 2.25;
        const qreal cornerRadius = 8.0;
        const QColor ringColour("#7b5ea7");
        const qreal ringOpacity = 0.95;
        // A backdrop light enough that the screen and source-over results
        // differ well past the audit's tolerance.
        const QColor backdropColour("#808080");

        Capture capture;
        capture.devicePixelRatio = dpr;
        capture.logicalSize = QSize(int(std::ceil(ringRect.right())) + 4,
                                    int(std::ceil(ringRect.bottom())) + 4);
        capture.image = QImage(capture.expectedImageSize(), QImage::Format_ARGB32_Premultiplied);
        capture.image.fill(backdropColour);
        QVERIFY(capture.coherent());

        const QRectF outer(ringRect.x() * dpr, ringRect.y() * dpr, ringRect.width() * dpr,
                           ringRect.height() * dpr);
        const qreal outerRadius = cornerRadius * dpr;
        const qreal join = outer.right() - outerRadius;
        QVERIFY2(join != std::floor(join), "this row's top-right join is not fractional");

        const QList<QPoint> covered =
            render_probe::fullyCoveredStrokePixels(capture, ringRect, lineWidth, cornerRadius);
        const int joinColumn = int(std::floor(join));
        QPoint witness(-1, -1);
        for (const QPoint &pixel : covered) {
            if (pixel.x() == joinColumn && (witness.x() < 0 || pixel.y() < witness.y())) {
                witness = pixel;
            }
        }
        QVERIFY2(witness.x() >= 0, "the enumeration reaches no pixel of the join column");
        QVERIFY2(qreal(witness.y()) < outer.top() + outerRadius,
                 "the witness is not where the top-right run meets its arc");

        // A ring painted right, over the flat backdrop the audit reads as its
        // reference. Every pixel is the screen blend, so whichever pixels an
        // enumeration names, only a corrupted one can be a mismatch.
        const QImage reference = capture.image;
        QImage focused = reference;
        focused.fill(render_probe::screenOn(backdropColour, ringColour, ringOpacity));
        const render_probe::StrokeReferenceAudit clean = render_probe::auditStrokeAgainstReference(
            focused, reference, covered, ringColour, ringOpacity);
        QCOMPARE(clean.covered, int(covered.size()));
        QCOMPARE(clean.mismatches, 0);
        QCOMPARE(clean.distinguishable, int(covered.size()));

        // The same band with the join witness alone painted source-over.
        QImage corrupted = focused;
        corrupted.setPixelColor(witness, render_probe::sourceOverOn(backdropColour, ringColour, ringOpacity));
        const render_probe::StrokeReferenceAudit caught = render_probe::auditStrokeAgainstReference(
            corrupted, reference, covered, ringColour, ringOpacity);
        QVERIFY2(caught.mismatches == 1 && caught.sourceOverMatches == 1,
                 qPrintable(QStringLiteral("join %1 corrupted at ratio %2: %3 mismatches, %4 source-over")
                                .arg(QTest::toString(witness)).arg(dpr)
                                .arg(caught.mismatches).arg(caught.sourceOverMatches)));

        // Dropped from the enumeration, the same corruption is invisible.
        QList<QPoint> withoutWitness = covered;
        QCOMPARE(withoutWitness.removeAll(witness), 1);
        const render_probe::StrokeReferenceAudit blind = render_probe::auditStrokeAgainstReference(
            corrupted, reference, withoutWitness, ringColour, ringOpacity);
        QCOMPARE(blind.covered, int(covered.size()) - 1);
        QCOMPARE(blind.mismatches, 0);

        // Misclassified as the partly covered pixel above it, likewise: the
        // audit judges one pixel of the band it has no business judging and
        // still never reaches the wrong one.
        const QPoint partlyCovered = witness + QPoint(0, -1);
        QVERIFY(!covered.contains(partlyCovered));
        QList<QPoint> slid = withoutWitness;
        slid.append(partlyCovered);
        const render_probe::StrokeReferenceAudit misclassified = render_probe::auditStrokeAgainstReference(
            corrupted, reference, slid, ringColour, ringOpacity);
        QCOMPARE(misclassified.covered, int(covered.size()));
        QCOMPARE(misclassified.mismatches, 0);
    }

    // Marquee/SharedViews/MovieCard.swift:320-322 draws the fallback's film
    // symbol as a stateless image: it is there at every size and after every
    // redraw. The canvas that stands in for it must paint the same whether
    // it paints for the first time, again at the same size, or after the
    // card has changed mode and back.
    void theFallbackSymbolSurvivesRepaintsAndModeChanges()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        QTemporaryDir library;
        QVERIFY(writeMediaFile(library.path(), QStringLiteral("Moon.2009.mkv")));

        ApplicationController controller;
        controller.setTemporaryLibraryRoot(library.path());
        controller.settings()->setLeanBackMode(false);
        QTRY_COMPARE(controller.library()->rowCount(), 1);

        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY2(window != nullptr, "qml/Main.qml did not load from the module");
        controller.navigation()->goHome();
        QVERIFY(QTest::qWaitForWindowExposed(window));

        QQuickItem *view = nullptr;
        QTRY_VERIFY((view = grid(window)) != nullptr);
        QTRY_COMPARE(view->property("count").toInt(), 1);
        revealRow(window, view);
        window->show();

        // The symbol's frame is tinted over the gradient; a point on its left
        // border, between the sprocket holes, differs from the gradient just
        // outside the symbol. When a paint erased instead of painting, the two
        // agree.
        const auto symbolOf = [&] {
            return fallbackOf(cardAt(view, 0))
                ->findChild<QQuickItem *>(QStringLiteral("posterFallbackSymbol"));
        };
        const auto symbolTinted = [&](const Capture &capture) {
            QQuickItem *symbol = symbolOf();
            const QRect symbolRect = imageRectForItem(capture, symbol);
            if (symbolRect.isEmpty()) {
                return false;
            }
            const QPoint onFrame(symbolRect.left() + pixels(capture, 0.07 * symbol->width()),
                                 symbolRect.top() + symbolRect.height() / 2);
            const QPoint beside(symbolRect.left() - pixels(capture, 3), onFrame.y());
            const QColor frame = capture.image.pixelColor(onFrame);
            const QColor gradient = capture.image.pixelColor(beside);
            return std::abs(frame.red() - gradient.red()) > 6
                || std::abs(frame.green() - gradient.green()) > 6
                || std::abs(frame.blue() - gradient.blue()) > 6;
        };
        const auto captureSymbol = [&] {
            return captureWindowUntil(window, {symbolOf()}, symbolTinted);
        };

        const Capture first = captureSymbol();
        QVERIFY2(first.coherent() && symbolTinted(first), "the film symbol was not painted");
        QCOMPARE(qRound(symbolOf()->width()), 34);

        // The same size, painted again.
        QSignalSpy repainted(symbolOf(), SIGNAL(painted()));
        QVERIFY(QMetaObject::invokeMethod(symbolOf(), "requestPaint"));
        QTRY_VERIFY(repainted.count() > 0);
        const Capture again = captureSymbol();
        QVERIFY2(again.coherent() && symbolTinted(again),
                 "the film symbol was erased by its own repaint at the same size");

        // Lean-back grows the symbol to 52 points, and compact brings it back.
        controller.settings()->setLeanBackMode(true);
        QTRY_COMPARE(qRound(symbolOf()->width()), 52);
        const Capture leanBack = captureSymbol();
        QVERIFY2(leanBack.coherent() && symbolTinted(leanBack),
                 "the film symbol was not painted at the lean-back size");
        controller.settings()->setLeanBackMode(false);
        QTRY_COMPARE(qRound(symbolOf()->width()), 34);
        const Capture compactAgain = captureSymbol();
        QVERIFY2(compactAgain.coherent() && symbolTinted(compactAgain),
                 "the film symbol was not painted again at the compact size");
    }

    void posterSurfaceIsClippedToItsRoundedCorners_data()
    {
        QTest::addColumn<QString>("artwork");
        QTest::addColumn<bool>("leanBack");
        for (const char *artwork : {"real", "transparent", "missing", "undecodable"}) {
            QTest::newRow((QByteArray(artwork) + ", compact").constData())
                << QString::fromLatin1(artwork) << false;
            QTest::newRow((QByteArray(artwork) + ", lean-back").constData())
                << QString::fromLatin1(artwork) << true;
        }
    }

    // Marquee/SharedViews/MovieCard.swift:161-163 clips the whole poster
    // surface to an 8-point rounded rectangle before the focus chrome is
    // applied outside it. Whatever the surface shows, real artwork, the
    // fallback beneath a transparent, missing, or undecodable sidecar, the
    // pixel in each of the four corners of the artwork's rectangle lies
    // wholly outside that arc and must show the backdrop, while the pixel at
    // the arc's centre and one on each straight edge show the surface, so a
    // surface that simply vanished could not pass. The outside chrome is
    // never cut: focused, the same corners show the halo instead.
    void posterSurfaceIsClippedToItsRoundedCorners()
    {
        QFETCH(QString, artwork);
        QFETCH(bool, leanBack);

        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        QTemporaryDir library;
        QVERIFY(writeMediaFile(library.path(), QStringLiteral("Arrival.2016.mkv")));
        const QString sidecar = QStringLiteral("Arrival.2016-poster.png");
        if (artwork == QStringLiteral("real")) {
            QVERIFY(writePosterFile(library.path(), sidecar, QColor("#00c800")));
        } else if (artwork == QStringLiteral("transparent")) {
            QVERIFY(writePosterFile(library.path(), sidecar, Qt::transparent));
        } else if (artwork == QStringLiteral("undecodable")) {
            QVERIFY(writeUndecodablePosterFile(library.path(), sidecar));
        }

        ApplicationController controller;
        controller.setTemporaryLibraryRoot(library.path());
        controller.settings()->setLeanBackMode(leanBack);
        QTRY_COMPARE(controller.library()->rowCount(), 1);

        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY2(window != nullptr, "qml/Main.qml did not load from the module");
        controller.navigation()->goHome();
        QVERIFY(QTest::qWaitForWindowExposed(window));

        QQuickItem *view = nullptr;
        QTRY_VERIFY((view = grid(window)) != nullptr);
        QTRY_COMPARE(view->property("count").toInt(), 1);
        revealRow(window, view);
        auto *card = cardAt(view, 0);
        QVERIFY(card != nullptr);
        auto *art = artOf(card);
        QVERIFY(art != nullptr);
        if (artwork == QStringLiteral("real") || artwork == QStringLiteral("transparent")) {
            QTRY_COMPARE(art->property("status").toInt(), 1); // Image.Ready
        } else {
            QTRY_COMPARE(art->property("source").toUrl(), QUrl());
        }
        window->show();

        // What the surface shows at a witness: the artwork's own green, or
        // the fallback gradient of MovieCard.swift:315-325, which runs from
        // the surface layer at the top-leading corner through the accent to
        // the elevated surface along the diagonal and is therefore a
        // different colour at each witness. Qt's own gradient, painted here
        // over the elevated fill exactly as the fallback canvas paints it, is
        // the reference, sampled at each witness's position relative to the
        // artwork; that also keeps a grab taken before the gradient canvas
        // has painted, when only the fill shows, from being accepted.
        // Focused, MovieCard.swift:226-227 washes the whole surface with
        // black at 0.28, so a focused witness is its idle counterpart washed.
        const bool paintsArtwork = artwork == QStringLiteral("real");
        const auto referenceFallback = [&](const QSize &logicalSize) {
            QImage reference(logicalSize, QImage::Format_ARGB32_Premultiplied);
            reference.fill(QColor("#1a1525"));
            QPainter painter(&reference);
            QLinearGradient gradient(0, 0, logicalSize.width(), logicalSize.height());
            QColor start("#231d30");
            start.setAlphaF(0.96f);
            QColor middle("#7b5ea7");
            middle.setAlphaF(0.22f);
            QColor end("#1a1525");
            end.setAlphaF(0.98f);
            gradient.setColorAt(0.0, start);
            gradient.setColorAt(0.5, middle);
            gradient.setColorAt(1.0, end);
            painter.fillRect(reference.rect(), gradient);
            painter.end();
            return reference;
        };
        const auto expectedIdleSurface = [&](const Capture &capture, const QRect &artRect, const QPoint &at) {
            if (paintsArtwork) {
                return QColor("#00c800");
            }
            const QSize logicalSize(qRound(artRect.width() / capture.devicePixelRatio),
                                    qRound(artRect.height() / capture.devicePixelRatio));
            const QImage reference = referenceFallback(logicalSize);
            const QPoint relative(qRound((at.x() - artRect.left()) / capture.devicePixelRatio),
                                  qRound((at.y() - artRect.top()) / capture.devicePixelRatio));
            return reference.pixelColor(QPoint(qBound(0, relative.x(), logicalSize.width() - 1),
                                               qBound(0, relative.y(), logicalSize.height() - 1)));
        };
        const auto isIdleSurface = [&](const Capture &capture, const QRect &artRect, const QPoint &at) {
            const QColor painted = capture.image.pixelColor(at);
            const QColor expected = expectedIdleSurface(capture, artRect, at);
            return paintsArtwork ? painted == expected : render_probe::withinTolerance(painted, expected, 6);
        };

        // Witness offsets relative to the artwork's rectangle: the arc centre
        // of each corner and the middle of two straight edges, one point in.
        // The same offsets name the same content idle and focused, because
        // the artwork scales with its frame.
        const auto witnessesFor = [&](const Capture &capture, const QRect &artRect) {
            const int radius = pixels(capture, 8);
            const int edge = pixels(capture, 1);
            const int along = pixels(capture, 40);
            return QList<QPair<QString, QPoint>>{
                {QStringLiteral("top-left arc centre"), artRect.topLeft() + QPoint(radius, radius)},
                {QStringLiteral("top-right arc centre"), artRect.topRight() + QPoint(-radius, radius)},
                {QStringLiteral("bottom-left arc centre"), artRect.bottomLeft() + QPoint(radius, -radius)},
                {QStringLiteral("bottom-right arc centre"), artRect.bottomRight() + QPoint(-radius, -radius)},
                {QStringLiteral("left edge"), QPoint(artRect.left() + edge, artRect.center().y() - along)},
                {QStringLiteral("top edge"), QPoint(artRect.center().x() - along, artRect.top() + edge)}};
        };

        // Every corner is judged on its own: the pixel at the corner of the
        // aligned rectangle, whose centre lies more than the radius from the
        // arc's centre at any ratio, against the backdrop three points
        // diagonally outside it, which shares its shadow or halo.
        const auto backdropOutside = [&](const Capture &capture, const QPoint &corner, const QPoint &outward) {
            return capture.image.pixelColor(corner + outward * pixels(capture, 3));
        };
        const auto cornerHoldsBackdrop = [&](const Capture &capture, const QRect &artRect,
                                             const char *name, const QPoint &corner,
                                             const QPoint &outward) {
            const QColor painted = capture.image.pixelColor(corner);
            const QColor backdrop = backdropOutside(capture, corner, outward);
            const bool holds = render_probe::withinTolerance(painted, backdrop, 8);
            if (!holds) {
                QTest::qFail(qPrintable(QStringLiteral("%1 corner %2 painted %3 where the backdrop is %4 (artwork %5)")
                                            .arg(QString::fromLatin1(name)).arg(QTest::toString(corner))
                                            .arg(painted.name()).arg(backdrop.name())
                                            .arg(QTest::toString(artRect))),
                             __FILE__, __LINE__);
            }
            return holds;
        };
        // The corners and the backdrop just outside each of them.
        const auto cornersOf = [](const QRect &artRect) {
            return QList<QPair<QPoint, QPoint>>{
                {artRect.topLeft(), QPoint(-1, -1)}, {artRect.topRight(), QPoint(1, -1)},
                {artRect.bottomLeft(), QPoint(-1, 1)}, {artRect.bottomRight(), QPoint(1, 1)}};
        };
        const char *const cornerNames[] = {"top-left", "top-right", "bottom-left", "bottom-right"};

        QList<QColor> idleWitnessColours;
        const auto judgeSurface = [&](const Capture &capture, bool focused) {
            const char *state = focused ? "focused" : "idle";
            const QRect artRect = imageRectForItem(capture, art);
            QVERIFY2(!artRect.isEmpty(), state);
            const QList<QPair<QString, QPoint>> witnesses = witnessesFor(capture, artRect);
            const QList<QPair<QPoint, QPoint>> corners = cornersOf(artRect);

            for (int index = 0; index < witnesses.size(); ++index) {
                const QPoint at = witnesses.at(index).second;
                const QColor painted = capture.image.pixelColor(at);
                if (!focused) {
                    QVERIFY2(isIdleSurface(capture, artRect, at),
                             qPrintable(QStringLiteral("idle: %1 witness at %2 painted %3, expected %4")
                                            .arg(witnesses.at(index).first).arg(QTest::toString(at))
                                            .arg(painted.name())
                                            .arg(expectedIdleSurface(capture, artRect, at).name())));
                    idleWitnessColours.append(painted);
                } else {
                    const QColor expected = render_probe::washed(idleWitnessColours.at(index), 0.28);
                    QVERIFY2(render_probe::withinTolerance(painted, expected, 8),
                             qPrintable(QStringLiteral("focused: %1 witness at %2 painted %3, expected the idle "
                                                       "surface %4 washed to %5")
                                            .arg(witnesses.at(index).first).arg(QTest::toString(at))
                                            .arg(painted.name()).arg(idleWitnessColours.at(index).name())
                                            .arg(expected.name())));
                }
            }

            for (int index = 0; index < corners.size(); ++index) {
                QVERIFY(cornerHoldsBackdrop(capture, artRect, cornerNames[index], corners.at(index).first,
                                            corners.at(index).second));
            }

            // The check discriminates: a corner painted like the surface at its
            // own arc centre would not have passed. Idle, every fixture's
            // surface stands clear of the shadowed backdrop; focused, only the
            // artwork does, because the washed fallback and the corner under
            // the focused shadow are both within a few levels of black, so
            // the focused discrimination is carried by the real artwork rows.
            if (!focused || paintsArtwork) {
                for (int index = 0; index < corners.size(); ++index) {
                    const QColor painted = capture.image.pixelColor(corners.at(index).first);
                    const QColor surface = capture.image.pixelColor(witnesses.at(index).second);
                    QVERIFY2(!render_probe::withinTolerance(painted, surface, 8),
                             qPrintable(QStringLiteral("%1: the %2 corner at %3 is indistinguishable from its surface %4")
                                            .arg(QString::fromLatin1(state)).arg(QString::fromLatin1(cornerNames[index]))
                                            .arg(QTest::toString(corners.at(index).first)).arg(surface.name())));
                }
            }
        };

        // Ready to judge once the arc centres nearest and farthest along the
        // gradient both show the painted surface, so the fill alone does not
        // pass for the fallback.
        const auto surfacePainted = [&](const Capture &capture) {
            const QRect artRect = imageRectForItem(capture, art);
            if (artRect.isEmpty()) {
                return false;
            }
            const int radius = pixels(capture, 8);
            return isIdleSurface(capture, artRect, artRect.topLeft() + QPoint(radius, radius))
                && isIdleSurface(capture, artRect, artRect.topRight() + QPoint(-radius, radius));
        };
        const Capture idle = captureSettled(window, card, false, surfacePainted);
        QVERIFY2(idle.coherent() && surfacePainted(idle), "the poster surface was not painted");
        judgeSurface(idle, false);
        if (QTest::currentTestFailed()) {
            return;
        }

        focusFirstCard(window, view);
        const auto focusedPainted = [&](const Capture &capture) {
            const QRect artRect = imageRectForItem(capture, art);
            if (artRect.isEmpty() || !glowPaintedAbove(capture, art)) {
                return false;
            }
            const QPoint witness = artRect.topLeft() + QPoint(pixels(capture, 8), pixels(capture, 8));
            return render_probe::withinTolerance(capture.image.pixelColor(witness),
                                                 render_probe::washed(idleWitnessColours.at(0), 0.28), 8);
        };
        const Capture focused = captureSettled(window, card, true, focusedPainted);
        QVERIFY2(focused.coherent() && focusedPainted(focused), "the focused poster surface was not painted");
        judgeSurface(focused, true);
        if (QTest::currentTestFailed()) {
            return;
        }
        // The chrome outside the surface is intact: the glow still reaches
        // beside the artwork past its corners.
        const QRect focusedArt = imageRectForItem(focused, art);
        QVERIFY(countPixels(focused.image, stripBeside(focused, focusedArt, 2, 12, true), isAccentGlowPixel) > 0);
        QVERIFY(countPixels(focused.image, stripBeside(focused, focusedArt, 2, 12, false), isAccentGlowPixel) > 0);
    }

    // Under a one-point checker drawn at the focus scale every ring pixel
    // sits over a four-texel mixture. The model of two backdrop colours at a
    // time cannot predict it, which is recorded here as its counterexample,
    // while the rendered backdrop judges the whole band exactly.
    void focusRingBlendIsExactOverFourTexelMixtures()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        QTemporaryDir library;
        QVERIFY(writeMediaFile(library.path(), QStringLiteral("Arrival.2016.mkv")));
        QVERIFY(writeCheckerPosterFile(library.path(), QStringLiteral("Arrival.2016-poster.png")));

        ApplicationController controller;
        controller.setTemporaryLibraryRoot(library.path());
        controller.settings()->setLeanBackMode(false);
        QTRY_COMPARE(controller.library()->rowCount(), 1);

        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY2(window != nullptr, "qml/Main.qml did not load from the module");
        controller.navigation()->goHome();

        QQuickItem *view = nullptr;
        QTRY_VERIFY((view = grid(window)) != nullptr);
        QTRY_COMPARE(view->property("count").toInt(), 1);
        revealRow(window, view);
        auto *card = cardAt(view, 0);
        QVERIFY(card != nullptr);
        auto *art = artOf(card);
        QVERIFY(art != nullptr);
        QTRY_COMPARE(art->property("status").toInt(), 1); // Image.Ready

        window->show();
        const auto checkerPainted = [&](const Capture &capture) {
            const QRect artRect = imageRectForItem(capture, art);
            if (artRect.isEmpty()) {
                return false;
            }
            // Over any small block the checker's four colours average to a
            // mid grey, drawn crisp at ratio 1 or smoothly upscaled at ratio
            // 2; the fill and the fallback are far darker.
            int red = 0;
            int green = 0;
            int blue = 0;
            const QRect block(artRect.center() - QPoint(2, 2), QSize(4, 4));
            for (int y = block.top(); y <= block.bottom(); ++y) {
                for (int x = block.left(); x <= block.right(); ++x) {
                    const QColor pixel = capture.image.pixelColor(x, y);
                    red += pixel.red();
                    green += pixel.green();
                    blue += pixel.blue();
                }
            }
            const int count = block.width() * block.height();
            return red / count >= 40 && green / count >= 40 && blue / count >= 40;
        };
        const Capture idle = captureSettled(window, card, false, checkerPainted);
        QVERIFY2(idle.coherent() && checkerPainted(idle), "the checker poster was not painted");

        focusFirstCard(window, view);
        const auto ringPainted = [&](const Capture &capture) {
            return glowPaintedAbove(capture, art) && capture.items.contains(ringOf(card));
        };
        const Capture focused = captureSettled(window, card, true, ringPainted);
        QVERIFY2(focused.coherent() && ringPainted(focused), "the focus ring was not painted over the checker");

        // The two-colour model's counterexample, on record.
        const render_probe::StrokeBlendModel model = ringBlendModel(focused, card);
        const render_probe::StrokeBlendAudit pairwise =
            render_probe::auditStrokeBlend(focused.image, idle, ringPixels(focused, card), model);
        QVERIFY2(pairwise.mismatches > 0,
                 "the two-colour model unexpectedly predicted every four-texel mixture");

        verifyRingBlendedOverRenderedBackdrop(window, focused, idle, card, true, false);
    }

    // Marquee/Models/MediaItem.swift:191-192 names a title's container format
    // by its file extension, uppercased, and the projection must say the
    // same thing the details surface already says, whatever case the file
    // was named in.
    void libraryModelProjectsTheFormatBadgeAsTheDetailsSurfaceDoes()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        QTemporaryDir library;
        QVERIFY(writeMediaFile(library.path(), QStringLiteral("Arrival.2016.mkv")));
        QVERIFY(writeMediaFile(library.path(), QStringLiteral("Moon.2009.M4V")));

        ApplicationController controller;
        controller.setTemporaryLibraryRoot(library.path());
        QTRY_COMPARE(controller.library()->rowCount(), 2);

        const LibraryModel *model = controller.library();
        QCOMPARE(model->roleNames().value(LibraryModel::FormatBadgeRole), QByteArrayLiteral("formatBadge"));
        for (int row = 0; row < model->rowCount(); ++row) {
            const QModelIndex index = model->index(row, 0);
            const QString badge = model->data(index, LibraryModel::FormatBadgeRole).toString();
            const QString title = model->data(index, LibraryModel::TitleRole).toString();
            QCOMPARE(badge, title == QStringLiteral("Arrival") ? QStringLiteral("MKV") : QStringLiteral("M4V"));
            QCOMPARE(badge, model->detailsForId(idAt(model, row)).value(QStringLiteral("formatBadge")).toString());
        }
    }

    void movieFallbackNamesTheFormatBadge_data()
    {
        QTest::addColumn<QString>("artwork");
        QTest::addColumn<QString>("fileName");
        QTest::addColumn<QString>("badge");
        QTest::newRow("missing, mkv") << QStringLiteral("missing") << QStringLiteral("Arrival.2016.mkv") << QStringLiteral("MKV");
        QTest::newRow("transparent, mkv") << QStringLiteral("transparent") << QStringLiteral("Arrival.2016.mkv") << QStringLiteral("MKV");
        QTest::newRow("undecodable, mkv") << QStringLiteral("undecodable") << QStringLiteral("Arrival.2016.mkv") << QStringLiteral("MKV");
        QTest::newRow("missing, M4V") << QStringLiteral("missing") << QStringLiteral("Moon.2009.M4V") << QStringLiteral("M4V");
    }

    // Marquee/SharedViews/MovieCard.swift:13-18 hands the fallback artwork a
    // movie's format badge, and MovieCard.swift:327-337 draws it uppercase,
    // monospaced, in the secondary accent at 0.78, above the title at the
    // bottom-leading corner. A browse card whose artwork is missing,
    // transparent, or undecodable must show it, painted, whatever case the
    // file was named in; a card with real artwork keeps it beneath.
    void movieFallbackNamesTheFormatBadge()
    {
        QFETCH(QString, artwork);
        QFETCH(QString, fileName);
        QFETCH(QString, badge);

        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        QTemporaryDir library;
        QVERIFY(writeMediaFile(library.path(), fileName));
        const QString sidecar = QFileInfo(fileName).completeBaseName() + QStringLiteral("-poster.png");
        if (artwork == QStringLiteral("transparent")) {
            QVERIFY(writePosterFile(library.path(), sidecar, Qt::transparent));
        } else if (artwork == QStringLiteral("undecodable")) {
            QVERIFY(writeUndecodablePosterFile(library.path(), sidecar));
        }
        QVERIFY(writeMediaFile(library.path(), QStringLiteral("Dune.2021.mkv")));
        QVERIFY(writePosterFile(library.path(), QStringLiteral("Dune.2021-poster.png"), QColor("#00c800")));

        ApplicationController controller;
        controller.setTemporaryLibraryRoot(library.path());
        controller.settings()->setLeanBackMode(false);
        QTRY_COMPARE(controller.library()->rowCount(), 2);

        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY2(window != nullptr, "qml/Main.qml did not load from the module");
        controller.navigation()->goHome();
        QVERIFY(QTest::qWaitForWindowExposed(window));

        QQuickItem *view = nullptr;
        QTRY_VERIFY((view = grid(window)) != nullptr);
        QTRY_COMPARE(view->property("count").toInt(), 2);
        revealRow(window, view);
        const int fallbackRow = rowForTitle(controller.library(), QFileInfo(fileName).completeBaseName().section(QLatin1Char('.'), 0, 0));
        const int artworkRow = rowForTitle(controller.library(), QStringLiteral("Dune"));
        QVERIFY(fallbackRow >= 0);
        QVERIFY(artworkRow >= 0);
        QQuickItem *fallbackCard = cardAt(view, fallbackRow);
        QQuickItem *artworkCard = cardAt(view, artworkRow);
        QVERIFY(fallbackCard != nullptr);
        QVERIFY(artworkCard != nullptr);

        // The binding, on both cards.
        QCOMPARE(fallbackCard->property("formatBadge").toString(), badge);
        QCOMPARE(artworkCard->property("formatBadge").toString(), QStringLiteral("MKV"));
        auto *badgeText = fallbackOf(fallbackCard)->findChild<QQuickItem *>(QStringLiteral("posterFallbackBadge"));
        QVERIFY(badgeText != nullptr);
        QCOMPARE(badgeText->property("text").toString(), badge);
        QVERIFY(badgeText->isVisible());
        QQuickItem *art = artOf(fallbackCard);
        QVERIFY(art != nullptr);
        if (artwork == QStringLiteral("transparent")) {
            QTRY_COMPARE(art->property("status").toInt(), 1); // Image.Ready
        } else {
            QTRY_COMPARE(art->property("source").toUrl(), QUrl());
        }
        QTRY_COMPARE(artOf(artworkCard)->property("status").toInt(), 1);
        window->show();

        // Painted: the badge's accent (#c9a84c at 0.78 over the dark fallback)
        // is the only warm colour on the surface, and it sits inside the
        // badge text's own rectangle at the bottom-leading corner; the card
        // with real artwork paints nothing warm there because the artwork
        // covers it.
        const auto isBadgeInk = [](const QColor &pixel) {
            return pixel.red() > 120 && pixel.green() > 95 && pixel.blue() < 90 && pixel.red() > pixel.blue() + 60;
        };
        const auto badgePainted = [&](const Capture &capture) {
            const QRect badgeRect = imageRectForItem(capture, badgeText);
            return !badgeRect.isEmpty() && countPixels(capture.image, badgeRect, isBadgeInk) > 0;
        };
        const Capture idle = captureWindowUntil(window, {fallbackCard, art, badgeText, artOf(artworkCard)}, badgePainted);
        QVERIFY2(idle.coherent() && badgePainted(idle),
                 qPrintable(QStringLiteral("the %1 badge was not painted on the %2 fallback").arg(badge).arg(artwork)));
        const QRect badgeRect = imageRectForItem(idle, badgeText);
        const QRect artRect = imageRectForItem(idle, art);
        QVERIFY(artRect.contains(badgeRect));
        QVERIFY(badgeRect.left() >= artRect.left() + pixels(idle, 12));
        QVERIFY(badgeRect.bottom() < artRect.bottom() - pixels(idle, 12));
        // Nothing warm anywhere on the artwork card's surface.
        const QRect artworkRect = imageRectForItem(idle, artOf(artworkCard));
        QVERIFY(!artworkRect.isEmpty());
        QCOMPARE(countPixels(idle.image, artworkRect, isBadgeInk), 0);
    }

    // Marquee/SharedViews/MovieCard.swift:226-247 washes a focused poster with
    // black at 0.28 and centres a 44/64-point chevron badge on it.
    void focusedPosterDimsItsArtworkBehindAChevronBadge()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        QTemporaryDir library;
        QVERIFY(writeMediaFile(library.path(), QStringLiteral("Arrival.2016.mkv")));
        QVERIFY(writePosterFile(library.path(),
                                QStringLiteral("Arrival.2016-poster.png"),
                                QColor("#00c800")));

        ApplicationController controller;
        controller.setTemporaryLibraryRoot(library.path());
        controller.settings()->setLeanBackMode(false);
        QTRY_COMPARE(controller.library()->rowCount(), 1);

        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY2(window != nullptr, "qml/Main.qml did not load from the module");
        controller.navigation()->goHome();

        QQuickItem *view = nullptr;
        QTRY_VERIFY((view = grid(window)) != nullptr);
        QTRY_COMPARE(view->property("count").toInt(), 1);
        revealRow(window, view);
        auto *card = cardAt(view, 0);
        QVERIFY(card != nullptr);
        auto *art = artOf(card);
        auto *scrim = card->findChild<QQuickItem *>(QStringLiteral("posterFocusScrim"));
        auto *badge = card->findChild<QQuickItem *>(QStringLiteral("posterFocusBadge"));
        QVERIFY(art != nullptr);
        QVERIFY(scrim != nullptr);
        QVERIFY(badge != nullptr);
        QTRY_COMPARE(art->property("status").toInt(), 1); // Image.Ready
        QVERIFY(!scrim->isVisible());
        QVERIFY(!badge->isVisible());

        window->show();
        focusFirstCard(window, view);
        QTRY_VERIFY(scrim->isVisible());
        QVERIFY(badge->isVisible());
        QCOMPARE(scrim->property("color").value<QColor>(), QColor::fromRgbF(0, 0, 0, 0.28f));
        QCOMPARE(badge->width(), 44.0);
        QCOMPARE(badge->height(), 44.0);
        QCOMPARE(badge->property("radius").toReal(), 22.0);
        QCOMPARE(badge->property("color").value<QColor>(), QColor::fromRgbF(0, 0, 0, 0.52f));
        // Anchors centre to whole pixels.
        const QPointF badgeCentre =
            badge->mapToItem(art, QPointF(badge->width() / 2, badge->height() / 2));
        QVERIFY(std::abs(badgeCentre.x() - art->width() / 2) <= 0.75);
        QVERIFY(std::abs(badgeCentre.y() - art->height() / 2) <= 0.75);

        // #00c800 under a 0.28 black wash is (0, 144, 0); under the badge's
        // further 0.52 wash it is (0, 69, 0).
        const auto isWashed = [](const QColor &pixel) {
            return pixel.red() < 12 && std::abs(pixel.green() - 144) <= 8 && pixel.blue() < 12;
        };
        const auto isBadged = [](const QColor &pixel) {
            return pixel.red() < 12 && std::abs(pixel.green() - 69) <= 8 && pixel.blue() < 12;
        };
        const auto focusWashPainted = [&](const Capture &capture) {
            const QRect artRect = imageRectForItem(capture, art);
            if (artRect.isEmpty()) {
                return false;
            }
            const QPoint corner = artRect.topLeft() + QPoint(pixels(capture, 16), pixels(capture, 16));
            const QPoint besideChevron = artRect.center() - QPoint(pixels(capture, 12), 0);
            return isWashed(capture.image.pixelColor(corner))
                && isBadged(capture.image.pixelColor(besideChevron));
        };
        const Capture focused = captureSettled(window, card, true, focusWashPainted);
        QVERIFY2(focused.coherent() && focusWashPainted(focused),
                 "the focused poster was not washed behind its chevron badge");

        controller.settings()->setLeanBackMode(true);
        card = cardAt(view, 0);
        QVERIFY(card != nullptr);
        badge = card->findChild<QQuickItem *>(QStringLiteral("posterFocusBadge"));
        QVERIFY(badge != nullptr);
        QTRY_COMPARE(badge->width(), 64.0);
    }

    void pointerHoverBrightensOnlyTheCardWithoutTakingKeyboardFocus_data()
    {
        QTest::addColumn<bool>("leanBack");
        QTest::addColumn<bool>("reduceMotion");
        QTest::newRow("compact, animated") << false << false;
        QTest::newRow("compact, reduced motion") << false << true;
        QTest::newRow("lean-back, animated") << true << false;
        QTest::newRow("lean-back, reduced motion") << true << true;
    }

    void pointerHoverBrightensOnlyTheCardWithoutTakingKeyboardFocus()
    {
        QFETCH(bool, leanBack);
        QFETCH(bool, reduceMotion);
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
        QTemporaryDir library;
        QVERIFY(writeMediaFile(library.path(), QStringLiteral("Arrival.2016.mkv")));
        QVERIFY(writePosterFile(library.path(), QStringLiteral("Arrival.2016-poster.png"), QColor("#00c800")));
        QVERIFY(writeMediaFile(library.path(), QStringLiteral("Moon.2009.mkv")));

        ApplicationController controller;
        controller.settings()->setLeanBackMode(leanBack);
        controller.settings()->setReduceMotion(reduceMotion);
        controller.setTemporaryLibraryRoot(library.path());
        QTRY_COMPARE(controller.library()->rowCount(), 2);
        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY(window != nullptr);
        controller.navigation()->goHome();
        QVERIFY(QTest::qWaitForWindowExposed(window));
        const QPoint outside(90, 20);
        QTest::mouseMove(window, outside);
        const auto parkPointer = qScopeGuard([&] { QTest::mouseMove(window, outside); });
        QQuickItem *view = nullptr;
        QTRY_VERIFY((view = grid(window)) != nullptr);
        QTRY_COMPARE(view->property("count").toInt(), 2);
        revealRow(window, view);
        auto *sidebar = window->findChild<QQuickItem *>(QStringLiteral("sidebar"));
        QVERIFY(sidebar != nullptr);

        // MovieCard.swift:134-146 includes the caption in hover, but its
        // surrounding row halo is not part of the button's content shape.
        for (int row = 0; row < 2; ++row) {
            sidebar->forceActiveFocus();
            auto *card = cardAt(view, row);
            QVERIFY(card != nullptr);
            auto *art = artOf(card);
            auto *title = card->findChild<QQuickItem *>(QStringLiteral("posterTitle"));
            auto *caption = card->findChild<QQuickItem *>(QStringLiteral("posterCaption"));
            auto *badge = card->findChild<QQuickItem *>(QStringLiteral("posterFocusBadge"));
            QVERIFY(art != nullptr && title != nullptr && caption != nullptr && badge != nullptr);
            const QList<QQuickItem *> measured{art, title, frameOf(card), chromeOf(card)};
            const auto sample = [&](const Capture &capture) {
                const QRect rect = imageRectForItem(capture, art);
                return rect.topLeft() + QPoint(pixels(capture, 20), pixels(capture, 20));
            };
            const Capture idle = captureWindowUntil(window, measured, [&](const Capture &capture) {
                if (!cardSettled(capture, card, false)) {
                    return false;
                }
                const QColor colour = capture.image.pixelColor(sample(capture));
                return row == 0 ? colour == QColor("#00c800")
                                : colour != QColor("#1a1525") && colour != QColor("#0d0b1a");
            });
            QVERIFY(idle.coherent() && cardSettled(idle, card, false));
            const QColor idleColour = idle.image.pixelColor(sample(idle));
            QVERIFY(row == 0 ? idleColour == QColor("#00c800")
                             : idleColour != QColor("#1a1525") && idleColour != QColor("#0d0b1a"));
            const QColor hoverColour = render_probe::sourceOverOn(idleColour, Qt::white, 0.045);
            const auto hoverPainted = [&](const Capture &capture) {
                return cardSettled(capture, card, false)
                    && capture.geometryOf(art) == idle.geometryOf(art)
                    && render_probe::withinTolerance(capture.image.pixelColor(sample(capture)), hoverColour, 2);
            };
            const QPoint overArt = art->mapToScene(QPointF(art->width() / 2, art->height() / 2)).toPoint();
            QTest::mouseMove(window, overArt);
            QTRY_COMPARE(title->property("color").value<QColor>(), QColor("#f5f0eb"));
            const Capture hovered = captureWindowUntil(window, measured, hoverPainted);
            QVERIFY2(hovered.coherent() && hoverPainted(hovered), "hover did not paint the released white 0.045 wash");
            QVERIFY(idle.sameGeometryAs(hovered));
            QVERIFY(sidebar->hasActiveFocus());
            QCOMPARE(currentIndexOf(view), 0);
            QCOMPARE(frameOf(card)->scale(), 1.0);
            QVERIFY(!ringOf(card)->isVisible());
            QVERIFY(!badge->isVisible());
            QCOMPARE(render_probe::changedPixels(idle, hovered, imageRectForItem(idle, title)) > 0, true);

            // The added layer must not square off any of the rounded corners.
            const QRect artRect = imageRectForItem(idle, art);
            for (const QPoint &corner : {artRect.topLeft(), artRect.topRight(), artRect.bottomLeft(), artRect.bottomRight()}) {
                QVERIFY(render_probe::withinTolerance(hovered.image.pixelColor(corner), idle.image.pixelColor(corner), 2));
            }
            auto *scrim = card->findChild<QQuickItem *>(QStringLiteral("posterHoverScrim"));
            QVERIFY(scrim != nullptr);
            QTRY_COMPARE(scrim->opacity(), 0.045);
            auto *animation = scrim->findChild<QObject *>(QStringLiteral("posterHoverAnimation"));
            if (!reduceMotion) {
                QVERIFY(animation != nullptr);
                QCOMPARE(animation->property("duration").toInt(), 250);
            }
            QTest::mouseMove(window, caption->mapToScene(QPointF(caption->width() / 2, caption->height() / 2)).toPoint());
            QCOMPARE(title->property("color").value<QColor>(), QColor("#f5f0eb"));
            QCOMPARE(scrim->opacity(), 0.045);

            // Leaving into reserved halo space restores idle. Reduce Motion
            // reaches the target in this delivery, not after a timed wait.
            QTest::mouseMove(window, card->mapToScene(QPointF(card->width() / 2, 2)).toPoint());
            if (reduceMotion) {
                QCOMPARE(scrim->opacity(), 0.0);
            }
            QTRY_COMPARE(scrim->opacity(), 0.0);
            QCOMPARE(title->property("color").value<QColor>(), QColor("#9b8fb0"));
            const Capture left = captureWindowUntil(window, measured, [&](const Capture &capture) {
                return capture.geometryOf(art) == idle.geometryOf(art)
                    && render_probe::withinTolerance(capture.image.pixelColor(sample(capture)), idleColour, 2);
            });
            QVERIFY(left.coherent());
            QCOMPARE(render_probe::changedPixels(idle, left, artRect, 2), 0);

            // Hover another card while the keyboard selection stays on row 0,
            // then move that selection onto this card. Focus wins immediately,
            // even if a hover fade is still running.
            focusFirstCard(window, view);
            QTest::mouseMove(window, overArt);
            if (row == 1) {
                QCOMPARE(currentIndexOf(view), 0);
                QVERIFY(!card->property("selected").toBool());
                QTest::keyClick(window, Qt::Key_Right);
            }
            QCOMPARE(currentIndexOf(view), row);
            QVERIFY(card->property("selected").toBool());
            QVERIFY(!scrim->isVisible());
            QVERIFY(badge->isVisible());
            QTRY_COMPARE(frameOf(card)->scale(), 1.045);
            const auto focusPainted = [&](const Capture &capture) {
                return cardSettled(capture, card, true)
                    && render_probe::withinTolerance(capture.image.pixelColor(sample(capture)),
                                                     render_probe::washed(idleColour, 0.28), 3);
            };
            const Capture focused = captureWindowUntil(window, measured, focusPainted);
            QVERIFY(focused.coherent() && focusPainted(focused));
            QVERIFY(ringOf(card)->isVisible());
            QTest::mouseMove(window, outside);
            QVERIFY(card->property("selected").toBool());
            QVERIFY(badge->isVisible());
            QCOMPARE(title->property("color").value<QColor>(), QColor("#f5f0eb"));
            // Restore the starting identity before the next fixture card.
            setCurrentIndex(view, 0);
        }
    }

    void boundaryModes_data()
    {
        QTest::addColumn<bool>("leanBack");
        QTest::newRow("compact") << false;
        QTest::newRow("lean-back") << true;
    }

    void focusedFirstColumnCardPaintsItsHaloIntoTheOuterPadding_data() { boundaryModes_data(); }

    // Marquee/SharedViews/ArrowedScrollRow.swift:75-87 widens the row's
    // scroll view by the halo padding on both sides and starts its content a
    // halo padding in, so a first-column card's chrome paints into the page's
    // outer padding instead of being cut at the row boundary, while the pitch
    // and the vertical halo room are unchanged.
    void focusedFirstColumnCardPaintsItsHaloIntoTheOuterPadding()
    {
        QFETCH(bool, leanBack);

        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        QTemporaryDir library;
        for (const QString &name : sampleTitles()) {
            QVERIFY(writeMediaFile(library.path(), name));
        }

        ApplicationController controller;
        controller.setTemporaryLibraryRoot(library.path());
        QQmlApplicationEngine engine;
        BoundaryScene scene;
        prepareBoundaryScene(leanBack, controller, engine, scene);
        if (QTest::currentTestFailed() || scene.unsupported) {
            return;
        }
        QQuickWindow *window = scene.window;
        const auto firstCard = [&] { return cardAt(scene.view, 0); };
        const auto firstArt = [&] { return artOf(firstCard()); };

        CapturePair pair;
        captureIdleAndFocused(
            scene, firstCard,
            [&] {
                focusFirstCard(window, scene.view);
                QCOMPARE(currentIndexOf(scene.view), 0);
            },
            [&](const Capture &capture) {
                return artworkPainted(capture, firstArt()) && !glowPaintedAbove(capture, firstArt());
            },
            [&](const Capture &capture) { return glowPaintedAbove(capture, firstArt()); },
            pair);
        if (QTest::currentTestFailed()) {
            return;
        }
        const Capture &idle = pair.idle;
        const Capture &focused = pair.focused;
        QQuickItem *art = firstArt();
        QVERIFY(art != nullptr);

        const QRect artRect = imageRectForItem(focused, art);
        QVERIFY(!artRect.isEmpty());
        QVERIFY2(countPixels(focused.image, stripBeside(focused, artRect, 2, 12, true),
                             isAccentGlowPixel) > 0,
                 "the first column's glow was cut at the grid's left boundary");
        const QRect outerStrip = stripBeside(focused, artRect, 12, scene.halo - 4, true);
        const int outerChanged = render_probe::changedPixels(idle, focused, outerStrip);
        QVERIFY2(outerChanged > 0,
                 qPrintable(QStringLiteral("the first column's halo did not reach into the outer "
                                           "padding: %1 changed pixels in %2")
                                .arg(outerChanged).arg(QTest::toString(outerStrip))));

        // The chrome stops at the widened viewport: the gutter between the
        // sidebar and the viewport does not change when a card takes focus.
        const QRect sidebarRect = imageRectForItem(focused, scene.sidebar);
        const QRect viewportRect = imageRectForItem(focused, scene.viewport);
        QVERIFY(!sidebarRect.isEmpty());
        QVERIFY(!viewportRect.isEmpty());
        QVERIFY(viewportRect.left() > sidebarRect.right());
        const QRect gutter(sidebarRect.right() + 1, viewportRect.top(),
                           viewportRect.left() - sidebarRect.right() - 1,
                           viewportRect.height());
        QVERIFY(gutter.width() > 0);
        QCOMPARE(render_probe::changedPixels(idle, focused, gutter), 0);

        // HomeDetailView.swift:198-247 scrolls the surface beneath the sticky
        // title bar rather than beside a heading, and :201 opens its content
        // 120/170 points down, so the bar's own band is clear of the first
        // row's halo and nothing a focused card paints reaches it.
        const QRect titleBarRect = imageRectForItem(focused, scene.titleBar);
        QVERIFY(!titleBarRect.isEmpty());
        const QRect titleBarBand(sidebarRect.right() + 1, 0,
                                 focused.image.width() - sidebarRect.right() - 1,
                                 titleBarRect.bottom() + 1);
        QVERIFY(titleBarBand.height() > 0);
        QCOMPARE(render_probe::changedPixels(idle, focused, titleBarBand), 0);
    }

    void homeBottomFadeMixesTheScrolledRowsIntoThePageBackground_data() { boundaryModes_data(); }

    // HomeDetailView.swift:246 draws BottomFadeView.swift:14-24 over the
    // scrolled surface: an 80-point band running from nothing to the page's
    // own background. Home is a stack of rows that scrolls beneath it, so the
    // page is put where the All Movies cards run under the band, and the band
    // must be its own mixture of those cards and the background rather than
    // an empty strip or an opaque cover.
    void homeBottomFadeMixesTheScrolledRowsIntoThePageBackground()
    {
        QFETCH(bool, leanBack);

        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        QTemporaryDir library;
        for (const QString &name : sampleTitles()) {
            QVERIFY(writeMediaFile(library.path(), name));
        }

        ApplicationController controller;
        controller.setTemporaryLibraryRoot(library.path());
        QQmlApplicationEngine engine;
        BoundaryScene scene;
        prepareBoundaryScene(leanBack, controller, engine, scene);
        if (QTest::currentTestFailed() || scene.unsupported) {
            return;
        }
        QQuickWindow *window = scene.window;
        QQuickItem *scroll = scrollOf(window);
        QVERIFY(scroll != nullptr);

        // Put the row's posters a hundred points above the band's top edge, so
        // their lower part runs under all of it while their upper part is
        // still plain artwork. The page is moved the way a wheel would move
        // it; the remote stays where it is.
        const QRectF fadeInWindow =
            scene.bottomFade->mapRectToItem(window->contentItem(), scene.bottomFade->boundingRect());
        QQuickItem *firstArt = artOf(cardAt(scene.view, 0));
        QVERIFY(firstArt != nullptr);
        const auto artTop = [&] {
            return firstArt->mapToItem(window->contentItem(), QPointF(0, 0)).y();
        };
        const qreal wanted = fadeInWindow.top() - 100;
        scroll->setProperty("contentY", scroll->property("contentY").toReal() + artTop() - wanted);
        QTRY_VERIFY(qAbs(artTop() - wanted) < 1.0);

        const QList<QQuickItem *> arts = realisedArtwork(scene.view);
        QVERIFY(!arts.isEmpty());
        QList<QQuickItem *> items = measuredItems(scene, cardAt(scene.view, 0));
        for (QQuickItem *art : arts) {
            if (!items.contains(art)) {
                items.append(art);
            }
        }
        // The sticky title bar is opaque, so a poster scrolled under it shows
        // the bar and not its own artwork: only the posters clear of the bar
        // can say whether the grid has painted.
        const qreal barBottom =
            scene.titleBar->mapRectToItem(window->contentItem(), scene.titleBar->boundingRect())
                .bottom();
        QList<QQuickItem *> visibleArts;
        for (QQuickItem *art : arts) {
            if (art->mapToItem(window->contentItem(), QPointF(0, 0)).y() >= barBottom) {
                visibleArts.append(art);
            }
        }
        QVERIFY(!visibleArts.isEmpty());
        const auto gridPainted = [&](const Capture &capture) {
            return gridArtworkPainted(capture, visibleArts);
        };
        const SceneGeometry before = sceneGeometry(scene, cardAt(scene.view, 0));
        const Capture faded = captureWindowUntil(window, items, [&](const Capture &capture) {
            return gridPainted(capture);
        });
        QVERIFY(faded.coherent());
        QVERIFY(gridPainted(faded));
        QCOMPARE(sceneGeometry(scene, cardAt(scene.view, 0)), before);

        const QRect fadeRect = imageRectForItem(faded, scene.bottomFade);
        const QRect viewRect = imageRectForItem(faded, scene.view);
        QVERIFY(!fadeRect.isEmpty());
        QVERIFY(!viewRect.isEmpty());
        QCOMPARE(fadeRect.bottom(), faded.image.height() - 1);
        QVERIFY2(viewRect.top() < fadeRect.bottom() && viewRect.bottom() >= fadeRect.top(),
                 "the All Movies row must reach under the bottom fade");

        const Capture withoutFade =
            captureWithoutFade(window, scene.bottomFade, items, faded, gridPainted);
        QVERIFY(withoutFade.coherent());
        QVERIFY2(gridPainted(withoutFade),
                 "the frame taken without the band did not show the painted rows");
        QVERIFY2(contentPixelsUnderBand(withoutFade, fadeRect) > 0,
                 "the fixture painted nothing under the bottom fade");
        verifyBottomFadeMixesTheSurfaceIntoTheBackground(faded, withoutFade, scene.bottomFade,
                                                         true);
    }

    // A platform can re-configure the window between the two grabs of a
    // before/after comparison. Such a pair is retaken as a whole, not compared
    // as if both buffers showed the same layout.
    void captureGeometryChangedBetweenIdleAndFocusedIsRetakenNotCompared()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        QTemporaryDir library;
        for (const QString &name : sampleTitles()) {
            QVERIFY(writeMediaFile(library.path(), name));
        }

        ApplicationController controller;
        controller.setTemporaryLibraryRoot(library.path());
        QQmlApplicationEngine engine;
        BoundaryScene scene;
        prepareBoundaryScene(false, controller, engine, scene);
        if (QTest::currentTestFailed() || scene.unsupported) {
            return;
        }
        QQuickWindow *window = scene.window;
        const auto firstCard = [&] { return cardAt(scene.view, 0); };
        const auto firstArt = [&] { return artOf(firstCard()); };
        const int narrowerWidth = window->width() - scene.cellWidth;
        QVERIFY(narrowerWidth >= window->minimumWidth());

        int focusCalls = 0;
        CapturePair pair;
        captureIdleAndFocused(
            scene, firstCard,
            [&] {
                ++focusCalls;
                QTest::keyClick(window, Qt::Key_Right);
                QTRY_VERIFY(contentHasFocus(window));
                if (focusCalls == 1) {
                    // The window is granted a narrower size after the idle grab.
                    window->resize(narrowerWidth, window->height());
                    QTRY_COMPARE(window->width(), narrowerWidth);
                }
            },
            [&](const Capture &capture) {
                return artworkPainted(capture, firstArt()) && !glowPaintedAbove(capture, firstArt());
            },
            [&](const Capture &capture) { return glowPaintedAbove(capture, firstArt()); },
            pair);
        if (QTest::currentTestFailed()) {
            return;
        }

        QCOMPARE(focusCalls, 2);
        QCOMPARE(pair.attempts, 2);
        QVERIFY(pair.idle.coherent());
        QVERIFY(pair.focused.coherent());
        QVERIFY(pair.idle.sameGeometryAs(pair.focused));
        QCOMPARE(pair.geometry.logicalSize, QSize(narrowerWidth, window->height()));
        QCOMPARE(pair.geometry, sceneGeometry(scene, firstCard()));
        QCOMPARE(pair.idle.logicalSize, window->size());

        // Only like captures are ever subtracted.
        Capture wider = pair.idle;
        wider.logicalSize = QSize(wider.logicalSize.width() + scene.cellWidth,
                                  wider.logicalSize.height());
        QVERIFY(!wider.coherent());
        QCOMPARE(render_probe::changedPixels(wider, pair.focused, pair.focused.image.rect()), -1);
    }

    // Marquee/Theme/ViewModifiers/CardHoverModifier.swift:50 and
    // Marquee/Theme/MarqueeTheme.swift:252 grow a focused poster to 1.045
    // over a quarter-second spring while the chrome paints at once. How far
    // the spring has run by the time a grab lands depends on the platform's
    // frame pacing, so the unsettled state is held on purpose: the spring is
    // stretched so far that the frame cannot reach its focused size within
    // this test, a capture of that frame must be refused, and once the
    // spring is its normal length again the settled frame is accepted at
    // 1.045.
    void focusedCaptureIsTakenAtTheSelectedCardsSettledScale()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        QTemporaryDir library;
        for (const QString &name : sampleTitles()) {
            QVERIFY(writeMediaFile(library.path(), name));
        }

        ApplicationController controller;
        controller.setTemporaryLibraryRoot(library.path());
        QQmlApplicationEngine engine;
        BoundaryScene scene;
        prepareBoundaryScene(true, controller, engine, scene);
        if (QTest::currentTestFailed() || scene.unsupported) {
            return;
        }
        QQuickWindow *window = scene.window;
        const auto lastCard = [&] { return cardAt(scene.view, scene.columns - 1); };
        const auto lastArt = [&] { return artOf(lastCard()); };
        const QList<QQuickItem *> measured{lastCard(), lastArt(), frameOf(lastCard()),
                                           chromeOf(lastCard())};
        const auto focusLastCard = [&] {
            focusFirstCard(window, scene.view);
            for (int step = 0; step < scene.columns - 1; ++step) {
                QTest::keyClick(window, Qt::Key_Right);
            }
            QCOMPARE(currentIndexOf(scene.view), scene.columns - 1);
        };
        const auto glowAboveLastArt = [&](const Capture &capture) {
            return glowPaintedAbove(capture, lastArt());
        };

        // The first focus creates the spring and runs it out normally.
        focusLastCard();
        if (QTest::currentTestFailed()) {
            return;
        }
        const Capture first = captureSettled(window, lastCard(), true, glowAboveLastArt);
        QVERIFY(first.coherent());
        QCOMPARE(first.geometryOf(frameOf(lastCard())).scale, 1.045);
        QObject *spring = scaleAnimationOf(lastCard());
        QVERIFY2(spring != nullptr, "the poster frame's scale spring was not found");
        const int springDuration = spring->property("duration").toInt();
        QCOMPARE(springDuration, 250);

        scene.sidebar->forceActiveFocus();
        QTRY_VERIFY(!contentHasFocus(scene.window));
        const Capture backToIdle = captureSettled(window, lastCard(), false, [&](const Capture &capture) {
            return artworkPainted(capture, lastArt()) && !glowPaintedAbove(capture, lastArt());
        });
        QVERIFY(backToIdle.coherent());
        QCOMPARE(backToIdle.geometryOf(frameOf(lastCard())).scale, 1.0);

        // Held part way: with the spring stretched to ten minutes, the frame
        // is larger than idle at most and never at its focused size, and no
        // grab of it counts as the focused state.
        spring->setProperty("duration", 600000);
        focusLastCard();
        if (QTest::currentTestFailed()) {
            return;
        }
        QVERIFY2(spring->property("running").toBool(),
                 "focusing the card did not start its scale spring");
        const Capture held = render_probe::captureWindow(window, measured);
        QVERIFY(held.coherent());
        const qreal heldScale = held.geometryOf(frameOf(lastCard())).scale;
        QVERIFY2(heldScale >= 1.0 && heldScale < 1.045,
                 qPrintable(QStringLiteral("the stretched spring left the frame at %1").arg(heldScale)));
        QVERIFY(refusedAsUnsettled(held, lastCard()));
        // A bound on a negative: while the spring is held, readiness never
        // arrives, so this wait can only run out, and what it returns must
        // still be a real measured frame of the held card.
        bool ready = true;
        const Capture refused = captureWindowUntil(window, measured, [&](const Capture &capture) {
            return cardSettled(capture, lastCard(), true);
        }, 300, &ready);
        QVERIFY2(!ready, "readiness was reported while the spring was held");
        QVERIFY(refusedAsUnsettled(refused, lastCard()));
        QVERIFY(refused.items.contains(lastArt()));

        // With its normal length restored, the next spring settles.
        spring->setProperty("duration", springDuration);
        CapturePair pair;
        captureIdleAndFocused(
            scene, lastCard,
            [&] {
                // The sidebar hand-off keeps the column the row last held.
                QTest::keyClick(window, Qt::Key_Right);
                QTRY_VERIFY(contentHasFocus(window));
                QCOMPARE(currentIndexOf(scene.view), scene.columns - 1);
            },
            [&](const Capture &capture) {
                return artworkPainted(capture, lastArt()) && !glowPaintedAbove(capture, lastArt());
            },
            [&](const Capture &capture) { return glowPaintedAbove(capture, lastArt()); },
            pair);
        if (QTest::currentTestFailed()) {
            return;
        }

        QQuickItem *frame = frameOf(lastCard());
        QVERIFY(frame != nullptr);
        QCOMPARE(pair.idle.geometryOf(frame).scale, 1.0);
        QCOMPARE(pair.focused.geometryOf(frame).scale, 1.045);
        QCOMPARE(frame->scale(), 1.045);
        QCOMPARE(pair.focused.geometryOf(lastArt()).sceneRect.width(), 225 * 1.045);
        const QRect artRect = imageRectForItem(pair.focused, lastArt());
        // The measured rectangles are the grabbed frame's: the artwork stands
        // past its unscaled frame by the settled growth on each side, and the
        // idle grab's artwork does not.
        const QRectF focusedArt = pair.focused.geometryOf(lastArt()).sceneRect;
        const QRectF focusedFrame = pair.focused.geometryOf(chromeOf(lastCard())).sceneRect;
        const QRectF idleArt = pair.idle.geometryOf(lastArt()).sceneRect;
        const qreal growth = 225 * (1.045 - 1.0) / 2;
        QCOMPARE(focusedArt.right() - focusedFrame.right(), growth);
        QCOMPARE(focusedFrame.left() - focusedArt.left(), growth);
        QCOMPARE(idleArt, focusedFrame);
        QVERIFY(pair.focused.image.pixelColor(artRect.center()) != QColor("#0d0b1a"));
    }

    // The idle and focused grabs of a boundary comparison are compared over
    // the whole window, so readiness has to speak for every poster the grid
    // painted into them, not only for the card taking focus. Qt's Canvas
    // paints asynchronously (PosterArt.qml:138-164), so a delegate whose
    // gradient has not landed still shows PosterArt.qml:110's bare elevated
    // plate, and a grab taken then is one card's idle state beside another
    // card's unpainted one. That state is reproduced here exactly rather than
    // waited for: the gradient of a poster the focused card never touches is
    // hidden, which leaves the plate the unpainted canvas leaves. Readiness
    // must refuse that capture while the check that samples one centre pixel
    // of the focused card still accepts it, and no empty, unmeasured, or
    // default-geometry capture may satisfy it either.
    void idleReadinessRefusesACaptureWhoseOtherPostersHaveNotPainted()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        QTemporaryDir library;
        for (const QString &name : sampleTitles()) {
            QVERIFY(writeMediaFile(library.path(), name));
        }

        ApplicationController controller;
        controller.setTemporaryLibraryRoot(library.path());
        QQmlApplicationEngine engine;
        BoundaryScene scene;
        prepareBoundaryScene(true, controller, engine, scene);
        if (QTest::currentTestFailed() || scene.unsupported) {
            return;
        }
        QQuickWindow *window = scene.window;
        QQuickItem *lastCard = cardAt(scene.view, scene.columns - 1);
        QQuickItem *lastArt = artOf(lastCard);
        QVERIFY(lastCard != nullptr);
        QVERIFY(lastArt != nullptr);

        const QList<QQuickItem *> arts = realisedArtwork(scene.view);
        QVERIFY2(arts.size() > scene.columns,
                 qPrintable(QStringLiteral("the fixture realised only %1 posters, so no second "
                                           "row stands beside the %2 in the first")
                                .arg(arts.size()).arg(scene.columns)));
        QVERIFY(arts.contains(lastArt));

        // The second row's poster: it is the one the failing band comparison
        // reads and the focused card never touches it. Its fallback gradient
        // hangs off the card rather than off the artwork item, which is the
        // image layer stacked over it.
        QQuickItem *otherCard = cardAt(scene.view, scene.columns);
        QVERIFY(otherCard != nullptr);
        QQuickItem *otherArt = artOf(otherCard);
        QVERIFY(otherArt != nullptr);
        QVERIFY(otherArt != lastArt);
        QCOMPARE(arts.at(scene.columns), otherArt);
        QQuickItem *otherGradient =
            otherCard->findChild<QQuickItem *>(QStringLiteral("posterFallbackGradient"));
        QVERIFY2(otherGradient != nullptr, "the second row's poster has no fallback gradient");

        // The grid as the product paints it: readiness holds, and every judged
        // poster's ramp stands clear of the threshold rather than grazing it.
        const Capture painted = captureWindowUntil(window, arts, [&](const Capture &capture) {
            return gridArtworkPainted(capture, arts);
        });
        QVERIFY2(gridArtworkPainted(painted, arts),
                 "the settled grid was refused, so this check cannot tell painted from unpainted");
        int judged = 0;
        for (QQuickItem *art : arts) {
            const int spread = paintedRowSpread(painted, art);
            if (spread < 0) {
                continue;
            }
            ++judged;
            QVERIFY2(spread >= minimumPaintedRowSpread + 2,
                     qPrintable(QStringLiteral("a painted poster's widest row spread is %1, "
                                               "against a threshold of %2")
                                    .arg(spread).arg(minimumPaintedRowSpread)));
        }
        QVERIFY2(judged >= 2, "fewer than two posters could be judged in the fixture");

        // One poster left showing the bare plate. Nothing else moves.
        otherGradient->setVisible(false);
        const auto restoreGradient = qScopeGuard([otherGradient] { otherGradient->setVisible(true); });
        bool ready = true;
        const Capture unpainted = captureWindowUntil(window, arts, [&](const Capture &capture) {
            return capture.coherent() && paintedRowSpread(capture, otherArt) == 0;
        }, 5000, &ready);
        QVERIFY2(ready, "the hidden gradient never left its poster on the bare plate");
        QCOMPARE(paintedRowSpread(unpainted, otherArt), 0);
        QVERIFY(unpainted.coherent());
        QVERIFY(unpainted.sameGeometryAs(painted));

        // The capture the old single-pixel check accepts is exactly the one
        // whole-grid readiness refuses.
        QVERIFY2(artworkPainted(unpainted, lastArt),
                 "the focused card's own centre pixel must still read as painted here");
        QVERIFY2(!gridArtworkPainted(unpainted, arts),
                 "readiness accepted a capture with an unpainted poster in it");

        // A bound on the negative: while that poster is bare, readiness never
        // arrives, so this wait can only run out, and what it returns is still
        // a real measured frame that readiness refuses.
        bool readyWhileBare = true;
        const Capture refused = captureWindowUntil(window, arts, [&](const Capture &capture) {
            return gridArtworkPainted(capture, arts);
        }, 400, &readyWhileBare);
        QVERIFY2(!readyWhileBare, "readiness was reported while a poster showed the bare plate");
        QVERIFY(refused.coherent());
        QVERIFY(refused.items.contains(otherArt));
        QVERIFY(!gridArtworkPainted(refused, arts));

        // Restored, the same grid is accepted again, so the refusal was the
        // unpainted poster and not the fixture.
        otherGradient->setVisible(true);
        bool readyAgain = false;
        const Capture repainted = captureWindowUntil(window, arts, [&](const Capture &capture) {
            return gridArtworkPainted(capture, arts);
        }, 5000, &readyAgain);
        QVERIFY2(readyAgain, "the restored grid was not accepted again");
        QVERIFY(gridArtworkPainted(repainted, arts));

        // Nothing empty, unmeasured, or defaulted can stand in for a painted
        // grid. A capture that sampled no items has no geometry to judge; a
        // capture carrying a default rectangle for a poster reports one, and
        // a default rectangle is not a painted poster.
        const Capture empty;
        QVERIFY(!empty.coherent());
        QVERIFY(empty.geometryOf(otherArt).sceneRect.isEmpty());
        QVERIFY(!gridArtworkPainted(empty, arts));

        const Capture unmeasured = render_probe::captureWindow(window, {});
        QVERIFY(unmeasured.coherent());
        QVERIFY(unmeasured.items.isEmpty());
        QVERIFY(!gridArtworkPainted(unmeasured, arts));

        Capture defaulted = repainted;
        defaulted.items.insert(otherArt, render_probe::ItemGeometry{});
        QVERIFY(defaulted.coherent());
        QVERIFY(defaulted.items.contains(otherArt));
        QVERIFY(defaulted.geometryOf(otherArt).sceneRect.isEmpty());
        QVERIFY(!gridArtworkPainted(defaulted, arts));

        // A poster measured off screen is not judged, but it cannot carry the
        // whole check either: with no judgeable poster left there is nothing
        // to stand for the grid.
        QVERIFY(!gridArtworkPainted(repainted, {}));
        Capture offScreen = repainted;
        for (QQuickItem *art : arts) {
            render_probe::ItemGeometry away = offScreen.geometryOf(art);
            away.sceneRect.moveTop(offScreen.logicalSize.height() + 10);
            offScreen.items.insert(art, away);
        }
        QVERIFY(offScreen.coherent());
        QVERIFY(!gridArtworkPainted(offScreen, arts));
    }

    // A refusal must come from a measured frame of the card. An empty capture
    // and a coherent grab that did not sample the frame both read a default
    // scale of 1.0 and are not settled, which is exactly what an unsettled
    // frame looks like unless the capture itself is required to be real.
    void anUnmeasuredCaptureIsNotAnUnsettledRefusal()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        QTemporaryDir library;
        QVERIFY(writeMediaFile(library.path(), QStringLiteral("Arrival.2016.mkv")));

        ApplicationController controller;
        controller.setTemporaryLibraryRoot(library.path());
        controller.settings()->setLeanBackMode(false);
        QTRY_COMPARE(controller.library()->rowCount(), 1);

        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY2(window != nullptr, "qml/Main.qml did not load from the module");
        controller.navigation()->goHome();
        QVERIFY(QTest::qWaitForWindowExposed(window));

        QQuickItem *view = nullptr;
        QTRY_VERIFY((view = grid(window)) != nullptr);
        QTRY_COMPARE(view->property("count").toInt(), 1);
        revealRow(window, view);
        auto *card = cardAt(view, 0);
        QVERIFY(card != nullptr);
        QVERIFY(frameOf(card) != nullptr);

        const Capture empty;
        QVERIFY(!empty.coherent());
        QCOMPARE(empty.geometryOf(frameOf(card)).scale, 1.0);
        QVERIFY(!cardSettled(empty, card, true));
        QVERIFY(!refusedAsUnsettled(empty, card));

        const Capture unmeasured = render_probe::captureWindow(window, {});
        QVERIFY(unmeasured.coherent());
        QCOMPARE(unmeasured.geometryOf(frameOf(card)).scale, 1.0);
        QVERIFY(!cardSettled(unmeasured, card, true));
        QVERIFY(!refusedAsUnsettled(unmeasured, card));

        // A wait that runs out says so, whatever it returns.
        bool ready = true;
        const Capture never = captureWindowUntil(window, {card, frameOf(card), chromeOf(card)},
                                                 [](const Capture &) { return false; }, 100, &ready);
        QVERIFY(!ready);
        QVERIFY(never.coherent());
        // The idle card is at rest, which is not the unsettled state either.
        QVERIFY(cardSettled(never, card, false));
        QVERIFY(!refusedAsUnsettled(never, card));

        bool readyNow = false;
        const Capture immediate = captureWindowUntil(window, {card, frameOf(card), chromeOf(card)},
                                                     [](const Capture &) { return true; }, 100, &readyNow);
        QVERIFY(readyNow);
        QVERIFY(immediate.coherent());
    }

    void posterTextMetricsKeepReleasedDefaultValues()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        QTemporaryDir library;
        QVERIFY(writeMediaFile(library.path(), QStringLiteral("Arrival.2016.mkv")));

        ApplicationController controller;
        controller.settings()->setLeanBackMode(false);
        controller.setTemporaryLibraryRoot(library.path());
        QTRY_COMPARE(controller.library()->rowCount(), 1);

        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY2(window != nullptr, "qml/Main.qml did not load from the module");
        controller.navigation()->goHome();

        QQuickItem *view = nullptr;
        QTRY_VERIFY((view = grid(window)) != nullptr);
        QTRY_COMPARE(view->property("count").toInt(), 1);
        revealRow(window, view);

        auto *card = cardAt(view, 0);
        QVERIFY(card != nullptr);
        auto *title = card->findChild<QQuickItem *>(QStringLiteral("posterTitle"));
        auto *metadata =
            card->findChild<QQuickItem *>(QStringLiteral("posterMetadata"));
        auto *caption =
            card->findChild<QQuickItem *>(QStringLiteral("posterCaption"));
        QVERIFY(title != nullptr);
        QVERIFY(metadata != nullptr);
        QVERIFY(caption != nullptr);

        // These are the released base metrics at the neutral scale.
        QCOMPARE(title->property("lineHeight").toReal(), 16.0);
        QCOMPARE(metadata->property("lineHeight").toReal(), 13.0);
        QCOMPARE(caption->height(), 62.0);
        QCOMPARE(cellHeightOf(view), 373);

        // Marquee/SharedViews/MovieCard.swift:122-130 derives these metrics
        // from live accessibility values. No Qt production source is wired in
        // this slice, so only the released neutral values are part of the
        // shipped contract.
    }

    void aTitleWithALocalPosterShowsItWhileOneWithoutShowsTheFallbackArtwork()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        QTemporaryDir library;
        QVERIFY(writeMediaFile(library.path(), QStringLiteral("Arrival (2016).mkv")));
        QVERIFY(writePosterFile(library.path(),
                                QStringLiteral("Arrival (2016)-poster.png")));
        QVERIFY(writeMediaFile(library.path(), QStringLiteral("Moon.2009.mkv")));

        ApplicationController controller;
        controller.setTemporaryLibraryRoot(library.path());
        QTRY_COMPARE(controller.library()->rowCount(), 2);

        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY2(window != nullptr, "qml/Main.qml did not load from the module");
        controller.navigation()->goHome();

        QQuickItem *view = nullptr;
        QTRY_VERIFY((view = grid(window)) != nullptr);
        QTRY_COMPARE(view->property("count").toInt(), 2);
        revealRow(window, view);

        QQuickItem *art = artOf(cardAt(view, 0));
        QVERIFY(art != nullptr);
        QCOMPARE(art->property("source").toUrl(),
                 QUrl::fromLocalFile(QDir(library.path())
                                         .filePath(QStringLiteral("Arrival (2016)-poster.png"))));
        QTRY_COMPARE(art->property("status").toInt(), 1); // Image.Ready

        // MovieCard.swift:214-222 draws no artwork for a title without a
        // sidecar; the fallback artwork beneath shows through.
        QQuickItem *bareCard = cardAt(view, 1);
        QQuickItem *bareArt = artOf(bareCard);
        QVERIFY(bareArt != nullptr);
        QCOMPARE(bareArt->property("source").toUrl(), QUrl());
        QCOMPARE(bareArt->property("status").toInt(), 0); // Image.Null
        QVERIFY(fallbackOf(bareCard) != nullptr);
        QVERIFY(fallbackOf(bareCard)->isVisible());
    }

    void aPosterThatCannotBeDecodedFallsBackToTheFallbackArtwork()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        QTemporaryDir library;
        QVERIFY(writeMediaFile(library.path(), QStringLiteral("Arrival (2016).mkv")));
        QVERIFY(writeFile(library.path(), QStringLiteral("Arrival (2016)-poster.png"),
                          QByteArrayLiteral("<html>not an image</html>")));

        ApplicationController controller;
        controller.setTemporaryLibraryRoot(library.path());
        QTRY_COMPARE(controller.library()->rowCount(), 1);

        // The catalog still points at the sidecar, so the fallback below is the
        // card's answer to art it cannot draw rather than a scan that skipped it.
        QCOMPARE(controller.library()
                     ->data(controller.library()->index(0, 0), LibraryModel::PosterUrlRole)
                     .toUrl(),
                 QUrl::fromLocalFile(QDir(library.path())
                                         .filePath(QStringLiteral("Arrival (2016)-poster.png"))));

        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY2(window != nullptr, "qml/Main.qml did not load from the module");
        controller.navigation()->goHome();

        QQuickItem *view = nullptr;
        QTRY_VERIFY((view = grid(window)) != nullptr);
        QTRY_COMPARE(view->property("count").toInt(), 1);
        revealRow(window, view);

        QQuickItem *art = artOf(cardAt(view, 0));
        QVERIFY(art != nullptr);
        QTRY_COMPARE(art->property("source").toUrl(), QUrl());
        QCOMPARE(art->property("status").toInt(), 0); // Image.Null
        QVERIFY(fallbackOf(cardAt(view, 0))->isVisible());
    }

    // HomeDetailView.swift:191-196 answers a library holding neither movies nor
    // episodes with :477-492's empty state, and :195 reaches it only when no
    // scan is running. The wording, type, and ink are the released view's.
    void emptyLibraryExplainsItselfInsteadOfShowingAnEmptyGrid()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        ApplicationController controller;
        controller.settings()->setLeanBackMode(false);
        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY2(window != nullptr, "qml/Main.qml did not load from the module");
        controller.navigation()->goHome();

        // The state is reached only once the shell's own first scan has ended.
        QTRY_VERIFY(!controller.scanning());

        auto *empty = window->findChild<QQuickItem *>(QStringLiteral("libraryEmptyState"));
        QTRY_VERIFY(empty != nullptr);
        QTRY_VERIFY(empty->isVisible());

        // :483 and :486's copy, at :484's 17 points medium in the secondary
        // ink over :487's 12 points in the tertiary ink.
        auto *title = window->findChild<QQuickItem *>(QStringLiteral("libraryEmptyTitle"));
        auto *detail = window->findChild<QQuickItem *>(QStringLiteral("libraryEmptyDetail"));
        auto *glyph = window->findChild<QQuickItem *>(QStringLiteral("libraryEmptyGlyph"));
        QVERIFY(title != nullptr);
        QVERIFY(detail != nullptr);
        QVERIFY(glyph != nullptr);
        QCOMPARE(title->property("text").toString(), QStringLiteral("No content found"));
        QCOMPARE(detail->property("text").toString(),
                 QStringLiteral("Content will appear once scanning completes"));
        QCOMPARE(title->property("font").value<QFont>().pixelSize(), 17);
        QCOMPARE(detail->property("font").value<QFont>().pixelSize(), 12);
        QCOMPARE(title->property("color").value<QColor>(), QColor("#9b8fb0"));
        QCOMPARE(detail->property("color").value<QColor>(), QColor("#6b6178"));

        // :480-482 draws `film` at 40 points in the tertiary ink at 0.4.
        QCOMPARE(glyph->property("symbol").toString(), QStringLiteral("film"));
        QCOMPARE(qRound(glyph->property("pointSize").toReal()), 40);
        const QColor glyphInk = glyph->property("color").value<QColor>();
        QCOMPARE(glyphInk.rgb(), QColor("#6b6178").rgb());
        QCOMPARE(qRound(glyphInk.alphaF() * 100.0f), 40);

        // The scanning state and the whole title bar belong to the other two
        // branches of :191-247 and are not drawn here.
        auto *scanState = window->findChild<QQuickItem *>(QStringLiteral("libraryScanState"));
        auto *titleBar = window->findChild<QQuickItem *>(QStringLiteral("homeTitleBar"));
        auto *bottomFade = window->findChild<QQuickItem *>(QStringLiteral("homeBottomFade"));
        QVERIFY(scanState != nullptr);
        QVERIFY(titleBar != nullptr);
        QVERIFY(bottomFade != nullptr);
        QVERIFY(!scanState->isVisible());
        QVERIFY(!titleBar->isVisible());
        QVERIFY(!bottomFade->isVisible());

        // No rows exist, and the surface that would hold them is hidden.
        QVERIFY(grid(window) == nullptr);
        QCOMPARE(controller.homeRows()->rowCount(), 0);
        QVERIFY(rowsViewport(window) != nullptr);
        QVERIFY(!rowsViewport(window)->isVisible());
    }

    // Sixteen titles in one decade-less pile give Home three rows: Recently
    // Added and All Movies hold eight cards each, and every title is a card.
    void arrowKeysMoveAlongARowAndBetweenRowsAndStopAtTheEdges()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        QTemporaryDir library;
        for (const QString &name : sampleTitles()) {
            QVERIFY(writeMediaFile(library.path(), name));
        }

        ApplicationController controller;
        controller.setTemporaryLibraryRoot(library.path());
        QTRY_COMPARE(controller.library()->rowCount(), 16);

        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY2(window != nullptr, "qml/Main.qml did not load from the module");
        controller.navigation()->goHome();
        QVERIFY(QTest::qWaitForWindowExposed(window));

        QQuickItem *view = nullptr;
        QTRY_VERIFY((view = grid(window)) != nullptr);
        QTRY_COMPARE(view->property("count").toInt(), 8);
        revealRow(window, view);

        FocusNavigator *focus = controller.homeRows()->focus();
        const int rows = controller.homeRows()->rowCount();
        const int allRow = allMoviesRowIndex();
        QVERIFY(rows >= 3);
        QCOMPARE(allRow, rows - 1);
        QTest::keyClick(window, Qt::Key_Right);
        QTRY_VERIFY(contentHasFocus(window));
        QCOMPARE(focus->row(), allRow);
        QCOMPARE(focus->column(), 0);

        QTest::keyClick(window, Qt::Key_Right);
        QCOMPARE(focus->column(), 1);
        QTest::keyClick(window, Qt::Key_Left);
        QCOMPARE(focus->column(), 0);
        // Down on the last row has nowhere to go and must not drift sideways.
        QTest::keyClick(window, Qt::Key_Down);
        QCOMPARE(focus->row(), allRow);
        QCOMPARE(focus->column(), 0);

        QTest::keyClick(window, Qt::Key_Up);
        QCOMPARE(focus->row(), allRow - 1);
        QTest::keyClick(window, Qt::Key_Down);
        QCOMPARE(focus->row(), allRow);

        // Right stops at the eighth card, the last Home draws, rather than
        // wrapping onto the next row or running into the cards left out.
        for (int step = 0; step < 12; ++step) {
            QTest::keyClick(window, Qt::Key_Right);
        }
        QCOMPARE(focus->column(), 7);
        // Up lands on the column that row last held, kept inside its length.
        QTest::keyClick(window, Qt::Key_Up);
        QCOMPARE(focus->row(), allRow - 1);
        const QObject *above = controller.homeRows()
                                   ->data(controller.homeRows()->index(allRow - 1),
                                          HomeRowsModel::ItemsRole)
                                   .value<QObject *>();
        const int aboveLength = qobject_cast<const QAbstractItemModel *>(above)->rowCount();
        QVERIFY(focus->column() <= std::min(7, aboveLength - 1));
        for (int step = 0; step < rows; ++step) {
            QTest::keyClick(window, Qt::Key_Up);
        }
        QCOMPARE(focus->row(), 0);
    }

    void leftAtTheFirstColumnReturnsFocusToTheSidebar()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        QTemporaryDir library;
        for (const QString &name : sampleTitles()) {
            QVERIFY(writeMediaFile(library.path(), name));
        }

        ApplicationController controller;
        controller.setTemporaryLibraryRoot(library.path());
        QTRY_COMPARE(controller.library()->rowCount(), 16);

        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY2(window != nullptr, "qml/Main.qml did not load from the module");
        controller.navigation()->goHome();

        QQuickItem *view = nullptr;
        QTRY_VERIFY((view = grid(window)) != nullptr);
        QTRY_COMPARE(view->property("count").toInt(), 8);
        revealRow(window, view);

        auto *sidebar = window->findChild<QQuickItem *>(QStringLiteral("sidebar"));
        QVERIFY(sidebar != nullptr);

        focusFirstCard(window, view);
        QTest::keyClick(window, Qt::Key_Right);
        QCOMPARE(currentIndexOf(view), 1);

        // Inside the row, Left belongs to the row.
        QTest::keyClick(window, Qt::Key_Left);
        QCOMPARE(currentIndexOf(view), 0);
        QVERIFY(contentHasFocus(window));

        auto *card = cardAt(view, 0);
        QVERIFY(card != nullptr);
        auto *posterFrame =
            card->findChild<QQuickItem *>(QStringLiteral("posterFrame"));
        auto *focusFrame =
            card->findChild<QQuickItem *>(QStringLiteral("posterFocusFrame"));
        auto *title = card->findChild<QQuickItem *>(QStringLiteral("posterTitle"));
        QVERIFY(posterFrame != nullptr);
        QVERIFY(focusFrame != nullptr);
        QVERIFY(title != nullptr);
        QTRY_VERIFY(std::abs(posterFrame->scale() - 1.045) < 0.001);
        QVERIFY(focusFrame->property("active").toBool());
        QCOMPARE(title->property("color").value<QColor>(), QColor("#f5f0eb"));

        // At the first column it belongs to the sidebar.
        QTest::keyClick(window, Qt::Key_Left);
        QTRY_VERIFY(sidebar->hasActiveFocus());
        QTRY_VERIFY(std::abs(posterFrame->scale() - 1.0) < 0.001);
        QVERIFY(!focusFrame->property("active").toBool());
        QCOMPARE(title->property("color").value<QColor>(), QColor("#9b8fb0"));
        QTRY_VERIFY(std::abs(posterFrame->z()) < 0.001);

        // The same holds on a row below the first.
        QTest::keyClick(window, Qt::Key_Right);
        QTRY_VERIFY(contentHasFocus(window));
        const int allRow = allMoviesRowIndex();
        QTest::keyClick(window, Qt::Key_Up);
        QCOMPARE(controller.homeRows()->focus()->row(), allRow - 1);

        QTest::keyClick(window, Qt::Key_Left);
        QTRY_VERIFY(sidebar->hasActiveFocus());
        QCOMPARE(controller.homeRows()->focus()->row(), allRow - 1);
    }

    void returnOnAFocusedCardOpensThatTitlesDetails()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        QTemporaryDir library;
        for (const QString &name : sampleTitles()) {
            QVERIFY(writeMediaFile(library.path(), name));
        }

        ApplicationController controller;
        controller.setTemporaryLibraryRoot(library.path());
        QTRY_COMPARE(controller.library()->rowCount(), 16);

        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY2(window != nullptr, "qml/Main.qml did not load from the module");
        controller.navigation()->goHome();

        QQuickItem *view = nullptr;
        QTRY_VERIFY((view = grid(window)) != nullptr);
        QTRY_COMPARE(view->property("count").toInt(), 8);
        revealRow(window, view);

        focusFirstCard(window, view);
        QTest::keyClick(window, Qt::Key_Right);
        QCOMPARE(currentIndexOf(view), 1);

        // The catalog entry the second card is showing, read before it is
        // opened so the assertions below cannot be satisfied by the wrong row.
        const QVariantMap focused =
            controller.homeRows()->cardAt(allMoviesRowIndex(), 1);
        const std::optional<MediaItem> expected =
            controller.library()->itemForId(focused.value(QStringLiteral("mediaId")).toString());
        QVERIFY(expected.has_value());
        QCOMPARE(expected->title, QStringLiteral("Coco"));

        QTest::keyClick(window, Qt::Key_Return);

        QTRY_COMPARE(controller.navigation()->route(), NavigationController::Route::Details);
        QCOMPARE(controller.navigation()->selectedMediaId(), expected->id);
        // Activating a card describes the title rather than starting it, so
        // nothing has been handed to the player yet.
        QVERIFY(controller.player()->currentFileUrl().isEmpty());
        QVERIFY2(!controller.hasError(), qPrintable(controller.errorMessage()));
    }

    void tappingACardOpensThatCardsTitleRatherThanTheSelectedOne()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        QTemporaryDir library;
        for (const QString &name : sampleTitles()) {
            QVERIFY(writeMediaFile(library.path(), name));
        }

        ApplicationController controller;
        controller.setTemporaryLibraryRoot(library.path());
        QTRY_COMPARE(controller.library()->rowCount(), 16);

        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY2(window != nullptr, "qml/Main.qml did not load from the module");
        controller.navigation()->goHome();

        QQuickItem *view = nullptr;
        QTRY_VERIFY((view = grid(window)) != nullptr);
        QTRY_COMPARE(view->property("count").toInt(), 8);
        revealRow(window, view);

        QQuickItem *card = cardAt(view, 2);
        QVERIFY(card != nullptr);

        const QVariantMap tapped = controller.homeRows()->cardAt(allMoviesRowIndex(), 2);
        const std::optional<MediaItem> expected =
            controller.library()->itemForId(tapped.value(QStringLiteral("mediaId")).toString());
        QVERIFY(expected.has_value());
        QCOMPARE(expected->title, QStringLiteral("Dune"));

        const QPointF centre =
            card->mapToScene(QPointF(card->width() / 2, card->height() / 2));
        QTest::mouseClick(window, Qt::LeftButton, Qt::NoModifier, centre.toPoint());

        // Opening the details destroys the rows and their delegates, so
        // nothing below may read the browse scene again: the identity that
        // opened is what proves the tapped card won over the selected one.
        QTRY_COMPARE(controller.navigation()->route(), NavigationController::Route::Details);
        QCOMPARE(controller.navigation()->selectedMediaId(), expected->id);
        QVERIFY2(!controller.hasError(), qPrintable(controller.errorMessage()));
    }

    void playingAnIdTheLibraryNoLongerHoldsIsReportedNotOpened()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        ApplicationController controller;
        const NavigationController::Route before = controller.navigation()->route();

        controller.playMediaId(QStringLiteral("not-a-media-id"));

        QVERIFY(controller.hasError());
        QCOMPARE(controller.errorTitle(), QStringLiteral("Playback"));
        QCOMPARE(controller.navigation()->route(), before);
        QVERIFY(controller.player()->currentFileUrl().isEmpty());
    }

private:
    // Marquee/SharedViews/CachedImageView.swift:4-8 and :27-45 give an artwork
    // request three states and a generation that guards them. The cases below
    // drive the shipped poster surface through each transition directly: a
    // grid delegate settles its load before a test can observe the states in
    // flight, so the surface is instantiated from the shipped module and
    // driven by its own source property.
    struct PosterProbe
    {
        QQuickItem *poster = nullptr;
        QQuickItem *art = nullptr;
        QQuickItem *placeholder = nullptr;
        QQuickItem *symbol = nullptr;
        QQuickItem *wordmark = nullptr;
        QQuickItem *fallback = nullptr;
    };

    // The shipped PosterArt, created from the linked module rather than a
    // replica. The component outlives the item, so the caller owns both.
    [[nodiscard]] static bool loadPosterProbe(QQmlComponent &component, PosterProbe &probe)
    {
        component.setData(
            QByteArrayLiteral("import QtQuick\nimport Marquee\n"
                              "PosterArt { width: 150; source: \"\"; title: \"Arrival\" }\n"),
            QUrl(QStringLiteral("qrc:/browse-poster-probe.qml")));
        if (component.isError()) {
            qWarning() << component.errorString();
            return false;
        }
        probe.poster = qobject_cast<QQuickItem *>(component.create());
        if (probe.poster == nullptr) {
            return false;
        }
        probe.poster->setParent(&component);
        probe.art = probe.poster->findChild<QQuickItem *>(QStringLiteral("posterArt"));
        probe.placeholder = probe.poster->findChild<QQuickItem *>(QStringLiteral("posterPlaceholder"));
        probe.symbol = probe.poster->findChild<QQuickItem *>(QStringLiteral("posterPlaceholderSymbol"));
        probe.wordmark = probe.poster->findChild<QQuickItem *>(QStringLiteral("posterPlaceholderWordmark"));
        probe.fallback = probe.poster->findChild<QQuickItem *>(QStringLiteral("posterFallback"));
        return probe.art != nullptr && probe.placeholder != nullptr && probe.symbol != nullptr
            && probe.wordmark != nullptr && probe.fallback != nullptr;
    }

    [[nodiscard]] static int loadStateOf(const PosterProbe &probe)
    {
        return probe.poster->property("loadState").toInt();
    }

    // PosterArt.LoadState, in the order the QML enum declares it.
    enum class PosterLoadState { Loading = 0, Ready = 1, TerminalFallback = 2 };

    [[nodiscard]] static bool completeOn(QQuickItem *poster, const QUrl &request,
                                         int generation, bool imageAvailable)
    {
        QVariant accepted;
        if (!QMetaObject::invokeMethod(poster, "completeRequest",
                                       Q_RETURN_ARG(QVariant, accepted),
                                       Q_ARG(QVariant, QVariant::fromValue(request)),
                                       Q_ARG(QVariant, generation),
                                       Q_ARG(QVariant, imageAvailable))) {
            return false;
        }
        return accepted.toBool();
    }

    // Holds a request open at the shipped state machine's own entry point: a
    // Canvas paints over event-loop turns and those same turns settle a real
    // file read, so a surface driven from a file could not be grabbed while
    // loading. `beginRequest` is what `onSourceChanged` calls, and with the
    // image item left pointing at nothing there is no load outstanding to end
    // it.
    [[nodiscard]] static bool beginRequestOn(QQuickItem *poster, const QUrl &request,
                                             QVariant &generation)
    {
        return QMetaObject::invokeMethod(poster, "beginRequest",
                                         Q_RETURN_ARG(QVariant, generation),
                                         Q_ARG(QVariant, QVariant::fromValue(request)));
    }

    // The band the fallback artwork's own badge and title occupy: inside the
    // rounded corners, and clear of the loading symbol and wordmark, which
    // CachedImageView.swift:119 centres.
    [[nodiscard]] static QRect fallbackCaptionBand(const Capture &capture,
                                                   const QRect &surfaceRect)
    {
        const int inset = pixels(capture, 12);
        return QRect(surfaceRect.left() + inset,
                     surfaceRect.bottom() - pixels(capture, 42),
                     surfaceRect.width() - 2 * inset,
                     pixels(capture, 30));
    }

    // MovieCard.swift:342-344 draws the fallback title in the primary text
    // colour at 0.92, which no layer of either presentation approaches: the
    // elevated fill, the gradient, and both symbols are far darker.
    [[nodiscard]] static bool isFallbackCaptionInk(const QColor &pixel)
    {
        return pixel.red() > 150 && pixel.green() > 150 && pixel.blue() > 150;
    }

private slots:
    // CachedImageView.swift:31 begins a request with artwork in the loading
    // state and :43 settles it on the decoded image; :86-97 then shows the
    // image in place of the placeholder. A request with no artwork at all is
    // terminal from the start and never loads.
    void aPosterRequestIsVisiblyLoadingUntilItsArtworkArrives()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        QTemporaryDir library;
        QVERIFY(writePosterFile(library.path(), QStringLiteral("Arrival-poster.png"),
                                QColor("#00c800")));

        ApplicationController controller;
        controller.settings()->setLeanBackMode(false);

        QQmlApplicationEngine engine;
        engine.rootContext()->setContextProperty(QStringLiteral("appController"), &controller);
        QQmlComponent posterComponent(&engine);
        PosterProbe probe;
        QVERIFY(loadPosterProbe(posterComponent, probe));

        // A surface pointed at nothing is terminal, and shows no placeholder:
        // the fallback artwork beneath is the whole of that presentation.
        QCOMPARE(loadStateOf(probe), int(PosterLoadState::TerminalFallback));
        QVERIFY(!probe.placeholder->isVisible());
        QVERIFY(probe.fallback->isVisible());

        const QUrl poster =
            QUrl::fromLocalFile(QDir(library.path()).filePath(QStringLiteral("Arrival-poster.png")));
        probe.poster->setProperty("source", poster);

        // The request is loading the moment it is made, before any event loop
        // turn could have completed it, and says so on the surface.
        QCOMPARE(loadStateOf(probe), int(PosterLoadState::Loading));
        QCOMPARE(probe.poster->property("loadRequest").toUrl(), poster);
        QVERIFY(probe.placeholder->isVisible());
        QVERIFY(probe.symbol->isVisible());
        QVERIFY(probe.wordmark->isVisible());
        // CachedImageView.swift:63 inks a loading placeholder at 0.18 and :64
        // its wordmark at 0.34; a colour channel carries eight bits, so the
        // wordmark's alpha is that value quantized.
        QCOMPARE(probe.poster->property("placeholderIconOpacity").toReal(), 0.18);
        QCOMPARE(qRound(probe.wordmark->property("color").value<QColor>().alphaF() * 255.0f),
                 qRound(0.34 * 255.0));
        QCOMPARE(probe.wordmark->property("text").toString(), QStringLiteral("MARQUEE"));
        // CachedImageView.swift:121 sizes the symbol at 22 points compact.
        QCOMPARE(qRound(probe.symbol->width()), 22);

        // The image replaces the placeholder once it arrives, and the fallback
        // beneath it is never disturbed.
        QTRY_COMPARE(loadStateOf(probe), int(PosterLoadState::Ready));
        QCOMPARE(probe.art->property("status").toInt(), 1); // Image.Ready
        QVERIFY(!probe.placeholder->isVisible());
        QVERIFY(probe.fallback->isVisible());
    }

    // CachedImageView.swift:43 settles a request that produced no image as the
    // terminal fallback, which MovieCard.swift:204-224 presents as the fallback
    // artwork with its own film treatment rather than the loading placeholder.
    void anUndecodablePosterEndsAtTheTerminalFallbackNotTheLoadingPlaceholder()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        QTemporaryDir library;
        QVERIFY(writeUndecodablePosterFile(library.path(), QStringLiteral("Arrival-poster.png")));

        ApplicationController controller;
        controller.settings()->setLeanBackMode(false);

        QQmlApplicationEngine engine;
        engine.rootContext()->setContextProperty(QStringLiteral("appController"), &controller);
        QQmlComponent posterComponent(&engine);
        PosterProbe probe;
        QVERIFY(loadPosterProbe(posterComponent, probe));

        probe.poster->setProperty(
            "source",
            QUrl::fromLocalFile(QDir(library.path()).filePath(QStringLiteral("Arrival-poster.png"))));
        QCOMPARE(loadStateOf(probe), int(PosterLoadState::Loading));
        QVERIFY(probe.placeholder->isVisible());

        QTRY_COMPARE(loadStateOf(probe), int(PosterLoadState::TerminalFallback));
        // The loading placeholder is gone and the fallback artwork, with the
        // film symbol of MovieCard.swift:329-331, is what remains.
        QVERIFY(!probe.placeholder->isVisible());
        QVERIFY(probe.fallback->isVisible());
        QVERIFY(probe.fallback->findChild<QQuickItem *>(QStringLiteral("posterFallbackSymbol"))
                    ->isVisible());
        // MovieCard.swift:214-222 draws no artwork for a sidecar that would
        // not decode: the failed source is dropped rather than retried.
        QCOMPARE(probe.art->property("source").toUrl(), QUrl());
    }

    // CachedImageView.swift:135-146 abandons the outstanding load and begins a
    // new generation the moment the surface is pointed at other artwork, and
    // :41-42 then refuses any completion whose generation or request no longer
    // matches. A recycled delegate is the case that matters, and it is a case
    // in flight: the replacement happens while the first read is still
    // outstanding, so the late completion must neither paint the previous
    // title's artwork nor clear the loading state of the title now on screen.
    // No event loop turn runs between the assignments below, so the boundary
    // this drives is the real one rather than a settled surface reopened.
    void aSourceReplacedWhileItsReadIsInFlightStaysLoadingAndRefusesTheStaleCompletion()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        QTemporaryDir library;
        QVERIFY(writePosterFile(library.path(), QStringLiteral("Arrival-poster.png"),
                                QColor("#00c800")));
        QVERIFY(writePosterFile(library.path(), QStringLiteral("Dune-poster.png"),
                                QColor("#c80000")));

        ApplicationController controller;
        controller.settings()->setLeanBackMode(false);

        QQmlApplicationEngine engine;
        engine.rootContext()->setContextProperty(QStringLiteral("appController"), &controller);
        QQmlComponent posterComponent(&engine);
        PosterProbe probe;
        QVERIFY(loadPosterProbe(posterComponent, probe));

        const QUrl first =
            QUrl::fromLocalFile(QDir(library.path()).filePath(QStringLiteral("Arrival-poster.png")));
        const QUrl second =
            QUrl::fromLocalFile(QDir(library.path()).filePath(QStringLiteral("Dune-poster.png")));

        probe.poster->setProperty("source", first);
        const int firstGeneration = probe.poster->property("loadGeneration").toInt();

        // The first read is genuinely outstanding: the image item was handed
        // artwork this process has never decoded, and asynchronous loading
        // reports it as loading until an event loop turn completes it.
        QCOMPARE(loadStateOf(probe), int(PosterLoadState::Loading));
        QCOMPARE(probe.poster->property("loadRequest").toUrl(), first);
        QCOMPARE(probe.art->property("source").toUrl(), first);
        QCOMPARE(probe.art->property("status").toInt(), 2); // Image.Loading

        // The surface is recycled onto another title without waiting for that
        // read: no event loop turn separates the two assignments, so the first
        // request is still in flight as far as its own completion is
        // concerned, and the second is what the surface is now showing.
        probe.poster->setProperty("source", second);
        const int secondGeneration = probe.poster->property("loadGeneration").toInt();
        QVERIFY(secondGeneration > firstGeneration);
        QCOMPARE(probe.poster->property("loadRequest").toUrl(), second);
        QCOMPARE(probe.art->property("source").toUrl(), second);
        // The replacement did not inherit the abandoned read's outcome: the
        // production image item and the surface are both loading here.
        QCOMPARE(probe.art->property("status").toInt(), 2); // Image.Loading
        QCOMPARE(loadStateOf(probe), int(PosterLoadState::Loading));
        QVERIFY(probe.placeholder->isVisible());

        // The previous title's completion is refused on its generation.
        QVERIFY(!completeOn(probe.poster, first, firstGeneration, true));
        // And on its request, even carrying the live generation, so a
        // completion cannot be laundered by an interleaved request that
        // happens to land on the same number.
        QVERIFY(!completeOn(probe.poster, first, secondGeneration, true));
        // A stale failure is refused on the same terms, so a read abandoned
        // mid-flight cannot drop the surface to the terminal fallback either.
        QVERIFY(!completeOn(probe.poster, first, firstGeneration, false));
        // CachedImageView.swift:41 also guards the request now on screen
        // against a generation it has already outlived: the same title read
        // twice does not let the first read settle the second.
        QVERIFY(!completeOn(probe.poster, second, firstGeneration, true));

        // None of them reached the live request: it is still the one on
        // screen, still in flight, and still showing that on the surface.
        QCOMPARE(loadStateOf(probe), int(PosterLoadState::Loading));
        QCOMPARE(probe.poster->property("loadRequest").toUrl(), second);
        QCOMPARE(probe.poster->property("loadGeneration").toInt(), secondGeneration);
        QVERIFY(probe.placeholder->isVisible());

        // Only the read now on screen settles it, and it settles with its own
        // artwork rather than the artwork it replaced.
        QTRY_COMPARE(loadStateOf(probe), int(PosterLoadState::Ready));
        QCOMPARE(probe.poster->property("loadRequest").toUrl(), second);
        QCOMPARE(probe.poster->property("loadGeneration").toInt(), secondGeneration);
        QCOMPARE(probe.art->property("source").toUrl(), second);
        QCOMPARE(probe.art->property("status").toInt(), 1); // Image.Ready
        QVERIFY(!probe.placeholder->isVisible());

        // A stale failure cannot force the settled surface back to the
        // placeholder afterwards either.
        probe.poster->setProperty("source", first);
        const int thirdGeneration = probe.poster->property("loadGeneration").toInt();
        QVERIFY(!completeOn(probe.poster, second, secondGeneration, false));
        QCOMPARE(probe.poster->property("loadRequest").toUrl(), first);

        // The live request's own completion is the one that is honoured.
        QVERIFY(completeOn(probe.poster, first, thirdGeneration, false));
        QCOMPARE(loadStateOf(probe), int(PosterLoadState::TerminalFallback));
        QVERIFY(!probe.placeholder->isVisible());
    }

    // A source replaced while its predecessor is still loading starts a fresh
    // request rather than inheriting the old one's state, and artwork already
    // in Qt's pixmap cache still settles: CachedImageView.swift:156-169 takes
    // the memory-cached image without waiting for a pipeline callback.
    void replacingASourceRestartsTheRequestAndACachedImageStillSettlesIt()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        QTemporaryDir library;
        QVERIFY(writePosterFile(library.path(), QStringLiteral("Arrival-poster.png"),
                                QColor("#00c800")));
        QVERIFY(writeUndecodablePosterFile(library.path(), QStringLiteral("Broken-poster.png")));

        ApplicationController controller;
        controller.settings()->setLeanBackMode(false);

        QQmlApplicationEngine engine;
        engine.rootContext()->setContextProperty(QStringLiteral("appController"), &controller);
        QQmlComponent posterComponent(&engine);
        PosterProbe probe;
        QVERIFY(loadPosterProbe(posterComponent, probe));

        const QUrl good =
            QUrl::fromLocalFile(QDir(library.path()).filePath(QStringLiteral("Arrival-poster.png")));
        const QUrl broken =
            QUrl::fromLocalFile(QDir(library.path()).filePath(QStringLiteral("Broken-poster.png")));

        probe.poster->setProperty("source", good);
        QTRY_COMPARE(loadStateOf(probe), int(PosterLoadState::Ready));
        const int firstGeneration = probe.poster->property("loadGeneration").toInt();

        // A failure between the two, so the retry latch that clears a failed
        // source has been used before the cached image is asked for again.
        probe.poster->setProperty("source", broken);
        QTRY_COMPARE(loadStateOf(probe), int(PosterLoadState::TerminalFallback));

        // The same artwork again. Qt hands back the cached pixmap inside the
        // assignment, emitting no later status change, so a surface that
        // waited for one would sit on the loading placeholder forever.
        probe.poster->setProperty("source", good);
        QCOMPARE(probe.poster->property("loadGeneration").toInt(), firstGeneration + 2);
        QCOMPARE(loadStateOf(probe), int(PosterLoadState::Ready));
        QVERIFY(!probe.placeholder->isVisible());
        QCOMPARE(probe.art->property("status").toInt(), 1); // Image.Ready

        // It stays settled once the event loop has run, rather than being
        // reopened by a late signal.
        QTest::qWait(50);
        QCOMPARE(loadStateOf(probe), int(PosterLoadState::Ready));

        // Clearing the artwork is terminal at once, with no placeholder: there
        // is no request to be in flight.
        probe.poster->setProperty("source", QUrl());
        QCOMPARE(loadStateOf(probe), int(PosterLoadState::TerminalFallback));
        QVERIFY(!probe.placeholder->isVisible());
        QVERIFY(probe.fallback->isVisible());
    }

    // The loading placeholder and the terminal fallback must be told apart on
    // the surface, not only in the state machine: CachedImageView.swift:120
    // draws `photo` over the loading placeholder, while a terminal request
    // shows the fallback artwork's own film treatment. Both are canvases, so
    // the proof is painted pixels over one rectangle in both states.
    void theLoadingPlaceholderIsPaintedUnlikeTheTerminalFallback()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        QTemporaryDir library;
        QVERIFY(writePosterFile(library.path(), QStringLiteral("Arrival-poster.png"),
                                QColor("#00c800")));

        ApplicationController controller;
        controller.settings()->setLeanBackMode(false);

        QQmlApplicationEngine engine;
        engine.rootContext()->setContextProperty(QStringLiteral("appController"), &controller);
        QQmlComponent component(&engine);
        component.setData(
            QByteArrayLiteral("import QtQuick\nimport Marquee\n"
                              "Window {\n"
                              "    width: 200; height: 320; visible: true; color: \"#0d0b1a\"\n"
                              "    PosterArt { objectName: \"probePoster\"\n"
                              "                x: 25; y: 25; width: 150; source: \"\"\n"
                              "                title: \"Arrival\" }\n"
                              "}\n"),
            QUrl(QStringLiteral("qrc:/browse-poster-paint-probe.qml")));
        QVERIFY2(!component.isError(), qPrintable(component.errorString()));
        const std::unique_ptr<QObject> created(component.create());
        auto *window = qobject_cast<QQuickWindow *>(created.get());
        QVERIFY(window != nullptr);
        QVERIFY(QTest::qWaitForWindowExposed(window));

        auto *poster = window->findChild<QQuickItem *>(QStringLiteral("probePoster"));
        QVERIFY(poster != nullptr);
        auto *symbol = poster->findChild<QQuickItem *>(QStringLiteral("posterPlaceholderSymbol"));
        auto *placeholder = poster->findChild<QQuickItem *>(QStringLiteral("posterPlaceholder"));
        QVERIFY(symbol != nullptr);
        QVERIFY(placeholder != nullptr);

        // A Canvas paints over event-loop turns, and those same turns settle a
        // real artwork load, so a request driven from a file could not be
        // grabbed while loading. The request is held open at the shipped state
        // machine's own entry point instead.
        const QUrl request =
            QUrl::fromLocalFile(QDir(library.path()).filePath(QStringLiteral("Arrival-poster.png")));
        QVariant generation;
        QVERIFY(beginRequestOn(poster, request, generation));
        QCOMPARE(poster->property("loadState").toInt(), int(PosterLoadState::Loading));
        QVERIFY(placeholder->isVisible());

        // The loading presentation is the placeholder's own elevated fill of
        // CachedImageView.swift:116-117 with :120's `photo` stroked over it;
        // the terminal presentation is the fallback artwork's gradient and its
        // own film treatment. Both are canvases over one rectangle, so the
        // proof is painted pixels: the fill is there in one state and gone in
        // the other, and the stroke is only ever over the fill.
        const QColor placeholderFill("#1a1525");
        const auto isPlaceholderFill = [&](const QColor &pixel) {
            return render_probe::withinTolerance(pixel, placeholderFill, 2);
        };
        // CachedImageView.swift:122 strokes the tertiary text colour at the
        // loading opacity, which lifts every channel of the fill beneath it.
        const auto isSymbolInk = [&](const QColor &pixel) {
            return pixel.red() > placeholderFill.red() + 4
                && pixel.green() > placeholderFill.green() + 4
                && pixel.blue() > placeholderFill.blue() + 4;
        };
        const auto symbolPainted = [&](const Capture &capture) {
            const QRect symbolRect = imageRectForItem(capture, symbol);
            return !symbolRect.isEmpty()
                && countPixels(capture.image, symbolRect, isPlaceholderFill) > 0
                && countPixels(capture.image, symbolRect, isSymbolInk) > 0;
        };
        const Capture loading = captureWindowUntil(window, {symbol, placeholder}, symbolPainted);
        QVERIFY2(loading.coherent() && symbolPainted(loading),
                 "the loading placeholder painted no symbol over its own fill");
        const QRect symbolRect = imageRectForItem(loading, symbol);
        QVERIFY(!symbolRect.isEmpty());
        const int loadingInk = countPixels(loading.image, symbolRect, isSymbolInk);
        QCOMPARE(poster->property("loadState").toInt(), int(PosterLoadState::Loading));

        // The same request settled with no artwork: the placeholder goes and
        // the fallback beneath is the whole of the terminal presentation.
        QVERIFY(QMetaObject::invokeMethod(poster, "completeRequest",
                                          Q_ARG(QVariant, QVariant::fromValue(request)),
                                          Q_ARG(QVariant, generation),
                                          Q_ARG(QVariant, false)));
        QCOMPARE(poster->property("loadState").toInt(), int(PosterLoadState::TerminalFallback));
        QVERIFY(!placeholder->isVisible());

        const Capture terminal = captureWindowUntil(
            window, {symbol, placeholder}, [&](const Capture &capture) {
                const QRect rect = imageRectForItem(capture, symbol);
                return !rect.isEmpty()
                    && countPixels(capture.image, rect, isPlaceholderFill) == 0;
            });
        QVERIFY(terminal.coherent());
        QVERIFY(loading.sameGeometryAs(terminal));

        // The two presentations differ over the same pixels: the placeholder's
        // fill carried the loading stroke in one and is wholly gone in the
        // other, so the film symbol MovieCard.swift:329-331 draws beneath
        // cannot be mistaken for the photo symbol drawn above it.
        QVERIFY(loadingInk > 0);
        QCOMPARE(countPixels(terminal.image, symbolRect, isPlaceholderFill), 0);
        QVERIFY(countPixels(loading.image, symbolRect, isPlaceholderFill) > 0);
        QVERIFY(changedPixels(loading, terminal, symbolRect) > 0);

        // And the loading treatment is not what a title with real artwork
        // ends at: the artwork replaces it entirely.
        poster->setProperty("source", request);
        QTRY_COMPARE(poster->property("loadState").toInt(), int(PosterLoadState::Ready));
        QVERIFY(!placeholder->isVisible());
    }

    // MovieCard.swift:215-222 and MovieDetailView.swift:288-292 are the two
    // call sites, and they configure the placeholder differently: the card
    // passes 0 fill and 0 ink, so a title reading its sidecar keeps showing
    // the fallback artwork :209-213 stacked beneath, while the detail poster
    // takes CachedImageView.swift:75-76's defaults, whose elevated fill at
    // full opacity masks whatever :285-286 put beneath it. The proof is over
    // painted pixels of the shipped surfaces, in the one state that
    // distinguishes them: a request in flight.
    void theCardCallSiteKeepsItsFallbackWhileLoadingAndTheDetailPosterMasksIt()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        QTemporaryDir library;
        QVERIFY(writePosterFile(library.path(), QStringLiteral("Arrival-poster.png"),
                                QColor("#00c800")));

        ApplicationController controller;
        controller.settings()->setLeanBackMode(false);

        QQmlApplicationEngine engine;
        engine.rootContext()->setContextProperty(QStringLiteral("appController"), &controller);
        QQmlComponent component(&engine);
        // The shipped card and the shipped details poster side by side, each
        // created the way its own screen creates it: HomeScreen.qml:91 hands
        // PosterCard the model's fields, and DetailsScreen.qml:52-62 sets the
        // poster's source, title, and badge and nothing else.
        component.setData(
            QByteArrayLiteral("import QtQuick\nimport Marquee\n"
                              "Window {\n"
                              "    width: 460; height: 420; visible: true; color: \"#0d0b1a\"\n"
                              "    PosterCard { objectName: \"probeCard\"\n"
                              "                 x: 20; y: 20\n"
                              "                 title: \"Arrival\"; year: 2016; posterUrl: \"\"\n"
                              "                 metadata: \"2016\"; formatBadge: \"MKV\" }\n"
                              "    PosterArt { objectName: \"probeDetail\"\n"
                              "                x: 260; y: 20; width: 150; source: \"\"\n"
                              "                title: \"Arrival\"; badge: \"MKV\" }\n"
                              "}\n"),
            QUrl(QStringLiteral("qrc:/browse-poster-call-site-probe.qml")));
        QVERIFY2(!component.isError(), qPrintable(component.errorString()));
        const std::unique_ptr<QObject> created(component.create());
        auto *window = qobject_cast<QQuickWindow *>(created.get());
        QVERIFY(window != nullptr);
        QVERIFY(QTest::qWaitForWindowExposed(window));

        auto *card = window->findChild<QQuickItem *>(QStringLiteral("probeCard"));
        QVERIFY(card != nullptr);
        QQuickItem *cardPoster = posterSurfaceOf(card);
        auto *detailPoster = window->findChild<QQuickItem *>(QStringLiteral("probeDetail"));
        QVERIFY(cardPoster != nullptr);
        QVERIFY(detailPoster != nullptr);

        // The configuration each call site made, read off the shipped
        // surfaces rather than assumed from a default.
        QCOMPARE(cardPoster->property("placeholderFillOpacity").toReal(), 0.0);
        QCOMPARE(cardPoster->property("placeholderIconOpacity").toReal(), 0.0);
        QCOMPARE(cardPoster->property("placeholderWordmarkOpacity").toReal(), 0.0);
        QCOMPARE(detailPoster->property("placeholderFillOpacity").toReal(), 1.0);
        QCOMPARE(detailPoster->property("placeholderIconOpacity").toReal(), 0.18);
        QCOMPARE(detailPoster->property("placeholderWordmarkOpacity").toReal(), 0.34);

        const QUrl request =
            QUrl::fromLocalFile(QDir(library.path()).filePath(QStringLiteral("Arrival-poster.png")));
        const auto captionOf = [](QQuickItem *poster) {
            return poster->findChild<QQuickItem *>(QStringLiteral("posterFallbackTitle"));
        };
        QQuickItem *cardCaption = captionOf(cardPoster);
        QQuickItem *detailCaption = captionOf(detailPoster);
        QVERIFY(cardCaption != nullptr && detailCaption != nullptr);

        // Both surfaces show their fallback caption before anything is asked
        // of them, so a difference below is the loading treatment and not a
        // surface that never painted.
        const QList<QQuickItem *> measured{cardPoster, detailPoster};
        const auto captionInk = [&](const Capture &capture, QQuickItem *poster) {
            const QRect surfaceRect = imageRectForItem(capture, poster);
            return surfaceRect.isEmpty()
                ? 0
                : countPixels(capture.image, fallbackCaptionBand(capture, surfaceRect),
                              isFallbackCaptionInk);
        };
        const Capture idle = captureWindowUntil(window, measured, [&](const Capture &capture) {
            return captionInk(capture, cardPoster) > 0 && captionInk(capture, detailPoster) > 0;
        });
        QVERIFY(idle.coherent());
        const int idleCardInk = captionInk(idle, cardPoster);
        const int idleDetailInk = captionInk(idle, detailPoster);
        QVERIFY2(idleCardInk > 0 && idleDetailInk > 0,
                 "a poster painted no fallback caption before any request began");

        // Both are put in flight at the shipped state machine's entry point,
        // with no load outstanding to end either.
        QVariant cardGeneration;
        QVariant detailGeneration;
        QVERIFY(beginRequestOn(cardPoster, request, cardGeneration));
        QVERIFY(beginRequestOn(detailPoster, request, detailGeneration));
        QCOMPARE(cardPoster->property("loadState").toInt(), int(PosterLoadState::Loading));
        QCOMPARE(detailPoster->property("loadState").toInt(), int(PosterLoadState::Loading));

        const Capture loading = captureWindowUntil(
            window, measured,
            [&](const Capture &capture) { return captionInk(capture, detailPoster) == 0; });
        QVERIFY(loading.coherent());
        QVERIFY(idle.sameGeometryAs(loading));

        // The card keeps its fallback artwork throughout, as MovieCard.swift's
        // zeroed placeholder does.
        QCOMPARE(captionInk(loading, cardPoster), idleCardInk);
        QCOMPARE(render_probe::changedPixels(idle, loading,
                                             imageRectForItem(idle, cardPoster)),
                 0);

        // The detail poster masks it, as CachedImageView.swift:116-117's
        // elevated fill at full opacity does.
        QCOMPARE(captionInk(loading, detailPoster), 0);
        const QRect detailRect = imageRectForItem(loading, detailPoster);
        QVERIFY(render_probe::changedPixels(idle, loading, detailRect) > 0);
        // The mask is that fill and not a cleared surface: it is the elevated
        // surface colour, away from the centred symbol and wordmark.
        const QPoint fillSample = detailRect.topLeft()
            + QPoint(pixels(loading, 12), pixels(loading, 12));
        QVERIFY2(render_probe::withinTolerance(loading.image.pixelColor(fillSample),
                                               QColor("#1a1525"), 2),
                 qPrintable(QStringLiteral("the default placeholder fill painted %1 at %2")
                                .arg(loading.image.pixelColor(fillSample).name())
                                .arg(QTest::toString(fillSample))));

        // Both hand the surface back once the request ends, so neither
        // configuration leaves a layer behind.
        QVERIFY(completeOn(cardPoster, request, cardGeneration.toInt(), false));
        QVERIFY(completeOn(detailPoster, request, detailGeneration.toInt(), false));
        const Capture settled = captureWindowUntil(
            window, measured,
            [&](const Capture &capture) { return captionInk(capture, detailPoster) > 0; });
        QVERIFY(settled.coherent() && idle.sameGeometryAs(settled));
        QCOMPARE(captionInk(settled, detailPoster), idleDetailInk);
        QCOMPARE(captionInk(settled, cardPoster), idleCardInk);
    }

    // HomeDetailView.swift:301-389's sticky title bar, drawn over the scrolled
    // surface whenever the library has content: the MARQUEE wordmark at the
    // released sizes and tracking, the Play Something capsule, and the trailing
    // count, all inset by the page's own outer padding.
    void homeModes_data()
    {
        QTest::addColumn<bool>("leanBack");
        QTest::addColumn<int>("openBarHeight");
        QTest::addColumn<int>("compactBarHeight");
        QTest::addColumn<int>("openWordmarkSize");
        QTest::addColumn<int>("compactWordmarkSize");
        QTest::addColumn<int>("tracking");
        QTest::addColumn<int>("controlTextSize");
        QTest::addColumn<int>("outerPadding");
        QTest::addColumn<int>("topSpacer");

        // :365's bar heights, :305-309's wordmark sizes and tracking,
        // :318/:332/:335/:360's 11/16-point control and count type,
        // MarqueeTheme.swift:214-216's outer padding, and :201's leading
        // spacer.
        QTest::newRow("compact") << false << 78 << 44 << 26 << 18 << 5 << 11 << 48 << 120;
        QTest::newRow("lean-back") << true << 108 << 62 << 38 << 28 << 8 << 16 << 72 << 170;
    }

    void homeTitleBarMatchesTheReleasedStickyHeader_data() { homeModes_data(); }

    void homeTitleBarMatchesTheReleasedStickyHeader()
    {
        QFETCH(bool, leanBack);
        QFETCH(int, openBarHeight);
        QFETCH(int, openWordmarkSize);
        QFETCH(int, tracking);
        QFETCH(int, controlTextSize);
        QFETCH(int, outerPadding);
        QFETCH(int, topSpacer);

        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        QTemporaryDir library;
        for (const QString &name : sampleTitles()) {
            QVERIFY(writeMediaFile(library.path(), name));
        }

        ApplicationController controller;
        controller.settings()->setLeanBackMode(leanBack);
        controller.setTemporaryLibraryRoot(library.path());
        QTRY_COMPARE(controller.library()->rowCount(), 16);

        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY2(window != nullptr, "qml/Main.qml did not load from the module");
        controller.navigation()->goHome();
        QVERIFY(QTest::qWaitForWindowExposed(window));

        QQuickItem *view = nullptr;
        QTRY_VERIFY((view = grid(window)) != nullptr);
        QTRY_COMPARE(view->property("count").toInt(), 8);
        QQuickItem *scroll = scrollOf(window);
        QVERIFY(scroll != nullptr);

        QQuickItem *titleBar = window->findChild<QQuickItem *>(QStringLiteral("homeTitleBar"));
        QQuickItem *surface =
            window->findChild<QQuickItem *>(QStringLiteral("homeTitleBarSurface"));
        QQuickItem *wordmark = window->findChild<QQuickItem *>(QStringLiteral("homeWordmark"));
        QQuickItem *count = window->findChild<QQuickItem *>(QStringLiteral("homeTitleCount"));
        QQuickItem *playLabel =
            window->findChild<QQuickItem *>(QStringLiteral("homePlaySomethingLabel"));
        QQuickItem *playSymbol =
            window->findChild<QQuickItem *>(QStringLiteral("homePlaySomethingSymbol"));
        QQuickItem *sidebar = window->findChild<QQuickItem *>(QStringLiteral("sidebar"));
        QVERIFY(titleBar != nullptr);
        QVERIFY(surface != nullptr);
        QVERIFY(wordmark != nullptr);
        QVERIFY(count != nullptr);
        QVERIFY(playLabel != nullptr);
        QVERIFY(playSymbol != nullptr);
        QVERIFY(sidebar != nullptr);
        QVERIFY(titleBar->isVisible());

        // The bar is pinned at the top of the surface and spans it.
        QCOMPARE(qRound(titleBar->y()), 0);
        QCOMPARE(qRound(titleBar->width()), qRound(titleBar->parentItem()->width()));

        // :365's open bar height, over :366's top padding.
        QCOMPARE(qRound(titleBar->property("barHeight").toReal()), openBarHeight);
        QCOMPARE(qRound(surface->height()),
                 qRound(titleBar->property("topPadding").toReal()) + openBarHeight);

        // :304-309's wordmark size and tracking.
        QCOMPARE(qRound(wordmark->property("pointSize").toReal()), openWordmarkSize);
        QCOMPARE(qRound(wordmark->property("tracking").toReal()), tracking);

        // :318, :332-335, and :360 all use the same 11/16-point face.
        QCOMPARE(playLabel->property("font").value<QFont>().pixelSize(), controlTextSize);
        QCOMPARE(count->property("font").value<QFont>().pixelSize(), controlTextSize);
        QCOMPARE(qRound(playSymbol->property("pointSize").toReal()), controlTextSize);
        QCOMPARE(playSymbol->property("symbol").toString(), QStringLiteral("shuffle"));

        // :363 insets the row by the page's outer padding on both sides, and
        // :357-361 pushes the count to the trailing edge.
        QQuickItem *content = window->contentItem();
        const QRectF sidebarRect = sidebar->mapRectToItem(content, sidebar->boundingRect());
        const QRectF wordmarkRect = wordmark->mapRectToItem(content, wordmark->boundingRect());
        const QRectF countRect = count->mapRectToItem(content, count->boundingRect());
        QCOMPARE(qRound(wordmarkRect.left() - sidebarRect.right()), outerPadding);
        QCOMPARE(qRound(content->width() - countRect.right()), outerPadding);

        // :360-361's tertiary ink on the count, and :319's secondary on the
        // scan label when it is drawn.
        QCOMPARE(count->property("color").value<QColor>(), QColor("#6b6178"));

        // :201's leading spacer is the room the bar is drawn over, so the
        // first row of cards begins below it rather than under the wordmark.
        QCOMPARE(qRound(scroll->property("topMargin").toReal()), topSpacer);
        QVERIFY2(topSpacer >= qRound(surface->height()),
                 "the released spacer must clear the open title bar");
    }

    // :385-389 counts the projection: both numbers, singular only at one, and
    // nothing at all when the library holds neither. The v3 catalog models no
    // episode, so the episode half is always zero here and says so.
    void homeTitleCountNamesTheProjectedLibrary()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        QTemporaryDir library;
        QVERIFY(writeMediaFile(library.path(), QStringLiteral("Arrival.2016.mkv")));

        ApplicationController controller;
        controller.settings()->setLeanBackMode(false);
        controller.setTemporaryLibraryRoot(library.path());
        QTRY_COMPARE(controller.library()->rowCount(), 1);

        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY2(window != nullptr, "qml/Main.qml did not load from the module");
        controller.navigation()->goHome();

        QQuickItem *view = nullptr;
        QTRY_VERIFY((view = grid(window)) != nullptr);
        QTRY_COMPARE(view->property("count").toInt(), 1);

        QQuickItem *count = window->findChild<QQuickItem *>(QStringLiteral("homeTitleCount"));
        QVERIFY(count != nullptr);
        // One title is singular on the left and the empty episode set plural
        // on the right, either side of :388's double-spaced slash.
        QTRY_COMPARE(count->property("text").toString(),
                     QStringLiteral("1 movie  /  0 episodes"));

        // The count follows the projection rather than the delegates the grid
        // happens to have realized.
        QCOMPARE(controller.library()->titleCount(), 1);

        QVector<MediaItem> grown;
        for (int index = 0; index < 3; ++index) {
            grown.push_back(MediaItem{.id = QStringLiteral("root/%1").arg(index),
                                      .libraryRootId = QStringLiteral("root"),
                                      .relativePath = QStringLiteral("%1.mkv").arg(index),
                                      .absolutePath = QStringLiteral("/library/%1.mkv").arg(index),
                                      .title = QStringLiteral("Title %1").arg(index),
                                      .sortTitle = QStringLiteral("title %1").arg(index),
                                      .mediaKind = QStringLiteral("movie"),
                                      .year = 2020,
                                      .durationSeconds = 0,
                                      .posterRelativePath = QString(),
                                      .posterAbsolutePath = QString(),
                                      .fileSize = 1024,
                                      .modifiedAt = QDateTime::currentDateTimeUtc(),
                                      .resumePositionMs = 0,
                                      .watched = false,
                                      .showName = QString(),
                                      .seasonNumber = 0,
                                      .episodeNumber = 0,
                                      .episodeTitle = QString(),
                                      .showPosterRelativePath = QString(),
                                      .showPosterAbsolutePath = QString(),
                                      .showBackdropRelativePath = QString(),
                                      .showBackdropAbsolutePath = QString(),
                                      .seasonPosterRelativePath = QString(),
                                      .seasonPosterAbsolutePath = QString(),
                                      .episodeStillRelativePath = QString(),
                                      .episodeStillAbsolutePath = QString()});
        }
        controller.library()->replaceItems(grown);
        QTRY_COMPARE(count->property("text").toString(),
                     QStringLiteral("3 movies  /  0 episodes"));

        // :387 shows nothing at all rather than a pair of zeroes.
        controller.library()->replaceItems({});
        QTRY_COMPARE(count->property("text").toString(), QString());
    }

    void homeHeaderCollapsesPastSixtyPointsOfScroll_data() { homeModes_data(); }

    // :141-143 collapses the bar past 60 points of scroll, and :305-307,
    // :365-366 give the collapsed bar its own smaller wordmark, height, and
    // padding; :370-375 widens its trailing fade from 6 to 20.
    void homeHeaderCollapsesPastSixtyPointsOfScroll()
    {
        QFETCH(bool, leanBack);
        QFETCH(int, openBarHeight);
        QFETCH(int, compactBarHeight);
        QFETCH(int, openWordmarkSize);
        QFETCH(int, compactWordmarkSize);

        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        QTemporaryDir library;
        for (const QString &name : sampleTitles()) {
            QVERIFY(writeMediaFile(library.path(), name));
        }

        ApplicationController controller;
        controller.settings()->setLeanBackMode(leanBack);
        // The collapse is measured at its own threshold, so the placement it
        // causes must not be animated past it while the offset is read.
        controller.settings()->setReduceMotion(true);
        controller.setTemporaryLibraryRoot(library.path());
        QTRY_COMPARE(controller.library()->rowCount(), 16);

        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY2(window != nullptr, "qml/Main.qml did not load from the module");
        controller.navigation()->goHome();
        QVERIFY(QTest::qWaitForWindowExposed(window));

        QQuickItem *view = nullptr;
        QTRY_VERIFY((view = grid(window)) != nullptr);
        QTRY_COMPARE(view->property("count").toInt(), 8);
        QQuickItem *scroll = scrollOf(window);
        QVERIFY(scroll != nullptr);

        QQuickItem *titleBar = window->findChild<QQuickItem *>(QStringLiteral("homeTitleBar"));
        QVERIFY(titleBar != nullptr);
        QQuickItem *home = titleBar->parentItem();
        QQuickItem *wordmark = window->findChild<QQuickItem *>(QStringLiteral("homeWordmark"));
        QQuickItem *fade = window->findChild<QQuickItem *>(QStringLiteral("homeTitleBarFade"));
        QVERIFY(home != nullptr);
        QVERIFY(wordmark != nullptr);
        QVERIFY(fade != nullptr);

        // The surface must have somewhere to scroll, or the threshold below is
        // never crossed and the case proves nothing.
        QTRY_VERIFY2(scroll->property("contentHeight").toReal()
                         + scroll->property("topMargin").toReal()
                         + scroll->property("bottomMargin").toReal()
                     > scroll->height() + 60,
                     "the fixture library must overflow the surface by the threshold");

        // The grid is the surface's one scroll authority: its own content
        // offset is what the collapse is measured against, so there is no
        // second scroller to disagree with it.
        const qreal restingOffset = home->property("scrollOffset").toReal();
        QCOMPARE(qRound(restingOffset), 0);
        QVERIFY(!home->property("compactHeader").toBool());
        QCOMPARE(qRound(titleBar->property("barHeight").toReal()), openBarHeight);
        QCOMPARE(qRound(wordmark->property("pointSize").toReal()), openWordmarkSize);
        QCOMPARE(qRound(fade->height()), 6);

        // Exactly at the threshold the bar is still open: :142 collapses past
        // 60 points, not at them.
        const qreal topMargin = scroll->property("topMargin").toReal();
        scroll->setProperty("contentY", 60.0 - topMargin);
        QTRY_COMPARE(qRound(home->property("scrollOffset").toReal()), 60);
        QVERIFY2(!home->property("compactHeader").toBool(),
                 "the header collapsed at the threshold rather than past it");
        QCOMPARE(qRound(titleBar->property("barHeight").toReal()), openBarHeight);

        // One point past it, every collapsing measurement takes its compact
        // value at once, because motion is reduced.
        scroll->setProperty("contentY", 61.0 - topMargin);
        QTRY_VERIFY(home->property("compactHeader").toBool());
        QCOMPARE(qRound(titleBar->property("barHeight").toReal()), compactBarHeight);
        QCOMPARE(qRound(wordmark->property("pointSize").toReal()), compactWordmarkSize);
        QCOMPARE(qRound(fade->height()), 20);

        // Scrolling back opens it again: the collapse follows the offset
        // rather than latching once.
        scroll->setProperty("contentY", -topMargin);
        QTRY_VERIFY(!home->property("compactHeader").toBool());
        QCOMPARE(qRound(titleBar->property("barHeight").toReal()), openBarHeight);
        QCOMPARE(qRound(fade->height()), 6);
    }

    // MarqueeTheme.swift:273-275 withholds motion when it is reduced, and
    // :368/:377 otherwise settle the collapse in :256's spring. The declared
    // duration is asserted with motion on and the transition refused with it
    // off, rather than timing a frame.
    void homeHeaderCollapseRespectsReduceMotion()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        QTemporaryDir library;
        for (const QString &name : sampleTitles()) {
            QVERIFY(writeMediaFile(library.path(), name));
        }

        ApplicationController controller;
        controller.settings()->setLeanBackMode(false);
        controller.settings()->setReduceMotion(false);
        controller.setTemporaryLibraryRoot(library.path());
        QTRY_COMPARE(controller.library()->rowCount(), 16);

        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY2(window != nullptr, "qml/Main.qml did not load from the module");
        controller.navigation()->goHome();
        QVERIFY(QTest::qWaitForWindowExposed(window));

        QQuickItem *view = nullptr;
        QTRY_VERIFY((view = grid(window)) != nullptr);
        QTRY_COMPARE(view->property("count").toInt(), 8);
        QQuickItem *scroll = scrollOf(window);
        QVERIFY(scroll != nullptr);

        QQuickItem *titleBar = window->findChild<QQuickItem *>(QStringLiteral("homeTitleBar"));
        QVERIFY(titleBar != nullptr);

        // `animation` is a deferred property of Behavior, so QtQuick builds the
        // declared NumberAnimation only when an enabled Behavior first
        // intercepts a write, as tst_sidebar_navigation.cpp records for the
        // route lift. Nothing has collapsed yet, so neither spring exists.
        QVERIFY(titleBar->findChild<QObject *>(QStringLiteral("homeHeaderHeightSpring"))
                == nullptr);
        QVERIFY(titleBar->findChild<QObject *>(QStringLiteral("homeHeaderPaddingSpring"))
                == nullptr);

        const qreal topMargin = scroll->property("topMargin").toReal();
        // The surface must have somewhere to scroll, or the collapse below is
        // an assignment the Flickable clamps away and the case proves nothing.
        QQuickItem *home = titleBar->parentItem();
        QVERIFY(home != nullptr);
        qreal reach = 0.0;
        QTRY_VERIFY2([&] {
                         reach = scroll->property("contentHeight").toReal()
                             + scroll->property("topMargin").toReal()
                             + scroll->property("bottomMargin").toReal()
                             - scroll->height();
                         return reach > 60.0;
                     }(),
                     qPrintable(QStringLiteral("the fixture library must overflow the "
                                               "surface past the 60-point threshold; it "
                                               "reaches %1")
                                    .arg(reach)));

        // Past the threshold, but only as far as the surface can actually go,
        // so the collapse follows a scroll that really happened.
        const qreal collapsed = std::min(400.0, reach);
        QVERIFY(collapsed > 60.0);
        scroll->setProperty("contentY", collapsed - topMargin);
        // The scroll really moved: the offset the collapse is measured from is
        // the distance the grid actually travelled, not the value assigned to
        // it, so a clamped assignment cannot stand in for a collapse.
        QTRY_COMPARE(qRound(home->property("scrollOffset").toReal()), qRound(collapsed));
        QVERIFY(home->property("compactHeader").toBool());

        // That intercepted write is what instantiates the animations, so the
        // duration is read off the objects HomeScreen.qml actually built.
        auto *heightSpring =
            titleBar->findChild<QObject *>(QStringLiteral("homeHeaderHeightSpring"));
        auto *paddingSpring =
            titleBar->findChild<QObject *>(QStringLiteral("homeHeaderPaddingSpring"));
        QVERIFY(heightSpring != nullptr);
        QVERIFY(paddingSpring != nullptr);

        // The approximation of :256's response-0.35 spring the surface
        // declares. Its 0.6 damping bounce is not reproduced; that remains an
        // open parity gap rather than a settled value.
        QCOMPARE(heightSpring->property("duration").toInt(), 350);
        QCOMPARE(paddingSpring->property("duration").toInt(), 350);

        // With motion on the collapse is a transition, so the bar settles on
        // the compact height rather than taking it in the write above.
        QTRY_COMPARE(qRound(titleBar->property("barHeight").toReal()), 44);

        // Reduced, the same collapse is applied without any animation running,
        // and each step is a scroll the surface really made, bounded by the
        // reach measured above so a clamped assignment cannot stand in for one.
        controller.settings()->setReduceMotion(true);
        scroll->setProperty("contentY", -topMargin);
        QTRY_COMPARE(qRound(home->property("scrollOffset").toReal()), 0);
        QTRY_COMPARE(qRound(titleBar->property("barHeight").toReal()), 78);
        scroll->setProperty("contentY", collapsed - topMargin);
        QCOMPARE(qRound(home->property("scrollOffset").toReal()), qRound(collapsed));
        QCOMPARE(qRound(titleBar->property("barHeight").toReal()), 44);
        QVERIFY(!heightSpring->property("running").toBool());
        QVERIFY(!paddingSpring->property("running").toBool());
    }

    // The collapse threshold under real input rather than an assignment:
    // :141-143 measures it against the surface's own scroll offset, so a wheel
    // over the grid must move the scene and take the header with it. The
    // fixture's reach is measured first and the wheel's own clamped result is
    // read from the surface, so nothing here depends on a scroll the page
    // could not make.
    void aWheelOverHomeScrollsTheSurfaceAndCollapsesItsHeader()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        QTemporaryDir library;
        for (const QString &name : sampleTitles()) {
            QVERIFY(writeMediaFile(library.path(), name));
        }

        ApplicationController controller;
        controller.settings()->setLeanBackMode(false);
        // The collapse is read at the offset the wheel produced, so the
        // header must take its compact measurements in that same frame.
        controller.settings()->setReduceMotion(true);
        controller.setTemporaryLibraryRoot(library.path());
        QTRY_COMPARE(controller.library()->rowCount(), 16);

        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY2(window != nullptr, "qml/Main.qml did not load from the module");
        controller.navigation()->goHome();
        QVERIFY(QTest::qWaitForWindowExposed(window));

        QQuickItem *view = nullptr;
        QTRY_VERIFY((view = grid(window)) != nullptr);
        QTRY_COMPARE(view->property("count").toInt(), 8);
        QQuickItem *scroll = scrollOf(window);
        QVERIFY(scroll != nullptr);

        QQuickItem *titleBar = window->findChild<QQuickItem *>(QStringLiteral("homeTitleBar"));
        QVERIFY(titleBar != nullptr);
        QQuickItem *home = titleBar->parentItem();
        QQuickItem *content = window->contentItem();
        QVERIFY(home != nullptr);

        // How far this fixture can actually travel. The threshold has to lie
        // inside it, or the wheel below would be clamped short of a collapse
        // and the case would prove nothing.
        qreal reach = 0.0;
        QTRY_VERIFY2([&] {
                         reach = scroll->property("contentHeight").toReal()
                             + scroll->property("topMargin").toReal()
                             + scroll->property("bottomMargin").toReal()
                             - scroll->height();
                         return reach > 60.0;
                     }(),
                     qPrintable(QStringLiteral("the fixture library must overflow the surface "
                                               "past the 60-point threshold; it reaches %1")
                                    .arg(reach)));

        QQuickItem *firstCard = cardAt(view, 0);
        QVERIFY(firstCard != nullptr);
        const qreal cardAtRest =
            firstCard->mapRectToItem(content, firstCard->boundingRect()).top();
        QCOMPARE(qRound(home->property("scrollOffset").toReal()), 0);
        QVERIFY(!home->property("compactHeader").toBool());

        // A real wheel over the grid, delivered where a card is drawn, as the
        // Movies route's own overflow case drives its page.
        const QPointF wheelAt(scroll->mapToScene(QPointF(scroll->width() / 2, scroll->height() / 2)));
        QTest::wheelEvent(window, wheelAt, QPoint(0, -240), QPoint(0, -240));
        QTRY_VERIFY2(home->property("scrollOffset").toReal() > 60.0,
                     "the wheel did not scroll the surface past the collapse threshold");
        QTRY_VERIFY(!scroll->property("moving").toBool());
        QTRY_VERIFY(!scroll->property("flicking").toBool());

        const qreal offset = home->property("scrollOffset").toReal();
        // The wheel's result is what the surface could travel, never more.
        QVERIFY2(offset <= reach + 1.0,
                 qPrintable(QStringLiteral("the surface reported %1 of travel past its own "
                                           "reach of %2")
                                .arg(offset).arg(reach)));

        // The scene really moved: the first card is drawn exactly that far up
        // the window, so the offset the header collapses on is a displacement
        // rather than a value written to a property.
        QQuickItem *cardNow = cardAt(view, 0);
        QVERIFY(cardNow != nullptr);
        const qreal cardMoved =
            cardAtRest - cardNow->mapRectToItem(content, cardNow->boundingRect()).top();
        QVERIFY2(qAbs(cardMoved - offset) < 1.0,
                 qPrintable(QStringLiteral("the surface reported %1 of scroll while its first "
                                           "card moved %2")
                                .arg(offset).arg(cardMoved)));

        QVERIFY(home->property("compactHeader").toBool());
        QCOMPARE(qRound(titleBar->property("barHeight").toReal()), 44);

        // And back: an opposite wheel returns the surface, and the header
        // follows the offset rather than latching once.
        QTest::wheelEvent(window, wheelAt, QPoint(0, 240), QPoint(0, 240));
        QTRY_COMPARE(qRound(home->property("scrollOffset").toReal()), 0);
        QTRY_VERIFY(!scroll->property("moving").toBool());
        QVERIFY(!home->property("compactHeader").toBool());
        QCOMPARE(qRound(titleBar->property("barHeight").toReal()), 78);

        QQuickItem *cardBack = cardAt(view, 0);
        QVERIFY(cardBack != nullptr);
        QVERIFY(qAbs(cardBack->mapRectToItem(content, cardBack->boundingRect()).top()
                     - cardAtRest)
                < 1.0);
    }

    // :192-193 and :312-327: a library with nothing in it yet shows the
    // scanning state rather than the empty state, and a populated library
    // being rescanned shows the header capsule instead.
    void homeShowsTheScanningStateWhileTheLibraryIsStillEmpty()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        ApplicationController controller;
        controller.settings()->setLeanBackMode(false);
        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY2(window != nullptr, "qml/Main.qml did not load from the module");
        controller.navigation()->goHome();

        QQuickItem *home = nullptr;
        QTRY_VERIFY((home = window->findChild<QQuickItem *>(QStringLiteral("libraryScanState")))
                    != nullptr);
        QQuickItem *screen = home->parentItem();
        QVERIFY(screen != nullptr);
        QQuickItem *empty = window->findChild<QQuickItem *>(QStringLiteral("libraryEmptyState"));
        QQuickItem *ring = window->findChild<QQuickItem *>(QStringLiteral("libraryScanRing"));
        QQuickItem *logo = window->findChild<QQuickItem *>(QStringLiteral("libraryScanLogo"));
        QQuickItem *view = rowsViewport(window);
        QVERIFY(empty != nullptr);
        QVERIFY(ring != nullptr);
        QVERIFY(logo != nullptr);
        QVERIFY(view != nullptr);

        // A real scan settles faster than a frame can be observed, so the
        // surface's own scanning input is driven directly, exactly as the
        // poster surface's request state is.
        screen->setProperty("scanning", true);
        QTRY_VERIFY(home->isVisible());
        QVERIFY(!empty->isVisible());

        // :409-410 and :443-446 size the ring and the logo.
        QCOMPARE(qRound(ring->width()), 160);
        QCOMPARE(qRound(ring->height()), 160);
        QCOMPARE(qRound(logo->width()), 88);
        QCOMPARE(qRound(logo->height()), 88);
        QTRY_COMPARE(logo->property("status").toInt(), 1); // Image.Ready

        // The scan state is the whole surface: no title bar, no fade, and no
        // grid, which :191-197 draws only in the other branch.
        QQuickItem *titleBar = window->findChild<QQuickItem *>(QStringLiteral("homeTitleBar"));
        QVERIFY(titleBar != nullptr);
        QVERIFY(!titleBar->isVisible());
        QVERIFY(!view->isVisible());

        // With the scan ended and still nothing found, :195's empty state
        // replaces it.
        screen->setProperty("scanning", false);
        QTRY_VERIFY(empty->isVisible());
        QVERIFY(!home->isVisible());
    }

    // :431-438 and :460-467 run the ring and the logo for ever while the
    // scanning state is on screen. Neither is drawn in any other state, and an
    // infinite animation that nothing draws is only work: both must stop
    // whenever the surface is not showing that state, and under Reduce Motion.
    void theScanMarkAnimatesOnlyWhileTheScanStateIsShown()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        ApplicationController controller;
        controller.settings()->setLeanBackMode(false);
        controller.settings()->setReduceMotion(false);
        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY2(window != nullptr, "qml/Main.qml did not load from the module");
        controller.navigation()->goHome();

        QQuickItem *scanState = nullptr;
        QTRY_VERIFY((scanState = window->findChild<QQuickItem *>(
                         QStringLiteral("libraryScanState")))
                    != nullptr);
        QQuickItem *screen = scanState->parentItem();
        QVERIFY(screen != nullptr);
        auto *ringSpin = window->findChild<QObject *>(QStringLiteral("libraryScanRingSpin"));
        auto *logoBreath = window->findChild<QObject *>(QStringLiteral("libraryScanLogoBreath"));
        auto *capsule = window->findChild<QQuickItem *>(QStringLiteral("homeScanningCapsule"));
        auto *capsuleSpin =
            window->findChild<QObject *>(QStringLiteral("homeScanningSpinnerSpin"));
        QVERIFY(ringSpin != nullptr);
        QVERIFY(logoBreath != nullptr);
        QVERIFY(capsule != nullptr);
        QVERIFY(capsuleSpin != nullptr);
        // The shell's own first scan of an unconfigured library settles before
        // the surface's scanning input is driven, so its empty projection
        // cannot land on top of the states below.
        QTRY_VERIFY(!controller.scanning());

        const auto ringRunning = [&] { return ringSpin->property("running").toBool(); };
        const auto logoRunning = [&] { return logoBreath->property("running").toBool(); };
        const auto capsuleRunning = [&] { return capsuleSpin->property("running").toBool(); };

        // An empty library being scanned: the state is on screen and both of
        // its marks turn. The header capsule belongs to the other branch and
        // is not drawn here.
        screen->setProperty("scanning", true);
        QTRY_VERIFY(scanState->isVisible());
        QVERIFY(ringRunning());
        QVERIFY(logoRunning());
        QVERIFY(!capsule->isVisible());
        QVERIFY(!capsuleRunning());

        // A populated library rescanning draws the capsule instead, so the
        // scan state's own marks stop even though the scan continues.
        QVector<MediaItem> projected;
        projected.push_back(MediaItem{.id = QStringLiteral("root/arrival"),
                                      .libraryRootId = QStringLiteral("root"),
                                      .relativePath = QStringLiteral("Arrival.mkv"),
                                      .absolutePath = QStringLiteral("/library/Arrival.mkv"),
                                      .title = QStringLiteral("Arrival"),
                                      .sortTitle = QStringLiteral("arrival"),
                                      .mediaKind = QStringLiteral("movie"),
                                      .year = 2016,
                                      .durationSeconds = 0,
                                      .posterRelativePath = QString(),
                                      .posterAbsolutePath = QString(),
                                      .fileSize = 1024,
                                      .modifiedAt = QDateTime::currentDateTimeUtc(),
                                      .resumePositionMs = 0,
                                      .watched = false,
                                      .showName = QString(),
                                      .seasonNumber = 0,
                                      .episodeNumber = 0,
                                      .episodeTitle = QString(),
                                      .showPosterRelativePath = QString(),
                                      .showPosterAbsolutePath = QString(),
                                      .showBackdropRelativePath = QString(),
                                      .showBackdropAbsolutePath = QString(),
                                      .seasonPosterRelativePath = QString(),
                                      .seasonPosterAbsolutePath = QString(),
                                      .episodeStillRelativePath = QString(),
                                      .episodeStillAbsolutePath = QString()});
        controller.library()->replaceItems(projected);
        QTRY_VERIFY(!scanState->isVisible());
        QTRY_VERIFY(capsule->isVisible());
        QVERIFY2(!ringRunning(), "the scan ring kept turning behind a populated library");
        QVERIFY2(!logoRunning(), "the scan logo kept breathing behind a populated library");
        QVERIFY(capsuleRunning());

        // A finished scan on an empty library shows the empty state, and
        // nothing animates in it.
        controller.library()->replaceItems({});
        QTRY_VERIFY(scanState->isVisible());
        QVERIFY(ringRunning());
        screen->setProperty("scanning", false);
        QTRY_VERIFY(!scanState->isVisible());
        QVERIFY2(!ringRunning(), "the scan ring kept turning after the scan ended");
        QVERIFY2(!logoRunning(), "the scan logo kept breathing after the scan ended");
        QVERIFY(!capsuleRunning());

        // Reduce Motion holds both still while the state is shown, and turning
        // it back off starts them again, because the state is still on screen.
        controller.settings()->setReduceMotion(true);
        screen->setProperty("scanning", true);
        QTRY_VERIFY(scanState->isVisible());
        QVERIFY(!ringRunning());
        QVERIFY(!logoRunning());
        controller.settings()->setReduceMotion(false);
        QTRY_VERIFY(ringRunning());
        QVERIFY(logoRunning());
    }

    // HomeDetailView.swift:413-424 strokes the trimmed arc with an
    // `AngularGradient` about the ring's own centre, so a point's colour
    // follows its angle around that centre rather than its position across the
    // canvas. A diagonal linear fill cannot produce that: it puts one ramp
    // along the canvas diagonal, which reaches every colour of the ramp on
    // the arc's own straight-ish top run and repeats colours symmetrically
    // about that diagonal. The arc's painted colour distribution is therefore
    // measured against the angular law itself, at the ring's own geometry.
    void theScanArcSweepsItsGoldsAroundTheRingNotAcrossIt()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        ApplicationController controller;
        controller.settings()->setLeanBackMode(false);
        // A turning arc would move under the grab; the released sweep is a
        // property of the paint, not of the rotation carrying it.
        controller.settings()->setReduceMotion(true);
        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY2(window != nullptr, "qml/Main.qml did not load from the module");
        controller.navigation()->goHome();
        QVERIFY(QTest::qWaitForWindowExposed(window));

        QQuickItem *scanState = nullptr;
        QTRY_VERIFY((scanState = window->findChild<QQuickItem *>(
                         QStringLiteral("libraryScanState")))
                    != nullptr);
        QQuickItem *screen = scanState->parentItem();
        QQuickItem *ring = window->findChild<QQuickItem *>(QStringLiteral("libraryScanRing"));
        QQuickItem *logo = window->findChild<QQuickItem *>(QStringLiteral("libraryScanLogo"));
        QVERIFY(screen != nullptr);
        QVERIFY(ring != nullptr);
        QVERIFY(logo != nullptr);
        screen->setProperty("scanning", true);
        QTRY_VERIFY(scanState->isVisible());
        QCOMPARE(qRound(ring->width()), 160);
        QCOMPARE(ring->rotation(), 0.0);

        // MarqueeTheme.swift:142-144's three golds in :416-421's own order.
        const QColor golds[] = {QColor("#c9a84c"), QColor("#e8d08c"), QColor("#d4af5c")};
        // The released sweep runs from the trim's start clockwise; three
        // colours are spaced evenly over the full turn, so the trimmed 0.3
        // shows only the first 0.6 of the first-to-second leg.
        const auto expectedAt = [&golds](qreal turn) {
            const qreal position = turn / 0.5;
            const int leg = position < 1.0 ? 0 : 1;
            const qreal blend = position - leg;
            const QColor &from = golds[leg];
            const QColor &to = golds[leg + 1];
            return QColor(qRound(from.red() + (to.red() - from.red()) * blend),
                          qRound(from.green() + (to.green() - from.green()) * blend),
                          qRound(from.blue() + (to.blue() - from.blue()) * blend));
        };

        const QList<QQuickItem *> items{ring, logo, scanState};
        const QColor restingRing("#231d30");
        // Qt's `arc` starts at three o'clock and sweeps with increasing angle,
        // which in image coordinates runs clockwise, exactly as SwiftUI's
        // `Circle().trim(from:to:)` does, so a fraction of the turn names the
        // same point on both. The 3-point stroke is centred on the ring's own
        // radius; a sample is located by scanning that radius and its two
        // physical neighbours and taking the most stroke-covered of them,
        // which the golds' red channel identifies without reference to the
        // colour the sweep is expected to hold there. Locating the band is a
        // lookup; the assertion is the colour found on it.
        const auto sampleAt = [&](const Capture &capture, qreal turn) {
            const QRectF ringRect(imageRectForItem(capture, ring));
            const qreal radius = ringRect.width() / 2.0 - pixels(capture, 1.5);
            const QPointF centre = ringRect.center();
            const qreal angle = turn * 2 * std::numbers::pi;
            QColor best;
            for (int step = -1; step <= 1; ++step) {
                const qreal at = radius + step;
                const QPoint pixel(int(std::floor(centre.x() + at * std::cos(angle))),
                                   int(std::floor(centre.y() + at * std::sin(angle))));
                if (!capture.image.rect().contains(pixel)) {
                    continue;
                }
                const QColor candidate = capture.image.pixelColor(pixel);
                if (!best.isValid() || candidate.red() > best.red()) {
                    best = candidate;
                }
            }
            return best;
        };

        // The arc has painted when its start bears gold rather than the
        // resting ring's surface layer.
        const Capture painted = captureWindowUntil(
            window, items, [&](const Capture &capture) {
                const QRect ringRect = imageRectForItem(capture, ring);
                if (ringRect.isEmpty()) {
                    return false;
                }
                return render_probe::withinTolerance(sampleAt(capture, 0.02),
                                                     expectedAt(0.02), 24);
            });
        QVERIFY(painted.coherent());
        const QRectF ringRect(imageRectForItem(painted, ring));
        QVERIFY(!ringRect.isEmpty());

        // Along the trimmed arc, every sample is the gold the angular ramp
        // holds at that angle. A stroke filled by a gradient laid across the
        // canvas cannot satisfy this: the diagonal ramp reaches its far end
        // near the arc's own start and would be far from these colours.
        int sampled = 0;
        QStringList wrong;
        for (int step = 1; step < 30; ++step) {
            const qreal turn = 0.3 * step / 30.0;
            const QColor pixel = sampleAt(painted, turn);
            ++sampled;
            if (!render_probe::withinTolerance(pixel, expectedAt(turn), 24)) {
                wrong << QStringLiteral("turn %1 painted %2 expected %3")
                             .arg(turn, 0, 'f', 3).arg(pixel.name())
                             .arg(expectedAt(turn).name());
            }
        }
        QCOMPARE(sampled, 29);
        QVERIFY2(wrong.isEmpty(),
                 qPrintable(QStringLiteral("%1 of %2 arc samples are not the angular sweep's "
                                           "own gold: %3")
                                .arg(wrong.size()).arg(sampled)
                                .arg(wrong.mid(0, 8).join(QLatin1Char(' ')))));

        // The distribution itself: the ramp moves monotonically from the first
        // gold towards the second along the arc, so the last sample is
        // measurably lighter than the first. A linear fill across the canvas
        // reverses or repeats that ordering depending on where the arc runs.
        const QColor arcStart = sampleAt(painted, 0.01);
        const QColor arcEnd = sampleAt(painted, 0.29);
        QVERIFY2(arcEnd.green() > arcStart.green() + 10,
                 qPrintable(QStringLiteral("the arc does not lighten along its sweep: %1 to %2")
                                .arg(arcStart.name()).arg(arcEnd.name())));

        // Beyond the trim there is no arc at all: :414 trims the stroke to
        // 0.3, so the rest of the circle carries the resting ring in the
        // surface layer or the page behind it, and none of the sweep's golds.
        // Every gold is far brighter than either, so the red channel alone
        // separates them without depending on which of the two a sample lands
        // on.
        for (const qreal turn : {0.45, 0.6, 0.85}) {
            const QColor beyond = sampleAt(painted, turn);
            QVERIFY2(beyond.red() < 100,
                     qPrintable(QStringLiteral("the arc was painted past its 0.3 trim: %1 at "
                                               "%2 turn")
                                    .arg(beyond.name()).arg(turn)));
            QVERIFY2(render_probe::withinTolerance(beyond, restingRing, 24)
                         || render_probe::withinTolerance(beyond, QColor("#0d0b1a"), 24),
                     qPrintable(QStringLiteral("%1 past the trim at %2 turn is neither the "
                                               "resting ring nor the page")
                                    .arg(beyond.name()).arg(turn)));
        }

        // And the arc is on the ring's own band rather than beside it: four
        // points outside it is the state's own background, never gold.
        for (const qreal turn : {0.05, 0.15, 0.25}) {
            const qreal radius = ringRect.width() / 2.0 - pixels(painted, 1.5);
            const QPointF centre = ringRect.center();
            const qreal angle = turn * 2 * std::numbers::pi;
            const qreal outer = radius + pixels(painted, 4);
            const QPoint at(int(std::floor(centre.x() + outer * std::cos(angle))),
                            int(std::floor(centre.y() + outer * std::sin(angle))));
            QVERIFY(painted.image.rect().contains(at));
            const QColor outside = painted.image.pixelColor(at);
            QVERIFY2(!render_probe::withinTolerance(outside, expectedAt(turn), 24),
                     qPrintable(QStringLiteral("gold outside the ring band at %1 turn: %2")
                                    .arg(turn).arg(outside.name())));
        }
    }

    // `LibraryState.swift:395-419` ends a scan only when its gate has no
    // queued request left: `ScanRequestGate.swift:31-41` answers a completion
    // with another pass whenever one was requested while the first was
    // running. A refresh requested behind a running one must therefore keep
    // Home scanning until the follow-up's own projection lands, not stop at
    // the first completion.
    void aRefreshQueuedBehindARunningScanKeepsScanningUntilBothProjectionsLand()
    {
        QTemporaryDir runtimeRoot;
        QTemporaryDir firstLibrary;
        QTemporaryDir secondLibrary;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
        QVERIFY(writeMediaFile(firstLibrary.path(), QStringLiteral("Arrival.2016.mkv")));
        QVERIFY(writeMediaFile(secondLibrary.path(), QStringLiteral("Moon.2009.mkv")));

        ApplicationController controller;
        QVERIFY2(!controller.hasError(), qPrintable(controller.errorMessage()));
        controller.setTemporaryLibraryRoot(firstLibrary.path());
        QTRY_COMPARE(controller.library()->rowCount(), 1);
        QTRY_VERIFY(!controller.scanning());

        // The worker is held inside each refresh it starts, so a second
        // request can be made while the first is still running.
        QSemaphore refreshEntered;
        QSemaphore releaseRefresh;
        int released = 0;
        const QMetaObject::Connection gate = QObject::connect(
            &controller, &ApplicationController::catalogRefreshStarted, &controller,
            [&] {
                refreshEntered.release();
                releaseRefresh.acquire();
            },
            Qt::DirectConnection);
        const auto releaseGate = qScopeGuard([&] {
            QObject::disconnect(gate);
            releaseRefresh.release(2);
        });

        QSignalSpy projections(controller.library(), &QAbstractItemModel::modelReset);
        QSignalSpy scanningChanges(&controller, &ApplicationController::scanningChanged);

        // The first refresh: requested, running, and blocked.
        controller.setTemporaryLibraryRoot(secondLibrary.path());
        QVERIFY(controller.scanning());
        QVERIFY2(refreshEntered.tryAcquire(1, 5000),
                 "the first refresh did not reach its deterministic gate");

        // A second refresh requested while the first is still inside the
        // worker. Home is already scanning, so nothing is published for it.
        controller.settings()->setLibraryRoots({firstLibrary.path()});
        QVERIFY(controller.scanning());
        QCOMPARE(scanningChanges.count(), 1);

        // The first completion lands its projection and must not end the scan:
        // the queued refresh has not run yet.
        releaseRefresh.release();
        ++released;
        QTRY_COMPARE(projections.count(), 1);
        QVERIFY2(refreshEntered.tryAcquire(1, 5000),
                 "the queued refresh did not start after the first one finished");
        QVERIFY2(controller.scanning(),
                 "Home stopped scanning while a queued refresh was still outstanding");
        QCOMPARE(scanningChanges.count(), 1);

        // Only the follow-up's own completion ends it, once.
        releaseRefresh.release();
        ++released;
        QTRY_COMPARE(projections.count(), 2);
        QTRY_VERIFY(!controller.scanning());
        QCOMPARE(scanningChanges.count(), 2);
        QVERIFY2(!controller.hasError(), qPrintable(controller.errorMessage()));
        QCOMPARE(released, 2);
    }

    // The same accounting across a failure: `LibraryState.swift:399-415` takes
    // its decision from the gate whatever the pass reported, so a failed
    // follow-up ends the scan exactly as a successful one does -- and a
    // failure that arrives with another refresh still queued does not.
    void aFailedFollowUpScanEndsTheScanAndReportsItself()
    {
        QTemporaryDir runtimeRoot;
        QTemporaryDir firstLibrary;
        QTemporaryDir secondLibrary;
        QTemporaryDir unconfiguredRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
        QVERIFY(writeMediaFile(firstLibrary.path(), QStringLiteral("Arrival.2016.mkv")));
        QVERIFY(writeMediaFile(secondLibrary.path(), QStringLiteral("Moon.2009.mkv")));

        ApplicationController controller;
        QVERIFY2(!controller.hasError(), qPrintable(controller.errorMessage()));
        controller.setTemporaryLibraryRoot(firstLibrary.path());
        QTRY_COMPARE(controller.library()->rowCount(), 1);
        QTRY_VERIFY(!controller.scanning());

        // A stored row already claiming the identity the second root's own
        // file will be given, filed under a root the application never
        // configures so no scan of the configured roots can diff it away.
        // Adding that root makes the second root's insert collide, which is a
        // catalog write failure the worker reports rather than a filesystem
        // condition this test would have to simulate.
        {
            CatalogStore store(AppPaths::catalogFile());
            const QVector<LibraryRoot> registered =
                store.registerRoots({secondLibrary.path(), unconfiguredRoot.path()});
            QCOMPARE(registered.size(), 2);
            const QString conflictingId = LibraryScanner::mediaIdFor(
                registered.at(0).id, QStringLiteral("Moon.2009.mkv"));

            CatalogDatabase catalog(AppPaths::catalogFile());
            QSqlQuery insert(catalog.connection());
            QVERIFY(insert.prepare(QStringLiteral(
                "INSERT INTO media_items (id, library_root_id, relative_path, media_kind, "
                "title, sort_title, year, file_size, modified_at, discovered_at, updated_at) "
                "VALUES (?, ?, 'Decoy.2001.mkv', 'movie', 'Decoy', 'decoy', 2001, 1, ?, ?, ?)")));
            const QString now =
                QDateTime::currentDateTimeUtc().toString(Qt::ISODateWithMs);
            insert.addBindValue(conflictingId);
            insert.addBindValue(registered.at(1).id);
            insert.addBindValue(now);
            insert.addBindValue(now);
            insert.addBindValue(now);
            QVERIFY2(insert.exec(), qPrintable(insert.lastError().text()));
        }

        QSemaphore refreshEntered;
        QSemaphore releaseRefresh;
        const QMetaObject::Connection gate = QObject::connect(
            &controller, &ApplicationController::catalogRefreshStarted, &controller,
            [&] {
                refreshEntered.release();
                releaseRefresh.acquire();
            },
            Qt::DirectConnection);
        const auto releaseGate = qScopeGuard([&] {
            QObject::disconnect(gate);
            releaseRefresh.release(2);
        });

        QSignalSpy projections(controller.library(), &QAbstractItemModel::modelReset);
        QSignalSpy scanningChanges(&controller, &ApplicationController::scanningChanged);

        // A first refresh over the reachable root alone, held inside the
        // worker. Nothing about it fails.
        controller.settings()->setLibraryRoots({firstLibrary.path()});
        QVERIFY(controller.scanning());
        QCOMPARE(scanningChanges.count(), 1);
        QVERIFY2(refreshEntered.tryAcquire(1, 5000),
                 "the first refresh did not reach its deterministic gate");

        // Then the second root, queued behind it, whose rows cannot be applied.
        controller.setTemporaryLibraryRoot(secondLibrary.path());
        QVERIFY(controller.scanning());
        QCOMPARE(scanningChanges.count(), 1);

        releaseRefresh.release();
        QTRY_COMPARE(projections.count(), 1);
        QVERIFY2(refreshEntered.tryAcquire(1, 5000),
                 "the queued refresh did not start after the first one finished");
        QVERIFY2(controller.scanning(),
                 "Home stopped scanning while the failing refresh was still outstanding");
        QVERIFY2(!controller.hasError(), qPrintable(controller.errorMessage()));

        // The failure is what ends this scan, and it is reported rather than
        // swallowed. The library the shell already had is left alone, because
        // a refresh that threw publishes no projection.
        releaseRefresh.release();
        QTRY_VERIFY(controller.hasError());
        QCOMPARE(controller.errorTitle(), QStringLiteral("Library scan"));
        QTRY_VERIFY(!controller.scanning());
        QCOMPARE(scanningChanges.count(), 2);
        QCOMPARE(projections.count(), 1);
        QCOMPARE(controller.library()->rowCount(), 1);
    }

    void homeScanningCapsuleAppearsOnAPopulatedLibrary_data() { homeModes_data(); }

    void homeScanningCapsuleAppearsOnAPopulatedLibrary()
    {
        QFETCH(bool, leanBack);
        QFETCH(int, controlTextSize);

        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        QTemporaryDir library;
        QVERIFY(writeMediaFile(library.path(), QStringLiteral("Arrival.2016.mkv")));

        ApplicationController controller;
        controller.settings()->setLeanBackMode(leanBack);
        controller.setTemporaryLibraryRoot(library.path());
        QTRY_COMPARE(controller.library()->rowCount(), 1);

        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY2(window != nullptr, "qml/Main.qml did not load from the module");
        controller.navigation()->goHome();

        QQuickItem *view = nullptr;
        QTRY_VERIFY((view = grid(window)) != nullptr);
        QTRY_COMPARE(view->property("count").toInt(), 1);

        QQuickItem *capsule =
            window->findChild<QQuickItem *>(QStringLiteral("homeScanningCapsule"));
        QQuickItem *label =
            window->findChild<QQuickItem *>(QStringLiteral("homeScanningLabel"));
        QQuickItem *scanState =
            window->findChild<QQuickItem *>(QStringLiteral("libraryScanState"));
        QQuickItem *titleBar = window->findChild<QQuickItem *>(QStringLiteral("homeTitleBar"));
        QVERIFY(capsule != nullptr);
        QVERIFY(label != nullptr);
        QVERIFY(scanState != nullptr);
        QVERIFY(titleBar != nullptr);
        QQuickItem *home = titleBar->parentItem();
        QVERIFY(home != nullptr);

        // The capsule really is inside the sticky bar rather than a second
        // banner of its own, which is where :312-327 draws it.
        bool capsuleIsInsideTheTitleBar = false;
        for (QQuickItem *ancestor = capsule->parentItem(); ancestor != nullptr;
             ancestor = ancestor->parentItem()) {
            if (ancestor == titleBar) {
                capsuleIsInsideTheTitleBar = true;
                break;
            }
        }
        QVERIFY2(capsuleIsInsideTheTitleBar,
                 "the scanning capsule is not inside the sticky title bar");

        // A settled library shows no capsule.
        QTRY_VERIFY(!controller.scanning());
        QVERIFY(!capsule->isVisible());

        // :312-320: rescanning a library that already has content shows the
        // capsule beside the wordmark, not the whole scanning state.
        home->setProperty("scanning", true);
        QTRY_VERIFY(capsule->isVisible());
        QVERIFY2(!scanState->isVisible(),
                 "a populated library must keep its content while rescanning");
        QVERIFY(view->isVisible());

        // :317-319's copy, face, and ink.
        QCOMPARE(label->property("text").toString(), QStringLiteral("Scanning"));
        QCOMPARE(label->property("font").value<QFont>().pixelSize(), controlTextSize);
        QCOMPARE(label->property("color").value<QColor>(), QColor("#9b8fb0"));

        // :323-326's capsule: the surface layer at 0.82, fully rounded.
        const QColor fill = capsule->property("color").value<QColor>();
        QCOMPARE(fill.rgb(), QColor("#231d30").rgb());
        QCOMPARE(qRound(fill.alphaF() * 100.0f), 82);
        QCOMPARE(qRound(capsule->property("radius").toReal()),
                 qRound(capsule->height() / 2));

        home->setProperty("scanning", false);
        QTRY_VERIFY(!capsule->isVisible());
    }

    // :329-355 draws the Play Something capsule; a tap plays a pick at once
    // (AppState.swift:235-245) and must not take the keyboard selection away
    // from the grid on the way.
    void homePlaySomethingPlaysAPickOnATap()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        QTemporaryDir library;
        for (const QString &name : sampleTitles()) {
            QVERIFY(writeMediaFile(library.path(), name));
        }

        ApplicationController controller;
        controller.setTemporaryLibraryRoot(library.path());
        QTRY_COMPARE(controller.library()->rowCount(), 16);

        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY2(window != nullptr, "qml/Main.qml did not load from the module");
        controller.navigation()->goHome();
        QVERIFY(QTest::qWaitForWindowExposed(window));

        QQuickItem *view = nullptr;
        QTRY_VERIFY((view = grid(window)) != nullptr);
        QTRY_COMPARE(view->property("count").toInt(), 8);
        revealRow(window, view);

        QQuickItem *control =
            window->findChild<QQuickItem *>(QStringLiteral("homePlaySomething"));
        QVERIFY(control != nullptr);
        QVERIFY(control->isVisible());

        // A tap on the capsule (over the cards scrolled beneath the bar) opens
        // no card; it plays a title.
        focusFirstCard(window, view);
        QCOMPARE(currentIndexOf(view), 0);

        const QPointF centre =
            control->mapToScene(QPointF(control->width() / 2, control->height() / 2));
        QTest::mouseClick(window, Qt::LeftButton, Qt::NoModifier, centre.toPoint());

        QTRY_COMPARE(controller.navigation()->route(), NavigationController::Route::Player);
        QVERIFY(!controller.hasError());
        QVERIFY(!controller.player()->mediaId().isEmpty());
        QCOMPARE(currentIndexOf(view), 0);
    }

    void anUnreachableRootIsReportedWhileItsTitlesStayListed()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        QTemporaryDir library;
        QVERIFY(writeMediaFile(library.path(), QStringLiteral("Arrival.2016.mkv")));
        QVERIFY(writeMediaFile(library.path(), QStringLiteral("Moon.2009.mkv")));
        const QString libraryPath = library.path();

        {
            ApplicationController controller;
            controller.setTemporaryLibraryRoot(libraryPath);
            QTRY_COMPARE(controller.library()->rowCount(), 2);
            QVERIFY2(!controller.hasError(), qPrintable(controller.errorMessage()));
        }

        QVERIFY(QDir(libraryPath).removeRecursively());

        ApplicationController controller;
        controller.setTemporaryLibraryRoot(libraryPath);

        QTRY_VERIFY(controller.hasError());
        QCOMPARE(controller.errorTitle(), QStringLiteral("Library unavailable"));
        QVERIFY(controller.errorMessage().contains(libraryPath));
        QVERIFY(controller.errorMessage().contains(QStringLiteral("preserved")));
        QCOMPARE(controller.library()->rowCount(), 2);
    }

    // A glow that is not shown (EpisodeRow's, until its row is focused) used
    // to build its MultiEffect and layer textures anyway, which is the memory
    // a long season paid for. Only a GPU scene graph has the effect to build.
    void anInvisibleSoftShadowBuildsNoEffect()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        QQmlApplicationEngine engine;
        QQmlComponent component(&engine);
        component.setData(
            QByteArrayLiteral("import QtQuick\nimport Marquee\n"
                              "Window {\n"
                              "    width: 300; height: 200; visible: true\n"
                              "    SoftShadow { objectName: \"shownShadow\"\n"
                              "                 x: 20; y: 20; width: 80; height: 60; blur: 10 }\n"
                              "    SoftShadow { objectName: \"hiddenShadow\"; visible: false\n"
                              "                 x: 150; y: 20; width: 80; height: 60; blur: 10 }\n"
                              "}\n"),
            QUrl(QStringLiteral("qrc:/soft-shadow-visibility-probe.qml")));
        QVERIFY2(!component.isError(), qPrintable(component.errorString()));
        const std::unique_ptr<QObject> created(component.create());
        auto *window = qobject_cast<QQuickWindow *>(created.get());
        QVERIFY(window != nullptr);
        QVERIFY(QTest::qWaitForWindowExposed(window));

        auto *shown = window->findChild<QQuickItem *>(QStringLiteral("shownShadow"));
        auto *hidden = window->findChild<QQuickItem *>(QStringLiteral("hiddenShadow"));
        QVERIFY(shown != nullptr);
        QVERIFY(hidden != nullptr);
        if (shown->property("hardware").toBool() == false) {
            QSKIP("the software scene graph has no shader effect; run on a display-backed session");
        }

        const auto effectCount = [](QQuickItem *shadow) {
            int count = 0;
            std::function<void(QQuickItem *)> walk = [&](QQuickItem *item) {
                if (item->objectName() == QLatin1String("softShadowEffect")) {
                    ++count;
                }
                for (QQuickItem *child : item->childItems()) {
                    walk(child);
                }
            };
            walk(shadow);
            return count;
        };
        QTRY_COMPARE(effectCount(shown), 1);
        QCOMPARE(effectCount(hidden), 0);

        // Shown, it builds the effect; hidden again, it lets it go.
        hidden->setVisible(true);
        QTRY_COMPARE(effectCount(hidden), 1);
        hidden->setVisible(false);
        QTRY_COMPARE(effectCount(hidden), 0);
    }
};

int main(int argc, char *argv[])
{
    QGuiApplication app(argc, argv);
    LibraryBrowseTest test;
    return QTest::qExec(&test, argc, argv);
}

#include "tst_library_browse.moc"
