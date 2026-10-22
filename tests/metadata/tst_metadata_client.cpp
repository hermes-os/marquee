#include <QDir>
#include <QEventLoop>
#include <QFile>
#include <QImage>
#include <QBuffer>
#include <QJsonDocument>
#include <QTemporaryDir>
#include <QtTest>

#include <optional>

#include "metadata/ArtworkCache.hpp"
#include "metadata/MetadataClient.hpp"
#include "metadata/TmdbApiKey.hpp"
#include "metadata/TmdbParsing.hpp"

#include "FakeTransport.hpp"

namespace
{
// A made-up key. The real one is a secret and none exists in this sandbox.
const QString kFakeKey = QStringLiteral("fake-key-0123456789abcdef");

QStringList &loggedMessages()
{
    static QStringList messages;
    return messages;
}

void collectMessage(QtMsgType, const QMessageLogContext &, const QString &message)
{
    loggedMessages().push_back(message);
}

[[nodiscard]] QByteArray fixture(const QString &name)
{
    QFile file(QDir(QStringLiteral(MARQUEE_METADATA_FIXTURES)).filePath(name));
    if (!file.open(QIODevice::ReadOnly)) {
        qFatal("missing fixture %s", qPrintable(name));
    }
    return file.readAll();
}

[[nodiscard]] QJsonObject fixtureObject(const QString &name)
{
    return QJsonDocument::fromJson(fixture(name)).object();
}

[[nodiscard]] QByteArray pngBytes(int width, int height)
{
    QImage image(width, height, QImage::Format_RGB32);
    image.fill(Qt::darkBlue);
    QByteArray bytes;
    QBuffer buffer(&bytes);
    buffer.open(QIODevice::WriteOnly);
    image.save(&buffer, "PNG");
    return bytes;
}

[[nodiscard]] QJsonArray results(std::initializer_list<std::pair<int, QString>> rows,
                                 const QString &titleKey = QStringLiteral("title"))
{
    QJsonArray array;
    for (const auto &[id, title] : rows) {
        array.push_back(QJsonObject{{QStringLiteral("id"), id}, {titleKey, title}});
    }
    return array;
}

MetadataClient::Config fastConfig()
{
    MetadataClient::Config config;
    config.apiKey = kFakeKey;
    config.minRequestIntervalMs = 0;
    config.defaultRetryDelayMs = 1;
    return config;
}
}

class MetadataClientTest final : public QObject
{
    Q_OBJECT

private slots:
    // --- matching -------------------------------------------------------

    void normalizingDropsALeadingArticleAndPunctuation()
    {
        QCOMPARE(tmdb::normalizeTitle(QStringLiteral("The Matrix")), QStringLiteral("matrix"));
        QCOMPARE(tmdb::normalizeTitle(QStringLiteral("A Quiet Place")), QStringLiteral("quiet place"));
        QCOMPARE(tmdb::normalizeTitle(QStringLiteral("An Education")), QStringLiteral("education"));
        QCOMPARE(tmdb::normalizeTitle(QStringLiteral("Spider-Man: Homecoming")),
                 QStringLiteral("spiderman homecoming"));
        QCOMPARE(tmdb::normalizeTitle(QStringLiteral("Fast & Furious")),
                 QStringLiteral("fast and furious"));
        QCOMPARE(tmdb::normalizeTitle(QStringLiteral("  Lots   of \t spaces  ")),
                 QStringLiteral("lots of spaces"));
        // "the" is only an article when a word follows it.
        QCOMPARE(tmdb::normalizeTitle(QStringLiteral("Theatre Nights")),
                 QStringLiteral("theatre nights"));
        QCOMPARE(tmdb::normalizeTitle(QStringLiteral("The")), QStringLiteral("the"));
        // Only a leading article goes.
        QCOMPARE(tmdb::normalizeTitle(QStringLiteral("Into The Wild")),
                 QStringLiteral("into the wild"));
    }

    void anEqualTitleBeatsAnEarlierPartialOne()
    {
        const QJsonArray rows = fixtureObject(QStringLiteral("search_movie.json"))
                                    .value(QStringLiteral("results")).toArray();
        QCOMPARE(tmdb::bestMatch(rows, QStringLiteral("Synthetic Odyssey"), QStringLiteral("title")),
                 std::optional<int>(9001));
        // "the" and punctuation do not stop two titles being equal.
        QCOMPARE(tmdb::bestMatch(results({{1, QStringLiteral("Spider-Man: Homecoming")}}),
                                 QStringLiteral("the spiderman homecoming"), QStringLiteral("title")),
                 std::optional<int>(1));
    }

    void aResultHoldingEveryQueryWordMatchesWhenNoneIsEqual()
    {
        const QJsonArray rows = results({{10, QStringLiteral("Unrelated Film")},
                                         {11, QStringLiteral("Synthetic Odyssey Extended Cut")}});
        QCOMPARE(tmdb::bestMatch(rows, QStringLiteral("Synthetic Odyssey"), QStringLiteral("title")),
                 std::optional<int>(11));
    }

