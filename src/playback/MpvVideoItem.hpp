#pragma once

#include <cstdint>
#include <memory>
#include <optional>

#include <QMetaType>
#include <QList>
#include <QQuickFramebufferObject>
#include <QString>
#include <QTimer>
#include <QUrl>
#include <QVariantList>
#include <QtQml/qqmlregistration.h>

#include "playback/TrackSelection.hpp"

struct mpv_event;
struct mpv_handle;
class MpvNotifier;

// A mutable-event slot stays invocable through the meta-object, but Qt only
// registers a pointer meta-type when the pointed-to type is fully defined or
// declared opaque. libmpv's mpv_event never crosses a QVariant boundary
// here, so the opaque-pointer declaration below is the supported seam.
Q_DECLARE_OPAQUE_POINTER(mpv_event *)

/// Qt Quick surface that renders one local media file through libmpv's OpenGL
/// render API, leaving QML free to draw controls on top of the video.
///
/// The item owns the libmpv core on the GUI thread while the renderer owns the
/// mpv render context on the scene-graph render thread. Both hold the core
/// through one shared owner, so the render context is always released before
/// the core is destroyed regardless of which thread finishes last.
// Qt derives a wrapper from every QML-creatable type, so this cannot be final.
class MpvVideoItem : public QQuickFramebufferObject
{
    Q_OBJECT
    QML_ELEMENT

