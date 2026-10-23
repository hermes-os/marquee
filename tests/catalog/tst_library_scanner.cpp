#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QIODevice>
#include <QScopeGuard>
#include <QSqlQuery>
#include <QTemporaryDir>
#include <QVariant>
#include <QtTest>

#include <algorithm>
#include <optional>

#include "app/AppPaths.hpp"
#include "app/ApplicationController.hpp"
#include "catalog/CatalogDatabase.hpp"
#include "catalog/CatalogStore.hpp"
#include "catalog/LibraryScanner.hpp"
#include "models/LibraryModel.hpp"

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

void migrateCatalog(const QString &path)
{
    CatalogDatabase catalog(path);
    catalog.migrate();
}

[[nodiscard]] QString catalogValue(const QString &catalogPath, const QString &sql)
{
    CatalogDatabase catalog(catalogPath);
    QSqlQuery query(catalog.connection());
    if (!query.exec(sql) || !query.next()) {
        return {};
    }
    return query.value(0).toString();
}

[[nodiscard]] LibraryRoot rootAt(const QString &path)
{
    return {.id = QStringLiteral("root-1"),
            .path = path,
            .displayName = QStringLiteral("Movies"),
            .available = false};
}

// Mirrors what the catalog worker performs on its own thread: register the
// configured roots, walk each one, then apply and project.
[[nodiscard]] QVector<MediaItem> refresh(CatalogStore &store, const QStringList &paths)
{
    const QVector<LibraryRoot> roots = store.registerRoots(paths);
    for (const LibraryRoot &root : roots) {
        store.applyScan(root, LibraryScanner::scan(root));
    }
    return store.projection(roots);
}

[[nodiscard]] QStringList titlesOf(const QVector<MediaItem> &items)
{
    QStringList titles;
    for (const MediaItem &item : items) {
        titles.push_back(item.title);
    }
    return titles;
}

[[nodiscard]] QStringList idsOf(const QVector<MediaItem> &items)
{
    QStringList ids;
    for (const MediaItem &item : items) {
        ids.push_back(item.id);
    }
    return ids;
}

[[nodiscard]] bool blockDirectoryListing(const QString &path)
{
    return QFile::setPermissions(path, QFileDevice::ExeOwner);
}

void restoreDirectoryListing(const QString &path)
{
    QFile::setPermissions(path,
                          QFileDevice::ReadOwner | QFileDevice::WriteOwner
                              | QFileDevice::ExeOwner);
}

[[nodiscard]] QStringList relativePathsOf(const QVector<MediaItem> &items)
{
    QStringList paths;
    for (const MediaItem &item : items) {
        paths.push_back(item.relativePath);
    }
    return paths;
}

[[nodiscard]] QStringList posterPathsOf(const QVector<MediaItem> &items)
{
    QStringList paths;
    for (const MediaItem &item : items) {
        paths.push_back(item.posterRelativePath);
    }
    return paths;
}
}

class LibraryScannerTest final : public QObject
{
    Q_OBJECT

private slots:
    void parsesTitleAndYearFromASceneStyleName()
    {
        const LibraryScanner::ParsedFilename parsed = LibraryScanner::parseMovieFilename(
            QFileInfo(QStringLiteral("Arrival.2016.1080p.BluRay.x264.mkv")));

        QCOMPARE(parsed.title, QStringLiteral("Arrival"));
        QCOMPARE(parsed.year, 2016);
    }

    void parsesTitleAndYearFromABracketedName()
    {
        const LibraryScanner::ParsedFilename parsed = LibraryScanner::parseMovieFilename(
            QFileInfo(QStringLiteral("Arrival (2016).mkv")));

        QCOMPARE(parsed.title, QStringLiteral("Arrival"));
        QCOMPARE(parsed.year, 2016);
    }

    void keepsTheWholeNameAsTheTitleWhenNoYearIsPresent()
    {
        const LibraryScanner::ParsedFilename parsed = LibraryScanner::parseMovieFilename(
            QFileInfo(QStringLiteral("The_Wild_Robot.mkv")));

        QCOMPARE(parsed.title, QStringLiteral("The Wild Robot"));
        QCOMPARE(parsed.year, 0);
    }

    void treatsAnImplausibleFutureYearAsPartOfTheTitle()
    {
        const LibraryScanner::ParsedFilename parsed = LibraryScanner::parseMovieFilename(
            QFileInfo(QStringLiteral("Blade Runner 2049.2017.mkv")));

        QCOMPARE(parsed.title, QStringLiteral("Blade Runner 2049"));
        QCOMPARE(parsed.year, 2017);
    }

    void keepsTheFilenameAsTheTitleWhenTheYearIsAllThereIs()
    {
        const LibraryScanner::ParsedFilename parsed =
            LibraryScanner::parseMovieFilename(QFileInfo(QStringLiteral("2016.mkv")));

        QCOMPARE(parsed.title, QStringLiteral("2016"));
        QCOMPARE(parsed.year, 2016);
    }

    void cleansTheTitleBeforeAParenthesizedYearAndRejectsAFutureOne()
    {
        const struct
        {
            const char *name;
            const char *title;
            int year;
        } cases[] = {
            // The dash that led to the year goes with it.
            {"Alien - (1979).mkv", "Alien", 1979},
            // Another bracket group before the year is not the title.
            {"X (1999) (2008).mkv", "X", 2008},
            // A year no film has is not the release year.
            {"Movie (2099).mkv", "Movie (2099)", 0},
            // Initials keep their dots, as the released app shows them.
            {"E.T. the Extra-Terrestrial (1982).mkv", "E.T. the Extra-Terrestrial", 1982},
            {"L.A. Confidential (1997).mkv", "L.A. Confidential", 1997},
            {"Dr. Strangelove (1964).mkv", "Dr. Strangelove", 1964},
            {"Kill Bill Vol. 1 (2003).mkv", "Kill Bill Vol. 1", 2003},
            // With no space at all the dots are separators.
            {"The.Matrix.(1999).mkv", "The Matrix", 1999},
            // Initials keep their dots in a dot-separated name too; only the
            // dots after a word of two letters or more separate words.
            {"E.T.the.Extra-Terrestrial.(1982).mkv", "E.T. the Extra-Terrestrial", 1982},
            {"L.A.Confidential.(1997).mkv", "L.A. Confidential", 1997},
            {"S.W.A.T.(2003).mkv", "S.W.A.T.", 2003},
            {"A.Beautiful.Mind.(2001).mkv", "A Beautiful Mind", 2001},
            {"Star.Trek.V.The.Final.Frontier.(1989).mkv", "Star Trek V The Final Frontier", 1989},
            {"The_Wild_Robot (2024).mkv", "The Wild Robot", 2024},
        };
        for (const auto &c : cases) {
            const LibraryScanner::ParsedFilename parsed =
                LibraryScanner::parseMovieFilename(QFileInfo(QString::fromLatin1(c.name)));
            QVERIFY2(parsed.title == QString::fromLatin1(c.title) && parsed.year == c.year,
                     qPrintable(QStringLiteral("%1 gave '%2' %3").arg(QString::fromLatin1(c.name),
                                                                    parsed.title).arg(parsed.year)));
        }
    }

