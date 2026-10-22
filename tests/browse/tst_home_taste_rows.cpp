#include <QtTest>

#include <QLocale>

#include <memory>

#include "catalog/MediaItem.hpp"
#include "models/BrowseSemantics.hpp"
#include "models/HomeRowsModel.hpp"
#include "models/SimilarityIndex.hpp"
#include "profiles/ContentPolicy.hpp"
#include "profiles/ProfileStore.hpp"

namespace
{
// A mid-October day in the viewer's own calendar, which is how the released
// app reads the date.
const QDateTime kOctober = QDateTime(QDate(2026, 10, 15), QTime(12, 0));
const QDateTime kMarch = QDateTime(QDate(2026, 3, 15), QTime(12, 0));

[[nodiscard]] MediaItem movie(const QString &title,
                              int year,
                              const QStringList &genres = {},
                              int daysOld = 100)
{
    MediaItem item;
    item.id = QStringLiteral("root/") + title;
    item.relativePath = title + QStringLiteral(".mkv");
    item.title = title;
    item.mediaKind = QStringLiteral("movie");
    item.year = year;
    item.modifiedAt = kOctober.addDays(-daysOld);
    if (!genres.isEmpty()) {
        auto metadata = std::make_shared<TitleMetadata>();
        metadata->tmdbId = 1;
        metadata->genres = genres;
        item.metadata = metadata;
    }
    return item;
}

[[nodiscard]] TitleMetadata &editable(MediaItem &item)
{
    auto copy = item.metadata ? std::make_shared<TitleMetadata>(*item.metadata)
                              : std::make_shared<TitleMetadata>();
    TitleMetadata &ref = *copy;
    item.metadata = std::move(copy);
    return ref;
}

void finish(MediaItem &item, int daysAgo = 2)
{
    item.watched = true;
    item.lastPlayedAt = kOctober.addDays(-daysAgo);
}

[[nodiscard]] QStringList rowIds(const QVector<home_rows::Row> &rows)
{
    QStringList ids;
    for (const home_rows::Row &row : rows) {
        ids.push_back(row.id);
    }
    return ids;
}

[[nodiscard]] const home_rows::Row *rowNamed(const QVector<home_rows::Row> &rows, const QString &id)
{
    for (const home_rows::Row &row : rows) {
        if (row.id == id) {
            return &row;
        }
    }
    return nullptr;
}

[[nodiscard]] QStringList titlesOf(const home_rows::Row &row)
{
    QStringList titles;
    for (const home_rows::Card &card : row.cards) {
        titles.push_back(card.title);
    }
    return titles;
}

// A library whose finished title is a Drama and which holds a number of
// unwatched Dramas to rank.
[[nodiscard]] QVector<MediaItem> libraryWithHistory()
{
    MediaItem seen = movie(QStringLiteral("Seen"), 1999, {QStringLiteral("Drama")});
    finish(seen);
    return {seen};
}
}

class HomeTasteRowsTest final : public QObject
{
    Q_OBJECT

private slots:
    void initTestCase()
    {
        QLocale::setDefault(QLocale(QLocale::English, QLocale::UnitedStates));
    }

    // :2832-2890.
    void everyRowComposesInTheReleasedOrder()
    {
        QVector<MediaItem> items;
        MediaItem resumed = movie(QStringLiteral("Resumed"), 2015, {QStringLiteral("Drama")});
        resumed.resumePositionMs = 600'000;
        resumed.lastPlayedAt = kOctober.addDays(-1);
        items.push_back(resumed);
        MediaItem seen = movie(QStringLiteral("Seen Film"), 2016, {QStringLiteral("Horror")});
        finish(seen);
        items.push_back(seen);
        // Hidden Gems and Short Tonight.
        for (const QString &name : {QStringLiteral("Gem One"), QStringLiteral("Gem Two")}) {
            MediaItem gem = movie(name, 2017, {QStringLiteral("Drama")});
            editable(gem).voteAverage = 8.0;
            editable(gem).voteCount = 400;
            editable(gem).runtimeMinutes = 90;
            items.push_back(gem);
        }
        // October Horror and Holiday Movies.
        items.push_back(movie(QStringLiteral("Dread"), 2016, {QStringLiteral("Horror")}));
        items.push_back(movie(QStringLiteral("Christmas Wish"), 2016, {QStringLiteral("Comedy")}));
        items.push_back(movie(QStringLiteral("Santa Again"), 2016, {QStringLiteral("Comedy")}));
        // Because You Watched: four unwatched in Seen Film's franchise.
        for (int index = 1; index <= 4; ++index) {
            items.push_back(movie(QStringLiteral("Seen Film %1").arg(index), 2016, {QStringLiteral("Horror")}));
        }

        const QStringList ids = rowIds(home_rows::compose(items, kOctober));

        const QStringList expected{QStringLiteral("continue-watching"),
                                   QStringLiteral("recently-watched"),
                                   QStringLiteral("play-something"),
                                   QStringLiteral("because-you-watched-root/Seen Film"),
                                   QStringLiteral("hidden-gems"),
                                   QStringLiteral("short-tonight"),
                                   QStringLiteral("seasonal-october-horror"),
                                   QStringLiteral("recently-added"),
                                   QStringLiteral("holiday-movies"),
                                   QStringLiteral("decade-2010s"),
                                   QStringLiteral("all-movies")};
        QCOMPARE(ids, expected);
    }

