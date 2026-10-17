#pragma once

#include <QObject>
#include <QtQml/qqmlregistration.h>

/// When the next-episode card is up. The player screen feeds it the clock the
/// film reports and the screen draws what it says; the lead time, the
/// countdown and "hidden for this episode" are decided here
/// (`next_episode::cardLeadSeconds` in AutoPlayPolicy.hpp has the lead rule).
// Qt derives a wrapper from every QML-creatable type, so this cannot be final.
class NextEpisodeCard : public QObject
{
    Q_OBJECT
    QML_ELEMENT

    /// Where the film is, its length (0 when unknown) and the playback speed,
    /// as the player surface reports them.
    Q_PROPERTY(double position READ position WRITE setPosition NOTIFY positionChanged)
    Q_PROPERTY(double duration READ duration WRITE setDuration NOTIFY durationChanged)
    Q_PROPERTY(double speed READ speed WRITE setSpeed NOTIFY speedChanged)
    /// Whether this episode may show a card at all: it has a next episode and
    /// Auto-play Next Episode is on.
    Q_PROPERTY(bool allowed READ allowed WRITE setAllowed NOTIFY allowedChanged)
    Q_PROPERTY(bool shown READ shown NOTIFY shownChanged)
    /// The countdown the card reads, in seconds of waiting until the end of
    /// the file.
    Q_PROPERTY(int secondsLeft READ secondsLeft NOTIFY secondsLeftChanged)
    Q_PROPERTY(bool hiddenForEpisode READ hiddenForEpisode NOTIFY hiddenForEpisodeChanged)

public:
    explicit NextEpisodeCard(QObject *parent = nullptr);

    [[nodiscard]] double position() const;
    void setPosition(double seconds);
    [[nodiscard]] double duration() const;
    void setDuration(double seconds);
    [[nodiscard]] double speed() const;
    void setSpeed(double speed);
    [[nodiscard]] bool allowed() const;
    void setAllowed(bool allowed);
    [[nodiscard]] bool shown() const;
    [[nodiscard]] int secondsLeft() const;
    [[nodiscard]] bool hiddenForEpisode() const;

    /// The viewer chose Hide, or the episode ended: no card for the rest of
    /// this episode, however often the film is sought back to the lead time.
    Q_INVOKABLE void hide();
    /// A new episode (or a replay) begins: the card may show again.
    Q_INVOKABLE void reset();

signals:
    void positionChanged();
    void durationChanged();
    void speedChanged();
    void allowedChanged();
    void shownChanged();
    void secondsLeftChanged();
    void hiddenForEpisodeChanged();

private:
    void update();

    double m_position{0.0};
    double m_duration{0.0};
    double m_speed{1.0};
    bool m_allowed{false};
    bool m_hidden{false};
    bool m_shown{false};
    int m_secondsLeft{0};
};
