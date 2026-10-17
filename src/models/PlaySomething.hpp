#pragma once

#include <QString>
#include <QVector>

#include <optional>

#include "catalog/MediaItem.hpp"

/// The pick behind Play Something, as plain functions over projected items.
/// Like `home_rows`, every function reads the watch state the items carry,
/// which is the active profile's alone (`CatalogStore::projection` joins one
/// profile's progress), and none of them filters by maturity: the caller hands
/// in only what the profile may see, so a Kids profile is never offered a
/// title its policy hides.
///
/// The rules follow `BrowseLeanBackDelightPolicy` in
/// `BrowseSnapshotStore.swift:369-420` and `:563-600`: the unwatched titles,
/// each given a weighted random key, taken in key order. Two differences are
/// deliberate:
///  - Only movies are eligible. The oracle also offers each show's up-next
///    episode; docs/ARCHITECTURE_V3.md ("Play Something is movie-only") says
///    no episode may ever be picked.
///  - The weight reads only what a v3 catalog holds. The oracle adds taste
///    affinity, vote average, popularity, and backdrop art, none of which the
///    catalog stores yet; the poster term is kept.
namespace play_something
{
/// The Home row's id, `BrowseLeanBackDelightPolicy.playSomethingRowID`.
inline constexpr auto kRowId = "play-something";

/// The Home row holds at most this many of the candidates
/// (`playSomethingRow`'s `limit`, BrowseSnapshotStore.swift:376).
inline constexpr int kRowLimit = 12;

/// The salt the Home row draws with (`salt: String = "home"`, :375): the row is
/// the same shuffle until a viewing or a rescan changes what is unwatched.
inline const QString kHomeSalt = QStringLiteral("home");

/// Eligible titles in pick order: unwatched movies, the weighted shuffle of
/// `salt` (BrowseSnapshotStore.swift:563-575). A title is drawn once, so no
/// title repeats within the order, and the same items and salt always give the
/// same order. Empty when nothing is eligible.
[[nodiscard]] QVector<MediaItem> candidates(const QVector<MediaItem> &items, const QString &salt);

/// The first of `candidates`, or nothing when the library holds no unwatched
/// movie (the oracle then does nothing, AppState.swift:236). A press draws a
/// fresh salt (AppState.swift:239-240), so consecutive presses differ; like the
/// oracle, v3 does not remember the previous pick, and the salt is the one
/// injectable source of randomness.
[[nodiscard]] std::optional<MediaItem> pick(const QVector<MediaItem> &items, const QString &salt);
}