    // :2906-2911: nothing finished, no taste, no taste rows. Play Something
    // and the seasonal rows do not need one.
    void aProfileWithNoHistoryHasNoTasteRows()
    {
        QVector<MediaItem> items;
        for (int index = 0; index < 4; ++index) {
            MediaItem gem = movie(QStringLiteral("Dread %1").arg(index), 2016, {QStringLiteral("Horror")});
            editable(gem).voteAverage = 8.5;
            editable(gem).voteCount = 900;
            editable(gem).runtimeMinutes = 80;
            items.push_back(gem);
        }
        const QStringList ids = rowIds(home_rows::compose(items, kOctober));
        QVERIFY(ids.contains(QStringLiteral("play-something")));
        QVERIFY(ids.contains(QStringLiteral("seasonal-october-horror")));
        QVERIFY(!ids.contains(QStringLiteral("hidden-gems")));
        QVERIFY(!ids.contains(QStringLiteral("short-tonight")));
        for (const QString &id : ids) {
            QVERIFY(!id.startsWith(QStringLiteral("because-you-watched")));
        }
    }

    // :2898-2899, :2920-2929: 7.5 and 50 votes, inclusive; a title with no
    // metadata has neither.
    void hiddenGemsNeedTheReleasedRatingAndVotes()
    {
        QVector<MediaItem> items = libraryWithHistory();
        const auto gem = [](const QString &name, double rating, int votes) {
            MediaItem item = movie(name, 2010, {QStringLiteral("Comedy")});
            editable(item).voteAverage = rating;
            editable(item).voteCount = votes;
            return item;
        };
        items << gem(QStringLiteral("Exactly"), 7.5, 50) << gem(QStringLiteral("Also"), 9.0, 51)
              << gem(QStringLiteral("Few Votes"), 9.0, 49) << gem(QStringLiteral("Low Rating"), 7.4, 500)
              << movie(QStringLiteral("Bare"), 2011);
        MediaItem seenGem = gem(QStringLiteral("Seen Gem"), 9.5, 500);
        finish(seenGem, 5);
        items.push_back(seenGem);

        const QVector<home_rows::Row> rows = home_rows::compose(items, kMarch);
        const home_rows::Row *row = rowNamed(rows, QStringLiteral("hidden-gems"));
        QVERIFY(row != nullptr);
        QCOMPARE(row->title, QStringLiteral("Hidden Gems"));
        QCOMPARE(titlesOf(*row), (QStringList{QStringLiteral("Also"), QStringLiteral("Exactly")}));
    }

    // :2927: one title is not a row.
    void aSmallRowNeedsTwoTitles()
    {
        QVector<MediaItem> items = libraryWithHistory();
        MediaItem gem = movie(QStringLiteral("Only Gem"), 2010, {QStringLiteral("Comedy")});
        editable(gem).voteAverage = 9.0;
        editable(gem).voteCount = 900;
        editable(gem).runtimeMinutes = 80;
        items.push_back(gem);
        const QStringList ids = rowIds(home_rows::compose(items, kMarch));
        QVERIFY(!ids.contains(QStringLiteral("hidden-gems")));
        QVERIFY(!ids.contains(QStringLiteral("short-tonight")));
    }

