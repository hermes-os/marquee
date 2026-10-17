# Third-party software

Marquee is licensed under the GNU General Public License version 3 only
(GPL-3.0-only). Third-party software used to build or run Marquee remains under
its own license.

## Released Swift v2

The source tree refers to a locally supplied MPVKit checkout. No MPVKit,
libmpv, FFmpeg, or related framework binary is distributed in this repository.

- [MPVKit](https://github.com/mpvkit/MPVKit) is licensed under LGPL-3.0. Its
  default bundles are described by that project as LGPL-3.0; bundles built with
  `enable-gpl` or carrying the `-GPL` suffix are GPL-3.0.
- [mpv/libmpv](https://github.com/mpv-player/mpv) is GPL-2.0-or-later by
  default. A build may be LGPL-2.1-or-later only when all GPL-only files are
  excluded and the resulting build actually satisfies mpv's LGPL conditions.
- [FFmpeg](https://github.com/FFmpeg/FFmpeg) is LGPL-2.1-or-later by default.
  Enabling GPL components changes the resulting build to GPL-2.0-or-later;
  enabling version 3 changes the applicable version as described by FFmpeg.

Marquee's historical local MPVKit frameworks don't have a retained, exact
corresponding-source revision and build configuration. They are intentionally
excluded from source publication. Do not publish a Marquee binary made from
those frameworks.

A future binary release must record every dependency revision and build flag,
include all required license and copyright notices, and provide the complete
corresponding source for the exact distributed dependency binaries. This
requirement applies even when those binaries were built without local changes.

The small bridge source in `MarqueePatches/standalone-mac-bridge-stub.c` is part
of Marquee and is covered by Marquee's GPL-3.0 license. It isn't a substitute
for MPVKit or libmpv corresponding source.

## C++/Qt v3

Marquee v3 builds against Qt 6, QML, libmpv, and SQLite, but no v3 dependency
binary is distributed here. Open-source Qt 6 modules are available under
module-specific LGPL-3.0 and GPL-3.0 terms. Before a v3 binary release, record
its exact Qt modules and revisions, verify each module's license, preserve
relinking and installation rights where LGPL applies, and publish the required
corresponding source and notices.

Apple platform frameworks and SQLite supplied by the operating system are not
copied into this source repository.
