#include "models/HeroSpotlight.hpp"

#include "models/BrowseSemantics.hpp"
#include "models/HomeRowsModel.hpp"
#include "models/SeasonalRows.hpp"
#include "models/ShowsModel.hpp"
#include "models/TasteModel.hpp"
#include "profiles/ContentPolicy.hpp"

#include <QFileInfo>
#include <QHash>
#include <QSet>
#include <QTimeZone>
#include <QUrl>

#include <algorithm>
#include <optional>
#include <utility>

namespace
{
// :750-753 and :757-758 look at the first four of a title's ranked neighbours.
constexpr int kSimilarNeighbourCount = 4;

[[nodiscard]] QUrl localUrl(const QString &path)
{
    return path.isEmpty() ? QUrl() : QUrl::fromLocalFile(path);
}

// One title of the carousel's pool: a movie, or a show standing for its
// episodes (BrowseSnapshotStore.swift:2655 spotlights `movies +
// showSummaries.representative`).
struct Candidate
{
    // Unique among candidates: a movie's id, or "show:" and its name.
    QString key;
    QString showName;
    // The id the spotlight plays: the movie, or the episode to continue with.
    QString playId;
    // The file the card draws and names: the movie, or the show's first
    // episode, which is the oracle's representative (:3088, :2655).
    const MediaItem *art{nullptr};
    QString title;
    int year{0};
    QDateTime date;
    // `heroScore` (:2103-2121), and with the taste boost (:788) the score the
    // quality ranking sorts by.
    double score{0.0};
    double rankScore{0.0};
    // What the title and its metadata alone decide: the franchise, the browse
    // key and the holiday score, from the library cache.
    home_rows::LibraryRows::TitleFacts facts;

    [[nodiscard]] bool isShow() const { return !showName.isEmpty(); }
    // HeroCarousel.swift:307, :330: the representative's display artwork, a
    // local sidecar first and the cached TMDB image only in its absence.
    [[nodiscard]] QString posterPath() const { return art->displayPosterPath(); }
    [[nodiscard]] QString backdropPath() const { return art->displayBackdropPath(); }
};

// BrowseSnapshotStore.swift:2044-2046, the order every released browse sort
// breaks its ties by.
[[nodiscard]] bool browsesBefore(const Candidate &left, const Candidate &right)
{
    return browse::compareMovieBrowseSortKeys(left.facts.sortKey, right.facts.sortKey);
}

// :841-880 `HeroContentProfile`: what makes a movie and a show near-duplicates
// of each other (a franchise, a top-billed actor, or a director and a genre).
struct ContentProfile
{
    QString franchise;
    QString director;
    QSet<QString> topCast;
    QSet<QString> genres;

    explicit ContentProfile(const Candidate &candidate)
        : franchise(candidate.facts.franchise)
    {
        const MediaItem &item = *candidate.art;
        if (item.metadata) {
            director = browse::normalizedText(item.metadata->director);
            for (qsizetype index = 0; index < std::min<qsizetype>(2, item.metadata->cast.size()); ++index) {
                if (const QString name = browse::normalizedText(item.metadata->cast.at(index).name);
                    !name.isEmpty()) {
                    topCast.insert(name);
                }
            }
        }
        for (const QString &genre : content_policy::displayGenresOf(item)) {
            if (const QString normalized = browse::normalizedText(genre); !normalized.isEmpty()) {
                genres.insert(normalized);
            }
        }
    }

    [[nodiscard]] bool isNearDuplicate(const ContentProfile &other) const
    {
        if (!franchise.isEmpty() && franchise == other.franchise) {
            return true;
        }
        if (topCast.intersects(other.topCast)) {
            return true;
        }
        return !director.isEmpty() && director == other.director && genres.intersects(other.genres);
    }
};

[[nodiscard]] QDateTime unknownDate()
{
    return QDateTime::fromSecsSinceEpoch(0, QTimeZone::UTC);
}
}

