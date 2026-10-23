#include <QtTest>

#include <QDir>
#include <QFile>
#include <QScopeGuard>
#include <QTemporaryDir>

#include <filesystem>
#include <memory>
#include <optional>
#include <system_error>

#include "app/AppPaths.hpp"
#include "app/ApplicationController.hpp"
#include "catalog/MediaItem.hpp"
#include "models/LibraryModel.hpp"
#include "models/MovieRowsModel.hpp"
#include "models/ShowsModel.hpp"
#include "navigation/NavigationController.hpp"
#include "playback/PlayerController.hpp"
#include "profiles/ContentPolicy.hpp"
#include "profiles/ProfileStore.hpp"
#include "search/SearchSession.hpp"
#include "settings/SettingsStore.hpp"
#include "support/FileIdentity.hpp"

namespace
{
[[nodiscard]] bool writeFile(const QString &path)
{
    QDir().mkpath(QFileInfo(path).absolutePath());
    QFile file(path);
    return file.open(QIODevice::WriteOnly) && file.write("m") == 1;
}

// A second directory entry for the same inode, which is what a bind mount of
// the library gives every file: two paths, one device and inode.
[[nodiscard]] bool hardLink(const QString &target, const QString &link)
{
    std::error_code error;
    std::filesystem::create_hard_link(target.toStdString(), link.toStdString(), error);
    return !error;
}

// Both helpers start from Home, so the route afterwards says whether the
// player opened.
[[nodiscard]] bool looseFileRefused(ApplicationController &controller, const QString &path)
{
    controller.navigation()->resetTo(NavigationController::Route::Home);
    controller.dismissError();
    const QUrl before = controller.player()->currentFileUrl();
    controller.playLocalFile(path);
    return controller.hasError()
        && controller.player()->currentFileUrl() == before
        && controller.navigation()->route() == NavigationController::Route::Home;
}

[[nodiscard]] bool looseFilePlays(ApplicationController &controller, const QString &path)
{
    controller.navigation()->resetTo(NavigationController::Route::Home);
    controller.dismissError();
    controller.playLocalFile(path);
    return !controller.hasError()
        && controller.player()->currentFileUrl() == QUrl::fromLocalFile(path)
        && controller.navigation()->route() == NavigationController::Route::Player;
}

// A synthetic library. The Kids profile's ceiling is Family, so two movies and
// one show are allowed (a Kids folder, a Family folder holding an animated
// title, a show the offline table knows as Kids), and four movies and one show
// are not (Drama and Horror folders, an animated title with no Family signal,
// and a title nothing classifies).
constexpr int kAllowedMovies = 2;
constexpr int kBlockedMovies = 4;

[[nodiscard]] bool writeMovies(const QString &root)
{
    return writeFile(root + QStringLiteral("/Kids/Wonder (2017).mkv"))
        && writeFile(root + QStringLiteral("/Family/WALL-E (2008).mkv"))
        && writeFile(root + QStringLiteral("/Drama/Heat (1995).mkv"))
        && writeFile(root + QStringLiteral("/Horror/Midnight Blood Moon (2020).mkv"))
        && writeFile(root + QStringLiteral("/Frozen (2013).mkv"))
        && writeFile(root + QStringLiteral("/Unsorted Film (2001).mkv"));
}

[[nodiscard]] bool writeShows(const QString &root)
{
    return writeFile(root
                     + QStringLiteral("/Bluey (2018)/Season 1/Bluey - S01E01 - Magic Xylophone.mkv"))
        && writeFile(root
                     + QStringLiteral("/Bluey (2018)/Season 1/Bluey - S01E02 - Hospital.mkv"))
        && writeFile(root
                     + QStringLiteral("/The Wire (2002)/Season 1/The Wire - S01E01 - The Target.mkv"))
        && writeFile(root
                     + QStringLiteral("/The Wire (2002)/Season 1/The Wire - S01E02 - The Detail.mkv"));
}

[[nodiscard]] QStringList movieTitles(const LibraryModel *library)
{
    QStringList titles;
    for (int row = 0; row < library->rowCount(); ++row) {
        titles.push_back(
            library->data(library->index(row), LibraryModel::TitleRole).toString());
    }
    titles.sort();
    return titles;
}

[[nodiscard]] QString movieId(const LibraryModel *library, const QString &title)
{
    for (int row = 0; row < library->rowCount(); ++row) {
        if (library->data(library->index(row), LibraryModel::TitleRole).toString() == title) {
            return library->data(library->index(row), LibraryModel::IdRole).toString();
        }
    }
    return {};
}

[[nodiscard]] QString episodeId(const ShowsModel *shows, const QString &showName, int episode)
{
    const ShowSummary *summary = shows->summary(showName);
    if (summary == nullptr) {
        return {};
    }
    for (const MediaItem &item : summary->episodes) {
        if (item.episodeNumber == episode) {
            return item.id;
        }
    }
    return {};
}

// Every title the Movies rows hold, across all rows.
[[nodiscard]] QStringList movieRowTitles(MovieRowsModel *rows)
{
    QStringList titles;
    for (int row = 0; row < rows->rowCount(); ++row) {
        auto *items = rows->data(rows->index(row, 0), MovieRowsModel::ItemsRole)
                          .value<LibraryModel *>();
        if (items != nullptr) {
            titles += movieTitles(items);
        }
    }
    titles.removeDuplicates();
    titles.sort();
    return titles;
}

[[nodiscard]] QStringList searchTitles(SearchSession *search, const QString &query)
{
    search->setQuery(query);
    QStringList titles;
    for (int row = 0; row < search->rowCount(); ++row) {
        titles.push_back(search->data(search->index(row), SearchSession::TitleRole).toString());
    }
    return titles;
}
}

