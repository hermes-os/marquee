#pragma once

#include <QHashFunctions>
#include <QString>
#include <QtTypes>

#include <optional>

/// Which file's data a path reaches, whatever the path is: two hard links, or
/// one disk mounted at two paths, carry the same device and inode.
struct FileIdentity
{
    quint64 device{0};
    quint64 inode{0};

    friend bool operator==(const FileIdentity &, const FileIdentity &) = default;
};

[[nodiscard]] inline size_t qHash(const FileIdentity &identity, size_t seed = 0) noexcept
{
    return qHashMulti(seed, identity.device, identity.inode);
}

/// The identity of the file `path` resolves to, following symlinks, or nothing
/// when it cannot be read.
[[nodiscard]] std::optional<FileIdentity> readFileIdentity(const QString &path);
