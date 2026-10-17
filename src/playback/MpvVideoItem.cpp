#include "playback/MpvVideoItem.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <utility>

#include <QByteArray>
#include <QFileInfo>
#include <QOpenGLContext>
#include <QOpenGLFramebufferObject>
#include <QQuickWindow>

#include <mpv/client.h>
#include <mpv/render_gl.h>

#include "playback/SubtitleDiscovery.hpp"
#include "support/Logging.hpp"

namespace {

constexpr uint64_t kPausedProperty = 1;
constexpr uint64_t kTimePositionProperty = 2;
constexpr uint64_t kDurationProperty = 3;
constexpr uint64_t kEofReachedProperty = 4;
constexpr uint64_t kTrackListProperty = 5;
constexpr uint64_t kAudioIdProperty = 6;
constexpr uint64_t kSubtitleIdProperty = 7;
constexpr uint64_t kVolumeProperty = 8;
constexpr uint64_t kMuteProperty = 9;
constexpr uint64_t kSpeedProperty = 10;

// PlayerView.swift:15.
constexpr std::array<double, 7> kSpeedSteps{0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0};
constexpr double kMinimumSpeed = 0.5;
constexpr double kMaximumSpeed = 3.0;
constexpr double kMaximumVolume = 100.0;

void *resolveOpenGlFunction(void *, const char *name)
{
    QOpenGLContext *context = QOpenGLContext::currentContext();
    if (context == nullptr) {
        return nullptr;
    }
    return reinterpret_cast<void *>(context->getProcAddress(name));
}

QString mpvErrorText(int code)
{
    return QString::fromUtf8(mpv_error_string(code));
}

/// libmpv renders `aid` and `sid` as the track number, "auto" before a file
/// has chosen, or "no". Only a number is a selected track.
int trackIdFromProperty(const mpv_event_property *property)
{
    if (property->format != MPV_FORMAT_STRING || property->data == nullptr) {
        return 0;
    }
    const char *text = *static_cast<char **>(property->data);
    if (text == nullptr) {
        return 0;
    }
    bool ok = false;
    const int id = QByteArray(text).toInt(&ok);
    return ok && id > 0 ? id : 0;
}

}

/// Marshals libmpv callbacks, which arrive on libmpv's own threads, onto the
/// item's thread. It is kept alive by the core's deleter so a callback can
/// never reach a destroyed object during teardown.
class MpvNotifier final : public QObject
{
    Q_OBJECT

signals:
    void eventsPending();
    void frameReady();
    void renderContextReady();
    void renderContextLost();
    void renderContextFailed(const QString &message);
};

class MpvVideoRenderer final : public QQuickFramebufferObject::Renderer
{
public:
    MpvVideoRenderer(std::shared_ptr<mpv_handle> core,
                     std::shared_ptr<MpvNotifier> notifier)
        : m_core(std::move(core)),
          m_notifier(std::move(notifier))
    {
        if (!m_core) {
            return;
        }

        mpv_opengl_init_params openGlParameters{&resolveOpenGlFunction, nullptr};
        mpv_render_param parameters[] = {
            {MPV_RENDER_PARAM_API_TYPE,
             const_cast<char *>(MPV_RENDER_API_TYPE_OPENGL)},
            {MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, &openGlParameters},
            {MPV_RENDER_PARAM_INVALID, nullptr}
        };

        const int result =
            mpv_render_context_create(&m_renderContext, m_core.get(), parameters);
        if (result < 0) {
            m_renderContext = nullptr;
            emit m_notifier->renderContextFailed(
                QStringLiteral("Video rendering unavailable: %1")
                    .arg(mpvErrorText(result)));
            return;
        }

        mpv_render_context_set_update_callback(
            m_renderContext, &MpvVideoRenderer::onFrameReady, m_notifier.get());
        emit m_notifier->renderContextReady();
    }

    ~MpvVideoRenderer() override
    {
        if (m_renderContext == nullptr) {
            return;
        }
        mpv_render_context_free(m_renderContext);
        emit m_notifier->renderContextLost();
    }

    MpvVideoRenderer(const MpvVideoRenderer &) = delete;
    MpvVideoRenderer &operator=(const MpvVideoRenderer &) = delete;

    void synchronize(QQuickFramebufferObject *item) override
    {
        m_window = item->window();
    }

    void render() override
    {
        QOpenGLFramebufferObject *target = framebufferObject();
        if (m_renderContext == nullptr || target == nullptr) {
            return;
        }

        mpv_opengl_fbo targetDescription{
            .fbo = static_cast<int>(target->handle()),
            .w = target->width(),
            .h = target->height(),
            .internal_format = 0,
        };
        // Qt Quick samples the framebuffer bottom-up, matching mpv's own
        // OpenGL output, so the frame must not be flipped again here.
        int flipY = 0;
        mpv_render_param parameters[] = {
            {MPV_RENDER_PARAM_OPENGL_FBO, &targetDescription},
            {MPV_RENDER_PARAM_FLIP_Y, &flipY},
            {MPV_RENDER_PARAM_INVALID, nullptr}
        };

        if (m_window != nullptr) {
            m_window->beginExternalCommands();
        }
        mpv_render_context_render(m_renderContext, parameters);
        if (m_window != nullptr) {
            m_window->endExternalCommands();
        }
    }

private:
    static void onFrameReady(void *context)
    {
        emit static_cast<MpvNotifier *>(context)->frameReady();
    }

    std::shared_ptr<mpv_handle> m_core;
    std::shared_ptr<MpvNotifier> m_notifier;
    mpv_render_context *m_renderContext{nullptr};
    QQuickWindow *m_window{nullptr};
};

