#include <QtTest>

#include <QDir>
#include <QFile>
#include <QGuiApplication>
#include <QImage>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickItem>
#include <QQuickWindow>
#include <QTemporaryDir>
#include <QUrl>

#include "app/AppPaths.hpp"
#include "app/ApplicationController.hpp"
#include "models/ShowsModel.hpp"
#include "navigation/NavigationController.hpp"
#include "playback/PlayerController.hpp"
#include "settings/SettingsStore.hpp"

namespace
{
[[nodiscard]] bool writeFile(const QString &path, const QByteArray &bytes)
{
    QDir().mkpath(QFileInfo(path).absolutePath());
    QFile file(path);
    return file.open(QIODevice::WriteOnly) && file.write(bytes) == bytes.size();
}

[[nodiscard]] bool writePoster(const QString &path, const QColor &color)
{
    QImage poster(40, 60, QImage::Format_ARGB32);
    poster.fill(color);
    QDir().mkpath(QFileInfo(path).absolutePath());
    return poster.save(path, "PNG");
}

// Three shows: one with two seasons and artwork at every scope, and two
// single-season shows sharing offline genres, so More Like This has a row.
[[nodiscard]] bool writeTvFixture(const QString &root)
{
    const QString wire = root + QStringLiteral("/The Wire (2002)");
    const QString bluey = root + QStringLiteral("/Bluey (2018)");
    const QString arnold = root + QStringLiteral("/Hey Arnold (1996)");
    return writeFile(wire + QStringLiteral("/Season 1/The Wire - S01E01 - The Target.mkv"), "m")
        && writeFile(wire + QStringLiteral("/Season 1/The Wire - S01E02 - The Detail.mkv"), "m")
        && writeFile(wire + QStringLiteral("/Season 2/The Wire - S02E01 - Ebb Tide.mkv"), "m")
        && writePoster(wire + QStringLiteral("/poster.png"), QColor(40, 60, 90))
        && writePoster(wire + QStringLiteral("/fanart.png"), QColor(20, 30, 50))
        && writePoster(wire + QStringLiteral("/Season 2/folder.png"), QColor(60, 90, 40))
        && writeFile(bluey + QStringLiteral("/Season 1/Bluey - S01E01 - Magic Xylophone.mkv"), "m")
        && writeFile(bluey + QStringLiteral("/Season 1/Bluey - S01E02 - Hospital.mkv"), "m")
        && writePoster(bluey + QStringLiteral("/poster.png"), QColor(76, 138, 208))
        && writeFile(arnold + QStringLiteral("/Season 1/Hey Arnold - S01E01 - Downtown as Fruits.mkv"), "m")
        && writePoster(arnold + QStringLiteral("/poster.png"), QColor(90, 58, 122));
}

struct Shell
{
    QTemporaryDir runtimeRoot;
    QTemporaryDir library;
    std::unique_ptr<ApplicationController> controller;
    std::unique_ptr<QQmlApplicationEngine> engine;
    QQuickWindow *window = nullptr;
    QQuickItem *screen = nullptr;

