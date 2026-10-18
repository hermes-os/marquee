# Issues

Open bugs and gaps. Each entry names where it is, what happens, and how it was
found. The commit that fixes an entry removes it.

Commit hashes in entries written before 6eb1590 refer to the private development
history and do not resolve in this repository.

Entries below were carried over from the retired v3 plan, its parity inventory,
and the retired issue queue, and each was re-checked against the source at
`81c8fa8`. The released Swift app in `Marquee/` is the behavior oracle for
appearance and interaction; a "released" comparison below means that source.
"Not run on a display" means the finding comes from reading the source and the
headless CTest suites, not from the theater host.

## A scrubbing hold shows no live frame
Where: `src/playback/MpvVideoItem.cpp`, `src/playback/SeekScrubber.*`, `qml/screens/PlayerScreen.qml`.
What happens: while Left or Right is held past half a second the film is paused and the clock and progress bar show where letting go would land, but the picture stays on the frame where the hold began until the key is let go. The released app sets mpv's `hr-seek` to `no` and previews the target (`PlayerView.swift:478-523`, `MPVPlayerService.swift:3050-3059`).
Found: implementing the hold-to-scrub; `SeekScrubber` emits only the final seek.

## The player never hides the pointer with the HUD
Where: `qml/screens/PlayerScreen.qml`.
What happens: the released HUD hides the mouse cursor when its controls auto-hide and shows it again on movement (`PlayerView.swift:222-257`); the Linux player leaves the cursor visible over the film.
Found: comparing the new HUD with `PlayerView.swift` after adding pointer reveal.

## libmpv core is still owned by the render item
Where: `src/playback/MpvVideoItem.cpp` (`mpv_create`, hwdec, play/seek commands), `src/playback/PlayerController.*`.
What happens: the render item owns the libmpv handle and every playback command; `PlayerController` holds session state only. `docs/ARCHITECTURE_V3.md` (Player-facing API and spike ownership) puts the core behind `PlayerController` once the spike is proven, and HUD features (Restart) already drive playback through the item.
Found: retired issue-closeout constraints and surfaces, re-checked against source at 81c8fa8.

## No sound subsystem
Where: `src/settings/SettingsStore.*`, `qml/screens/SettingsScreen.qml`.
What happens: Interface Sounds, Launch Ident, and Sound Pack persist and say
"Saved", but no code plays a cue.
Found: source read at 81c8fa8; no audio module is linked in `CMakeLists.txt`.

## Online Metadata is not implemented and its switch is not marked inert
Where: `qml/screens/SettingsScreen.qml` (Online Metadata row),
`src/settings/SettingsSession.cpp`, `src/catalog/`.
What happens: the switch says "Fetch TMDB details and artwork during library
scans", persists, and changes only the scan status text. Nothing fetches
anything: there is no network code. Without enrichment the catalog holds no
backdrop for movies, overview, director, cast, certification, rating, or genre,
so details omit those sections, the Movies route has no genre rows, and scoped
and genre search find nothing. The playback rows that are inert say "Saved"; this
one does not.
Found: source read at 81c8fa8; `git grep QNetwork` is empty and `CMakeLists.txt`
has no Network component.

## Home has no hero spotlight, taste rows, or seasonal rows
Where: `qml/screens/HomeScreen.qml`, `src/models/HomeRowsModel.cpp` (`compose`
leaves the place after Play Something and before Recently Added open).
What happens: Home has no hero spotlight or carousel. Its rows are Continue
Watching, Recently Watched, Play Something, Recently Added, a row per decade,
and All Movies; the released Because You Watched, Hidden Gems, Short Tonight,
seasonal, and Holiday Movies rows are not built, and the hero has no place in
the Home focus tree.
Found: parity inventory in the retired plan, re-checked against source at 81c8fa8.

