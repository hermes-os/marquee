#include <QDir>
#include <QFile>
#include <QFileDevice>
#include <QFileInfo>
#include <QScopeGuard>
#include <QSemaphore>
#include <QSqlQuery>
#include <QTemporaryDir>
#include <QtTest>
#include <QVariantList>

#include <cstddef>
#include <stdexcept>
#include <thread>
#include <vector>

#include "app/AppPaths.hpp"
#include "app/ApplicationController.hpp"
#include "catalog/CatalogDatabase.hpp"
#include "catalog/LibraryScanner.hpp"
#include "profiles/ProfileStore.hpp"

namespace
{
constexpr auto insertMoviesRoot =
    "INSERT INTO library_roots (id, path, display_name) "
    "VALUES ('root-1', '/fixtures/movies', 'Movies')";

[[nodiscard]] QString insertMediaItem(const QString &id, const QString &rootId)
{
    return QStringLiteral(
               "INSERT INTO media_items (id, library_root_id, relative_path, "
               "media_kind, title, sort_title, file_size, modified_at, "
               "discovered_at, updated_at) "
               "VALUES (%1, %2, 'Arrival (2016)/Arrival.mkv', 'movie', "
               "'Arrival', 'arrival', 1024, '2016-01-01T00:00:00Z', "
               "'2016-01-01T00:00:00Z', '2016-01-01T00:00:00Z')")
        .arg(id, rootId);
}

bool execute(CatalogDatabase &catalog, const QString &sql)
{
    QSqlQuery query(catalog.connection());
    return query.exec(sql);
}

[[nodiscard]] int schemaVersionOf(CatalogDatabase &catalog)
{
    QSqlQuery query(catalog.connection());
    if (!query.exec(QStringLiteral("PRAGMA user_version")) || !query.next()) {
        return -1;
    }
    return query.value(0).toInt();
}

[[nodiscard]] QStringList tableNames(CatalogDatabase &catalog)
{
    QSqlQuery query(catalog.connection());
    if (!query.exec(QStringLiteral("SELECT name FROM sqlite_master "
                                   "WHERE type = 'table' ORDER BY name"))) {
        return {};
    }

    QStringList names;
    while (query.next()) {
        names.push_back(query.value(0).toString());
    }
    return names;
}

// SQLite names the implicit index behind a UNIQUE constraint itself, so only
// the explicitly created ones answer whether a migration recreated them.
[[nodiscard]] QStringList indexNames(CatalogDatabase &catalog)
{
    QSqlQuery query(catalog.connection());
    if (!query.exec(QStringLiteral("SELECT name FROM sqlite_master "
                                   "WHERE type = 'index' "
                                   "AND name NOT LIKE 'sqlite_%' ORDER BY name"))) {
        return {};
    }

    QStringList names;
    while (query.next()) {
        names.push_back(query.value(0).toString());
    }
    return names;
}

[[nodiscard]] QString journalModeOf(CatalogDatabase &catalog)
{
    QSqlQuery query(catalog.connection());
    if (!query.exec(QStringLiteral("PRAGMA journal_mode")) || !query.next()) {
        return {};
    }
    return query.value(0).toString();
}

[[nodiscard]] int rowCount(CatalogDatabase &catalog, const QString &table)
{
    QSqlQuery query(catalog.connection());
    if (!query.exec(QStringLiteral("SELECT count(*) FROM %1").arg(table))
        || !query.next()) {
        return -1;
    }
    return query.value(0).toInt();
}

// Version 1 declared both identity columns without NOT NULL, which SQLite
// accepts on a TEXT primary key, so upgrade cases start from that exact file.
[[nodiscard]] bool seedVersionOneCatalog(const QString &path)
{
    CatalogDatabase catalog(path);
    return execute(catalog, R"SQL(
               CREATE TABLE library_roots (
                   id TEXT PRIMARY KEY,
                   path TEXT NOT NULL UNIQUE,
                   display_name TEXT NOT NULL,
                   available INTEGER NOT NULL DEFAULT 1,
                   last_scan_at TEXT
               )
           )SQL")
        && execute(catalog, R"SQL(
               CREATE TABLE media_items (
                   id TEXT PRIMARY KEY,
                   library_root_id TEXT NOT NULL,
                   relative_path TEXT NOT NULL,
                   media_kind TEXT NOT NULL,
                   title TEXT NOT NULL,
                   sort_title TEXT NOT NULL,
                   year INTEGER,
                   poster_path TEXT,
                   backdrop_path TEXT,
                   file_size INTEGER NOT NULL,
                   modified_at TEXT NOT NULL,
                   discovered_at TEXT NOT NULL,
                   updated_at TEXT NOT NULL,
                   FOREIGN KEY (library_root_id)
                       REFERENCES library_roots(id)
                       ON DELETE CASCADE,
                   UNIQUE (library_root_id, relative_path)
               )
           )SQL")
        && execute(
               catalog,
               "CREATE INDEX media_items_sort_title_idx ON media_items(sort_title)")
        && execute(
               catalog,
               "CREATE INDEX media_items_root_idx ON media_items(library_root_id)")
        && execute(catalog, "PRAGMA user_version = 1");
}

// The schema the previous build shipped (migrations 1-4), written out so the
// upgrade starts from the exact file a user would have, with two titles and
// one progress row each.
[[nodiscard]] bool seedVersionFourCatalog(const QString &path)
{
    CatalogDatabase catalog(path);
    return execute(catalog, R"SQL(
               CREATE TABLE library_roots (
                   id TEXT PRIMARY KEY NOT NULL,
                   path TEXT NOT NULL UNIQUE,
                   display_name TEXT NOT NULL,
                   available INTEGER NOT NULL DEFAULT 1,
                   last_scan_at TEXT
               )
           )SQL")
        && execute(catalog, R"SQL(
               CREATE TABLE media_items (
                   id TEXT PRIMARY KEY NOT NULL,
                   library_root_id TEXT NOT NULL,
                   relative_path TEXT NOT NULL,
                   media_kind TEXT NOT NULL,
                   title TEXT NOT NULL,
                   sort_title TEXT NOT NULL,
                   year INTEGER,
                   poster_path TEXT,
                   backdrop_path TEXT,
                   file_size INTEGER NOT NULL,
                   modified_at TEXT NOT NULL,
                   discovered_at TEXT NOT NULL,
                   updated_at TEXT NOT NULL,
                   show_name TEXT,
                   season_number INTEGER,
                   episode_number INTEGER,
                   episode_title TEXT,
                   show_poster_path TEXT,
                   show_backdrop_path TEXT,
                   season_poster_path TEXT,
                   episode_still_path TEXT,
                   FOREIGN KEY (library_root_id)
                       REFERENCES library_roots(id)
                       ON DELETE CASCADE,
                   UNIQUE (library_root_id, relative_path)
               )
           )SQL")
        && execute(catalog, R"SQL(
               CREATE TABLE watch_progress (
                   media_id TEXT PRIMARY KEY NOT NULL,
                   position_ms INTEGER NOT NULL DEFAULT 0,
                   duration_ms INTEGER NOT NULL DEFAULT 0,
                   completed INTEGER NOT NULL DEFAULT 0,
                   updated_at TEXT NOT NULL,
                   FOREIGN KEY (media_id)
                       REFERENCES media_items(id)
                       ON DELETE CASCADE
               )
           )SQL")
        && execute(catalog,
                   "CREATE INDEX media_items_sort_title_idx ON media_items(sort_title)")
        && execute(catalog,
                   "CREATE INDEX media_items_root_idx ON media_items(library_root_id)")
        && execute(catalog, "CREATE INDEX media_items_show_idx ON media_items(show_name)")
        && execute(catalog, insertMoviesRoot)
        && execute(catalog, QStringLiteral(
               "INSERT INTO media_items (id, library_root_id, relative_path, "
               "media_kind, title, sort_title, file_size, modified_at, "
               "discovered_at, updated_at) VALUES "
               "('item-1', 'root-1', 'One.mkv', 'movie', 'One', 'one', 1, "
               "'2016-01-01T00:00:00Z', '2016-01-01T00:00:00Z', '2016-01-01T00:00:00Z'), "
               "('item-2', 'root-1', 'Two.mkv', 'movie', 'Two', 'two', 1, "
               "'2016-01-01T00:00:00Z', '2016-01-01T00:00:00Z', '2016-01-01T00:00:00Z')"))
        && execute(catalog,
                   "INSERT INTO watch_progress (media_id, position_ms, duration_ms, "
                   "completed, updated_at) VALUES "
                   "('item-1', 600000, 7200000, 0, '2026-01-01T00:00:00Z'), "
                   "('item-2', 0, 5400000, 1, '2026-01-02T00:00:00Z')")
        && execute(catalog, "PRAGMA user_version = 4");
}

/// position_ms, duration_ms, completed of one profile's row, or an empty list.
[[nodiscard]] QVariantList progressOf(CatalogDatabase &catalog,
                                      const QString &profileId,
                                      const QString &mediaId)
{
    QSqlQuery query(catalog.connection());
    if (!query.prepare("SELECT position_ms, duration_ms, completed FROM watch_progress "
                       "WHERE profile_id = ? AND media_id = ?")) {
        return {};
    }
    query.addBindValue(profileId);
    query.addBindValue(mediaId);
    if (!query.exec() || !query.next()) {
        return {};
    }
    return {query.value(0), query.value(1), query.value(2)};
}
}

