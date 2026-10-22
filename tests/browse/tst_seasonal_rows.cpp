#include <QtTest>

#include <QLocale>

#include <memory>

#include "catalog/MediaItem.hpp"
#include "models/SeasonalRows.hpp"

namespace
{
// Midday local time: the released app reads the month and day in the viewer's
// own calendar, so a test pins a local date, not a UTC instant.
[[nodiscard]] QDateTime on(int year, int month, int day)
{
    return QDateTime(QDate(year, month, day), QTime(12, 0));
}

[[nodiscard]] MediaItem movie(const QString &title, const QStringList &genres, int year = 2000)
{
    MediaItem item;
    item.id = QStringLiteral("root/") + title;
    item.relativePath = title + QStringLiteral(".mkv");
    item.title = title;
    item.mediaKind = QStringLiteral("movie");
    item.year = year;
    item.modifiedAt = on(2026, 1, 1);
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

[[nodiscard]] const home_rows::IdRow *rowNamed(const QVector<home_rows::IdRow> &rows, const QString &id)
{
    for (const home_rows::IdRow &row : rows) {
        if (row.id == id) {
            return &row;
        }
    }
    return nullptr;
}

[[nodiscard]] QVector<MediaItem> horrorLibrary(int count)
{
    QVector<MediaItem> movies;
    for (int index = 0; index < count; ++index) {
        movies.push_back(movie(QStringLiteral("Dread %1").arg(index, 2, 10, QLatin1Char('0')),
                               {QStringLiteral("Horror")}, 1970 + index));
    }
    return movies;
}
}

class SeasonalRowsTest final : public QObject
{
    Q_OBJECT

private slots:
    void initTestCase()
    {
        QLocale::setDefault(QLocale(QLocale::English, QLocale::UnitedStates));
    }

    // :474-483: October, two horror movies.
    void octoberShowsHorrorOnceTwoMoviesQualify()
    {
        QVector<MediaItem> movies{movie(QStringLiteral("Dread"), {QStringLiteral("Horror")}),
                                  movie(QStringLiteral("Calm"), {QStringLiteral("Drama")})};
        QVERIFY(home_rows::seasonalRows(movies, on(2026, 10, 15)).isEmpty());

        movies.push_back(movie(QStringLiteral("Fright"), {QStringLiteral("horror")}));
        const QVector<home_rows::IdRow> rows = home_rows::seasonalRows(movies, on(2026, 10, 15));
        QCOMPARE(rows.size(), 1);
        QCOMPARE(rows.first().id, QStringLiteral("seasonal-october-horror"));
        QCOMPARE(rows.first().title, QStringLiteral("October Horror"));
        QCOMPARE(QSet<QString>(rows.first().mediaIds.cbegin(), rows.first().mediaIds.cend()),
                 (QSet<QString>{QStringLiteral("root/Dread"), QStringLiteral("root/Fright")}));
    }

    // :474: the month decides, on the first and the last day alike.
    void horrorIsOnlyShownInOctober()
    {
        const QVector<MediaItem> movies = horrorLibrary(4);
        QVERIFY(home_rows::seasonalRows(movies, on(2026, 9, 30)).isEmpty());
        QCOMPARE(home_rows::seasonalRows(movies, on(2026, 10, 1)).size(), 1);
        QCOMPARE(home_rows::seasonalRows(movies, on(2026, 10, 31)).size(), 1);
        QVERIFY(home_rows::seasonalRows(movies, on(2026, 11, 1)).isEmpty());
        QVERIFY(home_rows::seasonalRows(movies, on(2026, 7, 4)).isEmpty());
    }

    // :609-615: containment in the title, the overview or the genres.
    void horrorMatchesHalloweenHauntedAndGhostAnywhere()
    {
        QVERIFY(home_rows::isOctoberHorror(movie(QStringLiteral("Halloween Night"), {})));
        QVERIFY(home_rows::isOctoberHorror(movie(QStringLiteral("Ghostbusters"), {})));
        MediaItem overview = movie(QStringLiteral("Quiet House"), {QStringLiteral("Drama")});
        editable(overview).overview = QStringLiteral("A family moves into a haunted farm.");
        QVERIFY(home_rows::isOctoberHorror(overview));
        QVERIFY(home_rows::isOctoberHorror(movie(QStringLiteral("Anything"), {QStringLiteral("Horror")})));
        QVERIFY(!home_rows::isOctoberHorror(movie(QStringLiteral("Calm"), {QStringLiteral("Comedy")})));
        // The folder name also implies a genre when TMDB names none.
        MediaItem folderGenre = movie(QStringLiteral("Plain"), {});
        folderGenre.metadata.reset();
        folderGenre.relativePath = QStringLiteral("Horror/Plain.mkv");
        QVERIFY(home_rows::isOctoberHorror(folderGenre));
    }

    // :485-494: June to August.
    void summerBlockbustersRunFromJuneToAugust()
    {
        QVector<MediaItem> movies;
        for (int index = 0; index < 3; ++index) {
            MediaItem item = movie(QStringLiteral("Epic %1").arg(index), {QStringLiteral("Action")});
            editable(item).voteCount = 500;
            movies.push_back(item);
        }
        QVERIFY(home_rows::seasonalRows(movies, on(2026, 5, 31)).isEmpty());
        for (const int month : {6, 7, 8}) {
            const QVector<home_rows::IdRow> rows = home_rows::seasonalRows(movies, on(2026, month, 10));
            QCOMPARE(rows.size(), 1);
            QCOMPARE(rows.first().id, QStringLiteral("seasonal-summer-blockbusters"));
            QCOMPARE(rows.first().title, QStringLiteral("Summer Blockbusters"));
            QCOMPARE(rows.first().mediaIds.size(), 3);
        }
        QVERIFY(home_rows::seasonalRows(movies, on(2026, 9, 1)).isEmpty());
    }