    // :2900, :2931-2940, :2968-2976: 100 minutes or less, the file's length
    // first and TMDB's runtime otherwise; an unknown length is left out.
    void shortTonightTakesHundredMinutesOrLess()
    {
        QVector<MediaItem> items = libraryWithHistory();
        MediaItem exactly = movie(QStringLiteral("Exactly"), 2010);
        exactly.durationSeconds = 6'000;
        MediaItem over = movie(QStringLiteral("Over"), 2011);
        over.durationSeconds = 6'001;
        MediaItem byRuntime = movie(QStringLiteral("By Runtime"), 2012, {QStringLiteral("Comedy")});
        editable(byRuntime).runtimeMinutes = 95;
        // The file's length wins over TMDB's runtime.
        MediaItem fileWins = movie(QStringLiteral("File Wins"), 2013, {QStringLiteral("Comedy")});
        editable(fileWins).runtimeMinutes = 200;
        fileWins.durationSeconds = 4'000;
        MediaItem unknown = movie(QStringLiteral("Unknown"), 2014);
        items << exactly << over << byRuntime << fileWins << unknown;

        const home_rows::Row *row = nullptr;
        const QVector<home_rows::Row> rows = home_rows::compose(items, kMarch);
        row = rowNamed(rows, QStringLiteral("short-tonight"));
        QVERIFY(row != nullptr);
        QCOMPARE(row->title, QStringLiteral("Short Tonight"));
        QStringList titles = titlesOf(*row);
        titles.sort();
        QCOMPARE(titles, (QStringList{QStringLiteral("By Runtime"), QStringLiteral("Exactly"),
                                      QStringLiteral("File Wins")}));
        QVERIFY(home_rows::runtimeSeconds(unknown) == std::nullopt);
    }

    // :2896, :2926: ranked and capped at twelve; the row counts twelve while
    // Home draws eight.
    void aRankedRowHoldsTwelveByAffinityThenRating()
    {
        QVector<MediaItem> items = libraryWithHistory();
        for (int index = 0; index < 15; ++index) {
            MediaItem gem = movie(QStringLiteral("Gem %1").arg(index, 2, 10, QLatin1Char('0')), 2010,
                                  {index % 2 == 0 ? QStringLiteral("Drama") : QStringLiteral("Comedy")});
            editable(gem).voteAverage = 7.5 + static_cast<double>(index) / 10.0;
            editable(gem).voteCount = 100;
            items.push_back(gem);
        }
        const QVector<home_rows::Row> rows = home_rows::compose(items, kMarch);
        const home_rows::Row *row = rowNamed(rows, QStringLiteral("hidden-gems"));
        QVERIFY(row != nullptr);
        QCOMPARE(row->totalCount, 12);
        QCOMPARE(row->cards.size(), home_rows::kCardsPerRow);
        // The Dramas match the finished Drama, so they lead, best rated first.
        QCOMPARE(row->cards.first().title, QStringLiteral("Gem 14"));
        QCOMPARE(row->cards.at(1).title, QStringLiteral("Gem 12"));
    }

    // :2945-2966, :2901-2903.
    void becauseYouWatchedTakesThreeNewestSeedsAndNeedsFourTitles()
    {
        QVector<MediaItem> items;
        const QStringList families{QStringLiteral("Cobalt Run"), QStringLiteral("Amber Gate"),
                                   QStringLiteral("Violet Sky"), QStringLiteral("Silver Fox")};
        for (int family = 0; family < families.size(); ++family) {
            MediaItem seed = movie(families.at(family), 2000, {QStringLiteral("Drama")}, 10 * (family + 1));
            finish(seed, family + 1);
            items.push_back(seed);
            // Silver Fox, the oldest file, has only three matches.
            const int matches = family == 3 ? 3 : 5;
            for (int index = 1; index <= matches; ++index) {
                items.push_back(movie(QStringLiteral("%1 %2").arg(families.at(family)).arg(index), 2000 + index,
                                      {QStringLiteral("Drama")}, 500));
            }
        }
        const QVector<home_rows::Row> rows = home_rows::compose(items, kMarch);
        QStringList because;
        for (const home_rows::Row &row : rows) {
            if (row.id.startsWith(QStringLiteral("because-you-watched-"))) {
                because.push_back(row.title);
            }
        }
        // The three newest files seed rows, in that order; the fourth seed is
        // past the limit.
        QCOMPARE(because, (QStringList{QStringLiteral("Because You Watched Cobalt Run"),
                                       QStringLiteral("Because You Watched Amber Gate"),
                                       QStringLiteral("Because You Watched Violet Sky")}));
        const home_rows::Row *row = rowNamed(rows, QStringLiteral("because-you-watched-root/Cobalt Run"));
        QVERIFY(row != nullptr);
        QCOMPARE(row->totalCount, 12);
        // The franchise leads the row, nearest year first.
        QCOMPARE(row->cards.first().title, QStringLiteral("Cobalt Run 1"));
    }