class CatalogBootstrapTest final : public QObject
{
    Q_OBJECT

private slots:
    void migratesFreshCatalogToTheCurrentSchemaVersion()
    {
        QTemporaryDir dataDirectory;
        const QString path = QDir(dataDirectory.path()).filePath("catalog.sqlite");

        CatalogDatabase catalog(path);
        catalog.migrate();

        QVERIFY(QFileInfo::exists(path));
        QCOMPARE(schemaVersionOf(catalog), 6);
        QCOMPARE(tableNames(catalog),
                 QStringList({"episode_metadata", "library_roots", "media_items",
                                      "title_cast", "title_keyword", "title_metadata",
                                      "watch_progress"}));
    }

    void reopeningMigratedCatalogKeepsSchemaVersionAndRows()
    {
        QTemporaryDir dataDirectory;
        const QString path = QDir(dataDirectory.path()).filePath("catalog.sqlite");

        {
            CatalogDatabase catalog(path);
            catalog.migrate();
            QVERIFY(execute(catalog, insertMoviesRoot));
        }

        CatalogDatabase reopened(path);
        reopened.migrate();

        QCOMPARE(schemaVersionOf(reopened), 6);
        QCOMPARE(rowCount(reopened, "library_roots"), 1);
    }

    void rejectsMediaItemsWithoutTheirLibraryRoot()
    {
        QTemporaryDir dataDirectory;
        CatalogDatabase catalog(
            QDir(dataDirectory.path()).filePath("catalog.sqlite"));
        catalog.migrate();

        QVERIFY(execute(catalog, insertMoviesRoot));
        QVERIFY(!execute(catalog, insertMediaItem("'item-1'", "'missing-root'")));
        QVERIFY(execute(catalog, insertMediaItem("'item-2'", "'root-1'")));

        QVERIFY(execute(catalog, "DELETE FROM library_roots WHERE id = 'root-1'"));
        QCOMPARE(rowCount(catalog, "media_items"), 0);
    }

