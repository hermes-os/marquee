# Building Marquee

Marquee v3 builds on Omarchy/Arch Linux with CMake and Ninja. The Swift/Xcode
tree is a frozen reference and is not built.

## Dependencies

Qt 6.8 or newer, CMake 3.24 or newer, a C++23 compiler, Ninja, `pkg-config`, and
libmpv:

```bash
sudo pacman -S --needed \
  base-devel cmake ninja pkgconf \
  qt6-base qt6-declarative qt6-shadertools qt6-wayland \
  mpv sqlite
```

The Arch `mpv` package provides the libmpv headers, library, and `mpv.pc`;
CMake finds it through `pkg-config`. The configured Qt components are
Concurrent, Core, Gui, OpenGL, Qml, Quick, QuickControls2, ShaderTools, and Sql.
Tests add Qt Test. No dependency is vendored.

## Configure, build, test

```bash
./scripts/configure-v3-debug.sh          # build/v3-debug, Ninja, Debug, tests ON
cmake --build build/v3-debug
ctest --test-dir build/v3-debug --output-on-failure
```

Extra arguments to `configure-v3-debug.sh` pass through to `cmake`. Configure
again after CMake changes. `build/` is ignored by Git.

CMake options:

| Option | Default | Effect |
| --- | --- | --- |
| `MARQUEE_BUILD_TESTS` | ON | Builds the Qt Test targets under `tests/`. |
| `MARQUEE_ENABLE_SANITIZERS` | OFF | Adds address and undefined-behavior sanitizers to every target. |
| `MARQUEE_WARNINGS_AS_ERRORS` | OFF | Adds `-Werror` to the strict warning set. |

Run one heavy build or test run at a time. Exit 137 means the host ran out of
memory; it is not a product result. Which suites to run for a change, and what a
skip means, is in [`docs/QUALITY_GATES.md`](docs/QUALITY_GATES.md).

## Run

```bash
./scripts/run-v3-debug.sh --windowed --library /path/to/Movies
```

The script rebuilds `build/v3-debug`, turns on the `marquee.*` logging
categories, and runs the binary with your arguments. Options:

| Option | Meaning |
| --- | --- |
| `-f`, `--fullscreen` / `--windowed` | Override the saved start mode. |
| `--library <path>` | Add a movie root for this run only. |
| `--tv-library <path>` | Add a TV Shows root for this run only. |
| `--play <path>` | Play a local file immediately; it records no watch progress. |
| `--test-mode` | Use Qt test paths instead of the user's data paths. |

Point manual runs at a disposable library. Never point automated work at the
live theater library.

## Local data

Paths come from `QStandardPaths` through `src/app/AppPaths.cpp`: settings
(`marquee.ini`) under the config location, `catalog.sqlite` and `profiles.json`
under the data location, and the artwork and thumbnail caches under the cache
location. Library roots are kept in settings and edited on the Settings screen.
Tests redirect the whole tree with `AppPaths::setRuntimeRoot`.

Credentials stay outside the repository and out of logs, settings dumps, the
catalog, and diagnostics. Online metadata is not implemented yet, so no key is
read; see `issues.md`.

## Display-backed runs

The libmpv render path needs an OpenGL scene graph. Under the offscreen platform
`tst_playback` skips its render cases, and a skip is not render proof. To run
them, start the test with a live Wayland or X11 session (or a nested Wayland
compositor) so `WAYLAND_DISPLAY` or `DISPLAY` is set.

## Packaging

There is no package yet: `CMakeLists.txt` installs only the `marquee` binary, and
no PKGBUILD or desktop entry exists (`issues.md`). Binary publication stays
disabled; see [`docs/operations/source-publication.md`](docs/operations/source-publication.md).
`THIRD_PARTY_NOTICES.md` lists the notice obligations for a future binary.
