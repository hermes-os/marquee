#include "models/ShowsModel.hpp"

#include "models/BrowseSemantics.hpp"
#include "models/TitleMetadataView.hpp"
#include "profiles/ContentPolicy.hpp"

#include <QChar>
#include <QCollator>
#include <QHash>
#include <QLatin1Char>
#include <QRegularExpression>
#include <QSet>
#include <QUrl>
#include <QVariantList>

#include <algorithm>
#include <cstdlib>
#include <utility>

namespace
{
[[nodiscard]] QUrl localUrl(const QString &path)
{
    return path.isEmpty() ? QUrl() : QUrl::fromLocalFile(path);
}
}

// BrowseSnapshotStore.swift:3103-3110.
void show_order::sortEpisodes(QVector<MediaItem> &episodes)
{
    std::stable_sort(episodes.begin(), episodes.end(),
                     [](const MediaItem &left, const MediaItem &right) {
                         if (left.seasonNumber != right.seasonNumber) {
                             return left.seasonNumber < right.seasonNumber;
                         }
                         return left.episodeNumber < right.episodeNumber;
                     });
}

// BrowseSnapshotStore.swift:3112-3124: the last episode with any watch state
// decides. In progress, it is up next itself; finished, the one after it is,
// and a show watched through has none. Untouched shows start at the first.
int show_order::upNextIndexOf(const QVector<MediaItem> &episodes)
{
    for (qsizetype index = episodes.size() - 1; index >= 0; --index) {
        const MediaItem &episode = episodes.at(index);
        if (episode.watched || episode.hasProgress()) {
            if (episode.hasProgress()) {
                return static_cast<int>(index);
            }
            // A second file of an episode already watched is not "the next
            // one": the oracle never meets it because it lists only episodes
            // with progress, but a library can hold two files of one episode.
            QSet<std::pair<int, int>> seen;
            for (const MediaItem &candidate : episodes) {
                if (candidate.watched) {
                    seen.insert({candidate.seasonNumber, candidate.episodeNumber});
                }
            }
            qsizetype next = index + 1;
            while (next < episodes.size()
                   && seen.contains({episodes.at(next).seasonNumber,
                                     episodes.at(next).episodeNumber})) {
                ++next;
            }
            return next < episodes.size() ? static_cast<int>(next) : -1;
        }
    }
    return episodes.isEmpty() ? -1 : 0;
}

// PlayerController.swift:5-18, with the copies of one episode skipped: a library
// can hold two files of an episode, and playing "the next" must not replay it.
int show_order::nextEpisodeIndexAfter(const QVector<MediaItem> &episodes, int index)
{
    if (index < 0 || index >= episodes.size()) {
        return -1;
    }
    const MediaItem &current = episodes.at(index);
    for (qsizetype next = index + 1; next < episodes.size(); ++next) {
        const MediaItem &candidate = episodes.at(next);
        if (candidate.seasonNumber != current.seasonNumber
            || candidate.episodeNumber != current.episodeNumber) {
            return static_cast<int>(next);
        }
    }
    return -1;
}

