#include <QtTest>

#include <QDateTime>
#include <QSignalSpy>
#include <QSet>

#include "models/HeroSpotlight.hpp"
#include "models/HomeRowsModel.hpp"
#include "models/TasteModel.hpp"
#include "profiles/ContentPolicy.hpp"
#include "profiles/ProfileStore.hpp"

namespace
{
const QDateTime kNow = QDateTime(QDate(2026, 10, 15), QTime(12, 0), QTimeZone::UTC);

[[nodiscard]] QDateTime daysAgo(int days)
{
    return kNow.addDays(-days);
}

[[nodiscard]] MediaItem movie(const QString &title,
                              int year,
                              const QDateTime &modified = daysAgo(100),
                              bool art = false)
{
    MediaItem item;
    item.id = QStringLiteral("root/") + title;
    item.relativePath = title + QStringLiteral(".mkv");
    item.title = title;
    item.mediaKind = QStringLiteral("movie");
    item.year = year;
    item.modifiedAt = modified;
    if (art) {
        item.posterAbsolutePath = QStringLiteral("/home/alex/Videos/%1/poster.jpg").arg(title);
        item.backdropAbsolutePath = QStringLiteral("/home/alex/Videos/%1/fanart.jpg").arg(title);
    }
    return item;
}

[[nodiscard]] MediaItem episode(const QString &show,
                                int season,
                                int number,
                                const QDateTime &modified = daysAgo(100))
{
    MediaItem item;
    item.id = QStringLiteral("shows/%1/S%2E%3").arg(show).arg(season).arg(number);
    item.relativePath = item.id + QStringLiteral(".mp4");
    item.title = show;
    item.mediaKind = QStringLiteral("episode");
    item.showName = show;
    item.seasonNumber = season;
    item.episodeNumber = number;
    item.modifiedAt = modified;
    return item;
}

[[nodiscard]] QStringList categories(const QVector<hero_spotlight::Spotlight> &spotlights)
{
    QStringList result;
    for (const hero_spotlight::Spotlight &spotlight : spotlights) {
        result.push_back(spotlight.category);
    }
    return result;
}

[[nodiscard]] QStringList titles(const QVector<hero_spotlight::Spotlight> &spotlights)
{
    QStringList result;
    for (const hero_spotlight::Spotlight &spotlight : spotlights) {
        result.push_back(spotlight.title);
    }
    return result;
}

[[nodiscard]] QVector<MediaItem> library(int movies)
{
    QVector<MediaItem> items;
    for (int index = 0; index < movies; ++index) {
        items.push_back(movie(QStringLiteral("Film %1").arg(char('A' + index)), 1990 + index * 3,
                              daysAgo(10 + index * 20)));
    }
    return items;
}
}

class HeroSpotlightTest final : public QObject
{
    Q_OBJECT

private slots:
    // BrowseSnapshotStore.swift:719-720.
    void anEmptyLibraryHasNoSpotlight()
    {
        QVERIFY(hero_spotlight::build({}, kNow).isEmpty());
        HeroSpotlightModel model;
        model.replaceSpotlights({});
        QCOMPARE(model.count(), 0);
        QVERIFY(model.current().isEmpty());
    }

    // :776-781: the first spotlight is the title the viewer was last in.
    void aMovieInProgressIsTheFirstSpotlightAsContinueWatching()
    {
        QVector<MediaItem> items = library(6);
        items[2].resumePositionMs = 90'000;
        items[2].lastPlayedAt = daysAgo(1);
        items[4].resumePositionMs = 30'000;
        items[4].lastPlayedAt = daysAgo(5);

        const QVector<hero_spotlight::Spotlight> spotlights = hero_spotlight::build(items, kNow);
        QVERIFY(!spotlights.isEmpty());
        QCOMPARE(spotlights.constFirst().category, QStringLiteral("Continue Watching"));
        QCOMPARE(spotlights.constFirst().icon, QStringLiteral("play.circle"));
        QCOMPARE(spotlights.constFirst().mediaId, items.at(2).id);
        QCOMPARE(spotlights.constFirst().id, QStringLiteral("continue-") + items.at(2).id);
    }

