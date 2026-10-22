#include <QtTest>

#include <QDir>
#include <QFile>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickItem>
#include <QQuickWindow>
#include <QScopeGuard>
#include <QSemaphore>
#include <QSignalSpy>
#include <QSqlDatabase>
#include <QSqlError>
#include <QSqlQuery>
#include <QTemporaryDir>

#include "app/AppPaths.hpp"
#include "app/ApplicationController.hpp"
#include "catalog/CatalogDatabase.hpp"
#include "catalog/CatalogStore.hpp"
#include "catalog/LibraryScanner.hpp"
#include "navigation/NavigationController.hpp"
#include "models/HomeRowsModel.hpp"
#include "profiles/ProfileStore.hpp"

namespace
{
[[nodiscard]] QQuickItem *itemNamed(QObject *root, const QString &name)
{
    return root->findChild<QQuickItem *>(name);
}

// A Repeater's delegates live outside the QObject tree, so a card is asked of
// the repeater that owns it.
[[nodiscard]] QQuickItem *repeaterItem(QObject *root, const QString &repeaterName, int index)
{
    auto *repeater = root->findChild<QQuickItem *>(repeaterName);
    if (repeater == nullptr) {
        return nullptr;
    }
    QQuickItem *item = nullptr;
    QMetaObject::invokeMethod(repeater, "itemAt", Q_RETURN_ARG(QQuickItem *, item), Q_ARG(int, index));
    return item;
}

// A catalog holding scanned movies, so Home has cards to take the remote.
[[nodiscard]] bool seedMovies(const QString &moviesDir, int count = 1)
{
    AppPaths::ensureDirectories();
    for (int index = 0; index < count; ++index) {
        QFile file(moviesDir + QStringLiteral("/Arrival %1 (%2).mkv").arg(index).arg(2016 + index));
        if (!file.open(QIODevice::WriteOnly) || file.write("media") != 5) {
            return false;
        }
        file.close();
    }
    CatalogDatabase catalog(AppPaths::catalogFile());
    catalog.migrate();
    CatalogStore store(AppPaths::catalogFile());
    LibraryRootPaths paths;
    paths.movies.push_back(moviesDir);
    const QVector<LibraryRoot> roots = store.registerRoots(paths);
    for (const LibraryRoot &root : roots) {
        store.applyScan(root, LibraryScanner::scan(root));
    }
    return !roots.isEmpty();
}

// Where the sidebar's Home entry sits in its own list, so a test does not
// assume Home is first.
[[nodiscard]] int homeEntryIndex(QQuickItem *sidebar)
{
    const QVariantList entries = sidebar->property("entries").toList();
    for (int index = 0; index < entries.size(); ++index) {
        if (entries.at(index).toMap().value(QStringLiteral("route")).toInt()
            == static_cast<int>(NavigationController::Route::Home)) {
            return index;
        }
    }
    return -1;
}

[[nodiscard]] QString focusKind(QQuickItem *picker)
{
    return picker->property("focusKind").toString();
}

[[nodiscard]] QString focusProfileId(QQuickItem *picker)
{
    return picker->property("focusProfileId").toString();
}

// What the late-restart cases share: a second profile, the title it has
// progress on, and Home's first card.
struct SwitchFixture
{
    QString second;
    QString watched;
};
}

class ProfilePickerTest final : public QObject
{
    Q_OBJECT

private:
    QQuickWindow *loadMainWindow(ApplicationController &controller, QQmlApplicationEngine &engine)
    {
        controller.setStartFullscreen(false);
        engine.rootContext()->setContextProperty(QStringLiteral("appController"), &controller);
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

    [[nodiscard]] QQuickItem *pickerOf(QQuickWindow *window)
    {
        auto *loader = itemNamed(window, QStringLiteral("profilePickerLoader"));
        if (loader == nullptr) {
            return nullptr;
        }
        return loader->property("item").value<QQuickItem *>();
    }

private slots:
    // ContentView.swift:29-40: the application opens on the picker, over the
    // whole window with no sidebar, and the header copy is the released
    // prompt over the library summary.
    void theApplicationOpensOnThePickerWithoutTheSidebar()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restore = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        ApplicationController controller;
        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY2(window != nullptr, "qml/Main.qml did not load from the module");

        QCOMPARE(controller.navigation()->route(), NavigationController::Route::ProfilePicker);
        QQuickItem *picker = pickerOf(window);
        QVERIFY(picker != nullptr);
        QTRY_VERIFY(picker->hasActiveFocus());

        QQuickItem *sidebar = itemNamed(window, QStringLiteral("sidebar"));
        QVERIFY(sidebar != nullptr);
        QVERIFY(!sidebar->isVisible());

        QCOMPARE(itemNamed(picker, QStringLiteral("profilePickerPrompt"))->property("text").toString(),
                 QStringLiteral("Who's watching?"));
        QCOMPARE(itemNamed(picker, QStringLiteral("profilePickerSummary"))->property("text").toString(),
                 QStringLiteral("0 movies  /  0 episodes"));

        // ProfilePickerView.swift:511-521: the focus opens on the first
        // profile when none is remembered.
        QCOMPARE(focusKind(picker), QStringLiteral("profile"));
        QCOMPARE(focusProfileId(picker), controller.profiles()->profiles().at(0).id);
    }

    // ProfilePickerView.swift:132-141, :187-235: Right walks the profiles
    // then the add item and stops; Down reaches the manage control; Up
    // returns; Left on the manage control wraps to the far end.
    void theRemoteWalksTheTopRowAndTheManageControl()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restore = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        ApplicationController controller;
        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY(window != nullptr);
        QQuickItem *picker = pickerOf(window);
        QVERIFY(picker != nullptr);
        QTRY_VERIFY(picker->hasActiveFocus());

        const QString main = controller.profiles()->profiles().at(0).id;
        const QString kids = controller.profiles()->profiles().at(1).id;

        QTest::keyClick(window, Qt::Key_Left);
        QCOMPARE(focusProfileId(picker), main);

