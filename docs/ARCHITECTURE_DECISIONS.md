---
summary: Decisions behind the frozen Swift v2.0.1 app, kept as the record of why the behavior oracle is built as it is.
read_when:
  - Asking why the released Swift app handles persistence, focus, artwork, or playback the way it does.
  - Comparing a v3 decision with the released one before departing from it.
---

# Architecture Decisions

These records describe the released Swift v2.0.1 system. That code is a frozen,
read-only reference: nothing here directs new work, and the Xcode, Swift, and
macOS 12 constraints below are history, not a build or test path. The v3
decisions are in `ARCHITECTURE_V3.md`.

## ADR-001 — Preserve the macOS 12 baseline

**Status:** Historical — the Swift app is frozen and no longer built

The released app targeted macOS 12 and Xcode 14.2 on an Intel Broadwell host,
used Swift 5, `ObservableObject`, `@Published`, and explicit composition, and
could not use APIs whose minimum is macOS 13 or 14, including SwiftData and the
Observation framework. This explains the shape of the released code; it is not a
toolchain to set up.

## ADR-002 — Use the system SQLite catalog and stable typed identity

**Status:** Accepted; supersedes the earlier proposed GRDB design

The catalog uses the custom `CatalogStore` abstraction backed by the system
sqlite3 library. Schema version 4 is the current operational schema. Migrations
are forward-only; versions 3 and 4 apply their schema and `user_version` updates
atomically. Media identity derives from volume identity plus relative path, and
entity IDs remain strongly typed.

Do not introduce Core Data, SwiftData, GRDB, or parallel JSON runtime storage
without a new decision and a migration plan. The legacy JSON format is an
import source, not a second authority.

## ADR-003 — Keep browsing offline-first and sidecar-first

**Status:** Accepted

The local catalog and local sidecars are sufficient for all core browse flows.
TMDB enrichment is optional, cached, and isolated behind catalog protocols.
Valid sidecar artwork wins over online artwork. Network loss or absent
credentials must not empty the library or block navigation.

## ADR-004 — Decompose state by domain through explicit composition

**Status:** Accepted

Ownership belongs to `LibraryState`, `ProfileSession`, `PlaybackSession`,
`AppRouter`, and other narrow domain owners. `AppState` composes them, relays
their `objectWillChange`, and keeps only its own policy: playback entry points,
profile selection and exit sequencing, scan lifecycle triggers, and error
presentation. Its library-forwarding shims are gone; a view that needs library
data observes `LibraryState`. Additions should strengthen those boundaries
rather than grow a replacement god object or create screen-specific copies of
shared state.

Cross-domain coordination is wired at composition. Any future compatibility
shim may live only as long as it has real consumers and must be removed with the
consumer migration that makes it unnecessary.

## ADR-005 — Use one logical focus and placement authority per surface

**Status:** Accepted

Remote traversal is expressed through shared focus engines and typed targets.
Placement policies decide whether a measured correction is needed; AppKit
coordinators execute it using finite, clamped geometry.

The engine has no wrap concept. A container reports `.boundaryHit` at its edge
and the surface decides what that means — hero wrap on Home, back-at-root on the
browse grids, a no-op on a header. Adding wrap to the shared engine was rejected
because it would reach every focus surface to serve one.

Native programmatic scroll animation stays disabled below macOS 13. Motion is
the authority's own interpolation toward a target it has already clamped, and
Reduce Motion bypasses it for immediate placement. The placement formulas remain
the source of truth: motion changes how a row travels, never where it lands.

Timer-settled restores, speculative repeated scrolls, raw unbounded geometry,
and competing scroll owners are rejected because they cause overshoot,
oscillation, and stale-focus bugs.

## ADR-006 — Keep playback multi-backend and explicit

**Status:** Accepted; supersedes the proposed single-libmpv-engine design

`MPVPlayerService` selects exactly one route for each load. Direct AVFoundation
owns ordinary MP4/M4V/MOV. The crash-isolated embedded ffmpeg bridge owns
normal multiformat containers and HEVC-tagged AV containers. Prepared
AVFoundation/remux, transcode, external ffplay, and in-process mpv remain
diagnostic opt-ins rather than silent production fallbacks.