class TestKidsContent : public QObject
{
    Q_OBJECT

    struct Shell
    {
        QTemporaryDir runtimeRoot;
        QTemporaryDir movies;
        QTemporaryDir shows;
        std::unique_ptr<ApplicationController> controller;

        ~Shell()
        {
            controller.reset();
            AppPaths::clearRuntimeRoot();
        }
    };

    [[nodiscard]] bool openShell(Shell &shell)
    {
        AppPaths::setRuntimeRoot(shell.runtimeRoot.path());
        if (!writeMovies(shell.movies.path()) || !writeShows(shell.shows.path())) {
            return false;
        }
        shell.controller = std::make_unique<ApplicationController>();
        shell.controller->setTemporaryLibraryRoot(shell.movies.path());
        shell.controller->setTemporaryTvShowsRoot(shell.shows.path());
        return QTest::qWaitFor([&] {
            return shell.controller->library()->rowCount() == kAllowedMovies + kBlockedMovies
                && shell.controller->shows()->episodeCount() == 4;
        });
    }

    [[nodiscard]] static QString profileNamed(ApplicationController &controller,
                                              const QString &name)
    {
        for (const Profile &profile : controller.profiles()->profiles()) {
            if (profile.name == name) {
                return profile.id;
            }
        }
        return {};
    }

    [[nodiscard]] static bool choose(ApplicationController &controller, const QString &name)
    {
        if (!controller.chooseProfile(profileNamed(controller, name))) {
            return false;
        }
        return QTest::qWaitFor([&] { return !controller.profileExitInFlight(); });
    }

private slots:
    void classificationFollowsTheReleasedMaturityRule()
    {
        const auto movie = [](const QString &relativePath, const QString &title) {
            MediaItem item;
            item.relativePath = relativePath;
            item.title = title;
            item.mediaKind = QStringLiteral("movie");
            return item;
        };
        using Maturity = ProfileStore::Maturity;
        const auto level = [](Maturity value) { return static_cast<int>(value); };

        // MaturityLevel.swift:75-82 with the Kids folder and Family folder
        // cases the projection harness pins (VerifyProjectionHarness.swift
        // :1631-1720).
        QCOMPARE(content_policy::maturityOf(movie("Kids/Wonder (2017).mkv", "Wonder")),
                 level(Maturity::Kids));
        QCOMPARE(content_policy::maturityOf(movie("Family/WALL-E (2008).mkv", "WALL-E")),
                 level(Maturity::Kids));
        QCOMPARE(content_policy::maturityOf(movie("Family/Little Women.mkv", "Little Women")),
                 level(Maturity::Family));
        // Animation alone is not a Kids signal.
        QCOMPARE(content_policy::maturityOf(movie("Frozen (2013).mkv", "Frozen")),
                 level(Maturity::Teen));
        QCOMPARE(content_policy::maturityOf(movie("Horror/Midnight Blood Moon.mkv", "Midnight")),
                 level(Maturity::Adult));
        QCOMPARE(content_policy::maturityOf(movie("Unsorted Film (2001).mkv", "Unsorted Film")),
                 level(Maturity::Adult));

        const MediaItem teen = movie("Drama/Heat (1995).mkv", "Heat");
        QVERIFY(content_policy::allows(level(Maturity::Adult), teen));
        QVERIFY(content_policy::allows(level(Maturity::Teen), teen));
        QVERIFY(!content_policy::allows(level(Maturity::Family), teen));
        QVERIFY(!content_policy::allows(level(Maturity::Kids), teen));
        // UserProfile.swift:73-75: a Kids profile admits through Family.
        QVERIFY(content_policy::allows(level(Maturity::Kids),
                                       movie("Family/Little Women.mkv", "Little Women")));
    }