    void onlyTheTopResultIsTriedBySimilarity()
    {
        // 2 of 3 words shared out of 4 distinct: 0.5 is not above the bar.
        QCOMPARE(tmdb::bestMatch(results({{1, QStringLiteral("Red Green Blue")}}),
                                 QStringLiteral("Red Green Yellow"), QStringLiteral("title")),
                 std::optional<int>());
        // 3 of 4 words shared out of 5 distinct (0.6) is.
        QCOMPARE(tmdb::bestMatch(results({{2, QStringLiteral("Red Green Blue Pink")}}),
                                 QStringLiteral("Red Green Blue Gold"), QStringLiteral("title")),
                 std::optional<int>(2));
        // A good second result is not looked at by that pass.
        QCOMPARE(tmdb::bestMatch(results({{3, QStringLiteral("Red Pink")},
                                          {4, QStringLiteral("Red Green Blue Pink")}}),
                                 QStringLiteral("Red Green Blue Gold"), QStringLiteral("title")),
                 std::optional<int>());
    }

    void noResultMeansNoMatch()
    {
        QCOMPARE(tmdb::bestMatch({}, QStringLiteral("Anything"), QStringLiteral("title")),
                 std::optional<int>());
        QCOMPARE(tmdb::bestMatch(results({{1, QStringLiteral("Completely Different")}}),
                                 QStringLiteral("Synthetic Odyssey"), QStringLiteral("title")),
                 std::optional<int>());
        // A result without the title key, or without an id, is skipped.
        QJsonArray rows;
        rows.push_back(QJsonObject{{QStringLiteral("id"), 5}});
        rows.push_back(QJsonObject{{QStringLiteral("title"), QStringLiteral("Synthetic Odyssey")}});
        QCOMPARE(tmdb::bestMatch(rows, QStringLiteral("Synthetic Odyssey"), QStringLiteral("title")),
                 std::optional<int>());
    }

    void aShowIsMatchedOnItsNameKey()
    {
        QCOMPARE(tmdb::bestMatch(results({{7, QStringLiteral("The Synthetic Harbor")}},
                                         QStringLiteral("name")),
                                 QStringLiteral("Synthetic Harbor"), QStringLiteral("name")),
                 std::optional<int>(7));
    }

    void resultsNearAYearKeepsOnlyThoseWithinTheTolerance()
    {
        QJsonArray rows;
        for (const auto &[id, date] : std::initializer_list<std::pair<int, QString>>{
                 {1, QStringLiteral("2014-01-01")}, {2, QStringLiteral("2015-06-30")},
                 {3, QStringLiteral("2018-01-01")}, {4, QString()}, {5, QStringLiteral("x")}}) {
            rows.push_back(QJsonObject{{QStringLiteral("id"), id}, {QStringLiteral("release_date"), date}});
        }
        const QJsonArray near =
            tmdb::resultsNearYear(rows, QStringLiteral("release_date"), 2016, 1);
        QCOMPARE(near.size(), 1);
        QCOMPARE(near.first().toObject().value(QStringLiteral("id")).toInt(), 2);
    }

    // --- parsing --------------------------------------------------------

    void aMovieAnswerIsReadFieldByField()
    {
        const TitleMetadata movie =
            tmdb::parseMovie(fixtureObject(QStringLiteral("movie_with_collection.json")), 9001);
        QCOMPARE(movie.tmdbId, 9001);
        QCOMPARE(movie.overview, QStringLiteral("A synthetic crew crosses a synthetic sea."));
        QCOMPARE(movie.genres, (QStringList{QStringLiteral("Adventure"), QStringLiteral("Science Fiction")}));
        QCOMPARE(movie.director, QStringLiteral("Director One"));
        // The first non-empty US certification, not the GB one.
        QCOMPARE(movie.certification, QStringLiteral("PG-13"));
        QCOMPARE(movie.voteAverage, std::optional<double>(7.4));
        QCOMPARE(movie.voteCount, std::optional<int>(3120));
        QCOMPARE(movie.popularity, std::optional<double>(41.5));
        QCOMPARE(movie.collectionId, std::optional<int>(777));
        QCOMPARE(movie.collectionName, QStringLiteral("Synthetic Odyssey Collection"));
        QCOMPARE(movie.releaseDate, QStringLiteral("2019-07-12"));
        QCOMPARE(movie.runtimeMinutes, 128);
        QCOMPARE(movie.posterRemotePath, QStringLiteral("/synthPoster.jpg"));
        QCOMPARE(movie.backdropRemotePath, QStringLiteral("/synthBackdrop.jpg"));
        // An entry with no name is dropped; ids come as TMDB listed them.
        QCOMPARE(movie.keywords.size(), 2);
        QCOMPARE(movie.keywords.at(0), (MetadataKeyword{1, QStringLiteral("sea voyage")}));
        QCOMPARE(movie.similarTmdbIds, (QVector<int>{9002, 9003}));
        QCOMPARE(movie.recommendedTmdbIds, (QVector<int>{9004, 9002}));
    }