    // :2957, :2959: what the profile has seen is not suggested, and fewer than
    // four titles is no row.
    void becauseYouWatchedSkipsWatchedTitlesAndShortRows()
    {
        QVector<MediaItem> items = libraryWithHistory();
        for (int index = 1; index <= 4; ++index) {
            MediaItem match = movie(QStringLiteral("Match %1").arg(index), 2000, {QStringLiteral("Drama")});
            if (index == 1) {
                finish(match, 40);
            }
            items.push_back(match);
        }
        // Two seeds now (Seen and Match 1); the first finds Matches 2-4, three,
        // and the second finds Seen's three siblings: no row has four.
        const QStringList ids = rowIds(home_rows::compose(items, kMarch));
        for (const QString &id : ids) {
            QVERIFY2(!id.startsWith(QStringLiteral("because-you-watched-")), qPrintable(id));
        }
    }

    // :2951-2953 on a library with no metadata at all: the older rule ranks
    // the sequels of a finished film by name, so the row still appears.
    void becauseYouWatchedWorksWithoutMetadata()
    {
        QVector<MediaItem> items;
        MediaItem seed = movie(QStringLiteral("Cobalt Run"), 2000);
        finish(seed);
        items.push_back(seed);
        for (int index = 1; index <= 4; ++index) {
            items.push_back(movie(QStringLiteral("Cobalt Run %1").arg(index), 2000 + index));
        }
        items.push_back(movie(QStringLiteral("Unrelated"), 1950));
        const QVector<home_rows::Row> rows = home_rows::compose(items, kMarch);
        const home_rows::Row *row = rowNamed(rows, QStringLiteral("because-you-watched-root/Cobalt Run"));
        QVERIFY(row != nullptr);
        QCOMPARE(titlesOf(*row),
                 (QStringList{QStringLiteral("Cobalt Run 1"), QStringLiteral("Cobalt Run 2"),
                              QStringLiteral("Cobalt Run 3"), QStringLiteral("Cobalt Run 4")}));
        // No metadata: no Hidden Gems, and no season but October's or summer's.
        QVERIFY(rowNamed(rows, QStringLiteral("hidden-gems")) == nullptr);
        QVERIFY(rowNamed(rows, QStringLiteral("seasonal-october-horror")) == nullptr);
    }

    // The Kids policy filters before Home sees the library, so no row holds an
    // adult title and an adult title's viewing shapes no Kids row.
    void aKidsProfileSeesOnlyKidsTitlesInEveryRow()
    {
        QVector<MediaItem> library;
        MediaItem adultSeen = movie(QStringLiteral("Dread"), 2001, {QStringLiteral("Horror")});
        finish(adultSeen);
        library.push_back(adultSeen);
        for (int index = 0; index < 4; ++index) {
            library.push_back(movie(QStringLiteral("Dread %1").arg(index), 2002, {QStringLiteral("Horror")}));
            MediaItem kids = movie(QStringLiteral("Wonder %1").arg(index), 2002,
                                   {QStringLiteral("Family"), QStringLiteral("Animation")});
            editable(kids).voteAverage = 8.0;
            editable(kids).voteCount = 300;
            editable(kids).runtimeMinutes = 80;
            editable(kids).certification = QStringLiteral("G");
            library.push_back(kids);
        }
        MediaItem kidsSeen = movie(QStringLiteral("Wonder Seen"), 2002, {QStringLiteral("Family")});
        editable(kidsSeen).certification = QStringLiteral("G");
        finish(kidsSeen);
        library.push_back(kidsSeen);

        const QVector<MediaItem> visible = content_policy::filtered(
            static_cast<int>(ProfileStore::Maturity::Kids), library);
        QVERIFY(visible.size() < library.size());

        const QVector<home_rows::Row> rows = home_rows::compose(visible, kOctober);
        QVERIFY(rowNamed(rows, QStringLiteral("hidden-gems")) != nullptr);
        QVERIFY(rowNamed(rows, QStringLiteral("seasonal-october-horror")) == nullptr);
        for (const home_rows::Row &row : rows) {
            for (const home_rows::Card &card : row.cards) {
                QVERIFY2(!card.title.startsWith(QStringLiteral("Dread")),
                         qPrintable(row.id + QLatin1Char(' ') + card.title));
            }
        }
    }