    void takesTheTrailingParenthesizedYearAndKeepsItOutOfTheTitle()
    {
        // A title that is itself a year, or starts with one, must not lend
        // its number to the release year.
        const struct
        {
            const char *name;
            const char *title;
            int year;
        } cases[] = {
            {"1917 (2019).mkv", "1917", 2019},
            {"2001 A Space Odyssey (1968).mkv", "2001 A Space Odyssey", 1968},
            {"Blade Runner 2049 (2017).mkv", "Blade Runner 2049", 2017},
            {"1917.2019.BluRay.mkv", "1917", 2019},
            {"2001.A.Space.Odyssey.1968.1080p.mkv", "2001 A Space Odyssey", 1968},
        };
        for (const auto &c : cases) {
            const LibraryScanner::ParsedFilename parsed =
                LibraryScanner::parseMovieFilename(QFileInfo(QString::fromLatin1(c.name)));
            QVERIFY2(parsed.title == QString::fromLatin1(c.title) && parsed.year == c.year,
                     c.name);
        }
    }

    void mediaIdIsStablePerRootAndRelativePath()
    {
        const QString path = QStringLiteral("Arrival (2016)/Arrival (2016).mkv");
        const QString id = LibraryScanner::mediaIdFor(QStringLiteral("root-1"), path);

        QCOMPARE(LibraryScanner::mediaIdFor(QStringLiteral("root-1"), path), id);
        QVERIFY(LibraryScanner::mediaIdFor(QStringLiteral("root-2"), path) != id);
        QVERIFY(LibraryScanner::mediaIdFor(QStringLiteral("root-1"),
                                           QStringLiteral("Moon.2009.mkv"))
                != id);
    }

    void scanReturnsSupportedMediaFilesOrderedByRelativePath()
    {
        QTemporaryDir library;
        QVERIFY(writeMediaFile(library.path(), QStringLiteral("Moon.2009.mkv")));
        QVERIFY(writeMediaFile(library.path(),
                               QStringLiteral("Arrival (2016)/Arrival (2016).mkv")));
        QVERIFY(writeMediaFile(library.path(), QStringLiteral("Nope (2022)/Nope.mp4")));
        QVERIFY(writeFile(library.path(), QStringLiteral("Arrival (2016)/poster.jpg"),
                          QByteArrayLiteral("art")));
        QVERIFY(writeFile(library.path(), QStringLiteral("library.nfo"),
                          QByteArrayLiteral("notes")));

        const LibraryScanner::ScanResult result = LibraryScanner::scan(rootAt(library.path()));

        QCOMPARE(result.outcome, LibraryScanner::ScanOutcome::Complete);
        QCOMPARE(relativePathsOf(result.items),
                 QStringList({QStringLiteral("Arrival (2016)/Arrival (2016).mkv"),
                              QStringLiteral("Moon.2009.mkv"),
                              QStringLiteral("Nope (2022)/Nope.mp4")}));
        QCOMPARE(result.items.constFirst().mediaKind, QStringLiteral("movie"));
        QCOMPARE(result.items.constFirst().sortTitle, QStringLiteral("arrival"));
        QCOMPARE(result.items.constFirst().fileSize, qint64{5});
    }

    void scanSkipsMediaInsideHiddenDirectories()
    {
        QTemporaryDir library;
        QVERIFY(writeMediaFile(library.path(), QStringLiteral("Moon.2009.mkv")));
        QVERIFY(writeMediaFile(library.path(),
                               QStringLiteral(".Trash-1000/files/Deleted.mkv")));

        const LibraryScanner::ScanResult result = LibraryScanner::scan(rootAt(library.path()));

        QCOMPARE(relativePathsOf(result.items),
                 QStringList({QStringLiteral("Moon.2009.mkv")}));
    }

    void scanReportsAMissingRootAsUnavailable()
    {
        QTemporaryDir library;
        const LibraryScanner::ScanResult result = LibraryScanner::scan(
            rootAt(QDir(library.path()).filePath(QStringLiteral("absent"))));

        QCOMPARE(result.outcome, LibraryScanner::ScanOutcome::RootUnavailable);
        QVERIFY(result.items.isEmpty());
    }

    void scanReportsARootThatIsAFileAsUnavailable()
    {
        QTemporaryDir library;
        QVERIFY(writeMediaFile(library.path(), QStringLiteral("Moon.2009.mkv")));

        const LibraryScanner::ScanResult result = LibraryScanner::scan(
            rootAt(QDir(library.path()).filePath(QStringLiteral("Moon.2009.mkv"))));

        QCOMPARE(result.outcome, LibraryScanner::ScanOutcome::RootUnavailable);
        QVERIFY(result.items.isEmpty());
    }

    void scanExcludesASymlinkResolvingOutsideTheRoot()
    {
        QTemporaryDir outside;
        QTemporaryDir library;
        QVERIFY(writeMediaFile(outside.path(), QStringLiteral("Elsewhere.2020.mkv")));
        QVERIFY(writeMediaFile(library.path(), QStringLiteral("Moon.2009.mkv")));
        QVERIFY(QFile::link(QDir(outside.path()).filePath(QStringLiteral("Elsewhere.2020.mkv")),
                            QDir(library.path()).filePath(QStringLiteral("Linked.2020.mkv"))));

        const LibraryScanner::ScanResult result = LibraryScanner::scan(rootAt(library.path()));

        QCOMPARE(result.outcome, LibraryScanner::ScanOutcome::Complete);
        QCOMPARE(relativePathsOf(result.items),
                 QStringList({QStringLiteral("Moon.2009.mkv")}));
    }

    void scanDoesNotDescendIntoASymlinkedDirectory()
    {
        QTemporaryDir outside;
        QTemporaryDir library;
        QVERIFY(writeMediaFile(outside.path(), QStringLiteral("Elsewhere.2020.mkv")));
        QVERIFY(writeMediaFile(library.path(), QStringLiteral("Moon.2009.mkv")));
        QVERIFY(QFile::link(outside.path(),
                            QDir(library.path()).filePath(QStringLiteral("Elsewhere"))));

        const LibraryScanner::ScanResult result = LibraryScanner::scan(rootAt(library.path()));

        QCOMPARE(result.outcome, LibraryScanner::ScanOutcome::Complete);
        QCOMPARE(relativePathsOf(result.items),
                 QStringList({QStringLiteral("Moon.2009.mkv")}));
    }