## Home remembers the selected card only while its row survives
Where: `src/models/HomeRowsModel.cpp` (`recompose` keeps the focus on the
focused row id and card), `qml/Main.qml` (the route `Loader` recreates the
screen on every route change).
What happens: the focus lives in the controller's `HomeRowsModel`, so it is not
reset when Home is recreated after details or the player, and it follows its
card when a recomposition adds or removes rows. When the card's row is gone
(its title finished Continue Watching, or the profile changed), the remote goes
to the first card of the first row; nothing stores the title itself to find it
in another row, and nothing restores the page's scroll position apart from
placing the focused row.
Found: source read at 81c8fa8, re-read after the row-id focus fix.

## Poster tap target is larger than its hover target
Where: `qml/components/PosterCard.qml` (`TapHandler` on the whole delegate,
`HoverHandler` on the poster and caption), `qml/components/MediaItemRow.qml`
(delegate includes halo strips).
What happens: clicking the empty halo strip above or below a card activates it,
but hovering there does nothing. The released button has one rectangular hit
shape for both.
Found: retired plan's P3 note, re-checked against source at 81c8fa8.

## Sidebar has no pointer-hover ink and the profile editor has no character avatars
Where: `qml/components/Sidebar.qml`, `qml/components/ProfileEditor.qml`.
What happens: sidebar rows have no hover state (the released rows have a fourth
ink for hover); the profile editor offers only symbol avatars, not the released
character avatars.
Found: source comments and `git grep HoverHandler` at 81c8fa8.

## Released springs, SF Symbols, and shadows are approximated
Where: `qml/Theme.qml` (`motionNormal` 250 ms, `motionPage` 350 ms), sidebar,
poster card, Home header, `qml/components/MarqueeSymbol.qml`,
`qml/screens/HomeScreen.qml`.
What happens: the released response/damping springs (including the header's 0.6
damping bounce) are replaced by OutCubic eases; SF Symbols (the focus chevron,
the sidebar and profile symbols) are hand-drawn paths; the scanning logo's two
depth shadows are not drawn; the scanning spinner is a reconstruction. Poster
text metrics also ignore any accessibility text-size setting. Perceptual
fidelity was never judged on a display.
Found: parity inventory in the retired plan, re-checked at 81c8fa8.

## Kids palette is applied on some screens only
Where: `qml/screens/HomeScreen.qml`, `MoviesScreen.qml`, `ShowsScreen.qml`,
`SettingsScreen.qml`, `PlayerScreen.qml`, `ProfilePickerScreen.qml` (no
`kidsMode` reference); `DetailsScreen.qml`, `ShowDetailScreen.qml`,
`SearchScreen.qml`, `Sidebar.qml`, `EpisodeRow.qml`, `DetailCapsuleButton.qml`
(use it).
What happens: under a Kids profile the details, show, search, and sidebar
surfaces switch palette and copy; Home, Movies, TV Shows, Settings, and the
player do not. The released app applies the kids theme from the shell.
Found: `git grep -c kidsMode -- qml` at 81c8fa8. Not run on a display.

## No drop-to-play overlay and no post-play handoff card
Where: `qml/Main.qml`, `qml/screens/PlayerScreen.qml`.
What happens: dragging a file onto the window does nothing, and the released
"pairs well with" card after playback does not exist. `git grep DropArea` is empty.
Found: source read at 81c8fa8.

## Error toast never dismisses itself
Where: `src/app/ApplicationController.cpp` (`raiseError`),
`qml/components/ErrorToast.qml`.
What happens: a raised error stays on screen until the viewer clicks its close
button; there is no timer. The released toast dismisses after 5 seconds. The
toast also uses fixed 18 and 16 px type and a text glyph, where the released
toast scales 13/18 and 12/16 and draws a gold triangle.
Found: source read at 81c8fa8; compared with `Marquee/AppState.swift` `showError`.

## Search covers movies only
Where: `src/search/SearchSession.*` (built on `LibraryModel`, which holds movies
only), `qml/screens/SearchScreen.qml`.
What happens: shows and episodes are never searched, yet the landing hint says
"Titles, shows, episodes, cast, directors, genres, years, and filenames". Buffered
typing before the Search route appears is not carried over. The released pending
state never shows because evaluation is synchronous.
Found: source read at 81c8fa8; `ApplicationController` filters the library model
to movies before `replaceItems`.