namespace
{
[[nodiscard]] int seasonCountOf(const QVector<MediaItem> &episodes)
{
    QSet<int> seasons;
    for (const MediaItem &episode : episodes) {
        seasons.insert(episode.seasonNumber);
    }
    return static_cast<int>(seasons.size());
}

[[nodiscard]] bool caseInsensitiveBefore(const QString &left, const QString &right)
{
    static const QCollator collator = [] {
        QCollator built;
        built.setCaseSensitivity(Qt::CaseInsensitive);
        return built;
    }();
    return collator.compare(left, right) < 0;
}

[[nodiscard]] QVariantMap episodeMap(const MediaItem &episode, bool isUpNext)
{
    // EpisodeRow.swift:59-78: the episode's own still first, then the
    // show-level backdrop. Generated frames and TMDB stills do not exist here.
    const QString thumbPath = !episode.episodeStillAbsolutePath.isEmpty()
        ? episode.episodeStillAbsolutePath
        : episode.showBackdropAbsolutePath;
    const qint64 durationMs = episode.durationSeconds * 1000;
    const double progress = durationMs > 0 && episode.hasProgress()
        ? static_cast<double>(episode.resumePositionMs) / static_cast<double>(durationMs)
        : 0.0;
    const QString runtime = episode.displayRuntime();
    // The episode's own TMDB facts ride along under their own keys; the keys
    // below, which the screen binds today, keep their meaning.
    QVariantMap map = {{QStringLiteral("tmdbTitle"), episode.tmdbEpisodeTitle},
                       {QStringLiteral("overview"), episode.episodeOverview},
                       {QStringLiteral("airDate"), episode.episodeAirDate},
                       {QStringLiteral("voteAverage"), episode.episodeVoteAverage
                                                           ? QVariant(*episode.episodeVoteAverage)
                                                           : QVariant()},
                       {QStringLiteral("tmdbStillUrl"), localUrl(episode.tmdbEpisodeStillAbsolutePath)}};
    const QVariantMap shown = {{QStringLiteral("mediaId"), episode.id},
            {QStringLiteral("episodeNumber"), episode.episodeNumber},
            {QStringLiteral("seasonNumber"), episode.seasonNumber},
            {QStringLiteral("episodeLabel"), episode.episodeLabel()},
            {QStringLiteral("title"), episode.displayEpisodeTitle()},
            {QStringLiteral("runtime"), runtime},
            {QStringLiteral("thumbUrl"), localUrl(thumbPath)},
            {QStringLiteral("watched"), episode.watched},
            {QStringLiteral("hasProgress"), episode.hasProgress()},
            {QStringLiteral("progress"), progress},
            {QStringLiteral("isUpNext"), isUpNext}};
    for (auto entry = shown.cbegin(); entry != shown.cend(); ++entry) {
        map.insert(entry.key(), entry.value());
    }
    return map;
}
}

ShowRowModel::ShowRowModel(QObject *parent)
    : QAbstractListModel(parent)
{
}

int ShowRowModel::rowCount(const QModelIndex &parent) const
{
    return parent.isValid() ? 0 : static_cast<int>(m_shows.size());
}

QVariant ShowRowModel::data(const QModelIndex &index, int role) const
{
    if (!index.isValid() || index.row() < 0 || index.row() >= m_shows.size()) {
        return {};
    }
    const ShowSummary &show = m_shows.at(index.row());
    switch (role) {
    case ShowNameRole:
        return show.showName;
    case PosterUrlRole:
        return localUrl(show.posterPath());
    case SeasonLabelRole:
        return QStringLiteral("%1 Season%2")
            .arg(show.seasonCount)
            .arg(show.seasonCount == 1 ? QString() : QStringLiteral("s"));
    case UpNextLabelRole:
        return show.upNextLabel();
    case HasMetadataRole:
        return title_metadata_view::has(show.representative());
    case TmdbIdRole:
        return title_metadata_view::tmdbId(show.representative());
    case OverviewRole:
        return title_metadata_view::overview(show.representative());
    case DirectorRole:
        return title_metadata_view::director(show.representative());
    case CertificationRole:
        return title_metadata_view::certification(show.representative());
    case ReleaseDateRole:
        return title_metadata_view::releaseDate(show.representative());
    case VoteAverageRole:
        return title_metadata_view::voteAverage(show.representative());
    case RuntimeMinutesRole:
        return title_metadata_view::runtimeMinutes(show.representative());
    case GenresRole:
        return title_metadata_view::genres(show.representative());
    case CastRole:
        return title_metadata_view::cast(show.representative());
    case BackdropUrlRole:
        return localUrl(show.representative().tmdbBackdropAbsolutePath);
    default:
        return {};
    }
}

