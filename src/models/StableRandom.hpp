#pragma once

#include <QString>

#include <cstdint>

/// The stable shuffle behind Play Something and the seasonal rows: the same
/// text always gives the same number, so a row keeps its order until its salt
/// (a day, or a viewing that changes what is unwatched) changes.
namespace stable_random
{
/// BrowseSnapshotStore.swift:701-708: FNV-1a over the UTF-8 bytes.
[[nodiscard]] std::uint64_t stableHash(const QString &value);

/// BrowseSnapshotStore.swift:696-699: a number in (0, 1) fixed by the text.
[[nodiscard]] double deterministicUnitInterval(const QString &value);
}