    void failedMigrationRollsBackAndKeepsExistingRows()
    {
        QTemporaryDir dataDirectory;
        const QString path = QDir(dataDirectory.path()).filePath("catalog.sqlite");

        QString seededJournalMode;
        {
            CatalogDatabase conflicting(path);
            QVERIFY(execute(conflicting, "CREATE TABLE media_items (id TEXT PRIMARY KEY)"));
            QVERIFY(execute(conflicting, "INSERT INTO media_items (id) VALUES ('keep-me')"));
            seededJournalMode = journalModeOf(conflicting);
        }

        CatalogDatabase catalog(path);
        QVERIFY_EXCEPTION_THROWN(catalog.migrate(), std::runtime_error);

        QCOMPARE(schemaVersionOf(catalog), 0);
        QCOMPARE(tableNames(catalog), QStringList({"media_items"}));
        QCOMPARE(rowCount(catalog, "media_items"), 1);
        QCOMPARE(journalModeOf(catalog), seededJournalMode);
        QVERIFY(!QFileInfo::exists(path + "-wal"));
    }

    void refusesCatalogWrittenByANewerSchema()
    {
        QTemporaryDir dataDirectory;
        const QString path = QDir(dataDirectory.path()).filePath("catalog.sqlite");

        QString seededJournalMode;
        {
            CatalogDatabase future(path);
            QVERIFY(execute(future, "PRAGMA user_version = 99"));
            seededJournalMode = journalModeOf(future);
        }

        CatalogDatabase catalog(path);
        QVERIFY_EXCEPTION_THROWN(catalog.migrate(), std::runtime_error);

        QCOMPARE(schemaVersionOf(catalog), 99);
        QVERIFY(tableNames(catalog).isEmpty());
        QCOMPARE(journalModeOf(catalog), seededJournalMode);
        QVERIFY(!QFileInfo::exists(path + "-wal"));
    }

    void migrationSwitchesTheCatalogToWriteAheadLogging()
    {
        QTemporaryDir dataDirectory;
        CatalogDatabase catalog(
            QDir(dataDirectory.path()).filePath("catalog.sqlite"));

        QVERIFY(journalModeOf(catalog).compare(QStringLiteral("wal"),
                                               Qt::CaseInsensitive)
                != 0);

        catalog.migrate();

        QCOMPARE(journalModeOf(catalog).toLower(), QStringLiteral("wal"));
    }

    void migrationKeepsThePreviousJournalModeWhenWriteAheadLoggingIsBlocked()
    {
        QTemporaryDir dataDirectory;
        const QString path = QDir(dataDirectory.path()).filePath("catalog.sqlite");

        {
            CatalogDatabase migrated(path);
            migrated.migrate();
        }
        {
            CatalogDatabase rolledBack(path);
            QVERIFY(execute(rolledBack, "PRAGMA journal_mode = DELETE"));
        }

        CatalogDatabase reader(path);
        QVERIFY(execute(reader, "BEGIN"));
        QVERIFY(execute(reader, "SELECT count(*) FROM library_roots"));

        CatalogDatabase catalog(path);
        // The reader's shared lock blocks the journal-mode change alone, and
        // without this the blocked attempt would sit out the busy timeout.
        QVERIFY(execute(catalog, "PRAGMA busy_timeout = 0"));
        catalog.migrate();

        QCOMPARE(journalModeOf(catalog).toLower(), QStringLiteral("delete"));
    }