MpvVideoItem::MpvVideoItem(QQuickItem *parent)
    : QQuickFramebufferObject(parent),
      m_notifier(std::make_shared<MpvNotifier>())
{
    setMirrorVertically(false);

    mpv_handle *core = mpv_create();
    if (core == nullptr) {
        setError(QStringLiteral(
            "Video engine unavailable: libmpv could not be created."));
        return;
    }

    // Holding the notifier in the deleter keeps it alive until after
    // mpv_terminate_destroy returns, which is the point libmpv guarantees no
    // further callbacks.
    m_core = std::shared_ptr<mpv_handle>(
        core,
        [notifier = m_notifier](mpv_handle *handle) { mpv_terminate_destroy(handle); });

    mpv_set_option_string(core, "config", "no");
    mpv_set_option_string(core, "terminal", "no");
    mpv_set_option_string(core, "input-default-bindings", "no");
    mpv_set_option_string(core, "input-vo-keyboard", "no");
    mpv_set_option_string(core, "vo", "libmpv");
    // `UserSettings.swift:34`, bound from PlayerScreen.qml to
    // `SettingsStore::hardwareDecodingEnabled`.
    mpv_set_option_string(core, "hwdec", m_hardwareDecodingEnabled ? "auto-safe" : "no");
    mpv_set_option_string(core, "keep-open", "yes");
    // Subtitles start Off and a language setting or the viewer turns one on
    // (`MPVPlayerService.swift:2435` sets sid=no). The sidecar files beside
    // the video are found by `SubtitleDiscovery` and added at the start of
    // each load, never by libmpv: its "fuzzy" search takes "Episode 10.en.srt"
    // for "Episode 1.mkv", and its "exact" search drops "Film_en.srt", which
    // the released app lists (`SubtitleDiscovery.swift:57-138`).
    mpv_set_option_string(core, "sid", "no");
    mpv_set_option_string(core, "sub-auto", "no");
    // `SubtitleOverlayView.swift:13` draws subtitles at a 30-point base font
    // times the saved size. mpv's `sub-font-size` is in pixels of a 720-high
    // window, so the same 30 is the base and `sub-scale` carries the saved
    // size (applySubtitleScale). The oracle names no other reference height.
    mpv_set_option_string(core, "sub-font-size", "30");
    // The released app scales with bilinear filters (`MPVPlayerService.swift`
    // :2407-2409). libmpv's own default is the six-tap lanczos pair, which
    // draws through two extra offscreen passes and a weights texture. Under
    // Mesa's software GL (xvfb, headless sway) those passes sometimes write
    // NaN into whole rows of their offscreen texture, and the context then
    // draws a black or banded picture for the rest of its life, on a first
    // play as often as after a lost window surface. In those runs the decoded
    // frame, the weights texture and the framebuffer handed to mpv are intact;
    // the NaN appears inside mpv's own passes. Why is not isolated (issues.md).
    mpv_set_option_string(core, "scale", "bilinear");
    mpv_set_option_string(core, "cscale", "bilinear");
    mpv_set_option_string(core, "dscale", "bilinear");

    const int initialized = mpv_initialize(core);
    if (initialized < 0) {
        m_core.reset();
        setError(QStringLiteral("Video engine unavailable: %1")
                     .arg(mpvErrorText(initialized)));
        return;
    }

    mpv_observe_property(core, kPausedProperty, "pause", MPV_FORMAT_FLAG);
    mpv_observe_property(core, kTimePositionProperty, "time-pos", MPV_FORMAT_DOUBLE);
    mpv_observe_property(core, kDurationProperty, "duration", MPV_FORMAT_DOUBLE);
    mpv_observe_property(core, kEofReachedProperty, "eof-reached", MPV_FORMAT_FLAG);
    mpv_observe_property(core, kTrackListProperty, "track-list", MPV_FORMAT_STRING);
    mpv_observe_property(core, kAudioIdProperty, "aid", MPV_FORMAT_STRING);
    mpv_observe_property(core, kSubtitleIdProperty, "sid", MPV_FORMAT_STRING);
    mpv_observe_property(core, kVolumeProperty, "volume", MPV_FORMAT_DOUBLE);
    mpv_observe_property(core, kMuteProperty, "mute", MPV_FORMAT_FLAG);
    mpv_observe_property(core, kSpeedProperty, "speed", MPV_FORMAT_DOUBLE);
    // Held at on_preloaded for the sidecar subtitles (addSidecarSubtitles); the
    // hook's event is always answered in applyEvent.
    mpv_hook_add(core, 0, "on_preloaded", 0);
    applySubtitleScale();

    connect(m_notifier.get(), &MpvNotifier::eventsPending,
            this, &MpvVideoItem::drainEvents, Qt::QueuedConnection);
    connect(m_notifier.get(), &MpvNotifier::frameReady,
            this, [this] { update(); }, Qt::QueuedConnection);
    connect(m_notifier.get(), &MpvNotifier::renderContextReady,
            this, &MpvVideoItem::onRenderContextReady, Qt::QueuedConnection);
    connect(m_notifier.get(), &MpvNotifier::renderContextLost,
            this, &MpvVideoItem::onRenderContextLost, Qt::QueuedConnection);
    connect(m_notifier.get(), &MpvNotifier::renderContextFailed,
            this, qOverload<const QString &>(&MpvVideoItem::setError),
            Qt::QueuedConnection);

    mpv_set_wakeup_callback(
        core,
        [](void *context) { emit static_cast<MpvNotifier *>(context)->eventsPending(); },
        m_notifier.get());
}

MpvVideoItem::~MpvVideoItem()
{
    if (m_core) {
        mpv_set_wakeup_callback(m_core.get(), nullptr, nullptr);
    }
}

QQuickFramebufferObject::Renderer *MpvVideoItem::createRenderer() const
{
    return new MpvVideoRenderer(m_core, m_notifier);
}

QUrl MpvVideoItem::source() const
{
    return m_source;
}

void MpvVideoItem::setSource(const QUrl &source)
{
    if (m_source == source && source.isEmpty()) {
        return;
    }
    // PlayerController::prepare re-announces currentFileUrl on every session,
    // including an unchanged URL for a replay (a replayed episode, a loose
    // file reopened). The QML `source` binding re-runs its C++ setter when
    // the underlying notify signal fires even when the value is unchanged,
    // so the re-announcement arrives here as a same-URL write: it must run
    // the same new-load boundary below — clearing the end latch and the
    // load latch, re-arming the startup latch, resetting the clock — and
    // re-issue the file to libmpv. Clearing the loaded latch forces
    // loadCurrentSource past its loaded-generation match, so the replay
    // issues even though the URL is unchanged, and arms while the file
    // waits for a surface: the issue is only recorded after a successful
    // loadfile, so the next entry past the context gate retries the same
    // replay. A genuine same-source render-context reload reaches
    // loadCurrentSource without passing through here, so it keeps its
    // reload path untouched: it reloads without resetting the position,
    // re-arming the startup latch, or re-emitting sourceChanged.
    // sourceChanged still fires for the replay so the QML binding
    // re-evaluates the way every other new session does.
    if (m_source == source) {
        m_loadedSource.clear();
    }
    m_source = source;
    // PlayerView.swift:62, :108-124: the startup cover belongs to a one-time
    // start-of-session state. A new source — or a same-source replay, which
    // PlayerController announces by re-emitting the unchanged URL — opens a
    // new session, so the latch is re-armed at this boundary — matching the
    // oracle's deferred pendingLoadPath flush, the request re-arms even
    // while the file waits for a surface.
    // The clock belongs to the previous session: unless it is reset here, a
    // surviving item re-sourced while the route stays on Player (the
    // auto-play-next-episode handoff) shows the old position beside the
    // re-armed latch, so the new session's first copy reads
    // "Starting playback..." instead of "Opening video...". The reset runs
    // before the re-arm so no observer ever sees the new latch beside the
    // old clock. Resume state is unaffected: loadCurrentSource below prefers
    // the session's start position for a new source, and same-source surface
    // reloads never pass through here.
    if (!qFuzzyCompare(m_position, 0.0)) {
        m_position = 0.0;
        emit positionChanged();
    }
    if (!m_startupPending) {
        m_startupPending = true;
        emit startupPendingChanged();
    }
    // The old file's confirmation ends at this boundary, ahead of the issue
    // in loadCurrentSource: while the new file waits for a surface, or for
    // its loadfile to run, libmpv can still report the old file's position
    // and end, and an old FILE_LOADED can still be queued. With no issued
    // entry, handleFileLoaded ignores that one once an entry has hooked.
    m_fileLoaded = false;
    m_issuedLoadEntry = -1;
    // The controls are cleared once for this source, not again when its
    // surface arrives: a pause pressed before any file loaded must stay.
    m_resetControlsPending = true;
    emit sourceChanged();
    loadCurrentSource();
}

double MpvVideoItem::startPosition() const
{
    return m_startPosition;
}

void MpvVideoItem::setStartPosition(double seconds)
{
    const double next = qMax(0.0, seconds);
    if (qFuzzyCompare(m_startPosition, next)) {
        return;
    }
    m_startPosition = next;
    emit startPositionChanged();
}

