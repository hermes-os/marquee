#include "playback/SeekScrubber.hpp"

#include <algorithm>
#include <cmath>
#include <utility>

namespace
{
// Short enough that a release is never judged more than a frame late, long
// enough to cost nothing: the timer only runs while a key is down.
constexpr int kPollIntervalMs = 20;
}

SeekScrubber::SeekScrubber(QObject *parent)
    : QObject(parent)
{
    m_elapsed.start();
    m_clock = [this] { return m_elapsed.elapsed(); };

    m_timer.setInterval(kPollIntervalMs);
    m_timer.setTimerType(Qt::PreciseTimer);
    connect(&m_timer, &QTimer::timeout, this, &SeekScrubber::poll);
}

double SeekScrubber::stepForTick(int tick)
{
    if (tick < 10) {
        return 1.0;
    }
    if (tick < 25) {
        return 2.0;
    }
    if (tick < 45) {
        return 5.0;
    }
    return 10.0;
}

double SeekScrubber::position() const
{
    return m_position;
}

void SeekScrubber::setPosition(double seconds)
{
    if (m_position == seconds) {
        return;
    }
    m_position = seconds;
    emit positionChanged();
    if (!m_scrubbing) {
        m_target = seconds;
        emit targetChanged();
    }
}

double SeekScrubber::duration() const
{
    return m_duration;
}

void SeekScrubber::setDuration(double seconds)
{
    if (m_duration == seconds) {
        return;
    }
    m_duration = seconds;
    emit durationChanged();
}

bool SeekScrubber::paused() const
{
    return m_paused;
}

void SeekScrubber::setPaused(bool paused)
{
    if (m_paused == paused) {
        return;
    }
    m_paused = paused;
    emit pausedChanged();
}

bool SeekScrubber::scrubbing() const
{
    return m_scrubbing;
}

double SeekScrubber::target() const
{
    return m_target;
}

void SeekScrubber::setClockForTest(std::function<qint64()> clock)
{
    m_clock = std::move(clock);
}

qint64 SeekScrubber::now() const
{
    return m_clock();
}

double SeekScrubber::clamped(double seconds) const
{
    // PlayerView.swift:540-546: never before the start, never past a known end.
    const double lowerBounded = std::max(0.0, seconds);
    return m_duration > 0.0 && std::isfinite(m_duration) ? std::min(lowerBounded, m_duration)
                                                         : lowerBounded;
}

void SeekScrubber::press(int direction)
{
    if ((direction != -1 && direction != 1) || m_direction != 0) {
        return;
    }
    m_direction = direction;
    m_pressedAt = now();
    m_timer.start();
}

void SeekScrubber::release(int direction)
{
    if (m_direction == 0 || m_direction != direction) {
        return;
    }

    // A release that arrives before the timer noticed the half second is
    // still the end of a hold.
    poll();

    if (m_scrubbing) {
        const double landing = m_target;
        const bool resume = !m_wasPausedBeforeScrub;
        endHold();
        emit seekRequested(landing);
        if (resume) {
            emit pauseRequested(false);
        }
        return;
    }

    endHold();
    skip(direction < 0 ? kTapBackSeconds : kTapForwardSeconds);
}

void SeekScrubber::cancel()
{
    if (m_direction == 0) {
        return;
    }
    const bool resume = m_scrubbing && !m_wasPausedBeforeScrub;
    endHold();
    if (resume) {
        emit pauseRequested(false);
    }
}

void SeekScrubber::skip(double seconds)
{
    if (m_scrubbing) {
        return;
    }
    emit skipRequested(seconds);
}

void SeekScrubber::poll()
{
    if (m_direction == 0) {
        return;
    }

    const qint64 current = now();
    if (!m_scrubbing) {
        if (current - m_pressedAt < kHoldThresholdMs) {
            return;
        }
        beginScrub();
    }

    // The first tick is due the moment the hold is recognised, then one more
    // for every full tick since.
    const qint64 due = (current - m_scrubStart) / kTickMs + 1;
    const double before = m_target;
    while (m_ticksApplied < due) {
        m_target = clamped(m_target + m_direction * stepForTick(m_ticksApplied));
        ++m_ticksApplied;
    }
    if (m_target != before) {
        emit targetChanged();
    }
}

void SeekScrubber::beginScrub()
{
    m_scrubbing = true;
    m_scrubStart = m_pressedAt + kHoldThresholdMs;
    m_ticksApplied = 0;
    m_wasPausedBeforeScrub = m_paused;
    m_target = m_position;
    emit scrubbingChanged();
    emit pauseRequested(true);
}

void SeekScrubber::endHold()
{
    m_timer.stop();
    m_direction = 0;
    const bool wasScrubbing = m_scrubbing;
    m_scrubbing = false;
    m_ticksApplied = 0;
    const double before = m_target;
    m_target = m_position;
    if (wasScrubbing) {
        emit scrubbingChanged();
    }
    if (m_target != before) {
        emit targetChanged();
    }
}