    void concurrentBootstrapsMigrateTheCatalogOnce()
    {
        QTemporaryDir dataDirectory;
        const QString path = QDir(dataDirectory.path()).filePath("catalog.sqlite");

        constexpr int bootstraps = 4;
        QSemaphore start;
        std::vector<QString> failures(static_cast<std::size_t>(bootstraps));
        std::vector<std::thread> workers;

        for (int index = 0; index < bootstraps; ++index) {
            workers.emplace_back([&path, &start, &failures, index] {
                start.acquire();
                try {
                    CatalogDatabase catalog(path);
                    catalog.migrate();
                } catch (const std::exception &error) {
                    failures[static_cast<std::size_t>(index)] =
                        QString::fromStdString(error.what());
                }
            });
        }

        start.release(bootstraps);
        for (std::thread &worker : workers) {
            worker.join();
        }

        for (const QString &failure : failures) {
            QVERIFY2(failure.isEmpty(), qPrintable(failure));
        }

        CatalogDatabase catalog(path);
        QCOMPARE(schemaVersionOf(catalog), 6);
        QCOMPARE(tableNames(catalog),
                 QStringList({"episode_metadata", "library_roots", "media_items",
                                      "title_cast", "title_keyword", "title_metadata",
                                      "watch_progress"}));
    }

    void rejectsRowsWithoutAnIdentity()
    {
        QTemporaryDir dataDirectory;
        CatalogDatabase catalog(
            QDir(dataDirectory.path()).filePath("catalog.sqlite"));
        catalog.migrate();

        QVERIFY(!execute(catalog,
                         "INSERT INTO library_roots (id, path, display_name) "
                         "VALUES (NULL, '/fixtures/movies', 'Movies')"));
        QVERIFY(execute(catalog, insertMoviesRoot));
        QVERIFY(!execute(catalog, insertMediaItem("NULL", "'root-1'")));

        QCOMPARE(rowCount(catalog, "library_roots"), 1);
        QCOMPARE(rowCount(catalog, "media_items"), 0);
    }

    void upgradesAVersionOneCatalogWithoutLosingRows()
    {
        QTemporaryDir dataDirectory;
        const QString path = QDir(dataDirectory.path()).filePath("catalog.sqlite");
        QVERIFY(seedVersionOneCatalog(path));

        {
            CatalogDatabase seeded(path);
            QVERIFY(execute(seeded, insertMoviesRoot));
            QVERIFY(execute(seeded, insertMediaItem("'item-1'", "'root-1'")));
        }

        CatalogDatabase catalog(path);
        catalog.migrate();

        QCOMPARE(schemaVersionOf(catalog), 6);
        QCOMPARE(tableNames(catalog),
                 QStringList({"episode_metadata", "library_roots", "media_items",
                                      "title_cast", "title_keyword", "title_metadata",
                                      "watch_progress"}));
        QCOMPARE(
            indexNames(catalog),
            QStringList({"media_items_root_idx", "media_items_show_idx",
                         "media_items_sort_title_idx", "watch_progress_media_idx"}));
        QCOMPARE(rowCount(catalog, "library_roots"), 1);
        QCOMPARE(rowCount(catalog, "media_items"), 1);

        // Dropping media_items took its UNIQUE constraint with it, so the
        // rebuilt table has to reject a second row on the seeded path.
        QVERIFY(!execute(catalog, insertMediaItem("'item-2'", "'root-1'")));
        QCOMPARE(rowCount(catalog, "media_items"), 1);

        // The rebuilt child has to reference the rebuilt parent, not the
        // scratch table it was created against.
        QVERIFY(execute(catalog, "DELETE FROM library_roots WHERE id = 'root-1'"));
        QCOMPARE(rowCount(catalog, "media_items"), 0);
    }

    void upgradedVersionOneCatalogRejectsRowsWithoutAnIdentity()
    {
        QTemporaryDir dataDirectory;
        const QString path = QDir(dataDirectory.path()).filePath("catalog.sqlite");
        QVERIFY(seedVersionOneCatalog(path));

        CatalogDatabase catalog(path);
        catalog.migrate();

        QVERIFY(!execute(catalog,
                         "INSERT INTO library_roots (id, path, display_name) "
                         "VALUES (NULL, '/fixtures/movies', 'Movies')"));
        QVERIFY(execute(catalog, insertMoviesRoot));
        QVERIFY(!execute(catalog, insertMediaItem("NULL", "'root-1'")));

        QCOMPARE(rowCount(catalog, "library_roots"), 1);
        QCOMPARE(rowCount(catalog, "media_items"), 0);
    }

    void refusesToUpgradeAVersionOneCatalogHoldingANullIdentity()
    {
        QTemporaryDir dataDirectory;
        const QString path = QDir(dataDirectory.path()).filePath("catalog.sqlite");
        QVERIFY(seedVersionOneCatalog(path));

        QString seededJournalMode;
        {
            CatalogDatabase seeded(path);
            QVERIFY(execute(seeded, insertMoviesRoot));
            QVERIFY(execute(seeded,
                            "INSERT INTO library_roots (id, path, display_name) "
                            "VALUES (NULL, '/fixtures/shows', 'Shows')"));
            seededJournalMode = journalModeOf(seeded);
        }

        CatalogDatabase catalog(path);
        QVERIFY_EXCEPTION_THROWN(catalog.migrate(), std::runtime_error);

        QCOMPARE(schemaVersionOf(catalog), 1);
        QCOMPARE(tableNames(catalog), QStringList({"library_roots", "media_items"}));
        QCOMPARE(rowCount(catalog, "library_roots"), 2);
        QCOMPARE(journalModeOf(catalog), seededJournalMode);
        QVERIFY(!QFileInfo::exists(path + "-wal"));
    }