    // Two profiles of one library get rows from their own history.
    void eachProfilesHistoryShapesItsOwnRows()
    {
        QVector<MediaItem> profileA;
        QVector<MediaItem> profileB;
        for (const QString &name : {QStringLiteral("Drama One"), QStringLiteral("Drama Two"),
                                    QStringLiteral("Comedy One"), QStringLiteral("Comedy Two")}) {
            const bool drama = name.startsWith(QStringLiteral("Drama"));
            MediaItem item = movie(name, 2010, {drama ? QStringLiteral("Drama") : QStringLiteral("Comedy")});
            editable(item).voteAverage = 8.0;
            editable(item).voteCount = 200;
            profileA.push_back(item);
            profileB.push_back(item);
        }
        MediaItem seenByA = movie(QStringLiteral("Drama Seen"), 2001, {QStringLiteral("Drama")});
        MediaItem seenByB = movie(QStringLiteral("Comedy Seen"), 2001, {QStringLiteral("Comedy")});
        MediaItem unseenByB = seenByA;
        MediaItem unseenByA = seenByB;
        finish(seenByA);
        finish(seenByB);
        profileA << seenByA << unseenByA;
        profileB << seenByB << unseenByB;

        const home_rows::Row *a = nullptr;
        const QVector<home_rows::Row> rowsA = home_rows::compose(profileA, kMarch);
        a = rowNamed(rowsA, QStringLiteral("hidden-gems"));
        const QVector<home_rows::Row> rowsB = home_rows::compose(profileB, kMarch);
        const home_rows::Row *b = rowNamed(rowsB, QStringLiteral("hidden-gems"));
        QVERIFY(a != nullptr && b != nullptr);
        QVERIFY(titlesOf(*a).first().startsWith(QStringLiteral("Drama")));
        QVERIFY(titlesOf(*b).first().startsWith(QStringLiteral("Comedy")));
    }

    // The date comes from the model's clock, so a test pins it.
    void theClockDecidesTheSeasonalRow()
    {
        HomeRowsModel model;
        QVector<MediaItem> items;
        for (int index = 0; index < 3; ++index) {
            items.push_back(movie(QStringLiteral("Dread %1").arg(index), 2001 + index, {QStringLiteral("Horror")}));
        }
        model.setClockForTest([] { return kMarch; });
        model.replaceItems(items);
        const auto hasSeasonal = [&model] {
            for (int row = 0; row < model.rowCount(); ++row) {
                if (model.data(model.index(row), HomeRowsModel::RowIdRole).toString()
                    == QStringLiteral("seasonal-october-horror")) {
                    return true;
                }
            }
            return false;
        };
        QVERIFY(!hasSeasonal());
        model.setClockForTest([] { return kOctober; });
        QVERIFY(hasSeasonal());
    }

