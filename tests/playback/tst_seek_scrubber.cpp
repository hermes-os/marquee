#include <QSignalSpy>
#include <QTest>

#include "playback/SeekScrubber.hpp"

namespace
{
// The released ticks, PlayerView.swift:490-500, summed: 1 s for the first 10,
// 2 s up to the 25th, 5 s up to the 45th, then 10 s.
constexpr double scrubbedAfter(int ticks)
{
    double total = 0.0;
    for (int tick = 0; tick < ticks; ++tick) {
        total += SeekScrubber::stepForTick(tick);
    }
    return total;
}
}

/// The Left and Right keys with a clock the test moves by hand, so the half
/// second and the 0.1 s ticks are judged exactly rather than by waiting.
class SeekScrubberTest final : public QObject
{
    Q_OBJECT

private:
    qint64 m_now{0};

    void startAt(SeekScrubber &scrubber, double position, double duration = 7200.0,
                 bool paused = false)
    {
        m_now = 0;
        scrubber.setClockForTest([this] { return m_now; });
        scrubber.setDuration(duration);
        scrubber.setPosition(position);
        scrubber.setPaused(paused);
    }

private slots:
    void aTapBackStepsTenSecondsAndAForwardTapThirty()
    {
        SeekScrubber scrubber;
        startAt(scrubber, 100.0);
        QSignalSpy skipped(&scrubber, &SeekScrubber::skipRequested);
        QSignalSpy paused(&scrubber, &SeekScrubber::pauseRequested);

        scrubber.press(-1);
        m_now = 120;
        scrubber.release(-1);
        scrubber.press(1);
        m_now = 260;
        scrubber.release(1);

        QCOMPARE(skipped.count(), 2);
        QCOMPARE(skipped.at(0).at(0).toDouble(), -10.0);
        QCOMPARE(skipped.at(1).at(0).toDouble(), 30.0);
        QCOMPARE(paused.count(), 0);
        QVERIFY(!scrubber.scrubbing());
    }

    void aKeyHeldForExactlyHalfASecondIsAScrubNotATap()
    {
        SeekScrubber scrubber;
        startAt(scrubber, 100.0);
        QSignalSpy skipped(&scrubber, &SeekScrubber::skipRequested);

        scrubber.press(1);
        m_now = 499;
        scrubber.poll();
        QVERIFY(!scrubber.scrubbing());

        m_now = 500;
        scrubber.poll();
        QVERIFY(scrubber.scrubbing());
        scrubber.release(1);
        QCOMPARE(skipped.count(), 0);
    }

    void aHoldPausesTheFilmAndReleaseSeeksToWhereItGotAndResumes()
    {
        SeekScrubber scrubber;
        startAt(scrubber, 100.0);
        QSignalSpy skipped(&scrubber, &SeekScrubber::skipRequested);
        QSignalSpy seeks(&scrubber, &SeekScrubber::seekRequested);
        QSignalSpy pauses(&scrubber, &SeekScrubber::pauseRequested);

        scrubber.press(1);
        m_now = 500;
        scrubber.poll();
        QCOMPARE(pauses.count(), 1);
        QCOMPARE(pauses.at(0).at(0).toBool(), true);
        // The first tick lands the moment the hold is recognised.
        QCOMPARE(scrubber.target(), 101.0);

        m_now = 800;
        scrubber.poll();
        QCOMPARE(scrubber.target(), 104.0);

        m_now = 830;
        scrubber.release(1);
        QCOMPARE(seeks.count(), 1);
        QCOMPARE(seeks.at(0).at(0).toDouble(), 104.0);
        QCOMPARE(pauses.count(), 2);
        QCOMPARE(pauses.at(1).at(0).toBool(), false);
        QCOMPARE(skipped.count(), 0);
        QVERIFY(!scrubber.scrubbing());
        // The picture has not moved yet, so the target falls back to it.
        QCOMPARE(scrubber.target(), 100.0);
    }

    void theScrubAcceleratesAsTheReleasedAppDoes()
    {
        SeekScrubber scrubber;
        startAt(scrubber, 1000.0);

        scrubber.press(1);
        // (ticks applied, seconds scrubbed): the first ten ticks are 1 s, the
        // next fifteen 2 s, the next twenty 5 s, every later one 10 s.
        const QList<QPair<int, double>> expected{
            {1, 1.0}, {10, 10.0}, {11, 12.0}, {25, 40.0}, {26, 45.0}, {45, 140.0}, {46, 150.0},
            {60, 290.0}};
        for (const auto &[ticks, seconds] : expected) {
            QCOMPARE(scrubbedAfter(ticks), seconds);
            m_now = 500 + (ticks - 1) * 100;
            scrubber.poll();
            QCOMPARE(scrubber.target(), 1000.0 + seconds);
        }
    }