    void castKeepsTheFirstTenBilledThatCarryAnIdAndACharacter()
    {
        const TitleMetadata movie =
            tmdb::parseMovie(fixtureObject(QStringLiteral("movie_with_collection.json")), 9001);
        // Twelve billed; the first ten are looked at, and of those the third
        // has no character and the fifth no person id.
        QCOMPARE(movie.cast.size(), 8);
        QCOMPARE(movie.cast.at(0).name, QStringLiteral("Actor 1"));
        QCOMPARE(movie.cast.at(0).character, QStringLiteral("Role 1"));
        QCOMPARE(movie.cast.at(0).profilePath, QStringLiteral("/actor1.jpg"));
        QCOMPARE(movie.cast.at(0).personId, 5001);
        QCOMPARE(movie.cast.at(1).profilePath, QString());
        QCOMPARE(movie.cast.at(2).name, QStringLiteral("Actor 4"));
        QCOMPARE(movie.cast.at(3).name, QStringLiteral("Actor 6"));
        QCOMPARE(movie.cast.last().name, QStringLiteral("Actor 10"));
    }

    void aSparseMovieAnswerLeavesTheOptionalFieldsAbsent()
    {
        const TitleMetadata movie =
            tmdb::parseMovie(fixtureObject(QStringLiteral("movie_bare.json")), 9010);
        QCOMPARE(movie.tmdbId, 9010);
        QVERIFY(movie.overview.isEmpty());
        QVERIFY(movie.genres.isEmpty());
        QVERIFY(movie.cast.isEmpty());
        QVERIFY(movie.director.isEmpty());
        QVERIFY(movie.certification.isEmpty());
        QVERIFY(!movie.voteAverage);
        QVERIFY(!movie.voteCount);
        QVERIFY(!movie.popularity);
        QVERIFY(!movie.collectionId);
        QVERIFY(movie.keywords.isEmpty());
        QVERIFY(movie.similarTmdbIds.isEmpty());
        QCOMPARE(movie.runtimeMinutes, 0);
    }

    void aShowAnswerIsReadTheWayTheReleasedAppReadsIt()
    {
        const TitleMetadata show =
            tmdb::parseShow(fixtureObject(QStringLiteral("tv_show.json")), 9101);
        QCOMPARE(show.tmdbId, 9101);
        QCOMPARE(show.genres, (QStringList{QStringLiteral("Drama"), QStringLiteral("Mystery")}));
        // The first creator stands where a movie has its director.
        QCOMPARE(show.director, QStringLiteral("Creator One"));
        // The most restrictive US rating.
        QCOMPARE(show.certification, QStringLiteral("TV-MA"));
        QCOMPARE(show.voteAverage, std::optional<double>(8.1));
        QCOMPARE(show.releaseDate, QStringLiteral("2015-03-02"));
        QCOMPARE(show.runtimeMinutes, 44);
        QCOMPARE(show.cast.size(), 2);
        QCOMPARE(show.cast.at(1).character, QStringLiteral("Ferryman"));
        // TMDBService.parseTVJSON never reads these, so a show has none.
        QVERIFY(!show.voteCount);
        QVERIFY(!show.popularity);
        QVERIFY(!show.collectionId);
        QVERIFY(show.keywords.isEmpty());
    }

    void theMostRestrictiveRatingWinsAndAnUnknownOneCountsAsNotRated()
    {
        QCOMPARE(tmdb::mostRestrictiveRating({QStringLiteral("TV-14"), QStringLiteral("TV-MA")}),
                 QStringLiteral("TV-MA"));
        QCOMPARE(tmdb::mostRestrictiveRating({QStringLiteral("TV-MA"), QStringLiteral("TV-Y")}),
                 QStringLiteral("TV-MA"));
        QCOMPARE(tmdb::mostRestrictiveRating({QStringLiteral("TV-PG"), QStringLiteral("Weird")}),
                 QStringLiteral("Weird"));
        QCOMPARE(tmdb::mostRestrictiveRating({}), QString());
    }

    void aSeasonAnswerListsItsNamedEpisodes()
    {
        const auto episodes = tmdb::parseSeason(fixtureObject(QStringLiteral("tv_season_1.json")));
        QCOMPARE(episodes.size(), 2);
        QCOMPARE(episodes.at(0).episodeNumber, 1);
        QCOMPARE(episodes.at(0).metadata.title, QStringLiteral("Arrivals"));
        QCOMPARE(episodes.at(0).metadata.tmdbEpisodeId, 91011);
        QCOMPARE(episodes.at(0).metadata.stillRemotePath, QStringLiteral("/e1.jpg"));
        QCOMPARE(episodes.at(0).metadata.voteAverage, std::optional<double>(7.9));
        QCOMPARE(episodes.at(1).metadata.stillRemotePath, QString());
        QVERIFY(episodes.at(1).metadata.overview.isEmpty());
    }

