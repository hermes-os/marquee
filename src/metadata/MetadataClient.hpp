#pragma once

#include <QByteArray>
#include <QElapsedTimer>
#include <QJsonObject>
#include <QObject>
#include <QString>
#include <QUrl>
#include <QVector>

#include <functional>
#include <optional>

#include "catalog/TitleMetadata.hpp"
#include "metadata/HttpTransport.hpp"
#include "metadata/TmdbParsing.hpp"

/// The asynchronous TMDB v3 client (TMDBService.swift). It owns no thread and
/// no network object: requests go through the `HttpTransport` it is given and
/// answer on the thread that transport answers on.
///
/// Requests are sequential and paced, as the released actor's were: the
/// caller starts the next one from the previous one's answer, and
/// `Config::minRequestIntervalMs` keeps even a fast network under TMDB's
/// published limit. A 429 is waited out (the `Retry-After` it names, capped)
/// and retried twice before the answer is `Throttled`.
class MetadataClient final : public QObject
{
public:
    struct Config
    {
        /// `Configuration.tmdbBaseURL`.
        QString apiBase{QStringLiteral("https://api.themoviedb.org/3")};
        /// `Configuration.tmdbImageBaseURL`.
        QString imageBase{QStringLiteral("https://image.tmdb.org/t/p")};
        QString apiKey;
        int minRequestIntervalMs{100};
        /// How long a 429 without a usable `Retry-After` waits.
        int defaultRetryDelayMs{2000};
        int maxRetryDelayMs{30'000};
        int throttleRetries{2};
    };

    /// What came back, in the terms the enrichment decides on.
    enum class Status {
        Ok,
        /// TMDB answered and has no such thing (404, or no matching result).
        NotFound,
        /// The answer was not the JSON this client reads.
        Malformed,
        /// The key was refused (401). Every further request would be too.
        Rejected,
        /// 429 after the retries.
        Throttled,
        /// No answer, or a 5xx: nothing was learned about the title.
        Unavailable
    };

    template<typename T>
    struct Result
    {
        Status status{Status::Unavailable};
        T value{};
    };

    /// A status after which the same request would only fail again, so the
    /// whole run should stop instead of working through every title.
    [[nodiscard]] static bool endsRun(Status status)
    {
        return status == Status::Rejected || status == Status::Throttled
            || status == Status::Unavailable;
    }

    MetadataClient(HttpTransport &transport, Config config, QObject *parent = nullptr);

    /// TMDBService.swift:165-199 and :203-237. The year narrows TMDB's own
    /// search (`year`, or `first_air_date_year` for a show) and is not a test
    /// of the results. When that narrowed search finds nothing, the search
    /// runs once more without the year and takes a title match released
    /// within a year of it, so a file named a year off still finds its title;
    /// the released app gave up there.
    void findMovie(const QString &title, int year,
                   std::function<void(Result<int>)> done);
    void findShow(const QString &title, int year,
                  std::function<void(Result<int>)> done);

    /// TMDBService.swift:101-127 and :141-161.
    void movieDetails(int tmdbId, std::function<void(Result<TitleMetadata>)> done);
    void showDetails(int tmdbId, std::function<void(Result<TitleMetadata>)> done);
    /// TMDBService.swift:483-525.
    void seasonEpisodes(int tmdbShowId, int seasonNumber,
                        std::function<void(Result<QVector<tmdb::SeasonEpisode>>)> done);

    enum class ImageSize { Poster, Backdrop, Still };
    /// `Configuration.posterDownloadSize` w780, backdrop and still w1280
    /// (ImageCacheService.swift:105). Answers the image bytes.
    void downloadImage(const QString &remotePath, ImageSize size,
                       std::function<void(Result<QByteArray>)> done);

private:
    struct JsonOutcome
    {
        Status status{Status::Unavailable};
        QJsonObject json;
    };

    void getJson(const QString &path,
                 const QVector<std::pair<QString, QString>> &query,
                 std::function<void(JsonOutcome)> done);
    struct SearchKind
    {
        QString path;
        QString yearParameter;
        QString titleKey;
        QString dateKey;
    };
    void search(const SearchKind &kind,
                const QString &title,
                int year,
                bool yearInQuery,
                std::optional<int> prefixMatch,
                std::function<void(Result<int>)> done);
    void send(const QUrl &url, int attempt, std::function<void(HttpReply)> done);
    void afterPacing(std::function<void()> action);

    HttpTransport &m_transport;
    Config m_config;
    QElapsedTimer m_clock;
    qint64 m_lastRequestAtMs{-1};
};