    // The same function Home's Continue Watching row asks, so an episode in
    // progress is the show's card and plays that episode.
    void aShowInProgressContinuesWithItsUpNextEpisode()
    {
        QVector<MediaItem> items = library(3);
        MediaItem first = episode(QStringLiteral("Sample Show"), 1, 1);
        first.watched = true;
        first.lastPlayedAt = daysAgo(2);
        items.push_back(first);
        items.push_back(episode(QStringLiteral("Sample Show"), 1, 2));
        items.push_back(episode(QStringLiteral("Sample Show"), 1, 3));

        const QVector<hero_spotlight::Spotlight> spotlights = hero_spotlight::build(items, kNow);
        QCOMPARE(spotlights.constFirst().category, QStringLiteral("Continue Watching"));
        QCOMPARE(spotlights.constFirst().showName, QStringLiteral("Sample Show"));
        QCOMPARE(spotlights.constFirst().title, QStringLiteral("Sample Show"));
        QCOMPARE(spotlights.constFirst().mediaId, QStringLiteral("shows/Sample Show/S1E2"));
        // Nothing but the up-next episode reaches the card as a second entry.
        QCOMPARE(titles(spotlights).count(QStringLiteral("Sample Show")), 1);
    }

    // The idle window Home's row applies applies here too: a title not played
    // for a year is not "continuing".
    void aViewingNotPlayedForAYearIsNotContinued()
    {
        QVector<MediaItem> items = library(4);
        items[1].resumePositionMs = 90'000;
        items[1].lastPlayedAt = daysAgo(400);
        const QVector<hero_spotlight::Spotlight> spotlights = hero_spotlight::build(items, kNow);
        QVERIFY(!categories(spotlights).contains(QStringLiteral("Continue Watching")));
    }

    // :783-799, :2103-2121: artwork and a runtime outweigh newness.
    void featuredIsTheBestScoredTitle()
    {
        QVector<MediaItem> items;
        items.push_back(movie(QStringLiteral("Plain Newest"), 2025, daysAgo(0)));
        items.push_back(movie(QStringLiteral("Pictured Older"), 2005, daysAgo(40), true));
        MediaItem short_ = movie(QStringLiteral("Pictured Short"), 2006, daysAgo(0), true);
        short_.durationSeconds = 600;
        items.push_back(short_);

        const QVector<hero_spotlight::Spotlight> spotlights = hero_spotlight::build(items, kNow);
        QCOMPARE(spotlights.constFirst().category, QStringLiteral("Featured"));
        QCOMPARE(spotlights.constFirst().icon, QStringLiteral("sparkles"));
        QCOMPARE(spotlights.constFirst().title, QStringLiteral("Pictured Older"));
        QCOMPARE(spotlights.constFirst().backdropPath,
                 QStringLiteral("/home/alex/Videos/Pictured Older/fanart.jpg"));
        QCOMPARE(spotlights.constFirst().posterPath,
                 QStringLiteral("/home/alex/Videos/Pictured Older/poster.jpg"));
    }

    // The hero ranks by the one `heroScore` the seasonal rows use, the rating
    // term included (:2104).
    void theHeroRanksByTheRatingToo()
    {
        QVector<MediaItem> items = library(5);
        for (MediaItem &item : items) {
            item.modifiedAt = daysAgo(100);
        }
        MediaItem rated = movie(QStringLiteral("Quiet Masterpiece"), 2004, daysAgo(100));
        auto metadata = std::make_shared<TitleMetadata>();
        metadata->tmdbId = 7;
        metadata->voteAverage = 8.5;
        rated.metadata = metadata;
        items.push_back(rated);

        const QVector<hero_spotlight::Spotlight> spotlights = hero_spotlight::build(items, kNow);
        QCOMPARE(spotlights.constFirst().category, QStringLiteral("Featured"));
        QCOMPARE(spotlights.constFirst().title, QStringLiteral("Quiet Masterpiece"));
    }

