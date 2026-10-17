---
summary: Where Marquee's public source and its private history live, and why binaries are still not published.
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
