#include <QDir>
#include <QFile>
#include <QFileDevice>
#include <QFileInfo>
#include <QIODevice>
#include <QScopeGuard>
#include <QSignalSpy>
#include <QTemporaryDir>
#include <QVariant>
#include <QtTest>

#include "catalog/CatalogDatabase.hpp"
#include "catalog/CatalogStore.hpp"
#include "catalog/LibraryScanner.hpp"
#include "models/ShowsModel.hpp"

namespace
{
[[nodiscard]] bool writeFile(const QString &root, const QString &relativePath,
                             const QByteArray &contents)
{
    const QFileInfo target(QDir(root).filePath(relativePath));
    if (!QDir().mkpath(target.absolutePath())) {
        return false;
    }
    QFile file(target.absoluteFilePath());
    if (!file.open(QIODevice::WriteOnly)) {
        return false;
    }
    return file.write(contents) == contents.size();
}

[[nodiscard]] bool writeMediaFile(const QString &root, const QString &relativePath)
{
    return writeFile(root, relativePath, QByteArrayLiteral("media"));
}

[[nodiscard]] LibraryRoot tvRootAt(const QString &path)
{
    return {.id = QStringLiteral("tv-root"),
            .path = path,
            .displayName = QStringLiteral("TV Shows"),
            .available = false,
            .role = LibraryRoot::Role::TvShows};
}

// One show with two seasons of two episodes and a second show with one, the
// Plex shape CatalogContentPolicy.swift documents.
[[nodiscard]] bool writeTvFixture(const QString &root)
{
    return writeMediaFile(root, QStringLiteral("The Wire (2002)/Season 1/The Wire - S01E01 - The Target.mkv"))
        && writeMediaFile(root, QStringLiteral("The Wire (2002)/Season 1/The Wire - S01E02 - The Detail.mkv"))
        && writeMediaFile(root, QStringLiteral("The Wire (2002)/Season 2/The Wire - S02E01 - Ebb Tide.mkv"))
        && writeMediaFile(root, QStringLiteral("The Wire (2002)/Season 2/The Wire - S02E02 - Collateral Damage.mkv"))
        && writeMediaFile(root, QStringLiteral("Bluey (2018)/Season 1/S01E01 Magic Xylophone.mkv"));
}
}

class TvScannerTest : public QObject
{
    Q_OBJECT

private slots:
    void parsesDashedEpisodeNamesWithTitles()
    {
        LibraryScanner::ParsedEpisode episode;
        QVERIFY(LibraryScanner::parseEpisodeFilename(
            QStringLiteral("Show - S01E02 - Spider-Man.mkv"), episode));
        QCOMPARE(episode.showName, QStringLiteral("Show"));
        QCOMPARE(episode.seasonNumber, 1);
        QCOMPARE(episode.episodeNumber, 2);
        QCOMPARE(episode.episodeTitle, QStringLiteral("Spider-Man"));
    }

    void parsesDottedSceneNamesAndCleansTheTitle()
    {
        LibraryScanner::ParsedEpisode episode;
        QVERIFY(LibraryScanner::parseEpisodeFilename(
            QStringLiteral("The.Office.S03E01.Gay.Witch.Hunt.1080p.mkv"), episode));
        QCOMPARE(episode.showName, QStringLiteral("The Office"));
        QCOMPARE(episode.seasonNumber, 3);
        QCOMPARE(episode.episodeNumber, 1);
        QCOMPARE(episode.episodeTitle, QStringLiteral("Gay Witch Hunt"));
    }

    void parsesTheCrossNotation()
    {
        LibraryScanner::ParsedEpisode episode;
        QVERIFY(LibraryScanner::parseEpisodeFilename(
            QStringLiteral("Seinfeld - 4x11 - The Contest.mkv"), episode));
        QCOMPARE(episode.showName, QStringLiteral("Seinfeld"));
        QCOMPARE(episode.seasonNumber, 4);
        QCOMPARE(episode.episodeNumber, 11);
        QCOMPARE(episode.episodeTitle, QStringLiteral("The Contest"));
    }