QHash<int, QByteArray> ShowRowModel::roleNames() const
{
    return {{ShowNameRole, "showName"},
            {PosterUrlRole, "posterUrl"},
            {SeasonLabelRole, "seasonLabel"},
            {UpNextLabelRole, "upNextLabel"},
            {HasMetadataRole, "hasMetadata"},
            {TmdbIdRole, "tmdbId"},
            {OverviewRole, "overview"},
            {DirectorRole, "director"},
            {CertificationRole, "certification"},
            {ReleaseDateRole, "releaseDate"},
            {VoteAverageRole, "voteAverage"},
            {RuntimeMinutesRole, "runtimeMinutes"},
            {GenresRole, "genres"},
            {CastRole, "cast"},
            {BackdropUrlRole, "backdropUrl"}};
}

void ShowRowModel::replaceShows(QVector<ShowSummary> shows)
{
    beginResetModel();
    m_shows = std::move(shows);
    endResetModel();
}

QString ShowRowModel::showNameAt(int column) const
{
    return column >= 0 && column < m_shows.size() ? m_shows.at(column).showName : QString();
}

ShowsModel::ShowsModel(QObject *parent)
    : QAbstractListModel(parent)
{
}

int ShowsModel::rowCount(const QModelIndex &parent) const
{
    return parent.isValid() ? 0 : static_cast<int>(m_rows.size());
}

QVariant ShowsModel::data(const QModelIndex &index, int role) const
{
    if (!index.isValid() || index.row() < 0 || index.row() >= m_rows.size()) {
        return {};
    }
    const Row &row = m_rows.at(index.row());
    switch (role) {
    case RowIdRole:
        return row.id;
    case RowTitleRole:
        return row.title;
    case ShowCountRole:
        return row.shows->rowCount();
    case ShowsRole:
        return QVariant::fromValue<QObject *>(row.shows);
    default:
        return {};
    }
}

QHash<int, QByteArray> ShowsModel::roleNames() const
{
    return {{RowIdRole, "rowId"},
            {RowTitleRole, "rowTitle"},
            {ShowCountRole, "showCount"},
            {ShowsRole, "shows"}};
}

int ShowsModel::showCount() const
{
    return static_cast<int>(m_summaries.size());
}

int ShowsModel::episodeCount() const
{
    return m_episodeCount;
}

FocusNavigator *ShowsModel::focus()
{
    return &m_focus;
}

QString ShowsModel::showNameAt(int row, int column) const
{
    if (row < 0 || row >= m_rows.size()) {
        return {};
    }
    return m_rows.at(row).shows->showNameAt(column);
}

const ShowSummary *ShowsModel::summary(const QString &showName) const
{
    const auto match = std::find_if(
        m_summaries.cbegin(), m_summaries.cend(),
        [&showName](const ShowSummary &summary) { return summary.showName == showName; });
    return match == m_summaries.cend() ? nullptr : &*match;
}

const QVector<ShowSummary> &ShowsModel::summaries() const
{
    return m_summaries;
}