    Q_PROPERTY(QUrl source READ source WRITE setSource NOTIFY sourceChanged)
    Q_PROPERTY(double startPosition READ startPosition WRITE setStartPosition NOTIFY startPositionChanged)
    Q_PROPERTY(bool paused READ paused NOTIFY pausedChanged)
    Q_PROPERTY(double position READ position NOTIFY positionChanged)
    Q_PROPERTY(double duration READ duration NOTIFY durationChanged)
    /// PlayerView.swift:62 gates the startup overlay on the lifecycle, and
    /// :108-124 reaches the clock only in .playing: a mid-session seek back
    /// to 0 never re-enters the startup branch. This is that one-way
    /// start-of-session channel: set at construction and whenever a new
    /// source is assigned — a same-source replay re-announced by
    /// PlayerController counts as a new session — even while the file waits
    /// for a surface, cleared the first time the position reaches or leaves
    /// the 0.35-second startup window, and never set again within the
    /// session — not by a seek, not by a pause. The failure state has its
    /// own channel below.
    Q_PROPERTY(bool startupPending READ startupPending NOTIFY startupPendingChanged)
    Q_PROPERTY(QString errorMessage READ errorMessage NOTIFY errorMessageChanged)
    /// PlayerView.swift:57 gates the failure card on the lifecycle state
    /// (.failed), not on the message text. This is that state channel: set on
    /// any failure, cleared at the new-load boundary and by stop — never by
    /// FILE_LOADED, which PlaybackStateMachine.swift:87-95 rejects from
    /// .failed. The message is only read while failed.
    Q_PROPERTY(bool failed READ failed NOTIFY failedChanged)
    /// `UserSettings.swift:34` survives on this stack as the libmpv `hwdec`
    /// option (`auto-safe` when on, `no` when off), bound from
    /// `PlayerScreen.qml` to `SettingsStore::hardwareDecodingEnabled`.
    /// A runtime toggle applies to the live player: the setter writes it
    /// through `mpv_set_property_string` (the runtime property path — the
    /// creation-time `mpv_set_option_string` does not take effect after
    /// `mpv_initialize`) and commits the property only when the write
    /// succeeds. A rejected write is a preference refusal, not a playback
    /// failure: it warns on `logPlayback` and keeps the previous value,
    /// never latching the item failed (the failure card gates on that
    /// latch, which a preference must not raise).
    Q_PROPERTY(bool hardwareDecodingEnabled READ hardwareDecodingEnabled WRITE setHardwareDecodingEnabled NOTIFY hardwareDecodingEnabledChanged)
    /// The open file's audio and subtitle tracks as libmpv's `track-list`
    /// reports them, in libmpv's order. Each entry is a map of `id`,
    /// `language`, `title`, `codec`, `isDefault`, `forced`, `external`, and
    /// the menu `label` (TrackSelection::label). Sidecar subtitle files next
    /// to the video are listed too: the released subtitle menu offered
    /// exactly those (MPVPlayerService.swift:2772-2776).
    Q_PROPERTY(QVariantList audioTracks READ audioTracks NOTIFY audioTracksChanged)
    Q_PROPERTY(QVariantList subtitleTracks READ subtitleTracks NOTIFY subtitleTracksChanged)
    /// The selected tracks, mirrored from libmpv's `aid` and `sid`. 0 means no
    /// track: `sid` 0 is the menu's "Off".
    Q_PROPERTY(int audioTrackId READ audioTrackId NOTIFY audioTrackIdChanged)
    Q_PROPERTY(int subtitleTrackId READ subtitleTrackId NOTIFY subtitleTrackIdChanged)
    /// `UserSettings.defaultAudioLanguage` and `defaultSubtitleLanguage`
    /// (the Settings pickers' names, "None" for no subtitles), bound from
    /// `PlayerScreen.qml`. They choose the tracks a file opens with; changing
    /// them never moves the track of a file already playing, the way the
    /// released app chose once per load (AVPlayerService.swift:371-392).
    Q_PROPERTY(QString defaultAudioLanguage READ defaultAudioLanguage WRITE setDefaultAudioLanguage NOTIFY defaultAudioLanguageChanged)
    Q_PROPERTY(QString defaultSubtitleLanguage READ defaultSubtitleLanguage WRITE setDefaultSubtitleLanguage NOTIFY defaultSubtitleLanguageChanged)
    /// `UserSettings.subtitleScale` and the lean-back layout that
    /// `SubtitleOverlayView.swift:56-58` multiplies it by; together they set
    /// libmpv's `sub-scale` (TrackSelection::subtitleScale).
    Q_PROPERTY(double subtitleScale READ subtitleScale WRITE setSubtitleScale NOTIFY subtitleScaleChanged)
    Q_PROPERTY(bool subtitleLeanBack READ subtitleLeanBack WRITE setSubtitleLeanBack NOTIFY subtitleLeanBackChanged)
    /// libmpv's `volume` (0 to 100), `mute` and `speed` (0.5 to 3). The
    /// oracle keeps none of them: every playback is a fresh service at 100,
    /// unmuted, 1x (MPVPlayerService.swift:59-65, :386-395, :606), so they
    /// start over with every file this item opens and are stored nowhere.
    Q_PROPERTY(double volume READ volume NOTIFY volumeChanged)
    Q_PROPERTY(bool muted READ muted NOTIFY mutedChanged)
    Q_PROPERTY(double speed READ speed NOTIFY speedChanged)
    /// The speeds the HUD menu and the `[` and `]` keys step through
    /// (PlayerView.swift:15).
    Q_PROPERTY(QVariantList speedSteps READ speedSteps CONSTANT)
    /// True from beginScrub until the hold ends (finished or cancelled). While
    /// it is true the picture follows previewScrub and `position` stays where
    /// the hold began: only the landing is ever a position the session may
    /// store.
    Q_PROPERTY(bool scrubbing READ scrubbing NOTIFY scrubbingChanged)

public:
    explicit MpvVideoItem(QQuickItem *parent = nullptr);
    ~MpvVideoItem() override;

    [[nodiscard]] Renderer *createRenderer() const override;

