---
summary: Marquee v3 design - the C++23/Qt 6/QML/libmpv/SQLite architecture, product contract, boundaries, and acceptance bar for the Omarchy build.
read_when:
  - Designing or reviewing Marquee v3 code, boundaries, catalog schema, playback, or packaging.
  - Checking the v3 product contract (offline-first, profile rules, storage sources, Nostalgia TV, Pi) before changing it.
---

# Marquee v3 architecture

### C++23 + Qt 6/QML + libmpv + SQLite on Omarchy/Arch

This document is the design for Marquee v3, the native Linux home-theater
application for **Omarchy/Arch Linux**. It records decisions, boundaries, and
the acceptance bar. It is not a work log: what is built is in the source tree
and `git log`, and open work is in `issues.md`.

The code samples are a foundation, not a drop-in application. Where the source
tree differs from a sample, the source tree wins.

## Implementation notes

Differences between the shipped code and the starter examples below, each with
the reason. Read these before copying an example.

- The QML module and every non-`main.cpp` source live in a static
  `marquee_core` library so the app and every test link the shipped module
  instead of recompiling source lists. Sections 7 and 34 show the older
  executable-module shape. The module's tooling output directory stays out of
  the app binary's directory because a disk `qmldir` beside the executable
  conflicts with the statically linked type registration.
- Window-attached `Keys` handlers never receive events. Back-key handling must
  live on an item inside the scene's key-bubble chain. QML behavior tests must
  load the shipped module, never inline replica scenes.
- The render item is `MpvVideoItem` in the single `Marquee` module (not
  `MpvVideo` in a separate `Marquee.Playback` module, section 26). It is not
  `final` because Qt derives a wrapper from every QML-creatable type.
  `seekAbsolute` replaces the ambiguous `seek` in section 25.
- The catalog migration list lives inside `CatalogDatabase.cpp` rather than the
  separate `migrations/` files of section 6. Migration 1 creates
  `library_roots`, `media_items`, and the section-14 indexes. Migration 2
  rebuilds both tables so their identity columns are `NOT NULL` (SQLite leaves
  a `TEXT PRIMARY KEY` nullable); it preserves rows and fails the transaction
  rather than dropping a row whose identity is null. Migration 3 creates
  `watch_progress` without section 14's `profile_id`, because keying rows on a
  profile the application cannot yet name would invent an identity that the
  profiles feature then has to reconcile. Migration 4 adds the show, season,
  episode, and episode-artwork columns to `media_items`.
  Migration 5 rebuilds `watch_progress` keyed on `(profile_id, media_id)` and
  copies every row stored before it to each profile that exists when the
  catalog is upgraded (the profile ids come from `profiles.json`, which is
  where profiles live; there is no `profiles` table, so `profile_id` has no
  foreign key and deleting a profile removes its rows explicitly). When no
  profile is known it renames the stored table to `watch_progress_v4_unowned`
  (nothing is deleted, and nothing reads it) and creates the new table empty,
  rather than refusing and blocking the library. A profile created later
  starts with no progress, and clearing watch history clears the active
  profile only, as `WatchProgressStore.swift` does.
- `AppPaths` appends `config`, `data`, and `cache` to Qt's per-application XDG
  location (organization `HermesOS`, application `Marquee`), so the tree under
  section 9 gains those segments. Profiles are one `profiles.json` beside the
  catalog, not a `profiles/` directory, and the cache holds `artwork/` and
  `thumbnails/`. Tests redirect the whole tree with `AppPaths::setRuntimeRoot`.
- Startup opens the catalog only to migrate it, then closes it: a `QSqlDatabase`
  belongs to the thread that opened it, and the catalog worker owns the
  connection it queries. The worker's slot is a single `refresh(rootPaths)`
  rather than section 16's `initialize()`/`scanRoots()` pair, because startup
  has already migrated the catalog.
- `qRegisterMetaType<QVector<MediaItem>>` is not needed on Qt 6.
- `MediaItem` carries poster, backdrop, and episode artwork paths and the
  optional duration projected from recorded watch progress. `LibraryModel`
  exposes section 17's roles plus the card metadata. The placeholder lives in
  `PosterCard`/`PosterArt`, not in a `MediaItem::posterUrl()` helper: an empty
  role means the title has no local artwork, and the owning card can fall back
  again when a sidecar cannot be decoded.
- Surfaces activate a title by media identity, never by row, so a projection
  replaced under a grid cannot open the wrong file. Section 18's
  `showDetails(int index)` is `showMediaDetails(const QString &mediaId)` for the
  same reason; the details facts come from one `LibraryModel::detailsForId`
  lookup rather than a second model or a details controller.
- Activation is deferred with `Qt.callLater`: opening the player replaces the
  browse screen and every delegate in it, and running that teardown inside the
  pointer or key delivery still unwinding through the tapped card returns into
  freed memory.
- Home is a stack of titled rows composed in C++ (`HomeRowsModel`), not a grid:
  Continue Watching, Recently Watched, Play Something, the taste rows (Because
  You Watched, Hidden Gems, Short Tonight), the seasonal rows (October Horror,
  Summer Blockbusters), Recently Added, Holiday Movies, a row per decade, All
  Movies, at most eight cards each. The rules are plain functions in
  `home_rows` over projected items, which carry the active profile's progress
  and when it was recorded; the Kids policy is applied before they see the
  library. `HomeScreen.qml` handles every arrow key itself through the model's
  `FocusNavigator`, because a view's built-in traversal would swallow the
  first-column Left that has to reach the sidebar. Horizontal movement stays
  inside its row, Up on the first row reaches the Play Something capsule, and
  the page scrolls to the focused row over `Theme.motionNormal` (immediately
  under Reduce Motion). An
  episode card opens its show with `ShowsModel::requestEpisodeFocus`, which the
  show page spends once. The taste, seasonal and Play Something rows are plain
  functions in `HomeTasteRows.*`, `TasteModel.*`, `SimilarityIndex.*` and
  `SeasonalRows.*`; `compose` only places them. They rank the library against
  the profile's history, so `HomeRowsModel` builds them once per set of items
  and calendar day and again only when a title becomes watched, a movie's length
  becomes known, or the projection is replaced, never for the progress record
  playback writes every ten seconds. What the titles and their metadata alone
  decide (the holiday scores and row, the decade rows, the similarity index) is
  built by `LibraryRows` (`HomeLibraryRows.*`) when the items are replaced and
  kept until they are replaced again. The Play Something capsule
  in the title bar is the first stop of the remote's vertical order
  (`HomeRowsModel::moveUp`/`moveDown`), and `play_something::pick` is the one
  rule behind the capsule, the sidebar control, and the row: unwatched movies in
  a salted weighted shuffle, never an episode.
- Only relative paths are stored; a projection composes absolute paths from its
  root, so a row never records where its root currently is. Root identity is
  keyed on the configured path, and a path the catalog has not seen is always a
  new library. A move is never inferred: settings hold bare paths, so the only
  signal would be the old root being absent from disk, which is the ordinary
  unplugged case, and inferring a move from it would hand one library's rows
  and watch state to an unrelated directory.
- The filename parser truncates the title at the first plausible release year
  instead of removing the year in place (dropping trailing release tags such as
  the `1080p` section 34 left in its example), and rejects a four-digit token
  beyond next year so `Blade Runner 2049.2017` keeps its title.
- Media under a hidden path segment is skipped, because trash and sync
  directories inside a root hold ordinary-looking files.
- The scan walk is an explicit recursion rather than section 16's
  `QDirIterator`, which silently skips a directory it cannot open. A subtree
  that cannot be enumerated makes the whole walk incomplete, and only a complete
  walk may add or remove rows, so a permission change can never be read as
  deletion. Symlinks are excluded from the walk, so a link inside a root cannot
  pull a file from outside it into the library.
- Artwork is matched against the directory listing the walk already holds
  rather than section 29's `QFileInfo::exists` probes, so a symlinked or hidden
  sidecar is excluded by the same rule that excludes symlinked and hidden media.
- The details surface shows only what the catalog holds. A poster-less or
  metadata-less title renders exactly as the released app does when that input
  is empty (no backdrop, no overview section, no director line).
- A title watched to the end stores a zero position rather than its final one,
  so every surface reads the resume point from one column instead of deriving it
  from a completion flag; the row still records the duration and the
  completion. The closing-credits half of section 28's completion rule applies
  only to files longer than those credits, otherwise every glance at a short
  file would count as having watched it. Progress is recorded every ten seconds
  of playback, on pause, when another title replaces the session, when the
  viewer leaves the player, and when the application quits with the player open.
  The post-seek save point of section 28 is not made: the render item does not
  report when a seek commits, and the ten-second cadence bounds what a seek can
  lose.
- Playing a title resumes it. Start-from-beginning is the details surface's
  explicit action and the player HUD's Restart control. Restart seeks the open
  file rather than reloading it, and records the title at position zero rather
  than deleting its row, so zero stays what every surface reads as the
  beginning and the row keeps the length the session knew.
- Controlled shutdown queues the worker-owned quit after the final progress
  event, then runs a nested GUI event loop until the catalog thread finishes.
  A delayed scan keeps the interface event-driven, and the process cannot exit
  with a live writer before the queued final progress is durable. A recorded
  progress write is applied to the GUI projection after queued refresh
  projections, ordered by the recorder's rising sequence number, so a stale
  refresh or a delayed echo of an older row cannot move a title backwards.
- Velvet, Hearth, and Nocturne are audition sound packs. The default stays none
  (`SettingsStore` stores an empty pack) until the owner records a listening
  decision on the theater system; no build or generation step changes the
  shipping default.

Render-path facts established by the libmpv spike, each covered by
`tests/playback/tst_playback.cpp`:

- libmpv fails a file outright when no render context exists yet, so the item
  holds the source until the scene graph hands its renderer a context.
- Freeing a render context disables video for the file libmpv already holds, and
  losing it leaves no frames to schedule a repaint, so the item asks for a new
  surface itself and reloads at the position it had reached.
- Qt Quick samples the framebuffer bottom-up like mpv's own output, so
  `MPV_RENDER_PARAM_FLIP_Y` must be zero with `setMirrorVertically(false)`.
- With `keep-open=yes` libmpv sends no `MPV_EVENT_END_FILE` when a file
  finishes; the end arrives as the `eof-reached` property, and `END_FILE`
  reports failures only. A file unloading also reports `time-pos` as
  unavailable, which must not be read as position zero.
- The offscreen QPA platform runs Qt Quick on the software backend, where a
  `QQuickFramebufferObject` never renders, so the playback suite selects a
  display-backed platform and skips its rendering cases without one.
- `mpv_render_context_render` blocks for each frame's display time on the
  scene-graph render thread. Whether HUD animation is paced by the movie's frame
  rate decides whether `MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME` is needed.

Focus-chrome facts established by the poster-card work, covered by
`tests/browse/tst_library_browse.cpp` and `tests/details/tst_media_details.cpp`:

- Qt Quick composites items source-over only, so the released ring's screen blend
  cannot come from a Canvas or a sibling item. `src/ui/FocusRing.cpp` is a
  `QSGRenderNode`: under the software backend it strokes through the renderer's
  `QPainter` with `CompositionMode_Screen` over the pixels already painted; under
  the OpenGL backend `main.cpp` pins it draws a rounded-rectangle signed-distance
  band with `glBlendFunc(GL_ONE_MINUS_DST_COLOR, GL_ONE)`, the same
  `dst + src * (1 - dst)` result for a premultiplied source. Copying artwork into
  a second buffer was rejected because it blends against the file's raw pixels
  rather than the rendered surface, placeholder, or transparent regions.
- The `QRhi` headers are private in the packaged Qt, so the node reads the
  viewport from `GL_VIEWPORT` for its pixel-sized edge ramp rather than from
  `renderTarget()`.
- The released chrome scales the rendered content but not its layout frame
  (`CardHoverModifier.swift:50` applies `scaleEffect` before `:61-69` adds the
  ring overlay), so the ring is inset by its line width inside the unscaled frame
  while the artwork grows beneath it. `FocusFrame.qml` therefore sits on the
  frame's layout bounds and never scales; its owner scales the content.
- A row boundary must not cut the chrome. `ArrowedScrollRow.swift:75-87` pads the
  scroll content by the halo padding and widens the scroll view by
  `-haloPadding` on both sides, so a first- or last-column card paints its shadows
  into the page's outer padding. A `GridView` with `clip: true` cuts that halo, so
  each row's viewport reaches a halo padding into the outer padding on each side
  while its unclipped card list sits a halo padding inside it
  (`MediaItemRow.qml`, which Home and Movies share).
- Qt clips items to rectangles, so a rounded poster surface cannot be clipped with
  `clip: true`. Every layer that reaches the corners paints itself inside the
  rounded path: the rounded fill is a `Rectangle`; the gradient canvas clips its
  context to the same path; the artwork is loaded and reported by a non-painting
  `Image` (keeping `source`, `status`, cache, and failure semantics) and drawn by
  a canvas that clips to the path. `QQuickCanvasItem::loadImage` connects
  `imageLoaded` only while the pixmap is still loading, so the canvas checks the
  load again immediately after requesting it.
- Assigning an image source already in Qt's pixmap cache reaches `Image.Ready`
  inside the assignment and emits no later status change, and clearing a failed
  source from inside `onStatusChanged` re-enters that handler before the
  assignment returns. `PosterArt.qml`'s loading state machine settles the request
  before clearing the source for that reason.
- The grid's column count follows its width, and a compositor may re-configure
  the window after the scene first laid out. Display-backed browse tests must
  wait for the window to be exposed and walk edges against a column count that
  held from first key to last. Delegate lookups force the grid's batched layout
  first, because a `GridView` answers model changes once per frame.
- `QSGRenderNode::flags()` depth/cull/stencil states have no effect in Qt 6;
  `qsgbatchrenderer.cpp` wraps `render()` in `beginExternal()`/`endExternal()` and
  `qrhigles2.cpp` resets cached state, so GL state a render node changes is
  re-established by the next pipeline bind. Do not add flags as evidence of a
  fix; reproduce a concrete leak first.
- A `Behavior`'s `animation` is a deferred property. Tests that look up the
  animation object must trigger the intercepted write first, as
  `tests/navigation/tst_sidebar_navigation.cpp` does.

## Parity oracle

The released Swift macOS application is the authoritative appearance, layout,
and interaction oracle for v3. It is a frozen, read-only reference in
`Marquee/`: no fixes, builds, or tests. Changing the language and framework is
not permission to reinterpret the interface, substitute a mockup, or declare
functional parity sufficient: every v3 surface must match the released
geometry, typography, artwork treatment, copy, spacing, motion, and
remote/keyboard/pointer transitions, adapting only the approved Linux plumbing
(Qt Quick in place of SwiftUI, libmpv in place of the AVFoundation/ffmpeg
bridge, XDG paths, SQLite). Symbol artwork, springs, and blend modes that the
stack cannot reproduce directly must be reproduced by construction, and the
approximation recorded in a code comment next to it.

