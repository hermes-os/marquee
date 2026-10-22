#include <QtTest>

#include <QDir>
#include <QFile>
#include <QGuiApplication>
#include <QImage>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickItem>
#include <QQuickWindow>
#include <QScopeGuard>
#include <QSqlQuery>
#include <QTemporaryDir>

#include "app/AppPaths.hpp"
#include "app/ApplicationController.hpp"
#include "catalog/CatalogDatabase.hpp"
#include "catalog/CatalogStore.hpp"
#include "catalog/LibraryScanner.hpp"
#include "models/HomeRowsModel.hpp"
#include "models/ShowsModel.hpp"
#include "navigation/NavigationController.hpp"
#include "profiles/ProfileStore.hpp"
#include "settings/SettingsStore.hpp"
#include "support/RenderProbe.hpp"

namespace
{
[[nodiscard]] bool writeFile(const QString &path)
{
    QDir().mkpath(QFileInfo(path).absolutePath());
    QFile file(path);
    return file.open(QIODevice::WriteOnly) && file.write("media") == 5;
}

// A real image file, so a sidecar the scanner adopts is one the scene can
// decode.
[[nodiscard]] bool writeImage(const QString &path, const QColor &colour)
{
    QDir().mkpath(QFileInfo(path).absolutePath());
    QImage image(640, 360, QImage::Format_RGB32);
    image.fill(colour);
    return image.save(path, "PNG");
}

[[nodiscard]] QColor Theme_background()
{
    return QColor(QStringLiteral("#0d0b1a"));
}

[[nodiscard]] QString mainProfileId()
{
    AppPaths::ensureDirectories();
    const ProfileStore profiles(AppPaths::profilesFile());
    return profiles.profiles().at(0).id;
}

// The fixture's seeded rows: a catalog scanned and given watch progress before
// the controller opens it, the way a viewer's earlier sessions leave it.
struct Seed
{
    QVector<LibraryRoot> roots;
    QString profileId;

    [[nodiscard]] QString idOf(const QString &title, int episode = 0) const
    {
        CatalogStore store(AppPaths::catalogFile());
        for (const MediaItem &item : store.projection(roots, profileId)) {
            if (item.isEpisode() ? (item.showName == title && item.episodeNumber == episode)
                                 : item.title == title) {
                return item.id;
            }
        }
        return {};
    }

    void record(const QString &id, qint64 positionMs, bool completed) const
    {
        CatalogStore store(AppPaths::catalogFile());
        store.recordWatchProgress(profileId, id, positionMs, 3'600'000, completed);
    }
};

[[nodiscard]] Seed seed(const QString &movies, const QString &shows)
{
    AppPaths::ensureDirectories();
    CatalogDatabase catalog(AppPaths::catalogFile());
    catalog.migrate();
    CatalogStore store(AppPaths::catalogFile());
    LibraryRootPaths paths;
    if (!movies.isEmpty()) {
        paths.movies.push_back(movies);
    }
    if (!shows.isEmpty()) {
        paths.tvShows.push_back(shows);
    }
    Seed result;
    result.roots = store.registerRoots(paths);
    for (const LibraryRoot &root : result.roots) {
        store.applyScan(root, LibraryScanner::scan(root));
    }
    result.profileId = mainProfileId();
    return result;
}

[[nodiscard]] QQuickItem *itemNamed(QQuickWindow *window, const char *name)
{
    return window->findChild<QQuickItem *>(QLatin1String(name));
}

// The visual descendants of `root` named `name`: a Repeater's delegates hang
// off the item tree, not off the object tree `findChildren` walks.
void collectNamed(QQuickItem *root, const QString &name, QList<QQuickItem *> &found)
{
    for (QQuickItem *child : root->childItems()) {
        if (child->objectName() == name) {
            found.push_back(child);
        }
        collectNamed(child, name, found);
    }
}

[[nodiscard]] QList<QQuickItem *> allNamed(QQuickItem *root, const QString &name)
{
    QList<QQuickItem *> found;
    collectNamed(root, name, found);
    return found;
}

[[nodiscard]] QQuickItem *firstNamed(QQuickItem *root, const QString &name)
{
    const QList<QQuickItem *> found = allNamed(root, name);
    return found.isEmpty() ? nullptr : found.constFirst();
}

// A Repeater's delegates hang off the repeater, not the window.
[[nodiscard]] QQuickItem *rowNamed(QQuickWindow *window, const QString &rowId)
{
    QQuickItem *repeater = itemNamed(window, "homeRows");
    if (repeater == nullptr) {
        return nullptr;
    }
    const int count = repeater->property("count").toInt();
    for (int index = 0; index < count; ++index) {
        QQuickItem *row = nullptr;
        if (QMetaObject::invokeMethod(repeater, "itemAt", Q_RETURN_ARG(QQuickItem *, row),
                                      Q_ARG(int, index))
            && row != nullptr && row->objectName() == QStringLiteral("homeRow_") + rowId) {
            return row;
        }
    }
    return nullptr;
}

[[nodiscard]] QString rowIdAt(HomeRowsModel *rows, int row)
{
    return rows->data(rows->index(row), HomeRowsModel::RowIdRole).toString();
}

[[nodiscard]] QStringList rowIds(HomeRowsModel *rows)
{
    QStringList ids;
    for (int row = 0; row < rows->rowCount(); ++row) {
        ids.push_back(rowIdAt(rows, row));
    }
    return ids;
}
}

class HomeScreenTest final : public QObject
{
    Q_OBJECT

    struct Shell
    {
        QTemporaryDir runtimeRoot;
        QTemporaryDir movies;
        QTemporaryDir shows;
        std::unique_ptr<ApplicationController> controller;
        std::unique_ptr<QQmlApplicationEngine> engine;
        QQuickWindow *window = nullptr;
        Seed seeded;

        ~Shell()
        {
            engine.reset();
            controller.reset();
            AppPaths::clearRuntimeRoot();
        }
    };

    // Opens the shipped shell on Home for `shell`'s fixture, with the viewer
    // chosen as the seeded Main profile and the remote handed to the content.
    // `prepare` runs between the scan and the controller, to record progress.
    template <typename Prepare>
    [[nodiscard]] bool open(Shell &shell, Prepare prepare, bool withMovies, bool withShows)
    {
        AppPaths::setRuntimeRoot(shell.runtimeRoot.path());
        shell.seeded = seed(withMovies ? shell.movies.path() : QString(),
                            withShows ? shell.shows.path() : QString());
        prepare(shell.seeded);

        shell.controller = std::make_unique<ApplicationController>();
        shell.controller->setStartFullscreen(false);
        if (withMovies) {
            shell.controller->setTemporaryLibraryRoot(shell.movies.path());
        }
        if (withShows) {
            shell.controller->setTemporaryTvShowsRoot(shell.shows.path());
        }
        if (!shell.controller->chooseProfile(shell.seeded.profileId)
            || !QTest::qWaitFor([&] { return !shell.controller->profileExitInFlight(); })) {
            return false;
        }
        shell.engine = std::make_unique<QQmlApplicationEngine>();
        shell.engine->rootContext()->setContextProperty(QStringLiteral("appController"),
                                                        shell.controller.get());
        shell.engine->loadFromModule(QStringLiteral("Marquee"), QStringLiteral("Main"));
        if (shell.engine->rootObjects().size() != 1) {
            return false;
        }
        shell.window = qobject_cast<QQuickWindow *>(shell.engine->rootObjects().front());
        if (shell.window == nullptr) {
            return false;
        }
        shell.window->resize(1600, 900);
        shell.window->requestActivate();
        shell.controller->navigation()->goHome();
        return QTest::qWaitForWindowExposed(shell.window);
    }

    // The shell starts with the sidebar focused, and its first Right is that
    // hand-off rather than a card move.
    [[nodiscard]] bool handToContent(Shell &shell)
    {
        QQuickItem *content = itemNamed(shell.window, "contentFocus");
        if (content == nullptr) {
            return false;
        }
        QTest::keyClick(shell.window, Qt::Key_Right);
        return QTest::qWaitFor([&] { return content->hasActiveFocus(); });
    }

    static void press(Shell &shell, Qt::Key key)
    {
        QTest::keyClick(shell.window, key);
        QCoreApplication::processEvents();
    }

    // Home opens on the hero (HomeDetailView.swift:21), so a case about the
    // rows takes the remote down to the first one.
    [[nodiscard]] static bool enterRows(Shell &shell)
    {
        if (!shell.controller->homeRows()->heroFocused()) {
            return true;
        }
        press(shell, Qt::Key_Down);
        return !shell.controller->homeRows()->heroFocused();
    }

    // The sidebar owns the remote when the shell opens; walk it to the Play
    // Something control with the keys the remote has.
    [[nodiscard]] bool focusSidebarPlaySomething(Shell &shell)
    {
        QQuickItem *sidebar = itemNamed(shell.window, "sidebar");
        if (sidebar == nullptr || !QTest::qWaitFor([&] { return sidebar->hasActiveFocus(); })) {
            return false;
        }
        const int target = sidebar->property("playSomethingIndex").toInt();
        for (int step = 0; step < target + 2; ++step) {
            QTest::keyClick(shell.window, Qt::Key_Up);
        }
        for (int step = 0; step < target; ++step) {
            QTest::keyClick(shell.window, Qt::Key_Down);
        }
        return sidebar->property("focusedIndex").toInt() == target;
    }

