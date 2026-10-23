#include <QtTest>

#include <QLocale>

#include <memory>

#include "catalog/MediaItem.hpp"
#include "models/SimilarityIndex.hpp"

namespace
{
[[nodiscard]] MediaItem movie(const QString &title, int year, const QStringList &genres = {})
{
    MediaItem item;
    item.id = QStringLiteral("root/") + title;
    item.relativePath = title + QStringLiteral(".mkv");
    item.title = title;
    item.mediaKind = QStringLiteral("movie");
    item.year = year;
    auto metadata = std::make_shared<TitleMetadata>();
    metadata->tmdbId = 1;
    metadata->genres = genres;
    item.metadata = metadata;
    return item;
}

[[nodiscard]] TitleMetadata &editable(MediaItem &item)
{
    auto copy = std::make_shared<TitleMetadata>(*item.metadata);
    TitleMetadata &ref = *copy;
    item.metadata = std::move(copy);
    return ref;
}

[[nodiscard]] QVector<CastMember> castOf(const QStringList &names)
{
    QVector<CastMember> cast;
    for (const QString &name : names) {
        cast.push_back(CastMember{.name = name, .character = {}, .profilePath = {}, .personId = 1});
    }
    return cast;
}

[[nodiscard]] QStringList titlesOf(const QVector<MediaItem> &items)
{
    QStringList titles;
    for (const MediaItem &item : items) {
        titles.push_back(item.title);
    }
    return titles;
}

[[nodiscard]] QString idOf(const QString &title)
{
    return QStringLiteral("root/") + title;
}
}

class SimilarityIndexTest final : public QObject
{
    Q_OBJECT

private slots:
    void initTestCase()
    {
        QLocale::setDefault(QLocale(QLocale::English, QLocale::UnitedStates));
    }

    // :2381, :2397: fewer than two movies rank nothing, and a movie that shares
    // nothing with the source is not named.
    void aMovieSharingNothingIsNotRanked()
    {
        const QVector<MediaItem> alone{movie(QStringLiteral("Aster"), 2001, {QStringLiteral("Drama")})};
        QVERIFY(browse::SimilarityIndex(alone).rankedMovieIds(idOf(QStringLiteral("Aster"))).isEmpty());

        const QVector<MediaItem> two{movie(QStringLiteral("Aster"), 2001, {QStringLiteral("Drama")}),
                                     movie(QStringLiteral("Bramble"), 2002, {QStringLiteral("Comedy")})};
        QVERIFY(browse::SimilarityIndex(two).rankedMovieIds(idOf(QStringLiteral("Aster"))).isEmpty());
        QVERIFY(browse::SimilarityIndex(two).rankedMovieIds(QStringLiteral("root/Missing")).isEmpty());
    }

    // :2419-2425 (260 and a year bonus), :2427-2430 (150), :2453-2465 (cast
    // up to 240), :2434-2437 (a genre's weight): a franchise beats a director,
    // which beats a cast member, which beats one genre.
    void franchiseThenDirectorThenCastThenGenre()
    {
        MediaItem source = movie(QStringLiteral("Cobalt Run"), 2000, {QStringLiteral("Drama")});
        editable(source).director = QStringLiteral("Dana Fixture");
        editable(source).cast = castOf({QStringLiteral("A One")});

        MediaItem sequel = movie(QStringLiteral("Cobalt Run Again"), 2003);
        MediaItem sameDirector = movie(QStringLiteral("Dune Walker"), 2004);
        editable(sameDirector).director = QStringLiteral("DANA fixture");
        MediaItem sameCast = movie(QStringLiteral("Echo Park"), 2005);
        editable(sameCast).cast = castOf({QStringLiteral("a one")});
        MediaItem sameGenre = movie(QStringLiteral("Fennel"), 2006, {QStringLiteral("Drama")});
        const MediaItem nothing = movie(QStringLiteral("Gravel"), 2007, {QStringLiteral("Comedy")});

        const QVector<MediaItem> movies{nothing, sameGenre, sameCast, sameDirector, sequel, source};
        const browse::SimilarityIndex index(movies);

        QCOMPARE(index.rankedMovieIds(source.id),
                 (QVector<QString>{sequel.id, sameDirector.id, sameCast.id, sameGenre.id}));
    }