QVariantMap ShowsModel::showDetails(const QString &showName) const
{
    const ShowSummary *show = summary(showName);
    if (show == nullptr) {
        return {};
    }

    QVariantList seasons;
    QSet<int> seen;
    for (const MediaItem &episode : show->episodes) {
        if (!seen.contains(episode.seasonNumber)) {
            seen.insert(episode.seasonNumber);
            seasons.push_back(episode.seasonNumber);
        }
    }
    std::sort(seasons.begin(), seasons.end(),
              [](const QVariant &left, const QVariant &right) {
                  return left.toInt() < right.toInt();
              });

    const MediaItem &representative = show->representative();
    const bool hasUpNext = show->upNextIndex >= 0;
    const MediaItem *upNext = hasUpNext ? &show->episodes.at(show->upNextIndex) : nullptr;
    // ShowDetailView.swift:768-772: Continue appears when up-next is not the
    // first episode, or is the first episode with progress on it.
    const bool showsContinue = upNext != nullptr
        && (upNext->id != representative.id || upNext->hasProgress());
    // ShowDetailView.swift:860-865.
    const QString continueLabel = upNext == nullptr
        ? QString()
        : QStringLiteral("%1 %2")
              .arg(upNext->hasProgress() ? QStringLiteral("Resume") : QStringLiteral("Continue"),
                   upNext->episodeLabel());

    // The show's TMDB metadata (an episode carries its show's) under the
    // fields the later Details task reads; the keys below keep their meaning.
    QVariantMap details = title_metadata_view::toMap(representative);
    details.remove(QStringLiteral("genres"));
    details.remove(QStringLiteral("backdropUrl"));
    details.insert(QStringLiteral("displayGenres"), title_metadata_view::genres(representative));
    // Only the cached TMDB backdrop; `backdropUrl` below stays the sidecar's.
    details.insert(QStringLiteral("tmdbBackdropUrl"),
                   localUrl(representative.tmdbBackdropAbsolutePath));

    const QVariantMap facts = {{QStringLiteral("showName"), show->showName},
            {QStringLiteral("year"), representative.year},
            {QStringLiteral("seasons"), seasons},
            {QStringLiteral("seasonCount"), show->seasonCount},
            {QStringLiteral("episodeCount"), static_cast<int>(show->episodes.size())},
            {QStringLiteral("genres"), show->genres},
            // ShowDetailView.swift:235, :324: the show backdrop and poster
            // through MediaItem.swift:263-268.
            {QStringLiteral("backdropUrl"), localUrl(representative.showBackdropAbsolutePath)},
            {QStringLiteral("posterUrl"), localUrl(show->posterPath())},
            {QStringLiteral("firstEpisodeId"), representative.id},
            {QStringLiteral("upNextId"), upNext == nullptr ? QString() : upNext->id},
            {QStringLiteral("upNextSeason"), upNext == nullptr ? 0 : upNext->seasonNumber},
            {QStringLiteral("showsContinue"), showsContinue},
            {QStringLiteral("continueLabel"), continueLabel}};
    for (auto fact = facts.cbegin(); fact != facts.cend(); ++fact) {
        details.insert(fact.key(), fact.value());
    }
    return details;
}

namespace
{
// BrowseSnapshotStore.swift:2313-2324.
[[nodiscard]] int genreWeight(const QString &genre)
{
    static const QSet<QString> heavy{
        QStringLiteral("science fiction"), QStringLiteral("sci fi"),
        QStringLiteral("fantasy"),         QStringLiteral("animation"),
        QStringLiteral("family"),          QStringLiteral("horror"),
        QStringLiteral("mystery")};
    static const QSet<QString> medium{
        QStringLiteral("adventure"), QStringLiteral("comedy"), QStringLiteral("thriller"),
        QStringLiteral("crime"),     QStringLiteral("music"),  QStringLiteral("musical")};
    if (heavy.contains(genre)) {
        return 70;
    }
    if (medium.contains(genre)) {
        return 46;
    }
    if (genre == QLatin1String("action") || genre == QLatin1String("drama")) {
        return 28;
    }
    return 36;
}

// BrowseSnapshotStore.swift:2265-2311 without the director, cast, and holiday
// terms, which need fetched metadata the offline library does not carry.
[[nodiscard]] int showSimilarityScore(const ShowSummary &source, const ShowSummary &candidate)
{
    int score = 0;
    const QString sourceFamily = browse::franchiseKey(source.showName);
    if (!sourceFamily.isEmpty() && sourceFamily == browse::franchiseKey(candidate.showName)) {
        score += 1000;
        if (source.representative().year > 0 && candidate.representative().year > 0) {
            score += std::max(
                0, 80 - std::abs(candidate.representative().year - source.representative().year) * 4);
        }
    }
    QSet<QString> sourceGenres;
    for (const QString &genre : source.genres) {
        sourceGenres.insert(browse::normalizedText(genre));
    }
    for (const QString &genre : candidate.genres) {
        const QString normalized = browse::normalizedText(genre);
        if (sourceGenres.contains(normalized)) {
            score += genreWeight(normalized);
        }
    }
    const int sourceYear = source.representative().year;
    const int candidateYear = candidate.representative().year;
    if (sourceYear > 0 && candidateYear > 0 && sourceYear / 10 == candidateYear / 10) {
        score += 20;
    }
    return score;
}
}

