#include "catalog/LibraryScanner.hpp"

#include <QCryptographicHash>
#include <QDate>
#include <QDir>
#include <QFileInfoList>
#include <QLatin1Char>
#include <QRegularExpression>
#include <QSet>
#include <QStringList>

#include <algorithm>
#include <optional>

#include "support/Logging.hpp"

namespace
{
// A four-digit token beyond next year names the title, not the release
// (`Blade Runner 2049.2017`).
[[nodiscard]] bool isPlausibleReleaseYear(int year)
{
    return year <= QDate::currentDate().year() + 1;
}

// Symlinks are excluded so nothing a link points at can enter the library from
// outside the configured root, and hidden entries are excluded because trash and
// sync directories inside a root hold ordinary-looking media files.
constexpr QDir::Filters libraryEntryFilters =
    QDir::Files | QDir::Dirs | QDir::NoSymLinks | QDir::NoDotAndDotDot;

// CatalogContentPolicy.swift:90.
const QStringList &imageExtensions()
{
    static const QStringList extensions{QStringLiteral("jpg"), QStringLiteral("jpeg"),
                                        QStringLiteral("png"), QStringLiteral("webp")};
    return extensions;
}

/// The sidecar named after the media file, then the artwork the whole folder
/// shares. Candidates are matched against `fileNames`, the directory's own
/// listing, so artwork obeys the same containment as the walk: a symlinked or
/// hidden poster is not in that listing and can never be adopted.
[[nodiscard]] QString posterNameFor(const QString &stem, const QSet<QString> &fileNames)
{
    const QStringList candidates{stem + QStringLiteral("-poster.jpg"),
                                 stem + QStringLiteral("-poster.png"),
                                 QStringLiteral("poster.jpg"),
                                 QStringLiteral("folder.jpg"),
                                 QStringLiteral("poster.png")};

    for (const QString &candidate : candidates) {
        if (fileNames.contains(candidate)) {
            return candidate;
        }
    }

    return {};
}

/// A listing can name an entry the filesystem then refuses to open or stat (a
/// name the driver cannot map, a link to nowhere, a file deleted mid-scan).
/// The listing's own `QFileInfo` may answer from the directory read alone, so
/// the entry is stat'ed afresh by path.
[[nodiscard]] std::optional<QFileInfo> statableFile(const QFileInfo &listed)
{
    const QFileInfo fresh(listed.absoluteFilePath());
    if (!fresh.exists() || !fresh.isFile()) {
        return std::nullopt;
    }
    return fresh;
}

/// The names a directory's own listing holds, under the walk's containment
/// rules, so folder artwork is adopted by the same evidence as media files.
/// A sidecar that cannot be stat'ed is missing, not an error.
[[nodiscard]] QSet<QString> fileNamesIn(const QString &directoryPath)
{
    QSet<QString> names;
    const QFileInfoList entries = QDir(directoryPath).entryInfoList(libraryEntryFilters);
    for (const QFileInfo &entry : entries) {
        if (!entry.isDir() && statableFile(entry)) {
            names.insert(entry.fileName());
        }
    }
    return names;
}

struct FolderArtwork
{
    QString poster;
    QString backdrop;
};

/// CatalogContentPolicy.swift:189-216: a show or season folder's own
/// `poster`/`folder` and `fanart`/`backdrop`, in that name order across the
/// image extensions, with no per-file variants.
[[nodiscard]] FolderArtwork folderArtworkIn(const QString &directoryPath)
{
    const QSet<QString> names = fileNamesIn(directoryPath);
    const QDir directory(directoryPath);
    FolderArtwork artwork;

    for (const QString &extension : imageExtensions()) {
        for (const QString &stem : {QStringLiteral("poster"), QStringLiteral("folder")}) {
            const QString candidate = stem + QLatin1Char('.') + extension;
            if (artwork.poster.isEmpty() && names.contains(candidate)) {
                artwork.poster = directory.filePath(candidate);
            }
        }
        for (const QString &stem : {QStringLiteral("fanart"), QStringLiteral("backdrop")}) {
            const QString candidate = stem + QLatin1Char('.') + extension;
            if (artwork.backdrop.isEmpty() && names.contains(candidate)) {
                artwork.backdrop = directory.filePath(candidate);
            }
        }
    }

    return artwork;
}

/// CatalogContentPolicy.swift:150-173: the still named after the episode
/// file. Folder-level names are deliberately not candidates, so one season
/// backdrop cannot stand in for every episode's thumbnail.
[[nodiscard]] QString episodeStillNameFor(const QString &stem, const QSet<QString> &fileNames)
{
    for (const QString &extension : imageExtensions()) {
        const QStringList candidates{stem + QLatin1Char('.') + extension,
                                     stem + QStringLiteral("-still.") + extension,
                                     stem + QStringLiteral(" still.") + extension,
                                     stem + QStringLiteral("-screenshot.") + extension,
                                     stem + QStringLiteral(" screenshot.") + extension,
                                     stem + QStringLiteral("-thumb.") + extension,
                                     stem + QStringLiteral(" thumb.") + extension};
        for (const QString &candidate : candidates) {
            if (fileNames.contains(candidate)) {
                return candidate;
            }
        }
    }
    return {};
}

const QRegularExpression &seasonFolderExpression()
{
    // CatalogContentPolicy.swift:223.
    static const QRegularExpression expression(QStringLiteral(R"(^[Ss]eason\s*(\d+)$)"));
    return expression;
}

/// CatalogContentPolicy.swift:239-264: the folder above the first `Season N`
/// component, as a path relative to the root; empty when the season folder is
/// the root's own child and there is no show folder at all.
[[nodiscard]] QString showFolderRelativePath(const QStringList &components)
{
    for (qsizetype index = 0; index < components.size(); ++index) {
        if (seasonFolderExpression().match(components.at(index)).hasMatch()) {
            return QStringList(components.mid(0, index)).join(QLatin1Char('/'));
        }
    }
    return {};
}

/// CatalogContentPolicy.swift:271-289: `The Wire (2002)` is the Plex folder
/// shape; anything else is the show's name verbatim.
struct ShowFolderName
{
    QString name;
    int year{0};
};

[[nodiscard]] ShowFolderName parseShowFolderName(const QString &folderName)
{
    static const QRegularExpression expression(QStringLiteral(R"(^(.+?)\s*\((\d{4})\)\s*$)"));
    const QRegularExpressionMatch match = expression.match(folderName);
    if (match.hasMatch()) {
        return {.name = match.captured(1).trimmed(), .year = match.captured(2).toInt()};
    }
    return {.name = folderName.trimmed(), .year = 0};
}

// FilenameParser.swift:6-22, applied to episode titles after dots and
// underscores become spaces (:120-125).
const QVector<QRegularExpression> &cleanTitleExpressions()
{
    static const QVector<QRegularExpression> expressions{
        QRegularExpression(QStringLiteral(R"(\s*\(?\d{3,4}p\b[^)]*\)?)")),
        QRegularExpression(QStringLiteral(
            R"(\s*\(?(?:x26[45]|h\.?26[45]|[Hh][Ee][Vv][Cc]|AVC|AAC|AC3|DTS|FLAC)\s*[^)]*\)?)")),
        QRegularExpression(QStringLiteral(
            R"(\s*\(?(?:DVD|Blu-?[Rr]ay|BDRip|WEB[-.]?DL|HDRip|WEBRip|HDTV)\s*[^)]*\)?)")),
        QRegularExpression(QStringLiteral(R"(\s*[\[\(][^\]\)]+[\]\)]$)")),
        QRegularExpression(QStringLiteral(
            R"((?i)\s*-\s*(?:yify|yts(?:\.[a-z]{2})?|rarbg|etrg|ettv|eztv|evo|fgt|axxo|anoxmous)$)")),
        QRegularExpression(QStringLiteral(R"((?i)\s+-\s*(?:sparks|geckos|amiable|drones)$)")),
        QRegularExpression(QStringLiteral(R"(\s+-\s*(?![IVXLCDM]+$)[A-Z0-9]{2,}$)"))};
    return expressions;
}

[[nodiscard]] QString cleanEpisodeTitle(QString title)
{
    title.replace(QLatin1Char('.'), QLatin1Char(' '));
    title.replace(QLatin1Char('_'), QLatin1Char(' '));
    for (const QRegularExpression &expression : cleanTitleExpressions()) {
        title.remove(expression);
    }
    return title.trimmed();
}

[[nodiscard]] QString normalizedShowName(QString name)
{
    name.replace(QLatin1Char('.'), QLatin1Char(' '));
    name.replace(QLatin1Char('_'), QLatin1Char(' '));
    return name.trimmed();
}

// FilenameParser.swift:24-47, in the same order: the first shape to match
// wins, so `Show - S01E02 - Title` is read by the dashed rule before the
// looser dotted one can split it differently.
const QVector<QRegularExpression> &episodeExpressions()
{
    static const QVector<QRegularExpression> expressions{
        QRegularExpression(QStringLiteral(
            R"(^(.+?)\s*-\s*[Ss](\d{1,2})[Ee](\d{1,4})[Ee]\d{1,2}\s*-\s*(.+)$)")),
        QRegularExpression(QStringLiteral(R"(^(.+?)\s*-\s*[Ss](\d{1,2})[Ee](\d{1,4})\s*-\s*(.+)$)")),
        QRegularExpression(QStringLiteral(R"(^(.+?)\s*-\s*[Ss](\d{1,2})[Ee](\d{1,4})\s*$)")),
        QRegularExpression(QStringLiteral(
            R"(^(.+?)[.\s_][Ss](\d{1,2})[Ee](\d{1,4})[Ee]\d{1,2}(?:[.\s_-]+(.+))?$)")),
        QRegularExpression(QStringLiteral(
            R"(^(.+?)[.\s_][Ss](\d{1,2})[Ee](\d{1,4})(?:[.\s_-]+(.+))?$)")),
        QRegularExpression(QStringLiteral(
            R"(^(.+?)\s*-\s*[Ss](\d{1,2})\s+[Ee](\d{1,4})\s*-\s*(.+)$)")),
        QRegularExpression(QStringLiteral(R"(^(.+?)[.\s_][Ss](\d{1,2})\s+[Ee](\d{1,4}))")),
        QRegularExpression(QStringLiteral(R"(^(.+?)\s*-\s*(\d{1,2})x(\d{2,3})\s*-\s*(.+)$)")),
        QRegularExpression(QStringLiteral(R"(^(.+?)\s*-\s*(\d{1,2})x(\d{2,3})\s*$)")),
        QRegularExpression(QStringLiteral(R"(^(.+?)[.\s_](\d{1,2})x(\d{2,3}))")),
        QRegularExpression(QStringLiteral(
            R"(^(.+?)\s+[Ss]eason\s+(\d{1,2})\s+[Ee]pisode\s+(\d{1,4}))"))};
    return expressions;
}

[[nodiscard]] QString stemOf(const QString &fileName)
{
    return QFileInfo(fileName).completeBaseName();
}

/// Appends `directoryPath`'s media files and recurses into its subdirectories.
/// Returns false when any directory in the subtree cannot be enumerated,
/// because a walk that silently skipped part of the tree would look like proof
/// that the rows it missed are gone. A media entry that is listed but cannot be
/// stat'ed does not make the walk partial: the listing proves the file is
/// there, so its id goes into `unreadableIds` and the catalog keeps its row.
/// A failure never stops the walk: everything readable is still collected.
[[nodiscard]] bool collectInto(const QString &directoryPath, const QDir &rootDirectory,
                               const LibraryRoot &root, QVector<MediaItem> &items,
                               QSet<QString> &unreadableIds)
{
    const QFileInfo directoryInfo(directoryPath);
    if (!directoryInfo.isReadable() || !directoryInfo.isExecutable()) {
        qCWarning(logScanner) << "library subtree is not readable:" << directoryPath;
        return false;
    }

    bool complete = true;

    const QFileInfoList entries =
        QDir(directoryPath).entryInfoList(libraryEntryFilters);

    // Folder artwork can be listed after the media file it belongs to, so the
    // directory's file names are collected before any of them is turned into an
    // item.
    QSet<QString> fileNames;
    for (const QFileInfo &entry : entries) {
        if (!entry.isDir() && statableFile(entry)) {
            fileNames.insert(entry.fileName());
        }
    }

    // The season and show folders are properties of the directory, so they are
    // resolved once per directory rather than once per file in it.
    const QString directoryRelativePath = rootDirectory.relativeFilePath(directoryPath);
    const QStringList directoryComponents = directoryRelativePath == QStringLiteral(".")
        ? QStringList()
        : directoryRelativePath.split(QLatin1Char('/'), Qt::SkipEmptyParts);
    const int seasonNumber = root.role == LibraryRoot::Role::TvShows
        ? LibraryScanner::seasonNumberFromPath(directoryRelativePath)
        : 0;

    QString showRelativePath;
    ShowFolderName showFolder;
    FolderArtwork showArtwork;
    FolderArtwork seasonArtwork;
    if (seasonNumber > 0) {
        showRelativePath = showFolderRelativePath(directoryComponents);
        // CatalogProjection.swift:436-442: the show folder names the show;
        // without one the filename's own show name is used, then "Unknown
        // Show".
        showFolder = showRelativePath.isEmpty()
            ? ShowFolderName{}
            : parseShowFolderName(QFileInfo(showRelativePath).fileName());
        showArtwork = showRelativePath.isEmpty()
            ? FolderArtwork{}
            : folderArtworkIn(rootDirectory.filePath(showRelativePath));
        seasonArtwork = folderArtworkIn(directoryPath);
    }

    for (const QFileInfo &entry : entries) {
        if (entry.isDir()) {
            if (!collectInto(entry.absoluteFilePath(), rootDirectory, root, items,
                             unreadableIds)) {
                complete = false;
            }
            continue;
        }

        if (!LibraryScanner::isSupportedMediaFile(entry)) {
            continue;
        }

        const QString relativePath =
            rootDirectory.relativeFilePath(entry.absoluteFilePath());
        const QString posterName = posterNameFor(entry.completeBaseName(), fileNames);
        const QString posterPath =
            posterName.isEmpty() ? QString() : entry.absoluteDir().filePath(posterName);

        if (root.role == LibraryRoot::Role::TvShows) {
            if (seasonNumber == 0) {
                // CatalogProjection.swift:532-533 projects a file outside any
                // season folder as a movie-shaped row that no TV surface can
                // show and the Movies grid never receives. Not storing it
                // changes nothing that can be opened.
                continue;
            }
            LibraryScanner::ParsedEpisode episode;
            if (!LibraryScanner::parseEpisodeFilename(entry.fileName(), episode)
                && !LibraryScanner::parseEpisodeFromFolder(entry.fileName(), seasonNumber,
                                                           episode)) {
                // CatalogProjection.swift:527-531 drops these silently.
                continue;
            }

            const std::optional<QFileInfo> episodeFile = statableFile(entry);
            const QDateTime episodeModifiedAt =
                episodeFile ? episodeFile->lastModified().toUTC() : QDateTime();
            if (!episodeModifiedAt.isValid()) {
                qCWarning(logScanner) << "skipped unreadable media file:" << entry.absoluteFilePath();
                unreadableIds.insert(LibraryScanner::mediaIdFor(root.id, relativePath));
                continue;
            }

            const QString showName = !showFolder.name.isEmpty() ? showFolder.name
                : !episode.showName.isEmpty()                   ? episode.showName
                                                                : QStringLiteral("Unknown Show");
            const QString episodeStillName =
                episodeStillNameFor(entry.completeBaseName(), fileNames);
            const auto relativeOrEmpty = [&rootDirectory](const QString &absolute) {
                return absolute.isEmpty() ? QString() : rootDirectory.relativeFilePath(absolute);
            };
            const QString episodeStillPath = episodeStillName.isEmpty()
                ? QString()
                : entry.absoluteDir().filePath(episodeStillName);

            items.push_back(MediaItem{
                .id = LibraryScanner::mediaIdFor(root.id, relativePath),
                .libraryRootId = root.id,
                .relativePath = relativePath,
                .absolutePath = entry.absoluteFilePath(),
                // MediaItem.swift:496-500: an episode's title is its show.
                .title = showName,
                .sortTitle = showName.toLower(),
                .mediaKind = QStringLiteral("episode"),
                .year = showFolder.year,
                .posterRelativePath = relativeOrEmpty(posterPath),
                .posterAbsolutePath = posterPath,
                .fileSize = episodeFile->size(),
                .modifiedAt = episodeModifiedAt,
                .showName = showName,
                .seasonNumber = episode.seasonNumber,
                .episodeNumber = episode.episodeNumber,
                .episodeTitle = episode.episodeTitle,
                .showPosterRelativePath = relativeOrEmpty(showArtwork.poster),
                .showPosterAbsolutePath = showArtwork.poster,
                .showBackdropRelativePath = relativeOrEmpty(showArtwork.backdrop),
                .showBackdropAbsolutePath = showArtwork.backdrop,
                .seasonPosterRelativePath = relativeOrEmpty(seasonArtwork.poster),
                .seasonPosterAbsolutePath = seasonArtwork.poster,
                .episodeStillRelativePath = relativeOrEmpty(episodeStillPath),
                .episodeStillAbsolutePath = episodeStillPath});
            continue;
        }

        const std::optional<QFileInfo> movieFile = statableFile(entry);
        const QDateTime movieModifiedAt =
            movieFile ? movieFile->lastModified().toUTC() : QDateTime();
        if (!movieModifiedAt.isValid()) {
            qCWarning(logScanner) << "skipped unreadable media file:" << entry.absoluteFilePath();
            unreadableIds.insert(LibraryScanner::mediaIdFor(root.id, relativePath));
            continue;
        }

        const LibraryScanner::ParsedFilename parsed =
            LibraryScanner::parseMovieFilename(entry);

        items.push_back(MediaItem{
            .id = LibraryScanner::mediaIdFor(root.id, relativePath),
            .libraryRootId = root.id,
            .relativePath = relativePath,
            .absolutePath = entry.absoluteFilePath(),
            .title = parsed.title,
            .sortTitle = parsed.title.toLower(),
            .mediaKind = QStringLiteral("movie"),
            .year = parsed.year,
            .posterRelativePath =
                posterPath.isEmpty() ? QString()
                                     : rootDirectory.relativeFilePath(posterPath),
            .posterAbsolutePath = posterPath,
            .fileSize = movieFile->size(),
            .modifiedAt = movieModifiedAt,
            // Movies store NULL in every episode column, so the projection's
            // defaults (empty text, zero numbers) are restated here.
            .showName = QString(),
            .seasonNumber = 0,
            .episodeNumber = 0,
            .episodeTitle = QString(),
            .showPosterRelativePath = QString(),
            .showPosterAbsolutePath = QString(),
            .showBackdropRelativePath = QString(),
            .showBackdropAbsolutePath = QString(),
            .seasonPosterRelativePath = QString(),
            .seasonPosterAbsolutePath = QString(),
            .episodeStillRelativePath = QString(),
            .episodeStillAbsolutePath = QString()});
    }

    return complete;
}
}

