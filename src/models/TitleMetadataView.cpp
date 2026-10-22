#include "models/TitleMetadataView.hpp"

#include "profiles/ContentPolicy.hpp"

namespace
{
[[nodiscard]] QUrl localUrl(const QString &path)
{
    return path.isEmpty() ? QUrl() : QUrl::fromLocalFile(path);
}
}

bool title_metadata_view::has(const MediaItem &item)
{
    return item.metadata != nullptr;
}

QString title_metadata_view::overview(const MediaItem &item)
{
    return item.metadata ? item.metadata->overview : QString();
}

QString title_metadata_view::director(const MediaItem &item)
{
    return item.metadata ? item.metadata->director : QString();
}

QString title_metadata_view::certification(const MediaItem &item)
{
    return item.metadata ? item.metadata->certification : QString();
}

QString title_metadata_view::releaseDate(const MediaItem &item)
{
    return item.metadata ? item.metadata->releaseDate : QString();
}

QString title_metadata_view::collectionName(const MediaItem &item)
{
    return item.metadata ? item.metadata->collectionName : QString();
}

QVariant title_metadata_view::tmdbId(const MediaItem &item)
{
    return item.metadata ? QVariant(item.metadata->tmdbId) : QVariant();
}

QVariant title_metadata_view::voteAverage(const MediaItem &item)
{
    return item.metadata && item.metadata->voteAverage ? QVariant(*item.metadata->voteAverage)
                                                       : QVariant();
}

QVariant title_metadata_view::voteCount(const MediaItem &item)
{
    return item.metadata && item.metadata->voteCount ? QVariant(*item.metadata->voteCount)
                                                     : QVariant();
}

QVariant title_metadata_view::popularity(const MediaItem &item)
{
    return item.metadata && item.metadata->popularity ? QVariant(*item.metadata->popularity)
                                                      : QVariant();
}

QVariant title_metadata_view::collectionId(const MediaItem &item)
{
    return item.metadata && item.metadata->collectionId ? QVariant(*item.metadata->collectionId)
                                                        : QVariant();
}

QVariant title_metadata_view::runtimeMinutes(const MediaItem &item)
{
    return item.metadata && item.metadata->runtimeMinutes > 0
        ? QVariant(item.metadata->runtimeMinutes)
        : QVariant();
}

QStringList title_metadata_view::genres(const MediaItem &item)
{
    return content_policy::displayGenresOf(item);
}

QVariantList title_metadata_view::cast(const MediaItem &item)
{
    QVariantList list;
    if (!item.metadata) {
        return list;
    }
    for (const CastMember &member : item.metadata->cast) {
        list.push_back(QVariantMap{{QStringLiteral("name"), member.name},
                                   {QStringLiteral("character"), member.character},
                                   {QStringLiteral("profilePath"), member.profilePath},
                                   {QStringLiteral("personId"), member.personId}});
    }
    return list;
}

QStringList title_metadata_view::keywords(const MediaItem &item)
{
    QStringList names;
    if (item.metadata) {
        for (const MetadataKeyword &keyword : item.metadata->keywords) {
            names.push_back(keyword.name);
        }
    }
    return names;
}

QUrl title_metadata_view::backdropUrl(const MediaItem &item)
{
    return localUrl(item.displayBackdropPath());
}

QVariantMap title_metadata_view::toMap(const MediaItem &item)
{
    return {{QStringLiteral("hasMetadata"), has(item)},
            {QStringLiteral("tmdbId"), tmdbId(item)},
            {QStringLiteral("overview"), overview(item)},
            {QStringLiteral("director"), director(item)},
            {QStringLiteral("certification"), certification(item)},
            {QStringLiteral("releaseDate"), releaseDate(item)},
            {QStringLiteral("voteAverage"), voteAverage(item)},
            {QStringLiteral("voteCount"), voteCount(item)},
            {QStringLiteral("popularity"), popularity(item)},
            {QStringLiteral("collectionId"), collectionId(item)},
            {QStringLiteral("collectionName"), collectionName(item)},
            {QStringLiteral("runtimeMinutes"), runtimeMinutes(item)},
            {QStringLiteral("genres"), genres(item)},
            {QStringLiteral("cast"), cast(item)},
            {QStringLiteral("keywords"), keywords(item)},
            {QStringLiteral("backdropUrl"), backdropUrl(item)}};
}
