#include "models/StableRandom.hpp"

#include <QByteArray>

std::uint64_t stable_random::stableHash(const QString &value)
{
    std::uint64_t hash = 1'469'598'103'934'665'603ULL;
    const QByteArray bytes = value.toUtf8();
    for (const char byte : bytes) {
        hash ^= static_cast<std::uint8_t>(byte);
        hash *= 1'099'511'628'211ULL;
    }
    return hash;
}

double stable_random::deterministicUnitInterval(const QString &value)
{
    return (static_cast<double>(stableHash(value) % 1'000'000ULL) + 1.0) / 1'000'001.0;
}
