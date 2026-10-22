#include "metadata/TmdbApiKey.hpp"

#include <QFile>
#include <QStandardPaths>
#include <QUrlQuery>

#include "app/AppPaths.hpp"

QString tmdb_key::resolve(const QString &environmentValue, const QString &keyFilePath)
{
    const QString fromEnvironment = environmentValue.trimmed();
    if (!fromEnvironment.isEmpty()) {
        return fromEnvironment;
    }

    QFile file(keyFilePath);
    if (keyFilePath.isEmpty() || !file.open(QIODevice::ReadOnly | QIODevice::Text)) {
        return {};
    }
    // One line; anything after the first line break is not part of the key.
    return QString::fromUtf8(file.readLine(1024)).trimmed();
}

namespace
{
[[nodiscard]] QString keyFilePath()
{
    try {
        return AppPaths::tmdbKeyFile();
    } catch (const std::exception &) {
        // No config folder means no key file; the environment may still hold one.
        return {};
    }
}

// A test never reads the developer's real key, so it cannot reach TMDB.
[[nodiscard]] bool environmentIsIgnored()
{
    return AppPaths::hasRuntimeRoot() || QStandardPaths::isTestModeEnabled();
}
}

QString tmdb_key::load()
{
    return resolve(environmentIsIgnored() ? QString()
                                          : QString::fromLocal8Bit(qgetenv(environmentVariable)),
                   keyFilePath());
}

std::function<QString()> tmdb_key::provider()
{
    const bool ignoreEnvironment = environmentIsIgnored();
    const QString keyFile = keyFilePath();
    return [ignoreEnvironment, keyFile] {
        return resolve(ignoreEnvironment ? QString()
                                         : QString::fromLocal8Bit(qgetenv(environmentVariable)),
                       keyFile);
    };
}

QString tmdb_key::masked(const QUrl &url)
{
    QUrlQuery query(url);
    if (query.hasQueryItem(QStringLiteral("api_key"))) {
        query.removeAllQueryItems(QStringLiteral("api_key"));
        query.addQueryItem(QStringLiteral("api_key"), QStringLiteral("***"));
    }
    QUrl copy = url;
    copy.setQuery(query);
    return copy.toString(QUrl::FullyEncoded);
}
