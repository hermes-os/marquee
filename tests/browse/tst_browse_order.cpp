#include <QtTest>

#include <memory>

#include "catalog/MediaItem.hpp"
#include "models/BrowseSemantics.hpp"
#include "models/LibraryModel.hpp"
#include "models/MovieRowsModel.hpp"
#include "models/ShowsModel.hpp"

namespace
{
[[nodiscard]] MediaItem movie(const QString &title, int year, const QString &folder = QString())
{
    MediaItem item;
    item.id = QStringLiteral("root-1/") + title + QString::number(year);
    item.libraryRootId = QStringLiteral("root-1");
    item.relativePath = (folder.isEmpty() ? QString() : folder + QLatin1Char('/')) + title
        + QStringLiteral(".mkv");
    item.absolutePath = QStringLiteral("/library/") + item.relativePath;
    item.title = title;
    item.mediaKind = QStringLiteral("movie");
    item.year = year;
    return item;
}

[[nodiscard]] MediaItem withMetadata(MediaItem item,
                                     const QStringList &genres,
                                     const QString &overview = QString(),
                                     const QString &releaseDate = QString())
{
    auto metadata = std::make_shared<TitleMetadata>();
    metadata->tmdbId = 1;
    metadata->genres = genres;
    metadata->overview = overview;
    metadata->releaseDate = releaseDate;
    item.metadata = metadata;
    return item;
}

[[nodiscard]] MediaItem episode(const QString &show, int season, int number)
{
    MediaItem item;
    item.id = QStringLiteral("root-1/%1/S%2E%3").arg(show).arg(season).arg(number);
    item.libraryRootId = QStringLiteral("root-1");
    item.relativePath = QStringLiteral("%1/Season %2/%1 - S%2E%3.mkv").arg(show).arg(season).arg(number);
    item.absolutePath = QStringLiteral("/library/") + item.relativePath;
    item.title = show;
    item.mediaKind = QStringLiteral("episode");
    item.showName = show;
    item.seasonNumber = season;
    item.episodeNumber = number;
    return item;
}

[[nodiscard]] QStringList titlesOf(const QVector<MediaItem> &items)
{
    QStringList titles;
    for (const MediaItem &item : items) {
        titles.push_back(item.title);
    }
    return titles;
}

[[nodiscard]] QStringList titlesIn(const LibraryModel *items)
{
    QStringList titles;
    for (int row = 0; row < items->rowCount(); ++row) {
        titles.push_back(items->data(items->index(row, 0), LibraryModel::TitleRole).toString());
    }
    return titles;
}

[[nodiscard]] QStringList rowIds(const MovieRowsModel &rows)
{
    QStringList ids;
    for (int row = 0; row < rows.rowCount(); ++row) {
        ids.push_back(rows.data(rows.index(row, 0), MovieRowsModel::RowIdRole).toString());
    }
    return ids;
}

[[nodiscard]] const LibraryModel *itemsOfRow(const MovieRowsModel &rows, int row)
{
    return qobject_cast<const LibraryModel *>(
        rows.data(rows.index(row, 0), MovieRowsModel::ItemsRole).value<QAbstractItemModel *>());
}

[[nodiscard]] const LibraryModel *rowNamed(const MovieRowsModel &rows, const QString &id)
{
    for (int row = 0; row < rows.rowCount(); ++row) {
        if (rows.data(rows.index(row, 0), MovieRowsModel::RowIdRole).toString() == id) {
            return itemsOfRow(rows, row);
        }
    }
    return nullptr;
}

[[nodiscard]] QStringList showNamesIn(ShowRowModel *row)
{
    QStringList names;
    for (int column = 0; column < row->rowCount(); ++column) {
        names.push_back(row->showNameAt(column));
    }
    return names;
}
}

class BrowseOrderTest final : public QObject
{
    Q_OBJECT

private slots:
    // BrowseSnapshotStore.swift:2034-2042: family, then year, then title.
    void moviesSortByFamilyThenYearThenTitleWithAnUndatedTitleLast()
    {
        const QVector<MediaItem> sorted = browse::sortedMoviesForBrowsing(
            {movie(QStringLiteral("Star Wars Return of the Jedi"), 1983),
             movie(QStringLiteral("Arrival"), 2016),
             movie(QStringLiteral("Star Wars A New Hope"), 1977),
             movie(QStringLiteral("Star Wars Undated"), 0),
             movie(QStringLiteral("alien"), 1979),
             movie(QStringLiteral("Zodiac"), 2007)});

        // "alien", "arrival" and "zodiac" stand on their own title (a leading
        // token of five letters or more is its own family); the Star Wars
        // titles share one family and sort by year with the undated one last.
        QCOMPARE(titlesOf(sorted),
                 (QStringList{QStringLiteral("alien"), QStringLiteral("Arrival"),
                              QStringLiteral("Star Wars A New Hope"),
                              QStringLiteral("Star Wars Return of the Jedi"),
                              QStringLiteral("Star Wars Undated"), QStringLiteral("Zodiac")}));
    }

