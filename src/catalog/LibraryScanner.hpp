#pragma once

#include <QFileInfo>
#include <QString>
#include <QVector>

#include "catalog/LibraryRoot.hpp"
#include "catalog/MediaItem.hpp"

/// Read-only filesystem walk over one configured library root. Nothing here
/// opens the catalog: a scan completes before the apply transaction starts, so
/// the catalog is never write-locked while a mount is being read.
namespace LibraryScanner
{
struct ParsedFilename
{
    QString title;
    int year{0};
};

/// FilenameParser.swift:82-90: what a filename says about the episode it
/// holds. `showName` is empty when the name led with the episode code and the
/// show is implied by the folder above it.
struct ParsedEpisode
{
    QString showName;
    int seasonNumber{0};
    int episodeNumber{0};
    QString episodeTitle;
};

enum class ScanOutcome {
    /// The root is missing, unreadable, or not a directory.
    RootUnavailable,
    /// Part of the root could not be enumerated, so the walk is not evidence of
    /// what the root no longer holds.
    Incomplete,
    /// Every directory under the root was enumerated.
    Complete
};

struct ScanResult
{
    ScanOutcome outcome{ScanOutcome::RootUnavailable};
    QVector<MediaItem> items;
};

[[nodiscard]] bool isSupportedMediaFile(const QFileInfo &file);

/// Splits a movie filename into its title and release year. A plausible
/// four-digit year ends the title region, so release tags trailing it are
/// dropped instead of being folded into the title.
[[nodiscard]] ParsedFilename parseMovieFilename(const QFileInfo &file);

/// FilenameParser.swift:129-168: reads the show, season, episode, and title
/// out of a self-describing episode name (`Show - S01E02 - Title`, `Show
/// 1x02`, ...). Returns false when the name carries no episode code.
[[nodiscard]] bool parseEpisodeFilename(const QString &fileName, ParsedEpisode &episode);

/// FilenameParser.swift:171-228: the two shapes that only make sense inside a
/// `Season N` folder, `S01E02 Title` and `Show 102 Title`; the season in the
/// name must agree with the folder's.
[[nodiscard]] bool parseEpisodeFromFolder(const QString &fileName,
                                          int seasonNumber,
                                          ParsedEpisode &episode);

/// CatalogContentPolicy.swift:222-232: the number of the first `Season N`
/// component in `relativePath`, or zero when none is present.
[[nodiscard]] int seasonNumberFromPath(const QString &relativePath);

/// Derives an item's catalog identity from its root and relative path so the
/// same file keeps its row, and its future watch state, across rescans.
[[nodiscard]] QString mediaIdFor(const QString &rootId, const QString &relativePath);

/// Walks `root` and returns its media files ordered by relative path, each
/// carrying the local sidecar poster found beside it. A TV root yields
/// episodes (CatalogProjection.swift:411-531): a file inside a `Season N`
/// folder whose name parses as an episode, carrying the show folder's and
/// season folder's artwork; other files in a season folder are skipped, and
/// files outside any season folder are kept as movies the way the released
/// projection keeps them. Symlinks are never followed, so everything reported
/// lies inside the configured root. Only a `Complete` outcome states what the
/// root holds; the other two mean the catalog must preserve what it already
/// stored for this root.
[[nodiscard]] ScanResult scan(const LibraryRoot &root);
}