    // :788: a title the profile has not finished is boosted by how much its
    // genres, director and cast match what the profile finished.
    void aTasteBoostMovesAnUnwatchedMatchAhead()
    {
        QVector<MediaItem> items;
        const auto withGenre = [](MediaItem item, const QString &genre) {
            auto metadata = std::make_shared<TitleMetadata>();
            metadata->tmdbId = 1;
            metadata->genres = {genre};
            item.metadata = metadata;
            return item;
        };
        MediaItem seen = withGenre(movie(QStringLiteral("Seen Western"), 1990, daysAgo(200)), QStringLiteral("Western"));
        seen.watched = true;
        items.push_back(seen);
        items.push_back(withGenre(movie(QStringLiteral("Alpha Comedy"), 2000, daysAgo(100)), QStringLiteral("Comedy")));
        items.push_back(withGenre(movie(QStringLiteral("Zulu Western"), 2001, daysAgo(100)), QStringLiteral("Western")));

        const QVector<hero_spotlight::Spotlight> plain = hero_spotlight::build(items, kNow);
        QCOMPARE(plain.constFirst().title, QStringLiteral("Alpha Comedy"));

        const std::optional<browse::TasteModel> taste = browse::TasteModel::build(items);
        QVERIFY(taste.has_value());
        const QVector<hero_spotlight::Spotlight> boosted = hero_spotlight::build(items, kNow, nullptr, &*taste);
        QCOMPARE(boosted.constFirst().title, QStringLiteral("Zulu Western"));
    }

    // :838-871: a title sharing a top-billed actor with one already chosen is
    // too similar while others remain.
    void aSharedLeadActorKeepsTwoTitlesApart()
    {
        QVector<MediaItem> items;
        const auto starring = [](MediaItem item, const QString &actor) {
            auto metadata = std::make_shared<TitleMetadata>();
            metadata->tmdbId = 1;
            metadata->cast = {CastMember{.name = actor, .character = {}, .profilePath = {}, .personId = 1}};
            item.metadata = metadata;
            return item;
        };
        items.push_back(starring(movie(QStringLiteral("First Lead"), 2001, daysAgo(10), true), QStringLiteral("Pat Example")));
        items.push_back(starring(movie(QStringLiteral("Second Lead"), 2002, daysAgo(11), true), QStringLiteral("Pat Example")));
        items.push_back(movie(QStringLiteral("Other One"), 2003, daysAgo(60)));
        items.push_back(movie(QStringLiteral("Other Two"), 2004, daysAgo(70)));

        const QVector<hero_spotlight::Spotlight> spotlights = hero_spotlight::build(items, kNow);
        QCOMPARE(spotlights.at(0).title, QStringLiteral("First Lead"));
        QVERIFY(spotlights.at(1).title != QStringLiteral("Second Lead"));
    }

    // The released Holiday Pick reads the same holiday score as the Movies and
    // Home rows (:801-808 over the same `holidayScores`): the overview and the
    // genres count, not only the title.
    void theHolidayPickReadsTheOverviewAndGenres()
    {
        QVector<MediaItem> items = library(5);
        MediaItem quiet = movie(QStringLiteral("Snow Globe"), 1995, daysAgo(300));
        auto metadata = std::make_shared<TitleMetadata>();
        metadata->tmdbId = 9;
        metadata->overview = QStringLiteral("A family gathers for Christmas.");
        quiet.metadata = metadata;
        items.push_back(quiet);

        const QVector<hero_spotlight::Spotlight> spotlights = hero_spotlight::build(items, kNow);
        const int at = static_cast<int>(categories(spotlights).indexOf(QStringLiteral("Holiday Pick")));
        QVERIFY(at >= 0);
        QCOMPARE(spotlights.at(at).title, QStringLiteral("Snow Globe"));
    }

    // :801-808.
    void aHolidayTitleIsOfferedAsHolidayPick()
    {
        QVector<MediaItem> items = library(5);
        items.push_back(movie(QStringLiteral("A Christmas Story"), 1983, daysAgo(300)));

        const QVector<hero_spotlight::Spotlight> spotlights = hero_spotlight::build(items, kNow);
        const int at = static_cast<int>(categories(spotlights).indexOf(QStringLiteral("Holiday Pick")));
        QVERIFY(at >= 0);
        QCOMPARE(spotlights.at(at).title, QStringLiteral("A Christmas Story"));
        QCOMPARE(spotlights.at(at).icon, QStringLiteral("gift"));
    }