bool MpvVideoItem::paused() const
{
    return m_paused;
}

double MpvVideoItem::position() const
{
    return m_position;
}

double MpvVideoItem::duration() const
{
    return m_duration;
}

bool MpvVideoItem::startupPending() const
{
    return m_startupPending;
}

QString MpvVideoItem::errorMessage() const
{
    return m_errorMessage;
}

bool MpvVideoItem::failed() const
{
    return m_failed;
}

bool MpvVideoItem::hardwareDecodingEnabled() const
{
    return m_hardwareDecodingEnabled;
}

QString MpvVideoItem::hwdecForTest() const
{
    if (!m_core) {
        return {};
    }
    char *value = mpv_get_property_string(m_core.get(), "hwdec");
    if (value == nullptr) {
        return {};
    }
    const QString result = QString::fromUtf8(value);
    mpv_free(value);
    return result;
}

QString MpvVideoItem::scalerForTest(const QString &option) const
{
    if (!m_core) {
        return {};
    }
    char *value = mpv_get_property_string(m_core.get(), option.toUtf8().constData());
    if (value == nullptr) {
        return {};
    }
    const QString result = QString::fromUtf8(value);
    mpv_free(value);
    return result;
}

void MpvVideoItem::failNextHardwareDecodingWriteForTest()
{
    if (m_core) {
        m_failNextHwdecWriteForTest = true;
    }
}

void MpvVideoItem::setHardwareDecodingEnabled(bool enabled)
{
    if (m_hardwareDecodingEnabled == enabled) {
        return;
    }
    // `UserSettings.swift:34`, bound from PlayerScreen.qml to the settings
    // store: hardware decoding is a user preference, not playback lifecycle
    // state, so a rejected write must neither latch the session failed nor
    // leave the property reporting a value libmpv never accepted
    // (PlayerScreen.qml:61 gates the full-screen failure card on
    // `video.failed`, and an untagged latch clears only on a new source or
    // stop() — handleFileLoaded cannot heal it). Per mpv/client.h this is
    // a runtime property, not a creation option: mpv_set_option_string
    // after mpv_initialize is semi-deprecated and does not take effect, so
    // the toggle goes through mpv_set_property_string. The write is
    // attempted first and the property + signal commit only when it
    // succeeds; a negative result warns on logPlayback and keeps the
    // previous value. It applies to the current source (the covering test
    // reads it back), not only the next load.
    if (m_core) {
        // Test seam (see failNextHardwareDecodingWriteForTest): both values
        // below round-trip on every real handle, so the rejection branch is
        // otherwise unreachable in-harness. The seam reports the real
        // invalid-parameter code through the same negative-result path a
        // real libmpv refusal takes, without touching the live handle.
        const bool forceRejection = m_failNextHwdecWriteForTest;
        m_failNextHwdecWriteForTest = false;
        const int result =
            forceRejection
                ? static_cast<int>(MPV_ERROR_INVALID_PARAMETER)
                : mpv_set_property_string(m_core.get(), "hwdec", enabled ? "auto-safe" : "no");
        if (result < 0) {
            qCWarning(logPlayback) << QStringLiteral("Could not change hardware decoding: %1")
                                          .arg(mpvErrorText(result));
            return;
        }
    }
    m_hardwareDecodingEnabled = enabled;
    emit hardwareDecodingEnabledChanged();
}

void MpvVideoItem::play()
{
    setPauseFlag(false);
}

void MpvVideoItem::pause()
{
    setPauseFlag(true);
}

void MpvVideoItem::togglePause()
{
    setPauseFlag(!m_paused);
}

void MpvVideoItem::stop()
{
    if (!m_core) {
        return;
    }

    const char *command[] = {"stop", nullptr};
    const int result = mpv_command(m_core.get(), command);
    if (result < 0) {
        setError(QStringLiteral("Could not stop playback: %1").arg(mpvErrorText(result)));
        return;
    }

    clearError();
    setPositionValue(0.0);
    setDurationValue(0.0);
    m_loadedSource.clear();
    m_fileLoaded = false;
    m_playedBeforeReload = false;
    m_seenTeardownSinceReload = 0;
    m_resumePosition = 0.0;
    m_endReported = false;
    m_chooseTracksOnLoad = false;
    m_pendingLoadEntry = 0;
    // A FILE_LOADED still queued from before the stop describes an entry that
    // is gone: with no issued entry, handleFileLoaded no longer mistakes it
    // for a live load.
    m_issuedLoadEntry = -1;
    m_restoreSubtitleId = 0;
    setTrackListValue(QByteArray());
    setAudioTrackIdValue(0);
    setSubtitleTrackIdValue(0);
    if (!m_source.isEmpty()) {
        m_source.clear();
        emit sourceChanged();
    }
}

bool MpvVideoItem::seekAbsolute(double seconds)
{
    // libmpv refuses a seek while no file is open, and a refused seek latches
    // the failure card. A key pressed while the file is still opening (or the
    // picture is being rebuilt) has nothing to seek yet.
    if (!m_core || !m_fileLoaded) {
        return false;
    }

    const QByteArray target = QByteArray::number(qMax(0.0, seconds), 'f', 3);
    const char *command[] = {"seek", target.constData(), "absolute", nullptr};
    const int result = mpv_command(m_core.get(), command);
    if (result < 0) {
        setError(QStringLiteral("Could not seek: %1").arg(mpvErrorText(result)));
        return false;
    }
    return true;
}

bool MpvVideoItem::seekRelative(double seconds)
{
    if (!m_core || !m_fileLoaded || !std::isfinite(seconds)) {
        return false;
    }

    const QByteArray amount = QByteArray::number(seconds, 'f', 3);
    const char *command[] = {"seek", amount.constData(), "relative+keyframes", nullptr};
    const int result = mpv_command(m_core.get(), command);
    if (result < 0) {
        setError(QStringLiteral("Could not seek: %1").arg(mpvErrorText(result)));
        return false;
    }
    return true;
}

void MpvVideoItem::setVolume(double percent)
{
    if (!m_core || !std::isfinite(percent)) {
        return;
    }
    double value = std::clamp(percent, 0.0, kMaximumVolume);
    // A preference write like hwdec: a refusal warns and never latches the
    // session failed.
    const int result = mpv_set_property(m_core.get(), "volume", MPV_FORMAT_DOUBLE, &value);
    if (result < 0) {
        qCWarning(logPlayback) << QStringLiteral("Could not change the volume: %1")
                                      .arg(mpvErrorText(result));
        return;
    }
    setVolumeValue(value);
}

void MpvVideoItem::adjustVolume(double delta)
{
    setVolume(m_volume + delta);
}

void MpvVideoItem::toggleMute()
{
    if (!m_core) {
        return;
    }
    int flag = m_muted ? 0 : 1;
    const int result = mpv_set_property(m_core.get(), "mute", MPV_FORMAT_FLAG, &flag);
    if (result < 0) {
        qCWarning(logPlayback) << QStringLiteral("Could not change mute: %1")
                                      .arg(mpvErrorText(result));
        return;
    }
    setMutedValue(flag != 0);
}