    void scanReportsASubtreeItCannotEnumerateAsIncomplete()
    {
        QTemporaryDir library;
        QVERIFY(writeMediaFile(library.path(), QStringLiteral("Moon.2009.mkv")));
        const QString locked = QDir(library.path()).filePath(QStringLiteral("Archive"));
        QVERIFY(writeMediaFile(locked, QStringLiteral("Arrival.2016.mkv")));

        QVERIFY(blockDirectoryListing(locked));
        const auto restore = qScopeGuard([&locked] { restoreDirectoryListing(locked); });

        const LibraryScanner::ScanResult result = LibraryScanner::scan(rootAt(library.path()));

        QCOMPARE(result.outcome, LibraryScanner::ScanOutcome::Incomplete);
    }

    void scanDoesNotListABrokenSymlinkAndKeepsTheGoodFiles()
    {
        QTemporaryDir library;
        QVERIFY(writeMediaFile(library.path(), QStringLiteral("Moon.2009.mkv")));
        QVERIFY(writeMediaFile(library.path(), QStringLiteral("Arrival (2016)/Arrival (2016).mkv")));
        QVERIFY(QFile::link(QDir(library.path()).filePath(QStringLiteral("nowhere.mkv")),
                            QDir(library.path()).filePath(QStringLiteral("Broken Movie (2020).mkv"))));

        const LibraryScanner::ScanResult result = LibraryScanner::scan(rootAt(library.path()));

        QVERIFY(result.outcome != LibraryScanner::ScanOutcome::RootUnavailable);
        QCOMPARE(relativePathsOf(result.items),
                 QStringList({QStringLiteral("Arrival (2016)/Arrival (2016).mkv"),
                              QStringLiteral("Moon.2009.mkv")}));
        for (const MediaItem &item : result.items) {
            QVERIFY(item.modifiedAt.isValid());
        }
    }

    // The listing names the file but the stat refuses it. The walk stays
    // Complete, the file is skipped, its siblings are stored and its row from
    // an earlier scan survives.
    void aListedMovieThatFailsStatIsSkippedReportedAndItsRowKept()
    {
        QTemporaryDir dataDirectory;
        QTemporaryDir library;
        const QString catalogPath =
            QDir(dataDirectory.path()).filePath(QStringLiteral("catalog.sqlite"));
        migrateCatalog(catalogPath);
        QVERIFY(writeMediaFile(library.path(), QStringLiteral("Moon.2009.mkv")));
        QVERIFY(writeMediaFile(library.path(), QStringLiteral("Heat.1995.mkv")));

        CatalogStore store(catalogPath);
        const QVector<LibraryRoot> roots = store.registerRoots({library.path()});
        QCOMPARE(roots.size(), 1);
        store.applyScan(roots.constFirst(), LibraryScanner::scan(roots.constFirst()));
        QCOMPARE(store.projection(roots).size(), 2);

        const auto restore = qScopeGuard([] { LibraryScanner::setMediaStatForTest({}); });
        LibraryScanner::setMediaStatForTest(
            [](const QFileInfo &listed) -> std::optional<QFileInfo> {
                if (listed.fileName() == QStringLiteral("Moon.2009.mkv")) {
                    return std::nullopt;
                }
                return QFileInfo(listed.absoluteFilePath());
            });
        QVERIFY(writeMediaFile(library.path(), QStringLiteral("Zodiac.2007.mkv")));

        const LibraryScanner::ScanResult result = LibraryScanner::scan(roots.constFirst());

        QCOMPARE(result.outcome, LibraryScanner::ScanOutcome::Complete);
        QCOMPARE(relativePathsOf(result.items),
                 QStringList({QStringLiteral("Heat.1995.mkv"), QStringLiteral("Zodiac.2007.mkv")}));
        QCOMPARE(result.unreadableIds,
                 QSet<QString>({LibraryScanner::mediaIdFor(roots.constFirst().id,
                                                           QStringLiteral("Moon.2009.mkv"))}));

        store.applyScan(roots.constFirst(), result);
        QCOMPARE(titlesOf(store.projection(roots)),
                 QStringList({QStringLiteral("Heat"), QStringLiteral("Moon"),
                              QStringLiteral("Zodiac")}));
    }

    void aListedEpisodeThatFailsStatIsSkippedReportedAndItsRowKept()
    {
        QTemporaryDir dataDirectory;
        QTemporaryDir library;
        const QString catalogPath =
            QDir(dataDirectory.path()).filePath(QStringLiteral("catalog.sqlite"));
        migrateCatalog(catalogPath);
        const QString first = QStringLiteral("Show (2001)/Season 1/Show - S01E01 - One.mkv");
        const QString second = QStringLiteral("Show (2001)/Season 1/Show - S01E02 - Two.mkv");
        QVERIFY(writeMediaFile(library.path(), first));
        QVERIFY(writeMediaFile(library.path(), second));

        CatalogStore store(catalogPath);
        const QVector<LibraryRoot> roots = store.registerRoots(
            LibraryRootPaths{.movies = {}, .tvShows = {library.path()}});
        QCOMPARE(roots.size(), 1);
        store.applyScan(roots.constFirst(), LibraryScanner::scan(roots.constFirst()));
        QCOMPARE(store.projection(roots).size(), 2);

        const auto restore = qScopeGuard([] { LibraryScanner::setMediaStatForTest({}); });
        LibraryScanner::setMediaStatForTest(
            [](const QFileInfo &listed) -> std::optional<QFileInfo> {
                if (listed.fileName().contains(QStringLiteral("S01E01"))) {
                    return std::nullopt;
                }
                return QFileInfo(listed.absoluteFilePath());
            });
        QVERIFY(writeMediaFile(library.path(),
                               QStringLiteral("Show (2001)/Season 1/Show - S01E03 - Three.mkv")));

        const LibraryScanner::ScanResult result = LibraryScanner::scan(roots.constFirst());

        QCOMPARE(result.outcome, LibraryScanner::ScanOutcome::Complete);
        QCOMPARE(result.items.size(), 2);
        QCOMPARE(result.items.at(0).episodeNumber, 2);
        QCOMPARE(result.items.at(1).episodeNumber, 3);
        QCOMPARE(result.unreadableIds,
                 QSet<QString>({LibraryScanner::mediaIdFor(roots.constFirst().id, first)}));

        store.applyScan(roots.constFirst(), result);
        const QVector<MediaItem> after = store.projection(roots);
        QCOMPARE(after.size(), 3);
        QVERIFY(std::any_of(after.cbegin(), after.cend(), [](const MediaItem &item) {
            return item.episodeNumber == 1;
        }));
    }

