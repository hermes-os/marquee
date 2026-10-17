#include <QtTest>

#include <QDir>
#include <QFile>
#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickItem>
#include <QQuickWindow>
#include <QScopeGuard>
#include <QTemporaryDir>

#include "app/AppPaths.hpp"
#include "app/ApplicationController.hpp"
#include "navigation/NavigationController.hpp"
#include "search/SearchSession.hpp"

namespace
{
[[nodiscard]] bool writeMediaFile(const QString &root, const QString &relativePath)
{
    const QString path = root + QLatin1Char('/') + relativePath;
    QDir().mkpath(QFileInfo(path).absolutePath());
    QFile file(path);
    return file.open(QIODevice::WriteOnly) && file.write("media") == 5;
}

[[nodiscard]] QStringList sampleTitles()
{
    return {QStringLiteral("Alien.1979.mkv"),   QStringLiteral("Aliens.1986.mkv"),
            QStringLiteral("Arrival.2016.mkv"), QStringLiteral("Coco.2017.mkv"),
            QStringLiteral("Dune.2021.mkv"),    QStringLiteral("Heat.1995.mkv"),
            QStringLiteral("Jaws.1975.mkv"),    QStringLiteral("Moon.2009.mkv"),
            QStringLiteral("Nope.2022.mkv"),    QStringLiteral("Prey.2022.mkv"),
            QStringLiteral("Tenet.2020.mkv"),   QStringLiteral("The.Final.Cut.2004.mkv")};
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

[[nodiscard]] QString remoteFocusOf(const Shell &shell)
{
    return shell.screen->property("remoteFocus").toString();
}

void press(Shell &shell, Qt::Key key)
{
    QTest::keyClick(shell.window, key);
    QCoreApplication::processEvents();
}

void type(Shell &shell, const QString &text)
{
    for (const QChar character : text) {
        QTest::keyClick(shell.window, character.toLatin1());
    }
    QCoreApplication::processEvents();
}
}

class TestSearchScreen : public QObject
{
    Q_OBJECT