void MpvVideoItem::setSpeed(double speed)
{
    if (!m_core || !std::isfinite(speed)) {
        return;
    }
    double value = std::clamp(speed, kMinimumSpeed, kMaximumSpeed);
    const int result = mpv_set_property(m_core.get(), "speed", MPV_FORMAT_DOUBLE, &value);
    if (result < 0) {
        qCWarning(logPlayback) << QStringLiteral("Could not change the speed: %1")
                                      .arg(mpvErrorText(result));
        return;
    }
    setSpeedValue(value);
}

void MpvVideoItem::stepSpeed(int direction)
{
    const auto exact = [this](double step) { return qFuzzyCompare(step, m_speed); };
    auto at = std::find_if(kSpeedSteps.cbegin(), kSpeedSteps.cend(), exact);
    if (at == kSpeedSteps.cend()) {
        at = std::find(kSpeedSteps.cbegin(), kSpeedSteps.cend(), 1.0);
    }
    const auto index = std::clamp<std::ptrdiff_t>(
        (at - kSpeedSteps.cbegin()) + (direction < 0 ? -1 : direction > 0 ? 1 : 0),
        0, static_cast<std::ptrdiff_t>(kSpeedSteps.size()) - 1);
    setSpeed(kSpeedSteps[static_cast<std::size_t>(index)]);
}

void MpvVideoItem::toggleSubtitles()
{
    if (m_subtitleTrackId > 0) {
        selectSubtitleTrack(0);
    } else if (!m_subtitleTracks.isEmpty()) {
        selectSubtitleTrack(m_subtitleTracks.constFirst().id);
    }
}

double MpvVideoItem::volume() const
{
    return m_volume;
}

bool MpvVideoItem::muted() const
{
    return m_muted;
}

double MpvVideoItem::speed() const
{
    return m_speed;
}

QVariantList MpvVideoItem::speedSteps() const
{
    QVariantList steps;
    for (const double step : kSpeedSteps) {
        steps.append(step);
    }
    return steps;
}

void MpvVideoItem::setVolumeValue(double percent)
{
    if (qFuzzyCompare(m_volume + 1.0, percent + 1.0)) {
        return;
    }
    m_volume = percent;
    emit volumeChanged();
}

void MpvVideoItem::setMutedValue(bool muted)
{
    if (m_muted == muted) {
        return;
    }
    m_muted = muted;
    emit mutedChanged();
}

void MpvVideoItem::setSpeedValue(double speed)
{
    if (qFuzzyCompare(m_speed, speed)) {
        return;
    }
    m_speed = speed;
    emit speedChanged();
}

void MpvVideoItem::resetPlaybackControls()
{
    // libmpv keeps these across loadfile; the oracle starts every playback
    // from 100, unmuted, 1x and playing (PlayerController.swift:76-104 builds
    // a fresh player per file). They are written without being asked of the
    // viewer, so a refusal only warns.
    if (!m_core) {
        return;
    }
    setVolume(kMaximumVolume);
    if (m_muted) {
        toggleMute();
    }
    setSpeed(1.0);

    // A pause would carry into the new file, which would then never leave
    // startup. It is cleared here, ahead of the loadfile, so no frame of the
    // new file plays and then stops. The flag is mirrored at once so the HUD
    // does not show the old pause until libmpv's report arrives; that report
    // follows libmpv's own order and settles on the same value.
    int playing = 0;
    const int result = mpv_set_property(m_core.get(), "pause", MPV_FORMAT_FLAG, &playing);
    if (result < 0) {
        qCWarning(logPlayback) << QStringLiteral("Could not start playing: %1")
                                      .arg(mpvErrorText(result));
        return;
    }
    setPausedValue(false);
}

QString MpvVideoItem::propertyForTest(const QString &name) const
{
    if (!m_core) {
        return {};
    }
    char *value = mpv_get_property_string(m_core.get(), name.toUtf8().constData());
    if (value == nullptr) {
        return {};
    }
    const QString result = QString::fromUtf8(value);
    mpv_free(value);
    return result;
}

QVariantList MpvVideoItem::audioTracks() const
{
    return m_audioTrackList;
}

QVariantList MpvVideoItem::subtitleTracks() const
{
    return m_subtitleTrackList;
}

int MpvVideoItem::audioTrackId() const
{
    return m_audioTrackId;
}

int MpvVideoItem::subtitleTrackId() const
{
    return m_subtitleTrackId;
}

QString MpvVideoItem::defaultAudioLanguage() const
{
    return m_defaultAudioLanguage;
}

void MpvVideoItem::setDefaultAudioLanguage(const QString &language)
{
    if (m_defaultAudioLanguage == language) {
        return;
    }
    m_defaultAudioLanguage = language;
    emit defaultAudioLanguageChanged();
}

QString MpvVideoItem::defaultSubtitleLanguage() const
{
    return m_defaultSubtitleLanguage;
}

void MpvVideoItem::setDefaultSubtitleLanguage(const QString &language)
{
    if (m_defaultSubtitleLanguage == language) {
        return;
    }
    m_defaultSubtitleLanguage = language;
    emit defaultSubtitleLanguageChanged();
}

double MpvVideoItem::subtitleScale() const
{
    return m_subtitleScale;
}

void MpvVideoItem::setSubtitleScale(double scale)
{
    if (qFuzzyCompare(m_subtitleScale, scale)) {
        return;
    }
    m_subtitleScale = scale;
    applySubtitleScale();
    emit subtitleScaleChanged();
}

bool MpvVideoItem::subtitleLeanBack() const
{
    return m_subtitleLeanBack;
}

void MpvVideoItem::setSubtitleLeanBack(bool leanBack)
{
    if (m_subtitleLeanBack == leanBack) {
        return;
    }
    m_subtitleLeanBack = leanBack;
    applySubtitleScale();
    emit subtitleLeanBackChanged();
}

void MpvVideoItem::applySubtitleScale()
{
    if (!m_core) {
        return;
    }
    // A preference write, like hwdec: a refusal warns and never latches the
    // session failed.
    double scale = TrackSelection::subtitleScale(m_subtitleScale, m_subtitleLeanBack);
    const int result = mpv_set_property(m_core.get(), "sub-scale", MPV_FORMAT_DOUBLE, &scale);
    if (result < 0) {
        qCWarning(logPlayback) << QStringLiteral("Could not change subtitle size: %1")
                                      .arg(mpvErrorText(result));
    }
}

QString MpvVideoItem::subScaleForTest() const
{
    if (!m_core) {
        return {};
    }
    char *value = mpv_get_property_string(m_core.get(), "sub-scale");
    if (value == nullptr) {
        return {};
    }
    const QString result = QString::fromUtf8(value);
    mpv_free(value);
    return result;
}

void MpvVideoItem::useNullAudioOutputForTest()
{
    if (m_core) {
        mpv_set_property_string(m_core.get(), "ao", "null");
    }
}

void MpvVideoItem::selectAudioTrack(int id)
{
    if (!m_core) {
        return;
    }
    const bool listed = std::any_of(m_audioTracks.cbegin(), m_audioTracks.cend(),
                                    [id](const MediaTrack &track) { return track.id == id; });
    if (!listed) {
        qCWarning(logPlayback) << QStringLiteral("This file has no audio track %1").arg(id);
        return;
    }
    int64_t value = id;
    const int result = mpv_set_property(m_core.get(), "aid", MPV_FORMAT_INT64, &value);
    if (result < 0) {
        qCWarning(logPlayback) << QStringLiteral("Could not change the audio track: %1")
                                      .arg(mpvErrorText(result));
    }
}