bool LibraryScanner::isSupportedMediaFile(const QFileInfo &file)
{
    static const QSet<QString> extensions{
        QStringLiteral("mp4"), QStringLiteral("m4v"), QStringLiteral("mov"),
        QStringLiteral("mkv"), QStringLiteral("webm"), QStringLiteral("avi"),
        QStringLiteral("mpg"), QStringLiteral("mpeg"), QStringLiteral("ts"),
        QStringLiteral("m2ts"), QStringLiteral("vob")};

    return extensions.contains(file.suffix().toLower());
}

LibraryScanner::ParsedFilename LibraryScanner::parseMovieFilename(const QFileInfo &file)
{
    static const QRegularExpression yearExpression(
        QStringLiteral(R"((?:^|[\s._(\[])(19\d{2}|20\d{2})(?=$|[\s._)\]]))"));
    static const QRegularExpression separators(QStringLiteral(R"([._]+)"));

    QString stem = file.completeBaseName();
    int year = 0;

    QRegularExpressionMatchIterator matches = yearExpression.globalMatch(stem);
    while (matches.hasNext()) {
        const QRegularExpressionMatch match = matches.next();
        const int candidate = match.captured(1).toInt();
        if (!isPlausibleReleaseYear(candidate)) {
            continue;
        }
        year = candidate;
        stem.truncate(match.capturedStart(1));
        break;
    }

    stem.replace(separators, QStringLiteral(" "));
    stem = stem.simplified();

    // Removing the year leaves the bracket or dash that introduced it.
    while (stem.endsWith(QLatin1Char('(')) || stem.endsWith(QLatin1Char('['))
           || stem.endsWith(QLatin1Char('-'))) {
        stem.chop(1);
        stem = stem.trimmed();
    }

    if (stem.isEmpty()) {
        stem = file.completeBaseName();
    }

    return {.title = stem, .year = year};
}