    [[nodiscard]] QUrl source() const;
    /// Assigns the file libmpv opens. A same-URL assignment is a replay
    /// request rather than a no-op: `PlayerController::prepare` re-announces
    /// `currentFileUrl` for every session, including an unchanged URL for a
    /// replayed episode or a reopened loose file, and the QML `source`
    /// binding re-runs this setter when the notify signal fires even when
    /// the value is unchanged. The assignment therefore runs the same
    /// new-load boundary as a changed source (the load latch clears, the end
    /// latch clears, the startup latch re-arms, the clock resets, the file
    /// issues again); a same-source render-context reload bypasses this
    /// setter and reloads through `loadCurrentSource()` alone.
    void setSource(const QUrl &source);

    /// Seconds into the next file this item opens to seek to. It applies to a
    /// file this item has not loaded yet, so changing it never moves the one
    /// already playing.
    [[nodiscard]] double startPosition() const;
    void setStartPosition(double seconds);

    [[nodiscard]] bool paused() const;
    [[nodiscard]] double position() const;
    [[nodiscard]] double duration() const;
    [[nodiscard]] bool startupPending() const;
    [[nodiscard]] QString errorMessage() const;
    [[nodiscard]] bool failed() const;

    /// `UserSettings.swift:34` survives on this stack as the libmpv `hwdec`
    /// option. Bound from `PlayerScreen.qml` to the settings store; the only
    /// playback preference besides auto-play next episode with a consumer.
    /// Applies at runtime through `mpv_set_property_string`. A negative
    /// return code is a preference refusal, not a playback failure: it
    /// warns on `logPlayback` and keeps the previous property value, never
    /// latching `failed`.
    [[nodiscard]] bool hardwareDecodingEnabled() const;
    void setHardwareDecodingEnabled(bool enabled);
    /// Reads libmpv's live `hwdec` property back for the covering test, so
    /// the test fails if the setter's libmpv call is removed. Production
    /// code never calls this; it is test-only surface on the same terms as
    /// the private slots below. Returns an empty string when libmpv has no
    /// live value (no core).
    [[nodiscard]] QString hwdecForTest() const;
    /// Reads one of libmpv's scaler options (`scale`, `cscale`, `dscale`)
    /// back for the covering test. Test-only, on the same terms as
    /// `hwdecForTest`. Returns an empty string when libmpv has no live value.
    [[nodiscard]] QString scalerForTest(const QString &option) const;
    /// Arms one rejected hardware-decoding write for the covering test, so
    /// it takes the same negative-result path a real libmpv refusal takes.
    /// Production code never calls this; it is test-only surface on the
    /// same terms as the private slots below. A no-op without a live core.
    Q_INVOKABLE void failNextHardwareDecodingWriteForTest();

    Q_INVOKABLE void play();
    Q_INVOKABLE void pause();
    Q_INVOKABLE void togglePause();
    Q_INVOKABLE void stop();
    /// Returns whether the seek was issued: false when no file is open yet
    /// (the seek is dropped) or libmpv refused it, so a caller can tell a
    /// seek in flight from a key that had nothing to move.
    Q_INVOKABLE bool seekAbsolute(double seconds);
    /// Moves by `seconds` from where libmpv is, on keyframes like the released
    /// taps (MPVPlayerService.swift:3047); libmpv stops at either end of the
    /// file. Returns whether the seek was issued, as seekAbsolute does.
    Q_INVOKABLE bool seekRelative(double seconds);

    [[nodiscard]] QVariantList audioTracks() const;
    [[nodiscard]] QVariantList subtitleTracks() const;
    [[nodiscard]] int audioTrackId() const;
    [[nodiscard]] int subtitleTrackId() const;
    [[nodiscard]] QString defaultAudioLanguage() const;
    void setDefaultAudioLanguage(const QString &language);
    [[nodiscard]] QString defaultSubtitleLanguage() const;
    void setDefaultSubtitleLanguage(const QString &language);
    [[nodiscard]] double subtitleScale() const;
    void setSubtitleScale(double scale);
    [[nodiscard]] bool subtitleLeanBack() const;
    void setSubtitleLeanBack(bool leanBack);