    // Writes the same three movies every Play Something case uses.
    static void writeThreeMovies(Shell &shell)
    {
        QVERIFY(writeFile(shell.movies.path() + QStringLiteral("/Arrival (2016).mkv")));
        QVERIFY(writeFile(shell.movies.path() + QStringLiteral("/Coco (2017).mkv")));
        QVERIFY(writeFile(shell.movies.path() + QStringLiteral("/Dune (2021).mkv")));
    }

    // Writes three movies that each have a poster and a backdrop of their own
    // colour, so the hero has artwork to draw and the render can be judged.
    static void writeThreeMoviesWithArtwork(Shell &shell)
    {
        for (const auto &film : {std::pair{QStringLiteral("Arrival (2016)"), QColor(200, 30, 30)},
                                 std::pair{QStringLiteral("Coco (2017)"), QColor(30, 200, 30)},
                                 std::pair{QStringLiteral("Dune (2021)"), QColor(30, 30, 200)}}) {
            QVERIFY(writeFile(shell.movies.path() + QLatin1Char('/') + film.first + QLatin1Char('/')
                              + film.first + QStringLiteral(".mkv")));
            QVERIFY(writeImage(shell.movies.path() + QLatin1Char('/') + film.first
                                   + QStringLiteral("/poster.png"),
                               QColor(220, 220, 40)));
            QVERIFY(writeImage(shell.movies.path() + QLatin1Char('/') + film.first
                                   + QStringLiteral("/fanart.png"),
                               film.second));
        }
    }

    // The carousel's cards, front to back by logical slide.
    [[nodiscard]] static QQuickItem *centerCard(Shell &shell)
    {
        QQuickItem *hero = itemNamed(shell.window, "homeHero");
        if (hero == nullptr) {
            return nullptr;
        }
        for (QQuickItem *card : allNamed(hero, QStringLiteral("heroCard"))) {
            if (card->property("isCenter").toBool() && card->isVisible()) {
                return card;
            }
        }
        return nullptr;
    }


private slots:
    // HomeDetailView.swift:202-203, :21: the hero is the top of the page and
    // Home's first focus, above the rows.
    void theHeroIsTheTopOfHomeAndWhereTheRemoteStarts()
    {
        Shell shell;
        writeThreeMoviesWithArtwork(shell);
        QVERIFY(open(shell, [](const Seed &) {}, true, false));
        HomeRowsModel *rows = shell.controller->homeRows();
        QTRY_VERIFY(rows->hero()->count() == 3);
        QVERIFY(handToContent(shell));

        QQuickItem *hero = itemNamed(shell.window, "homeHero");
        QVERIFY(hero != nullptr);
        QVERIFY(hero->isVisible());
        QVERIFY(rows->heroFocused());
        QVERIFY(hero->property("remoteFocused").toBool());
        QCOMPARE(rows->hero()->currentIndex(), 0);

        // The hero lies above the first row and below the title bar, and the
        // first row holds no focus.
        QQuickItem *firstRow = nullptr;
        QTRY_VERIFY((firstRow = rowNamed(shell.window, rowIdAt(rows, 0))) != nullptr);
        QCOMPARE(firstRow->property("focusedIndex").toInt(), -1);
        const qreal heroBottom = hero->mapToScene(QPointF(0, hero->height())).y();
        QVERIFY(firstRow->mapToScene(QPointF(0, 0)).y() >= heroBottom);
        QQuickItem *bar = itemNamed(shell.window, "homeTitleBarSurface");
        QVERIFY(bar != nullptr);
        QVERIFY(hero->mapToScene(QPointF(0, 0)).y() >= bar->mapToScene(QPointF(0, bar->height())).y()
                - 1.0);

        // Five cards are mounted around the front one (:48-61), of which only
        // the nearest are seen.
        QCOMPARE(allNamed(hero, QStringLiteral("heroCard")).size(), 5);
        QQuickItem *front = centerCard(shell);
        QVERIFY(front != nullptr);
        // The front card offers Watch Now: the button, and over it the item
        // that hears the click, since on a GPU scene graph the card's content
        // is drawn through an effect and is itself not visible.
        QVERIFY(firstNamed(front, QStringLiteral("heroWatchNow")) != nullptr);
        QQuickItem *hit = firstNamed(front, QStringLiteral("heroWatchNowHit"));
        QVERIFY(hit != nullptr);
        QTRY_VERIFY(hit->isVisible());
        // :194-239: arrows and dots for a carousel of more than one.
        QVERIFY(firstNamed(hero, QStringLiteral("heroArrowLeft")) != nullptr);
        QVERIFY(firstNamed(hero, QStringLiteral("heroDots"))->isVisible());
    }

    // HomeDetailView.swift:46-77, :985-1011: the remote walks the hero with
    // Left and Right, enters the first row with Down, returns with Up, and
    // Return plays the spotlight in front with no page between.
    void theRemoteWalksTheHeroAndReturnPlaysIt()
    {
        Shell shell;
        writeThreeMoviesWithArtwork(shell);
        QVERIFY(open(shell, [](const Seed &) {}, true, false));
        HomeRowsModel *rows = shell.controller->homeRows();
        QTRY_COMPARE(rows->hero()->count(), 3);
        shell.controller->settings()->setReduceMotion(true);
        QVERIFY(handToContent(shell));
        QVERIFY(rows->heroFocused());

        press(shell, Qt::Key_Right);
        QCOMPARE(rows->hero()->currentIndex(), 1);
        press(shell, Qt::Key_Left);
        press(shell, Qt::Key_Left);
        // Left from the first slide wraps to the last, and is not the
        // sidebar's.
        QCOMPARE(rows->hero()->currentIndex(), 2);
        QVERIFY(rows->heroFocused());
        QVERIFY(itemNamed(shell.window, "contentFocus")->hasActiveFocus());
        press(shell, Qt::Key_Right);
        QCOMPARE(rows->hero()->currentIndex(), 0);
        press(shell, Qt::Key_Right);
        QCOMPARE(rows->hero()->currentIndex(), 1);

        // The card in front follows the position (:69-75).
        QQuickItem *card = nullptr;
        QTRY_VERIFY((card = centerCard(shell)) != nullptr
                    && card->property("logical").toInt() == 1);

        press(shell, Qt::Key_Down);
        QVERIFY(!rows->heroFocused());
        QCOMPARE(rows->focus()->row(), 0);
        QQuickItem *firstRow = rowNamed(shell.window, rowIdAt(rows, 0));
        QVERIFY(firstRow != nullptr);
        QCOMPARE(firstRow->property("focusedIndex").toInt(), 0);
        QVERIFY(!itemNamed(shell.window, "homeHero")->property("remoteFocused").toBool());

        press(shell, Qt::Key_Up);
        QVERIFY(rows->heroFocused());
        QCOMPARE(firstRow->property("focusedIndex").toInt(), -1);
        // The slide the remote left is still in front.
        QCOMPARE(rows->hero()->currentIndex(), 1);

        const QString expected = rows->hero()->current().value(QStringLiteral("mediaId")).toString();
        QVERIFY(!expected.isEmpty());
        press(shell, Qt::Key_Return);
        QTRY_COMPARE(shell.controller->navigation()->route(), NavigationController::Route::Player);
        QCOMPARE(shell.controller->player()->mediaId(), expected);
        QVERIFY(!shell.controller->hasError());
    }

    // HomeDetailView.swift:1021 answers Back by handing the remote to the
    // sidebar.
    void backOnTheHeroHandsTheRemoteToTheSidebar()
    {
        Shell shell;
        writeThreeMoviesWithArtwork(shell);
        QVERIFY(open(shell, [](const Seed &) {}, true, false));
        QTRY_COMPARE(shell.controller->homeRows()->hero()->count(), 3);
        QVERIFY(handToContent(shell));
        auto *sidebar = itemNamed(shell.window, "sidebar");
        QVERIFY(sidebar != nullptr);
        press(shell, Qt::Key_Escape);
        QTRY_VERIFY(sidebar->hasActiveFocus());
        QCOMPARE(shell.controller->navigation()->route(), NavigationController::Route::Home);
        // With the remote gone from it, the hero is no longer the focused one.
        QVERIFY(!itemNamed(shell.window, "homeHero")->property("remoteFocused").toBool());
    }

