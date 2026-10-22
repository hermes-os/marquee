#include "catalog/CatalogStore.hpp"

#include <QDateTime>
#include <QDir>
#include <QHash>
#include <QSet>
#include <QSqlError>
#include <QSqlQuery>
#include <QUuid>
#include <QVariant>

#include <stdexcept>

#include "support/Logging.hpp"

namespace
{
// The catalog stores timestamps as text, so change detection compares the
// stored string with a freshly formatted one and never reparses to decide.
[[nodiscard]] QString formatTimestamp(const QDateTime &value)
{
    return value.toUTC().toString(Qt::ISODateWithMs);
}

[[nodiscard]] QDateTime parseTimestamp(const QString &value)
{
    return QDateTime::fromString(value, Qt::ISODateWithMs).toUTC();
}

struct ItemFingerprint
{
    QString mediaKind;
    QString title;
    QString sortTitle;
    int year{0};
    QString posterRelativePath;
    qint64 fileSize{0};
    QString modifiedAt;
    QString showName;
    int seasonNumber{0};
    int episodeNumber{0};
    QString episodeTitle;
    QString showPosterRelativePath;
    QString showBackdropRelativePath;
    QString seasonPosterRelativePath;
    QString episodeStillRelativePath;

    bool operator==(const ItemFingerprint &) const = default;
};

[[nodiscard]] ItemFingerprint fingerprintOf(const MediaItem &item)
{
    return {.mediaKind = item.mediaKind,
            .title = item.title,
            .sortTitle = item.sortTitle,
            .year = item.year,
            .posterRelativePath = item.posterRelativePath,
            .fileSize = item.fileSize,
            .modifiedAt = formatTimestamp(item.modifiedAt),
            .showName = item.showName,
            .seasonNumber = item.seasonNumber,
            .episodeNumber = item.episodeNumber,
            .episodeTitle = item.episodeTitle,
            .showPosterRelativePath = item.showPosterRelativePath,
            .showBackdropRelativePath = item.showBackdropRelativePath,
            .seasonPosterRelativePath = item.seasonPosterRelativePath,
            .episodeStillRelativePath = item.episodeStillRelativePath};
}

// Movies store NULL in every episode column (CatalogDatabase.cpp migration 4),
// so an empty string and a missing value read back the same.
[[nodiscard]] QVariant optionalText(const QString &value)
{
    return value.isEmpty() ? QVariant() : QVariant(value);
}

[[nodiscard]] QVariant optionalNumber(int value)
{
    return value > 0 ? QVariant(value) : QVariant();
}

[[nodiscard]] QSqlQuery prepared(QSqlDatabase &database, const QString &sql)
{
    QSqlQuery query(database);
    if (!query.prepare(sql)) {
        throw std::runtime_error(QStringLiteral("Unable to prepare %1: %2")
                                     .arg(sql.simplified(), query.lastError().text())
                                     .toStdString());
    }
    return query;
}

void executeOrThrow(QSqlQuery &query)
{
    if (!query.exec()) {
        throw std::runtime_error(
            QStringLiteral("SQL failed: %1; statement: %2")
                .arg(query.lastError().text(), query.lastQuery().simplified())
                .toStdString());
    }
}

void executeOrThrow(QSqlDatabase &database, const QString &sql)
{
    QSqlQuery query = prepared(database, sql);
    executeOrThrow(query);
}

[[nodiscard]] QStringList configuredPaths(const QStringList &paths)
{
    QStringList configured;
    for (const QString &path : paths) {
        const QString trimmed = path.trimmed();
        if (trimmed.isEmpty()) {
            continue;
        }
        const QString normalized = QDir(trimmed).absolutePath();
        if (!configured.contains(normalized)) {
            configured.push_back(normalized);
        }
    }
    return configured;
}

[[nodiscard]] QString displayNameFor(const QString &path)
{
    const QString name = QDir(path).dirName();
    return name.isEmpty() ? path : name;
}

[[nodiscard]] QHash<QString, LibraryRoot> storedRoots(QSqlDatabase &database)
{
    QSqlQuery query = prepared(
        database,
        QStringLiteral("SELECT id, path, display_name, available FROM library_roots"));
    executeOrThrow(query);

    QHash<QString, LibraryRoot> roots;
    while (query.next()) {
        const QString path = query.value(1).toString();
        roots.insert(path,
                     {.id = query.value(0).toString(),
                      .path = path,
                      .displayName = query.value(2).toString(),
                      .available = query.value(3).toBool()});
    }
    return roots;
}

[[nodiscard]] LibraryRoot createRoot(QSqlDatabase &database, const QString &path)
{
    const LibraryRoot created{
        .id = QUuid::createUuid().toString(QUuid::WithoutBraces),
        .path = path,
        .displayName = displayNameFor(path),
        .available = false};

    QSqlQuery query = prepared(
        database,
        QStringLiteral("INSERT INTO library_roots (id, path, display_name, available) "
                       "VALUES (?, ?, ?, 0)"));
    query.addBindValue(created.id);
    query.addBindValue(created.path);
    query.addBindValue(created.displayName);
    executeOrThrow(query);

    qCInfo(logCatalog) << "registered library root" << created.path;
    return created;
}

[[nodiscard]] QHash<QString, ItemFingerprint> storedFingerprints(QSqlDatabase &database,
                                                                 const QString &rootId)
{
    QSqlQuery query = prepared(
        database,
        QStringLiteral("SELECT id, media_kind, title, sort_title, year, poster_path, "
                       "file_size, modified_at, show_name, season_number, "
                       "episode_number, episode_title, show_poster_path, "
                       "show_backdrop_path, season_poster_path, episode_still_path "
                       "FROM media_items WHERE library_root_id = ?"));
    query.addBindValue(rootId);
    executeOrThrow(query);

    QHash<QString, ItemFingerprint> fingerprints;
    while (query.next()) {
        fingerprints.insert(query.value(0).toString(),
                            {.mediaKind = query.value(1).toString(),
                             .title = query.value(2).toString(),
                             .sortTitle = query.value(3).toString(),
                             .year = query.value(4).toInt(),
                             .posterRelativePath = query.value(5).toString(),
                             .fileSize = query.value(6).toLongLong(),
                             .modifiedAt = query.value(7).toString(),
                             .showName = query.value(8).toString(),
                             .seasonNumber = query.value(9).toInt(),
                             .episodeNumber = query.value(10).toInt(),
                             .episodeTitle = query.value(11).toString(),
                             .showPosterRelativePath = query.value(12).toString(),
                             .showBackdropRelativePath = query.value(13).toString(),
                             .seasonPosterRelativePath = query.value(14).toString(),
                             .episodeStillRelativePath = query.value(15).toString()});
    }
    return fingerprints;
}

// Every NOT NULL media_items column. A null QString or an invalid QDateTime
// binds NULL, which would fail the insert and roll back the whole root.
[[nodiscard]] bool hasRequiredColumns(const MediaItem &item)
{
    return !item.id.isEmpty() && !item.libraryRootId.isEmpty()
        && !item.relativePath.isEmpty() && !item.mediaKind.isEmpty()
        && !item.title.isNull() && !item.sortTitle.isNull() && item.fileSize >= 0
        && item.modifiedAt.isValid();
}

void insertItem(QSqlDatabase &database, const MediaItem &item, const QString &now)
{
    QSqlQuery query = prepared(
        database,
        QStringLiteral("INSERT INTO media_items (id, library_root_id, relative_path, "
                       "media_kind, title, sort_title, year, poster_path, file_size, "
                       "modified_at, discovered_at, updated_at, show_name, "
                       "season_number, episode_number, episode_title, "
                       "show_poster_path, show_backdrop_path, season_poster_path, "
                       "episode_still_path) "
                       "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, "
                       "?, ?, ?, ?, ?, ?, ?, ?)"));
    query.addBindValue(item.id);
    query.addBindValue(item.libraryRootId);
    query.addBindValue(item.relativePath);
    query.addBindValue(item.mediaKind);
    query.addBindValue(item.title);
    query.addBindValue(item.sortTitle);
    query.addBindValue(item.year);
    query.addBindValue(item.posterRelativePath);
    query.addBindValue(item.fileSize);
    query.addBindValue(formatTimestamp(item.modifiedAt));
    query.addBindValue(now);
    query.addBindValue(now);
    query.addBindValue(optionalText(item.showName));
    query.addBindValue(optionalNumber(item.seasonNumber));
    query.addBindValue(optionalNumber(item.episodeNumber));
    query.addBindValue(optionalText(item.episodeTitle));
    query.addBindValue(optionalText(item.showPosterRelativePath));
    query.addBindValue(optionalText(item.showBackdropRelativePath));
    query.addBindValue(optionalText(item.seasonPosterRelativePath));
    query.addBindValue(optionalText(item.episodeStillRelativePath));
    executeOrThrow(query);
}

void updateItem(QSqlDatabase &database, const MediaItem &item, const QString &now)
{
    QSqlQuery query = prepared(
        database,
        QStringLiteral("UPDATE media_items SET media_kind = ?, title = ?, "
                       "sort_title = ?, year = ?, poster_path = ?, file_size = ?, "
                       "modified_at = ?, updated_at = ?, show_name = ?, "
                       "season_number = ?, episode_number = ?, episode_title = ?, "
                       "show_poster_path = ?, show_backdrop_path = ?, "
                       "season_poster_path = ?, episode_still_path = ? "
                       "WHERE id = ?"));
    query.addBindValue(item.mediaKind);
    query.addBindValue(item.title);
    query.addBindValue(item.sortTitle);
    query.addBindValue(item.year);
    query.addBindValue(item.posterRelativePath);
    query.addBindValue(item.fileSize);
    query.addBindValue(formatTimestamp(item.modifiedAt));
    query.addBindValue(now);
    query.addBindValue(optionalText(item.showName));
    query.addBindValue(optionalNumber(item.seasonNumber));
    query.addBindValue(optionalNumber(item.episodeNumber));
    query.addBindValue(optionalText(item.episodeTitle));
    query.addBindValue(optionalText(item.showPosterRelativePath));
    query.addBindValue(optionalText(item.showBackdropRelativePath));
    query.addBindValue(optionalText(item.seasonPosterRelativePath));
    query.addBindValue(optionalText(item.episodeStillRelativePath));
    query.addBindValue(item.id);
    executeOrThrow(query);
}

void deleteItem(QSqlDatabase &database, const QString &id)
{
    QSqlQuery query =
        prepared(database, QStringLiteral("DELETE FROM media_items WHERE id = ?"));
    query.addBindValue(id);
    executeOrThrow(query);
}
}