    // A sidecar's presence comes from the listing alone, so a stat failure on
    // it cannot clear the artwork a stored row already has.
    void aSidecarIsAdoptedFromTheListingEvenWhenTheStatRefusesIt()
    {
        QTemporaryDir library;
        QVERIFY(writeMediaFile(library.path(), QStringLiteral("Moon.2009.mkv")));
        QVERIFY(writeFile(library.path(), QStringLiteral("Moon.2009-poster.jpg"),
                          QByteArrayLiteral("art")));

        const auto restore = qScopeGuard([] { LibraryScanner::setMediaStatForTest({}); });
        LibraryScanner::setMediaStatForTest(
            [](const QFileInfo &listed) -> std::optional<QFileInfo> {
                if (listed.suffix() == QStringLiteral("jpg")) {
                    return std::nullopt;
                }
                return QFileInfo(listed.absoluteFilePath());
            });

        const LibraryScanner::ScanResult result = LibraryScanner::scan(rootAt(library.path()));

        QCOMPARE(result.items.size(), 1);
        QCOMPARE(result.items.constFirst().posterRelativePath,
                 QStringLiteral("Moon.2009-poster.jpg"));
    }

    void aBrokenSymlinkNamedLikeMediaDoesNotFailTheCatalogWrite()
    {
        QTemporaryDir dataDirectory;
        QTemporaryDir library;
        const QString catalogPath =
            QDir(dataDirectory.path()).filePath(QStringLiteral("catalog.sqlite"));
        migrateCatalog(catalogPath);
        QVERIFY(writeMediaFile(library.path(), QStringLiteral("Moon.2009.mkv")));
        QVERIFY(writeMediaFile(library.path(), QStringLiteral("Arrival (2016)/Arrival (2016).mkv")));
        QVERIFY(QFile::link(QDir(library.path()).filePath(QStringLiteral("nowhere.mkv")),
                            QDir(library.path()).filePath(QStringLiteral("Broken Movie (2020).mkv"))));

        CatalogStore store(catalogPath);
        QStringList titles;
        try {
            titles = titlesOf(refresh(store, {library.path()}));
        } catch (const std::exception &error) {
            QFAIL(error.what());
        }

        QCOMPARE(titles, QStringList({QStringLiteral("Arrival"), QStringLiteral("Moon")}));
    }

    // The same rule as an unreadable file, one level up: what a partial walk did
    // read is stored, because a library that is empty until every directory is
    // readable is no better than one that failed to load.
    void aPartiallyReadableRootStoresWhatItReadAndRemovesNothing()
    {
        QTemporaryDir dataDirectory;
        QTemporaryDir library;
        const QString catalogPath =
            QDir(dataDirectory.path()).filePath(QStringLiteral("catalog.sqlite"));
        migrateCatalog(catalogPath);

        QVERIFY(writeMediaFile(library.path(), QStringLiteral("Moon.2009.mkv")));
        const QString locked = QDir(library.path()).filePath(QStringLiteral("Archive"));
        QVERIFY(writeMediaFile(locked, QStringLiteral("Arrival.2016.mkv")));

        CatalogStore store(catalogPath);
        QVERIFY(blockDirectoryListing(locked));
        const auto restore = qScopeGuard([&locked] { restoreDirectoryListing(locked); });

        // Nothing is cataloged yet, so the readable file must still arrive.
        QCOMPARE(titlesOf(refresh(store, {library.path()})),
                 QStringList({QStringLiteral("Moon")}));

        restoreDirectoryListing(locked);
        QCOMPARE(titlesOf(refresh(store, {library.path()})),
                 QStringList({QStringLiteral("Arrival"), QStringLiteral("Moon")}));

        // Now the file that scanned is removed while the other directory is
        // unreadable: neither the unread nor the removed row may be deleted on
        // the strength of a partial walk.
        QVERIFY(QFile::remove(QDir(library.path()).filePath(QStringLiteral("Moon.2009.mkv"))));
        QVERIFY(writeMediaFile(library.path(), QStringLiteral("Heat.1995.mkv")));
        QVERIFY(blockDirectoryListing(locked));
        QCOMPARE(titlesOf(refresh(store, {library.path()})),
                 QStringList({QStringLiteral("Arrival"), QStringLiteral("Heat"),
                              QStringLiteral("Moon")}));
    }

    void anItemWithoutAModificationTimeIsDroppedAloneByTheCatalogWrite()
    {
        QTemporaryDir dataDirectory;
        QTemporaryDir library;
        const QString catalogPath =
            QDir(dataDirectory.path()).filePath(QStringLiteral("catalog.sqlite"));
        migrateCatalog(catalogPath);
        QVERIFY(writeMediaFile(library.path(), QStringLiteral("Moon.2009.mkv")));
        QVERIFY(writeMediaFile(library.path(), QStringLiteral("Arrival (2016)/Arrival (2016).mkv")));
        QVERIFY(writeMediaFile(library.path(), QStringLiteral("Heat.1995.mkv")));

        CatalogStore store(catalogPath);
        const QVector<LibraryRoot> roots = store.registerRoots({library.path()});
        QCOMPARE(roots.size(), 1);

        // Heat is cataloged before its time goes missing, so the dropped update
        // must not cost it the row it already has.
        store.applyScan(roots.constFirst(), LibraryScanner::scan(roots.constFirst()));
        QCOMPARE(store.projection(roots).size(), 3);

        QVERIFY(writeMediaFile(library.path(), QStringLiteral("Zodiac.2007.mkv")));
        LibraryScanner::ScanResult result = LibraryScanner::scan(roots.constFirst());
        QCOMPARE(result.items.size(), 4);
        for (MediaItem &item : result.items) {
            if (item.title == QStringLiteral("Heat") || item.title == QStringLiteral("Zodiac")) {
                item.modifiedAt = QDateTime();
                item.fileSize += 1;
            }
        }

        try {
            store.applyScan(roots.constFirst(), result);
        } catch (const std::exception &error) {
            QFAIL(error.what());
        }

        QCOMPARE(titlesOf(store.projection(roots)),
                 QStringList({QStringLiteral("Arrival"), QStringLiteral("Heat"),
                              QStringLiteral("Moon")}));
    }

    void scanPrefersATitlesOwnSidecarOverTheFolderArtwork()
    {
        QTemporaryDir library;
        QVERIFY(writeMediaFile(library.path(),
                               QStringLiteral("Arrival (2016)/Arrival (2016).mkv")));
        QVERIFY(writeFile(library.path(),
                          QStringLiteral("Arrival (2016)/Arrival (2016)-poster.jpg"),
                          QByteArrayLiteral("art")));
        QVERIFY(writeFile(library.path(), QStringLiteral("Arrival (2016)/poster.jpg"),
                          QByteArrayLiteral("art")));

        const LibraryScanner::ScanResult result = LibraryScanner::scan(rootAt(library.path()));

        QCOMPARE(posterPathsOf(result.items),
                 QStringList({QStringLiteral("Arrival (2016)/Arrival (2016)-poster.jpg")}));
        QCOMPARE(result.items.constFirst().posterAbsolutePath,
                 QDir(library.path())
                     .filePath(QStringLiteral("Arrival (2016)/Arrival (2016)-poster.jpg")));
    }