    // MaturityLevel.swift:49-73 decides on the stored certification when there
    // is one, with the genres only breaking the PG and unknown cases.
    void aStoredCertificationDecidesTheMaturityAsTheReleasedAppDoes()
    {
        using Maturity = ProfileStore::Maturity;
        const auto level = [](Maturity value) { return static_cast<int>(value); };
        const auto rated = [](const QString &relativePath, const QString &certification,
                              const QStringList &genres = {}) {
            MediaItem item;
            item.relativePath = relativePath;
            item.title = QFileInfo(relativePath).completeBaseName();
            item.mediaKind = QStringLiteral("movie");
            auto metadata = std::make_shared<TitleMetadata>();
            metadata->tmdbId = 1;
            metadata->certification = certification;
            metadata->genres = genres;
            item.metadata = metadata;
            return item;
        };

        // Kids sees what the certification calls Kids even with no genre,
        // which the genre rule alone hides as Adult.
        QCOMPARE(content_policy::maturityOf(rated("Unsorted Film.mkv", "G")), level(Maturity::Kids));
        QCOMPARE(content_policy::maturityOf(rated("Unsorted Show.mkv", "TV-Y7-FV")),
                 level(Maturity::Kids));
        QCOMPARE(content_policy::maturityOf(rated("Unsorted Film.mkv", " rated g ")),
                 level(Maturity::Kids));
        QVERIFY(content_policy::allows(level(Maturity::Kids), rated("Unsorted Film.mkv", "TV-G")));

        // Kids does not see what the certification calls Adult, whatever the
        // folder says.
        QCOMPARE(content_policy::maturityOf(rated("Kids/Wonder (2017).mkv", "R")),
                 level(Maturity::Adult));
        QCOMPARE(content_policy::maturityOf(rated("Family/Fable.mkv", "TV-MA", {"Animation", "Family"})),
                 level(Maturity::Adult));
        QCOMPARE(content_policy::maturityOf(rated("Kids/Wonder (2017).mkv", "NR")),
                 level(Maturity::Adult));
        QVERIFY(!content_policy::allows(level(Maturity::Kids), rated("Kids/Wonder (2017).mkv", "NC-17")));
        QVERIFY(!content_policy::allows(level(Maturity::Teen), rated("Kids/Wonder (2017).mkv", "R")));
        QVERIFY(content_policy::allows(level(Maturity::Teen), rated("Heat.mkv", "PG-13")));
        QVERIFY(!content_policy::allows(level(Maturity::Family), rated("Heat.mkv", "TV-14")));

        // PG: Kids with a kids signal, Family with Family or Animation, else
        // Teen. TMDB's genres replace the folder's, so a Horror folder does
        // not lower a PG title that TMDB calls Animation.
        QCOMPARE(content_policy::maturityOf(rated("Frozen (2013).mkv", "PG", {"Animation", "Family"})),
                 level(Maturity::Kids));
        QCOMPARE(content_policy::maturityOf(rated("Frozen (2013).mkv", "PG", {"Animation"})),
                 level(Maturity::Family));
        QCOMPARE(content_policy::maturityOf(rated("Heat.mkv", "PG", {"Crime"})),
                 level(Maturity::Teen));
        QCOMPARE(content_policy::maturityOf(rated("Heat.mkv", "TV-PG")), level(Maturity::Teen));
        QVERIFY(!content_policy::allows(level(Maturity::Kids), rated("Heat.mkv", "PG", {"Crime"})));

        // A certification the table does not know falls to the genres, and a
        // title with none of the family signals is Adult.
        QCOMPARE(content_policy::maturityOf(rated("Foreign.mkv", "FSK 12")), level(Maturity::Adult));
        QCOMPARE(content_policy::maturityOf(rated("Foreign.mkv", "FSK 0", {"Kids"})),
                 level(Maturity::Kids));
        QCOMPARE(content_policy::maturityOf(rated("Foreign.mkv", "FSK 6", {"Family"})),
                 level(Maturity::Family));
        QCOMPARE(content_policy::maturityOf(rated("Foreign.mkv", "FSK 6", {"Comedy"})),
                 level(Maturity::Adult));
    }

    void aTitleWithMetadataButNoCertificationFallsBackToItsGenres()
    {
        using Maturity = ProfileStore::Maturity;
        MediaItem item;
        item.relativePath = QStringLiteral("Unsorted Film.mkv");
        item.title = QStringLiteral("Unsorted Film");
        item.mediaKind = QStringLiteral("movie");
        auto metadata = std::make_shared<TitleMetadata>();
        metadata->tmdbId = 1;
        metadata->genres = {QStringLiteral("Kids")};
        item.metadata = metadata;
        // displayGenres: TMDB's list, with no certification to consult.
        QCOMPARE(content_policy::maturityOf(item), static_cast<int>(Maturity::Kids));

        metadata = std::make_shared<TitleMetadata>(*item.metadata);
        metadata->genres = {QStringLiteral("Horror")};
        item.metadata = metadata;
        QCOMPARE(content_policy::maturityOf(item), static_cast<int>(Maturity::Adult));

        // No metadata at all keeps the offline rule.
        item.metadata = nullptr;
        QCOMPARE(content_policy::maturityOf(item), static_cast<int>(Maturity::Adult));
    }

    void aKidsProjectionHoldsTheTitlesTheCertificationAdmits()
    {
        using Maturity = ProfileStore::Maturity;
        const auto certified = [](const QString &title, const QString &certification) {
            MediaItem item;
            item.id = title;
            item.relativePath = title + QStringLiteral(".mkv");
            item.title = title;
            item.mediaKind = QStringLiteral("movie");
            auto metadata = std::make_shared<TitleMetadata>();
            metadata->tmdbId = 1;
            metadata->certification = certification;
            item.metadata = metadata;
            return item;
        };
        const QVector<MediaItem> visible = content_policy::filtered(
            static_cast<int>(Maturity::Kids),
            {certified(QStringLiteral("Gentle"), QStringLiteral("G")),
             certified(QStringLiteral("Gritty"), QStringLiteral("R")),
             certified(QStringLiteral("Show"), QStringLiteral("TV-Y")),
             certified(QStringLiteral("Teenish"), QStringLiteral("PG-13"))});
        QStringList ids;
        for (const MediaItem &item : visible) {
            ids.push_back(item.id);
        }
        QCOMPARE(ids, (QStringList{QStringLiteral("Gentle"), QStringLiteral("Show")}));
    }

    void folderGenreIsCapitalizedLikeTheReleasedApp()
    {
        const auto movie = [](const QString &relativePath) {
            MediaItem item;
            item.relativePath = relativePath;
            item.mediaKind = QStringLiteral("movie");
            return item;
        };
        // Swift's `capitalized` uppercases the letter after a hyphen too.
        QCOMPARE(content_policy::folderGenreOf(movie("sci-fi/Arrival (2016).mkv")),
                 QStringLiteral("Sci-Fi"));
        QCOMPARE(content_policy::folderGenreOf(movie("FILM NOIR/Laura (1944).mkv")),
                 QStringLiteral("Film Noir"));
        QCOMPARE(content_policy::folderGenreOf(movie("Drama/Heat (1995).mkv")),
                 QStringLiteral("Drama"));
    }