This routing reflects the proven macOS 12 behavior of the current app. Backend
choice, state transitions, track selection, and errors remain observable
through the player facade.

## ADR-007 — Fail controlled when the required playback bridge is unavailable

**Status:** Accepted

If the embedded ffmpeg/ffprobe route required for HEVC or a multiformat
container is missing or fails, Marquee presents a controlled playback error.
It does not silently retry HEVC through direct AVFoundation, make remux the
default, or fall through to an external window. Sidecar subtitles are preserved
on the embedded route.

Every backend exit path must close pipes and terminate owned helpers. Tests for
load failure and parent death are release-gate requirements because leaked
helpers and process crashes are higher risk than a visible controlled failure.

## ADR-008 — Isolate automated QA and tier it by risk

**Status:** Historical for the Xcode gate; the isolation rule carries to v3

Automated QA uses a unique scratch data root and never seeds or mutates the live
catalog. v3 keeps that rule through Qt test paths and temporary roots (see
`QUALITY_GATES.md`). The released app also ran one Debug Xcode build with
in-app harnesses, with release builds, screenshot tours, and codec-routing
scenarios at phase boundaries; that gate is retired with the Mac build.

## ADR-009 — Keep local dependencies, secrets, and private data out of Git

**Status:** Accepted; the MPVKit and DMG details are historical

Generated dependency frameworks, `Secrets.plist`, credentials, live catalogs,
private media, build products, and generated QA artifacts are never committed.
The released app built MPVKit/libmpv locally under the ignored
`Vendor/MPVKit-local/` path, with a small compatibility shim in
`MarqueePatches/`, and staged disk images on an APFS temporary path because its
checkout was on exFAT. v3 links the system libmpv through `pkg-config`.

## ADR-010 — The embedded bridge is paced by an owned platform clock, not by `-re`

**Status:** Accepted; supersedes the `-re`/wall-clock revision of this decision

The bridge previously throttled decode with ffmpeg's `-re` and inferred
position from wall-clock arithmetic or rendered-audio measurement. That model
was open-loop — no timestamps crossed the process boundary — so pause had to
SIGSTOP and restart the process, playback speed was impossible and its
control hidden, position was inferred rather than known, and every stall
threatened A/V divergence. Each symptom needed bespoke machinery.

The current model closes the loop with the platform's synchronization
engine. `EmbeddedPlaybackPresenter` owns an `AVSampleBufferRenderSynchronizer`
as the master clock. The bridge decodes with no realtime throttling; the
`fps` filter forces constant frame rate at the probed source rate, so each
raw frame's timestamp is exactly its index over that rate, and each PCM
chunk's timestamp is its sample index. Video intake is gated to a bounded
lead over the clock, which backpressures the single ffmpeg process through
its own pipes — the clock paces the bridge, never the reverse. A display
link presents the newest frame whose timestamp the clock has reached.

Audio PCM travels through a FIFO (on a POSIX filesystem — the exFAT playback
cache cannot host FIFOs) into an `AVSampleBufferAudioRenderer` attached to
the synchronizer, which owns device routing and time-pitch correction.
Volume and mute are renderer properties. If audio cannot be prepared the
bridge launches without an audio mapping (ffmpeg blocks forever opening a
FIFO no one reads) and a notice says so; if the renderer fails mid-play,
playback continues on the synchronizer clock without audio and a notice
says so.

Consequences of owning the clock: pause is rate 0 and resume restarts the
clock in place — the process, its decode state, and the picture all hold,
with no signals and no relaunch; playback speed is the synchronizer rate,
so the speed control returned to every backend; position is read from the
clock and is exact under pause, seek, and rate change, which is also what
sidecar subtitles align to; natural end is deferred until the queued tail
plays out. Seeks still relaunch the bridge at the target offset, preserving
the last frame while the new process opens.

Playback on the bridge and mpv backends holds a display-sleep assertion
while actively playing; AVFoundation manages its own. In-process mpv remains
an opt-in diagnostic; its GPU/libass crash history is why decode stays in a
crash-isolated helper process.
