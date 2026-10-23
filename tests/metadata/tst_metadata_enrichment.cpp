#include <QBuffer>
#include <QDir>
#include <QDirIterator>
#include <QEventLoop>
#include <QFile>
#include <QImage>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSignalSpy>
#include <QSqlDatabase>
#include <QSqlQuery>
#include <QTemporaryDir>
#include <QThread>
#include <QTimeZone>
#include <QtTest>

#include <atomic>
#include <memory>

#include "catalog/CatalogDatabase.hpp"
#include "catalog/CatalogStore.hpp"
#include "catalog/CatalogWorker.hpp"
#include "catalog/LibraryScanner.hpp"
#include "metadata/MetadataEnrichment.hpp"
#include "metadata/MetadataSwitch.hpp"

#include "FakeTransport.hpp"

namespace
{
const QString kFakeKey = QStringLiteral("fake-key-0123456789abcdef");

[[nodiscard]] QByteArray fixture(const QString &name)
{
    QFile file(QDir(QStringLiteral(MARQUEE_METADATA_FIXTURES)).filePath(name));
    if (!file.open(QIODevice::ReadOnly)) {
        qFatal("missing fixture %s", qPrintable(name));
    }
    return file.readAll();
}

[[nodiscard]] QByteArray png()
{
    QImage image(1000, 600, QImage::Format_RGB32);
    image.fill(Qt::darkGreen);
    QByteArray bytes;
    QBuffer buffer(&bytes);
    buffer.open(QIODevice::WriteOnly);
    image.save(&buffer, "PNG");
    return bytes;
}

[[nodiscard]] bool writeFile(const QString &root, const QString &relativePath,
                             const QByteArray &contents = QByteArrayLiteral("media"))
{
    const QFileInfo target(QDir(root).filePath(relativePath));
    if (!QDir().mkpath(target.absolutePath())) {
        return false;
    }
    QFile file(target.absoluteFilePath());
    return file.open(QIODevice::WriteOnly) && file.write(contents) == contents.size();
}

[[nodiscard]] QByteArray searchAnswer(int id, const QString &titleKey, const QString &title)
{
    return QJsonDocument(QJsonObject{
                             {QStringLiteral("results"),
                              QJsonArray{QJsonObject{{QStringLiteral("id"), id}, {titleKey, title}}}}})
        .toJson();
}

// What TMDB answers for the synthetic library below.
[[nodiscard]] HttpReply tmdbAnswer(const QUrl &url)
{
    const QString path = url.path();
    const QString query = FakeTransport::queryValue(url, QStringLiteral("query"));
    if (url.host() == QLatin1String("image.tmdb.org")) {
        return FakeTransport::json(png());
    }
    if (FakeTransport::queryValue(url, QStringLiteral("api_key")) != kFakeKey) {
        return FakeTransport::status(401);
    }
    if (path == QLatin1String("/3/search/movie")) {
        if (query == QLatin1String("Synthetic Odyssey")) {
            return FakeTransport::json(searchAnswer(9001, QStringLiteral("title"), query.toUtf8()));
        }
        if (query == QLatin1String("Bare Synthetic")) {
            return FakeTransport::json(searchAnswer(9010, QStringLiteral("title"), query.toUtf8()));
        }
        return FakeTransport::json(QByteArrayLiteral(R"({"results":[]})"));
    }
    if (path == QLatin1String("/3/movie/9001")) {
        return FakeTransport::json(fixture(QStringLiteral("movie_with_collection.json")));
    }
    if (path == QLatin1String("/3/movie/9010")) {
        return FakeTransport::json(fixture(QStringLiteral("movie_bare.json")));
    }
    if (path == QLatin1String("/3/search/tv")) {
        return query == QLatin1String("Synthetic Harbor")
            ? FakeTransport::json(searchAnswer(9101, QStringLiteral("name"), query.toUtf8()))
            : FakeTransport::json(QByteArrayLiteral(R"({"results":[]})"));
    }
    if (path == QLatin1String("/3/tv/9101")) {
        return FakeTransport::json(fixture(QStringLiteral("tv_show.json")));
    }
    if (path == QLatin1String("/3/tv/9101/season/1")) {
        return FakeTransport::json(fixture(QStringLiteral("tv_season_1.json")));
    }
    return FakeTransport::status(404);
}

// A movies root holding two films and a TV root holding one show of two
// episodes, plus one title TMDB has never heard of.
struct Library
{
    QTemporaryDir moviesRoot;
    QTemporaryDir tvRoot;
    QTemporaryDir dataRoot;
    QTemporaryDir cacheRoot;

    QString catalogPath() const { return QDir(dataRoot.path()).filePath(QStringLiteral("catalog.sqlite")); }
    MetadataStore::CacheDirectories cache() const
    {
        return {.fullDirectory = QDir(cacheRoot.path()).filePath(QStringLiteral("artwork")),
                .thumbnailDirectory = QDir(cacheRoot.path()).filePath(QStringLiteral("thumbnails"))};
    }
    LibraryRootPaths roots() const { return {.movies = {moviesRoot.path()}, .tvShows = {tvRoot.path()}}; }
    QStringList rootList() const { return {moviesRoot.path(), tvRoot.path()}; }

    bool build(bool withPosterSidecar = false)
    {
        if (!writeFile(moviesRoot.path(), QStringLiteral("Synthetic Odyssey (2019)/Synthetic Odyssey (2019).mkv"))
            || !writeFile(moviesRoot.path(), QStringLiteral("Bare Synthetic (2021)/Bare Synthetic (2021).mkv"))
            || !writeFile(moviesRoot.path(), QStringLiteral("Obscure Nothing (2010)/Obscure Nothing (2010).mkv"))
            || !writeFile(tvRoot.path(), QStringLiteral("Synthetic Harbor (2015)/Season 1/Synthetic Harbor - S01E01 - Arrivals.mkv"))
            || !writeFile(tvRoot.path(), QStringLiteral("Synthetic Harbor (2015)/Season 1/Synthetic Harbor - S01E02 - Fog.mkv"))) {
            return false;
        }
        if (withPosterSidecar
            && !writeFile(moviesRoot.path(), QStringLiteral("Synthetic Odyssey (2019)/poster.jpg"), png())) {
            return false;
        }
        CatalogDatabase database(catalogPath());
        database.migrate({QStringLiteral("main")});
        scan();
        return true;
    }