CatalogStore::CatalogStore(const QString &catalogPath)
    : m_database(catalogPath)
{
}

QVector<LibraryRoot> CatalogStore::registerRoots(const QStringList &paths)
{
    return registerRoots(LibraryRootPaths{.movies = paths, .tvShows = {}});
}

QVector<LibraryRoot> CatalogStore::registerRoots(const LibraryRootPaths &paths)
{
    QSqlDatabase &database = m_database.connection();
    const QHash<QString, LibraryRoot> stored = storedRoots(database);

    // LibraryState.swift:301-314: a folder listed under both roles is TV,
    // because the usual overlap is a movies root with a TV folder inside it,
    // so the TV list is registered first and the movies list skips its paths.
    QVector<LibraryRoot> roots;
    QSet<QString> registered;
    const auto registerUnder = [&](const QStringList &list, LibraryRoot::Role role) {
        for (const QString &path : configuredPaths(list)) {
            if (registered.contains(path)) {
                continue;
            }
            registered.insert(path);
            const auto existing = stored.constFind(path);
            LibraryRoot root = existing != stored.constEnd() ? *existing
                                                             : createRoot(database, path);
            // The role follows the settings list, not the stored row: a folder
            // moved from one list to the other is rescanned under its new role
            // and its rows are rewritten by the diff.
            root.role = role;
            roots.push_back(root);
        }
    };
    registerUnder(paths.tvShows, LibraryRoot::Role::TvShows);
    registerUnder(paths.movies, LibraryRoot::Role::Movies);

    m_knownRoots = roots;
    return m_knownRoots;
}

