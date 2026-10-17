# Marquee

Marquee is a home-theater app for browsing and playing a private local movie and
TV library. It combines a remote-first, ten-foot interface with offline
cataloging, profile-aware discovery, sidecar artwork, and libmpv playback.

Marquee v3 is the product: C++23, Qt 6/QML, libmpv, and SQLite, built with CMake
and Ninja for Omarchy/Arch Linux. The released Swift v2.0.1 macOS app remains in
`Marquee/` as a frozen, read-only reference for behavior and appearance. It is
not built, tested, or fixed. This repository is not the separate web/Roku
streaming project.

## Build and test

```bash
./scripts/configure-v3-debug.sh
cmake --build build/v3-debug
ctest --test-dir build/v3-debug --output-on-failure
```

Dependencies, run options, and local data locations are in
[`BUILDING.md`](BUILDING.md). The verification gate and what each suite can and
cannot prove are in [`docs/QUALITY_GATES.md`](docs/QUALITY_GATES.md).

## Repository map

- `src/` — C++ behavior and state: `app/` (composition, paths), `catalog/`
  (SQLite catalog, scanner, worker), `models/` (Qt models and browse
  projections), `navigation/`, `playback/` (libmpv render item, player session),
  `profiles/`, `search/`, `settings/`, `ui/`, `support/`.
- `qml/` — presentation only: `Main.qml`, `Theme.qml`, `screens/`, `components/`,
  `shaders/`.
- `tests/` — Qt Test targets registered in `tests/CMakeLists.txt`; each links the
  shipped `Marquee` QML module.
- `scripts/` — `configure-v3-debug.sh` and `run-v3-debug.sh` for v3. The other
  scripts belong to the frozen Swift reference and are not used.
- `docs/` — v3 design, gates, manual QA, and operations notes.
- `Marquee/`, `MarqueePatches/`, `Marquee.xcodeproj`, `Package.swift` — the
  frozen Swift v2 reference.
- `issues.md` — open bugs and gaps. `CHANGELOG.md` — user-facing changes.

## Product constraints

- Offline browsing must remain functional without TMDB or network access.
- Local sidecar artwork is authoritative.
- Credentials and the live media catalog are never committed or packaged.
- Automated tests use Qt test paths and temporary roots, never the live library.
- A library root that is missing or unreadable never deletes catalog rows.

See [`AGENTS.md`](AGENTS.md) for repository invariants,
[`docs/ARCHITECTURE_V3.md`](docs/ARCHITECTURE_V3.md) for the v3 design, and
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the frozen v2 system the
parity work reads from.

## License

Marquee is free software licensed under the
[GNU General Public License version 3 only](LICENSE). Third-party dependencies
keep their own licenses; see [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).

The repository doesn't distribute MPVKit, libmpv, FFmpeg, or Qt binaries. The
historical v2.0.1 binary's exact dependency source and build flags weren't
retained, so that binary isn't suitable for public redistribution. A future
binary release must be rebuilt from recorded corresponding source. See the
[source-publication boundary](docs/operations/source-publication.md) before
publishing a release.