    // A progress record every ten seconds must not rank the library again.
    void aProgressRecordDoesNotBuildTheTasteRowsAgain()
    {
        HomeRowsModel model;
        model.setClockForTest([] { return kOctober; });
        QVector<MediaItem> items = libraryWithHistory();
        for (int index = 0; index < 20; ++index) {
            items.push_back(movie(QStringLiteral("Film %1").arg(index), 2010, {QStringLiteral("Drama")}));
        }
        model.replaceItems(items);
        const int built = model.derivedRowBuildsForTest();
        QVERIFY(built >= 1);

        // Ten seconds of a film after ten more, the length now known.
        model.applyWatchProgress(QStringLiteral("root/Film 3"), 600'000, 7'200'000, false);
        const int afterFirst = model.derivedRowBuildsForTest();
        QCOMPARE(afterFirst, built + 1);
        model.applyWatchProgress(QStringLiteral("root/Film 3"), 610'000, 7'200'000, false);
        model.applyWatchProgress(QStringLiteral("root/Film 3"), 620'000, 7'200'000, false);
        QCOMPARE(model.derivedRowBuildsForTest(), afterFirst);

        // Finishing it changes what is unwatched, so the rows are built again.
        model.applyWatchProgress(QStringLiteral("root/Film 3"), 0, 7'200'000, true);
        QCOMPARE(model.derivedRowBuildsForTest(), afterFirst + 1);
        // A new projection does too, and so does tomorrow.
        model.replaceItems(items);
        QCOMPARE(model.derivedRowBuildsForTest(), afterFirst + 2);
        model.setClockForTest([] { return kOctober.addDays(1); });
        QCOMPARE(model.derivedRowBuildsForTest(), afterFirst + 3);
    }

    // What the titles and their metadata alone decide is built when the items
    // are replaced: a progress record scores no overview and ranks no library.
    void aProgressRecordDoesNotScoreOrIndexTheLibraryAgain()
    {
        HomeRowsModel model;
        model.setClockForTest([] { return kMarch; });
        QVector<MediaItem> items = libraryWithHistory();
        for (int index = 0; index < 20; ++index) {
            MediaItem film = movie(QStringLiteral("Film %1").arg(index), 2010, {QStringLiteral("Drama")});
            editable(film).overview = QStringLiteral("A quiet town waits for winter and the ")
                + (index < 3 ? QStringLiteral("Christmas fair.") : QStringLiteral("harvest fair."));
            items.push_back(film);
        }
        const int scoredBefore = browse::holidayScoreCallsForTest();
        const int indexedBefore = browse::SimilarityIndex::constructedForTest();
        model.replaceItems(items);
        const int scored = browse::holidayScoreCallsForTest() - scoredBefore;
        const int indexed = browse::SimilarityIndex::constructedForTest() - indexedBefore;
        QVERIFY(scored >= 21);
        QCOMPARE(indexed, 1);
        const auto rowIdsNow = [&model] {
            QStringList ids;
            for (int row = 0; row < model.rowCount(); ++row) {
                ids.push_back(model.data(model.index(row), HomeRowsModel::RowIdRole).toString());
            }
            return ids;
        };
        QVERIFY(rowIdsNow().contains(QStringLiteral("holiday-movies")));
        QVERIFY(rowIdsNow().contains(QStringLiteral("decade-2010s")));
        QVERIFY(rowIdsNow().contains(QStringLiteral("because-you-watched-root/Seen")));

        // A position, then more of it with the length known, then a title
        // finished: none of them changes a title or its metadata.
        model.applyWatchProgress(QStringLiteral("root/Film 7"), 600'000, 7'200'000, false);
        model.applyWatchProgress(QStringLiteral("root/Film 7"), 610'000, 7'200'000, false);
        model.applyWatchProgress(QStringLiteral("root/Film 9"), 0, 7'200'000, true);
        QCOMPARE(browse::holidayScoreCallsForTest() - scoredBefore, scored);
        QCOMPARE(browse::SimilarityIndex::constructedForTest() - indexedBefore, indexed);
        QVERIFY(rowIdsNow().contains(QStringLiteral("holiday-movies")));
        // The finished film left the row built from the index made before it.
        for (int row = 0; row < model.rowCount(); ++row) {
            if (model.data(model.index(row), HomeRowsModel::RowIdRole).toString()
                != QStringLiteral("because-you-watched-root/Seen")) {
                continue;
            }
            const QVariantMap card = model.cardForId(row, QStringLiteral("root/Film 9"));
            QVERIFY(card.isEmpty());
        }

        // A new projection does score and index again.
        model.replaceItems(items);
        QVERIFY(browse::holidayScoreCallsForTest() - scoredBefore >= scored * 2);
        QCOMPARE(browse::SimilarityIndex::constructedForTest() - indexedBefore, indexed + 1);
    }

    // A finished movie leaves Play Something and Hidden Gems at once and
    // changes what Because You Watched offers.
    void finishingAMovieUpdatesTheTasteRows()
    {
        HomeRowsModel model;
        model.setClockForTest([] { return kMarch; });
        QVector<MediaItem> items = libraryWithHistory();
        for (int index = 0; index < 3; ++index) {
            MediaItem gem = movie(QStringLiteral("Gem %1").arg(index), 2010, {QStringLiteral("Drama")});
            editable(gem).voteAverage = 8.0;
            editable(gem).voteCount = 200;
            items.push_back(gem);
        }
        model.replaceItems(items);
        const auto hiddenGemCount = [&model] {
            for (int row = 0; row < model.rowCount(); ++row) {
                if (model.data(model.index(row), HomeRowsModel::RowIdRole).toString()
                    == QStringLiteral("hidden-gems")) {
                    return model.data(model.index(row), HomeRowsModel::ItemCountRole).toInt();
                }
            }
            return 0;
        };
        QCOMPARE(hiddenGemCount(), 3);
        model.applyWatchProgress(QStringLiteral("root/Gem 1"), 0, 7'200'000, true);
        QCOMPARE(hiddenGemCount(), 2);
        model.applyWatchProgress(QStringLiteral("root/Gem 2"), 0, 7'200'000, true);
        QCOMPARE(hiddenGemCount(), 0);
    }
};

QTEST_MAIN(HomeTasteRowsTest)
#include "tst_home_taste_rows.moc"
