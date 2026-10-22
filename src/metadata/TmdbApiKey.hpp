#pragma once

#include <QString>
#include <QUrl>

/// The TMDB v3 `api_key`, which is a secret: it is read at run time, held in
/// memory, and never written to a log, an error message, the catalog, a
/// setting, or the UI.
namespace tmdb_key
{
inline constexpr const char *environmentVariable = "MARQUEE_TMDB_API_KEY";

/// The key, or an empty string when there is none. `environmentValue` wins;
/// otherwise the first line of the file at `keyFilePath`. Surrounding
/// whitespace is dropped, so a trailing newline is not part of the key. A
/// missing or unreadable file means no key.
[[nodiscard]] QString resolve(const QString &environmentValue, const QString &keyFilePath);

/// The key the running app uses: the environment variable, then the
/// `tmdb-api-key` file in the config folder beside `marquee.ini`. When a test
/// runtime root is set the environment variable is ignored, so a developer's
/// real key can never send a test to the network.
[[nodiscard]] QString load();

/// `url` with the `api_key` value replaced, for logs and diagnostics.
[[nodiscard]] QString masked(const QUrl &url);
/// `text` with every occurrence of `key` replaced; a no-op for an empty key.
[[nodiscard]] QString scrub(const QString &text, const QString &key);
}
