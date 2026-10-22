#include <QtTest>

#include <memory>

#include "catalog/MediaItem.hpp"
#include "models/LibraryModel.hpp"
#include "models/ShowsModel.hpp"

namespace
{
[[nodiscard]] std::shared_ptr<const TitleMetadata> sampleMetadata()
{
    auto metadata = std::make_shared<TitleMetadata>();
    metadata->tmdbId = 9001;
    metadata->overview = QStringLiteral("A synthetic crew crosses a synthetic sea.");
    metadata->genres = {QStringLiteral("Adventure"), QStringLiteral("Science Fiction")};
    metadata->cast = {{.name = QStringLiteral("Actor 1"), .character = QStringLiteral("Role 1"),
                       .profilePath = QStringLiteral("/a1.jpg"), .personId = 5001},
                      {.name = QStringLiteral("Actor 2"), .character = QStringLiteral("Role 2"),
                       .profilePath = QString(), .personId = 5002}};
    metadata->director = QStringLiteral("Director One");
    metadata->certification = QStringLiteral("PG-13");
    metadata->voteAverage = 7.4;
    metadata->voteCount = 3120;
    metadata->popularity = 41.5;
    metadata->collectionId = 777;
    metadata->collectionName = QStringLiteral("Synthetic Odyssey Collection");
    metadata->keywords = {{1, QStringLiteral("sea voyage")}, {2, QStringLiteral("crew")}};
    metadata->releaseDate = QStringLiteral("2019-07-12");
    metadata->runtimeMinutes = 128;
    return metadata;
}

[[nodiscard]] MediaItem movie(const QString &id, const QString &title)
{
    MediaItem item;
    item.id = id;
    item.title = title;
    item.mediaKind = QStringLiteral("movie");
    item.relativePath = title + QStringLiteral(".mkv");
    item.year = 2019;
    return item;
}

[[nodiscard]] MediaItem episode(const QString &id, int number)
{
    MediaItem item;
    item.id = id;
    item.title = QStringLiteral("Synthetic Harbor");
    item.showName = QStringLiteral("Synthetic Harbor");
    item.mediaKind = QStringLiteral("episode");
    item.relativePath = QStringLiteral("Synthetic Harbor/Season 1/%1.mkv").arg(id);
    item.seasonNumber = 1;
    item.episodeNumber = number;
    return item;
}

[[nodiscard]] QVariant roleOf(const QAbstractItemModel &model, int row, const QByteArray &name)
{
    const QHash<int, QByteArray> names = model.roleNames();
    for (auto role = names.cbegin(); role != names.cend(); ++role) {
        if (role.value() == name) {
            return model.data(model.index(row, 0), role.key());
        }
    }
    qFatal("no role %s", name.constData());
    return {};
}
}

class MetadataModelsTest final : public QObject
{
    Q_OBJECT

private slots:
    // --- the library model ----------------------------------------------