    void scan()
    {
        CatalogStore store(catalogPath());
        for (const LibraryRoot &root : store.registerRoots(roots())) {
            store.applyScan(root, LibraryScanner::scan(root));
        }
    }

    QVector<MediaItem> projection()
    {
        CatalogStore store(catalogPath());
        store.setMetadataCache(cache());
        const QVector<LibraryRoot> known = store.registerRoots(roots());
        return store.projection(known);
    }

    MediaItem movie(const QString &title)
    {
        for (const MediaItem &item : projection()) {
            if (item.isMovie() && item.title == title) {
                return item;
            }
        }
        return {};
    }

    MediaItem episode(int number)
    {
        for (const MediaItem &item : projection()) {
            if (item.isEpisode() && item.episodeNumber == number) {
                return item;
            }
        }
        return {};
    }
};

struct Setup
{
    QDateTime clock{QDateTime(QDate(2026, 1, 1), QTime(12, 0), QTimeZone::UTC)};
    QString key{kFakeKey};
    bool allowed{true};
};

[[nodiscard]] MetadataSetup makeSetup(Library &library, const std::shared_ptr<FakeTransport> &transport,
                                      const std::shared_ptr<Setup> &state)
{
    MetadataSetup setup;
    setup.transportFactory = [transport] {
        // A thin forwarder, so one fake can outlive the enrichment that used it
        // and a restart sees the requests of the run before.
        struct Forward final : HttpTransport
        {
            std::shared_ptr<FakeTransport> target;
            void get(const QUrl &url, std::function<void(HttpReply)> done) override
            {
                target->get(url, std::move(done));
            }
        };
        auto forward = std::make_unique<Forward>();
        forward->target = transport;
        return forward;
    };
    setup.keyProvider = [state] { return state->key; };
    setup.allowed = [state] { return state->allowed; };
    setup.now = [state] { return state->clock; };
    setup.cache = library.cache();
    setup.minRequestIntervalMs = 0;
    return setup;
}

[[nodiscard]] MetadataEnrichment::Summary runOnce(MetadataEnrichment &enrichment,
                                                  const QStringList &roots)
{
    QSignalSpy finished(&enrichment, &MetadataEnrichment::finished);
    enrichment.start(roots);
    // A run with nothing to do ends inside start().
    if (finished.isEmpty() && !finished.wait(15'000)) {
        qFatal("the run did not finish");
    }
    return qvariant_cast<MetadataEnrichment::Summary>(finished.first().first());
}

// Runs SQL against the catalog the way an older build left it.
[[nodiscard]] bool sql(const QString &catalogPath, const QString &statement)
{
    CatalogDatabase database(catalogPath);
    QSqlQuery query(database.connection());
    return query.exec(statement);
}

[[nodiscard]] QVariant scalar(const QString &catalogPath, const QString &statement)
{
    CatalogDatabase database(catalogPath);
    QSqlQuery query(database.connection());
    return query.exec(statement) && query.next() ? query.value(0) : QVariant();
}

[[nodiscard]] int filesUnder(const QString &directory)
{
    int count = 0;
    QDirIterator files(directory, QDir::Files, QDirIterator::Subdirectories);
    while (files.hasNext()) {
        files.next();
        ++count;
    }
    return count;
}
}

class MetadataEnrichmentTest final : public QObject
{
    Q_OBJECT

    std::shared_ptr<FakeTransport> m_transport;
    std::shared_ptr<Setup> m_state;

    void resetFakes()
    {
        m_transport = std::make_shared<FakeTransport>(tmdbAnswer);
        m_state = std::make_shared<Setup>();
    }

private slots:
    void init() { resetFakes(); }
    void cleanup() { metadata_switch::setEnabled(true); }

    void aRunFillsTheCatalogWithWhatTmdbSays()
    {
        Library library;
        QVERIFY(library.build());
        MetadataEnrichment enrichment(library.catalogPath(), makeSetup(library, m_transport, m_state));

        const auto summary = runOnce(enrichment, library.rootList());
        QCOMPARE(summary.outcome, MetadataEnrichment::Outcome::Finished);
        QCOMPARE(summary.titlesSaved, 3);       // two films and the show
        QCOMPARE(summary.titlesUnmatched, 1);   // the film TMDB has no record of
        QCOMPARE(summary.episodesSaved, 2);

        const MediaItem odyssey = library.movie(QStringLiteral("Synthetic Odyssey"));
        QVERIFY(odyssey.metadata);
        QCOMPARE(odyssey.metadata->tmdbId, 9001);
        QCOMPARE(odyssey.metadata->director, QStringLiteral("Director One"));
        QCOMPARE(odyssey.metadata->certification, QStringLiteral("PG-13"));
        QCOMPARE(odyssey.metadata->voteAverage, std::optional<double>(7.4));
        QCOMPARE(odyssey.metadata->voteCount, std::optional<int>(3120));
        QCOMPARE(odyssey.metadata->popularity, std::optional<double>(41.5));
        QCOMPARE(odyssey.metadata->collectionId, std::optional<int>(777));
        QCOMPARE(odyssey.metadata->collectionName, QStringLiteral("Synthetic Odyssey Collection"));
        QCOMPARE(odyssey.metadata->runtimeMinutes, 128);
        QCOMPARE(odyssey.metadata->genres,
                 (QStringList{QStringLiteral("Adventure"), QStringLiteral("Science Fiction")}));
        QCOMPARE(odyssey.metadata->cast.size(), 8);
        QCOMPARE(odyssey.metadata->cast.first().name, QStringLiteral("Actor 1"));
        QCOMPARE(odyssey.metadata->keywords.size(), 2);
        QCOMPARE(odyssey.metadata->similarTmdbIds, (QVector<int>{9002, 9003}));
        QCOMPARE(odyssey.metadata->overview, QStringLiteral("A synthetic crew crosses a synthetic sea."));
        QCOMPARE(odyssey.metadata->releaseDate, QStringLiteral("2019-07-12"));

        // The title TMDB could not match has no metadata and still browses.
        const MediaItem obscure = library.movie(QStringLiteral("Obscure Nothing"));
        QVERIFY(!obscure.id.isEmpty());
        QVERIFY(!obscure.metadata);

        // Both episodes carry the show's metadata, shared.
        QVector<MediaItem> episodes;
        for (const MediaItem &item : library.projection()) {
            if (item.isEpisode()) {
                episodes.push_back(item);
            }
        }
        QCOMPARE(episodes.size(), 2);
        const MediaItem &first = episodes.at(0).episodeNumber == 1 ? episodes.at(0) : episodes.at(1);
        const MediaItem &second = episodes.at(0).episodeNumber == 1 ? episodes.at(1) : episodes.at(0);
        QVERIFY(first.metadata && second.metadata);
        QCOMPARE(first.metadata.get(), second.metadata.get());
        QCOMPARE(first.metadata->director, QStringLiteral("Creator One"));
        QCOMPARE(first.metadata->certification, QStringLiteral("TV-MA"));
        QCOMPARE(first.tmdbEpisodeTitle, QStringLiteral("Arrivals"));
        QCOMPARE(first.episodeOverview, QStringLiteral("The first ferry."));
        QCOMPARE(first.episodeVoteAverage, std::optional<double>(7.9));
        QCOMPARE(second.tmdbEpisodeTitle, QStringLiteral("Fog"));
    }

