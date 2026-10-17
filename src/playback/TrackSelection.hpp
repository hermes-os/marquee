#pragma once

#include <optional>

#include <QByteArray>
#include <QList>
#include <QString>
#include <QVariantMap>

/// One audio or subtitle track as libmpv's `track-list` reports it.
struct MediaTrack
{
    enum class Kind { Audio, Subtitle };

    Kind kind{Kind::Audio};
    /// libmpv's per-kind track id, the value `aid` and `sid` take.
    int id{0};
    /// The container's language tag, usually ISO 639-2 ("eng"); empty when
    /// the file carries none.
    QString language;
    QString title;
    QString codec;
    bool isDefault{false};
    bool forced{false};
    /// A sidecar file libmpv loaded next to the video, not a stream inside it.
    bool external{false};
    QString externalFilename;
};

/// What the viewer's saved language settings choose for a file that just
/// opened. `audioId` is empty when nothing matched and libmpv's own choice
/// stands; `subtitleId` is 0 for Off.
struct TrackChoice
{
    std::optional<int> audioId;
    int subtitleId{0};
};

namespace TrackSelection
{
/// Parses libmpv's `track-list` JSON and keeps the audio and subtitle
/// entries, in the order libmpv lists them. Malformed input yields nothing.
[[nodiscard]] QList<MediaTrack> parseTrackList(const QByteArray &json);

/// The name the released app's two code tables (`SubtitleDiscovery.swift:
/// 171-273`) give a bare ISO 639-1 or 639-2 code, or an empty string for any
/// other word. Unlike `languageName` it never asks Qt, so a file-name word
/// such as "the" or "part" is not mistaken for a language.
[[nodiscard]] QString releasedLanguageName(const QString &code);

/// English name for a container language tag ("eng", "fre", "fra", "en",
/// "pt-BR"), or an empty string when the tag names no language.
[[nodiscard]] QString languageName(const QString &tag);

/// The menu label: `MPVPlayerService.swift:2753-2766` for a stream (title,
/// else the language's name, else the raw tag, else "Track N", then the
/// codec in parentheses) and `SubtitleDiscovery.swift:156-161` for a sidecar
/// file ("English (SRT)", "External (SRT)").
[[nodiscard]] QString label(const MediaTrack &track);

/// Applies `AVPlayerService.swift:371-392`: Default Subtitle Language "None"
/// is Off, otherwise the first subtitle track naming the language is on and
/// none naming it leaves Off; Default Audio Language picks the first audio
/// track naming it and otherwise leaves libmpv's default.
[[nodiscard]] TrackChoice choose(const QList<MediaTrack> &audioTracks,
                                 const QList<MediaTrack> &subtitleTracks,
                                 const QString &audioLanguage,
                                 const QString &subtitleLanguage);

/// `SubtitleOverlayView.swift:49-52, 56-58`: the saved Subtitle Size clamped
/// to the slider's 0.8...2.2, times the lean-back layout scale of 1.15.
[[nodiscard]] double subtitleScale(double saved, bool leanBack);

/// The track as the QML menus read it.
[[nodiscard]] QVariantMap toVariant(const MediaTrack &track);
}