void CatalogStore::applyScan(const LibraryRoot &root,
                             const LibraryScanner::ScanResult &result)
{
    switch (result.outcome) {
    case LibraryScanner::ScanOutcome::RootUnavailable:
        markRootUnavailable(root);
        qCWarning(logCatalog) << "kept stored rows for unavailable root" << root.path;
        return;
    case LibraryScanner::ScanOutcome::Incomplete:
        // A walk that could not read part of the root says nothing about what
        // the unread part still holds, so what it did read is stored but no
        // row is removed on the strength of a partial picture.
        qCWarning(logCatalog) << "kept stored rows for partially readable root"
                              << root.path;
        applyAvailableScan(root, result.items, result.unreadableIds, false);
        return;
    case LibraryScanner::ScanOutcome::Complete:
        applyAvailableScan(root, result.items, result.unreadableIds, true);
        return;
    }
}

QVector<MediaItem> CatalogStore::projection(const QVector<LibraryRoot> &roots,
                                            const QString &profileId)
{
    if (roots.isEmpty()) {
        return {};
    }

    QHash<QString, QString> rootPaths;
    QStringList placeholders;
    for (const LibraryRoot &root : roots) {
        rootPaths.insert(root.id, root.path);
        placeholders.push_back(QStringLiteral("?"));
    }

    QSqlQuery query = prepared(
        m_database.connection(),
        QStringLiteral("SELECT m.id, m.library_root_id, m.relative_path, m.media_kind, "
                       "m.title, m.sort_title, m.year, m.poster_path, m.file_size, "
                       "m.modified_at, COALESCE(w.position_ms, 0), "
                       "COALESCE(w.duration_ms, 0), COALESCE(w.completed, 0), "
                       "m.show_name, m.season_number, m.episode_number, "
                       "m.episode_title, m.show_poster_path, m.show_backdrop_path, "
                       "m.season_poster_path, m.episode_still_path, w.updated_at "
                       "FROM media_items m "
                       "LEFT JOIN watch_progress w ON w.media_id = m.id "
                       "AND w.profile_id = ? "
                       "WHERE m.library_root_id IN (%1) ORDER BY m.sort_title, m.id")
            .arg(placeholders.join(QStringLiteral(", "))));
    // An empty profile id matches no row: a session with no profile has no
    // progress to show.
    query.addBindValue(profileId);
    for (const LibraryRoot &root : roots) {
        query.addBindValue(root.id);
    }
    executeOrThrow(query);

    QVector<MediaItem> items;
    while (query.next()) {
        const QString rootId = query.value(1).toString();
        const QString relativePath = query.value(2).toString();
        const QDir rootDirectory(rootPaths.value(rootId));
        const QString posterRelativePath = query.value(7).toString();
        const auto absoluteOrEmpty = [&rootDirectory](const QString &relative) {
            return relative.isEmpty() ? QString() : rootDirectory.filePath(relative);
        };
        const QString showPosterRelativePath = query.value(17).toString();
        const QString showBackdropRelativePath = query.value(18).toString();
        const QString seasonPosterRelativePath = query.value(19).toString();
        const QString episodeStillRelativePath = query.value(20).toString();
        items.push_back(MediaItem{
            .id = query.value(0).toString(),
            .libraryRootId = rootId,
            .relativePath = relativePath,
            // Absolute paths are composed on read, so a root that moves does not
            // have to rewrite every row it owns.
            .absolutePath = rootDirectory.filePath(relativePath),
            .title = query.value(4).toString(),
            .sortTitle = query.value(5).toString(),
            .mediaKind = query.value(3).toString(),
            .year = query.value(6).toInt(),
            // CatalogDatabase.cpp:128-137 stores the player's duration in
            // milliseconds; MediaItem.swift:143-151 formats whole seconds.
            .durationSeconds = query.value(11).toLongLong() / 1000,
            .posterRelativePath = posterRelativePath,
            .posterAbsolutePath = posterRelativePath.isEmpty()
                ? QString()
                : rootDirectory.filePath(posterRelativePath),
            .fileSize = query.value(8).toLongLong(),
            .modifiedAt = parseTimestamp(query.value(9).toString()),
            .resumePositionMs = query.value(10).toLongLong(),
            .watched = query.value(12).toBool(),
            .showName = query.value(13).toString(),
            .seasonNumber = query.value(14).toInt(),
            .episodeNumber = query.value(15).toInt(),
            .episodeTitle = query.value(16).toString(),
            .showPosterRelativePath = showPosterRelativePath,
            .showPosterAbsolutePath = absoluteOrEmpty(showPosterRelativePath),
            .showBackdropRelativePath = showBackdropRelativePath,
            .showBackdropAbsolutePath = absoluteOrEmpty(showBackdropRelativePath),
            .seasonPosterRelativePath = seasonPosterRelativePath,
            .seasonPosterAbsolutePath = absoluteOrEmpty(seasonPosterRelativePath),
            .episodeStillRelativePath = episodeStillRelativePath,
            .episodeStillAbsolutePath = absoluteOrEmpty(episodeStillRelativePath),
            // A title this profile never played has no progress row, so the
            // join yields NULL and the time stays invalid.
            .lastPlayedAt = query.value(21).isNull()
                ? QDateTime()
                : parseTimestamp(query.value(21).toString())});
    }

    return items;
}