    // --- the client -----------------------------------------------------

    void aMovieSearchSendsTheTitleTheYearAndTheKey()
    {
        FakeTransport transport([](const QUrl &) {
            return FakeTransport::json(fixture(QStringLiteral("search_movie.json")));
        });
        MetadataClient client(transport, fastConfig());

        std::optional<MetadataClient::Result<int>> answer;
        client.findMovie(QStringLiteral("Synthetic Odyssey"), 2019,
                         [&answer](MetadataClient::Result<int> result) { answer = result; });
        QTRY_VERIFY(answer.has_value());

        QCOMPARE(answer->status, MetadataClient::Status::Ok);
        QCOMPARE(answer->value, 9001);
        QCOMPARE(transport.count(), 1);
        const QUrl url = transport.urls().first();
        QCOMPARE(url.host(), QStringLiteral("api.themoviedb.org"));
        QCOMPARE(url.path(), QStringLiteral("/3/search/movie"));
        QCOMPARE(FakeTransport::queryValue(url, QStringLiteral("query")), QStringLiteral("Synthetic Odyssey"));
        QCOMPARE(FakeTransport::queryValue(url, QStringLiteral("year")), QStringLiteral("2019"));
        QCOMPARE(FakeTransport::queryValue(url, QStringLiteral("api_key")), kFakeKey);
    }

    void aShowSearchUsesTheFirstAirYear()
    {
        FakeTransport transport([](const QUrl &) {
            return FakeTransport::json(QByteArrayLiteral(
                R"({"results":[{"id":9101,"name":"Synthetic Harbor"}]})"));
        });
        MetadataClient client(transport, fastConfig());

        std::optional<MetadataClient::Result<int>> answer;
        client.findShow(QStringLiteral("Synthetic Harbor"), 2015,
                        [&answer](MetadataClient::Result<int> result) { answer = result; });
        QTRY_VERIFY(answer.has_value());

        QCOMPARE(answer->value, 9101);
        QCOMPARE(transport.urls().first().path(), QStringLiteral("/3/search/tv"));
        QCOMPARE(FakeTransport::queryValue(transport.urls().first(), QStringLiteral("first_air_date_year")),
                 QStringLiteral("2015"));
    }

    void aTitleWithoutAYearIsSearchedByNameAlone()
    {
        FakeTransport transport([](const QUrl &) {
            return FakeTransport::json(fixture(QStringLiteral("search_movie.json")));
        });
        MetadataClient client(transport, fastConfig());
        std::optional<MetadataClient::Result<int>> answer;
        client.findMovie(QStringLiteral("Synthetic Odyssey"), 0,
                         [&answer](MetadataClient::Result<int> result) { answer = result; });
        QTRY_VERIFY(answer.has_value());
        QVERIFY(!QUrlQuery(transport.urls().first()).hasQueryItem(QStringLiteral("year")));
    }

    void aFileNamedAYearOffStillFindsItsTitle()
    {
        // The file says 2018, TMDB dates the film 2019. TMDB's year-narrowed
        // search finds nothing, so the search runs again without the year and
        // takes the title released within a year of the file's.
        FakeTransport transport([](const QUrl &url) {
            if (!FakeTransport::queryValue(url, QStringLiteral("year")).isEmpty()) {
                return FakeTransport::json(QByteArrayLiteral(R"({"results":[]})"));
            }
            return FakeTransport::json(fixture(QStringLiteral("search_movie.json")));
        });
        MetadataClient client(transport, fastConfig());

        std::optional<MetadataClient::Result<int>> answer;
        client.findMovie(QStringLiteral("Synthetic Odyssey"), 2018,
                         [&answer](MetadataClient::Result<int> result) { answer = result; });
        QTRY_VERIFY(answer.has_value());
        QCOMPARE(answer->status, MetadataClient::Status::Ok);
        QCOMPARE(answer->value, 9001);
        QCOMPARE(transport.count(), 2);
    }

    void aFileNamedTwoYearsOffIsNotMatchedToAnotherFilm()
    {
        FakeTransport transport([](const QUrl &url) {
            if (!FakeTransport::queryValue(url, QStringLiteral("year")).isEmpty()) {
                return FakeTransport::json(QByteArrayLiteral(R"({"results":[]})"));
            }
            return FakeTransport::json(fixture(QStringLiteral("search_movie.json")));
        });
        MetadataClient client(transport, fastConfig());

        std::optional<MetadataClient::Result<int>> answer;
        client.findMovie(QStringLiteral("Synthetic Odyssey"), 2016,
                         [&answer](MetadataClient::Result<int> result) { answer = result; });
        QTRY_VERIFY(answer.has_value());
        QCOMPARE(answer->status, MetadataClient::Status::NotFound);
    }