## A partially readable library root is only logged
Where: `src/catalog/CatalogStore.cpp` (`applyScan`, `Incomplete`),
`src/catalog/CatalogWorker.cpp`.
What happens: when part of a root cannot be read, its rows are kept and a warning
goes to the log. The viewer is told nothing, unlike an unavailable root.
Found: source read at 81c8fa8.

## A moved library is treated as a new library
Where: `src/catalog/CatalogStore.*` (root identity keyed on the configured path),
`qml/screens/SettingsScreen.qml`.
What happens: pointing a library at a new path creates new rows and drops watch
state and resume points for the old ones; nothing can relink a root. This is
deliberate while no UI states the move explicitly.
Found: comment in `CatalogStore.hpp`, re-read at 81c8fa8.

## Product text and code comments point at the removed plan
Where: `qml/screens/SettingsScreen.qml:568` (user-visible string "…arrive with
the player and sound milestones named in the plan"), comments at
`qml/screens/SettingsScreen.qml:610`, `:634`, `:705`, `:726`,
`qml/screens/DetailsScreen.qml:410`, `tests/details/tst_media_details.cpp:1696`.
What happens: the Settings screen tells the viewer to look in a plan that no
longer exists, and the comments cite "plan section 5" and "the plan's Settings
gaps".
Found: `git grep -n "plan"` over `src qml tests` after the plan was retired.

## Settings diagnostics export omits crash reports and does not reveal the file
Where: `src/settings/SettingsSession.cpp` (`writeDiagnosticsSnapshot`),
`qml/screens/SettingsScreen.qml`.
What happens: the export writes the app version, OS, kernel, CPU, library roots,
and catalog and settings paths to a JSON file in the data directory and shows its
path. It includes no crash reports and
does not open or select the file; the image-cache summary shows the disk size
only because Qt keeps no hit counters; the released QA sound-pack hook is not
carried.
Found: source read at 81c8fa8, against the released settings page.

## Player teardown stress test loses a frame under a software-rendered compositor
Where: `tests/playback/tst_playback.cpp` (`repeatedPlayerTeardownKeepsPlaybackHealthy`).
What happens: at a doubled device pixel ratio on a Wayland compositor that
renders in software (Mesa llvmpipe), the complete playback binary intermittently
fails to see the third decoded frame in this case, while the neighbouring
fallback rows pass. Whether it is the test's timing or a real teardown race is
unknown. On a headless run the case skips.
Found: recorded in the retired plan's detail-surface repair notes; not
reproduced at 81c8fa8 because the host runs the suite without an OpenGL display.

## Several regressions were never run against the unfixed code
Where: `tests/browse/tst_library_browse.cpp`
(`movieFallbackNamesTheFormatBadge`,
`libraryModelProjectsTheFormatBadgeAsTheDetailsSurfaceDoes`,
`paintedBackdropUsesPhysicalPixelsWhateverTheSourceTag`,
`theFallbackSymbolSurvivesRepaintsAndModeChanges`),
`tests/playback/tst_watch_progress.cpp`
(`aDelayedEchoOfAnOlderRowCannotMoveATitleBackwards`,
`theSurfaceReportsALengthThatArrivesAfterTheFirstRow`).
What happens: they pass, but no record shows they fail without their fix, so a
test that cannot fail would go unnoticed.
Found: retired plan listed the reverted-source red runs as owed; re-checked that
the tests exist at 81c8fa8.

## Display-backed and theater-host proof is missing
Where: `tests/playback/tst_playback.cpp` (its render cases skip without an
OpenGL scene graph; nine at ab91a38), `src/ui/FocusRing.cpp` (OpenGL branch), `src/playback/MpvVideoItem.cpp`,
`tests/browse/tst_library_browse.cpp` (lean-back boundary cases skip as an
unsupported fixture when the compositor grants a wider window).
What happens: the headless gate passes with those cases skipped. Home, Movies,
TV Shows, details, and the empty, loading, and failure states have never had
display-backed visual acceptance, and no physical-remote pass is recorded.
Unproven on the theater host: 4K and HEVC decode, hardware decoding on the GPU, PipeWire routing,
repeated fullscreen, whether HUD animation is paced by the film's frame rate
(`MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME`), the focus-ring blend on the GPU, and a
two-minute SDR playback with the HUD cycling for a picture-brightness shift. The
app also never logs which decoder libmpv selected, so hardware decode cannot be
confirmed from its output.
Found: `ctest` skip counts and source read at 81c8fa8.

## Playback under host memory pressure is unmeasured on v3
Where: `src/playback/MpvVideoItem.cpp`, `qml/screens/PlayerScreen.qml`;
`tests/playback/tst_playback.cpp` has no resource-pressure case.
What happens: a v2 incident showed laggy playback while the host swapped heavily
(8 GB host, about 2.9 GB swap growing 12 MB/s, 4.8 GB free disk). Whether v3 shows
it is unknown. Comparing v3 against standalone mpv cannot separate host
provisioning from a shared libmpv defect, because both drive libmpv.
Found: retired ISSUE-002, carried over unchanged in substance.

## No package, desktop entry, sanitizer run, or crash collection
Where: `CMakeLists.txt` (`install(TARGETS marquee …)` only),
`src/main.cpp` (`setDesktopFileName("marquee")`), `scripts/`.
What happens: no PKGBUILD or `.desktop` file exists, so the app cannot be
installed as a desktop application. `MARQUEE_ENABLE_SANITIZERS` exists but no
script or CI job runs it, and there is no install, upgrade, or migration smoke
test. Nothing collects crash logs.
Found: `git ls-files` and `git grep sanitiz` at 81c8fa8.

## Storage sources are not built
Where: `src/catalog/`, `src/settings/SettingsStore.*` (`libraryRoots`,
`tvShowsRoots` are bare paths).
What happens: there is no source registry. A removable or network drive is
identified only by its current path, with no stable identity, kind (SD, USB,
NAS), or availability state beyond "root unavailable". The design is in
`docs/ARCHITECTURE_V3.md` (Storage boundary).
Found: source read at 81c8fa8.

## Nostalgia TV and the Raspberry Pi target are not built
Where: `src/navigation/NavigationController.hpp` (no route), `src/`
(no channel model), `CMakeLists.txt` (no ARM64 target).
What happens: neither the channel route nor a Pi artifact exists. The design is
in `docs/ARCHITECTURE_V3.md` (Pi storage and Nostalgia TV).
Found: source read at 81c8fa8.

## Swift and Xcode build tooling still ships beside the v3 gate
Where: `scripts/quality-gate.sh`, `scripts/toolchain-quality-gate.sh`,
`scripts/build-qa-app.sh`, `scripts/build-local.sh`, `scripts/diagnose-build.sh`,
`scripts/release.sh`, `scripts/perf-trace.sh`, `scripts/verify-*.sh`,
`scripts/test-quality-gate-legacy-import.sh`, `scripts/hammerspoon/`,
`Marquee.xcodeproj`, `Package.swift`, `MarqueePatches/`.
What happens: these still run Xcode, SwiftPM, `xcrun`, and the DEBUG harness
gate. The documentation now treats `Marquee/` as a frozen read-only reference
that is never built, but nothing stops a run of `quality-gate.sh`, and the
scripts' own headers still describe Mac builds and releases.
Found: `ls scripts` and the script headers at 81c8fa8, while retiring the Mac gate
from the docs.

## Open product questions
Where: `docs/ARCHITECTURE_V3.md`.
What happens: these have no decision: whether the theater remote works through
keyboard and media-key events alone (`scripts/hammerspoon/` is macOS-only and
unmaintained); Pi image layout (separate media SD card, second partition, or
both) and first-release filesystems; USB automount ownership and stable volume
identity; SMB/CIFS versus NFS and the mount-ready and retry policy over Wi-Fi and
Tailscale; how channel membership is authored and how unclassified Kids items
are approved; Wayland compositor versus EGLFS on the Pi; whether standalone
NostalgiaBox stays installable; and whether importing the v2 catalog is worth the
migration.
Found: the retired plan's Open Questions section.

## Kids loose-file check stalls the GUI thread when a library root is offline
Where: `ApplicationController::isRefusedLooseFile` and `playLocalFile` in `src/app/ApplicationController.cpp`.
What happens: on a restricted profile every loose-file request resolves and stats every hidden catalog title on the GUI thread (`canonicalFilePath` and `stat`). When a root is an offline network mount or a missing USB disk those calls can block, so each request freezes the UI until they time out, not only the first one. The request is refused afterwards, but only after the stall. Adult profiles and sessions with no profile do not run the check.
Found: review of 5a5d848; the code comment already notes the GUI-thread cost. No file-open path calls it yet (`--play` runs before a profile is chosen), so it is not reachable from the UI today.

## Kids loose-file check can read the wrong file after a library root moves
- Where: `src/app/ApplicationController.cpp` around line 660 (`isRefusedLooseFile`).
- What happens: the check reads the identity at the kept canonical path first. If that old path still reads but the catalog path now resolves to another disk (a root symlink re-pointed while the old disk stays mounted), the hidden title is checked against the wrong file.
- Found: round 2 review of c322b38.

## A deleted profile's watch progress can stay in the catalog with no owner
Where: `src/app/ApplicationController.cpp` (the `profileDeleted` connection, made only after the catalog worker starts), `src/catalog/CatalogWorker.cpp:126`.
What happens: deleting a profile removes its rows only if the worker is connected and the delete succeeds. A profile deleted before the worker starts is never connected, and a failed delete only logs, so the rows stay in `watch_progress` under an id no profile has. A profile later created with the same id would not collide (ids are UUIDs), but the rows are never reclaimed.
Found: review of 120327a..e264cec.

## Watch progress set aside after an unreadable profiles.json is never read back
Where: catalog migration 5 (`src/catalog/`, table `watch_progress_v4_unowned`), `src/profiles/ProfileStore.*`.
What happens: when `profiles.json` cannot be read at the upgrade, migration 5 renames the old `watch_progress` to `watch_progress_v4_unowned` and nothing ever reads that table. Once `profiles.json` is readable again, the viewer's earlier resume points and watched marks stay orphaned and no profile receives them.
Found: report of fix commit 1fe4413.

## Sidecar subtitle "Cars 2.en.srt" is listed for "Cars.mkv"
Where: `src/playback/SubtitleDiscovery.*` (in the other clone).
What happens: discovery follows the released rule, in which a space counts as a separator after the video's base name. So "Cars 2.en.srt" is listed in the subtitle menu for "Cars.mkv" (not auto-selected), though it belongs to another film.
Found: report of the tracks fix 72bfea2.

## A 6-minute title stopped from 2:00 on is marked watched
Where: `src/playback/PlayerController.cpp:70-71` (`watchedToTheEnd`).
What happens: the "last 5 minutes" half of the watched rule still applies to short titles, so a title of 6 minutes counts as watched once the viewer stops anywhere from 2:00 on, the point where a resume point starts to count. The viewer who stops a short film part-way through gets it marked watched and no resume point instead. Before the two-minute floor the same title was marked from about 1:00.
Found: review of 276354c..8f819a2.

## A resume row written before the length is known is never withdrawn if the title is under 5 minutes
Where: `src/playback/PlayerController.cpp:135-137` with `:198` (`isResumePoint` and `recordProgress`).
What happens: an unknown length does not block a resume point, so a row can be written before libmpv reports the length. When the length then arrives and turns out under 5 minutes, `recordProgress` runs again, finds the title is not a resume point and returns without writing, so the earlier row is left in the catalog and the title can show as "Continue Watching" although titles under 5 minutes are not meant to have a resume point.
Found: review of 276354c..8f819a2.

## FocusNavigator remembers columns by row number, so a row inserted above shifts them
Where: `src/navigation/FocusNavigator.cpp:49-54` (`m_rememberedColumns`).
What happens: the remembered column of each row is stored at the row's index. When a row is inserted above (a new Continue Watching row, for example), the remembered columns stay at their old indexes, so Up from a row lands on the next row up at the column that belonged to a different row.
Found: Home rows review.

## tst_profile_picker fails 3 of 9 cases under xvfb
Where: `tests/profiles/tst_profile_picker.cpp:133`, `:185`, `:257` (`theRemoteWalksTheTopRowAndTheManageControl`, `selectingAProfileFadesThePickerThenShowsTheShell`, `managementModeExposesTheActionsAndBackLeavesIt`).
What happens: under `xvfb-run -s "-screen 0 1920x1080x24"` the focused profile id is empty and the focus kind is "add" where the test expects "manage"; 3 of 3 runs, the same on the build from before the shadow change. It passes offscreen under ctest.
Found: gate run for the first-frame freeze fix.

## everyHudControlWorksWithAPointer fails when tst_player_hud runs directly offscreen
Where: `tests/playback/tst_player_hud.cpp:1057` (the window is still fullscreen).
What happens: 3 of 3 runs fail when the binary runs directly with `QT_QPA_PLATFORM=offscreen`; the case passes under ctest.
Found: review of a41f841.

## MediaItemRow logs a TypeError when a row is torn down with a placement queued
Where: `qml/components/MediaItemRow.qml` (`reconcilePlacement`, queued with
`Qt.callLater` from `onWidthChanged`, `onCardStrideChanged`, and
`onHaloPaddingChanged`).
What happens: if the row is destroyed before the queued call runs, Qt logs
"Property 'scrollToFocusedCard' of object MediaItemRow ... is not a function"
once per row, beside `QQmlVMEMetaObject: Internal error - attempted to evaluate
a function in an invalid context`. Nothing visible breaks, but it hides real
warnings. It shows in `tst_media_details` (More Like This) and in
`tst_home_screen` when a profile switch replaces Home's rows. It also shows at
window (or app) teardown on Home, Details and More Like This rows, 3-4 per test
under xcb in `tst_media_details` and `tst_home_screen`; the count is the same
before and after 14c9132.
Found: `tst_home_screen` at the Home rows commit; teardown count from
`tst_media_details` under xvfb with `QT_QPA_PLATFORM=xcb`.

## Play Something can still stall on a root that goes away between refreshes
Where: `ApplicationController::playSomething` in `src/app/ApplicationController.cpp`, `m_unavailableRootIds`.
What happens: the stat is skipped only for roots the latest finished refresh found unreachable. A network mount that dies after that refresh is still stat'd on the GUI thread, up to five titles per press, and `QFileInfo::isFile` on a dead hard NFS mount may never return (a minute or more on soft NFS or CIFS). Refreshes run on startup and on settings changes, not on a timer.
Found: review of 0ef4e95..ff928d9; the fix for the first round stops at what the catalog worker already knows.

## tst_player_hud hangs on window teardown and once aborted before any output
Where: `tests/playback/tst_player_hud.cpp`, `~QQuickWindow` on teardown.
What happens: two runs on 2026-10-16, both under load on the shared host. One hung in `~QQuickWindow` when a case's window was torn down and never finished. The other aborted with a core dump before printing any output; the rerun passed 23/23. The cause is not known and neither run was reproduced.
Found: the next-episode flow review runs (3b445ef..4da0105), running `tst_player_hud` under xvfb.

## The first frame blocks about 5 s on the software scene graph
Where: `qml/components/SoftShadow.qml` (the Canvas path, used when `GraphicsInfo.api` is Software).
What happens: on the software scene graph (the offscreen platform, or `QT_QUICK_BACKEND=software` under xcb) the GUI thread stalls about 5.2 s at the first frame while the Canvas `shadowBlur` convolutions run: 5,243 ms on the base build and 5,215 ms at ba2fc10, so the GPU path did not change it. The window ignores the remote for that time. The GPU (hardware) scene graph is not affected.
Found: review of 0e91322..ba2fc10.

## A track query can block the GUI thread on libmpv's audio teardown
Where: `src/playback/MpvVideoItem.cpp:946` (`applyDefaultTracks`).
What happens: `applyDefaultTracks` called `mpv_get_property` on the GUI thread, which blocked until the 300 s test watchdog fired while libmpv's core thread waited in `pw_thread_loop_stop`. Seen under xvfb with an empty `XDG_RUNTIME_DIR` on the base build.
Found: review of ba2fc10.

## playerRouteRendersDecodedVideoRightSideUp fails about 1 run in 10 under xvfb
Where: `tests/playback/tst_playback.cpp:831` ("No decoded video reached the Qt Quick scene").
What happens: about 1 in 10 full `tst_playback` runs under xvfb/xcb fail this case. It fails the same way on the 4da0105 source, so 9cc342b did not introduce it. 15 of 16 targeted reruns of the case passed.
Found: round 3 review of 4da0105..9cc342b.

## A source can stay in startup after a reload of the same file
Where: `src/playback/MpvVideoItem.cpp:306-308` with `:1195-1196`.
What happens: play A, call `setSource(B)` while B's loadfile is not issued (no render context) or is rejected, then call `setSource(A)` again. The second call returns early with `m_fileLoaded` already false, so A's positions are ignored and `startupPending` stays set until the surface comes back. Reachable only with a lost surface or a rejected loadfile.
Found: round 3 review of 4da0105..9cc342b.

## libmpv's lanczos scaler passes sometimes write NaN under Mesa's software GL
Where: libmpv 0.41's default `scale`/`cscale` (separable lanczos), reached through `MpvVideoItem`'s render context; `MpvVideoItem` has asked for bilinear since 13a940f, so Marquee no longer shows it.
What happens: with the lanczos defaults on llvmpipe (and on softpipe), about 1 render context in 3 draws a black or banded picture for its whole life. Reading mpv's offscreen textures back after the render shows NaN in alternate rows of the 80x120 chroma pass and in every 9th row of the 160x1080 luma pass, while the decoded frame (`screenshot-raw video`), the 2x256 weights texture (all 256 rows sum to 1) and the framebuffer state are intact. Not isolated: the cause inside mpv or Mesa is unknown. Facts: `mpv --vo=gpu` under the same xvfb never failed in 30 runs; `MALLOC_PERTURB_` set to 1, 85 or 128 made it vanish (36 of 36 phases fine against about 1 in 3); `dither-depth=no`, `LP_NUM_THREADS=0`, `hwdec=no` and an exposed window before the first grab did not help; scale and cscale both bilinear gave 0 of 45 phases. Any scaler that goes through the weights texture (spline36, ewa_lanczos) may show it if a later change selects one.
Found: investigation of the playbackSurvivesLosingAndRegainingItsRenderSurface flake, 2026-10-16.

## The macOS 2.0.2 license file lacks the Rust standard library's texts
Where: `THIRD_PARTY_LICENSES.md`, `Libdovi` section.
What happens: `Libdovi` is a Rust static library built with `-Zbuild-std`, so it contains the Rust standard library (archive members `std`, `core`, `alloc`, `compiler_builtins`, `hashbrown`, `gimli`, `addr2line`, `miniz_oxide`, `object`, `memchr`, `rustc_demangle` and others). libdovi-build does not record the nightly toolchain it used, so those crates' versions and license texts are not in the file; only the `dolby_vision` crate and its Cargo.lock dependencies are.
Found: listing the arm64 archive members of `Libdovi.xcframework` from libdovi-build release 3.3.2 while writing `THIRD_PARTY_LICENSES.md`.