    // :2481-2496: a genre few movies share weighs more than one most share.
    void aRarerSharedGenreOutweighsACommonOne()
    {
        const MediaItem source = movie(QStringLiteral("Aster"), 2000,
                                       {QStringLiteral("Drama"), QStringLiteral("Western")});
        const MediaItem commonMatch = movie(QStringLiteral("Bramble"), 2001, {QStringLiteral("Drama")});
        const MediaItem rareMatch = movie(QStringLiteral("Cedar"), 2002, {QStringLiteral("Western")});
        QVector<MediaItem> movies{source, commonMatch, rareMatch};
        for (int index = 0; index < 8; ++index) {
            movies.push_back(movie(QStringLiteral("Filler %1").arg(index), 1990, {QStringLiteral("Drama")}));
        }
        const browse::SimilarityIndex index(movies);

        const QVector<QString> ranked = index.rankedMovieIds(source.id, 3);
        QCOMPARE(ranked.first(), rareMatch.id);
        QVERIFY(ranked.contains(commonMatch.id) || ranked.size() == 3);
    }

    // :2453-2465: a cast member billed higher counts for more than one billed
    // lower, and the sum stops at 240.
    void castCountsByBillingRank()
    {
        MediaItem source = movie(QStringLiteral("Aster"), 2000);
        editable(source).cast = castOf({QStringLiteral("Top Star"), QStringLiteral("Second"),
                                        QStringLiteral("Third"), QStringLiteral("Fourth"),
                                        QStringLiteral("Fifth")});
        MediaItem leads = movie(QStringLiteral("Bramble"), 2001);
        editable(leads).cast = castOf({QStringLiteral("Top Star")});
        MediaItem support = movie(QStringLiteral("Cedar"), 2002);
        editable(support).cast = castOf({QStringLiteral("x1"), QStringLiteral("x2"), QStringLiteral("x3"),
                                         QStringLiteral("x4"), QStringLiteral("Fifth")});

        const browse::SimilarityIndex index({source, support, leads});
        QCOMPARE(index.rankedMovieIds(source.id), (QVector<QString>{leads.id, support.id}));
    }

    // :2467-2479: the share of overview words, by cosine, over words of three
    // letters that are not stopwords.
    void overviewWordsRankWhatSharesMore()
    {
        MediaItem source = movie(QStringLiteral("Aster"), 2000);
        editable(source).overview = QStringLiteral("A lighthouse keeper discovers a smuggler cave");
        MediaItem close = movie(QStringLiteral("Bramble"), 2001);
        editable(close).overview = QStringLiteral("The lighthouse keeper finds a smuggler cave");
        MediaItem loose = movie(QStringLiteral("Cedar"), 2002);
        editable(loose).overview = QStringLiteral("A keeper of bees moves to the city and plants trees");
        MediaItem unrelated = movie(QStringLiteral("Dune"), 2003);
        editable(unrelated).overview = QStringLiteral("Robots race across the desert");

        const browse::SimilarityIndex index({unrelated, loose, close, source});
        QCOMPARE(index.rankedMovieIds(source.id), (QVector<QString>{close.id, loose.id}));
    }

    // :2503-2517: equal scores fall to the rating, then the newest file, then
    // the nearer year.
    void equalScoresFallToRatingThenYearDistance()
    {
        const MediaItem source = movie(QStringLiteral("Aster"), 2000, {QStringLiteral("Drama")});
        MediaItem rated = movie(QStringLiteral("Bramble"), 1960, {QStringLiteral("Drama")});
        editable(rated).voteAverage = 7.0;
        const MediaItem near = movie(QStringLiteral("Cedar"), 1999, {QStringLiteral("Drama")});
        const MediaItem far = movie(QStringLiteral("Dune"), 1950, {QStringLiteral("Drama")});

        // The ratings differ by the quality prior, so the rated one leads; the
        // two unrated ones are decided by the year.
        const browse::SimilarityIndex index({far, near, rated, source});
        QCOMPARE(index.rankedMovieIds(source.id),
                 (QVector<QString>{rated.id, near.id, far.id}));
    }