QVector<hero_spotlight::Spotlight> hero_spotlight::build(const QVector<MediaItem> &items,
                                                         const QDateTime &now,
                                                         home_rows::LibraryRows *library,
                                                         const browse::TasteModel *taste)
{
    if (items.isEmpty()) {
        return {};
    }
    home_rows::LibraryRows uncachedLibrary;
    home_rows::LibraryRows &libraryRows = library != nullptr ? *library : uncachedLibrary;
    // The holiday scores of the movies are built first so the title facts and
    // the similarity index reuse them.
    (void)libraryRows.built(items);

    // The pool: every movie, and one entry per show (:2655).
    QVector<QVector<MediaItem>> showEpisodes;
    QHash<QString, int> showIndex;
    for (const MediaItem &item : items) {
        if (!item.isEpisode()) {
            continue;
        }
        const auto found = showIndex.constFind(item.showName);
        if (found == showIndex.cend()) {
            showIndex.insert(item.showName, static_cast<int>(showEpisodes.size()));
            showEpisodes.push_back({item});
        } else {
            showEpisodes[found.value()].push_back(item);
        }
    }

    QVector<Candidate> pool;
    pool.reserve(items.size());
    const auto describe = [&libraryRows](Candidate &candidate) {
        // :1820-1862 and :2026-2033 through the library cache: the family is
        // the franchise, or the normalized title when the title has none.
        candidate.facts = libraryRows.titleFacts(*candidate.art);
    };
    for (const MediaItem &item : items) {
        if (item.isEpisode()) {
            continue;
        }
        Candidate candidate;
        candidate.key = item.id;
        candidate.playId = item.id;
        candidate.art = &item;
        candidate.title = item.title;
        candidate.year = item.year;
        candidate.date = item.modifiedAt.isValid() ? item.modifiedAt : unknownDate();
        describe(candidate);
        pool.push_back(std::move(candidate));
    }
    // The vectors of episodes must not move once pointers into them are held.
    for (QVector<MediaItem> &episodes : showEpisodes) {
        show_order::sortEpisodes(episodes);
    }
    for (const QVector<MediaItem> &episodes : std::as_const(showEpisodes)) {
        const MediaItem &first = episodes.constFirst();
        // The oracle plays a show's representative, its first episode,
        // whatever has been watched (HomeDetailView.swift:1011 over :3088).
        // A Return that restarts a show the viewer is half through is worse
        // than that, so a spotlight plays the episode the Home rows and the
        // show page agree on (`show_order::upNextIndexOf`, :3112-3124), and a
        // show watched through starts over.
        const int upNext = show_order::upNextIndexOf(episodes);
        const MediaItem &playable = episodes.at(upNext >= 0 ? upNext : 0);

        Candidate candidate;
        candidate.key = QStringLiteral("show:") + first.showName;
        candidate.showName = first.showName;
        candidate.playId = playable.id;
        candidate.art = &first;
        candidate.title = first.showName;
        candidate.year = first.year;
        // The newest episode file dates a show, as it does on Recently Added
        // (home_rows::recentlyAdded); the oracle dates it by its first.
        QDateTime newest;
        for (const MediaItem &episode : episodes) {
            if (episode.modifiedAt.isValid() && (!newest.isValid() || episode.modifiedAt > newest)) {
                newest = episode.modifiedAt;
            }
        }
        candidate.date = newest.isValid() ? newest : unknownDate();
        describe(candidate);
        pool.push_back(std::move(candidate));
    }

    // :783: scores are taken against the newest date in the pool.
    qint64 newestMs = 0;
    for (const Candidate &candidate : std::as_const(pool)) {
        newestMs = std::max(newestMs, candidate.date.toMSecsSinceEpoch());
    }
    for (Candidate &candidate : pool) {
        candidate.score = home_rows::heroScoreDated(*candidate.art, candidate.date.toMSecsSinceEpoch(), newestMs);
        candidate.rankScore = candidate.score + (taste != nullptr ? taste->heroBoost(*candidate.art) : 0.0);
    }

    QVector<const Candidate *> qualityRanked;
    qualityRanked.reserve(pool.size());
    for (const Candidate &candidate : std::as_const(pool)) {
        qualityRanked.push_back(&candidate);
    }
    // :784-795: score with the taste boost, then browse order.
    std::stable_sort(qualityRanked.begin(), qualityRanked.end(),
                     [](const Candidate *left, const Candidate *right) {
                         if (left->rankScore != right->rankScore) {
                             return left->rankScore > right->rankScore;
                         }
                         return browsesBefore(*left, *right);
                     });

    QVector<Spotlight> spotlights;
    QSet<QString> usedKeys;
    QVector<const Candidate *> used;

    const auto remember = [&](const Candidate &candidate) {
        usedKeys.insert(candidate.key);
        used.push_back(&candidate);
    };
    // :738-759. A movie is too similar to a chosen one when either is among
    // the other's four nearest neighbours in the similarity index (the
    // library's, shared with Because You Watched); a movie and a show are
    // compared by their content profiles (:863-880). The index ranks movies
    // only, so two shows are judged by their franchise alone, which is the
    // term it weighs most (issues.md).
    QHash<QString, QVector<QString>> nearest;
    const browse::SimilarityIndex *index = nullptr;
    const auto nearestOf = [&](const QString &id) -> const QVector<QString> & {
        auto found = nearest.find(id);
        if (found == nearest.end()) {
            if (index == nullptr) {
                QVector<MediaItem> movies;
                for (const MediaItem &item : items) {
                    if (item.isMovie()) {
                        movies.push_back(item);
                    }
                }
                index = &libraryRows.similarityIndex(movies);
            }
            found = nearest.insert(id, index->rankedMovieIds(id, kSimilarNeighbourCount));
        }
        return found.value();
    };
    const auto tooSimilar = [&](const Candidate &candidate) {
        std::optional<ContentProfile> profile;
        return std::any_of(used.cbegin(), used.cend(), [&](const Candidate *chosen) {
            if (chosen->isShow() != candidate.isShow()) {
                if (!profile) {
                    profile.emplace(candidate);
                }
                return ContentProfile(*chosen).isNearDuplicate(*profile);
            }
            if (candidate.isShow()) {
                return !candidate.facts.franchise.isEmpty()
                    && chosen->facts.franchise == candidate.facts.franchise;
            }
            return nearestOf(chosen->playId).contains(candidate.playId)
                || nearestOf(candidate.playId).contains(chosen->playId);
        });
    };
    // :761-764.
    const auto firstAvailable = [&](const QVector<const Candidate *> &candidates) -> const Candidate * {
        for (const Candidate *candidate : candidates) {
            if (!usedKeys.contains(candidate->key) && !tooSimilar(*candidate)) {
                return candidate;
            }
        }
        for (const Candidate *candidate : candidates) {
            if (!usedKeys.contains(candidate->key)) {
                return candidate;
            }
        }
        return nullptr;
    };
    const auto append = [&](const Candidate &candidate, const QString &category, const QString &icon,
                            const QString &idPrefix, const QString &playId) {
        Spotlight spotlight;
        spotlight.id = idPrefix + QLatin1Char('-') + candidate.art->id;
        spotlight.category = category;
        spotlight.icon = icon;
        spotlight.mediaId = playId;
        spotlight.showName = candidate.showName;
        spotlight.title = candidate.title;
        spotlight.year = candidate.year;
        // HeroCarousel.swift:380-384 names the runtime and format of the item
        // the card stands for, a show's representative.
        spotlight.runtime = candidate.art->displayRuntime();
        spotlight.formatBadge = QFileInfo(candidate.art->relativePath).suffix().toUpper();
        spotlight.posterPath = candidate.posterPath();
        spotlight.backdropPath = candidate.backdropPath();
        spotlights.push_back(std::move(spotlight));
        remember(candidate);
    };
    const auto appendPick = [&](const Candidate &candidate, const QString &category,
                                const QString &icon, const QString &idPrefix) {
        append(candidate, category, icon, idPrefix, candidate.playId);
    };

    // :776-781: the title the viewer was last in. The Home row's own
    // functions decide it, so the hero and Continue Watching agree on what
    // "continuing" means, up-next episode and idle window included; the oracle
    // reads the title's own progress only (:797).
    const QVector<home_rows::Card> continuing = home_rows::continueWatching(items, now);
    if (!continuing.isEmpty()) {
        const home_rows::Card &next = continuing.constFirst();
        const QString key = next.isEpisode() ? QStringLiteral("show:") + next.showName : next.mediaId;
        const auto found = std::find_if(pool.cbegin(), pool.cend(),
                                        [&key](const Candidate &candidate) { return candidate.key == key; });
        if (found != pool.cend()) {
            append(*found, QStringLiteral("Continue Watching"), QStringLiteral("play.circle"),
                   QStringLiteral("continue"), next.mediaId);
        }
    }

    // :797-799: the best-scored title not yet shown.
    if (const Candidate *pick = firstAvailable(qualityRanked)) {
        appendPick(*pick, QStringLiteral("Featured"), QStringLiteral("sparkles"), QStringLiteral("featured"));
    }

    // :801-808. The oracle's seasonal gate is none: a holiday title is
    // offered all year, so it is here.
    QVector<const Candidate *> holiday;
    for (const Candidate *candidate : std::as_const(qualityRanked)) {
        if (candidate->facts.holiday > 0 && !usedKeys.contains(candidate->key)) {
            holiday.push_back(candidate);
        }
    }
    if (const Candidate *pick = firstAvailable(holiday)) {
        appendPick(*pick, QStringLiteral("Holiday Pick"), QStringLiteral("gift"), QStringLiteral("holiday"));
    }

    // :810-825: newest file first, ties to the better score.
    QVector<const Candidate *> recentlyAdded;
    for (const Candidate &candidate : std::as_const(pool)) {
        if (!usedKeys.contains(candidate.key)) {
            recentlyAdded.push_back(&candidate);
        }
    }
    std::stable_sort(recentlyAdded.begin(), recentlyAdded.end(),
                     [](const Candidate *left, const Candidate *right) {
                         if (left->date != right->date) {
                             return left->date > right->date;
                         }
                         if (left->score != right->score) {
                             return left->score > right->score;
                         }
                         return browsesBefore(*left, *right);
                     });
    if (const Candidate *pick = firstAvailable(recentlyAdded)) {
        appendPick(*pick, QStringLiteral("Recently Added"), QStringLiteral("plus.square.on.square"),
                   QStringLiteral("recently-added"));
    }

    // :827-831: the best-scored title from before 2000. A title with no known
    // year is not one (:828 reads it as 9999).
    QVector<const Candidate *> classics;
    for (const Candidate *candidate : std::as_const(qualityRanked)) {
        if (candidate->year > 0 && candidate->year < 2000 && !usedKeys.contains(candidate->key)) {
            classics.push_back(candidate);
        }
    }
    if (const Candidate *pick = firstAvailable(classics)) {
        appendPick(*pick, QStringLiteral("From the Vault"), QStringLiteral("clock.arrow.circlepath"),
                   QStringLiteral("vault"));
    }

    // :833-836.
    while (spotlights.size() < kTargetCount) {
        const Candidate *pick = firstAvailable(qualityRanked);
        if (pick == nullptr) {
            break;
        }
        appendPick(*pick, QStringLiteral("Smart Pick"), QStringLiteral("wand.and.stars"),
                   QStringLiteral("smart-pick"));
    }
    return spotlights;
}

