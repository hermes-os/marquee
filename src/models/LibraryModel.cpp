#include "models/LibraryModel.hpp"

#include <QCollator>
#include <QFileInfo>
#include <QStringList>
#include <QUrl>

#include <algorithm>
#include <cstdlib>
#include <iterator>
#include <limits>
#include <utility>

#include "models/BrowseSemantics.hpp"
#include "models/TitleMetadataView.hpp"

namespace
{
// An empty URL means the title has no local artwork; the surface that draws it
// owns the placeholder, which lives in the QML module's own resources.
[[nodiscard]] QUrl posterUrlOf(const MediaItem &item)
{
    // A local sidecar wins; the cached TMDB poster only fills its absence.
    const QString poster = item.displayPosterPath();
    return poster.isEmpty() ? QUrl() : QUrl::fromLocalFile(poster);
}

// MediaItem.swift:143-151 derives displayRuntime from duration in seconds,
// truncating to whole minutes before choosing the hour/minute form.
// Marquee/Models/MediaItem.swift:191-192: the file extension, uppercased.
[[nodiscard]] QString formatBadgeOf(const MediaItem &item)
{
    return QFileInfo(item.relativePath).suffix().toUpper();
}

[[nodiscard]] QString displayRuntimeOf(qint64 durationSeconds)
{
    if (durationSeconds <= 0) {
        return {};
    }

    const qint64 totalMinutes = durationSeconds / 60;
    const qint64 hours = totalMinutes / 60;
    const qint64 minutes = totalMinutes % 60;
    if (hours > 0) {
        return QStringLiteral("%1h %2m").arg(hours).arg(minutes);
    }
    return QStringLiteral("%1m").arg(minutes);
}

// TimeInterval+Marquee.swift:6-16: a finite non-negative position as M:SS,
// or H:MM:SS past the hour; anything else reads as the start.
[[nodiscard]] QString formattedResumeTime(qint64 positionMs)
{
    if (positionMs < 0) {
        return QStringLiteral("0:00");
    }
    const qint64 totalSeconds = positionMs / 1000;
    const qint64 hours = totalSeconds / 3600;
    const qint64 minutes = (totalSeconds % 3600) / 60;
    const qint64 seconds = totalSeconds % 60;
    if (hours > 0) {
        return QStringLiteral("%1:%2:%3")
            .arg(hours)
            .arg(minutes, 2, 10, QLatin1Char('0'))
            .arg(seconds, 2, 10, QLatin1Char('0'));
    }
    return QStringLiteral("%1:%2")
        .arg(minutes)
        .arg(seconds, 2, 10, QLatin1Char('0'));
}

// MovieDetailView.swift:424-447: the Resume action appears only for a title
// with a position that is not watched, labelled with that position.
[[nodiscard]] QString metadataOf(const MediaItem &item)
{
    QStringList parts;
    if (item.year > 0) {
        parts.push_back(QString::number(item.year));
    }
    const QString runtime = displayRuntimeOf(item.durationSeconds);
    if (!runtime.isEmpty()) {
        parts.push_back(runtime);
    }
    return parts.join(QLatin1Char(' '));
}

// A movie is sized in gigabytes once it reaches one and in whole megabytes
// below that, as the released application sizes it.
[[nodiscard]] QString formatFileSize(qint64 bytes)
{
    constexpr qint64 bytesPerGigabyte = 1024LL * 1024 * 1024;
    constexpr qint64 bytesPerMegabyte = 1024LL * 1024;

    if (bytes >= bytesPerGigabyte) {
        return QStringLiteral("%1 GB").arg(
            QString::number(static_cast<double>(bytes) / bytesPerGigabyte, 'f', 1));
    }
    return QStringLiteral("%1 MB").arg(
        qRound64(static_cast<double>(bytes) / bytesPerMegabyte));
}
}

LibraryModel::LibraryModel(QObject *parent)
    : QAbstractListModel(parent)
{
}

int LibraryModel::rowCount(const QModelIndex &parent) const
{
    return parent.isValid() ? 0 : static_cast<int>(m_items.size());
}