    void aMovieNameIsNotAnEpisode()
    {
        LibraryScanner::ParsedEpisode episode;
        QVERIFY(!LibraryScanner::parseEpisodeFilename(
            QStringLiteral("Arrival (2016).mkv"), episode));
    }

    void parsesAPrefixedNameInsideItsSeasonFolder()
    {
        LibraryScanner::ParsedEpisode episode;
        QVERIFY(LibraryScanner::parseEpisodeFromFolder(
            QStringLiteral("S01E01 Joe Pera Shows You Iron.mkv"), 1, episode));
        QVERIFY(episode.showName.isEmpty());
        QCOMPARE(episode.episodeNumber, 1);
        QCOMPARE(episode.episodeTitle, QStringLiteral("Joe Pera Shows You Iron"));
    }

    void aPrefixedNameMustAgreeWithItsSeasonFolder()
    {
        LibraryScanner::ParsedEpisode episode;
        QVERIFY(!LibraryScanner::parseEpisodeFromFolder(
            QStringLiteral("S02E01 Wrong Season.mkv"), 1, episode));
    }

    void parsesABareNumberedNameInsideItsSeasonFolder()
    {
        LibraryScanner::ParsedEpisode episode;
        QVERIFY(LibraryScanner::parseEpisodeFromFolder(
            QStringLiteral("Fosters Home 501 Title.mkv"), 5, episode));
        QCOMPARE(episode.showName, QStringLiteral("Fosters Home"));
        QCOMPARE(episode.seasonNumber, 5);
        QCOMPARE(episode.episodeNumber, 1);
        QCOMPARE(episode.episodeTitle, QStringLiteral("Title"));
    }

    void readsTheSeasonNumberFromAnyPathComponent()
    {
        QCOMPARE(LibraryScanner::seasonNumberFromPath(
                     QStringLiteral("The Wire (2002)/Season 3")), 3);
        QCOMPARE(LibraryScanner::seasonNumberFromPath(
                     QStringLiteral("The Wire (2002)/season12")), 12);
        QCOMPARE(LibraryScanner::seasonNumberFromPath(
                     QStringLiteral("The Wire (2002)/Extras")), 0);
    }

    void aTvRootYieldsEpisodesNamedByTheirShowFolder()
    {
        QTemporaryDir library;
        QVERIFY(writeTvFixture(library.path()));

        const LibraryScanner::ScanResult result = LibraryScanner::scan(tvRootAt(library.path()));

        QCOMPARE(result.outcome, LibraryScanner::ScanOutcome::Complete);
        QCOMPARE(result.items.size(), 5);
        const MediaItem &first = result.items.constFirst();
        QCOMPARE(first.relativePath,
                 QStringLiteral("Bluey (2018)/Season 1/S01E01 Magic Xylophone.mkv"));
        QCOMPARE(first.mediaKind, QStringLiteral("episode"));
        QCOMPARE(first.showName, QStringLiteral("Bluey"));
        QCOMPARE(first.title, QStringLiteral("Bluey"));
        QCOMPARE(first.year, 2018);
        QCOMPARE(first.seasonNumber, 1);
        QCOMPARE(first.episodeNumber, 1);
        QCOMPARE(first.episodeTitle, QStringLiteral("Magic Xylophone"));
        QCOMPARE(first.episodeLabel(), QStringLiteral("S1 E1"));

        const MediaItem &last = result.items.constLast();
        QCOMPARE(last.showName, QStringLiteral("The Wire"));
        QCOMPARE(last.seasonNumber, 2);
        QCOMPARE(last.episodeNumber, 2);
        QCOMPARE(last.episodeTitle, QStringLiteral("Collateral Damage"));
    }

    void aTvRootSkipsFilesThatAreNotEpisodes()
    {
        QTemporaryDir library;
        QVERIFY(writeTvFixture(library.path()));
        QVERIFY(writeMediaFile(library.path(),
                               QStringLiteral("The Wire (2002)/Season 1/making-of.mkv")));
        QVERIFY(writeMediaFile(library.path(),
                               QStringLiteral("The Wire (2002)/trailer.mkv")));
        QVERIFY(writeMediaFile(library.path(), QStringLiteral("loose-file.mkv")));

        const LibraryScanner::ScanResult result = LibraryScanner::scan(tvRootAt(library.path()));

        QCOMPARE(result.outcome, LibraryScanner::ScanOutcome::Complete);
        QCOMPARE(result.items.size(), 5);
        for (const MediaItem &item : result.items) {
            QVERIFY(item.isEpisode());
        }
    }