    void aMatchedMovieExposesEveryStoredFieldAsARole()
    {
        MediaItem matched = movie(QStringLiteral("m1"), QStringLiteral("Synthetic Odyssey"));
        matched.metadata = sampleMetadata();
        LibraryModel model;
        model.replaceItems({matched});

        QCOMPARE(roleOf(model, 0, "hasMetadata").toBool(), true);
        QCOMPARE(roleOf(model, 0, "tmdbId").toInt(), 9001);
        QCOMPARE(roleOf(model, 0, "overview").toString(),
                 QStringLiteral("A synthetic crew crosses a synthetic sea."));
        QCOMPARE(roleOf(model, 0, "director").toString(), QStringLiteral("Director One"));
        QCOMPARE(roleOf(model, 0, "certification").toString(), QStringLiteral("PG-13"));
        QCOMPARE(roleOf(model, 0, "releaseDate").toString(), QStringLiteral("2019-07-12"));
        QCOMPARE(roleOf(model, 0, "voteAverage").toDouble(), 7.4);
        QCOMPARE(roleOf(model, 0, "voteCount").toInt(), 3120);
        QCOMPARE(roleOf(model, 0, "popularity").toDouble(), 41.5);
        QCOMPARE(roleOf(model, 0, "collectionId").toInt(), 777);
        QCOMPARE(roleOf(model, 0, "collectionName").toString(), QStringLiteral("Synthetic Odyssey Collection"));
        QCOMPARE(roleOf(model, 0, "runtimeMinutes").toInt(), 128);
        // TMDB's genres replace the local ones when it named any.
        QCOMPARE(roleOf(model, 0, "genres").toStringList(),
                 (QStringList{QStringLiteral("Adventure"), QStringLiteral("Science Fiction")}));
        QCOMPARE(roleOf(model, 0, "keywords").toStringList(),
                 (QStringList{QStringLiteral("sea voyage"), QStringLiteral("crew")}));
        const QVariantList cast = roleOf(model, 0, "cast").toList();
        QCOMPARE(cast.size(), 2);
        QCOMPARE(cast.at(0).toMap().value(QStringLiteral("name")).toString(), QStringLiteral("Actor 1"));
        QCOMPARE(cast.at(0).toMap().value(QStringLiteral("character")).toString(), QStringLiteral("Role 1"));
        QCOMPARE(cast.at(1).toMap().value(QStringLiteral("personId")).toInt(), 5002);
    }

    void aTitleWithoutMetadataAnswersEmptyAndNullNotZero()
    {
        LibraryModel model;
        model.replaceItems({movie(QStringLiteral("m2"), QStringLiteral("Obscure Nothing"))});

        QCOMPARE(roleOf(model, 0, "hasMetadata").toBool(), false);
        QVERIFY(roleOf(model, 0, "tmdbId").isNull());
        QVERIFY(roleOf(model, 0, "voteAverage").isNull());
        QVERIFY(roleOf(model, 0, "voteCount").isNull());
        QVERIFY(roleOf(model, 0, "popularity").isNull());
        QVERIFY(roleOf(model, 0, "collectionId").isNull());
        QVERIFY(roleOf(model, 0, "runtimeMinutes").isNull());
        QCOMPARE(roleOf(model, 0, "overview").toString(), QString());
        QCOMPARE(roleOf(model, 0, "director").toString(), QString());
        QCOMPARE(roleOf(model, 0, "certification").toString(), QString());
        QVERIFY(roleOf(model, 0, "cast").toList().isEmpty());
        QVERIFY(roleOf(model, 0, "keywords").toStringList().isEmpty());
        QCOMPARE(roleOf(model, 0, "backdropUrl").toUrl(), QUrl());
    }

    void aRatingOfZeroIsNotAnAbsentRating()
    {
        auto metadata = std::make_shared<TitleMetadata>(*sampleMetadata());
        metadata->voteAverage = 0.0;
        metadata->voteCount.reset();
        MediaItem item = movie(QStringLiteral("m3"), QStringLiteral("Unrated Synthetic"));
        item.metadata = metadata;
        LibraryModel model;
        model.replaceItems({item});

        QVERIFY(!roleOf(model, 0, "voteAverage").isNull());
        QCOMPARE(roleOf(model, 0, "voteAverage").toDouble(), 0.0);
        QVERIFY(roleOf(model, 0, "voteCount").isNull());
    }

    void theCardsKeepTheRolesTheyBindToday()
    {
        MediaItem plain = movie(QStringLiteral("m4"), QStringLiteral("Plain Synthetic"));
        LibraryModel model;
        model.replaceItems({plain});
        // The roles the cards bind today are unchanged.
        QCOMPARE(roleOf(model, 0, "mediaId").toString(), QStringLiteral("m4"));
        QCOMPARE(roleOf(model, 0, "title").toString(), QStringLiteral("Plain Synthetic"));
        QCOMPARE(roleOf(model, 0, "formatBadge").toString(), QStringLiteral("MKV"));
        QCOMPARE(roleOf(model, 0, "metadata").toString(), QStringLiteral("2019"));
    }