void MpvVideoItem::selectSubtitleTrack(int id)
{
    if (!m_core) {
        return;
    }
    int result = 0;
    if (id == 0) {
        result = mpv_set_property_string(m_core.get(), "sid", "no");
    } else {
        const bool listed = std::any_of(
            m_subtitleTracks.cbegin(), m_subtitleTracks.cend(),
            [id](const MediaTrack &track) { return track.id == id; });
        if (!listed) {
            qCWarning(logPlayback) << QStringLiteral("This file has no subtitle track %1").arg(id);
            return;
        }
        int64_t value = id;
        result = mpv_set_property(m_core.get(), "sid", MPV_FORMAT_INT64, &value);
    }
    if (result < 0) {
        qCWarning(logPlayback) << QStringLiteral("Could not change the subtitle track: %1")
                                      .arg(mpvErrorText(result));
    }
}

void MpvVideoItem::setTrackListValue(const QByteArray &json)
{
    const QList<MediaTrack> all = TrackSelection::parseTrackList(json);
    QList<MediaTrack> audio;
    QList<MediaTrack> subtitles;
    for (const MediaTrack &track : all) {
        (track.kind == MediaTrack::Kind::Audio ? audio : subtitles).append(track);
    }
    const auto toList = [](const QList<MediaTrack> &tracks) {
        QVariantList list;
        for (const MediaTrack &track : tracks) {
            list.append(TrackSelection::toVariant(track));
        }
        return list;
    };

    m_audioTracks = audio;
    m_subtitleTracks = subtitles;
    const QVariantList audioList = toList(audio);
    const QVariantList subtitleList = toList(subtitles);
    if (audioList != m_audioTrackList) {
        m_audioTrackList = audioList;
        emit audioTracksChanged();
    }
    if (subtitleList != m_subtitleTrackList) {
        m_subtitleTrackList = subtitleList;
        emit subtitleTracksChanged();
    }
}

void MpvVideoItem::setAudioTrackIdValue(int id)
{
    if (m_audioTrackId == id) {
        return;
    }
    m_audioTrackId = id;
    emit audioTrackIdChanged();
}

void MpvVideoItem::setSubtitleTrackIdValue(int id)
{
    if (m_subtitleTrackId == id) {
        return;
    }
    m_subtitleTrackId = id;
    emit subtitleTrackIdChanged();
}

int64_t MpvVideoItem::playingEntryId() const
{
    // The hook event names no entry, so the entry libmpv is opening is read
    // from its playlist; it is parked at the hook while this runs.
    int64_t position = -1;
    if (mpv_get_property(m_core.get(), "playlist-playing-pos", MPV_FORMAT_INT64, &position) < 0
        || position < 0) {
        return 0;
    }
    int64_t id = 0;
    const QByteArray name = "playlist/" + QByteArray::number(position) + "/id";
    if (mpv_get_property(m_core.get(), name.constData(), MPV_FORMAT_INT64, &id) < 0) {
        return 0;
    }
    return id;
}

void MpvVideoItem::addSidecarSubtitles()
{
    if (!m_core || !m_source.isLocalFile()) {
        return;
    }
    // Added while the file is still opening, so the tracks are listed (and
    // the saved language can pick one) by the time it has loaded. "auto" adds
    // without selecting, which stays the choice of applyDefaultTracks.
    const QList<SidecarSubtitle> sidecars =
        SubtitleDiscovery::discover(m_source.toLocalFile());
    for (const SidecarSubtitle &sidecar : sidecars) {
        const QByteArray path = sidecar.path.toUtf8();
        const QByteArray title = QFileInfo(sidecar.path).fileName().toUtf8();
        const QByteArray language = sidecar.language.toUtf8();
        // A file name that carries no known language stays without one, so
        // no saved language picks it.
        const char *command[] = {"sub-add", path.constData(), "auto", title.constData(),
                                 language.isEmpty() ? nullptr : language.constData(),
                                 nullptr};
        const int result = mpv_command(m_core.get(), command);
        if (result < 0) {
            qCWarning(logPlayback) << QStringLiteral("Could not add the subtitle file %1: %2")
                                          .arg(sidecar.path, mpvErrorText(result));
        }
    }
}

void MpvVideoItem::applyDefaultTracks()
{
    // The tracks as libmpv lists them once the file has loaded, sidecar
    // subtitles included; read here rather than taken from the last event so
    // the choice never runs on a list from the previous file.
    char *json = mpv_get_property_string(m_core.get(), "track-list");
    if (json != nullptr) {
        setTrackListValue(QByteArray(json));
        mpv_free(json);
    }

    // The released rule (TrackSelection::choose) picks by language alone:
    // `MPVPlayerService.swift` never reads the file's default or forced flags
    // when it opens a file, and this build does not invent a policy for
    // them. Where the saved language matches nothing the file opens with
    // subtitles Off (the oracle's sid=no) and libmpv's own audio pick, which
    // is the first track unless the file flags another as its default.
    const TrackChoice choice = TrackSelection::choose(
        m_audioTracks, m_subtitleTracks, m_defaultAudioLanguage, m_defaultSubtitleLanguage);
    if (choice.audioId.has_value() && *choice.audioId != m_audioTrackId) {
        selectAudioTrack(*choice.audioId);
    }
    if (choice.subtitleId != m_subtitleTrackId) {
        selectSubtitleTrack(choice.subtitleId);
    }
}

void MpvVideoItem::drainEvents()
{
    if (!m_core) {
        return;
    }

    while (true) {
        mpv_event *event = mpv_wait_event(m_core.get(), 0.0);
        if (event == nullptr || event->event_id == MPV_EVENT_NONE
            || event->event_id == MPV_EVENT_SHUTDOWN) {
            return;
        }

        applyEvent(event);
    }
}