    // A click plays (Watch Now), a side card or a dot brings its slide to the
    // front (HeroCarousel.swift:147-163, :208-239), and the arrows step.
    void aPointerPlaysFromWatchNowAndMovesTheCarouselFromItsControls()
    {
        Shell shell;
        writeThreeMoviesWithArtwork(shell);
        QVERIFY(open(shell, [](const Seed &) {}, true, false));
        HomeRowsModel *rows = shell.controller->homeRows();
        QTRY_COMPARE(rows->hero()->count(), 3);
        shell.controller->settings()->setReduceMotion(true);
        QVERIFY(handToContent(shell));
        // Take the remote off the hero so a pointer touch has to bring it
        // back, and scroll the page to its origin as a flick would so the hero
        // is not under the title bar.
        press(shell, Qt::Key_Down);
        QVERIFY(!rows->heroFocused());
        QQuickItem *page = itemNamed(shell.window, "homeScroll");
        QVERIFY(page != nullptr);
        auto *pageSpring = page->findChild<QObject *>(QStringLiteral("homeScrollSpring"));
        QTRY_VERIFY(pageSpring != nullptr && !pageSpring->property("running").toBool());
        page->setProperty("contentY", -page->property("topMargin").toReal());

        const auto centreOf = [&](QQuickItem *item) {
            return item->mapToScene(QPointF(item->width() / 2, item->height() / 2)).toPoint();
        };
        QQuickItem *homeHero = itemNamed(shell.window, "homeHero");
        QVERIFY(homeHero != nullptr);
        QQuickItem *rightArrow = firstNamed(homeHero, QStringLiteral("heroArrowRight"));
        QVERIFY(rightArrow != nullptr);
        QTest::mouseClick(shell.window, Qt::LeftButton, Qt::NoModifier, centreOf(rightArrow));
        QTRY_COMPARE(rows->hero()->currentIndex(), 1);
        QVERIFY(rows->heroFocused());

        QQuickItem *dot = firstNamed(homeHero, QStringLiteral("heroDot_0"));
        QVERIFY(dot != nullptr);
        QTest::mouseClick(shell.window, Qt::LeftButton, Qt::NoModifier, centreOf(dot));
        QTRY_COMPARE(rows->hero()->currentIndex(), 0);

        // The slide 0 -> 2 by the dot is one step back, the shorter way.
        QQuickItem *lastDot = firstNamed(homeHero, QStringLiteral("heroDot_2"));
        QVERIFY(lastDot != nullptr);
        QTest::mouseClick(shell.window, Qt::LeftButton, Qt::NoModifier, centreOf(lastDot));
        QTRY_COMPARE(rows->hero()->currentIndex(), 2);
        QCOMPARE(rows->hero()->position(), -1);

        // Watch Now plays the spotlight in front.
        const QString expected = rows->hero()->current().value(QStringLiteral("mediaId")).toString();
        QQuickItem *watch = nullptr;
        QQuickItem *front = nullptr;
        // The strip has finished sliding: a card is "in front" from half a
        // slide away, and a click aimed at one still moving misses it.
        QTRY_VERIFY((front = centerCard(shell)) != nullptr
                    && homeHero->property("scrollPosition").toReal() == rows->hero()->position()
                    && front->property("logical").toInt() == rows->hero()->position()
                    && firstNamed(front, QStringLiteral("heroWatchNow")) != nullptr);
        watch = firstNamed(front, QStringLiteral("heroWatchNow"));
        QVERIFY(watch != nullptr);
        // The button joins the card's text column when the card reaches the
        // front, and the column lays it out on the next frame: until then the
        // button is reported a line above where it is drawn and a click aimed
        // at it lands beside it. A frame later its place has not moved.
        QPoint at;
        QTRY_VERIFY([&] {
            const QPoint before = centreOf(watch);
            QSignalSpy swapped(shell.window, &QQuickWindow::frameSwapped);
            swapped.wait(100);
            at = centreOf(watch);
            return at == before;
        }());
        QTest::mouseClick(shell.window, Qt::LeftButton, Qt::NoModifier, at);
        QTRY_COMPARE(shell.controller->navigation()->route(), NavigationController::Route::Player);
        QCOMPARE(shell.controller->player()->mediaId(), expected);
    }

    // The title bar is opaque and sits over the page (HomeDetailView.swift
    // :367), so a hero control scrolled under it is neither seen nor reachable:
    // a click, a hover or a drag on the bar belongs to the bar.
    void aPointerOnTheTitleBarDoesNotReachTheHeroUnderIt()
    {
        Shell shell;
        writeThreeMoviesWithArtwork(shell);
        QVERIFY(open(shell, [](const Seed &) {}, true, false));
        HomeRowsModel *rows = shell.controller->homeRows();
        QTRY_COMPARE(rows->hero()->count(), 3);
        shell.controller->settings()->setReduceMotion(true);
        QVERIFY(handToContent(shell));
        press(shell, Qt::Key_Down);
        QVERIFY(!rows->heroFocused());

        QQuickItem *page = itemNamed(shell.window, "homeScroll");
        QQuickItem *bar = itemNamed(shell.window, "homeTitleBarSurface");
        QQuickItem *homeHero = itemNamed(shell.window, "homeHero");
        QVERIFY(page != nullptr && bar != nullptr && homeHero != nullptr);
        auto *pageSpring = page->findChild<QObject *>(QStringLiteral("homeScrollSpring"));
        QTRY_VERIFY(pageSpring != nullptr && !pageSpring->property("running").toBool());
        page->setProperty("contentY", -page->property("topMargin").toReal());

        // Scroll the page until the hero's right arrow is under the middle of
        // the bar.
        QQuickItem *rightArrow = firstNamed(homeHero, QStringLiteral("heroArrowRight"));
        QVERIFY(rightArrow != nullptr);
        const auto centreOf = [](QQuickItem *item) {
            return item->mapToScene(QPointF(item->width() / 2, item->height() / 2));
        };
        const qreal barMiddle = bar->height() / 2;
        QTRY_VERIFY(centreOf(rightArrow).y() > barMiddle);
        page->setProperty("contentY",
                          page->property("contentY").toReal() + centreOf(rightArrow).y() - barMiddle);
        QTRY_VERIFY(qAbs(centreOf(rightArrow).y() - barMiddle) < 1.0);
        const QPoint onTheBar = centreOf(rightArrow).toPoint();
        QVERIFY(onTheBar.y() < bar->height());
        const qreal scrolled = page->property("contentY").toReal();

        QTest::mouseClick(shell.window, Qt::LeftButton, Qt::NoModifier, onTheBar);
        QTest::qWait(100);
        QCOMPARE(rows->hero()->currentIndex(), 0);
        QVERIFY(!rows->heroFocused());
        QCOMPARE(page->property("contentY").toReal(), scrolled);

        // A drag along the bar does not move the strip either.
        QTest::mousePress(shell.window, Qt::LeftButton, Qt::NoModifier, onTheBar);
        for (int step = 1; step <= 12; ++step) {
            QTest::mouseMove(shell.window, onTheBar - QPoint(step * 25, 0));
        }
        QTest::mouseRelease(shell.window, Qt::LeftButton, Qt::NoModifier,
                            onTheBar - QPoint(300, 0));
        QTest::qWait(100);
        QCOMPARE(rows->hero()->currentIndex(), 0);
        QCOMPARE(homeHero->property("dragOffset").toReal(), 0.0);
        QVERIFY(!rows->heroFocused());
        QCOMPARE(page->property("contentY").toReal(), scrolled);
    }

