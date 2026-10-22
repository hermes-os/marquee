#pragma once

#include <QString>

namespace browse
{
/// BrowseSnapshotStore.swift:1784-1802: folds diacritics and width,
/// lowercases, and reduces every run of non-alphanumerics to one space.
[[nodiscard]] QString normalizedText(const QString &value);

/// BrowseSnapshotStore.swift:1824-1862: the compact franchise rules first,
/// then a leading token long enough to stand on its own, then the first two
/// meaningful tokens. An empty key means the title has no family of its own.
[[nodiscard]] QString franchiseKey(const QString &title);

/// BrowseSnapshotStore.swift:2073-2101: a title's holiday signal, 100 for a
/// direct keyword, 86 for a named holiday film, otherwise 0. The released
/// score also reads genres and the overview, which the v3 catalog does not
/// hold, so it runs over the title alone. Movies' Holiday Movies row and the
/// hero's Holiday Pick both ask it.
[[nodiscard]] int holidayScore(const QString &title);
}
