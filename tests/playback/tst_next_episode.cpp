#include <QSignalSpy>
#include <QTest>
#include <QVector>

#include "catalog/MediaItem.hpp"
#include "models/ShowsModel.hpp"
#include "playback/AutoPlayPolicy.hpp"
#include "playback/NextEpisodeCard.hpp"

namespace
{
[[nodiscard]] MediaItem episode(const QString &id, int season, int number)
{
    MediaItem item;
    item.id = id;
    item.showName = QStringLiteral("Show");
    item.mediaKind = QStringLiteral("episode");
    item.seasonNumber = season;
    item.episodeNumber = number;
    return item;
}

[[nodiscard]] QString nextId(QVector<MediaItem> episodes, const QString &id)
{
    show_order::sortEpisodes(episodes);
    for (int index = 0; index < episodes.size(); ++index) {
        if (episodes.at(index).id == id) {
            const int next = show_order::nextEpisodeIndexAfter(episodes, index);
            return next < 0 ? QString() : episodes.at(next).id;
        }
    }
    return QStringLiteral("<missing>");
}
}

/// The rules of the next-episode flow that are plain functions: how early the
/// card comes, which episode follows, and when to ask "Still watching?".
class NextEpisodeTest final : public QObject
{
    Q_OBJECT

    qint64 m_now{0};

private slots:
    void theCardLeadGrowsWithTheEpisodeLength()
    {
        // Under ten minutes there is no card at all.
        QCOMPARE(next_episode::cardLeadSeconds(0.0), 0.0);
        QCOMPARE(next_episode::cardLeadSeconds(-5.0), 0.0);
        QCOMPARE(next_episode::cardLeadSeconds(9 * 60 + 59.0), 0.0);
        QCOMPARE(next_episode::cardLeadSeconds(10 * 60.0), 30.0);
        QCOMPARE(next_episode::cardLeadSeconds(22 * 60.0), 30.0);
        QCOMPARE(next_episode::cardLeadSeconds(40 * 60.0 - 1), 30.0);
        QCOMPARE(next_episode::cardLeadSeconds(40 * 60.0), 35.0);
        QCOMPARE(next_episode::cardLeadSeconds(50 * 60.0 - 1), 35.0);
        QCOMPARE(next_episode::cardLeadSeconds(50 * 60.0), 40.0);
        QCOMPARE(next_episode::cardLeadSeconds(3 * 3600.0), 40.0);
    }

    void theNextEpisodeFollowsAiredOrder()
    {
        // Listed out of order on purpose: the order is the show's, not the
        // catalog's.
        const QVector<MediaItem> show{episode(QStringLiteral("s1e2"), 1, 2),
                                      episode(QStringLiteral("s1e1"), 1, 1),
                                      episode(QStringLiteral("s2e1"), 2, 1)};
        QCOMPARE(nextId(show, QStringLiteral("s1e1")), QStringLiteral("s1e2"));
    }

    void theNextEpisodeCrossesIntoTheNextSeason()
    {
        const QVector<MediaItem> show{episode(QStringLiteral("s1e1"), 1, 1),
                                      episode(QStringLiteral("s1e2"), 1, 2),
                                      episode(QStringLiteral("s2e1"), 2, 1)};
        QCOMPARE(nextId(show, QStringLiteral("s1e2")), QStringLiteral("s2e1"));
    }

    void aSecondCopyOfTheSameEpisodeIsNotTheNextOne()
    {
        const QVector<MediaItem> show{episode(QStringLiteral("a-s1e1"), 1, 1),
                                      episode(QStringLiteral("b-s1e1"), 1, 1),
                                      episode(QStringLiteral("s1e2"), 1, 2)};
        // Whichever copy plays, the next one is the following episode, and
        // the copy that sorts later is never offered.
        QCOMPARE(nextId(show, QStringLiteral("a-s1e1")), QStringLiteral("s1e2"));
        QCOMPARE(nextId(show, QStringLiteral("b-s1e1")), QStringLiteral("s1e2"));
    }

    void theFinaleAndAnUnknownIndexHaveNoNextEpisode()
    {
        const QVector<MediaItem> show{episode(QStringLiteral("s1e1"), 1, 1),
                                      episode(QStringLiteral("s1e2"), 1, 2)};
        QCOMPARE(nextId(show, QStringLiteral("s1e2")), QString());
        QCOMPARE(show_order::nextEpisodeIndexAfter(show, -1), -1);
        QCOMPARE(show_order::nextEpisodeIndexAfter(show, 2), -1);

        // A show whose last season holds two copies of its finale ends there.
        const QVector<MediaItem> copies{episode(QStringLiteral("s1e1"), 1, 1),
                                        episode(QStringLiteral("a-s1e2"), 1, 2),
                                        episode(QStringLiteral("b-s1e2"), 1, 2)};
        QCOMPARE(nextId(copies, QStringLiteral("a-s1e2")), QString());
    }

    void showsModelAgreesWithTheOrderHelper()
    {
        ShowsModel shows;
        shows.replaceItems({episode(QStringLiteral("s1e2"), 1, 2),
                            episode(QStringLiteral("s2e1"), 2, 1),
                            episode(QStringLiteral("s1e1"), 1, 1),
                            episode(QStringLiteral("dup-s2e1"), 2, 1)});
        QCOMPARE(shows.nextEpisodeId(QStringLiteral("s1e1")), QStringLiteral("s1e2"));
        QCOMPARE(shows.nextEpisodeId(QStringLiteral("s1e2")), QStringLiteral("s2e1"));
        QCOMPARE(shows.nextEpisodeId(QStringLiteral("s2e1")), QString());
        QCOMPARE(shows.nextEpisodeId(QStringLiteral("not-an-episode")), QString());
    }

