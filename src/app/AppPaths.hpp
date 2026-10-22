#pragma once

#include <QString>

class AppPaths final
{
public:
    [[nodiscard]] static QString configDirectory();
    [[nodiscard]] static QString dataDirectory();
    [[nodiscard]] static QString cacheDirectory();

    [[nodiscard]] static QString settingsFile();
    /// The one-line TMDB v3 key file beside `marquee.ini`.
    [[nodiscard]] static QString tmdbKeyFile();
    [[nodiscard]] static QString catalogFile();
    [[nodiscard]] static QString profilesFile();
    [[nodiscard]] static QString artworkCacheDirectory();
    [[nodiscard]] static QString thumbnailCacheDirectory();

    static void setRuntimeRoot(const QString &path);
    static void clearRuntimeRoot();
    /// Whether a test runtime root replaces the user's directories.
    [[nodiscard]] static bool hasRuntimeRoot();

    static void ensureDirectories();
};
