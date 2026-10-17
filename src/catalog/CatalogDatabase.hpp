#pragma once

#include <QSqlDatabase>
#include <QString>
#include <QStringList>
#include <QVariantList>

/// Owns one SQLite connection to the catalog file and brings its schema
/// forward. A `QSqlDatabase` belongs to the thread that opened it, so every
/// thread that touches the catalog constructs its own instance instead of
/// sharing this one.
class CatalogDatabase final
{
public:
    /// Opens `databasePath`, creating the file when it does not exist. Opening
    /// an existing catalog leaves its contents and journal mode alone.
    /// Throws `std::runtime_error` when the file cannot be opened.
    explicit CatalogDatabase(const QString &databasePath);
    ~CatalogDatabase();

    CatalogDatabase(const CatalogDatabase &) = delete;
    CatalogDatabase &operator=(const CatalogDatabase &) = delete;
    CatalogDatabase(CatalogDatabase &&) = delete;
    CatalogDatabase &operator=(CatalogDatabase &&) = delete;

    [[nodiscard]] QSqlDatabase &connection();

    /// Applies the outstanding forward-only migrations, one write-locked
    /// transaction each, then tries to switch the catalog to WAL now that its
    /// schema is current. Concurrent bootstraps serialize on that lock.
    /// Enabling WAL is best effort: another connection holding the catalog
    /// blocks the journal-mode change, which is logged and leaves the file in
    /// its previous mode rather than failing the migration. Throws
    /// `std::runtime_error` and leaves the stored catalog untouched when a
    /// migration fails or the file was written by a newer schema.
    ///
    /// `profileIds` names the profiles that exist now. Migration 5 gives each
    /// of them a copy of the watch progress stored before profiles had their
    /// own. When the list is empty the stored progress has no owner: it is kept
    /// apart in `watch_progress_v4_unowned` (nothing is deleted) and the
    /// per-profile table starts empty, so an unreadable profile list never
    /// blocks the library.
    void migrate(const QStringList &profileIds = {});

private:
    void executeOrThrow(const QString &sql, const QVariantList &bindings = {});
    [[nodiscard]] bool hasStoredWatchProgress();
    [[nodiscard]] int readSchemaVersion();
    [[nodiscard]] int requireSupportedSchemaVersion(int latestVersion);
    void rollbackAfterFailure();
    void enableWriteAheadLogging();
    void closeConnection();

    QString m_connectionName;
    QSqlDatabase m_database;
};
