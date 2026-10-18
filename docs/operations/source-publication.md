---
summary: Where Marquee's public source and its private history live, why binaries are not published, and the one exception, the macOS 2.0.2 workflow artifact.
read_when:
  - Changing where Marquee's source is hosted, mirrored, or pushed.
  - Re-enabling binary release publishing.
---

# Source Publication

This repository is public. Its history starts at a new root commit whose tree is
the audited source tree of the former private development repository.

The history before that commit is in the private repository `marquee-history`.
It contains retired streaming work, host-specific configuration, generated
captures, Xcode user data, and dependency framework binaries whose corresponding
source wasn't retained. Deleting those paths in a later commit would not make
that history public-safe, so `marquee-history` is never published, and none of
its branches, tags, pull-request refs, or objects are pushed or mirrored into
this repository.

Ordinary development continues on this repository's `main`.

## Binary boundary

Source publication does not authorize binary publication. The historical v2
framework build lacks retained corresponding source and exact build flags.
`scripts/release.sh` therefore packages locally but rejects `--publish` before
any build or remote mutation.

Re-enable binary publishing only when the build itself can produce and verify:

- exact revisions and configuration flags for every bundled dependency;
- complete corresponding source for the emitted dependency binaries;
- all applicable license and copyright notices from the actual transitive
  bundle;
- checksums binding the source, manifest, frameworks, app, and release assets;
- a release upload that publishes the complete verified set together.

## macOS 2.0.2 download

The only binary that may be published is the artifact of the manual
`.github/workflows/macos-release.yml` workflow: the frozen Swift v2 app built
against the official MPVKit tag `1.1.0-n9.0.2` (commit
`98c3453e252922e3136422da3fbb2e341ed9edc8`), its `MPVKit` (LGPL) product. It
does not use the historical frameworks above, and `scripts/release.sh
--publish` stays disabled. Against the five conditions:

- Exact revisions and flags: met by reference. The workflow pins MPVKit to that
  commit and fails on any other. That commit's `Package.swift` pins each of the
  29 bundled binary targets by release URL and SHA-256, which SwiftPM checks on
  download. The configure flags are in MPVKit's
  `Sources/BuildScripts/XCFrameworkBuild/main.swift` and each `mpvkit/*-build`
  repository at the pinned tag. The workflow does not rebuild those binaries,
  so it cannot prove they came from those flags.
- Complete corresponding source: knowingly waived. The source is hosted
  upstream at the pinned tags (MPVKit, the `mpvkit/*-build` repositories and
  each library's own project), not mirrored here. Publishing the download
  depends on those upstream tags staying available.
  `THIRD_PARTY_LICENSES.md` names each library's source URL at its version.
- License and copyright notices: met for the bundle. `LICENSE`,
  `THIRD_PARTY_NOTICES.md` and `THIRD_PARTY_LICENSES.md`, with each bundled
  library's upstream license text, ship in the disk image. The release zips
  carry no license files of their own. System libraries the app links from
  macOS (`/usr/lib`, `/System/Library`) are not bundled.
- Checksums: partly met. SwiftPM verifies every binary zip against its
  `Package.swift` checksum, the artifact carries the DMG's SHA-256, and
  `BUILD-INFO.txt` records the Marquee commit, the MPVKit commit, Xcode and the
  version. No checksum binds upstream source to the emitted binaries; the build
  is not reproducible.
- Complete upload: the workflow uploads the DMG, its checksum, `BUILD-INFO.txt`
  and the build logs as one artifact, or fails. It creates no GitHub release;
  the maintainer attaches the DMG, the checksum and `BUILD-INFO.txt` to the
  release together.

## Cutting a new public root

Before the first publication of a new root, run these checks against the
candidate clone:

- Verify the clone has exactly one root commit.
- Run the repository gate.
- Run a secret scan.
- Run a binary-aware private-marker scan.
- Run a forbidden-path scan.