void MpvVideoItem::applyEvent(mpv_event *event)
{
    if (event == nullptr) {
        return;
    }

    switch (event->event_id) {
        case MPV_EVENT_PROPERTY_CHANGE: {
            const auto *property = static_cast<mpv_event_property *>(event->data);
            if (property == nullptr || property->name == nullptr) {
                break;
            }

            const QByteArray name(property->name);
            if (name == "pause" && property->format == MPV_FORMAT_FLAG) {
                setPausedValue(*static_cast<int *>(property->data) != 0);
            } else if (name == "time-pos" && property->format == MPV_FORMAT_DOUBLE) {
                // Reports queued from the file this one replaced still reach
                // here after setSource. Nothing counts until the issued
                // entry's own FILE_LOADED: a stale position would clear the
                // startup latch at once, and a stale end would end a file
                // that has not begun.
                if (m_fileLoaded) {
                    setPositionValue(*static_cast<double *>(property->data));
                }
            } else if (name == "eof-reached" && property->format == MPV_FORMAT_FLAG
                       && *static_cast<int *>(property->data) != 0) {
                if (!m_fileLoaded) {
                    break;
                }
                // The oracle emits its end callback only from an ordinary
                // end (MPVPlayerService.swift:2633-2635 applies .ended for
                // EOF, :2636-2637 applies .fail for an error), so a terminal
                // failure never reports an end: PlayerView.swift:57 keeps
                // the failed player on screen behind its failure card, and
                // PlayerScreen.qml's onPlaybackEnded answers only the
                // ordinary end.
                if (!m_endReported && !m_failed) {
                    m_endReported = true;
                    emit playbackEnded();
                }
            } else if (name == "track-list") {
                setTrackListValue(property->format == MPV_FORMAT_STRING
                                      && property->data != nullptr
                                      && *static_cast<char **>(property->data) != nullptr
                                      ? QByteArray(*static_cast<char **>(property->data))
                                      : QByteArray());
            } else if (name == "aid") {
                setAudioTrackIdValue(trackIdFromProperty(property));
            } else if (name == "sid") {
                setSubtitleTrackIdValue(trackIdFromProperty(property));
            } else if (name == "volume" && property->format == MPV_FORMAT_DOUBLE) {
                setVolumeValue(*static_cast<double *>(property->data));
            } else if (name == "mute" && property->format == MPV_FORMAT_FLAG) {
                setMutedValue(*static_cast<int *>(property->data) != 0);
            } else if (name == "speed" && property->format == MPV_FORMAT_DOUBLE) {
                setSpeedValue(*static_cast<double *>(property->data));
            } else if (name == "duration") {
                setDurationValue(property->format == MPV_FORMAT_DOUBLE
                                     ? *static_cast<double *>(property->data)
                                     : 0.0);
            }
            break;
        }
        case MPV_EVENT_HOOK: {
            const auto *hook = static_cast<mpv_event_hook *>(event->data);
            if (hook == nullptr) {
                break;
            }
            // libmpv is parked at this hook until it is continued, so the
            // sidecars are in the track list before it picks tracks: from
            // START_FILE they raced that pick. The continue below runs for
            // every hook event (a stale entry, a stop, a failed add), since a
            // hook left open holds the load forever.
            // Every load passes this hook before its FILE_LOADED, so the entry
            // read here is the one the next FILE_LOADED belongs to.
            m_hookedEntry = m_core ? playingEntryId() : 0;
            if (m_pendingLoadEntry != 0 && m_hookedEntry == m_pendingLoadEntry) {
                m_pendingLoadEntry = 0;
                addSidecarSubtitles();
                // The sidecar the viewer chose reads "auto" again by now:
                // libmpv forgets a selected external track when the old file
                // goes, so the choice is put back once the track exists.
                if (m_restoreSubtitleId > 0) {
                    int64_t restored = m_restoreSubtitleId;
                    mpv_set_property(m_core.get(), "sid", MPV_FORMAT_INT64, &restored);
                }
            }
            if (m_core) {
                mpv_hook_continue(m_core.get(), hook->id);
            }
            break;
        }
        case MPV_EVENT_FILE_LOADED:
            handleFileLoaded();
            break;
        case MPV_EVENT_END_FILE: {
            const auto *endFile = static_cast<mpv_event_end_file *>(event->data);
            if (endFile == nullptr) {
                break;
            }
            handleEndFile(static_cast<int>(endFile->reason), endFile->error);
            break;
        }
        default:
            break;
        }
}

void MpvVideoItem::setError(const QString &message)
{
    setError(message, false);
}

void MpvVideoItem::setError(const QString &message, bool surfaceTeardown)
{
    if (message.isEmpty()) {
        clearError();
        return;
    }
    // A live genuine failure is never downgraded to teardown noise: a
    // tagged latch arriving after an untagged one leaves the genuine tag
    // (and its message) intact, so the superseding FILE_LOADED still
    // cannot retire it (PlaybackStateMachine.swift:87-95 rejects
    // .fileLoaded from .failed). A teardown-only latch stays retiring.
    if (m_failed && !m_errorIsSurfaceTeardown && surfaceTeardown) {
        return;
    }
    // A tagged report arriving while a tagged latch is live still describes
    // the superseded surface: it stays retiring. The reload's own open
    // failing carries the same signature — tagged, while the reload's
    // surface still reads present, because the new renderer's context
    // notification is still queued behind libmpv's own reports exactly the
    // way the old surface's echo is — so no report-time rule promotes one
    // of them. In particular a second report while the confirmation is
    // still live is the ordinary loss/regain pair draining before any
    // reload issued: promoting it (as the removed m_fileLoaded disjunct
    // did) latched an ordinary surface loss permanently, with no path out
    // but a new source or stop. The count below only remembers that a
    // second report arrived for the load-time guard in handleFileLoaded,
    // which pairs it with the settled render-context read — that pairing
    // is the one discriminator; nothing here decides genuine.
    if (m_failed && m_errorIsSurfaceTeardown && surfaceTeardown) {
        ++m_seenTeardownSinceReload;
        return;
    }
    // A fresh tagged latch opens a new pair count: the load-time guard
    // pairs "a second report arrived" with the settled context read, so
    // the count starts at zero here and moves on only while this latch is
    // live (branch above). The (re)load boundary in loadCurrentSource and
    // stop() reset it the same way for a new load.
    if (surfaceTeardown) {
        m_seenTeardownSinceReload = 0;
    }
    const bool stateChanged = !m_failed;
    m_failed = true;
    m_errorIsSurfaceTeardown = surfaceTeardown;
    const bool messageChanged = m_errorMessage != message;
    m_errorMessage = message;
    if (messageChanged) {
        qCWarning(logPlayback) << message;
        emit errorMessageChanged();
    }
    if (stateChanged) {
        emit failedChanged();
    }
}

void MpvVideoItem::clearError()
{
    const bool stateChanged = m_failed;
    const bool messageChanged = !m_errorMessage.isEmpty();
    m_failed = false;
    m_errorIsSurfaceTeardown = false;
    m_errorMessage.clear();
    if (messageChanged) {
        emit errorMessageChanged();
    }
    if (stateChanged) {
        emit failedChanged();
    }
}