    void anAdultProfileSeesTheWholeLibrary()
    {
        Shell shell;
        QVERIFY(openShell(shell));
        QVERIFY(choose(*shell.controller, QStringLiteral("Main")));

        QCOMPARE(shell.controller->library()->rowCount(), kAllowedMovies + kBlockedMovies);
        QCOMPARE(shell.controller->shows()->showCount(), 2);
        QCOMPARE(shell.controller->shows()->episodeCount(), 4);
    }

    void aKidsProfileSeesOnlyAllowedMovies()
    {
        Shell shell;
        QVERIFY(openShell(shell));
        QVERIFY(choose(*shell.controller, QStringLiteral("Kids")));
        QVERIFY(shell.controller->kidsMode());

        const QStringList allowed{QStringLiteral("WALL-E"), QStringLiteral("Wonder")};
        // Home and the Movies grid read the library model, its count, and the
        // movie rows.
        QCOMPARE(movieTitles(shell.controller->library()), allowed);
        QCOMPARE(shell.controller->library()->titleCount(), kAllowedMovies);
        QCOMPARE(shell.controller->movieRows()->titleCount(), kAllowedMovies);
        QCOMPARE(movieRowTitles(shell.controller->movieRows()), allowed);
    }

    void aKidsProfileSeesOnlyAllowedShowsAndEpisodes()
    {
        Shell shell;
        QVERIFY(openShell(shell));
        QVERIFY(choose(*shell.controller, QStringLiteral("Kids")));

        ShowsModel *shows = shell.controller->shows();
        QCOMPARE(shows->showCount(), 1);
        QCOMPARE(shows->episodeCount(), 2);
        QVERIFY(shows->summary(QStringLiteral("Bluey")) != nullptr);
        QVERIFY(shows->summary(QStringLiteral("The Wire")) == nullptr);
        QVERIFY(shows->showDetails(QStringLiteral("The Wire")).isEmpty());
        QVERIFY(shows->episodesOf(QStringLiteral("The Wire"), 1).isEmpty());
        QCOMPARE(shows->episodesOf(QStringLiteral("Bluey"), 1).size(), 2);
        // Every grid row holds only the allowed show.
        for (int row = 0; row < shows->rowCount(); ++row) {
            QCOMPARE(shows->data(shows->index(row, 0), ShowsModel::ShowCountRole).toInt(), 1);
        }
    }

    void searchNeverReturnsABlockedTitle()
    {
        Shell shell;
        QVERIFY(openShell(shell));
        SearchSession *search = shell.controller->search();

        QCOMPARE(searchTitles(search, QStringLiteral("heat")), QStringList{QStringLiteral("Heat")});

        QVERIFY(choose(*shell.controller, QStringLiteral("Kids")));
        QVERIFY(searchTitles(search, QStringLiteral("heat")).isEmpty());
        QVERIFY(searchTitles(search, QStringLiteral("midnight")).isEmpty());
        QVERIFY(searchTitles(search, QStringLiteral("unsorted")).isEmpty());
        QCOMPARE(searchTitles(search, QStringLiteral("wonder")),
                 QStringList{QStringLiteral("Wonder")});
        QVERIFY(!search->suggestions().join(QLatin1Char(' ')).contains(QStringLiteral("Heat")));
    }

    void aBlockedTitleDoesNotPlayOrOpenByDirectId()
    {
        Shell shell;
        QVERIFY(openShell(shell));
        ApplicationController &controller = *shell.controller;

        const QString heatId = movieId(controller.library(), QStringLiteral("Heat"));
        const QString wonderId = movieId(controller.library(), QStringLiteral("Wonder"));
        const QString wireId = episodeId(controller.shows(), QStringLiteral("The Wire"), 1);
        const QString blueyId = episodeId(controller.shows(), QStringLiteral("Bluey"), 1);
        QVERIFY(!heatId.isEmpty() && !wonderId.isEmpty());
        QVERIFY(!wireId.isEmpty() && !blueyId.isEmpty());
        const QString heatPath = QDir(shell.movies.path()).filePath(QStringLiteral("Drama/Heat (1995).mkv"));

        QVERIFY(choose(controller, QStringLiteral("Kids")));
        controller.dismissError();

        for (const QString &blocked : {heatId, wireId}) {
            controller.navigation()->resetTo(NavigationController::Route::Home);
            controller.dismissError();

            controller.playMediaId(blocked);
            QVERIFY2(controller.player()->mediaId().isEmpty(), "a blocked title reached the player");
            QVERIFY(controller.player()->currentFileUrl().isEmpty());
            QCOMPARE(controller.navigation()->route(), NavigationController::Route::Home);
            QVERIFY(controller.hasError());
            QVERIFY(!controller.errorMessage().contains(QStringLiteral("Heat")));

            controller.dismissError();
            controller.showMediaDetails(blocked);
            QCOMPARE(controller.navigation()->route(), NavigationController::Route::Home);
            QVERIFY(controller.hasError());
        }

        controller.dismissError();
        controller.playLocalFile(heatPath);
        QVERIFY(controller.player()->currentFileUrl().isEmpty());
        QVERIFY(controller.hasError());

        // The same file reached through `..` or through a symlink is still
        // that title.
        const QString dotDotPath = shell.movies.path()
            + QStringLiteral("/Drama/../Drama/Heat (1995).mkv");
        const QString linkPath = shell.runtimeRoot.filePath(QStringLiteral("innocent.mkv"));
        QVERIFY(QFile::link(heatPath, linkPath));
        for (const QString &alias : {dotDotPath, linkPath}) {
            controller.dismissError();
            controller.playLocalFile(alias);
            QVERIFY2(controller.player()->currentFileUrl().isEmpty(),
                     qPrintable(QStringLiteral("a blocked file played through %1").arg(alias)));
            QVERIFY(controller.hasError());
            QCOMPARE(controller.navigation()->route(), NavigationController::Route::Home);
        }

        // Allowed titles still play, so the block is the profile and not a
        // broken play path.
        controller.dismissError();
        controller.playMediaId(wonderId);
        QCOMPARE(controller.player()->mediaId(), wonderId);
        QVERIFY2(!controller.hasError(), qPrintable(controller.errorMessage()));
        QCOMPARE(controller.navigation()->route(), NavigationController::Route::Player);

        controller.navigation()->resetTo(NavigationController::Route::Home);
        controller.playMediaId(blueyId);
        QCOMPARE(controller.player()->mediaId(), blueyId);
        QVERIFY(controller.continueAfterPlayback(blueyId));
        QCOMPARE(controller.player()->mediaId(),
                 episodeId(controller.shows(), QStringLiteral("Bluey"), 2));
    }