    // The Home hero draws a movie's backdrop: the folder's `fanart` before the
    // file's own `-backdrop`, as the released app orders them, stored
    // relatively and projected absolutely.
    void aMoviesBackdropSidecarIsStoredAndProjected()
    {
        QTemporaryDir dataDirectory;
        QTemporaryDir library;
        const QString catalogPath =
            QDir(dataDirectory.path()).filePath(QStringLiteral("catalog.sqlite"));
        migrateCatalog(catalogPath);

        QVERIFY(writeMediaFile(library.path(),
                               QStringLiteral("Arrival (2016)/Arrival (2016).mkv")));
        QVERIFY(writeFile(library.path(), QStringLiteral("Arrival (2016)/fanart.jpg"),
                          QByteArrayLiteral("art")));
        QVERIFY(writeFile(library.path(),
                          QStringLiteral("Arrival (2016)/Arrival (2016)-backdrop.jpg"),
                          QByteArrayLiteral("art")));
        QVERIFY(writeMediaFile(library.path(), QStringLiteral("Moon.2009.mkv")));
        QVERIFY(writeMediaFile(library.path(), QStringLiteral("Heat (1995)/Heat (1995).mkv")));
        QVERIFY(writeFile(library.path(), QStringLiteral("Heat (1995)/backdrop.png"),
                          QByteArrayLiteral("art")));

        CatalogStore store(catalogPath);
        const QVector<MediaItem> items = refresh(store, {library.path()});
        QCOMPARE(items.size(), 3);
        QHash<QString, MediaItem> byTitle;
        for (const MediaItem &item : items) {
            byTitle.insert(item.title, item);
        }
        // v3's `-backdrop` name is an extra after the released names.
        QCOMPARE(byTitle.value(QStringLiteral("Arrival")).backdropRelativePath,
                 QStringLiteral("Arrival (2016)/fanart.jpg"));
        QCOMPARE(byTitle.value(QStringLiteral("Arrival")).backdropAbsolutePath,
                 QDir(library.path()).filePath(QStringLiteral("Arrival (2016)/fanart.jpg")));
        QCOMPARE(byTitle.value(QStringLiteral("Heat")).backdropRelativePath,
                 QStringLiteral("Heat (1995)/backdrop.png"));
        QVERIFY(byTitle.value(QStringLiteral("Moon")).backdropAbsolutePath.isEmpty());

        // A backdrop added later reaches the next projection.
        QVERIFY(writeFile(library.path(), QStringLiteral("Moon.2009-fanart.jpg"),
                          QByteArrayLiteral("art")));
        for (const MediaItem &item : refresh(store, {library.path()})) {
            if (item.title == QStringLiteral("Moon")) {
                QCOMPARE(item.backdropRelativePath, QStringLiteral("Moon.2009-fanart.jpg"));
            }
        }
    }

    // CatalogContentPolicy.swift:96-136: across jpg, jpeg, png and webp, a
    // folder's `fanart` and `backdrop` come before the file's `<base> fanart`
    // and `<base> backdrop`; v3's `<base>-backdrop` and `<base>-fanart` follow.
    void aBackdropSidecarIsFoundByEveryReleasedNameAndExtension()
    {
        const QStringList extensions{QStringLiteral("jpg"), QStringLiteral("jpeg"),
                                     QStringLiteral("png"), QStringLiteral("webp")};
        const QStringList names{QStringLiteral("fanart"), QStringLiteral("backdrop"),
                                QStringLiteral("Heat (1995) fanart"),
                                QStringLiteral("Heat (1995) backdrop"),
                                QStringLiteral("Heat (1995)-backdrop"),
                                QStringLiteral("Heat (1995)-fanart")};
        const auto backdropOf = [](const QStringList &sidecars) {
            QTemporaryDir library;
            if (!writeMediaFile(library.path(), QStringLiteral("Heat (1995)/Heat (1995).mkv"))) {
                return QStringLiteral("<media not written>");
            }
            for (const QString &sidecar : sidecars) {
                if (!writeFile(library.path(), QStringLiteral("Heat (1995)/") + sidecar,
                               QByteArrayLiteral("art"))) {
                    return QStringLiteral("<sidecar not written>");
                }
            }
            const LibraryScanner::ScanResult result = LibraryScanner::scan(rootAt(library.path()));
            return result.items.size() == 1
                ? result.items.constFirst().backdropRelativePath
                : QStringLiteral("<%1 items>").arg(result.items.size());
        };

        for (const QString &name : names) {
            for (const QString &extension : extensions) {
                const QString file = name + QLatin1Char('.') + extension;
                QCOMPARE(backdropOf({file}), QStringLiteral("Heat (1995)/") + file);
            }
        }

        // Extension order leads: a jpg of a later name beats a webp of an
        // earlier one, and within an extension the released names keep their order.
        QCOMPARE(backdropOf({QStringLiteral("fanart.webp"),
                             QStringLiteral("Heat (1995) backdrop.jpg")}),
                 QStringLiteral("Heat (1995)/Heat (1995) backdrop.jpg"));
        QCOMPARE(backdropOf({QStringLiteral("backdrop.png"), QStringLiteral("fanart.png"),
                             QStringLiteral("Heat (1995) fanart.png")}),
                 QStringLiteral("Heat (1995)/fanart.png"));
        QCOMPARE(backdropOf({QStringLiteral("Heat (1995) backdrop.png"),
                             QStringLiteral("Heat (1995) fanart.png")}),
                 QStringLiteral("Heat (1995)/Heat (1995) fanart.png"));
        QCOMPARE(backdropOf({QStringLiteral("Heat (1995)-backdrop.jpg"),
                             QStringLiteral("backdrop.webp")}),
                 QStringLiteral("Heat (1995)/backdrop.webp"));
        QCOMPARE(backdropOf({QStringLiteral("Heat (1995)-fanart.jpg"),
                             QStringLiteral("Heat (1995)-backdrop.jpg")}),
                 QStringLiteral("Heat (1995)/Heat (1995)-backdrop.jpg"));
    }