QVariant LibraryModel::data(const QModelIndex &index, int role) const
{
    if (!index.isValid() || index.row() < 0 || index.row() >= m_items.size()) {
        return {};
    }

    const MediaItem &item = m_items.at(index.row());

    switch (role) {
    case IdRole:
        return item.id;
    case TitleRole:
        return item.title;
    case YearRole:
        return item.year;
    case KindRole:
        return item.mediaKind;
    case PosterUrlRole:
        return posterUrlOf(item);
    case MetadataRole:
        return metadataOf(item);
    case FormatBadgeRole:
        return formatBadgeOf(item);
    case HasMetadataRole:
        return title_metadata_view::has(item);
    case TmdbIdRole:
        return title_metadata_view::tmdbId(item);
    case OverviewRole:
        return title_metadata_view::overview(item);
    case DirectorRole:
        return title_metadata_view::director(item);
    case CertificationRole:
        return title_metadata_view::certification(item);
    case ReleaseDateRole:
        return title_metadata_view::releaseDate(item);
    case VoteAverageRole:
        return title_metadata_view::voteAverage(item);
    case VoteCountRole:
        return title_metadata_view::voteCount(item);
    case PopularityRole:
        return title_metadata_view::popularity(item);
    case CollectionIdRole:
        return title_metadata_view::collectionId(item);
    case CollectionNameRole:
        return title_metadata_view::collectionName(item);
    case RuntimeMinutesRole:
        return title_metadata_view::runtimeMinutes(item);
    case GenresRole:
        return title_metadata_view::genres(item);
    case CastRole:
        return title_metadata_view::cast(item);
    case KeywordsRole:
        return title_metadata_view::keywords(item);
    case BackdropUrlRole:
        return title_metadata_view::backdropUrl(item);
    default:
        return {};
    }
}

QHash<int, QByteArray> LibraryModel::roleNames() const
{
    return {{IdRole, "mediaId"},
            {TitleRole, "title"},
            {YearRole, "year"},
            {KindRole, "mediaKind"},
            {PosterUrlRole, "posterUrl"},
            {MetadataRole, "metadata"},
            {FormatBadgeRole, "formatBadge"},
            {HasMetadataRole, "hasMetadata"},
            {TmdbIdRole, "tmdbId"},
            {OverviewRole, "overview"},
            {DirectorRole, "director"},
            {CertificationRole, "certification"},
            {ReleaseDateRole, "releaseDate"},
            {VoteAverageRole, "voteAverage"},
            {VoteCountRole, "voteCount"},
            {PopularityRole, "popularity"},
            {CollectionIdRole, "collectionId"},
            {CollectionNameRole, "collectionName"},
            {RuntimeMinutesRole, "runtimeMinutes"},
            {GenresRole, "genres"},
            {CastRole, "cast"},
            {KeywordsRole, "keywords"},
            {BackdropUrlRole, "backdropUrl"}};
}

int LibraryModel::titleCount() const
{
    return static_cast<int>(m_items.size());
}

std::optional<MediaItem> LibraryModel::itemForId(const QString &mediaId) const
{
    const auto match = std::find_if(
        m_items.cbegin(), m_items.cend(), [&mediaId](const MediaItem &item) {
            return item.id == mediaId;
        });
    if (match == m_items.cend()) {
        return std::nullopt;
    }
    return *match;
}

QVariantMap LibraryModel::detailsForId(const QString &mediaId) const
{
    const std::optional<MediaItem> item = itemForId(mediaId);
    if (!item) {
        return {};
    }

    QVariantMap details = title_metadata_view::toMap(*item);
    // Keys below win over a metadata key of the same name.
    const QVariantMap facts = {{QStringLiteral("mediaId"), item->id},
            {QStringLiteral("title"), item->title},
            {QStringLiteral("year"), item->year},
            {QStringLiteral("posterUrl"), posterUrlOf(*item)},
            {QStringLiteral("formatBadge"), formatBadgeOf(*item)},
            {QStringLiteral("fileSizeText"), formatFileSize(item->fileSize)},
            // The path a title keeps inside its library, which says where the
            // file is without recording where its root is currently mounted.
            {QStringLiteral("relativePath"), item->relativePath},
            // MovieDetailView.swift:424-447: the Resume action exists only for
            // a title with a position that is not watched, and reads the
            // recorded position through TimeInterval+Marquee.swift:6-16.
            {QStringLiteral("hasResume"), item->hasProgress()},
            {QStringLiteral("resumeTime"), item->hasProgress()
                                               ? formattedResumeTime(item->resumePositionMs)
                                               : QString()},
            // The runtime the hero's metadata line draws once a viewing
            // records it. Zero means it is unknown, which the surface renders
            // by leaving that slot out exactly as the oracle leaves an absent
            // runtime out.
            {QStringLiteral("runtime"), displayRuntimeOf(item->durationSeconds)}};
    for (auto fact = facts.cbegin(); fact != facts.cend(); ++fact) {
        details.insert(fact.key(), fact.value());
    }
    return details;
}