Each parity proof uses an isolated synthetic library and drives the shipped QML
module; painted-pixel assertions retry until the scene has painted rather than
sleep. Display-backed visual acceptance on the theater host is separate from the
headless suites. Gaps found against the oracle go in `issues.md`.

---

## Problem

The released Swift v2 application is tied to macOS and Apple-specific UI and
playback frameworks. Marquee needs a portable Linux successor that preserves
its offline, local-library, and remote-first product strengths without carrying
the old implementation architecture forward.

## Goals

- Build Marquee v3 as a native Linux application, Omarchy/Arch-first, with
  C++23, Qt 6/QML, libmpv, SQLite, CMake, and Ninja.
- Preserve offline browsing, authoritative local artwork, deterministic remote
  navigation, safe library handling, and explicit domain ownership.
- Reproduce the released macOS appearance, layout, artwork treatment, focus and
  remote interactions, navigation transitions, and user-visible state changes
  in QML/C++, with source-backed evidence for every parity slice.
- Retire the highest technical risks through a libmpv/Qt Quick spike and then
  deliver the rewrite in independently useful milestones.
- Establish isolated automated tests, Arch packaging, and release verification
  before treating v3 as the daily-driver replacement.
- Keep one shared v3 codebase for the Linux x86_64 desktop build and the ARM64
  Raspberry Pi 5 appliance build; publish platform-specific packages/images
  rather than maintaining platform forks.
- Support local media on the Pi from an SD-card source, a USB drive, or a
  mounted NAS while keeping the catalog, artwork cache, settings, and playback
  state on the Pi.
- Add profile-aware Nostalgia TV as an internal Marquee route alongside the
  movie-only Play Something action, using the same catalog and player.

## Non-Goals

- Extending or refactoring the frozen v2 implementation as part of v3 work.
- Mechanically porting SwiftUI view files or retaining Apple frameworks for
  familiarity; the released rendered design and interaction contract remain
  mandatory v3 acceptance requirements.
- Adding arbitrary network streaming, mandatory TMDB access, multiple playback
  backends, or unrelated distribution formats before a real requirement
  justifies them. A user-mounted NAS root and the ARM64 Pi package/image are
  explicit v3 requirements, not app-level streaming or a second codebase.
- Requiring macOS catalog import before the fresh v3 schema and scanner are
  stable.

## Decisions

### 0. v3 product scope addition: Pi storage and Nostalgia TV

This is an intentional v3 product expansion, not a second application and not
an attempt to embed the standalone Python NostalgiaBox runtime. Marquee remains
one product with shared catalog, profiles, navigation, QML presentation, and
libmpv playback. The release family has separate artifacts for each supported
target:

```text
shared v3 source
       |
       +-- Linux x86_64 desktop package
       +-- Linux ARM64 Raspberry Pi 5 package/image
       `-- future macOS v3 artifact, only if a v3 macOS target is approved
```

### Product contract

- **Play Something is movie-only.** Its query and controller contract must
  include `media_kind = movie`; a TV episode must never be selected by this
  action, recommendation, or random-play path.
- **Nostalgia TV is television-only.** It is a sidebar route near Play
  Something that plays episodes through named, channel-style lineups rather
  than presenting another movie grid.
- **Entering Nostalgia TV stays inside Marquee.** It uses the existing route
  history, focus restoration, player lifecycle, and Back/Escape behavior. Exit
  stops or pauses the channel session and returns to the exact previous
  Marquee surface and logical focus target.
- **Profiles own the visible channel lineup and media allowlist.** The Kids
  profile can expose age-appropriate cartoons, educational/family shows, and
  era-specific children's channels. The Adult profile can expose classic
  sitcoms, westerns, dramas, mysteries, and 70s/80s/90s lineups. The profile
  boundary applies to browsing, search, Play Something, autoplay, channel
  switching, and direct playback; hiding an adult channel in QML is not enough.
- **A channel is data, not a hard-coded folder convention.** A channel has a
  stable ID, number, name, era/genre labels, profile or maturity scope, an
  ordered media selector, and a playback mode such as random, resume, or
  broadcast-clock scheduling. Channel membership references catalog media; it
  does not duplicate files or media rows.
- **The Pi targets 1080p first.** Hardware-accelerated H.264 playback and
  normal Qt/libmpv overlays are the initial acceptance bar. CRT treatment,
  4:3 presentation, channel banners, and other NostalgiaBox-inspired effects
  must have a performance-safe fallback on Pi.

### Storage boundary

Storage is an external filesystem/network boundary. Keep it below the catalog,
profile, and channel layers so those features do not care whether an episode
came from an SD card, USB drive, or NAS.

#### Storage sources and roots

Introduce a source registry rather than expanding `SettingsStore::libraryRoots`
into platform-specific conditionals:

```text
StorageSource
├── id                 stable application UUID
├── kind               sd | usb | nas
├── displayName
├── stableIdentity     filesystem UUID, udev identity, or server/share identity
├── mountPath          current local path, when available
├── available
└── lastSeenAt

MediaRoot
├── id
├── storageSourceId
├── relativePath       path below the source mount
├── contentKind        movies | tv | nostalgia
├── displayName
└── scanEnabled
```

The source identity, not `/dev/sdX` or a transient mount path, reconnects a
removable device to its existing catalog. The source/root migration must keep
the current v3 `library_roots` records readable and preserve media IDs,
watch-progress rows, and artwork references while adding source kind and
stable identity. Profile scope belongs to catalog queries and channel
definitions, not to the physical root, so one source can serve both profiles.

The three Pi modes are:

1. **SD card:** support a dedicated media partition or media card without
   scanning the operating-system partition as a library. The final Pi image
   must reserve application state and leave the media layout explicit rather
   than silently filling the boot volume.
2. **USB drive:** support locally attached flash, SSD, or HDD media through a
   stable filesystem identity. Do not persist device-letter assumptions. The
   Pi setup documentation must call out powered enclosures/hubs for drives
   that need more power.
3. **NAS:** consume a user-mounted SMB/CIFS or NFS share as a local-looking
   media root. Local Wi-Fi is sufficient for the first path; Ethernet is the
   reliability option. Tailscale is optional for a remote NAS or subnet route,
   and its credentials/routing belong to the OS/network setup, not ordinary
   Marquee settings.

Multiple sources may be enabled at once. The Pi stores the SQLite catalog,
artwork/thumbnails, settings, and profile/channel state locally; it does not
copy the NAS library merely to make it playable.

#### Mount and availability rules

- The platform/storage layer reports source readiness to `CatalogService`; it
  does not make QML or the scanner guess whether a path is a mount.
- A missing or disconnected source becomes `unavailable`, not an empty root.
  Existing catalog rows remain visible with an unavailable state and are not
  deleted by a failed scan.
- A NAS that drops during playback produces a controlled library/playback
  error and retry state. It must not silently advance through missing files or
  rewrite the catalog as if the media had been removed.
- The Pi setup flow may test and request a mount, but Marquee must not store
  NAS passwords in `QSettings`, logs, the catalog, or channel definitions.
- The desktop build consumes the same normalized source events but does not
  assume Pi-specific automount, HDMI-CEC, or systemd behavior.

### TV catalog and profile policy

The TV catalog must produce real show, season, and episode identity,
including series title, season/episode numbers, episode title, air year, and
ordering. The catalog may start with folder and `SxxEyy` parsing, but the
resulting channel selectors must query structured episode data rather than
reparse filenames in QML.

Add channel definitions and, if useful for query performance, materialized
channel membership in a later forward-only SQLite migration. The definition
needs at least:

```text
channel ID / number / display name
profile or maturity scope
era and genre labels
episode selector or collection ID
ordering mode: random | resume | broadcast
enabled state and optional schedule metadata
```

`ProfileController` supplies the active profile to every catalog projection.
`CatalogService`, `Search`, `PlaySomethingController`, and
`NostalgiaController` all apply the same allowlist before returning a playable
item. Unclassified content is excluded from Kids channels until explicitly
approved. QML may render the resulting projection but may not implement the
policy.

### Nostalgia TV route and playback

Add an explicit `NostalgiaTv` route to `NavigationController`, a
`NostalgiaController`/channel repository to the C++ domain layer, and a
`NostalgiaTvScreen.qml` surface loaded by `Main.qml`. `Sidebar.qml` gets a
Nostalgia TV entry beside the existing Play Something affordance.

The controller owns:

- the active profile and permitted channel lineup;
- channel selection and channel-number navigation;
- deterministic random selection, persistent resume, and optional
  broadcast-clock tune-in offsets;
- episode-end advancement and next-episode behavior;
- channel banner/OSD state and the profile-safe error state; and
- restoration of the previous route/focus target when the user exits.

Nostalgia playback uses the same future shared `MpvCore`/`PlayerController`
that normal movie and episode playback use. A channel queue may preload or
replace the next episode, but there must not be a second libmpv handle for the
same session. Do not launch the Python NostalgiaBox process from Marquee: a
second fullscreen app would compete for DRM/Wayland, audio, focus, and remote
input. Keep NostalgiaBox as a behavioral reference and optional standalone
hardware-spike tool while the production route is native to Marquee.

#### Retro TV viewer: required presentation layer

The retro viewer is a product requirement, not optional polish. The integration
must preserve the visual contract already implemented by NostalgiaBox:

- a centred 4:3 picture inside the 16:9 display with pillarbox bars;
- gentle CRT barrel curvature, rounded screen corners, edge vignette, and
  configurable scanlines/phosphor treatment;
- channel-change static or transition filler before the new episode appears;
- the green phosphor channel banner, volume/mute bar, information messages,
  and persistent standby screen; and
- overlay safe-area placement inside the curved 4:3 picture rather than in the
  black pillarbox bars.

Implement the video treatment as a Marquee-owned libmpv shader/effect in
Nostalgia mode, starting from NostalgiaBox's generated GLSL behavior. Render
the channel/volume/message OSD through the native `NostalgiaTvScreen.qml` and
its controller so it participates in Marquee focus, timers, accessibility, and
route teardown; matching the appearance does not require carrying the Python
ASS-overlay implementation into the application.

The effect is allowed to disable itself when a Pi renderer cannot sustain it,
but playback must remain correct and the UI must show that the visual effect
is unavailable rather than silently changing the channel experience. The
desktop and Pi acceptance gates must separately verify 4:3 geometry, shader
output, static transition timing, OSD placement/expiry, volume/mute behavior,
standby, and clean exit back to Marquee.

### Pi runtime and release boundary

The application layer remains portable. The Pi target adds a thin platform
layer for ARM64 build flags, fullscreen/window startup, hardware-decoding
validation, HDMI-CEC or evdev/USB remote input, systemd boot/recovery, and
storage setup documentation. It must not leak mount commands or Pi-only input
APIs into catalog, profile, channel, or QML code.

The release plan therefore publishes separate artifacts from the same source:

- Linux x86_64 desktop package for laptops/Omarchy.
- Linux ARM64 Pi package and, once hardware validation passes, a bootable Pi
  image or image-install guide with SD, USB, and NAS setup.
- No promise that the shipped macOS v2 binary runs on Pi; macOS v3 is a
  separate future target.

### Delivery gates for this addition

Do not make Nostalgia TV or Pi hardware block the first movie-only vertical
slice. Add the work only after the shared catalog, profiles, TV hierarchy,
route history, and player lifecycle have owners and tests. The smallest useful
order is:

```text
movie-only v3 foundation
        -> TV shows / seasons / episodes
        -> profile allowlists and movie-only Play Something
        -> storage source registry and unavailable-source behavior
        -> Pi SD / USB / NAS setup and ARM64 playback spike
        -> Nostalgia TV route and one channel
        -> channel scheduling, OSD/CRT effects, remote, and release polish
```

Each arrow is independently testable and landable. A Pi package is not called
compatible until a real Pi 5, display, audio path, remote, and at least one
sample from each storage mode have passed the acceptance gate below.

### 1. Final recommendation

Build Marquee with:

- **C++23** for application behavior and durable state
- **Qt 6** for the application framework
- **Qt Quick/QML** for the ten-foot interface
- **libmpv** for all normal media playback
- **SQLite** for the offline catalog and profile state
- **CMake + Ninja** for builds
- **Qt Test + CTest** for automated tests
- **PKGBUILD** for Omarchy/Arch packaging

The ownership rule is:

> **C++ owns behavior and state. QML owns presentation. libmpv owns playback. SQLite owns durable local data.**

Do not port SwiftUI view files line by line or preserve Apple-specific APIs.
That is an implementation-boundary rule, not permission to reinterpret the
design: Swift sources remain the oracle for the released rendered hierarchy,
geometry, typography, colors, artwork treatment, focus/remote behavior,
navigation transitions, timing, and state changes. A v3 slice is accepted only
with source-backed differential coverage and an honest record of any behavior
that cannot yet be established on the target display or remote.

---

### 2. Product invariants to preserve

The Linux rewrite should retain the strongest parts of the existing Marquee design:

1. **Offline-first browsing**
   - A network connection must not be required to browse or play the local library.
   - TMDB is optional enrichment, never a runtime dependency.

2. **Local artwork is authoritative**
   - A valid sidecar poster or backdrop wins over downloaded artwork.
   - Network metadata may fill gaps but should not silently replace local choices.

3. **Remote-first navigation**
   - Arrow keys, a D-pad, Enter/Select, Back/Escape, and media keys are primary inputs.
   - Mouse support is useful, but it must not define the interaction model.

4. **One clear navigation authority**
   - Logical focus and route state must not be inferred from scroll offsets or animation state.
   - Scrolling follows focus; focus does not follow scrolling.

5. **Safe library handling**
   - Tests never touch the live catalog or real theater library.
   - A temporarily unavailable mount does not cause the catalog to be deleted.

6. **Deterministic playback lifecycle**
   - Stop, failure, shutdown, and reload paths must leave the player in a known state.
   - No orphaned helper processes should remain if ffprobe or another helper is later used.

7. **Explicit state ownership**
   - Avoid rebuilding the old all-purpose `AppState` pattern in C++.
   - Each domain has one owner.

8. **Motion respects the user**
   - Motion uses named `Theme` tokens and honors `SettingsStore.reduceMotion`.
   - Reduce Motion changes interpolation, never the focus-derived final target.

---

### 3. What changes from the macOS build

| Existing concept | Omarchy implementation |
|---|---|
| `MarqueeApp.swift` | `main.cpp` plus `ApplicationController` |
| SwiftUI screens | QML screens and components |
| AppKit focus/scroll coordinators | Explicit QML focus indices plus a C++ focus/navigation controller where needed |
| `AppState` compatibility surface | Thin composition/controller layer only |
| `LibraryState` | `CatalogService`, `LibraryModel`, and browse projections |
| `ProfileSession` | `ProfileController` and profile repository |
| `PlaybackSession` / `MPVPlayerService` | `PlayerController` and `MpvVideoItem` |
| `AppRouter` | `NavigationController` |
| `SQLiteCatalogStore` | `CatalogDatabase` and repositories |
| `DiffScanner` | `LibraryScanner` worker |
| `BrowseSnapshot` | Immutable C++ projections exposed through Qt models |
| `ArtworkCache` / `CachedImageView` | `ArtworkResolver`, disk cache, and QML image provider |
| AVFoundation/ffmpeg backend routing | One normal libmpv playback path |
| Xcode project | CMake project |
| DMG release | Arch package, then optional AppImage/Flatpak later |

The old macOS catalog may be importable, but **do not make catalog compatibility a first-milestone requirement**. Prove the Linux product with a fresh test catalog first. Add an importer after the new schema and scanner are stable.

---

### 4. Target architecture

```text
Keyboard / remote / gamepad
            |
            v
        QML screens
            |
       user intents
            |
            v
  ApplicationController
   |       |        |          |
   v       v        v          v