void MpvVideoItem::loadCurrentSource()
{
    if (m_source.isEmpty()
        || (m_source == m_loadedSource && m_loadedGeneration == m_surfaceGeneration)) {
        return;
    }

    if (!m_core) {
        setError(QStringLiteral("Video engine unavailable."));
        return;
    }

    if (!m_source.isLocalFile()) {
        setError(QStringLiteral("Playback requires a local file: %1")
                     .arg(m_source.toString()));
        return;
    }

    // MPVPlayerService.loadFile clears the message at the new-load boundary
    // (MPVPlayerService.swift:2816-2818), and only there: a
    // surface-generation reload of the same file must not wipe a live
    // failure that no new load requested. It also runs before the context
    // gate below, matching the oracle's deferred pendingLoadPath flush (the
    // request re-arms in attachRenderView at MPVPlayerService.swift:2529-2534
    // even while the file waits for a surface). Membership is recorded only
    // after a successful loadfile below (:546-547), so a rejected loadfile
    // leaves the file retryable without re-arming anything: the next entry
    // past the context gate retries the same new source.
    const bool loadingNewSource = m_source != m_loadedSource;
    if (loadingNewSource) {
        clearError();
        m_playedBeforeReload = false;
        m_seenTeardownSinceReload = 0;
        // The previous file's tracks are not this file's; the saved languages
        // choose again once this one loads.
        setTrackListValue(QByteArray());
        setAudioTrackIdValue(0);
        setSubtitleTrackIdValue(0);
        m_chooseTracksOnLoad = true;
        if (m_resetControlsPending) {
            m_resetControlsPending = false;
            resetPlaybackControls();
        }
    }

    // libmpv fails a file outright when its video output cannot be set up, so
    // the file waits until the scene graph has handed the renderer a context.
    // A new source stays retryable past this gate (m_loadedSource is
    // recorded only after a successful loadfile below), so its next entry
    // past the gate retries the same load.
    if (!m_renderContextReady) {
        return;
    }

    // A same-source reload supersedes the lost surface: a teardown-tagged
    // failure — a video-output error for a file that provably played, or
    // while no render context stands — describes that surface rather than
    // the file. It is the failure the reload retires, not a boundary that
    // heals anything itself: teardown noise stays latched until the
    // reload's own FILE_LOADED supersedes it, so a reload that fails
    // before that load reports its own genuine error below instead of
    // vanishing into the boundary. A genuine failure is never cleared
    // here either: only a new load, stop, or the superseding FILE_LOADED
    // retires teardown noise.
    // (Kept latched rather than cleared at issue: clearing here is what
    // let a genuine VO_INIT_FAILED/NOTHING_TO_PLAY during the new
    // same-source open classify as teardown noise and be healed by
    // handleFileLoaded.)

    // Freeing a render context disables video for the file libmpv is holding,
    // so a replaced surface reloads the file and resumes where it left off. A
    // file that has not reached the position the session opened it at asks for
    // that position again instead, because the zero it has not left yet is not
    // where it left off.
    if (loadingNewSource) {
        m_endReported = false;
        m_startPending = true;
    }
    // Every issued (re)load opens a new load boundary, including a same-source
    // render-surface reload: until its FILE_LOADED arrives, a video-output
    // error describes that open rather than a surface this file provably
    // played behind, so a reload that fails before its next FILE_LOADED
    // reports a genuine failure instead of being mislabeled teardown noise.
    // The superseding reload still carries the proof that the held source
    // played before the reload cleared the confirmation: a teardown END_FILE
    // for the superseded surface can still be queued behind the reload's own
    // FILE_LOADED, and without the carried proof it misclassifies as a
    // genuine open failure the reload's FILE_LOADED can never heal.
    if (!loadingNewSource && m_fileLoaded && m_loadedSource == m_source) {
        m_playedBeforeReload = true;
    }
    m_fileLoaded = false;
    m_seenTeardownSinceReload = 0;
    m_resumePosition = m_startPending ? m_startPosition : m_position;
    // libmpv keeps the last track properties across loadfile, so the next
    // file starts from a known state: a new source from "automatic audio,
    // subtitles Off", and a surface reload of a file already chosen for from
    // the viewer's current tracks, which would otherwise snap back to the
    // defaults mid-film.
    {
        const bool restore = !m_chooseTracksOnLoad;
        const QByteArray audio = restore && m_audioTrackId > 0
            ? QByteArray::number(m_audioTrackId) : QByteArrayLiteral("auto");
        const QByteArray subtitle = restore && m_subtitleTrackId > 0
            ? QByteArray::number(m_subtitleTrackId) : QByteArrayLiteral("no");
        m_restoreSubtitleId = restore && m_subtitleTrackId > 0 ? m_subtitleTrackId : 0;
        mpv_set_property_string(m_core.get(), "aid", audio.constData());
        mpv_set_property_string(m_core.get(), "sid", subtitle.constData());
    }
    const QByteArray path = m_source.toLocalFile().toUtf8();
    const char *command[] = {"loadfile", path.constData(), "replace", nullptr};
    mpv_node loaded{};
    // Cleared before the command, so a loadfile that fails cannot leave an
    // older load's hook matching. On success the load's own playlist entry
    // follows, so the on_preloaded hook that opens it adds the sidecars and a
    // stale one from a load this replaced does not.
    m_pendingLoadEntry = 0;
    const int result = mpv_command_ret(m_core.get(), command, &loaded);
    if (result < 0) {
        setError(QStringLiteral("Could not open the file: %1").arg(mpvErrorText(result)));
        return;
    }
    m_issuedLoadEntry = 0;
    if (loaded.format == MPV_FORMAT_NODE_MAP && loaded.u.list != nullptr) {
        for (int index = 0; index < loaded.u.list->num; ++index) {
            if (std::strcmp(loaded.u.list->keys[index], "playlist_entry_id") == 0
                && loaded.u.list->values[index].format == MPV_FORMAT_INT64) {
                m_pendingLoadEntry = loaded.u.list->values[index].u.int64;
                m_issuedLoadEntry = m_pendingLoadEntry;
            }
        }
    }
    mpv_free_node_contents(&loaded);
    m_loadedSource = m_source;
    m_loadedGeneration = m_surfaceGeneration;
}

void MpvVideoItem::handleFileLoaded()
{
    // A surface that is lost and regained reloads the file while the load it
    // replaces can still have its FILE_LOADED queued here. That event
    // describes an entry libmpv has already dropped, so acting on it spends
    // the one resume seek on a file that is gone (the seek fails and the
    // reload then starts from the beginning) and settles the state the
    // reload's own FILE_LOADED has to settle.
    if (m_issuedLoadEntry != 0 && m_hookedEntry != 0 && m_hookedEntry != m_issuedLoadEntry) {
        return;
    }
    // PlaybackStateMachine.swift:87-95 rejects .fileLoaded from .failed, and
    // MPVPlayerService.loadFile clears playbackErrorMessage at the load
    // boundary only (:2817), never on fileLoaded. A FILE_LOADED therefore
    // heals exactly one latch: surface-teardown noise tagged in drainEvents
    // (VO_INIT_FAILED / NOTHING_TO_PLAY while the render context is absent —
    // the oracle answers a lost surface with stop, never fail, at
    // MPVPlayerService.swift:2360-2364 via :3338-3352). The successful load
    // proves libmpv opened the file behind the current surface and supersedes
    // that noise, so the message clears and the failure card
    // (PlayerView.swift:57) leaves with it. Every other failure latches
    // untagged and stays: the new-load boundary in loadCurrentSource is where
    // a genuine failure clears (the oracle's other exits from .failed include
    // .prepare at PlaybackStateMachine.swift:53-56 and .stop at :145-146,
    // mirrored by this item's setSource/loadCurrentSource and stop()), and a
    // surface-generation reload of a genuinely failed file preserves the
    // failure at that boundary by construction, so this event leaves it
    // intact. The resume seek still runs only while no failure is live,
    // because seeking a failed session would only re-mask it.
    if (m_failed && !m_errorIsSurfaceTeardown) {
        return;
    }
    // The reload's FILE_LOADED supersedes the lost surface and retires the
    // tagged latch — unless a second tagged report already arrived while
    // the latch was live AND no render context stands behind this load.
    // Pairing those two facts is the one discriminator. The second report
    // shows the teardown pair drained, not a lone echo; the absent context
    // shows the reload's own open took its surface with it rather than
    // standing behind this load. Either fact alone heals: a single report
    // (the ordinary loss) heals however the notifications ordered, and a
    // pair draining behind the reload's still-standing surface is still the
    // old surface echoing while the superseding load arrives, so that load
    // retires it. A lone second report while the confirmation is still
    // live never reaches this guard as genuine for the wrong reason: no
    // reload issued, no load boundary ran, and the reload's own
    // FILE_LOADED supersedes it — retiring needs no second report, and
    // waiting for one strands the latch. (A new source clears the latch at
    // its boundary in loadCurrentSource, so a moved-on count can only
    // have started inside the live in-flight reload it guards.)
    if (m_failed && m_errorIsSurfaceTeardown && m_seenTeardownSinceReload > 0
        && !m_renderContextReady) {
        return;
    }
    // Untouched by the reload boundary above: only this FILE_LOADED retires
    // teardown noise, so the stranded pre-reload proof leaves with the load
    // that superseded it and no later genuine break can hide behind it.
    // The teardown count resets with the confirmation: the next reload
    // starts its own first-report carve-out from zero.
    clearError();
    m_seenTeardownSinceReload = 0;
    m_fileLoaded = true;
    // The in-flight reload's FILE_LOADED supersedes the carried proof: a
    // later teardown END_FILE again proves the file behind this surface
    // through the confirmation above, so the stranded flag leaves no stale
    // proof behind for a genuinely broken reload to hide behind.
    m_playedBeforeReload = false;
    if (m_chooseTracksOnLoad && m_core) {
        m_chooseTracksOnLoad = false;
        applyDefaultTracks();
    }
    if (m_resumePosition > 0.0) {
        seekAbsolute(m_resumePosition);
        m_resumePosition = 0.0;
    }
}