    void aSearchWithNoMatchingTitleIsNotFound()
    {
        FakeTransport transport([](const QUrl &) {
            return FakeTransport::json(QByteArrayLiteral(
                R"({"results":[{"id":1,"title":"Something Else Entirely"}]})"));
        });
        MetadataClient client(transport, fastConfig());
        std::optional<MetadataClient::Result<int>> answer;
        client.findMovie(QStringLiteral("Synthetic Odyssey"), 0,
                         [&answer](MetadataClient::Result<int> result) { answer = result; });
        QTRY_VERIFY(answer.has_value());
        QCOMPARE(answer->status, MetadataClient::Status::NotFound);
    }

    void movieDetailsAskForCreditsReleaseDatesKeywordsAndNeighbours()
    {
        FakeTransport transport([](const QUrl &) {
            return FakeTransport::json(fixture(QStringLiteral("movie_with_collection.json")));
        });
        MetadataClient client(transport, fastConfig());

        std::optional<MetadataClient::Result<TitleMetadata>> answer;
        client.movieDetails(9001, [&answer](MetadataClient::Result<TitleMetadata> result) {
            answer = std::move(result);
        });
        QTRY_VERIFY(answer.has_value());

        QCOMPARE(answer->status, MetadataClient::Status::Ok);
        QCOMPARE(answer->value.tmdbId, 9001);
        QCOMPARE(answer->value.collectionId, std::optional<int>(777));
        const QUrl url = transport.urls().first();
        QCOMPARE(url.path(), QStringLiteral("/3/movie/9001"));
        QCOMPARE(FakeTransport::queryValue(url, QStringLiteral("append_to_response")),
                 QStringLiteral("credits,release_dates,keywords,similar,recommendations"));
    }

    void showDetailsAndSeasonsUseTheirOwnEndpoints()
    {
        FakeTransport transport([](const QUrl &url) {
            return FakeTransport::json(url.path().contains(QLatin1String("/season/"))
                                           ? fixture(QStringLiteral("tv_season_1.json"))
                                           : fixture(QStringLiteral("tv_show.json")));
        });
        MetadataClient client(transport, fastConfig());

        std::optional<MetadataClient::Result<TitleMetadata>> show;
        client.showDetails(9101, [&show](MetadataClient::Result<TitleMetadata> result) {
            show = std::move(result);
        });
        QTRY_VERIFY(show.has_value());
        QCOMPARE(show->value.certification, QStringLiteral("TV-MA"));

        std::optional<MetadataClient::Result<QVector<tmdb::SeasonEpisode>>> season;
        client.seasonEpisodes(9101, 1, [&season](MetadataClient::Result<QVector<tmdb::SeasonEpisode>> result) {
            season = std::move(result);
        });
        QTRY_VERIFY(season.has_value());
        QCOMPARE(season->value.size(), 2);

        QCOMPARE(transport.urls().at(0).path(), QStringLiteral("/3/tv/9101"));
        QCOMPARE(FakeTransport::queryValue(transport.urls().at(0), QStringLiteral("append_to_response")),
                 QStringLiteral("credits,content_ratings"));
        QCOMPARE(transport.urls().at(1).path(), QStringLiteral("/3/tv/9101/season/1"));
    }

    void imagesComeFromTheImageHostAtTheReleasedSizes()
    {
        FakeTransport transport([](const QUrl &) { return FakeTransport::json(pngBytes(4, 4)); });
        MetadataClient client(transport, fastConfig());

        int answers = 0;
        for (const auto size : {MetadataClient::ImageSize::Poster, MetadataClient::ImageSize::Backdrop,
                                MetadataClient::ImageSize::Still}) {
            client.downloadImage(QStringLiteral("/p.jpg"), size,
                                 [&answers](MetadataClient::Result<QByteArray> result) {
                                     QCOMPARE(result.status, MetadataClient::Status::Ok);
                                     ++answers;
                                 });
        }
        QTRY_COMPARE(answers, 3);
        QCOMPARE(transport.urls().at(0).toString(), QStringLiteral("https://image.tmdb.org/t/p/w780/p.jpg"));
        QCOMPARE(transport.urls().at(1).toString(), QStringLiteral("https://image.tmdb.org/t/p/w1280/p.jpg"));
        QCOMPARE(transport.urls().at(2).toString(), QStringLiteral("https://image.tmdb.org/t/p/w1280/p.jpg"));
        // The image host takes no key.
        QVERIFY(!QUrlQuery(transport.urls().at(0)).hasQueryItem(QStringLiteral("api_key")));
    }