    void startupMigratesTheCatalogUnderIsolatedPaths()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        {
            ApplicationController controller;
            QVERIFY2(!controller.hasError(), qPrintable(controller.errorMessage()));
        }

        CatalogDatabase catalog(AppPaths::catalogFile());
        QCOMPARE(schemaVersionOf(catalog), 6);
    }

    void startupLoadsTheReadableFilesOfRootsWithUnreadableEntries()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        QTemporaryDir movies;
        QTemporaryDir shows;
        const auto write = [](const QString &root, const QString &relativePath) {
            const QFileInfo target(QDir(root).filePath(relativePath));
            QFile file(target.absoluteFilePath());
            return QDir().mkpath(target.absolutePath()) && file.open(QIODevice::WriteOnly)
                && file.write("media") == 5;
        };
        QVERIFY(write(movies.path(), QStringLiteral("Moon.2009.mkv")));
        QVERIFY(write(movies.path(), QStringLiteral("Broken Movie (2020).mkv")));
        QVERIFY(write(movies.path(), QStringLiteral("Archive/Heat.1995.mkv")));
        const QString locked = QDir(movies.path()).filePath(QStringLiteral("Archive"));
        QVERIFY(QFile::setPermissions(locked, QFileDevice::ExeOwner));
        const auto restoreListing = qScopeGuard([&locked] {
            QFile::setPermissions(locked,
                                  QFileDevice::ReadOwner | QFileDevice::WriteOwner
                                      | QFileDevice::ExeOwner);
        });
        QVERIFY(write(shows.path(), QStringLiteral("Show (2001)/Season 1/Show S01E02.mkv")));
        QVERIFY(write(shows.path(), QStringLiteral("Show (2001)/Season 1/Show S01E01.mkv")));

        // The listing names these two files and the stat refuses them. Set
        // before the controller starts its worker and cleared after it is gone.
        const auto restoreStat = qScopeGuard([] { LibraryScanner::setMediaStatForTest({}); });
        LibraryScanner::setMediaStatForTest(
            [](const QFileInfo &listed) -> std::optional<QFileInfo> {
                if (listed.fileName() == QStringLiteral("Broken Movie (2020).mkv")
                    || listed.fileName() == QStringLiteral("Show S01E01.mkv")) {
                    return std::nullopt;
                }
                return QFileInfo(listed.absoluteFilePath());
            });

        {
            ApplicationController controller;
            QVERIFY2(!controller.hasError(), qPrintable(controller.errorMessage()));
            controller.setTemporaryLibraryRoot(movies.path());
            controller.setTemporaryTvShowsRoot(shows.path());
            QTRY_COMPARE(controller.library()->rowCount(), 1);
            QTRY_COMPARE(controller.shows()->rowCount(), 1);
            QVERIFY2(!controller.hasError(), qPrintable(controller.errorMessage()));
        }

        CatalogDatabase catalog(AppPaths::catalogFile());
        QCOMPARE(rowCount(catalog, "media_items"), 2);
    }

    void startupReportsAnUnwritableCatalogInsteadOfFailing()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        AppPaths::ensureDirectories();
        const QString dataDirectory = AppPaths::dataDirectory();
        QVERIFY(QFile::setPermissions(
            dataDirectory, QFileDevice::ReadOwner | QFileDevice::ExeOwner));
        const auto restorePermissions = qScopeGuard([&dataDirectory] {
            QFile::setPermissions(dataDirectory,
                                  QFileDevice::ReadOwner | QFileDevice::WriteOwner
                                      | QFileDevice::ExeOwner);
        });

        ApplicationController controller;

        QVERIFY(controller.hasError());
        QCOMPARE(controller.errorTitle(), QStringLiteral("Library catalog"));
        QVERIFY(!QFileInfo::exists(AppPaths::catalogFile()));
    }

    // Migration 5. The app is not installed anywhere yet, so every stored row
    // is copied to every profile that exists rather than guessing an owner.
    void upgradingGivesEveryProfileACopyOfTheStoredProgress()
    {
        QTemporaryDir dataDirectory;
        const QString path = QDir(dataDirectory.path()).filePath("catalog.sqlite");
        QVERIFY(seedVersionFourCatalog(path));

        // An identity with a quote proves the id is data, not SQL.
        const QString kids = QStringLiteral("kid's");
        CatalogDatabase catalog(path);
        catalog.migrate({QStringLiteral("main"), kids});

        QCOMPARE(schemaVersionOf(catalog), 6);
        QCOMPARE(rowCount(catalog, "watch_progress"), 4);
        for (const QString &profile : {QStringLiteral("main"), kids}) {
            QCOMPARE(progressOf(catalog, profile, "item-1"),
                     (QVariantList{600000, 7200000, 0}));
            QCOMPARE(progressOf(catalog, profile, "item-2"),
                     (QVariantList{0, 5400000, 1}));
        }

        // A profile created after the upgrade starts with nothing.
        QVERIFY(progressOf(catalog, "created-later", "item-1").isEmpty());

        // The rebuilt table still follows its title away.
        QVERIFY(execute(catalog, "DELETE FROM media_items WHERE id = 'item-1'"));
        QCOMPARE(rowCount(catalog, "watch_progress"), 2);
    }

    void aProfileHasOneRowPerTitle()
    {
        QTemporaryDir dataDirectory;
        const QString path = QDir(dataDirectory.path()).filePath("catalog.sqlite");
        QVERIFY(seedVersionFourCatalog(path));

        CatalogDatabase catalog(path);
        // A repeated identity must not make the copy collide with itself.
        catalog.migrate({QStringLiteral("main"), QStringLiteral("main")});

        QCOMPARE(rowCount(catalog, "watch_progress"), 2);
        QVERIFY(!execute(catalog,
                         "INSERT INTO watch_progress (profile_id, media_id, updated_at) "
                         "VALUES ('main', 'item-1', 'now')"));
    }

    void upgradingTwiceChangesNothingTheSecondTime()
    {
        QTemporaryDir dataDirectory;
        const QString path = QDir(dataDirectory.path()).filePath("catalog.sqlite");
        QVERIFY(seedVersionFourCatalog(path));

        {
            CatalogDatabase catalog(path);
            catalog.migrate({QStringLiteral("main")});
            QVERIFY(execute(catalog,
                            "UPDATE watch_progress SET position_ms = 1 "
                            "WHERE media_id = 'item-1'"));
        }

        // Another profile appearing between launches is not a reason to copy
        // again: the rows now belong to the profile that wrote them.
        CatalogDatabase reopened(path);
        reopened.migrate({QStringLiteral("main"), QStringLiteral("added")});

        QCOMPARE(schemaVersionOf(reopened), 6);
        QCOMPARE(rowCount(reopened, "watch_progress"), 2);
        QCOMPARE(progressOf(reopened, "main", "item-1").at(0).toLongLong(), 1);
        QVERIFY(progressOf(reopened, "added", "item-1").isEmpty());
    }

    // The profile list can be unknown (profiles.json unreadable). That must not
    // block the library: the old rows are set aside, not dropped, and the
    // per-profile table starts empty.
    void upgradingWithStoredProgressAndNoProfilesSetsTheOldRowsAside()
    {
        QTemporaryDir dataDirectory;
        const QString path = QDir(dataDirectory.path()).filePath("catalog.sqlite");
        QVERIFY(seedVersionFourCatalog(path));

        CatalogDatabase catalog(path);
        catalog.migrate();

        QCOMPARE(schemaVersionOf(catalog), 6);
        QCOMPARE(rowCount(catalog, "watch_progress"), 0);
        QCOMPARE(rowCount(catalog, "watch_progress_v4_unowned"), 2);
        QCOMPARE(rowCount(catalog, "media_items"), 2);

        // The per-profile table is the real one: it takes rows and follows its
        // title away.
        QVERIFY(execute(catalog,
                        "INSERT INTO watch_progress (profile_id, media_id, updated_at) "
                        "VALUES ('main', 'item-1', 'now')"));
        QVERIFY(!execute(catalog,
                         "INSERT INTO watch_progress (profile_id, media_id, updated_at) "
                         "VALUES ('main', 'item-1', 'again')"));
        QVERIFY(indexNames(catalog).contains(QStringLiteral("watch_progress_media_idx")));
        QVERIFY(execute(catalog, "DELETE FROM media_items WHERE id = 'item-1'"));
        QCOMPARE(rowCount(catalog, "watch_progress"), 0);

        // Running again changes nothing.
        CatalogDatabase reopened(path);
        reopened.migrate({QStringLiteral("main")});
        QCOMPARE(rowCount(reopened, "watch_progress_v4_unowned"), 1);
    }

    // Blank ids are skipped by the copy, so they are no owner either.
    void aListOfOnlyBlankProfileIdsKeepsTheOldRows()
    {
        QTemporaryDir dataDirectory;
        const QString path = QDir(dataDirectory.path()).filePath("catalog.sqlite");
        QVERIFY(seedVersionFourCatalog(path));

        CatalogDatabase catalog(path);
        catalog.migrate({QString()});

        QCOMPARE(schemaVersionOf(catalog), 6);
        QCOMPARE(rowCount(catalog, "watch_progress_v4_unowned"), 2);
    }

    // An id is data: a NUL inside it must not cut the copy statement short.
    void aProfileIdWithANulIsCopiedWhole()
    {
        QTemporaryDir dataDirectory;
        const QString path = QDir(dataDirectory.path()).filePath("catalog.sqlite");
        QVERIFY(seedVersionFourCatalog(path));

        const QString odd = QString::fromUtf8("a\0b", 3);
        QCOMPARE(odd.size(), 3);
        CatalogDatabase catalog(path);
        catalog.migrate({odd, QStringLiteral("a")});

        QCOMPARE(schemaVersionOf(catalog), 6);
        QCOMPARE(rowCount(catalog, "watch_progress"), 4);
        QCOMPARE(progressOf(catalog, odd, "item-1"),
                 (QVariantList{600000, 7200000, 0}));
        QCOMPARE(progressOf(catalog, QStringLiteral("a"), "item-2"),
                 (QVariantList{0, 5400000, 1}));
    }

    void aCatalogWithoutProgressUpgradesWithoutProfiles()
    {
        QTemporaryDir dataDirectory;
        const QString path = QDir(dataDirectory.path()).filePath("catalog.sqlite");
        QVERIFY(seedVersionFourCatalog(path));
        {
            CatalogDatabase seeded(path);
            QVERIFY(execute(seeded, "DELETE FROM watch_progress"));
        }

        CatalogDatabase catalog(path);
        catalog.migrate();

        QCOMPARE(schemaVersionOf(catalog), 6);
        QCOMPARE(rowCount(catalog, "watch_progress"), 0);
    }

    void aFailedProgressMigrationLeavesTheOldCatalogUsable()
    {
        QTemporaryDir dataDirectory;
        const QString path = QDir(dataDirectory.path()).filePath("catalog.sqlite");
        QVERIFY(seedVersionFourCatalog(path));
        {
            // The migration builds watch_progress_v5; a table already holding
            // that name makes it fail after the migration has begun.
            CatalogDatabase seeded(path);
            QVERIFY(execute(seeded, "CREATE TABLE watch_progress_v5 (x INTEGER)"));
        }

        CatalogDatabase catalog(path);
        QVERIFY_EXCEPTION_THROWN(catalog.migrate({QStringLiteral("main")}),
                                 std::runtime_error);

        QCOMPARE(schemaVersionOf(catalog), 4);
        QCOMPARE(rowCount(catalog, "watch_progress"), 2);
        QVERIFY(execute(catalog, "SELECT media_id FROM watch_progress"));

        QVERIFY(execute(catalog, "DROP TABLE watch_progress_v5"));
        catalog.migrate({QStringLiteral("main")});
        QCOMPARE(schemaVersionOf(catalog), 6);
        QCOMPARE(rowCount(catalog, "watch_progress"), 2);
    }

    // The catalog the release before TMDB wrote: schema 5, with titles and
    // per-profile progress. Dropping what migration 6 adds from a migrated
    // catalog gives that exact shape without restating migrations 1 to 5.
    static bool downgradeToVersionFive(CatalogDatabase &catalog)
    {
        return execute(catalog, "DROP TRIGGER media_items_metadata_cleanup")
            && execute(catalog, "DROP TABLE title_cast")
            && execute(catalog, "DROP TABLE title_keyword")
            && execute(catalog, "DROP TABLE title_metadata")
            && execute(catalog, "DROP TABLE episode_metadata")
            && execute(catalog, "PRAGMA user_version = 5");
    }

    void metadataMigrationKeepsTitlesAndWatchProgressOfAVersionFiveCatalog()
    {
        QTemporaryDir dataDirectory;
        const QString path = QDir(dataDirectory.path()).filePath("catalog.sqlite");
        {
            CatalogDatabase seeded(path);
            seeded.migrate({QStringLiteral("main")});
            QVERIFY(execute(seeded, insertMoviesRoot));
            QVERIFY(execute(seeded, insertMediaItem("'item-1'", "'root-1'")));
            QVERIFY(execute(seeded,
                            "INSERT INTO watch_progress (profile_id, media_id, position_ms, "
                            "duration_ms, completed, updated_at) VALUES "
                            "('main', 'item-1', 600000, 7200000, 0, '2026-01-01T00:00:00Z')"));
            QVERIFY(downgradeToVersionFive(seeded));
            QCOMPARE(schemaVersionOf(seeded), 5);
            QVERIFY(!tableNames(seeded).contains("title_metadata"));
        }

        CatalogDatabase catalog(path);
        catalog.migrate({QStringLiteral("main")});

        QCOMPARE(schemaVersionOf(catalog), 6);
        QCOMPARE(rowCount(catalog, "library_roots"), 1);
        QCOMPARE(rowCount(catalog, "media_items"), 1);
        QCOMPARE(progressOf(catalog, "main", "item-1"), (QVariantList{600000, 7200000, 0}));
        const QStringList metadataTables{"title_metadata", "title_cast", "title_keyword",
                                         "episode_metadata"};
        for (const QString &table : metadataTables) {
            QVERIFY2(tableNames(catalog).contains(table), qPrintable(table));
            QCOMPARE(rowCount(catalog, table), 0);
        }
    }

    void metadataMigrationRunsFromTheOldestSchemaToo()
    {
        QTemporaryDir dataDirectory;
        const QString path = QDir(dataDirectory.path()).filePath("catalog.sqlite");
        QVERIFY(seedVersionFourCatalog(path));

        CatalogDatabase catalog(path);
        catalog.migrate({QStringLiteral("main")});

        QCOMPARE(schemaVersionOf(catalog), 6);
        QCOMPARE(rowCount(catalog, "media_items"), 2);
        QCOMPARE(progressOf(catalog, "main", "item-1"), (QVariantList{600000, 7200000, 0}));
        QVERIFY(tableNames(catalog).contains("title_metadata"));
    }

    void aFailedMetadataMigrationLeavesTheVersionFiveCatalogUsable()
    {
        QTemporaryDir dataDirectory;
        const QString path = QDir(dataDirectory.path()).filePath("catalog.sqlite");
        {
            CatalogDatabase seeded(path);
            seeded.migrate({QStringLiteral("main")});
            QVERIFY(execute(seeded, insertMoviesRoot));
            QVERIFY(execute(seeded, insertMediaItem("'item-1'", "'root-1'")));
            QVERIFY(downgradeToVersionFive(seeded));
            // The migration creates title_keyword after title_metadata and
            // title_cast; a table holding that name fails it part-way.
            QVERIFY(execute(seeded, "CREATE TABLE title_keyword (x INTEGER)"));
        }

        CatalogDatabase catalog(path);
        QVERIFY_EXCEPTION_THROWN(catalog.migrate({QStringLiteral("main")}), std::runtime_error);

        QCOMPARE(schemaVersionOf(catalog), 5);
        QCOMPARE(rowCount(catalog, "media_items"), 1);
        // The tables the failed run created before it stopped are rolled back.
        QVERIFY(!tableNames(catalog).contains("title_metadata"));
        QVERIFY(!tableNames(catalog).contains("title_cast"));

        QVERIFY(execute(catalog, "DROP TABLE title_keyword"));
        catalog.migrate({QStringLiteral("main")});
        QCOMPARE(schemaVersionOf(catalog), 6);
        QCOMPARE(rowCount(catalog, "media_items"), 1);
    }

    void deletingAMediaItemTakesItsMovieMetadataAndNothingElse()
    {
        QTemporaryDir dataDirectory;
        CatalogDatabase catalog(QDir(dataDirectory.path()).filePath("catalog.sqlite"));
        catalog.migrate();
        QVERIFY(execute(catalog, insertMoviesRoot));
        QVERIFY(execute(catalog, insertMediaItem("'item-1'", "'root-1'")));
        QVERIFY(execute(catalog, "INSERT INTO title_metadata (owner_key, kind, fetch_state, "
                                 "fetched_at) VALUES ('item-1', 'movie', 'matched', 'x'), "
                                 "('show:Fixture Show|2001', 'show', 'matched', 'x')"));
        QVERIFY(execute(catalog, "INSERT INTO title_cast (owner_key, ordinal, person_id, name, "
                                 "character) VALUES ('item-1', 0, 1, 'Actor', 'Role')"));
        QVERIFY(execute(catalog, "INSERT INTO episode_metadata (media_id, fetched_at) "
                                 "VALUES ('item-1', 'x')"));

        // Removing the movie's media item takes its fetched facts with it, and
        // the cast and episode row behind them; a show is not tied to one file.
        QVERIFY(execute(catalog, "DELETE FROM media_items WHERE id = 'item-1'"));
        QCOMPARE(rowCount(catalog, "title_metadata"), 1);
        QCOMPARE(rowCount(catalog, "title_cast"), 0);
        QCOMPARE(rowCount(catalog, "episode_metadata"), 0);
    }

    void startupWithAnUnreadableProfilesFileStillOpensTheLibrary()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
        AppPaths::ensureDirectories();
        QVERIFY(seedVersionFourCatalog(AppPaths::catalogFile()));

        {
            QFile file(AppPaths::profilesFile());
            QVERIFY(file.open(QIODevice::WriteOnly));
            file.write("{ not json");
        }

        {
            ApplicationController controller;
            QCOMPARE(controller.errorTitle(), QStringLiteral("Profiles"));
            QVERIFY(!controller.profiles()->storageError().isEmpty());
        }

        CatalogDatabase catalog(AppPaths::catalogFile());
        QCOMPARE(schemaVersionOf(catalog), 6);
        QCOMPARE(rowCount(catalog, "media_items"), 2);
        QCOMPARE(rowCount(catalog, "watch_progress_v4_unowned"), 2);
    }

    void startupCopiesStoredProgressToTheProfilesItFinds()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
        AppPaths::ensureDirectories();
        QVERIFY(seedVersionFourCatalog(AppPaths::catalogFile()));

        QStringList profileIds;
        {
            ApplicationController controller;
            QVERIFY2(!controller.hasError(), qPrintable(controller.errorMessage()));
            for (const Profile &profile : controller.profiles()->profiles()) {
                profileIds.push_back(profile.id);
            }
        }

        QCOMPARE(profileIds.size(), 2);
        CatalogDatabase catalog(AppPaths::catalogFile());
        QCOMPARE(schemaVersionOf(catalog), 6);
        for (const QString &profile : profileIds) {
            QCOMPARE(progressOf(catalog, profile, "item-1"),
                     (QVariantList{600000, 7200000, 0}));
        }
    }
};

QTEST_MAIN(CatalogBootstrapTest)
#include "tst_catalog_bootstrap.moc"