bool LibraryScanner::parseEpisodeFilename(const QString &fileName, ParsedEpisode &episode)
{
    const QString name = stemOf(fileName);

    for (const QRegularExpression &expression : episodeExpressions()) {
        const QRegularExpressionMatch match = expression.match(name);
        if (!match.hasMatch()) {
            continue;
        }
        episode = ParsedEpisode{
            .showName = normalizedShowName(match.captured(1)),
            .seasonNumber = match.captured(2).toInt(),
            .episodeNumber = match.captured(3).toInt(),
            .episodeTitle = match.lastCapturedIndex() >= 4
                ? cleanEpisodeTitle(match.captured(4).trimmed())
                : QString()};
        return true;
    }

    return false;
}

bool LibraryScanner::parseEpisodeFromFolder(const QString &fileName,
                                            int seasonNumber,
                                            ParsedEpisode &episode)
{
    // FilenameParser.swift:49-51: `S01E02 Title` with the show implied.
    static const QRegularExpression prefixedExpression(
        QStringLiteral(R"(^[Ss](\d{1,2})[Ee](\d{1,4})(?:[.\s_-]+(.+))?$)"));
    // FilenameParser.swift:53-55: `Show 102 Title`, one season digit then two
    // episode digits.
    static const QRegularExpression bareExpression(
        QStringLiteral(R"(^(.+?)\s+(\d{1})(\d{2})(?:\s+(.+))?$)"));

    const QString name = stemOf(fileName);

    if (const QRegularExpressionMatch match = prefixedExpression.match(name); match.hasMatch()) {
        if (match.captured(1).toInt() != seasonNumber) {
            return false;
        }
        episode = ParsedEpisode{.showName = QString(),
                                .seasonNumber = seasonNumber,
                                .episodeNumber = match.captured(2).toInt(),
                                .episodeTitle = cleanEpisodeTitle(match.captured(3).trimmed())};
        return true;
    }

    if (const QRegularExpressionMatch match = bareExpression.match(name); match.hasMatch()) {
        if (match.captured(2).toInt() != seasonNumber) {
            return false;
        }
        episode = ParsedEpisode{.showName = normalizedShowName(match.captured(1)),
                                .seasonNumber = seasonNumber,
                                .episodeNumber = match.captured(3).toInt(),
                                .episodeTitle = cleanEpisodeTitle(match.captured(4).trimmed())};
        return true;
    }

    return false;
}