    void aLocalPosterWinsOverTheCachedTmdbPoster()
    {
        MediaItem both = movie(QStringLiteral("m5"), QStringLiteral("Both Posters"));
        both.posterAbsolutePath = QStringLiteral("/home/alex/Videos/Both Posters/poster.jpg");
        both.tmdbPosterAbsolutePath = QStringLiteral("/home/alex/.cache/Marquee/thumbnails/movie-1-poster-thumb.jpg");
        MediaItem onlyTmdb = movie(QStringLiteral("m6"), QStringLiteral("Only Tmdb"));
        onlyTmdb.tmdbPosterAbsolutePath = both.tmdbPosterAbsolutePath;
        LibraryModel model;
        model.replaceItems({both, onlyTmdb});

        QCOMPARE(roleOf(model, 0, "posterUrl").toUrl(), QUrl::fromLocalFile(both.posterAbsolutePath));
        QCOMPARE(roleOf(model, 1, "posterUrl").toUrl(), QUrl::fromLocalFile(both.tmdbPosterAbsolutePath));
    }

    void detailsCarryTheMetadataBesideTheirOwnKeys()
    {
        MediaItem matched = movie(QStringLiteral("m7"), QStringLiteral("Synthetic Odyssey"));
        matched.metadata = sampleMetadata();
        matched.tmdbBackdropAbsolutePath = QStringLiteral("/home/alex/.cache/Marquee/thumbnails/movie-9001-backdrop-thumb.jpg");
        LibraryModel model;
        model.replaceItems({matched});

        const QVariantMap details = model.detailsForId(QStringLiteral("m7"));
        QCOMPARE(details.value(QStringLiteral("director")).toString(), QStringLiteral("Director One"));
        QCOMPARE(details.value(QStringLiteral("certification")).toString(), QStringLiteral("PG-13"));
        QCOMPARE(details.value(QStringLiteral("cast")).toList().size(), 2);
        QCOMPARE(details.value(QStringLiteral("backdropUrl")).toUrl(),
                 QUrl::fromLocalFile(matched.tmdbBackdropAbsolutePath));
        // The keys the screen binds today keep their meaning.
        QCOMPARE(details.value(QStringLiteral("mediaId")).toString(), QStringLiteral("m7"));
        QCOMPARE(details.value(QStringLiteral("title")).toString(), QStringLiteral("Synthetic Odyssey"));
        QCOMPARE(details.value(QStringLiteral("runtime")).toString(), QString());
    }

    // --- shows ----------------------------------------------------------