Router  Catalog  Storage    Playback
          |        |           |
          v        v           v
       SQLite  mounts/roots  libmpv
          \       |          /
           \      v         /
            profile/channel projections
```

Recommended domain owners:

```text
ApplicationController
├── NavigationController
├── StorageSourceRegistry / MountMonitor
├── CatalogService
│   ├── CatalogDatabase
│   ├── LibraryScanner
│   ├── LibraryModel
│   └── HomeProjectionModel
├── ProfileController
├── NostalgiaController / ChannelRepository
├── PlayerController / MpvVideoItem
├── ArtworkResolver
├── MetadataService
└── SettingsStore
```

#### Boundary rules

QML may:

- bind to properties
- display model roles
- emit user intent
- animate visual state
- maintain small, screen-local presentation state

QML must not:

- walk the filesystem
- run SQL
- call TMDB directly
- parse media filenames
- own watch progress
- perform blocking work
- decide catalog identity
- resolve storage mounts or stable source identity
- enforce profile and maturity policy in the view
- directly manage libmpv lifecycle

C++ may expose deliberate Qt-facing APIs such as:

```cpp
Q_INVOKABLE void scanLibraries();
Q_INVOKABLE void openMedia(const QString &mediaId);
Q_INVOKABLE void openNostalgiaTv();
Q_INVOKABLE void goBack();
Q_INVOKABLE void togglePause();
```

Avoid exposing an unrestricted object graph to QML.

---

### 5. Development environment on Omarchy

Install the native dependencies from the Arch repositories:

```bash
sudo pacman -S --needed \
  base-devel \
  cmake \
  ninja \
  pkgconf \
  qt6-base \
  qt6-declarative \
  qt6-shadertools \
  qt6-wayland \
  mpv \
  sqlite
```

Useful development tools:

```bash
sudo pacman -S --needed \
  clang \
  clang-tools-extra \
  gdb \
  lldb \
  ccache
```

The Arch `mpv` package includes the libmpv headers, shared library, and `mpv.pc`, so CMake can discover it through `pkg-config`.

Confirm the environment:

```bash
cmake --version
ninja --version
pkg-config --modversion mpv
qmake6 -v
```

For Wayland testing, confirm the current session:

```bash
echo "$XDG_SESSION_TYPE"
echo "$WAYLAND_DISPLAY"
```

Expected:

```text
wayland
wayland-1
```

The exact `WAYLAND_DISPLAY` value may differ.

---

### 6. Recommended repository layout

```text
marquee/
├── CMakeLists.txt
├── cmake/
│   ├── CompilerWarnings.cmake
│   └── Sanitizers.cmake
│
├── src/
│   ├── main.cpp
│   │
│   ├── app/
│   │   ├── ApplicationController.hpp
│   │   ├── ApplicationController.cpp
│   │   ├── AppPaths.hpp
│   │   └── AppPaths.cpp
│   │
│   ├── navigation/
│   │   ├── NavigationController.hpp
│   │   └── NavigationController.cpp
│   │
│   ├── storage/
│   │   ├── StorageSource.hpp
│   │   ├── StorageSourceRegistry.cpp
│   │   ├── MountMonitor.hpp
│   │   └── MountMonitor.cpp
│   │
│   ├── catalog/
│   │   ├── CatalogDatabase.hpp
│   │   ├── CatalogDatabase.cpp
│   │   ├── CatalogRepository.hpp
│   │   ├── CatalogRepository.cpp
│   │   ├── CatalogWorker.hpp
│   │   ├── CatalogWorker.cpp
│   │   ├── LibraryScanner.hpp
│   │   ├── LibraryScanner.cpp
│   │   ├── MediaItem.hpp
│   │   └── migrations/
│   │       ├── Migration.hpp
│   │       └── Migrations.cpp
│   │
│   ├── models/
│   │   ├── LibraryModel.hpp
│   │   ├── LibraryModel.cpp
│   │   ├── MediaRowModel.hpp
│   │   └── MediaRowModel.cpp
│   │
│   ├── playback/
│   │   ├── PlayerController.hpp
│   │   ├── PlayerController.cpp
│   │   ├── MpvHandle.hpp
│   │   ├── MpvVideoItem.hpp
│   │   └── MpvVideoItem.cpp
│   │
│   ├── profiles/
│   │   ├── ProfileController.hpp
│   │   ├── ProfileController.cpp
│   │   └── ProfileRepository.cpp
│   │
│   ├── nostalgia/
│   │   ├── NostalgiaController.hpp
│   │   ├── NostalgiaController.cpp
│   │   ├── ChannelRepository.hpp
│   │   └── ChannelRepository.cpp
│   │
│   ├── artwork/
│   │   ├── ArtworkResolver.hpp
│   │   ├── ArtworkResolver.cpp
│   │   └── ArtworkImageProvider.cpp
│   │
│   ├── metadata/
│   │   ├── MetadataService.hpp
│   │   └── MetadataService.cpp
│   │
│   ├── settings/
│   │   ├── SettingsStore.hpp
│   │   └── SettingsStore.cpp
│   │
│   └── support/
│       ├── Error.hpp
│       ├── Logging.hpp
│       └── Logging.cpp
│
├── qml/
│   ├── Main.qml
│   ├── Theme.qml
│   ├── components/
│   │   ├── PosterCard.qml
│   │   ├── MediaRow.qml
│   │   ├── HeroBanner.qml
│   │   ├── Sidebar.qml
│   │   ├── PlayerControls.qml
│   │   └── ErrorToast.qml
│   └── screens/
│       ├── HomeScreen.qml
│       ├── LibraryScreen.qml
│       ├── SearchScreen.qml
│       ├── DetailsScreen.qml
│       ├── PlayerScreen.qml
│       ├── NostalgiaTvScreen.qml
│       ├── ProfilePickerScreen.qml
│       └── SettingsScreen.qml
│
├── resources/
│   ├── icons/
│   └── placeholders/
│
├── tests/
│   ├── CMakeLists.txt
│   ├── catalog/
│   ├── scanner/
│   ├── navigation/
│   └── fixtures/
│       └── library/
│
├── packaging/
│   ├── arch/PKGBUILD
│   ├── pi/
│   │   ├── marquee.service
│   │   └── storage-setup.md
│   ├── marquee.desktop
│   └── icons/
│
└── scripts/
    ├── configure-debug.sh
    ├── run-debug.sh
    └── make-fixture-library.sh
```

Do not create every directory on day one. Start with the vertical slice and add domains as they become real.

---

### 7. Starter `CMakeLists.txt`

This is a practical starting point for an executable with embedded QML resources and libmpv discovery.

```cmake
cmake_minimum_required(VERSION 3.24)

project(Marquee
    VERSION 0.1.0
    DESCRIPTION "Native Linux home-theater library browser"
    LANGUAGES CXX
)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

option(MARQUEE_BUILD_TESTS "Build Marquee tests" ON)
option(MARQUEE_ENABLE_SANITIZERS "Enable ASan and UBSan" OFF)

include(GNUInstallDirs)

find_package(Qt6 6.8 REQUIRED COMPONENTS
    Core
    Gui
    Qml
    Quick
    QuickControls2
    OpenGL
    Sql
    Network
    Concurrent
)

find_package(PkgConfig REQUIRED)
pkg_check_modules(MPV REQUIRED IMPORTED_TARGET mpv)

qt_standard_project_setup(REQUIRES 6.8)

set_source_files_properties(qml/Theme.qml PROPERTIES
    QT_QML_SINGLETON_TYPE TRUE
)

qt_add_executable(marquee
    src/main.cpp

    src/app/ApplicationController.hpp
    src/app/ApplicationController.cpp
    src/app/AppPaths.hpp
    src/app/AppPaths.cpp

    src/catalog/MediaItem.hpp
    src/catalog/CatalogDatabase.hpp
    src/catalog/CatalogDatabase.cpp
    src/catalog/LibraryScanner.hpp
    src/catalog/LibraryScanner.cpp

    src/models/LibraryModel.hpp
    src/models/LibraryModel.cpp

    src/navigation/NavigationController.hpp
    src/navigation/NavigationController.cpp

    src/playback/PlayerController.hpp
    src/playback/PlayerController.cpp
    src/playback/MpvVideoItem.hpp
    src/playback/MpvVideoItem.cpp

    src/support/Logging.hpp
    src/support/Logging.cpp
)

qt_add_qml_module(marquee
    URI Marquee
    VERSION 1.0

    QML_FILES
        qml/Main.qml
        qml/Theme.qml
        qml/components/PosterCard.qml
        qml/components/PlayerControls.qml
        qml/screens/HomeScreen.qml
        qml/screens/PlayerScreen.qml

    RESOURCES
        resources/icons/marquee.svg
)

target_include_directories(marquee PRIVATE src)

target_link_libraries(marquee PRIVATE
    Qt6::Core
    Qt6::Gui
    Qt6::Qml
    Qt6::Quick
    Qt6::QuickControls2
    Qt6::OpenGL
    Qt6::Sql
    Qt6::Network
    Qt6::Concurrent
    PkgConfig::MPV
)

if(CMAKE_CXX_COMPILER_ID MATCHES "GNU|Clang")
    target_compile_options(marquee PRIVATE
        -Wall
        -Wextra
        -Wpedantic
        -Wshadow
        -Wnon-virtual-dtor
    )
endif()

if(MARQUEE_ENABLE_SANITIZERS AND CMAKE_CXX_COMPILER_ID MATCHES "GNU|Clang")
    target_compile_options(marquee PRIVATE
        -fsanitize=address,undefined
        -fno-omit-frame-pointer
    )
    target_link_options(marquee PRIVATE
        -fsanitize=address,undefined
    )
endif()

install(TARGETS marquee
    RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
)

install(FILES packaging/marquee.desktop
    DESTINATION ${CMAKE_INSTALL_DATADIR}/applications
)

install(FILES packaging/icons/marquee.svg
    DESTINATION ${CMAKE_INSTALL_DATADIR}/icons/hicolor/scalable/apps
)

if(MARQUEE_BUILD_TESTS)
    enable_testing()
    add_subdirectory(tests)
endif()
```

Configure and build:

```bash
cmake -S . -B build/debug -G Ninja \
  -DCMAKE_BUILD_TYPE=Debug \
  -DMARQUEE_BUILD_TESTS=ON

cmake --build build/debug
```

Run:

```bash
QT_LOGGING_RULES="marquee.*=true" ./build/debug/marquee
```

Sanitizer build:

```bash
cmake -S . -B build/asan -G Ninja \
  -DCMAKE_BUILD_TYPE=Debug \
  -DMARQUEE_ENABLE_SANITIZERS=ON

cmake --build build/asan
./build/asan/marquee
```

---

### 8. Application entry point

For the first integrated libmpv path, force Qt Quick to use OpenGL. This allows a straightforward `QQuickFramebufferObject` bridge.

`src/main.cpp`:

```cpp
#include <clocale>
#include <cstdlib>

#include <QCommandLineOption>
#include <QCommandLineParser>
#include <QCoreApplication>
#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickWindow>
#include <QSGRendererInterface>

#include "app/ApplicationController.hpp"
#include "navigation/NavigationController.hpp"
#include "playback/MpvVideoItem.hpp"

int main(int argc, char *argv[])
{
    // Must be requested before the first QQuickWindow is created.
    QQuickWindow::setGraphicsApi(QSGRendererInterface::OpenGL);

    QGuiApplication app(argc, argv);

    // libmpv expects numeric parsing to use the C locale.
    std::setlocale(LC_NUMERIC, "C");

    QCoreApplication::setOrganizationName(QStringLiteral("HermesOS"));
    QCoreApplication::setOrganizationDomain(QStringLiteral("hermes.local"));
    QCoreApplication::setApplicationName(QStringLiteral("Marquee"));
    QCoreApplication::setApplicationVersion(QStringLiteral("0.1.0"));
    QGuiApplication::setDesktopFileName(QStringLiteral("marquee"));

    QCommandLineParser parser;
    parser.setApplicationDescription(
        QStringLiteral("Marquee local home-theater browser"));
    parser.addHelpOption();
    parser.addVersionOption();

    QCommandLineOption fullscreenOption(
        QStringList{QStringLiteral("f"), QStringLiteral("fullscreen")},
        QStringLiteral("Start in fullscreen mode."));

    QCommandLineOption libraryOption(
        QStringList{QStringLiteral("library")},
        QStringLiteral("Temporarily add a library root for this run."),
        QStringLiteral("path"));

    parser.addOption(fullscreenOption);
    parser.addOption(libraryOption);
    parser.process(app);

    qmlRegisterType<MpvVideoItem>("Marquee.Playback", 1, 0, "MpvVideo");
    qmlRegisterUncreatableType<NavigationController>(
        "Marquee",
        1,
        0,
        "NavigationController",
        "NavigationController is owned by ApplicationController");

    ApplicationController controller;
    controller.setStartFullscreen(parser.isSet(fullscreenOption));

    if (parser.isSet(libraryOption)) {
        controller.setTemporaryLibraryRoot(parser.value(libraryOption));
    }

    QQmlApplicationEngine engine;
    engine.rootContext()->setContextProperty(
        QStringLiteral("appController"), &controller);

    QObject::connect(
        &engine,
        &QQmlApplicationEngine::objectCreationFailed,
        &app,
        [] { QCoreApplication::exit(EXIT_FAILURE); },
        Qt::QueuedConnection);

    engine.loadFromModule(QStringLiteral("Marquee"), QStringLiteral("Main"));

    return app.exec();
}
```

The `ApplicationController` must outlive the QML engine objects that reference it. Declaring it before the engine, as above, gives the engine the earlier destruction point because local variables are destroyed in reverse order.

---

### 9. Application paths and XDG storage

Use `QStandardPaths`; do not hard-code `~/.config` or `~/.local/share` throughout the code.

Recommended effective layout on Linux:

```text
~/.config/Marquee/
    marquee.ini

~/.local/share/Marquee/
    catalog.sqlite
    profiles/

~/.cache/Marquee/
    artwork/
    thumbnails/
```

`src/app/AppPaths.hpp`:

```cpp
#pragma once

#include <QString>

class AppPaths final
{
public:
    static QString configDirectory();
    static QString dataDirectory();
    static QString cacheDirectory();

    static QString settingsFile();
    static QString catalogFile();
    static QString artworkCacheDirectory();

    static void ensureDirectories();
};
```

`src/app/AppPaths.cpp`:

```cpp
#include "app/AppPaths.hpp"