void MpvVideoItem::handleEndFile(int reason, int error)
{
    // keep-open holds a finished file open and reports the end through
    // eof-reached, so a file that ends here ended badly.
    if (reason != MPV_END_FILE_REASON_ERROR) {
        return;
    }
    // The intact render context proves which errors describe the
    // file: once it is gone, VO errors describe the absent surface
    // instead. Freeing the render context disables video for the
    // file libmpv is holding, so the loss path reports
    // VO_INIT_FAILED for the superseded output and then
    // NOTHING_TO_PLAY once the output is gone — the display-backed
    // pair in the surface-loss log. (A headless loadfile with no render
    // context at all also ends VO-less as NOTHING_TO_PLAY, which is why
    // the classifier below never tags on the code alone: without a live
    // tagged latch, proof the file played, or an absent context behind
    // an in-flight reload, a video-output error still latches genuine.)
    // The oracle answers a lost surface with stop, never fail (MPVPlayerService.swift
    // :2360-2364 answers MPVOGLView.swift:49-56
    // via :3338-3352, and freeRenderContext
    // at :2567-2571 is private with no callers, so no oracle path
    // turns a lost surface into a failure), so these two codes
    // while the context is absent are tagged as teardown noise for
    // the superseding FILE_LOADED to retire.
    //
    // The loss notification crosses threads on a queued connection while
    // libmpv's own report arrives on another, so the END_FILE can be
    // drained before the queued renderContextLost clears the flag: the
    // context then still reads ready for a surface that is already gone.
    // A video-output error for a file libmpv already confirmed behind
    // this surface (FILE_LOADED seen for the held source) cannot describe
    // the file — it played — so it is teardown noise however the two
    // notifications ordered. A same-source render-surface reload clears
    // that confirmation when it is issued, and libmpv's teardown END_FILE
    // for the superseded surface can be queued behind the reload in
    // either order: after the reload's own FILE_LOADED it would otherwise
    // read as a video-output error for a file that never loaded and latch
    // genuine — the observed second error the repair heals from instead of
    // latching. The carried pre-reload proof above is what tells that
    // trailing teardown report from a reload that itself failed before
    // its FILE_LOADED: with no live tagged latch, a video-output error
    // for a file that never loaded still latches as a genuine failure
    // that FILE_LOADED cannot heal (PlaybackStateMachine.swift:87-95
    // rejects .fileLoaded from .failed), as does every other error code.
    // libmpv's mpv_error codes arrive verbatim on END_FILE (mpv/client.h):
    // MPV_ERROR_VO_INIT_FAILED (-15) means initializing the video output
    // failed — the surface going away — and MPV_ERROR_NOTHING_TO_PLAY
    // (-16) means no audio or video data to play, which is what the loss
    // path reports once the output is gone. The classifier below tags
    // exactly this display-backed pair as teardown noise for the
    // superseding FILE_LOADED to retire, and only while one of the
    // surface proofs holds (no context standing, a confirmed file behind
    // this surface, or the carried pre-reload proof): every other error
    // code — UNKNOWN_FORMAT for a broken file, LOADING_FAILED, the audio
    // failure, and the rest — latches genuine however the surface reads,
    // as does a video-output error with no surface proof behind it.
    const bool videoOutputError = error == MPV_ERROR_VO_INIT_FAILED
        || error == MPV_ERROR_NOTHING_TO_PLAY;
    const bool heldFilePlayed = m_fileLoaded && m_loadedSource == m_source;
    const bool playedBeforeInFlightReload =
        m_playedBeforeReload && m_loadedSource == m_source;
    // A new load boundary retires teardown noise only through the reload's
    // own FILE_LOADED. Reports that arrive while a tagged latch is live
    // only move the pair count on for that load-time guard — the first
    // queued echo of the superseded surface arrives with that count still
    // zero (see setError), so it stays retiring: the observed display-backed
    // VO_INIT_FAILED/NOTHING_TO_PLAY pair heals through the reload's
    // FILE_LOADED exactly because that first echo stays teardown, while a
    // second report plus a lost surface together hold the latch.
    const bool teardownSignature = videoOutputError
        && (!m_renderContextReady || heldFilePlayed || playedBeforeInFlightReload);
    setError(QStringLiteral("Playback failed: %1").arg(mpvErrorText(error)),
             teardownSignature);
}

void MpvVideoItem::onRenderContextReady()
{
    m_renderContextReady = true;
    ++m_surfaceGeneration;
    loadCurrentSource();
}

void MpvVideoItem::onRenderContextLost()
{
    m_renderContextReady = false;
    // Without video there are no frames to schedule a repaint, so the item has
    // to ask for one itself or the scene graph never builds another surface.
    update();
}

void MpvVideoItem::setPauseFlag(bool value)
{
    if (!m_core) {
        return;
    }

    int flag = value ? 1 : 0;
    const int result = mpv_set_property(m_core.get(), "pause", MPV_FORMAT_FLAG, &flag);
    if (result < 0) {
        setError(QStringLiteral("Could not change playback state: %1")
                     .arg(mpvErrorText(result)));
    }
}

void MpvVideoItem::setPausedValue(bool value)
{
    if (m_paused == value) {
        return;
    }
    m_paused = value;
    emit pausedChanged();
}

void MpvVideoItem::setPositionValue(double value)
{
    if (m_startPending && value >= m_startPosition) {
        m_startPending = false;
    }
    // PlayerView.swift:108-124 reaches the clock only in lifecycle .playing:
    // once a position past the startup window proves playback established,
    // the start-of-session state is left for good. A later seek back to 0
    // only moves the clock; the latch stays cleared, paused or not.
    // The oracle clears when `clock.currentTime < 0.35` no longer holds, so
    // exactly 0.35 is already past the transition: `>=` matches it.
    if (m_startupPending && value >= 0.35) {
        m_startupPending = false;
        emit startupPendingChanged();
    }
    if (qFuzzyCompare(m_position, value)) {
        return;
    }
    m_position = value;
    emit positionChanged();
}

void MpvVideoItem::setDurationValue(double value)
{
    if (qFuzzyCompare(m_duration, value)) {
        return;
    }
    m_duration = value;
    emit durationChanged();
}

#include "MpvVideoItem.moc"