HeroSpotlightModel::HeroSpotlightModel(QObject *parent)
    : QAbstractListModel(parent),
      m_timer(this)
{
    m_timer.setSingleShot(false);
    connect(&m_timer, &QTimer::timeout, this, [this] { step(1); });
}

int HeroSpotlightModel::rowCount(const QModelIndex &parent) const
{
    return parent.isValid() ? 0 : static_cast<int>(m_spotlights.size());
}

QVariant HeroSpotlightModel::data(const QModelIndex &index, int role) const
{
    if (!index.isValid() || index.row() < 0 || index.row() >= m_spotlights.size()) {
        return {};
    }
    const hero_spotlight::Spotlight &spotlight = m_spotlights.at(index.row());
    switch (role) {
    case SpotlightIdRole:
        return spotlight.id;
    case CategoryRole:
        return spotlight.category;
    case IconRole:
        return spotlight.icon;
    case MediaIdRole:
        return spotlight.mediaId;
    case ShowNameRole:
        return spotlight.showName;
    case TitleRole:
        return spotlight.title;
    case YearRole:
        return spotlight.year > 0 ? QString::number(spotlight.year) : QString();
    case RuntimeRole:
        return spotlight.runtime;
    case FormatBadgeRole:
        return spotlight.formatBadge;
    case PosterUrlRole:
        return localUrl(spotlight.posterPath);
    case BackdropUrlRole:
        return localUrl(spotlight.backdropPath);
    default:
        return {};
    }
}