#include <QDir>
#include <QStandardPaths>
#include <stdexcept>

namespace
{
QString requirePath(QStandardPaths::StandardLocation location)
{
    const QString path = QStandardPaths::writableLocation(location);
    if (path.isEmpty()) {
        throw std::runtime_error("Qt returned an empty writable path");
    }
    return path;
}
}

QString AppPaths::configDirectory()
{
    return requirePath(QStandardPaths::AppConfigLocation);
}

QString AppPaths::dataDirectory()
{
    return requirePath(QStandardPaths::AppDataLocation);
}

QString AppPaths::cacheDirectory()
{
    return requirePath(QStandardPaths::CacheLocation);
}

QString AppPaths::settingsFile()
{
    return QDir(configDirectory()).filePath(QStringLiteral("marquee.ini"));
}

QString AppPaths::catalogFile()
{
    return QDir(dataDirectory()).filePath(QStringLiteral("catalog.sqlite"));
}

QString AppPaths::artworkCacheDirectory()
{
    return QDir(cacheDirectory()).filePath(QStringLiteral("artwork"));
}

void AppPaths::ensureDirectories()
{
    const QStringList paths{
        configDirectory(),
        dataDirectory(),
        cacheDirectory(),
        artworkCacheDirectory()
    };

    for (const QString &path : paths) {
        if (!QDir().mkpath(path)) {
            throw std::runtime_error(
                QStringLiteral("Unable to create %1").arg(path).toStdString());
        }
    }
}
```

For tests, enable Qt's test path mode before creating repositories:

```cpp
QStandardPaths::setTestModeEnabled(true);
```

That protects the real user configuration and catalog.

---

### 10. Settings

The earlier general recommendation used TOML. For the Qt build, simplify the first release and use **`QSettings` with INI format**. It is dependency-free, human-readable, and works well with XDG paths.

`src/settings/SettingsStore.hpp`:

```cpp
#pragma once

#include <QObject>
#include <QStringList>

class SettingsStore final : public QObject
{
    Q_OBJECT

    Q_PROPERTY(QStringList libraryRoots
               READ libraryRoots
               WRITE setLibraryRoots
               NOTIFY libraryRootsChanged)

    Q_PROPERTY(bool startFullscreen
               READ startFullscreen
               WRITE setStartFullscreen
               NOTIFY startFullscreenChanged)

public:
    explicit SettingsStore(QObject *parent = nullptr);

    QStringList libraryRoots() const;
    void setLibraryRoots(const QStringList &roots);

    bool startFullscreen() const;
    void setStartFullscreen(bool value);

signals:
    void libraryRootsChanged();
    void startFullscreenChanged();

private:
    QStringList m_libraryRoots;
    bool m_startFullscreen{true};
};
```

Basic load/save implementation:

```cpp
#include "settings/SettingsStore.hpp"

#include <QSettings>

#include "app/AppPaths.hpp"

SettingsStore::SettingsStore(QObject *parent)
    : QObject(parent)
{
    QSettings settings(AppPaths::settingsFile(), QSettings::IniFormat);

    m_libraryRoots = settings.value(
        QStringLiteral("library/roots"), QStringList{}).toStringList();

    m_startFullscreen = settings.value(
        QStringLiteral("ui/startFullscreen"), true).toBool();
}

QStringList SettingsStore::libraryRoots() const
{
    return m_libraryRoots;
}

void SettingsStore::setLibraryRoots(const QStringList &roots)
{
    if (m_libraryRoots == roots) {
        return;
    }

    m_libraryRoots = roots;

    QSettings settings(AppPaths::settingsFile(), QSettings::IniFormat);
    settings.setValue(QStringLiteral("library/roots"), m_libraryRoots);

    emit libraryRootsChanged();
}

bool SettingsStore::startFullscreen() const
{
    return m_startFullscreen;
}

void SettingsStore::setStartFullscreen(bool value)
{
    if (m_startFullscreen == value) {
        return;
    }

    m_startFullscreen = value;

    QSettings settings(AppPaths::settingsFile(), QSettings::IniFormat);
    settings.setValue(QStringLiteral("ui/startFullscreen"), value);

    emit startFullscreenChanged();
}
```

Resulting file:

```ini
[library]
roots=/mnt/media/Movies, /mnt/media/TV

[ui]
startFullscreen=true
```

Keep credentials out of this file by default. Read TMDB configuration from the environment:

```bash
export TMDB_API_KEY='...'
```

C++:

```cpp
const QByteArray tmdbKey = qgetenv("TMDB_API_KEY");
```

Never print the credential in logs.

The simple `libraryRoots` setting is sufficient for the first movie-only
vertical slice. Before storage sources land, the settings surface must manage
`StorageSource` and `MediaRoot` records instead: source type, display name,
availability, test/retry action, and the content roots assigned to Movies or
TV. Mount credentials remain an OS/network concern and never become a
Marquee setting.

---

### 11. Logging

Use Qt logging categories instead of scattered `qDebug()` calls.

`src/support/Logging.hpp`:

```cpp
#pragma once

#include <QLoggingCategory>

Q_DECLARE_LOGGING_CATEGORY(logApp)
Q_DECLARE_LOGGING_CATEGORY(logCatalog)
Q_DECLARE_LOGGING_CATEGORY(logScanner)
Q_DECLARE_LOGGING_CATEGORY(logPlayback)
Q_DECLARE_LOGGING_CATEGORY(logArtwork)
Q_DECLARE_LOGGING_CATEGORY(logMetadata)
```

`src/support/Logging.cpp`:

```cpp
#include "support/Logging.hpp"

Q_LOGGING_CATEGORY(logApp, "marquee.app")
Q_LOGGING_CATEGORY(logCatalog, "marquee.catalog")
Q_LOGGING_CATEGORY(logScanner, "marquee.scanner")
Q_LOGGING_CATEGORY(logPlayback, "marquee.playback")
Q_LOGGING_CATEGORY(logArtwork, "marquee.artwork")
Q_LOGGING_CATEGORY(logMetadata, "marquee.metadata")
```

Usage:

```cpp
qCInfo(logScanner)
    << "scan complete"
    << "root=" << rootPath
    << "files=" << candidates.size()
    << "changed=" << changedCount;
```

Enable during development:

```bash
QT_LOGGING_RULES="marquee.*=true" ./build/debug/marquee
```

Enable one subsystem:

```bash
QT_LOGGING_RULES="marquee.playback.debug=true" ./build/debug/marquee
```

Never log:

- API credentials
- entire private metadata responses unless explicitly redacted
- profile secrets
- full library paths in user-facing telemetry

Local debug logs may include paths when needed, but make that an explicit diagnostic choice.

---

### 12. C++ engineering rules

Treat these as non-negotiable:

#### Ownership

- Use RAII for every resource.
- No owning raw pointers.
- Use Qt parent ownership for `QObject` trees.
- Use `std::unique_ptr` for non-`QObject` ownership.
- Do not give a `QObject` both a Qt parent and a `std::unique_ptr` owner.
- Use `QPointer<T>` when observing a `QObject` that may be deleted elsewhere.

#### Types

- Prefer `enum class`.
- Prefer domain IDs over anonymous strings in internal APIs.
- Use `std::optional` when absence is meaningful.
- Use `const` by default.
- Do not persist list positions as identity; persist media IDs.

#### Signals and slots

Use typed connections:

```cpp
connect(scanner,
        &LibraryScanner::scanCompleted,
        this,
        &CatalogService::handleScanCompleted);
```

Avoid string-based `SIGNAL()`/`SLOT()` macros.

#### Threading

- GUI objects stay on the GUI thread.
- Do not mutate `QAbstractItemModel` from a worker thread.
- Each SQL connection belongs to the thread in which it was created.
- Prefer worker `QObject`s moved to a `QThread` over putting business slots directly on a `QThread` subclass.
- Never block the GUI thread waiting for a scan or network response.

#### Errors

- Do not let exceptions cross the QML boundary.
- Catch at C++ controller boundaries and expose a user-safe error state.
- Preserve technical details in logs.
- Never use `unwrap`-style assumptions such as unchecked `.value()` or null dereferences in runtime paths.

---

### 13. Core media types

Start with plain value types that can be copied between the catalog worker and GUI thread.

`src/catalog/MediaItem.hpp`:

```cpp
#pragma once

#include <QDateTime>
#include <QMetaType>
#include <QString>
#include <QUrl>

struct MediaItem
{
    QString id;
    QString libraryRootId;
    QString relativePath;
    QString absolutePath;

    QString title;
    QString sortTitle;
    QString kind;          // "movie", "show", or "episode"
    int year{0};

    QString posterPath;
    QString backdropPath;

    qint64 fileSize{0};
    QDateTime modifiedAt;

    [[nodiscard]] QUrl posterUrl() const
    {
        // An empty path means no local artwork; PosterArt draws the placeholder.
        return posterPath.isEmpty() ? QUrl() : QUrl::fromLocalFile(posterPath);
    }
};

Q_DECLARE_METATYPE(MediaItem)
Q_DECLARE_METATYPE(QVector<MediaItem>)
```

A stable first-pass ID can be derived from:

```text
library root UUID + normalized relative path
```

Example helper:

```cpp
#include <QCryptographicHash>

QString mediaIdFor(const QString &rootId, const QString &relativePath)
{
    QByteArray material = rootId.toUtf8();
    material.append('\0');
    material.append(relativePath.toUtf8());

    return QString::fromLatin1(
        QCryptographicHash::hash(material, QCryptographicHash::Sha256).toHex());
}
```

A rename will change this path-derived ID. That is acceptable for the first milestone. Later, add rename detection using file fingerprints or inode/device observations if preserving watch state across renames becomes important.

---

### 14. SQLite catalog

#### Recommended first schema

Start smaller than the full macOS catalog. Build the minimum schema needed for the vertical slice.

```sql
PRAGMA foreign_keys = ON;

CREATE TABLE library_roots (
    id              TEXT PRIMARY KEY NOT NULL,
    path            TEXT NOT NULL UNIQUE,
    display_name    TEXT NOT NULL,
    available       INTEGER NOT NULL DEFAULT 1,
    last_scan_at    TEXT
);

CREATE TABLE media_items (
    id              TEXT PRIMARY KEY NOT NULL,
    library_root_id TEXT NOT NULL,
    relative_path   TEXT NOT NULL,
    media_kind      TEXT NOT NULL,
    title           TEXT NOT NULL,
    sort_title      TEXT NOT NULL,
    year            INTEGER,
    poster_path     TEXT,
    backdrop_path   TEXT,
    file_size       INTEGER NOT NULL,
    modified_at     TEXT NOT NULL,
    discovered_at   TEXT NOT NULL,
    updated_at      TEXT NOT NULL,

    FOREIGN KEY (library_root_id)
        REFERENCES library_roots(id)
        ON DELETE CASCADE,

    UNIQUE (library_root_id, relative_path)
);

CREATE INDEX media_items_sort_title_idx
    ON media_items(sort_title);

CREATE INDEX media_items_root_idx
    ON media_items(library_root_id);

CREATE TABLE profiles (
    id              TEXT PRIMARY KEY,
    name            TEXT NOT NULL,
    created_at      TEXT NOT NULL
);

CREATE TABLE watch_progress (
    profile_id      TEXT NOT NULL,
    media_id        TEXT NOT NULL,
    position_ms     INTEGER NOT NULL DEFAULT 0,
    duration_ms     INTEGER NOT NULL DEFAULT 0,
    completed       INTEGER NOT NULL DEFAULT 0,
    updated_at      TEXT NOT NULL,

    PRIMARY KEY (profile_id, media_id),

    FOREIGN KEY (profile_id)
        REFERENCES profiles(id)
        ON DELETE CASCADE,

    FOREIGN KEY (media_id)
        REFERENCES media_items(id)
        ON DELETE CASCADE
);
```

Add shows, seasons, episodes, people, genres, taste data, and FTS only after the movie path works end to end.

#### Database wrapper

`src/catalog/CatalogDatabase.hpp`:

```cpp
#pragma once

#include <QSqlDatabase>
#include <QString>

class CatalogDatabase final
{
public:
    explicit CatalogDatabase(QString databasePath);
    ~CatalogDatabase();

    CatalogDatabase(const CatalogDatabase &) = delete;
    CatalogDatabase &operator=(const CatalogDatabase &) = delete;

    CatalogDatabase(CatalogDatabase &&) = delete;
    CatalogDatabase &operator=(CatalogDatabase &&) = delete;

    [[nodiscard]] QSqlDatabase &connection();
    void migrate();

private:
    void executeOrThrow(const QString &sql);

    QString m_connectionName;
    QSqlDatabase m_database;
};
```

`src/catalog/CatalogDatabase.cpp`:

```cpp
#include "catalog/CatalogDatabase.hpp"

#include <QSqlError>
#include <QSqlQuery>
#include <QUuid>
#include <stdexcept>

CatalogDatabase::CatalogDatabase(QString databasePath)
    : m_connectionName(
          QStringLiteral("marquee-catalog-%1")
              .arg(QUuid::createUuid().toString(QUuid::WithoutBraces))),
      m_database(QSqlDatabase::addDatabase(
          QStringLiteral("QSQLITE"), m_connectionName))
{
    m_database.setDatabaseName(std::move(databasePath));

    if (!m_database.open()) {
        throw std::runtime_error(
            m_database.lastError().text().toStdString());
    }

    // The lock wait must be in place before anything takes a lock, and
    // journal mode is a persistent change to the file, so migrate() switches
    // the catalog to WAL only once it has accepted the schema.
    executeOrThrow(QStringLiteral("PRAGMA busy_timeout = 5000"));
    executeOrThrow(QStringLiteral("PRAGMA foreign_keys = ON"));
}

CatalogDatabase::~CatalogDatabase()
{
    if (m_database.isValid()) {
        m_database.close();
    }

    // Drop our handle before removing the named Qt connection.
    m_database = QSqlDatabase{};
    QSqlDatabase::removeDatabase(m_connectionName);
}

QSqlDatabase &CatalogDatabase::connection()
{
    return m_database;
}

