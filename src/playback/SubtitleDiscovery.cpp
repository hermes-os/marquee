#include "playback/SubtitleDiscovery.hpp"

#include <QDir>
#include <QFileInfo>
#include <QSet>
#include <QStringList>

#include "playback/TrackSelection.hpp"

namespace {

const QStringList &subtitleExtensions()
{
    // `SubtitleFormat` in `SubtitleDiscovery.swift:5-16`.
    static const QStringList extensions{
        QStringLiteral("srt"), QStringLiteral("ass"), QStringLiteral("ssa"),
        QStringLiteral("vtt")};
    return extensions;
}

[[nodiscard]] bool isSeparator(QChar character)
{
    return character == QLatin1Char('.') || character == QLatin1Char('_')
        || character == QLatin1Char('-') || character == QLatin1Char(' ');
}

/// `parseLanguageCode` (`SubtitleDiscovery.swift:142-157`): the first word of
/// what follows the video's name, if a released table knows it.
[[nodiscard]] QString languageCode(const QString &suffix)
{
    qsizetype begin = 0;
    while (begin < suffix.size() && isSeparator(suffix.at(begin))) {
        ++begin;
    }
    qsizetype end = begin;
    while (end < suffix.size() && !isSeparator(suffix.at(end))) {
        ++end;
    }
    const QString code = suffix.mid(begin, end - begin).toLower();
    return TrackSelection::releasedLanguageName(code).isEmpty() ? QString() : code;
}

}

namespace SubtitleDiscovery {

bool matches(const QString &subtitleFileName,
             const QString &videoBaseName,
             SidecarSubtitle *result)
{
    const QFileInfo file(subtitleFileName);
    if (!subtitleExtensions().contains(file.suffix().toLower())) {
        return false;
    }

    const QString name = file.completeBaseName();
    if (!name.startsWith(videoBaseName, Qt::CaseInsensitive)) {
        return false;
    }

    // "Episode 10.en.srt" starts with "Episode 1" but belongs to another
    // episode: what follows the video's name must open with a separator.
    const QString suffix = name.mid(videoBaseName.size());
    if (!suffix.isEmpty() && !isSeparator(suffix.at(0))) {
        return false;
    }

    if (result != nullptr) {
        result->path = subtitleFileName;
        result->language = languageCode(suffix);
    }
    return true;
}

QList<SidecarSubtitle> discover(const QString &videoPath)
{
    const QFileInfo video(videoPath);
    const QString baseName = video.completeBaseName();
    const QDir parent = video.absoluteDir();

    // `gatherScanDirectories` (`SubtitleDiscovery.swift:67-90`): the video's
    // folder, then the four conventional subfolders, each scanned once even
    // when a symlink or a case-insensitive volume reaches it twice.
    QList<QDir> directories{parent};
    QSet<QString> seen{QFileInfo(parent.absolutePath()).canonicalFilePath()};
    for (const QString &name : {QStringLiteral("Subs"), QStringLiteral("subs"),
                                QStringLiteral("Subtitles"), QStringLiteral("subtitles")}) {
        const QFileInfo sub(parent.filePath(name));
        if (!sub.isDir()) {
            continue;
        }
        if (seen.contains(sub.canonicalFilePath())) {
            continue;
        }
        seen.insert(sub.canonicalFilePath());
        directories.append(QDir(sub.canonicalFilePath()));
    }

    QList<SidecarSubtitle> found;
    for (const QDir &directory : std::as_const(directories)) {
        // Sorted so the menu order does not depend on the file system.
        const QStringList names = directory.entryList(
            QDir::Files | QDir::NoDotAndDotDot, QDir::Name);
        for (const QString &name : names) {
            SidecarSubtitle subtitle;
            if (matches(name, baseName, &subtitle)) {
                subtitle.path = directory.absoluteFilePath(name);
                found.append(subtitle);
            }
        }
    }
    return found;
}

}