    void episodesCarryShowSeasonAndEpisodeArtworkAtTheirOwnScopes()
    {
        QTemporaryDir library;
        QVERIFY(writeTvFixture(library.path()));
        const QByteArray art = QByteArrayLiteral("art");
        QVERIFY(writeFile(library.path(), QStringLiteral("The Wire (2002)/poster.jpg"), art));
        QVERIFY(writeFile(library.path(), QStringLiteral("The Wire (2002)/fanart.jpg"), art));
        QVERIFY(writeFile(library.path(), QStringLiteral("The Wire (2002)/Season 2/folder.png"), art));
        QVERIFY(writeFile(library.path(),
                          QStringLiteral("The Wire (2002)/Season 2/The Wire - S02E01 - Ebb Tide-thumb.jpg"),
                          art));

        const LibraryScanner::ScanResult result = LibraryScanner::scan(tvRootAt(library.path()));

        const auto find = [&result](const QString &relativePath) -> const MediaItem * {
            for (const MediaItem &item : result.items) {
                if (item.relativePath == relativePath) {
                    return &item;
                }
            }
            return nullptr;
        };
        const MediaItem *seasonOne = find(
            QStringLiteral("The Wire (2002)/Season 1/The Wire - S01E01 - The Target.mkv"));
        QVERIFY(seasonOne != nullptr);
        QCOMPARE(seasonOne->showPosterRelativePath, QStringLiteral("The Wire (2002)/poster.jpg"));
        QCOMPARE(seasonOne->showBackdropRelativePath, QStringLiteral("The Wire (2002)/fanart.jpg"));
        QVERIFY(seasonOne->seasonPosterRelativePath.isEmpty());
        QVERIFY(seasonOne->episodeStillRelativePath.isEmpty());

        const MediaItem *seasonTwo = find(
            QStringLiteral("The Wire (2002)/Season 2/The Wire - S02E01 - Ebb Tide.mkv"));
        QVERIFY(seasonTwo != nullptr);
        QCOMPARE(seasonTwo->seasonPosterRelativePath,
                 QStringLiteral("The Wire (2002)/Season 2/folder.png"));
        QCOMPARE(seasonTwo->episodeStillRelativePath,
                 QStringLiteral("The Wire (2002)/Season 2/The Wire - S02E01 - Ebb Tide-thumb.jpg"));
        QCOMPARE(seasonTwo->gridShowPosterPath(),
                 QDir(library.path()).filePath(QStringLiteral("The Wire (2002)/poster.jpg")));

        const MediaItem *bluey = find(
            QStringLiteral("Bluey (2018)/Season 1/S01E01 Magic Xylophone.mkv"));
        QVERIFY(bluey != nullptr);
        QVERIFY(bluey->showPosterRelativePath.isEmpty());
        QVERIFY(bluey->gridShowPosterPath().isEmpty());
    }

    void aSeasonFolderWithoutAShowFolderNamesTheShowFromTheFile()
    {
        QTemporaryDir library;
        QVERIFY(writeMediaFile(library.path(),
                               QStringLiteral("Season 1/Seinfeld - S01E01 - The Seinfeld Chronicles.mkv")));
        QVERIFY(writeMediaFile(library.path(), QStringLiteral("Season 1/S01E02 The Stakeout.mkv")));

        const LibraryScanner::ScanResult result = LibraryScanner::scan(tvRootAt(library.path()));

        QCOMPARE(result.items.size(), 2);
        QCOMPARE(result.items.at(0).showName, QStringLiteral("Unknown Show"));
        QCOMPARE(result.items.at(1).showName, QStringLiteral("Seinfeld"));
    }