    /// Switches the audio track to one this file lists. An id the file does
    /// not list is refused with a warning and changes nothing. The selection
    /// is committed when libmpv reports `aid`, so the property never shows a
    /// track libmpv did not take.
    Q_INVOKABLE void selectAudioTrack(int id);
    /// Switches the subtitle track; 0 turns subtitles off
    /// (`MPVPlayerService.swift:3165-3191`).
    Q_INVOKABLE void selectSubtitleTrack(int id);

    /// Volume in percent, clamped to 0 to 100 (MPVPlayerService.swift:3098-3113).
    Q_INVOKABLE void setVolume(double percent);
    /// Moves the volume by `delta` percent.
    Q_INVOKABLE void adjustVolume(double delta);
    Q_INVOKABLE void toggleMute();
    /// Playback speed, clamped to 0.5 to 3 (MPVPlayerService.swift:3267-3299).
    Q_INVOKABLE void setSpeed(double speed);
    /// Moves one step along `speedSteps` (PlayerView.swift:274-281); the ends
    /// stay put, and a speed that is not a step counts from 1x.
    Q_INVOKABLE void stepSpeed(int direction);
    /// The S key (MPVPlayerService.swift toggleSubtitles): Off when a track
    /// shows, otherwise the first subtitle the file lists.
    Q_INVOKABLE void toggleSubtitles();

    /// A Left or Right hold that scrubs (MPVPlayerService.swift:3050-3085).
    /// beginScrub relaxes libmpv's `hr-seek` to `no` so previews land on
    /// keyframes quickly; previewScrub shows the frame at `seconds`, one
    /// preview seek in flight at a time with only the newest target queued
    /// behind it; finishScrub seeks exactly to the landing and restores
    /// `hr-seek`; cancelScrub returns the picture to where the hold began and
    /// restores it. None of them blocks on libmpv, and none moves `position`
    /// to a previewed time. finishScrub returns whether the seek was issued
    /// and, with no scrub running, is a plain absolute seek.
    Q_INVOKABLE void beginScrub();
    Q_INVOKABLE void previewScrub(double seconds);
    Q_INVOKABLE bool finishScrub(double seconds);
    Q_INVOKABLE void cancelScrub();
    [[nodiscard]] bool scrubbing() const;
    /// How many preview seeks have been handed to libmpv, so a test can show
    /// that a flood of previews is coalesced. Test-only, like the others.
    [[nodiscard]] int previewSeeksIssuedForTest() const;

    [[nodiscard]] double volume() const;
    [[nodiscard]] bool muted() const;
    [[nodiscard]] double speed() const;
    [[nodiscard]] QVariantList speedSteps() const;

    /// libmpv's live value of any property, read back for the covering test
    /// so it fails if a setter's libmpv call is removed. Empty without a core.
    [[nodiscard]] QString propertyForTest(const QString &name) const;