    // A controller whose first scan cannot have landed, since no event has
    // run. `profile` empty leaves no profile chosen.
    [[nodiscard]] bool openUnscannedShell(Shell &shell, const QString &profile)
    {
        AppPaths::setRuntimeRoot(shell.runtimeRoot.path());
        if (!writeMovies(shell.movies.path())) {
            return false;
        }
        shell.controller = std::make_unique<ApplicationController>();
        return profile.isEmpty()
            || shell.controller->chooseProfile(profileNamed(*shell.controller, profile));
    }

    void aKidsProfileGetsNoLooseFileBeforeTheFirstScanArrives()
    {
        const QString heatName = QStringLiteral("Drama/Heat (1995).mkv");

        // The same call plays for an Adult profile and for no profile, so the
        // refusal below is the Kids gate and not a broken loose-file path.
        for (const QString &profile : {QString(), QStringLiteral("Main")}) {
            Shell open;
            QVERIFY(openUnscannedShell(open, profile));
            open.controller->playLocalFile(QDir(open.movies.path()).filePath(heatName));
            QVERIFY2(!open.controller->player()->currentFileUrl().isEmpty(),
                     qPrintable(QStringLiteral("profile '%1' was refused").arg(profile)));
            QVERIFY2(!open.controller->hasError(), qPrintable(open.controller->errorMessage()));
            QCOMPARE(open.controller->navigation()->route(),
                     NavigationController::Route::Player);
        }

        Shell shell;
        QVERIFY(openUnscannedShell(shell, QStringLiteral("Kids")));
        ApplicationController &controller = *shell.controller;
        const QString heatPath = QDir(shell.movies.path()).filePath(heatName);
        const QString wonderPath = QDir(shell.movies.path()).filePath(
            QStringLiteral("Kids/Wonder (2017).mkv"));

        // Even an allowed file is refused: the catalog cannot yet say which
        // files are hidden.
        for (const QString &path : {heatPath, wonderPath}) {
            controller.dismissError();
            controller.playLocalFile(path);
            QVERIFY(controller.player()->currentFileUrl().isEmpty());
            QVERIFY(controller.hasError());
            QVERIFY(controller.navigation()->route() != NavigationController::Route::Player);
        }

        // Once the scan has landed the allowed file plays and the hidden one
        // stays refused.
        shell.controller->setTemporaryLibraryRoot(shell.movies.path());
        QVERIFY(QTest::qWaitFor([&] {
            return controller.library()->rowCount() == kAllowedMovies;
        }));
        controller.dismissError();
        controller.playLocalFile(wonderPath);
        QVERIFY2(!controller.player()->currentFileUrl().isEmpty(),
                 qPrintable(controller.errorMessage()));
        QVERIFY(!controller.hasError());

        controller.navigation()->resetTo(NavigationController::Route::Home);
        controller.dismissError();
        controller.playLocalFile(heatPath);
        QVERIFY(controller.hasError());
        QCOMPARE(controller.navigation()->route(), NavigationController::Route::Home);
    }

    void anAdultProfileOrNoProfilePlaysAHiddenLooseFile()
    {
        // The catalog lookup resolves every catalog path on the GUI thread, so
        // only a restricted profile may pay for it. That the lookup is skipped
        // cannot be observed from here; what is pinned is that Adult and no
        // profile play a file Kids refuses, directly and through a symlink.
        Shell shell;
        QVERIFY(openShell(shell));
        ApplicationController &controller = *shell.controller;
        const QString heatPath = QDir(shell.movies.path()).filePath(
            QStringLiteral("Drama/Heat (1995).mkv"));
        const QString linkPath = shell.runtimeRoot.filePath(QStringLiteral("innocent.mkv"));
        QVERIFY(QFile::link(heatPath, linkPath));

        const auto playsBoth = [&](const QString &label) {
            for (const QString &path : {heatPath, linkPath}) {
                controller.navigation()->resetTo(NavigationController::Route::Home);
                controller.dismissError();
                controller.playLocalFile(path);
                QVERIFY2(!controller.player()->currentFileUrl().isEmpty(),
                         qPrintable(QStringLiteral("%1 was refused %2").arg(label, path)));
                QVERIFY2(!controller.hasError(), qPrintable(controller.errorMessage()));
                QCOMPARE(controller.navigation()->route(), NavigationController::Route::Player);
            }
        };
        playsBoth(QStringLiteral("no profile"));
        QVERIFY(choose(controller, QStringLiteral("Main")));
        playsBoth(QStringLiteral("Adult"));
    }

