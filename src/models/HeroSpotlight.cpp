#include "models/HeroSpotlight.hpp"

#include "models/BrowseSemantics.hpp"
#include "models/HomeRowsModel.hpp"
#include "models/ShowsModel.hpp"

#include <QCollator>
#include <QFileInfo>
#include <QHash>
#include <QSet>
#include <QTimeZone>
#include <QUrl>

#include <algorithm>
#include <limits>
#include <utility>

namespace
{
[[nodiscard]] QUrl localUrl(const QString &path)
{
    return path.isEmpty() ? QUrl() : QUrl::fromLocalFile(path);
}

// MediaItem.swift:143-151, the form the poster cards use too.
[[nodiscard]] QString runtimeOf(const MediaItem &item)
{
    if (item.durationSeconds <= 0) {
        return {};
    }
    const qint64 totalMinutes = item.durationSeconds / 60;
    return totalMinutes >= 60 ? QStringLiteral("%1h %2m").arg(totalMinutes / 60).arg(totalMinutes % 60)
                              : QStringLiteral("%1m").arg(totalMinutes);
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
    double score{0.0};
    int holiday{0};
    // BrowseSemanticPolicy.franchiseKey, empty when the title has none.
    QString franchise;
    // The browse-order family: the franchise, else the normalized title.
    QString family;
    int sortYear{std::numeric_limits<int>::max()};

    [[nodiscard]] bool isShow() const { return !showName.isEmpty(); }
    [[nodiscard]] QString posterPath() const
    {
        if (isShow()) {
            return art->gridShowPosterPath().isEmpty() ? art->posterAbsolutePath
                                                       : art->gridShowPosterPath();
        }
        return art->posterAbsolutePath;
    }
    [[nodiscard]] QString backdropPath() const
    {
        // MediaItem.swift:202-207: a movie's own backdrop; an episode's is the
        // show's. v3 holds no season backdrop.
        return isShow() ? art->showBackdropAbsolutePath : art->backdropAbsolutePath;
    }
};

// BrowseSnapshotStore.swift:2026-2046: browse order is the title's family, its
// year with an unknown one last, then its title. The key breaks what the
// oracle leaves unordered.
[[nodiscard]] bool browsesBefore(const Candidate &left, const Candidate &right)
{
    static const QCollator collator = [] {
        QCollator built;
        built.setCaseSensitivity(Qt::CaseInsensitive);
        return built;
    }();
    if (const int byFamily = collator.compare(left.family, right.family); byFamily != 0) {
        return byFamily < 0;
    }
    if (left.sortYear != right.sortYear) {
        return left.sortYear < right.sortYear;
    }
    if (const int byTitle = collator.compare(left.title, right.title); byTitle != 0) {
        return byTitle < 0;
    }
    return left.key < right.key;
}

[[nodiscard]] QDateTime unknownDate()
{
    return QDateTime::fromSecsSinceEpoch(0, QTimeZone::UTC);
}
}

double hero_spotlight::heroScore(bool hasBackdrop,
                                 bool hasPoster,
                                 qint64 durationSeconds,
                                 const QDateTime &effectiveDate,
                                 const QDateTime &newestDate)
{
    // BrowseSnapshotStore.swift:2103-2121. `voteAverage * 100` (:2104) is not
    // here: the catalog holds no rating.
    double score = 0.0;
    if (hasBackdrop) {
        score += 180.0;
    }
    if (hasPoster) {
        score += 50.0;
    }
    // :2111-2114. The catalog knows a runtime only once the player has
    // recorded one, so an unknown runtime scores neither way.
    if (durationSeconds > 0) {
        if (durationSeconds >= 4'500) {
            score += 30.0;
        }
        if (durationSeconds < 1'200) {
            score -= 180.0;
        }
    }
    // :2115-2119: up to 70 for being as new as the newest title, none after
    // thirty days older.
    if (newestDate.isValid() && effectiveDate.isValid()) {
        const double ageSeconds =
            std::max(0.0, static_cast<double>(effectiveDate.msecsTo(newestDate)) / 1000.0);
        const double thirtyDays = 60.0 * 60.0 * 24.0 * 30.0;
        score += std::max(0.0, 70.0 - (ageSeconds / thirtyDays) * 70.0);
    }
    return score;
}

QVector<hero_spotlight::Spotlight> hero_spotlight::build(const QVector<MediaItem> &items,
                                                         const QDateTime &now)
{
    if (items.isEmpty()) {
        return {};
    }

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
    const auto describe = [](Candidate &candidate) {
        // :1820-1862 and :2026-2033: the family is the franchise, or the
        // normalized title when the title has none.
        const QString franchise = browse::franchiseKey(candidate.title);
        candidate.franchise = franchise;
        candidate.family = franchise.isEmpty() ? browse::normalizedText(candidate.title) : franchise;
        candidate.sortYear = candidate.year > 0 ? candidate.year : std::numeric_limits<int>::max();
        candidate.holiday = browse::holidayScore(candidate.title);
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
    QDateTime newestDate = unknownDate();
    for (const Candidate &candidate : std::as_const(pool)) {
        newestDate = std::max(newestDate, candidate.date);
    }
    for (Candidate &candidate : pool) {
        candidate.score = heroScore(!candidate.backdropPath().isEmpty(),
                                    !candidate.posterPath().isEmpty(),
                                    candidate.art->durationSeconds, candidate.date, newestDate);
    }

    QVector<const Candidate *> qualityRanked;
    qualityRanked.reserve(pool.size());
    for (const Candidate &candidate : std::as_const(pool)) {
        qualityRanked.push_back(&candidate);
    }
    // :784-795: score, then browse order.
    std::stable_sort(qualityRanked.begin(), qualityRanked.end(),
                     [](const Candidate *left, const Candidate *right) {
                         if (left->score != right->score) {
                             return left->score > right->score;
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
    // :738-759 asks the similarity index for the top four neighbours of every
    // title already chosen, and :867-871 treats a shared franchise as a near
    // duplicate. The index is built from genres, cast, directors, overviews and
    // ratings the catalog does not hold; the franchise (:1824-1862) is the one
    // term it still has, and it outweighs the rest (:2419-2421), so a title of
    // a franchise already spotlit is too similar.
    const auto tooSimilar = [&](const Candidate &candidate) {
        if (candidate.franchise.isEmpty()) {
            return false;
        }
        return std::any_of(used.cbegin(), used.cend(), [&](const Candidate *chosen) {
            return chosen->franchise == candidate.franchise;
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
        spotlight.runtime = runtimeOf(*candidate.art);
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
        if (candidate->holiday > 0 && !usedKeys.contains(candidate->key)) {
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