    // HeroCarousel.swift:380-387, :238-244: the carousel advances on its own
    // while it is on screen, and stops while the remote rests on it or motion
    // is reduced. A pointer over it does not stop it.
    void theCarouselAdvancesByItselfUntilTheRemoteOrReducedMotionHoldsIt()
    {
        Shell shell;
        writeThreeMoviesWithArtwork(shell);
        QVERIFY(open(shell, [](const Seed &) {}, true, false));
        HomeRowsModel *rows = shell.controller->homeRows();
        QTRY_COMPARE(rows->hero()->count(), 3);
        shell.controller->settings()->setReduceMotion(false);
        QCOMPARE(rows->hero()->advanceIntervalMs(), 15'000);
        rows->hero()->setAdvanceIntervalForTest(120);

        // The shell opens with the remote on the sidebar, so nothing holds the
        // carousel.
        QTRY_VERIFY(rows->hero()->timerRunning());
        QTRY_VERIFY_WITH_TIMEOUT(rows->hero()->position() >= 1, 3000);
        // The card in front slides with it, a little behind the position
        // while the slide is still travelling.
        QTRY_VERIFY_WITH_TIMEOUT(
            [&] {
                QQuickItem *card = centerCard(shell);
                return card != nullptr && card->property("logical").toInt() >= 1;
            }(),
            3000);

        // The remote taking the hero stops it, and it stays where it was.
        QVERIFY(handToContent(shell));
        QVERIFY(!rows->hero()->timerRunning());
        const int held = rows->hero()->position();
        QTest::qWait(400);
        QCOMPARE(rows->hero()->position(), held);

        // A pointer over the front card leaves it held by the remote, and a
        // hover on its own does not stop a free-running one.
        QQuickItem *rowsItem = itemNamed(shell.window, "contentFocus");
        QVERIFY(rowsItem != nullptr);
        QTest::keyClick(shell.window, Qt::Key_Escape);
        QTRY_VERIFY(itemNamed(shell.window, "sidebar")->hasActiveFocus());
        QTRY_VERIFY(rows->hero()->timerRunning());
        QQuickItem *front = centerCard(shell);
        QVERIFY(front != nullptr);
        QTest::mouseMove(shell.window,
                         front->mapToScene(QPointF(front->width() / 2, front->height() / 3)).toPoint());
        QTest::qWait(100);
        QVERIFY(rows->hero()->timerRunning());

        shell.controller->settings()->setReduceMotion(true);
        QVERIFY(!rows->hero()->timerRunning());
        const int reduced = rows->hero()->position();
        QTest::qWait(400);
        QCOMPARE(rows->hero()->position(), reduced);
        shell.controller->settings()->setReduceMotion(false);
        QTRY_VERIFY(rows->hero()->timerRunning());

        // Leaving Home takes the carousel off screen and stops its timer.
        shell.controller->navigation()->openRoute(NavigationController::Route::Movies);
        QTRY_VERIFY(!rows->hero()->timerRunning());
    }

    // The slide ends at the same place with motion reduced as with it, only
    // without the travel (:63-65, :19).
    void theSlideSettlesOnTheSamePositionWithAndWithoutMotion()
    {
        Shell shell;
        writeThreeMoviesWithArtwork(shell);
        QVERIFY(open(shell, [](const Seed &) {}, true, false));
        HomeRowsModel *rows = shell.controller->homeRows();
        QTRY_COMPARE(rows->hero()->count(), 3);
        QVERIFY(handToContent(shell));
        QQuickItem *hero = itemNamed(shell.window, "homeHero");

        shell.controller->settings()->setReduceMotion(false);
        QCOMPARE(hero->property("slideDuration").toInt(), 500);
        press(shell, Qt::Key_Right);
        QTRY_COMPARE(hero->property("scrollPosition").toReal(), 1.0);
        shell.controller->settings()->setReduceMotion(true);
        QCOMPARE(hero->property("slideDuration").toInt(), 10);
        press(shell, Qt::Key_Right);
        QTRY_COMPARE(hero->property("scrollPosition").toReal(), 2.0);
        QCOMPARE(rows->hero()->currentIndex(), 2);
    }

    // The library with nothing in it has no hero; and the rows' focus there
    // falls back as before (HomeDetailView.swift:94, :1128-1134).
    void anEmptyLibraryHasNoHero()
    {
        Shell shell;
        QVERIFY(open(shell, [](const Seed &) {}, false, false));
        QTRY_VERIFY(!shell.controller->scanning());
        QCOMPARE(shell.controller->homeRows()->hero()->count(), 0);
        QVERIFY(!shell.controller->homeRows()->heroFocused());
        QQuickItem *hero = itemNamed(shell.window, "homeHero");
        QVERIFY(hero != nullptr);
        QVERIFY(!hero->isVisible());
    }

    // Kids profile: only the titles its policy allows reach the hero.
    void aKidsProfilesHeroHoldsOnlyWhatItsPolicyAllows()
    {
        Shell shell;
        QVERIFY(writeFile(shell.movies.path() + QStringLiteral("/Kids/Wonder (2017).mkv")));
        QVERIFY(writeFile(shell.movies.path() + QStringLiteral("/Drama/Heat (1995).mkv")));
        QVERIFY(writeFile(shell.movies.path() + QStringLiteral("/Drama/Casino (1995).mkv")));
        QVERIFY(open(shell, [](const Seed &) {}, true, false));
        HomeRowsModel *rows = shell.controller->homeRows();
        QTRY_COMPARE(rows->hero()->count(), 3);

        const auto kidsId = [&] {
            for (const Profile &profile : shell.controller->profiles()->profiles()) {
                if (profile.name == QStringLiteral("Kids")) {
                    return profile.id;
                }
            }
            return QString();
        }();
        QVERIFY(!kidsId.isEmpty());
        QVERIFY(shell.controller->chooseProfile(kidsId));
        QTRY_VERIFY(!shell.controller->profileExitInFlight());
        QTRY_COMPARE(rows->hero()->count(), 1);
        QCOMPARE(rows->hero()->spotlightAt(0).value(QStringLiteral("title")).toString(),
                 QStringLiteral("Wonder"));
        // One spotlight has nothing to move to: no arrows, no dots, no timer.
        QQuickItem *kidsHero = itemNamed(shell.window, "homeHero");
        QVERIFY(kidsHero != nullptr);
        QTRY_VERIFY(!firstNamed(kidsHero, QStringLiteral("heroDots"))->isVisible());
        QTRY_VERIFY(firstNamed(kidsHero, QStringLiteral("heroArrowLeft")) == nullptr);
        QVERIFY(!rows->hero()->timerRunning());
    }

    // A render on whatever scene graph the run has: the hero shows its
    // artwork, not the fallback. A grab of the front card's backdrop is the
    // colour of the title's fanart sidecar under the released washes.
    void theHeroPaintsTheFrontCardsBackdrop()
    {
        Shell shell;
        writeThreeMoviesWithArtwork(shell);
        QVERIFY(open(shell, [](const Seed &) {}, true, false));
        HomeRowsModel *rows = shell.controller->homeRows();
        QTRY_COMPARE(rows->hero()->count(), 3);
        shell.controller->settings()->setReduceMotion(true);
        QVERIFY(handToContent(shell));

        QQuickItem *card = nullptr;
        QTRY_VERIFY((card = centerCard(shell)) != nullptr);
        QQuickItem *backdrop = firstNamed(card, QStringLiteral("heroBackdrop"));
        QVERIFY(backdrop != nullptr);
        QTRY_COMPARE(backdrop->property("status").toInt(), 1); // Image.Ready
        QVERIFY(card->property("revealed").toBool());

        const QString title = rows->hero()->current().value(QStringLiteral("title")).toString();
        const QColor fanart = title == QStringLiteral("Arrival") ? QColor(200, 30, 30)
            : title == QStringLiteral("Coco")                    ? QColor(30, 200, 30)
                                                                 : QColor(30, 30, 200);

        // The capsule badge and the title text sit on it; a point in the open
        // top right of the card is only the backdrop and the washes.
        QQuickItem *titleText = firstNamed(card, QStringLiteral("heroTitle"));
        QVERIFY(titleText != nullptr);
        const render_probe::Capture capture = render_probe::captureWindowUntil(
            shell.window, {card, titleText}, [&](const render_probe::Capture &grabbed) {
                const QRect area = render_probe::imageRectForItem(grabbed, card);
                if (area.isEmpty()) {
                    return false;
                }
                const QPoint at(area.left() + area.width() * 7 / 10, area.top() + area.height() / 8);
                const QColor pixel = grabbed.image.pixelColor(at);
                // 0.18 black wash and a transparent-to-0.3 gradient at the top.
                return render_probe::withinTolerance(
                    pixel, render_probe::washed(fanart, 0.18 + 0.04), 28);
            });
        const QRect area = render_probe::imageRectForItem(capture, card);
        QVERIFY(!area.isEmpty());
        // The card is wide: it is the hero's 0.72 of the page, 390 tall.
        QVERIFY(area.width() > area.height() * 2);
        const QPoint at(area.left() + area.width() * 7 / 10, area.top() + area.height() / 8);
        const QColor pixel = capture.image.pixelColor(at);
        QVERIFY2(render_probe::withinTolerance(pixel, render_probe::washed(fanart, 0.22), 28),
                 qPrintable(QStringLiteral("%1 painted %2, fanart %3")
                                .arg(title, pixel.name(), fanart.name())));
        // The fallback wordmark is not showing over a ready backdrop.
        QVERIFY(card->property("revealed").toBool());
        // The title text is painted over the lower part of the card.
        const QRect lower = render_probe::imageRectForItem(capture, titleText);
        QVERIFY(!lower.isEmpty());
        const int bright = render_probe::countPixels(capture.image, lower, [](const QColor &colour) {
            return colour.red() > 200 && colour.green() > 200 && colour.blue() > 200;
        });
        QVERIFY2(bright > 40, qPrintable(QString::number(bright)));
    }

    // Set MARQUEE_HERO_GRAB to a file name to keep the frame this case sees,
    // for a look at the whole page on a real scene graph.
    void theWholePageGrabShowsTheHeroAboveTheRows()
    {
        Shell shell;
        writeThreeMoviesWithArtwork(shell);
        QVERIFY(open(shell, [](const Seed &) {}, true, false));
        HomeRowsModel *rows = shell.controller->homeRows();
        QTRY_COMPARE(rows->hero()->count(), 3);
        shell.controller->settings()->setReduceMotion(true);
        QVERIFY(handToContent(shell));
        QQuickItem *card = nullptr;
        QTRY_VERIFY((card = centerCard(shell)) != nullptr);
        QQuickItem *backdrop = firstNamed(card, QStringLiteral("heroBackdrop"));
        QVERIFY(backdrop != nullptr);
        QTRY_COMPARE(backdrop->property("status").toInt(), 1);
        QTRY_VERIFY(!shell.window->grabWindow().isNull());
        QTest::qWait(300);
        const QImage frame = shell.window->grabWindow();
        QVERIFY(!frame.isNull());
        const QString out = qEnvironmentVariable("MARQUEE_HERO_GRAB");
        if (!out.isEmpty()) {
            QVERIFY(frame.save(out));
        }
        // The hero is not blank: the backdrop's colour is on the page.
        QQuickItem *hero = itemNamed(shell.window, "homeHero");
        const QRect area = render_probe::imageRect(
            render_probe::captureWindow(shell.window, {hero}),
            hero->mapRectToScene(hero->boundingRect()));
        QVERIFY(!area.isEmpty());
        QVERIFY(render_probe::countPixels(frame, area, [](const QColor &colour) {
                    return colour != Theme_background();
                }) > area.width() * area.height() / 4);
    }

    // A title with no backdrop sidecar shows its content over the fallback at
    // once: the wordmark tile beneath it, never a spinner (:36-40, :253-258).
    void aTitleWithNoBackdropStillShowsItsCard()
    {
        Shell shell;
        QVERIFY(writeFile(shell.movies.path() + QStringLiteral("/Arrival (2016).mkv")));
        QVERIFY(open(shell, [](const Seed &) {}, true, false));
        HomeRowsModel *rows = shell.controller->homeRows();
        QTRY_COMPARE(rows->hero()->count(), 1);
        QQuickItem *card = nullptr;
        QTRY_VERIFY((card = centerCard(shell)) != nullptr);
        QVERIFY(card->property("revealed").toBool());
        QQuickItem *title = firstNamed(card, QStringLiteral("heroTitle"));
        QVERIFY(title != nullptr);
        QCOMPARE(title->property("text").toString(), QStringLiteral("Arrival"));
        QVERIFY(firstNamed(card, QStringLiteral("heroFallbackWordmark")) != nullptr);
    }
    // AppRouter.swift:40-46: Select on the sidebar's Play Something control
    // plays a pick at once, with no details page between.
    void theSidebarsPlaySomethingPlaysAnUnwatchedMovieAtOnce()
    {
        Shell shell;
        writeThreeMovies(shell);
        QVERIFY(open(
            shell,
            [](const Seed &seeded) {
                seeded.record(seeded.idOf(QStringLiteral("Arrival")), 0, true);
                seeded.record(seeded.idOf(QStringLiteral("Coco")), 0, true);
            },
            true, false));
        HomeRowsModel *rows = shell.controller->homeRows();
        QTRY_COMPARE(rowIds(rows).value(0), QStringLiteral("recently-watched"));
        QVERIFY(focusSidebarPlaySomething(shell));

        press(shell, Qt::Key_Return);

        // Dune is the only title left unwatched.
        QTRY_COMPARE(shell.controller->navigation()->route(), NavigationController::Route::Player);
        QCOMPARE(shell.controller->player()->mediaId(), shell.seeded.idOf(QStringLiteral("Dune")));
        QVERIFY(!shell.controller->hasError());
    }

    void thePlaySomethingCapsuleIsReachedWithTheRemoteAndPlaysWithEnter()
    {
        Shell shell;
        writeThreeMovies(shell);
        QVERIFY(open(
            shell,
            [](const Seed &seeded) {
                seeded.record(seeded.idOf(QStringLiteral("Arrival")), 0, true);
                seeded.record(seeded.idOf(QStringLiteral("Dune")), 0, true);
            },
            true, false));
        HomeRowsModel *rows = shell.controller->homeRows();
        QTRY_VERIFY(rowIds(rows).contains(QStringLiteral("play-something")));
        QVERIFY(handToContent(shell));
        QQuickItem *slot = itemNamed(shell.window, "homePlaySomethingSlot");
        QQuickItem *frame = itemNamed(shell.window, "homePlaySomethingFocusFrame");
        QVERIFY(slot != nullptr && frame != nullptr);
        QVERIFY(!slot->property("remoteFocused").toBool());
        QVERIFY(!frame->property("active").toBool());

        // Up from the hero (where Home opens) reaches the capsule, draws its
        // focus chrome, and leaves no ring on any card.
        QVERIFY(rows->heroFocused());
        press(shell, Qt::Key_Up);
        QVERIFY(rows->playSomethingFocused());
        QVERIFY(slot->property("remoteFocused").toBool());
        QVERIFY(frame->property("active").toBool());
        QQuickItem *firstRow = rowNamed(shell.window, rowIdAt(rows, 0));
        QVERIFY(firstRow != nullptr);
        QCOMPARE(firstRow->property("focusedIndex").toInt(), -1);
        // Left and Right on the capsule go nowhere, and Left does not hand the
        // remote to the sidebar from it.
        press(shell, Qt::Key_Right);
        QVERIFY(rows->playSomethingFocused());
        QCOMPARE(shell.controller->navigation()->route(), NavigationController::Route::Home);

        // Down leaves it, back on the hero it left, and Down again enters the
        // first row.
        press(shell, Qt::Key_Down);
        QVERIFY(!rows->playSomethingFocused());
        QVERIFY(rows->heroFocused());
        QVERIFY(!frame->property("active").toBool());
        press(shell, Qt::Key_Down);
        QCOMPARE(firstRow->property("focusedIndex").toInt(), 0);

        press(shell, Qt::Key_Up);
        press(shell, Qt::Key_Up);
        QVERIFY(rows->playSomethingFocused());
        press(shell, Qt::Key_Return);
        // Coco is the only title left unwatched; the press plays it and opens
        // no details page.
        QTRY_COMPARE(shell.controller->navigation()->route(), NavigationController::Route::Player);
        QCOMPARE(shell.controller->player()->mediaId(), shell.seeded.idOf(QStringLiteral("Coco")));
    }

    void aPointerTapOnTheCapsulePlaysATitleAndLeavesTheRemoteWhereItWas()
    {
        Shell shell;
        writeThreeMovies(shell);
        QVERIFY(open(shell, [](const Seed &) {}, true, false));
        HomeRowsModel *rows = shell.controller->homeRows();
        QTRY_VERIFY(rowIds(rows).contains(QStringLiteral("play-something")));
        rows->setPlaySomethingSaltForTest([] { return QStringLiteral("fixed"); });
        const QString expected = rows->playSomethingPick();
        QVERIFY(!expected.isEmpty());

        QQuickItem *capsule = itemNamed(shell.window, "homePlaySomething");
        QVERIFY(capsule != nullptr);
        const QPointF centre =
            capsule->mapToScene(QPointF(capsule->width() / 2, capsule->height() / 2));
        QTest::mouseClick(shell.window, Qt::LeftButton, Qt::NoModifier, centre.toPoint());

        QTRY_COMPARE(shell.controller->navigation()->route(), NavigationController::Route::Player);
        QCOMPARE(shell.controller->player()->mediaId(), expected);
        QVERIFY(!rows->playSomethingFocused());
    }

    void aKidsProfileIsPlayedOnlyWhatItsPolicyAllows()
    {
        Shell shell;
        QVERIFY(writeFile(shell.movies.path() + QStringLiteral("/Kids/Wonder (2017).mkv")));
        QVERIFY(writeFile(shell.movies.path() + QStringLiteral("/Drama/Heat (1995).mkv")));
        QVERIFY(writeFile(shell.movies.path() + QStringLiteral("/Drama/Casino (1995).mkv")));
        QVERIFY(open(shell, [](const Seed &) {}, true, false));
        HomeRowsModel *rows = shell.controller->homeRows();
        QTRY_VERIFY(rowIds(rows).contains(QStringLiteral("play-something")));

        const auto kidsId = [&] {
            for (const Profile &profile : shell.controller->profiles()->profiles()) {
                if (profile.name == QStringLiteral("Kids")) {
                    return profile.id;
                }
            }
            return QString();
        }();
        QVERIFY(!kidsId.isEmpty());
        QVERIFY(shell.controller->chooseProfile(kidsId));
        QTRY_VERIFY(!shell.controller->profileExitInFlight());
        QTRY_COMPARE(rows->rowCount(), 3);

        int press = 0;
        rows->setPlaySomethingSaltForTest([&press] { return QStringLiteral("k%1").arg(press++); });
        const QString wonder = shell.seeded.idOf(QStringLiteral("Wonder"));
        for (int index = 0; index < 40; ++index) {
            QCOMPARE(rows->playSomethingPick(), wonder);
        }
        shell.controller->playSomething();
        QTRY_COMPARE(shell.controller->navigation()->route(), NavigationController::Route::Player);
        QCOMPARE(shell.controller->player()->mediaId(), wonder);
    }

    // AppState.swift:236: no candidate, no action and no message.
    void playSomethingWithNothingToPlayDoesNothing()
    {
        Shell shell;
        QVERIFY(writeFile(shell.movies.path() + QStringLiteral("/Arrival (2016).mkv")));
        QVERIFY(open(
            shell,
            [](const Seed &seeded) {
                seeded.record(seeded.idOf(QStringLiteral("Arrival")), 0, true);
            },
            true, false));
        HomeRowsModel *rows = shell.controller->homeRows();
        QTRY_VERIFY(!rowIds(rows).contains(QStringLiteral("play-something")));
        QVERIFY(focusSidebarPlaySomething(shell));

        press(shell, Qt::Key_Return);
        QTest::qWait(100);

        QCOMPARE(shell.controller->navigation()->route(), NavigationController::Route::Home);
        QVERIFY(!shell.controller->hasError());
        QVERIFY(shell.controller->player()->mediaId().isEmpty());

        // The capsule is still on screen and still takes the remote.
        QVERIFY(handToContent(shell));
        press(shell, Qt::Key_Up);
        QVERIFY(rows->playSomethingFocused());
        press(shell, Qt::Key_Return);
        QTest::qWait(100);
        QCOMPARE(shell.controller->navigation()->route(), NavigationController::Route::Home);
        QVERIFY(!shell.controller->hasError());
    }

    // The catalog keeps the rows of a root that is offline or a file that is
    // gone, so the first pick may be one the player cannot open.
    void anUnplayableFirstPickIsSkippedForTheNextPlayableOne()
    {
        Shell shell;
        writeThreeMovies(shell);
        QVERIFY(open(shell, [](const Seed &) {}, true, false));
        HomeRowsModel *rows = shell.controller->homeRows();
        QTRY_VERIFY(rowIds(rows).contains(QStringLiteral("play-something")));
        QTRY_VERIFY(!shell.controller->scanning());
        rows->setPlaySomethingSaltForTest([] { return QStringLiteral("fixed"); });
        const QStringList order = rows->playSomethingCandidates();
        QCOMPARE(order.size(), 3);

        const QString first = shell.controller->library()->itemForId(order.at(0))->absolutePath;
        QVERIFY(QFile::remove(first));

        shell.controller->playSomething();

        QTRY_COMPARE(shell.controller->navigation()->route(), NavigationController::Route::Player);
        QCOMPARE(shell.controller->player()->mediaId(), order.at(1));
        QVERIFY(!shell.controller->hasError());
    }

    void withNoPlayableTitlePlaySomethingDoesNothingAndShowsNoError()
    {
        Shell shell;
        writeThreeMovies(shell);
        QVERIFY(open(shell, [](const Seed &) {}, true, false));
        HomeRowsModel *rows = shell.controller->homeRows();
        QTRY_VERIFY(rowIds(rows).contains(QStringLiteral("play-something")));
        QTRY_VERIFY(!shell.controller->scanning());
        for (const QString &id : rows->playSomethingCandidates()) {
            QVERIFY(QFile::remove(shell.controller->library()->itemForId(id)->absolutePath));
        }

        shell.controller->playSomething();
        QTest::qWait(100);

        QCOMPARE(shell.controller->navigation()->route(), NavigationController::Route::Home);
        QVERIFY(!shell.controller->hasError());
        QVERIFY(shell.controller->player()->mediaId().isEmpty());
    }

    // A stat on an offline network root can block for seconds, so only the
    // first five candidates are tried.
    void onlyTheFirstFewCandidatesAreTriedForAReadableFile()
    {
        Shell shell;
        for (int index = 0; index < 7; ++index) {
            QVERIFY(writeFile(shell.movies.path()
                              + QStringLiteral("/Film %1 (%2).mkv").arg(index).arg(2000 + index)));
        }
        QVERIFY(open(shell, [](const Seed &) {}, true, false));
        HomeRowsModel *rows = shell.controller->homeRows();
        QTRY_VERIFY(rowIds(rows).contains(QStringLiteral("play-something")));
        QTRY_VERIFY(!shell.controller->scanning());
        rows->setPlaySomethingSaltForTest([] { return QStringLiteral("fixed"); });
        const QStringList order = rows->playSomethingCandidates();
        QCOMPARE(order.size(), 7);
        for (int index = 0; index < 5; ++index) {
            QVERIFY(QFile::remove(shell.controller->library()->itemForId(order.at(index))->absolutePath));
        }

        shell.controller->playSomething();
        QTest::qWait(100);

        QCOMPARE(shell.controller->navigation()->route(), NavigationController::Route::Home);
        QVERIFY(!shell.controller->hasError());
    }

    // A stat on an unreachable network mount can hang the interface for
    // minutes, so a title of a root the last refresh found unavailable is
    // never stat'd, and a root that returns is tried again.
    void aTitleOfAnUnavailableRootIsSkippedWithoutAStat()
    {
        Shell shell;
        QTemporaryDir otherMovies;
        QVERIFY(otherMovies.isValid());
        writeThreeMovies(shell);
        QVERIFY(writeFile(otherMovies.path() + QStringLiteral("/Heat (1995).mkv")));
        QVERIFY(writeFile(otherMovies.path() + QStringLiteral("/Alien (1979).mkv")));
        QVERIFY(writeFile(otherMovies.path() + QStringLiteral("/Brazil (1985).mkv")));
        QVERIFY(open(shell, [](const Seed &) {}, true, false));
        shell.controller->setTemporaryLibraryRoot(otherMovies.path());
        shell.controller->requestCatalogRefresh();
        HomeRowsModel *rows = shell.controller->homeRows();
        QTRY_COMPARE(rows->playSomethingCandidates().size(), 6);
        QTRY_VERIFY(!shell.controller->scanning());
        rows->setPlaySomethingSaltForTest([] { return QStringLiteral("fixed"); });
        const QStringList order = rows->playSomethingCandidates();
        QCOMPARE(order.size(), 6);

        // Take away the root the first pick is on.
        const MediaItem firstPick = *shell.controller->library()->itemForId(order.at(0));
        const bool firstIsOther = firstPick.absolutePath.startsWith(otherMovies.path());
        const QString awayRoot = firstIsOther ? otherMovies.path() : shell.movies.path();
        const QString awayRenamed = awayRoot + QStringLiteral(".away");
        QVERIFY(QDir().rename(awayRoot, awayRenamed));
        const auto restore = qScopeGuard([&] { QDir().rename(awayRenamed, awayRoot); });
        shell.controller->requestCatalogRefresh();
        QTRY_VERIFY(shell.controller->hasError());
        QTRY_VERIFY(!shell.controller->scanning());
        shell.controller->dismissError();
        QCOMPARE(rows->playSomethingCandidates(), order);

        QStringList statted;
        shell.controller->setPlayableFileCheckForTest([&statted](const QString &path) {
            statted.push_back(path);
            return QFileInfo(path).isFile();
        });
        shell.controller->playSomething();

        QTRY_COMPARE(shell.controller->navigation()->route(), NavigationController::Route::Player);
        QVERIFY(!statted.isEmpty());
        for (const QString &path : std::as_const(statted)) {
            QVERIFY2(!path.startsWith(awayRoot), qPrintable(path));
        }
        const MediaItem played = *shell.controller->library()->itemForId(
            shell.controller->player()->mediaId());
        QVERIFY(!played.absolutePath.startsWith(awayRoot));
        QVERIFY(!shell.controller->hasError());

        // The root coming back clears the set: its first pick plays again.
        shell.controller->navigation()->goHome();
        QVERIFY(QDir().rename(awayRenamed, awayRoot));
        shell.controller->requestCatalogRefresh();
        QTRY_VERIFY(!shell.controller->scanning());
        QTRY_VERIFY(([&] {
            shell.controller->playSomething();
            return shell.controller->player()->mediaId() == order.at(0);
        })());
    }

    void thePlaySomethingRowOffersTheTitlesThePressCanPick()
    {
        Shell shell;
        writeThreeMovies(shell);
        QVERIFY(open(
            shell,
            [](const Seed &seeded) {
                seeded.record(seeded.idOf(QStringLiteral("Coco")), 0, true);
            },
            true, false));
        HomeRowsModel *rows = shell.controller->homeRows();
        QTRY_COMPARE(rowIds(rows), (QStringList{QStringLiteral("recently-watched"),
                                                QStringLiteral("play-something"),
                                                QStringLiteral("recently-added"),
                                                QStringLiteral("decade-2010s"),
                                                QStringLiteral("all-movies")}));
        QQuickItem *row = nullptr;
        QTRY_VERIFY((row = rowNamed(shell.window, QStringLiteral("play-something"))) != nullptr);
        QCOMPARE(row->findChild<QQuickItem *>(QStringLiteral("movieRowTitle"))
                     ->property("text")
                     .toString(),
                 QStringLiteral("Play Something"));
        QCOMPARE(row->findChild<QQuickItem *>(QStringLiteral("movieRowCount"))
                     ->property("text")
                     .toString(),
                 QStringLiteral("2 titles"));
    }

    void aRowListsTheOraclesTitlesInOrder()
    {
        Shell shell;
        QVERIFY(writeFile(shell.movies.path() + QStringLiteral("/Arrival (2016).mkv")));
        QVERIFY(writeFile(shell.movies.path() + QStringLiteral("/Coco (2017).mkv")));
        QVERIFY(writeFile(shell.movies.path() + QStringLiteral("/Heat (1995).mkv")));
        QVERIFY(open(
            shell,
            [](const Seed &seeded) {
                seeded.record(seeded.idOf(QStringLiteral("Heat")), 600'000, false);
            },
            true, false));
        QTRY_COMPARE(shell.controller->homeRows()->rowCount(), 5);

        QQuickItem *continueRow = nullptr;
        QTRY_VERIFY((continueRow = rowNamed(shell.window, QStringLiteral("continue-watching")))
                    != nullptr);
        auto *title = continueRow->findChild<QQuickItem *>(QStringLiteral("movieRowTitle"));
        QVERIFY(title != nullptr);
        QCOMPARE(title->property("text").toString(), QStringLiteral("Continue Watching"));
        for (const auto &expected : {std::pair{QStringLiteral("play-something"),
                                               QStringLiteral("Play Something")},
                                     std::pair{QStringLiteral("recently-added"),
                                               QStringLiteral("Recently Added")},
                                     std::pair{QStringLiteral("decade-2010s"),
                                               QStringLiteral("The 2010s")},
                                     std::pair{QStringLiteral("all-movies"),
                                               QStringLiteral("All Movies")}}) {
            QQuickItem *row = rowNamed(shell.window, expected.first);
            QVERIFY2(row != nullptr, qPrintable(expected.first));
            QCOMPARE(row->findChild<QQuickItem *>(QStringLiteral("movieRowTitle"))
                         ->property("text")
                         .toString(),
                     expected.second);
        }
    }

    void onHomeAtMostEightCardsAreDrawnButTheHeaderCountsTheWholeRow()
    {
        Shell shell;
        for (int index = 0; index < 11; ++index) {
            QVERIFY(writeFile(shell.movies.path()
                              + QStringLiteral("/Film %1 (%2).mkv")
                                    .arg(index, 2, 10, QLatin1Char('0'))
                                    .arg(2010 + index % 3)));
        }
        QVERIFY(open(shell, [](const Seed &) {}, true, false));
        QQuickItem *all = nullptr;
        QTRY_VERIFY((all = rowNamed(shell.window, QStringLiteral("all-movies"))) != nullptr);
        auto *list = all->findChild<QQuickItem *>(QStringLiteral("movieRow"));
        QVERIFY(list != nullptr);
        QTRY_COMPARE(list->property("count").toInt(), 8);
        QCOMPARE(all->findChild<QQuickItem *>(QStringLiteral("movieRowCount"))
                     ->property("text")
                     .toString(),
                 QStringLiteral("11 titles"));
        // The remote cannot walk past the eighth card either.
        QVERIFY(handToContent(shell));
        QQuickItem *content = itemNamed(shell.window, "contentFocus");
        QVERIFY(content != nullptr);
        const int lastRow = shell.controller->homeRows()->rowCount() - 1;
        shell.controller->homeRows()->focusCard(lastRow, 0);
        for (int step = 0; step < 12; ++step) {
            press(shell, Qt::Key_Right);
        }
        QCOMPARE(shell.controller->homeRows()->focus()->column(), 7);
    }

    void theRemoteWalksTheRowsWithUpDownLeftRightAndEnterOpensDetails()
    {
        Shell shell;
        QVERIFY(writeFile(shell.movies.path() + QStringLiteral("/Arrival (2016).mkv")));
        QVERIFY(writeFile(shell.movies.path() + QStringLiteral("/Coco (2017).mkv")));
        QVERIFY(writeFile(shell.movies.path() + QStringLiteral("/Dune (2021).mkv")));
        QVERIFY(open(
            shell,
            [](const Seed &seeded) {
                seeded.record(seeded.idOf(QStringLiteral("Arrival")), 600'000, false);
            },
            true, false));
        HomeRowsModel *rows = shell.controller->homeRows();
        QTRY_COMPARE(rowIds(rows).value(0), QStringLiteral("continue-watching"));
        QVERIFY(handToContent(shell));
        FocusNavigator *focus = rows->focus();
        QVERIFY(rows->heroFocused());
        QVERIFY(enterRows(shell));
        QCOMPARE(focus->row(), 0);
        QCOMPARE(focus->column(), 0);

        // Up at the top reaches the hero, and Up again the Play Something
        // capsule above it, moving no card; Down returns through the hero to
        // the card it left.
        press(shell, Qt::Key_Up);
        QVERIFY(rows->heroFocused());
        press(shell, Qt::Key_Up);
        QVERIFY(rows->playSomethingFocused());
        QCOMPARE(focus->row(), 0);
        press(shell, Qt::Key_Down);
        QVERIFY(rows->heroFocused());
        press(shell, Qt::Key_Down);
        QVERIFY(!rows->playSomethingFocused());
        QVERIFY(!rows->heroFocused());
        QCOMPARE(focus->row(), 0);

        press(shell, Qt::Key_Down);
        QCOMPARE(focus->row(), 1);
        QCOMPARE(rowIdAt(rows, 1), QStringLiteral("play-something"));
        press(shell, Qt::Key_Right);
        QCOMPARE(focus->column(), 1);
        press(shell, Qt::Key_Left);
        QCOMPARE(focus->column(), 0);
        press(shell, Qt::Key_Right);
        const QVariantMap card = rows->cardAt(focus->row(), focus->column());
        QVERIFY(!card.isEmpty());

        // The focused card shows the remote on exactly one row.
        QQuickItem *focusedRow = rowNamed(shell.window, QStringLiteral("play-something"));
        QQuickItem *otherRow = rowNamed(shell.window, QStringLiteral("continue-watching"));
        QVERIFY(focusedRow != nullptr && otherRow != nullptr);
        QCOMPARE(focusedRow->property("focusedIndex").toInt(), 1);
        QCOMPARE(otherRow->property("focusedIndex").toInt(), -1);

        press(shell, Qt::Key_Return);
        QTRY_COMPARE(shell.controller->navigation()->route(), NavigationController::Route::Details);
        QCOMPARE(shell.controller->navigation()->selectedMediaId(),
                 card.value(QStringLiteral("mediaId")).toString());
    }

    void leftAtTheFirstCardReturnsTheRemoteToTheSidebar()
    {
        Shell shell;
        QVERIFY(writeFile(shell.movies.path() + QStringLiteral("/Arrival (2016).mkv")));
        QVERIFY(open(shell, [](const Seed &) {}, true, false));
        QTRY_COMPARE(shell.controller->homeRows()->rowCount(), 3);
        QVERIFY(handToContent(shell));
        auto *sidebar = itemNamed(shell.window, "sidebar");
        QVERIFY(sidebar != nullptr);
        // Left on the hero wraps it, as the released hero does; with one
        // spotlight there is nothing to wrap to, and it is not the sidebar's.
        press(shell, Qt::Key_Left);
        QVERIFY(shell.controller->homeRows()->heroFocused());
        QVERIFY(!sidebar->hasActiveFocus());
        QVERIFY(enterRows(shell));
        press(shell, Qt::Key_Left);
        QTRY_VERIFY(sidebar->hasActiveFocus());
    }

    void anEpisodeCardOpensItsShowAtThatEpisode()
    {
        Shell shell;
        for (int episode = 1; episode <= 3; ++episode) {
            QVERIFY(writeFile(shell.shows.path()
                              + QStringLiteral("/Bluey (2018)/Season 1/Bluey - S01E0%1 - Title.mkv")
                                    .arg(episode)));
        }
        QVERIFY(open(
            shell,
            [](const Seed &seeded) {
                seeded.record(seeded.idOf(QStringLiteral("Bluey"), 1), 0, true);
            },
            false, true));
        HomeRowsModel *rows = shell.controller->homeRows();
        QTRY_COMPARE(rowIdAt(rows, 0), QStringLiteral("continue-watching"));
        const QVariantMap card = rows->cardAt(0, 0);
        QCOMPARE(card.value(QStringLiteral("mediaId")).toString(),
                 shell.seeded.idOf(QStringLiteral("Bluey"), 2));
        QCOMPARE(card.value(QStringLiteral("showName")).toString(), QStringLiteral("Bluey"));

        QVERIFY(handToContent(shell));
        QVERIFY(enterRows(shell));
        press(shell, Qt::Key_Return);
        QTRY_COMPARE(shell.controller->navigation()->route(),
                     NavigationController::Route::ShowDetail);
        QCOMPARE(shell.controller->navigation()->selectedMediaId(), QStringLiteral("Bluey"));

        QQuickItem *screen = nullptr;
        QTRY_VERIFY((screen = itemNamed(shell.window, "showDetailScroll")) != nullptr);
        QQuickItem *page = screen->parentItem();
        QVERIFY(page != nullptr);
        // The remote starts on the episode the card stood for.
        QTRY_COMPARE(page->property("focusNode").toString(), QStringLiteral("episode"));
        QCOMPARE(page->property("focusedEpisode").toInt(), 1);
        QCOMPARE(page->property("selectedSeason").toInt(), 1);
    }

    void aRecentlyAddedShowCardOpensTheShowWithoutPickingAnEpisode()
    {
        Shell shell;
        for (int episode = 1; episode <= 2; ++episode) {
            QVERIFY(writeFile(shell.shows.path()
                              + QStringLiteral("/Bluey (2018)/Season 1/Bluey - S01E0%1 - Title.mkv")
                                    .arg(episode)));
        }
        QVERIFY(open(shell, [](const Seed &) {}, false, true));
        HomeRowsModel *rows = shell.controller->homeRows();
        QTRY_COMPARE(rowIds(rows), QStringList{QStringLiteral("recently-added")});
        QVERIFY(handToContent(shell));
        QVERIFY(enterRows(shell));
        press(shell, Qt::Key_Return);
        QTRY_COMPARE(shell.controller->navigation()->route(),
                     NavigationController::Route::ShowDetail);
        QQuickItem *screen = nullptr;
        QTRY_VERIFY((screen = itemNamed(shell.window, "showDetailScroll")) != nullptr);
        QCOMPARE(screen->parentItem()->property("focusNode").toString(), QStringLiteral("start"));
    }

    void aTappedCardOpensThatCardRatherThanTheFocusedOne()
    {
        Shell shell;
        QVERIFY(writeFile(shell.movies.path() + QStringLiteral("/Arrival (2016).mkv")));
        QVERIFY(writeFile(shell.movies.path() + QStringLiteral("/Coco (2017).mkv")));
        QVERIFY(writeFile(shell.movies.path() + QStringLiteral("/Dune (2021).mkv")));
        QVERIFY(open(shell, [](const Seed &) {}, true, false));
        // The hero fills the top of the page, so the first row is brought into
        // view the way the remote would: by resting on it.
        shell.controller->homeRows()->focusCard(0, 0);
        QQuickItem *scroller = itemNamed(shell.window, "homeScroll");
        QVERIFY(scroller != nullptr);
        auto *glide = scroller->findChild<QObject *>(QStringLiteral("homeScrollSpring"));
        QVERIFY(glide != nullptr);
        QTRY_VERIFY(scroller->property("contentY").toReal() > 0);
        QTRY_VERIFY(!glide->property("running").toBool());
        QQuickItem *added = nullptr;
        QTRY_VERIFY((added = rowNamed(shell.window, QStringLiteral("play-something"))) != nullptr);
        auto *list = added->findChild<QQuickItem *>(QStringLiteral("movieRow"));
        QVERIFY(list != nullptr);
        QTRY_COMPARE(list->property("count").toInt(), 3);
        QQuickItem *card = nullptr;
        QTRY_VERIFY([&] {
            QMetaObject::invokeMethod(list, "itemAtIndex", Q_RETURN_ARG(QQuickItem *, card),
                                      Q_ARG(int, 2));
            return card != nullptr;
        }());
        const QVariantMap expected = shell.controller->homeRows()->cardAt(0, 2);
        QVERIFY(!expected.isEmpty());
        // The remote rests on the first card; the tap names another.
        QCOMPARE(shell.controller->homeRows()->focus()->column(), 0);

        const QPointF centre = card->mapToScene(QPointF(card->width() / 2, card->height() / 2));
        QVERIFY(shell.window->geometry().contains(centre.toPoint()));
        QTest::mouseClick(shell.window, Qt::LeftButton, Qt::NoModifier, centre.toPoint());
        QTRY_COMPARE(shell.controller->navigation()->route(), NavigationController::Route::Details);
        QCOMPARE(shell.controller->navigation()->selectedMediaId(),
                 expected.value(QStringLiteral("mediaId")).toString());
    }

    void anEpisodesOnlyLibraryShowsItsTvRowsNotAnEmptyMovieGrid()
    {
        Shell shell;
        QVERIFY(writeFile(shell.shows.path()
                          + QStringLiteral("/Bluey (2018)/Season 1/Bluey - S01E01 - Title.mkv")));
        QVERIFY(writeFile(shell.shows.path()
                          + QStringLiteral("/The Wire (2002)/Season 1/The Wire - S01E01 - T.mkv")));
        QVERIFY(open(shell, [](const Seed &) {}, false, true));
        QTRY_COMPARE(shell.controller->homeRows()->rowCount(), 1);

        QQuickItem *added = nullptr;
        QTRY_VERIFY((added = rowNamed(shell.window, QStringLiteral("recently-added"))) != nullptr);
        auto *list = added->findChild<QQuickItem *>(QStringLiteral("movieRow"));
        QVERIFY(list != nullptr);
        QTRY_COMPARE(list->property("count").toInt(), 2);
        QVERIFY(itemNamed(shell.window, "homeRowsViewport")->isVisible());
        QVERIFY(!itemNamed(shell.window, "libraryEmptyState")->isVisible());
        QVERIFY(!itemNamed(shell.window, "libraryScanState")->isVisible());
        QVERIFY(itemNamed(shell.window, "libraryGrid") == nullptr);
    }

    void anEmptyLibraryShowsTheEmptyStateAndNoRows()
    {
        Shell shell;
        QVERIFY(open(shell, [](const Seed &) {}, false, false));
        QTRY_VERIFY(!shell.controller->scanning());
        QTRY_VERIFY(itemNamed(shell.window, "libraryEmptyState")->isVisible());
        QCOMPARE(shell.controller->homeRows()->rowCount(), 0);
        QVERIFY(!itemNamed(shell.window, "homeRowsViewport")->isVisible());
    }

    void movingBetweenRowsGlidesWithTheTokenAndHonoursReduceMotion()
    {
        Shell shell;
        // Enough decades to push the last row below the fold.
        for (int decade = 0; decade < 8; ++decade) {
            for (int film = 0; film < 2; ++film) {
                QVERIFY(writeFile(shell.movies.path()
                                  + QStringLiteral("/Film %1 %2 (%3).mkv")
                                        .arg(decade)
                                        .arg(film)
                                        .arg(1950 + decade * 10 + film)));
            }
        }
        QVERIFY(open(shell, [](const Seed &) {}, true, false));
        HomeRowsModel *rows = shell.controller->homeRows();
        QTRY_VERIFY(rows->rowCount() >= 9);
        shell.controller->settings()->setReduceMotion(false);
        QVERIFY(handToContent(shell));
        QQuickItem *scroll = itemNamed(shell.window, "homeScroll");
        QVERIFY(scroll != nullptr);
        auto *springObject = scroll->findChild<QObject *>(QStringLiteral("homeScrollSpring"));
        QVERIFY(springObject != nullptr);
        QCOMPARE(springObject->property("duration").toInt(), 250);

        // The page rests at its origin on the hero; one Down more than there
        // are rows between enters the first row and walks to the last.
        QVERIFY(rows->heroFocused());
        const qreal start = scroll->property("contentY").toReal();
        for (int step = 0; step < rows->rowCount(); ++step) {
            press(shell, Qt::Key_Down);
        }
        QCOMPARE(rows->focus()->row(), rows->rowCount() - 1);
        // The glide ran: the page is on its way to, or at, the focused row.
        QTRY_VERIFY(scroll->property("contentY").toReal() > start);
        QTRY_VERIFY(!springObject->property("running").toBool());
        const qreal settled = scroll->property("contentY").toReal();

        // The same focus under Reduce Motion lands at the same place with no
        // spring running.
        shell.controller->settings()->setReduceMotion(true);
        for (int step = 0; step < rows->rowCount(); ++step) {
            press(shell, Qt::Key_Up);
        }
        // Back on the hero the page returns to its origin (HomeDetailView
        // .swift:761-768), whatever offset a row left it at.
        QVERIFY(rows->heroFocused());
        QTRY_COMPARE(qRound(scroll->property("contentY").toReal()), qRound(start));
        QVERIFY(!springObject->property("running").toBool());
        for (int step = 0; step < rows->rowCount(); ++step) {
            press(shell, Qt::Key_Down);
        }
        QVERIFY(!springObject->property("running").toBool());
        QCOMPARE(qRound(scroll->property("contentY").toReal()), qRound(settled));
    }

    void switchingToKidsRecomposesEveryRowFromWhatTheProfileMaySee()
    {
        Shell shell;
        QVERIFY(writeFile(shell.movies.path() + QStringLiteral("/Kids/Wonder (2017).mkv")));
        QVERIFY(writeFile(shell.movies.path() + QStringLiteral("/Family/WALL-E (2008).mkv")));
        QVERIFY(writeFile(shell.movies.path() + QStringLiteral("/Drama/Heat (1995).mkv")));
        QVERIFY(writeFile(shell.movies.path() + QStringLiteral("/Drama/Casino (1995).mkv")));
        QVERIFY(writeFile(shell.shows.path()
                          + QStringLiteral("/The Wire (2002)/Season 1/The Wire - S01E01 - T.mkv")));
        QVERIFY(writeFile(shell.shows.path()
                          + QStringLiteral("/The Wire (2002)/Season 1/The Wire - S01E02 - T.mkv")));
        QVERIFY(open(
            shell,
            [](const Seed &seeded) {
                seeded.record(seeded.idOf(QStringLiteral("Heat")), 600'000, false);
                seeded.record(seeded.idOf(QStringLiteral("Wonder")), 0, true);
                seeded.record(seeded.idOf(QStringLiteral("The Wire"), 1), 0, true);
            },
            true, true));
        HomeRowsModel *rows = shell.controller->homeRows();
        QTRY_VERIFY(rowIds(rows).contains(QStringLiteral("continue-watching")));
        const auto titlesOf = [&] {
            QStringList titles;
            for (int row = 0; row < rows->rowCount(); ++row) {
                const QObject *items =
                    rows->data(rows->index(row), HomeRowsModel::ItemsRole).value<QObject *>();
                const auto *cards = qobject_cast<const QAbstractItemModel *>(items);
                for (int column = 0; cards != nullptr && column < cards->rowCount(); ++column) {
                    titles.push_back(
                        cards->data(cards->index(column, 0), HomeCardModel::TitleRole).toString());
                }
            }
            titles.removeDuplicates();
            titles.sort();
            return titles;
        };
        const QStringList adult = titlesOf();
        QVERIFY(adult.contains(QStringLiteral("Heat")));
        QVERIFY(adult.contains(QStringLiteral("The Wire")));

        const auto kidsId = [&] {
            for (const Profile &profile : shell.controller->profiles()->profiles()) {
                if (profile.name == QStringLiteral("Kids")) {
                    return profile.id;
                }
            }
            return QString();
        }();
        QVERIFY(!kidsId.isEmpty());
        QVERIFY(shell.controller->chooseProfile(kidsId));
        QTRY_VERIFY(!shell.controller->profileExitInFlight());

        // Every row obeys the policy: nothing the Kids profile may not see
        // appears in any of them, and the Main profile's progress is gone.
        QTRY_VERIFY(!titlesOf().contains(QStringLiteral("Heat")));
        const QStringList kids = titlesOf();
        QVERIFY(!kids.contains(QStringLiteral("Casino")));
        QVERIFY(!kids.contains(QStringLiteral("The Wire")));
        QVERIFY(kids.contains(QStringLiteral("WALL-E")));
        QVERIFY(kids.contains(QStringLiteral("Wonder")));
        QVERIFY(!rowIds(rows).contains(QStringLiteral("continue-watching")));
        // Wonder was watched by Main only, so it is new to Kids.
        QVERIFY(!rowIds(rows).contains(QStringLiteral("recently-watched")));
    }

    void aViewingRecordedInThePlayerMovesTheShowIntoContinueWatching()
    {
        Shell shell;
        for (int episode = 1; episode <= 2; ++episode) {
            QVERIFY(writeFile(shell.shows.path()
                              + QStringLiteral("/Bluey (2018)/Season 1/Bluey - S01E0%1 - Title.mkv")
                                    .arg(episode)));
        }
        QVERIFY(open(shell, [](const Seed &) {}, false, true));
        HomeRowsModel *rows = shell.controller->homeRows();
        QTRY_COMPARE(rowIds(rows), QStringList{QStringLiteral("recently-added")});

        const std::optional<MediaItem> first =
            shell.controller->shows()->episodeForId(shell.seeded.idOf(QStringLiteral("Bluey"), 1));
        QVERIFY(first.has_value());
        shell.controller->player()->prepare(first->absolutePath, first->title, first->id);
        shell.controller->player()->reportPlayback(1800.0, 3600.0, false);
        shell.controller->player()->reportPlayback(1800.0, 3600.0, true);

        // The episode is part-way, so it is the card, and the card is the
        // in-progress episode rather than the one after it.
        QTRY_COMPARE(rowIdAt(rows, 0), QStringLiteral("continue-watching"));
        QCOMPARE(rows->cardAt(0, 0).value(QStringLiteral("mediaId")).toString(), first->id);
    }
};

int main(int argc, char *argv[])
{
    QGuiApplication app(argc, argv);
    HomeScreenTest test;
    return QTest::qExec(&test, argc, argv);
}

#include "tst_home_screen.moc"