    // :810-825: the newest file not yet shown, then :827-831 the best-scored
    // film from before 2000.
    void recentlyAddedIsTheNewestFileAndTheVaultIsAnOlderFilm()
    {
        QVector<MediaItem> items;
        items.push_back(movie(QStringLiteral("Aaa Modern"), 2018, daysAgo(200), true));
        items.push_back(movie(QStringLiteral("Bbb Modern"), 2019, daysAgo(2)));
        items.push_back(movie(QStringLiteral("Ccc Classic"), 1971, daysAgo(300)));
        items.push_back(movie(QStringLiteral("Ddd Classic"), 1982, daysAgo(280), true));

        const QVector<hero_spotlight::Spotlight> spotlights = hero_spotlight::build(items, kNow);
        QCOMPARE(categories(spotlights),
                 (QStringList{QStringLiteral("Featured"), QStringLiteral("Recently Added"),
                              QStringLiteral("From the Vault"), QStringLiteral("Smart Pick")}));
        QCOMPARE(spotlights.at(1).title, QStringLiteral("Bbb Modern"));
        QCOMPARE(spotlights.at(1).icon, QStringLiteral("plus.square.on.square"));
        QCOMPARE(spotlights.at(2).icon, QStringLiteral("clock.arrow.circlepath"));
        QVERIFY(spotlights.at(2).title.contains(QStringLiteral("Classic")));
    }

    // :833-836: Smart Picks fill the carousel to five and no further.
    void theCarouselIsFilledToFiveAndNoTitleRepeats()
    {
        QVector<MediaItem> items = library(12);
        items[3].resumePositionMs = 50'000;
        items[3].lastPlayedAt = daysAgo(1);
        const QVector<hero_spotlight::Spotlight> spotlights = hero_spotlight::build(items, kNow);
        QCOMPARE(spotlights.size(), hero_spotlight::kTargetCount);
        QSet<QString> ids;
        QSet<QString> mediaIds;
        for (const hero_spotlight::Spotlight &spotlight : spotlights) {
            ids.insert(spotlight.id);
            mediaIds.insert(spotlight.mediaId);
        }
        QCOMPARE(ids.size(), spotlights.size());
        QCOMPARE(mediaIds.size(), spotlights.size());
        QCOMPARE(spotlights.constFirst().category, QStringLiteral("Continue Watching"));
        QCOMPARE(spotlights.constLast().category, QStringLiteral("Smart Pick"));
    }

    // Fewer titles than slots: every title once, no padding.
    void aSmallLibraryShowsEachTitleOnce()
    {
        const QVector<hero_spotlight::Spotlight> spotlights = hero_spotlight::build(library(2), kNow);
        QCOMPARE(spotlights.size(), 2);
        QVERIFY(spotlights.at(0).mediaId != spotlights.at(1).mediaId);
        const QVector<hero_spotlight::Spotlight> one = hero_spotlight::build(library(1), kNow);
        QCOMPARE(one.size(), 1);
        QCOMPARE(one.constFirst().category, QStringLiteral("Featured"));
    }

    // A show is one title whatever its episode count (:2655 spotlights the
    // representative), and its art is the show folder's.
    void aShowIsOneSpotlightWithTheShowFoldersArtwork()
    {
        QVector<MediaItem> items;
        for (int number = 1; number <= 5; ++number) {
            MediaItem item = episode(QStringLiteral("Sample Show"), 1, number);
            item.showPosterAbsolutePath = QStringLiteral("/home/alex/Shows/Sample Show/poster.jpg");
            item.showBackdropAbsolutePath = QStringLiteral("/home/alex/Shows/Sample Show/fanart.jpg");
            items.push_back(item);
        }
        const QVector<hero_spotlight::Spotlight> spotlights = hero_spotlight::build(items, kNow);
        QCOMPARE(spotlights.size(), 1);
        QCOMPARE(spotlights.constFirst().showName, QStringLiteral("Sample Show"));
        QCOMPARE(spotlights.constFirst().backdropPath,
                 QStringLiteral("/home/alex/Shows/Sample Show/fanart.jpg"));
        QCOMPARE(spotlights.constFirst().posterPath,
                 QStringLiteral("/home/alex/Shows/Sample Show/poster.jpg"));
        // Untouched: it plays from the first episode.
        QCOMPARE(spotlights.constFirst().mediaId, QStringLiteral("shows/Sample Show/S1E1"));
    }