    void artworkFillsAGapInTheAppCacheAndNeverWritesIntoALibraryRoot()
    {
        Library library;
        QVERIFY(library.build());
        const int moviesBefore = filesUnder(library.moviesRoot.path());
        const int tvBefore = filesUnder(library.tvRoot.path());
        MetadataEnrichment enrichment(library.catalogPath(), makeSetup(library, m_transport, m_state));
        QVERIFY(runOnce(enrichment, library.rootList()).imagesCached >= 5);

        const MediaItem odyssey = library.movie(QStringLiteral("Synthetic Odyssey"));
        QVERIFY(odyssey.posterAbsolutePath.isEmpty());
        QVERIFY2(!odyssey.tmdbPosterAbsolutePath.isEmpty(), "the film has no folder poster");
        QVERIFY(QFile::exists(odyssey.tmdbPosterAbsolutePath));
        QVERIFY(QFile::exists(odyssey.tmdbBackdropAbsolutePath));
        QCOMPARE(odyssey.displayPosterPath(), odyssey.tmdbPosterAbsolutePath);
        QCOMPARE(odyssey.displayBackdropPath(), odyssey.tmdbBackdropAbsolutePath);

        const MediaItem episode = library.episode(1);
        QVERIFY(QFile::exists(episode.tmdbEpisodeStillAbsolutePath));
        QVERIFY(QFile::exists(episode.tmdbPosterAbsolutePath));

        // Every cached file is under the cache directory, and nothing at all
        // was added beside the media.
        const QStringList cached{odyssey.tmdbPosterAbsolutePath, odyssey.tmdbBackdropAbsolutePath,
                                 episode.tmdbEpisodeStillAbsolutePath};
        for (const QString &path : cached) {
            QVERIFY2(path.startsWith(library.cacheRoot.path()), qPrintable(path));
            QVERIFY2(!path.startsWith(library.moviesRoot.path()) && !path.startsWith(library.tvRoot.path()),
                     qPrintable(path));
        }
        QCOMPARE(filesUnder(library.moviesRoot.path()), moviesBefore);
        QCOMPARE(filesUnder(library.tvRoot.path()), tvBefore);
    }

    void aLocalSidecarPosterWinsAndIsNotDownloadedOver()
    {
        Library library;
        QVERIFY(library.build(true));
        MetadataEnrichment enrichment(library.catalogPath(), makeSetup(library, m_transport, m_state));
        (void)runOnce(enrichment, library.rootList());

        const MediaItem odyssey = library.movie(QStringLiteral("Synthetic Odyssey"));
        QVERIFY(odyssey.posterAbsolutePath.endsWith(QStringLiteral("poster.jpg")));
        QVERIFY(odyssey.tmdbPosterAbsolutePath.isEmpty());
        QCOMPARE(odyssey.displayPosterPath(), odyssey.posterAbsolutePath);
        // The backdrop has no sidecar, so TMDB's fills it.
        QVERIFY(!odyssey.tmdbBackdropAbsolutePath.isEmpty());
        // The poster image was never requested for that film.
        for (const QUrl &url : m_transport->urls()) {
            QVERIFY2(!(url.host() == QLatin1String("image.tmdb.org") && url.path().contains(QLatin1String("synthPoster"))),
                     qPrintable(url.toString()));
        }
    }

    void aTitleAlreadyFetchedIsNotAskedAgain()
    {
        Library library;
        QVERIFY(library.build());
        {
            MetadataEnrichment first(library.catalogPath(), makeSetup(library, m_transport, m_state));
            QCOMPARE(runOnce(first, library.rootList()).outcome, MetadataEnrichment::Outcome::Finished);
        }
        const int requestsAfterFirst = m_transport->count();
        QVERIFY(requestsAfterFirst > 0);

        // A new process: a new object, the same catalog.
        MetadataEnrichment second(library.catalogPath(), makeSetup(library, m_transport, m_state));
        const auto summary = runOnce(second, library.rootList());
        QCOMPARE(summary.outcome, MetadataEnrichment::Outcome::UpToDate);
        QCOMPARE(m_transport->count(), requestsAfterFirst);
    }

    void aRunCutShortResumesWhereItStoppedAfterARestart()
    {
        Library library;
        QVERIFY(library.build());

        // The network drops after the first film's details and its images.
        std::atomic<int> served{0};
        m_transport->setResponder([&served](const QUrl &url) {
            return ++served > 4 ? FakeTransport::offline() : tmdbAnswer(url);
        });
        {
            MetadataEnrichment first(library.catalogPath(), makeSetup(library, m_transport, m_state));
            const auto summary = runOnce(first, library.rootList());
            QCOMPARE(summary.outcome, MetadataEnrichment::Outcome::Interrupted);
            QVERIFY(summary.titlesSaved >= 1);
            QVERIFY(summary.titlesSaved < 3);
        }
        const int saved = [&library] {
            int count = 0;
            for (const MediaItem &item : library.projection()) {
                count += item.metadata && item.isMovie() ? 1 : 0;
            }
            return count;
        }();
        QVERIFY(saved >= 1);
        QVERIFY(!library.episode(1).metadata);

        // The network is back and the app has been restarted.
        m_transport->setResponder(tmdbAnswer);
        const QList<QUrl> before = m_transport->urls();
        MetadataEnrichment second(library.catalogPath(), makeSetup(library, m_transport, m_state));
        QCOMPARE(runOnce(second, library.rootList()).outcome, MetadataEnrichment::Outcome::Finished);

        QVERIFY(library.episode(1).metadata);
        QVERIFY(library.movie(QStringLiteral("Bare Synthetic")).metadata);
        // The details of a title saved before the cut were not fetched again.
        QList<QUrl> after = m_transport->urls();
        after = after.mid(before.size());
        int movie9001Requests = 0;
        for (const QUrl &url : std::as_const(after)) {
            movie9001Requests += url.path() == QLatin1String("/3/movie/9001") ? 1 : 0;
        }
        QVERIFY(movie9001Requests <= 1);
        const QList<QUrl> firstRunDetails = before;
        int totalDetails = 0;
        for (const QUrl &url : m_transport->urls()) {
            totalDetails += url.path() == QLatin1String("/3/movie/9001") ? 1 : 0;
        }
        Q_UNUSED(firstRunDetails);
        QCOMPARE(totalDetails, 1);
    }

