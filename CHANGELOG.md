# Changelog

All notable changes to Marquee are recorded here. Historical entries summarize
major milestones between the selected tags rather than duplicating every
intermediate version bump.

## [Unreleased]

- Home shows a Holiday Movies row after Recently Added, as the released app
  does, once two movies qualify: a holiday word in the title, in TMDB's genres
  or in its overview, or a named holiday film. No migration.
- After an update, every title whose online metadata an older matcher wrote is
  checked again once in the background, including the ones fetched in the last
  day (before, those skipped the check). A title waits a day only after a check
  that failed. The catalog is migrated to schema 8; titles, metadata and watch
  progress are kept.
- A dot-separated movie name keeps the dots of its initials:
  "E.T.the.Extra-Terrestrial.(1982)" shows as "E.T. the Extra-Terrestrial" and
  "L.A.Confidential.(1997)" as "L.A. Confidential", not "E T the
  Extra-Terrestrial" and "L A Confidential". Shown titles change on the next
  scan; no migration.
- Online metadata keeps a title the folder name only begins with ("Star Trek"
  for "Star Trek The Original Series") when the second search, without the
  year, fails on the network or is rate limited, instead of dropping it and
  trying again on the next run. No migration.
- Kids, Family and Teen profiles judge a title by its TMDB certification when
  it has one, as the released app does: a G or TV-Y title with no genre shows
  for Kids, and an R or TV-MA title no longer shows there because of its
  folder. Titles with no certification keep the genre rule. No migration.
- Movies and TV Shows group titles as the released app does. A title's genre
  rows come from TMDB's genres when it named any (the folder and the title
  guess otherwise), so Movies gains a row per genre between Holiday Movies and
  All Movies and TV Shows takes its rows from TMDB too. Holiday Movies also
  counts a holiday word in a title's TMDB genres or overview. Rows keep the
  released order: franchise, then year, then title. Search results and More
  Like This break ties in that order too. No migration.
- Movie titles no longer carry the year of a `Title (YYYY)` file or folder
  name: "1917 (2019)" is now "1917" from 2019 and "2001 A Space Odyssey (1968)"
  is "2001 A Space Odyssey" from 1968, and the year is what online metadata
  searches with. The library shows the corrected titles after the next scan.