void CatalogDatabase::executeOrThrow(const QString &sql)
{
    QSqlQuery query(m_database);
    if (!query.exec(sql)) {
        throw std::runtime_error(
            QStringLiteral("SQL failed: %1; statement: %2")
                .arg(query.lastError().text(), sql)
                .toStdString());
    }
}
```

#### Migration approach

Use `PRAGMA user_version` and forward-only migrations.

```cpp
struct Migration
{
    int version;
    QStringList statements;
};
```

```cpp
const QVector<Migration> migrations{
    {
        1,
        {
            QStringLiteral(R"SQL(
                CREATE TABLE library_roots (
                    id TEXT PRIMARY KEY NOT NULL,
                    path TEXT NOT NULL UNIQUE,
                    display_name TEXT NOT NULL,
                    available INTEGER NOT NULL DEFAULT 1,
                    last_scan_at TEXT
                )
            )SQL"),
            QStringLiteral(R"SQL(
                CREATE TABLE media_items (
                    id TEXT PRIMARY KEY NOT NULL,
                    library_root_id TEXT NOT NULL,
                    relative_path TEXT NOT NULL,
                    media_kind TEXT NOT NULL,
                    title TEXT NOT NULL,
                    sort_title TEXT NOT NULL,
                    year INTEGER,
                    poster_path TEXT,
                    backdrop_path TEXT,
                    file_size INTEGER NOT NULL,
                    modified_at TEXT NOT NULL,
                    discovered_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    FOREIGN KEY (library_root_id)
                        REFERENCES library_roots(id)
                        ON DELETE CASCADE,
                    UNIQUE (library_root_id, relative_path)
                )
            )SQL"),
            QStringLiteral(
                "CREATE INDEX media_items_sort_title_idx ON media_items(sort_title)"),
            QStringLiteral(
                "CREATE INDEX media_items_root_idx ON media_items(library_root_id)")
        }
    }
};
```

Migration algorithm:

```text
open connection
for each migration in order:
    read PRAGMA user_version, refusing a catalog newer than this build
    skip the migration when the catalog already carries its version
    begin immediate transaction
    re-read PRAGMA user_version inside the write lock, and skip the
        migration when a racing bootstrap already applied it
    execute statements
    set PRAGMA user_version = migration version
    commit
on any failure:
    rollback
    stop startup with a controlled error
once the schema is accepted:
    switch the file to WAL, keeping the previous journal mode and logging
        when another connection blocks the change
```

Never delete the catalog automatically because migration failed.

#### Thread rule

A `QSqlDatabase` connection must be used only from its owning thread. Therefore:

- create the catalog connection inside the catalog worker thread
- execute all queries for that connection in that worker
- return plain value projections to the GUI thread
- never pass a live `QSqlDatabase` or `QSqlQuery` to QML or another thread

---

### 15. Library roots and mount behavior

Do not hard-code `/Volumes`-style assumptions.

A user may configure roots such as:

```text
/mnt/media/Movies
/mnt/media/TV
/run/media/alex/Archive/Movies
/home/alex/Videos
```

Store each root as:

```cpp
struct LibraryRoot
{
    QString id;          // Stable UUID generated once
    QString path;
    QString displayName;
    bool available{false};
};
```

The configured root ID remains stable even if the mounted device details change.
For Pi storage, `LibraryRoot` is the catalog projection of a stable
`StorageSource` plus a relative path; the current absolute `path` remains a
resolved runtime location, not the source identity. A later migration must be
able to relink an SD card or USB drive at a new mount path and reconnect a NAS
after its mount becomes ready.

At scan time:

1. Check whether the root exists and is readable.
2. If missing, mark it unavailable.
3. Preserve its catalog records.
4. Do not treat every item as deleted.
5. Resume normal diffing once the root returns.

User-facing error:

```text
Library unavailable

/mnt/media/Movies is not currently accessible.
The existing catalog has been preserved.
```

---

### 16. Library scanner

The scanner must perform filesystem I/O before opening the apply transaction.

Correct flow:

```text
collect filesystem candidates
        |
        v
compare with catalog snapshot
        |
        v
calculate additions / updates / removals
        |
        v
begin short SQLite transaction
        |
        v
apply diff and commit
```

Do not hold a database write transaction while recursively walking the disk.

#### Supported first-pass extensions

```cpp
bool isSupportedMediaFile(const QFileInfo &file)
{
    static const QSet<QString> extensions{
        QStringLiteral("mp4"),
        QStringLiteral("m4v"),
        QStringLiteral("mov"),
        QStringLiteral("mkv"),
        QStringLiteral("webm"),
        QStringLiteral("avi"),
        QStringLiteral("mpg"),
        QStringLiteral("mpeg"),
        QStringLiteral("ts"),
        QStringLiteral("m2ts"),
        QStringLiteral("vob")
    };

    return extensions.contains(file.suffix().toLower());
}
```

#### Basic candidate collector

```cpp
#include <QDir>
#include <QDirIterator>
#include <QFileInfo>

struct ScanCandidate
{
    QString relativePath;
    QString absolutePath;
    qint64 fileSize{0};
    QDateTime modifiedAt;
};

QVector<ScanCandidate> collectCandidates(const QString &rootPath)
{
    QVector<ScanCandidate> candidates;
    const QDir root(rootPath);

    QDirIterator iterator(
        rootPath,
        QDir::Files | QDir::Readable | QDir::NoDotAndDotDot,
        QDirIterator::Subdirectories);

    while (iterator.hasNext()) {
        iterator.next();
        const QFileInfo file = iterator.fileInfo();

        if (!isSupportedMediaFile(file)) {
            continue;
        }

        candidates.push_back({
            .relativePath = root.relativeFilePath(file.absoluteFilePath()),
            .absolutePath = file.absoluteFilePath(),
            .fileSize = file.size(),
            .modifiedAt = file.lastModified()
        });
    }

    return candidates;
}
```

#### Simple title parsing for the first milestone

```cpp
struct ParsedFilename
{
    QString title;
    int year{0};
};

ParsedFilename parseMovieFilename(const QFileInfo &file)
{
    QString stem = file.completeBaseName();

    const QRegularExpression yearExpression(
        QStringLiteral(
            R"year((?:^|[\s._(\[])(19\d{2}|20\d{2})(?=$|[\s._)\]]))year"));

    int year = 0;
    const QRegularExpressionMatch match = yearExpression.match(stem);
    if (match.hasMatch()) {
        year = match.captured(1).toInt();
        stem.remove(match.capturedStart(), match.capturedLength());
    }

    stem.replace(QRegularExpression(QStringLiteral(R"([._-]+)")),
                 QStringLiteral(" "));
    stem = stem.simplified();

    return {
        .title = stem,
        .year = year
    };
}
```

Do not spend weeks perfecting filename parsing before real items can appear in the UI. Add parser rules from actual failures and keep them tested.

#### Worker-object pattern

```cpp
class CatalogWorker final : public QObject
{
    Q_OBJECT

public:
    explicit CatalogWorker(QString databasePath);

public slots:
    void initialize();
    void scanRoots(const QVector<LibraryRoot> &roots);

signals:
    void projectionReady(QVector<MediaItem> items);
    void scanFailed(QString userMessage, QString technicalDetail);

private:
    QString m_databasePath;
    std::unique_ptr<CatalogDatabase> m_database;
};
```

Wiring:

```cpp
m_catalogWorker = new CatalogWorker(databasePath);
m_catalogWorker->moveToThread(&m_catalogThread);

connect(&m_catalogThread,
        &QThread::started,
        m_catalogWorker,
        &CatalogWorker::initialize);

connect(&m_catalogThread,
        &QThread::finished,
        m_catalogWorker,
        &QObject::deleteLater);

connect(m_catalogWorker,
        &CatalogWorker::projectionReady,
        m_libraryModel,
        &LibraryModel::replaceItems,
        Qt::QueuedConnection);

m_catalogThread.start();
```

The worker must have no parent before `moveToThread()`.

Register the queued projection type once during startup, before making the
cross-thread connection:

```cpp
qRegisterMetaType<QVector<MediaItem>>("QVector<MediaItem>");
```

---

### 17. Exposing catalog data to QML

Use `QAbstractListModel` rather than passing arrays of `QVariantMap` for the main library.

`src/models/LibraryModel.hpp`:

```cpp
#pragma once

#include <QAbstractListModel>
#include <QVector>

#include "catalog/MediaItem.hpp"

class LibraryModel final : public QAbstractListModel
{
    Q_OBJECT

public:
    enum Role {
        IdRole = Qt::UserRole + 1,
        TitleRole,
        YearRole,
        KindRole,
        PosterUrlRole
    };
    Q_ENUM(Role)

    explicit LibraryModel(QObject *parent = nullptr);

    int rowCount(const QModelIndex &parent = QModelIndex{}) const override;
    QVariant data(const QModelIndex &index, int role) const override;
    QHash<int, QByteArray> roleNames() const override;

    Q_INVOKABLE QVariantMap get(int index) const;
    [[nodiscard]] const MediaItem *itemAt(int index) const;

public slots:
    void replaceItems(QVector<MediaItem> items);

private:
    QVector<MediaItem> m_items;
};
```

`src/models/LibraryModel.cpp`:

```cpp
#include "models/LibraryModel.hpp"

LibraryModel::LibraryModel(QObject *parent)
    : QAbstractListModel(parent)
{
}

int LibraryModel::rowCount(const QModelIndex &parent) const
{
    return parent.isValid() ? 0 : m_items.size();
}

QVariant LibraryModel::data(const QModelIndex &index, int role) const
{
    if (!index.isValid() || index.row() < 0 || index.row() >= m_items.size()) {
        return {};
    }

    const MediaItem &item = m_items.at(index.row());

    switch (role) {
    case IdRole:
        return item.id;
    case TitleRole:
        return item.title;
    case YearRole:
        return item.year;
    case KindRole:
        return item.kind;
    case PosterUrlRole:
        return item.posterUrl();
    default:
        return {};
    }
}

QHash<int, QByteArray> LibraryModel::roleNames() const
{
    return {
        {IdRole, "mediaId"},
        {TitleRole, "title"},
        {YearRole, "year"},
        {KindRole, "mediaKind"},
        {PosterUrlRole, "posterUrl"}
    };
}

void LibraryModel::replaceItems(QVector<MediaItem> items)
{
    beginResetModel();
    m_items = std::move(items);
    endResetModel();
}

const MediaItem *LibraryModel::itemAt(int index) const
{
    if (index < 0 || index >= m_items.size()) {
        return nullptr;
    }
    return &m_items.at(index);
}

QVariantMap LibraryModel::get(int index) const
{
    const MediaItem *item = itemAt(index);
    if (!item) {
        return {};
    }

    return {
        {QStringLiteral("mediaId"), item->id},
        {QStringLiteral("title"), item->title},
        {QStringLiteral("year"), item->year},
        {QStringLiteral("posterUrl"), item->posterUrl()}
    };
}
```

`replaceItems()` must execute on the model's GUI thread. The queued connection from the catalog worker provides that boundary.

---

### 18. Application controller

Keep this class thin. It composes services and translates high-level UI intent. It should not become a second database, router, player, and scanner implementation in one class.

`src/app/ApplicationController.hpp`:

```cpp
#pragma once

#include <QObject>
#include <QString>

#include "models/LibraryModel.hpp"
#include "navigation/NavigationController.hpp"
#include "playback/PlayerController.hpp"

class ApplicationController final : public QObject
{
    Q_OBJECT

    Q_PROPERTY(LibraryModel *libraryModel
               READ libraryModel
               CONSTANT)

    Q_PROPERTY(NavigationController *navigation
               READ navigation
               CONSTANT)

    Q_PROPERTY(PlayerController *player
               READ player
               CONSTANT)

    Q_PROPERTY(bool startFullscreen
               READ startFullscreen
               WRITE setStartFullscreen
               NOTIFY startFullscreenChanged)

public:
    explicit ApplicationController(QObject *parent = nullptr);

    LibraryModel *libraryModel();
    NavigationController *navigation();
    PlayerController *player();

    bool startFullscreen() const;
    void setStartFullscreen(bool value);

    void setTemporaryLibraryRoot(const QString &path);

    Q_INVOKABLE void scanLibraries();
    Q_INVOKABLE void playIndex(int index);
    Q_INVOKABLE void showDetails(int index);

signals:
    void startFullscreenChanged();
    void errorRaised(QString title, QString message);

private:
    LibraryModel m_libraryModel;
    NavigationController m_navigation;
    PlayerController m_player;
    bool m_startFullscreen{true};
};
```

Intent translation:

```cpp
void ApplicationController::playIndex(int index)
{
    const MediaItem *item = m_libraryModel.itemAt(index);
    if (!item) {
        emit errorRaised(
            QStringLiteral("Unable to play"),
            QStringLiteral("The selected media item no longer exists."));
        return;
    }

    m_player.prepare(item->absolutePath, item->title);
    m_navigation.openPlayer(item->id);
}
```

Do not pass `absolutePath` directly from arbitrary QML code into the player. Let C++ resolve a selected media ID or validated model index.

---

### 19. Navigation controller

Use an explicit route enum.

`src/navigation/NavigationController.hpp`:

```cpp
#pragma once

#include <QObject>
#include <QString>
#include <QVector>

class NavigationController final : public QObject
{
    Q_OBJECT

public:
    enum class Route {
        ProfilePicker,
        Home,
        Library,
        Search,
        Details,
        Player,
        Settings
    };
    Q_ENUM(Route)

    Q_PROPERTY(Route route READ route NOTIFY routeChanged)
    Q_PROPERTY(QString selectedMediaId
               READ selectedMediaId
               NOTIFY selectedMediaIdChanged)

    explicit NavigationController(QObject *parent = nullptr);

    Route route() const;
    QString selectedMediaId() const;

    Q_INVOKABLE void goHome();
    Q_INVOKABLE void goBack();
    Q_INVOKABLE void openDetails(const QString &mediaId);
    Q_INVOKABLE void openPlayer(const QString &mediaId);

signals:
    void routeChanged();
    void selectedMediaIdChanged();

private:
    Route m_route{Route::Home};
    QString m_selectedMediaId;
    QVector<Route> m_history;
};
```

Persist logical restoration targets separately from pixels:

```cpp
struct FocusTarget
{
    QString surfaceId;  // "home", "search", "details"
    QString sectionId;  // "recently-added"
    QString mediaId;
    int fallbackIndex{0};
};
```

When returning to a surface:

1. Find the stored `mediaId` in the current projection.
2. Fall back to the stored index if the item disappeared.
3. Clamp to valid bounds.
4. Set the view's logical index.
5. Ask the view to reveal that index once.

Do not run timer-based correction loops.

---

### 20. QML foundation

#### Theme singleton

`qml/Theme.qml`:

```qml
pragma Singleton

import QtQuick

QtObject {
    readonly property color background: "#0b0d12"
    readonly property color panel: "#151923"
    readonly property color textPrimary: "#f4f6fb"
    readonly property color textSecondary: "#aab1c0"
    readonly property color accent: "#f1c75b"
    readonly property color focusRing: "#ffffff"

    readonly property int radiusSmall: 8
    readonly property int radiusMedium: 14
    readonly property int radiusLarge: 22

    readonly property int spacingSmall: 8
    readonly property int spacingMedium: 16
    readonly property int spacingLarge: 28

    readonly property int motionFast: 110
    readonly property int motionNormal: 180

    readonly property real posterAspect: 2.0 / 3.0
}
```

Replace colors and typography with Marquee's final visual language later. Centralize them now so visual changes are not spread across every component.

#### Main window

`qml/Main.qml`:

```qml
import QtQuick
import QtQuick.Controls
import Marquee