    void withNoNetworkTheAppWorksAsBeforeAndStoresNothing()
    {
        Library library;
        QVERIFY(library.build());
        m_transport->setResponder([](const QUrl &) { return FakeTransport::offline(); });
        MetadataEnrichment enrichment(library.catalogPath(), makeSetup(library, m_transport, m_state));

        const auto summary = runOnce(enrichment, library.rootList());
        QCOMPARE(summary.outcome, MetadataEnrichment::Outcome::Interrupted);
        QCOMPARE(summary.titlesSaved, 0);
        // The run stopped at the first failure instead of working through the
        // whole library against a dead network.
        QCOMPARE(m_transport->count(), 1);

        const QVector<MediaItem> items = library.projection();
        QCOMPARE(items.size(), 5);
        for (const MediaItem &item : items) {
            QVERIFY(!item.metadata);
        }

        // Nothing was recorded as tried, so the next run asks again.
        m_transport->setResponder(tmdbAnswer);
        MetadataEnrichment later(library.catalogPath(), makeSetup(library, m_transport, m_state));
        QCOMPARE(runOnce(later, library.rootList()).outcome, MetadataEnrichment::Outcome::Finished);
        QVERIFY(library.movie(QStringLiteral("Synthetic Odyssey")).metadata);
    }

    void withNoKeyNothingIsRequested()
    {
        Library library;
        QVERIFY(library.build());
        m_state->key.clear();
        MetadataEnrichment enrichment(library.catalogPath(), makeSetup(library, m_transport, m_state));

        QCOMPARE(runOnce(enrichment, library.rootList()).outcome, MetadataEnrichment::Outcome::Disabled);
        QCOMPARE(m_transport->count(), 0);
        QVERIFY(!library.movie(QStringLiteral("Synthetic Odyssey")).metadata);

        // A key added later is picked up by the next run.
        m_state->key = kFakeKey;
        QCOMPARE(runOnce(enrichment, library.rootList()).outcome, MetadataEnrichment::Outcome::Finished);
        QVERIFY(library.movie(QStringLiteral("Synthetic Odyssey")).metadata);
    }

    void aRefusedKeyEndsTheRunAtOnceAndLeavesTheCatalogAlone()
    {
        Library library;
        QVERIFY(library.build());
        m_state->key = QStringLiteral("a-different-fake-key");
        MetadataEnrichment enrichment(library.catalogPath(), makeSetup(library, m_transport, m_state));

        QCOMPARE(runOnce(enrichment, library.rootList()).outcome, MetadataEnrichment::Outcome::Interrupted);
        QCOMPARE(m_transport->count(), 1);
        QVERIFY(!library.movie(QStringLiteral("Synthetic Odyssey")).metadata);
    }

    void theSwitchOffFromTheStartRequestsNothing()
    {
        Library library;
        QVERIFY(library.build());
        m_state->allowed = false;
        MetadataEnrichment enrichment(library.catalogPath(), makeSetup(library, m_transport, m_state));

        QCOMPARE(runOnce(enrichment, library.rootList()).outcome, MetadataEnrichment::Outcome::Disabled);
        QCOMPARE(m_transport->count(), 0);
    }

    void turningTheSwitchOffMidRunStopsBeforeTheNextRequest()
    {
        Library library;
        QVERIFY(library.build());
        // The viewer turns the switch off while the first film's details are
        // being answered.
        m_transport->setResponder([this](const QUrl &url) {
            if (url.path() == QLatin1String("/3/movie/9010") || url.path() == QLatin1String("/3/movie/9001")) {
                m_state->allowed = false;
            }
            return tmdbAnswer(url);
        });
        MetadataEnrichment enrichment(library.catalogPath(), makeSetup(library, m_transport, m_state));

        const auto summary = runOnce(enrichment, library.rootList());
        QCOMPARE(summary.outcome, MetadataEnrichment::Outcome::Stopped);
        const int requestsWhenStopped = m_transport->count();
        QTest::qWait(50);
        QCOMPARE(m_transport->count(), requestsWhenStopped);
        QVERIFY(summary.titlesSaved <= 1);

        // Turned back on, the rest is filled in and the first is not repeated.
        m_state->allowed = true;
        m_transport->setResponder(tmdbAnswer);
        MetadataEnrichment again(library.catalogPath(), makeSetup(library, m_transport, m_state));
        QCOMPARE(runOnce(again, library.rootList()).outcome, MetadataEnrichment::Outcome::Finished);
        QVERIFY(library.episode(1).metadata);
    }

    void aTitleTmdbCouldNotMatchWaitsAWeekBeforeItIsTriedAgain()
    {
        Library library;
        QVERIFY(library.build());
        {
            MetadataEnrichment first(library.catalogPath(), makeSetup(library, m_transport, m_state));
            (void)runOnce(first, library.rootList());
        }
        const auto searchesFor = [this](const QString &title) {
            int count = 0;
            for (const QUrl &url : m_transport->urls()) {
                count += url.path() == QLatin1String("/3/search/movie")
                        && FakeTransport::queryValue(url, QStringLiteral("query")) == title
                    ? 1
                    : 0;
            }
            return count;
        };
        // Once, then once more without the year for the near-year pass.
        const int firstRunSearches = searchesFor(QStringLiteral("Obscure Nothing"));
        QCOMPARE(firstRunSearches, 2);

        m_state->clock = m_state->clock.addDays(3);
        {
            MetadataEnrichment second(library.catalogPath(), makeSetup(library, m_transport, m_state));
            QCOMPARE(runOnce(second, library.rootList()).outcome, MetadataEnrichment::Outcome::UpToDate);
        }
        QCOMPARE(searchesFor(QStringLiteral("Obscure Nothing")), firstRunSearches);

        m_state->clock = m_state->clock.addDays(5);
        {
            MetadataEnrichment third(library.catalogPath(), makeSetup(library, m_transport, m_state));
            (void)runOnce(third, library.rootList());
        }
        QCOMPARE(searchesFor(QStringLiteral("Obscure Nothing")), 2 * firstRunSearches);
    }

