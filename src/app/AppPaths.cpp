#include "app/AppPaths.hpp"

#include <QDir>
#include <QStandardPaths>
#include <QStringList>

#include <stdexcept>

namespace
{
QString gRuntimeRootOverride;

[[nodiscard]] QString baseDirectory(QStandardPaths::StandardLocation location)
{
    if (!gRuntimeRootOverride.isEmpty()) {
        return gRuntimeRootOverride;
    }
    return QStandardPaths::writableLocation(location);
}

[[nodiscard]] QString requirePath(QStandardPaths::StandardLocation location)
{
    const QString path = [location]() -> QString {
        switch (location) {
        case QStandardPaths::AppConfigLocation:
            return QDir(baseDirectory(QStandardPaths::AppConfigLocation))
                .filePath(QStringLiteral("config"));
        case QStandardPaths::AppDataLocation:
            return QDir(baseDirectory(QStandardPaths::AppDataLocation))
                .filePath(QStringLiteral("data"));
        case QStandardPaths::CacheLocation:
            return QDir(baseDirectory(QStandardPaths::CacheLocation))
                .filePath(QStringLiteral("cache"));
        default:
            return QDir(baseDirectory(QStandardPaths::AppConfigLocation))
                .filePath(QStringLiteral("unknown"));
        }
    }();
    if (path.isEmpty()) {
        throw std::runtime_error("Qt returned an empty writable path");
    }
    return path;
}
}

QString AppPaths::configDirectory()
{
    return requirePath(QStandardPaths::AppConfigLocation);
}

QString AppPaths::dataDirectory()
{
    return requirePath(QStandardPaths::AppDataLocation);
}

QString AppPaths::cacheDirectory()
{
    return requirePath(QStandardPaths::CacheLocation);
}

QString AppPaths::settingsFile()
{
    return QDir(configDirectory()).filePath(QStringLiteral("marquee.ini"));
}

QString AppPaths::catalogFile()
{
    return QDir(dataDirectory()).filePath(QStringLiteral("catalog.sqlite"));
}

QString AppPaths::profilesFile()
{
    return QDir(dataDirectory()).filePath(QStringLiteral("profiles.json"));
}

QString AppPaths::artworkCacheDirectory()
{
    return QDir(cacheDirectory()).filePath(QStringLiteral("artwork"));
}

QString AppPaths::thumbnailCacheDirectory()
{
    return QDir(cacheDirectory()).filePath(QStringLiteral("thumbnails"));
}

void AppPaths::ensureDirectories()
{
    const QStringList paths{
        configDirectory(),
        dataDirectory(),
        cacheDirectory(),
        artworkCacheDirectory(),
        thumbnailCacheDirectory()
    };

    for (const QString &path : paths) {
        if (!QDir().mkpath(path)) {
            throw std::runtime_error(
                QStringLiteral("Unable to create %1").arg(path).toStdString());
        }
    }
}

void AppPaths::setRuntimeRoot(const QString &path)
{
    gRuntimeRootOverride = path;
}

void AppPaths::clearRuntimeRoot()
{
    gRuntimeRootOverride.clear();
}
