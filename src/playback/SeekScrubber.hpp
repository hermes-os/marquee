#pragma once

#include <functional>

#include <QElapsedTimer>
#include <QObject>
#include <QTimer>
#include <QtQml/qqmlregistration.h>

/// The Left and Right keys of the player: a tap steps back 10 s or forward
/// 30 s, and a hold of more than half a second scrubs, with the playing film
/// paused until the key is let go (PlayerView.swift:453-523, :465-476).
///
/// The scrubber decides and the player screen carries out: it asks for a seek
/// or a pause through its signals and never touches libmpv. Time comes from an
/// injectable clock, and what is due at a given time is worked out from that
/// clock rather than from how many timer events happened to arrive, so a
/// late timer scrubs as far as an on-time one would have.
// Qt derives a wrapper from every QML-creatable type, so this cannot be final.
class SeekScrubber : public QObject
{
    Q_OBJECT
    QML_ELEMENT

    /// Where the film is, its length (0 when unknown) and whether it is
    /// paused, as the player surface reports them.
    Q_PROPERTY(double position READ position WRITE setPosition NOTIFY positionChanged)
    Q_PROPERTY(double duration READ duration WRITE setDuration NOTIFY durationChanged)
    Q_PROPERTY(bool paused READ paused WRITE setPaused NOTIFY pausedChanged)
    /// True from the moment a hold is recognised until the key is let go.
    Q_PROPERTY(bool scrubbing READ scrubbing NOTIFY scrubbingChanged)
    /// Where letting go would seek to; the position itself when not scrubbing.
    Q_PROPERTY(double target READ target NOTIFY targetChanged)

public:
    /// PlayerView.swift:458: a key held this long is a scrub, not a tap.
    static constexpr qint64 kHoldThresholdMs = 500;
    /// PlayerView.swift:506: one scrub step per tick.
    static constexpr qint64 kTickMs = 100;
    /// PlayerView.swift:472, PlayerControlsOverlay.swift:378, :390.
    static constexpr double kTapBackSeconds = -10.0;
    static constexpr double kTapForwardSeconds = 30.0;

    explicit SeekScrubber(QObject *parent = nullptr);

    /// Seconds one scrub tick moves, PlayerView.swift:490-500: 1 s for the
    /// first 10 ticks, then 2 s up to tick 25, 5 s up to tick 45, then 10 s.
    [[nodiscard]] static double stepForTick(int tick);

    [[nodiscard]] double position() const;
    void setPosition(double seconds);
    [[nodiscard]] double duration() const;
    void setDuration(double seconds);
    [[nodiscard]] bool paused() const;
    void setPaused(bool paused);
    [[nodiscard]] bool scrubbing() const;
    [[nodiscard]] double target() const;

    /// Replaces the monotonic clock (milliseconds) so a test can move time by
    /// hand. Production code never calls this.
    void setClockForTest(std::function<qint64()> clock);

    /// A direction key went down: -1 for Left, +1 for Right. A second key
    /// while one is held is ignored, as the released app does
    /// (PlayerView.swift:454).
    Q_INVOKABLE void press(int direction);
    /// The key came up. A tap seeks; the end of a hold seeks to where the
    /// scrub got to and lets a film that was playing carry on.
    Q_INVOKABLE void release(int direction);
    /// Ends a hold without seeking, for a key-up that will never arrive (the
    /// window lost focus, the screen is going): a film the scrub paused
    /// resumes where it was.
    Q_INVOKABLE void cancel();
    /// A tap on the -10 or +30 button: the same step a key tap takes. Ignored
    /// while a hold is scrubbing.
    Q_INVOKABLE void skip(double seconds);
    /// Works out what the clock has made due. A timer calls it while a key is
    /// held; a test calls it after moving its clock.
    Q_INVOKABLE void poll();

signals:
    void positionChanged();
    void durationChanged();
    void pausedChanged();
    void scrubbingChanged();
    void targetChanged();
    /// Seek the film to this absolute second: the end of a hold.
    void seekRequested(double seconds);
    /// Move the film by this many seconds from wherever it is: a tap. Relative
    /// so that two quick taps add up instead of both aiming at a position
    /// libmpv has not yet reported past.
    void skipRequested(double seconds);
    /// Pause (true) or resume (false) the film.
    void pauseRequested(bool paused);
    /// A hold has just become a scrub; the picture should start following it.
    void scrubStarted();
    /// The scrub reached a new target: show the film there. Not the final
    /// seek, which only seekRequested carries.
    void previewRequested(double seconds);
    /// A hold ended without a seek (cancel): the picture goes back to where
    /// the hold began.
    void scrubCancelled();

private:
    [[nodiscard]] qint64 now() const;
    [[nodiscard]] double clamped(double seconds) const;
    void beginScrub();
    void endHold();

    std::function<qint64()> m_clock;
    QElapsedTimer m_elapsed;
    QTimer m_timer;
    double m_position{0.0};
    double m_duration{0.0};
    bool m_paused{false};
    bool m_scrubbing{false};
    double m_target{0.0};
    // The key being held, 0 when none.
    int m_direction{0};
    qint64 m_pressedAt{0};
    // When the hold became a scrub: the first tick is due at once.
    qint64 m_scrubStart{0};
    int m_ticksApplied{0};
    bool m_wasPausedBeforeScrub{false};
};
