#include "metadata/MetadataClient.hpp"

#include <QJsonDocument>
#include <QPointer>
#include <QTimer>
#include <QUrlQuery>

#include <algorithm>
#include <memory>
#include <utility>

#include "metadata/TmdbApiKey.hpp"
#include "support/Logging.hpp"

namespace
{
using Query = QVector<std::pair<QString, QString>>;

[[nodiscard]] MetadataClient::Status statusOf(const HttpReply &reply)
{
    using Status = MetadataClient::Status;
    if (reply.error != HttpReply::Error::None) {
        return Status::Unavailable;
    }
    if (reply.status >= 200 && reply.status < 300) {
        return Status::Ok;
    }
    switch (reply.status) {
    case 401:
        return Status::Rejected;
    case 404:
        return Status::NotFound;
    case 429:
        return Status::Throttled;
    default:
        // Any other status says nothing about the title: a 5xx is TMDB's
        // trouble, and a 4xx other than 404 is a request this client should
        // not have made.
        return Status::Unavailable;
    }
}

// TMDBService.swift:56-73 logs the status and never the body, and here the URL
// is masked as well because it carries the key.
void logFailure(const QUrl &url, const HttpReply &reply, MetadataClient::Status status)
{
    using Status = MetadataClient::Status;
    if (status == Status::NotFound) {
        qCInfo(logMetadata) << "TMDB has nothing at" << tmdb_key::masked(url);
        return;
    }
    if (status == Status::Rejected) {
        qCWarning(logMetadata) << "TMDB refused the API key (HTTP 401); check the key for"
                               << tmdb_key::masked(url);
        return;
    }
    if (reply.error != HttpReply::Error::None) {
        qCWarning(logMetadata) << "network request failed for" << tmdb_key::masked(url);
        return;
    }
    qCWarning(logMetadata) << "TMDB HTTP" << reply.status << "for" << tmdb_key::masked(url);
}
}

MetadataClient::MetadataClient(HttpTransport &transport, Config config, QObject *parent)
    : QObject(parent)
    , m_transport(transport)
    , m_config(std::move(config))
{
    m_clock.start();
}

void MetadataClient::afterPacing(std::function<void()> action)
{
    const qint64 now = m_clock.elapsed();
    const qint64 wait = m_lastRequestAtMs < 0
        ? 0
        : std::max<qint64>(0, m_config.minRequestIntervalMs - (now - m_lastRequestAtMs));
    m_lastRequestAtMs = now + wait;
    if (wait == 0) {
        action();
        return;
    }
    // The client is the timer's context, so a client that is gone takes its
    // pending request with it.
    QTimer::singleShot(static_cast<int>(wait), this, std::move(action));
}

void MetadataClient::send(const QUrl &url, int attempt, std::function<void(HttpReply)> done)
{
    afterPacing([this, url, attempt, done = std::move(done)]() mutable {
        // The transport may answer after this client is gone.
        QPointer<MetadataClient> self(this);
        m_transport.get(url, [self, url, attempt, done = std::move(done)](HttpReply reply) mutable {
            if (self.isNull()) {
                return;
            }
            if (statusOf(reply) == Status::Throttled && attempt < self->m_config.throttleRetries) {
                const int waitMs = reply.retryAfterSeconds >= 0
                    ? static_cast<int>(std::min<qint64>(qint64(reply.retryAfterSeconds) * 1000,
                                                      self->m_config.maxRetryDelayMs))
                    : self->m_config.defaultRetryDelayMs;
                qCWarning(logMetadata) << "TMDB rate limited (429); retrying in" << waitMs << "ms";
                QTimer::singleShot(waitMs, self.data(),
                                   [self, url, attempt, done = std::move(done)]() mutable {
                                       self->send(url, attempt + 1, std::move(done));
                                   });
                return;
            }
            done(std::move(reply));
        });
    });
}

void MetadataClient::getJson(const QString &path, const Query &query,
                             std::function<void(JsonOutcome)> done)
{
    QUrl url(m_config.apiBase + path);
    QUrlQuery items;
    for (const auto &[name, value] : query) {
        items.addQueryItem(name, value);
    }
    items.addQueryItem(QStringLiteral("api_key"), m_config.apiKey);
    url.setQuery(items);

    send(url, 0, [url, done = std::move(done)](HttpReply reply) {
        JsonOutcome outcome;
        outcome.status = statusOf(reply);
        if (outcome.status != Status::Ok) {
            logFailure(url, reply, outcome.status);
            done(std::move(outcome));
            return;
        }
        const QJsonDocument document = QJsonDocument::fromJson(reply.body);
        if (!document.isObject()) {
            qCWarning(logMetadata) << "unreadable TMDB answer for" << tmdb_key::masked(url);
            outcome.status = Status::Malformed;
        } else {
            outcome.json = document.object();
        }
        done(std::move(outcome));
    });
}

