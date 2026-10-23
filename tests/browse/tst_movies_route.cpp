#include <algorithm>
#include <cmath>

#include <QAbstractItemModel>
#include <QColor>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QFont>
#include <QGuiApplication>
#include <QImage>
#include <QIODevice>
#include <QLatin1String>
#include <QList>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickItem>
#include <QQuickWindow>
#include <QRect>
#include <QScopeGuard>
#include <QStringList>
#include <QTemporaryDir>
#include <QTest>
#include <QVariant>
#include <QVector>

#include "app/AppPaths.hpp"
#include "app/ApplicationController.hpp"
#include "catalog/MediaItem.hpp"
#include "models/LibraryModel.hpp"
#include "models/MovieRowsModel.hpp"
#include "navigation/FocusNavigator.hpp"
#include "navigation/NavigationController.hpp"
#include "settings/SettingsStore.hpp"
#include "support/RenderProbe.hpp"

namespace
{
[[nodiscard]] bool writeMediaFile(const QString &root, const QString &relativePath)
{
    const QFileInfo target(QDir(root).filePath(relativePath));
    if (!QDir().mkpath(target.absolutePath())) {
        return false;
    }

    QFile file(target.absoluteFilePath());
    if (!file.open(QIODevice::WriteOnly)) {
        return false;
    }
    return file.write(QByteArrayLiteral("media")) == 5;
}

// Enough titles that the fixture window cannot show the whole row at once, so
// the row's own placement has somewhere to move.
[[nodiscard]] QStringList sampleTitles()
{
    return {QStringLiteral("Arrival.2016.mkv"),  QStringLiteral("Cobalt.2017.mkv"),
            QStringLiteral("Dune.2021.mkv"),     QStringLiteral("Eclipse.2023.mkv"),
            QStringLiteral("Flow.2024.mkv"),     QStringLiteral("Gravity.2013.mkv"),
            QStringLiteral("Heat.1995.mkv"),     QStringLiteral("Interstellar.2014.mkv"),
            QStringLiteral("Jaws.1975.mkv"),     QStringLiteral("Kestrel.2019.mkv"),
            QStringLiteral("Moon.2009.mkv"),     QStringLiteral("Nope.2022.mkv"),
            QStringLiteral("Prey.2022.mkv"),     QStringLiteral("Rushmore.1998.mkv"),
            QStringLiteral("Sicario.2015.mkv"),  QStringLiteral("Tenet.2020.mkv")};
}

// A projected movie built here rather than scanned, so the facts a row's order
// is composed from are stated by the test itself. The fixture titles carry no
// artwork, which is the poster suite's subject rather than this one's.
[[nodiscard]] MediaItem projectedMovie(const QString &title, int year)
{
    const QString relativePath = title + QStringLiteral(".mkv");
    return MediaItem{.id = QStringLiteral("root-1/") + title,
                     .libraryRootId = QStringLiteral("root-1"),
                     .relativePath = relativePath,
                     .absolutePath = QStringLiteral("/library/") + relativePath,
                     .title = title,
                     .sortTitle = title.toLower(),
                     .mediaKind = QStringLiteral("movie"),
                     .year = year,
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
                     .episodeStillAbsolutePath = QString()};
}

[[nodiscard]] QStringList titlesIn(const LibraryModel *items)
{
    QStringList titles;
    for (int row = 0; row < items->rowCount(); ++row) {
        titles.push_back(
            items->data(items->index(row, 0), LibraryModel::TitleRole).toString());
    }
    return titles;
}

// The row's items model, projected as the abstract model QML binds to.
[[nodiscard]] const LibraryModel *itemsOfRow(const MovieRowsModel &rows, int row)
{
    return qobject_cast<const LibraryModel *>(
        rows.data(rows.index(row, 0), MovieRowsModel::ItemsRole)
            .value<QAbstractItemModel *>());
}

// The row with `id`, or null when the composition holds none.
[[nodiscard]] const LibraryModel *rowWithId(const MovieRowsModel &rows, const QString &id)
{
    for (int row = 0; row < rows.rowCount(); ++row) {
        if (rows.data(rows.index(row, 0), MovieRowsModel::RowIdRole).toString() == id) {
            return itemsOfRow(rows, row);
        }
    }
    return nullptr;
}

[[nodiscard]] QStringList rowIdsOf(const MovieRowsModel &rows)
{
    QStringList ids;
    for (int row = 0; row < rows.rowCount(); ++row) {
        ids.push_back(rows.data(rows.index(row, 0), MovieRowsModel::RowIdRole).toString());
    }
    return ids;
}
}