    // Loads the shipped module and lands on the search route with a scanned
    // fixture library, the remote on the field, as ContentView.swift:167-173
    // and SearchView.swift:162-166 leave it.
    [[nodiscard]] bool openSearch(Shell &shell)
    {
        AppPaths::setRuntimeRoot(shell.runtimeRoot.path());
        for (const QString &name : sampleTitles()) {
            if (!writeMediaFile(shell.library.path(), name)) {
                return false;
            }
        }
        shell.controller = std::make_unique<ApplicationController>();
        shell.controller->setStartFullscreen(false);
        shell.controller->setTemporaryLibraryRoot(shell.library.path());
        if (!QTest::qWaitFor([&] { return shell.controller->library()->rowCount() == 12; })) {
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
        shell.controller->navigation()->openRoute(NavigationController::Route::Search);
        return QTest::qWaitFor([&] {
            shell.screen = shell.window->findChild<QQuickItem *>(QStringLiteral("searchCommands"));
            return shell.screen != nullptr;
        }) && (shell.screen = shell.screen->parentItem()) != nullptr;
    }

private slots:
    void arrivesOnTheFieldWithTheLandingState()
    {
        Shell shell;
        QVERIFY(openSearch(shell));

        QTRY_COMPARE(remoteFocusOf(shell), QStringLiteral("field"));
        auto *field = shell.window->findChild<QQuickItem *>(QStringLiteral("searchField"));
        QVERIFY(field != nullptr);
        QTRY_VERIFY(field->hasActiveFocus());
        auto *landing = shell.window->findChild<QQuickItem *>(QStringLiteral("searchLanding"));
        QVERIFY(landing != nullptr && landing->isVisible());
        auto *placeholder =
            shell.window->findChild<QQuickItem *>(QStringLiteral("searchPlaceholder"));
        QVERIFY(placeholder != nullptr && placeholder->isVisible());
        QCOMPARE(placeholder->property("text").toString(),
                 QStringLiteral("Search movies, shows, cast..."));
        QVERIFY(!shell.window->findChild<QQuickItem *>(QStringLiteral("remoteSearchKeyboard"))
                     ->isVisible());
    }

    void typingShowsSuggestionsAndResultsForTheQuery()
    {
        Shell shell;
        QVERIFY(openSearch(shell));
        QTRY_COMPARE(remoteFocusOf(shell), QStringLiteral("field"));

        type(shell, QStringLiteral("al"));

        QCOMPARE(shell.controller->search()->query(), QStringLiteral("al"));
        auto *suggestions =
            shell.window->findChild<QQuickItem *>(QStringLiteral("searchSuggestions"));
        QTRY_VERIFY(suggestions->isVisible());
        // BrowseSnapshotStore.swift:964-980: every indexed title containing
        // "al" anywhere, in localized order.
        QCOMPARE(shell.controller->search()->suggestions(),
                 (QStringList{QStringLiteral("Alien"), QStringLiteral("Aliens"),
                              QStringLiteral("Arrival"), QStringLiteral("The Final Cut")}));
        auto *count = shell.window->findChild<QQuickItem *>(QStringLiteral("searchResultsCount"));
        QTRY_VERIFY(count->isVisible());
        QCOMPARE(count->property("text").toString(), QStringLiteral("4 results for 'al'"));
        QVERIFY(shell.window->findChild<QQuickItem *>(QStringLiteral("searchClearButton"))
                    ->isVisible());
        QVERIFY(!shell.window->findChild<QQuickItem *>(QStringLiteral("searchLanding"))
                     ->isVisible());
    }

    void downFromTheFieldWalksSuggestionsThenResults()
    {
        Shell shell;
        QVERIFY(openSearch(shell));
        QTRY_COMPARE(remoteFocusOf(shell), QStringLiteral("field"));
        type(shell, QStringLiteral("al"));
        QTRY_COMPARE(shell.controller->search()->suggestions().size(), 4);

        // RemoteSearchKeyboardPolicy.swift:148-152: Down with suggestions
        // enters them at the top.
        press(shell, Qt::Key_Down);
        QCOMPARE(remoteFocusOf(shell), QStringLiteral("suggestions"));
        QCOMPARE(shell.screen->property("suggestionIndex").toInt(), 0);

        // :202-204: Down past the last suggestion enters the results.
        press(shell, Qt::Key_Down);
        press(shell, Qt::Key_Down);
        press(shell, Qt::Key_Down);
        QCOMPARE(shell.screen->property("suggestionIndex").toInt(), 3);
        press(shell, Qt::Key_Down);
        QCOMPARE(remoteFocusOf(shell), QStringLiteral("results"));
        QCOMPARE(shell.screen->property("resultIndex").toInt(), 0);
        QVERIFY(!shell.window->findChild<QQuickItem *>(QStringLiteral("searchSuggestions"))
                     ->isVisible());

        // SearchView.swift:531-536: Back from results returns to the field
        // while no keyboard is up.
        press(shell, Qt::Key_Escape);
        QCOMPARE(remoteFocusOf(shell), QStringLiteral("field"));

        // :199-201: Up on the first suggestion returns to the field.
        press(shell, Qt::Key_Down);
        press(shell, Qt::Key_Up);
        QCOMPARE(remoteFocusOf(shell), QStringLiteral("field"));
    }

    void selectingASuggestionAppliesItAndFocusesResults()
    {
        Shell shell;
        QVERIFY(openSearch(shell));
        QTRY_COMPARE(remoteFocusOf(shell), QStringLiteral("field"));
        type(shell, QStringLiteral("al"));
        QTRY_COMPARE(shell.controller->search()->suggestions().size(), 4);

        press(shell, Qt::Key_Down);
        press(shell, Qt::Key_Down);
        press(shell, Qt::Key_Return);

        // RemoteSearchKeyboardPolicy.swift:205-206 and SearchView.swift:592-608.
        QCOMPARE(shell.controller->search()->query(), QStringLiteral("Aliens"));
        QCOMPARE(remoteFocusOf(shell), QStringLiteral("results"));
        QCOMPARE(shell.screen->property("resultIndex").toInt(), 0);
        QCOMPARE(shell.controller->search()->totalCount(), 1);
    }

    void selectOnTheFieldOpensTheRemoteKeyboardAndTypesWithIt()
    {
        Shell shell;
        QVERIFY(openSearch(shell));
        QTRY_COMPARE(remoteFocusOf(shell), QStringLiteral("field"));

        // RemoteSearchKeyboardPolicy.swift:153-154 and :62-64: Select opens the
        // keyboard on Q.
        press(shell, Qt::Key_Return);
        QCOMPARE(remoteFocusOf(shell), QStringLiteral("keyboard"));
        auto *keyboard =
            shell.window->findChild<QQuickItem *>(QStringLiteral("remoteSearchKeyboard"));
        QTRY_VERIFY(keyboard->isVisible());
        QCOMPARE(shell.screen->property("keyboardRow").toInt(), 1);
        QCOMPARE(shell.screen->property("keyboardColumn").toInt(), 0);

        // Q → W → E, then Down to A (column clamped), Select types "a".
        press(shell, Qt::Key_Right);
        press(shell, Qt::Key_Right);
        QCOMPARE(shell.screen->property("keyboardColumn").toInt(), 2);
        press(shell, Qt::Key_Down);
        QCOMPARE(shell.screen->property("keyboardRow").toInt(), 2);
        press(shell, Qt::Key_Left);
        press(shell, Qt::Key_Left);
        press(shell, Qt::Key_Return);
        QCOMPARE(shell.controller->search()->query(), QStringLiteral("a"));
        QCOMPARE(remoteFocusOf(shell), QStringLiteral("keyboard"));

        // :81-82: Left on the first column leaves for the sidebar.
        press(shell, Qt::Key_Left);
        QCOMPARE(remoteFocusOf(shell), QStringLiteral("inactive"));
        auto *sidebar = shell.window->findChild<QQuickItem *>(QStringLiteral("sidebar"));
        QTRY_VERIFY(sidebar->hasActiveFocus());
        // SearchView.swift:434: the keyboard leaves with the field's owner.
        QVERIFY(!keyboard->isVisible());
    }

    void doneOnTheKeyboardFocusesTheFirstResult()
    {
        Shell shell;
        QVERIFY(openSearch(shell));
        QTRY_COMPARE(remoteFocusOf(shell), QStringLiteral("field"));
        type(shell, QStringLiteral("heat"));
        QTRY_COMPARE(shell.controller->search()->totalCount(), 1);

        press(shell, Qt::Key_Return);
        QCOMPARE(remoteFocusOf(shell), QStringLiteral("keyboard"));
        // Down to the action row and Right to Done: Space, Delete, Clear, Done.
        press(shell, Qt::Key_Down);
        press(shell, Qt::Key_Down);
        press(shell, Qt::Key_Down);
        QCOMPARE(shell.screen->property("keyboardRow").toInt(), 4);
        press(shell, Qt::Key_Right);
        press(shell, Qt::Key_Right);
        press(shell, Qt::Key_Right);
        QCOMPARE(shell.screen->property("keyboardColumn").toInt(), 3);
        press(shell, Qt::Key_Return);

        // SearchView.swift:433-441.
        QCOMPARE(remoteFocusOf(shell), QStringLiteral("results"));
        QVERIFY(!shell.window->findChild<QQuickItem *>(QStringLiteral("remoteSearchKeyboard"))
                     ->isVisible());
        QCOMPARE(shell.controller->search()->query(), QStringLiteral("heat"));

        // :531-536: Back from results with no keyboard returns to the field.
        press(shell, Qt::Key_Escape);
        QCOMPARE(remoteFocusOf(shell), QStringLiteral("field"));
    }

    void resultsGridMovesAndOpensDetails()
    {
        Shell shell;
        QVERIFY(openSearch(shell));
        QTRY_COMPARE(remoteFocusOf(shell), QStringLiteral("field"));
        // A single character searches title prefixes: Nope alone starts
        // with "n", so a two-character substring query finds a full row.
        type(shell, QStringLiteral("en"));
        QTRY_VERIFY(shell.controller->search()->totalCount() >= 2);
        const int count = shell.controller->search()->totalCount();

        // RemoteSearchKeyboardFlowPolicy.fieldDestination :155-156: Right
        // from the field enters the first result.
        press(shell, Qt::Key_Right);
        QCOMPARE(remoteFocusOf(shell), QStringLiteral("results"));
        QCOMPARE(shell.screen->property("resultIndex").toInt(), 0);

        press(shell, Qt::Key_Right);
        QCOMPARE(shell.screen->property("resultIndex").toInt(), 1);
        // :331-336: Up on the first row leaves for the field.
        press(shell, Qt::Key_Up);
        QCOMPARE(remoteFocusOf(shell), QStringLiteral("field"));

        press(shell, Qt::Key_Right);
        // :331-336: Left on the first column leaves for the field too.
        press(shell, Qt::Key_Left);
        QCOMPARE(remoteFocusOf(shell), QStringLiteral("field"));

        press(shell, Qt::Key_Right);
        for (int i = 1; i < count; ++i) {
            press(shell, Qt::Key_Right);
        }
        // :289 and :335: Right on the last card holds still.
        QVERIFY(shell.screen->property("resultIndex").toInt() < count);
        const int last = shell.screen->property("resultIndex").toInt();
        press(shell, Qt::Key_Right);
        QCOMPARE(shell.screen->property("resultIndex").toInt(), last);

        // SearchView.swift:1041-1051: Select opens the focused title.
        const QString mediaId = shell.controller->search()->mediaIdAt(last);
        press(shell, Qt::Key_Return);
        QTRY_COMPARE(shell.controller->navigation()->route(), NavigationController::Route::Details);
        QCOMPARE(shell.controller->navigation()->selectedMediaId(), mediaId);
    }

    void aQueryWithNoMatchesShowsTheEmptyState()
    {
        Shell shell;
        QVERIFY(openSearch(shell));
        QTRY_COMPARE(remoteFocusOf(shell), QStringLiteral("field"));
        type(shell, QStringLiteral("zzzz"));

        auto *empty = shell.window->findChild<QQuickItem *>(QStringLiteral("searchEmptyState"));
        QTRY_VERIFY(empty->isVisible());
        QVERIFY(!shell.window->findChild<QQuickItem *>(QStringLiteral("searchResults"))
                     ->isVisible());

        // SearchView.swift:1315-1318.
        bool found = false;
        for (auto *text : empty->findChildren<QQuickItem *>()) {
            if (text->property("text").toString() == QStringLiteral("No results for 'zzzz'")) {
                found = true;
            }
        }
        QVERIFY(found);

        // :155-156: Right with nothing to enter falls back to the field.
        press(shell, Qt::Key_Right);
        QCOMPARE(remoteFocusOf(shell), QStringLiteral("field"));
    }

    void leftOrBackOnTheFieldHandsTheRemoteToTheSidebar()
    {
        Shell shell;
        QVERIFY(openSearch(shell));
        QTRY_COMPARE(remoteFocusOf(shell), QStringLiteral("field"));

        press(shell, Qt::Key_Left);
        QCOMPARE(remoteFocusOf(shell), QStringLiteral("inactive"));
        auto *sidebar = shell.window->findChild<QQuickItem *>(QStringLiteral("sidebar"));
        QTRY_VERIFY(sidebar->hasActiveFocus());

        // SearchView.swift:198-204: Right from the sidebar restores the field.
        press(shell, Qt::Key_Right);
        QTRY_COMPARE(remoteFocusOf(shell), QStringLiteral("field"));
        auto *field = shell.window->findChild<QQuickItem *>(QStringLiteral("searchField"));
        QTRY_VERIFY(field->hasActiveFocus());
    }
};

QTEST_MAIN(TestSearchScreen)
#include "tst_search_screen.moc"
