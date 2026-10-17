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
}