    void stillWatchingNeedsThreeAutoPlaysAndNinetyIdleMinutes()
    {
        constexpr qint64 minute = 60 * 1000;
        QVERIFY(!still_watching::isDue(0, 0));
        QVERIFY(!still_watching::isDue(2, 200 * minute));
        QVERIFY(!still_watching::isDue(3, 90 * minute - 1));
        QVERIFY(still_watching::isDue(3, 90 * minute));
        QVERIFY(still_watching::isDue(9, 500 * minute));
    }

    void theTrackerCountsAutoPlaysAndIdleTimeOnItsClock()
    {
        constexpr qint64 minute = 60 * 1000;
        StillWatchingTracker tracker;
        m_now = 1000 * minute;
        tracker.setClockForTest([this] { return m_now; });

        // Three episodes hand over by themselves while nobody touches
        // anything; each is 45 minutes.
        for (int played = 0; played < 3; ++played) {
            QVERIFY2(!tracker.isDue(), "asked before the third auto-play");
            m_now += 45 * minute;
            tracker.noteAutoPlayed();
        }
        QCOMPARE(tracker.autoPlayedInARow(), 3);
        QCOMPARE(tracker.idleMs(), 135 * minute);
        QVERIFY(tracker.isDue());
    }

    void anInputResetsBothCounts()
    {
        constexpr qint64 minute = 60 * 1000;
        StillWatchingTracker tracker;
        m_now = 0;
        tracker.setClockForTest([this] { return m_now; });
        for (int played = 0; played < 3; ++played) {
            tracker.noteAutoPlayed();
        }
        m_now = 100 * minute;
        QVERIFY(tracker.isDue());

        tracker.noteInput();
        QCOMPARE(tracker.autoPlayedInARow(), 0);
        QCOMPARE(tracker.idleMs(), 0);
        QVERIFY(!tracker.isDue());

        // Long idle alone, or many auto-plays alone, never ask.
        m_now += 200 * minute;
        QVERIFY(!tracker.isDue());
        for (int played = 0; played < 5; ++played) {
            tracker.noteAutoPlayed();
        }
        tracker.noteInput();
        m_now += 10 * minute;
        QVERIFY(!tracker.isDue());
    }

    void theCardAppearsAtTheLeadTimeAndCountsDownToTheEnd()
    {
        NextEpisodeCard card;
        QSignalSpy shown(&card, &NextEpisodeCard::shownChanged);
        card.setAllowed(true);
        card.setDuration(22 * 60.0);

        card.setPosition(22 * 60.0 - 31.0);
        QVERIFY(!card.shown());
        card.setPosition(22 * 60.0 - 30.0);
        QVERIFY(card.shown());
        QCOMPARE(card.secondsLeft(), 30);
        card.setPosition(22 * 60.0 - 12.4);
        QCOMPARE(card.secondsLeft(), 13);
        QCOMPARE(shown.count(), 1);

        // A longer episode comes earlier.
        card.setDuration(45 * 60.0);
        card.setPosition(45 * 60.0 - 36.0);
        QVERIFY(!card.shown());
        card.setPosition(45 * 60.0 - 35.0);
        QVERIFY(card.shown());
        card.setDuration(55 * 60.0);
        card.setPosition(55 * 60.0 - 40.0);
        QVERIFY(card.shown());
        QCOMPARE(card.secondsLeft(), 40);
    }

    void theCardNeverComesForShortEpisodesOrWithoutANextEpisode()
    {
        NextEpisodeCard card;
        card.setAllowed(true);
        card.setDuration(9 * 60.0);
        card.setPosition(9 * 60.0 - 5.0);
        QVERIFY(!card.shown());

        card.setDuration(30 * 60.0);
        card.setPosition(30 * 60.0 - 5.0);
        QVERIFY(card.shown());
        card.setAllowed(false);
        QVERIFY(!card.shown());
        QCOMPARE(card.secondsLeft(), 0);
    }

    void hidingKeepsTheCardAwayUntilTheNextEpisodeStarts()
    {
        NextEpisodeCard card;
        card.setAllowed(true);
        card.setDuration(30 * 60.0);
        card.setPosition(30 * 60.0 - 20.0);
        QVERIFY(card.shown());

        card.hide();
        QVERIFY(!card.shown());
        QVERIFY(card.hiddenForEpisode());
        // Seeking back out of the window and into it again stays hidden.
        card.setPosition(100.0);
        card.setPosition(30 * 60.0 - 20.0);
        QVERIFY(!card.shown());

        card.reset();
        QVERIFY(card.shown());
    }

    void seekingBackBeforeTheLeadTimeRemovesTheCardAndReachingItAgainShowsIt()
    {
        NextEpisodeCard card;
        card.setAllowed(true);
        card.setDuration(30 * 60.0);
        card.setPosition(30 * 60.0 - 20.0);
        QVERIFY(card.shown());

        card.setPosition(30 * 60.0 - 60.0);
        QVERIFY(!card.shown());
        QCOMPARE(card.secondsLeft(), 0);
        card.setPosition(30 * 60.0 - 29.0);
        QVERIFY(card.shown());
    }
};

QTEST_MAIN(NextEpisodeTest)
#include "tst_next_episode.moc"
