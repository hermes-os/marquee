---
summary: Manual Omarchy theater-host checklist for Marquee v3 - what the automated suites cannot prove about display, remote, audio, and playback.
read_when:
  - Closing a milestone, cutting a release, or changing playback, focus, motion, visuals, profiles, or settings.
  - Validating behavior the headless CTest suites cannot prove.
---

# Runtime Smoke Test

Run this on the Omarchy theater host with a display-backed OpenGL session, the
real remote, and a disposable library. The CTest suites run headless and skip
the libmpv render cases; this list covers everything they cannot. A box is
checked only when the row was observed in the current run.

Record the commit (`git rev-parse --short HEAD`), the Qt and mpv versions, the
compositor, the display mode, the input device, and the media samples. Add a row
here in the same commit that lands the feature it covers; rows for features that
do not exist yet are not listed.

## Preparation

- [ ] `cmake --build build/v3-debug` and `ctest --test-dir build/v3-debug
      --output-on-failure` passed on the candidate commit.
- [ ] `tst_playback` and the browse suites ran on a display-backed OpenGL session
      and their skips were counted and explained, not assumed.
- [ ] No `marquee`, `mpv`, `ffmpeg`, or `ffprobe` process from an earlier run is
      active.
- [ ] The disposable library holds a movie with a sidecar poster, a movie
      without artwork, a show with several seasons and episodes, and H.264 MP4,
      HEVC, 4K, MKV, and WebM samples.
- [ ] The offline rows below were run once with networking disabled.

## Launch and library

- [ ] The session is native Wayland (`echo "$XDG_SESSION_TYPE"`) and Qt Quick
      runs on OpenGL.
- [ ] The app starts without a crash or fatal assertion; first launch shows the
      profile picker and a choice reaches the shell.
- [ ] `--fullscreen` works without a compositor rule, and F11 toggles
      fullscreen.
- [ ] A second launch lists the stored library; record how long until titles
      appear.
- [ ] A disposable file added, renamed, and removed is reflected after a scan;
      unrelated titles keep their watch state; no duplicates appear.
- [ ] An unmounted or unreadable root keeps its titles listed, reports `Library
      unavailable`, and recovers when the root returns. No catalog row is lost.
- [ ] Browsing and local artwork work with the network disabled.

## Browse, search, and details

- [ ] Home, Movies, and TV Shows render stable poster crops with no blank first
      paint, and the focus ring is visible at ten-foot distance.
- [ ] The Home title bar collapses past 60 points of scroll and the bottom fade
      does not cut the focused card.
- [ ] Search accepts typed and remote-keyboard input without dropped or doubled
      characters; results and the empty state read correctly.
- [ ] Movie and show details show title, metadata, artwork, and actions; seasons
      and episodes are reachable and never place focus on a stale row.
- [ ] Back from details, search, and the player returns to the previous surface.
      Record where focus lands; Home returns to the first title (`issues.md`).

## Profiles and settings

- [ ] Picker tiles, selection, add, edit, delete, and the exit fade work.
- [ ] Settings persist across a relaunch without changing unrelated choices.
- [ ] Reduce Motion places every glide immediately and lands on the same targets.
- [ ] Hardware Decoding applies to the running player; Auto-play Next Episode
      gates the handoff.
- [ ] Add Folder opens inside the window, including in fullscreen.

## Remote traversal

Name the input path used: keyboard, media keys, CEC, or evdev.

- [ ] Direction, Select, Back/Escape, and Play/Pause work through the real remote.
- [ ] Every grid reaches its edges and returns without oscillation, overshoot, or
      focus loss; held direction keys advance focus immediately.
- [ ] The sidebar, search keyboard, HUD Restart control, season tabs, episode
      rows, profile picker, and settings are reachable without a mouse.

## Playback

- [ ] H.264 MP4 and MKV play with synchronized audio and video; HEVC and 4K
      samples play.
- [ ] Hardware decoding is active on the theater GPU. Confirm it from the host
      (for example mpv's `hwdec-current` on the same file or the GPU's video
      engine load); the app does not log the selected decoder (`issues.md`).
- [ ] Audio comes out of the expected PipeWire sink.
- [ ] A two-minute SDR playback with the HUD shown, hidden, and animated shows no
      change in the picture's luminance or color and no periodic flicker or
      judder.
- [ ] Pause, resume, and seek work; the HUD auto-hides after 3 seconds and never
      hides a control that holds the remote.
- [ ] Down moves the remote onto Restart, Enter restarts without reloading, and
      Up hands the remote back.
- [ ] Leaving mid-film and reopening resumes at the recorded position; a film
      watched to its end starts from the beginning.
- [ ] At the end of an episode with Auto-play Next Episode on, the next episode
      starts at its own saved position; at the end of a final episode the player
      returns to the show page.
- [ ] While an episode with a next one plays, the HUD has a Next Episode control
      after +30 that the remote reaches and a click works; a film and a final
      episode have none.
- [ ] An episode of 10 minutes or more shows the next-episode card 30 s before
      its end (35 s from 40 minutes, 40 s from 50) with Play Now focused;
      Hide removes it and auto-play still happens; Back hides the card, then
      the HUD, then leaves.
- [ ] After three auto-played episodes and 90 minutes with no input, the next
      end shows "Still watching?" with Continue focused and Stop.
- [ ] Opening and closing the player repeatedly does not crash and leaks no
      frame, audio, or state into the next title.
- [ ] Repeated fullscreen entry and exit during playback works.
- [ ] An unplayable file shows the failure card, and Escape or Close dismisses it.
- [ ] After normal stop, load failure, and quit with the player open, no
      `marquee`, `mpv`, `ffmpeg`, or `ffprobe` process remains and the last
      position is stored.

## Closeout

- [ ] Screenshots of Home, Movies, TV Shows, details, the profile picker,
      settings, and the player HUD were inspected.
- [ ] No new console crash, assertion, secret, private path, or live-library
      mutation was observed.
- [ ] Every failed row is in `issues.md`.