    void aBackwardScrubAcceleratesTheSameWay()
    {
        SeekScrubber scrubber;
        startAt(scrubber, 1000.0);
        scrubber.press(-1);
        m_now = 500 + 24 * 100;
        scrubber.poll();
        QCOMPARE(scrubber.target(), 1000.0 - 40.0);
    }

    // A timer that was late must not scrub less than an on-time one.
    void aLatePollCatchesUpOnEveryTickItMissed()
    {
        SeekScrubber scrubber;
        startAt(scrubber, 1000.0);
        scrubber.press(1);
        m_now = 500 + 44 * 100;
        scrubber.poll();
        QCOMPARE(scrubber.target(), 1000.0 + 140.0);
    }

    void aReleaseThatBeatsTheTimerIsStillTheEndOfAHold()
    {
        SeekScrubber scrubber;
        startAt(scrubber, 100.0);
        QSignalSpy seeks(&scrubber, &SeekScrubber::seekRequested);
        QSignalSpy skipped(&scrubber, &SeekScrubber::skipRequested);

        scrubber.press(1);
        m_now = 700;
        scrubber.release(1);

        QCOMPARE(skipped.count(), 0);
        QCOMPARE(seeks.count(), 1);
        QCOMPARE(seeks.at(0).at(0).toDouble(), 103.0);
    }

    void aFilmThatWasPausedStaysPausedAfterAScrub()
    {
        SeekScrubber scrubber;
        startAt(scrubber, 100.0, 7200.0, true);
        QSignalSpy pauses(&scrubber, &SeekScrubber::pauseRequested);
        QSignalSpy seeks(&scrubber, &SeekScrubber::seekRequested);

        scrubber.press(-1);
        m_now = 600;
        scrubber.poll();
        m_now = 650;
        scrubber.release(-1);

        QCOMPARE(seeks.count(), 1);
        QCOMPARE(seeks.at(0).at(0).toDouble(), 98.0);
        // It was asked to pause (a no-op for a paused film) and never to play.
        for (const QList<QVariant> &call : pauses) {
            QCOMPARE(call.at(0).toBool(), true);
        }
    }

    void aScrubStopsAtTheStartAndAtTheEnd()
    {
        SeekScrubber scrubber;
        startAt(scrubber, 3.0, 20.0);
        scrubber.press(-1);
        m_now = 500 + 9 * 100;
        scrubber.poll();
        QCOMPARE(scrubber.target(), 0.0);
        scrubber.cancel();

        startAt(scrubber, 15.0, 20.0);
        scrubber.press(1);
        m_now = 500 + 9 * 100;
        scrubber.poll();
        QCOMPARE(scrubber.target(), 20.0);
    }

    void aSecondKeyWhileOneIsHeldIsIgnored()
    {
        SeekScrubber scrubber;
        startAt(scrubber, 100.0);
        QSignalSpy seeks(&scrubber, &SeekScrubber::seekRequested);
        QSignalSpy skipped(&scrubber, &SeekScrubber::skipRequested);

        scrubber.press(1);
        m_now = 100;
        scrubber.press(-1);
        scrubber.release(-1);
        m_now = 600;
        scrubber.poll();
        QVERIFY(scrubber.scrubbing());
        QCOMPARE(scrubber.target(), 102.0);
        QCOMPARE(skipped.count(), 0);

        scrubber.release(1);
        QCOMPARE(seeks.count(), 1);
    }

    void cancellingAHoldResumesAFilmItPausedAndSeeksNowhere()
    {
        SeekScrubber scrubber;
        startAt(scrubber, 100.0);
        QSignalSpy seeks(&scrubber, &SeekScrubber::seekRequested);
        QSignalSpy pauses(&scrubber, &SeekScrubber::pauseRequested);

        scrubber.press(1);
        m_now = 800;
        scrubber.poll();
        QVERIFY(scrubber.scrubbing());
        scrubber.cancel();

        QVERIFY(!scrubber.scrubbing());
        QCOMPARE(seeks.count(), 0);
        QCOMPARE(pauses.count(), 2);
        QCOMPARE(pauses.at(1).at(0).toBool(), false);

        // Nothing is held any more, so a stray release does nothing.
        scrubber.release(1);
        QCOMPARE(seeks.count(), 0);
    }

    void aButtonSkipIsIgnoredWhileAHoldScrubs()
    {
        SeekScrubber scrubber;
        startAt(scrubber, 100.0);
        QSignalSpy skipped(&scrubber, &SeekScrubber::skipRequested);

        scrubber.skip(30.0);
        QCOMPARE(skipped.count(), 1);

        scrubber.press(1);
        m_now = 600;
        scrubber.poll();
        scrubber.skip(30.0);
        QCOMPARE(skipped.count(), 1);
    }
};

QTEST_GUILESS_MAIN(SeekScrubberTest)

#include "tst_seek_scrubber.moc"
