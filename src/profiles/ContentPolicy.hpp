#pragma once

#include <QString>
#include <QStringList>
#include <QVector>

#include "catalog/MediaItem.hpp"

/// What a profile's maturity level lets it see. The single rule every
/// projection and every play request asks, so a title is classified the same
/// way on Home, Movies, TV Shows, search, details, and direct playback.
///
/// The rule is the released one: `Marquee/Models/MaturityLevel.swift:33-83`
/// classifies a title from its certification and its genres, and
/// `Marquee/Models/UserProfile.swift:70-79` admits an item when its level is
/// at or below the profile's (a Kids profile admits Kids and Family). The v3
/// catalog holds no certification, so classification runs on the genres alone:
/// the folder genre under the library root, then the genres inferred from the
/// title (`CatalogContentPolicy.swift:322-398`). A title with no genre at all
/// classifies as Adult, which keeps unclassified content away from Kids
/// profiles.
namespace content_policy
{
/// Trimmed, de-duplicated (case-insensitively) genres in first-seen order.
QStringList uniqueGenres(const QStringList &genres);

/// CatalogContentPolicy.swift:374-398: the genres a show is known to have
/// when no online metadata names them.
QStringList offlineTvGenres(const QString &showTitle);

/// CatalogContentPolicy.swift:339-372: the genres a movie title implies.
QStringList offlineMovieGenres(const QString &movieTitle);

/// CatalogContentPolicy.swift:305-320: the first folder under the root names
/// a genre when it is one of the known names. Empty otherwise.
QString folderGenreOf(const MediaItem &item);

/// MediaItem.displayGenres without online metadata: the folder genre first,
/// then the title-inferred ones.
QStringList genresOf(const MediaItem &item);

/// MediaItem.swift:154-171 `displayGenres`: TMDB's genres when it named any,
/// followed by the local ones only when TMDB's are all generic family labels;
/// otherwise the local genres. Rows still key on `genresOf` until the Rows
/// task moves them.
QStringList displayGenresOf(const MediaItem &item);

/// MaturityLevel.classify without a certification, as a ProfileStore::Maturity
/// value: 0 Kids, 1 Family, 2 Teen, 3 Adult.
int maturityOf(const MediaItem &item);

/// UserProfile.allows(item:) for a profile of `profileMaturity`.
bool allows(int profileMaturity, const MediaItem &item);

/// The items `profileMaturity` may see, in their original order.
QVector<MediaItem> filtered(int profileMaturity, const QVector<MediaItem> &items);
}