QHash<int, QByteArray> HeroSpotlightModel::roleNames() const
{
    return {{SpotlightIdRole, "spotlightId"}, {CategoryRole, "category"},
            {IconRole, "icon"},               {MediaIdRole, "mediaId"},
            {ShowNameRole, "showName"},       {TitleRole, "title"},
            {YearRole, "year"},               {RuntimeRole, "runtime"},
            {FormatBadgeRole, "formatBadge"}, {PosterUrlRole, "posterUrl"},
            {BackdropUrlRole, "backdropUrl"}};
}

int HeroSpotlightModel::count() const
{
    return static_cast<int>(m_spotlights.size());
}

int HeroSpotlightModel::position() const
{
    return m_position;
}

int HeroSpotlightModel::currentIndex() const
{
    const int size = count();
    if (size == 0) {
        return 0;
    }
    // :23-27: wrapped into 0..<count whatever side of zero the slide is on.
    const int wrapped = m_position % size;
    return wrapped < 0 ? wrapped + size : wrapped;
}

int HeroSpotlightModel::revision() const
{
    return m_revision;
}

bool HeroSpotlightModel::active() const
{
    return m_active;
}

bool HeroSpotlightModel::remoteFocused() const
{
    return m_remoteFocused;
}

bool HeroSpotlightModel::reduceMotion() const
{
    return m_reduceMotion;
}

