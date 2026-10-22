#pragma once

#include <QStringList>
#include <QUrl>
#include <QVariant>
#include <QVariantList>
#include <QVariantMap>

#include "catalog/MediaItem.hpp"

/// What QML may read of a title's TMDB metadata, in one place so every model
/// names a field the same way. Missing values are an empty string, an empty
/// list, or an invalid variant (`null` in QML) for the numbers, which is the
/// released `nil` the browse rules branch on: a title with a rating of zero is
/// different from a title with none.
namespace title_metadata_view
{
/// True when TMDB matched the title.
[[nodiscard]] bool has(const MediaItem &item);

[[nodiscard]] QString overview(const MediaItem &item);
[[nodiscard]] QString director(const MediaItem &item);
[[nodiscard]] QString certification(const MediaItem &item);
[[nodiscard]] QString releaseDate(const MediaItem &item);
[[nodiscard]] QString collectionName(const MediaItem &item);
[[nodiscard]] QVariant tmdbId(const MediaItem &item);
[[nodiscard]] QVariant voteAverage(const MediaItem &item);
[[nodiscard]] QVariant voteCount(const MediaItem &item);
[[nodiscard]] QVariant popularity(const MediaItem &item);
[[nodiscard]] QVariant collectionId(const MediaItem &item);
/// Minutes, or an invalid variant when TMDB gave none.
[[nodiscard]] QVariant runtimeMinutes(const MediaItem &item);
/// `MediaItem.displayGenres`.
[[nodiscard]] QStringList genres(const MediaItem &item);
/// Each entry `{name, character, profilePath, personId}`, in billing order.
[[nodiscard]] QVariantList cast(const MediaItem &item);
[[nodiscard]] QStringList keywords(const MediaItem &item);
/// The cached TMDB backdrop, or empty when there is none or a local one wins.
[[nodiscard]] QUrl backdropUrl(const MediaItem &item);

/// Every field above under its own key, for a surface that wants them as one
/// value.
[[nodiscard]] QVariantMap toMap(const MediaItem &item);
}
