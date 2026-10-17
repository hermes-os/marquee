#include "playback/AutoPlayPolicy.hpp"

#include <QElapsedTimer>

#include <memory>
#include <utility>

double next_episode::cardLeadSeconds(double durationSeconds)
{
    if (!(durationSeconds >= kCardMinimumDurationSeconds)) {
        return 0.0;
    }
    if (durationSeconds >= 50.0 * 60.0) {
        return 40.0;
    }
    if (durationSeconds >= 40.0 * 60.0) {
        return 35.0;
    }
    return 30.0;
}

bool still_watching::isDue(int autoPlayedInARow, qint64 idleMs)
{
    return autoPlayedInARow >= kAutoPlayedEpisodes && idleMs >= kIdleLimitMs;
}

StillWatchingTracker::StillWatchingTracker()
{
    auto elapsed = std::make_shared<QElapsedTimer>();
    elapsed->start();
    m_clock = [elapsed] { return elapsed->elapsed(); };
    m_lastInputMs = m_clock();
}

void StillWatchingTracker::setClockForTest(std::function<qint64()> clock)
{
    m_clock = std::move(clock);
    m_lastInputMs = m_clock();
    m_autoPlayedInARow = 0;
}

void StillWatchingTracker::noteInput()
{
    m_lastInputMs = m_clock();
    m_autoPlayedInARow = 0;
}

void StillWatchingTracker::noteAutoPlayed()
{
    ++m_autoPlayedInARow;
}

int StillWatchingTracker::autoPlayedInARow() const
{
    return m_autoPlayedInARow;
}

qint64 StillWatchingTracker::idleMs() const
{
    return m_clock() - m_lastInputMs;
}

bool StillWatchingTracker::isDue() const
{
    return still_watching::isDue(m_autoPlayedInARow, idleMs());
}