    void statusesMapToWhatTheEnrichmentDecidesOn()
    {
        const auto statusFor = [](const FakeTransport::Responder &responder) {
            FakeTransport transport(responder);
            MetadataClient client(transport, fastConfig());
            std::optional<MetadataClient::Status> status;
            client.movieDetails(1, [&status](MetadataClient::Result<TitleMetadata> result) {
                status = result.status;
            });
            [[maybe_unused]] const bool answered =
                QTest::qWaitFor([&status] { return status.has_value(); }, 5000);
            return status.value_or(MetadataClient::Status::Unavailable);
        };
        QCOMPARE(statusFor([](const QUrl &) { return FakeTransport::status(401); }),
                 MetadataClient::Status::Rejected);
        QCOMPARE(statusFor([](const QUrl &) { return FakeTransport::status(404); }),
                 MetadataClient::Status::NotFound);
        QCOMPARE(statusFor([](const QUrl &) { return FakeTransport::status(500); }),
                 MetadataClient::Status::Unavailable);
        QCOMPARE(statusFor([](const QUrl &) { return FakeTransport::offline(); }),
                 MetadataClient::Status::Unavailable);
        QCOMPARE(statusFor([](const QUrl &) { return FakeTransport::json("not json"); }),
                 MetadataClient::Status::Malformed);
        QCOMPARE(statusFor([](const QUrl &) { return FakeTransport::json("[1,2]"); }),
                 MetadataClient::Status::Malformed);
        QVERIFY(MetadataClient::endsRun(MetadataClient::Status::Rejected));
        QVERIFY(MetadataClient::endsRun(MetadataClient::Status::Unavailable));
        QVERIFY(!MetadataClient::endsRun(MetadataClient::Status::NotFound));
        QVERIFY(!MetadataClient::endsRun(MetadataClient::Status::Malformed));
    }

    void aRateLimitIsWaitedOutAndRetried()
    {
        int calls = 0;
        FakeTransport transport([&calls](const QUrl &) {
            return ++calls < 3 ? FakeTransport::status(429)
                               : FakeTransport::json(fixture(QStringLiteral("movie_bare.json")));
        });
        MetadataClient client(transport, fastConfig());

        std::optional<MetadataClient::Result<TitleMetadata>> answer;
        client.movieDetails(9010, [&answer](MetadataClient::Result<TitleMetadata> result) {
            answer = std::move(result);
        });
        QTRY_VERIFY_WITH_TIMEOUT(answer.has_value(), 5000);
        QCOMPARE(answer->status, MetadataClient::Status::Ok);
        QCOMPARE(transport.count(), 3);
    }

    void aRateLimitThatDoesNotLiftIsReportedAfterTheRetries()
    {
        FakeTransport transport([](const QUrl &) { return FakeTransport::status(429); });
        MetadataClient client(transport, fastConfig());

        std::optional<MetadataClient::Result<TitleMetadata>> answer;
        client.movieDetails(1, [&answer](MetadataClient::Result<TitleMetadata> result) {
            answer = std::move(result);
        });
        QTRY_VERIFY_WITH_TIMEOUT(answer.has_value(), 5000);
        QCOMPARE(answer->status, MetadataClient::Status::Throttled);
        // The first try and two retries.
        QCOMPARE(transport.count(), 3);
    }

    void requestsAreSpacedByTheConfiguredInterval()
    {
        FakeTransport transport([](const QUrl &) {
            return FakeTransport::json(fixture(QStringLiteral("movie_bare.json")));
        });
        MetadataClient::Config config = fastConfig();
        config.minRequestIntervalMs = 80;
        MetadataClient client(transport, config);

        QElapsedTimer clock;
        clock.start();
        int answers = 0;
        for (int index = 0; index < 3; ++index) {
            client.movieDetails(9010, [&answers](MetadataClient::Result<TitleMetadata>) { ++answers; });
        }
        QTRY_COMPARE_WITH_TIMEOUT(answers, 3, 5000);
        // Three requests need two gaps.
        QVERIFY2(clock.elapsed() >= 150, qPrintable(QString::number(clock.elapsed())));
    }

    // --- the key --------------------------------------------------------

    void theEnvironmentKeyWinsOverTheFile()
    {
        QTemporaryDir directory;
        const QString keyFile = QDir(directory.path()).filePath(QStringLiteral("tmdb-api-key"));
        {
            QFile file(keyFile);
            QVERIFY(file.open(QIODevice::WriteOnly));
            file.write("from-the-file\n");
        }
        QCOMPARE(tmdb_key::resolve(QStringLiteral("from-the-environment"), keyFile),
                 QStringLiteral("from-the-environment"));
        QCOMPARE(tmdb_key::resolve(QString(), keyFile), QStringLiteral("from-the-file"));
        QCOMPARE(tmdb_key::resolve(QStringLiteral("   "), keyFile), QStringLiteral("from-the-file"));
    }