class MoviesRouteTest final : public QObject
{
    Q_OBJECT

private:
    // Loads the shipped Marquee module linked into this binary so these tests
    // exercise the real Main.qml and its screens, not a replica.
    QQuickWindow *loadMainWindow(ApplicationController &controller,
                                 QQmlApplicationEngine &engine)
    {
        // A fullscreen window has no usable geometry on the test platform, and
        // a row with no width lays out no cards at all.
        controller.setStartFullscreen(false);

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

    [[nodiscard]] static QQuickItem *itemNamed(QQuickWindow *window, const char *name)
    {
        return window->findChild<QQuickItem *>(QLatin1String(name));
    }

    [[nodiscard]] static QString textOf(QQuickWindow *window, const char *name)
    {
        QQuickItem *item = itemNamed(window, name);
        return item == nullptr ? QString() : item->property("text").toString();
    }

    // Delegates hang off the view rather than the window's object tree, and the
    // view answers model changes once per frame, so it is asked to catch up
    // before it is asked for a delegate.
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

    // A QML-declared function answers through QVariant, not through the C++
    // type it happens to compute.
    [[nodiscard]] static QVariant callQml(QQuickItem *item, const char *name,
                                          QVariant argument = QVariant())
    {
        QVariant result;
        const bool called = argument.isValid()
            ? QMetaObject::invokeMethod(item, name, Q_RETURN_ARG(QVariant, result),
                                        Q_ARG(QVariant, argument))
            : QMetaObject::invokeMethod(item, name, Q_RETURN_ARG(QVariant, result));
        return called ? result : QVariant();
    }

    // A Repeater instantiates its delegates outside the window's QObject tree,
    // so a row is never reachable by findChild from the window and is asked of
    // the repeater that owns it instead, exactly as MoviesScreen.qml:220
    // addresses its own rows. The row is matched by the identity it composes
    // its objectName from rather than taken at an index, so a route that grows
    // a second row cannot silently answer with the wrong one.
    [[nodiscard]] static QQuickItem *movieRowNamed(QQuickWindow *window, const char *rowName)
    {
        QQuickItem *repeater = itemNamed(window, "movieRows");
        if (repeater == nullptr) {
            return nullptr;
        }
        const int count = repeater->property("count").toInt();
        for (int index = 0; index < count; ++index) {
            QQuickItem *row = nullptr;
            if (!QMetaObject::invokeMethod(repeater, "itemAt",
                                           Q_RETURN_ARG(QQuickItem *, row),
                                           Q_ARG(int, index))) {
                return nullptr;
            }
            // A delegate the repeater has not instantiated answers as null
            // rather than ending the search.
            if (row != nullptr && row->objectName() == QLatin1String(rowName)) {
                return row;
            }
        }
        return nullptr;
    }

    // The one row the v3 catalog composes, found through the shipped surface
    // rather than assumed at an index.
    [[nodiscard]] static QQuickItem *allMoviesRow(QQuickWindow *window)
    {
        QQuickItem *rowItem = movieRowNamed(window, "movieRow_all-movies");
        return rowItem == nullptr
            ? nullptr
            : rowItem->findChild<QQuickItem *>(QStringLiteral("movieRow"));
    }

    // A row's own header and viewport are declared inside the delegate, so they
    // are reachable from the row rather than from the window.
    [[nodiscard]] static QQuickItem *itemInAllMoviesRow(QQuickWindow *window, const char *name)
    {
        QQuickItem *rowItem = movieRowNamed(window, "movieRow_all-movies");
        return rowItem == nullptr
            ? nullptr
            : rowItem->findChild<QQuickItem *>(QLatin1String(name));
    }

    [[nodiscard]] static QString textInAllMoviesRow(QQuickWindow *window, const char *name)
    {
        QQuickItem *item = itemInAllMoviesRow(window, name);
        return item == nullptr ? QString() : item->property("text").toString();
    }

    [[nodiscard]] static int focusedIndexOf(QQuickWindow *window)
    {
        QQuickItem *rowItem = movieRowNamed(window, "movieRow_all-movies");
        return rowItem == nullptr ? -2 : rowItem->property("focusedIndex").toInt();
    }

    // Opens the Movies route on the controller's library, waits for its row to
    // lay out, and hands the remote from the sidebar to the route. The shell
    // starts with the sidebar focused, and its first Right is that hand-off
    // rather than a column move (qml/components/Sidebar.qml:163-166). The
    // caller owns the controller and engine so the scene outlives this setup,
    // and reports the window through `window`.
    void openMoviesRoute(ApplicationController &controller,
                         QQmlApplicationEngine &engine,
                         int expectedCount,
                         QQuickWindow *&window)
    {
        window = loadMainWindow(controller, engine);
        QVERIFY2(window != nullptr, "qml/Main.qml did not load from the module");
        controller.navigation()->openRoute(NavigationController::Route::Movies);
        // A window is exposed only once the platform has configured it, so the
        // row below has laid out at the size the platform granted.
        QVERIFY(QTest::qWaitForWindowExposed(window));

        QQuickItem *view = nullptr;
        QTRY_VERIFY((view = allMoviesRow(window)) != nullptr);
        QTRY_COMPARE(view->property("count").toInt(), expectedCount);

        QQuickItem *content = window->findChild<QQuickItem *>(QStringLiteral("contentFocus"));
        QVERIFY(content != nullptr);
        QTest::keyClick(window, Qt::Key_Right);
        QTRY_VERIFY(content->hasActiveFocus());
        // The hand-off itself does not move the remote's column.
        QCOMPARE(controller.movieRows()->focus()->column(), 0);
        QTRY_COMPARE(focusedIndexOf(window), 0);
    }

private slots:
    // The route's own composition, proved without a scene so a failure here is
    // never confused with a layout problem.

    // A library whose titles name no genre composes the single "All Movies"
    // row: BrowseSnapshotStore.swift:3030-3044 drops the "Other" group.
    void titlesWithNoGenreComposeOneAllMoviesRow()
    {
        MovieRowsModel rows;
        rows.replaceItems({projectedMovie(QStringLiteral("Arrival"), 2016),
                           projectedMovie(QStringLiteral("Moon"), 2009)});

        QCOMPARE(rows.rowCount(), 1);
        QCOMPARE(rows.data(rows.index(0, 0), MovieRowsModel::RowIdRole).toString(),
                 QStringLiteral("all-movies"));
        QCOMPARE(rows.data(rows.index(0, 0), MovieRowsModel::RowTitleRole).toString(),
                 QStringLiteral("All Movies"));
        QCOMPARE(rows.data(rows.index(0, 0), MovieRowsModel::ItemCountRole).toInt(), 2);
        QCOMPARE(rows.titleCount(), 2);
    }

    // BrowseSnapshotStore.swift:2087-2098 recognizes a holiday film from its
    // title alone, and :3022-3028 composes that row before the genre rows and
    // All Movies once at least two titles qualify. Elf and Home Alone also
    // infer the Comedy and Holiday genres offline, so they get those rows too
    // (:3030-3044), between Holiday Movies and All Movies.
    void holidayTitlesComposeTheirOwnRowAheadOfTheGenreRowsAndAllMovies()
    {
        MovieRowsModel rows;
        rows.replaceItems({projectedMovie(QStringLiteral("Arrival"), 2016),
                           projectedMovie(QStringLiteral("Home Alone"), 1990),
                           projectedMovie(QStringLiteral("Elf"), 2003)});

        // :3027 and :3046 fix the order of the rows; the genre rows sort
        // case-insensitively.
        QCOMPARE(rowIdsOf(rows),
                 (QStringList{QStringLiteral("holiday-movies"), QStringLiteral("genre-Comedy"),
                              QStringLiteral("genre-Holiday"), QStringLiteral("all-movies")}));
        QCOMPARE(rows.data(rows.index(0, 0), MovieRowsModel::RowTitleRole).toString(),
                 QStringLiteral("Holiday Movies"));
        QCOMPARE(rows.data(rows.index(3, 0), MovieRowsModel::RowTitleRole).toString(),
                 QStringLiteral("All Movies"));

        QCOMPARE(rows.data(rows.index(0, 0), MovieRowsModel::ItemCountRole).toInt(), 2);
        QCOMPARE(rows.data(rows.index(3, 0), MovieRowsModel::ItemCountRole).toInt(), 3);
        // The count the surface's own heading answers is still every movie the
        // library holds, not the sum of the rows.
        QCOMPARE(rows.titleCount(), 3);

        const auto *holiday = rowWithId(rows, QStringLiteral("holiday-movies"));
        const auto *all = rowWithId(rows, QStringLiteral("all-movies"));
        QVERIFY(holiday != nullptr);
        QVERIFY(all != nullptr);
        // Both infer the Holiday genre offline (CatalogContentPolicy.swift
        // :400-476), which :2077 puts in the haystack, so both score 100 and the
        // row keeps browse order between them: "elf" sorts before "home alone".
        QCOMPARE(titlesIn(holiday),
                 (QStringList{QStringLiteral("Elf"), QStringLiteral("Home Alone")}));
        // :3020 and :3046 build All Movies from every movie, so a holiday
        // title is shown in both rows rather than moved out of this one.
        QCOMPARE(titlesIn(all),
                 (QStringList{QStringLiteral("Arrival"), QStringLiteral("Elf"),
                              QStringLiteral("Home Alone")}));

        // The remote addresses each row, and each answers with its own card.
        QCOMPARE(rows.mediaIdAt(0, 0), QStringLiteral("root-1/Elf"));
        QCOMPARE(rows.mediaIdAt(3, 0), QStringLiteral("root-1/Arrival"));
        QVERIFY(rows.mediaIdAt(0, 2).isEmpty());
    }

    // :2079-2085 scores a keyword title above a named one (Scrooged has no
    // holiday genre, so only :2087-2098 recognizes it), and :2066-2068 puts the
    // stronger signal first in the row.
    void aKeywordHolidayTitleIsPlacedAheadOfANamedHolidayFilm()
    {
        MovieRowsModel rows;
        rows.replaceItems({projectedMovie(QStringLiteral("Scrooged"), 1988),
                           projectedMovie(QStringLiteral("The Santa Clause"), 1994)});

        const auto *holiday = rowWithId(rows, QStringLiteral("holiday-movies"));
        QVERIFY(holiday != nullptr);
        QCOMPARE(titlesIn(holiday),
                 (QStringList{QStringLiteral("The Santa Clause"),
                              QStringLiteral("Scrooged")}));
    }

    // :3026 composes the row only once at least two titles qualify, so one
    // holiday title on its own gets no Holiday Movies row.
    void oneQualifyingTitleComposesNoHolidayRow()
    {
        MovieRowsModel rows;
        rows.replaceItems({projectedMovie(QStringLiteral("Arrival"), 2016),
                           projectedMovie(QStringLiteral("Elf"), 2003)});

        QVERIFY(rowWithId(rows, QStringLiteral("holiday-movies")) == nullptr);
        QCOMPARE(rows.data(rows.index(rows.rowCount() - 1, 0), MovieRowsModel::RowIdRole)
                     .toString(),
                 QStringLiteral("all-movies"));
    }

    // :2096 matches a named holiday film by containment rather than by whole
    // tokens, which is what lets "Nightmare Before Christmas" match inside the
    // full released title. That same rule reaches a title that merely spells
    // one of those names inside a longer word, and this pins the released
    // behavior rather than quietly improving on it: "Self Reliance" holds
    // "elf" and qualifies, while a title that holds none of the names does
    // not.
    void holidayNamesAreMatchedByContainmentExactlyAsTheReleasedClassifierDoes()
    {
        MovieRowsModel rows;
        rows.replaceItems({projectedMovie(QStringLiteral("Elf"), 2003),
                           projectedMovie(QStringLiteral("Home Alone"), 1990),
                           projectedMovie(QStringLiteral("Self Reliance"), 2023),
                           projectedMovie(QStringLiteral("The Elephant Man"), 1980)});

        const auto *holiday = rowWithId(rows, QStringLiteral("holiday-movies"));
        QVERIFY(holiday != nullptr);
        QCOMPARE(titlesIn(holiday),
                 (QStringList{QStringLiteral("Elf"), QStringLiteral("Home Alone"),
                              QStringLiteral("Self Reliance")}));

        // "The Elephant Man" spells none of the names and stays out of the
        // row while remaining in All Movies.
        const auto *all = rowWithId(rows, QStringLiteral("all-movies"));
        QVERIFY(all != nullptr);
        QVERIFY(titlesIn(all).contains(QStringLiteral("The Elephant Man")));
        QVERIFY(!titlesIn(holiday).contains(QStringLiteral("The Elephant Man")));
    }

    // BrowseSnapshotStore.swift:3008-3048 orders a movie row by franchise
    // family, then year, then title: a sequel follows its predecessor whatever
    // the alphabet says, and an unrelated title between them alphabetically
    // does not split the pair.
    void moviesAreOrderedByFranchiseThenYearThenTitle()
    {
        MovieRowsModel rows;
        rows.replaceItems({projectedMovie(QStringLiteral("Batman Begins"), 2005),
                           projectedMovie(QStringLiteral("Arrival"), 2016),
                           projectedMovie(QStringLiteral("The Dark Knight"), 2008),
                           projectedMovie(QStringLiteral("Cobalt"), 2017)});

        const auto *items = itemsOfRow(rows, 0);
        QVERIFY(items != nullptr);
        QCOMPARE(titlesIn(items),
                 (QStringList{QStringLiteral("Arrival"),
                              // Both Batman titles share the "batman" family
                              // from BrowseSnapshotStore.swift:1842-1843, so
                              // the 2005 film precedes the 2008 one and Cobalt
                              // does not fall between them.
                              QStringLiteral("Batman Begins"),
                              QStringLiteral("The Dark Knight"),
                              QStringLiteral("Cobalt")}));
    }

    // BrowseSnapshotStore.swift:2038-2040 sorts a title with no year after its
    // dated siblings rather than before them.
    void aMovieWithNoYearSortsAfterItsDatedSiblings()
    {
        MovieRowsModel rows;
        rows.replaceItems({projectedMovie(QStringLiteral("Avengers Endgame"), 0),
                           projectedMovie(QStringLiteral("Avengers Infinity War"), 2018)});

        const auto *items = itemsOfRow(rows, 0);
        QVERIFY(items != nullptr);
        QCOMPARE(titlesIn(items),
                 (QStringList{QStringLiteral("Avengers Infinity War"),
                              QStringLiteral("Avengers Endgame")}));
    }

    void anEmptyLibraryComposesNoRowsAndCountsNoTitles()
    {
        MovieRowsModel rows;
        rows.replaceItems({projectedMovie(QStringLiteral("Arrival"), 2016)});
        QCOMPARE(rows.rowCount(), 1);

        rows.replaceItems({});

        QCOMPARE(rows.rowCount(), 0);
        QCOMPARE(rows.titleCount(), 0);
        QVERIFY(rows.mediaIdAt(0, 0).isEmpty());
        QVERIFY(rows.focus()->empty());
    }

    // MoviesDetailView.swift:401-419 clamps the remote onto a card that still
    // exists whenever the composition changes under it.
    void aShorterRescanClampsTheRemoteOntoACardThatStillExists()
    {
        MovieRowsModel rows;
        rows.replaceItems({projectedMovie(QStringLiteral("Arrival"), 2016),
                           projectedMovie(QStringLiteral("Cobalt"), 2017),
                           projectedMovie(QStringLiteral("Dune"), 2021)});
        rows.focus()->setPosition(0, 2);
        QCOMPARE(rows.focus()->column(), 2);
        QCOMPARE(rows.mediaIdAt(0, 2), QStringLiteral("root-1/Dune"));

        rows.replaceItems({projectedMovie(QStringLiteral("Arrival"), 2016)});

        QCOMPARE(rows.focus()->column(), 0);
        QCOMPARE(rows.mediaIdAt(0, 0), QStringLiteral("root-1/Arrival"));
        QVERIFY(rows.mediaIdAt(0, 2).isEmpty());
    }

    void mediaIdRefusesAPositionTheCompositionDoesNotHold()
    {
        MovieRowsModel rows;
        rows.replaceItems({projectedMovie(QStringLiteral("Arrival"), 2016)});

        QCOMPARE(rows.mediaIdAt(0, 0), QStringLiteral("root-1/Arrival"));
        QVERIFY(rows.mediaIdAt(-1, 0).isEmpty());
        QVERIFY(rows.mediaIdAt(0, -1).isEmpty());
        QVERIFY(rows.mediaIdAt(1, 0).isEmpty());
        QVERIFY(rows.mediaIdAt(0, 1).isEmpty());
    }

    // A card's runtime is projected the same way in a row as it is in the
    // library grid, so a title played from Movies refreshes where it is shown.
    void aRecordedRuntimeReachesTheCardInsideItsRow()
    {
        MovieRowsModel rows;
        rows.replaceItems({projectedMovie(QStringLiteral("Arrival"), 2016)});

        const auto *items = itemsOfRow(rows, 0);
        QVERIFY(items != nullptr);
        QCOMPARE(items->data(items->index(0, 0), LibraryModel::MetadataRole).toString(),
                 QStringLiteral("2016"));

        rows.applyWatchProgress(QStringLiteral("root-1/Arrival"), 60'000, 6'960'000, 1);

        QCOMPARE(items->data(items->index(0, 0), LibraryModel::MetadataRole).toString(),
                 QStringLiteral("2016 1h 56m"));
    }

    // The shipped surface itself.

    // MoviesDetailView.swift:101-211 is the Movies route; ContentView.swift:259
    // routes to it. The v3 shell used to fall through to a rewrite-status
    // screen with no released counterpart.
    void theMoviesRouteShowsTheLibraryRatherThanTheRewriteStatusScreen()
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
        QQuickWindow *window = nullptr;
        openMoviesRoute(controller, engine, 16, window);
        QVERIFY2(window != nullptr, "the Movies route did not lay out its row");

        QCOMPARE(textOf(window, "moviesHeading"), QStringLiteral("Movies"));
        // The Welcome screen's status capsule has no released counterpart and
        // must no longer be what this route shows.
        QVERIFY(window->findChild<QQuickItem *>(QStringLiteral("movieRows")) != nullptr);
        QCOMPARE(controller.navigation()->route(), NavigationController::Route::Movies);
    }

    // MoviesDetailView.swift:113-117 counts every movie the library holds, and
    // MovieCard.swift:380-382 counts the row's own length in its header.
    void theHeadingAndRowHeaderCountTheTitlesTheySpeakFor()
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
        QQuickWindow *window = nullptr;
        openMoviesRoute(controller, engine, 16, window);
        QVERIFY2(window != nullptr, "the Movies route did not lay out its row");

        QCOMPARE(textOf(window, "moviesTitleCount"), QStringLiteral("16 titles"));
        QCOMPARE(textInAllMoviesRow(window, "movieRowTitle"), QStringLiteral("All Movies"));
        QCOMPARE(textInAllMoviesRow(window, "movieRowCount"), QStringLiteral("16 titles"));

        QQuickItem *count = itemNamed(window, "moviesTitleCount");
        QVERIFY(count != nullptr);
        QVERIFY(count->isVisible());
    }

