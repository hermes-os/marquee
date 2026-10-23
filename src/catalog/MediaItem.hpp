#pragma once

#include <QDateTime>
#include <QMetaType>
#include <QString>

#include <memory>
#include <optional>

#include "catalog/TitleMetadata.hpp"

/// One playable library entry. The catalog projects these as plain values so a
/// projection can cross the catalog worker's thread boundary by copy.
///
/// Marquee/Models/MediaItem.swift:8-49 keeps movies and episodes in one type:
/// an episode is the entry whose `showName` is set, and the show it belongs to
/// is the group of entries sharing that name.
struct MediaItem
{
    QString id;
    QString libraryRootId;
    QString relativePath;
    QString absolutePath;
    QString title;
    QString sortTitle;
    /// `movie` or `episode` (MediaItem.swift:238-239 derives the same split
    /// from `showName`; the catalog stores it so a projection never has to
    /// re-parse a path to know what a row is).
    QString mediaKind;
    int year{0};
    // Optional media duration in whole seconds. CatalogStore projects the
    // player's recorded watch_progress duration; zero means it is unknown.
    qint64 durationSeconds{0};
    // Local sidecar artwork, empty when the title has none. The pair mirrors the
    // media paths because only relative paths are stored.
    QString posterRelativePath;
    QString posterAbsolutePath;
    // A movie's own backdrop sidecar (`<name>-backdrop.jpg`, `fanart.jpg`),
    // which the Home hero draws full-bleed. Empty when there is none; episodes
    // use the show-level backdrop below.
    // Initialized in place so a projection built field by field elsewhere
    // (tests, fixtures) need not name them.
    QString backdropRelativePath{};
    QString backdropAbsolutePath{};
    qint64 fileSize{0};
    QDateTime modifiedAt;
    // Where playing this title should start. Zero means from the beginning,
    // which is also where a title watched to the end starts again.
    qint64 resumePositionMs{0};
    // MediaItem.swift:50, :228-229: a title played to its end is watched, and
    // a title with a position that is not watched is in progress.
    bool watched{false};

    // Episode facts (MediaItem.swift:27-30). Zero season and episode numbers
    // mean the entry is a movie; `showName` is the grouping key
    // (CatalogProjection.swift:436-442 resolves it from the show folder).
    QString showName;
    int seasonNumber{0};
    int episodeNumber{0};
    QString episodeTitle;
    // Show-level artwork (MediaItem.swift:36-39): the show folder's poster and
    // backdrop sidecars, then the season folder's, stored relative to the root
    // like the title's own artwork.
    QString showPosterRelativePath;
    QString showPosterAbsolutePath;
    QString showBackdropRelativePath;
    QString showBackdropAbsolutePath;
    QString seasonPosterRelativePath;
    QString seasonPosterAbsolutePath;
    // MediaItem.swift:43: a still named after the episode file, which the
    // episode row prefers over any folder-level art.
    QString episodeStillRelativePath;
    QString episodeStillAbsolutePath;

    // When the active profile last recorded progress on this title, or an
    // invalid time when it never did (MediaItem.swift:51 `lastPlayedDate`).
    // Home orders Continue Watching and Recently Watched by it.
    QDateTime lastPlayedAt{};

    // What TMDB said about the title (MediaItem.swift's `metadata`), or null
    // while the title has none: online metadata is off, no key exists, TMDB
    // has not been asked yet, or it found no match. An episode carries its
    // show's metadata, as CatalogProjection.makeShowMetadata does; the
    // episodes of one show share the one value.
    std::shared_ptr<const TitleMetadata> metadata{};
    // TMDB artwork cached under the app's cache directory, empty when there is
    // none. A local sidecar above always wins; these only fill its absence
    // (MediaItem.swift:195-218 `thumbPosterPath`, `thumbBackdropPath`).
    QString tmdbPosterAbsolutePath{};
    QString tmdbBackdropAbsolutePath{};
    // The episode's own TMDB facts (CatalogEpisode): its title when the file
    // name gave none, summary, air date, rating and cached still.
    QString tmdbEpisodeTitle{};
    QString episodeOverview{};
    QString episodeAirDate{};
    std::optional<double> episodeVoteAverage{};
    QString tmdbEpisodeStillAbsolutePath{};

    [[nodiscard]] bool isEpisode() const { return !showName.isEmpty(); }
    [[nodiscard]] bool isMovie() const { return showName.isEmpty(); }

    // MediaItem.swift:241-244: the `S1 E4` label every TV surface shares.
    [[nodiscard]] QString episodeLabel() const
    {
        if (!isEpisode()) {
            return {};
        }
        return QStringLiteral("S%1 E%2").arg(seasonNumber).arg(episodeNumber);
    }

    // MediaItem.swift:246-248. TMDB's title for the episode is `tmdbEpisodeTitle`;
    // the label stays the file's own until the Details task chooses to use it.
    [[nodiscard]] QString displayEpisodeTitle() const
    {
        return episodeTitle.isEmpty() ? QStringLiteral("Episode %1").arg(episodeNumber)
                                      : episodeTitle;
    }

    // MediaItem.swift:195-199, :270-272: the poster a show card shows; the
    // show folder wins, then the season folder, and the cached TMDB poster only
    // when the folders have none.
    [[nodiscard]] QString gridShowPosterPath() const
    {
        if (!showPosterAbsolutePath.isEmpty()) {
            return showPosterAbsolutePath;
        }
        return seasonPosterAbsolutePath.isEmpty() ? tmdbPosterAbsolutePath
                                                  : seasonPosterAbsolutePath;
    }

    // MediaItem.swift:195-218: the poster this title draws. A local sidecar
    // always wins (the show folder's, then the season folder's, then the
    // file's own, for an episode); the cached TMDB image only fills its
    // absence.
    [[nodiscard]] QString displayPosterPath() const
    {
        if (isEpisode()) {
            const QString local = !showPosterAbsolutePath.isEmpty() ? showPosterAbsolutePath
                : !seasonPosterAbsolutePath.isEmpty()              ? seasonPosterAbsolutePath
                                                                   : posterAbsolutePath;
            return local.isEmpty() ? tmdbPosterAbsolutePath : local;
        }
        return posterAbsolutePath.isEmpty() ? tmdbPosterAbsolutePath : posterAbsolutePath;
    }

    // MediaItem.swift:202-208: the backdrop, the show folder's sidecar first
    // for an episode, then the title's own sidecar (`<name>-backdrop.jpg`,
    // `fanart.jpg`); the cached TMDB image only fills their absence. v3 holds
    // no season backdrop.
    [[nodiscard]] QString displayBackdropPath() const
    {
        if (isEpisode() && !showBackdropAbsolutePath.isEmpty()) {
            return showBackdropAbsolutePath;
        }
        return backdropAbsolutePath.isEmpty() ? tmdbBackdropAbsolutePath : backdropAbsolutePath;
    }

    // MediaItem.swift:143-151: the duration cut to whole minutes before the
    // hour or the minute form is chosen ("1h 52m", "47m"); empty while the
    // length is unknown.
    [[nodiscard]] QString displayRuntime() const
    {
        if (durationSeconds <= 0) {
            return {};
        }
        const qint64 totalMinutes = durationSeconds / 60;
        return totalMinutes >= 60 ? QStringLiteral("%1h %2m").arg(totalMinutes / 60).arg(totalMinutes % 60)
                                  : QStringLiteral("%1m").arg(totalMinutes);
    }

    // MediaItem.swift:228-229.
    [[nodiscard]] bool hasProgress() const { return resumePositionMs > 0 && !watched; }
};
Q_DECLARE_METATYPE(MediaItem)
