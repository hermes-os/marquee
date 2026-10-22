---
summary: The Marquee v3 verification gate - CMake/Ninja/CTest commands, focused tests per area, display-dependent limits, and evidence rules.
read_when:
  - Choosing checks for a change or deciding whether a result proves anything.
  - Adding or modifying a Qt Test target, a CMake test property, or a QML behavior test.
---

# Quality Gates

Marquee v3 (C++23, Qt 6/QML, libmpv, SQLite) is verified with CMake, Ninja, and
CTest on Linux. The Swift/Xcode tree is a frozen read-only reference and has no
gate: do not build, test, or fix it.

## The gate

```bash
# Configure the Debug build with tests (once, or after CMake changes)
./scripts/configure-v3-debug.sh

# Build and run every deterministic test
cmake --build build/v3-debug
ctest --test-dir build/v3-debug --output-on-failure
```

A source change is done when the full build and the full CTest run pass. Run one
heavy build or test run at a time and check memory and disk headroom first. An
exit caused by host starvation (exit 137) is neither a product pass nor a
product failure: restore headroom and rerun.

A docs-only change runs only the repository checks, not a rebuild:

```bash
docs-list --check "$PWD"
agent-repo-check --repo "$PWD"
git diff --check HEAD
```

Run `git diff --check HEAD` before committing, or `git diff --check origin/main`
over a finished range; plain `git diff --check` skips staged changes. Before
each commit, check your own change for secrets, private paths, live-library
data, generated artifacts, and unrelated work. The independent review reads the
commits afterwards.

## Focused tests while iterating

Run one target with `ctest --test-dir build/v3-debug -R '<regex>'
--output-on-failure`. Targets are registered in `tests/CMakeLists.txt`.

| Changed area | Targets |
| --- | --- |
| Routes, history, keys, startup | `^tst_navigation_controller$`, `^tst_navigation_keyboard$`, `^tst_startup_smoke$` |
| Logical focus (row/column) | `^tst_focus_navigator$` |
| Sidebar | `^tst_sidebar_navigation` (also runs `_hidpi`) |
| Settings, Reduce Motion | `^tst_settings_store$`, `^tst_settings_screen$` |
| Catalog schema, repository, scanner | `^tst_catalog_bootstrap$`, `^tst_library_scanner$`, `^tst_tv_scanner$` |
| Home poster cards and header | `^tst_library_browse` (also runs `_hidpi`) |
| Home rows (rules, then the screen) | `^tst_home_rows$`, `^tst_home_taste_rows$`, `^tst_home_screen$` |
| Play Something (the pick, then the controls) | `^tst_play_something$`, `^tst_home_rows$`, `^tst_home_screen$`, `^tst_sidebar_navigation` |
| Movies and TV routes (order, genre rows, holiday) | `^tst_browse_order$`, `^tst_movies_route` (also runs `_hidpi`), `^tst_tv_route$` |
| Details | `^tst_media_details$` |
| Player, HUD, watch progress | `^tst_playback$`, `^tst_playback_fullscreen$`, `^tst_player_window$`, `^tst_player_hud$`, `^tst_next_episode$`, `^tst_next_episode_flow$`, `^tst_player_tracks$`, `^tst_subtitle_discovery$`, `^tst_track_selection$`, `^tst_watch_progress$`, `^tst_watch_progress_process$` |
| Profiles and Kids content filtering | `^tst_profile_store$`, `^tst_profile_picker$`, `^tst_kids_content$` |
| Search | `^tst_search_session$`, `^tst_search_screen$` |

Change-specific additions:

- Playback, backend, or process changes also need the player HUD and watch
  progress targets, and proof that no `mpv`, `ffmpeg`, `ffprobe`, or `marquee`
  process is left behind after teardown.
- Focus, scroll, or browse-placement changes also need the browse suites at both
  device pixel ratios and a physical-remote pass on the affected surfaces.
- Visual or artwork changes need the browse and details suites at both ratios and
  a display-backed run (below); painted-pixel assertions retry until the scene
  has painted rather than sleep.
- Catalog schema changes add a forward-only migration with rollback coverage on
  a temporary database. Never edit a shipped migration.
- Motion changes need a QML test for each affected animation, with Reduce Motion
  on and off reaching the same focus-derived final target.

## What the suites can and cannot prove

- Every test links `marquee_core` and its shipped `Marquee` QML module. A QML
  behavior test must load that module; an inline replica scene proves nothing
  about the product QML.
- Tests choose their Qt platform in `tests/CMakeLists.txt` (`offscreen` or
  `minimal`). The `_hidpi` entries rerun a binary at `QT_SCALE_FACTOR=2`
  because painted chrome is judged in captured device pixels.
- The offscreen platform runs Qt Quick on the software backend, where
  `QQuickFramebufferObject` never renders. `tst_playback` therefore builds a
  platform fallback chain from the live session's display variables and skips
  its render cases when nothing connects. A skip is not a pass and is not render
  proof. The OpenGL branch of `FocusRing` and the libmpv render path are only
  exercised on a display-backed OpenGL session. `tst_player_window` builds the
  same chain so its title-shadow case, which needs the OpenGL scene graph, runs
  under an X display (xvfb) and skips on a headless offscreen run.
- Browse fixtures that need a window narrower than the compositor grants skip as
  an unsupported fixture rather than passing. Count skips; do not call a run
  with skips acceptance.
- Logical focus and navigation policy can be asserted deterministically.
  Perceived motion, physical-remote reachability, Wayland and OpenGL/EGL
  behavior, hardware decode, PipeWire routing, fullscreen transitions, and
  sustained picture stability need the theater host and
  `docs/RUNTIME_SMOKE_TEST.md`.
- Source inspection proves that a control, owner, or test is absent. It cannot
  prove runtime causality or target-host behavior.

## Isolated data

Automated runs use Qt test paths, `AppPaths::setRuntimeRoot`, temporary
databases, and synthetic legal media. They never open the live catalog or the
theater library, and never write to the user's real config, data, or cache
directories. `--test-mode` makes the application use Qt test paths. Credentials,
private inventories, and live paths do not appear in source, fixtures, or logs.

## Reporting

State each command, its exit status, and its pass, fail, and skip counts. Say
which checks you could not run. Never describe a skipped or unrun check as
passing.
