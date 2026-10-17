#include <QColor>
#include <QGuiApplication>
#include <QLatin1String>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQmlEngine>
#include <QQmlProperty>
#include <QQuickItem>
#include <QQuickWindow>
#include <QScopeGuard>
#include <QStringList>
#include <QTemporaryDir>
#include <QTest>
#include <QVariant>

#include "app/AppPaths.hpp"
#include "app/ApplicationController.hpp"
#include "navigation/NavigationController.hpp"
#include "settings/SettingsStore.hpp"
#include "support/RenderProbe.hpp"

using render_probe::Capture;
using render_probe::captureWindowUntil;
using render_probe::countPixels;
using render_probe::imageRectForItem;

namespace
{
// Marquee/SharedViews/MarqueeSidebar.swift:6-24 fixes the routes, their
// order, their labels, and the SF Symbol each one draws.
struct ReleasedRoute
{
    NavigationController::Route route;
    const char *label;
    const char *symbol;
};

[[nodiscard]] QList<ReleasedRoute> releasedRoutes()
{
    return {{NavigationController::Route::Home, "Home", "house.fill"},
            {NavigationController::Route::Search, "Search", "magnifyingglass"},
            {NavigationController::Route::Movies, "Movies", "film"},
            {NavigationController::Route::Shows, "TV Shows", "tv"},
            {NavigationController::Route::Settings, "Settings", "gearshape"}};
}

// MarqueeTheme.swift:36-46 names the three inks SidebarRow.swift:211-216
// chooses between for a route symbol.
const QColor kStructuralFocus("#7b5ea7");
const QColor kAccentBright("#9e86ff");
const QColor kTextTertiary("#6b6178");

// The colours the Play Something control is made of, each stated from the
// released contract rather than read back from the surface under test:
// MarqueeSidebar.swift:137 lays the column on the surface layer, :85-90 fills
// the control with the primary accent at 0.14 until the remote is on it and
// with that accent itself once it is, and :78 inks the symbol in the
// secondary accent at 0.78 until then and in the primary text colour after.
// MarqueeTheme.swift:111, :114, :124, and :130 fix those four values, which
// qml/Theme.qml:9-14 carries unchanged.
const QColor kSurfaceLayer("#231d30");
const QColor kAccentPrimary("#7b5ea7");
const QColor kAccentSecondary("#c9a84c");
const QColor kTextPrimary("#f5f0eb");
constexpr qreal kPlaySomethingRestingFillOpacity = 0.14;

// :78's two inks. An expectation derived from the symbol's own colour would
// hold whatever that binding chose, so a wrong token or the wrong state's
// colour would still be found in the pixels it painted; these are the released
// values themselves.
[[nodiscard]] QColor playSomethingRestingInk()
{
    QColor ink = kAccentSecondary;
    ink.setAlphaF(0.78f);
    return ink;
}

[[nodiscard]] QColor playSomethingFocusedInk()
{
    return kTextPrimary;
}
}

class SidebarNavigationTest final : public QObject
{
    Q_OBJECT

private:
    // Loads the shipped Marquee module linked into this binary, so these
    // cases exercise qml/Main.qml and qml/components/Sidebar.qml themselves
    // rather than a replica of either.
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
            window->resize(1280, 800);
            window->requestActivate();
        }
        return window;
    }

    [[nodiscard]] static QQuickItem *itemNamed(QObject *root, const QString &name)
    {
        return root->findChild<QQuickItem *>(name);
    }

    // A Repeater instantiates its delegates outside the surface's QObject
    // tree, so a route row is never reachable by findChild from the sidebar
    // and is asked of the repeater that owns it instead, as
    // tests/browse/tst_movies_route.cpp addresses the Movies rows. A row's
    // own layers are declared inside the delegate and are reachable from it.
    [[nodiscard]] static QQuickItem *routeEntry(QQuickItem *sidebar, int index)
    {
        QQuickItem *repeater = itemNamed(sidebar, QStringLiteral("sidebarRoutes"));
        if (repeater == nullptr || index >= repeater->property("count").toInt()) {
            return nullptr;
        }
        QQuickItem *entry = nullptr;
        if (!QMetaObject::invokeMethod(repeater, "itemAt",
                                       Q_RETURN_ARG(QQuickItem *, entry),
                                       Q_ARG(int, index))) {
            return nullptr;
        }
        return entry;
    }

    [[nodiscard]] static QQuickItem *routeLayer(QQuickItem *sidebar, int index,
                                                const char *name)
    {
        QQuickItem *entry = routeEntry(sidebar, index);
        return entry == nullptr ? nullptr : itemNamed(entry, QLatin1String(name));
    }

    [[nodiscard]] static QQuickItem *routeSurface(QQuickItem *sidebar, int index)
    {
        return routeLayer(sidebar, index, "sidebarRouteSurface");
    }

    [[nodiscard]] static QQuickItem *routeSymbol(QQuickItem *sidebar, int index)
    {
        return routeLayer(sidebar, index, "sidebarRouteSymbol");
    }

    // An attached property is only reachable through the item's own QML
    // context, so accessibility names are read the way the platform's
    // accessibility bridge resolves them rather than off a duplicate. An
    // unresolved read yields an invalid variant, which the first case checks
    // for explicitly so a broken read cannot be mistaken for an empty name.
    [[nodiscard]] static QVariant accessibleProperty(QQuickItem *item, const char *name)
    {
        return QQmlProperty::read(item, QLatin1String("Accessible.") + QLatin1String(name),
                                  qmlContext(item));
    }

    [[nodiscard]] static QString accessibleName(QQuickItem *item)
    {
        return accessibleProperty(item, "name").toString();
    }

    [[nodiscard]] static QString accessibleDescription(QQuickItem *item)
    {
        return accessibleProperty(item, "description").toString();
    }

    [[nodiscard]] static int focusedIndexOf(QQuickItem *sidebar)
    {
        return sidebar->property("focusedIndex").toInt();
    }

    // The released ink inside the symbol's own rectangle. `house.fill` is the
    // one filled symbol of the five, so its body carries whole pixels of the
    // chosen ink rather than only the antialiased mixtures a stroke leaves.
    // The three inks are far enough apart that a partial blend of any one of
    // them with the surface beneath cannot land within this tolerance of
    // another.
    [[nodiscard]] static int inkPixels(const Capture &capture, QQuickItem *symbol,
                                       const QColor &ink)
    {
        const QRect rect = imageRectForItem(capture, symbol);
        if (rect.isEmpty()) {
            return -1;
        }
        return countPixels(capture.image, rect, [&](const QColor &pixel) {
            return render_probe::withinTolerance(pixel, ink, 2);
        });
    }

    // How much of a stroke's own ink a pixel carries. A symbol is composited
    // over the surface beneath it, so a pixel the stroke covers part of lands
    // on the segment from that surface to the fully covered ink, at the
    // fraction of the pixel the stroke covered. `coverage` is that position
    // along the segment and `offSegment` how far the pixel sits off it, which
    // no mixture of those two colours can be.
    struct InkMixture
    {
        qreal coverage = 0.0;
        int offSegment = 0;
    };

    [[nodiscard]] static InkMixture inkMixture(const QColor &pixel, const QColor &fill,
                                               const QColor &covered)
    {
        const qreal red = covered.red() - fill.red();
        const qreal green = covered.green() - fill.green();
        const qreal blue = covered.blue() - fill.blue();
        const qreal squared = red * red + green * green + blue * blue;
        InkMixture mixture;
        if (squared > 0.0) {
            mixture.coverage = qBound(0.0,
                                      ((pixel.red() - fill.red()) * red
                                       + (pixel.green() - fill.green()) * green
                                       + (pixel.blue() - fill.blue()) * blue)
                                          / squared,
                                      1.0);
        }
        const auto offBy = [&](int painted, int base, qreal delta) {
            return qAbs(painted - qRound(base + mixture.coverage * delta));
        };
        mixture.offSegment = qMax(qMax(offBy(pixel.red(), fill.red(), red),
                                       offBy(pixel.green(), fill.green(), green)),
                                  offBy(pixel.blue(), fill.blue(), blue));
        return mixture;
    }

    // Pixels of the symbol's own painted rectangle carrying at least
    // `minimumCoverage` of an ink drawn on `fill`. A stroke this thin leaves
    // antialiased mixtures rather than whole covered pixels, so the mixture
    // itself is the evidence; the fill sits at coverage zero whatever colour
    // it takes, so nothing the surface beneath the symbol paints is counted.
    [[nodiscard]] static int inkCoveragePixels(const Capture &capture, QQuickItem *symbol,
                                               const QColor &fill, const QColor &covered,
                                               qreal minimumCoverage, int tolerance)
    {
        const QRect rect = imageRectForItem(capture, symbol);
        if (rect.isEmpty()) {
            return -1;
        }
        return countPixels(capture.image, rect, [&](const QColor &pixel) {
            const InkMixture mixture = inkMixture(pixel, fill, covered);
            return mixture.offSegment <= tolerance && mixture.coverage >= minimumCoverage;
        });
    }