    void rowsAnOlderMatcherWroteAreMatchedAgainAndOnlyAChangedMatchReplacesTheData()
    {
        Library library;
        QVERIFY(library.build());
        {
            MetadataEnrichment first(library.catalogPath(), makeSetup(library, m_transport, m_state));
            (void)runOnce(first, library.rootList());
        }
        const QString odysseyId = library.movie(QStringLiteral("Synthetic Odyssey")).id;
        const QString bareId = library.movie(QStringLiteral("Bare Synthetic")).id;
        QVERIFY(!odysseyId.isEmpty() && !bareId.isEmpty());

        // The catalog as an older matcher left it: Bare Synthetic matched to
        // the wrong film with that film's cast and keywords, Odyssey matched
        // right with data that must survive, and Obscure Nothing unmatched.
        const QString path = library.catalogPath();
        QVERIFY(sql(path, QStringLiteral("UPDATE title_metadata SET matcher_version = 0")));
        // The rows were written long ago, outside any retry wait.
        m_state->clock = m_state->clock.addDays(2);
        QVERIFY(sql(path, QStringLiteral("UPDATE title_metadata SET tmdb_id = 123, "
                                         "overview = 'Wrong film', fetched_at = '2020-01-01T00:00:00.000Z' "
                                         "WHERE owner_key = '%1'").arg(bareId)));
        QVERIFY(sql(path, QStringLiteral("INSERT INTO title_cast (owner_key, ordinal, person_id, name, character) "
                                         "VALUES ('%1', 0, 1, 'Wrong Actor', 'Wrong')").arg(bareId)));
        QVERIFY(sql(path, QStringLiteral("INSERT INTO title_keyword (owner_key, keyword_id, name) "
                                         "VALUES ('%1', 1, 'wrong')").arg(bareId)));
        QVERIFY(sql(path, QStringLiteral("UPDATE title_metadata SET overview = 'Kept as it was' "
                                         "WHERE owner_key = '%1'").arg(odysseyId)));

        m_transport->setResponder([](const QUrl &url) {
            // Obscure Nothing is now findable.
            if (url.path() == QLatin1String("/3/search/movie")
                && FakeTransport::queryValue(url, QStringLiteral("query")) == QLatin1String("Obscure Nothing")) {
                return FakeTransport::json(searchAnswer(9010, QStringLiteral("title"), QStringLiteral("Obscure Nothing")));
            }
            return tmdbAnswer(url);
        });
        const int requestsBefore = m_transport->count();

        MetadataEnrichment second(path, makeSetup(library, m_transport, m_state));
        const auto summary = runOnce(second, library.rootList());
        QCOMPARE(summary.outcome, MetadataEnrichment::Outcome::Finished);

        // The changed match replaced the data, cast and keywords.
        const MediaItem bare = library.movie(QStringLiteral("Bare Synthetic"));
        QVERIFY(bare.metadata);
        QCOMPARE(bare.metadata->tmdbId, 9010);
        QVERIFY(bare.metadata->overview != QLatin1String("Wrong film"));
        for (const CastMember &member : bare.metadata->cast) {
            QVERIFY(member.name != QLatin1String("Wrong Actor"));
        }
        QCOMPARE(scalar(path, QStringLiteral("SELECT COUNT(*) FROM title_keyword WHERE name = 'wrong'")).toInt(), 0);

        // The unchanged match kept its data and was not fetched again.
        QCOMPARE(library.movie(QStringLiteral("Synthetic Odyssey")).metadata->overview,
                 QStringLiteral("Kept as it was"));
        for (qsizetype index = requestsBefore; index < m_transport->count(); ++index) {
            QVERIFY2(m_transport->urls().at(index).path() != QLatin1String("/3/movie/9001"),
                     "an unchanged match must not fetch its details again");
        }

        // Nor were its images (already cached) asked for again.
        for (qsizetype index = requestsBefore; index < m_transport->count(); ++index) {
            QVERIFY2(m_transport->urls().at(index).host() != QLatin1String("image.tmdb.org"),
                     "an unchanged match must not download its images again");
        }

        // The title the old rules missed is matched now.
        const MediaItem obscure = library.movie(QStringLiteral("Obscure Nothing"));
        QVERIFY(obscure.metadata);
        QCOMPARE(obscure.metadata->tmdbId, 9010);

        // Everything carries the current matcher version, so a third run
        // has nothing to do.
        QCOMPARE(scalar(path, QStringLiteral("SELECT COUNT(*) FROM title_metadata WHERE matcher_version < %1")
                                  .arg(MetadataStore::matcherVersion)).toInt(), 0);
        MetadataEnrichment third(path, makeSetup(library, m_transport, m_state));
        QCOMPARE(runOnce(third, library.rootList()).outcome, MetadataEnrichment::Outcome::UpToDate);
    }

