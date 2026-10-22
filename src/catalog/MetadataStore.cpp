#include "catalog/MetadataStore.hpp"

#include <QDir>
#include <QFileInfo>
#include <QHash>
#include <QJsonArray>
#include <QJsonDocument>
#include <QSqlError>
#include <QSqlQuery>
#include <QVariant>

#include <map>
#include <memory>
#include <stdexcept>

#include "support/Logging.hpp"

namespace
{
[[nodiscard]] QString formatTimestamp(const QDateTime &value)
{
    return value.toUTC().toString(Qt::ISODateWithMs);
}

[[nodiscard]] QDateTime parseTimestamp(const QString &value)
{
    return QDateTime::fromString(value, Qt::ISODateWithMs).toUTC();
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

// Optional values bind NULL, so "TMDB gave none" and "never fetched" stay
// different from zero and the empty string.
[[nodiscard]] QVariant optionalText(const QString &value)
{
    return value.isEmpty() ? QVariant() : QVariant(value);
}

template<typename T>
[[nodiscard]] QVariant optionalValue(const std::optional<T> &value)
{
    return value ? QVariant::fromValue(*value) : QVariant();
}

[[nodiscard]] QString encodeStrings(const QStringList &values)
{
    return QString::fromUtf8(QJsonDocument(QJsonArray::fromStringList(values))
                                 .toJson(QJsonDocument::Compact));
}

[[nodiscard]] QStringList decodeStrings(const QString &json)
{
    QStringList values;
    for (const QJsonValue &value : QJsonDocument::fromJson(json.toUtf8()).array()) {
        values.push_back(value.toString());
    }
    return values;
}

[[nodiscard]] QString encodeIds(const QVector<int> &ids)
{
    QJsonArray array;
    for (const int id : ids) {
        array.push_back(id);
    }
    return QString::fromUtf8(QJsonDocument(array).toJson(QJsonDocument::Compact));
}

[[nodiscard]] QVector<int> decodeIds(const QString &json)
{
    QVector<int> ids;
    for (const QJsonValue &value : QJsonDocument::fromJson(json.toUtf8()).array()) {
        ids.push_back(value.toInt());
    }
    return ids;
}

// An empty directory means no cache was configured, which must not read as
// the process's working directory.
[[nodiscard]] bool cached(const QString &directory, const QString &name)
{
    return !directory.isEmpty() && !name.isEmpty()
        && QFileInfo::exists(QDir(directory).filePath(name));
}

[[nodiscard]] QString cachedPath(const QString &directory, const QString &name)
{
    return cached(directory, name) ? QDir(directory).filePath(name) : QString();
}

struct StoredTitle
{
    QString kind;
    QString state;
    QDateTime fetchedAt;
    std::optional<int> tmdbId;
    QString posterRemotePath;
    QString backdropRemotePath;
    QString posterCachePath;
    QString backdropCachePath;
};

[[nodiscard]] QHash<QString, StoredTitle> storedTitles(QSqlDatabase &database)
{
    QSqlQuery query = prepared(
        database,
        QStringLiteral("SELECT owner_key, kind, fetch_state, fetched_at, tmdb_id, "
                       "poster_remote_path, backdrop_remote_path, poster_cache_path, "
                       "backdrop_cache_path FROM title_metadata"));
    executeOrThrow(query);

    QHash<QString, StoredTitle> titles;
    while (query.next()) {
        titles.insert(query.value(0).toString(),
                      {.kind = query.value(1).toString(),
                       .state = query.value(2).toString(),
                       .fetchedAt = parseTimestamp(query.value(3).toString()),
                       .tmdbId = query.value(4).isNull()
                           ? std::nullopt
                           : std::optional<int>(query.value(4).toInt()),
                       .posterRemotePath = query.value(5).toString(),
                       .backdropRemotePath = query.value(6).toString(),
                       .posterCachePath = query.value(7).toString(),
                       .backdropCachePath = query.value(8).toString()});
    }
    return titles;
}

struct StoredEpisode
{
    QDateTime fetchedAt;
    std::optional<int> tmdbEpisodeId;
    QString stillRemotePath;
    QString stillCachePath;
};

[[nodiscard]] QHash<QString, StoredEpisode> storedEpisodes(QSqlDatabase &database)
{
    QSqlQuery query = prepared(
        database,
        QStringLiteral("SELECT media_id, fetched_at, tmdb_episode_id, still_remote_path, "
                       "still_cache_path FROM episode_metadata"));
    executeOrThrow(query);

    QHash<QString, StoredEpisode> episodes;
    while (query.next()) {
        episodes.insert(query.value(0).toString(),
                        {.fetchedAt = parseTimestamp(query.value(1).toString()),
                         .tmdbEpisodeId = query.value(2).isNull()
                             ? std::nullopt
                             : std::optional<int>(query.value(2).toInt()),
                         .stillRemotePath = query.value(3).toString(),
                         .stillCachePath = query.value(4).toString()});
    }
    return episodes;
}

// The roots as the catalog stores them (CatalogStore::registerRoots).
[[nodiscard]] QStringList normalizedRootPaths(const QStringList &paths)
{
    QStringList normalized;
    for (const QString &path : paths) {
        const QString trimmed = path.trimmed();
        if (!trimmed.isEmpty()) {
            normalized.push_back(QDir(trimmed).absolutePath());
        }
    }
    return normalized;
}

[[nodiscard]] QString placeholders(qsizetype count)
{
    QStringList marks;
    for (qsizetype index = 0; index < count; ++index) {
        marks.push_back(QStringLiteral("?"));
    }
    return marks.join(QLatin1String(", "));
}

// Whether a title last tried at `fetchedAt` may be tried again at `now`.
[[nodiscard]] bool retryDue(const QDateTime &fetchedAt, int days, const QDateTime &now)
{
    return !fetchedAt.isValid() || fetchedAt.addDays(days) <= now;
}

struct ShowAccumulator
{
    MetadataTarget target;
    bool anySidecarPoster{false};
    bool anySidecarBackdrop{false};
};
}

MetadataStore::MetadataStore(const QString &catalogPath)
    : m_database(catalogPath)
{
}

QVector<MetadataTarget> MetadataStore::pendingTargets(const QStringList &rootPaths,
                                                      const QDateTime &now,
                                                      const CacheDirectories &cache)
{
    const QStringList roots = normalizedRootPaths(rootPaths);
    if (roots.isEmpty()) {
        return {};
    }

    QSqlDatabase &database = m_database.connection();
    const QHash<QString, StoredTitle> titles = storedTitles(database);
    const QHash<QString, StoredEpisode> episodes = storedEpisodes(database);

    const auto bindRoots = [&roots](QSqlQuery &query) {
        for (const QString &root : roots) {
            query.addBindValue(root);
        }
    };

    // The part of "what does this title still need" both kinds share: a title
    // with no row is fetched; a fetched one is not, except for artwork TMDB
    // named and the cache does not hold; one TMDB could not match waits.
    struct Need
    {
        bool details{false};
        bool poster{false};
        bool backdrop{false};
        bool any() const { return details || poster || backdrop; }
    };
    const auto needOf = [&](const StoredTitle *stored, bool sidecarGapPoster,
                            bool sidecarGapBackdrop) {
        Need need;
        if (stored == nullptr) {
            need.details = true;
            need.poster = sidecarGapPoster;
            need.backdrop = sidecarGapBackdrop;
            return need;
        }
        if (stored->state == QLatin1String("matched")) {
            need.poster = sidecarGapPoster && !stored->posterRemotePath.isEmpty()
                && !cached(cache.thumbnailDirectory, stored->posterCachePath);
            need.backdrop = sidecarGapBackdrop && !stored->backdropRemotePath.isEmpty()
                && !cached(cache.thumbnailDirectory, stored->backdropCachePath);
            return need;
        }
        const int days = stored->state == QLatin1String("unmatched") ? MetadataStore::unmatchedRetryDays
                                                                     : MetadataStore::failedRetryDays;
        if (retryDue(stored->fetchedAt, days, now)) {
            need.details = true;
            need.poster = sidecarGapPoster;
            need.backdrop = sidecarGapBackdrop;
        }
        return need;
    };

    QVector<MetadataTarget> targets;

    {
        QSqlQuery query = prepared(
            database,
            QStringLiteral("SELECT m.id, m.title, m.year, m.poster_path FROM media_items m "
                           "JOIN library_roots r ON r.id = m.library_root_id "
                           "WHERE m.media_kind = 'movie' AND r.path IN (%1) "
                           "ORDER BY m.sort_title, m.id")
                .arg(placeholders(roots.size())));
        bindRoots(query);
        executeOrThrow(query);

        while (query.next()) {
            const QString id = query.value(0).toString();
            const auto stored = titles.constFind(id);
            const StoredTitle *row = stored == titles.constEnd() ? nullptr : &*stored;
            // The scanner reads no movie backdrop sidecar, so TMDB's backdrop
            // fills a gap that is always there; the poster only when the
            // folder has none (a local sidecar still wins).
            const bool sidecarPoster = !query.value(3).toString().isEmpty();
            const Need need = needOf(row, !sidecarPoster, true);
            if (!need.any()) {
                continue;
            }
            MetadataTarget target;
            target.kind = MetadataTarget::Kind::Movie;
            target.ownerKey = id;
            target.title = query.value(1).toString();
            target.year = query.value(2).toInt();
            target.needsDetails = need.details;
            target.wantPoster = need.poster;
            target.wantBackdrop = need.backdrop;
            if (row != nullptr) {
                target.tmdbId = row->tmdbId;
                target.posterRemotePath = row->posterRemotePath;
                target.backdropRemotePath = row->backdropRemotePath;
            }
            targets.push_back(target);
        }
    }

    std::map<QString, ShowAccumulator> shows;
    {
        QSqlQuery query = prepared(
            database,
            QStringLiteral("SELECT m.id, m.show_name, m.year, m.season_number, "
                           "m.episode_number, m.show_poster_path, m.show_backdrop_path, "
                           "m.season_poster_path, m.episode_still_path "
                           "FROM media_items m "
                           "JOIN library_roots r ON r.id = m.library_root_id "
                           "WHERE m.media_kind = 'episode' AND m.show_name IS NOT NULL "
                           "AND r.path IN (%1) "
                           "ORDER BY m.show_name, m.year, m.season_number, m.episode_number, m.id")
                .arg(placeholders(roots.size())));
        bindRoots(query);
        executeOrThrow(query);

        while (query.next()) {
            const QString showName = query.value(1).toString();
            const int year = query.value(2).toInt();
            const QString key = showOwnerKey(showName, year);
            ShowAccumulator &show = shows[key];
            if (show.target.ownerKey.isEmpty()) {
                show.target.kind = MetadataTarget::Kind::Show;
                show.target.ownerKey = key;
                show.target.title = showName;
                show.target.year = year;
            }
            // MediaItem::gridShowPosterPath: the show folder's poster, then the
            // season folder's; those are the sidecars a show's poster yields to.
            if (!query.value(5).toString().isEmpty() || !query.value(7).toString().isEmpty()) {
                show.anySidecarPoster = true;
            }
            if (!query.value(6).toString().isEmpty()) {
                show.anySidecarBackdrop = true;
            }

            const QString mediaId = query.value(0).toString();
            const auto storedEpisode = episodes.constFind(mediaId);
            EpisodeTarget episode;
            episode.mediaId = mediaId;
            episode.seasonNumber = query.value(3).toInt();
            episode.episodeNumber = query.value(4).toInt();
            const bool stillGap = query.value(8).toString().isEmpty();
            if (storedEpisode == episodes.constEnd()) {
                episode.needsDetails = true;
                episode.wantStill = stillGap;
            } else {
                // An episode TMDB did not list waits like an unmatched title.
                episode.needsDetails = !storedEpisode->tmdbEpisodeId
                    && retryDue(storedEpisode->fetchedAt, unmatchedRetryDays, now);
                episode.stillRemotePath = storedEpisode->stillRemotePath;
                episode.wantStill = stillGap
                    && (episode.needsDetails
                        || (!storedEpisode->stillRemotePath.isEmpty()
                            && !cached(cache.thumbnailDirectory, storedEpisode->stillCachePath)));
            }
            if (episode.needsDetails || episode.wantStill) {
                show.target.episodes.push_back(episode);
            }
        }
    }

    for (auto &[key, show] : shows) {
        MetadataTarget target = show.target;
        const auto stored = titles.constFind(key);
        const StoredTitle *row = stored == titles.constEnd() ? nullptr : &*stored;
        const Need need = needOf(row, !show.anySidecarPoster, !show.anySidecarBackdrop);
        const bool matched = row != nullptr && row->state == QLatin1String("matched");

        target.needsDetails = need.details;
        target.wantPoster = need.poster;
        target.wantBackdrop = need.backdrop;
        if (row != nullptr) {
            target.tmdbId = row->tmdbId;
            target.posterRemotePath = row->posterRemotePath;
            target.backdropRemotePath = row->backdropRemotePath;
        }
        // Episodes can only be asked about under a show TMDB matched.
        if (!matched && !need.details) {
            continue;
        }
        if (!need.any() && target.episodes.isEmpty()) {
            continue;
        }
        targets.push_back(target);
    }
    return targets;
}

void MetadataStore::saveTitle(const MetadataTarget &target, const TitleMetadata &metadata,
                              const QDateTime &now)
{
    QSqlDatabase &database = m_database.connection();
    if (target.kind == MetadataTarget::Kind::Movie) {
        // A scan may have removed the file while TMDB was being asked, and a
        // row for it would outlive its trigger.
        QSqlQuery exists = prepared(database,
                                    QStringLiteral("SELECT 1 FROM media_items WHERE id = ?"));
        exists.addBindValue(target.ownerKey);
        executeOrThrow(exists);
        if (!exists.next()) {
            return;
        }
    }
    executeOrThrow(database, QStringLiteral("BEGIN IMMEDIATE"));
    try {
        QSqlQuery upsert = prepared(
            database,
            QStringLiteral(
                "INSERT INTO title_metadata (owner_key, kind, fetch_state, fetched_at, "
                "tmdb_id, overview, genres, director, certification, vote_average, "
                "vote_count, popularity, collection_id, collection_name, "
                "similar_tmdb_ids, recommended_tmdb_ids, release_date, runtime_minutes, "
                "poster_remote_path, backdrop_remote_path) "
                "VALUES (?, ?, 'matched', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) "
                "ON CONFLICT(owner_key) DO UPDATE SET "
                "kind = excluded.kind, fetch_state = 'matched', "
                "fetched_at = excluded.fetched_at, tmdb_id = excluded.tmdb_id, "
                "overview = excluded.overview, genres = excluded.genres, "
                "director = excluded.director, certification = excluded.certification, "
                "vote_average = excluded.vote_average, vote_count = excluded.vote_count, "
                "popularity = excluded.popularity, collection_id = excluded.collection_id, "
                "collection_name = excluded.collection_name, "
                "similar_tmdb_ids = excluded.similar_tmdb_ids, "
                "recommended_tmdb_ids = excluded.recommended_tmdb_ids, "
                "release_date = excluded.release_date, "
                "runtime_minutes = excluded.runtime_minutes, "
                // A cached image stays valid only while TMDB names the same one.
                "poster_cache_path = CASE WHEN poster_remote_path IS excluded.poster_remote_path "
                "THEN poster_cache_path ELSE NULL END, "
                "backdrop_cache_path = CASE WHEN backdrop_remote_path IS "
                "excluded.backdrop_remote_path THEN backdrop_cache_path ELSE NULL END, "
                "poster_remote_path = excluded.poster_remote_path, "
                "backdrop_remote_path = excluded.backdrop_remote_path"));
        upsert.addBindValue(target.ownerKey);
        upsert.addBindValue(target.kind == MetadataTarget::Kind::Movie ? QStringLiteral("movie")
                                                                       : QStringLiteral("show"));
        upsert.addBindValue(formatTimestamp(now));
        upsert.addBindValue(metadata.tmdbId);
        upsert.addBindValue(optionalText(metadata.overview));
        upsert.addBindValue(encodeStrings(metadata.genres));
        upsert.addBindValue(optionalText(metadata.director));
        upsert.addBindValue(optionalText(metadata.certification));
        upsert.addBindValue(optionalValue(metadata.voteAverage));
        upsert.addBindValue(optionalValue(metadata.voteCount));
        upsert.addBindValue(optionalValue(metadata.popularity));
        upsert.addBindValue(optionalValue(metadata.collectionId));
        upsert.addBindValue(optionalText(metadata.collectionName));
        upsert.addBindValue(encodeIds(metadata.similarTmdbIds));
        upsert.addBindValue(encodeIds(metadata.recommendedTmdbIds));
        upsert.addBindValue(optionalText(metadata.releaseDate));
        upsert.addBindValue(metadata.runtimeMinutes > 0 ? QVariant(metadata.runtimeMinutes)
                                                        : QVariant());
        upsert.addBindValue(optionalText(metadata.posterRemotePath));
        upsert.addBindValue(optionalText(metadata.backdropRemotePath));
        executeOrThrow(upsert);

        for (const QString &table : {QStringLiteral("title_cast"), QStringLiteral("title_keyword")}) {
            QSqlQuery clear = prepared(
                database, QStringLiteral("DELETE FROM %1 WHERE owner_key = ?").arg(table));
            clear.addBindValue(target.ownerKey);
            executeOrThrow(clear);
        }

        int ordinal = 0;
        for (const CastMember &member : metadata.cast) {
            QSqlQuery insert = prepared(
                database,
                QStringLiteral("INSERT INTO title_cast (owner_key, ordinal, person_id, name, "
                               "profile_path, character) VALUES (?, ?, ?, ?, ?, ?)"));
            insert.addBindValue(target.ownerKey);
            insert.addBindValue(ordinal++);
            insert.addBindValue(member.personId);
            insert.addBindValue(member.name);
            insert.addBindValue(optionalText(member.profilePath));
            insert.addBindValue(member.character);
            executeOrThrow(insert);
        }
        for (const MetadataKeyword &keyword : metadata.keywords) {
            // OR IGNORE: TMDB lists a keyword once, but a repeated id must not
            // cost the whole title.
            QSqlQuery insert = prepared(
                database,
                QStringLiteral("INSERT OR IGNORE INTO title_keyword (owner_key, keyword_id, name) "
                               "VALUES (?, ?, ?)"));
            insert.addBindValue(target.ownerKey);
            insert.addBindValue(keyword.id);
            insert.addBindValue(keyword.name);
            executeOrThrow(insert);
        }
        executeOrThrow(database, QStringLiteral("COMMIT"));
    } catch (...) {
        QSqlQuery rollback(database);
        if (!rollback.exec(QStringLiteral("ROLLBACK"))) {
            qCWarning(logCatalog) << "metadata rollback failed:" << rollback.lastError().text();
        }
        throw;
    }
}

void MetadataStore::saveAttempt(const MetadataTarget &target, const QString &state,
                                const QDateTime &now, std::optional<int> tmdbId)
{
    QSqlQuery query = prepared(
        m_database.connection(),
        QStringLiteral("INSERT INTO title_metadata (owner_key, kind, fetch_state, fetched_at, "
                       "tmdb_id) VALUES (?, ?, ?, ?, ?) "
                       "ON CONFLICT(owner_key) DO UPDATE SET fetch_state = excluded.fetch_state, "
                       "fetched_at = excluded.fetched_at, "
                       "tmdb_id = COALESCE(excluded.tmdb_id, tmdb_id) "
                       "WHERE fetch_state != 'matched'"));
    query.addBindValue(target.ownerKey);
    query.addBindValue(target.kind == MetadataTarget::Kind::Movie ? QStringLiteral("movie")
                                                                  : QStringLiteral("show"));
    query.addBindValue(state);
    query.addBindValue(formatTimestamp(now));
    query.addBindValue(optionalValue(tmdbId));
    executeOrThrow(query);
}

void MetadataStore::saveArtwork(const QString &ownerKey, bool poster,
                                const QString &thumbnailName, bool forgetRemote)
{
    const QString cacheColumn = poster ? QStringLiteral("poster_cache_path")
                                       : QStringLiteral("backdrop_cache_path");
    const QString remoteColumn = poster ? QStringLiteral("poster_remote_path")
                                        : QStringLiteral("backdrop_remote_path");
    QSqlQuery query = prepared(
        m_database.connection(),
        QStringLiteral("UPDATE title_metadata SET %1 = ?%2 WHERE owner_key = ?")
            .arg(cacheColumn,
                 forgetRemote ? QStringLiteral(", %1 = NULL").arg(remoteColumn) : QString()));
    query.addBindValue(optionalText(thumbnailName));
    query.addBindValue(ownerKey);
    executeOrThrow(query);
}

void MetadataStore::saveEpisode(const QString &mediaId,
                                const std::optional<EpisodeMetadata> &metadata,
                                const QDateTime &now)
{
    // A scan may have removed the file while TMDB was being asked; its row is
    // gone and a metadata row for it would break the reference.
    QSqlQuery exists = prepared(m_database.connection(),
                                QStringLiteral("SELECT 1 FROM media_items WHERE id = ?"));
    exists.addBindValue(mediaId);
    executeOrThrow(exists);
    if (!exists.next()) {
        return;
    }
    QSqlQuery query = prepared(
        m_database.connection(),
        QStringLiteral(
            "INSERT INTO episode_metadata (media_id, fetched_at, tmdb_episode_id, title, "
            "overview, air_date, vote_average, still_remote_path) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?) "
            "ON CONFLICT(media_id) DO UPDATE SET fetched_at = excluded.fetched_at, "
            "tmdb_episode_id = excluded.tmdb_episode_id, title = excluded.title, "
            "overview = excluded.overview, air_date = excluded.air_date, "
            "vote_average = excluded.vote_average, "
            "still_cache_path = CASE WHEN still_remote_path IS excluded.still_remote_path "
            "THEN still_cache_path ELSE NULL END, "
            "still_remote_path = excluded.still_remote_path"));
    query.addBindValue(mediaId);
    query.addBindValue(formatTimestamp(now));
    if (metadata) {
        query.addBindValue(metadata->tmdbEpisodeId > 0 ? QVariant(metadata->tmdbEpisodeId)
                                                       : QVariant(0));
        query.addBindValue(optionalText(metadata->title));
        query.addBindValue(optionalText(metadata->overview));
        query.addBindValue(optionalText(metadata->airDate));
        query.addBindValue(optionalValue(metadata->voteAverage));
        query.addBindValue(optionalText(metadata->stillRemotePath));
    } else {
        // TMDB's season did not list this episode.
        for (int column = 0; column < 6; ++column) {
            query.addBindValue(QVariant());
        }
    }
    executeOrThrow(query);
}

void MetadataStore::saveEpisodeStill(const QString &mediaId, const QString &thumbnailName,
                                     bool forgetRemote)
{
    QSqlQuery query = prepared(
        m_database.connection(),
        QStringLiteral("UPDATE episode_metadata SET still_cache_path = ?%1 WHERE media_id = ?")
            .arg(forgetRemote ? QStringLiteral(", still_remote_path = NULL") : QString()));
    query.addBindValue(optionalText(thumbnailName));
    query.addBindValue(mediaId);
    executeOrThrow(query);
}

void MetadataStore::attach(QSqlDatabase &database, QVector<MediaItem> &items,
                           const CacheDirectories &cache)
{
    if (items.isEmpty()) {
        return;
    }

    struct Loaded
    {
        std::shared_ptr<TitleMetadata> metadata;
        QString posterPath;
        QString backdropPath;
    };
    QHash<QString, Loaded> byOwner;

    {
        QSqlQuery query = prepared(
            database,
            QStringLiteral(
                "SELECT owner_key, tmdb_id, overview, genres, director, certification, "
                "vote_average, vote_count, popularity, collection_id, collection_name, "
                "similar_tmdb_ids, recommended_tmdb_ids, release_date, runtime_minutes, "
                "poster_remote_path, backdrop_remote_path, poster_cache_path, "
                "backdrop_cache_path FROM title_metadata WHERE fetch_state = 'matched'"));
        executeOrThrow(query);
        while (query.next()) {
            auto metadata = std::make_shared<TitleMetadata>();
            metadata->tmdbId = query.value(1).toInt();
            metadata->overview = query.value(2).toString();
            metadata->genres = decodeStrings(query.value(3).toString());
            metadata->director = query.value(4).toString();
            metadata->certification = query.value(5).toString();
            if (!query.value(6).isNull()) {
                metadata->voteAverage = query.value(6).toDouble();
            }
            if (!query.value(7).isNull()) {
                metadata->voteCount = query.value(7).toInt();
            }
            if (!query.value(8).isNull()) {
                metadata->popularity = query.value(8).toDouble();
            }
            if (!query.value(9).isNull()) {
                metadata->collectionId = query.value(9).toInt();
            }
            metadata->collectionName = query.value(10).toString();
            metadata->similarTmdbIds = decodeIds(query.value(11).toString());
            metadata->recommendedTmdbIds = decodeIds(query.value(12).toString());
            metadata->releaseDate = query.value(13).toString();
            metadata->runtimeMinutes = query.value(14).toInt();
            metadata->posterRemotePath = query.value(15).toString();
            metadata->backdropRemotePath = query.value(16).toString();
            byOwner.insert(query.value(0).toString(),
                           {.metadata = std::move(metadata),
                            .posterPath = cachedPath(cache.thumbnailDirectory,
                                                     query.value(17).toString()),
                            .backdropPath = cachedPath(cache.thumbnailDirectory,
                                                       query.value(18).toString())});
        }
    }
    {
        QSqlQuery query = prepared(
            database,
            QStringLiteral("SELECT owner_key, person_id, name, profile_path, character "
                           "FROM title_cast ORDER BY owner_key, ordinal"));
        executeOrThrow(query);
        while (query.next()) {
            const auto loaded = byOwner.find(query.value(0).toString());
            if (loaded == byOwner.end()) {
                continue;
            }
            loaded->metadata->cast.push_back({.name = query.value(2).toString(),
                                              .character = query.value(4).toString(),
                                              .profilePath = query.value(3).toString(),
                                              .personId = query.value(1).toInt()});
        }
    }
    {
        QSqlQuery query = prepared(
            database,
            QStringLiteral("SELECT owner_key, keyword_id, name FROM title_keyword "
                           "ORDER BY owner_key, keyword_id"));
        executeOrThrow(query);
        while (query.next()) {
            const auto loaded = byOwner.find(query.value(0).toString());
            if (loaded == byOwner.end()) {
                continue;
            }
            loaded->metadata->keywords.push_back(
                {.id = query.value(1).toInt(), .name = query.value(2).toString()});
        }
    }

    struct EpisodeFacts
    {
        QString title;
        QString overview;
        QString airDate;
        std::optional<double> voteAverage;
        QString stillPath;
    };
    QHash<QString, EpisodeFacts> episodeFacts;
    {
        QSqlQuery query = prepared(
            database,
            QStringLiteral("SELECT media_id, title, overview, air_date, vote_average, "
                           "still_cache_path FROM episode_metadata"));
        executeOrThrow(query);
        while (query.next()) {
            episodeFacts.insert(
                query.value(0).toString(),
                {.title = query.value(1).toString(),
                 .overview = query.value(2).toString(),
                 .airDate = query.value(3).toString(),
                 .voteAverage = query.value(4).isNull()
                     ? std::nullopt
                     : std::optional<double>(query.value(4).toDouble()),
                 .stillPath = cachedPath(cache.thumbnailDirectory, query.value(5).toString())});
        }
    }

    for (MediaItem &item : items) {
        const QString key = item.isEpisode() ? showOwnerKey(item.showName, item.year) : item.id;
        const auto loaded = byOwner.constFind(key);
        if (loaded != byOwner.constEnd()) {
            // One value shared by every episode of the show.
            item.metadata = loaded->metadata;
            item.tmdbPosterAbsolutePath = loaded->posterPath;
            item.tmdbBackdropAbsolutePath = loaded->backdropPath;
        }
        if (item.isEpisode()) {
            const auto facts = episodeFacts.constFind(item.id);
            if (facts != episodeFacts.constEnd()) {
                item.tmdbEpisodeTitle = facts->title;
                item.episodeOverview = facts->overview;
                item.episodeAirDate = facts->airDate;
                item.episodeVoteAverage = facts->voteAverage;
                item.tmdbEpisodeStillAbsolutePath = facts->stillPath;
            }
        }
    }
}