    // :738-759, :867-871: the similarity pass keeps a franchise from filling
    // the carousel while other titles are left.
    void aFranchiseDoesNotFillTheCarouselWhileOtherTitlesRemain()
    {
        QVector<MediaItem> items;
        for (int part = 1; part <= 4; ++part) {
            items.push_back(movie(QStringLiteral("Star Wars Part %1").arg(part), 1977 + part,
                                  daysAgo(30), true));
        }
        items.push_back(movie(QStringLiteral("Unrelated One"), 2001, daysAgo(60)));
        items.push_back(movie(QStringLiteral("Another Story"), 2003, daysAgo(80)));

        const QVector<hero_spotlight::Spotlight> spotlights = hero_spotlight::build(items, kNow);
        QCOMPARE(spotlights.size(), 5);
        int franchise = 0;
        for (const hero_spotlight::Spotlight &spotlight : spotlights) {
            franchise += spotlight.title.startsWith(QStringLiteral("Star Wars")) ? 1 : 0;
        }
        // One of the family ahead of the others, then the rest only once the
        // unrelated titles are used up (:761-764's fallback).
        QVERIFY(spotlights.at(0).title.startsWith(QStringLiteral("Star Wars")));
        QVERIFY(!spotlights.at(1).title.startsWith(QStringLiteral("Star Wars")));
        QCOMPARE(franchise, 3);
    }

    // HeroCarousel.swift:19-27, :300-314: the position is a count that wraps
    // when read, and a dot takes the shorter way round.
    void theCarouselWrapsAndAJumpTakesTheShorterWay()
    {
        HeroSpotlightModel model;
        model.replaceSpotlights(hero_spotlight::build(library(5), kNow));
        QCOMPARE(model.count(), 5);
        QSignalSpy moved(&model, &HeroSpotlightModel::positionChanged);

        model.step(-1);
        QCOMPARE(model.position(), -1);
        QCOMPARE(model.currentIndex(), 4);
        model.step(1);
        QCOMPARE(model.currentIndex(), 0);
        model.step(1);
        model.step(1);
        QCOMPARE(model.currentIndex(), 2);
        // 2 -> 4 is two steps forward; 2 -> 0 is two back; 4 -> 0 wraps one.
        model.moveTo(4);
        QCOMPARE(model.currentIndex(), 4);
        QCOMPARE(model.position(), 4);
        model.moveTo(0);
        QCOMPARE(model.currentIndex(), 0);
        QCOMPARE(model.position(), 5);
        QCOMPARE(moved.count(), 6);

        // Fewer than two spotlights cannot move (:301).
        model.replaceSpotlights(hero_spotlight::build(library(1), kNow));
        QSignalSpy still(&model, &HeroSpotlightModel::positionChanged);
        model.step(1);
        model.moveTo(0);
        QCOMPARE(still.count(), 0);
        QCOMPARE(model.currentIndex(), 0);
    }

    // :222-226: a carousel that changes length starts over; one that keeps its
    // length keeps its place.
    void aNewLengthReturnsToTheFirstSlide()
    {
        HeroSpotlightModel model;
        model.replaceSpotlights(hero_spotlight::build(library(5), kNow));
        model.step(3);
        QCOMPARE(model.currentIndex(), 3);
        model.replaceSpotlights(hero_spotlight::build(library(3), kNow));
        QCOMPARE(model.position(), 0);
        QCOMPARE(model.currentIndex(), 0);

        model.replaceSpotlights(hero_spotlight::build(library(5), kNow));
        model.step(2);
        QVector<MediaItem> same = library(5);
        same[0].title = QStringLiteral("Film A Renamed");
        model.replaceSpotlights(hero_spotlight::build(same, kNow));
        QCOMPARE(model.currentIndex(), 2);
    }