    void folderArtworkCoversItsOwnDirectoryOnly()
    {
        QTemporaryDir library;
        QVERIFY(writeMediaFile(library.path(), QStringLiteral("Trilogy/Part One.mkv")));
        QVERIFY(writeMediaFile(library.path(), QStringLiteral("Trilogy/Part Two.mkv")));
        QVERIFY(writeFile(library.path(), QStringLiteral("Trilogy/poster.jpg"),
                          QByteArrayLiteral("art")));
        QVERIFY(writeMediaFile(library.path(), QStringLiteral("Moon.2009.mkv")));

        const LibraryScanner::ScanResult result = LibraryScanner::scan(rootAt(library.path()));

        QCOMPARE(relativePathsOf(result.items),
                 QStringList({QStringLiteral("Moon.2009.mkv"),
                              QStringLiteral("Trilogy/Part One.mkv"),
                              QStringLiteral("Trilogy/Part Two.mkv")}));
        QCOMPARE(posterPathsOf(result.items),
                 QStringList({QString(),
                              QStringLiteral("Trilogy/poster.jpg"),
                              QStringLiteral("Trilogy/poster.jpg")}));
    }

    void folderArtworkFollowsTheDocumentedNameOrder()
    {
        QTemporaryDir library;
        QVERIFY(writeMediaFile(library.path(), QStringLiteral("Moon.2009.mkv")));
        QVERIFY(writeFile(library.path(), QStringLiteral("poster.jpg"),
                          QByteArrayLiteral("art")));
        QVERIFY(writeFile(library.path(), QStringLiteral("folder.jpg"),
                          QByteArrayLiteral("art")));
        QVERIFY(writeFile(library.path(), QStringLiteral("poster.png"),
                          QByteArrayLiteral("art")));

        QCOMPARE(posterPathsOf(LibraryScanner::scan(rootAt(library.path())).items),
                 QStringList({QStringLiteral("poster.jpg")}));

        QVERIFY(QFile::remove(QDir(library.path()).filePath(QStringLiteral("poster.jpg"))));
        QCOMPARE(posterPathsOf(LibraryScanner::scan(rootAt(library.path())).items),
                 QStringList({QStringLiteral("folder.jpg")}));

        QVERIFY(QFile::remove(QDir(library.path()).filePath(QStringLiteral("folder.jpg"))));
        QCOMPARE(posterPathsOf(LibraryScanner::scan(rootAt(library.path())).items),
                 QStringList({QStringLiteral("poster.png")}));
    }

    void scanIgnoresASymlinkedPoster()
    {
        QTemporaryDir outside;
        QTemporaryDir library;
        QVERIFY(writeFile(outside.path(), QStringLiteral("elsewhere.jpg"),
                          QByteArrayLiteral("art")));
        QVERIFY(writeMediaFile(library.path(), QStringLiteral("Moon.2009.mkv")));
        QVERIFY(QFile::link(QDir(outside.path()).filePath(QStringLiteral("elsewhere.jpg")),
                            QDir(library.path()).filePath(QStringLiteral("poster.jpg"))));

        const LibraryScanner::ScanResult result = LibraryScanner::scan(rootAt(library.path()));

        QCOMPARE(result.outcome, LibraryScanner::ScanOutcome::Complete);
        QCOMPARE(posterPathsOf(result.items), QStringList({QString()}));
    }

    void registeringARootReusesItsStoredIdentity()
    {
        QTemporaryDir dataDirectory;
        QTemporaryDir library;
        const QString catalogPath =
            QDir(dataDirectory.path()).filePath(QStringLiteral("catalog.sqlite"));
        migrateCatalog(catalogPath);

        CatalogStore store(catalogPath);
        const QVector<LibraryRoot> first = store.registerRoots({library.path()});
        const QVector<LibraryRoot> second = store.registerRoots({library.path()});

        QCOMPARE(first.size(), 1);
        QCOMPARE(second.size(), 1);
        QVERIFY(!first.constFirst().id.isEmpty());
        QCOMPARE(second.constFirst().id, first.constFirst().id);
        QCOMPARE(second.constFirst().displayName, QDir(library.path()).dirName());
    }

    void registeringRootsIgnoresBlankAndRepeatedPaths()
    {
        QTemporaryDir dataDirectory;
        QTemporaryDir library;
        const QString catalogPath =
            QDir(dataDirectory.path()).filePath(QStringLiteral("catalog.sqlite"));
        migrateCatalog(catalogPath);

        CatalogStore store(catalogPath);
        const QVector<LibraryRoot> roots = store.registerRoots(
            {library.path(), QStringLiteral("   "), library.path() + QStringLiteral("/"),
             QString()});

        QCOMPARE(roots.size(), 1);
        QCOMPARE(roots.constFirst().path, library.path());
    }

    void scanApplyProjectsStoredItemsWithTheirAbsolutePaths()
    {
        QTemporaryDir dataDirectory;
        QTemporaryDir library;
        const QString catalogPath =
            QDir(dataDirectory.path()).filePath(QStringLiteral("catalog.sqlite"));
        migrateCatalog(catalogPath);

        QVERIFY(writeMediaFile(library.path(), QStringLiteral("Moon.2009.mkv")));
        QVERIFY(writeMediaFile(library.path(),
                               QStringLiteral("Arrival (2016)/Arrival (2016).mkv")));

        CatalogStore store(catalogPath);
        const QVector<MediaItem> items = refresh(store, {library.path()});

        QCOMPARE(titlesOf(items),
                 QStringList({QStringLiteral("Arrival"), QStringLiteral("Moon")}));
        QCOMPARE(items.constFirst().year, 2016);
        QCOMPARE(items.constFirst().absolutePath,
                 QDir(library.path())
                     .filePath(QStringLiteral("Arrival (2016)/Arrival (2016).mkv")));
        QCOMPARE(catalogValue(catalogPath,
                              QStringLiteral("SELECT available FROM library_roots")),
                 QStringLiteral("1"));
    }

    void sidecarArtworkIsStoredRelativelyAndProjectedAbsolutely()
    {
        QTemporaryDir dataDirectory;
        QTemporaryDir library;
        const QString catalogPath =
            QDir(dataDirectory.path()).filePath(QStringLiteral("catalog.sqlite"));
        migrateCatalog(catalogPath);

        QVERIFY(writeMediaFile(library.path(),
                               QStringLiteral("Arrival (2016)/Arrival (2016).mkv")));
        QVERIFY(writeFile(library.path(), QStringLiteral("Arrival (2016)/poster.jpg"),
                          QByteArrayLiteral("art")));
        QVERIFY(writeMediaFile(library.path(), QStringLiteral("Moon.2009.mkv")));

        CatalogStore store(catalogPath);
        const QVector<MediaItem> items = refresh(store, {library.path()});

        QCOMPARE(posterPathsOf(items),
                 QStringList({QStringLiteral("Arrival (2016)/poster.jpg"), QString()}));
        QCOMPARE(items.constFirst().posterAbsolutePath,
                 QDir(library.path()).filePath(QStringLiteral("Arrival (2016)/poster.jpg")));
        QVERIFY(items.constLast().posterAbsolutePath.isEmpty());

        // The row records where the artwork sits inside its root, never where
        // that root currently is.
        QCOMPARE(catalogValue(catalogPath,
                              QStringLiteral("SELECT poster_path FROM media_items "
                                             "ORDER BY sort_title")),
                 QStringLiteral("Arrival (2016)/poster.jpg"));
    }

