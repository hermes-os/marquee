#include "playback/NextEpisodeCard.hpp"

#include <QtMath>

#include <algorithm>

#include "playback/AutoPlayPolicy.hpp"

NextEpisodeCard::NextEpisodeCard(QObject *parent)
    : QObject(parent)
{
}

double NextEpisodeCard::position() const
{
    return m_position;
}

void NextEpisodeCard::setPosition(double seconds)
{
    if (qFuzzyCompare(m_position, seconds)) {
        return;
    }
    m_position = seconds;
    emit positionChanged();
    update();
}

double NextEpisodeCard::duration() const
{
    return m_duration;
}

void NextEpisodeCard::setDuration(double seconds)
{
    if (qFuzzyCompare(m_duration, seconds)) {
        return;
    }
    m_duration = seconds;
    emit durationChanged();
    update();
}

double NextEpisodeCard::speed() const
{
    return m_speed;
}

void NextEpisodeCard::setSpeed(double speed)
{
    if (qFuzzyCompare(m_speed, speed)) {
        return;
    }
    m_speed = speed;
    emit speedChanged();
    update();
}

bool NextEpisodeCard::allowed() const
{
    return m_allowed;
}

void NextEpisodeCard::setAllowed(bool allowed)
{
    if (m_allowed == allowed) {
        return;
    }
    m_allowed = allowed;
    emit allowedChanged();
    update();
}

bool NextEpisodeCard::shown() const
{
    return m_shown;
}

int NextEpisodeCard::secondsLeft() const
{
    return m_secondsLeft;
}

bool NextEpisodeCard::hiddenForEpisode() const
{
    return m_hidden;
}

void NextEpisodeCard::hide()
{
    if (m_hidden) {
        return;
    }
    m_hidden = true;
    emit hiddenForEpisodeChanged();
    update();
}

void NextEpisodeCard::reset()
{
    if (m_hidden) {
        m_hidden = false;
        emit hiddenForEpisodeChanged();
    }
    update();
}

void NextEpisodeCard::update()
{
    const double lead = next_episode::cardLeadSeconds(m_duration);
    const bool inWindow = m_allowed && lead > 0.0 && m_position >= m_duration - lead
        && m_position <= m_duration;
    const bool shown = inWindow && !m_hidden;

    // The countdown is the wait that is left, so a film played faster counts
    // down faster.
    const double remaining = std::max(0.0, m_duration - m_position);
    const int seconds = shown ? static_cast<int>(std::ceil(remaining / std::max(0.1, m_speed))) : 0;

    const bool shownChangedNow = shown != m_shown;
    const bool secondsChangedNow = seconds != m_secondsLeft;
    m_shown = shown;
    m_secondsLeft = seconds;
    if (secondsChangedNow) {
        emit secondsLeftChanged();
    }
    if (shownChangedNow) {
        emit shownChanged();
    }
}