    // The count is a singular "1 title" for one movie, as both headers are.
    void oneMovieIsCountedInTheSingular()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        QTemporaryDir library;
        QVERIFY(writeMediaFile(library.path(), QStringLiteral("Arrival.2016.mkv")));

        ApplicationController controller;
        controller.setTemporaryLibraryRoot(library.path());
        QTRY_COMPARE(controller.library()->rowCount(), 1);

        QQmlApplicationEngine engine;
        QQuickWindow *window = nullptr;
        openMoviesRoute(controller, engine, 1, window);
        QVERIFY2(window != nullptr, "the Movies route did not lay out its row");

        QCOMPARE(textOf(window, "moviesTitleCount"), QStringLiteral("1 title"));
        QCOMPARE(textInAllMoviesRow(window, "movieRowCount"), QStringLiteral("1 title"));
    }

    // MoviesDetailView.swift:121-122 and :215-229: an empty library explains
    // itself and names the folder being scanned instead of showing the count
    // and an empty row.
    void anEmptyLibraryShowsTheNoMoviesFoundStateNamingTheScannedFolder()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        QTemporaryDir library;

        ApplicationController controller;
        controller.settings()->setLibraryRoots({library.path()});
        QTRY_COMPARE(controller.library()->rowCount(), 0);

        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY2(window != nullptr, "qml/Main.qml did not load from the module");
        controller.navigation()->openRoute(NavigationController::Route::Movies);
        QVERIFY(QTest::qWaitForWindowExposed(window));

        QQuickItem *empty = nullptr;
        QTRY_VERIFY((empty = itemNamed(window, "moviesEmptyState")) != nullptr);
        QTRY_VERIFY(empty->isVisible());
        QCOMPARE(textOf(window, "moviesEmptyTitle"), QStringLiteral("No movies found"));
        QCOMPARE(textOf(window, "moviesEmptyDetail"),
                 QStringLiteral("Scanning %1").arg(library.path()));

        // The count says nothing when there is nothing to count, and the rows
        // are not shown behind the empty state. MoviesDetailView.swift:121-136
        // puts the empty state where the rows would have gone inside the same
        // scrolled stack, so the page itself stays and it is the composition
        // that holds no row to draw.
        QQuickItem *count = itemNamed(window, "moviesTitleCount");
        QVERIFY(count != nullptr);
        QVERIFY(!count->isVisible());
        QQuickItem *scroll = itemNamed(window, "moviesScroll");
        QVERIFY(scroll != nullptr);
        QVERIFY(scroll->isVisible());
        QQuickItem *rowRepeater = itemNamed(window, "movieRows");
        QVERIFY(rowRepeater != nullptr);
        QCOMPARE(rowRepeater->property("count").toInt(), 0);
    }

    // With no configured root at all the released empty state still names a
    // folder rather than an empty string.
    void anUnconfiguredLibraryNamesTheDefaultMoviesFolder()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        ApplicationController controller;
        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY2(window != nullptr, "qml/Main.qml did not load from the module");
        controller.navigation()->openRoute(NavigationController::Route::Movies);
        QVERIFY(QTest::qWaitForWindowExposed(window));

        QQuickItem *empty = nullptr;
        QTRY_VERIFY((empty = itemNamed(window, "moviesEmptyState")) != nullptr);
        QTRY_VERIFY(empty->isVisible());
        QCOMPARE(textOf(window, "moviesEmptyDetail"), QStringLiteral("Scanning ~/Movies"));
    }

    // MoviesDetailView.swift:107-119 and MovieCard.swift:366-383 fix the
    // route's compact and lean-back geometry and type. Both modes are checked
    // because every one of these values differs between them.
    void moviesGeometryAndTypographyMatchTheReleasedSurface_data()
    {
        QTest::addColumn<bool>("leanBack");
        QTest::addColumn<int>("outerPadding");
        QTest::addColumn<int>("headingSize");
        QTest::addColumn<int>("countSize");
        QTest::addColumn<int>("rowTitleSize");
        QTest::addColumn<int>("rowCountSize");
        QTest::addColumn<int>("rowSpacing");
        QTest::addColumn<int>("headerTopMargin");

        QTest::newRow("compact") << false << 48 << 28 << 13 << 20 << 12 << 36 << 28;
        QTest::newRow("lean-back") << true << 72 << 40 << 18 << 28 << 16 << 54 << 44;
    }

    void moviesGeometryAndTypographyMatchTheReleasedSurface()
    {
        QFETCH(bool, leanBack);
        QFETCH(int, outerPadding);
        QFETCH(int, headingSize);
        QFETCH(int, countSize);
        QFETCH(int, rowTitleSize);
        QFETCH(int, rowCountSize);
        QFETCH(int, rowSpacing);
        QFETCH(int, headerTopMargin);

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
        QQuickWindow *window = nullptr;
        openMoviesRoute(controller, engine, 16, window);
        QVERIFY2(window != nullptr, "the Movies route did not lay out its row");

        QQuickItem *heading = itemNamed(window, "moviesHeading");
        QQuickItem *count = itemNamed(window, "moviesTitleCount");
        QQuickItem *rowTitle = itemInAllMoviesRow(window, "movieRowTitle");
        QQuickItem *rowCount = itemInAllMoviesRow(window, "movieRowCount");
        QVERIFY(heading != nullptr);
        QVERIFY(count != nullptr);
        QVERIFY(rowTitle != nullptr);
        QVERIFY(rowCount != nullptr);

        QCOMPARE(heading->property("font").value<QFont>().pixelSize(), headingSize);
        QCOMPARE(count->property("font").value<QFont>().pixelSize(), countSize);
        QCOMPARE(rowTitle->property("font").value<QFont>().pixelSize(), rowTitleSize);
        QCOMPARE(rowCount->property("font").value<QFont>().pixelSize(), rowCountSize);

        // The heading sits an outer padding in from the window's content edge,
        // measured in the scene rather than read back from the binding.
        QQuickItem *content = window->contentItem();
        QQuickItem *sidebar = itemNamed(window, "sidebar");
        QVERIFY(sidebar != nullptr);
        const QRectF headingRect = heading->mapRectToItem(content, heading->boundingRect());
        const QRectF sidebarRect = sidebar->mapRectToItem(content, sidebar->boundingRect());
        QCOMPARE(qRound(headingRect.left() - sidebarRect.right()), outerPadding);
        QCOMPARE(qRound(headingRect.top()), headerTopMargin);

        // The count shares the heading's first text baseline rather than its
        // own box top, so a smaller face does not ride up.
        QCOMPARE(qRound(count->property("baselineOffset").toReal() + count->y()),
                 qRound(heading->property("baselineOffset").toReal() + heading->y()));

        // MovieCard.swift:375 spaces a row's header 12 points from its cards.
        QQuickItem *rowItem = movieRowNamed(window, "movieRow_all-movies");
        QVERIFY2(rowItem != nullptr, "the Movies route composed no all-movies row");
        QQuickItem *viewport = rowItem->findChild<QQuickItem *>(QStringLiteral("movieRowViewport"));
        QVERIFY(viewport != nullptr);
        QCOMPARE(qRound(viewport->y() - (rowTitle->y() + rowTitle->height())), 12);

        // MoviesDetailView.swift:107 separates the rows, and the heading from
        // the first row, by the same scaled spacing inside the one stack that
        // :105-144 scrolls. It is measured between the drawn heading and the
        // drawn row rather than against a container edge, because the heading
        // is a member of that stack rather than a header fixed above it.
        const QRectF rowRect = rowItem->mapRectToItem(content, rowItem->boundingRect());
        QCOMPARE(qRound(rowRect.top() - headingRect.bottom()), rowSpacing);
    }

    // ArrowedScrollRow.swift:75-87 lets a card at either end of a row paint its
    // focus halo into the page's outer padding instead of being cut at the
    // row's boundary.
    void aRowsViewportReachesIntoTheOuterPaddingByTheHaloPadding()
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
        controller.setTemporaryLibraryRoot(library.path());
        QTRY_COMPARE(controller.library()->rowCount(), 16);

        QQmlApplicationEngine engine;
        QQuickWindow *window = nullptr;
        openMoviesRoute(controller, engine, 16, window);
        QVERIFY2(window != nullptr, "the Movies route did not lay out its row");

        QQuickItem *rowItem = movieRowNamed(window, "movieRow_all-movies");
        QVERIFY2(rowItem != nullptr, "the Movies route composed no all-movies row");
        QQuickItem *viewport = rowItem->findChild<QQuickItem *>(QStringLiteral("movieRowViewport"));
        QQuickItem *view = allMoviesRow(window);
        QVERIFY(viewport != nullptr);
        QVERIFY(view != nullptr);

        // The compact halo padding from MarqueeTheme.swift:230-232.
        QCOMPARE(qRound(viewport->x()), -36);
        QCOMPARE(qRound(viewport->width() - rowItem->width()), 72);
        // The content still starts where the row's own left edge is, so the
        // cards are not shifted into that reach.
        QCOMPARE(qRound(view->property("leftMargin").toReal()), 36);
        // MovieCard.swift:373 pitches the cards by artwork width plus the
        // released 10-point compact gap.
        QCOMPARE(qRound(view->property("spacing").toReal()), 10);

        QQuickItem *first = cardAt(view, 0);
        QVERIFY(first != nullptr);
        QCOMPARE(qRound(first->width()), 150);
    }

    // MoviesDetailView.swift:485-497 moves one clamped selection along the row
    // and stops at its end rather than wrapping.
    void arrowKeysMoveAlongTheRowAndStopAtItsEnd()
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
        QQuickWindow *window = nullptr;
        openMoviesRoute(controller, engine, 16, window);
        QVERIFY2(window != nullptr, "the Movies route did not lay out its row");

        FocusNavigator *focus = controller.movieRows()->focus();
        QTest::keyClick(window, Qt::Key_Right);
        QTRY_COMPARE(focus->column(), 1);
        QCOMPARE(focus->row(), 0);

        QTest::keyClick(window, Qt::Key_Left);
        QCOMPARE(focus->column(), 0);

        // One row means Up and Down have nowhere to go and must not drift
        // along the row instead.
        QTest::keyClick(window, Qt::Key_Right);
        QCOMPARE(focus->column(), 1);
        QTest::keyClick(window, Qt::Key_Down);
        QCOMPARE(focus->row(), 0);
        QCOMPARE(focus->column(), 1);
        QTest::keyClick(window, Qt::Key_Up);
        QCOMPARE(focus->row(), 0);
        QCOMPARE(focus->column(), 1);

        // Right stops at the last card rather than wrapping to the first.
        for (int step = 0; step < 20; ++step) {
            QTest::keyClick(window, Qt::Key_Right);
        }
        QCOMPARE(focus->column(), 15);
        QCOMPARE(focusedIndexOf(window), 15);
    }

    // MoviesDetailView.swift:498-500 hands a Left at the first column back to
    // the sidebar, and the surface clears its card focus as it leaves.
    void leftAtTheFirstColumnReturnsFocusToTheSidebarAndClearsCardFocus()
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
        QQuickWindow *window = nullptr;
        openMoviesRoute(controller, engine, 16, window);
        QVERIFY2(window != nullptr, "the Movies route did not lay out its row");

        QQuickItem *sidebar = itemNamed(window, "sidebar");
        QQuickItem *view = allMoviesRow(window);
        QVERIFY(sidebar != nullptr);
        QVERIFY(view != nullptr);

        QTest::keyClick(window, Qt::Key_Right);
        QTRY_COMPARE(controller.movieRows()->focus()->column(), 1);
        QCOMPARE(focusedIndexOf(window), 1);

        // Inside the row, Left belongs to the row.
        QTest::keyClick(window, Qt::Key_Left);
        QCOMPARE(controller.movieRows()->focus()->column(), 0);
        QVERIFY(!sidebar->hasActiveFocus());

        // At the first column it belongs to the sidebar, and the card that had
        // focus stops showing it.
        QTest::keyClick(window, Qt::Key_Left);
        QTRY_VERIFY(sidebar->hasActiveFocus());
        QTRY_COMPARE(focusedIndexOf(window), -1);
        QQuickItem *card = cardAt(view, 0);
        QVERIFY(card != nullptr);
        QVERIFY(!card->property("selected").toBool());
        // Leaving the surface does not move the remote's remembered column.
        QCOMPARE(controller.movieRows()->focus()->column(), 0);
    }

    // MoviesDetailView.swift:478-480 answers Back at the route's root by
    // returning the remote to the sidebar rather than leaving the route.
    void backAtTheRouteRootReturnsToTheSidebarWithoutLeavingMovies()
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
        QQuickWindow *window = nullptr;
        openMoviesRoute(controller, engine, 16, window);
        QVERIFY2(window != nullptr, "the Movies route did not lay out its row");

        QQuickItem *sidebar = itemNamed(window, "sidebar");
        QVERIFY(sidebar != nullptr);
        QTest::keyClick(window, Qt::Key_Right);
        QTRY_COMPARE(controller.movieRows()->focus()->column(), 1);

        QTest::keyClick(window, Qt::Key_Escape);

        QTRY_VERIFY(sidebar->hasActiveFocus());
        QCOMPARE(controller.navigation()->route(), NavigationController::Route::Movies);

        // A second Back, now owned by the sidebar, is the shell's history back.
        QTest::keyClick(window, Qt::Key_Back);
        QTRY_VERIFY(controller.navigation()->route() != NavigationController::Route::Movies);
    }

    // MoviesDetailView.swift:481-484 opens the focused title's details, by the
    // identity the focused card is showing.
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
        QQuickWindow *window = nullptr;
        openMoviesRoute(controller, engine, 16, window);
        QVERIFY2(window != nullptr, "the Movies route did not lay out its row");

        QTest::keyClick(window, Qt::Key_Right);
        QTRY_COMPARE(controller.movieRows()->focus()->column(), 1);

        // The catalog entry the second card is showing, read before it is
        // opened so the assertions below cannot be satisfied by another row.
        const QString expectedId = controller.movieRows()->mediaIdAt(0, 1);
        QVERIFY(!expectedId.isEmpty());
        const std::optional<MediaItem> expected = controller.library()->itemForId(expectedId);
        QVERIFY(expected.has_value());
        QCOMPARE(expected->title, QStringLiteral("Cobalt"));

        QTest::keyClick(window, Qt::Key_Return);

        QTRY_COMPARE(controller.navigation()->route(), NavigationController::Route::Details);
        QCOMPARE(controller.navigation()->selectedMediaId(), expectedId);
        // Activating a card describes the title rather than starting it.
        QVERIFY(controller.player()->currentFileUrl().isEmpty());
        QVERIFY2(!controller.hasError(), qPrintable(controller.errorMessage()));
    }

    void tappingACardOpensThatCardsTitleRatherThanTheFocusedOne()
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
        QQuickWindow *window = nullptr;
        openMoviesRoute(controller, engine, 16, window);
        QVERIFY2(window != nullptr, "the Movies route did not lay out its row");

        QQuickItem *view = allMoviesRow(window);
        QVERIFY(view != nullptr);
        QCOMPARE(controller.movieRows()->focus()->column(), 0);

        QQuickItem *card = cardAt(view, 2);
        QVERIFY(card != nullptr);
        const QString expectedId = controller.movieRows()->mediaIdAt(0, 2);
        QVERIFY(!expectedId.isEmpty());

        const QPointF centre =
            card->mapToScene(QPointF(card->width() / 2, card->height() / 2));
        QTest::mouseClick(window, Qt::LeftButton, Qt::NoModifier, centre.toPoint());

        // Opening the details destroys the row and its delegates, so the
        // identity that opened is what proves the tapped card won.
        QTRY_COMPARE(controller.navigation()->route(), NavigationController::Route::Details);
        QCOMPARE(controller.navigation()->selectedMediaId(), expectedId);
        QVERIFY2(!controller.hasError(), qPrintable(controller.errorMessage()));
    }

    // RemoteGridFocus.swift:2422-2463 keeps the focused card visible by
    // stepping the row, and stops once the row has no more content to show.
    void movingAlongTheRowScrollsItAndStopsAtItsLastReachableStep()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        QTemporaryDir library;
        for (const QString &name : sampleTitles()) {
            QVERIFY(writeMediaFile(library.path(), name));
        }

        ApplicationController controller;
        // Reduce Motion places the row at once, so the assertions below read a
        // settled offset rather than a spring still in flight.
        controller.settings()->setReduceMotion(true);
        controller.settings()->setLeanBackMode(false);
        controller.setTemporaryLibraryRoot(library.path());
        QTRY_COMPARE(controller.library()->rowCount(), 16);

        QQmlApplicationEngine engine;
        QQuickWindow *window = nullptr;
        openMoviesRoute(controller, engine, 16, window);
        QVERIFY2(window != nullptr, "the Movies route did not lay out its row");

        QQuickItem *view = allMoviesRow(window);
        QQuickItem *rowItem = movieRowNamed(window, "movieRow_all-movies");
        QVERIFY(view != nullptr);
        QVERIFY(rowItem != nullptr);

        const QVariant slotCount = callQml(rowItem, "visibleSlotCount");
        QVERIFY(slotCount.isValid());
        const int visibleSlots = slotCount.toInt();
        QVERIFY2(visibleSlots >= 2, "the fixture window must show more than one card");
        QVERIFY2(visibleSlots < 16, "the fixture row must be longer than its viewport");

        // The row holds still until the focused card would leave the visible
        // slots; RemoteGridFocus.swift:2459-2462 starts stepping one past the
        // centre slot.
        QCOMPARE(qRound(view->property("contentX").toReal()),
                 -qRound(view->property("leftMargin").toReal()));

        for (int step = 0; step < 20; ++step) {
            QTest::keyClick(window, Qt::Key_Right);
        }
        QTRY_COMPARE(controller.movieRows()->focus()->column(), 15);

        // 150-point cards with a 10-point gap: the last reachable step is the
        // count past the viewport's slots.
        const qreal stride = 160;
        const qreal expected = (16 - visibleSlots) * stride
            - view->property("leftMargin").toReal();
        QTRY_COMPARE(qRound(view->property("contentX").toReal()), qRound(expected));
    }

    // ArrowedScrollRow.swift:120-125 takes the row's placement again whenever
    // its viewport changes, which the shipped row answered only on a focus or
    // count change. A row focused on a late card and then narrowed kept the
    // offset the wide viewport asked for and clipped that card, and at the
    // row's end another Right cannot repair it: the clamped selection does not
    // move, so nothing takes the placement again.
    void narrowingTheWindowReplacesTheFocusedCardsPlacementRatherThanClippingIt()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        QTemporaryDir library;
        for (const QString &name : sampleTitles()) {
            QVERIFY(writeMediaFile(library.path(), name));
        }

        ApplicationController controller;
        // Reduce Motion settles the offset in the same turn, so the assertions
        // below read a placement rather than a spring still in flight.
        controller.settings()->setReduceMotion(true);
        controller.settings()->setLeanBackMode(false);
        controller.setTemporaryLibraryRoot(library.path());
        QTRY_COMPARE(controller.library()->rowCount(), 16);

        QQmlApplicationEngine engine;
        QQuickWindow *window = nullptr;
        openMoviesRoute(controller, engine, 16, window);
        QVERIFY2(window != nullptr, "the Movies route did not lay out its row");

        QQuickItem *view = allMoviesRow(window);
        QQuickItem *rowItem = movieRowNamed(window, "movieRow_all-movies");
        QVERIFY(view != nullptr);
        QVERIFY2(rowItem != nullptr, "the Movies route composed no all-movies row");
        QQuickItem *viewport =
            rowItem->findChild<QQuickItem *>(QStringLiteral("movieRowViewport"));
        QVERIFY(viewport != nullptr);

        // The released compact geometry, restated here rather than read back
        // from the row, so the expectations below do not agree with a wrong
        // placement merely because it was computed the same wrong way.
        // MovieCard.swift:373 and MarqueeTheme.swift:230-232.
        constexpr qreal cardWidth = 150;
        constexpr qreal cardGap = 10;
        constexpr qreal halo = 36;
        constexpr qreal stride = cardWidth + cardGap;
        constexpr int count = 16;
        QCOMPARE(qRound(view->property("leftMargin").toReal()), qRound(halo));
        QCOMPARE(qRound(view->property("spacing").toReal()), qRound(cardGap));

        // RemoteGridFocus.swift:2508-2524 counts the whole slots the viewport
        // holds once both insets are removed, reasoned here from the released
        // constants instead of by asking the row under test.
        const auto slotsIn = [](qreal viewportWidth) {
            const qreal usable = std::max(qreal(0), viewportWidth - 2 * halo);
            return std::max(1, int(std::floor((usable + cardGap) / stride)));
        };
        // :2459-2462: the last card of the row is always past the centre slot,
        // so it is placed at the row's last reachable step.
        const auto expectedContentXForLastCard = [&](qreal viewportWidth) {
            return (count - slotsIn(viewportWidth)) * stride - halo;
        };

        const qreal wideViewport = viewport->width();
        const int wideSlots = slotsIn(wideViewport);
        QVERIFY2(wideSlots >= 2 && wideSlots < count,
                 "the fixture row must be longer than its viewport");

        // Walk the remote onto the row's final card, where Right has nowhere
        // left to go.
        for (int step = 0; step < 20; ++step) {
            QTest::keyClick(window, Qt::Key_Right);
        }
        QTRY_COMPARE(controller.movieRows()->focus()->column(), count - 1);
        QTRY_COMPARE(qRound(view->property("contentX").toReal()),
                     qRound(expectedContentXForLastCard(wideViewport)));

        // Narrow the shell to its own minimum width without touching the
        // selection: qml/Main.qml:12 refuses anything narrower.
        window->resize(window->minimumWidth(), window->height());
        QTRY_VERIFY2(viewport->width() < wideViewport,
                     qPrintable(QStringLiteral("the platform never narrowed the row's viewport "
                                               "from %1")
                                    .arg(wideViewport)));
        QTRY_VERIFY(!view->property("moving").toBool());

        const qreal narrowViewport = viewport->width();
        const int narrowSlots = slotsIn(narrowViewport);
        QVERIFY2(narrowSlots < wideSlots,
                 qPrintable(QStringLiteral("the narrowed viewport still holds %1 slots")
                                .arg(narrowSlots)));
        // The selection did not move; only the geometry did.
        QCOMPARE(controller.movieRows()->focus()->column(), count - 1);
        QCOMPARE(focusedIndexOf(window), count - 1);

        // The row is placed at the step the narrowed viewport asks for rather
        // than the one the wide viewport did.
        QTRY_COMPARE(qRound(view->property("contentX").toReal()),
                     qRound(expectedContentXForLastCard(narrowViewport)));

        // Measured rather than computed: the focused card is drawn inside the
        // strip the row actually shows. A ListView only realises the delegates
        // it draws, so a card left off screen answers as null here.
        QQuickItem *focusedCard = cardAt(view, count - 1);
        QVERIFY2(focusedCard != nullptr,
                 "the focused card was not drawn after the window narrowed");
        QVERIFY(focusedCard->property("selected").toBool());
        const QRectF cardRect =
            focusedCard->mapRectToItem(viewport, focusedCard->boundingRect());
        QVERIFY2(cardRect.left() >= 0 && cardRect.right() <= narrowViewport + 0.5,
                 qPrintable(QStringLiteral("the focused card is clipped at %1..%2 in a viewport "
                                           "of %3")
                                .arg(cardRect.left())
                                .arg(cardRect.right())
                                .arg(narrowViewport)));

        // One authority: the reconciliation places the row directly, and the
        // row's own spring is not left running behind it.
        auto *spring = rowItem->findChild<QObject *>(QStringLiteral("movieRowScrollSpring"));
        QVERIFY(spring != nullptr);
        QVERIFY2(!spring->property("running").toBool(),
                 "the row's placement spring ran while motion was reduced");
        QVERIFY2(!controller.hasError(), qPrintable(controller.errorMessage()));
    }

    // The same reconciliation for the row's own card geometry: lean-back
    // rescales the card width, gap, and halo the placement is clamped against,
    // which ArrowedScrollRow.swift:123-125 answers through
    // `contentChangeSerial` without the selection moving.
    void switchingToLeanBackReplacesTheFocusedCardsPlacementForItsNewCardSize()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        QTemporaryDir library;
        for (const QString &name : sampleTitles()) {
            QVERIFY(writeMediaFile(library.path(), name));
        }

        ApplicationController controller;
        controller.settings()->setReduceMotion(true);
        controller.settings()->setLeanBackMode(false);
        controller.setTemporaryLibraryRoot(library.path());
        QTRY_COMPARE(controller.library()->rowCount(), 16);

        QQmlApplicationEngine engine;
        QQuickWindow *window = nullptr;
        openMoviesRoute(controller, engine, 16, window);
        QVERIFY2(window != nullptr, "the Movies route did not lay out its row");

        QQuickItem *view = allMoviesRow(window);
        QQuickItem *rowItem = movieRowNamed(window, "movieRow_all-movies");
        QVERIFY(view != nullptr);
        QVERIFY2(rowItem != nullptr, "the Movies route composed no all-movies row");
        QQuickItem *viewport =
            rowItem->findChild<QQuickItem *>(QStringLiteral("movieRowViewport"));
        QVERIFY(viewport != nullptr);

        for (int step = 0; step < 20; ++step) {
            QTest::keyClick(window, Qt::Key_Right);
        }
        QTRY_COMPARE(controller.movieRows()->focus()->column(), 15);

        // The lean-back geometry from MovieCard.swift:373 and
        // MarqueeTheme.swift:230-232, restated rather than read from the row.
        constexpr qreal leanBackCardWidth = 225;
        constexpr qreal leanBackCardGap = 16;
        constexpr qreal leanBackHalo = 52;
        constexpr qreal leanBackStride = leanBackCardWidth + leanBackCardGap;
        constexpr int count = 16;

        controller.settings()->setLeanBackMode(true);
        QTRY_COMPARE(qRound(view->property("spacing").toReal()), qRound(leanBackCardGap));
        QTRY_VERIFY(!view->property("moving").toBool());

        // The selection did not move; the cards it is clamped against grew.
        QCOMPARE(controller.movieRows()->focus()->column(), count - 1);

        const qreal usable = std::max(qreal(0), viewport->width() - 2 * leanBackHalo);
        const int leanBackSlots =
            std::max(1, int(std::floor((usable + leanBackCardGap) / leanBackStride)));
        QVERIFY2(leanBackSlots >= 1 && leanBackSlots < count,
                 "the fixture row must be longer than its lean-back viewport");
        QTRY_COMPARE(qRound(view->property("contentX").toReal()),
                     qRound((count - leanBackSlots) * leanBackStride - leanBackHalo));

        QQuickItem *focusedCard = cardAt(view, count - 1);
        QVERIFY2(focusedCard != nullptr,
                 "the focused card was not drawn after the cards were rescaled");
        const QRectF cardRect =
            focusedCard->mapRectToItem(viewport, focusedCard->boundingRect());
        QVERIFY2(cardRect.left() >= 0 && cardRect.right() <= viewport->width() + 0.5,
                 qPrintable(QStringLiteral("the focused card is clipped at %1..%2 in a viewport "
                                           "of %3")
                                .arg(cardRect.left())
                                .arg(cardRect.right())
                                .arg(viewport->width())));
        QVERIFY2(!controller.hasError(), qPrintable(controller.errorMessage()));
    }

    // A library that no longer holds the focused title recomposes the row under
    // the remote, which must land on a card that is there.
    void aRescanThatEmptiesTheLibraryLeavesTheSurfaceInItsEmptyState()
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
        QQuickWindow *window = nullptr;
        openMoviesRoute(controller, engine, 16, window);
        QVERIFY2(window != nullptr, "the Movies route did not lay out its row");

        QTest::keyClick(window, Qt::Key_Right);
        QTRY_COMPARE(controller.movieRows()->focus()->column(), 1);

        // The projection is replaced directly, because a removed root would
        // preserve its catalog rows rather than empty the library.
        controller.movieRows()->replaceItems({});

        QQuickItem *empty = nullptr;
        QTRY_VERIFY((empty = itemNamed(window, "moviesEmptyState")) != nullptr);
        QTRY_VERIFY(empty->isVisible());
        QQuickItem *count = itemNamed(window, "moviesTitleCount");
        QVERIFY(count != nullptr);
        QVERIFY(!count->isVisible());
        // Nothing is left for Enter to open.
        QVERIFY(controller.movieRows()->mediaIdAt(0, 0).isEmpty());
        QTest::keyClick(window, Qt::Key_Return);
        QCOMPARE(controller.navigation()->route(), NavigationController::Route::Movies);
        QVERIFY2(!controller.hasError(), qPrintable(controller.errorMessage()));
    }

    // MoviesDetailView.swift:105-144 holds the heading (:108-119) and the rows
    // (:124-135) in one `LazyVStack` inside one vertical `ScrollView`, so a
    // page scrolled past its content carries the heading away with the rows.
    // A composition that pinned the heading above a rows-only scroller kept it
    // on screen for ever and measured its placement against the wrong viewport.
    void scrollingAnOverflowingPageCarriesTheHeadingAwayWithTheRows()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        QTemporaryDir library;
        for (const QString &name : sampleTitles()) {
            QVERIFY(writeMediaFile(library.path(), name));
        }

        ApplicationController controller;
        // Lean-back draws the tallest row this catalog composes, which is what
        // overflows a window at the shell's own minimum height.
        controller.settings()->setLeanBackMode(true);
        controller.settings()->setReduceMotion(true);
        controller.setTemporaryLibraryRoot(library.path());
        QTRY_COMPARE(controller.library()->rowCount(), 16);

        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY2(window != nullptr, "qml/Main.qml did not load from the module");
        // qml/Main.qml:12-13 refuses anything shorter; the page must overflow
        // at the shortest window the product actually allows.
        window->resize(1600, window->minimumHeight());
        controller.navigation()->openRoute(NavigationController::Route::Movies);
        QVERIFY(QTest::qWaitForWindowExposed(window));

        QQuickItem *view = nullptr;
        QTRY_VERIFY((view = allMoviesRow(window)) != nullptr);
        QTRY_COMPARE(view->property("count").toInt(), 16);

        QQuickItem *scroll = itemNamed(window, "moviesScroll");
        QQuickItem *heading = itemNamed(window, "moviesHeading");
        QQuickItem *rowItem = movieRowNamed(window, "movieRow_all-movies");
        QVERIFY(scroll != nullptr);
        QVERIFY(heading != nullptr);
        QVERIFY2(rowItem != nullptr, "the Movies route composed no all-movies row");

        // The heading is drawn inside the page's scrolled content rather than
        // beside it, which is the composition this regression exists for.
        bool headingIsInsideTheScroll = false;
        for (QQuickItem *ancestor = heading->parentItem(); ancestor != nullptr;
             ancestor = ancestor->parentItem()) {
            if (ancestor == scroll) {
                headingIsInsideTheScroll = true;
                break;
            }
        }
        QVERIFY2(headingIsInsideTheScroll,
                 "the heading is not inside the page's scrolled content");

        // One scroll authority: the page's own Flickable covers the surface
        // instead of starting below a fixed header.
        QQuickItem *surface = scroll->parentItem();
        QVERIFY(surface != nullptr);
        QCOMPARE(qRound(scroll->height()), qRound(surface->height()));
        QCOMPARE(qRound(scroll->y()), 0);

        // The lean-back row is taller than a window at the shell's minimum, so
        // the page overflows once the platform has applied that height. A
        // platform that refuses the resize fails here rather than testing a
        // page that never needed to scroll.
        QTRY_VERIFY2(scroll->property("contentHeight").toReal() > scroll->height(),
                     qPrintable(QStringLiteral("the fixture page must overflow: content %1 in %2")
                                    .arg(scroll->property("contentHeight").toReal())
                                    .arg(scroll->height())));
        const qreal viewportHeight = scroll->height();
        const qreal contentHeight = scroll->property("contentHeight").toReal();

        QTRY_COMPARE(qRound(scroll->property("contentY").toReal()), 0);
        const qreal headingAtRest = heading->mapToItem(scroll, QPointF(0, 0)).y();
        const qreal rowAtRest = rowItem->mapToItem(scroll, QPointF(0, 0)).y();
        QVERIFY2(headingAtRest >= 0 && headingAtRest < rowAtRest,
                 "the heading does not start above the first row");

        // A real wheel over the page, delivered where the row is drawn: the
        // row's own horizontal view must not swallow a vertical scroll.
        const qreal rowContentXBefore = view->property("contentX").toReal();
        QTest::wheelEvent(window, QPointF(window->width() / 2.0, rowAtRest + 40),
                          QPoint(0, -120), QPoint(0, -120));
        QTRY_VERIFY2(scroll->property("contentY").toReal() > 0,
                     "the wheel did not scroll the page");
        QTRY_VERIFY(!scroll->property("moving").toBool());

        const qreal offset = scroll->property("contentY").toReal();
        const qreal headingNow = heading->mapToItem(scroll, QPointF(0, 0)).y();
        const qreal rowNow = rowItem->mapToItem(scroll, QPointF(0, 0)).y();

        QVERIFY2(headingNow < headingAtRest,
                 qPrintable(QStringLiteral("the heading stayed put at %1 while the page moved %2")
                                .arg(headingNow)
                                .arg(offset)));
        // The heading and the rows travel together under one authority: each
        // moves by exactly the page's offset, so their separation is fixed.
        QVERIFY(qAbs((headingAtRest - headingNow) - offset) < 1.0);
        QVERIFY(qAbs((rowAtRest - rowNow) - offset) < 1.0);
        QVERIFY(qAbs((rowNow - headingNow) - (rowAtRest - headingAtRest)) < 1.0);
        // A vertical wheel belongs to the page, never to the row beneath it.
        QCOMPARE(qRound(view->property("contentX").toReal()), qRound(rowContentXBefore));

        // Scrolled far enough, the heading leaves the viewport entirely, which
        // a heading pinned outside the scroller could never do.
        QQuickItem *content = window->contentItem();
        scroll->setProperty("contentY", contentHeight - viewportHeight);
        QTRY_COMPARE(qRound(scroll->property("contentY").toReal()),
                     qRound(contentHeight - viewportHeight));
        const QRectF headingRect = heading->mapRectToItem(content, heading->boundingRect());
        const QRectF scrollRect = scroll->mapRectToItem(content, scroll->boundingRect());
        QVERIFY2(headingRect.bottom() <= scrollRect.top(),
                 qPrintable(QStringLiteral("the heading is still in the viewport at %1")
                                .arg(headingRect.bottom())));

        // The remote still places its focused row against the whole viewport
        // after the page was dragged by hand: moving focus along the row keeps
        // the row coherently placed rather than stranded off screen.
        QQuickItem *contentFocus =
            window->findChild<QQuickItem *>(QStringLiteral("contentFocus"));
        QVERIFY(contentFocus != nullptr);
        QTest::keyClick(window, Qt::Key_Right);
        QTRY_VERIFY(contentFocus->hasActiveFocus());
        QTest::keyClick(window, Qt::Key_Right);
        QTRY_COMPARE(controller.movieRows()->focus()->column(), 1);

        QTRY_VERIFY(!scroll->property("moving").toBool());
        const qreal placedTop = rowItem->mapToItem(scroll, QPointF(0, 0)).y();
        // RemoteScrollCoordinator.swift:1240-1241 and :1254-1255: the released
        // anchor and its tolerance, measured against the whole page viewport
        // rather than a strip beneath a fixed header.
        const qreal desiredTop = qMax(210.0, std::round(viewportHeight * 0.36));
        const qreal tolerance = qMax(48.0, viewportHeight * 0.11);
        // The drag left the row that far outside the tolerance, which is what
        // makes the placement fire rather than leave the page where it lay.
        QVERIFY(qAbs((rowAtRest - (contentHeight - viewportHeight)) - desiredTop) > tolerance);
        // :1288 clamps the offset the anchor asks for to the top of the
        // content, and the page's own extent clamps the other end. This route
        // composes one row, which the heading above it already starts nearer
        // the top than the anchor, so the released placement is that clamp:
        // the page returns to the top rather than scrolling past it to hang
        // the row lower than its own content can reach. rowAtRest was measured
        // with the page at rest, so it is the row's offset in that content.
        const qreal placedOffset =
            qBound(0.0, rowAtRest - desiredTop, contentHeight - viewportHeight);
        QTRY_COMPARE(qRound(scroll->property("contentY").toReal()), qRound(placedOffset));
        QVERIFY2(qAbs(placedTop - (rowAtRest - placedOffset)) < 1.0,
                 qPrintable(QStringLiteral("the focused row settled at %1, not at the released "
                                           "placement %2 for anchor %3")
                                .arg(placedTop)
                                .arg(rowAtRest - placedOffset)
                                .arg(desiredTop)));
        // The placement reclaimed the page the wheel had dragged away: the row
        // the remote is on starts inside the viewport instead of above it.
        QVERIFY2(placedTop >= 0 && placedTop < viewportHeight,
                 qPrintable(QStringLiteral("the focused row is stranded at %1 in a viewport of %2")
                                .arg(placedTop)
                                .arg(viewportHeight)));
        // Placing the row moves the whole page, so the heading keeps its fixed
        // separation from the row it precedes.
        const qreal headingPlaced = heading->mapToItem(scroll, QPointF(0, 0)).y();
        QVERIFY(qAbs((placedTop - headingPlaced) - (rowAtRest - headingAtRest)) < 1.0);
        QVERIFY2(!controller.hasError(), qPrintable(controller.errorMessage()));
    }

    // MoviesDetailView.swift:252-256 places a browse row immediately rather
    // than animating it when Reduce Motion is on.
    void reduceMotionPlacesTheRowWithoutRunningItsSpring()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        QTemporaryDir library;
        for (const QString &name : sampleTitles()) {
            QVERIFY(writeMediaFile(library.path(), name));
        }

        ApplicationController controller;
        controller.settings()->setReduceMotion(true);
        controller.settings()->setLeanBackMode(false);
        controller.setTemporaryLibraryRoot(library.path());
        QTRY_COMPARE(controller.library()->rowCount(), 16);

        QQmlApplicationEngine engine;
        QQuickWindow *window = nullptr;
        openMoviesRoute(controller, engine, 16, window);
        QVERIFY2(window != nullptr, "the Movies route did not lay out its row");

        QQuickItem *view = allMoviesRow(window);
        QQuickItem *rowItem = movieRowNamed(window, "movieRow_all-movies");
        QVERIFY(view != nullptr);
        QVERIFY(rowItem != nullptr);

        const QVariant slotCount = callQml(rowItem, "visibleSlotCount");
        QVERIFY(slotCount.isValid());
        const int visibleSlots = slotCount.toInt();

        // One key past the point where the row must move: the offset is
        // already final in the same turn, with no animation still running.
        for (int step = 0; step <= visibleSlots; ++step) {
            QTest::keyClick(window, Qt::Key_Right);
        }
        const int column = controller.movieRows()->focus()->column();
        const QVariant offset = callQml(rowItem, "focusOffset", column);
        QVERIFY(offset.isValid());
        const qreal expected = offset.toReal();
        QVERIFY(expected > 0);

        auto *spring = rowItem->findChild<QObject *>(QStringLiteral("movieRowScrollSpring"));
        QVERIFY(spring != nullptr);
        QVERIFY2(!spring->property("running").toBool(),
                 "the row's placement spring ran while motion was reduced");
        QCOMPARE(qRound(view->property("contentX").toReal()),
                 qRound(expected - view->property("leftMargin").toReal()));
    }

    // MoviesDetailView.swift:177 draws BottomFadeView.swift:14-24 over the
    // route: an 80-point band of the page background running from transparent
    // at its top to opaque at its bottom, so an overflowing page's last row
    // fades out instead of being cut at the window's edge. The route had no
    // such band at all. It is judged against the same frame with the band
    // hidden, so what it is drawn over is the product's own rendering, and it
    // must not have taken over the page's scrolling, its focus, or its
    // spacing.
    void anOverflowingPageFadesIntoTheBackgroundAtItsBottomEdge()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        QTemporaryDir library;
        for (const QString &name : sampleTitles()) {
            QVERIFY(writeMediaFile(library.path(), name));
        }
        // A single row does not reach the band: MoviesDetailView.swift:139
        // keeps 150 points of run-off below the last row in lean-back, so the
        // page's own end leaves the band over empty page. Two composed rows
        // give the surface a row that really runs beneath the band, which is
        // the state this band exists for. Both titles are named holiday films
        // at BrowseSnapshotStore.swift:2096, which is what composes the second
        // row.
        for (const QString &name :
             {QStringLiteral("Elf.2003.mkv"), QStringLiteral("Home.Alone.1990.mkv")}) {
            QVERIFY(writeMediaFile(library.path(), name));
        }

        ApplicationController controller;
        // Lean-back draws the tallest rows this catalog composes, which is what
        // overflows a window at the shell's own minimum height and so puts
        // real content under the band.
        controller.settings()->setLeanBackMode(true);
        controller.settings()->setReduceMotion(true);
        controller.setTemporaryLibraryRoot(library.path());
        QTRY_COMPARE(controller.library()->rowCount(), 18);

        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY2(window != nullptr, "qml/Main.qml did not load from the module");
        window->resize(1600, window->minimumHeight());
        controller.navigation()->openRoute(NavigationController::Route::Movies);
        QVERIFY(QTest::qWaitForWindowExposed(window));

        QQuickItem *view = nullptr;
        QTRY_VERIFY((view = allMoviesRow(window)) != nullptr);
        QTRY_COMPARE(view->property("count").toInt(), 18);

        QQuickItem *scroll = itemNamed(window, "moviesScroll");
        QQuickItem *fade = itemNamed(window, "moviesBottomFade");
        QQuickItem *rowItem = movieRowNamed(window, "movieRow_all-movies");
        QVERIFY(scroll != nullptr);
        QVERIFY2(fade != nullptr, "the Movies route draws no bottom fade");
        QVERIFY2(rowItem != nullptr, "the Movies route composed no all-movies row");

        // The band is the released one: 80 points tall, spanning the surface,
        // pinned at its bottom edge, and drawn over the scrolled page rather
        // than inside it, so it does not travel with the content.
        QQuickItem *surface = scroll->parentItem();
        QVERIFY(surface != nullptr);
        QCOMPARE(qRound(fade->height()), 80);
        QCOMPARE(qRound(fade->width()), qRound(surface->width()));
        QCOMPARE(qRound(fade->y() + fade->height()), qRound(surface->height()));
        QCOMPARE(fade->parentItem(), surface);

        // Scrolling ownership is unchanged: one Flickable still covers the
        // route, the band takes no pointer input, and the page's own extents
        // and spacing are what they were.
        QCOMPARE(qRound(scroll->height()), qRound(surface->height()));
        QCOMPARE(qRound(scroll->y()), 0);
        QTRY_VERIFY2(scroll->property("contentHeight").toReal() > scroll->height(),
                     qPrintable(QStringLiteral("the fixture page must overflow: content %1 in %2")
                                    .arg(scroll->property("contentHeight").toReal())
                                    .arg(scroll->height())));
        const qreal viewportHeight = scroll->height();
        const qreal contentHeight = scroll->property("contentHeight").toReal();

        // A pointer over the band still reaches the page beneath it, which is
        // what :23's `allowsHitTesting(false)` keeps true.
        const qreal beforeWheel = scroll->property("contentY").toReal();
        QTest::wheelEvent(window,
                          QPointF(window->width() / 2.0,
                                  fade->mapToScene(QPointF(0, fade->height() / 2)).y()),
                          QPoint(0, -120), QPoint(0, -120));
        QTRY_VERIFY2(scroll->property("contentY").toReal() > beforeWheel,
                     "a wheel over the bottom fade did not reach the page beneath it");
        QTRY_VERIFY(!scroll->property("moving").toBool());

        // The remote still owns the route: the band took no focus.
        QQuickItem *contentFocus =
            window->findChild<QQuickItem *>(QStringLiteral("contentFocus"));
        QVERIFY(contentFocus != nullptr);
        QTest::keyClick(window, Qt::Key_Right);
        QTRY_VERIFY(contentFocus->hasActiveFocus());
        QVERIFY(!fade->hasActiveFocus());

        // Now the rendered evidence. The page's own 150 points of run-off
        // below the last row (MoviesDetailView.swift:139) are deeper than the
        // 80-point band, so the end of the page holds the band over empty
        // padding; the state the band exists for is a row passing beneath it,
        // which is where the page is put here: the last row's centre under the
        // band's centre, clamped to what the page can actually reach.
        const qreal rowContentTop =
            scroll->property("contentY").toReal() + rowItem->mapToItem(scroll, QPointF(0, 0)).y();
        const qreal bandCentre = viewportHeight - 40.0;
        const qreal scrollTarget =
            std::clamp(rowContentTop + rowItem->height() / 2.0 - bandCentre, qreal(0),
                       contentHeight - viewportHeight);
        scroll->setProperty("contentY", scrollTarget);
        QTRY_COMPARE(qRound(scroll->property("contentY").toReal()), qRound(scrollTarget));
        QTRY_VERIFY(!scroll->property("moving").toBool());

        const QList<QQuickItem *> items{surface, scroll, fade, rowItem, view};
        const render_probe::Capture faded = render_probe::captureWindowUntil(
            window, items, [&](const render_probe::Capture &capture) {
                const QRect band = render_probe::imageRectForItem(capture, fade);
                return !band.isEmpty() && band.bottom() == capture.image.height() - 1;
            });
        QVERIFY(faded.coherent());
        const QRect band = render_probe::imageRectForItem(faded, fade);
        QVERIFY(!band.isEmpty());
        // A scene rectangle can start on a fractional row, so its aligned
        // extent may carry one pixel of rounding at either ratio.
        QVERIFY2(qAbs(band.height() - render_probe::pixels(faded, 80)) <= 1,
                 qPrintable(QStringLiteral("the fade band is %1 px tall, not the released 80 "
                                           "points at ratio %2")
                                .arg(band.height()).arg(faded.devicePixelRatio)));

        // The same frame with the band alone hidden: what it is drawn over.
        fade->setVisible(false);
        const render_probe::Capture unfaded = render_probe::captureWindowUntil(
            window, items, [&](const render_probe::Capture &capture) {
                return capture.sameGeometryAs(faded) && !fade->isVisible()
                    && capture.geometryOf(fade) == faded.geometryOf(fade);
            });
        fade->setVisible(true);
        QVERIFY(unfaded.coherent());
        QVERIFY(unfaded.sameGeometryAs(faded));
        // Validation: the band is the only difference between the two frames.
        QCOMPARE(render_probe::changedPixels(
                     faded, unfaded, QRect(0, 0, faded.image.width(), band.top())),
                 0);

        const QColor background("#0d0b1a");
        // The fixture really overflows into the band, which is what makes the
        // controls below meaningful rather than vacuous. Content is judged by
        // the audit's own tolerance, so a band whose content the audit can
        // still distinguish is never read as clear page.
        const int contentUnderBand =
            render_probe::countPixels(unfaded.image, band, [&background](const QColor &pixel) {
                return render_probe::departureFrom(pixel, background)
                    > render_probe::fadeBandTolerance;
            });
        QVERIFY2(contentUnderBand > 0,
                 "the fixture painted no content under the bottom fade");

        const render_probe::FadeBandAudit audit =
            render_probe::auditBottomFadeBand(faded.image, unfaded.image, band, background);
        QCOMPARE(audit.judged, band.width() * band.height());
        QVERIFY2(audit.mismatches == 0,
                 qPrintable(QStringLiteral("%1 of %2 band pixels are not the band's own mixture "
                                           "of the page and its background at ratio %3; first %4")
                                .arg(audit.mismatches).arg(audit.judged)
                                .arg(faded.devicePixelRatio).arg(audit.firstMismatch)));
        // Negative controls: an opaque band would hide the row at the band's
        // head, and a band that was never drawn would leave it visible at the
        // band's foot.
        QVERIFY(audit.strongInHead > 0);
        QVERIFY(audit.strongInFoot > 0);
        QVERIFY2(audit.opaqueMatches == 0,
                 qPrintable(QStringLiteral("%1 of %2 pixels under the band's head are the page "
                                           "background rather than the row beneath them")
                                .arg(audit.opaqueMatches).arg(audit.strongInHead)));
        QVERIFY2(audit.unfadedMatches == 0,
                 qPrintable(QStringLiteral("%1 of %2 pixels under the band's foot are the "
                                           "unfaded row rather than the page background")
                                .arg(audit.unfadedMatches).arg(audit.strongInFoot)));
        QVERIFY2(!controller.hasError(), qPrintable(controller.errorMessage()));
    }
};

int main(int argc, char *argv[])
{
    QGuiApplication app(argc, argv);
    MoviesRouteTest test;
    return QTest::qExec(&test, argc, argv);
}

#include "tst_movies_route.moc"