    // The identity rule is judged on a hard link: two paths whose canonical
    // paths differ and whose device and inode match. A bind mount of the
    // library gives every file the same pair of names, so this covers it too.
    void aHardLinkToAHiddenTitleIsRefusedForKidsAndPlaysForAdult()
    {
        Shell shell;
        QVERIFY(openShell(shell));
        ApplicationController &controller = *shell.controller;
        const QString heatPath = QDir(shell.movies.path()).filePath(
            QStringLiteral("Drama/Heat (1995).mkv"));
        const QString wonderPath = QDir(shell.movies.path()).filePath(
            QStringLiteral("Kids/Wonder (2017).mkv"));
        const QString heatLink = shell.runtimeRoot.filePath(QStringLiteral("not-heat.mkv"));
        const QString wonderLink = shell.runtimeRoot.filePath(QStringLiteral("not-wonder.mkv"));
        QVERIFY(hardLink(heatPath, heatLink));
        QVERIFY(hardLink(wonderPath, wonderLink));

        // The premise: no path comparison relates the two names.
        QVERIFY(QFileInfo(heatLink).canonicalFilePath() != QFileInfo(heatPath).canonicalFilePath());
        const std::optional<FileIdentity> heatIdentity = readFileIdentity(heatPath);
        QVERIFY(heatIdentity.has_value());
        QVERIFY(readFileIdentity(heatLink) == heatIdentity);
        QVERIFY(readFileIdentity(wonderLink) != heatIdentity);

        QVERIFY2(looseFilePlays(controller, heatLink), "no profile was refused");

        QVERIFY(choose(controller, QStringLiteral("Kids")));
        QVERIFY2(looseFileRefused(controller, heatLink),
                 "a hard link to a hidden title played on a Kids profile");
        QVERIFY(!controller.errorMessage().contains(QStringLiteral("Heat")));
        // An allowed title's hard link still plays, so the refusal is the
        // identity match and not a blanket ban on links.
        QVERIFY2(looseFilePlays(controller, wonderLink), qPrintable(controller.errorMessage()));

        QVERIFY(choose(controller, QStringLiteral("Main")));
        QVERIFY2(looseFilePlays(controller, heatLink), "Adult was refused a hard link");

        // Back on Kids, the index is built for the profile again.
        QVERIFY(choose(controller, QStringLiteral("Kids")));
        QVERIFY(looseFileRefused(controller, heatLink));

        // A hidden file replaced in place keeps its path but not its inode.
        // The index was built before the swap, so only the canonical path can
        // still name it.
        const QString replacement = shell.runtimeRoot.filePath(QStringLiteral("replacement.mkv"));
        QVERIFY(writeFile(replacement));
        std::error_code error;
        std::filesystem::rename(replacement.toStdString(), heatPath.toStdString(), error);
        QVERIFY(!error);
        QVERIFY(readFileIdentity(heatPath) != heatIdentity);
        QVERIFY(looseFileRefused(controller, heatPath));
    }

    void aRescanKeepsTheHiddenFileIdentitiesCurrent()
    {
        Shell shell;
        QVERIFY(openShell(shell));
        ApplicationController &controller = *shell.controller;
        const QString heatLink = shell.runtimeRoot.filePath(QStringLiteral("not-heat.mkv"));
        QVERIFY(hardLink(QDir(shell.movies.path()).filePath(QStringLiteral("Drama/Heat (1995).mkv")),
                         heatLink));
        QVERIFY(choose(controller, QStringLiteral("Kids")));
        QVERIFY(looseFileRefused(controller, heatLink));

        // Titles that arrive in a rescan are sorted by the same rule: the
        // hidden one is refused through its link, the allowed one plays.
        const QString nightmare = QDir(shell.movies.path()).filePath(
            QStringLiteral("Horror/Another Nightmare (2021).mkv"));
        const QString paddington = QDir(shell.movies.path()).filePath(
            QStringLiteral("Kids/Paddington Tales (2019).mkv"));
        QVERIFY(writeFile(nightmare));
        QVERIFY(writeFile(paddington));
        const QString nightmareLink = shell.runtimeRoot.filePath(QStringLiteral("not-nightmare.mkv"));
        const QString paddingtonLink = shell.runtimeRoot.filePath(QStringLiteral("not-paddington.mkv"));
        QVERIFY(hardLink(nightmare, nightmareLink));
        QVERIFY(hardLink(paddington, paddingtonLink));
        controller.requestCatalogRefresh();
        QTRY_COMPARE(controller.library()->rowCount(), kAllowedMovies + 1);
        QTRY_VERIFY(!controller.scanning());

        QVERIFY2(looseFileRefused(controller, nightmareLink),
                 "a hard link to a title found by a rescan played on a Kids profile");
        QVERIFY(looseFileRefused(controller, heatLink));
        QVERIFY2(looseFilePlays(controller, paddingtonLink), qPrintable(controller.errorMessage()));
    }