ApplicationWindow {
    id: window

    width: 1920
    height: 1080
    visible: true
    color: Theme.background
    title: qsTr("Marquee")

    Component.onCompleted: {
        if (appController.startFullscreen)
            showFullScreen()
    }

    Shortcut {
        sequence: "F11"
        onActivated: {
            if (window.visibility === Window.FullScreen)
                window.showNormal()
            else
                window.showFullScreen()
        }
    }

    Loader {
        id: screenLoader
        anchors.fill: parent

        sourceComponent: {
            switch (appController.navigation.route) {
            case NavigationController.Home:
                return homeScreen
            case NavigationController.Player:
                return playerScreen
            default:
                return homeScreen
            }
        }
    }

    Component {
        id: homeScreen
        HomeScreen { }
    }

    Component {
        id: playerScreen
        PlayerScreen { }
    }

    Connections {
        target: appController

        function onErrorRaised(title, message) {
            console.error(title + ": " + message)
            // Replace this with ErrorToast once added.
        }
    }
}
```

---

### 21. Poster card

`qml/components/PosterCard.qml`:

```qml
import QtQuick
import Marquee

Item {
    id: root

    required property string title
    required property url posterUrl
    property bool selected: false
    property bool reduceMotion: false

    signal activated()

    width: 240
    height: 400

    Rectangle {
        id: card

        anchors.horizontalCenter: parent.horizontalCenter
        width: 220
        height: width / Theme.posterAspect
        radius: Theme.radiusMedium
        color: Theme.panel
        clip: true

        scale: root.selected ? 1.065 : 1.0

        border.width: root.selected ? 4 : 0
        border.color: Theme.focusRing

        Image {
            anchors.fill: parent
            source: root.posterUrl
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            cache: true
        }

        Behavior on scale {
            enabled: !root.reduceMotion
            NumberAnimation {
                duration: Theme.motionFast
                easing.type: Easing.OutCubic
            }
        }
    }

    Text {
        anchors.top: card.bottom
        anchors.topMargin: Theme.spacingSmall
        anchors.horizontalCenter: card.horizontalCenter
        width: card.width

        text: root.title
        color: Theme.textPrimary
        font.pixelSize: 22
        font.weight: root.selected ? Font.DemiBold : Font.Normal
        elide: Text.ElideRight
        horizontalAlignment: Text.AlignHCenter
    }

    TapHandler {
        onTapped: root.activated()
    }
}
```

The visible selection state is driven by one logical selected item. Do not let hover and keyboard focus independently claim ownership of the focus ring.

---

### 22. First home/library screen

For the first vertical slice, a single `GridView` is enough.

`qml/screens/HomeScreen.qml`:

```qml
import QtQuick
import QtQuick.Controls
import Marquee

FocusScope {
    id: root

    focus: true

    Rectangle {
        anchors.fill: parent
        color: Theme.background
    }

    Text {
        id: heading

        anchors.left: parent.left
        anchors.leftMargin: 72
        anchors.top: parent.top
        anchors.topMargin: 42

        text: qsTr("Library")
        color: Theme.textPrimary
        font.pixelSize: 44
        font.weight: Font.DemiBold
    }

    GridView {
        id: grid

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: heading.bottom
        anchors.bottom: parent.bottom
        anchors.margins: 56

        focus: true
        clip: true
        model: appController.libraryModel

        cellWidth: 260
        cellHeight: 420
        keyNavigationWraps: false
        boundsBehavior: Flickable.StopAtBounds

        delegate: PosterCard {
            required property int index

            title: model.title
            posterUrl: model.posterUrl
            selected: GridView.isCurrentItem

            onActivated: appController.playIndex(index)
        }

        Keys.onLeftPressed: event => {
            if (currentIndex > 0)
                currentIndex -= 1
            event.accepted = true
        }

        Keys.onRightPressed: event => {
            if (currentIndex + 1 < count)
                currentIndex += 1
            event.accepted = true
        }

        Keys.onUpPressed: event => {
            const columns = Math.max(1, Math.floor(width / cellWidth))
            currentIndex = Math.max(0, currentIndex - columns)
            event.accepted = true
        }

        Keys.onDownPressed: event => {
            const columns = Math.max(1, Math.floor(width / cellWidth))
            currentIndex = Math.min(count - 1, currentIndex + columns)
            event.accepted = true
        }

        Keys.onReturnPressed: event => {
            if (currentIndex >= 0)
                appController.playIndex(currentIndex)
            event.accepted = true
        }

        Keys.onEnterPressed: event => {
            if (currentIndex >= 0)
                appController.playIndex(currentIndex)
            event.accepted = true
        }

        onCurrentIndexChanged: {
            if (currentIndex >= 0)
                positionViewAtIndex(currentIndex, GridView.Contain)
        }

        onCountChanged: {
            if (count > 0 && currentIndex < 0)
                currentIndex = 0
        }

        Component.onCompleted: {
            if (count > 0)
                currentIndex = 0
            forceActiveFocus()
        }
    }
}
```

This is intentionally explicit. Once the layout becomes rows rather than one grid, move cross-row focus restoration into a controller instead of building increasingly complex coordinate inference in QML.

---

### 23. Focus and remote input strategy

#### Input map for the first build

| Input | Action |
|---|---|
| Left/Right/Up/Down | Move logical focus |
| Enter / Return | Activate |
| Escape / Back | Navigate back or close overlay |
| Space / media play-pause | Toggle playback |
| F11 | Toggle fullscreen during development |
| Volume keys | Let the desktop handle system volume initially |

#### Rules

- Each active surface has exactly one logical focus target.
- Opening an overlay moves focus into the overlay.
- Closing the overlay restores the previous logical target.
- `Escape` must never become trapped in a child component.
- A route transition cancels stale delayed focus work.
- Home and non-home browse surfaces use the same focus-following horizontal and
  vertical motion. Viewport placement follows the logical focus target and
  settles on the identical offset on every surface; Reduce Motion replaces the
  interpolation with immediate placement and the same final target.
- Never use arbitrary sleeps to “wait for focus.”
- Do not store `QModelIndex` objects across model resets; store media IDs.

#### Nested row model

For a mature home screen, represent focus as:

```cpp
struct BrowseFocus
{
    int row{0};
    int column{0};
    QString mediaId;
};
```

Movement:

```text
Left:  column - 1, clamped
Right: column + 1, clamped
Up:    previous row; restore that row's remembered column
Down:  next row; restore that row's remembered column
```

Keep a remembered column per row so moving down and back up feels stable.

#### Media remotes

Start with keyboard-compatible remotes. Many USB and HDMI remotes already emit keyboard or media-key events.

Only add lower-level input libraries after identifying a real unsupported device. Possible later options include:

- Qt Gamepad alternatives or SDL for controllers
- direct evdev/libinput integration for specialized remotes
- MPRIS for desktop media-control integration

Do not add all three before the basic keyboard path is excellent.

---

### 24. Playback architecture

Use one normal playback backend:

```text
MP4 / MKV / MOV / WebM / AVI / TS / VOB / subtitles
                         |
                         v
                       libmpv
                         |
               video + audio + tracks
```

Do not recreate the macOS AVFoundation/embedded-ffmpeg routing unless a Linux-specific failure proves it is necessary.

#### Player-facing API and spike ownership

Use two steps so the render experiment stays small and the eventual architecture stays clean.

During the **technology spike**, let `MpvVideoItem` own the libmpv handle, render context, and direct playback commands. `PlayerController` is only the durable playback selection/session shell used by the rest of the app:

```cpp
#include <QObject>
#include <QUrl>

class PlayerController final : public QObject
{
    Q_OBJECT

    Q_PROPERTY(QUrl currentFileUrl
               READ currentFileUrl
               NOTIFY currentFileUrlChanged)
    Q_PROPERTY(QString title READ title NOTIFY titleChanged)

public:
    explicit PlayerController(QObject *parent = nullptr);

    QUrl currentFileUrl() const;
    QString title() const;

    // C++ application intent, not an arbitrary QML file loader.
    void prepare(const QString &validatedLocalPath, const QString &title);

signals:
    void currentFileUrlChanged();
    void titleChanged();

private:
    QUrl m_currentFileUrl;
    QString m_title;
};
```

A minimal session-shell implementation is:

```cpp
PlayerController::PlayerController(QObject *parent)
    : QObject(parent)
{
}

QUrl PlayerController::currentFileUrl() const
{
    return m_currentFileUrl;
}

QString PlayerController::title() const
{
    return m_title;
}

void PlayerController::prepare(const QString &validatedLocalPath,
                               const QString &title)
{
    const QUrl nextUrl = QUrl::fromLocalFile(validatedLocalPath);

    if (m_currentFileUrl != nextUrl) {
        m_currentFileUrl = nextUrl;
        emit currentFileUrlChanged();
    }

    if (m_title != title) {
        m_title = title;
        emit titleChanged();
    }
}
```

After the renderer spike is proven, move the libmpv handle and durable playback state behind `PlayerController` (or a non-QObject `MpvCore` owned by it). At that point the public API should grow to include:

```cpp
Q_PROPERTY(bool loaded READ loaded NOTIFY loadedChanged)
Q_PROPERTY(bool paused READ paused NOTIFY pausedChanged)
Q_PROPERTY(double positionSeconds
           READ positionSeconds
           NOTIFY positionSecondsChanged)
Q_PROPERTY(double durationSeconds
           READ durationSeconds
           NOTIFY durationSecondsChanged)
Q_PROPERTY(QString errorMessage
           READ errorMessage
           NOTIFY errorMessageChanged)

Q_INVOKABLE void play();
Q_INVOKABLE void pause();
Q_INVOKABLE void togglePause();
Q_INVOKABLE void stop();
Q_INVOKABLE void seekAbsolute(double seconds);
Q_INVOKABLE void seekRelative(double deltaSeconds);
```

The production `MpvVideoItem` should then become a rendering surface for that shared core rather than a second independent player. Do not keep two libmpv handles for one playback session.

#### Player HUD control contract

- **Restart** is a remote-focusable HUD control. Down moves the remote off the
  picture onto it, Up hands it back, and Enter or a tap seeks the open file to
  its first frame without reloading. The HUD's auto-hide must not hide a control
  that is holding the remote.
- **Next Episode** is a remote-focusable HUD control that exists only when the
  playing item has an ordered successor. Films and final episodes must not leave
  a dead focus target, and directional traversal skips controls that are not
  present. The successor is `show_order::nextEpisodeIndexAfter` (aired order,
  across seasons, skipping copies of the same episode), shared with Home's and
  the show page's ordering. It sits after +30, and it starts the next episode
  at that episode's own saved position.
- **Next-episode card** (`NextEpisodeCard`, `AutoPlayPolicy`): only for an
  episode of 10 minutes or more that has a next one, with Auto-play Next
  Episode on. It appears 30 s before the end (35 s from 40 minutes, 40 s from
  50), shows the next title and "Next episode in N" counting down to the end of
  the file, with Play Now (takes the remote) and Hide. Hide holds for the rest
  of the episode; seeking back removes the card and reaching the lead time shows
  it again. Back closes a menu, then the card, then the HUD, then leaves.
- **Still watching?** After three episodes in a row started by auto-play and 90
  minutes without a remote key or pointer input, the next end shows Continue
  (focused) and Stop instead of starting an episode; any input resets both
  counts (`still_watching::isDue` with `StillWatchingTracker`'s injectable
  clock). The end of the last episode returns to the show page.
- **Transport keys** follow the released app (`PlayerView.swift:299-358`,
  `:453-523`): Left taps -10 s and Right +30 s, a hold over 0.5 s scrubs with
  the film paused (1 s per 0.1 s tick for ten ticks, then 2 s to the 25th, 5 s
  to the 45th, then 10 s) and a release seeks and resumes; S, F, M, `[` and `]`
  toggle subtitles, fullscreen and mute and step the speed. `SeekScrubber`
  owns the timing against an injectable clock; the screen carries the result
  out. Volume, mute and speed are libmpv's own and start over (100, unmuted,
  1x) with every file; nothing stores them, as in the released app.
- **Back** hides a visible HUD (an open menu closes first); with the HUD hidden
  it leaves the player. The HUD's close control leaves at once.
- Resume points are written only from 120 s into a title and never for a title
  under five minutes; a stop before that leaves the older point unchanged.
- Hardware Decoding applies to the running player, not only the next file. A
  rejected change keeps the previous value and logs a warning without failing
  the session.

#### Highest-risk technical spike

Before building the full catalog UI, prove this exact behavior on the target Omarchy machine:

1. Qt Quick window starts under native Wayland.
2. Qt Quick uses OpenGL through EGL.
3. libmpv renders a local 4K sample into a Qt Quick item.
4. QML text and controls render over the video.
5. Pause, seek, audio track, and subtitle track changes work.
6. Fullscreen survives repeated entry/exit.
7. Playback survives closing and loading a second file.
8. No crash occurs during item/window teardown.
9. Hardware decoding works on the theater GPU.
10. Audio uses the expected PipeWire output.

Do not defer this spike. It decides whether the chosen render bridge is acceptable.

---

### 25. Recommended libmpv render path for version one

#### Why OpenGL first

Qt's `QQuickFramebufferObject` is OpenGL-only and considered a legacy convenience class, but it remains the shortest, clearest route to a working libmpv-backed QML video surface.

For the Omarchy-first build:

- force Qt Quick to OpenGL
- use libmpv's render API
- render into the current Qt Quick framebuffer object
- place QML controls over the resulting item

This is a pragmatic product decision, not a claim that OpenGL is Qt's long-term universal rendering architecture.

A later renderer can investigate `QQuickRhiItem` or a custom scene-graph texture path. Do not block the usable application on that future optimization.

#### Do not use X11-style window embedding

Avoid a design based on handing mpv a foreign window ID. Generic child-window embedding is not a dependable Wayland architecture and makes QML overlays difficult.

Use the libmpv render API instead.

#### Minimal `MpvVideoItem` shape

`src/playback/MpvVideoItem.hpp`:

```cpp
#pragma once

#include <QQuickFramebufferObject>
#include <QString>
#include <QUrl>

struct mpv_handle;
struct mpv_render_context;

class MpvVideoItem final : public QQuickFramebufferObject
{
    Q_OBJECT

    Q_PROPERTY(QUrl source READ source WRITE setSource NOTIFY sourceChanged)
    Q_PROPERTY(bool paused READ paused NOTIFY pausedChanged)
    Q_PROPERTY(double position READ position NOTIFY positionChanged)
    Q_PROPERTY(double duration READ duration NOTIFY durationChanged)
    Q_PROPERTY(QString errorMessage
               READ errorMessage
               NOTIFY errorMessageChanged)

public:
    explicit MpvVideoItem(QQuickItem *parent = nullptr);
    ~MpvVideoItem() override;

    Renderer *createRenderer() const override;

    QUrl source() const;
    void setSource(const QUrl &source);

    bool paused() const;
    double position() const;
    double duration() const;
    QString errorMessage() const;

    Q_INVOKABLE void loadFile(const QUrl &fileUrl);
    Q_INVOKABLE void play();
    Q_INVOKABLE void pause();
    Q_INVOKABLE void togglePause();
    Q_INVOKABLE void stop();
    Q_INVOKABLE void seek(double seconds);

signals:
    void sourceChanged();
    void pausedChanged();
    void positionChanged();
    void durationChanged();
    void errorMessageChanged();
    void playbackEnded();

private slots:
    void drainEvents();
    void requestFrameUpdate();

private:
    static void wakeupCallback(void *context);
    static void renderUpdateCallback(void *context);