    /// Routes audio to libmpv's null output so a headless host with no sound
    /// device can still play a file to its tracks. Production code never
    /// calls this; it is test-only surface on the same terms as the others.
    Q_INVOKABLE void useNullAudioOutputForTest();
    /// libmpv's live `sub-scale`, read back for the covering test. Empty
    /// without a core.
    [[nodiscard]] QString subScaleForTest() const;

signals:
    void sourceChanged();
    void startPositionChanged();
    void pausedChanged();
    void positionChanged();
    void durationChanged();
    void startupPendingChanged();
    void errorMessageChanged();
    void failedChanged();
    void playbackEnded();
    void hardwareDecodingEnabledChanged();
    void audioTracksChanged();
    void subtitleTracksChanged();
    void audioTrackIdChanged();
    void subtitleTrackIdChanged();
    void defaultAudioLanguageChanged();
    void defaultSubtitleLanguageChanged();
    void subtitleScaleChanged();
    void subtitleLeanBackChanged();
    void volumeChanged();
    void mutedChanged();
    void speedChanged();
    void scrubbingChanged();

private slots:
    void drainEvents();
    // Reachable through the meta-object, so a test injects a failure with
    // invokeMethod("setError", ...) the way it already delivers libmpv's own
    // reports below. moc registers private slots in the meta-object, which
    // is why QMetaObject::invokeMethod reaches them from tests; but the QML
    // engine filters private methods out of its property cache, so
    // `private slots:` IS a real QML boundary as well as the C++ one —
    // and no QML consumer calls it (PlayerScreen.qml calls none of these
    // slots) while errorMessage stays a read-only property, so QML has no
    // writable failure path.
    // A test injection is always a genuine failure, never surface teardown.
    void setError(const QString &message);
    // The END_FILE handler's two-argument latch beside it, so a test can
    // drive the teardown tag through the same meta-object path with
    // invokeMethod("setError", QString, bool) and pin both directions of the
    // classification. It stays a private slot — moc registers it in the
    // meta-object, which is why QMetaObject::invokeMethod reaches it from
    // tests, but the QML engine filters private methods out of its
    // property cache, so `private slots:` IS a real QML boundary as well
    // as the C++ one — and errorMessage stays a read-only property, and
    // no QML calls it (PlayerScreen.qml calls none of these slots), so
    // QML gains no writable failure path.
    void setError(const QString &message, bool surfaceTeardown);
    // The file-loaded event libmpv reports, applied as a slot so a test can
    // deliver it in libmpv's order through the item's own notifications
    // without a render context. moc registers it in the meta-object, which
    // is why QMetaObject::invokeMethod reaches it from tests; but the QML
    // engine filters private methods out of its property cache, so
    // `private slots:` IS a real QML boundary — and no QML consumer calls
    // it (PlayerScreen.qml calls none of these slots).
    void handleFileLoaded();
    // The end-of-file report libmpv posts, applied as a slot so a test can
    // deliver it in libmpv's order through the item's own notifications
    // without a render context. moc registers it in the meta-object, which
    // is why QMetaObject::invokeMethod reaches it from tests; but the QML
    // engine filters private methods out of its property cache, so
    // `private slots:` IS a real QML boundary — and no QML consumer calls
    // it. Carries libmpv's
    // reason and error codes verbatim (mpv_end_file_reason, mpv_error), so
    // the teardown-versus-genuine classifier in drainEvents is what runs.
    void handleEndFile(int reason, int error);
    // The values libmpv reports, applied as slots so a test can deliver them
    // in libmpv's order through the item's own notifications without a
    // render context. moc registers them in the meta-object, which is why
    // QMetaObject::invokeMethod reaches them from tests; but the QML
    // engine filters private methods out of its property cache, so
    // `private slots:` IS a real QML boundary — and no QML consumer calls
    // them (PlayerScreen.qml calls none of these slots).
    void setPausedValue(bool value);
    void setPositionValue(double value);
    void setDurationValue(double value);
    // The track state libmpv reports, applied as slots for the same reason:
    // a test delivers `track-list`, `aid`, and `sid` through the item's own
    // notifications. `json` is the `track-list` property as libmpv renders
    // it; the ids are `aid` and `sid` (0 for none). No QML consumer calls
    // them.
    void setTrackListValue(const QByteArray &json);
    void setAudioTrackIdValue(int id);
    void setSubtitleTrackIdValue(int id);
    // What libmpv reports for `volume`, `mute` and `speed`, applied as slots
    // for the same reason. No QML consumer calls them.
    void setVolumeValue(double percent);
    void setMutedValue(bool muted);
    void setSpeedValue(double speed);
    /// Applies one drained libmpv event through the production event-drain
    /// path: the shared body behind `drainEvents`, so a test exercising it
    /// runs the same payload/order classifier as libmpv's own reports,
    /// including the event payload and ordering relevant to the same-source
    /// replay repair. moc registers private slots in the meta-object, which
    /// is why QMetaObject::invokeMethod reaches it from tests; but the QML
    /// engine filters private methods out of its property cache, so
    /// `private slots:` IS a real QML boundary as well as the C++ one —
    /// and no QML consumer calls it (PlayerScreen.qml calls none
    /// of these slots) while the event argument is not constructible from
    /// QML (opaque pointer, never crossing QVariant), so QML gains no
    /// usable event path. Takes a mutable event pointer
    /// because the meta-object
    /// normalizes `const T *` and `T *` to different signatures and only
    /// the mutable form is invocable through it; the event is never
    /// modified.
    void applyEvent(mpv_event *event);
    // Driven by the renderer's scene-graph signals, applied as slots so a
    // test can drive them in libmpv's order through the item's own
    // notifications without a render context. moc registers them in the
    // meta-object, which is why QMetaObject::invokeMethod reaches them from
    // tests; but the QML engine filters private methods out of its
    // property cache, so `private slots:` IS a real QML boundary — and no
    // QML consumer calls them.
    void onRenderContextReady();
    void onRenderContextLost();

private:
    void clearError();
    void loadCurrentSource();
    void setPauseFlag(bool value);
    void applyDefaultTracks();
    [[nodiscard]] int64_t playingEntryId() const;
    void addSidecarSubtitles();
    void applySubtitleScale();
    void resetPlaybackControls();
    // The scrub helpers: all asynchronous, so the GUI thread never waits on
    // libmpv's core thread.
    void setHrSeek(const char *value);
    void issuePreview(double seconds);
    void beginSettle(double landing);
    void endSettle();
    void leaveScrub();
    void previewTimedOut();
    void handlePlaybackRestart();
    void handlePlaybackRestartEvent();
    void handleCommandReply(uint64_t replyId, int error);

