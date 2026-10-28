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
#include <QSqlDatabase>
#include <QSqlQuery>
#include <QTemporaryDir>

#include "app/AppPaths.hpp"
#include "app/ApplicationController.hpp"
#include "catalog/CatalogDatabase.hpp"
#include "catalog/CatalogStore.hpp"
#include "catalog/LibraryScanner.hpp"
#include "models/HeroSpotlight.hpp"
#include "models/HomeRowsModel.hpp"
#include "models/ShowsModel.hpp"
#include "navigation/NavigationController.hpp"
#include "profiles/ProfileStore.hpp"
#include "search/SearchSession.hpp"
#include "settings/SettingsStore.hpp"
#include "support/GuiThreadIoProbe.hpp"

#include <cstdio>

#ifndef __linux__
#error "The GUI-thread file probe replaces C library entry points and is Linux only."
#endif

// A library root on a removable drive that is unplugged under an automount
// makes every stat, open and directory read of its paths block until the
// device times out. These cases keep that drive's paths away from the GUI
// thread for the whole life of the shipped shell: they run it with the drive
// gone, count what the GUI thread asks of the file system under the drive's
// paths, and judge what the viewer is shown.
namespace
{
[[nodiscard]] bool writeFile(const QString &path)
{
    QDir().mkpath(QFileInfo(path).absolutePath());
    QFile file(path);
    return file.open(QIODevice::WriteOnly) && file.write("media") == 5;
}

[[nodiscard]] bool writeImage(const QString &path, const QColor &colour)
{
    QDir().mkpath(QFileInfo(path).absolutePath());
    QImage image(640, 360, QImage::Format_RGB32);
    image.fill(colour);
    return image.save(path, "PNG");
}

// A film in a folder of its own with the poster and backdrop sidecars the
// scanner adopts, so the title has local artwork for the scene to load.
[[nodiscard]] bool writeFilm(const QString &root, const QString &folder, const QColor &colour)
{
    return writeFile(root + QLatin1Char('/') + folder + QLatin1Char('/') + folder
                     + QStringLiteral(".mkv"))
        && writeImage(root + QLatin1Char('/') + folder + QStringLiteral("/poster.png"), colour)
        && writeImage(root + QLatin1Char('/') + folder + QStringLiteral("/fanart.png"), colour);
}

[[nodiscard]] bool writeShow(const QString &root, const QString &show, const QString &episode,
                             const QColor &colour)
{
    return writeFile(root + QLatin1Char('/') + show + QStringLiteral("/Season 1/") + episode
                     + QStringLiteral(".mkv"))
        && writeImage(root + QLatin1Char('/') + show + QStringLiteral("/poster.png"), colour)
        && writeImage(root + QLatin1Char('/') + show + QStringLiteral("/fanart.png"), colour);
}

// A scan of a drive that hangs takes as long as the drive's device timeout for
// each folder it reads; the shipped timeout was ten seconds.
constexpr int kScanTimeoutMs = 60'000;

[[nodiscard]] QString mainProfileId()
{
    AppPaths::ensureDirectories();
    const ProfileStore profiles(AppPaths::profilesFile());
    return profiles.profiles().at(0).id;
}

// The catalog as an earlier session left it: every root scanned while it was
// readable, and one title already part-watched.
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

[[nodiscard]] Seed seed(const LibraryRootPaths &paths)
{
    AppPaths::ensureDirectories();
    CatalogDatabase catalog(AppPaths::catalogFile());
    catalog.migrate();
    CatalogStore store(AppPaths::catalogFile());
    Seed result;
    result.roots = store.registerRoots(paths);
    for (const LibraryRoot &root : result.roots) {
        store.applyScan(root, LibraryScanner::scan(root));
    }
    result.profileId = mainProfileId();
    return result;
}

// One value read straight from the catalog file, through a connection of its
// own, so it states what is durable rather than what a model holds.
[[nodiscard]] QString catalogValue(const QString &sql)
{
    const QString connection = QStringLiteral("unavailable-root-probe");
    QString value;
    {
        QSqlDatabase database = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), connection);
        database.setDatabaseName(AppPaths::catalogFile());
        if (database.open()) {
            QSqlQuery query(database);
            if (query.exec(sql) && query.next()) {
                value = query.value(0).toString();
            }
        }
    }
    QSqlDatabase::removeDatabase(connection);
    return value;
}

