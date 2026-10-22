#include "metadata/TmdbApiKey.hpp"

#include <QFile>
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

QString tmdb_key::load()
{
    QString environmentValue;
    if (!AppPaths::hasRuntimeRoot()) {
        environmentValue = QString::fromLocal8Bit(qgetenv(environmentVariable));
    }
    QString keyFile;
    try {
        keyFile = AppPaths::tmdbKeyFile();
    } catch (const std::exception &) {
        // No config folder means no key file; the environment may still hold one.
    }
    return resolve(environmentValue, keyFile);
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

QString tmdb_key::scrub(const QString &text, const QString &key)
{
    if (key.isEmpty()) {
        return text;
    }
    QString result = text;
    result.replace(key, QStringLiteral("***"));
    return result;
}
