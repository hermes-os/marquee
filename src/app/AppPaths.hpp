#pragma once

#include <QString>

class AppPaths final
{
public:
    [[nodiscard]] static QString configDirectory();
    [[nodiscard]] static QString dataDirectory();
    [[nodiscard]] static QString cacheDirectory();

    [[nodiscard]] static QString settingsFile();
    [[nodiscard]] static QString catalogFile();
    [[nodiscard]] static QString profilesFile();
    [[nodiscard]] static QString artworkCacheDirectory();
    [[nodiscard]] static QString thumbnailCacheDirectory();

    static void setRuntimeRoot(const QString &path);
    static void clearRuntimeRoot();

    static void ensureDirectories();
};
