//
//  EnrichmentProtocols.swift
//  Marquee
//
//  Protocol seams for deterministic enrichment coverage.
//
//  Two narrow protocols that mirror the methods `TMDBEnrichmentService`
//  needs from `TMDBService` and `ImageCacheService`. They exist purely
//  as a testing seam: production callers continue to use the singletons
//  unchanged via extension-only conformance, and the harness drives the
//  actor through deterministic fakes that conform to the same shapes.
//
//  See docs/ARCHITECTURE.md §"Catalog and library data flow".
//
//  The thumbnail-repair contract is documented on
//  `ArtworkDownloading.downloadAndCacheImages` and implemented by the
//  production `ImageCacheService` conformance.
//

import Foundation

// MARK: - TMDBMetadataFetching

/// What the enrichment actor needs from TMDB. Mirrors the existing
/// public methods on `TMDBService` one-for-one — no new behavior, just
/// a seam for testing.
protocol TMDBMetadataFetching: Sendable {
    func fetchMovieDetails(title: String, year: Int?) async -> TMDBMetadata?
    func fetchMovieDetails(tmdbID: Int) async -> TMDBMetadata?
    func fetchTVDetails(title: String, year: Int?) async -> TMDBMetadata?
    func fetchSeasonEpisodes(
        tvID: Int,
        seasonNumber: Int
    ) async -> [TMDBService.EpisodeInfo]
}

// MARK: - ArtworkDownloading

/// What the enrichment actor needs from the image cache. The download
/// method is fire-and-forget (matches the existing
/// `ImageCacheService.downloadAndCacheImages` surface — returns Void,
/// logs on failure), so the actor *must* read back via the cached-path
/// lookups to learn which images actually landed locally. Those lookups
/// are the source of `local_path` written into `artwork_asset` rows.
///
/// **Cache contract (`local_path` semantics)** — the value written into
/// `artwork_asset.local_path` is the *thumbnail* path. `local_path != nil`
/// means the thumbnail file exists on disk. Full-size cached files are
/// an internal implementation detail of `ImageCacheService` and are not
/// tracked by `artwork_asset` in 2E.4b.
///
/// **Thumbnail-missing repair contract** — a conforming
/// `downloadAndCacheImages` implementation MUST schedule a fresh
/// download whenever the corresponding *thumbnail* is missing, even if
/// the full-size cached file is present. Without this rule the actor's
/// retry path can get stuck: full-size present + thumb missing
/// (post-crash, user deletion, thumb-generation failure) means the
/// completeness predicate keeps reporting incomplete and
/// `forceRedownload: false` keeps skipping the work.
///
/// The production `ImageCacheService.downloadAndCacheImages` enforces
/// this contract by scheduling work when either the full-size file or
/// its thumbnail is missing. This protocol declaration keeps that repair
/// behavior explicit for alternate implementations and tests.
protocol ArtworkDownloading: Sendable {
    func downloadAndCacheImages(
        tmdbID: Int,
        posterPath: String?,
        backdropPath: String?,
        forceRedownload: Bool
    ) async
    func cachedPosterPath(tmdbID: Int) -> String?
    func cachedBackdropPath(tmdbID: Int) -> String?
    func cachedThumbPosterPath(tmdbID: Int) -> String?
    func cachedThumbBackdropPath(tmdbID: Int) -> String?
    func downloadEpisodeStill(
        tmdbID: Int,
        seasonNumber: Int,
        episodeNumber: Int,
        stillPath: String
    ) async -> String?
}

// MARK: - Production conformances (extension-only)
//
// Both singletons satisfy the shape of the protocols today. The actor
// `TMDBService` is `Sendable` by virtue of being an actor; the final
// class `ImageCacheService` is reference-typed but its mutable state is
// limited to immutable `let` fields after `init` (the directory URLs,
// the `URLSession`) so an `@unchecked Sendable` declaration on the
// conformance is sound — every method either reads `let` fields or
// dispatches into URLSession.
//
// `ImageCacheService.downloadAndCacheImages` has a default-valued
// `forceRedownload` parameter; the protocol method is non-defaulted so
// the conformance binds to the same underlying method via overload
// resolution. No body is required here.

extension TMDBService: TMDBMetadataFetching {}

extension ImageCacheService: @unchecked Sendable, ArtworkDownloading {

    // The protocol method is non-defaulted; the existing
    // `downloadAndCacheImages(tmdbID:posterPath:backdropPath:forceRedownload:)`
    // already satisfies it via overload resolution because the default
    // value on the parameter does not change the function signature.
    // Listed here as documentation: there is no body to write.
}