    void aKidsProfileIsRefusedAFileWhoseIdentityCannotBeRead()
    {
        Shell shell;
        QVERIFY(openShell(shell));
        ApplicationController &controller = *shell.controller;
        // Wonder is allowed, so the only thing that can refuse it is the
        // identity read failing.
        const QString wonderPath = QDir(shell.movies.path()).filePath(
            QStringLiteral("Kids/Wonder (2017).mkv"));
        int reads = 0;
        controller.setFileIdentityReaderForTest([&reads](const QString &) {
            ++reads;
            return std::optional<FileIdentity>();
        });

        // Adult and no profile never look: the unreadable identity costs them
        // nothing and does not stop them.
        QVERIFY2(looseFilePlays(controller, wonderPath), "no profile was refused");
        QVERIFY(choose(controller, QStringLiteral("Main")));
        QVERIFY2(looseFilePlays(controller, wonderPath), "Adult was refused");
        QCOMPARE(reads, 0);

        QVERIFY(choose(controller, QStringLiteral("Kids")));
        QVERIFY2(looseFileRefused(controller, wonderPath),
                 "a file with no readable identity played on a Kids profile");
        QVERIFY(controller.errorMessage().contains(QStringLiteral("No readable media file")));
        QVERIFY(reads > 0);

        // With the reader back, the same file plays.
        controller.setFileIdentityReaderForTest({});
        QVERIFY2(looseFilePlays(controller, wonderPath), qPrintable(controller.errorMessage()));
    }

    // A disk remounted under the same path answers with a new device number
    // while no rescan or profile change runs, so nothing rebuilds the index.
    void aHardLinkToAHiddenTitleStaysRefusedAfterItsDiskIsRemounted()
    {
        Shell shell;
        QVERIFY(openShell(shell));
        ApplicationController &controller = *shell.controller;
        const QString heatPath = QDir(shell.movies.path()).filePath(
            QStringLiteral("Drama/Heat (1995).mkv"));
        const QString wonderPath = QDir(shell.movies.path()).filePath(
            QStringLiteral("Kids/Wonder (2017).mkv"));
        const QString heatLink = shell.runtimeRoot.filePath(QStringLiteral("not-heat.mkv"));
        const QString wonderLink = shell.runtimeRoot.filePath(QStringLiteral("not-wonder.mkv"));
        QVERIFY(hardLink(heatPath, heatLink));
        QVERIFY(hardLink(wonderPath, wonderLink));

        // Every name on the disk reports the device it is mounted as.
        quint64 mountedAs = 0;
        int reads = 0;
        const auto remountable = [&](const QString &path) {
            ++reads;
            std::optional<FileIdentity> identity = readFileIdentity(path);
            if (identity) {
                identity->device += mountedAs;
            }
            return identity;
        };
        controller.setFileIdentityReaderForTest(remountable);

        QVERIFY2(looseFilePlays(controller, heatLink), "no profile was refused");
        QVERIFY(choose(controller, QStringLiteral("Main")));
        QVERIFY2(looseFilePlays(controller, heatLink), "Adult was refused");
        QCOMPARE(reads, 0);

        QVERIFY(choose(controller, QStringLiteral("Kids")));
        QVERIFY(looseFileRefused(controller, heatLink));
        QVERIFY(looseFilePlays(controller, wonderLink));
        QVERIFY(reads > 0);

        const std::optional<FileIdentity> before = remountable(heatLink);
        mountedAs = 1;
        const std::optional<FileIdentity> after = remountable(heatLink);
        QVERIFY(before.has_value() && after.has_value());
        QVERIFY2(*before != *after, "the remount did not change the identity");

        QVERIFY2(looseFileRefused(controller, heatLink),
                 "a hard link to a hidden title played after its disk was remounted");
        QVERIFY(looseFileRefused(controller, heatPath));
        // The allowed title's link still plays under the new device number,
        // so the refusal is the match and not a failure of the read.
        QVERIFY2(looseFilePlays(controller, wonderLink), qPrintable(controller.errorMessage()));
    }

    // Nothing can say a file is not a hidden title when that title cannot be
    // read, so a restricted profile gets no loose file until it can be.
    void aHiddenTitleThatWasUnreadableWhenIndexedIsCoveredOnceItCanBeRead()
    {
        Shell shell;
        QVERIFY(openShell(shell));
        ApplicationController &controller = *shell.controller;
        const QString heatPath = QDir(shell.movies.path()).filePath(
            QStringLiteral("Drama/Heat (1995).mkv"));
        const QString wonderPath = QDir(shell.movies.path()).filePath(
            QStringLiteral("Kids/Wonder (2017).mkv"));
        const QString heatLink = shell.runtimeRoot.filePath(QStringLiteral("not-heat.mkv"));
        QVERIFY(hardLink(heatPath, heatLink));
        const QString heatCanonical = QFileInfo(heatPath).canonicalFilePath();

        // Heat's root is offline while loose files are checked.
        bool heatReadable = false;
        int reads = 0;
        controller.setFileIdentityReaderForTest([&](const QString &path) {
            ++reads;
            return path == heatCanonical && !heatReadable
                ? std::optional<FileIdentity>()
                : readFileIdentity(path);
        });

        QVERIFY2(looseFilePlays(controller, wonderPath), "no profile was refused");
        QVERIFY(choose(controller, QStringLiteral("Main")));
        QVERIFY2(looseFilePlays(controller, wonderPath), "Adult was refused");
        QCOMPARE(reads, 0);

        QVERIFY(choose(controller, QStringLiteral("Kids")));
        QVERIFY2(looseFileRefused(controller, wonderPath),
                 "a loose file played while a hidden title could not be read");
        QVERIFY(controller.errorMessage().contains(QStringLiteral("not available")));
        // Asking again does not turn the refusal into a pass.
        QVERIFY(looseFileRefused(controller, wonderPath));
        QVERIFY(looseFileRefused(controller, heatLink));

        // Heat comes back: Wonder is not the same file as any hidden title and
        // plays, and the link to Heat is covered.
        heatReadable = true;
        QVERIFY2(looseFilePlays(controller, wonderPath), qPrintable(controller.errorMessage()));
        QVERIFY2(looseFileRefused(controller, heatLink),
                 "a hidden title that came back after indexing was never covered");
    }

