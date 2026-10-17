#pragma once

#include <algorithm>
#include <cmath>
#include <functional>
#include <tuple>

#include <QColor>
#include <QHash>
#include <QImage>
#include <QList>
#include <QPainter>
#include <QPen>
#include <QPoint>
#include <QPointF>
#include <QTransform>
#include <QQuickItem>
#include <QQuickWindow>
#include <QRect>
#include <QRectF>
#include <QStringList>
#include <QTest>

// Painted-pixel probes for tests that drive the shipped QML scene. A grab is
// retried until the scene has painted what the predicate is waiting for, so
// no assertion depends on a fixed sleep.
namespace render_probe
{
// Where an item was painted, and at what effective scale, when a frame was
// grabbed. Items animate between states, so geometry read from the live scene
// after a grab need not be the geometry the grabbed frame shows.
struct ItemGeometry
{
    QRectF sceneRect;
    qreal scale = 1.0;

    bool operator==(const ItemGeometry &) const = default;
};

using ItemGeometries = QHash<QQuickItem *, ItemGeometry>;

[[nodiscard]] inline ItemGeometries sampleItems(QQuickWindow *window,
                                                const QList<QQuickItem *> &items)
{
    ItemGeometries geometries;
    for (QQuickItem *item : items) {
        if (item == nullptr) {
            continue;
        }
        ItemGeometry geometry;
        geometry.sceneRect = item->mapRectToItem(window->contentItem(), item->boundingRect());
        geometry.scale = item->width() > 0.0 ? geometry.sceneRect.width() / item->width() : 1.0;
        geometries.insert(item, geometry);
    }
    return geometries;
}

// A grab of the window together with the geometry it was taken against: the
// window's logical size and device pixel ratio, and the measured items as
// they stood while the frame was grabbed. A platform may hand back a buffer
// it has not yet brought up to the window's current size, so a capture is
// only trusted when its extent is exactly the window at its ratio and the
// measured items did not move around the grab; it is only ever measured
// against what it recorded, never against the live scene afterwards.
struct Capture
{
    QImage image;
    QSize logicalSize;
    qreal devicePixelRatio = 1.0;
    // The ratio the platform tagged the grabbed image with. Qt's painter
    // honours that tag when an image is drawn by position, so every probe
    // that paints a capture must address it in physical pixels.
    qreal imageDevicePixelRatio = 1.0;
    ItemGeometries items;
    bool itemsHeld = true;

    [[nodiscard]] QSize expectedImageSize() const
    {
        return {qRound(logicalSize.width() * devicePixelRatio),
                qRound(logicalSize.height() * devicePixelRatio)};
    }

    [[nodiscard]] bool coherent() const
    {
        return !image.isNull() && logicalSize.isValid()
            && image.size() == expectedImageSize() && itemsHeld;
    }

    [[nodiscard]] bool sameGeometryAs(const Capture &other) const
    {
        return logicalSize == other.logicalSize
            && qFuzzyCompare(devicePixelRatio, other.devicePixelRatio)
            && image.size() == other.image.size();
    }