    void theKeyFileHoldsOneTrimmedLine()
    {
        QTemporaryDir directory;
        const QString keyFile = QDir(directory.path()).filePath(QStringLiteral("tmdb-api-key"));
        {
            QFile file(keyFile);
            QVERIFY(file.open(QIODevice::WriteOnly));
            file.write("  fake-key-line-one \r\nsecond line is ignored\n");
        }
        QCOMPARE(tmdb_key::resolve(QString(), keyFile), QStringLiteral("fake-key-line-one"));
    }

    void noKeyMeansNoKey()
    {
        QTemporaryDir directory;
        QCOMPARE(tmdb_key::resolve(QString(), QDir(directory.path()).filePath(QStringLiteral("absent"))),
                 QString());
        QCOMPARE(tmdb_key::resolve(QString(), QString()), QString());
    }

    void aLoggedRequestUrlHasItsKeyMasked()
    {
        QUrl url(QStringLiteral("https://api.themoviedb.org/3/movie/9001"));
        QUrlQuery query;
        query.addQueryItem(QStringLiteral("append_to_response"), QStringLiteral("credits"));
        query.addQueryItem(QStringLiteral("api_key"), kFakeKey);
        url.setQuery(query);

        const QString masked = tmdb_key::masked(url);
        QVERIFY(!masked.contains(kFakeKey));
        QVERIFY(masked.contains(QStringLiteral("api_key=***")));
        QVERIFY(masked.contains(QStringLiteral("append_to_response=credits")));
        QVERIFY(masked.contains(QStringLiteral("/3/movie/9001")));

        QCOMPARE(tmdb_key::scrub(QStringLiteral("GET ?api_key=%1 failed").arg(kFakeKey), kFakeKey),
                 QStringLiteral("GET ?api_key=*** failed"));
        QCOMPARE(tmdb_key::scrub(QStringLiteral("nothing here"), QString()), QStringLiteral("nothing here"));
    }

    void noLogLineOfAFailingRequestHoldsTheKey()
    {
        loggedMessages().clear();
        const QtMessageHandler previous = qInstallMessageHandler(collectMessage);

        // Every failure the client logs: no answer, rejected key, rate limit,
        // server error, unreadable answer, missing item, and a search that
        // matches nothing.
        const QList<FakeTransport::Responder> failures{
            [](const QUrl &) { return FakeTransport::offline(); },
            [](const QUrl &) { return FakeTransport::status(401); },
            [](const QUrl &) { return FakeTransport::status(429); },
            [](const QUrl &) { return FakeTransport::status(503); },
            [](const QUrl &) { return FakeTransport::json("garbage"); },
            [](const QUrl &) { return FakeTransport::status(404); }};
        for (const FakeTransport::Responder &failure : failures) {
            FakeTransport transport(failure);
            MetadataClient client(transport, fastConfig());
            bool done = false;
            client.movieDetails(9001, [&done](MetadataClient::Result<TitleMetadata>) { done = true; });
            QTRY_VERIFY_WITH_TIMEOUT(done, 5000);
            done = false;
            client.findMovie(QStringLiteral("Synthetic Odyssey"), 2019,
                             [&done](MetadataClient::Result<int>) { done = true; });
            QTRY_VERIFY_WITH_TIMEOUT(done, 5000);
        }

        qInstallMessageHandler(previous);
        QVERIFY2(!loggedMessages().isEmpty(), "the failures should have been logged");
        for (const QString &message : std::as_const(loggedMessages())) {
            QVERIFY2(!message.contains(kFakeKey), qPrintable(message));
        }
        // They do say which request failed, with the key masked.
        QVERIFY(std::any_of(loggedMessages().cbegin(), loggedMessages().cend(),
                            [](const QString &message) { return message.contains(QStringLiteral("api_key=***")); }));
    }

    // --- artwork cache --------------------------------------------------

    void onlyPlainTmdbImagePathsAreFetched()
    {
        QVERIFY(artwork_cache::isSafeRemotePath(QStringLiteral("/abc123.jpg")));
        QVERIFY(artwork_cache::isSafeRemotePath(QStringLiteral("/a-b_c.png")));
        QVERIFY(!artwork_cache::isSafeRemotePath(QString()));
        QVERIFY(!artwork_cache::isSafeRemotePath(QStringLiteral("abc.jpg")));
        QVERIFY(!artwork_cache::isSafeRemotePath(QStringLiteral("/../etc/passwd")));
        QVERIFY(!artwork_cache::isSafeRemotePath(QStringLiteral("/a/b.jpg")));
        QVERIFY(!artwork_cache::isSafeRemotePath(QStringLiteral("//evil.example/x.jpg")));
        QVERIFY(!artwork_cache::isSafeRemotePath(QStringLiteral("/x.jpg?api_key=1")));
    }

