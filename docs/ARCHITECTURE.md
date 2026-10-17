---
summary: Architecture and runtime boundaries of the frozen Swift v2.0.1 macOS app, kept as the behavior oracle for v3.
read_when:
  - Checking how the released Swift app composes state, catalog data, focus, artwork, or playback before matching it in v3.
  - Reading the released implementation as a reference; it is not built, tested, or changed.
---

# Architecture

This document describes the released Swift v2.0.1 system. That code stays in
`Marquee/` as a frozen, read-only reference: no fixes, builds, tests, or Mac
gates. The product is Marquee v3; its architecture is in
`ARCHITECTURE_V3.md`. Statements below describe the reference, not rules for new
work.

## System context

Marquee is a single native macOS application for browsing and playing a private
local media library. It targets macOS 12 and Xcode 14.2 on the Intel theater
Mac. The app is offline-first: the catalog, browse surfaces, artwork choices,
profiles, and playback must continue to work without an online provider.

The Xcode project currently has one application target. Deterministic tests are
DEBUG launch-argument harnesses compiled into that target rather than a
separate XCTest bundle.

## Composition and state

`MarqueeApp.swift` is the composition root. `AppState` constructs the domain
owners below, relays their `objectWillChange`, and keeps only its own policy:
playback entry points, profile selection and exit sequencing, scan lifecycle
triggers, and error presentation. It no longer forwards library state — no view
reads browse, show, or episode data through it. Durable ownership is split by
domain:

- `LibraryState` owns catalog projection, scanning, browse snapshots, and
  library-derived rows.
- `ProfileSession` owns the active profile and profile-picker transition.
- `PlaybackSession` owns the player controller and playback handoff.
- `AppRouter` owns root/sidebar routes while a few feature-local selections
  remain local to their v2 features.
- `UserSettings`, `ProfileStore`, `ArtworkCache`, and a small number of legacy
  services remain process-wide in v2.

`AppState` is not a place to park new unrelated state. A view that needs library
data observes `LibraryState` directly; the released code keeps those ownership
boundaries.

## Catalog and library data flow

`SQLiteCatalogStore` is an actor-backed implementation of `CatalogStore` using
the system sqlite3 library. `CatalogSchema.currentVersion` is 4. Migrations are
forward-only; versions 3 and 4 update `PRAGMA user_version` atomically with
their schema changes. The store serializes writes while allowing reads outside
an active write transaction.

Media identity is derived from the mounted volume identity and path relative to
the volume mount. Typed IDs keep catalog entities distinct. `VolumeRegistry`
resolves mounted roots, and `DiffScanner` performs a bounded, resumable walk,
diff, and transactional apply without holding a transaction during filesystem
I/O. Scan requests are coalesced before work begins.

The runtime path is:

```text
mounted library -> DiffScanner -> CatalogStore -> CatalogProjection
                                           |-> BrowseSnapshot/search/taste rows
                                           |-> optional TMDB enrichment
```

The legacy JSON importer is a migration input only. Runtime reads should come
from catalog projections. TMDB enrichment is optional and writes through the
catalog; it must never become a prerequisite for browsing.

## Artwork, browse, and discovery

Local sidecar artwork is authoritative. Online artwork may fill gaps, but it
must not replace a valid local selection simply because the network is
available. `ArtworkCache` and `CachedImageView` own decode and cache behavior;
feature views should request the appropriate poster or backdrop size rather
than create a second image pipeline.

`BrowseSnapshot` is the read model for home, search, similarity, profile
filtering, and taste-driven rows. Snapshot construction stays outside view
bodies; v2 feature consumers use that shared read model.

## Navigation and remote input

`AppRouter` is the root/sidebar navigation authority. Every remote surface with
directional traversal — Home, the browse grids, movie and show detail, search
results, the profile picker, and the player HUD — resolves focus through the
shared `FocusEngine`, backed by specialized placement policies, geometry
observers, and AppKit scroll coordinators. Wrap and back-at-root remain
surface-local edge policy: the engine reports a `.boundaryHit` and the view
decides. Geometry supplied to scrolling must be finite and clamped.

Native programmatic scroll animation stays disabled on macOS 12
(`RemoteProgrammaticScrollPolicy`). Motion instead comes from
`RemoteAppKitScrollMotion.springScroll`, which interpolates the clip view
directly on the main run loop toward a target the placement authority has
already clamped, and falls back to immediate placement under Reduce Motion. The
frozen placement formulas stay the source of truth — the spring changes how a
row travels, never where it lands. Do not add animated correction loops,
timer-settled focus restoration, or a second owner for the same scroll
position. A surface return may restore a logical focus target and request at
most the measured placement correction defined by the shared policy.

## Playback

`MPVPlayerService` is a multi-backend facade with one active backend per load:

- ordinary MP4, M4V, and MOV files use direct AVFoundation;
- HEVC-tagged (`hvc1`/`hev1`) AV containers use the embedded ffmpeg bridge;
- MKV, WebM, AVI, MPEG transport/program streams, VOB, and similar containers
  use the embedded ffmpeg bridge by default;
- external ffplay, prepared AVFoundation/remux, prepared transcode, and direct
  in-process mpv routes are diagnostic opt-ins controlled by environment
  flags.

The service owns backend selection, lifecycle state, tracks, subtitles,
seeking, cache paths, and helper processes. Sidecar subtitles remain available
on the embedded route. A missing or failed helper produces a controlled player
error. The app discovers system-installed ffmpeg/ffprobe rather than bundling
them. All stop, failure, and parent-death paths must terminate children. The
exact safety decision is recorded in `ARCHITECTURE_DECISIONS.md`.

## Local resources and boundaries

`Vendor/MPVKit-local/` is a gitignored dependency built locally from source.
`MarqueePatches/` holds the compatibility-shim source, not generated
frameworks. Secrets and the live media sidecar stay outside Git. Test and tour
processes receive an isolated `MARQUEE_SIDECAR_ROOT` under `build/tmp` so
automated work cannot mutate the real library.

The decisions behind these boundaries are recorded in
`ARCHITECTURE_DECISIONS.md`. The v3 boundaries are in `ARCHITECTURE_V3.md`.