    std::shared_ptr<mpv_handle> m_core;
    std::shared_ptr<MpvNotifier> m_notifier;
    QUrl m_source;
    QUrl m_loadedSource;
    bool m_hardwareDecodingEnabled{true};
    // Arms one rejected `hwdec` write for the covering test: while set, the
    // next setHardwareDecodingEnabled takes the same negative-result path
    // (MPV_ERROR_INVALID_PARAMETER) it would take for a real libmpv
    // refusal, without changing the live handle. Consumed on read; never
    // set outside the test seam.
    bool m_failNextHwdecWriteForTest{false};
    // The Settings defaults (`UserSettings.swift:177-178`) until QML binds
    // the saved ones.
    QString m_defaultAudioLanguage{QStringLiteral("English")};
    QString m_defaultSubtitleLanguage{QStringLiteral("None")};
    double m_subtitleScale{1.35};
    bool m_subtitleLeanBack{false};
    double m_volume{100.0};
    bool m_muted{false};
    double m_speed{1.0};
    QList<MediaTrack> m_audioTracks;
    QList<MediaTrack> m_subtitleTracks;
    QVariantList m_audioTrackList;
    QVariantList m_subtitleTrackList;
    int m_audioTrackId{0};
    int m_subtitleTrackId{0};
    // A new source chooses its tracks from the saved languages once its file
    // loads. A same-source surface reload instead puts back the viewer's
    // current tracks, which libmpv drops with the file.
    bool m_chooseTracksOnLoad{false};
    // The playlist entry of the load just issued, until its on_preloaded hook.
    int64_t m_pendingLoadEntry{0};
    // The entry of the latest load issued, and the entry the last on_preloaded
    // hook parked on. Events arrive in order, so a FILE_LOADED whose hook was
    // for an older entry belongs to a load that a newer one replaced.
    int64_t m_issuedLoadEntry{0};
    int64_t m_hookedEntry{0};
    // The subtitle id a surface reload puts back. libmpv resets a selected id
    // that the reloaded file does not list yet (a sidecar) to automatic, so
    // it is selected again once the sidecars are added.
    int m_restoreSubtitleId{0};
    double m_startPosition{0.0};
    quint64 m_surfaceGeneration{0};
    quint64 m_loadedGeneration{0};
    double m_resumePosition{0.0};
    bool m_startPending{false};
    bool m_renderContextReady{false};
    bool m_paused{false};
    double m_position{0.0};
    double m_duration{0.0};
    // The oracle's startup lifecycle as a one-way latch: set while the
    // session is still starting, cleared when playback is established, and
    // never set again within the session — a backward seek to 0 only moves
    // the clock, never this state.
    bool m_startupPending{true};
    bool m_endReported{false};
    bool m_failed{false};
    // Latch tag: true only while the live failure came from an END_FILE
    // whose mpv code proves libmpv lost the video output rather than the
    // file (VO_INIT_FAILED for the surface going away, NOTHING_TO_PLAY once
    // it is gone). A FILE_LOADED proves libmpv opened the file behind the
    // current surface and supersedes exactly that noise; every other error
    // latches untagged and FILE_LOADED cannot heal it
    // (PlaybackStateMachine.swift:87-95 rejects .fileLoaded from .failed).
    // Reset by clearError and by every untagged setError latch.
    bool m_errorIsSurfaceTeardown{false};
    // True once libmpv has confirmed the held file behind the current
    // surface (FILE_LOADED), cleared whenever a (re)load is issued — a new
    // source or a same-source render-surface reload — or the session ends.
    // Lets the END_FILE classifier tell a video-output error for a file that
    // provably played from one for a file that never opened, even when the
    // render-context loss notification is still queued behind libmpv's own
    // report.
    bool m_fileLoaded{false};
    // Set at each setSource, consumed by the first loadCurrentSource of that
    // source, so the per-playback controls reset once per source.
    bool m_resetControlsPending{false};
    // Teardown END_FILEs seen since the tagged latch opened, without an
    // intervening FILE_LOADED: the first still carries the superseded
    // surface's signature, so it stays teardown. A second while the latch
    // is live only moves this count on for the load-time guard in
    // handleFileLoaded, which pairs "a second report arrived" with the
    // settled render-context read before deciding — that pairing is the
    // one discriminator, and it is read at FILE_LOADED time, not here.
    // Reset when a fresh tagged latch opens (see setError) and at every
    // (re)load boundary and error-path exit that retires the latch (new
    // source, stop) — never while the latch is live, or the guard in
    // handleFileLoaded cannot see that a second report arrived.
    int m_seenTeardownSinceReload{0};
    // Remembers that the held source provably played before the in-flight
    // same-source render-surface reload cleared the confirmation above:
    // libmpv's teardown END_FILEs for the superseded surface can still be
    // queued behind the reload, and without this proof the trailing report
    // misclassifies as a genuine open failure that the reload's own
    // FILE_LOADED can never heal. Latched when a same-source reload is
    // issued for a confirmed file, subsumed by the next FILE_LOADED, and
    // cleared with a new source or stop — a file that never loaded keeps no
    // proof, so a reload that itself fails still reports genuine.
    bool m_playedBeforeReload{false};
    QString m_errorMessage;

    // Scrub state. `m_scrubHolding` runs from beginScrub to the end of the
    // hold; `m_scrubSettling` from then until libmpv confirms the exact seek
    // that ends it, during which libmpv's position reports (still those of
    // previews) are ignored so the clock never shows a previewed time.
    bool m_scrubHolding{false};
    bool m_scrubSettling{false};
    bool m_hrSeekRelaxed{false};
    bool m_previewIssued{false};
    bool m_previewInFlight{false};
    // libmpv has taken the in-flight preview's seek (its command reply came).
    bool m_previewAcknowledged{false};
    uint64_t m_previewSerial{0};
    std::optional<double> m_previewPending;
    double m_scrubOrigin{0.0};
    double m_settleLanding{0.0};
    uint64_t m_settleSerial{0};
    int m_previewSeeksIssued{0};
    // libmpv can drop the restart report of a seek that a newer one replaced,
    // or never raise it without a video output; neither may wedge the scrub.
    QTimer m_previewWatchdog;
    QTimer m_settleWatchdog;
};