void MetadataClient::search(const SearchKind &kind, const QString &title, int year,
                            bool yearInQuery, std::optional<int> prefixMatch,
                            std::function<void(Result<int>)> done)
{
    Query query{{QStringLiteral("query"), title}};
    if (yearInQuery && year > 0) {
        query.push_back({kind.yearParameter, QString::number(year)});
    }
    getJson(kind.path, query,
            [this, kind, title, year, yearInQuery, prefixMatch, done = std::move(done)](JsonOutcome outcome) mutable {
                if (outcome.status != Status::Ok) {
                    done({outcome.status, 0});
                    return;
                }
                const QJsonArray results = outcome.json.value(QLatin1String("results")).toArray();
                // The second pass takes only results near the file's year,
                // because without the year TMDB lists every title of that name.
                const QJsonArray candidates = yearInQuery
                    ? results
                    : tmdb::resultsNearYear(results, kind.dateKey, year, 1);
                // A title the file's name merely begins with (`Star Trek` for
                // `Star Trek The Original Series`) is the last resort: the
                // search without the year can still find an equal title one
                // year off, which is a better answer.
                const bool canSearchAgain = yearInQuery && year > 0;
                if (const std::optional<int> match = tmdb::bestMatch(candidates, title, kind.titleKey, kind.dateKey,
                                                                     year, !canSearchAgain)) {
                    done({Status::Ok, *match});
                    return;
                }
                const std::optional<int> prefix = prefixMatch
                    ? prefixMatch
                    : (canSearchAgain ? tmdb::bestMatch(candidates, title, kind.titleKey, kind.dateKey, year)
                                      : std::nullopt);
                if (canSearchAgain) {
                    search(kind, title, year, false, prefix, std::move(done));
                    return;
                }
                if (prefix) {
                    done({Status::Ok, *prefix});
                    return;
                }
                qCInfo(logMetadata) << "no matching TMDB result for a title";
                done({Status::NotFound, 0});
            });
}

void MetadataClient::findMovie(const QString &title, int year,
                               std::function<void(Result<int>)> done)
{
    search({QStringLiteral("/search/movie"), QStringLiteral("year"), QStringLiteral("title"),
            QStringLiteral("release_date")},
           title, year, true, std::nullopt, std::move(done));
}

void MetadataClient::findShow(const QString &title, int year,
                              std::function<void(Result<int>)> done)
{
    search({QStringLiteral("/search/tv"), QStringLiteral("first_air_date_year"),
            QStringLiteral("name"), QStringLiteral("first_air_date")},
           title, year, true, std::nullopt, std::move(done));
}

void MetadataClient::movieDetails(int tmdbId, std::function<void(Result<TitleMetadata>)> done)
{
    getJson(QStringLiteral("/movie/%1").arg(tmdbId),
            {{QStringLiteral("append_to_response"),
              QStringLiteral("credits,release_dates,keywords,similar,recommendations")}},
            [tmdbId, done = std::move(done)](JsonOutcome outcome) {
                done({outcome.status,
                      outcome.status == Status::Ok ? tmdb::parseMovie(outcome.json, tmdbId)
                                                   : TitleMetadata{}});
            });
}

void MetadataClient::showDetails(int tmdbId, std::function<void(Result<TitleMetadata>)> done)
{
    getJson(QStringLiteral("/tv/%1").arg(tmdbId),
            {{QStringLiteral("append_to_response"), QStringLiteral("credits,content_ratings")}},
            [tmdbId, done = std::move(done)](JsonOutcome outcome) {
                done({outcome.status,
                      outcome.status == Status::Ok ? tmdb::parseShow(outcome.json, tmdbId)
                                                   : TitleMetadata{}});
            });
}

void MetadataClient::seasonEpisodes(
    int tmdbShowId, int seasonNumber,
    std::function<void(Result<QVector<tmdb::SeasonEpisode>>)> done)
{
    getJson(QStringLiteral("/tv/%1/season/%2").arg(tmdbShowId).arg(seasonNumber), {},
            [done = std::move(done)](JsonOutcome outcome) {
                done({outcome.status,
                      outcome.status == Status::Ok ? tmdb::parseSeason(outcome.json)
                                                   : QVector<tmdb::SeasonEpisode>{}});
            });
}

void MetadataClient::downloadImage(const QString &remotePath, ImageSize size,
                                   std::function<void(Result<QByteArray>)> done)
{
    // Configuration.swift:21-23: posters w780, backdrops and stills w1280.
    const QString sizeName = size == ImageSize::Poster ? QStringLiteral("w780")
                                                       : QStringLiteral("w1280");
    // The image host takes no key.
    const QUrl url(QStringLiteral("%1/%2%3").arg(m_config.imageBase, sizeName, remotePath));
    send(url, 0, [url, done = std::move(done)](HttpReply reply) {
        const Status status = statusOf(reply);
        if (status != Status::Ok) {
            logFailure(url, reply, status);
            done({status, {}});
            return;
        }
        done({Status::Ok, std::move(reply.body)});
    });
}