    void aRematchThatFindsNothingKeepsTheOldMatchAndCountsItAsChecked()
    {
        Library library;
        QVERIFY(library.build());
        {
            MetadataEnrichment first(library.catalogPath(), makeSetup(library, m_transport, m_state));
            (void)runOnce(first, library.rootList());
        }
        const QString path = library.catalogPath();
        QVERIFY(sql(path, QStringLiteral("UPDATE title_metadata SET matcher_version = 0")));
        // The rows were written long ago, outside any retry wait.
        m_state->clock = m_state->clock.addDays(2);
        // Obscure Nothing was once matched by an older matcher whose details
        // then failed: it keeps that matcher's id with the state failed.
        QVERIFY(sql(path, QStringLiteral("UPDATE title_metadata SET fetch_state = 'failed', tmdb_id = 123 "
                                         "WHERE owner_key = (SELECT id FROM media_items WHERE title = 'Obscure Nothing')")));
        // TMDB answers nothing for any search now.
        m_transport->setResponder([](const QUrl &url) {
            if (url.path().startsWith(QLatin1String("/3/search/"))) {
                return FakeTransport::json(QByteArrayLiteral(R"({"results":[]})"));
            }
            return tmdbAnswer(url);
        });
        MetadataEnrichment second(path, makeSetup(library, m_transport, m_state));
        (void)runOnce(second, library.rootList());
        QVERIFY(library.movie(QStringLiteral("Synthetic Odyssey")).metadata);
        QCOMPARE(scalar(path, QStringLiteral("SELECT COUNT(*) FROM title_metadata WHERE matcher_version = 0")).toInt(), 0);
        // The id the older matcher gave is gone, or the retry would go
        // straight to that title.
        QCOMPARE(scalar(path, QStringLiteral("SELECT fetch_state FROM title_metadata WHERE owner_key = "
                                             "(SELECT id FROM media_items WHERE title = 'Obscure Nothing')"))
                     .toString(),
                 QStringLiteral("unmatched"));
        QVERIFY(scalar(path, QStringLiteral("SELECT tmdb_id FROM title_metadata WHERE owner_key = "
                                            "(SELECT id FROM media_items WHERE title = 'Obscure Nothing')"))
                    .isNull());
    }

    void aShowMatchedToAnotherShowByAnOlderMatcherLosesItsEpisodeFacts()
    {
        Library library;
        QVERIFY(library.build());
        {
            MetadataEnrichment first(library.catalogPath(), makeSetup(library, m_transport, m_state));
            (void)runOnce(first, library.rootList());
        }
        const QString path = library.catalogPath();
        const QString showKey = QStringLiteral("show:Synthetic Harbor|2015");
        QVERIFY(sql(path, QStringLiteral("UPDATE title_metadata SET matcher_version = 0")));
        // The rows were written long ago, outside any retry wait.
        m_state->clock = m_state->clock.addDays(2);
        QVERIFY(sql(path, QStringLiteral("UPDATE title_metadata SET tmdb_id = 555, overview = 'Wrong show' "
                                         "WHERE owner_key = '%1'").arg(showKey)));
        QVERIFY(sql(path, QStringLiteral("UPDATE episode_metadata SET title = 'Wrong episode', "
                                         "overview = 'Wrong'")));

        MetadataEnrichment second(path, makeSetup(library, m_transport, m_state));
        (void)runOnce(second, library.rootList());
        QCOMPARE(library.episode(1).tmdbEpisodeTitle, QStringLiteral("Arrivals"));
        QCOMPARE(library.episode(1).metadata->tmdbId, 9101);
    }

    void aChangedShowLosesItsOldEpisodeFactsEvenWhenTheNewOnesCannotBeFetched()
    {
        Library library;
        QVERIFY(library.build());
        {
            MetadataEnrichment first(library.catalogPath(), makeSetup(library, m_transport, m_state));
            (void)runOnce(first, library.rootList());
        }
        const QString path = library.catalogPath();
        QVERIFY(sql(path, QStringLiteral("UPDATE title_metadata SET matcher_version = 0")));
        // The rows were written long ago, outside any retry wait.
        m_state->clock = m_state->clock.addDays(2);
        QVERIFY(sql(path, QStringLiteral("UPDATE title_metadata SET tmdb_id = 555 WHERE owner_key = '%1'")
                              .arg(QStringLiteral("show:Synthetic Harbor|2015"))));
        QVERIFY(sql(path, QStringLiteral("UPDATE episode_metadata SET title = 'Wrong episode', "
                                         "overview = 'Wrong'")));
        QCOMPARE(scalar(path, QStringLiteral("SELECT COUNT(*) FROM episode_metadata")).toInt(), 2);

        // TMDB's season answer is refused, so the run ends after the show
        // was saved and the episodes were not.
        m_transport->setResponder([](const QUrl &url) {
            if (url.path() == QLatin1String("/3/tv/9101/season/1")) {
                return FakeTransport::status(401);
            }
            return tmdbAnswer(url);
        });
        MetadataEnrichment second(path, makeSetup(library, m_transport, m_state));
        QCOMPARE(runOnce(second, library.rootList()).outcome, MetadataEnrichment::Outcome::Interrupted);

        // The other show's episode facts are gone, not left under the new
        // show for the next run to trust.
        QCOMPARE(scalar(path, QStringLiteral("SELECT tmdb_id FROM title_metadata WHERE owner_key = '%1'")
                                  .arg(QStringLiteral("show:Synthetic Harbor|2015"))).toInt(), 9101);
        QCOMPARE(scalar(path, QStringLiteral("SELECT COUNT(*) FROM episode_metadata WHERE title = 'Wrong episode'"))
                     .toInt(), 0);
    }

    // After an upgrade every row an older matcher wrote is stale, including
    // the ones fetched in the last day; none of them has been rematched, so
    // none waits.
    void aRowFetchedLessThanADayAgoByAnOlderMatcherIsMatchedAgain()
    {
        Library library;
        QVERIFY(library.build());
        {
            MetadataEnrichment first(library.catalogPath(), makeSetup(library, m_transport, m_state));
            (void)runOnce(first, library.rootList());
        }
        const QString path = library.catalogPath();
        const QString bareId = library.movie(QStringLiteral("Bare Synthetic")).id;
        QVERIFY(sql(path, QStringLiteral("UPDATE title_metadata SET matcher_version = 0")));
        // Fetched an hour ago, well inside the failed-retry wait.
        m_state->clock = m_state->clock.addSecs(3600);
        QVERIFY(sql(path, QStringLiteral("UPDATE title_metadata SET tmdb_id = 123, overview = 'Wrong film' "
                                         "WHERE owner_key = '%1'").arg(bareId)));

        const auto searches = [this] {
            int count = 0;
            for (const QUrl &url : m_transport->urls()) {
                if (url.path() == QLatin1String("/3/search/movie")
                    && FakeTransport::queryValue(url, QStringLiteral("query")) == QLatin1String("Bare Synthetic")) {
                    ++count;
                }
            }
            return count;
        };
        const int before = searches();
        MetadataEnrichment second(path, makeSetup(library, m_transport, m_state));
        (void)runOnce(second, library.rootList());
        QCOMPARE(searches(), before + 1);
        QVERIFY(library.movie(QStringLiteral("Bare Synthetic")).metadata->overview
                != QLatin1String("Wrong film"));
    }