ShowRowModel *ShowsModel::similarShows(const QString &showName, int limit) const
{
    auto *row = new ShowRowModel();
    const ShowSummary *source = summary(showName);
    if (source == nullptr || limit <= 0) {
        return row;
    }
    struct Ranked
    {
        const ShowSummary *summary;
        int score;
    };
    QVector<Ranked> ranked;
    for (const ShowSummary &candidate : m_summaries) {
        if (candidate.showName == source->showName) {
            continue;
        }
        const int score = showSimilarityScore(*source, candidate);
        if (score > 0) {
            ranked.push_back({&candidate, score});
        }
    }
    std::stable_sort(ranked.begin(), ranked.end(), [](const Ranked &lhs, const Ranked &rhs) {
        if (lhs.score != rhs.score) {
            return lhs.score > rhs.score;
        }
        return QString::compare(lhs.summary->showName, rhs.summary->showName,
                                Qt::CaseInsensitive) < 0;
    });
    QVector<ShowSummary> shows;
    for (const Ranked &entry : ranked) {
        if (shows.size() >= limit) {
            break;
        }
        shows.push_back(*entry.summary);
    }
    row->replaceShows(std::move(shows));
    return row;
}

void ShowsModel::requestEpisodeFocus(const QString &mediaId)
{
    m_requestedEpisodeId = mediaId;
}

QVariantMap ShowsModel::takeEpisodeFocus(const QString &showName)
{
    const QString requested = std::exchange(m_requestedEpisodeId, QString());
    const ShowSummary *show = summary(showName);
    if (requested.isEmpty() || show == nullptr) {
        return {};
    }
    for (const MediaItem &episode : show->episodes) {
        if (episode.id == requested) {
            return {{QStringLiteral("mediaId"), episode.id},
                    {QStringLiteral("season"), episode.seasonNumber}};
        }
    }
    return {};
}

std::optional<MediaItem> ShowsModel::episodeForId(const QString &mediaId) const
{
    for (const ShowSummary &show : m_summaries) {
        for (const MediaItem &episode : show.episodes) {
            if (episode.id == mediaId) {
                return episode;
            }
        }
    }
    return std::nullopt;
}

QString ShowsModel::nextEpisodeId(const QString &mediaId) const
{
    for (const ShowSummary &show : m_summaries) {
        for (int index = 0; index < show.episodes.size(); ++index) {
            if (show.episodes.at(index).id != mediaId) {
                continue;
            }
            const int next = show_order::nextEpisodeIndexAfter(show.episodes, index);
            return next < 0 ? QString() : show.episodes.at(next).id;
        }
    }
    return {};
}

QVariantList ShowsModel::episodesOf(const QString &showName, int season) const
{
    const ShowSummary *show = summary(showName);
    if (show == nullptr) {
        return {};
    }
    QVariantList episodes;
    for (qsizetype index = 0; index < show->episodes.size(); ++index) {
        const MediaItem &episode = show->episodes.at(index);
        if (episode.seasonNumber != season) {
            continue;
        }
        episodes.push_back(episodeMap(episode, index == show->upNextIndex));
    }
    return episodes;
}