    void theSameFolderUnderTheMoviesRoleYieldsMovies()
    {
        QTemporaryDir library;
        QVERIFY(writeTvFixture(library.path()));
        const LibraryRoot movies{.id = QStringLiteral("movies-root"),
                                 .path = library.path(),
                                 .displayName = QStringLiteral("Movies"),
                                 .available = false,
                                 .role = LibraryRoot::Role::Movies};

        const LibraryScanner::ScanResult result = LibraryScanner::scan(movies);

        QCOMPARE(result.items.size(), 5);
        for (const MediaItem &item : result.items) {
            QCOMPARE(item.mediaKind, QStringLiteral("movie"));
            QVERIFY(item.isMovie());
        }
    }

    void episodeFactsSurviveTheCatalogRoundTrip()
    {
        QTemporaryDir library;
        QTemporaryDir catalogDir;
        QVERIFY(writeTvFixture(library.path()));
        QVERIFY(writeFile(library.path(), QStringLiteral("The Wire (2002)/poster.jpg"),
                          QByteArrayLiteral("art")));
        const QString catalogPath = catalogDir.filePath(QStringLiteral("catalog.sqlite"));
        {
            CatalogDatabase catalog(catalogPath);
            catalog.migrate();
        }

        CatalogStore store(catalogPath);
        const QVector<LibraryRoot> roots =
            store.registerRoots(LibraryRootPaths{.movies = {}, .tvShows = {library.path()}});
        QCOMPARE(roots.size(), 1);
        QCOMPARE(roots.constFirst().role, LibraryRoot::Role::TvShows);
        for (const LibraryRoot &root : roots) {
            store.applyScan(root, LibraryScanner::scan(root));
        }
        const QVector<MediaItem> projected = store.projection(roots);

        QCOMPARE(projected.size(), 5);
        const auto wire = std::find_if(projected.cbegin(), projected.cend(),
                                       [](const MediaItem &item) {
                                           return item.episodeTitle == QStringLiteral("Ebb Tide");
                                       });
        QVERIFY(wire != projected.cend());
        QCOMPARE(wire->mediaKind, QStringLiteral("episode"));
        QCOMPARE(wire->showName, QStringLiteral("The Wire"));
        QCOMPARE(wire->seasonNumber, 2);
        QCOMPARE(wire->episodeNumber, 1);
        QCOMPARE(wire->showPosterAbsolutePath,
                 QDir(library.path()).filePath(QStringLiteral("The Wire (2002)/poster.jpg")));
        QVERIFY(!wire->watched);
    }

    // Qt's listing already leaves a link to nowhere out, so the unreadable
    // season folder is what makes the root partial; the walk must still hand
    // over, and the catalog store, every episode it could read.
    void aTvRootWithUnreadableEntriesStoresTheEpisodesItCouldRead()
    {
        QTemporaryDir library;
        QTemporaryDir catalogDir;
        QVERIFY(writeTvFixture(library.path()));
        QVERIFY(QDir().mkpath(QDir(library.path()).filePath(QStringLiteral("Show (2001)/Season 1"))));
        QVERIFY(QFile::link(QDir(library.path()).filePath(QStringLiteral("nowhere.mkv")),
                            QDir(library.path()).filePath(
                                QStringLiteral("Show (2001)/Season 1/Show S01E01.mkv"))));
        const QString locked =
            QDir(library.path()).filePath(QStringLiteral("Show (2001)/Season 2"));
        QVERIFY(writeMediaFile(library.path(),
                               QStringLiteral("Show (2001)/Season 2/Show S02E01.mkv")));
        QVERIFY(QFile::setPermissions(locked, QFileDevice::ExeOwner));
        const auto restore = qScopeGuard([&locked] {
            QFile::setPermissions(locked,
                                  QFileDevice::ReadOwner | QFileDevice::WriteOwner
                                      | QFileDevice::ExeOwner);
        });
        const QString catalogPath = catalogDir.filePath(QStringLiteral("catalog.sqlite"));
        {
            CatalogDatabase catalog(catalogPath);
            catalog.migrate();
        }

        CatalogStore store(catalogPath);
        const QVector<LibraryRoot> roots =
            store.registerRoots(LibraryRootPaths{.movies = {}, .tvShows = {library.path()}});
        QCOMPARE(roots.size(), 1);
        const LibraryScanner::ScanResult result = LibraryScanner::scan(roots.constFirst());
        QCOMPARE(result.outcome, LibraryScanner::ScanOutcome::Incomplete);
        QCOMPARE(result.items.size(), 5);

        try {
            store.applyScan(roots.constFirst(), result);
        } catch (const std::exception &error) {
            QFAIL(error.what());
        }
        QCOMPARE(store.projection(roots).size(), 5);
    }