    // :2351, :2386-2407: the index keeps twelve per movie; the rest come from
    // the older rule (:2165-2170), and the source is never among them.
    void theIndexKeepsTwelveAndTheOlderRuleFillsTheRest()
    {
        QVector<MediaItem> movies;
        for (int index = 0; index < 20; ++index) {
            movies.push_back(movie(QStringLiteral("Film %1").arg(index, 2, 10, QLatin1Char('0')),
                                   1980 + index, {QStringLiteral("Drama")}));
        }
        const browse::SimilarityIndex index(movies);
        const MediaItem &source = movies.first();

        QCOMPARE(index.rankedMovieIds(source.id).size(), 12);
        const QVector<MediaItem> similar = index.similarMovies(source, 30);
        QCOMPARE(similar.size(), 19);
        const QStringList titles = titlesOf(similar);
        QCOMPARE(QSet<QString>(titles.cbegin(), titles.cend()).size(), 19);
        for (const MediaItem &item : similar) {
            QVERIFY(item.id != source.id);
        }
        QCOMPARE(index.similarMovies(source, 5).size(), 5);
        QVERIFY(index.similarMovies(source, 0).isEmpty());
    }

    // :2289-2293: two directors that are present and normalize to the same
    // (here empty) string match in the older rule, +160; an absent one does not.
    void theOlderRuleMatchesDirectorsThatNormalizeToNothing()
    {
        MediaItem source = movie(QStringLiteral("Aster"), 1990, {QStringLiteral("Drama")});
        editable(source).director = QStringLiteral("...");
        MediaItem punctuated = movie(QStringLiteral("Bramble"), 2015, {QStringLiteral("Comedy")});
        editable(punctuated).director = QStringLiteral("!!!");
        MediaItem absent = movie(QStringLiteral("Cedar"), 2016, {QStringLiteral("Comedy")});

        const browse::SimilarityIndex index({absent, punctuated, source});
        QVERIFY(index.rankedMovieIds(source.id).isEmpty());
        QCOMPARE(titlesOf(index.similarMovies(source, 10)), (QStringList{QStringLiteral("Bramble")}));
    }

    // :2265-2311: the older rule scores a shared holiday theme and decade.
    void theOlderRuleKnowsHolidaysAndDecades()
    {
        const MediaItem source = movie(QStringLiteral("Christmas Eve Tale"), 1990);
        const MediaItem holiday = movie(QStringLiteral("Santa Returns"), 1985);
        const MediaItem sameDecade = movie(QStringLiteral("Plain Story"), 1992);
        const MediaItem unrelated = movie(QStringLiteral("Other Tale"), 2015);

        const browse::SimilarityIndex index({unrelated, sameDecade, holiday, source});
        QCOMPARE(titlesOf(index.similarMovies(source, 10)),
                 (QStringList{QStringLiteral("Santa Returns"), QStringLiteral("Plain Story")}));
    }

    // TMDB's stored similar ids are not read by the released index
    // (`movieEdges` is stored and never consulted by the browse code), so
    // naming a library title there changes nothing.
    void tmdbsStoredSimilarIdsDoNotChangeTheRanking()
    {
        const MediaItem plain = movie(QStringLiteral("Aster"), 2000, {QStringLiteral("Drama")});
        MediaItem named = plain;
        editable(named).similarTmdbIds = {42};
        editable(named).recommendedTmdbIds = {42};
        MediaItem target = movie(QStringLiteral("Bramble"), 2001, {QStringLiteral("Comedy")});
        editable(target).tmdbId = 42;

        QVERIFY(browse::SimilarityIndex({named, target}).rankedMovieIds(named.id).isEmpty());
    }
};

QTEST_APPLESS_MAIN(SimilarityIndexTest)
#include "tst_similarity_index.moc"