void CatalogStore::recordWatchProgress(const QString &profileId,
                                       const QString &mediaId,
                                       qint64 positionMs,
                                       qint64 durationMs,
                                       bool completed)
{
    // Progress belongs to a profile (WatchProgressStore.swift:29-39), and the
    // released app saves nothing while it has no store (PlayerController.swift
    // :206). A row with no owner could never be read back.
    if (profileId.isEmpty()) {
        throw std::runtime_error("No profile is chosen, so watch progress was not saved");
    }

    QSqlQuery query = prepared(
        m_database.connection(),
        QStringLiteral("INSERT INTO watch_progress "
                       "(profile_id, media_id, position_ms, duration_ms, completed, "
                       "updated_at) "
                       "VALUES (?, ?, ?, ?, ?, ?) "
                       "ON CONFLICT(profile_id, media_id) DO UPDATE SET "
                       "position_ms = excluded.position_ms, "
                       "duration_ms = excluded.duration_ms, "
                       "completed = excluded.completed, "
                       "updated_at = excluded.updated_at"));
    query.addBindValue(profileId);
    query.addBindValue(mediaId);
    query.addBindValue(positionMs);
    query.addBindValue(durationMs);
    query.addBindValue(completed ? 1 : 0);
    query.addBindValue(formatTimestamp(QDateTime::currentDateTimeUtc()));
    executeOrThrow(query);
}