    void aFolderListedUnderBothRolesIsRegisteredAsTv()
    {
        QTemporaryDir library;
        QTemporaryDir catalogDir;
        const QString catalogPath = catalogDir.filePath(QStringLiteral("catalog.sqlite"));
        {
            CatalogDatabase catalog(catalogPath);
            catalog.migrate();
        }
        CatalogStore store(catalogPath);

        const QVector<LibraryRoot> roots = store.registerRoots(
            LibraryRootPaths{.movies = {library.path()}, .tvShows = {library.path()}});

        QCOMPARE(roots.size(), 1);
        QCOMPARE(roots.constFirst().role, LibraryRoot::Role::TvShows);
    }

    void theShowsModelGroupsEpisodesIntoOrderedSummaries()
    {
        QTemporaryDir library;
        QVERIFY(writeTvFixture(library.path()));
        const LibraryScanner::ScanResult result = LibraryScanner::scan(tvRootAt(library.path()));

        ShowsModel model;
        model.replaceItems(result.items);

        QCOMPARE(model.showCount(), 2);
        QCOMPARE(model.episodeCount(), 5);
        QCOMPARE(model.summaries().at(0).showName, QStringLiteral("Bluey"));
        QCOMPARE(model.summaries().at(1).showName, QStringLiteral("The Wire"));
        const ShowSummary *wire = model.summary(QStringLiteral("The Wire"));
        QVERIFY(wire != nullptr);
        QCOMPARE(wire->seasonCount, 2);
        QCOMPARE(wire->episodes.size(), 4);
        QCOMPARE(wire->upNextLabel(), QStringLiteral("S1 E1"));
        QCOMPARE(wire->episodes.constLast().episodeTitle, QStringLiteral("Collateral Damage"));
    }

    void theShowsModelKeysRowsByGenreThenAllShows()
    {
        QTemporaryDir library;
        QVERIFY(writeTvFixture(library.path()));
        const LibraryScanner::ScanResult result = LibraryScanner::scan(tvRootAt(library.path()));

        ShowsModel model;
        model.replaceItems(result.items);

        // Bluey maps to Kids, Animation, Family offline; The Wire has no
        // offline genres and appears only in All Shows.
        QStringList titles;
        for (int row = 0; row < model.rowCount(); ++row) {
            titles.push_back(model.data(model.index(row), ShowsModel::RowTitleRole).toString());
        }
        QCOMPARE(titles, QStringList({QStringLiteral("Animation"), QStringLiteral("Family"),
                                      QStringLiteral("Kids"), QStringLiteral("All Shows")}));
        QCOMPARE(model.showNameAt(0, 0), QStringLiteral("Bluey"));
        QCOMPARE(model.showNameAt(3, 1), QStringLiteral("The Wire"));
        QVERIFY(model.showNameAt(0, 1).isEmpty());
        QCOMPARE(model.focus()->row(), 0);
    }

