#pragma once

#include <QObject>
#include <QString>
#include <QTimer>
#include <QUrl>

/// Playback session shell: it holds what the application chose to play so the
/// QML player surface renders an application decision rather than loading an
/// arbitrary file of its own, and it decides when what the surface reports
/// becomes a durable watch-progress row.
class PlayerController final : public QObject
{
    Q_OBJECT

    Q_PROPERTY(QUrl currentFileUrl READ currentFileUrl NOTIFY currentFileUrlChanged)
    Q_PROPERTY(QString title READ title NOTIFY titleChanged)
    /// PlayerView.swift:207-213: the episode line under the show name; empty
    /// for a movie.
    Q_PROPERTY(QString subtitle READ subtitle NOTIFY titleChanged)
    /// The catalog identity of the playing title; empty for a loose file.
    Q_PROPERTY(QString mediaId READ mediaId NOTIFY currentFileUrlChanged)
    Q_PROPERTY(double startPosition READ startPosition NOTIFY startPositionChanged)

public:
    explicit PlayerController(QObject *parent = nullptr);

    [[nodiscard]] QUrl currentFileUrl() const;
    [[nodiscard]] QString title() const;
    [[nodiscard]] QString subtitle() const;
    [[nodiscard]] QString mediaId() const;

    /// Seconds into the file the session should start at.
    [[nodiscard]] double startPosition() const;

    /// Opens `validatedLocalPath`, ending whatever session it replaces. A file
    /// played without a catalog identity records no progress, because there is
    /// no library row for a resume point to belong to.
    void prepare(const QString &validatedLocalPath,
                 const QString &title,
                 const QString &mediaId = QString(),
                 qint64 resumePositionMs = 0,
                 const QString &subtitle = QString());

    /// What libmpv is currently doing, as the player surface sees it. The
    /// controller keeps the policy that decides which of these become rows.
    Q_INVOKABLE void reportPlayback(double positionSeconds,
                                    double durationSeconds,
                                    bool paused);

    /// The surface sent the current title back to its beginning, so the
    /// session's position becomes the beginning too: leaving straight after a
    /// restart must not resume at the point the viewer restarted away from.
    Q_INVOKABLE void reportRestart();

    /// Records the session's last position and ends it, so a session already
    /// ended writes nothing more.
    void endSession();

    /// Whether a title left at `positionMs` of `durationMs` has been watched.
    /// A watched title starts again from the beginning rather than reopening
    /// on its credits.
    [[nodiscard]] static bool watchedToTheEnd(qint64 positionMs, qint64 durationMs);

    /// Whether a title left at `positionMs` of `durationMs` (0 when unknown)
    /// is stored as a place to resume: not before 120 s in, and never for a
    /// title under five minutes long. A position that is not leaves any
    /// older resume point as it was.
    [[nodiscard]] static bool isResumePoint(qint64 positionMs, qint64 durationMs);

signals:
    void currentFileUrlChanged();
    void titleChanged();
    void startPositionChanged();

    /// Where `mediaId` was left. A completed title reports a zero position,
    /// which is where playing it again starts. `sequence` rises with every
    /// row this controller records, so a listener that hears the same row
    /// twice, once directly and once echoed back from the catalog, can tell
    /// an older echo from a newer record.
    void progressRecorded(QString mediaId,
                          qint64 positionMs,
                          qint64 durationMs,
                          bool completed,
                          quint64 sequence);

private:
    void setStartPositionMs(qint64 value);
    void recordProgress();

    QUrl m_currentFileUrl;
    QString m_title;
    QString m_subtitle;
    QString m_mediaId;
    qint64 m_startPositionMs{0};
    qint64 m_positionMs{0};
    qint64 m_durationMs{0};
    bool m_paused{false};
    // A row was written for this session before its length was known.
    bool m_recordedWithoutDuration{false};
    quint64 m_progressSequence{0};
    QTimer m_progressTimer;
};