    ~Shell()
    {
        engine.reset();
        controller.reset();
        AppPaths::clearRuntimeRoot();
    }
};

void press(Shell &shell, Qt::Key key)
{
    QTest::keyClick(shell.window, key);
    QCoreApplication::processEvents();
}

// Repeater delegates are not children of the window for findChild, so the
// repeaters are walked and their instantiated items matched by name.
[[nodiscard]] QQuickItem *repeaterItem(QQuickItem *repeater, const QString &objectName)
{
    if (repeater == nullptr) {
        return nullptr;
    }
    const int count = repeater->property("count").toInt();
    for (int index = 0; index < count; ++index) {
        QQuickItem *item = nullptr;
        if (!QMetaObject::invokeMethod(repeater, "itemAt", Q_RETURN_ARG(QQuickItem *, item),
                                       Q_ARG(int, index))) {
            return nullptr;
        }
        if (item != nullptr && item->objectName() == objectName) {
            return item;
        }
    }
    return nullptr;
}

[[nodiscard]] QQuickItem *find(const Shell &shell, const QString &objectName)
{
    if (auto *direct = shell.window->findChild<QQuickItem *>(objectName)) {
        return direct;
    }
    if (objectName.startsWith(QLatin1String("showRow_"))) {
        return repeaterItem(shell.window->findChild<QQuickItem *>(QStringLiteral("showRows")),
                            objectName);
    }
    if (objectName.startsWith(QLatin1String("showDetailEpisode_"))) {
        auto *list = shell.window->findChild<QQuickItem *>(QStringLiteral("showDetailEpisodes"));
        if (list == nullptr) {
            return nullptr;
        }
        for (QQuickItem *child : list->childItems()) {
            if (child->objectName() == objectName) {
                return child;
            }
        }
        return nullptr;
    }
    return nullptr;
}

// Saves a grab under $MARQUEE_TV_SHOTS when set, so a run doubles as the
// visual check; the assertions never depend on it.
void snapshot(Shell &shell, const char *name)
{
    const QString directory = qEnvironmentVariable("MARQUEE_TV_SHOTS");
    if (directory.isEmpty()) {
        return;
    }
    QTest::qWait(250);
    QDir().mkpath(directory);
    shell.window->grabWindow().save(directory + QLatin1Char('/') + QLatin1String(name)
                                    + QLatin1String(".png"));
}
}

class TestTvRoute : public QObject
{
    Q_OBJECT