    void aShowExposesItsMetadataThroughTheShowDetailsAndEpisodeMaps()
    {
        MediaItem first = episode(QStringLiteral("e1"), 1);
        MediaItem second = episode(QStringLiteral("e2"), 2);
        auto show = std::make_shared<TitleMetadata>();
        show->tmdbId = 9101;
        show->overview = QStringLiteral("Tides, rumors and synthetic ferries.");
        show->genres = {QStringLiteral("Drama")};
        show->director = QStringLiteral("Creator One");
        show->certification = QStringLiteral("TV-MA");
        show->voteAverage = 8.1;
        first.metadata = second.metadata = show;
        first.tmdbBackdropAbsolutePath = second.tmdbBackdropAbsolutePath =
            QStringLiteral("/home/alex/.cache/Marquee/thumbnails/tv-9101-backdrop-thumb.jpg");
        first.tmdbEpisodeTitle = QStringLiteral("Arrivals");
        first.episodeOverview = QStringLiteral("The first ferry.");
        first.episodeVoteAverage = 7.9;
        first.tmdbEpisodeStillAbsolutePath = QStringLiteral("/home/alex/.cache/Marquee/thumbnails/tv-9101-s1e1-still-thumb.jpg");

        ShowsModel shows;
        shows.replaceItems({first, second});
        const QVariantMap details = shows.showDetails(QStringLiteral("Synthetic Harbor"));
        QCOMPARE(details.value(QStringLiteral("overview")).toString(),
                 QStringLiteral("Tides, rumors and synthetic ferries."));
        QCOMPARE(details.value(QStringLiteral("director")).toString(), QStringLiteral("Creator One"));
        QCOMPARE(details.value(QStringLiteral("certification")).toString(), QStringLiteral("TV-MA"));
        QCOMPARE(details.value(QStringLiteral("voteAverage")).toDouble(), 8.1);
        QCOMPARE(details.value(QStringLiteral("displayGenres")).toStringList(), QStringList{QStringLiteral("Drama")});
        QCOMPARE(details.value(QStringLiteral("tmdbBackdropUrl")).toUrl(),
                 QUrl::fromLocalFile(first.tmdbBackdropAbsolutePath));
        // The keys the show page binds today are untouched: no sidecar
        // backdrop, so none.
        QCOMPARE(details.value(QStringLiteral("backdropUrl")).toUrl(), QUrl());
        QCOMPARE(details.value(QStringLiteral("showName")).toString(), QStringLiteral("Synthetic Harbor"));
        QCOMPARE(details.value(QStringLiteral("episodeCount")).toInt(), 2);

        const QVariantList episodes = shows.episodesOf(QStringLiteral("Synthetic Harbor"), 1);
        QCOMPARE(episodes.size(), 2);
        const QVariantMap one = episodes.at(0).toMap();
        QCOMPARE(one.value(QStringLiteral("tmdbTitle")).toString(), QStringLiteral("Arrivals"));
        QCOMPARE(one.value(QStringLiteral("overview")).toString(), QStringLiteral("The first ferry."));
        QCOMPARE(one.value(QStringLiteral("voteAverage")).toDouble(), 7.9);
        QCOMPARE(one.value(QStringLiteral("tmdbStillUrl")).toUrl(),
                 QUrl::fromLocalFile(first.tmdbEpisodeStillAbsolutePath));
        // Today's title and thumbnail keys are what they were.
        QCOMPARE(one.value(QStringLiteral("title")).toString(), QStringLiteral("Episode 1"));
        QCOMPARE(one.value(QStringLiteral("thumbUrl")).toUrl(), QUrl());
        QVERIFY(episodes.at(1).toMap().value(QStringLiteral("voteAverage")).isNull());
    }

    void aShowCardCarriesTheShowsMetadataRoles()
    {
        MediaItem first = episode(QStringLiteral("e1"), 1);
        auto show = std::make_shared<TitleMetadata>();
        show->tmdbId = 9101;
        show->certification = QStringLiteral("TV-14");
        show->genres = {QStringLiteral("Mystery")};
        first.metadata = show;

        ShowsModel shows;
        shows.replaceItems({first, episode(QStringLiteral("e2"), 2)});
        // The first row is the show's genre row; its model lists the show.
        QVERIFY(shows.rowCount() > 0);
        const QVariant rowShows = shows.data(shows.index(0, 0), ShowsModel::ShowsRole);
        auto *row = qobject_cast<ShowRowModel *>(rowShows.value<QObject *>());
        QVERIFY(row != nullptr);
        QCOMPARE(roleOf(*row, 0, "hasMetadata").toBool(), true);
        QCOMPARE(roleOf(*row, 0, "certification").toString(), QStringLiteral("TV-14"));
        QCOMPARE(roleOf(*row, 0, "tmdbId").toInt(), 9101);
        QVERIFY(roleOf(*row, 0, "voteAverage").isNull());
    }
};

QTEST_MAIN(MetadataModelsTest)
#include "tst_metadata_models.moc"