int LibraryScanner::seasonNumberFromPath(const QString &relativePath)
{
    const QStringList components = relativePath.split(QLatin1Char('/'), Qt::SkipEmptyParts);
    for (const QString &component : components) {
        const QRegularExpressionMatch match = seasonFolderExpression().match(component);
        if (match.hasMatch()) {
            return match.captured(1).toInt();
        }
    }
    return 0;
}

QString LibraryScanner::mediaIdFor(const QString &rootId, const QString &relativePath)
{
    QByteArray material = rootId.toUtf8();
    material.append('\0');
    material.append(relativePath.toUtf8());

    return QString::fromLatin1(
        QCryptographicHash::hash(material, QCryptographicHash::Sha256).toHex());
}

LibraryScanner::ScanResult LibraryScanner::scan(const LibraryRoot &root)
{
    const QFileInfo rootInfo(root.path);
    if (!rootInfo.isDir() || !rootInfo.isReadable()) {
        qCWarning(logScanner) << "library root is not readable:" << root.path;
        return {};
    }

    ScanResult result;
    result.outcome =
        collectInto(root.path, QDir(root.path), root, result.items, result.unreadableIds)
        ? ScanOutcome::Complete
        : ScanOutcome::Incomplete;

    // Directory order is whatever the filesystem hands back, so the projection's
    // stability starts by ordering the walk itself.
    std::sort(result.items.begin(),
              result.items.end(),
              [](const MediaItem &left, const MediaItem &right) {
                  return left.relativePath < right.relativePath;
              });

    qCInfo(logScanner) << "scanned" << root.path
                       << "media files:" << result.items.size();
    return result;
}
