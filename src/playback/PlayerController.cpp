#include "playback/PlayerController.hpp"

#include <QtGlobal>

#include "support/Logging.hpp"

namespace
{
// Watch progress is written on a cadence rather than on every position report,
// which libmpv sends for each frame.
constexpr int kProgressIntervalMs = 10'000;

// The last stretch of a film is its credits: stopping inside it means the film
// was watched. Files shorter than that stretch are judged by fraction alone,
// or every glance at a short file would count as having watched it.
constexpr qint64 kClosingCreditsMs = 5 * 60 * 1000;

// A resume point is worth keeping only once the viewer is past the opening
// stretch of a title (WatchProgressStore.swift:47, :66 drop anything under
// 120 s), so a glance at a film never replaces where they were. Titles shorter
// than the credits stretch are watched in one go and never resumed.
constexpr qint64 kMinimumResumeMs = 120 * 1000;
constexpr qint64 kMinimumResumableLengthMs = 5 * 60 * 1000;

[[nodiscard]] qint64 toMilliseconds(double seconds)
{
    return seconds > 0.0 ? static_cast<qint64>(seconds * 1000.0) : 0;
}
}

PlayerController::PlayerController(QObject *parent)
    : QObject(parent)
{
    m_progressTimer.setInterval(kProgressIntervalMs);
    connect(&m_progressTimer, &QTimer::timeout, this, &PlayerController::recordProgress);
}

QUrl PlayerController::currentFileUrl() const
{
    return m_currentFileUrl;
}

QString PlayerController::title() const
{
    return m_title;
}

QString PlayerController::subtitle() const
{
    return m_subtitle;
}

QString PlayerController::mediaId() const
{
    return m_mediaId;
}

double PlayerController::startPosition() const
{
    return static_cast<double>(m_startPositionMs) / 1000.0;
}

bool PlayerController::watchedToTheEnd(qint64 positionMs, qint64 durationMs)
{
    if (durationMs <= 0) {
        return false;
    }

    const bool nearlyAllOfIt = positionMs * 10 >= durationMs * 9;
    const bool insideTheCredits = durationMs > kClosingCreditsMs
        && durationMs - positionMs <= kClosingCreditsMs;
    return nearlyAllOfIt || insideTheCredits;
}

bool PlayerController::isResumePoint(qint64 positionMs, qint64 durationMs)
{
    // A length not yet known cannot disqualify the title; it is judged again
    // when the length arrives.
    const bool shortTitle = durationMs > 0 && durationMs < kMinimumResumableLengthMs;
    return positionMs >= kMinimumResumeMs && !shortTitle;
}

void PlayerController::prepare(const QString &validatedLocalPath,
                               const QString &title,
                               const QString &mediaId,
                               qint64 resumePositionMs,
                               const QString &subtitle)
{
    endSession();

    m_mediaId = mediaId;
    m_paused = false;
    setStartPositionMs(resumePositionMs);

    const QUrl nextUrl = QUrl::fromLocalFile(validatedLocalPath);
    // The same file prepared again (an episode replayed from the start, or a
    // loose file reopened) must still reload, so the url change is announced
    // whenever a session begins.
    m_currentFileUrl = nextUrl;
    qCInfo(logPlayback) << "prepared" << validatedLocalPath;
    emit currentFileUrlChanged();

    if (m_title != title || m_subtitle != subtitle) {
        m_title = title;
        m_subtitle = subtitle;
        emit titleChanged();
    }

    if (!m_mediaId.isEmpty()) {
        m_progressTimer.start();
    }
}

void PlayerController::reportPlayback(double positionSeconds,
                                      double durationSeconds,
                                      bool paused)
{
    // A zero position is never recorded, so taking one could only erase where
    // the film actually got to. It is what a surface reports on its way out:
    // stopping unloads the file, and the session ends after that.
    if (positionSeconds <= 0.0) {
        return;
    }

    m_positionMs = toMilliseconds(positionSeconds);
    // libmpv learns a file's length after it has already reported positions
    // and reports it as unavailable again while the file unloads, so a
    // length once known is kept for the rest of the session and a zero never
    // replaces it. A row already written without the length gets it as soon
    // as it arrives.
    const qint64 reportedDurationMs = toMilliseconds(durationSeconds);
    if (reportedDurationMs > 0) {
        const bool lengthArrived = m_durationMs <= 0;
        m_durationMs = reportedDurationMs;
        if (lengthArrived && m_recordedWithoutDuration) {
            recordProgress();
        }
    }

    if (m_paused == paused) {
        return;
    }
    m_paused = paused;
    // Pausing is the viewer stepping away, which is exactly when the position
    // on screen should already be the stored one. Nothing moves while paused,
    // so the cadence waits for playback to resume.
    if (m_paused) {
        m_progressTimer.stop();
        recordProgress();
    } else if (!m_mediaId.isEmpty()) {
        m_progressTimer.start();
    }
}

void PlayerController::reportRestart()
{
    if (m_mediaId.isEmpty()) {
        return;
    }

    // A zero position is already what every surface reads as the beginning, so
    // a restart is recorded as one rather than as a completion or a missing
    // row. The film is being watched again, not finished.
    // The sequence orders it against every other recorded point, so an
    // acknowledgement of an older resume point cannot revert the restart.
    m_positionMs = 0;
    ++m_progressSequence;
    emit progressRecorded(m_mediaId, 0, m_durationMs, false, m_progressSequence);
}

void PlayerController::endSession()
{
    m_progressTimer.stop();
    recordProgress();
    m_mediaId.clear();
    m_positionMs = 0;
    m_durationMs = 0;
    m_paused = false;
    m_recordedWithoutDuration = false;
}

void PlayerController::recordProgress()
{
    // A position of zero says nothing a missing row does not already say, and
    // reporting it would overwrite the resume point the session opened with
    // before playback has reached it.
    if (m_mediaId.isEmpty() || m_positionMs <= 0) {
        return;
    }

    const bool completed = watchedToTheEnd(m_positionMs, m_durationMs);
    // A position that is not a resume point writes nothing at all: recording
    // it would replace the older point the viewer actually got to. A title
    // watched through (nine tenths of it) is still marked watched however
    // short it is, but a few seconds into a title just over the credits
    // stretch is a peek, not the credits.
    const bool nearlyAllOfIt = m_positionMs * 10 >= m_durationMs * 9 && m_durationMs > 0;
    if (!isResumePoint(m_positionMs, m_durationMs) && !(completed && nearlyAllOfIt)) {
        return;
    }
    m_recordedWithoutDuration = m_durationMs <= 0;
    ++m_progressSequence;
    emit progressRecorded(
        m_mediaId, completed ? 0 : m_positionMs, m_durationMs, completed, m_progressSequence);
}

void PlayerController::setStartPositionMs(qint64 value)
{
    const qint64 next = qMax(qint64{0}, value);
    if (m_startPositionMs == next) {
        return;
    }
    m_startPositionMs = next;
    emit startPositionChanged();
}