    void aFamilyOfTwoShortTokensKeepsItsInstallmentsTogetherByYear()
    {
        const QVector<MediaItem> sorted = browse::sortedMoviesForBrowsing(
            {movie(QStringLiteral("Mad Max Fury Road"), 2015),
             movie(QStringLiteral("Mad Max"), 1979),
             movie(QStringLiteral("Mad Dog"), 2001),
             movie(QStringLiteral("Mad Max 2"), 1981)});

        QCOMPARE(titlesOf(sorted),
                 (QStringList{QStringLiteral("Mad Dog"), QStringLiteral("Mad Max"),
                              QStringLiteral("Mad Max 2"),
                              QStringLiteral("Mad Max Fury Road")}));
    }

    void equalKeysKeepTheCatalogOrder()
    {
        MediaItem first = movie(QStringLiteral("Heat"), 1995);
        first.id = QStringLiteral("b");
        MediaItem second = movie(QStringLiteral("Heat"), 1995);
        second.id = QStringLiteral("a");
        const QVector<MediaItem> sorted = browse::sortedMoviesForBrowsing({first, second});
        QCOMPARE(sorted.at(0).id, QStringLiteral("b"));
        QCOMPARE(sorted.at(1).id, QStringLiteral("a"));
    }

    // BrowseSnapshotStore.swift:660-665.
    void franchiseOrderReadsTheReleaseDateThenTheYearThenBrowseOrder()
    {
        const MediaItem late = withMetadata(movie(QStringLiteral("Star Wars Two"), 1980),
                                            {}, {}, QStringLiteral("1980-05-21"));
        const MediaItem early = withMetadata(movie(QStringLiteral("Star Wars One"), 1990),
                                             {}, {}, QStringLiteral("1977-05-25"));
        // The title sorts "One" before "Two" either way; the release date
        // overrides the file's year.
        QVERIFY(browse::compareFranchiseOrder(early, late));
        QVERIFY(!browse::compareFranchiseOrder(late, early));

        // With no metadata the year stands in, and browse order breaks a tie.
        QVERIFY(browse::compareFranchiseOrder(movie(QStringLiteral("Star Wars One"), 1977),
                                              movie(QStringLiteral("Star Wars Two"), 1980)));
        QVERIFY(browse::compareFranchiseOrder(movie(QStringLiteral("Star Wars One"), 1977),
                                              movie(QStringLiteral("Star Wars Two"), 1977)));
        // A title with no date at all sorts first, as the empty string does.
        QVERIFY(browse::compareFranchiseOrder(movie(QStringLiteral("Star Wars Zero"), 0),
                                              movie(QStringLiteral("Star Wars One"), 1977)));
    }

    // BrowseSnapshotStore.swift:3008-3048.
    void movieRowsKeyOnTmdbGenresAndSkipOtherAndTheGenreHoldingEveryMovie()
    {
        MovieRowsModel rows;
        rows.replaceItems(
            {withMetadata(movie(QStringLiteral("Arrival"), 2016),
                          {QStringLiteral("Drama"), QStringLiteral("Science Fiction")}),
             withMetadata(movie(QStringLiteral("Moon"), 2009),
                          {QStringLiteral("Science Fiction"), QStringLiteral("Drama")}),
             withMetadata(movie(QStringLiteral("Alien"), 1979),
                          {QStringLiteral("horror"), QStringLiteral("Drama")}),
             movie(QStringLiteral("Untagged Piece"), 2001)}); // no genre: "Other"

        // "Drama" holds three of four, so it keeps its row; "Other" has none.
        QCOMPARE(rowIds(rows),
                 (QStringList{QStringLiteral("genre-Drama"), QStringLiteral("genre-horror"),
                              QStringLiteral("genre-Science Fiction"),
                              QStringLiteral("all-movies")}));
        QCOMPARE(titlesIn(rowNamed(rows, QStringLiteral("genre-Drama"))),
                 (QStringList{QStringLiteral("Alien"), QStringLiteral("Arrival"),
                              QStringLiteral("Moon")}));
        QCOMPARE(titlesIn(rowNamed(rows, QStringLiteral("all-movies"))).size(), 4);
    }

