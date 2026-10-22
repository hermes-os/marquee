#include "metadata/ArtworkCache.hpp"

#include <QBuffer>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QImage>
#include <QImageReader>
#include <QRegularExpression>
#include <QSaveFile>

#include "support/Logging.hpp"

namespace
{
// The released app re-encodes thumbnails at compression factor 0.85
// (ImageCacheService.swift:204).
constexpr int kThumbnailQuality = 85;

// A decoded image the size of a few hundred megapixels is not artwork.
constexpr int kMaxEdgePixels = 12'000;

[[nodiscard]] bool writeAtomically(const QString &path, const QByteArray &bytes)
{
    QSaveFile file(path);
    if (!file.open(QIODevice::WriteOnly)) {
        return false;
    }
    if (file.write(bytes) != bytes.size()) {
        file.cancelWriting();
        return false;
    }
    return file.commit();
}

[[nodiscard]] QString cleanPath(const QString &path)
{
    return QDir::cleanPath(QFileInfo(path).absoluteFilePath());
}
}

int artwork_cache::thumbnailWidth(Kind kind)
{
    return kind == Kind::Poster ? 300 : 800;
}

QString artwork_cache::stem(const QString &ownerKind, int tmdbId, Kind kind)
{
    const char *suffix = kind == Kind::Poster ? "poster" : kind == Kind::Backdrop ? "backdrop" : "still";
    return QStringLiteral("%1-%2-%3").arg(ownerKind).arg(tmdbId).arg(QLatin1String(suffix));
}

QString artwork_cache::episodeStillStem(int tmdbShowId, int season, int episode)
{
    return QStringLiteral("tv-%1-s%2e%3-still").arg(tmdbShowId).arg(season).arg(episode);
}

QString artwork_cache::fullFileName(const QString &stem)
{
    return stem + QStringLiteral(".jpg");
}

QString artwork_cache::thumbnailFileName(const QString &stem)
{
    return stem + QStringLiteral("-thumb.jpg");
}

bool artwork_cache::isSafeRemotePath(const QString &remotePath)
{
    static const QRegularExpression safe(QStringLiteral(R"(^/[A-Za-z0-9][A-Za-z0-9._-]*$)"));
    return safe.match(remotePath).hasMatch();
}

bool artwork_cache::isInsideAny(const QString &path, const QStringList &roots)
{
    const QString target = cleanPath(path);
    for (const QString &root : roots) {
        if (root.trimmed().isEmpty()) {
            continue;
        }
        const QString base = cleanPath(root);
        if (target == base || target.startsWith(base + QLatin1Char('/'))
            || base == QLatin1String("/")) {
            return true;
        }
    }
    return false;
}

QString artwork_cache::store(const QByteArray &bytes,
                             const QString &stem,
                             Kind kind,
                             const QString &fullDirectory,
                             const QString &thumbnailDirectory)
{
    QBuffer buffer;
    buffer.setData(bytes);
    buffer.open(QIODevice::ReadOnly);
    QImageReader reader(&buffer);
    const QSize size = reader.size();
    if (size.isValid() && (size.width() > kMaxEdgePixels || size.height() > kMaxEdgePixels)) {
        qCWarning(logArtwork) << "refused an oversized image";
        return {};
    }
    const QImage image = reader.read();
    if (image.isNull() || image.width() <= 0 || image.height() <= 0) {
        qCWarning(logArtwork) << "downloaded bytes are not an image";
        return {};
    }

    if (!QDir().mkpath(fullDirectory) || !QDir().mkpath(thumbnailDirectory)) {
        qCWarning(logArtwork) << "cannot create the artwork cache directories";
        return {};
    }

    const QImage thumbnail = image.width() > thumbnailWidth(kind)
        ? image.scaledToWidth(thumbnailWidth(kind), Qt::SmoothTransformation)
        : image;
    QByteArray thumbnailBytes;
    QBuffer thumbnailBuffer(&thumbnailBytes);
    thumbnailBuffer.open(QIODevice::WriteOnly);
    if (!thumbnail.save(&thumbnailBuffer, "JPEG", kThumbnailQuality)) {
        qCWarning(logArtwork) << "cannot encode a thumbnail";
        return {};
    }

    // The full-size file goes first: the thumbnail is the marker that the
    // image is cached, so a crash between the two leaves it uncached.
    if (!writeAtomically(QDir(fullDirectory).filePath(fullFileName(stem)), bytes)) {
        qCWarning(logArtwork) << "cannot write the full-size image";
        return {};
    }
    const QString thumbnailName = thumbnailFileName(stem);
    if (!writeAtomically(QDir(thumbnailDirectory).filePath(thumbnailName), thumbnailBytes)) {
        qCWarning(logArtwork) << "cannot write the thumbnail";
        return {};
    }
    return thumbnailName;
}