- Online metadata matches more films correctly. "Hustle" (2022) is no longer
  matched to the 2019 "The Hustle": an exactly named title released in the
  file's year wins over a higher-ranked other year. "E T the Extra-Terrestrial",
  "L A Confidential" and "Richie Rich" are found (initials compare equal with
  or without dots, and TMDB's "Ri¢hie Ri¢h" reads as "Richie Rich"). Titles
  matched or missed by the earlier rules are matched again once, in the
  background, and a changed match replaces that title's stored metadata. The
  catalog is migrated to schema 7; titles and watch progress are kept.
- Online metadata also finds shows whose folder name has more words than TMDB's
  title when TMDB lists the show in the folder's year: "Star Trek The Original
  Series (1966)" and "The Office US (2005)". Titles are checked once more, in
  the background, after the update.
- A short film title inside a folder name is no longer taken for the film: "Us"
  (2019) is not "Between Us Girls (2019)". Only a title the name begins with
  matches this way. Titles are checked once more, in the background.
- Movie titles keep the dots of initials in a `Title (YYYY)` name, as the
  released app does: "E.T. the Extra-Terrestrial" and "L.A. Confidential" are
  no longer shown as "E T the Extra-Terrestrial" and "L A Confidential". A
  dot-separated name such as "The.Matrix.(1999)" still shows as "The Matrix".
- A `Title - (YYYY)` or `Title (YYYY) (YYYY)` movie name now shows and sorts as
  "Title" (not "Title -" or "Title (YYYY)"), and a `Title (2099)` name no longer
  takes 2099 as its release year.
- Choosing a profile again no longer sends the next Return back to the profile
  picker. After any profile choice, the first Return opens a Home card:
  Home's content holds the remote with a visible ring, and the sidebar's
  remembered stop is back on Home instead of the profile control, as in the
  released app. Before, the remote went to the collapsed sidebar still resting
  on the profile control, so every Return reopened the picker.
- Online metadata (TMDB) is fetched and stored. With a TMDB v3 key in the
  `MARQUEE_TMDB_API_KEY` environment variable, or in a one-line `tmdb-api-key`
  file next to `marquee.ini`, Marquee fetches each title's overview, genres,
  cast, director, certification, rating, votes, popularity, collection and
  keywords (and each episode's title, summary and still) in the background after
  a scan, one title at a time and never on the interface thread. Posters,
  backdrops and stills that your folders do not have are saved in Marquee's
  cache folder; artwork in your folders always wins and nothing is ever written
  into a library folder. A title that was fetched is not asked again, a run cut
  short resumes after a restart, and with no network, no key or the switch off
  the app works exactly as before. The Online Metadata switch in Settings now
  does this, starts on for settings that never stored a choice, and says "No
  TMDB key" when there is none; the key is never logged or shown. Nothing on screen uses the new data
  yet: rows and Details sections come in later changes. The catalog is migrated
  to schema 6 on first start; titles and watch progress are kept.
- A few unreadable files no longer empty the whole library. A file the drive
  lists but cannot open or stat (a name the filesystem driver cannot map, a
  file deleted mid-scan) is skipped and logged, and every other file in the
  root is still added; before, one such file failed the catalog write and left
  0 movies and 0 episodes. A skipped file keeps the row it already had, and
  files really deleted from the same root are still removed. A folder that
  cannot be read leaves the root partly read: what was read is stored and no
  row is removed until a scan reads every folder.
- The player covers the whole window. While a film or episode plays, the
  sidebar is gone and the picture and the controls use the full window width,
  as in the released app; closing the player brings the shell back on the same
  route with the remote on the content, as before.
- Playback goes fullscreen. Starting a film (a card, Play Something, Continue
  Watching, `--play`) puts the window fullscreen if it is not already. When the
  player closes, the window is decided from how it is then: if you used the
  Fullscreen control, F or F11 during playback, it stays as you left it; if
  your window manager took it out of fullscreen (its own fullscreen or
  maximize key), it stays where the manager put it; if it is still fullscreen,
  it goes back the way it was (windowed or maximized). A window that was
  already fullscreen stays fullscreen. A window manager that leaves fullscreen
  and returns during one film is treated as untouched, so the window goes
  back. Moving to the next episode changes nothing. This differs from the
  released macOS app on purpose.
- The mouse pointer hides with the player controls: when they fade out after
  three seconds (or Back hides them) the pointer disappears over the picture,
  and any pointer movement brings it and the controls back, as in the released
  app. It stays visible over "Still watching?", the failure card and an error
  message, and a failed player keeps its controls up instead of hiding them
  after three seconds.
- The player controls and the mouse pointer stay up while the progress bar is
  pressed or dragged, including a press held still for longer than three
  seconds; they hide three seconds after it ends, and the arrow keys keep
  working while it is held.
- The player controls match the released HUD more closely: the bottom bar
  fades from clear to black at 0.8 instead of a flat 0.72 slab, the progress
  bar is the released 4 (7 in lean-back) capsule over a dim track, the slash
  in the clock is dimmed, the side and bottom margins are the released 24/16
  (40/28 in lean-back) and the top bar's 20/16 (36/28). The gradient no longer
  adds a 48 px fade above the bar, the top bar has no dark gradient (the title
  block carries the released black shadow instead), the title and the episode
  line sit the released 2 (4 in lean-back) apart, and a speed of 1.25 reads
  "1.2x" as in the released app.
- While Left or Right is held past half a second the picture now follows the
  scrub: the player sets libmpv's `hr-seek` to `no` for the hold, previews the
  frame the clock points at (one preview seek at a time, only the newest target
  queued behind it, so a long hold leaves no backlog) and, on release, seeks
  exactly to the landing time and puts `hr-seek` back to `absolute`. Cancelling
  the hold (a menu opening, Media Stop, the player closing, a new file, a lost
  render surface) restores the seek mode and puts the picture back where the
  hold began. After a release the clock and progress bar go to the landing and
  stay there (on a film with a long keyframe interval they briefly jumped back
  to a preview's keyframe time), and the watch-progress position and the
  next-episode card never take a preview time, only the landing. A tap, a
  progress-bar click or Restart in the moment after a release moves the clock
  to where it goes (it stayed on the old landing, for good while paused, when
  the release landed where the film already was, for example a Left hold
  clamped at 0).
- A macOS 2.0.2 download is built from the frozen Swift app by a manual GitHub
  Actions workflow (`.github/workflows/macos-release.yml`): a universal (Apple
  silicon and Intel) `Marquee-2.0.2.dmg` with a checksum, built against the
  official MPVKit `1.1.0-n9.0.2` release instead of the earlier hand-patched
  frameworks. It is ad-hoc signed, not notarized: open it once; when macOS
  blocks it, go to System Settings, Privacy & Security, and choose Open Anyway
  (on macOS 14 and earlier, right-click and choose Open). If macOS still
  refuses, run `xattr -dr com.apple.quarantine /Applications/Marquee.app`.
  No Swift source changed; the bundled libmpv and FFmpeg are newer (MPVKit
  1.1.0-n9.0.2) and statically linked. The disk image carries
  `THIRD_PARTY_LICENSES.md` with the version, source and license text of every
  bundled library.
- The macOS 2.0.2 build's Swift self-tests pass in any month (the browse
  snapshot test no longer depends on the date) and the self-test binary is built
  before the first harness runs.
- The macOS 2.0.2 app no longer embeds MPVKit's frameworks that nothing loads
  (libmpv and FFmpeg are linked into the executable); the build removes every
  framework the executable does not load, directly or through another kept
  framework, before signing, ignores a dylib's own install name in its link
  check, and fails if any file in the signed app carries a build-machine temp
  path.
- The picture no longer comes up black now and then. Marquee scaled video with
  libmpv's default lanczos filters, which on a software GL stack (the test
  displays, a virtual machine) sometimes drew a black or banded picture for the
  rest of the playback, on a first play as often as after the window lost and
  regained its surface. Video is now scaled with bilinear filters, as in the
  released app. Looks: a sharp edge is slightly softer when a small video is
  stretched to the screen.

- A file you start always plays: pausing and then pressing Next Episode, Play
  Now or Continue, or leaving the player and playing another title, no longer
  opens the new file paused and stuck on its starting screen.
- The player has a Next Episode control after +30, shown only while an episode
  with a next one plays (aired order, into the next season, skipping a second
  copy of the same episode; films and final episodes have none), reachable from
  the remote and with a pointer. The next episode now opens at its own saved
  position, whether started by the control, the card or Auto-play, instead of
  from 0:00. With Auto-play Next Episode on, an episode of ten minutes or more
  shows a card 30 seconds before the end (35 from 40 minutes, 40 from 50 minutes)
  with the next title, "Next episode in N", Play Now (focused) and Hide; Back
  hides the card before the HUD. After three auto-played episodes and 90
  minutes without a key or pointer input the next end asks "Still watching?"
  with Continue and Stop. The end of a show's last episode returns to the show
  page.
- A show page builds only the episode rows on and near the screen, however long
  the season: the page is one list that recycles rows, so a 400-episode season
  holds 6 to 12 rows (12 to 18 blur effects) instead of 400 rows (404 effects),
  and the process stays under 0.4 GB instead of reaching 1.9 GB. The page looks
  and moves the same: Up and Down, the season picker, the hero actions, the
  scroll that keeps the focused row inside the margins, hover, click, and
  opening a show on an episode deep in a long season.
- Marquee opens without a 5 second pause on the GPU (hardware) scene graph: the
  card shadows and focus glows are blurred on the graphics card instead of the
  processor, so the first screen no longer freezes the window and ignores the
  remote while it draws. The software scene graph still pauses (see issues.md).
  A glow that is not shown, such as an episode row's before it is focused, no
  longer holds its blur effect and textures, so a long season uses less memory.

- A Left or Right tap while the player still says "Opening video..." no longer
  takes that message away: the tap has nothing to seek yet, so the screen waits
  for the film as before.

- The player has the released transport, volume, speed and fullscreen controls.
  Left steps back 10 seconds and Right forward 30 (Right used to step 10); hold
  either for half a second to scrub with the film paused, one second per tenth
  of a second at first, then two, five and ten, and let go to carry on from
  there. S toggles subtitles, F fullscreen, M mute, and [ and ] step the speed
  through 0.5x, 0.75x, 1x, 1.25x, 1.5x, 2x and 3x. The HUD has a close control
  and the title at the top, and along the bottom Restart, -10, play/pause, +30,
  the clock, then Subtitles, Audio, a speed menu, mute, a volume slider (Enter
  takes it, Left and Right change it) and fullscreen; every control works from
  the remote and with a pointer, a click or drag on the progress bar seeks, and
  the HUD stays up while a menu is open or a hold scrubs. Back and Escape
  now close an open menu first, then hide a visible HUD, and only with the HUD
  hidden leave the player, so pressing Back to clear the controls no longer
  loses the film. Volume, mute and speed start over at 100, unmuted and 1x with
  every film and are not saved, as in the released app.

- A resume point is now kept only once the viewer is two minutes into a title,
  and never for a title under five minutes long, so a three-second peek no
  longer shows up as "Continue Watching". Stopping before two minutes leaves an
  older resume point exactly as it was rather than replacing or erasing it.
  Finishing a title still marks it watched (nine tenths, or the last five
  minutes of a longer title).

- Play Something works. The sidebar control and the capsule beside Home's title
  now start an unwatched movie at once, with no details page between, from the
  remote (Enter) or a pointer. On Home, Up from the first row reaches the
  capsule, which takes the focus ring, and Down returns to the card the remote
  left; Left and Right do nothing on it. Each press draws a fresh weighted
  shuffle of the active profile's unwatched movies, so a Kids profile is only
  ever given titles its policy allows, a title one profile finished is still
  offered to another, and a part-way title is offered. TV episodes are never
  picked. A title whose file is gone or whose library root is offline is
  skipped for the next one that can play, and with nothing left to play the
  press does nothing and says nothing, as the released app does. A title of a
  root the last refresh found unreachable is skipped without touching its file,
  so a dead network mount does not freeze the interface; the first five titles
  on reachable roots are checked. On an empty library Up no longer rests the
  remote on the hidden capsule. Home shows a Play Something row of up to
  twelve of those titles (eight drawn) between Recently Watched and Recently
  Added. The shuffle weighs a poster only; the released taste, rating, and
  popularity terms wait for metadata. Two titles that draw the same shuffle
  key are ordered as the Movies page orders them: franchise, then year, then
  title. No migration.
- Home shows titled rows instead of one flat grid of movies: Continue Watching,
  Recently Watched, Recently Added, a row per decade of two or more movies, and
  All Movies, each with at most eight cards, moving with Up and Down between
  rows, Left and Right within one, Enter to open, and the same glide Movies and
  TV Shows use. A show in progress has one Continue Watching card for the
  episode to watch next, even when that episode is not started yet; an episode
  left part-way wins over the one after the last finished, a show with nothing
  watched or whose last episode is watched has no card, and a movie or show not
  played for 365 days leaves the row (its progress is kept, and playing it
  again brings it back). Recently Added has one card per show and hides what
  the profile has watched. An episode card opens its show at that episode. Each
  profile's rows come from its own progress, and a Kids profile's rows hold
  only what Kids may see. A library of only TV shows now shows its rows, not an
  empty movie grid. The Settings text for Watch History now says it clears the
  profile's saved positions and watched marks, which also returns watched
  titles to Recently Added. The remote stays on the title it rests on when a
  viewing or a rescan adds a row above it, or Home is opened again after the
  player, instead of landing on another row's card; if its row disappears it
  goes to the first card of the first row. A second file of an episode already
  watched is no longer offered as the next one, on Home or on the show page,
  and a show whose finale is watched through has no next episode even when it
  holds a copy of that finale. No migration.

- The saved Default Audio Language, Default Subtitle Language, and Subtitle Size
  now do something. When a file opens, the player picks the first audio track
  and the first subtitle track whose language matches the saved one, the
  released rule: "None" leaves subtitles off, and a language the file lacks
  leaves subtitles off and audio on the player's own pick. Sidecar subtitle
  files beside the video (and in a Subs or Subtitles folder) are found by the
  released rule, the video's name then a ".", "_", "-" or space, and listed
  too: "Film_en.srt" and "Film - eng.srt" count, and "Episode 10.en.srt" is no
  longer taken for "Episode 1". Subtitle Size scales the subtitles, 135% by default. The three
  rows no longer say "Saved", and the note calling them inert is gone. Switching
  a track while a film plays is kept when the picture is rebuilt, a sidecar
  subtitle file included, and sidecar files always list after the file's own
  subtitle tracks.

- The player HUD has Subtitles and Audio menus beside Restart. Subtitles shows
  when the file lists a subtitle and Audio when it lists a second audio track.
  Down reaches the HUD, Left and Right walk its controls, Enter opens a menu,
  Up and Down move through it, Enter chooses, and Escape closes the menu without
  leaving the player. The Subtitles menu starts with "Off", then a divider, then
  each track; tracks are named by the file's title, else the language, else
  "Track N", with the codec in parentheses, and a checkmark marks the current
  one. The HUD stays up while a menu is open, and a click on a track or outside
  the menu works too. The Restart control grows by the HUD's 1.07 when it
  takes the remote, and the player no longer logs a missing-scale warning.
  After a track menu opened by a click, the HUD now hides again once the
  choice is made or the menu is dismissed; from the remote it stays as before.

- A `profiles.json` that cannot be read at launch (corrupt or unopenable) now
  shows the "Profiles" storage error. Before, the error was recorded but
  never raised, so the default profiles appeared and the old watch progress
  was set aside with no notice.

- The catalog upgrade that gives each profile its watch progress now passes
  profile ids to SQLite as bound values, so an id holding a quote or a NUL
  character no longer makes the upgrade fail and block the library.

- A `profiles.json` that exists but cannot be opened (for example, wrong
  permissions) is no longer overwritten with the default profiles. The store
  keeps the file, shows the storage error, and does not write until the next
  launch can read it.

- Every profile now has its own watch progress. Resume points and watched
  marks are kept per profile, so the Kids profile and the adults no longer
  overwrite each other, and a new profile starts with none. Settings > Watch
  History clears the active profile's progress only, and deleting a profile
  removes its progress. A session with no profile chosen saves no progress
  and shows none. Catalog migration 5 rebuilds `watch_progress` with a
  profile column and copies each existing row to every profile that exists at
  the upgrade; it runs again as a no-op, and if it fails the catalog stays at
  version 4. When no profile list is readable (a missing, unreadable, or
  corrupt `profiles.json`) the upgrade still runs: the old rows are kept in
  `watch_progress_v4_unowned`, no profile has progress until it is watched
  again, and the library opens and scans as usual.

- Kids profiles now show only Kids and Family titles. Home, Movies, TV Shows,
  show episodes, and search drop everything else, and playing or opening a
  hidden title by its id is refused with "This title is not available on this
  profile." The rule is the released one: a title's maturity comes from its
  genres (the folder under the library root, then the title-based genres), a
  Kids profile admits Kids and Family, and a title with no genre information
  counts as Adult. Choosing another profile or editing the active profile's
  maturity refreshes every screen without a rescan.

- A Kids profile can no longer play a hidden title as a loose file by naming it
  through a symlink, and gets no loose file at all until the first library scan
  has finished. A genre folder named `sci-fi` now shows as "Sci-Fi", matching
  the released app. Only Kids profiles pay for that check, so Adult profiles
  and sessions with no profile open loose files without touching the catalog
  paths.

- A Kids profile can no longer play a hidden title as a loose file through a
  second name for the same data: a hard link to it, or the same disk mounted at
  another path. The check now compares the file's device and inode against
  every title the profile may not see, as well as its resolved path, and
  reads those identities again on each request, so a disk remounted under the
  same path with a new device number is still matched. It refuses a file whose
  identity cannot be read, and refuses every loose file while any title the
  profile may not see cannot be read (an offline or relocated root), since
  nothing can then say the file is not that title. Adult profiles and sessions
  with no profile are unaffected and skip the check.

- Repository documentation now matches the Linux build. The README, BUILDING,
  and the quality-gate guide lead with the CMake, Ninja, and CTest commands and
  describe the Swift macOS app as a frozen read-only reference that is no longer
  built or tested. The v3 design now lives in `docs/ARCHITECTURE_V3.md`, and
  open bugs and gaps are tracked in `issues.md`.

- Marquee v3's movie detail screen now matches the released layout. The
  Start From Beginning and Resume actions sit below the 400-point backdrop hero
  rather than inside it. The Start button's gold gradient runs diagonally
  inside its rounded corners with a clean white label. A title without a
  backdrop shows a diagonal gradient fallback on both the movie and show
  detail screens, with the blur matching the released radius. More Like This
  ranks equal-score titles by franchise, then release year (undated last), then
  title. The hero and poster, the circular Back control, the synopsis and
  director lines (omitted when the catalog has no text for them), and the file
  info follow the released composition. Resume reads the recorded watch
  progress in the released format, and the remote walks Back, the actions, and
  the related row.

- Marquee v3's player now shows the released preparation surface while a film
  opens. The backdrop is blurred and then dimmed, with the dim sitting above
  the blur; the preparation card is only as wide as its message; and the
  spinner is drawn at the released size. If playback fails, the failure card
  stays up: Return, Enter, and Select toggle pause as they do on the picture,
  Escape or the mouse closes it, and an end-of-file report from a failed player
  no longer sends the screen away.

- The Hardware Decoding setting in Marquee v3 now takes effect on the running
  player instead of waiting for the next file. A rejected change keeps the
  previous value and logs a warning without failing the session.

- Marquee v3's Home screen no longer shows a "No movies found" block inside the
  rows. An empty library says "No content found" and, while a scan runs, shows
  the scanning screen instead. A library that holds only episodes keeps the
  Home surface with its title-bar count and an empty movie grid until TV rows
  arrive.

- Marquee v3 now has TV shows. The catalog carries episodes: the scanner walks
  the TV Shows folders the way the released app does, reading the show, year,
  season, and episode from "Show (Year)/Season N/Show - S01E01 - Title.mkv"
  and the other released name shapes, carrying poster, backdrop, and season
  art from the show and season folders, and the per-episode thumbnail from
  beside the file (schema version 4 adds the episode columns with a
  single-column index on show name, media_items_show_idx, kept narrow because
  no query filters or orders by the show/season/episode triple — grouping and
  ordering happen in memory in ShowsModel). The TV Shows route lists every
  show under its genre rows
  and All Shows, each card with its season count and up-next episode, and
  Select opens the show: the backdrop hero with the title, the year, season,
  and episode facts, the genre tags, Continue Watching or Start Watching, the
  season capsules, the episode rows with their thumbnails, UP NEXT and
  WATCHED marks, and progress bars, and More Like This. Playing an episode
  shows its show and "S1 E2 · Title" in the player, records its progress
  under the episode, and when Auto-play Next Episode is on, the next episode
  follows. Settings gains the TV Shows Folders list beside the Movies one,
  and its Episodes and Sources tiles, Home's count, and the profile picker's
  count now read the real episode set.

- Marquee v3's Settings route now exists: the "Settings" header with its
  Library ready / Scan active capsule; the Movies, Episodes, Sources, and
  Image Cache tiles; the Library section with its folder rows, Add Folder
  (now a folder chooser inside the window), Online Metadata, and the Rescan
  row with the released Queued / Queue Scan / Rescan wording and status line;
  Playback with Hardware Decoding (live: the libmpv hwdec option via
  MpvVideoItem), Auto-play Next Episode (live: gates the next-episode
  handoff), the default subtitle and audio language pop-ups, and the Subtitle
  Size slider with its percentage (those three persist the released choice
  and say "Saved": no track list or subtitle overlay consumes them yet);
  Sound with Interface sounds, Launch ident, and the sound pack pop-up (all
  three persist and say "Saved": no sound subsystem exists yet, and none is
  invented); Storage with the image cache measurement and Clear Cache, Clear
  History, and Export, each with the released inline Clear / Cancel
  confirmation and two-second "Cleared"; and About with the gradient wordmark
  and version. The preferences behind those rows now persist, seeded with the
  released defaults. The whole page is reachable from the remote in reading
  order, and Left or Escape return to the sidebar.

- Marquee v3's Search route now exists: the released search bar with its
  placeholder, clear control, and focus stroke; suggestions beneath it drawn
  from the library's titles; the on-screen remote keyboard with its digit,
  letter, and Space / Delete / Clear / Done rows; the "N results for 'q'"
  line over a MOVIES grid of result cards that widen to fill their columns
  and carry a match label when a title was found by its file name; and the
  landing and "No results" states. Searching scores titles the way the
  released app does, including its fuzzy second pass, and a single character
  matches title prefixes only. The remote moves between the field,
  suggestions, keyboard, and results exactly as the released policies route
  it, and leaves for the sidebar on the same edges. Collection, director,
  cast, keyword, genre, and overview matches wait on catalog metadata; search
  still indexes movies only and does not reach the TV model yet.

- Marquee v3 now opens on the released app's profile picker: the MARQUEE
  wordmark over "Who's watching?", the library count, a row of profile discs
  with their own symbol and colour, Add Profile, and Manage Profiles. Choosing
  a profile fades the picker over the shell, which then shows that profile's
  avatar in the sidebar; the sidebar's profile control brings the picker back.
  Manage Profiles swaps the row for tiles with Edit and Delete, the editor
  offers the name, thirty avatars, and four maturity levels, and deleting asks
  first. Profiles persist beside the catalog and start as "Main" and "Kids".
  The Home wordmark is now painted the same way as the picker's, which also
  clears the notched letters it showed on the headless render path.

- Marquee v3 now keeps saying it is scanning while a second scan is still
  queued behind the one that just finished, instead of announcing the library
  is settled a moment early. The turning gold ring on the scanning screen now
  sweeps its golds around the ring as the released app does, rather than across
  it, and both it and the breathing logo stop running once that screen is no
  longer shown. The Movies page now fades out at its bottom edge, like Home and
  the released app, so a row leaving the screen is no longer cut off at the
  window's edge; scrolling, focus, and playback on that page are unchanged.

- Marquee v3's Home screen now opens on the released app's own shell instead of
  a "Library" heading over a grid. An empty library says "No content found" over
  "Content will appear once scanning completes" beneath a film icon, and a
  library still being scanned shows the turning gold ring around the breathing
  Marquee logo rather than claiming to be empty. Once there are titles, the
  MARQUEE wordmark sits in a header pinned above the surface, in the gold
  gradient of the app icon's play button, with the library's count on the right
  and a Play Something control beside it; scrolling down past the first 60
  points shrinks the wordmark and the header into a compact bar and widens the
  shadow beneath it, and scrolling back opens it again. A library being rescanned
  while it already has titles shows a "Scanning" capsule in that header and
  keeps its content on screen. A fade now covers the bottom of the page, so
  cards leave the screen instead of being cut off at its edge. Reduce Motion
  applies the header change at once and leaves the scanning ring and logo still.
  Play Something still answers "not available yet" with the same message the
  sidebar gives, because the feature that picks a title has not arrived yet.
  The episode half of the count reads zero until v3 models TV. The hero banner
  and the titled horizontal rows are still to come; the grid stands in for them
  for now, with its cards, keyboard movement, and sidebar hand-off unchanged.

- Marquee v3's sidebar now draws the released app's own icons instead of
  Unicode stand-ins: the house, magnifying glass, film, television, and gear
  for the five routes, the shuffle mark for Play Something, and the person
  outline on the profile control, each at the size, weight, and colour the
  released sidebar uses. The column, its rows, the icon frames, the paddings,
  the corner rounding, and the profile avatar are all sized from the released
  measurements in both compact and lean-back modes, so the shell no longer
  reads as a different width or rhythm on a television. A focused row's ink,
  background, ring, and lift, and the Play Something control's own focused
  fill, now match the released treatment, with the lift applied instantly
  under Reduce Motion. Screen readers now hear "Open Movies" rather than only
  "Movies", and "Switch Profile" as the profile control's hint. The profile
  control is ready to show an active profile's name, icon, and colour when
  profiles arrive, and falls back to the released person icon for any profile
  icon it cannot yet draw. Routes, focus order, the left and right hand-off to
  the content surface, and the "Play Something is not available yet" message
  are unchanged.

- Marquee v3's Movies route now shows the movie library instead of a rewrite
  status screen. The route draws a "Movies" heading with the library's title
  count beside it, over an "All Movies" row whose own header counts its length,
  ordered so a franchise's films sit together oldest first. An empty library
  says "No movies found" and names the folder being scanned rather than showing
  an empty row. Arrow keys move one clamped selection along the row, which
  scrolls to keep the focused card visible and stops at its last card rather
  than wrapping; Left at the first column and Back at the route's root return
  to the sidebar; Enter and tap open the focused card's title. A rescan that
  shortens or empties the library moves the selection onto a card that is still
  there. Resizing the window, or switching between compact and lean-back, keeps
  the focused card visible instead of leaving it clipped where the old size had
  placed it. The page scrolls as one surface: the "Movies" heading scrolls away
  with the rows instead of staying pinned above them when the library is taller
  than the window. Reduce Motion places the row and the page at once instead of
  animating them. A library holding at least two holiday titles also shows a
  "Holiday Movies" row above All Movies, recognized from the titles themselves
  the way the released app does; the released genre rows still wait on catalog
  metadata v3 does not hold yet.

- Marquee v3 movie cards now brighten their poster and title when the pointer
  is over the artwork or caption, without moving keyboard selection or showing
  focus chrome. Keyboard focus takes precedence, and Reduce Motion makes the
  hover wash change immediately.
- Marquee v3 browse cards now use leading captions and one-line year/runtime
  metadata from recorded playback durations, with year-only and empty fallbacks
  when a duration or year is absent, and visible cards refresh that runtime as
  playback records it. Focused cards match the released chrome: the artwork
  scales beneath a ring that stays inset inside the card's frame and is
  screen-blended over whatever it covers, the shadow and accent glow bloom
  outside the scaled artwork, a resting shadow sits under idle cards, and the
  focused poster is washed behind a centred chevron badge. Vertical halo room
  is reserved while horizontal pitch remains artwork width plus the released
  10/16-point gap, a card at either end of a row paints its halo into the
  page's outer padding instead of being cut at the grid boundary, and leaving
  the grid clears card focus. The details Play control uses the released
  detail focus surface: no scale, an inset ring, and a 20-point glow. A title
  without usable artwork, or with transparent artwork, now shows the released
  fallback beneath it: the gradient, film symbol, and title, plus the format
  badge on the details poster, instead of a placeholder image. The focus
  ring's blend is checked against Qt's own painter as an independent
  oracle, including where the artwork changes under it; the check now
  reaches the pixels where each straight run meets a rounded corner,
  including the joins that fall inside a pixel at the ring's own fractional
  geometry, which the covered-pixel enumeration had been skipping.
  Accessibility text scaling remains deferred until a production Qt input is
  wired.
- Marquee v3 posters now show a loading treatment while a title's artwork is
  being read, distinct from the fallback a title with no usable artwork keeps:
  the details poster shows a photo symbol over the Marquee wordmark on its own
  surface while the read is in flight, as the released detail poster does,
  while a browse card keeps showing its fallback artwork throughout, as the
  released cards do. The artwork replaces the treatment when it arrives, and
  the fallback's film artwork remains when it does not. A poster that has
  moved on to another title can no longer be changed by the previous title's
  read finishing late, so a scrolled row cannot briefly show one film's
  artwork on another film's card.
- Marquee v3 posters are now clipped to their rounded corners like the
  released cards, whether they show real artwork or the fallback beneath a
  missing, undecodable, or transparent sidecar, while the focus shadow,
  glow, and ring outside the poster stay whole; artwork that was already
  cached now paints without waiting for a repaint that never came. A movie
  card's fallback now names the file's container format, as the released
  cards and the details poster do.
- Marquee v3 now keeps a film's length once the player has learned it, so a
  resume point written before the length was known is completed as soon as
  it arrives and a momentary unknown length no longer erases it, a delayed
  catalog acknowledgement of an older resume point can no longer revert a
  newer one on screen, and the fallback artwork's film symbol survives being
  redrawn.
- Marquee v3 now reconciles a just-recorded resume point after an in-flight
  catalog refresh, and keeps the GUI event loop alive through catalog shutdown
  so queued final progress is written before the process exits.
- Marquee v3 can now restart the film it is playing. Pressing down in the
  player moves the remote off the picture and onto a Restart control in the
  HUD, where Enter or a tap sends the film back to its opening frame without
  reloading it, and pressing up hands the remote back to the picture. The HUD
  stays on screen for as long as that control holds the remote rather than
  hiding it mid-press, and Enter in front of the film still does nothing until
  the remote is moved onto the control. Restarting also puts the film's resume
  point back at its beginning, so leaving straight afterwards starts it from
  the beginning next time instead of the point it was restarted away from.
- Marquee v3 now picks a film up where it stopped. Playing a title records how
  far it got — while it plays, when it is paused, when the player is left, and
  when Marquee is closed with the film still open — and opening that title again
  starts it there instead of at the beginning. A film watched to the end is
  remembered as watched and starts over next time rather than reopening on its
  credits, a title removed from the library takes its progress with it, and a
  file opened with `marquee --play` keeps no progress because it has no library
  entry of its own.
- Marquee v3 now describes a movie before it plays one. Choosing a title in the
  library shows its poster, name, release year, file format, size, and the path
  it keeps inside its library folder, with a Play control that opens it and
  Escape or Back returning to the grid. A title whose file has gone says so when
  Play is pressed instead of opening an empty player, and a title that leaves
  the library while its details are open is reported there rather than described
  from facts that no longer hold. Returning from the details still leaves the
  grid selection at the first title.
- Marquee v3 now shows the artwork that already sits beside a movie. A poster
  named after the file, or a `poster.jpg`, `folder.jpg`, or `poster.png` in the
  movie's own folder, becomes that title's card in the library grid, and
  artwork added later appears after the next scan. A title with no artwork, or
  artwork Marquee cannot read, keeps the fallback artwork instead of a
  blank card. Artwork is only ever read from inside a configured library
  folder, and Marquee never writes to the artwork files it finds.
- Marquee v3 now browses and plays the library it scanned. Home shows every
  title as a poster card, the arrow keys move one clear selection through the
  grid, pressing left at the first column returns to the sidebar, and Enter or
  a tap opens the selected movie's details, where Play starts it. An empty
  library says so rather than showing a blank page, a title whose file has gone
  reports that instead of failing silently, and a library folder Marquee cannot
  reach is named on screen while the titles it contributed stay browsable.
- Marquee v3 now fills its library catalog from a configured movie directory.
  The scan runs off the interface thread, so browsing stays responsive while a
  root is read, and it recognizes the common video containers while ignoring
  artwork, notes, and anything inside trash or sync folders. Titles and release
  years come from the filename, each file keeps the same catalog entry across
  rescans, and a rescan adds new files, refreshes changed ones, and drops files
  that are gone. Nothing outside a configured folder can enter the library
  through a shortcut inside it, and each configured folder keeps its own
  entries: pointing Marquee at a different folder starts a new library rather
  than adopting an existing one's entries. A folder that is unplugged,
  unreadable, or only partly readable keeps everything it contributed, so a
  missing drive or a permission change never empties the library, and it stays
  browsable offline until that folder comes back.
- Marquee v3 now keeps its own library catalog: the first launch creates an
  empty SQLite catalog in the standard user data directory and applies each
  schema change as one all-or-nothing step. A catalog that cannot be opened or
  upgraded is reported as a startup error and left on disk untouched, and a
  catalog written by a newer Marquee is refused instead of misread.
- Marquee v3 now plays a local file: video is decoded by libmpv and rendered
  into the Qt Quick scene under Wayland, with a player HUD showing the title,
  progress, and playback state over the picture, remote keys for play/pause,
  skip, and stop, and `marquee --play <path>` to open a file before the catalog
  exists. Playback that fails is reported as a failure instead of appearing to
  finish normally, and video recovers by itself when the window loses and
  regains its render surface.
- Landed the first Marquee v3 slice for Omarchy/Arch Linux: a C++23/Qt 6
  application shell with a CMake/Ninja/CTest gate, XDG path ownership,
  persisted settings that surface storage errors, deterministic route and
  focus navigation with working Escape/Back remote back-navigation, and Qt
  Test suites that exercise the shipped QML module.
- Licensed Marquee under GPL-3.0, documented third-party obligations, removed
  untraceable dependency binaries and host-specific data from the publishable
  source snapshot, moved Roku network configuration outside Git, and disabled
  binary publishing until corresponding source and build provenance can be
  verified automatically.
- Made the Omarchy C++23/Qt 6/QML/libmpv/SQLite rewrite the sole active v3
  implementation plan and retired the completed Swift v2 refactor tracker;
  v2.0.1 remains available with its frozen `v2-maintenance` line.

## [2.0.1] - 2026-08-29

- Added a SwiftPM toolchain-only quality-gate path for deterministic policy and
  catalog harnesses on hosts without Xcode; unsupported app-bundle, UI,
  AVFoundation, and MPVKit suites are reported explicitly.
- Added a Player HUD control to restart the current title from the beginning.
- Added a conditional Player HUD Next Episode control that advances episodic
  playback when another episode follows and stays hidden for films and final
  episodes.
- Remote focus now glides between Home rows, detail sections, and horizontal
  card positions with a shared spring, while Reduce Motion keeps placement
  immediate.
- Sidecar subtitles now survive three common file shapes that previously
  produced garbled or missing text: cues separated by a blank line containing
  spaces no longer merge into one on-screen caption, UTF-16 `.srt` files are
  decoded instead of silently yielding no captions, and a corrupt timestamp
  field such as `00:00:0X,000` is rejected instead of being read as a
  hexadecimal number and shown at the wrong time. A `Subs` folder no longer
  yields duplicate subtitle tracks in the picker on case-insensitive volumes.
- Fixed movie and episode titles that lost their hyphenated words: `Spider-Man`
  displayed as `Spider`, `WALL-E` as `WALL`, and `X-Men` as `X`, which also sent
  the truncated title to TMDB enrichment. Release-group tags are still
  stripped, including known groups written unspaced or lowercase
  (`Movie-RARBG`, `Movie - yify`), while trailing sequel numerals such as
  `Rocky - II` are kept.
- Fixed the release year taken from scene-style filenames with release
  metadata after the year: `Blade Runner 2049.2017.1080p...` is the 2017
  release of `Blade Runner 2049` instead of `Blade Runner` from 2049, and
  `The.Matrix.1999.REMASTERED.2008` is the 1999 film rather than a 2008 one.
  A name that simply ends in a plausible year still reads it as the release
  year, so `Summer of 1984` parses as `Summer of` from 1984.
- Fixed Play Something narrowing to a single favorite as the watch history
  grows: the taste-affinity term in the shuffle weight is now capped at the
  same ceiling the hero lane already used, so a large ledger no longer
  outweighs every other candidate signal.
- Fixed Play Something repeating the same pick at every app launch: the salt
  now includes a per-press random token instead of a resetting counter, so
  each session's first press draws a distinct weighted shuffle.
- Lowercased the GitHub repository identifier and refreshed release links to
  use `hermes-os/marquee`.
- Migrated Movies and TV browse-detail remote focus to the shared
  `FocusEngine`, preserving row memory and the existing single scroll-placement
  authority.
- Reconciled the active native-refactor plan with landed history and preserved
  the legacy Phase 0b branch, stash, and detached validation worktree as
  recovery artifacts rather than active candidates.

## [2.0.0] - 2026-07-24

Originally published 2026-07-15 as build 431; republished 2026-07-20 as
build 432 with the sidebar, detail-navigation, and player HUD changes below;
republished 2026-07-24 as build 433 with the playback smoothness and display
fixes below, then as build 434 with in-app audio for the embedded player, then
as build 435 with audio-clocked playback and honest audio failure handling;
republished 2026-07-25 as build 436, which replaces the embedded player's
hand-rolled pacing with a platform-owned playback clock, then as build 437
with system-layer video presentation and hero pre-decoding, and finally as
build 438 with stable hero-card identity.

### Fixed (build 438)

- The centered hero card now keeps one stable view identity across the center
  threshold, so SwiftUI no longer tears it down and fades it back in mid-slide.

### Fixed (build 437)

- Video no longer changes brightness when the player HUD appears or
  disappears: frames are now presented by the system's video layer with an
  explicit colorspace, so appearance cannot depend on how the window is
  composited.
- HUD activity no longer causes playback jitter: frame presentation moved
  off the interface thread entirely — the system schedules every frame
  against the playback clock.
- Hero carousel cards slide with the intended spring on every advance:
  adjacent cards now pre-decode their artwork before scrolling into view.

### Changed (build 436)
- New app icon: a gold film-reel M on the purple squircle, normalized to
  the standard macOS icon grid at every size so it sits correctly in the
  Dock, Finder, and menus.

- The embedded player is now driven by the system's A/V synchronization
  clock instead of realtime-throttled decoding. Video and audio are
  timestamped and presented against one owned clock, so they cannot drift
  apart by construction, and the position readout and sidecar subtitles
  follow exactly what plays.
- Pausing the embedded player now freezes playback in place and resuming
  continues instantly — the playback process is no longer stopped and
  relaunched, so resume has no reopening delay.
- The playback speed control returned to the embedded player (0.5x–2x) with
  pitch-corrected audio; speed changes apply instantly without restarting
  playback.
- If audio output fails mid-movie, video continues on the same clock with an
  on-screen notice; the notice no longer lingers after the movie is stopped.
- A movie's final moments are no longer cut off at the end: playback ends
  only after everything buffered has actually played.

### Fixed (build 435)

- Playback position now comes from the audio actually played rather than
  wall-clock arithmetic, so the time readout and sidecar subtitles no longer
  drift away from what you hear over a long movie.
- Video and audio now stay together over long playback: the player buffers a
  fixed amount ahead and lets the audio device pace the whole pipeline,
  instead of buffering without limit and discarding audio when it fell behind
  (which permanently offset sound from picture).
- If audio output is unavailable or stops responding mid-movie, the player
  now says so on screen and keeps the picture running, instead of silently
  playing video with no sound.

### Changed (build 435)

- The playback speed control is now hidden on the embedded player, which
  cannot retime its realtime-paced output. It previously appeared and did
  nothing when selected.

### Changed (build 434)

- The embedded player's audio now plays through the app itself instead of a
  second ffmpeg output device: the bridge decodes PCM into a pipe and Marquee
  renders it with AVAudioEngine. Volume changes and mute are now instant
  mixer operations — they no longer restart the playback process, so the
  brief audio gap and picture freeze on every volume change are gone.
- Pausing now silences audio instantly, including already-buffered audio.

### Fixed (build 433)

- The screen no longer dims mid-movie and re-brightens on remote input:
  Marquee now holds a display-sleep assertion while the embedded player is
  actively playing. (AVFoundation playback already prevented display sleep;
  the embedded ffmpeg path did not.)
- Resuming from pause in the embedded player no longer fast-forwards video to
  catch up while audio lags behind. Resume reopens playback at the paused
  position instead of continuing the stopped decoder, which had desynced
  audio and video after every pause.
- Embedded video frames are now presented on the display's refresh cadence
  through a short arrival-order queue instead of racing the UI thread with
  latest-frame-wins delivery, removing intermittent judder during playback.
- Seeks, volume changes, mute, and resume in the embedded player keep the
  last video frame on screen instead of flashing black while the player
  process reopens.
- Tearing down a paused embedded player no longer stalls the app for the
  termination deadline; stopped decoder processes are continued before
  termination.
- The remote-input QA harness now pins lean-back mode, so quality-gate
  results no longer depend on how many displays are attached to the host.

### Changed

- The sidebar is now a fixed icon rail: it no longer expands, the expand
  toggle and bottom Marquee logo are gone, and the profile button shows the
  active profile's picture at a slightly larger size.
- On movie and show detail pages, pressing Left at the leftmost focus position
  now moves remote focus to the sidebar.
- When the sidebar has remote focus, Left is a boundary and does nothing;
  Back still returns focus to the content.
- The player HUD now shows the movie or show title — with the episode's
  "S# E# · Title" beneath — at the top left, just below the Back button.
- Expanded the native release tour with a pixel-validated remote-command
  Season 1 to Season 2 and back traversal using unequal episode counts,
  distinct per-episode artwork, and read-only focus evidence.

### Fixed

- Changing seasons on a show detail page now replaces the visible episode list
  immediately and keeps the first selected episode visibly focused, without
  retaining rows from the previous season.
- Switching routes from the sidebar while a Search detail page was open no
  longer leaves that stale detail page behind when returning to Search.

## [0.1.52] - 2026-07-15

### Added

- Added local similarity recommendations and a durable per-profile taste ledger
  for More Like, hero variety, and Because You Watched rows.
- Expanded search with overview indexing, typo tolerance, and scoped suggestions
  for collections, keywords, cast, directors, and genres.
- Added schema-v4 catalog intelligence for TMDB collections, keywords, and
  related-title edges.
- Added Play Something, seasonal rows, detail person rows, scoped search chips,
  and post-play handoff.
- Added a shared detail focus engine, ten-foot focus chrome, and default-on
  launch, focus, select, back, and boundary sound cues.
- Added opt-in Velvet, Hearth, and Nocturne sound-pack candidates with a global
  Settings picker and reproducible content-addressed assets.
- Added responsive profile-management tiles with remote reorder, edit, delete,
  add, and focus-retention behavior.
- Standardized structural focus chrome on the amethyst treatment across
  profiles and remote-driven surfaces.

### Changed

- Moved optional TMDB credentials out of the application bundle into host-local
  Application Support and made QA and release app assembly fail if a
  `Secrets.plist` is present.
- Retired the obsolete AV compositing guard in favor of the direct
  AVFoundation surface policy.
- Consolidated detail and browse placement around measured, clamped AppKit
  scrolling and isolated automated QA from the live catalog and playback
  cache.
- Replaced duplicated planning/review records and the 20–40 minute
  every-change gate with canonical docs, one active plan, and focused/full/
  release QA tiers; generated framework identity no longer requires two
  multi-gigabyte content scans per build.
- Made Home composition stable from first publish, reveal hero content only
  after current artwork decode or terminal fallback, and coalesce rapid AppKit
  scroll requests to the latest destination.
- Reworked Search around an immutable value-only worker index, background
  latest-query ranking, atomic result publication, stable media focus identity,
  and row-aware remote traversal; detail person rows and episodes now use lazy,
  cached, measured placement paths.

### Fixed

- Fixed detail reading-band placement, same-row scroll jumps, stale episode
  geometry, hidden search-result reachability, poster aspect fill, focus-ring
  clipping, and browse placement after returning to a surface.
- Kept Play Something constrained to the active profile's maturity-filtered
  library.
- Fixed stale hero-image completions, duplicate fallback wordmarks, clipped
  five-profile management layouts, and stale queued scroll motion after a
  controller reattaches.
- Fixed Home hero artwork remaining hidden until scrolling, stale Search cards
  appearing under the final query, unreachable first detail-person rows, and
  slow episode escape. Player Back is now remotely reachable, the duplicate
  bottom close control is removed, and HUD focus is substantially clearer.
- Kept the player seek canvas reachable between Back and the remembered
  transport control, refresh deferred movie/show-detail person and similarity
  rows whenever the live catalog presentation changes, and prevent delayed
  Search results from overriding a newer navigation choice.
- Removed the redundant Search debounce now that ranking runs on a cancellable
  background worker, restoring immediate indexed-result publication.

## [0.1.51] - 2026-07-05

- Consolidated remote-input ownership, finite/clamped scroll geometry, shared
  Movies/TV browse control, and search focus ownership.
- Decomposed application state into `AppRouter`, `PlaybackSession`,
  `ProfileSession`, and `LibraryState`, and split the large search view into
  focused components.
- Added condition-polled performance probes, accelerated profile-driven browse
  snapshots, fixed stale kids-filtered results after switching to an adult
  profile, and restored visible detail focus on macOS 12.

## [0.1.48] - 2026-06-30

- Restored the native release lineage and hardened the Monterey-compatible
  build and QA path.
- Improved remote traversal across episodes, profiles, Home, and browse
  surfaces.
- Added the on-screen remote search keyboard and fixed suggestion-grid focus;
  also improved browse intelligence and release icon sizing.

## [0.1.40] - 2026-06-16

- Added app-wide type-to-search and adaptive remote reading-band placement.
- Improved startup with projected-cache restore, local-first scanning, deferred
  metadata enrichment, and incremental watch-progress updates.
- Stabilized media identity across rescans and tightened maturity filtering,
  TMDB matching, subtitle discovery, episode parsing, image decoding, and
  player/scanner concurrency.

## [0.1.32] - 2026-05-12

- Unified lean-back remote launch, selection, back, Home, browse, and scrub
  behavior.
- Fixed focus scrolling and row placement across Home and detail surfaces, and
  made living-room input selection retryable.

## [0.1.20] - 2026-05-10

- Added lean-back remote navigation and cleaned up playback probing.
- Improved episode titles and thumbnails, show routing, Play versus Resume
  behavior, back-navigation state, and prepared-playback stability.

## [0.1.18] - 2026-05-04

- Added and stabilized prepared multiformat playback, including embedded bridge
  routing for unsupported containers and tagged HEVC media.
- Fixed helper teardown, attached-picture fallback, fullscreen AV tint,
  playback-cache placement, and playback-dismiss crashes.

## [0.1.0] - 2026-04-30

- Established the native offline movie and TV experience with household
  profiles, maturity filtering, search, details, sidecar artwork, watch
  progress, and multitrack playback.
- Replaced the legacy scan path with the durable schema-v3 SQLite catalog,
  resumable diff scanning, catalog projection, and background TMDB enrichment.
- Added reproducible local builds, diagnostics, patched-player restoration, and
  installable DMG packaging.

[Unreleased]: https://github.com/hermes-os/marquee/compare/v2.0.1...HEAD
[2.0.1]: https://github.com/hermes-os/marquee/compare/v2.0.0...v2.0.1
[2.0.0]: https://github.com/hermes-os/marquee/compare/v0.1.52...v2.0.0
[0.1.52]: https://github.com/hermes-os/marquee/compare/v0.1.51...v0.1.52
[0.1.51]: https://github.com/hermes-os/marquee/compare/v0.1.48...v0.1.51
[0.1.48]: https://github.com/hermes-os/marquee/compare/v0.1.40...v0.1.48
[0.1.40]: https://github.com/hermes-os/marquee/compare/v0.1.32...v0.1.40
[0.1.32]: https://github.com/hermes-os/marquee/compare/v0.1.20...v0.1.32
[0.1.20]: https://github.com/hermes-os/marquee/compare/v0.1.18...v0.1.20
[0.1.18]: https://github.com/hermes-os/marquee/compare/v0.1.0...v0.1.18
[0.1.0]: https://github.com/hermes-os/marquee/releases/tag/v0.1.0