    void aRematchWhoseDetailsFailKeepsTheOldMatchAndWaitsADayBeforeTryingAgain()
    {
        Library library;
        QVERIFY(library.build());
        {
            MetadataEnrichment first(library.catalogPath(), makeSetup(library, m_transport, m_state));
            (void)runOnce(first, library.rootList());
        }
        const QString path = library.catalogPath();
        const QString bareId = library.movie(QStringLiteral("Bare Synthetic")).id;
        // Bare Synthetic was matched to another film by an older matcher.
        QVERIFY(sql(path, QStringLiteral("UPDATE title_metadata SET matcher_version = 0")));
        // The rows were written long ago, outside any retry wait.
        m_state->clock = m_state->clock.addDays(2);
        QVERIFY(sql(path, QStringLiteral("UPDATE title_metadata SET tmdb_id = 123, overview = 'Wrong film' "
                                         "WHERE owner_key = '%1'").arg(bareId)));

        // The search now finds the right film, whose details TMDB cannot give.
        m_transport->setResponder([](const QUrl &url) {
            if (url.path() == QLatin1String("/3/movie/9010")) {
                return FakeTransport::status(404);
            }
            return tmdbAnswer(url);
        });
        const auto searches = [this] {
            int count = 0;
            for (const QUrl &url : m_transport->urls()) {
                if (url.path() == QLatin1String("/3/search/movie")
                    && FakeTransport::queryValue(url, QStringLiteral("query")) == QLatin1String("Bare Synthetic")) {
                    ++count;
                }
            }
            return count;
        };
        const int before = searches();
        {
            MetadataEnrichment second(path, makeSetup(library, m_transport, m_state));
            (void)runOnce(second, library.rootList());
        }
        QCOMPARE(searches(), before + 1);
        // The old match stays, and the attempt is on record.
        QCOMPARE(scalar(path, QStringLiteral("SELECT overview FROM title_metadata WHERE owner_key = '%1'")
                                  .arg(bareId)).toString(), QStringLiteral("Wrong film"));
        QCOMPARE(scalar(path, QStringLiteral("SELECT rematch_attempted_at FROM title_metadata WHERE owner_key = '%1'")
                                  .arg(bareId)).toString(),
                 QStringLiteral("2026-01-03T12:00:00.000Z"));
        // When the stored data was fetched does not move with the attempt.
        QCOMPARE(scalar(path, QStringLiteral("SELECT fetched_at FROM title_metadata WHERE owner_key = '%1'")
                                  .arg(bareId)).toString(),
                 QStringLiteral("2026-01-01T12:00:00.000Z"));

        // Within the day it is not asked again, after it is.
        m_state->clock = m_state->clock.addSecs(3600);
        {
            MetadataEnrichment third(path, makeSetup(library, m_transport, m_state));
            (void)runOnce(third, library.rootList());
        }
        QCOMPARE(searches(), before + 1);
        m_state->clock = m_state->clock.addDays(2);
        {
            MetadataEnrichment fourth(path, makeSetup(library, m_transport, m_state));
            (void)runOnce(fourth, library.rootList());
        }
        QCOMPARE(searches(), before + 2);
    }

    void aMalformedSearchAnswerCountsAsFailedAndIsStoredAsFailed()
    {
        Library library;
        QVERIFY(library.build());
        m_transport->setResponder([](const QUrl &url) {
            if (url.path() == QLatin1String("/3/search/movie")) {
                return FakeTransport::json("not json at all");
            }
            return tmdbAnswer(url);
        });
        MetadataEnrichment enrichment(library.catalogPath(), makeSetup(library, m_transport, m_state));
        const auto summary = runOnce(enrichment, library.rootList());
        QCOMPARE(summary.titlesFailed, 3);
        QCOMPARE(summary.titlesUnmatched, 0);
        QCOMPARE(scalar(library.catalogPath(),
                        QStringLiteral("SELECT COUNT(*) FROM title_metadata WHERE fetch_state = 'failed'")).toInt(), 3);
    }

    void anImageThatFailedToDecodeIsAskedForAgainWithoutAskingAboutTheTitle()
    {
        Library library;
        QVERIFY(library.build());
        // Images come back as an error page.
        m_transport->setResponder([](const QUrl &url) {
            return url.host() == QLatin1String("image.tmdb.org")
                ? FakeTransport::json(QByteArrayLiteral("<html>oops</html>"))
                : tmdbAnswer(url);
        });
        {
            MetadataEnrichment first(library.catalogPath(), makeSetup(library, m_transport, m_state));
            QCOMPARE(runOnce(first, library.rootList()).imagesCached, 0);
        }
        QVERIFY(library.movie(QStringLiteral("Synthetic Odyssey")).metadata);
        QVERIFY(library.movie(QStringLiteral("Synthetic Odyssey")).tmdbPosterAbsolutePath.isEmpty());

        m_transport->setResponder(tmdbAnswer);
        const int before = m_transport->count();
        MetadataEnrichment second(library.catalogPath(), makeSetup(library, m_transport, m_state));
        const auto summary = runOnce(second, library.rootList());
        QVERIFY(summary.imagesCached >= 3);
        QVERIFY(!library.movie(QStringLiteral("Synthetic Odyssey")).tmdbPosterAbsolutePath.isEmpty());
        // Only images and, for the show, its episodes' missing stills: no
        // search and no details were repeated for a fetched title.
        const QList<QUrl> retried = m_transport->urls().mid(before);
        for (const QUrl &url : retried) {
            QVERIFY2(url.host() == QLatin1String("image.tmdb.org"), qPrintable(url.toString()));
        }
    }

    void anArtworkCacheUnderALibraryRootIsNeverWrittenTo()
    {
        Library library;
        QVERIFY(library.build());
        MetadataSetup setup = makeSetup(library, m_transport, m_state);
        // A misconfigured cache inside the movies root.
        setup.cache = {.fullDirectory = QDir(library.moviesRoot.path()).filePath(QStringLiteral(".cache/a")),
                       .thumbnailDirectory = QDir(library.moviesRoot.path()).filePath(QStringLiteral(".cache/t"))};
        const int before = filesUnder(library.moviesRoot.path());
        MetadataEnrichment enrichment(library.catalogPath(), setup);

        const auto summary = runOnce(enrichment, library.rootList());
        QCOMPARE(summary.outcome, MetadataEnrichment::Outcome::Finished);
        QCOMPARE(summary.imagesCached, 0);
        QCOMPARE(filesUnder(library.moviesRoot.path()), before);
        QVERIFY(!QDir(QDir(library.moviesRoot.path()).filePath(QStringLiteral(".cache"))).exists());
        // The text facts still arrive.
        QVERIFY(library.movie(QStringLiteral("Synthetic Odyssey")).metadata);
        for (const QUrl &url : m_transport->urls()) {
            QVERIFY2(url.host() != QLatin1String("image.tmdb.org"), qPrintable(url.toString()));
        }
    }

