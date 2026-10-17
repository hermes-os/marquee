#pragma once

#include <QtGlobal>

#include <functional>

/// When the next-episode card appears for an episode of a given length.
namespace next_episode
{
/// An episode shorter than this has no card: it is a cartoon or a clip, and a
/// card over a third of it would be in the way.
constexpr double kCardMinimumDurationSeconds = 10.0 * 60.0;

/// How long before the end of the file the card appears: 30 s, 35 s for an
/// episode of 40 minutes or more and 40 s for 50 minutes or more, the longer
/// credits of the longer episodes. Zero when the length is unknown or under
/// ten minutes, which is "no card".
[[nodiscard]] double cardLeadSeconds(double durationSeconds);
}

/// The "Still watching?" rule: after `kAutoPlayedEpisodes` episodes in a row
/// that auto-play started, and `kIdleLimitMs` with no remote key or pointer
/// input, the next end asks instead of starting another episode.
namespace still_watching
{
constexpr int kAutoPlayedEpisodes = 3;
constexpr qint64 kIdleLimitMs = 90LL * 60 * 1000;

[[nodiscard]] bool isDue(int autoPlayedInARow, qint64 idleMs);
}

/// Counts what `still_watching::isDue` judges. Time comes from an injectable
/// monotonic clock (milliseconds), so a test moves it by hand.
class StillWatchingTracker
{
public:
    StillWatchingTracker();

    /// Replaces the clock. Production code never calls this.
    void setClockForTest(std::function<qint64()> clock);

    /// A remote key or pointer input: both counts start over.
    void noteInput();
    /// The next episode was started by auto-play at the end of the last one.
    void noteAutoPlayed();

    [[nodiscard]] int autoPlayedInARow() const;
    [[nodiscard]] qint64 idleMs() const;
    [[nodiscard]] bool isDue() const;

private:
    std::function<qint64()> m_clock;
    qint64 m_lastInputMs{0};
    int m_autoPlayedInARow{0};
};