    void upNextFollowsTheLastEpisodeWithWatchState()
    {
        QTemporaryDir library;
        QVERIFY(writeTvFixture(library.path()));
        const LibraryScanner::ScanResult result = LibraryScanner::scan(tvRootAt(library.path()));

        ShowsModel model;
        model.replaceItems(result.items);
        const ShowSummary *wire = model.summary(QStringLiteral("The Wire"));
        QVERIFY(wire != nullptr);
        const QString firstId = wire->episodes.at(0).id;
        const QString thirdId = wire->episodes.at(2).id;

        QSignalSpy progressSpy(&model, &ShowsModel::showProgressChanged);

        // Finishing S1E1 moves up-next to S1E2.
        model.applyWatchProgress(firstId, 0, 60000, true);
        QCOMPARE(model.summary(QStringLiteral("The Wire"))->upNextLabel(), QStringLiteral("S1 E2"));
        // Progress on S2E1 makes it up-next itself, ahead of the finished one.
        model.applyWatchProgress(thirdId, 30000, 60000, false);
        QCOMPARE(model.summary(QStringLiteral("The Wire"))->upNextLabel(), QStringLiteral("S2 E1"));
        QCOMPARE(progressSpy.count(), 2);

        const QVariantMap details = model.showDetails(QStringLiteral("The Wire"));
        QCOMPARE(details.value(QStringLiteral("continueLabel")).toString(),
                 QStringLiteral("Resume S2 E1"));
        QVERIFY(details.value(QStringLiteral("showsContinue")).toBool());
        QCOMPARE(details.value(QStringLiteral("seasons")).toList().size(), 2);

        const QVariantList seasonTwo = model.episodesOf(QStringLiteral("The Wire"), 2);
        QCOMPARE(seasonTwo.size(), 2);
        QVERIFY(seasonTwo.at(0).toMap().value(QStringLiteral("isUpNext")).toBool());
        QVERIFY(seasonTwo.at(0).toMap().value(QStringLiteral("hasProgress")).toBool());
        QCOMPARE(seasonTwo.at(0).toMap().value(QStringLiteral("progress")).toDouble(), 0.5);
    }

    // Two files of one episode: the unwatched copy of a watched episode is
    // not what comes next, on the show page as on Home.
    void anUnwatchedCopyOfAWatchedEpisodeIsNotUpNext()
    {
        const auto file = [](int season, int number, const QString &name) {
            MediaItem item;
            item.id = QStringLiteral("root/Solo/%1").arg(name);
            item.relativePath = item.id;
            item.mediaKind = QStringLiteral("episode");
            item.showName = QStringLiteral("Solo");
            item.seasonNumber = season;
            item.episodeNumber = number;
            return item;
        };
        MediaItem first = file(1, 1, QStringLiteral("S01E01.mkv"));
        const MediaItem firstCopy = file(1, 1, QStringLiteral("S01E01 copy.mkv"));
        const MediaItem second = file(1, 2, QStringLiteral("S01E02.mkv"));
        MediaItem finale = file(1, 3, QStringLiteral("S01E03.mkv"));
        const MediaItem finaleCopy = file(1, 3, QStringLiteral("S01E03 copy.mkv"));

        ShowsModel model;
        model.replaceItems({first, firstCopy, second, finale, finaleCopy});
        model.applyWatchProgress(first.id, 0, 60000, true);
        QCOMPARE(model.summary(QStringLiteral("Solo"))->upNextLabel(), QStringLiteral("S1 E2"));

        model.applyWatchProgress(finale.id, 0, 60000, true);
        // The last episode with watch state decides, and nothing follows the
        // finale but its own copy.
        QVERIFY(model.summary(QStringLiteral("Solo"))->upNextLabel().isEmpty());
    }

    void aShowWatchedThroughHasNoUpNext()
    {
        QTemporaryDir library;
        QVERIFY(writeMediaFile(library.path(),
                               QStringLiteral("Solo (2020)/Season 1/S01E01 Only.mkv")));
        const LibraryScanner::ScanResult result = LibraryScanner::scan(tvRootAt(library.path()));
        ShowsModel model;
        model.replaceItems(result.items);

        model.applyWatchProgress(result.items.constFirst().id, 0, 60000, true);

        QVERIFY(model.summary(QStringLiteral("Solo"))->upNextLabel().isEmpty());
        const QVariantMap details = model.showDetails(QStringLiteral("Solo"));
        QVERIFY(!details.value(QStringLiteral("showsContinue")).toBool());
        QVERIFY(details.value(QStringLiteral("upNextId")).toString().isEmpty());
    }
};

QTEST_MAIN(TvScannerTest)
#include "tst_tv_scanner.moc"