[[nodiscard]] QQuickItem *itemNamed(QQuickWindow *window, const char *name)
{
    return window->findChild<QQuickItem *>(QLatin1String(name));
}

[[nodiscard]] QString describe(const QStringList &hits)
{
    return QStringLiteral("%1 file system calls on the GUI thread under the missing drive:\n%2")
        .arg(hits.size())
        .arg(hits.join(QLatin1Char('\n')));
}

// Every title Home puts in front of the viewer: the cards of every row and the
// hero's slides.
[[nodiscard]] QStringList homeTitles(HomeRowsModel *rows)
{
    QStringList titles;
    for (int row = 0; row < rows->rowCount(); ++row) {
        const auto *cards = qobject_cast<const QAbstractItemModel *>(
            rows->data(rows->index(row), HomeRowsModel::ItemsRole).value<QObject *>());
        for (int column = 0; cards != nullptr && column < cards->rowCount(); ++column) {
            titles.push_back(
                cards->data(cards->index(column, 0), HomeCardModel::TitleRole).toString());
        }
    }
    for (int slide = 0; slide < rows->hero()->count(); ++slide) {
        titles.push_back(rows->hero()->spotlightAt(slide).value(QStringLiteral("title")).toString());
    }
    titles.removeDuplicates();
    titles.sort();
    return titles;
}

[[nodiscard]] QStringList rowIds(HomeRowsModel *rows)
{
    QStringList ids;
    for (int row = 0; row < rows->rowCount(); ++row) {
        ids.push_back(rows->data(rows->index(row), HomeRowsModel::RowIdRole).toString());
    }
    return ids;
}
}

class UnavailableRootTest final : public QObject
{
    Q_OBJECT

    // The laptop of the report: a readable local folder with two films and a
    // show, and a drive mounted at a folder of its own with two films and a
    // show on it. Unplugging the drive takes its folder away.
    struct Fixture
    {
        QTemporaryDir runtimeRoot;
        QTemporaryDir local;
        QTemporaryDir localShows;
        QTemporaryDir drive;
        QTemporaryDir shelf;
        bool unplugged = false;
        std::unique_ptr<ApplicationController> controller;
        std::unique_ptr<QQmlApplicationEngine> engine;
        QQuickWindow *window = nullptr;
        Seed seeded;

        [[nodiscard]] QString driveMovies() const { return drive.path() + QStringLiteral("/Movies"); }
        [[nodiscard]] QString driveShows() const { return drive.path() + QStringLiteral("/TV Shows"); }
        [[nodiscard]] QString shelved() const { return shelf.path() + QStringLiteral("/unplugged"); }

        // The C library's rename: Qt's own looks at the destination first,
        // which is a call on the drive's path that is the fixture's, not the
        // shell's.
        [[nodiscard]] bool unplug()
        {
            unplugged = ::rename(QFile::encodeName(drive.path()).constData(),
                                 QFile::encodeName(shelved()).constData())
                == 0;
            return unplugged;
        }

        [[nodiscard]] bool plugIn()
        {
            gui_thread_io::unwatch();
            if (::rename(QFile::encodeName(shelved()).constData(),
                         QFile::encodeName(drive.path()).constData())
                == 0) {
                unplugged = false;
            }
            return !unplugged;
        }

        ~Fixture()
        {
            engine.reset();
            controller.reset();
            gui_thread_io::unwatch();
            if (unplugged) {
                [[maybe_unused]] const bool restored = plugIn();
            }
            AppPaths::clearRuntimeRoot();
        }
    };

    struct Setup
    {
        // The readable folders are configured.
        bool local = true;
        // The drive's folders are configured and held films when last scanned.
        bool drive = true;
        // The drive is gone when the application starts.
        bool unplugged = true;
    };