    // :380-387, :238-244: the timer runs on screen, with more than one slide,
    // with no remote on it and motion allowed; each step restarts it.
    void theTimerAdvancesOnItsOwnAndStopsWhereTheReleasedOneDoes()
    {
        HeroSpotlightModel model;
        QCOMPARE(model.advanceIntervalMs(), 15'000);
        model.setAdvanceIntervalForTest(40);
        model.replaceSpotlights(hero_spotlight::build(library(5), kNow));

        // Off screen: nothing runs.
        QVERIFY(!model.timerRunning());
        model.setActive(true);
        QVERIFY(model.timerRunning());
        QTRY_VERIFY_WITH_TIMEOUT(model.position() >= 2, 2000);

        // The remote resting on it stops it; letting go starts it again.
        model.setRemoteFocused(true);
        QVERIFY(!model.timerRunning());
        const int held = model.position();
        QTest::qWait(150);
        QCOMPARE(model.position(), held);
        model.setRemoteFocused(false);
        QVERIFY(model.timerRunning());
        QTRY_VERIFY_WITH_TIMEOUT(model.position() > held, 2000);

        // Reduce Motion withholds it.
        model.setReduceMotion(true);
        QVERIFY(!model.timerRunning());
        const int reduced = model.position();
        QTest::qWait(150);
        QCOMPARE(model.position(), reduced);
        model.setReduceMotion(false);

        // One slide has nothing to advance to, and leaving the screen stops it.
        model.replaceSpotlights(hero_spotlight::build(library(1), kNow));
        QVERIFY(!model.timerRunning());
        model.replaceSpotlights(hero_spotlight::build(library(5), kNow));
        QVERIFY(model.timerRunning());
        model.setActive(false);
        QVERIFY(!model.timerRunning());
    }

    void aManualStepRestartsTheInterval()
    {
        HeroSpotlightModel model;
        model.setAdvanceIntervalForTest(300);
        model.replaceSpotlights(hero_spotlight::build(library(5), kNow));
        model.setActive(true);
        QTest::qWait(200);
        model.step(1);
        QCOMPARE(model.position(), 1);
        // Had the timer not restarted, it would fire about 100 ms later.
        QTest::qWait(180);
        QCOMPARE(model.position(), 1);
        QTRY_COMPARE_WITH_TIMEOUT(model.position(), 2, 1000);
    }

    // The library the caller hands in is the profile's view: a Kids profile's
    // hero holds only what its policy allows.
    void aKidsProfileIsSpotlitOnlyWhatItsPolicyAllows()
    {
        QVector<MediaItem> items;
        MediaItem kids = movie(QStringLiteral("Wonder"), 2017, daysAgo(20), true);
        kids.relativePath = QStringLiteral("Kids/Wonder (2017).mkv");
        MediaItem family = movie(QStringLiteral("WALL-E"), 2008, daysAgo(30), true);
        family.relativePath = QStringLiteral("Family/WALL-E (2008).mkv");
        MediaItem adult = movie(QStringLiteral("Heat"), 1995, daysAgo(1), true);
        adult.relativePath = QStringLiteral("Drama/Heat (1995).mkv");
        adult.resumePositionMs = 60'000;
        adult.lastPlayedAt = daysAgo(1);
        items = {kids, family, adult};

        const int kidsLevel = static_cast<int>(ProfileStore::Maturity::Kids);
        const QVector<MediaItem> allowed = content_policy::filtered(kidsLevel, items);
        QVERIFY(allowed.size() < items.size());

        HomeRowsModel model;
        model.replaceItems(allowed);
        QVERIFY(model.hero()->count() > 0);
        for (int index = 0; index < model.hero()->count(); ++index) {
            const QString title = model.hero()->spotlightAt(index).value(QStringLiteral("title")).toString();
            QVERIFY2(title != QStringLiteral("Heat"), "an adult title reached the Kids hero");
        }
        // The adult title was the one in progress; the Kids hero does not open
        // with Continue Watching.
        QVERIFY(model.hero()->spotlightAt(0).value(QStringLiteral("category")).toString()
                != QStringLiteral("Continue Watching"));

        model.replaceItems(items);
        QVERIFY(model.hero()->spotlightAt(0).value(QStringLiteral("category")).toString()
                == QStringLiteral("Continue Watching"));
    }

    // The model recomposes the carousel with the rows, so a viewing recorded
    // while Home is up reaches the hero without a rescan.
    void aRecordedViewingMovesContinueWatchingIntoTheHero()
    {
        HomeRowsModel model;
        const QVector<MediaItem> items = library(6);
        model.replaceItems(items);
        QVERIFY(model.hero()->spotlightAt(0).value(QStringLiteral("category")).toString()
                != QStringLiteral("Continue Watching"));
        model.applyWatchProgress(items.at(3).id, 120'000, 7'200'000, false);
        const QVariantMap first = model.hero()->spotlightAt(0);
        QCOMPARE(first.value(QStringLiteral("category")).toString(), QStringLiteral("Continue Watching"));
        QCOMPARE(first.value(QStringLiteral("mediaId")).toString(), items.at(3).id);
    }

    // HomeDetailView.swift:21, :94, :1128-1134: the remote starts on the first
    // hero item; with no spotlight, there is no hero to be on.
    void homeStartsOnTheHeroAndHasNoneForAnEmptyLibrary()
    {
        HomeRowsModel model;
        QVERIFY(!model.heroFocused());
        model.replaceItems(library(4));
        QVERIFY(model.heroFocused());
        QCOMPARE(model.hero()->currentIndex(), 0);
        model.replaceItems({});
        QVERIFY(!model.heroFocused());
        QCOMPARE(model.hero()->count(), 0);
    }

    // :52-65, :985-991: Left and Right wrap the hero, Down is the first row,
    // Up from it is the hero again, and Up from the hero is the capsule.
    void theRemoteWalksHeroRowsAndCapsule()
    {
        HomeRowsModel model;
        model.replaceItems(library(6));
        QVERIFY(model.heroFocused());
        const int slides = model.hero()->count();
        QVERIFY(slides >= 2);

        QVERIFY(model.moveRight());
        QCOMPARE(model.hero()->currentIndex(), 1);
        QVERIFY(model.moveLeft());
        QVERIFY(model.moveLeft());
        QCOMPARE(model.hero()->currentIndex(), slides - 1);
        QVERIFY(model.heroFocused());
        // Left never hands the remote to the sidebar from the hero.
        QCOMPARE(model.focus()->row(), 0);

        QSignalSpy heroChanged(&model, &HomeRowsModel::heroFocusedChanged);
        QVERIFY(model.moveDown());
        QVERIFY(!model.heroFocused());
        QCOMPARE(heroChanged.count(), 1);
        QCOMPARE(model.focus()->row(), 0);
        QCOMPARE(model.focus()->column(), 0);
        QVERIFY(!model.playSomethingFocused());

        // Left at the first card is the sidebar's, as before.
        QVERIFY(!model.moveLeft());

        QVERIFY(model.moveUp());
        QVERIFY(model.heroFocused());
        QCOMPARE(heroChanged.count(), 2);
        QCOMPARE(model.hero()->currentIndex(), slides - 1);

        QVERIFY(model.moveUp());
        QVERIFY(model.playSomethingFocused());
        QVERIFY(!model.heroFocused());
        // The capsule holds Left and Right.
        QVERIFY(model.moveLeft());
        QVERIFY(model.moveRight());
        QCOMPARE(model.hero()->currentIndex(), slides - 1);

        QVERIFY(model.moveDown());
        QVERIFY(model.heroFocused());
        QVERIFY(!model.playSomethingFocused());
    }

    // The first row is the hero's Down target whichever row the cards last
    // rested on.
    void downFromTheHeroEntersTheFirstRowAtItsRememberedColumn()
    {
        HomeRowsModel model;
        model.replaceItems(library(6));
        QVERIFY(model.moveDown());
        QVERIFY(model.moveRight());
        QVERIFY(model.moveRight());
        QCOMPARE(model.focus()->column(), 2);
        QVERIFY(model.moveUp());
        QVERIFY(model.heroFocused());
        QVERIFY(model.moveDown());
        QCOMPARE(model.focus()->row(), 0);
        QCOMPARE(model.focus()->column(), 2);
    }

    // A pointer on a card or on the hero moves the remote there.
    void aPointerTakesTheRemoteToWhatItTouches()
    {
        HomeRowsModel model;
        model.replaceItems(library(6));
        model.focusCard(1, 1);
        QVERIFY(!model.heroFocused());
        QCOMPARE(model.focus()->row(), 1);
        model.focusHero();
        QVERIFY(model.heroFocused());
        QCOMPARE(model.focus()->row(), 1);

        HomeRowsModel empty;
        empty.replaceItems({});
        empty.focusHero();
        QVERIFY(!empty.heroFocused());
    }

    // The rows' own rules are untouched by the hero: the focus memory by row
    // and card survives a recomposition while the remote is on the rows.
    void theRowsKeepTheirFocusMemoryAroundTheHero()
    {
        HomeRowsModel model;
        const QVector<MediaItem> items = library(6);
        model.replaceItems(items);
        QVERIFY(model.moveDown());
        QVERIFY(model.moveDown());
        const int row = model.focus()->row();
        QCOMPARE(row, 1);
        const QString card = model.cardAt(row, model.focus()->column()).value(QStringLiteral("mediaId")).toString();
        model.applyWatchProgress(items.at(5).id, 10'000, 7'200'000, false);
        QVERIFY(!model.heroFocused());
        QVERIFY(model.focus()->row() >= 0);
        QVERIFY(!card.isEmpty());
    }
};

QTEST_MAIN(HeroSpotlightTest)

#include "tst_hero_spotlight.moc"
