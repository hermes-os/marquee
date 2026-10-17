#pragma once

#include <QMetaType>
#include <QString>
#include <QStringList>

/// A configured library location. The identity is generated once and stored, so
/// catalog rows survive the same directory being remounted under different
/// device details.
struct LibraryRoot
{
    /// LibraryState.swift:451-460 walks each configured folder under the role
    /// of the list it came from, and that role decides what its files are.
    enum class Role { Movies, TvShows };

    QString id;
    QString path;
    QString displayName;
    bool available{false};
    Role role{Role::Movies};
};

/// The configured folders, split the way UserSettings.swift:155-156 stores
/// them. The worker registers both lists in one refresh so a single
/// projection covers the whole library.
struct LibraryRootPaths
{
    QStringList movies;
    QStringList tvShows;

    bool operator==(const LibraryRootPaths &) const = default;
};
Q_DECLARE_METATYPE(LibraryRootPaths)