    void cachedFilesAreNamedAfterTheTmdbIdAndNeverAfterAPath()
    {
        const QString poster = artwork_cache::stem(QStringLiteral("movie"), 603, artwork_cache::Kind::Poster);
        QCOMPARE(poster, QStringLiteral("movie-603-poster"));
        QCOMPARE(artwork_cache::fullFileName(poster), QStringLiteral("movie-603-poster.jpg"));
        QCOMPARE(artwork_cache::thumbnailFileName(poster), QStringLiteral("movie-603-poster-thumb.jpg"));
        // A movie and a show with the same TMDB id never share a file.
        QVERIFY(poster != artwork_cache::stem(QStringLiteral("tv"), 603, artwork_cache::Kind::Poster));
        QCOMPARE(artwork_cache::episodeStillStem(1396, 2, 5), QStringLiteral("tv-1396-s2e5-still"));
    }

    void thePathCheckSeesThroughDotsAndPrefixes()
    {
        const QStringList roots{QStringLiteral("/home/alex/Videos"), QStringLiteral("/Volumes/FixtureDisk/")};
        QVERIFY(artwork_cache::isInsideAny(QStringLiteral("/home/alex/Videos"), roots));
        QVERIFY(artwork_cache::isInsideAny(QStringLiteral("/home/alex/Videos/Film/poster.jpg"), roots));
        QVERIFY(artwork_cache::isInsideAny(QStringLiteral("/Volumes/FixtureDisk/x"), roots));
        QVERIFY(artwork_cache::isInsideAny(QStringLiteral("/home/alex/Videos/../Videos/a"), roots));
        QVERIFY(!artwork_cache::isInsideAny(QStringLiteral("/home/alex/Videos2/a"), roots));
        QVERIFY(!artwork_cache::isInsideAny(QStringLiteral("/home/alex/.cache/Marquee/artwork"), roots));
        QVERIFY(!artwork_cache::isInsideAny(QStringLiteral("/home/alex/Videos/../.cache/x"), roots));
        QVERIFY(!artwork_cache::isInsideAny(QStringLiteral("/tmp/x"), {}));
    }

    void storingAnImageWritesTheFileAndAScaledThumbnail()
    {
        QTemporaryDir cache;
        const QString full = QDir(cache.path()).filePath(QStringLiteral("artwork"));
        const QString thumbs = QDir(cache.path()).filePath(QStringLiteral("thumbnails"));

        const QString name = artwork_cache::store(pngBytes(780, 1170), QStringLiteral("movie-1-poster"),
                                                  artwork_cache::Kind::Poster, full, thumbs);
        QCOMPARE(name, QStringLiteral("movie-1-poster-thumb.jpg"));
        QVERIFY(QFile::exists(QDir(full).filePath(QStringLiteral("movie-1-poster.jpg"))));
        const QImage thumbnail(QDir(thumbs).filePath(name));
        QCOMPARE(thumbnail.width(), 300);
        QCOMPARE(thumbnail.height(), 450);
        // Nothing but the two files, and no half-written leftover.
        QCOMPARE(QDir(full).entryList(QDir::Files).size(), 1);
        QCOMPARE(QDir(thumbs).entryList(QDir::Files).size(), 1);
    }

    void aSmallImageKeepsItsSizeAndBackdropsAreEightHundredWide()
    {
        QTemporaryDir cache;
        const QString full = QDir(cache.path()).filePath(QStringLiteral("a"));
        const QString thumbs = QDir(cache.path()).filePath(QStringLiteral("t"));

        const QString small = artwork_cache::store(pngBytes(100, 150), QStringLiteral("movie-2-poster"),
                                                   artwork_cache::Kind::Poster, full, thumbs);
        QCOMPARE(QImage(QDir(thumbs).filePath(small)).width(), 100);

        const QString wide = artwork_cache::store(pngBytes(1280, 720), QStringLiteral("movie-2-backdrop"),
                                                  artwork_cache::Kind::Backdrop, full, thumbs);
        QCOMPARE(QImage(QDir(thumbs).filePath(wide)).width(), 800);
    }

    void bytesThatAreNotAnImageAreNotCached()
    {
        QTemporaryDir cache;
        const QString full = QDir(cache.path()).filePath(QStringLiteral("a"));
        const QString thumbs = QDir(cache.path()).filePath(QStringLiteral("t"));
        QCOMPARE(artwork_cache::store(QByteArrayLiteral("<html>not an image</html>"),
                                      QStringLiteral("movie-3-poster"), artwork_cache::Kind::Poster,
                                      full, thumbs),
                 QString());
        QVERIFY(!QDir(full).exists() || QDir(full).entryList(QDir::Files).isEmpty());
        QVERIFY(!QDir(thumbs).exists() || QDir(thumbs).entryList(QDir::Files).isEmpty());
    }
};

QTEST_MAIN(MetadataClientTest)
#include "tst_metadata_client.moc"