    void aShowIsMatchedOnceAndEachSeasonAskedForOnce()
    {
        Library library;
        QVERIFY(library.build());
        MetadataEnrichment enrichment(library.catalogPath(), makeSetup(library, m_transport, m_state));
        (void)runOnce(enrichment, library.rootList());

        QCOMPARE(m_transport->countContaining(QStringLiteral("/3/search/tv")), 1);
        QCOMPARE(m_transport->countContaining(QStringLiteral("/3/tv/9101/season/1")), 1);
        QCOMPARE(m_transport->countContaining(QStringLiteral("/3/tv/9101")), 2);  // details + season
    }

    void aFileRemovedMidRunDoesNotFailTheRun()
    {
        Library library;
        QVERIFY(library.build());
        // The first episode's file disappears and a scan drops its row while
        // the run is talking to TMDB.
        m_transport->setResponder([&library](const QUrl &url) {
            if (url.path() == QLatin1String("/3/tv/9101/season/1")) {
                QFile::remove(QDir(library.tvRoot.path())
                                  .filePath(QStringLiteral("Synthetic Harbor (2015)/Season 1/Synthetic Harbor - S01E01 - Arrivals.mkv")));
                library.scan();
            }
            return tmdbAnswer(url);
        });
        MetadataEnrichment enrichment(library.catalogPath(), makeSetup(library, m_transport, m_state));
        const auto summary = runOnce(enrichment, library.rootList());
        QCOMPARE(summary.outcome, MetadataEnrichment::Outcome::Finished);
        QVERIFY(library.episode(2).metadata);
        QVERIFY(library.episode(1).id.isEmpty());
    }

    void theBackgroundRunNeverTouchesTheNetworkOnTheGuiThread()
    {
        Library library;
        QVERIFY(library.build());
        qRegisterMetaType<LibraryRootPaths>();
        qRegisterMetaType<QVector<MediaItem>>();

        auto *thread = new QThread;
        MetadataSetup setup = makeSetup(library, m_transport, m_state);
        auto *worker = new CatalogWorker(library.catalogPath(), setup);
        worker->moveToThread(thread);
        connect(thread, &QThread::finished, worker, &QObject::deleteLater);
        QSignalSpy projections(worker, &CatalogWorker::projectionReloaded);
        QSignalSpy ready(worker, &CatalogWorker::projectionReady);
        QSignalSpy finished(worker, &CatalogWorker::metadataRunFinished);
        thread->start();

        QMetaObject::invokeMethod(worker, [worker, &library] {
            worker->refresh(library.roots(), QStringLiteral("main"));
        });
        QTRY_VERIFY_WITH_TIMEOUT(!finished.isEmpty(), 20'000);

        // The library was on screen before any of it was fetched.
        QCOMPARE(ready.size(), 1);
        const auto firstProjection = ready.first().first().value<QVector<MediaItem>>();
        for (const MediaItem &item : firstProjection) {
            QVERIFY(!item.metadata);
        }
        // Then it was reloaded with what TMDB said.
        QVERIFY(!projections.isEmpty());
        const auto reloaded = projections.last().first().value<QVector<MediaItem>>();
        int withMetadata = 0;
        for (const MediaItem &item : reloaded) {
            withMetadata += item.metadata ? 1 : 0;
        }
        QVERIFY(withMetadata >= 4);

        QVERIFY(m_transport->count() > 0);
        for (QThread *requestThread : m_transport->threads()) {
            QVERIFY(requestThread != QThread::currentThread());
            QCOMPARE(requestThread, thread);
        }

        QMetaObject::invokeMethod(worker, &CatalogWorker::shutdown);
        QVERIFY(thread->wait(10'000));
        delete thread;
    }

    void theSwitchTurnedOnAfterAScanFillsInWhatIsMissing()
    {
        Library library;
        QVERIFY(library.build());
        m_state->allowed = false;
        qRegisterMetaType<LibraryRootPaths>();
        qRegisterMetaType<QVector<MediaItem>>();
        qRegisterMetaType<MetadataEnrichment::Summary>();

        auto *thread = new QThread;
        auto *worker = new CatalogWorker(library.catalogPath(), makeSetup(library, m_transport, m_state));
        worker->moveToThread(thread);
        connect(thread, &QThread::finished, worker, &QObject::deleteLater);
        QSignalSpy ready(worker, &CatalogWorker::projectionReady);
        QSignalSpy finished(worker, &CatalogWorker::metadataRunFinished);
        thread->start();

        QMetaObject::invokeMethod(worker, [worker, &library] {
            worker->refresh(library.roots(), QStringLiteral("main"));
        });
        QTRY_VERIFY_WITH_TIMEOUT(!finished.isEmpty(), 10'000);
        QCOMPARE(qvariant_cast<MetadataEnrichment::Summary>(finished.last().first()).outcome,
                 MetadataEnrichment::Outcome::Disabled);
        QCOMPARE(m_transport->count(), 0);

        // The Settings switch is turned on.
        m_state->allowed = true;
        metadata_switch::setEnabled(false);
        metadata_switch::setEnabled(true);
        QTRY_VERIFY_WITH_TIMEOUT(finished.size() >= 2, 20'000);
        QCOMPARE(qvariant_cast<MetadataEnrichment::Summary>(finished.last().first()).outcome,
                 MetadataEnrichment::Outcome::Finished);
        QVERIFY(library.movie(QStringLiteral("Synthetic Odyssey")).metadata);

        QMetaObject::invokeMethod(worker, &CatalogWorker::shutdown);
        QVERIFY(thread->wait(10'000));
        delete thread;
    }
};

QTEST_MAIN(MetadataEnrichmentTest)
#include "tst_metadata_enrichment.moc"