    void aGenreHoldingEveryMovieGetsNoRow()
    {
        MovieRowsModel rows;
        rows.replaceItems(
            {withMetadata(movie(QStringLiteral("Arrival"), 2016),
                          {QStringLiteral("Drama"), QStringLiteral("Mystery")}),
             withMetadata(movie(QStringLiteral("Moon"), 2009), {QStringLiteral("Drama")})});

        QCOMPARE(rowIds(rows),
                 (QStringList{QStringLiteral("genre-Mystery"), QStringLiteral("all-movies")}));
    }

    void tmdbGenresReplaceTheFolderGenreAndTheTitleInference()
    {
        // Frozen is inferred as Animation/Music/Holiday from its title, and
        // sits in a Drama folder; TMDB's list replaces both.
        MovieRowsModel rows;
        rows.replaceItems(
            {withMetadata(movie(QStringLiteral("Frozen"), 2013, QStringLiteral("Drama")),
                          {QStringLiteral("Adventure")}),
             withMetadata(movie(QStringLiteral("Heat"), 1995), {QStringLiteral("Crime")})});

        QCOMPARE(rowIds(rows),
                 (QStringList{QStringLiteral("genre-Adventure"), QStringLiteral("genre-Crime"),
                              QStringLiteral("all-movies")}));
    }

    void withNoMetadataTheFolderGenreStillGroupsTitles()
    {
        MovieRowsModel rows;
        rows.replaceItems({movie(QStringLiteral("Heat"), 1995, QStringLiteral("Crime")),
                           movie(QStringLiteral("Ronin"), 1998, QStringLiteral("Crime")),
                           movie(QStringLiteral("Paddington"), 2014)});
        QCOMPARE(rowIds(rows),
                 (QStringList{QStringLiteral("genre-Comedy"), QStringLiteral("genre-Crime"),
                              QStringLiteral("all-movies")}));
    }

    // BrowseSnapshotStore.swift:2073-2101.
    void holidayScoreReadsTheGenresAndTheOverviewAsWellAsTheTitle()
    {
        QCOMPARE(browse::holidayScore(movie(QStringLiteral("Arrival"), 2016)), 0);
        // No genre, keyword or overview names the season: only the title list.
        QCOMPARE(browse::holidayScore(movie(QStringLiteral("Scrooged"), 1988)), 86);
        // Elf and Frozen infer the Holiday genre offline, which :2077 reads.
        QCOMPARE(browse::holidayScore(movie(QStringLiteral("Elf"), 2003)), 100);
        QCOMPARE(browse::holidayScore(movie(QStringLiteral("Frozen"), 2013)), 100);
        QCOMPARE(browse::holidayScore(withMetadata(movie(QStringLiteral("Arrival"), 2016),
                                                   {QStringLiteral("Holiday")})),
                 100);
        QCOMPARE(browse::holidayScore(withMetadata(movie(QStringLiteral("Arrival"), 2016), {},
                                                   QStringLiteral("A lonely Thanksgiving."))),
                 100);
        // A named film keeps 86 when TMDB's genres replace the inferred ones and
        // the overview says nothing of the season, and the overview lifts it to
        // 100.
        QCOMPARE(browse::holidayScore(withMetadata(movie(QStringLiteral("Scrooged"), 1988),
                                                   {QStringLiteral("Comedy")},
                                                   QStringLiteral("A cynic in the city."))),
                 86);
        QCOMPARE(browse::holidayScore(withMetadata(movie(QStringLiteral("Elf"), 2003),
                                                   {QStringLiteral("Comedy")},
                                                   QStringLiteral("Christmas in the city."))),
                 100);
        // TMDB's genres replace the inferred Holiday genre, so Elf falls back
        // to the title list.
        QCOMPARE(browse::holidayScore(withMetadata(movie(QStringLiteral("Elf"), 2003),
                                                   {QStringLiteral("Comedy")})),
                 86);
        QVERIFY(browse::isHolidayMovie(movie(QStringLiteral("Home Alone"), 1990)));
        QVERIFY(!browse::isHolidayMovie(movie(QStringLiteral("Heat"), 1995)));

        // The released score reads no keywords.
        auto keyworded = withMetadata(movie(QStringLiteral("Arrival"), 2016), {});
        auto metadata = std::make_shared<TitleMetadata>(*keyworded.metadata);
        metadata->keywords.push_back(MetadataKeyword{.id = 1, .name = QStringLiteral("christmas")});
        keyworded.metadata = metadata;
        QCOMPARE(browse::holidayScore(keyworded), 0);
    }