    [[nodiscard]] bool openShows(Shell &shell)
    {
        AppPaths::setRuntimeRoot(shell.runtimeRoot.path());
        if (!writeTvFixture(shell.library.path())) {
            return false;
        }
        shell.controller = std::make_unique<ApplicationController>();
        shell.controller->setStartFullscreen(false);
        shell.controller->settings()->setTvShowsRoots({shell.library.path()});
        if (!QTest::qWaitFor([&] { return shell.controller->shows()->episodeCount() == 6; })) {
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
        shell.window->show();
        shell.window->requestActivate();
        if (!QTest::qWaitForWindowActive(shell.window)) {
            return false;
        }
        shell.controller->chooseProfile(
            shell.controller->profiles()->profileAt(0).value(QStringLiteral("id")).toString());
        if (!QTest::qWaitFor([&] { return !shell.controller->profileExitInFlight(); })) {
            return false;
        }
        shell.controller->navigation()->openRoute(NavigationController::Route::Shows);
        if (!QTest::qWaitFor([&] {
                shell.screen = find(shell, QStringLiteral("showsScroll"));
                return shell.screen != nullptr;
            })) {
            return false;
        }
        shell.screen = shell.screen->parentItem();
        press(shell, Qt::Key_Right);
        return QTest::qWaitFor([&] { return shell.screen->hasActiveFocus(); });
    }

    [[nodiscard]] bool openWire(Shell &shell)
    {
        if (!openShows(shell)) {
            return false;
        }
        shell.controller->navigation()->openShowDetail(QStringLiteral("The Wire"));
        QQuickItem *detail = nullptr;
        if (!QTest::qWaitFor([&] {
                detail = find(shell, QStringLiteral("showDetailScroll"));
                return detail != nullptr;
            })) {
            return false;
        }
        shell.screen = detail->parentItem();
        return QTest::qWaitFor([&] { return shell.screen->hasActiveFocus(); });
    }

private slots:
    void theGridListsEveryShowUnderItsGenreRowsAndAllShows()
    {
        Shell shell;
        QVERIFY(openShows(shell));

        auto *heading = find(shell, QStringLiteral("showsHeading"));
        QVERIFY(heading != nullptr);
        QCOMPARE(heading->property("text").toString(), QStringLiteral("TV Shows"));
        auto *count = find(shell, QStringLiteral("showsCount"));
        QVERIFY(count != nullptr);
        QCOMPARE(count->property("text").toString(), QStringLiteral("3 shows"));
        QVERIFY(find(shell, QStringLiteral("showRow_all-shows")) != nullptr);
        QVERIFY(find(shell, QStringLiteral("showRow_genre-Animation")) != nullptr);
        auto *empty = find(shell, QStringLiteral("showsEmptyState"));
        QVERIFY(empty != nullptr);
        QVERIFY(!empty->isVisible());
        snapshot(shell, "01-shows-grid");
    }

    void theEmptyStateNamesTheConfiguredRoot()
    {
        Shell shell;
        AppPaths::setRuntimeRoot(shell.runtimeRoot.path());
        shell.controller = std::make_unique<ApplicationController>();
        shell.controller->setStartFullscreen(false);
        shell.engine = std::make_unique<QQmlApplicationEngine>();
        shell.engine->rootContext()->setContextProperty(QStringLiteral("appController"),
                                                        shell.controller.get());
        shell.engine->loadFromModule(QStringLiteral("Marquee"), QStringLiteral("Main"));
        QCOMPARE(shell.engine->rootObjects().size(), 1);
        shell.window = qobject_cast<QQuickWindow *>(shell.engine->rootObjects().front());
        QVERIFY(shell.window != nullptr);
        shell.window->resize(1600, 900);
        shell.window->show();
        QVERIFY(QTest::qWaitForWindowExposed(shell.window));
        shell.controller->chooseProfile(
            shell.controller->profiles()->profileAt(0).value(QStringLiteral("id")).toString());
        QTRY_VERIFY(!shell.controller->profileExitInFlight());
        shell.controller->navigation()->openRoute(NavigationController::Route::Shows);
        QTRY_VERIFY(!shell.controller->scanning());

        QQuickItem *empty = nullptr;
        QTRY_VERIFY((empty = find(shell, QStringLiteral("showsEmptyState"))) != nullptr);
        QTRY_VERIFY(empty->isVisible());
        auto *detail = find(shell, QStringLiteral("showsEmptyDetail"));
        QVERIFY(detail != nullptr);
        QCOMPARE(detail->property("text").toString(), QStringLiteral("Scanning ~/TV Shows"));
        snapshot(shell, "00-shows-empty");
    }

    void selectOpensTheFocusedShowAndBackReturnsToTheGrid()
    {
        Shell shell;
        QVERIFY(openShows(shell));

        press(shell, Qt::Key_Return);
        QTRY_COMPARE(shell.controller->navigation()->route(), NavigationController::Route::ShowDetail);
        QCOMPARE(shell.controller->navigation()->selectedMediaId(), QStringLiteral("Bluey"));
        QQuickItem *title = nullptr;
        QTRY_VERIFY((title = find(shell, QStringLiteral("showDetailTitle"))) != nullptr);
        QCOMPARE(title->property("text").toString(), QStringLiteral("Bluey"));

        press(shell, Qt::Key_Escape);
        QTRY_COMPARE(shell.controller->navigation()->route(), NavigationController::Route::Shows);
        // One Back is one step: the grid keeps the focused card, and a second
        // pop must not have run underneath it.
        QTest::qWait(150);
        QCOMPARE(shell.controller->navigation()->route(), NavigationController::Route::Shows);
        QQuickItem *grid = nullptr;
        QTRY_VERIFY((grid = find(shell, QStringLiteral("showsScroll"))) != nullptr);
        QTRY_VERIFY(grid->parentItem()->hasActiveFocus());
        QCOMPARE(shell.controller->shows()->focus()->row(), 0);
        QCOMPARE(shell.controller->shows()->focus()->column(), 0);
    }

    void theDetailShowsTheHeroFactsSeasonsAndEpisodes()
    {
        Shell shell;
        QVERIFY(openWire(shell));

        auto *title = find(shell, QStringLiteral("showDetailTitle"));
        QVERIFY(title != nullptr);
        QCOMPARE(title->property("text").toString(), QStringLiteral("The Wire"));
        QVERIFY(find(shell, QStringLiteral("showDetailStart"))->isVisible());
        auto *cont = find(shell, QStringLiteral("showDetailContinue"));
        QVERIFY(cont != nullptr);
        // Nothing watched: up-next is the first episode, so Continue is hidden
        // (ShowDetailView.swift:768-772).
        QVERIFY(!cont->isVisible());
        QVERIFY(find(shell, QStringLiteral("showDetailSeasons"))->isVisible());
        QCOMPARE(shell.screen->property("selectedSeason").toInt(), 1);
        QVERIFY(find(shell, QStringLiteral("showDetailEpisode_0")) != nullptr);
        QVERIFY(find(shell, QStringLiteral("showDetailEpisode_1")) != nullptr);
        QVERIFY(find(shell, QStringLiteral("showDetailEpisode_2")) == nullptr);
        QVERIFY(find(shell, QStringLiteral("showDetailPosterPreview")) != nullptr);
        QTRY_VERIFY(find(shell, QStringLiteral("showDetailPosterPreview"))->isVisible());
        snapshot(shell, "02-show-detail");
    }

    void theRemoteWalksActionsSeasonsAndEpisodes()
    {
        Shell shell;
        QVERIFY(openWire(shell));
        QCOMPARE(shell.screen->property("focusNode").toString(), QStringLiteral("start"));
        // The Wire carries no offline genres and no franchise sibling, so its
        // related row is empty (BrowseSnapshotStore.swift:2225-2233).
        QCOMPARE(shell.screen->property("similarCount").toInt(), 0);

        press(shell, Qt::Key_Down);
        QCOMPARE(shell.screen->property("focusNode").toString(), QStringLiteral("seasons"));
        // The stepper changes the season in place.
        press(shell, Qt::Key_Right);
        QCOMPARE(shell.screen->property("selectedSeason").toInt(), 2);
        QTRY_VERIFY(find(shell, QStringLiteral("showDetailEpisode_0")) != nullptr);
        QVERIFY(find(shell, QStringLiteral("showDetailEpisode_1")) == nullptr);
        press(shell, Qt::Key_Right);
        QCOMPARE(shell.screen->property("selectedSeason").toInt(), 2);
        press(shell, Qt::Key_Left);
        QCOMPARE(shell.screen->property("selectedSeason").toInt(), 1);

        press(shell, Qt::Key_Down);
        QCOMPARE(shell.screen->property("focusNode").toString(), QStringLiteral("episode"));
        QCOMPARE(shell.screen->property("focusedEpisode").toInt(), 0);
        QTRY_VERIFY(find(shell, QStringLiteral("showDetailEpisode_0"))->property("focused").toBool());
        press(shell, Qt::Key_Down);
        QCOMPARE(shell.screen->property("focusedEpisode").toInt(), 1);
        snapshot(shell, "03-show-detail-episode-focus");

        // The list's end holds focus when nothing follows it.
        press(shell, Qt::Key_Down);
        QCOMPARE(shell.screen->property("focusNode").toString(), QStringLiteral("episode"));
        QCOMPARE(shell.screen->property("focusedEpisode").toInt(), 1);

        press(shell, Qt::Key_Up);
        QCOMPARE(shell.screen->property("focusedEpisode").toInt(), 0);
        press(shell, Qt::Key_Up);
        QCOMPARE(shell.screen->property("focusNode").toString(), QStringLiteral("seasons"));
        press(shell, Qt::Key_Up);
        QCOMPARE(shell.screen->property("focusNode").toString(), QStringLiteral("start"));
        press(shell, Qt::Key_Up);
        QCOMPARE(shell.screen->property("focusNode").toString(), QStringLiteral("back"));
    }

    void moreLikeThisListsGenreSiblingsAndOpensThem()
    {
        Shell shell;
        QVERIFY(openShows(shell));
        shell.controller->navigation()->openShowDetail(QStringLiteral("Bluey"));
        QQuickItem *detail = nullptr;
        QTRY_VERIFY((detail = find(shell, QStringLiteral("showDetailScroll"))) != nullptr);
        shell.screen = detail->parentItem();
        QTRY_VERIFY(shell.screen->hasActiveFocus());
        // One season: no stepper, so Down goes straight to the rows.
        QCOMPARE(shell.screen->property("similarCount").toInt(), 1);
        QVERIFY(!find(shell, QStringLiteral("showDetailSeasons"))->isVisible());

        press(shell, Qt::Key_Down);
        QCOMPARE(shell.screen->property("focusNode").toString(), QStringLiteral("episode"));
        press(shell, Qt::Key_Down);
        press(shell, Qt::Key_Down);
        QCOMPARE(shell.screen->property("focusNode").toString(), QStringLiteral("more"));
        snapshot(shell, "04-show-detail-more-like-this");

        press(shell, Qt::Key_Return);
        QTRY_COMPARE(shell.controller->navigation()->selectedMediaId(), QStringLiteral("Hey Arnold"));
        QQuickItem *title = nullptr;
        QTRY_VERIFY((title = find(shell, QStringLiteral("showDetailTitle"))) != nullptr
                    && title->property("text").toString() == QStringLiteral("Hey Arnold"));
    }

    void progressMovesUpNextAndRevealsContinue()
    {
        Shell shell;
        QVERIFY(openWire(shell));
        const ShowSummary *wire = shell.controller->shows()->summary(QStringLiteral("The Wire"));
        QVERIFY(wire != nullptr);
        const QString firstId = wire->episodes.at(0).id;

        // Progress is kept for a profile, so a viewer has chosen one.
        QVERIFY(shell.controller->chooseProfile(
            shell.controller->profiles()->profileAt(0).value(QStringLiteral("profileId")).toString()));
        QTRY_VERIFY(!shell.controller->profileExitInFlight());

        shell.controller->player()->prepare(shell.library.path()
                                                + QStringLiteral("/The Wire (2002)/Season 1/The Wire - S01E01 - The Target.mkv"),
                                            QStringLiteral("The Wire"), firstId, 0);
        shell.controller->player()->reportPlayback(1800.0, 3600.0, false);
        shell.controller->player()->endSession();

        QTRY_COMPARE(shell.controller->shows()->summary(QStringLiteral("The Wire"))->upNextLabel(),
                     QStringLiteral("S1 E1"));
        QQuickItem *cont = nullptr;
        QTRY_VERIFY((cont = find(shell, QStringLiteral("showDetailContinue"))) != nullptr
                    && cont->isVisible());
        QCOMPARE(cont->property("label").toString(), QStringLiteral("Resume S1 E1"));
        auto *upNext = find(shell, QStringLiteral("showDetailEpisode_0"))
                           ->findChild<QQuickItem *>(QStringLiteral("episodeRowUpNext"));
        QVERIFY(upNext != nullptr);
        QVERIFY(upNext->isVisible());
        snapshot(shell, "05-show-detail-resume");
    }

    void continueAfterPlaybackQueuesTheNextEpisodeWhenAllowed()
    {
        Shell shell;
        QVERIFY(openWire(shell));
        const ShowSummary *wire = shell.controller->shows()->summary(QStringLiteral("The Wire"));
        QVERIFY(wire != nullptr);
        const QString firstId = wire->episodes.at(0).id;
        const QString lastId = wire->episodes.at(2).id;

        shell.controller->settings()->setAutoPlayNextEpisode(false);
        QVERIFY(!shell.controller->continueAfterPlayback(firstId));

        shell.controller->settings()->setAutoPlayNextEpisode(true);
        QVERIFY(shell.controller->continueAfterPlayback(firstId));
        QCOMPARE(shell.controller->player()->mediaId(), wire->episodes.at(1).id);
        QCOMPARE(shell.controller->player()->title(), QStringLiteral("The Wire"));
        QCOMPARE(shell.controller->player()->subtitle(),
                 QStringLiteral("S1 E2 \u00B7 The Detail"));
        QCOMPARE(shell.controller->navigation()->route(), NavigationController::Route::Player);

        // The last episode has nothing to follow it.
        QVERIFY(!shell.controller->continueAfterPlayback(lastId));
    }
};

QTEST_MAIN(TestTvRoute)
#include "tst_tv_route.moc"