    [[nodiscard]] ItemGeometry geometryOf(QQuickItem *item) const
    {
        return items.value(item);
    }
};

using CapturePredicate = std::function<bool(const Capture &)>;

[[nodiscard]] inline Capture captureWindow(QQuickWindow *window,
                                           const QList<QQuickItem *> &items = {})
{
    Capture capture;
    const ItemGeometries before = sampleItems(window, items);
    capture.logicalSize = window->size();
    capture.devicePixelRatio = window->devicePixelRatio();
    capture.image = window->grabWindow();
    capture.imageDevicePixelRatio = capture.image.devicePixelRatio();
    capture.items = sampleItems(window, items);
    capture.itemsHeld = capture.items == before && capture.logicalSize == window->size();
    return capture;
}

// Grabs until a coherent capture satisfies the predicate or the timeout
// passes; the caller asserts on the returned capture, so a timeout is reported
// against the pixels that were actually painted. `ready` receives whether
// the predicate was met before the timeout, for a caller that must tell a
// refusal from a wait that simply ran out.
[[nodiscard]] inline Capture captureWindowUntil(QQuickWindow *window,
                                                const QList<QQuickItem *> &items,
                                                const CapturePredicate &predicate,
                                                int timeoutMs = 5000,
                                                bool *ready = nullptr)
{
    Capture capture;
    const bool satisfied = QTest::qWaitFor(
        [&] {
            window->update();
            capture = captureWindow(window, items);
            return capture.coherent() && predicate(capture);
        },
        timeoutMs);
    if (ready != nullptr) {
        *ready = satisfied;
    }
    return capture;
}

// Up to `limit` pixels of `area` outside `excluded` that match, with their
// colours, for a failure message that says what was actually painted.
[[nodiscard]] inline QString describePixelsOutside(const QImage &image, const QRect &area,
                                                   const QRect &excluded,
                                                   const std::function<bool(const QColor &)> &matches,
                                                   int limit = 12)
{
    QStringList described;
    const QRect scanRect = area.intersected(image.rect());
    for (int y = scanRect.top(); y <= scanRect.bottom() && described.size() < limit; ++y) {
        for (int x = scanRect.left(); x <= scanRect.right() && described.size() < limit; ++x) {
            if (excluded.contains(x, y)) {
                continue;
            }
            const QColor pixel = image.pixelColor(x, y);
            if (matches(pixel)) {
                described << QStringLiteral("(%1,%2)=%3").arg(x).arg(y).arg(pixel.name());
            }
        }
    }
    return described.join(QLatin1Char(' '));
}

// A logical distance in the capture's pixels. Scene geometry is logical;
// a capture is device pixels, so every offset laid against a captured
// rectangle has to cross this boundary explicitly.
[[nodiscard]] inline int pixels(const Capture &capture, qreal logical)
{
    return qRound(logical * capture.devicePixelRatio);
}

// A scene rectangle in the capture's pixels.
[[nodiscard]] inline QRect imageRect(const Capture &capture, const QRectF &sceneRect)
{
    if (!capture.coherent() || sceneRect.isEmpty()) {
        return {};
    }
    const qreal scale = capture.devicePixelRatio;
    return QRectF(sceneRect.x() * scale,
                  sceneRect.y() * scale,
                  sceneRect.width() * scale,
                  sceneRect.height() * scale)
        .toAlignedRect()
        .intersected(capture.image.rect());
}

// The item's painted rectangle in the capture's pixels, including any scale
// the item or its ancestors applied, as sampled with the grab. An item that
// was not sampled has no rectangle in this capture.
[[nodiscard]] inline QRect imageRectForItem(const Capture &capture, QQuickItem *item)
{
    if (item == nullptr || !capture.items.contains(item)) {
        return {};
    }
    return imageRect(capture, capture.geometryOf(item).sceneRect);
}

[[nodiscard]] inline int countPixels(const QImage &image, const QRect &area,
                                     const std::function<bool(const QColor &)> &matches)
{
    const QRect scanRect = area.intersected(image.rect());
    int count = 0;
    for (int y = scanRect.top(); y <= scanRect.bottom(); ++y) {
        for (int x = scanRect.left(); x <= scanRect.right(); ++x) {
            if (matches(image.pixelColor(x, y))) {
                ++count;
            }
        }
    }
    return count;
}

// Pixels of `area` that lie outside `excluded`.
[[nodiscard]] inline int countPixelsOutside(const QImage &image, const QRect &area,
                                            const QRect &excluded,
                                            const std::function<bool(const QColor &)> &matches)
{
    return countPixels(image, area, matches)
        - countPixels(image, area.intersected(excluded), matches);
}

// Pixels of `area` no further than `depth` pixels from its edge.
[[nodiscard]] inline int countEdgePixels(const QImage &image, const QRect &area, int depth,
                                         const std::function<bool(const QColor &)> &matches)
{
    const QRect scanRect = area.intersected(image.rect());
    int count = 0;
    for (int y = scanRect.top(); y <= scanRect.bottom(); ++y) {
        for (int x = scanRect.left(); x <= scanRect.right(); ++x) {
            const int edgeDistance =
                std::min(std::min(x - scanRect.left(), scanRect.right() - x),
                         std::min(y - scanRect.top(), scanRect.bottom() - y));
            if (edgeDistance <= depth && matches(image.pixelColor(x, y))) {
                ++count;
            }
        }
    }
    return count;
}

// Pixels of `area` whose colour differs between two captures of the same
// scene by more than `tolerance` in any channel: what one state painted that
// the other did not, however faint. Two captures of different geometry show
// different layouts, so their difference is not a count; it is reported as -1
// rather than compared pixel by pixel.
[[nodiscard]] inline int changedPixels(const Capture &before, const Capture &after,
                                       const QRect &area, int tolerance = 3)
{
    if (!before.coherent() || !after.coherent() || !before.sameGeometryAs(after)) {
        return -1;
    }
    const QRect scanRect = area.intersected(before.image.rect());
    int count = 0;
    for (int y = scanRect.top(); y <= scanRect.bottom(); ++y) {
        for (int x = scanRect.left(); x <= scanRect.right(); ++x) {
            const QColor a = before.image.pixelColor(x, y);
            const QColor b = after.image.pixelColor(x, y);
            if (std::abs(a.red() - b.red()) > tolerance
                || std::abs(a.green() - b.green()) > tolerance
                || std::abs(a.blue() - b.blue()) > tolerance) {
                ++count;
            }
        }
    }
    return count;
}

// Marquee/Theme/ViewModifiers/CardHoverModifier.swift:56-59 blooms the
// structural accent (#7b5ea7) at opacity 0.48 around a focused surface. Over
// the dark background that reads as a violet tint: blue well ahead of green,
// red ahead of green, and blue lifted above the background's own.
[[nodiscard]] inline bool isAccentGlowPixel(const QColor &pixel)
{
    return pixel.blue() >= 40 && pixel.blue() > pixel.green() + 15
        && pixel.red() > pixel.green();
}

[[nodiscard]] inline bool withinTolerance(const QColor &pixel, const QColor &expected,
                                          int tolerance)
{
    return std::abs(pixel.red() - expected.red()) <= tolerance
        && std::abs(pixel.green() - expected.green()) <= tolerance
        && std::abs(pixel.blue() - expected.blue()) <= tolerance;
}

// A colour drawn source-over at `opacity` on `backdrop`.
[[nodiscard]] inline QColor sourceOverOn(const QColor &backdrop, const QColor &colour, qreal opacity)
{
    const auto channel = [&](qreal source, qreal destination) {
        return qRound((destination * (1.0 - opacity) + source * opacity) * 255.0);
    };
    return QColor(channel(colour.redF(), backdrop.redF()), channel(colour.greenF(), backdrop.greenF()),
                  channel(colour.blueF(), backdrop.blueF()));
}

// A colour screen-blended at `opacity` on `backdrop`: destination plus
// source times what the destination leaves.
[[nodiscard]] inline QColor screenOn(const QColor &backdrop, const QColor &colour, qreal opacity)
{
    const auto channel = [&](qreal source, qreal destination) {
        return qRound((destination + opacity * source * (1.0 - destination)) * 255.0);
    };
    return QColor(channel(colour.redF(), backdrop.redF()), channel(colour.greenF(), backdrop.greenF()),
                  channel(colour.blueF(), backdrop.blueF()));
}

// A backdrop under a black wash of `opacity`.
[[nodiscard]] inline QColor washed(const QColor &backdrop, qreal opacity)
{
    return QColor(qRound(backdrop.red() * (1.0 - opacity)), qRound(backdrop.green() * (1.0 - opacity)),
                  qRound(backdrop.blue() * (1.0 - opacity)));
}

// Signed distance from `point` to the boundary of a rounded rectangle in the
// same coordinates, negative inside, following the corner arcs.
[[nodiscard]] inline qreal roundedRectSignedDistance(const QPointF &point, const QRectF &rect, qreal radius)
{
    const QPointF centre = rect.center();
    const qreal halfWidth = rect.width() / 2.0 - radius;
    const qreal halfHeight = rect.height() / 2.0 - radius;
    const qreal qx = std::abs(point.x() - centre.x()) - halfWidth;
    const qreal qy = std::abs(point.y() - centre.y()) - halfHeight;
    const qreal outside = std::hypot(std::max(qx, 0.0), std::max(qy, 0.0));
    const qreal inside = std::min(std::max(qx, qy), 0.0);
    return outside + inside - radius;
}

// Whether the whole of the pixel square at (x, y) lies in the band between
// the rounded rectangle `outer` and that shape inset by `band`. The distance
// above grows with each coordinate's own distance from the centre, so over a
// pixel square it is largest at the square's corner farthest from the centre
// and smallest at the point of the square nearest it: the pixel is wholly
// covered exactly when the largest is at or inside the outer edge and the
// smallest at or outside the inner one.
[[nodiscard]] inline bool pixelWhollyInStrokeBand(int x, int y, const QRectF &outer, qreal radius,
                                                  qreal band)
{
    const QPointF centre = outer.center();
    const qreal farX = std::abs(x - centre.x()) > std::abs(x + 1 - centre.x()) ? qreal(x) : qreal(x + 1);
    const qreal farY = std::abs(y - centre.y()) > std::abs(y + 1 - centre.y()) ? qreal(y) : qreal(y + 1);
    const qreal nearX = std::clamp(centre.x(), qreal(x), qreal(x + 1));
    const qreal nearY = std::clamp(centre.y(), qreal(y), qreal(y + 1));
    return roundedRectSignedDistance(QPointF(farX, farY), outer, radius) <= 0.0
        && roundedRectSignedDistance(QPointF(nearX, nearY), outer, radius) >= -band;
}

// The pixels a stroke covers completely: those whose whole extent lies inside
// the band between the stroke's outer scene rectangle and that rectangle
// inset by the line width, on the straight run of each side, clear of the
// rounded corners by the corner radius, plus the corner arcs themselves.
// A run reaches the corner radius exactly: past it the band's edges are the
// two straight sides, so a whole pixel between them is wholly covered, and
// the pixels tangent to the arcs where the runs meet them belong to the
// enumeration. Where a side is fractional the join between a run and its arc
// falls inside a pixel, which then lies on neither the run's whole-pixel
// interval nor in the arc's quadrant, so each corner's neighbourhood is swept
// once more with the exact containment test above. Partially covered edge
// pixels carry antialiased mixtures that no blend rule predicts.
[[nodiscard]] inline QList<QPoint> fullyCoveredStrokePixels(const Capture &capture,
                                                            const QRectF &strokeSceneRect,
                                                            qreal lineWidth, qreal cornerRadius)
{
    QList<QPoint> covered;
    if (!capture.coherent() || strokeSceneRect.isEmpty()) {
        return covered;
    }
    const qreal dpr = capture.devicePixelRatio;
    const QRectF outer(strokeSceneRect.x() * dpr, strokeSceneRect.y() * dpr,
                       strokeSceneRect.width() * dpr, strokeSceneRect.height() * dpr);
    const qreal band = lineWidth * dpr;
    const qreal clear = cornerRadius * dpr;
    // A side's whole pixels, as an index range the join sweep can test a
    // pixel against rather than search the emitted list for.
    struct PixelRange
    {
        int firstX = 0;
        int lastX = 0;
        int firstY = 0;
        int lastY = 0;

        [[nodiscard]] bool contains(int x, int y) const
        {
            return x >= firstX && x <= lastX && y >= firstY && y <= lastY;
        }
    };
    const auto firstWhole = [](qreal from) { return int(std::ceil(from)); };
    const auto lastWhole = [](qreal to) { return int(std::floor(to)) - 1; };
    // Left and right sides run vertically between the corner zones; top and
    // bottom run horizontally between them.
    const PixelRange runs[] = {
        {firstWhole(outer.left()), lastWhole(outer.left() + band),
         firstWhole(outer.top() + clear), lastWhole(outer.bottom() - clear)},
        {firstWhole(outer.right() - band), lastWhole(outer.right()),
         firstWhole(outer.top() + clear), lastWhole(outer.bottom() - clear)},
        {firstWhole(outer.left() + clear), lastWhole(outer.right() - clear),
         firstWhole(outer.top()), lastWhole(outer.top() + band)},
        {firstWhole(outer.left() + clear), lastWhole(outer.right() - clear),
         firstWhole(outer.bottom() - band), lastWhole(outer.bottom())}};
    for (const PixelRange &run : runs) {
        for (int y = run.firstY; y <= run.lastY; ++y) {
            for (int x = run.firstX; x <= run.lastX; ++x) {
                covered.append(QPoint(x, y));
            }
        }
    }
    const auto onAnyRun = [&](int x, int y) {
        return std::any_of(std::begin(runs), std::end(runs),
                           [&](const PixelRange &run) { return run.contains(x, y); });
    };
    // The four corner arcs: a pixel is covered when all four of its corners
    // lie between the inner and outer radius of its corner's arc and it sits
    // in that corner's quadrant.
    const qreal outerRadius = cornerRadius * dpr;
    const qreal innerRadius = outerRadius - band;
    const auto coveredByArc = [&](const QPointF &centre, int x, int y) {
        for (const QPointF &corner : {QPointF(x, y), QPointF(x + 1, y), QPointF(x, y + 1), QPointF(x + 1, y + 1)}) {
            const qreal distance = std::hypot(corner.x() - centre.x(), corner.y() - centre.y());
            if (distance < innerRadius || distance > outerRadius) {
                return false;
            }
        }
        return true;
    };
    const QPointF centres[] = {
        QPointF(outer.left() + outerRadius, outer.top() + outerRadius),
        QPointF(outer.right() - outerRadius, outer.top() + outerRadius),
        QPointF(outer.left() + outerRadius, outer.bottom() - outerRadius),
        QPointF(outer.right() - outerRadius, outer.bottom() - outerRadius)};
    const int quadrantSignX[] = {-1, 1, -1, 1};
    const int quadrantSignY[] = {-1, -1, 1, 1};
    const auto inQuadrant = [&](int corner, int x, int y) {
        return (quadrantSignX[corner] < 0 ? x + 1 <= centres[corner].x() : x >= centres[corner].x())
            && (quadrantSignY[corner] < 0 ? y + 1 <= centres[corner].y() : y >= centres[corner].y());
    };
    const auto cornerBounds = [&](int corner, int &fromX, int &toX, int &fromY, int &toY) {
        fromX = int(std::floor(centres[corner].x() - outerRadius)) - 1;
        toX = int(std::ceil(centres[corner].x() + outerRadius)) + 1;
        fromY = int(std::floor(centres[corner].y() - outerRadius)) - 1;
        toY = int(std::ceil(centres[corner].y() + outerRadius)) + 1;
    };
    int fromX = 0;
    int toX = 0;
    int fromY = 0;
    int toY = 0;
    for (int corner = 0; corner < 4; ++corner) {
        cornerBounds(corner, fromX, toX, fromY, toY);
        for (int y = fromY; y <= toY; ++y) {
            for (int x = fromX; x <= toX; ++x) {
                if (inQuadrant(corner, x, y) && coveredByArc(centres[corner], x, y)) {
                    covered.append(QPoint(x, y));
                }
            }
        }
    }
    const auto onAnyArc = [&](int x, int y) {
        for (int corner = 0; corner < 4; ++corner) {
            if (inQuadrant(corner, x, y) && coveredByArc(centres[corner], x, y)) {
                return true;
            }
        }
        return false;
    };
    // The joins. A fractional side puts the line where a run's interval ends
    // and its arc's quadrant begins inside a pixel: that pixel lies on the
    // run's row or column and in the arc's neighbourhood, wholly inside the
    // band, and neither pass above reaches it. Each corner sweeps its own
    // neighbourhood for pixels the runs and the arcs both left, and takes
    // only those in its own quadrant of the rectangle, which is a partition
    // of the plane, so two corners can never claim one pixel.
    const QPointF rectCentre = outer.center();
    for (int corner = 0; corner < 4; ++corner) {
        cornerBounds(corner, fromX, toX, fromY, toY);
        for (int y = fromY; y <= toY; ++y) {
            for (int x = fromX; x <= toX; ++x) {
                const bool ownsPixel =
                    (quadrantSignX[corner] < 0 ? x + 0.5 < rectCentre.x() : x + 0.5 >= rectCentre.x())
                    && (quadrantSignY[corner] < 0 ? y + 0.5 < rectCentre.y() : y + 0.5 >= rectCentre.y());
                if (!ownsPixel || onAnyRun(x, y) || onAnyArc(x, y)) {
                    continue;
                }
                if (pixelWhollyInStrokeBand(x, y, outer, outerRadius, band)) {
                    covered.append(QPoint(x, y));
                }
            }
        }
    }
    covered.erase(std::remove_if(covered.begin(), covered.end(),
                                 [&](const QPoint &point) { return !capture.image.rect().contains(point); }),
                  covered.end());
    return covered;
}

// The subset of `covered` that lies on a corner arc rather than a straight
// run: pixels within the corner radius of the stroke rectangle's corners.
[[nodiscard]] inline QList<QPoint> cornerPixelsOf(const Capture &capture, const QList<QPoint> &covered,
                                                  const QRectF &strokeSceneRect, qreal cornerRadius)
{
    const qreal dpr = capture.devicePixelRatio;
    const QRectF outer(strokeSceneRect.x() * dpr, strokeSceneRect.y() * dpr,
                       strokeSceneRect.width() * dpr, strokeSceneRect.height() * dpr);
    const qreal radius = cornerRadius * dpr;
    QList<QPoint> corners;
    for (const QPoint &pixel : covered) {
        const qreal x = pixel.x() + 0.5;
        const qreal y = pixel.y() + 0.5;
        const bool nearVerticalEdge = x < outer.left() + radius || x > outer.right() - radius;
        const bool nearHorizontalEdge = y < outer.top() + radius || y > outer.bottom() - radius;
        if (nearVerticalEdge && nearHorizontalEdge) {
            corners.append(pixel);
        }
    }
    return corners;
}

// What one stroke pixel should look like: the idle backdrop beneath it,
// found where the content that now sits scaled about `centre` was painted
// at idle, then washed, then blended.
struct StrokeBlendModel
{
    QColor colour;
    qreal opacity = 1.0;
    qreal washOpacity = 0.0;
    QPointF centre;
    qreal scale = 1.0;
};

[[nodiscard]] inline QColor backdropAt(const Capture &idle, const StrokeBlendModel &model,
                                       const QPoint &pixel)
{
    const QPointF unscaled = model.centre + (QPointF(pixel) + QPointF(0.5, 0.5) - model.centre) / model.scale;
    const QPoint source(int(std::floor(unscaled.x())), int(std::floor(unscaled.y())));
    if (!idle.image.rect().contains(source)) {
        return {};
    }
    return washed(idle.image.pixelColor(source), model.washOpacity);
}

// Which composition rule a stroke audit expects of the painted ring. The
// product must satisfy Screen; SourceOver is the rule a corrupted classifier
// would hold, so an audit told to expect it must reject every real pixel.
enum class BlendRule { Screen, SourceOver };

[[nodiscard]] inline QColor blendedOn(BlendRule rule, const QColor &backdrop, const QColor &colour,
                                      qreal opacity)
{
    return rule == BlendRule::Screen ? screenOn(backdrop, colour, opacity)
                                     : sourceOverOn(backdrop, colour, opacity);
}

// The idle colours a stroke pixel's backdrop can be made of: the washed idle
// pixels in the three-by-three neighbourhood of the source it maps to. The
// poster item scales its artwork with smooth sampling, so over an artwork
// transition the backdrop is a mixture of these neighbours whose weights no
// external model can predict; away from one they are all the same colour.
[[nodiscard]] inline QList<QColor> backdropCandidatesAt(const Capture &idle, const StrokeBlendModel &model,
                                                        const QPoint &pixel, int tolerance)
{
    QList<QColor> candidates;
    const QPointF unscaled = model.centre + (QPointF(pixel) + QPointF(0.5, 0.5) - model.centre) / model.scale;
    const QPoint source(int(std::floor(unscaled.x())), int(std::floor(unscaled.y())));
    for (int dy = -1; dy <= 1; ++dy) {
        for (int dx = -1; dx <= 1; ++dx) {
            const QPoint neighbour = source + QPoint(dx, dy);
            if (!idle.image.rect().contains(neighbour)) {
                continue;
            }
            const QColor candidate = washed(idle.image.pixelColor(neighbour), model.washOpacity);
            const bool known = std::any_of(candidates.cbegin(), candidates.cend(), [&](const QColor &c) {
                return withinTolerance(candidate, c, tolerance);
            });
            if (!known) {
                candidates.append(candidate);
            }
        }
    }
    return candidates;
}

// Whether a stroke pixel sits over an artwork transition: more than one
// distinct colour in its backdrop neighbourhood.
[[nodiscard]] inline bool backdropIsFlatAt(const Capture &idle, const StrokeBlendModel &model,
                                           const QPoint &pixel, int tolerance)
{
    return backdropCandidatesAt(idle, model, pixel, tolerance).size() == 1;
}

// The point of the segment from `a` to `b` nearest to `pixel`, in colour
// space. Both blends are affine in the backdrop channel by channel, so the
// blend of any mixture of two backdrop colours lies on the segment between
// the blends of those colours.
[[nodiscard]] inline QColor nearestOnSegment(const QColor &pixel, const QColor &a, const QColor &b)
{
    const qreal dx = b.red() - a.red();
    const qreal dy = b.green() - a.green();
    const qreal dz = b.blue() - a.blue();
    const qreal length = dx * dx + dy * dy + dz * dz;
    qreal t = 0.0;
    if (length > 0.0) {
        t = ((pixel.red() - a.red()) * dx + (pixel.green() - a.green()) * dy + (pixel.blue() - a.blue()) * dz)
            / length;
        t = std::clamp(t, 0.0, 1.0);
    }
    return QColor(qRound(a.red() + t * dx), qRound(a.green() + t * dy), qRound(a.blue() + t * dz));
}

// Whether `pixel` is within tolerance of the blend of some mixture of two of
// the backdrop candidates under the given rule. With one candidate this is
// the plain point test.
[[nodiscard]] inline bool matchesBlendOfCandidates(const QColor &pixel, const QList<QColor> &candidates,
                                                   BlendRule rule, const QColor &colour, qreal opacity,
                                                   int tolerance)
{
    for (int i = 0; i < candidates.size(); ++i) {
        for (int j = i; j < candidates.size(); ++j) {
            const QColor a = blendedOn(rule, candidates.at(i), colour, opacity);
            const QColor b = blendedOn(rule, candidates.at(j), colour, opacity);
            if (withinTolerance(pixel, nearestOnSegment(pixel, a, b), tolerance)) {
                return true;
            }
        }
    }
    return false;
}

// Every fully covered stroke pixel judged one by one, transitions included,
// against the expected rule applied to its own backdrop, and against the
// source-over result it must not be. A single wrong pixel anywhere on the
// band counts.
struct StrokeBlendAudit
{
    int covered = 0;
    int judged = 0;
    int transitions = 0;
    int mismatches = 0;
    int sourceOverMatches = 0;
    QList<QPoint> judgedPixels;
    QList<QPoint> transitionPixels;
    QString firstMismatch;
};

[[nodiscard]] inline StrokeBlendAudit auditStrokeBlend(const QImage &focusedImage, const Capture &idle,
                                                       const QList<QPoint> &covered,
                                                       const StrokeBlendModel &model,
                                                       int tolerance = 6,
                                                       BlendRule rule = BlendRule::Screen)
{
    StrokeBlendAudit audit;
    for (const QPoint &pixel : covered) {
        if (!focusedImage.rect().contains(pixel)) {
            continue;
        }
        ++audit.covered;
        ++audit.judged;
        audit.judgedPixels.append(pixel);
        const QList<QColor> candidates = backdropCandidatesAt(idle, model, pixel, tolerance);
        if (candidates.size() > 1) {
            ++audit.transitions;
            audit.transitionPixels.append(pixel);
        }
        const QColor painted = focusedImage.pixelColor(pixel);
        if (candidates.isEmpty()
            || !matchesBlendOfCandidates(painted, candidates, rule, model.colour, model.opacity, tolerance)) {
            ++audit.mismatches;
            if (audit.firstMismatch.isEmpty()) {
                const QColor backdrop = backdropAt(idle, model, pixel);
                audit.firstMismatch = QStringLiteral("(%1,%2) painted %3 expected %4 over %5 (%6 candidates)")
                                          .arg(pixel.x()).arg(pixel.y()).arg(painted.name())
                                          .arg(blendedOn(rule, backdrop, model.colour, model.opacity).name())
                                          .arg(backdrop.name()).arg(candidates.size());
            }
        }
        if (!candidates.isEmpty()
            && matchesBlendOfCandidates(painted, candidates, BlendRule::SourceOver, model.colour,
                                        model.opacity, tolerance)) {
            ++audit.sourceOverMatches;
        }
    }
    return audit;
}

// The focused backdrop as Qt's own painter produces it, sharing no
// arithmetic with backdropAt: the idle capture drawn through a QTransform
// that scales about the artwork's centre by the focus scale, then washed
// with black at the wash opacity by ordinary source-over painting.
// Every geometry here is physical pixels. A grabbed image carries the
// window's ratio as metadata, and drawn by position Qt's painter would scale
// it down by that ratio into the scratch; the local copy is untagged and
// drawn through explicit physical source and target rectangles instead,
// which leaves the captured geometry untouched.
[[nodiscard]] inline QImage paintedFocusedBackdrop(const Capture &idle, const StrokeBlendModel &model)
{
    QImage source = idle.image;
    source.setDevicePixelRatio(1.0);
    const QRectF physical(QPointF(0, 0), QSizeF(source.size()));

    QImage backdrop(source.size(), QImage::Format_ARGB32_Premultiplied);
    backdrop.setDevicePixelRatio(1.0);
    backdrop.fill(Qt::black);
    QPainter painter(&backdrop);
    painter.setRenderHint(QPainter::SmoothPixmapTransform, false);
    QTransform transform;
    transform.translate(model.centre.x(), model.centre.y());
    transform.scale(model.scale, model.scale);
    transform.translate(-model.centre.x(), -model.centre.y());
    painter.setTransform(transform);
    painter.drawImage(physical, source, physical);
    painter.resetTransform();
    painter.setCompositionMode(QPainter::CompositionMode_SourceOver);
    painter.fillRect(backdrop.rect(), QColor(0, 0, 0, qRound(255.0 * model.washOpacity)));
    painter.end();
    return backdrop;
}

// A copy of `image` carrying `ratio` as its device pixel ratio metadata,
// for probes that must behave the same whatever the platform tags a grab.
[[nodiscard]] inline QImage taggedWithRatio(const QImage &image, qreal ratio)
{
    QImage tagged = image.copy();
    tagged.setDevicePixelRatio(ratio);
    return tagged;
}

// Every covered stroke pixel judged against the product's own rendering of
// what lies beneath the ring: `reference` is the same scene captured with
// the ring alone hidden, so whatever mixture the renderer produced there,
// from smooth sampling, transparent artwork, or the fallback layers, is the
// backdrop by construction. A pixel is right when it is the expected blend
// of that backdrop, and forbidden when it is the source-over result.
// Over a black backdrop screen and source-over agree exactly, so a
// source-over pixel is only ever forbidden where the two results differ by
// more than the tolerance; those are the distinguishable pixels.
struct StrokeReferenceAudit
{
    int covered = 0;
    int distinguishable = 0;
    int mismatches = 0;
    int sourceOverMatches = 0;
    QList<QPoint> distinguishablePixels;
    QString firstMismatch;
};

[[nodiscard]] inline StrokeReferenceAudit auditStrokeAgainstReference(
    const QImage &focusedImage, const QImage &reference, const QList<QPoint> &covered,
    const QColor &colour, qreal opacity, int tolerance = 6, BlendRule rule = BlendRule::Screen)
{
    StrokeReferenceAudit audit;
    for (const QPoint &pixel : covered) {
        if (!focusedImage.rect().contains(pixel) || !reference.rect().contains(pixel)) {
            continue;
        }
        ++audit.covered;
        const QColor backdrop = reference.pixelColor(pixel);
        const QColor painted = focusedImage.pixelColor(pixel);
        const QColor expected = blendedOn(rule, backdrop, colour, opacity);
        const QColor sourceOver = sourceOverOn(backdrop, colour, opacity);
        const QColor screen = screenOn(backdrop, colour, opacity);
        const bool distinguishable = !withinTolerance(screen, sourceOver, tolerance);
        if (distinguishable) {
            ++audit.distinguishable;
            audit.distinguishablePixels.append(pixel);
        }
        if (!withinTolerance(painted, expected, tolerance)) {
            ++audit.mismatches;
            if (audit.firstMismatch.isEmpty()) {
                audit.firstMismatch = QStringLiteral("(%1,%2) painted %3 expected %4 over %5")
                                          .arg(pixel.x()).arg(pixel.y()).arg(painted.name())
                                          .arg(expected.name()).arg(backdrop.name());
            }
        }
        if (distinguishable && withinTolerance(painted, sourceOver, tolerance)) {
            ++audit.sourceOverMatches;
        }
    }
    return audit;
}

// A copy of `image` whose pixels are read `offset` away: a reference whose
// correspondence to the focused frame has been corrupted.
[[nodiscard]] inline QImage shiftedBy(const QImage &image, const QPoint &offset)
{
    QImage shifted(image.size(), image.format());
    shifted.fill(Qt::black);
    for (int y = 0; y < image.height(); ++y) {
        for (int x = 0; x < image.width(); ++x) {
            const QPoint source(x + offset.x(), y + offset.y());
            if (image.rect().contains(source)) {
                shifted.setPixelColor(x, y, image.pixelColor(source));
            }
        }
    }
    return shifted;
}

// The ring as Qt's painter strokes it source-over on that backdrop, at the
// ring's own scene geometry: CardHoverModifier.swift:64-66 pads the ring by
// its line width and strokes inward, so the stroke's centre line lies half
// a line width inside the ring rectangle. This is the wrong result a
// screen-blended ring must not match, produced without the classifier.
[[nodiscard]] inline QImage paintedSourceOverStroke(const QImage &backdrop, const QRectF &strokeSceneRect,
                                                    qreal lineWidth, qreal cornerRadius, qreal dpr,
                                                    const QColor &colour, qreal opacity)
{
    QImage wrong = backdrop.copy();
    // A grab carries the window's ratio as metadata and the painter would
    // scale for it on top of the explicit scale below; the copy is untagged.
    wrong.setDevicePixelRatio(1.0);
    QPainter painter(&wrong);
    painter.setRenderHint(QPainter::Antialiasing, true);
    painter.setCompositionMode(QPainter::CompositionMode_SourceOver);
    painter.scale(dpr, dpr);
    QColor stroke = colour;
    stroke.setAlphaF(float(opacity));
    painter.setPen(QPen(stroke, lineWidth));
    painter.setBrush(Qt::NoBrush);
    const qreal half = lineWidth / 2.0;
    painter.drawRoundedRect(strokeSceneRect.adjusted(half, half, -half, -half),
                            cornerRadius - half, cornerRadius - half);
    painter.end();
    return wrong;
}

// How many judged pixels the painter's transformed backdrop lands outside
// the classifier's own backdrop neighbourhood on: the mapping checked
// against Qt's transform instead of against itself, to within one idle
// pixel, which is the rounding the two may legitimately differ by.
[[nodiscard]] inline int backdropDisagreements(const Capture &idle, const StrokeBlendModel &model,
                                               const QList<QPoint> &judged, const QImage &paintedBackdrop,
                                               int tolerance = 6)
{
    int disagreements = 0;
    for (const QPoint &pixel : judged) {
        if (!paintedBackdrop.rect().contains(pixel)) {
            ++disagreements;
            continue;
        }
        const QColor painted = paintedBackdrop.pixelColor(pixel);
        const QList<QColor> candidates = backdropCandidatesAt(idle, model, pixel, tolerance);
        const bool agrees = std::any_of(candidates.cbegin(), candidates.cend(), [&](const QColor &c) {
            return withinTolerance(painted, c, tolerance);
        });
        if (!agrees) {
            ++disagreements;
        }
    }
    return disagreements;
}

// The focused capture with one band pixel taken from the painter's wrong
// result: a band that is right everywhere but there.
[[nodiscard]] inline QImage withOnePixelFrom(const QImage &focusedImage, const QImage &wrong, const QPoint &pixel)
{
    QImage mixed = focusedImage.copy();
    if (mixed.rect().contains(pixel) && wrong.rect().contains(pixel)) {
        mixed.setPixelColor(pixel, wrong.pixelColor(pixel));
    }
    return mixed;
}

// A screen blend never darkens a channel: the result is at least the backdrop
// and at least the ring's own contribution in every channel.
[[nodiscard]] inline bool isScreenOf(const QColor &pixel, const QColor &backdrop,
                                     const QColor &ring, qreal ringOpacity,
                                     int tolerance = 6)
{
    const auto expected = [&](qreal source, qreal destination) {
        return qRound((destination + ringOpacity * source * (1.0 - destination)) * 255.0);
    };
    return std::abs(pixel.red() - expected(ring.redF(), backdrop.redF())) <= tolerance
        && std::abs(pixel.green() - expected(ring.greenF(), backdrop.greenF())) <= tolerance
        && std::abs(pixel.blue() - expected(ring.blueF(), backdrop.blueF())) <= tolerance;
}

// How far a pixel is from a colour, in its worst channel.
[[nodiscard]] inline int departureFrom(const QColor &pixel, const QColor &colour)
{
    return std::max({std::abs(pixel.red() - colour.red()),
                     std::abs(pixel.green() - colour.green()),
                     std::abs(pixel.blue() - colour.blue())});
}

// `Marquee/SharedViews/BottomFadeView.swift:14-24` draws a band of the page's
// own background running from fully transparent at its top to opaque at its
// bottom. A pixel in that band is therefore an exact mixture of what the
// surface paints beneath it and the background, weighted by the band's own
// gradient at that row -- not merely "weaker at the foot than at the head".
//
// The mixture is judged against the same scene captured with the band alone
// hidden, so what lies beneath it is the product's own rendering rather than a
// model of it. Two wrong bands are counted as controls rather than argued
// about: one that covered its content opaquely, and one that was not drawn at
// all. Each is judged where the released band actually separates it from the
// truth -- the opaque cover at the band's head, where the ramp is still
// transparent enough to show what lies beneath, and the undrawn band at its
// foot, where the ramp has reached the background -- and each is counted only
// over the pixels where that separation exceeds the tolerance, so the pixels
// that can tell a wrong band apart are counted separately from the pixels that
// match it. Over clear page nothing distinguishes the three, which is why an
// empty band is a separate case for the caller rather than a weaker assertion
// here.
// The tolerance the audit below judges a band's mixture by, and so also the
// threshold at which a pixel beneath the band counts as painted content
// rather than clear page: a caller that decided which of the two band states
// it is in by a stricter threshold would classify a band as clear whose
// content the audit can still see.
inline constexpr int fadeBandTolerance = 14;

struct FadeBandAudit
{
    int judged = 0;
    int mismatches = 0;
    // Head pixels where an opaque cover would be visibly wrong: the released
    // mixture there still carries what is painted beneath, so it differs from
    // the page background by more than the tolerance.
    int strongInHead = 0;
    // Of those, the pixels the surface actually painted as the page
    // background, which is what an opaque band would have produced.
    int opaqueMatches = 0;
    // Foot pixels where an undrawn band would be visibly wrong: the released
    // mixture there has reached the background, so it differs from what is
    // painted beneath by more than the tolerance.
    int strongInFoot = 0;
    // Of those, the pixels the surface actually left showing that unfaded
    // surface, which is what no band at all would have produced.
    int unfadedMatches = 0;
    QString firstMismatch;
};

[[nodiscard]] inline FadeBandAudit auditBottomFadeBand(const QImage &faded, const QImage &unfaded,
                                                       const QRect &band, const QColor &background,
                                                       int tolerance = fadeBandTolerance)
{
    FadeBandAudit audit;
    const QRect scanRect = band.intersected(faded.rect()).intersected(unfaded.rect());
    if (scanRect.isEmpty()) {
        return audit;
    }
    // The gradient is laid over the band's own extent, so a row's weight is
    // its pixel centre's position down that extent, whatever the ratio.
    const auto alphaAt = [&](int y) {
        return (qreal(y - scanRect.top()) + 0.5) / qreal(scanRect.height());
    };
    const auto mixed = [](const QColor &beneath, const QColor &colour, qreal alpha) {
        const auto channel = [&](int under, int over) {
            return qRound(under * (1.0 - alpha) + over * alpha);
        };
        return QColor(channel(beneath.red(), colour.red()),
                      channel(beneath.green(), colour.green()),
                      channel(beneath.blue(), colour.blue()));
    };
    // Each control is judged on the half of the band where the released ramp
    // separates it from the truth: an opaque cover is wrong at the head, where
    // the ramp is still mostly transparent, and an undrawn band is wrong at
    // the foot, where the ramp has reached the background.
    //
    // A pixel counts towards a control only where the released mixture stands
    // more than two tolerances from the wrong answer. A correct band paints
    // within one tolerance of that mixture, so it then lies more than one
    // tolerance from the wrong answer and cannot be mistaken for it; at a
    // separation of just over one tolerance the two admissible ranges still
    // overlap, and a correctly painted pixel could be counted as the defect
    // the control looks for.
    const int separation = 2 * tolerance;
    const int middle = scanRect.top() + scanRect.height() / 2;
    for (int y = scanRect.top(); y <= scanRect.bottom(); ++y) {
        const qreal alpha = alphaAt(y);
        const bool inHead = y < middle;
        for (int x = scanRect.left(); x <= scanRect.right(); ++x) {
            const QPoint pixel(x, y);
            const QColor beneath = unfaded.pixelColor(pixel);
            const QColor painted = faded.pixelColor(pixel);
            const QColor expected = mixed(beneath, background, alpha);
            ++audit.judged;
            if (!withinTolerance(painted, expected, tolerance)) {
                ++audit.mismatches;
                if (audit.firstMismatch.isEmpty()) {
                    audit.firstMismatch =
                        QStringLiteral("(%1,%2) painted %3 expected %4 over %5 at alpha %6")
                            .arg(x).arg(y).arg(painted.name()).arg(expected.name())
                            .arg(beneath.name()).arg(alpha, 0, 'f', 3);
                }
            }
            if (inHead) {
                if (departureFrom(expected, background) > separation) {
                    ++audit.strongInHead;
                    if (withinTolerance(painted, background, tolerance)) {
                        ++audit.opaqueMatches;
                    }
                }
            } else if (departureFrom(expected, beneath) > separation) {
                ++audit.strongInFoot;
                if (withinTolerance(painted, beneath, tolerance)) {
                    ++audit.unfadedMatches;
                }
            }
        }
    }
    return audit;
}
}