    void setError(QString message);

    // The QQuickFramebufferObject::Renderer owns the render context on
    // Qt Quick's render thread. The item owns only the libmpv client handle.
    mpv_handle *m_mpv{nullptr};

    QUrl m_source;
    bool m_paused{false};
    double m_position{0.0};
    double m_duration{0.0};
    QString m_errorMessage;
};
```

Initialization sequence:

```cpp
MpvVideoItem::MpvVideoItem(QQuickItem *parent)
    : QQuickFramebufferObject(parent)
{
    setMirrorVertically(false);

    m_mpv = mpv_create();
    if (!m_mpv) {
        throw std::runtime_error("mpv_create failed");
    }

    mpv_set_option_string(m_mpv, "config", "no");
    mpv_set_option_string(m_mpv, "terminal", "no");
    mpv_set_option_string(m_mpv, "input-default-bindings", "no");
    mpv_set_option_string(m_mpv, "input-vo-keyboard", "no");
    mpv_set_option_string(m_mpv, "vo", "libmpv");
    mpv_set_option_string(m_mpv, "hwdec", "auto-safe");
    mpv_set_option_string(m_mpv, "keep-open", "yes");

    if (mpv_initialize(m_mpv) < 0) {
        mpv_terminate_destroy(m_mpv);
        m_mpv = nullptr;
        throw std::runtime_error("mpv_initialize failed");
    }

    mpv_observe_property(m_mpv, 1, "pause", MPV_FORMAT_FLAG);
    mpv_observe_property(m_mpv, 2, "time-pos", MPV_FORMAT_DOUBLE);
    mpv_observe_property(m_mpv, 3, "duration", MPV_FORMAT_DOUBLE);

    mpv_set_wakeup_callback(m_mpv, &MpvVideoItem::wakeupCallback, this);
}
```

Event callback pattern:

```cpp
void MpvVideoItem::wakeupCallback(void *context)
{
    auto *self = static_cast<MpvVideoItem *>(context);

    // The callback may come from an mpv thread. Queue work to the item's thread.
    QMetaObject::invokeMethod(
        self,
        [self] { self->drainEvents(); },
        Qt::QueuedConnection);
}

void MpvVideoItem::drainEvents()
{
    if (!m_mpv) {
        return;
    }

    while (true) {
        mpv_event *event = mpv_wait_event(m_mpv, 0.0);
        if (!event || event->event_id == MPV_EVENT_NONE) {
            break;
        }

        if (event->event_id == MPV_EVENT_PROPERTY_CHANGE) {
            auto *property = static_cast<mpv_event_property *>(event->data);
            if (!property || !property->name) {
                continue;
            }

            const QByteArray name(property->name);

            if (name == "pause" &&
                property->format == MPV_FORMAT_FLAG &&
                property->data) {
                const bool value =
                    *static_cast<int *>(property->data) != 0;

                if (m_paused != value) {
                    m_paused = value;
                    emit pausedChanged();
                }
            }

            if (name == "time-pos" &&
                property->format == MPV_FORMAT_DOUBLE &&
                property->data) {
                m_position = *static_cast<double *>(property->data);
                emit positionChanged();
            }

            if (name == "duration" &&
                property->format == MPV_FORMAT_DOUBLE &&
                property->data) {
                m_duration = *static_cast<double *>(property->data);
                emit durationChanged();
            }
        }

        if (event->event_id == MPV_EVENT_END_FILE) {
            emit playbackEnded();
        }

        if (event->event_id == MPV_EVENT_SHUTDOWN) {
            break;
        }
    }
}
```

Source binding and command example:

```cpp
void MpvVideoItem::setSource(const QUrl &source)
{
    if (m_source == source) {
        return;
    }

    m_source = source;
    emit sourceChanged();

    if (!m_source.isEmpty()) {
        loadFile(m_source);
    }
}

void MpvVideoItem::loadFile(const QUrl &fileUrl)
{
    if (!m_mpv || !fileUrl.isLocalFile()) {
        setError(QStringLiteral("Playback requires a valid local file."));
        return;
    }

    const QByteArray path = fileUrl.toLocalFile().toUtf8();
    const char *command[] = {
        "loadfile",
        path.constData(),
        "replace",
        nullptr
    };

    const int result = mpv_command(m_mpv, command);
    if (result < 0) {
        setError(QString::fromUtf8(mpv_error_string(result)));
    }
}
```

Pause example:

```cpp
void MpvVideoItem::pause()
{
    int value = 1;
    const int result = mpv_set_property(
        m_mpv, "pause", MPV_FORMAT_FLAG, &value);

    if (result < 0) {
        setError(QString::fromUtf8(mpv_error_string(result)));
    }
}
```

Renderer responsibilities:

```text
create framebuffer
    |
    v
obtain current QOpenGLContext function resolver
    |
    v
create mpv_render_context using MPV_RENDER_API_TYPE_OPENGL
    |
    v
register mpv render-update callback
    |
    v
on render(): pass current FBO dimensions/handle to mpv
    |
    v
call mpv_render_context_render()
```

The `QQuickFramebufferObject::Renderer` should create, own, and destroy the
`mpv_render_context` on Qt Quick's render thread. The `MpvVideoItem` owns the
`mpv_handle` and queues events back to its GUI thread. Follow Qt Quick's
scene-graph thread rules strictly, and do not read or mutate ordinary item
properties directly from the renderer without using `synchronize()`.

The essential render call is shaped like:

```cpp
QOpenGLFramebufferObject *target = framebufferObject();

mpv_opengl_fbo mpvTarget{
    .fbo = static_cast<int>(target->handle()),
    .w = target->width(),
    .h = target->height(),
    .internal_format = 0
};

int flipY = 0;

mpv_render_param parameters[] = {
    {MPV_RENDER_PARAM_OPENGL_FBO, &mpvTarget},
    {MPV_RENDER_PARAM_FLIP_Y, &flipY},
    {MPV_RENDER_PARAM_INVALID, nullptr}
};

mpv_render_context_render(renderContext, parameters);
```

Use the official `mpv-examples/libmpv/qml` sample and Qt's `QQuickFramebufferObject` documentation as references while implementing the complete renderer. Do not copy an old Qt 5 example blindly; adapt lifecycle and graphics-API setup deliberately for Qt 6.

#### Teardown order

The safe conceptual order is:

```text
stop issuing QML commands
remove mpv callbacks
free mpv render context on render thread
terminate/destroy mpv handle
release QML item
```

Test repeated create/destroy cycles. Teardown bugs often remain hidden when the app only exits once.

---

### 26. Player screen example

`qml/screens/PlayerScreen.qml`:

```qml
import QtQuick
import QtQuick.Controls
import Marquee
import Marquee.Playback 1.0

FocusScope {
    id: root

    focus: true

    MpvVideo {
        id: video
        anchors.fill: parent
        source: appController.player.currentFileUrl
    }

    Rectangle {
        id: controlsScrim

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: 210

        color: "#b0000000"
        visible: controlsVisible

        property bool controlsVisible: true

        Column {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.margins: 48
            spacing: 16

            Text {
                text: appController.player.title
                color: Theme.textPrimary
                font.pixelSize: 30
                font.weight: Font.DemiBold
            }

            Slider {
                id: progress

                from: 0
                to: Math.max(1, video.duration)
                value: video.position

                onMoved: video.seek(value)
            }

            Row {
                spacing: 22

                Button {
                    text: video.paused ? qsTr("Play") : qsTr("Pause")
                    onClicked: video.togglePause()
                }

                Button {
                    text: qsTr("Back 10s")
                    onClicked: video.seek(Math.max(0, video.position - 10))
                }

                Button {
                    text: qsTr("Forward 30s")
                    onClicked: video.seek(video.position + 30)
                }
            }
        }
    }

    Keys.onSpacePressed: event => {
        video.togglePause()
        event.accepted = true
    }

    Keys.onEscapePressed: event => {
        video.stop()
        appController.navigation.goBack()
        event.accepted = true
    }

    Keys.onLeftPressed: event => {
        video.seek(Math.max(0, video.position - 10))
        controlsScrim.controlsVisible = true
        hideControls.restart()
        event.accepted = true
    }

    Keys.onRightPressed: event => {
        video.seek(video.position + 30)
        controlsScrim.controlsVisible = true
        hideControls.restart()
        event.accepted = true
    }

    Timer {
        id: hideControls
        interval: 3500
        repeat: false
        onTriggered: controlsScrim.controlsVisible = false
    }

    Component.onCompleted: {
        forceActiveFocus()
        hideControls.start()
    }
}
```

For the final player, do not let seeking fire continuously from every slider visual update. Distinguish between displayed progress and a committed user seek.

---

### 27. Tracks and subtitles

Ask mpv for its `track-list` property and convert it into a Qt model.

Expose roles such as:

```text
trackId
trackType       audio / sub / video
title
language
selected
external
```

Commands:

```cpp
void PlayerController::selectAudioTrack(int mpvTrackId)
{
    const QByteArray value = QByteArray::number(mpvTrackId);
    mpv_set_property_string(m_mpv, "aid", value.constData());
}