    void tmdbHolidayGenreAndOverviewTitlesFillTheHolidayRow()
    {
        MovieRowsModel rows;
        rows.replaceItems(
            {movie(QStringLiteral("Arrival"), 2016),
             withMetadata(movie(QStringLiteral("Zebra Story"), 2000), {},
                          QStringLiteral("A family gathers for Christmas.")),
             withMetadata(movie(QStringLiteral("Bright Night"), 1999),
                          {QStringLiteral("Holiday")}),
             movie(QStringLiteral("Scrooged"), 1988)});

        const LibraryModel *holiday = rowNamed(rows, QStringLiteral("holiday-movies"));
        QVERIFY(holiday != nullptr);
        // 100s first in browse order, then the named film at 86.
        QCOMPARE(titlesIn(holiday),
                 (QStringList{QStringLiteral("Bright Night"), QStringLiteral("Zebra Story"),
                              QStringLiteral("Scrooged")}));
        QCOMPARE(rows.data(rows.index(0, 0), MovieRowsModel::RowIdRole).toString(),
                 QStringLiteral("holiday-movies"));
    }

    // BrowseSnapshotStore.swift:3050-3076, :3078-3125.
    void showRowsKeyOnTmdbGenresAndKeepNameOrderWithinARow()
    {
        auto tagged = [](const QString &name, const QStringList &genres) {
            QVector<MediaItem> episodes{episode(name, 1, 1), episode(name, 1, 2)};
            for (MediaItem &entry : episodes) {
                entry = withMetadata(entry, genres);
            }
            return episodes;
        };
        QVector<MediaItem> items;
        items += tagged(QStringLiteral("Zed"), {QStringLiteral("Drama"), QStringLiteral("Other")});
        items += tagged(QStringLiteral("Alpha"), {QStringLiteral("Drama")});
        items += tagged(QStringLiteral("Mid"), {QStringLiteral("Comedy")});
        // The offline table knows Seinfeld as a Comedy, which TMDB's list
        // replaces.
        items += tagged(QStringLiteral("Seinfeld"), {QStringLiteral("Documentary")});
        items += QVector<MediaItem>{episode(QStringLiteral("Plain"), 1, 1)};

        ShowsModel shows;
        shows.replaceItems(items);

        QStringList ids;
        for (int row = 0; row < shows.rowCount(); ++row) {
            ids.push_back(shows.data(shows.index(row, 0), ShowsModel::RowIdRole).toString());
        }
        QCOMPARE(ids,
                 (QStringList{QStringLiteral("genre-Comedy"), QStringLiteral("genre-Documentary"),
                              QStringLiteral("genre-Drama"), QStringLiteral("all-shows")}));
        auto *documentary = qobject_cast<ShowRowModel *>(
            shows.data(shows.index(1, 0), ShowsModel::ShowsRole).value<QAbstractItemModel *>());
        QVERIFY(documentary != nullptr);
        QCOMPARE(showNamesIn(documentary), (QStringList{QStringLiteral("Seinfeld")}));
        auto *drama = qobject_cast<ShowRowModel *>(
            shows.data(shows.index(2, 0), ShowsModel::ShowsRole).value<QAbstractItemModel *>());
        QCOMPARE(showNamesIn(drama), (QStringList{QStringLiteral("Alpha"), QStringLiteral("Zed")}));
        auto *all = qobject_cast<ShowRowModel *>(
            shows.data(shows.index(3, 0), ShowsModel::ShowsRole).value<QAbstractItemModel *>());
        QCOMPARE(showNamesIn(all),
                 (QStringList{QStringLiteral("Alpha"), QStringLiteral("Mid"),
                              QStringLiteral("Plain"), QStringLiteral("Seinfeld"),
                              QStringLiteral("Zed")}));
    }
};

QTEST_APPLESS_MAIN(BrowseOrderTest)
#include "tst_browse_order.moc"