    [[nodiscard]] bool open(Fixture &f, Setup setup)
    {
        AppPaths::setRuntimeRoot(f.runtimeRoot.path());
        LibraryRootPaths configured;
        if (setup.local) {
            if (!writeFilm(f.local.path(), QStringLiteral("Arrival (2016)"), QColor(200, 30, 30))
                || !writeFilm(f.local.path(), QStringLiteral("Coco (2017)"), QColor(30, 200, 30))
                || !writeShow(f.localShows.path(), QStringLiteral("Bluey (2018)"),
                              QStringLiteral("Bluey - S01E01 - Title"), QColor(30, 30, 200))) {
                return false;
            }
            configured.movies.push_back(f.local.path());
            configured.tvShows.push_back(f.localShows.path());
        }
        if (setup.drive) {
            if (!writeFilm(f.driveMovies(), QStringLiteral("Dune (2021)"), QColor(200, 200, 30))
                || !writeFilm(f.driveMovies(), QStringLiteral("Heat (1995)"), QColor(30, 200, 200))
                || !writeShow(f.driveShows(), QStringLiteral("The Wire (2002)"),
                              QStringLiteral("The Wire - S01E01 - The Target"),
                              QColor(200, 30, 200))) {
                return false;
            }
            configured.movies.push_back(f.driveMovies());
            configured.tvShows.push_back(f.driveShows());
        }
        f.seeded = seed(configured);
        if (setup.drive) {
            f.seeded.record(f.seeded.idOf(QStringLiteral("Heat")), 600'000, false);
            f.seeded.record(f.seeded.idOf(QStringLiteral("The Wire"), 1), 600'000, false);
        }
        if (setup.drive && setup.unplugged && !f.unplug()) {
            return false;
        }
        // From here on the GUI thread must stay away from the drive.
        gui_thread_io::watch(f.drive.path());

        f.controller = std::make_unique<ApplicationController>();
        f.controller->setStartFullscreen(false);
        for (const QString &path : std::as_const(configured.movies)) {
            f.controller->setTemporaryLibraryRoot(path);
        }
        for (const QString &path : std::as_const(configured.tvShows)) {
            f.controller->setTemporaryTvShowsRoot(path);
        }
        if (!f.controller->chooseProfile(f.seeded.profileId)
            || !QTest::qWaitFor([&] { return !f.controller->profileExitInFlight(); })) {
            return false;
        }
        f.engine = std::make_unique<QQmlApplicationEngine>();
        f.engine->rootContext()->setContextProperty(QStringLiteral("appController"),
                                                    f.controller.get());
        f.engine->loadFromModule(QStringLiteral("Marquee"), QStringLiteral("Main"));
        if (f.engine->rootObjects().size() != 1) {
            return false;
        }
        f.window = qobject_cast<QQuickWindow *>(f.engine->rootObjects().front());
        if (f.window == nullptr) {
            return false;
        }
        f.window->resize(1600, 900);
        f.window->requestActivate();
        f.controller->navigation()->goHome();
        return QTest::qWaitForWindowExposed(f.window);
    }

    [[nodiscard]] static QStringList unavailableRoots(const Fixture &f)
    {
        return f.controller->property("unavailableLibraryRoots").toStringList();
    }

    // The scan has ended and has said which roots it could not read: for a
    // missing drive it also raised the "Library unavailable" toast.
    [[nodiscard]] static bool scanSettled(const Fixture &f, bool expectMissing)
    {
        if (f.controller->scanning()) {
            return false;
        }
        if (expectMissing) {
            return !unavailableRoots(f).isEmpty()
                || f.controller->errorTitle() == QStringLiteral("Library unavailable");
        }
        return unavailableRoots(f).isEmpty();
    }

private slots:
    void initTestCase()
    {
        // Without a platform that renders there is nothing for the scene to
        // load, and a quiet probe would prove nothing.
        QVERIFY(QGuiApplication::platformName() == QStringLiteral("offscreen")
                || QGuiApplication::platformName() == QStringLiteral("xcb")
                || QGuiApplication::platformName() == QStringLiteral("wayland"));
    }

    // The probe is only evidence while it sees what the GUI thread does, so it
    // is shown a stat of a path under its prefix first.
    void theProbeSeesTheGuiThreadStatAPathUnderItsPrefix()
    {
        QTemporaryDir directory;
        QVERIFY(directory.isValid());
        const QString missing = directory.path() + QStringLiteral("/Drive/film.mkv");
        gui_thread_io::watch(directory.path() + QStringLiteral("/Drive"));
        const auto stop = qScopeGuard([] { gui_thread_io::unwatch(); });

        QVERIFY(!QFileInfo(missing).isFile());
        const QStringList hits = gui_thread_io::mainThreadHits();
        QVERIFY2(!hits.isEmpty(), "a stat of the watched path was not seen");

        // A sibling whose name only starts with the prefix is another folder.
        gui_thread_io::watch(directory.path() + QStringLiteral("/Drive"));
        QVERIFY(!QFileInfo(directory.path() + QStringLiteral("/Drive2/film.mkv")).isFile());
        QVERIFY(gui_thread_io::mainThreadHits().isEmpty());

        // A worker thread's call is counted apart: scanning is its job.
        gui_thread_io::watch(directory.path() + QStringLiteral("/Drive"));
        QThread *worker = QThread::create([&] { QFileInfo(missing).isFile(); });
        worker->start();
        worker->wait();
        delete worker;
        QVERIFY(gui_thread_io::mainThreadHits().isEmpty());
        QCOMPARE(gui_thread_io::otherThreadHits() > 0, true);
    }

    // The report's freeze: the drive's titles reached Home, the hero and the
    // detail pages, and Qt Quick stat'd their artwork on the GUI thread. The
    // shell runs through every surface that draws the library with the drive
    // gone, and the GUI thread asks the drive for nothing.
    void theGuiThreadNeverTouchesAMissingDrive()
    {
        Fixture f;
        QVERIFY(open(f, {}));
        QTRY_VERIFY_WITH_TIMEOUT(scanSettled(f, true), kScanTimeoutMs);
        // The scan did look at the drive, away from the GUI thread.
        QVERIFY(gui_thread_io::otherThreadHits() > 0);
        QTest::qWait(300);

        using Route = NavigationController::Route;
        f.controller->navigation()->openRoute(Route::Movies);
        QTRY_COMPARE(f.controller->navigation()->route(), Route::Movies);
        QTest::qWait(150);
        f.controller->navigation()->openRoute(Route::Shows);
        QTRY_COMPARE(f.controller->navigation()->route(), Route::Shows);
        QTest::qWait(150);
        f.controller->navigation()->openRoute(Route::Search);
        QTRY_COMPARE(f.controller->navigation()->route(), Route::Search);
        f.controller->search()->setQuery(QStringLiteral("Dune"));
        QTest::qWait(150);
        f.controller->navigation()->goHome();
        QTRY_COMPARE(f.controller->navigation()->route(), Route::Home);
        QTest::qWait(150);

        // Details of a title that can be read, then a request for one of the
        // drive's, which is answered or refused but never read from the drive.
        f.controller->showMediaDetails(f.seeded.idOf(QStringLiteral("Arrival")));
        QTRY_COMPARE(f.controller->navigation()->route(), Route::Details);
        QTRY_VERIFY(itemNamed(f.window, "detailsScreen") != nullptr);
        QTest::qWait(150);
        f.controller->navigation()->goHome();
        QTRY_COMPARE(f.controller->navigation()->route(), Route::Home);
        f.controller->showMediaDetails(f.seeded.idOf(QStringLiteral("Dune")));
        QTest::qWait(250);
        f.controller->navigation()->goHome();
        f.controller->dismissError();

        // Play Something never checks a file of the drive.
        QStringList checked;
        f.controller->setPlayableFileCheckForTest([&checked](const QString &path) {
            checked.push_back(path);
            return false;
        });
        for (int press = 0; press < 5; ++press) {
            f.controller->playSomething();
        }
        for (const QString &path : std::as_const(checked)) {
            QVERIFY2(!path.startsWith(f.drive.path()), qPrintable(path));
        }

        // Key input on Home moves over the cards the viewer can see.
        for (int press = 0; press < 6; ++press) {
            QTest::keyClick(f.window, Qt::Key_Right);
            QCoreApplication::processEvents();
        }

        QTest::qWait(300);
        const QStringList hits = gui_thread_io::mainThreadHits();
        QVERIFY2(hits.isEmpty(), qPrintable(describe(hits)));
    }

    // What the viewer is shown while the drive is gone: its titles are on no
    // surface.
    void aMissingDrivesTitlesAreOnNoSurface()
    {
        Fixture f;
        QVERIFY(open(f, {}));
        HomeRowsModel *rows = f.controller->homeRows();
        QTRY_VERIFY_WITH_TIMEOUT(scanSettled(f, true), kScanTimeoutMs);
        QTRY_VERIFY(!homeTitles(rows).isEmpty());

        // Home: the rows and the hero hold what can be read, and only that.
        const QStringList shown = homeTitles(rows);
        QVERIFY2(shown.contains(QStringLiteral("Arrival")), qPrintable(shown.join(", ")));
        for (const QString &hidden : {QStringLiteral("Dune"), QStringLiteral("Heat"),
                                      QStringLiteral("The Wire")}) {
            QVERIFY2(!shown.contains(hidden), qPrintable(hidden));
        }
        QVERIFY(!rowIds(rows).contains(QStringLiteral("continue-watching")));
        QVERIFY(rows->hero()->count() > 0);

        // Movies, TV Shows, Search and Play Something.
        QCOMPARE(f.controller->library()->titleCount(), 2);
        QCOMPARE(f.controller->movieRows()->titleCount(), 2);
        QCOMPARE(f.controller->shows()->showCount(), 1);
        QCOMPARE(f.controller->shows()->episodeCount(), 1);
        f.controller->search()->setQuery(QStringLiteral("Dune"));
        QCOMPARE(f.controller->search()->rowCount(), 0);
        f.controller->search()->setQuery(QStringLiteral("Arrival"));
        QCOMPARE(f.controller->search()->rowCount(), 1);
        QCOMPARE(rows->playSomethingCandidates().size(), 2);

        // A title of the drive cannot be opened either, and the refusal says
        // why.
        f.controller->showMediaDetails(f.seeded.idOf(QStringLiteral("Dune")));
        QCOMPARE(f.controller->navigation()->route(), NavigationController::Route::Home);
        QVERIFY(f.controller->hasError());
        QCOMPARE(f.controller->errorMessage(),
                 QStringLiteral("That title is no longer in the library."));
    }

    // The drive may only be gone for the evening: nothing about its titles is
    // lost while it is.
    void theMissingDrivesRowsArtworkAndWatchStateAreKept()
    {
        Fixture f;
        QVERIFY(open(f, {}));
        QTRY_VERIFY_WITH_TIMEOUT(scanSettled(f, true), kScanTimeoutMs);
        QTest::qWait(150);

        QCOMPARE(catalogValue(QStringLiteral("SELECT COUNT(*) FROM media_items WHERE "
                                             "library_root_id IN (SELECT id FROM library_roots "
                                             "WHERE available = 0)")),
                 QStringLiteral("3"));
        QCOMPARE(catalogValue(QStringLiteral("SELECT COUNT(*) FROM media_items WHERE "
                                             "poster_path <> '' OR show_poster_path <> ''")),
                 QStringLiteral("6"));
        QCOMPARE(catalogValue(QStringLiteral("SELECT COUNT(*) FROM watch_progress WHERE "
                                             "position_ms = 600000")),
                 QStringLiteral("2"));
        QCOMPARE(catalogValue(QStringLiteral("SELECT COUNT(*) FROM library_roots "
                                             "WHERE available = 0")),
                 QStringLiteral("2"));
        QVERIFY2(gui_thread_io::mainThreadHits().isEmpty(),
                 qPrintable(describe(gui_thread_io::mainThreadHits())));
    }

    // A toast goes away; the notice is Home's own and stays while the drive
    // is missing.
    void homeKeepsANoticeNamingTheMissingFoldersWhileTheyAreMissing()
    {
        Fixture f;
        QVERIFY(open(f, {}));
        QTRY_VERIFY_WITH_TIMEOUT(scanSettled(f, true), kScanTimeoutMs);
        QCOMPARE(unavailableRoots(f).size(), 2);
        QVERIFY(unavailableRoots(f).contains(f.driveMovies()));
        QVERIFY(unavailableRoots(f).contains(f.driveShows()));

        QQuickItem *notice = nullptr;
        QTRY_VERIFY((notice = itemNamed(f.window, "homeLibraryNotice")) != nullptr);
        QTRY_VERIFY(notice->isVisible());
        const QString text = notice->property("text").toString();
        QVERIFY2(text.contains(f.driveMovies()), qPrintable(text));
        QVERIFY2(text.contains(f.driveShows()), qPrintable(text));
        QVERIFY2(text.contains(QStringLiteral("Settings")), qPrintable(text));
        QVERIFY2(text.contains(QStringLiteral("drive"), Qt::CaseInsensitive), qPrintable(text));
        // The projection a profile choice reloads lands after the scan ends.
        QTRY_VERIFY(itemNamed(f.window, "homeRowsViewport")->isVisible());
        QVERIFY(!itemNamed(f.window, "libraryEmptyState")->isVisible());

        // The toast is dismissed, a viewer walks the page, and the notice is
        // still on Home.
        f.controller->dismissError();
        QVERIFY(!f.controller->hasError());
        QTest::keyClick(f.window, Qt::Key_Right);
        QTest::keyClick(f.window, Qt::Key_Down);
        QTest::qWait(250);
        QVERIFY(notice->isVisible());
        QCOMPARE(unavailableRoots(f).size(), 2);
        QVERIFY2(gui_thread_io::mainThreadHits().isEmpty(),
                 qPrintable(describe(gui_thread_io::mainThreadHits())));
    }

    // With nothing readable Home is the empty library, the notices say what
    // to do, and the remote still reaches Settings.
    void whenEveryRootIsMissingHomeIsEmptyAndSettingsIsReachable()
    {
        Fixture f;
        QVERIFY(open(f, {.local = false}));
        QTRY_VERIFY_WITH_TIMEOUT(scanSettled(f, true), kScanTimeoutMs);

        QQuickItem *empty = itemNamed(f.window, "libraryEmptyState");
        QVERIFY(empty != nullptr);
        QTRY_VERIFY(empty->isVisible());
        QCOMPARE(f.controller->homeRows()->rowCount(), 0);
        QCOMPARE(f.controller->library()->titleCount(), 0);
        QVERIFY(!itemNamed(f.window, "homeRowsViewport")->isVisible());

        QQuickItem *detail = itemNamed(f.window, "libraryEmptyDetail");
        QVERIFY(detail != nullptr);
        const QString advice = detail->property("text").toString();
        QVERIFY2(advice.contains(QStringLiteral("Movies")) && advice.contains(QStringLiteral("TV"))
                     && advice.contains(QStringLiteral("Settings")),
                 qPrintable(advice));
        QQuickItem *notice = itemNamed(f.window, "libraryEmptyNotice");
        QVERIFY(notice != nullptr);
        QVERIFY(notice->isVisible());
        QVERIFY2(notice->property("text").toString().contains(f.driveMovies()),
                 qPrintable(notice->property("text").toString()));

        // The remote: Left from the empty Home reaches the sidebar, and the
        // sidebar opens Settings.
        QQuickItem *content = itemNamed(f.window, "contentFocus");
        QQuickItem *sidebar = itemNamed(f.window, "sidebar");
        QVERIFY(content != nullptr && sidebar != nullptr);
        QTRY_VERIFY(content->hasActiveFocus() || sidebar->hasActiveFocus());
        if (!sidebar->hasActiveFocus()) {
            QTest::keyClick(f.window, Qt::Key_Left);
            QTRY_VERIFY(sidebar->hasActiveFocus());
        }
        const int settingsIndex = sidebar->property("playSomethingIndex").toInt() - 1;
        for (int step = 0; step <= settingsIndex; ++step) {
            QTest::keyClick(f.window, Qt::Key_Up);
        }
        for (int step = 0; step < settingsIndex; ++step) {
            QTest::keyClick(f.window, Qt::Key_Down);
        }
        QCOMPARE(sidebar->property("focusedIndex").toInt(), settingsIndex);
        QTest::keyClick(f.window, Qt::Key_Return);
        QTRY_COMPARE(f.controller->navigation()->route(), NavigationController::Route::Settings);

        QVERIFY2(gui_thread_io::mainThreadHits().isEmpty(),
                 qPrintable(describe(gui_thread_io::mainThreadHits())));
    }

    void withNoRootsSetHomeIsEmptyAndAsksForMovieAndTvFolders()
    {
        Fixture f;
        QVERIFY(open(f, {.local = false, .drive = false}));
        QTRY_VERIFY(!f.controller->scanning());

        QQuickItem *empty = itemNamed(f.window, "libraryEmptyState");
        QVERIFY(empty != nullptr);
        QTRY_VERIFY(empty->isVisible());
        const QString advice = itemNamed(f.window, "libraryEmptyDetail")->property("text").toString();
        QVERIFY2(advice.contains(QStringLiteral("Movies")) && advice.contains(QStringLiteral("TV"))
                     && advice.contains(QStringLiteral("Settings")),
                 qPrintable(advice));
        QVERIFY(unavailableRoots(f).isEmpty());
        QQuickItem *notice = itemNamed(f.window, "libraryEmptyNotice");
        QVERIFY(notice == nullptr || !notice->isVisible());
        QQuickItem *pageNotice = itemNamed(f.window, "homeLibraryNotice");
        QVERIFY(pageNotice == nullptr || !pageNotice->isVisible());
    }

    // The next scan that reads the root brings its titles back, with the
    // watch state they kept.
    void theTitlesComeBackWhenAScanReadsTheRootAgain()
    {
        Fixture f;
        QVERIFY(open(f, {}));
        HomeRowsModel *rows = f.controller->homeRows();
        QTRY_VERIFY_WITH_TIMEOUT(scanSettled(f, true), kScanTimeoutMs);
        // The projection a profile choice reloads lands after the scan ends.
        QTRY_COMPARE(f.controller->library()->titleCount(), 2);
        QVERIFY(!homeTitles(rows).contains(QStringLiteral("Heat")));

        QVERIFY(f.plugIn());
        f.controller->requestCatalogRefresh();
        QTRY_VERIFY_WITH_TIMEOUT(scanSettled(f, false), kScanTimeoutMs);

        QTRY_COMPARE(f.controller->library()->titleCount(), 4);
        QCOMPARE(f.controller->shows()->showCount(), 2);
        QVERIFY(unavailableRoots(f).isEmpty());
        QTRY_VERIFY(rowIds(rows).contains(QStringLiteral("continue-watching")));
        const QStringList shown = homeTitles(rows);
        QVERIFY2(shown.contains(QStringLiteral("Heat")), qPrintable(shown.join(", ")));
        QCOMPARE(f.controller->library()
                     ->itemForId(f.seeded.idOf(QStringLiteral("Heat")))
                     ->resumePositionMs,
                 600'000);
        QQuickItem *notice = itemNamed(f.window, "homeLibraryNotice");
        QVERIFY(notice == nullptr || !notice->isVisible());
        f.controller->search()->setQuery(QStringLiteral("Dune"));
        QCOMPARE(f.controller->search()->rowCount(), 1);

        // And going away again hides them again.
        QVERIFY(f.unplug());
        gui_thread_io::watch(f.drive.path());
        f.controller->requestCatalogRefresh();
        QTRY_VERIFY_WITH_TIMEOUT(scanSettled(f, true), kScanTimeoutMs);
        QTRY_COMPARE(f.controller->library()->titleCount(), 2);
        QTest::qWait(150);
        QVERIFY2(gui_thread_io::mainThreadHits().isEmpty(),
                 qPrintable(describe(gui_thread_io::mainThreadHits())));
    }

    // Opening a title that was on screen when a scan found its root gone must
    // not stat it either.
    void aDetailsPageOpenOnATitleWhoseRootGoesMissingStaysOffTheDrive()
    {
        Fixture f;
        QVERIFY(open(f, {.unplugged = false}));
        QTRY_VERIFY(!f.controller->scanning());
        QTRY_COMPARE(f.controller->library()->titleCount(), 4);
        const QString dune = f.seeded.idOf(QStringLiteral("Dune"));
        f.controller->showMediaDetails(dune);
        QTRY_COMPARE(f.controller->navigation()->route(), NavigationController::Route::Details);
        QTRY_VERIFY(itemNamed(f.window, "detailsScreen") != nullptr);
        QTest::qWait(200);

        QVERIFY(f.unplug());
        gui_thread_io::watch(f.drive.path());
        f.controller->requestCatalogRefresh();
        QTRY_VERIFY_WITH_TIMEOUT(scanSettled(f, true), kScanTimeoutMs);
        QTRY_COMPARE(f.controller->library()->titleCount(), 2);
        QQuickItem *missing = nullptr;
        QTRY_VERIFY((missing = itemNamed(f.window, "detailsMissingState")) != nullptr);
        QTRY_VERIFY(missing->isVisible());
        QTest::qWait(200);
        QVERIFY2(gui_thread_io::mainThreadHits().isEmpty(),
                 qPrintable(describe(gui_thread_io::mainThreadHits())));
    }
};

QTEST_MAIN(UnavailableRootTest)
#include "tst_unavailable_root.moc"
