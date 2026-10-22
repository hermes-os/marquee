#include "catalog/CatalogDatabase.hpp"

#include <QList>
#include <QSqlError>
#include <QSqlQuery>
#include <QStringList>
#include <QUuid>
#include <QVariant>

#include <algorithm>
#include <functional>
#include <stdexcept>

#include "support/Logging.hpp"

namespace
{
struct Statement
{
    QString sql;
    QVariantList bindings{};
};

struct Migration
{
    int version;
    QStringList statements;
    // A migration whose statements depend on the profiles that exist builds
    // them here instead; `statements` is then empty. `unownedRows` is true when
    // the stored watch progress has no profile to go to.
    std::function<QList<Statement>(const QStringList &profileIds, bool unownedRows)>
        build{};
    // The migration copies rows to every profile, so it must know whether the
    // stored rows have a profile to go to.
    bool copiesStoredRowsToProfiles{false};
};

// Migration 5. Every pre-5 row belongs to no profile, so each profile receives
// its own copy; a profile created later starts empty, as
// WatchProgressStore.swift:49-62 starts a profile with no files.
//
// Profiles live in profiles.json, not in the catalog, so the ids reach the
// migration as text and are bound, never spliced into SQL: an id is data and
// may hold a quote or a NUL.
//
// With no profile list the rows have no owner. They are set aside under another
// name instead of dropped or copied to profiles that may not persist, so the
// library still opens and nothing is deleted.
[[nodiscard]] QList<Statement> profileWatchProgressStatements(
    const QStringList &profileIds, bool unownedRows)
{
    QList<Statement> statements;
    if (unownedRows) {
        statements.push_back(
            {QStringLiteral("ALTER TABLE watch_progress "
                            "RENAME TO watch_progress_v4_unowned")});
        statements.push_back({QStringLiteral(R"SQL(
        CREATE TABLE watch_progress (
            profile_id TEXT NOT NULL,
            media_id TEXT NOT NULL,
            position_ms INTEGER NOT NULL DEFAULT 0,
            duration_ms INTEGER NOT NULL DEFAULT 0,
            completed INTEGER NOT NULL DEFAULT 0,
            updated_at TEXT NOT NULL,
            PRIMARY KEY (profile_id, media_id),
            FOREIGN KEY (media_id)
                REFERENCES media_items(id)
                ON DELETE CASCADE
        )
    )SQL")});
    } else {
        statements.push_back({QStringLiteral(R"SQL(
        CREATE TABLE watch_progress_v5 (
            profile_id TEXT NOT NULL,
            media_id TEXT NOT NULL,
            position_ms INTEGER NOT NULL DEFAULT 0,
            duration_ms INTEGER NOT NULL DEFAULT 0,
            completed INTEGER NOT NULL DEFAULT 0,
            updated_at TEXT NOT NULL,
            PRIMARY KEY (profile_id, media_id),
            FOREIGN KEY (media_id)
                REFERENCES media_items(id)
                ON DELETE CASCADE
        )
    )SQL")});

        QStringList copied;
        for (const QString &profileId : profileIds) {
            if (profileId.isEmpty() || copied.contains(profileId)) {
                continue;
            }
            copied.push_back(profileId);
            statements.push_back(
                {QStringLiteral("INSERT INTO watch_progress_v5 "
                                "(profile_id, media_id, position_ms, duration_ms, "
                                "completed, updated_at) "
                                "SELECT ?, media_id, position_ms, duration_ms, "
                                "completed, updated_at FROM watch_progress"),
                 {profileId}});
        }

        statements.push_back({QStringLiteral("DROP TABLE watch_progress")});
        statements.push_back(
            {QStringLiteral("ALTER TABLE watch_progress_v5 RENAME TO watch_progress")});
    }

    statements.push_back({QStringLiteral(
        "CREATE INDEX watch_progress_media_idx ON watch_progress(media_id)")});
    return statements;
}

[[nodiscard]] QList<Migration> catalogMigrations()
{
    return {
        {1,
         {QStringLiteral(R"SQL(
            CREATE TABLE library_roots (
                id TEXT PRIMARY KEY NOT NULL,
                path TEXT NOT NULL UNIQUE,
                display_name TEXT NOT NULL,
                available INTEGER NOT NULL DEFAULT 1,
                last_scan_at TEXT
            )
         )SQL"),
          QStringLiteral(R"SQL(
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
                FOREIGN KEY (library_root_id)
                    REFERENCES library_roots(id)
                    ON DELETE CASCADE,
                UNIQUE (library_root_id, relative_path)
            )
         )SQL"),
          QStringLiteral(
              "CREATE INDEX media_items_sort_title_idx ON media_items(sort_title)"),
          QStringLiteral(
              "CREATE INDEX media_items_root_idx ON media_items(library_root_id)")}},
        {2,
         // SQLite cannot add NOT NULL to an existing column, so version 1
         // catalogs rebuild both tables. The old parent is dropped only after
         // the old child, because dropping a parent that still has children
         // cascades its implicit DELETE FROM into them; the rebuilt child
         // therefore references library_roots_v2 until the final rename
         // repoints it, which SQLite only does while foreign_keys is ON.
         {QStringLiteral(R"SQL(
            CREATE TABLE library_roots_v2 (
                id TEXT PRIMARY KEY NOT NULL,
                path TEXT NOT NULL UNIQUE,
                display_name TEXT NOT NULL,
                available INTEGER NOT NULL DEFAULT 1,
                last_scan_at TEXT
            )
         )SQL"),
          QStringLiteral(R"SQL(
            INSERT INTO library_roots_v2
                (id, path, display_name, available, last_scan_at)
            SELECT id, path, display_name, available, last_scan_at
            FROM library_roots
         )SQL"),
          QStringLiteral(R"SQL(
            CREATE TABLE media_items_v2 (
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
                FOREIGN KEY (library_root_id)
                    REFERENCES library_roots_v2(id)
                    ON DELETE CASCADE,
                UNIQUE (library_root_id, relative_path)
            )
         )SQL"),
          QStringLiteral(R"SQL(
            INSERT INTO media_items_v2
                (id, library_root_id, relative_path, media_kind, title,
                 sort_title, year, poster_path, backdrop_path, file_size,
                 modified_at, discovered_at, updated_at)
            SELECT id, library_root_id, relative_path, media_kind, title,
                   sort_title, year, poster_path, backdrop_path, file_size,
                   modified_at, discovered_at, updated_at
            FROM media_items
         )SQL"),
          QStringLiteral("DROP TABLE media_items"),
          QStringLiteral("DROP TABLE library_roots"),
          QStringLiteral("ALTER TABLE library_roots_v2 RENAME TO library_roots"),
          QStringLiteral("ALTER TABLE media_items_v2 RENAME TO media_items"),
          QStringLiteral(
              "CREATE INDEX media_items_sort_title_idx ON media_items(sort_title)"),
          QStringLiteral(
              "CREATE INDEX media_items_root_idx ON media_items(library_root_id)")}},
        {3,
         // Watch progress belongs to the title, not yet to a viewer: profiles
         // are a later milestone, and keying these rows on a profile the
         // application cannot name would invent an identity that milestone has
         // to reconcile. The profile column arrives with the profiles that
         // populate it.
         {QStringLiteral(R"SQL(
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
         )SQL")}},
        {4,
         // MediaItem.swift:27-43: an episode is a media item with its show,
         // season, and episode facts, and the show- and season-level artwork
         // found above it. Movies leave every one of these NULL, which is what
         // the projection reads as "not an episode".
         //
         // The index stays single-column on show_name: every read of these
         // columns today is the whole-projection SELECT in CatalogStore,
         // filtered by library_root_id and sorted in memory by ShowsModel, so
         // no query filters or orders by (show_name, season, episode) and a
         // composite index would index nothing a query asks for. Revisit if a
         // lookup by that triple ever reaches SQL.
         {QStringLiteral("ALTER TABLE media_items ADD COLUMN show_name TEXT"),
          QStringLiteral("ALTER TABLE media_items ADD COLUMN season_number INTEGER"),
          QStringLiteral("ALTER TABLE media_items ADD COLUMN episode_number INTEGER"),
          QStringLiteral("ALTER TABLE media_items ADD COLUMN episode_title TEXT"),
          QStringLiteral("ALTER TABLE media_items ADD COLUMN show_poster_path TEXT"),
          QStringLiteral("ALTER TABLE media_items ADD COLUMN show_backdrop_path TEXT"),
          QStringLiteral("ALTER TABLE media_items ADD COLUMN season_poster_path TEXT"),
          QStringLiteral("ALTER TABLE media_items ADD COLUMN episode_still_path TEXT"),
          QStringLiteral(
              "CREATE INDEX media_items_show_idx ON media_items(show_name)")}},
        {5,
         // SQLite cannot add a column to a primary key, so the table is
         // rebuilt. The media_id index serves the cascade from media_items,
         // which the (profile_id, media_id) key cannot.
         {},
         profileWatchProgressStatements,
         true},
        {6,
         // TMDB enrichment (TMDBEnrichmentService.swift). A movie is keyed by
         // its media item id and a show by `show:<name>|<year>`, because the
         // catalog stores episodes and a show exists only as the name they
         // share. Only a movie row is tied to media_items, by the trigger: a
         // show's metadata outlives its episodes, so an unplugged or
         // rescanned drive never costs a refetch (and a missing root never
         // deletes rows). Episodes cascade with their media item.
         //
         // fetch_state is matched, unmatched or failed; fetched_at is the last
         // attempt. Image columns hold TMDB's own path (`/abc.jpg`) and where
         // the cached thumbnail landed, so a failed download is retried
         // without asking TMDB about the title again.
         {QStringLiteral(R"SQL(
            CREATE TABLE title_metadata (
                owner_key TEXT PRIMARY KEY NOT NULL,
                kind TEXT NOT NULL,
                fetch_state TEXT NOT NULL,
                fetched_at TEXT NOT NULL,
                tmdb_id INTEGER,
                overview TEXT,
                genres TEXT NOT NULL DEFAULT '[]',
                director TEXT,
                certification TEXT,
                vote_average REAL,
                vote_count INTEGER,
                popularity REAL,
                collection_id INTEGER,
                collection_name TEXT,
                similar_tmdb_ids TEXT NOT NULL DEFAULT '[]',
                recommended_tmdb_ids TEXT NOT NULL DEFAULT '[]',
                release_date TEXT,
                runtime_minutes INTEGER,
                poster_remote_path TEXT,
                backdrop_remote_path TEXT,
                poster_cache_path TEXT,
                backdrop_cache_path TEXT
            )
         )SQL"),
          QStringLiteral(R"SQL(
            CREATE TABLE title_cast (
                owner_key TEXT NOT NULL,
                ordinal INTEGER NOT NULL,
                person_id INTEGER NOT NULL,
                name TEXT NOT NULL,
                profile_path TEXT,
                character TEXT NOT NULL,
                PRIMARY KEY (owner_key, ordinal),
                FOREIGN KEY (owner_key)
                    REFERENCES title_metadata(owner_key)
                    ON DELETE CASCADE
            )
         )SQL"),
          QStringLiteral(R"SQL(
            CREATE TABLE title_keyword (
                owner_key TEXT NOT NULL,
                keyword_id INTEGER NOT NULL,
                name TEXT NOT NULL,
                PRIMARY KEY (owner_key, keyword_id),
                FOREIGN KEY (owner_key)
                    REFERENCES title_metadata(owner_key)
                    ON DELETE CASCADE
            )
         )SQL"),
          QStringLiteral(R"SQL(
            CREATE TABLE episode_metadata (
                media_id TEXT PRIMARY KEY NOT NULL,
                fetched_at TEXT NOT NULL,
                tmdb_episode_id INTEGER,
                title TEXT,
                overview TEXT,
                air_date TEXT,
                vote_average REAL,
                still_remote_path TEXT,
                still_cache_path TEXT,
                FOREIGN KEY (media_id)
                    REFERENCES media_items(id)
                    ON DELETE CASCADE
            )
         )SQL"),
          QStringLiteral(R"SQL(
            CREATE TRIGGER media_items_metadata_cleanup
            AFTER DELETE ON media_items
            BEGIN
                DELETE FROM title_metadata WHERE owner_key = old.id;
            END
         )SQL")}}
    };
}
}

CatalogDatabase::CatalogDatabase(const QString &databasePath)
    : m_connectionName(
          QStringLiteral("marquee-catalog-%1")
              .arg(QUuid::createUuid().toString(QUuid::WithoutBraces))),
      m_database(QSqlDatabase::addDatabase(
          QStringLiteral("QSQLITE"), m_connectionName))
{
    m_database.setDatabaseName(databasePath);

    try {
        if (!m_database.open()) {
            throw std::runtime_error(
                QStringLiteral("Unable to open catalog %1: %2")
                    .arg(databasePath, m_database.lastError().text())
                    .toStdString());
        }

        // The lock wait must be in place before anything takes a lock, and
        // journal mode is a persistent change to the file, so WAL waits until
        // migrate() has accepted the catalog.
        executeOrThrow(QStringLiteral("PRAGMA busy_timeout = 5000"));
        executeOrThrow(QStringLiteral("PRAGMA foreign_keys = ON"));
    } catch (...) {
        closeConnection();
        throw;
    }
}

CatalogDatabase::~CatalogDatabase()
{
    closeConnection();
}

QSqlDatabase &CatalogDatabase::connection()
{
    return m_database;
}

void CatalogDatabase::migrate(const QStringList &profileIds)
{
    const QList<Migration> migrations = catalogMigrations();
    const int latestVersion = migrations.constLast().version;

    for (const Migration &migration : migrations) {
        if (requireSupportedSchemaVersion(latestVersion) >= migration.version) {
            continue;
        }

        // The write lock spans the version re-read and the statements, so a
        // bootstrap racing another process waits here and then finds the
        // migration already applied instead of repeating it.
        executeOrThrow(QStringLiteral("BEGIN IMMEDIATE"));

        try {
            if (requireSupportedSchemaVersion(latestVersion) >= migration.version) {
                executeOrThrow(QStringLiteral("ROLLBACK"));
                continue;
            }

            QList<Statement> statements;
            if (migration.build) {
                // Blank ids are skipped by the copy, so a list of only those
                // would drop the rows just as an empty list would.
                const bool hasProfile = std::any_of(
                    profileIds.cbegin(), profileIds.cend(),
                    [](const QString &id) { return !id.isEmpty(); });
                const bool unownedRows = migration.copiesStoredRowsToProfiles
                    && !hasProfile && hasStoredWatchProgress();
                if (unownedRows) {
                    qCWarning(logCatalog)
                        << "no profile list: stored watch progress kept apart "
                           "in watch_progress_v4_unowned";
                }
                statements = migration.build(profileIds, unownedRows);
            } else {
                for (const QString &sql : migration.statements) {
                    statements.push_back({sql});
                }
            }
            for (const Statement &statement : statements) {
                executeOrThrow(statement.sql, statement.bindings);
            }
            executeOrThrow(QStringLiteral("PRAGMA user_version = %1")
                               .arg(migration.version));
            executeOrThrow(QStringLiteral("COMMIT"));
        } catch (...) {
            rollbackAfterFailure();
            throw;
        }

        qCInfo(logCatalog) << "applied catalog migration" << migration.version;
    }

    enableWriteAheadLogging();
}

void CatalogDatabase::executeOrThrow(const QString &sql, const QVariantList &bindings)
{
    QSqlQuery query(m_database);
    bool executed = false;
    if (bindings.isEmpty()) {
        executed = query.exec(sql);
    } else {
        executed = query.prepare(sql);
        for (const QVariant &binding : bindings) {
            query.addBindValue(binding);
        }
        executed = executed && query.exec();
    }
    if (!executed) {
        throw std::runtime_error(
            QStringLiteral("SQL failed: %1; statement: %2")
                .arg(query.lastError().text(), sql.simplified())
                .toStdString());
    }
}

bool CatalogDatabase::hasStoredWatchProgress()
{
    QSqlQuery query(m_database);
    if (!query.exec(QStringLiteral("SELECT 1 FROM watch_progress LIMIT 1"))) {
        throw std::runtime_error(
            QStringLiteral("Unable to read stored watch progress: %1")
                .arg(query.lastError().text())
                .toStdString());
    }
    return query.next();
}

int CatalogDatabase::requireSupportedSchemaVersion(int latestVersion)
{
    const int version = readSchemaVersion();
    if (version > latestVersion) {
        throw std::runtime_error(
            QStringLiteral("Catalog schema %1 is newer than this build's %2")
                .arg(version)
                .arg(latestVersion)
                .toStdString());
    }
    return version;
}

void CatalogDatabase::rollbackAfterFailure()
{
    QSqlQuery query(m_database);
    if (!query.exec(QStringLiteral("ROLLBACK"))) {
        qCWarning(logCatalog) << "catalog rollback failed:"
                              << query.lastError().text();
    }
}

void CatalogDatabase::enableWriteAheadLogging()
{
    QSqlQuery query(m_database);
    if (!query.exec(QStringLiteral("PRAGMA journal_mode = WAL")) || !query.next()) {
        qCWarning(logCatalog) << "catalog stayed out of WAL:"
                              << query.lastError().text();
        return;
    }

    // Another connection holding the catalog blocks the mode change. The
    // previous journal mode is still durable, so record it and carry on.
    const QString mode = query.value(0).toString();
    if (mode.compare(QStringLiteral("wal"), Qt::CaseInsensitive) != 0) {
        qCWarning(logCatalog) << "catalog stayed in journal mode" << mode;
    }
}

int CatalogDatabase::readSchemaVersion()
{
    QSqlQuery query(m_database);
    if (!query.exec(QStringLiteral("PRAGMA user_version")) || !query.next()) {
        throw std::runtime_error(
            QStringLiteral("Unable to read catalog schema version: %1")
                .arg(query.lastError().text())
                .toStdString());
    }
    return query.value(0).toInt();
}

void CatalogDatabase::closeConnection()
{
    if (m_database.isValid()) {
        m_database.close();
    }

    // Drop this handle before removing the named connection, or Qt reports the
    // connection as still in use and keeps it alive.
    m_database = QSqlDatabase{};
    QSqlDatabase::removeDatabase(m_connectionName);
}