    // :617-627: one of the genres, and 100 votes, popularity 10 or a 7.0 rating.
    void aBlockbusterNeedsAGenreAndVotesPopularityOrRating()
    {
        const auto candidate = [](const QStringList &genres, int votes, double popularity, double rating) {
            MediaItem item = movie(QStringLiteral("Epic"), genres);
            editable(item).voteCount = votes;
            editable(item).popularity = popularity;
            editable(item).voteAverage = rating;
            return item;
        };
        const QStringList action{QStringLiteral("Action")};
        QVERIFY(home_rows::isSummerBlockbuster(candidate(action, 100, 0, 0)));
        QVERIFY(!home_rows::isSummerBlockbuster(candidate(action, 99, 9.9, 6.9)));
        QVERIFY(home_rows::isSummerBlockbuster(candidate(action, 0, 10, 0)));
        QVERIFY(home_rows::isSummerBlockbuster(candidate(action, 0, 0, 7.0)));
        for (const QString &genre : {QStringLiteral("Adventure"), QStringLiteral("Science Fiction"),
                                     QStringLiteral("Sci-Fi"), QStringLiteral("Fantasy")}) {
            QVERIFY2(home_rows::isSummerBlockbuster(candidate({genre}, 500, 0, 0)), qPrintable(genre));
        }
        QVERIFY(!home_rows::isSummerBlockbuster(candidate({QStringLiteral("Drama")}, 500, 50, 9)));
        // A title with no metadata has none of the three signals.
        MediaItem bare = movie(QStringLiteral("Epic"), {});
        bare.metadata.reset();
        bare.relativePath = QStringLiteral("Action/Epic.mkv");
        QVERIFY(!home_rows::isSummerBlockbuster(bare));
    }

    // :591-607: the stronger title leads; the weaker are shuffled by the day.
    void aBetterRatedMovieLeadsAndTheRestShuffleByTheDay()
    {
        QVector<MediaItem> movies = horrorLibrary(12);
        editable(movies[7]).voteAverage = 9.0;

        const QDateTime day = on(2026, 10, 15);
        const QStringList first = home_rows::seasonalRows(movies, day).first().mediaIds;
        QCOMPARE(first.size(), 12);
        QCOMPARE(first.first(), movies.at(7).id);

        // The same day is the same order, however often the row is built.
        QCOMPARE(home_rows::seasonalRows(movies, on(2026, 10, 15)).first().mediaIds, first);
        QCOMPARE(home_rows::seasonalRows(movies, QDateTime(QDate(2026, 10, 15), QTime(23, 59))).first().mediaIds,
                 first);
        // Another day mixes the equally strong titles another way.
        const QStringList next = home_rows::seasonalRows(movies, on(2026, 10, 16)).first().mediaIds;
        QCOMPARE(next.first(), movies.at(7).id);
        QVERIFY(next != first);
        QCOMPARE(QSet<QString>(next.cbegin(), next.cend()), QSet<QString>(first.cbegin(), first.cend()));
    }

    // :591-593, :684-694: the order depends on the date alone, not on when the
    // library was listed.
    void theOrderDoesNotDependOnTheOrderOfTheLibrary()
    {
        QVector<MediaItem> movies = horrorLibrary(8);
        QVector<MediaItem> reversed;
        for (auto it = movies.crbegin(); it != movies.crend(); ++it) {
            reversed.push_back(*it);
        }
        QCOMPARE(home_rows::seasonalRows(reversed, on(2026, 10, 15)).first().mediaIds,
                 home_rows::seasonalRows(movies, on(2026, 10, 15)).first().mediaIds);
    }

    void anEmptyLibraryHasNoSeasonalRow()
    {
        QVERIFY(home_rows::seasonalRows({}, on(2026, 10, 15)).isEmpty());
    }

    // :2103-2121.
    void heroScoreCountsRatingArtworkLengthAndFreshness()
    {
        MediaItem item = movie(QStringLiteral("Epic"), {});
        QCOMPARE(home_rows::heroScore(item, -1), 0.0);
        editable(item).voteAverage = 7.5;
        item.tmdbBackdropAbsolutePath = QStringLiteral("/cache/b.jpg");
        item.posterAbsolutePath = QStringLiteral("/lib/p.jpg");
        QCOMPARE(home_rows::heroScore(item, -1), 750.0 + 180.0 + 50.0);
        item.durationSeconds = 5'000;
        QCOMPARE(home_rows::heroScore(item, -1), 750.0 + 180.0 + 50.0 + 30.0);
        item.durationSeconds = 600;
        QCOMPARE(home_rows::heroScore(item, -1), 750.0 + 180.0 + 50.0 - 180.0);
        // Thirty days older than the newest file loses all seventy.
        const qint64 month = 30LL * 24 * 60 * 60 * 1000;
        QCOMPARE(home_rows::heroScore(item, item.modifiedAt.toMSecsSinceEpoch() + month),
                 750.0 + 180.0 + 50.0 - 180.0);
        QCOMPARE(home_rows::heroScore(item, item.modifiedAt.toMSecsSinceEpoch()),
                 750.0 + 180.0 + 50.0 - 180.0 + 70.0);
    }
};

QTEST_APPLESS_MAIN(SeasonalRowsTest)
#include "tst_seasonal_rows.moc"