void PlayerController::selectSubtitleTrack(int mpvTrackId)
{
    const QByteArray value = QByteArray::number(mpvTrackId);
    mpv_set_property_string(m_mpv, "sid", value.constData());
}
```

Disable subtitles:

```cpp
mpv_set_property_string(m_mpv, "sid", "no");
```

Let mpv discover embedded and conventional sidecar subtitles. Add Marquee-specific sidecar rules only when the default behavior is insufficient.

Initial settings:

```text
preferred audio language
preferred subtitle language
subtitles enabled by default
audio output override
hardware decoding override
```

Do not make advanced passthrough settings a first-milestone blocker.

---

### 28. Watch progress

Save progress:

- every 10 seconds while playing
- on pause
- after a committed seek
- before loading a different item
- when leaving the player
- during controlled shutdown

Do not write on every frame or every `time-pos` event.

Example debounce timer:

```cpp
m_progressTimer.setInterval(10'000);
m_progressTimer.setSingleShot(false);

connect(&m_progressTimer,
        &QTimer::timeout,
        this,
        &PlayerController::persistProgress);
```

Completion rule example:

```cpp
bool shouldMarkCompleted(qint64 positionMs, qint64 durationMs)
{
    if (durationMs <= 0) {
        return false;
    }

    const double ratio =
        static_cast<double>(positionMs) /
        static_cast<double>(durationMs);

    return ratio >= 0.90 || durationMs - positionMs <= 5 * 60 * 1000;
}
```

Treat this as product policy and test it. Do not bury it in a QML expression.

---

### 29. Artwork

Resolution order:

```text
explicit local sidecar
        |
folder-level local sidecar
        |
existing cached remote artwork
        |
optional metadata-provider artwork
        |
placeholder
```

Suggested local names:

```text
Movie Name (2024).mkv
Movie Name (2024)-poster.jpg
Movie Name (2024)-backdrop.jpg
poster.jpg
folder.jpg
fanart.jpg
backdrop.jpg
```

First-pass resolver:

```cpp
QString findPosterFor(const QFileInfo &mediaFile)
{
    const QDir directory = mediaFile.dir();
    const QString stem = mediaFile.completeBaseName();

    const QStringList candidates{
        directory.filePath(stem + QStringLiteral("-poster.jpg")),
        directory.filePath(stem + QStringLiteral("-poster.png")),
        directory.filePath(QStringLiteral("poster.jpg")),
        directory.filePath(QStringLiteral("folder.jpg")),
        directory.filePath(QStringLiteral("poster.png"))
    };

    for (const QString &candidate : candidates) {
        if (QFileInfo::exists(candidate)) {
            return candidate;
        }
    }

    return {};
}
```

For the first milestone, local `file://` URLs with `Image.asynchronous: true` are sufficient.

Later, add a `QQuickAsyncImageProvider` so Marquee can:

- decode off the GUI thread
- resize to requested display size
- cache decoded thumbnails
- avoid loading a 5000-pixel poster for a 220-pixel card

Use a cache key based on:

```text
source file path + source modified time + requested size + transform version
```

Never overwrite the user's sidecar files.

---

### 30. Search

Keep search local.

Phase one:

```sql
SELECT id, title, year, poster_path
FROM media_items
WHERE title LIKE '%' || :query || '%'
ORDER BY sort_title
LIMIT 100;
```

Phase two: SQLite FTS5.

```sql
CREATE VIRTUAL TABLE media_search USING fts5(
    media_id UNINDEXED,
    title,
    original_title,
    people,
    genres,
    series_title,
    episode_title,
    tokenize = 'unicode61 remove_diacritics 2'
);
```

Keep snapshot construction and ranking outside QML.

Search concurrency rule:

- assign each query a monotonically increasing request ID
- cancel or ignore results from older requests
- never let a delayed old query overwrite a newer result set

```cpp
const quint64 requestId = ++m_latestSearchRequest;

// In completion handler:
if (requestId != m_latestSearchRequest) {
    return;
}
```

This protects the same class of stale-result focus problems that remote-heavy interfaces often expose.

---

### 31. Profiles

Profiles are local in the first release.

Store:

- profile ID
- name
- avatar selection
- favorites
- watch progress
- watch history
- preferences
- later taste signals

Do not duplicate media rows for each profile. Store profile-to-media state separately.

Example tables:

```sql
CREATE TABLE profile_media_state (
    profile_id      TEXT NOT NULL,
    media_id        TEXT NOT NULL,
    favorite        INTEGER NOT NULL DEFAULT 0,
    hidden          INTEGER NOT NULL DEFAULT 0,
    last_watched_at TEXT,
    play_count      INTEGER NOT NULL DEFAULT 0,

    PRIMARY KEY (profile_id, media_id),

    FOREIGN KEY (profile_id)
        REFERENCES profiles(id)
        ON DELETE CASCADE,

    FOREIGN KEY (media_id)
        REFERENCES media_items(id)
        ON DELETE CASCADE
);
```

The active profile belongs to `ProfileController`, not individual screens.

---

### 32. Metadata/TMDB

Implement this after local browsing, details, search, and playback work.

Use `QNetworkAccessManager` owned by the metadata service's thread or the GUI thread. Its API is asynchronous; do not wrap it in blocking waits.

Service boundary:

```cpp
class MetadataService final : public QObject
{
    Q_OBJECT

public:
    explicit MetadataService(QObject *parent = nullptr);

    void enrichMovie(const QString &mediaId,
                     const QString &title,
                     int year);

signals:
    void enrichmentReady(QString mediaId, MetadataPatch patch);
    void enrichmentFailed(QString mediaId, QString technicalDetail);

private:
    QNetworkAccessManager m_network;
};
```

Rules:

- local title/path data remains usable if enrichment fails
- use retries only for genuinely retryable failures
- honor rate limits
- cache provider IDs and results
- never log the API key
- write enrichment through the catalog repository
- never mutate QML models directly from network callbacks
- never replace valid local artwork automatically

---

### 33. Errors shown to the user

Separate user-safe messages from technical detail.

```cpp
struct AppError
{
    QString code;
    QString title;
    QString userMessage;
    QString technicalDetail;
};
```

Example:

```cpp
AppError{
    .code = QStringLiteral("library.unavailable"),
    .title = QStringLiteral("Library unavailable"),
    .userMessage = QStringLiteral(
        "The Movies library is not currently mounted. "
        "Your catalog has been preserved."),
    .technicalDetail = QStringLiteral(
        "Root /mnt/media/Movies failed QFileInfo::isReadable()")
};
```

QML receives `title` and `userMessage`. Logs receive `code` and technical detail.

Playback failures should name the item and give the next useful action:

```text
Unable to play Arrival

The file is no longer available at its cataloged location.
Reconnect the library and rescan.
```

---

### 34. Tests

Preserve the deterministic QA mindset from the native app.

#### Test categories

Unit tests:

- filename parsing
- stable ID generation
- migration order
- scanner diff behavior
- unavailable-root behavior
- search ordering
- route transitions
- focus movement
- completion thresholds
- watch-progress debounce

Integration tests:

- scan fixture library into a temporary SQLite database
- rescan with add/update/remove changes
- load a short test clip through libmpv
- create/destroy the player repeatedly
- seek into a clip, activate the HUD Restart action, and verify playback returns
  to the beginning without unloading
- exercise a film, a mid-season episode, and a final episode so the HUD exposes
  Next Episode only when an ordered successor exists
- confirm settings and paths use test mode
- disconnect an SD/USB/NAS fixture source and verify rows remain cataloged,
  the source is unavailable, and a later reconnect resumes scanning
- parse a show/season/episode fixture and verify channel selectors use episode
  identity rather than filename parsing in the UI
- exercise deterministic random, resume, and broadcast-clock channel selection
  with a fixed clock and seed
- prove a NAS/read failure becomes a controlled retry/error state rather than
  an empty library or silent autoplay advance

QML tests:

- poster selected state
- grid boundary behavior
- Back/Escape behavior
- overlay focus restoration
- transport-control traversal when conditional controls appear and disappear
- identical focus-following viewport targets on Home and non-home browse
  surfaces, with animated intermediate offsets disabled by Reduce Motion
- Sidebar entry, Nostalgia TV route entry/exit, previous-route focus
  restoration, channel switching, and profile-lineup replacement
- Play Something never selects an episode, and Kids projections never expose
  an adult channel or unapproved media item

#### Test CMake file

`tests/CMakeLists.txt`:

```cmake
find_package(Qt6 REQUIRED COMPONENTS Test)

qt_add_executable(tst_filename_parser
    scanner/tst_filename_parser.cpp
    ../src/catalog/LibraryScanner.cpp
)

target_include_directories(tst_filename_parser PRIVATE
    ../src
)

target_link_libraries(tst_filename_parser PRIVATE
    Qt6::Core
    Qt6::Test
)

add_test(
    NAME filename_parser
    COMMAND tst_filename_parser
)
```

Example test:

```cpp
#include <QFileInfo>
#include <QtTest>

#include "catalog/LibraryScanner.hpp"

class FilenameParserTest final : public QObject
{
    Q_OBJECT

private slots:
    void extractsTitleAndYear()
    {
        const ParsedFilename result = parseMovieFilename(
            QFileInfo(QStringLiteral("Arrival.2016.1080p.mkv")));

        QCOMPARE(result.title, QStringLiteral("Arrival 1080p"));
        QCOMPARE(result.year, 2016);
    }
};

QTEST_MAIN(FilenameParserTest)
#include "tst_filename_parser.moc"
```

The expected title above exposes a likely parser improvement: stripping release tags. That is useful. Add the rule deliberately and update the test rather than hiding the weakness.

Run:

```bash
ctest --test-dir build/v3-debug --output-on-failure
```

#### Isolated fixture

```text
tests/fixtures/library/
├── Movies/
│   ├── Arrival (2016)/
│   │   ├── Arrival (2016).mkv
│   │   └── poster.jpg
│   └── Moon (2009)/
│       └── Moon.2009.mp4
└── TV/
    └── Example Show/
        └── Season 01/
            └── Example.Show.S01E01.mkv
```

The media files may be tiny generated clips. Never point tests at the live theater sidecar or catalog.

---

### 35. Build and run scripts

`scripts/configure-v3-debug.sh` configures `build/v3-debug` with Ninja, a Debug
build type, and `MARQUEE_BUILD_TESTS=ON`; extra arguments pass through to
`cmake`. `scripts/run-v3-debug.sh` rebuilds that tree, enables the `marquee.*`
logging categories, and runs `build/v3-debug/marquee` with the arguments it is
given:

```bash
./scripts/configure-v3-debug.sh
./scripts/run-v3-debug.sh --windowed --library /mnt/media/Movies
```

The application accepts `--fullscreen`, `--windowed`, `--library <path>`,
`--tv-library <path>`, `--play <path>`, and `--test-mode` (Qt test paths instead
of user data paths).

---

### 36. Desktop integration

`packaging/marquee.desktop`:

```ini
[Desktop Entry]
Type=Application
Name=Marquee
Comment=Browse and play a local movie and TV library
Exec=marquee --fullscreen
Icon=marquee
Terminal=false
Categories=AudioVideo;Video;
StartupNotify=true
StartupWMClass=marquee
```

Set the Qt desktop file name so Wayland/desktop matching is predictable:

```cpp
QGuiApplication::setDesktopFileName(QStringLiteral("marquee"));
```

Add that after constructing `QGuiApplication` in `main.cpp`.

Omarchy exposes the application launcher with its normal launcher shortcut once the desktop file is installed.

A direct launcher binding can be added to the user's Omarchy/Hyprland bindings configuration:

```ini
bind = SUPER, M, exec, marquee --fullscreen
```

Hyprland's configuration format is evolving. Keep compositor-specific fullscreen/window rules optional and verify their syntax against the installed Omarchy/Hyprland version. Marquee should implement `--fullscreen` itself so it does not depend on a compositor rule.

---

### 37. Arch packaging

`packaging/arch/PKGBUILD` starter:

```bash
pkgname=marquee
pkgver=0.1.0
pkgrel=1
pkgdesc='Native local home-theater library browser'
arch=('x86_64' 'aarch64')
url='https://github.com/hermes-os/marquee'
license=('GPL-3.0-only')

depends=(
  'qt6-base'
  'qt6-declarative'
  'qt6-wayland'
  'mpv'
  'sqlite'
)

makedepends=(
  'cmake'
  'ninja'
  'pkgconf'
)

# Replace this with a real release archive and checksum.
source=("$pkgname-$pkgver.tar.gz")
sha256sums=('REPLACE_WITH_RELEASE_CHECKSUM')

build() {
  cmake -S "$srcdir/$pkgname-$pkgver" -B build -G Ninja \
    -DCMAKE_BUILD_TYPE=None \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DMARQUEE_BUILD_TESTS=ON

  cmake --build build
}

check() {
  ctest --test-dir build --output-on-failure
}

package() {
  DESTDIR="$pkgdir" cmake --install build
}
```

For local development, create a source tarball:

```bash
git archive \
  --format=tar.gz \
  --prefix="marquee-0.1.0/" \
  -o packaging/arch/marquee-0.1.0.tar.gz \
  HEAD
```

Calculate the checksum:

```bash
sha256sum packaging/arch/marquee-0.1.0.tar.gz
```

Build the package from `packaging/arch`:

```bash
makepkg -sri
```

Do not ship `SKIP` checksums for an actual release.

The source package is shared, but release jobs must produce and test separate
x86_64 and aarch64 artifacts. The Pi release adds its systemd boot/recovery
unit, storage setup documentation, and eventual image/install flow; the
desktop package must not assume Pi automount, HDMI-CEC, or NAS credentials.

---

### 38. Performance guidelines

#### QML

- Keep expensive calculations out of delegates.
- Avoid creating hidden duplicate poster grids.
- Prefer model roles over repeatedly calling `get()` during binding evaluation.
- Load large screens through `Loader` only when needed.
- Use asynchronous image loading.
- Limit animations to focused/visible elements.
- Respect reduced-motion settings.

#### Catalog

- Use indexes for common sort/filter columns.
- Build browse projections in the catalog worker.
- Return compact value objects to the GUI.
- Use one short transaction per applied scan diff.
- Avoid one SQL query per visible card.

#### Artwork

- Decode at the requested size.
- Cache resized output.
- Limit concurrent decodes.
- Avoid retaining full-resolution source images in every delegate.

#### Playback

- Let mpv manage decoding and frame timing.
- Start with `hwdec=auto-safe`.
- Log the selected decoder during diagnostics.
- Do not add a second frame queue in Marquee unless measurements prove it is needed.

---

### 39. Acceptance for the first usable build

The first usable Omarchy build is accepted when all of these are true:

- Marquee launches as a native Wayland application.
- Local H.264 and HEVC samples play, audio reaches the expected device, and
  hardware decoding is active on the theater GPU.
- Showing, hiding, or animating the QML HUD does not change the decoded
  picture's luminance or color and does not cause periodic flicker or
  judder. This is checked on the theater host with a sustained two-minute SDR
  playback that cycles HUD visibility.
- `--fullscreen` works without a compositor rule.
- A configured movie directory is scanned off the GUI thread.
- SQLite migrations are forward-only and transactional.
- A missing mount preserves catalog records.
- Movies appear in a QML poster grid.
- Arrow-key/D-pad focus is predictable at every grid boundary.
- Enter plays the selected item.
- Escape leaves playback and returns to the prior selection.
- libmpv plays MP4 and MKV samples.
- Pause and seeking work.
- QML controls render over video.
- Repeated player creation/destruction does not crash.
- Repeated fullscreen entry and exit works.
- App shutdown is clean.
- Tests use Qt test paths and temporary fixture libraries.
- A PKGBUILD installs the application and desktop entry.

Anything beyond this list is valuable, but it should not block proving the foundation.

---

### 40. Acceptance for Pi and Nostalgia TV

This is a later product gate; it does not enlarge the first usable movie-only
build. It is complete only when all of these are true:

- The same v3 source builds a tested Linux x86_64 artifact and a tested
  Linux ARM64 artifact.
- A Pi 5 boots Marquee fullscreen and recovers cleanly through its service
  path.
- A configured SD source scans and plays a 1080p fixture without scanning
  or filling the OS partition.
- A configured USB source reconnects by stable identity after unplug/replug
  and preserves its catalog rows while absent.
- A mounted NAS plays over the intended Wi-Fi path; a Tailscale/subnet
  path is tested separately when used, without credentials in Marquee.
- NAS or removable-source loss shows an unavailable/retry state rather
  than an empty library or silent catalog deletion.
- Kids and Adult profiles expose only their permitted channels and media
  across browse, search, Play Something, autoplay, and channel switching.
- Play Something never selects a TV episode.
- Nostalgia TV enters from the sidebar, plays episode channels through the
  shared player, switches channels, and returns to the prior focus target.
- Nostalgia TV preserves the 4:3 viewer, CRT treatment, static transition,
  phosphor-green channel/volume OSD, standby, and safe-area placement.
- The CRT/OSD layer can be disabled safely on Pi hardware without breaking
  playback, and the fallback is covered by an explicit acceptance test.
- CEC, keyboard/media-key, or the selected USB/evdev remote path passes
  the physical-input test without Pi-specific code leaking into QML.
- 1080p playback and overlays pass on the target display; heavier 4K/HEVC
  behavior is documented separately unless hardware testing proves it.

---

### 41. Things not to do

- Do not retain Swift merely to preserve familiar syntax.
- Do not port SwiftUI view bodies into imperative C++.
- Do not place database code in QML.
- Do not use Electron for this dedicated native theater build.
- Do not use an ORM before explicit SQL becomes a demonstrated problem.
- Do not add multiple playback backends before libmpv fails a required case.
- Do not rely on X11 child-window embedding under Wayland.
- Do not make TMDB required to browse.
- Do not let remote focus depend on hover state.
- Do not hold an SQLite transaction while walking the filesystem.
- Do not use a SQL connection from a different thread than its owner.
- Do not update Qt models from worker threads.
- Do not hide crashes by leaking the mpv context on shutdown.
- Do not test against the live library.
- Do not automatically delete catalog data when a drive is temporarily missing.
- Do not build a giant C++ `ApplicationController` that owns every decision.

---

### 42. Implementation decision record

These decisions are durable. Do not reopen them casually; a change to one is a
new decision recorded here.

```markdown
# ADR-001: Linux application stack

 ## Decision

Marquee for Omarchy uses C++23, Qt 6/QML, libmpv, SQLite, and CMake.

 ## Reasons

- QML is a strong fit for a custom animated ten-foot interface.
- Qt provides mature Linux/Wayland application infrastructure.
- libmpv provides one capable playback path for Marquee's container range.
- SQLite preserves offline-first local ownership.
- C++ offers direct integration with Qt and libmpv without an FFI layer.

 ## Constraints

- C++ owns durable state and behavior.
- QML owns presentation only.
- Version-one embedded video uses Qt Quick's OpenGL path.
- Local artwork is authoritative.
- Metadata enrichment is optional.
- Automated tests use isolated data roots.
```

---

### 43. Primary references

Use current upstream documentation while implementing; APIs and compositor configuration can change.

- Qt: CMake QML module integration
  <https://doc.qt.io/qt-6/qt-add-qml-module.html>

- Qt: C++ and QML integration
  <https://doc.qt.io/qt-6/qtqml-cppintegration-topic.html>

- Qt: `QAbstractListModel`
  <https://doc.qt.io/qt-6/qabstractlistmodel.html>

- Qt: `QQuickFramebufferObject`
  <https://doc.qt.io/qt-6/qquickframebufferobject.html>

- Qt: Qt Quick scene graph
  <https://doc.qt.io/qt-6/qtquick-visualcanvas-scenegraph.html>

- Qt: `QStandardPaths`
  <https://doc.qt.io/qt-6/qstandardpaths.html>

- Qt: SQL database connections
  <https://doc.qt.io/qt-6/qsqldatabase.html>

- Qt: worker-object threading pattern
  <https://doc.qt.io/qt-6/qthread.html>

- Qt: Qt Test overview
  <https://doc.qt.io/qt-6/qtest-overview.html>

- mpv stable manual
  <https://mpv.io/manual/stable/>

- libmpv client API header
  <https://github.com/mpv-player/mpv/blob/master/include/mpv/client.h>

- libmpv render API header
  <https://github.com/mpv-player/mpv/blob/master/include/mpv/render.h>

- official libmpv/QML example
  <https://github.com/mpv-player/mpv-examples/tree/master/libmpv/qml>

- Arch package creation
  <https://wiki.archlinux.org/title/Creating_packages>

- Arch CMake packaging guidelines
  <https://wiki.archlinux.org/title/CMake_package_guidelines>

- Omarchy manual
  <https://learn.omacom.io/2/the-omarchy-manual>

- Hyprland current configuration documentation
  <https://wiki.hypr.land/>