void ShowsModel::replaceItems(QVector<MediaItem> items)
{
    // BrowseSnapshotStore.swift:3078-3101.
    QHash<QString, QVector<MediaItem>> grouped;
    QStringList order;
    int episodeCount = 0;
    for (MediaItem &item : items) {
        if (!item.isEpisode()) {
            continue;
        }
        ++episodeCount;
        if (!grouped.contains(item.showName)) {
            order.push_back(item.showName);
        }
        grouped[item.showName].push_back(std::move(item));
    }

    QVector<ShowSummary> summaries;
    summaries.reserve(order.size());
    for (const QString &showName : std::as_const(order)) {
        QVector<MediaItem> episodes = std::move(grouped[showName]);
        show_order::sortEpisodes(episodes);
        ShowSummary summary{.showName = showName,
                            .episodes = std::move(episodes),
                            .upNextIndex = 0,
                            .seasonCount = 0,
                            .genres = {}};
        summary.upNextIndex = show_order::upNextIndexOf(summary.episodes);
        summary.seasonCount = seasonCountOf(summary.episodes);
        // BrowseSnapshotStore.swift:3093 reads the representative's
        // `displayGenres` (MediaItem.swift:154-171): TMDB's when it named any,
        // else the folder genre and then the title-inferred ones.
        summary.genres = content_policy::displayGenresOf(summary.representative());
        summaries.push_back(std::move(summary));
    }
    std::stable_sort(summaries.begin(), summaries.end(),
                     [](const ShowSummary &left, const ShowSummary &right) {
                         return caseInsensitiveBefore(left.showName, right.showName);
                     });

    m_summaries = std::move(summaries);
    m_episodeCount = episodeCount;
    recompose();
    emit showsChanged();
}

void ShowsModel::recompose()
{
    // BrowseSnapshotStore.swift:3050-3076.
    QHash<QString, QVector<ShowSummary>> byGenre;
    QStringList genreOrder;
    for (const ShowSummary &summary : std::as_const(m_summaries)) {
        for (const QString &genre : summary.genres) {
            // :3053-3063 groups a show with no genre under "Other" and then
            // drops that group, so a genre literally named Other is dropped too.
            if (genre == QLatin1String("Other")) {
                continue;
            }
            if (!byGenre.contains(genre)) {
                genreOrder.push_back(genre);
            }
            byGenre[genre].push_back(summary);
        }
    }
    std::sort(genreOrder.begin(), genreOrder.end(), caseInsensitiveBefore);

    struct Composed
    {
        QString id;
        QString title;
        QVector<ShowSummary> shows;
    };
    QVector<Composed> composed;
    for (const QString &genre : std::as_const(genreOrder)) {
        // The summaries are already in name order, which is the row's order.
        composed.push_back(Composed{.id = QStringLiteral("genre-") + genre,
                                    .title = genre,
                                    .shows = byGenre.value(genre)});
    }
    if (!m_summaries.isEmpty()) {
        composed.push_back(Composed{.id = QStringLiteral("all-shows"),
                                    .title = QStringLiteral("All Shows"),
                                    .shows = m_summaries});
    }

    while (m_rowModels.size() < composed.size()) {
        m_rowModels.push_back(new ShowRowModel(this));
    }

    beginResetModel();
    m_rows.clear();
    m_rows.reserve(composed.size());
    for (qsizetype index = 0; index < composed.size(); ++index) {
        ShowRowModel *rowModel = m_rowModels.at(index);
        rowModel->replaceShows(std::move(composed[index].shows));
        m_rows.push_back(Row{.id = std::move(composed[index].id),
                             .title = std::move(composed[index].title),
                             .shows = rowModel});
    }
    endResetModel();

    QVector<int> rowLengths;
    rowLengths.reserve(m_rows.size());
    for (const Row &row : std::as_const(m_rows)) {
        rowLengths.push_back(row.shows->rowCount());
    }
    m_focus.setRows(std::move(rowLengths));
}

void ShowsModel::applyWatchProgress(const QString &mediaId,
                                    qint64 positionMs,
                                    qint64 durationMs,
                                    bool completed)
{
    for (ShowSummary &summary : m_summaries) {
        for (MediaItem &episode : summary.episodes) {
            if (episode.id != mediaId) {
                continue;
            }
            episode.resumePositionMs = completed ? 0 : positionMs;
            if (durationMs > 0) {
                episode.durationSeconds = durationMs / 1000;
            }
            episode.watched = completed;
            summary.upNextIndex = show_order::upNextIndexOf(summary.episodes);
            // The rows hold copies of the summaries, so the card's up-next
            // label is refreshed by recomposing them in place.
            const QString showName = summary.showName;
            recompose();
            emit showProgressChanged(showName);
            return;
        }
    }
}
