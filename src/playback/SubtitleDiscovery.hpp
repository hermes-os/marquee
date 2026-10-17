#pragma once

#include <QList>
#include <QString>

/// A subtitle file that sits beside a video and belongs to it.
struct SidecarSubtitle
{
    QString path;
    /// The code the file name carries ("en", "fra"), lower case, when it is
    /// one of the released app's known languages; empty otherwise.
    QString language;
};

namespace SubtitleDiscovery
{
/// Finds the subtitle files of `videoPath` by the released rule
/// (`SubtitleDiscovery.swift:57-138`): a .srt, .ass, .ssa or .vtt file in the
/// video's folder, or in its Subs, subs, Subtitles or subtitles subfolder,
/// whose name starts with the video's file name (case-insensitively) and then
/// either ends or continues with a ".", "_", "-" or space. libmpv's own
/// "fuzzy" search is not used: it also takes "Episode 10.en.srt" for
/// "Episode 1.mkv".
[[nodiscard]] QList<SidecarSubtitle> discover(const QString &videoPath);

/// The rule for one file name inside a scanned folder; `discover` applies it
/// to every file. Returns false when `subtitleFileName` is not a sidecar of
/// `videoBaseName`.
[[nodiscard]] bool matches(const QString &subtitleFileName,
                           const QString &videoBaseName,
                           SidecarSubtitle *result = nullptr);
}
