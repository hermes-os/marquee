#include <QtTest>

#include <QDir>
#include <QFile>
#include <QGuiApplication>
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

namespace
{
[[nodiscard]] bool writeFile(const QString &path)
{
    QDir().mkpath(QFileInfo(path).absolutePath());
    QFile file(path);
    return file.open(QIODevice::WriteOnly) && file.write("media") == 5;
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

private slots:
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

        // Up from the first row reaches the capsule, draws its focus chrome,
        // and takes the ring off every card.
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

        // Down leaves it, back on the card it left.
        press(shell, Qt::Key_Down);
        QVERIFY(!rows->playSomethingFocused());
        QVERIFY(!frame->property("active").toBool());
        QCOMPARE(firstRow->property("focusedIndex").toInt(), 0);

        press(shell, Qt::Key_Up);
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
        shell.controller->homeRows()->focus()->setPosition(lastRow, 0);
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
        QCOMPARE(focus->row(), 0);
        QCOMPARE(focus->column(), 0);

        // Up at the top reaches the Play Something capsule above the rows and
        // moves no card; Down returns to the card it left.
        press(shell, Qt::Key_Up);
        QVERIFY(rows->playSomethingFocused());
        QCOMPARE(focus->row(), 0);
        press(shell, Qt::Key_Down);
        QVERIFY(!rows->playSomethingFocused());
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
        // The first row sits above the fold whatever the window size.
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

        const qreal start = scroll->property("contentY").toReal();
        for (int step = 0; step < rows->rowCount() - 1; ++step) {
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
        for (int step = 0; step < rows->rowCount() - 1; ++step) {
            press(shell, Qt::Key_Up);
        }
        QTRY_COMPARE(qRound(scroll->property("contentY").toReal()), qRound(start));
        QVERIFY(!springObject->property("running").toBool());
        for (int step = 0; step < rows->rowCount() - 1; ++step) {
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