// BrowseSnapshotStore.swift:148-159, through BrowseRecommendationEngine's
// franchise-first ranking with the decade term: up to `limit` other movies
// ordered by shared franchise then shared decade. No metadata exists to score
// beyond those terms, so ties and the no-signal case hold the browse order
// (BrowseSnapshotStore.swift:2016-2041: franchise family, then year
// ascending with unknown years last, then title), and a library that yields
// no scored candidate answers with an empty list, which the surface renders
// as the oracle renders an empty `similar` (it draws nothing).
QVariantList LibraryModel::similarMovies(const QString &mediaId, int limit) const
{
    const std::optional<MediaItem> source = itemForId(mediaId);
    if (!source || limit <= 0) {
        return {};
    }

    struct Ranked
    {
        const MediaItem *item;
        int score;
        QString family;
    };

    const QString sourceFamily = browse::franchiseKey(source->title);
    const int sourceDecade = source->year > 0 ? source->year / 10 : 0;

    QVector<Ranked> ranked;
    for (const MediaItem &candidate : m_items) {
        if (candidate.id == source->id) {
            continue;
        }
        int score = 0;
        const QString candidateFamily = browse::franchiseKey(candidate.title);
        if (!sourceFamily.isEmpty() && candidateFamily == sourceFamily) {
            score += 1000;
            if (source->year > 0 && candidate.year > 0) {
                score += std::max(
                    0, 80 - std::abs(candidate.year - source->year) * 4);
            }
        }
        if (sourceDecade > 0 && candidate.year / 10 == sourceDecade) {
            score += 20;
        }
        if (score > 0) {
            // movieBrowseSortKey (BrowseSnapshotStore.swift:2027-2033):
            // a title with no family of its own sorts by its normalized
            // title.
            ranked.push_back({&candidate, score,
                              candidateFamily.isEmpty()
                                  ? browse::normalizedText(candidate.title)
                                  : candidateFamily});
        }
    }

    QCollator familyCollator;
    familyCollator.setCaseSensitivity(Qt::CaseInsensitive);
    std::stable_sort(ranked.begin(), ranked.end(),
                     [&familyCollator](const Ranked &left, const Ranked &right) {
                         if (left.score != right.score) {
                             return left.score > right.score;
                         }
                         // BrowseSnapshotStore.swift:2034-2042 compares families
                         // with localizedCaseInsensitiveCompare even after
                         // normalization. Collation-equivalent keys fall through
                         // to year (unknown last), title, then id, preserving
                         // strict, deterministic tie-breaking.
                         const int familyOrder =
                             familyCollator.compare(left.family, right.family);
                         if (familyOrder != 0) {
                             return familyOrder < 0;
                         }
                         const int leftYear = left.item->year > 0
                             ? left.item->year
                             : std::numeric_limits<int>::max();
                         const int rightYear = right.item->year > 0
                             ? right.item->year
                             : std::numeric_limits<int>::max();
                         if (leftYear != rightYear) {
                             return leftYear < rightYear;
                         }
                         const int titleOrder =
                             QString::compare(left.item->title, right.item->title,
                                              Qt::CaseInsensitive);
                         if (titleOrder != 0) {
                             return titleOrder < 0;
                         }
                         return left.item->id < right.item->id;
                     });

    QVariantList similar;
    for (const Ranked &entry : ranked) {
        if (similar.size() >= limit) {
            break;
        }
        similar.push_back(QVariantMap{
            {QStringLiteral("mediaId"), entry.item->id},
            {QStringLiteral("title"), entry.item->title},
            {QStringLiteral("year"), entry.item->year},
            {QStringLiteral("posterUrl"), posterUrlOf(*entry.item)},
            {QStringLiteral("metadata"), metadataOf(*entry.item)},
            {QStringLiteral("formatBadge"), formatBadgeOf(*entry.item)}});
    }
    return similar;
}

void LibraryModel::replaceItems(QVector<MediaItem> items)
{
    const int previousCount = static_cast<int>(m_items.size());

    beginResetModel();
    m_items = std::move(items);
    endResetModel();

    for (auto sequence = m_progressSequences.begin(); sequence != m_progressSequences.end();) {
        const bool projected = std::any_of(
            m_items.cbegin(), m_items.cend(),
            [&sequence](const MediaItem &item) { return item.id == sequence.key(); });
        sequence = projected ? std::next(sequence) : m_progressSequences.erase(sequence);
    }

    if (previousCount != static_cast<int>(m_items.size())) {
        emit titleCountChanged();
    }
}

void LibraryModel::applyWatchProgress(const QString &mediaId,
                                      qint64 positionMs,
                                      qint64 durationMs,
                                      quint64 sequence)
{
    const auto match = std::find_if(
        m_items.begin(), m_items.end(), [&mediaId](const MediaItem &item) {
            return item.id == mediaId;
        });
    if (match == m_items.end()) {
        return;
    }

    const auto newest = m_progressSequences.constFind(mediaId);
    if (newest != m_progressSequences.constEnd() && sequence < newest.value()) {
        return;
    }
    m_progressSequences.insert(mediaId, sequence);

    const qint64 durationSeconds = qMax(qint64{0}, durationMs / 1000);
    const bool durationChanged = match->durationSeconds != durationSeconds;
    match->resumePositionMs = positionMs;

    if (!durationChanged) {
        return;
    }

    match->durationSeconds = durationSeconds;
    const int row = static_cast<int>(std::distance(m_items.begin(), match));
    emit dataChanged(index(row, 0), index(row, 0), {MetadataRole});
}