void CatalogStore::clearWatchProgress(const QString &profileId)
{
    QSqlQuery query = prepared(
        m_database.connection(),
        QStringLiteral("DELETE FROM watch_progress WHERE profile_id = ?"));
    query.addBindValue(profileId);
    executeOrThrow(query);
}

QVector<LibraryRoot> CatalogStore::knownRoots() const
{
    return m_knownRoots;
}

void CatalogStore::applyAvailableScan(const LibraryRoot &root,
                                      const QVector<MediaItem> &items,
                                      const QSet<QString> &unreadableIds, bool removeMissing)
{
    QSqlDatabase &database = m_database.connection();
    const QString now = formatTimestamp(QDateTime::currentDateTimeUtc());

    executeOrThrow(database, QStringLiteral("BEGIN IMMEDIATE"));

    try {
        const QHash<QString, ItemFingerprint> stored =
            storedFingerprints(database, root.id);
        // A file the listing named but stat refused still exists, so its row
        // is not "missing" below.
        QSet<QString> scanned = unreadableIds;

        for (const MediaItem &item : items) {
            // Counted as scanned even when dropped below, so a bad item never
            // costs the row it already has.
            scanned.insert(item.id);
            if (!hasRequiredColumns(item)) {
                qCWarning(logCatalog) << "dropped media item with a missing required value:"
                                      << item.absolutePath;
                continue;
            }
            const auto existing = stored.constFind(item.id);
            if (existing == stored.constEnd()) {
                insertItem(database, item, now);
            } else if (*existing != fingerprintOf(item)) {
                updateItem(database, item, now);
            }
        }

        if (removeMissing) {
            const QList<QString> storedIds = stored.keys();
            for (const QString &id : storedIds) {
                if (!scanned.contains(id)) {
                    deleteItem(database, id);
                }
            }
        }

        QSqlQuery touch = prepared(
            database,
            QStringLiteral("UPDATE library_roots SET available = 1, last_scan_at = ? "
                           "WHERE id = ?"));
        touch.addBindValue(now);
        touch.addBindValue(root.id);
        executeOrThrow(touch);

        executeOrThrow(database, QStringLiteral("COMMIT"));
    } catch (...) {
        QSqlQuery rollback(database);
        if (!rollback.exec(QStringLiteral("ROLLBACK"))) {
            qCWarning(logCatalog) << "catalog rollback failed:"
                                  << rollback.lastError().text();
        }
        throw;
    }
}

void CatalogStore::markRootUnavailable(const LibraryRoot &root)
{
    QSqlQuery query = prepared(
        m_database.connection(),
        QStringLiteral("UPDATE library_roots SET available = 0 WHERE id = ?"));
    query.addBindValue(root.id);
    executeOrThrow(query);
}