    void artworkAddedAfterTheFirstScanReachesTheNextProjection()
    {
        QTemporaryDir dataDirectory;
        QTemporaryDir library;
        const QString catalogPath =
            QDir(dataDirectory.path()).filePath(QStringLiteral("catalog.sqlite"));
        migrateCatalog(catalogPath);

        QVERIFY(writeMediaFile(library.path(), QStringLiteral("Moon.2009.mkv")));

        CatalogStore store(catalogPath);
        QCOMPARE(posterPathsOf(refresh(store, {library.path()})), QStringList({QString()}));

        QVERIFY(writeFile(library.path(), QStringLiteral("Moon.2009-poster.jpg"),
                          QByteArrayLiteral("art")));

        QCOMPARE(posterPathsOf(refresh(store, {library.path()})),
                 QStringList({QStringLiteral("Moon.2009-poster.jpg")}));
    }

    void rescanAppliesAdditionsUpdatesAndRemovals()
    {
        QTemporaryDir dataDirectory;
        QTemporaryDir library;
        const QString catalogPath =
            QDir(dataDirectory.path()).filePath(QStringLiteral("catalog.sqlite"));
        migrateCatalog(catalogPath);

        QVERIFY(writeMediaFile(library.path(), QStringLiteral("Moon.2009.mkv")));
        QVERIFY(writeMediaFile(library.path(), QStringLiteral("Nope.2022.mkv")));

        CatalogStore store(catalogPath);
        QCOMPARE(refresh(store, {library.path()}).size(), 2);

        QVERIFY(QFile::remove(QDir(library.path()).filePath(QStringLiteral("Nope.2022.mkv"))));
        QVERIFY(writeFile(library.path(), QStringLiteral("Moon.2009.mkv"),
                          QByteArrayLiteral("a longer file")));
        QVERIFY(writeMediaFile(library.path(), QStringLiteral("Arrival.2016.mkv")));

        const QVector<MediaItem> items = refresh(store, {library.path()});

        QCOMPARE(titlesOf(items),
                 QStringList({QStringLiteral("Arrival"), QStringLiteral("Moon")}));
        QCOMPARE(items.constLast().fileSize, qint64{13});
    }

    void rescanKeepsTheOriginalDiscoveryTimestampOfASurvivingItem()
    {
        QTemporaryDir dataDirectory;
        QTemporaryDir library;
        const QString catalogPath =
            QDir(dataDirectory.path()).filePath(QStringLiteral("catalog.sqlite"));
        migrateCatalog(catalogPath);

        QVERIFY(writeMediaFile(library.path(), QStringLiteral("Moon.2009.mkv")));

        CatalogStore store(catalogPath);
        QCOMPARE(refresh(store, {library.path()}).size(), 1);
        const QString discoveredAt = catalogValue(
            catalogPath, QStringLiteral("SELECT discovered_at FROM media_items"));
        QVERIFY(!discoveredAt.isEmpty());

        QVERIFY(writeFile(library.path(), QStringLiteral("Moon.2009.mkv"),
                          QByteArrayLiteral("a longer file")));
        QCOMPARE(refresh(store, {library.path()}).size(), 1);

        QCOMPARE(catalogValue(catalogPath,
                              QStringLiteral("SELECT discovered_at FROM media_items")),
                 discoveredAt);
    }

    void anUnavailableRootKeepsItsStoredRows()
    {
        QTemporaryDir dataDirectory;
        QTemporaryDir library;
        const QString catalogPath =
            QDir(dataDirectory.path()).filePath(QStringLiteral("catalog.sqlite"));
        migrateCatalog(catalogPath);

        QVERIFY(writeMediaFile(library.path(), QStringLiteral("Moon.2009.mkv")));
        QVERIFY(writeMediaFile(library.path(), QStringLiteral("Nope.2022.mkv")));

        CatalogStore store(catalogPath);
        QCOMPARE(refresh(store, {library.path()}).size(), 2);
        QVERIFY(QDir(library.path()).removeRecursively());

        const QVector<MediaItem> items = refresh(store, {library.path()});

        QCOMPARE(titlesOf(items),
                 QStringList({QStringLiteral("Moon"), QStringLiteral("Nope")}));
        QCOMPARE(catalogValue(catalogPath,
                              QStringLiteral("SELECT available FROM library_roots")),
                 QStringLiteral("0"));
    }

    // A listed file that fails stat is still there, so a complete walk must
    // not read its absence as deletion; a file that is really gone still is.
    void aCompleteWalkKeepsTheRowOfAListedFileThatFailedStat()
    {
        QTemporaryDir dataDirectory;
        QTemporaryDir library;
        const QString catalogPath =
            QDir(dataDirectory.path()).filePath(QStringLiteral("catalog.sqlite"));
        migrateCatalog(catalogPath);
        QVERIFY(writeMediaFile(library.path(), QStringLiteral("Moon.2009.mkv")));
        QVERIFY(writeMediaFile(library.path(), QStringLiteral("Arrival (2016)/Arrival (2016).mkv")));
        QVERIFY(writeMediaFile(library.path(), QStringLiteral("Heat.1995.mkv")));

        CatalogStore store(catalogPath);
        const QVector<LibraryRoot> roots = store.registerRoots({library.path()});
        QCOMPARE(roots.size(), 1);
        store.applyScan(roots.constFirst(), LibraryScanner::scan(roots.constFirst()));
        QVector<MediaItem> stored = store.projection(roots, QStringLiteral("profile-1"));
        QCOMPARE(stored.size(), 3);

        QString moonId;
        QString heatId;
        for (const MediaItem &item : stored) {
            if (item.title == QStringLiteral("Moon")) {
                moonId = item.id;
            } else if (item.title == QStringLiteral("Heat")) {
                heatId = item.id;
            }
        }
        QVERIFY(!moonId.isEmpty());
        QVERIFY(!heatId.isEmpty());
        store.recordWatchProgress(QStringLiteral("profile-1"), moonId, 5000, 90000, false);

        // Moon failed stat this time; Heat is gone from the listing altogether.
        LibraryScanner::ScanResult result;
        result.outcome = LibraryScanner::ScanOutcome::Complete;
        for (const MediaItem &item : stored) {
            if (item.id != moonId && item.id != heatId) {
                result.items.push_back(item);
            }
        }
        result.unreadableIds.insert(moonId);

        store.applyScan(roots.constFirst(), result);

        const QVector<MediaItem> after = store.projection(roots, QStringLiteral("profile-1"));
        QCOMPARE(titlesOf(after), QStringList({QStringLiteral("Arrival"), QStringLiteral("Moon")}));
        for (const MediaItem &item : after) {
            if (item.id == moonId) {
                QCOMPARE(item.resumePositionMs, qint64(5000));
            }
        }
    }