private slots:
    // MarqueeSidebar.swift:53-71 lays the five routes out in declaration
    // order, labels each with its raw value, and hints "Open <label>"; :68-70
    // and SidebarRow.swift:182 give a row no text of its own, only a symbol.
    void sidebarPresentsTheFiveReleasedRoutesAsSymbolsWithTheirAccessibilityNames()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        ApplicationController controller;
        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY2(window != nullptr, "qml/Main.qml did not load from the module");

        QQuickItem *sidebar = itemNamed(window, QStringLiteral("sidebar"));
        QVERIFY(sidebar != nullptr);

        const QList<ReleasedRoute> expected = releasedRoutes();
        QCOMPARE(sidebar->property("entries").toList().size(), expected.size());
        QVERIFY(routeEntry(sidebar, 0) != nullptr);

        // The attached read resolves at all, so an empty name below is the
        // surface's and not this suite's.
        QVERIFY2(accessibleProperty(routeEntry(sidebar, 0), "name").isValid(),
                 "Accessible.name did not resolve through the item's QML context");

        for (int index = 0; index < expected.size(); ++index) {
            const ReleasedRoute &released = expected.at(index);
            QQuickItem *entry = routeEntry(sidebar, index);
            QQuickItem *symbol = routeSymbol(sidebar, index);
            QVERIFY2(entry != nullptr && symbol != nullptr,
                     qPrintable(QStringLiteral("route %1 is missing").arg(index)));

            QCOMPARE(entry->property("route").toInt(), int(released.route));
            QCOMPARE(accessibleName(entry), QLatin1String(released.label));
            QCOMPARE(accessibleDescription(entry),
                     QStringLiteral("Open %1").arg(QLatin1String(released.label)));
            QCOMPARE(symbol->property("symbol").toString(),
                     QLatin1String(released.symbol));
            // The symbol is drawn from a path of its own, not approximated by
            // whatever glyph a font happens to carry for it.
            QVERIFY2(symbol->property("hasPath").toBool(),
                     qPrintable(QStringLiteral("%1 has no drawn path")
                                    .arg(QLatin1String(released.symbol))));
        }

        // MarqueeSidebar.swift:76 and :158 name the other two symbols this
        // surface draws.
        QQuickItem *shuffle = itemNamed(sidebar, QStringLiteral("sidebarPlaySomethingSymbol"));
        QQuickItem *profileSymbol = itemNamed(sidebar, QStringLiteral("sidebarProfileSymbol"));
        QVERIFY(shuffle != nullptr && profileSymbol != nullptr);
        QCOMPARE(shuffle->property("symbol").toString(), QStringLiteral("shuffle"));
        QVERIFY(shuffle->property("hasPath").toBool());
        QCOMPARE(profileSymbol->property("fallbackSymbol").toString(),
                 QStringLiteral("person.crop.circle"));
        QVERIFY(profileSymbol->property("hasPath").toBool());

        QCOMPARE(accessibleName(itemNamed(sidebar, QStringLiteral("sidebarPlaySomething"))),
                 QStringLiteral("Play Something"));

        // The released sidebar carries no text at all, so a v3 approximation
        // that reaches for a glyph or a label instead of a symbol is a
        // divergence this surface must not have. Repeater delegates hang off
        // the repeater rather than the sidebar, so each route row is scanned
        // through its own subtree as well.
        QList<QQuickItem *> roots{sidebar};
        for (int index = 0; index < expected.size(); ++index) {
            roots.append(routeEntry(sidebar, index));
        }
        for (QQuickItem *scanned : roots) {
            QVERIFY(scanned != nullptr);
            for (QQuickItem *child : scanned->findChildren<QQuickItem *>()) {
                QVERIFY2(!child->inherits("QQuickText"),
                         qPrintable(QStringLiteral("the sidebar drew text: %1")
                                        .arg(child->property("text").toString())));
            }
        }
    }

    // AppRouter.swift:62-91 walks remote focus down through the routes, then
    // to Play Something, then to the profile control, and refuses to move
    // past either end: :64-70 stops at the profile going down and :86-90
    // stops at Play Something rather than wrapping.
    void remoteFocusWalksTheRoutesThenPlaySomethingThenTheProfileAndStopsAtBothEnds()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        ApplicationController controller;
        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY2(window != nullptr, "qml/Main.qml did not load from the module");
        controller.navigation()->goHome();

        QQuickItem *sidebar = itemNamed(window, QStringLiteral("sidebar"));
        QVERIFY(sidebar != nullptr);
        QTRY_VERIFY(sidebar->hasActiveFocus());

        const int routes = int(sidebar->property("entries").toList().size());
        QCOMPARE(routes, 5);
        QCOMPARE(sidebar->property("playSomethingIndex").toInt(), routes);
        QCOMPARE(sidebar->property("profileIndex").toInt(), routes + 1);
        QCOMPARE(focusedIndexOf(sidebar), 0);

        // Up at the first route is a boundary, not a wrap onto the profile.
        QTest::keyClick(window, Qt::Key_Up);
        QCOMPARE(focusedIndexOf(sidebar), 0);

        for (int step = 1; step <= routes + 1; ++step) {
            QTest::keyClick(window, Qt::Key_Down);
            QCOMPARE(focusedIndexOf(sidebar), step);
        }

        // Down at the profile control is a boundary, not a wrap onto Home.
        QTest::keyClick(window, Qt::Key_Down);
        QCOMPARE(focusedIndexOf(sidebar), routes + 1);

        for (int step = routes; step >= 0; --step) {
            QTest::keyClick(window, Qt::Key_Up);
            QCOMPARE(focusedIndexOf(sidebar), step);
        }

        // Walking focus is not selecting: AppRouter.swift:36-39 moves the
        // focused item without touching the selected one.
        QCOMPARE(controller.navigation()->route(), NavigationController::Route::Home);
    }

    // AppRouter.swift:54-56 makes Left a boundary at the sidebar, and
    // ContentView.swift:195-213 puts the detail surface to its right.
    // MarqueeSidebar.swift:53-71 keeps the focused row across the hand-off,
    // so the remote returns to the row it left from.
    void leftIsABoundaryAndRightHandsTheRemoteToTheContentKeepingTheFocusedRow()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        ApplicationController controller;
        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY2(window != nullptr, "qml/Main.qml did not load from the module");

        // ContentView.swift:41: the shell composes once a profile is chosen;
        // Home with an empty library is the surface to the right that claims
        // no arrow keys of its own, so every key below is answered by the
        // sidebar and the shell alone.
        controller.navigation()->goHome();

        QQuickItem *sidebar = itemNamed(window, QStringLiteral("sidebar"));
        QQuickItem *content = itemNamed(window, QStringLiteral("contentFocus"));
        QVERIFY(sidebar != nullptr && content != nullptr);
        QTRY_VERIFY(sidebar->hasActiveFocus());

        const NavigationController::Route before = controller.navigation()->route();

        QTest::keyClick(window, Qt::Key_Down);
        QTest::keyClick(window, Qt::Key_Down);
        QCOMPARE(focusedIndexOf(sidebar), 2);

        // Left at the sidebar changes nothing: it neither moves focus, nor
        // leaves the surface, nor opens a route.
        QTest::keyClick(window, Qt::Key_Left);
        QVERIFY(sidebar->hasActiveFocus());
        QCOMPARE(focusedIndexOf(sidebar), 2);
        QCOMPARE(controller.navigation()->route(), before);

        QTest::keyClick(window, Qt::Key_Right);
        QTRY_VERIFY(content->hasActiveFocus());
        QVERIFY(!sidebar->hasActiveFocus());
        // Right hands the remote across without opening the focused route.
        QCOMPARE(controller.navigation()->route(), before);
        // The remote-focus presentation goes with the remote.
        QVERIFY(!sidebar->property("remoteActive").toBool());

        QTest::keyClick(window, Qt::Key_Left);
        QTRY_VERIFY(sidebar->hasActiveFocus());
        QCOMPARE(focusedIndexOf(sidebar), 2);
        QVERIFY(sidebar->property("remoteActive").toBool());
    }

    // AppRouter.swift:40-53 activates the focused item: a route becomes the
    // selection, the profile control presents the picker, and Play Something
    // runs. MarqueeSidebar.swift:75 and :111 give the pointer the same three
    // actions.
    void activatingEachFocusedControlPerformsItsReleasedAction()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        ApplicationController controller;
        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY2(window != nullptr, "qml/Main.qml did not load from the module");

        // The shell opens on the profile picker with no sidebar
        // (ContentView.swift:29-40). Entering through a route no released
        // row activates keeps every activation below a real transition
        // rather than a no-op that would pass whatever happened.
        QCOMPARE(controller.navigation()->route(), NavigationController::Route::ProfilePicker);
        controller.navigation()->openRoute(NavigationController::Route::Settings);

        QQuickItem *sidebar = itemNamed(window, QStringLiteral("sidebar"));
        QVERIFY(sidebar != nullptr);
        QTRY_VERIFY(sidebar->hasActiveFocus());

        const QList<ReleasedRoute> expected = releasedRoutes();
        for (int index = 0; index < expected.size(); ++index) {
            const NavigationController::Route before = controller.navigation()->route();
            QVERIFY2(before != expected.at(index).route,
                     qPrintable(QStringLiteral("route %1 was already open").arg(index)));
            sidebar->forceActiveFocus();
            sidebar->setProperty("focusedIndex", index);
            QTest::keyClick(window, Qt::Key_Return);
            QTRY_COMPARE(controller.navigation()->route(), expected.at(index).route);
            // The row the remote left from is the one the surface now shows
            // as selected.
            QCOMPARE(sidebar->property("selectedRoute").toInt(),
                     int(expected.at(index).route));
        }

        // Play Something runs the released action, which does nothing and says
        // nothing when the library holds no title to play
        // (AppState.swift:235-238); the pick itself is judged on Home's suite.
        QVERIFY(!controller.hasError());
        sidebar->forceActiveFocus();
        sidebar->setProperty("focusedIndex", sidebar->property("playSomethingIndex"));
        QTest::keyClick(window, Qt::Key_Return);
        QTest::qWait(50);
        QVERIFY(!controller.hasError());
        QCOMPARE(controller.navigation()->route(), NavigationController::Route::Settings);

        controller.dismissError();
        sidebar->forceActiveFocus();
        sidebar->setProperty("focusedIndex", sidebar->property("profileIndex"));
        QTest::keyClick(window, Qt::Key_Return);
        QTRY_COMPARE(controller.navigation()->route(),
                     NavigationController::Route::ProfilePicker);
    }

    // MarqueeSidebar.swift:42-48 and SidebarRow.swift:183-202 size the whole
    // surface from the same compact/lean-back pairs, and MarqueeTheme.swift:
    // 210-212 picks between them.
    void sidebarGeometryFollowsTheReleasedCompactAndLeanBackMeasurements_data()
    {
        QTest::addColumn<bool>("leanBack");
        QTest::addColumn<int>("width");
        QTest::addColumn<int>("symbolFrame");
        QTest::addColumn<int>("rowHeight");
        QTest::addColumn<int>("inset");
        QTest::addColumn<int>("topMargin");
        QTest::addColumn<int>("rowSpacing");
        QTest::addColumn<int>("symbolPoints");
        QTest::addColumn<int>("avatarDiameter");
        QTest::addColumn<int>("playSomethingHeight");
        QTest::addColumn<int>("profileHeight");

        // :43 width, :186-189 symbol frame and row padding, :202 inset,
        // :73 top margin, :52 row spacing, :183 symbol points, :47 avatar,
        // :83 and :102 the Play Something paddings, :113 and :134 the
        // profile paddings.
        QTest::newRow("compact") << false << 56 << 22 << 36 << 8 << 18 << 2 << 14 << 30 << 46 << 54;
        QTest::newRow("lean-back") << true << 78 << 32 << 56 << 12 << 28 << 6 << 21 << 44 << 72 << 84;
    }

    void sidebarGeometryFollowsTheReleasedCompactAndLeanBackMeasurements()
    {
        QFETCH(bool, leanBack);
        QFETCH(int, width);
        QFETCH(int, symbolFrame);
        QFETCH(int, rowHeight);
        QFETCH(int, inset);
        QFETCH(int, topMargin);
        QFETCH(int, rowSpacing);
        QFETCH(int, symbolPoints);
        QFETCH(int, avatarDiameter);
        QFETCH(int, playSomethingHeight);
        QFETCH(int, profileHeight);

        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        ApplicationController controller;
        controller.settings()->setLeanBackMode(leanBack);

        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY2(window != nullptr, "qml/Main.qml did not load from the module");
        controller.navigation()->goHome();
        QVERIFY(QTest::qWaitForWindowExposed(window));

        QQuickItem *sidebar = itemNamed(window, QStringLiteral("sidebar"));
        QVERIFY(sidebar != nullptr);
        QCOMPARE(qRound(sidebar->property("implicitWidth").toReal()), width);
        QTRY_COMPARE(qRound(sidebar->width()), width);

        QQuickItem *column = itemNamed(sidebar, QStringLiteral("sidebarRouteColumn"));
        QVERIFY(column != nullptr);
        QCOMPARE(qRound(column->property("spacing").toReal()), rowSpacing);
        QCOMPARE(qRound(column->y()), topMargin);

        for (int index = 0; index < releasedRoutes().size(); ++index) {
            QQuickItem *entry = routeEntry(sidebar, index);
            QQuickItem *surface = routeSurface(sidebar, index);
            QQuickItem *frame = routeLayer(sidebar, index, "sidebarRouteSymbolFrame");
            QQuickItem *symbol = routeSymbol(sidebar, index);
            QVERIFY(entry != nullptr && surface != nullptr && frame != nullptr
                    && symbol != nullptr);

            QCOMPARE(qRound(entry->height()), rowHeight);
            QCOMPARE(qRound(frame->width()), symbolFrame);
            QCOMPARE(qRound(frame->height()), symbolFrame);
            QCOMPARE(qRound(symbol->property("pointSize").toReal()), symbolPoints);
            // :202 insets each row's painted background from both edges.
            QCOMPARE(qRound(surface->x()), inset);
            QCOMPARE(qRound(surface->width()), width - 2 * inset);
        }

        QQuickItem *playSomething = itemNamed(sidebar, QStringLiteral("sidebarPlaySomething"));
        QQuickItem *profile = itemNamed(sidebar, QStringLiteral("sidebarProfile"));
        QQuickItem *avatar = itemNamed(sidebar, QStringLiteral("sidebarProfileAvatar"));
        QVERIFY(playSomething != nullptr && profile != nullptr && avatar != nullptr);
        QCOMPARE(qRound(playSomething->height()), playSomethingHeight);
        QCOMPARE(qRound(profile->height()), profileHeight);
        QCOMPARE(qRound(avatar->width()), avatarDiameter);
        QCOMPARE(qRound(avatar->height()), avatarDiameter);
        // :48 and :150-152 keep the avatar a circle at either size.
        QCOMPARE(qRound(avatar->property("radius").toReal()), avatarDiameter / 2);

        // :108 and :134 hold the profile control at the bottom of the column.
        QTRY_COMPARE(qRound(profile->y() + profile->height()), qRound(sidebar->height()));
    }

    // MarqueeSidebar.swift:130-132 labels the profile control with the active
    // profile's name and always hints what it does; :158-163 draws that
    // profile's own symbol and colour, or the released fallback identity when
    // there is no profile. UserProfile.swift:17-48 lists thirty catalog
    // symbols, so a profile naming one this surface cannot draw still reaches
    // :158's fallback rather than an empty avatar.
    void theProfileControlNamesTheActiveProfileAndFallsBackToTheReleasedIdentity()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        ApplicationController controller;
        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY2(window != nullptr, "qml/Main.qml did not load from the module");

        QQuickItem *sidebar = itemNamed(window, QStringLiteral("sidebar"));
        QVERIFY(sidebar != nullptr);
        QQuickItem *profile = itemNamed(sidebar, QStringLiteral("sidebarProfile"));
        QQuickItem *symbol = itemNamed(sidebar, QStringLiteral("sidebarProfileSymbol"));
        QVERIFY(profile != nullptr && symbol != nullptr);

        // With no profile bound the sidebar shows :130's fallback label over
        // :158's fallback symbol, inked by :162's accent.
        QVERIFY(!sidebar->property("hasActiveProfile").toBool());
        QCOMPARE(accessibleName(profile), QStringLiteral("Switch Profile"));
        QCOMPARE(accessibleDescription(profile), QStringLiteral("Switch Profile"));
        QCOMPARE(symbol->property("resolvedSymbol").toString(),
                 QStringLiteral("person.crop.circle"));
        QCOMPARE(symbol->property("color").value<QColor>(), kAccentBright);

        // A profile whose symbol this surface draws takes both its symbol and
        // its own colour.
        sidebar->setProperty("activeProfileName", QStringLiteral("Alex"));
        sidebar->setProperty("activeProfileAvatarIcon", QStringLiteral("person.crop.circle"));
        sidebar->setProperty("activeProfileAvatarColor", QColor("#ff6b6b"));
        QVERIFY(sidebar->property("hasActiveProfile").toBool());
        QCOMPARE(accessibleName(profile), QStringLiteral("Alex"));
        QCOMPARE(accessibleDescription(profile), QStringLiteral("Switch Profile"));
        QCOMPARE(symbol->property("resolvedSymbol").toString(),
                 QStringLiteral("person.crop.circle"));
        QCOMPARE(symbol->property("color").value<QColor>(), QColor("#ff6b6b"));

        // A catalog avatar (UserProfile.swift:60-92) is drawn as itself.
        sidebar->setProperty("activeProfileAvatarIcon", QStringLiteral("hare.fill"));
        QCOMPARE(symbol->property("symbol").toString(), QStringLiteral("hare.fill"));
        QCOMPARE(symbol->property("resolvedSymbol").toString(), QStringLiteral("hare.fill"));
        QVERIFY(symbol->property("hasPath").toBool());

        // A symbol nothing here can draw keeps the profile's name and colour
        // and falls back to the released identity symbol, rather than
        // drawing nothing.
        sidebar->setProperty("activeProfileAvatarIcon", QStringLiteral("sparkles.rectangle.stack"));
        QCOMPARE(symbol->property("resolvedSymbol").toString(),
                 QStringLiteral("person.crop.circle"));
        QVERIFY(symbol->property("hasPath").toBool());
        QCOMPARE(accessibleName(profile), QStringLiteral("Alex"));
        QCOMPARE(symbol->property("color").value<QColor>(), QColor("#ff6b6b"));
    }

    // MarqueeSidebar.swift:137 lays the column on the kids surface layer
    // under a kids profile, and :162 inks the fallback avatar with the kids
    // accent there.
    void kidsModeLaysTheSidebarOnTheKidsSurfaceLayerWithTheKidsAvatarAccent()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        ApplicationController controller;
        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY2(window != nullptr, "qml/Main.qml did not load from the module");

        QQuickItem *sidebar = itemNamed(window, QStringLiteral("sidebar"));
        QVERIFY(sidebar != nullptr);
        QQuickItem *surface = itemNamed(sidebar, QStringLiteral("sidebarSurface"));
        QQuickItem *symbol = itemNamed(sidebar, QStringLiteral("sidebarProfileSymbol"));
        QVERIFY(surface != nullptr && symbol != nullptr);

        QCOMPARE(surface->property("color").value<QColor>(), QColor("#231d30"));
        QCOMPARE(symbol->property("color").value<QColor>(), kAccentBright);

        sidebar->setProperty("kidsMode", true);
        QCOMPARE(surface->property("color").value<QColor>(), QColor("#2e2245"));
        QCOMPARE(symbol->property("color").value<QColor>(), QColor("#ffd600"));

        // A kids profile's own avatar colour still wins, as :161-163 orders
        // the fallback chain.
        sidebar->setProperty("activeProfileName", QStringLiteral("Sam"));
        sidebar->setProperty("activeProfileAvatarColor", QColor("#4ecdc4"));
        QCOMPARE(symbol->property("color").value<QColor>(), QColor("#4ecdc4"));
    }

    // SidebarRow.swift:199-201 lifts a remote-focused row that is not the
    // selected one, over MarqueeTheme.swift:251's spring, and :273-275
    // removes that motion entirely under Reduce Motion.
    void reduceMotionAppliesTheRemoteFocusLiftWithoutAnimatingIt()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        ApplicationController controller;
        controller.settings()->setReduceMotion(true);

        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY2(window != nullptr, "qml/Main.qml did not load from the module");
        controller.navigation()->goHome();

        QQuickItem *sidebar = itemNamed(window, QStringLiteral("sidebar"));
        QVERIFY(sidebar != nullptr);
        QTRY_VERIFY(sidebar->hasActiveFocus());
        QVERIFY(sidebar->property("reduceMotion").toBool());

        QQuickItem *home = routeSurface(sidebar, 0);
        QQuickItem *movies = routeSurface(sidebar, 2);
        QVERIFY(home != nullptr && movies != nullptr);

        // :199 withholds the lift from the row that is already selected, even
        // while the remote is on it.
        QCOMPARE(focusedIndexOf(sidebar), 0);
        QCOMPARE(home->scale(), 1.0);

        QTest::keyClick(window, Qt::Key_Down);
        QTest::keyClick(window, Qt::Key_Down);
        QCOMPARE(focusedIndexOf(sidebar), 2);
        // Reduce Motion reaches the lifted scale in this delivery, not after
        // a timed wait.
        QCOMPARE(movies->scale(), 1.03);

        QTest::keyClick(window, Qt::Key_Up);
        QCOMPARE(movies->scale(), 1.0);

        // Neither step above ran the row's animation at all. `animation` is a
        // deferred property of Behavior, so QtQuick builds the declared
        // NumberAnimation only when an enabled Behavior first intercepts a
        // write; a disabled one never does, and none exists here yet.
        QVERIFY(movies->findChild<QObject *>(QStringLiteral("sidebarRouteScale")) == nullptr);

        // With motion on the same step is animated instead, over
        // MarqueeTheme.swift:251's quarter second, and still settles on the
        // released scale. The declared duration and the settled value are the
        // contract; the trajectory between them is not asserted.
        controller.settings()->setReduceMotion(false);
        QTRY_VERIFY(!sidebar->property("reduceMotion").toBool());
        QTest::keyClick(window, Qt::Key_Down);
        QCOMPARE(focusedIndexOf(sidebar), 2);

        // That intercepted write is what instantiates the animation, so the
        // duration is read from the object Sidebar.qml:126-130 actually built
        // and is now running, not from a value restated here.
        QObject *lift = movies->findChild<QObject *>(QStringLiteral("sidebarRouteScale"));
        QVERIFY(lift != nullptr);
        QCOMPARE(lift->property("duration").toInt(), 250);
        QVERIFY(lift->property("running").toBool());
        QTRY_COMPARE(movies->scale(), 1.03);
    }

    // SidebarRow.swift:211-216 orders the route symbol's ink: remote focus
    // first, then selection, then the resting tertiary text colour. The proof
    // is painted pixels of the shipped surface, because that ordering is what
    // a viewer sees rather than a property this suite could read back from
    // the binding it is checking.
    //
    // Rendered under the offscreen platform's software backend. Display-backed
    // and physical-remote acceptance on the theater GPU are separate gates and
    // are not claimed here.
    void theRouteSymbolInkFollowsTheReleasedFocusThenSelectionPrecedence()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        ApplicationController controller;
        // The settings store's own default, so the symbol is drawn at
        // MarqueeSidebar.swift:183's lean-back 21 points and its filled body
        // is several pixels across at either device pixel ratio.
        controller.settings()->setLeanBackMode(true);
        controller.settings()->setReduceMotion(true);

        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY2(window != nullptr, "qml/Main.qml did not load from the module");
        controller.navigation()->goHome();
        QVERIFY(QTest::qWaitForWindowExposed(window));

        QQuickItem *sidebar = itemNamed(window, QStringLiteral("sidebar"));
        QVERIFY(sidebar != nullptr);
        QTRY_VERIFY(sidebar->hasActiveFocus());

        // Home's `house.fill` is the one filled symbol of the five, so its
        // body carries whole pixels of whichever ink was chosen; a stroked
        // symbol leaves only antialiased mixtures at this point size.
        QQuickItem *home = routeSymbol(sidebar, 0);
        QVERIFY(home != nullptr);
        const QList<QQuickItem *> measured{home};

        const auto onlyInk = [&](const QColor &expected) {
            return [&, expected](const Capture &capture) {
                return inkPixels(capture, home, expected) > 0;
            };
        };
        const auto assertInk = [&](const Capture &capture, const QColor &expected,
                                   const QColor &firstAbsent, const QColor &secondAbsent,
                                   const char *state) {
            QVERIFY2(capture.coherent(), state);
            QVERIFY2(inkPixels(capture, home, expected) > 0,
                     qPrintable(QStringLiteral("%1: no %2 pixels in the Home symbol")
                                    .arg(QLatin1String(state), expected.name())));
            QCOMPARE(inkPixels(capture, home, firstAbsent), 0);
            QCOMPARE(inkPixels(capture, home, secondAbsent), 0);
        };

        // Remote focus on the selected Home row: :212 wins over :213.
        QCOMPARE(focusedIndexOf(sidebar), 0);
        QCOMPARE(controller.navigation()->route(), NavigationController::Route::Home);
        const Capture focused =
            captureWindowUntil(window, measured, onlyInk(kStructuralFocus));
        assertInk(focused, kStructuralFocus, kAccentBright, kTextTertiary,
                  "remote focus on the selected route");

        // Handing the remote across leaves Home selected but unfocused: :213.
        // What the ink depends on is that the sidebar no longer holds the
        // remote, wherever inside the content surface it landed.
        QTest::keyClick(window, Qt::Key_Right);
        QTRY_VERIFY(!sidebar->hasActiveFocus());
        const Capture selected =
            captureWindowUntil(window, measured, onlyInk(kAccentBright));
        assertInk(selected, kAccentBright, kStructuralFocus, kTextTertiary,
                  "the selected route with the remote elsewhere");

        // Opening another route leaves Home neither: :215's resting ink.
        controller.navigation()->openRoute(NavigationController::Route::Movies);
        QTRY_COMPARE(sidebar->property("selectedRoute").toInt(),
                     int(NavigationController::Route::Movies));
        const Capture resting =
            captureWindowUntil(window, measured, onlyInk(kTextTertiary));
        assertInk(resting, kTextTertiary, kStructuralFocus, kAccentBright,
                  "an unselected route with the remote elsewhere");

        QVERIFY(focused.sameGeometryAs(selected));
        QVERIFY(focused.sameGeometryAs(resting));
    }

    // MarqueeSidebar.swift:76-78 inks Play Something's shuffle symbol in the
    // secondary accent at 0.78, and :85-90 fills its surface with the primary
    // accent at 0.14, until the remote is on it: then :78 takes the primary
    // text colour over :88's solid accent. The two states are asserted over
    // the same painted pixels, against the released tokens themselves rather
    // than against the colour the surface under test reports, and the states
    // the contract forbids are then presented and refused.
    //
    // Rendered under the offscreen platform's software backend; display-backed
    // acceptance is a separate gate.
    void thePlaySomethingControlRepaintsItsSurfaceAndInkWhenTheRemoteReachesIt()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        ApplicationController controller;
        // The settings store's own default, so the shuffle symbol and its
        // surface are drawn at MarqueeSidebar.swift:77-83's lean-back sizes.
        controller.settings()->setLeanBackMode(true);
        controller.settings()->setReduceMotion(true);

        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY2(window != nullptr, "qml/Main.qml did not load from the module");
        controller.navigation()->goHome();
        QVERIFY(QTest::qWaitForWindowExposed(window));

        QQuickItem *sidebar = itemNamed(window, QStringLiteral("sidebar"));
        QVERIFY(sidebar != nullptr);
        QTRY_VERIFY(sidebar->hasActiveFocus());

        QQuickItem *surface = itemNamed(sidebar, QStringLiteral("sidebarPlaySomethingSurface"));
        QQuickItem *symbol = itemNamed(sidebar, QStringLiteral("sidebarPlaySomethingSymbol"));
        QVERIFY(surface != nullptr && symbol != nullptr);
        const QList<QQuickItem *> measured{surface, symbol};

        // :85-90's resting fill: the primary accent at 0.14 over the surface
        // layer, which is neither the accent nor the layer alone. Both the
        // layer and the accent are the released tokens above, not values read
        // back from the surface being judged.
        const QColor restingFill = render_probe::sourceOverOn(kSurfaceLayer, kAccentPrimary,
                                                              kPlaySomethingRestingFillOpacity);
        // The surface's own interior, clear of :86's rounded corners and of
        // :92-98's ring, whose antialiased edges carry mixtures of both
        // states' inks that neither model predicts.
        const auto interiorOf = [&](const Capture &capture) {
            const QRect rect = imageRectForItem(capture, surface);
            return rect.isEmpty()
                ? QRect()
                : rect.adjusted(render_probe::pixels(capture, 8),
                                render_probe::pixels(capture, 8),
                                -render_probe::pixels(capture, 8),
                                -render_probe::pixels(capture, 8));
        };
        const auto fillPixels = [&](const Capture &capture, const QColor &expected) {
            const QRect interior = interiorOf(capture);
            return interior.isEmpty()
                ? -1
                : countPixels(capture.image, interior, [&](const QColor &pixel) {
                      return render_probe::withinTolerance(pixel, expected, 2);
                  });
        };

        // MarqueeSymbol.qml:43 strokes a symbol at a ninth of its point size,
        // which at :77's lean-back 21 points is under two device pixels at
        // ratio 1: the shuffle lands as antialiased mixtures of its ink and
        // the fill beneath it rather than as whole covered pixels. A pixel is
        // the symbol's own when it carries this much of that ink, a coverage
        // the fill can never reach however its own colour changes.
        constexpr qreal minimumCoverage = 0.35;
        constexpr int inkTolerance = 6;
        const qreal strokeWidth = symbol->property("strokeWidth").toReal();
        QVERIFY2(strokeWidth > 0.0, "the shuffle symbol reported no stroke width to draw with");
        // A floor no drawn shuffle can fall under: a stroked path leaves at
        // least the square of its own width, while MarqueeSymbol.qml:136-150's
        // shuffle is two long crossing runs and four arrowhead segments, an
        // order of magnitude more. An empty or transparent path leaves none.
        const auto minimumInkPixels = [&](const Capture &capture) {
            const qreal device = strokeWidth * capture.devicePixelRatio;
            return qMax(1, qRound(device * device));
        };
        // :78's ink, read from the shipped component rather than restated
        // here, fully covering the fill it is drawn on.
        const auto coveredInk = [](const QColor &fill, const QColor &ink) {
            return render_probe::sourceOverOn(fill, ink, qreal(ink.alphaF()));
        };
        const auto strokePixels = [&](const Capture &capture, const QColor &fill,
                                      const QColor &ink) {
            return inkCoveragePixels(capture, symbol, fill, coveredInk(fill, ink),
                                     minimumCoverage, inkTolerance);
        };
        // An ink the colour of the fill, or drawn at no alpha, would put every
        // mixture at the fill itself and make the coverage above meaningless:
        // the faintest pixel this counts must be one the fill cannot be
        // mistaken for.
        const auto inkDepartsFromFill = [&](const QColor &fill, const QColor &ink) {
            return !render_probe::withinTolerance(
                render_probe::sourceOverOn(fill, ink, qreal(ink.alphaF()) * minimumCoverage), fill,
                inkTolerance);
        };
        const auto reportInk = [&](const Capture &capture, const QColor &fill, const QColor &ink,
                                   const char *state) {
            return QStringLiteral("the %1 shuffle symbol painted %2 pixels of %3, needed %4")
                .arg(QLatin1String(state))
                .arg(strokePixels(capture, fill, ink))
                .arg(coveredInk(fill, ink).name())
                .arg(minimumInkPixels(capture));
        };

        const QColor restingInk = playSomethingRestingInk();
        const QColor focusedInk = playSomethingFocusedInk();
        QVERIFY2(inkDepartsFromFill(restingFill, restingInk),
                 "the resting shuffle ink cannot be told from the surface beneath it");

        const Capture resting = captureWindowUntil(
            window, measured, [&](const Capture &capture) {
                return fillPixels(capture, restingFill) > 0
                    && strokePixels(capture, restingFill, restingInk) >= minimumInkPixels(capture);
            });
        QVERIFY2(resting.coherent() && fillPixels(resting, restingFill) > 0,
                 "the resting Play Something surface did not paint the released 0.14 accent");
        QCOMPARE(fillPixels(resting, kAccentPrimary), 0);
        // :78's resting ink, proven where the symbol was actually painted.
        QVERIFY2(strokePixels(resting, restingFill, restingInk) >= minimumInkPixels(resting),
                 qPrintable(reportInk(resting, restingFill, restingInk, "resting")));

        sidebar->setProperty("focusedIndex", sidebar->property("playSomethingIndex"));
        QVERIFY2(inkDepartsFromFill(kAccentPrimary, focusedInk),
                 "the focused shuffle ink cannot be told from the surface beneath it");

        // :88 fills the focused control with the accent itself, so pixels of
        // the solid accent appear where the 0.14 wash used to be, and :78
        // repaints the symbol over it in the primary text colour.
        const Capture reached = captureWindowUntil(
            window, measured, [&](const Capture &capture) {
                return fillPixels(capture, kAccentPrimary) > 0
                    && strokePixels(capture, kAccentPrimary, focusedInk)
                        >= minimumInkPixels(capture);
            });
        QVERIFY2(reached.coherent() && fillPixels(reached, kAccentPrimary) > 0,
                 "the focused Play Something surface did not paint the released solid accent");
        QCOMPARE(fillPixels(reached, restingFill), 0);
        QVERIFY(resting.sameGeometryAs(reached));
        QVERIFY2(strokePixels(reached, kAccentPrimary, focusedInk) >= minimumInkPixels(reached),
                 qPrintable(reportInk(reached, kAccentPrimary, focusedInk, "focused")));

        // Neither capture carries the other state's ink over its own fill,
        // which is what a symbol that kept its ink while the surface beneath
        // it repainted would leave.
        QCOMPARE(strokePixels(resting, restingFill, focusedInk), 0);
        QCOMPARE(strokePixels(reached, kAccentPrimary, restingInk), 0);

        // The two states also differ over the symbol as a whole. This is a
        // supplement to the ink counts above: the rectangle it scans includes
        // the fill between the strokes, which changes on its own.
        QVERIFY(render_probe::changedPixels(resting, reached,
                                            imageRectForItem(resting, symbol))
                > 0);

        // The failure conditions the checks above must refuse. Each drives the
        // shipped symbol into one of them and waits for the scene to actually
        // paint that state, so a refusal is never a frame that never arrived.
        // Every expectation stays the released ink, which is what makes the
        // refusals meaningful. Writing the symbol's colour replaces
        // Sidebar.qml:224-227's binding on this engine alone; the released
        // values above are never re-read from it.
        bool settled = false;
        const auto settleOn = [&](const render_probe::CapturePredicate &painted) {
            return captureWindowUntil(window, measured, painted, 5000, &settled);
        };
        // What an expectation read back from the symbol's own colour property
        // would conclude. It follows whatever the binding chose, so it accepts
        // the wrong-state ink below; the released expectation refuses it.
        const auto ownColourOf = [&] { return symbol->property("color").value<QColor>(); };
        // The released resting ink actually on the pixels again, which every
        // refusal below is measured as a departure from rather than against a
        // probe that had simply stopped finding ink.
        const auto repaintRestingInk = [&] {
            sidebar->setProperty("focusedIndex", 0);
            symbol->setProperty("symbol", QStringLiteral("shuffle"));
            symbol->setProperty("color", restingInk);
            const Capture painted = settleOn([&](const Capture &capture) {
                return fillPixels(capture, restingFill) > 0
                    && strokePixels(capture, restingFill, restingInk) >= minimumInkPixels(capture);
            });
            return settled && strokePixels(painted, restingFill, restingInk)
                >= minimumInkPixels(painted);
        };

        // A focused control still carrying the resting ink: the stale symbol a
        // fill-only repaint would leave behind.
        symbol->setProperty("color", restingInk);
        sidebar->setProperty("focusedIndex", sidebar->property("playSomethingIndex"));
        const Capture staleFocused = settleOn([&](const Capture &capture) {
            return fillPixels(capture, kAccentPrimary) > 0
                && strokePixels(capture, kAccentPrimary, restingInk) >= minimumInkPixels(capture);
        });
        QVERIFY2(settled, "the focused control never repainted under the resting ink");
        QVERIFY2(strokePixels(staleFocused, kAccentPrimary, focusedInk) == 0,
                 qPrintable(reportInk(staleFocused, kAccentPrimary, focusedInk, "stale focused")));
        // The same frame satisfies an expectation read back from the symbol's
        // own colour, which is the regression the released one now catches.
        QVERIFY2(strokePixels(staleFocused, kAccentPrimary, ownColourOf())
                     >= minimumInkPixels(staleFocused),
                 "the stale focused symbol painted neither ink");

        // The opposite divergence: a resting control inked as though the
        // remote were on it.
        sidebar->setProperty("focusedIndex", 0);
        symbol->setProperty("color", focusedInk);
        const Capture wrongResting = settleOn([&](const Capture &capture) {
            return fillPixels(capture, restingFill) > 0
                && strokePixels(capture, restingFill, focusedInk) >= minimumInkPixels(capture);
        });
        QVERIFY2(settled, "the resting control never repainted under the focused ink");
        QVERIFY2(strokePixels(wrongResting, restingFill, restingInk) == 0,
                 qPrintable(reportInk(wrongResting, restingFill, restingInk, "wrong-state resting")));
        QVERIFY2(strokePixels(wrongResting, restingFill, ownColourOf())
                     >= minimumInkPixels(wrongResting),
                 "the wrong-state resting symbol painted neither ink");

        // An ink at no alpha leaves the fill exactly, so the symbol vanishes
        // from the pixels while the surface beneath is untouched. The guard
        // above rejects such an ink before any count is taken.
        QVERIFY(repaintRestingInk());
        symbol->setProperty("color", QColor(Qt::transparent));
        QVERIFY2(!inkDepartsFromFill(restingFill, ownColourOf()),
                 "a fully transparent ink was treated as distinguishable from its fill");
        const Capture transparentInk = settleOn([&](const Capture &capture) {
            return fillPixels(capture, restingFill) > 0
                && strokePixels(capture, restingFill, restingInk) == 0;
        });
        QVERIFY2(settled, "the transparent ink never cleared the painted symbol");
        QCOMPARE(strokePixels(transparentInk, restingFill, focusedInk), 0);
        QCOMPARE(fillPixels(transparentInk, kAccentPrimary), 0);

        // No symbol at all: MarqueeSymbol.qml:175-181 clears the canvas and
        // returns for a name it holds no path for, leaving only the fill.
        QVERIFY(repaintRestingInk());
        symbol->setProperty("symbol", QString());
        QVERIFY(!symbol->property("hasPath").toBool());
        const Capture absentSymbol = settleOn([&](const Capture &capture) {
            return fillPixels(capture, restingFill) > 0
                && strokePixels(capture, restingFill, restingInk) == 0;
        });
        QVERIFY2(settled,
                 qPrintable(reportInk(absentSymbol, restingFill, restingInk, "absent")));
        QCOMPARE(strokePixels(absentSymbol, restingFill, focusedInk), 0);
        QVERIFY(resting.sameGeometryAs(absentSymbol));

        // The released symbol paints again over the same fill, so every
        // refusal above was the modelled state and not an exhausted probe.
        QVERIFY(repaintRestingInk());
    }
};

int main(int argc, char *argv[])
{
    QGuiApplication app(argc, argv);
    SidebarNavigationTest test;
    return QTest::qExec(&test, argc, argv);
}

#include "tst_sidebar_navigation.moc"
