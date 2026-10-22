#pragma once

#include <QByteArray>
#include <QString>
#include <QStringList>

/// TMDB artwork on disk (ImageCacheService.swift). Files live in the app's
/// cache directories and are named after the TMDB id, never after a path or a
/// name TMDB supplied.
namespace artwork_cache
{
enum class Kind { Poster, Backdrop, Still };

/// ImageCacheService.swift:20-21: thumbnails are 300 wide for posters and 800
/// wide for backdrops and stills.
[[nodiscard]] int thumbnailWidth(Kind kind);

/// `movie-603-poster`, `tv-1396-backdrop`, `tv-1396-s1e2-still`: a stem both
/// the full-size file and its thumbnail derive from. `ownerKind` is "movie" or
/// "tv". A TMDB movie id and a TMDB show id name different things, so the two
/// never share a file.
[[nodiscard]] QString stem(const QString &ownerKind, int tmdbId, Kind kind);
[[nodiscard]] QString episodeStillStem(int tmdbShowId, int season, int episode);

[[nodiscard]] QString fullFileName(const QString &stem);
[[nodiscard]] QString thumbnailFileName(const QString &stem);

/// A TMDB image path is `/` and a file name. Anything else is refused, so a
/// hostile or corrupt answer cannot change which URL is fetched.
[[nodiscard]] bool isSafeRemotePath(const QString &remotePath);

/// Whether `path` is `root` or lies under it, after resolving `.` and `..`.
/// The drives holding the library are mounted read-only and are never written
/// to; this is the check that keeps a misplaced cache from trying.
[[nodiscard]] bool isInsideAny(const QString &path, const QStringList &roots);

/// Decodes `bytes`, writes the full-size file under `fullDirectory` and a
/// thumbnail under `thumbnailDirectory`, and returns the thumbnail's file
/// name; an empty string when the bytes are not an image or a write failed.
/// Both files are written to a temporary name and renamed, so a crash never
/// leaves half an image that would count as cached.
[[nodiscard]] QString store(const QByteArray &bytes,
                            const QString &stem,
                            Kind kind,
                            const QString &fullDirectory,
                            const QString &thumbnailDirectory);
}