    void aPartiallyReadableRootKeepsItsPreviouslyCatalogedRows()
    {
        QTemporaryDir dataDirectory;
        QTemporaryDir library;
        const QString catalogPath =
            QDir(dataDirectory.path()).filePath(QStringLiteral("catalog.sqlite"));
        migrateCatalog(catalogPath);

        QVERIFY(writeMediaFile(library.path(), QStringLiteral("Moon.2009.mkv")));
        const QString locked = QDir(library.path()).filePath(QStringLiteral("Archive"));
        QVERIFY(writeMediaFile(locked, QStringLiteral("Arrival.2016.mkv")));

        CatalogStore store(catalogPath);
        QCOMPARE(refresh(store, {library.path()}).size(), 2);

        QVERIFY(blockDirectoryListing(locked));
        const auto restore = qScopeGuard([&locked] { restoreDirectoryListing(locked); });

        const QVector<MediaItem> items = refresh(store, {library.path()});

        QCOMPARE(titlesOf(items),
                 QStringList({QStringLiteral("Arrival"), QStringLiteral("Moon")}));
    }

    // A stored root missing from disk is the ordinary unplugged case, so a newly
    // configured directory must never inherit its identity: doing so would hand
    // one library's rows, and later its watch state, to an unrelated one.
    void replacingAnOfflineRootCreatesAFreshIdentityAndKeepsItsRows()
    {
        QTemporaryDir dataDirectory;
        QTemporaryDir enclosing;
        const QString catalogPath =
            QDir(dataDirectory.path()).filePath(QStringLiteral("catalog.sqlite"));
        migrateCatalog(catalogPath);

        const QString offline = QDir(enclosing.path()).filePath(QStringLiteral("Movies"));
        QVERIFY(writeMediaFile(offline, QStringLiteral("Moon.2009.mkv")));
        QVERIFY(writeMediaFile(offline,
                               QStringLiteral("Arrival (2016)/Arrival (2016).mkv")));

        CatalogStore store(catalogPath);
        const QVector<MediaItem> original = refresh(store, {offline});
        QCOMPARE(original.size(), 2);

        QVERIFY(QDir(offline).removeRecursively());

        const QString replacement =
            QDir(enclosing.path()).filePath(QStringLiteral("Archive"));
        QVERIFY(writeMediaFile(replacement, QStringLiteral("Nope.2022.mkv")));

        const QVector<MediaItem> items = refresh(store, {replacement});

        QCOMPARE(titlesOf(items), QStringList({QStringLiteral("Nope")}));
        const QStringList replacementIds = idsOf(items);
        for (const QString &id : idsOf(original)) {
            QVERIFY(!replacementIds.contains(id));
        }

        // The offline root keeps its own row and every item it contributed.
        QCOMPARE(catalogValue(catalogPath,
                              QStringLiteral("SELECT count(*) FROM library_roots")),
                 QStringLiteral("2"));
        QCOMPARE(catalogValue(catalogPath,
                              QStringLiteral("SELECT count(*) FROM media_items")),
                 QStringLiteral("3"));
        QCOMPARE(idsOf(refresh(store, {offline})), idsOf(original));
    }

    void projectionCoversOnlyTheRootsStillConfigured()
    {
        QTemporaryDir dataDirectory;
        QTemporaryDir movies;
        QTemporaryDir extras;
        const QString catalogPath =
            QDir(dataDirectory.path()).filePath(QStringLiteral("catalog.sqlite"));
        migrateCatalog(catalogPath);

        QVERIFY(writeMediaFile(movies.path(), QStringLiteral("Moon.2009.mkv")));
        QVERIFY(writeMediaFile(extras.path(), QStringLiteral("Arrival.2016.mkv")));

        CatalogStore store(catalogPath);
        QCOMPARE(refresh(store, {movies.path(), extras.path()}).size(), 2);

        const QVector<MediaItem> items = refresh(store, {movies.path()});

        QCOMPARE(titlesOf(items), QStringList({QStringLiteral("Moon")}));
        QCOMPARE(catalogValue(catalogPath,
                              QStringLiteral("SELECT count(*) FROM media_items")),
                 QStringLiteral("2"));
    }

    void startupScansTheConfiguredRootWithoutBlockingTheGuiThread()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        QTemporaryDir library;
        QVERIFY(writeMediaFile(library.path(),
                               QStringLiteral("Arrival (2016)/Arrival (2016).mkv")));
        QVERIFY(writeMediaFile(library.path(), QStringLiteral("Moon.2009.mkv")));

        ApplicationController controller;
        QVERIFY2(!controller.hasError(), qPrintable(controller.errorMessage()));
        controller.setTemporaryLibraryRoot(library.path());

        // The walk runs on the catalog thread, so the projection cannot have
        // reached the model before this thread returns to its event loop.
        QCOMPARE(controller.library()->rowCount(), 0);
        QTRY_COMPARE(controller.library()->rowCount(), 2);

        const QModelIndex first = controller.library()->index(0, 0);
        QCOMPARE(controller.library()->data(first, LibraryModel::TitleRole).toString(),
                 QStringLiteral("Arrival"));
        QCOMPARE(controller.library()->data(first, LibraryModel::YearRole).toInt(), 2016);
        QCOMPARE(controller.library()->data(first, LibraryModel::KindRole).toString(),
                 QStringLiteral("movie"));
        QVERIFY2(!controller.hasError(), qPrintable(controller.errorMessage()));
    }

    void storedRowsStayBrowsableAfterTheRootDisappears()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        QTemporaryDir library;
        QVERIFY(writeMediaFile(library.path(), QStringLiteral("Moon.2009.mkv")));
        const QString libraryPath = library.path();

        {
            ApplicationController controller;
            controller.setTemporaryLibraryRoot(libraryPath);
            QTRY_COMPARE(controller.library()->rowCount(), 1);
        }

        QVERIFY(QDir(libraryPath).removeRecursively());

        ApplicationController controller;
        controller.setTemporaryLibraryRoot(libraryPath);

        QTRY_COMPARE(controller.library()->rowCount(), 1);
        QCOMPARE(controller.library()
                     ->data(controller.library()->index(0, 0), LibraryModel::TitleRole)
                     .toString(),
                 QStringLiteral("Moon"));

        // Browsing keeps working, and the root being gone is stated rather than
        // left for the user to infer from a library that stopped changing.
        QTRY_VERIFY(controller.hasError());
        QCOMPARE(controller.errorTitle(), QStringLiteral("Library unavailable"));
    }
};

QTEST_MAIN(LibraryScannerTest)
#include "tst_library_scanner.moc"