bool HeroSpotlightModel::timerRunning() const
{
    return m_timer.isActive();
}

int HeroSpotlightModel::advanceIntervalMs() const
{
    return m_interval;
}

void HeroSpotlightModel::setActive(bool active)
{
    if (m_active == active) {
        return;
    }
    m_active = active;
    emit activeChanged();
    updateTimer();
}

void HeroSpotlightModel::setRemoteFocused(bool focused)
{
    if (m_remoteFocused == focused) {
        return;
    }
    m_remoteFocused = focused;
    emit remoteFocusedChanged();
    // :238-244: the remote taking the carousel stops the timer, and letting
    // it go starts a fresh one.
    updateTimer();
}

void HeroSpotlightModel::setReduceMotion(bool reduce)
{
    if (m_reduceMotion == reduce) {
        return;
    }
    m_reduceMotion = reduce;
    emit reduceMotionChanged();
    updateTimer();
}

void HeroSpotlightModel::step(int delta)
{
    if (count() < 2 || delta == 0) {
        return;
    }
    m_position += delta;
    emit positionChanged();
    restartTimer();
}

void HeroSpotlightModel::moveTo(int index)
{
    const int size = count();
    if (size == 0) {
        return;
    }
    // :308-314: the shorter way round.
    int delta = index - currentIndex();
    if (delta > size / 2) {
        delta -= size;
    }
    if (delta < -size / 2) {
        delta += size;
    }
    step(delta);
}

QVariantMap HeroSpotlightModel::spotlightAt(int logical) const
{
    const int size = count();
    if (size == 0) {
        return {};
    }
    const int wrapped = ((logical % size) + size) % size;
    const hero_spotlight::Spotlight &spotlight = m_spotlights.at(wrapped);
    return {{QStringLiteral("spotlightId"), spotlight.id},
            {QStringLiteral("category"), spotlight.category},
            {QStringLiteral("icon"), spotlight.icon},
            {QStringLiteral("mediaId"), spotlight.mediaId},
            {QStringLiteral("showName"), spotlight.showName},
            {QStringLiteral("title"), spotlight.title},
            {QStringLiteral("year"), spotlight.year > 0 ? QString::number(spotlight.year) : QString()},
            {QStringLiteral("runtime"), spotlight.runtime},
            {QStringLiteral("formatBadge"), spotlight.formatBadge},
            {QStringLiteral("posterUrl"), localUrl(spotlight.posterPath)},
            {QStringLiteral("backdropUrl"), localUrl(spotlight.backdropPath)},
            {QStringLiteral("index"), wrapped}};
}

QVariantMap HeroSpotlightModel::current() const
{
    return spotlightAt(m_position);
}

const hero_spotlight::Spotlight *HeroSpotlightModel::spotlight(int index) const
{
    return index >= 0 && index < m_spotlights.size() ? &m_spotlights.at(index) : nullptr;
}

void HeroSpotlightModel::replaceSpotlights(QVector<hero_spotlight::Spotlight> spotlights)
{
    if (spotlights == m_spotlights) {
        return;
    }
    const int previousCount = count();
    const int previousPosition = m_position;
    beginResetModel();
    m_spotlights = std::move(spotlights);
    // :222-226: a carousel of a different length starts over; one of the same
    // length stays on the slide it is on.
    if (count() != previousCount) {
        m_position = 0;
    }
    endResetModel();
    ++m_revision;
    emit spotlightsChanged();
    if (count() != previousCount) {
        emit countChanged();
    }
    if (m_position != previousPosition) {
        emit positionChanged();
    }
    updateTimer();
}

void HeroSpotlightModel::setAdvanceIntervalForTest(int milliseconds)
{
    m_interval = milliseconds;
    if (m_timer.isActive()) {
        m_timer.start(m_interval);
    }
}

void HeroSpotlightModel::updateTimer()
{
    // :380-387: the carousel advances by itself while it is on screen with
    // more than one slide, unless the viewer asked for less motion or the
    // remote is resting on it. A pointer hovering it does not stop the timer.
    const bool shouldRun = m_active && !m_remoteFocused && !m_reduceMotion && count() > 1;
    const bool wasRunning = m_timer.isActive();
    if (shouldRun) {
        m_timer.start(m_interval);
    } else {
        m_timer.stop();
    }
    if (wasRunning != m_timer.isActive()) {
        emit timerRunningChanged();
    }
}

void HeroSpotlightModel::restartTimer()
{
    // :391-394.
    if (m_timer.isActive()) {
        m_timer.start(m_interval);
    }
}