        QTest::keyClick(window, Qt::Key_Right);
        QCOMPARE(focusKind(picker), QStringLiteral("profile"));
        QCOMPARE(focusProfileId(picker), kids);

        QTest::keyClick(window, Qt::Key_Right);
        QCOMPARE(focusKind(picker), QStringLiteral("add"));

        QTest::keyClick(window, Qt::Key_Right);
        QCOMPARE(focusKind(picker), QStringLiteral("add"));

        QTest::keyClick(window, Qt::Key_Down);
        QCOMPARE(focusKind(picker), QStringLiteral("manage"));

        QTest::keyClick(window, Qt::Key_Down);
        QCOMPARE(focusKind(picker), QStringLiteral("manage"));

        QTest::keyClick(window, Qt::Key_Left);
        QCOMPARE(focusKind(picker), QStringLiteral("add"));

        QTest::keyClick(window, Qt::Key_Down);
        QTest::keyClick(window, Qt::Key_Right);
        QCOMPARE(focusKind(picker), QStringLiteral("profile"));
        QCOMPARE(focusProfileId(picker), main);

        QTest::keyClick(window, Qt::Key_Down);
        QTest::keyClick(window, Qt::Key_Up);
        QCOMPARE(focusKind(picker), QStringLiteral("profile"));
        QCOMPARE(focusProfileId(picker), main);
    }

    // AppState.swift:267-305 and ContentView.swift:29-43: Select on a
    // profile makes it active at once, the picker stops taking input and
    // fades for 0.24 seconds, then the shell shows on Home with the sidebar
    // wearing that profile.
    void selectingAProfileFadesThePickerThenShowsTheShell()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restore = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        ApplicationController controller;
        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY(window != nullptr);
        QQuickItem *picker = pickerOf(window);
        QVERIFY(picker != nullptr);
        QTRY_VERIFY(picker->hasActiveFocus());

        QTest::keyClick(window, Qt::Key_Right);
        const QString kids = controller.profiles()->profiles().at(1).id;
        QCOMPARE(focusProfileId(picker), kids);

        QSignalSpy exitSpy(&controller, &ApplicationController::profileExitInFlightChanged);
        QTest::keyClick(window, Qt::Key_Return);

        QVERIFY(controller.profileExitInFlight());
        QCOMPARE(controller.activeProfileId(), kids);
        QCOMPARE(controller.activeProfileName(), QStringLiteral("Kids"));
        QVERIFY(controller.kidsMode());
        // ProfileSession.swift:80 and ContentView.swift:41-43: the shell is
        // composed beneath the fading picker from the moment of the choice,
        // and the picker keeps the remote until the fade ends (:83-87).
        QCOMPARE(controller.navigation()->route(), NavigationController::Route::Home);
        QCOMPARE(picker->property("exitSelectionId").toString(), kids);
        QQuickItem *shell = itemNamed(window, QStringLiteral("sidebar"));
        QVERIFY(shell != nullptr);
        QVERIFY(shell->isVisible());
        QVERIFY(!shell->isEnabled());
        QVERIFY(picker->hasActiveFocus());

        // A second choice while the exit runs is refused (AppState.swift:267).
        QTest::keyClick(window, Qt::Key_Left);
        QCOMPARE(focusProfileId(picker), kids);
        QTest::keyClick(window, Qt::Key_Return);
        QCOMPARE(controller.activeProfileId(), kids);

        QTRY_VERIFY_WITH_TIMEOUT(!controller.profileExitInFlight(), 2000);
        QCOMPARE(exitSpy.count(), 2);
        QCOMPARE(controller.navigation()->route(), NavigationController::Route::Home);

        QQuickItem *sidebar = itemNamed(window, QStringLiteral("sidebar"));
        QVERIFY(sidebar != nullptr);
        QTRY_VERIFY(sidebar->isVisible());
        // ContentView.swift:391-407 leaves the sidebar without remote focus
        // when the picker goes, so the content owns the remote.
        QTRY_VERIFY(itemNamed(window, QStringLiteral("contentFocus"))->hasActiveFocus());
        QVERIFY(!sidebar->hasActiveFocus());
        QCOMPARE(sidebar->property("activeProfileName").toString(), QStringLiteral("Kids"));
        QCOMPARE(sidebar->property("activeProfileAvatarIcon").toString(), QStringLiteral("hare.fill"));
        QVERIFY(sidebar->property("kidsMode").toBool());
        QVERIFY(pickerOf(window) == nullptr);

        // MarqueeSidebar.swift:110-111: the sidebar's profile control brings
        // the picker back, remembering the active profile as its focus.
        controller.switchProfile();
        QCOMPARE(controller.navigation()->route(), NavigationController::Route::ProfilePicker);
        QQuickItem *reopened = pickerOf(window);
        QVERIFY(reopened != nullptr);
        QTRY_VERIFY(reopened->hasActiveFocus());
        QCOMPARE(focusProfileId(reopened), kids);
        QVERIFY(!sidebar->isVisible());
    }

    // The released picker only tints a hovered card (ProfilePickerView.swift
    // :805-807). A pointer resting where the picker opens must not take the
    // remote: Return still chooses the profile the remote stands on.
    void aRestingPointerDoesNotMoveThePickersRemote()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restore = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        ApplicationController controller;
        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY(window != nullptr);
        QQuickItem *picker = pickerOf(window);
        QVERIFY(picker != nullptr);
        QTRY_VERIFY(picker->hasActiveFocus());

        const QString main = controller.profiles()->profiles().at(0).id;
        const QString kids = controller.profiles()->profiles().at(1).id;
        QQuickItem *kidsCard = repeaterItem(picker, QStringLiteral("profileCards"), 1);
        QVERIFY(kidsCard != nullptr);
        QTRY_VERIFY(kidsCard->width() > 0 && kidsCard->height() > 0);
        QTRY_VERIFY(window->isExposed());
        QTRY_COMPARE(window->size(), QSize(1280, 800));
        const QPoint overKids = kidsCard->mapToScene(QPointF(kidsCard->width() / 2, kidsCard->height() / 2)).toPoint();

        QTest::keyClick(window, Qt::Key_Return);
        QTRY_VERIFY_WITH_TIMEOUT(!controller.profileExitInFlight(), 2000);
        QCOMPARE(controller.activeProfileId(), main);

        // The pointer comes to rest, then the picker opens beneath it.
        QTest::mouseMove(window, overKids);
        controller.switchProfile();
        QCOMPARE(controller.navigation()->route(), NavigationController::Route::ProfilePicker);
        QQuickItem *reopened = pickerOf(window);
        QVERIFY(reopened != nullptr);
        QTRY_VERIFY(reopened->hasActiveFocus());
        QQuickItem *reopenedKids = repeaterItem(reopened, QStringLiteral("profileCards"), 1);
        QVERIFY(reopenedKids != nullptr);
        // The hover reached the card (it tints) but not the remote.
        QTRY_VERIFY(reopenedKids->property("hovered").toBool());
        QTest::qWait(200);
        QCOMPARE(focusProfileId(reopened), main);

        QTest::keyClick(window, Qt::Key_Return);
        QCOMPARE(controller.activeProfileId(), main);
        QVERIFY(controller.activeProfileId() != kids);
    }

    // The shared body of the two re-choice cases: Home's content must hold
    // the remote with a visible ring, and the sidebar's remembered stop must
    // be Home, so the next Return opens a card instead of the profile picker.
    void verifyHomeHoldsTheRemote(QQuickWindow *window, ApplicationController &controller)
    {
        QTRY_VERIFY_WITH_TIMEOUT(!controller.profileExitInFlight(), 2000);
        QQuickItem *sidebar = itemNamed(window, QStringLiteral("sidebar"));
        QQuickItem *content = itemNamed(window, QStringLiteral("contentFocus"));
        QVERIFY(sidebar != nullptr && content != nullptr);
        QTRY_VERIFY(content->hasActiveFocus());
        QVERIFY(!sidebar->hasActiveFocus());
        const int homeIndex = homeEntryIndex(sidebar);
        QVERIFY(homeIndex >= 0);
        QCOMPARE(sidebar->property("focusedIndex").toInt(), homeIndex);

        auto *loader = itemNamed(window, QStringLiteral("screenLoader"));
        QVERIFY(loader != nullptr);
        auto *home = loader->property("item").value<QQuickItem *>();
        QVERIFY(home != nullptr);
        QVERIFY(home->hasActiveFocus());
        // The ring is drawn by the row whose focusedIndex is not -1.
        QTRY_VERIFY(([&] {
            auto *rows = itemNamed(home, QStringLiteral("homeRows"));
            if (rows == nullptr) {
                return false;
            }
            const int count = rows->property("count").toInt();
            for (int index = 0; index < count; ++index) {
                QQuickItem *row = repeaterItem(home, QStringLiteral("homeRows"), index);
                if (row != nullptr && row->property("focusedIndex").toInt() >= 0) {
                    return true;
                }
            }
            return false;
        })());
    }

    // The loop the owner hit: choose a profile, walk the sidebar to the
    // profile control, Return, choose again, Return. The second Return opens
    // a Home card; it used to land on the profile control again.
    void choosingAgainAfterSwitchProfileLeavesTheRemoteOnHome()
    {
        QTemporaryDir runtimeRoot;
        QTemporaryDir movies;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restore = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
        QVERIFY(seedMovies(movies.path()));

        ApplicationController controller;
        controller.setTemporaryLibraryRoot(movies.path());
        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY(window != nullptr);
        QQuickItem *picker = pickerOf(window);
        QVERIFY(picker != nullptr);
        QTRY_VERIFY(picker->hasActiveFocus());

        QTest::keyClick(window, Qt::Key_Return);
        QTRY_VERIFY_WITH_TIMEOUT(!controller.profileExitInFlight(), 2000);
        QCOMPARE(controller.navigation()->route(), NavigationController::Route::Home);
        verifyHomeHoldsTheRemote(window, controller);

        QQuickItem *sidebar = itemNamed(window, QStringLiteral("sidebar"));
        QTest::keyClick(window, Qt::Key_Left);
        QTRY_VERIFY(sidebar->hasActiveFocus());
        const int profileIndex = sidebar->property("profileIndex").toInt();
        for (int step = 0; step < profileIndex; ++step) {
            QTest::keyClick(window, Qt::Key_Down);
        }
        QCOMPARE(sidebar->property("focusedIndex").toInt(), profileIndex);
        QTest::keyClick(window, Qt::Key_Return);
        QCOMPARE(controller.navigation()->route(), NavigationController::Route::ProfilePicker);

        QQuickItem *reopened = pickerOf(window);
        QVERIFY(reopened != nullptr);
        QTRY_VERIFY(reopened->hasActiveFocus());
        QTest::keyClick(window, Qt::Key_Return);
        verifyHomeHoldsTheRemote(window, controller);

        // Return on Home opens the focused card; it does not reopen the picker.
        QTest::keyClick(window, Qt::Key_Return);
        QTRY_COMPARE(controller.navigation()->route(), NavigationController::Route::Details);
        QVERIFY(pickerOf(window) == nullptr);
    }

    // The owner's loop on a real session: choose, Return opens Details, back
    // to Home, Left to the sidebar, Down to the profile control, Return, choose
    // again, wait, Return. The first Return after the second choice must open
    // the first card, not vanish.
    void theFirstReturnAfterAReChoiceOpensTheFirstCard()
    {
        QTemporaryDir runtimeRoot;
        QTemporaryDir movies;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restore = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
        QVERIFY(seedMovies(movies.path(), 3));

        ApplicationController controller;
        controller.setTemporaryLibraryRoot(movies.path());
        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY(window != nullptr);
        QQuickItem *picker = pickerOf(window);
        QVERIFY(picker != nullptr);
        QTRY_VERIFY(picker->hasActiveFocus());

        QTest::keyClick(window, Qt::Key_Return);
        verifyHomeHoldsTheRemote(window, controller);
        HomeRowsModel *home = controller.homeRows();
        QTRY_VERIFY(home->rowCount() >= 2);
        const QString firstCard = home->cardAt(0, 0).value(QStringLiteral("mediaId")).toString();
        QVERIFY(!firstCard.isEmpty());
        // Off the first card, so a Home that kept the remote where it stood
        // would open another card after the re-choice.
        // The same movie can sit in several rows, so walk to a card that is a
        // different title.
        QTest::keyClick(window, Qt::Key_Down);
        QCOMPARE(home->focus()->row(), 1);
        const auto focusedCard = [home] {
            return home->cardAt(home->focus()->row(), home->focus()->column())
                .value(QStringLiteral("mediaId")).toString();
        };
        while (focusedCard() == firstCard) {
            QVERIFY2(home->moveRight(), "row 1 holds no title other than the first card");
        }
        const QString stale = focusedCard();
        QTest::keyClick(window, Qt::Key_Return);
        QTRY_COMPARE(controller.navigation()->route(), NavigationController::Route::Details);
        QCOMPARE(controller.navigation()->selectedMediaId(), stale);

        QTest::keyClick(window, Qt::Key_Escape);
        QTRY_COMPARE(controller.navigation()->route(), NavigationController::Route::Home);
        QQuickItem *sidebar = itemNamed(window, QStringLiteral("sidebar"));
        QVERIFY(sidebar != nullptr);
        // Left walks the row back to its first card, then hands the remote
        // to the sidebar.
        for (int step = 0; step < 6 && !sidebar->hasActiveFocus(); ++step) {
            QTest::keyClick(window, Qt::Key_Left);
        }
        QTRY_VERIFY(sidebar->hasActiveFocus());
        const int profileIndex = sidebar->property("profileIndex").toInt();
        for (int step = 0; step < profileIndex; ++step) {
            QTest::keyClick(window, Qt::Key_Down);
        }
        QTest::keyClick(window, Qt::Key_Return);
        QCOMPARE(controller.navigation()->route(), NavigationController::Route::ProfilePicker);

        QQuickItem *reopened = pickerOf(window);
        QVERIFY(reopened != nullptr);
        QTRY_VERIFY(reopened->hasActiveFocus());
        QTest::keyClick(window, Qt::Key_Return);
        verifyHomeHoldsTheRemote(window, controller);

        QTRY_VERIFY(home->focus()->row() == 0 && home->focus()->column() == 0);
        QTest::keyClick(window, Qt::Key_Return);
        QTRY_COMPARE(controller.navigation()->route(), NavigationController::Route::Details);
        QCOMPARE(controller.navigation()->selectedMediaId(), firstCard);
    }

    [[nodiscard]] bool prepareSwitch(ApplicationController &controller, QQuickWindow *window,
                                     SwitchFixture &fixture)
    {
        fixture.second = controller.profiles()->addProfile(
            QStringLiteral("Second"), QStringLiteral("hare.fill"), QStringLiteral("#3366CC"),
            static_cast<int>(ProfileStore::Maturity::Adult));
        return !fixture.second.isEmpty() && window != nullptr;
    }

    void chooseSecondProfile(QQuickWindow *window, ApplicationController &controller,
                             const QString &second)
    {
        controller.switchProfile();
        QQuickItem *reopened = pickerOf(window);
        QVERIFY(reopened != nullptr);
        QTRY_VERIFY(reopened->hasActiveFocus());
        QTest::keyClick(window, Qt::Key_Right);
        QTest::keyClick(window, Qt::Key_Right);
        QCOMPARE(focusProfileId(reopened), second);
        QTest::keyClick(window, Qt::Key_Return);
        verifyHomeHoldsTheRemote(window, controller);
    }

    // A reload queued behind a running scan lands while the viewer browses
    // the instant republish; Home must not snap to the top card under them.
    void aProjectionLandingAfterTheViewerMovedDoesNotRestartHome()
    {
        QTemporaryDir runtimeRoot;
        QTemporaryDir movies;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restore = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
        QVERIFY(seedMovies(movies.path(), 4));

        ApplicationController controller;
        controller.setTemporaryLibraryRoot(movies.path());
        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        SwitchFixture fixture;
        QVERIFY(prepareSwitch(controller, window, fixture));
        QQuickItem *picker = pickerOf(window);
        QVERIFY(picker != nullptr);
        QTRY_VERIFY(picker->hasActiveFocus());
        QTest::keyClick(window, Qt::Key_Return);
        verifyHomeHoldsTheRemote(window, controller);
        HomeRowsModel *home = controller.homeRows();
        QTRY_VERIFY(home->rowCount() >= 2);
        QTRY_VERIFY(!controller.scanning());
        fixture.watched = home->cardAt(0, 1).value(QStringLiteral("mediaId")).toString();
        QVERIFY(!fixture.watched.isEmpty());
        {
            CatalogStore store(AppPaths::catalogFile());
            store.recordWatchProgress(fixture.second, fixture.watched, 600'000, 3'600'000, false);
        }

        // The worker is held inside a running refresh, so the reload that the
        // profile choice queues waits behind it.
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
        controller.requestCatalogRefresh();
        QVERIFY2(refreshEntered.tryAcquire(1, 5000), "the refresh did not reach its gate");

        chooseSecondProfile(window, controller, fixture.second);
        QTest::keyClick(window, Qt::Key_Down);
        QCOMPARE(home->focus()->row(), 1);
        const auto focusedCard = [home] {
            return home->cardAt(home->focus()->row(), home->focus()->column())
                .value(QStringLiteral("mediaId")).toString();
        };
        const QString browsed = focusedCard();

        releaseRefresh.release();
        QTRY_COMPARE(home->cardAt(0, 0).value(QStringLiteral("mediaId")).toString(), fixture.watched);
        QTRY_VERIFY(!controller.scanning());
        // The new row sits above, the remote stayed on the card the viewer chose.
        QCOMPARE(home->focus()->row(), 2);
        QCOMPARE(focusedCard(), browsed);
    }

    // A reload that fails brings no projection, so the restart it was waiting
    // for must not stay armed for a later one.
    void aFailedReloadDisarmsTheHomeRestart()
    {
        QTemporaryDir runtimeRoot;
        QTemporaryDir movies;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restore = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
        QVERIFY(seedMovies(movies.path(), 4));

        ApplicationController controller;
        controller.setTemporaryLibraryRoot(movies.path());
        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        SwitchFixture fixture;
        QVERIFY(prepareSwitch(controller, window, fixture));
        QQuickItem *picker = pickerOf(window);
        QVERIFY(picker != nullptr);
        QTRY_VERIFY(picker->hasActiveFocus());
        QTest::keyClick(window, Qt::Key_Return);
        verifyHomeHoldsTheRemote(window, controller);
        HomeRowsModel *home = controller.homeRows();
        QTRY_VERIFY(home->rowCount() >= 2);
        QTRY_VERIFY(!controller.scanning());
        fixture.watched = home->cardAt(0, 1).value(QStringLiteral("mediaId")).toString();
        const QString top = home->cardAt(0, 0).value(QStringLiteral("mediaId")).toString();
        QVERIFY(!fixture.watched.isEmpty() && fixture.watched != top);
        {
            CatalogStore store(AppPaths::catalogFile());
            store.recordWatchProgress(fixture.second, fixture.watched, 600'000, 3'600'000, false);
        }

        // The progress table is out of the way for the reload, so it throws.
        const QString connection = QStringLiteral("profile-picker-sabotage");
        {
            QSqlDatabase database = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), connection);
            database.setDatabaseName(AppPaths::catalogFile());
            QVERIFY(database.open());
            QSqlQuery rename(database);
            QVERIFY2(rename.exec(QStringLiteral("ALTER TABLE watch_progress RENAME TO watch_progress_away")),
                     qPrintable(rename.lastError().text()));
        }
        const auto restoreTable = qScopeGuard([&] {
            {
                QSqlDatabase database = QSqlDatabase::database(connection);
                QSqlQuery rename(database);
                rename.exec(QStringLiteral("ALTER TABLE watch_progress_away RENAME TO watch_progress"));
                database.close();
            }
            QSqlDatabase::removeDatabase(connection);
        });
        QSignalSpy errors(&controller, &ApplicationController::errorChanged);
        controller.switchProfile();
        QQuickItem *reopened = pickerOf(window);
        QVERIFY(reopened != nullptr);
        QTRY_VERIFY(reopened->hasActiveFocus());
        QTest::keyClick(window, Qt::Key_Right);
        QTest::keyClick(window, Qt::Key_Right);
        QCOMPARE(focusProfileId(reopened), fixture.second);
        QTest::keyClick(window, Qt::Key_Return);
        QTRY_VERIFY(errors.count() > 0);
        QTRY_VERIFY_WITH_TIMEOUT(!controller.profileExitInFlight(), 2000);
        controller.dismissError();

        // The table is back; a later refresh now lands the progress row above.
        {
            QSqlDatabase database = QSqlDatabase::database(connection);
            QSqlQuery rename(database);
            QVERIFY(rename.exec(QStringLiteral("ALTER TABLE watch_progress_away RENAME TO watch_progress")));
        }
        controller.requestCatalogRefresh();
        QTRY_COMPARE(home->cardAt(0, 0).value(QStringLiteral("mediaId")).toString(), fixture.watched);
        QTRY_VERIFY(!controller.scanning());
        // The remote kept the card it rested on, now one row lower.
        QCOMPARE(home->focus()->row(), 1);
        QCOMPARE(home->cardAt(1, 0).value(QStringLiteral("mediaId")).toString(), top);
    }

    // Choosing the same profile again while the switch's reload is in flight
    // leaves the restart pending: the viewer has not moved, and the reload has
    // not landed.
    void choosingTheSameProfileAgainKeepsTheRestartPending()
    {
        QTemporaryDir runtimeRoot;
        QTemporaryDir movies;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restore = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
        QVERIFY(seedMovies(movies.path(), 4));

        ApplicationController controller;
        controller.setTemporaryLibraryRoot(movies.path());
        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        SwitchFixture fixture;
        QVERIFY(prepareSwitch(controller, window, fixture));
        QQuickItem *picker = pickerOf(window);
        QVERIFY(picker != nullptr);
        QTRY_VERIFY(picker->hasActiveFocus());
        QTest::keyClick(window, Qt::Key_Return);
        verifyHomeHoldsTheRemote(window, controller);
        HomeRowsModel *home = controller.homeRows();
        QTRY_VERIFY(home->rowCount() >= 2);
        QTRY_VERIFY(!controller.scanning());
        fixture.watched = home->cardAt(0, 1).value(QStringLiteral("mediaId")).toString();
        QVERIFY(!fixture.watched.isEmpty()
                && fixture.watched != home->cardAt(0, 0).value(QStringLiteral("mediaId")).toString());
        {
            CatalogStore store(AppPaths::catalogFile());
            store.recordWatchProgress(fixture.second, fixture.watched, 600'000, 3'600'000, false);
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
        controller.requestCatalogRefresh();
        QVERIFY2(refreshEntered.tryAcquire(1, 5000), "the refresh did not reach its gate");

        chooseSecondProfile(window, controller, fixture.second);
        // The same profile again, with the reload still queued and the remote
        // untouched. The picker opens on the active profile.
        controller.switchProfile();
        QQuickItem *reopened = pickerOf(window);
        QVERIFY(reopened != nullptr);
        QTRY_VERIFY(reopened->hasActiveFocus());
        QCOMPARE(focusProfileId(reopened), fixture.second);
        QTest::keyClick(window, Qt::Key_Return);
        verifyHomeHoldsTheRemote(window, controller);
        QCOMPARE(home->focus()->row(), 0);
        QCOMPARE(home->focus()->column(), 0);

        releaseRefresh.release();
        QTRY_COMPARE(home->cardAt(0, 0).value(QStringLiteral("mediaId")).toString(), fixture.watched);
        QTRY_VERIFY(!controller.scanning());
        QCOMPARE(home->focus()->row(), 0);
        QCOMPARE(home->focus()->column(), 0);
        QVERIFY(!home->playSomethingFocused());
    }

    // The profile choice resets Home's focus on the previous profile's
    // projection; the chosen profile's own projection then adds a Continue
    // Watching row above, and the first Return must still open the top card.
    void theFirstReturnOpensTheTopCardWhenTheNewProfileAddsARowAbove()
    {
        QTemporaryDir runtimeRoot;
        QTemporaryDir movies;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restore = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
        QVERIFY(seedMovies(movies.path(), 4));

        ApplicationController controller;
        controller.setTemporaryLibraryRoot(movies.path());
        const QString second = controller.profiles()->addProfile(
            QStringLiteral("Second"), QStringLiteral("hare.fill"), QStringLiteral("#3366CC"),
            static_cast<int>(ProfileStore::Maturity::Adult));
        QVERIFY(!second.isEmpty());

        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY(window != nullptr);
        QQuickItem *picker = pickerOf(window);
        QVERIFY(picker != nullptr);
        QTRY_VERIFY(picker->hasActiveFocus());

        // The first profile has no progress: Home has no Continue Watching.
        QTest::keyClick(window, Qt::Key_Return);
        verifyHomeHoldsTheRemote(window, controller);
        HomeRowsModel *home = controller.homeRows();
        QTRY_VERIFY(home->rowCount() >= 2);
        // A title that is not Home's first card for a profile without
        // progress, so the new row's card is told apart from the old top one.
        const QString watched = home->cardAt(0, 1).value(QStringLiteral("mediaId")).toString();
        QVERIFY(!watched.isEmpty());
        QVERIFY(watched != home->cardAt(0, 0).value(QStringLiteral("mediaId")).toString());
        {
            CatalogStore store(AppPaths::catalogFile());
            store.recordWatchProgress(second, watched, 600'000, 3'600'000, false);
        }
        QTest::keyClick(window, Qt::Key_Right);
        QTest::keyClick(window, Qt::Key_Down);
        QCOMPARE(home->focus()->row(), 1);

        controller.switchProfile();
        QQuickItem *reopened = pickerOf(window);
        QVERIFY(reopened != nullptr);
        QTRY_VERIFY(reopened->hasActiveFocus());
        QTest::keyClick(window, Qt::Key_Right);
        QTest::keyClick(window, Qt::Key_Right);
        QCOMPARE(focusProfileId(reopened), second);
        QTest::keyClick(window, Qt::Key_Return);
        verifyHomeHoldsTheRemote(window, controller);

        // The second profile's projection lands with the new row on top.
        QTRY_COMPARE(home->cardAt(0, 0).value(QStringLiteral("mediaId")).toString(), watched);
        QCOMPARE(home->focus()->row(), 0);
        QCOMPARE(home->focus()->column(), 0);
        QVERIFY(!home->playSomethingFocused());

        QTest::keyClick(window, Qt::Key_Return);
        QTRY_COMPARE(controller.navigation()->route(), NavigationController::Route::Details);
        QCOMPARE(controller.navigation()->selectedMediaId(), watched);
    }

    // Home is rebuilt at its first target on every profile choice
    // (ContentView.swift:391-407). The remote may have left Home standing on
    // the Play Something capsule or deep in the rows, and the viewer reaches
    // the avatar by pointer from there; the pointer or the keys then choose
    // again, and the first Return must open the first card, not act on what
    // the last visit left behind (the capsule plays something, or does
    // nothing when nothing is playable).
    void aProfileChoiceReturnsHomeToItsFirstTarget_data()
    {
        QTest::addColumn<bool>("onCapsule");
        QTest::newRow("capsule") << true;
        QTest::newRow("deep in the rows") << false;
    }

    void aProfileChoiceReturnsHomeToItsFirstTarget()
    {
        QFETCH(bool, onCapsule);
        QTemporaryDir runtimeRoot;
        QTemporaryDir movies;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restore = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
        QVERIFY(seedMovies(movies.path(), 3));

        ApplicationController controller;
        controller.setTemporaryLibraryRoot(movies.path());
        // Nothing is playable: a Return on the capsule is silent, as the
        // owner saw it.
        controller.setPlayableFileCheckForTest([](const QString &) { return false; });
        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY(window != nullptr);
        QQuickItem *picker = pickerOf(window);
        QVERIFY(picker != nullptr);
        QTRY_VERIFY(picker->hasActiveFocus());

        QTest::keyClick(window, Qt::Key_Return);
        verifyHomeHoldsTheRemote(window, controller);
        HomeRowsModel *home = controller.homeRows();
        QTRY_VERIFY(home->rowCount() >= 2);

        if (onCapsule) {
            QTest::keyClick(window, Qt::Key_Up);
            QVERIFY(home->playSomethingFocused());
        } else {
            QTest::keyClick(window, Qt::Key_Right);
            QTest::keyClick(window, Qt::Key_Down);
            QCOMPARE(home->focus()->row(), 1);
            QVERIFY(home->focus()->column() > 0);
        }

        QQuickItem *sidebar = itemNamed(window, QStringLiteral("sidebar"));
        QQuickItem *avatar = itemNamed(sidebar, QStringLiteral("sidebarProfile"));
        QVERIFY(avatar != nullptr);
        const QPoint avatarPoint = avatar->mapToScene(QPointF(avatar->width() / 2, avatar->height() / 2)).toPoint();
        QTest::mouseClick(window, Qt::LeftButton, Qt::NoModifier, avatarPoint);
        QCOMPARE(controller.navigation()->route(), NavigationController::Route::ProfilePicker);

        QQuickItem *reopened = pickerOf(window);
        QVERIFY(reopened != nullptr);
        QTRY_VERIFY(reopened->hasActiveFocus());
        QTest::keyClick(window, Qt::Key_Return);
        verifyHomeHoldsTheRemote(window, controller);

        QVERIFY(!home->playSomethingFocused());
        QCOMPARE(home->focus()->row(), 0);
        QCOMPARE(home->focus()->column(), 0);
        const QString firstCard = home->cardAt(0, 0).value(QStringLiteral("mediaId")).toString();
        QVERIFY(!firstCard.isEmpty());

        QTest::keyClick(window, Qt::Key_Return);
        QTRY_COMPARE(controller.navigation()->route(), NavigationController::Route::Details);
        QCOMPARE(controller.navigation()->selectedMediaId(), firstCard);
    }

    // The same loop through the pointer: the sidebar's remembered stop is
    // left on the profile control by the keys, the avatar is clicked, a card
    // is clicked, and the first key afterwards must not reopen the picker.
    void clickingACardAfterTheAvatarLeavesTheRemoteOnHome()
    {
        QTemporaryDir runtimeRoot;
        QTemporaryDir movies;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restore = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
        QVERIFY(seedMovies(movies.path()));

        ApplicationController controller;
        controller.setTemporaryLibraryRoot(movies.path());
        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY(window != nullptr);
        QQuickItem *picker = pickerOf(window);
        QVERIFY(picker != nullptr);
        QTRY_VERIFY(picker->hasActiveFocus());

        QTest::keyClick(window, Qt::Key_Return);
        verifyHomeHoldsTheRemote(window, controller);

        QQuickItem *sidebar = itemNamed(window, QStringLiteral("sidebar"));
        QTest::keyClick(window, Qt::Key_Left);
        QTRY_VERIFY(sidebar->hasActiveFocus());
        const int profileIndex = sidebar->property("profileIndex").toInt();
        for (int step = 0; step < profileIndex; ++step) {
            QTest::keyClick(window, Qt::Key_Down);
        }
        QQuickItem *avatar = itemNamed(sidebar, QStringLiteral("sidebarProfile"));
        QVERIFY(avatar != nullptr);
        const QPoint avatarPoint = avatar->mapToScene(QPointF(avatar->width() / 2, avatar->height() / 2)).toPoint();
        QTest::mouseClick(window, Qt::LeftButton, Qt::NoModifier, avatarPoint);
        QCOMPARE(controller.navigation()->route(), NavigationController::Route::ProfilePicker);

        QQuickItem *reopened = pickerOf(window);
        QVERIFY(reopened != nullptr);
        QQuickItem *card = repeaterItem(reopened, QStringLiteral("profileCards"), 0);
        QVERIFY(card != nullptr);
        const QPoint cardPoint = card->mapToScene(QPointF(card->width() / 2, card->height() / 2)).toPoint();
        QTest::mouseClick(window, Qt::LeftButton, Qt::NoModifier, cardPoint);
        verifyHomeHoldsTheRemote(window, controller);

        QTest::keyClick(window, Qt::Key_Return);
        QTRY_COMPARE(controller.navigation()->route(), NavigationController::Route::Details);
        QVERIFY(pickerOf(window) == nullptr);
    }

    // ProfilePickerView.swift:495-497, :664-690, :1022-1031: Manage Profiles
    // swaps the cards for tiles under the "Manage Profiles" prompt, Down from
    // a tile enters its actions (the first profile cannot move left, so Edit
    // is first), Select on an action performs it, and Back leaves management.
    void managementModeExposesTheActionsAndBackLeavesIt()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restore = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        ApplicationController controller;
        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY(window != nullptr);
        QQuickItem *picker = pickerOf(window);
        QVERIFY(picker != nullptr);
        QTRY_VERIFY(picker->hasActiveFocus());

        const QString main = controller.profiles()->profiles().at(0).id;
        const QString kids = controller.profiles()->profiles().at(1).id;

        QTest::keyClick(window, Qt::Key_Down);
        QCOMPARE(focusKind(picker), QStringLiteral("manage"));
        QTest::keyClick(window, Qt::Key_Return);
        QVERIFY(picker->property("managing").toBool());
        QCOMPARE(itemNamed(picker, QStringLiteral("profilePickerPrompt"))->property("text").toString(),
                 QStringLiteral("Manage Profiles"));
        QCOMPARE(itemNamed(picker, QStringLiteral("profileManageLabel"))->property("text").toString(),
                 QStringLiteral("Done"));
        QVERIFY(!itemNamed(picker, QStringLiteral("profileSelectionRow"))->isVisible());
        QVERIFY(itemNamed(picker, QStringLiteral("profileManagementRow"))->isVisible());

        QTest::keyClick(window, Qt::Key_Up);
        QCOMPARE(focusKind(picker), QStringLiteral("profile"));
        QCOMPARE(focusProfileId(picker), main);

        QTest::keyClick(window, Qt::Key_Down);
        QCOMPARE(focusKind(picker), QStringLiteral("action"));
        QCOMPARE(picker->property("focusAction").toInt(), 1);

        // Edit, Delete, Move Right are what the first of two profiles offers.
        QTest::keyClick(window, Qt::Key_Right);
        QCOMPARE(picker->property("focusAction").toInt(), 2);
        QTest::keyClick(window, Qt::Key_Right);
        QCOMPARE(picker->property("focusAction").toInt(), 3);
        QTest::keyClick(window, Qt::Key_Right);
        QCOMPARE(picker->property("focusAction").toInt(), 3);

        // Move Right swaps the profiles and keeps the focus on the moved one.
        QTest::keyClick(window, Qt::Key_Return);
        QCOMPARE(controller.profiles()->profiles().at(0).id, kids);
        QCOMPARE(controller.profiles()->profiles().at(1).id, main);
        QCOMPARE(focusProfileId(picker), main);

        // The last profile cannot move right; its actions are Left, Edit,
        // Delete.
        QTest::keyClick(window, Qt::Key_Up);
        QTest::keyClick(window, Qt::Key_Down);
        QCOMPARE(picker->property("focusAction").toInt(), 0);
        QTest::keyClick(window, Qt::Key_Right);
        QTest::keyClick(window, Qt::Key_Right);
        QCOMPARE(picker->property("focusAction").toInt(), 2);
        QTest::keyClick(window, Qt::Key_Right);
        QCOMPARE(picker->property("focusAction").toInt(), 2);

        // Delete asks first (:591-600); Back declines and nothing changes.
        QTest::keyClick(window, Qt::Key_Return);
        QCOMPARE(picker->property("pendingDeleteId").toString(), main);
        QVERIFY(itemNamed(picker, QStringLiteral("profileDeleteDialog"))->isVisible());
        QCOMPARE(itemNamed(picker, QStringLiteral("confirmDialogTitle"))->property("text").toString(),
                 QStringLiteral("Delete Main?"));
        QTest::keyClick(window, Qt::Key_Escape);
        QCOMPARE(picker->property("pendingDeleteId").toString(), QString());
        QCOMPARE(controller.profiles()->count(), 2);

        // Confirming removes it and the focus stays at that index.
        QTest::keyClick(window, Qt::Key_Return);
        QTest::keyClick(window, Qt::Key_Return);
        QCOMPARE(controller.profiles()->count(), 1);
        QCOMPARE(focusKind(picker), QStringLiteral("profile"));
        QCOMPARE(focusProfileId(picker), kids);

        // Back leaves management (:967-970).
        QTest::keyClick(window, Qt::Key_Escape);
        QVERIFY(!picker->property("managing").toBool());
        QCOMPARE(controller.navigation()->route(), NavigationController::Route::ProfilePicker);
    }

    // ProfilePickerView.swift:812-895 and :1257-1544: the add item opens the
    // editor as New Profile with the first catalog avatar and Adult chosen;
    // Save with a name adds the profile and the picker focuses it.
    void theAddItemOpensTheEditorAndSavingCreatesTheProfile()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restore = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        ApplicationController controller;
        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY(window != nullptr);
        QQuickItem *picker = pickerOf(window);
        QVERIFY(picker != nullptr);
        QTRY_VERIFY(picker->hasActiveFocus());

        QTest::keyClick(window, Qt::Key_Right);
        QTest::keyClick(window, Qt::Key_Right);
        QCOMPARE(focusKind(picker), QStringLiteral("add"));
        QTest::keyClick(window, Qt::Key_Return);
        QVERIFY(picker->property("editorOpen").toBool());

        QQuickItem *editor = itemNamed(picker, QStringLiteral("profileEditor"));
        QVERIFY(editor != nullptr);
        QCOMPARE(itemNamed(editor, QStringLiteral("profileEditorTitle"))->property("text").toString(),
                 QStringLiteral("New Profile"));
        QCOMPARE(editor->property("selectedIcon").toString(), QStringLiteral("hare.fill"));
        QCOMPARE(editor->property("maturityLevel").toInt(), int(ProfileStore::Maturity::Adult));
        QVERIFY(!editor->property("canSave").toBool());

        QQuickItem *nameField = itemNamed(editor, QStringLiteral("profileEditorName"));
        QVERIFY(nameField != nullptr);
        QTRY_VERIFY(nameField->hasActiveFocus());
        for (const QChar letter : QStringLiteral("Sam")) {
            QTest::keyClick(window, letter.toLatin1());
        }
        QVERIFY(editor->property("canSave").toBool());
        QTest::keyClick(window, Qt::Key_Return);

        QVERIFY(!picker->property("editorOpen").toBool());
        QCOMPARE(controller.profiles()->count(), 3);
        const Profile created = controller.profiles()->profiles().at(2);
        QCOMPARE(created.name, QStringLiteral("Sam"));
        QCOMPARE(created.avatarIcon, QStringLiteral("hare.fill"));
        QCOMPARE(created.maturityLevel, int(ProfileStore::Maturity::Adult));
        QCOMPARE(focusKind(picker), QStringLiteral("profile"));
        QCOMPARE(focusProfileId(picker), created.id);
        QTRY_VERIFY(picker->hasActiveFocus());
    }

    // ProfilePickerView.swift:435-440 and :735-810: the card column is
    // 150/220 wide, the disc 130/190 inside a 4/6 ring outset, items 24/38
    // apart, in the compact and lean-back measurements.
    void cardsFollowTheReleasedGeometry_data()
    {
        QTest::addColumn<bool>("leanBack");
        QTest::addColumn<qreal>("cardWidth");
        QTest::addColumn<qreal>("spacing");
        QTest::addColumn<qreal>("disc");
        QTest::addColumn<qreal>("frame");
        QTest::newRow("compact") << false << 150.0 << 24.0 << 130.0 << 138.0;
        QTest::newRow("lean-back") << true << 220.0 << 38.0 << 190.0 << 202.0;
    }

    void cardsFollowTheReleasedGeometry()
    {
        QFETCH(bool, leanBack);
        QFETCH(qreal, cardWidth);
        QFETCH(qreal, spacing);
        QFETCH(qreal, disc);
        QFETCH(qreal, frame);

        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restore = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        ApplicationController controller;
        controller.settings()->setLeanBackMode(leanBack);
        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY(window != nullptr);
        QQuickItem *picker = pickerOf(window);
        QVERIFY(picker != nullptr);

        QQuickItem *first = repeaterItem(picker, QStringLiteral("profileCards"), 0);
        QQuickItem *second = repeaterItem(picker, QStringLiteral("profileCards"), 1);
        QVERIFY(first != nullptr && second != nullptr);
        QCOMPARE(first->width(), cardWidth);
        QCOMPARE(second->x() - (first->x() + first->width()), spacing);

        QQuickItem *discItem = itemNamed(first, QStringLiteral("profileCardDisc"));
        QQuickItem *frameItem = itemNamed(first, QStringLiteral("profileCardDiscFrame"));
        QVERIFY(discItem != nullptr && frameItem != nullptr);
        QCOMPARE(discItem->width(), disc);
        QCOMPARE(frameItem->width(), frame);

        QQuickItem *add = itemNamed(picker, QStringLiteral("profileAddCard"));
        QVERIFY(add != nullptr);
        QVERIFY(add->isVisible());
        QCOMPARE(add->width(), cardWidth);
        QCOMPARE(itemNamed(add, QStringLiteral("profileCardTitle"))->property("text").toString(),
                 QStringLiteral("Add Profile"));
    }
};

QTEST_MAIN(ProfilePickerTest)
#include "tst_profile_picker.moc"