    void switchingProfilesRefreshesEverySurface()
    {
        Shell shell;
        QVERIFY(openShell(shell));
        ApplicationController &controller = *shell.controller;
        const QString heatId = movieId(controller.library(), QStringLiteral("Heat"));
        QVERIFY(!heatId.isEmpty());

        QVERIFY(choose(controller, QStringLiteral("Kids")));
        QCOMPARE(controller.library()->rowCount(), kAllowedMovies);
        QCOMPARE(controller.shows()->showCount(), 1);

        // The profile picker is reached again and the adult profile chosen: the
        // hidden titles return without a rescan.
        controller.switchProfile();
        QVERIFY(choose(controller, QStringLiteral("Main")));
        QVERIFY(!controller.kidsMode());
        QCOMPARE(controller.library()->rowCount(), kAllowedMovies + kBlockedMovies);
        QCOMPARE(controller.movieRows()->titleCount(), kAllowedMovies + kBlockedMovies);
        QCOMPARE(controller.shows()->showCount(), 2);
        QCOMPARE(searchTitles(controller.search(), QStringLiteral("heat")),
                 QStringList{QStringLiteral("Heat")});
        controller.playMediaId(heatId);
        QCOMPARE(controller.player()->mediaId(), heatId);
        controller.player()->reportPlayback(600.0, 7200.0, true);

        // And back: the kids profile hides them again.
        controller.navigation()->resetTo(NavigationController::Route::Home);
        controller.switchProfile();
        QVERIFY(choose(controller, QStringLiteral("Kids")));
        QCOMPARE(controller.library()->rowCount(), kAllowedMovies);
        QVERIFY(searchTitles(controller.search(), QStringLiteral("heat")).isEmpty());

        // Progress recorded while the title was hidden from the model still
        // reaches it when the adult profile returns.
        controller.switchProfile();
        QVERIFY(choose(controller, QStringLiteral("Main")));
        const std::optional<MediaItem> heat = controller.library()->itemForId(heatId);
        QVERIFY(heat.has_value());
        QCOMPARE(heat->resumePositionMs, qint64{600000});
    }

    void editingTheActiveProfilesMaturityRefreshesTheSurfaces()
    {
        Shell shell;
        QVERIFY(openShell(shell));
        ApplicationController &controller = *shell.controller;

        QVERIFY(choose(controller, QStringLiteral("Main")));
        QCOMPARE(controller.library()->rowCount(), kAllowedMovies + kBlockedMovies);

        const QString mainId = profileNamed(controller, QStringLiteral("Main"));
        const Profile main = *controller.profiles()->profile(mainId);
        controller.profiles()->updateProfile(
            mainId, main.name, main.avatarIcon, main.avatarColor,
            static_cast<int>(ProfileStore::Maturity::Kids));
        QCOMPARE(controller.library()->rowCount(), kAllowedMovies);
        QCOMPARE(controller.shows()->showCount(), 1);

        controller.profiles()->updateProfile(
            mainId, main.name, main.avatarIcon, main.avatarColor,
            static_cast<int>(ProfileStore::Maturity::Adult));
        QCOMPARE(controller.library()->rowCount(), kAllowedMovies + kBlockedMovies);
    }

    void aRescanKeepsTheKidsFilter()
    {
        Shell shell;
        QVERIFY(openShell(shell));
        ApplicationController &controller = *shell.controller;
        QVERIFY(choose(controller, QStringLiteral("Kids")));

        QVERIFY(writeFile(shell.movies.path() + QStringLiteral("/Horror/Another Nightmare (2021).mkv")));
        QVERIFY(writeFile(shell.movies.path() + QStringLiteral("/Kids/Paddington Tales (2019).mkv")));
        controller.requestCatalogRefresh();
        QTRY_COMPARE(controller.library()->rowCount(), kAllowedMovies + 1);
        QTRY_VERIFY(!controller.scanning());
        QVERIFY(!movieTitles(controller.library()).contains(QStringLiteral("Another Nightmare")));
        QVERIFY(movieTitles(controller.library()).contains(QStringLiteral("Paddington Tales")));
    }

    void aKidsProfileChosenBeforeTheFirstScanFiltersTheFirstProjection()
    {
        Shell shell;
        AppPaths::setRuntimeRoot(shell.runtimeRoot.path());
        QVERIFY(writeMovies(shell.movies.path()));
        shell.controller = std::make_unique<ApplicationController>();
        QVERIFY(choose(*shell.controller, QStringLiteral("Kids")));
        shell.controller->setTemporaryLibraryRoot(shell.movies.path());

        QTRY_COMPARE(shell.controller->library()->rowCount(), kAllowedMovies);
        // Never an interval where the full library is on screen.
        QCOMPARE(movieTitles(shell.controller->library()),
                 (QStringList{QStringLiteral("WALL-E"), QStringLiteral("Wonder")}));
    }
};

QTEST_MAIN(TestKidsContent)
#include "tst_kids_content.moc"
