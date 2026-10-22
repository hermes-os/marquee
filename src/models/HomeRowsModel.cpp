#include "models/HomeRowsModel.hpp"

#include "models/PlaySomething.hpp"
#include "models/ShowsModel.hpp"

#include <QCollator>
#include <QFileInfo>
#include <QHash>
#include <QList>
#include <QStringList>
#include <QUrl>
#include <QUuid>

#include <algorithm>
#include <functional>
#include <utility>

namespace
{
[[nodiscard]] QUrl localUrl(const QString &path)
{
    return path.isEmpty() ? QUrl() : QUrl::fromLocalFile(path);
}

// MediaItem.swift:143-151 truncates the duration to whole minutes before it
// chooses the hour or the minute form, which is the form the Movies and search
// cards use.
[[nodiscard]] QString movieMetadata(const MediaItem &item)
{
    QStringList parts;
    if (item.year > 0) {
        parts.push_back(QString::number(item.year));
    }
    if (item.durationSeconds > 0) {
        const qint64 totalMinutes = item.durationSeconds / 60;
        parts.push_back(totalMinutes >= 60
                            ? QStringLiteral("%1h %2m").arg(totalMinutes / 60).arg(totalMinutes % 60)
                            : QStringLiteral("%1m").arg(totalMinutes));
    }
    return parts.join(QLatin1Char(' '));
}

[[nodiscard]] QString seasonLabel(int seasonCount)
{
    return QStringLiteral("%1 Season%2")
        .arg(seasonCount)
        .arg(seasonCount == 1 ? QString() : QStringLiteral("s"));
}

[[nodiscard]] int seasonCountOf(const QVector<MediaItem> &episodes)
{
    QList<int> seasons;
    for (const MediaItem &episode : episodes) {
        if (!seasons.contains(episode.seasonNumber)) {
            seasons.push_back(episode.seasonNumber);
        }
    }
    return static_cast<int>(seasons.size());
}

[[nodiscard]] home_rows::Card movieCard(const MediaItem &movie)
{
    return home_rows::Card{.mediaId = movie.id,
                           .showName = {},
                           .opensEpisode = false,
                           .title = movie.title,
                           .year = movie.year,
                           .posterPath = movie.posterAbsolutePath,
                           .metadata = movieMetadata(movie),
                           .formatBadge = QFileInfo(movie.relativePath).suffix().toUpper()};
}

// The card of an episode: the show's name and poster, with the episode's label
// beneath, which opens the show at that episode.
[[nodiscard]] home_rows::Card episodeCard(const MediaItem &episode)
{
    return home_rows::Card{.mediaId = episode.id,
                           .showName = episode.showName,
                           .opensEpisode = true,
                           .title = episode.showName,
                           .year = 0,
                           .posterPath = episode.gridShowPosterPath(),
                           .metadata = episode.episodeLabel(),
                           .formatBadge = episode.episodeLabel()};
}

[[nodiscard]] home_rows::Card showCard(const QVector<MediaItem> &episodes)
{
    const MediaItem &first = episodes.first();
    const QString seasons = seasonLabel(seasonCountOf(episodes));
    return home_rows::Card{.mediaId = first.id,
                           .showName = first.showName,
                           .opensEpisode = false,
                           .title = first.showName,
                           .year = 0,
                           .posterPath = first.gridShowPosterPath(),
                           .metadata = seasons,
                           .formatBadge = seasons};
}

struct Show
{
    QString name;
    // In season and episode order.
    QVector<MediaItem> episodes;
};

// BrowseSnapshotStore.swift:3078-3101: episodes grouped by show name, each
// show's episodes in season and episode order.
[[nodiscard]] QVector<Show> groupShows(const QVector<MediaItem> &items)
{
    QVector<Show> shows;
    QHash<QString, int> index;
    for (const MediaItem &item : items) {
        if (!item.isEpisode()) {
            continue;
        }
        const auto found = index.constFind(item.showName);
        if (found == index.cend()) {
            index.insert(item.showName, static_cast<int>(shows.size()));
            shows.push_back(Show{.name = item.showName, .episodes = {item}});
        } else {
            shows[found.value()].episodes.push_back(item);
        }
    }
    for (Show &show : shows) {
        show_order::sortEpisodes(show.episodes);
    }
    return shows;
}

// An unknown time sorts as the oldest, so a title with no recorded time is
// never placed ahead of one with a time.
[[nodiscard]] bool newer(const QDateTime &left, const QDateTime &right)
{
    if (left.isValid() != right.isValid()) {
        return left.isValid();
    }
    return left > right;
}

[[nodiscard]] bool hasWatchState(const MediaItem &episode)
{
    return episode.watched || episode.hasProgress();
}

struct Dated
{
    QDateTime when;
    home_rows::Card card;
};

[[nodiscard]] QVector<home_rows::Card> newestFirst(QVector<Dated> dated)
{
    std::stable_sort(dated.begin(), dated.end(), [](const Dated &left, const Dated &right) {
        if (left.when != right.when) {
            return newer(left.when, right.when);
        }
        const int byTitle = QString::compare(left.card.title, right.card.title, Qt::CaseInsensitive);
        return byTitle != 0 ? byTitle < 0 : left.card.mediaId < right.card.mediaId;
    });
    QVector<home_rows::Card> cards;
    cards.reserve(dated.size());
    for (Dated &entry : dated) {
        cards.push_back(std::move(entry.card));
    }
    return cards;
}

[[nodiscard]] home_rows::Row makeRow(const QString &id,
                                     const QString &title,
                                     QVector<home_rows::Card> cards)
{
    home_rows::Row row{.id = id, .title = title, .cards = {}, .totalCount = 0};
    row.totalCount = static_cast<int>(cards.size());
    if (cards.size() > home_rows::kCardsPerRow) {
        cards.resize(home_rows::kCardsPerRow);
    }
    row.cards = std::move(cards);
    return row;
}
}

int home_rows::continueIndexOf(const QVector<MediaItem> &episodes)
{
    // An episode the viewer left part-way wins over the one after the last
    // watched: they are in the middle of it. With several, the one played
    // most recently, and the later episode when no time says otherwise.
    int inProgress = -1;
    for (int index = 0; index < episodes.size(); ++index) {
        if (!episodes.at(index).hasProgress()) {
            continue;
        }
        if (inProgress < 0
            || !newer(episodes.at(inProgress).lastPlayedAt, episodes.at(index).lastPlayedAt)) {
            inProgress = index;
        }
    }
    if (inProgress >= 0) {
        return inProgress;
    }
    // `upNextIndexOf` starts an untouched show at its first episode; Home
    // gives such a show no card, because nobody has begun it.
    if (!std::any_of(episodes.cbegin(), episodes.cend(), hasWatchState)) {
        return -1;
    }
    return show_order::upNextIndexOf(episodes);
}

QVector<home_rows::Card> home_rows::continueWatching(const QVector<MediaItem> &items,
                                                     const QDateTime &now)
{
    // A title idle this long leaves the row. Its watch state is untouched; it
    // only stops being offered here.
    const QDateTime cutoff = now.addDays(-kIdleDays);
    const auto idle = [&cutoff](const QDateTime &lastPlayed) {
        return lastPlayed.isValid() && lastPlayed <= cutoff;
    };

    QVector<Dated> dated;
    for (const MediaItem &item : items) {
        if (item.isMovie() && item.hasProgress() && !idle(item.lastPlayedAt)) {
            dated.push_back(Dated{.when = item.lastPlayedAt, .card = movieCard(item)});
        }
    }
    for (const Show &show : groupShows(items)) {
        const int index = continueIndexOf(show.episodes);
        if (index < 0) {
            continue;
        }
        QDateTime lastPlayed;
        for (const MediaItem &episode : show.episodes) {
            if (hasWatchState(episode) && newer(episode.lastPlayedAt, lastPlayed)) {
                lastPlayed = episode.lastPlayedAt;
            }
        }
        if (idle(lastPlayed)) {
            continue;
        }
        dated.push_back(Dated{.when = lastPlayed, .card = episodeCard(show.episodes.at(index))});
    }
    return newestFirst(std::move(dated));
}

QVector<home_rows::Card> home_rows::recentlyWatched(const QVector<MediaItem> &items)
{
    QVector<Dated> dated;
    for (const MediaItem &item : items) {
        if (item.isMovie() && item.watched && item.lastPlayedAt.isValid()) {
            dated.push_back(Dated{.when = item.lastPlayedAt, .card = movieCard(item)});
        }
    }
    for (const Show &show : groupShows(items)) {
        const MediaItem *latest = nullptr;
        for (const MediaItem &episode : show.episodes) {
            if (episode.watched && episode.lastPlayedAt.isValid()
                && (latest == nullptr || episode.lastPlayedAt > latest->lastPlayedAt)) {
                latest = &episode;
            }
        }
        if (latest != nullptr) {
            dated.push_back(Dated{.when = latest->lastPlayedAt, .card = episodeCard(*latest)});
        }
    }
    return newestFirst(std::move(dated));
}

QVector<home_rows::Card> home_rows::recentlyAdded(const QVector<MediaItem> &items)
{
    QVector<Dated> dated;
    for (const MediaItem &item : items) {
        if (item.isMovie() && !item.watched) {
            dated.push_back(Dated{.when = item.modifiedAt, .card = movieCard(item)});
        }
    }
    for (const Show &show : groupShows(items)) {
        // A show watched through is hidden; one episode left keeps it.
        if (std::all_of(show.episodes.cbegin(), show.episodes.cend(),
                        [](const MediaItem &episode) { return episode.watched; })) {
            continue;
        }
        QDateTime newest;
        for (const MediaItem &episode : show.episodes) {
            if (newer(episode.modifiedAt, newest)) {
                newest = episode.modifiedAt;
            }
        }
        dated.push_back(Dated{.when = newest, .card = showCard(show.episodes)});
    }
    return newestFirst(std::move(dated));
}

QVector<home_rows::Card> home_rows::playSomethingCards(const QVector<MediaItem> &items)
{
    QVector<Card> cards;
    const QVector<MediaItem> ordered = play_something::candidates(items, play_something::kHomeSalt);
    for (const MediaItem &movie : ordered) {
        if (cards.size() == play_something::kRowLimit) {
            break;
        }
        cards.push_back(movieCard(movie));
    }
    return cards;
}

QVector<home_rows::Row> home_rows::decadeRows(const QVector<MediaItem> &items)
{
    QHash<int, QVector<MediaItem>> byDecade;
    for (const MediaItem &item : items) {
        if (item.isMovie() && item.year > 0) {
            byDecade[(item.year / 10) * 10].push_back(item);
        }
    }
    QList<int> decades;
    for (auto it = byDecade.cbegin(); it != byDecade.cend(); ++it) {
        if (it.value().size() >= 2) {
            decades.push_back(it.key());
        }
    }
    std::sort(decades.begin(), decades.end(), std::greater<>());

    QCollator collator;
    collator.setCaseSensitivity(Qt::CaseInsensitive);
    QVector<Row> rows;
    for (const int decade : std::as_const(decades)) {
        QVector<MediaItem> movies = byDecade.value(decade);
        std::stable_sort(movies.begin(), movies.end(),
                         [&collator](const MediaItem &left, const MediaItem &right) {
                             return collator.compare(left.title, right.title) < 0;
                         });
        QVector<Card> cards;
        cards.reserve(movies.size());
        for (const MediaItem &movie : std::as_const(movies)) {
            cards.push_back(movieCard(movie));
        }
        rows.push_back(makeRow(QStringLiteral("decade-%1s").arg(decade),
                               QStringLiteral("The %1s").arg(decade), std::move(cards)));
    }
    return rows;
}

QVector<home_rows::Row> home_rows::compose(const QVector<MediaItem> &items, const QDateTime &now)
{
    QVector<Row> rows;
    const auto append = [&rows](Row row) {
        if (row.totalCount > 0) {
            rows.push_back(std::move(row));
        }
    };

    append(makeRow(QStringLiteral("continue-watching"), QStringLiteral("Continue Watching"),
                   continueWatching(items, now)));
    append(makeRow(QStringLiteral("recently-watched"), QStringLiteral("Recently Watched"),
                   recentlyWatched(items)));

    // BrowseSnapshotStore.swift:2856-2860 puts Play Something here; :2862-2870
    // puts the taste rows (Because You Watched, Hidden Gems, Short Tonight) and
    // the seasonal rows after it, before Recently Added. Those arrive with
    // their own inputs; append them at this point to keep the released order.
    append(makeRow(QString::fromLatin1(play_something::kRowId), QStringLiteral("Play Something"),
                   playSomethingCards(items)));

    append(makeRow(QStringLiteral("recently-added"), QStringLiteral("Recently Added"),
                   recentlyAdded(items)));

    // :2876-2881 puts Holiday Movies after Recently Added and before the
    // decades. MovieRowsModel already composes that row for the Movies route.

    for (Row &row : decadeRows(items)) {
        append(std::move(row));
    }

    QVector<Card> allMovies;
    for (const MediaItem &item : items) {
        if (item.isMovie()) {
            allMovies.push_back(movieCard(item));
        }
    }
    append(makeRow(QStringLiteral("all-movies"), QStringLiteral("All Movies"),
                   std::move(allMovies)));
    return rows;
}

HomeCardModel::HomeCardModel(QObject *parent)
    : QAbstractListModel(parent)
{
}

int HomeCardModel::rowCount(const QModelIndex &parent) const
{
    return parent.isValid() ? 0 : static_cast<int>(m_cards.size());
}

QVariant HomeCardModel::data(const QModelIndex &index, int role) const
{
    if (!index.isValid() || index.row() < 0 || index.row() >= m_cards.size()) {
        return {};
    }
    const home_rows::Card &card = m_cards.at(index.row());
    switch (role) {
    case MediaIdRole:
        return card.mediaId;
    case TitleRole:
        return card.title;
    case YearRole:
        return card.year;
    case PosterUrlRole:
        return localUrl(card.posterPath);
    case MetadataRole:
        return card.metadata;
    case FormatBadgeRole:
        return card.formatBadge;
    case ShowNameRole:
        return card.showName;
    default:
        return {};
    }
}

QHash<int, QByteArray> HomeCardModel::roleNames() const
{
    return {{MediaIdRole, "mediaId"},
            {TitleRole, "title"},
            {YearRole, "year"},
            {PosterUrlRole, "posterUrl"},
            {MetadataRole, "metadata"},
            {FormatBadgeRole, "formatBadge"},
            {ShowNameRole, "showName"}};
}

void HomeCardModel::replaceCards(QVector<home_rows::Card> cards)
{
    if (cards == m_cards) {
        return;
    }
    bool sameCards = cards.size() == m_cards.size();
    for (qsizetype index = 0; sameCards && index < cards.size(); ++index) {
        sameCards = cards.at(index).mediaId == m_cards.at(index).mediaId
            && cards.at(index).showName == m_cards.at(index).showName;
    }
    if (sameCards) {
        // The same cards with new facts (a runtime, an episode label): the
        // delegates on screen are updated, not rebuilt under the remote.
        m_cards = std::move(cards);
        emit dataChanged(index(0), index(static_cast<int>(m_cards.size()) - 1));
        return;
    }
    beginResetModel();
    m_cards = std::move(cards);
    endResetModel();
}

const home_rows::Card *HomeCardModel::cardAt(int column) const
{
    return column >= 0 && column < m_cards.size() ? &m_cards.at(column) : nullptr;
}

HomeRowsModel::HomeRowsModel(QObject *parent)
    : QAbstractListModel(parent),
      m_focus(this)
{
}

int HomeRowsModel::rowCount(const QModelIndex &parent) const
{
    return parent.isValid() ? 0 : static_cast<int>(m_rows.size());
}

QVariant HomeRowsModel::data(const QModelIndex &index, int role) const
{
    if (!index.isValid() || index.row() < 0 || index.row() >= m_rows.size()) {
        return {};
    }
    const RowSlot &row = m_rows.at(index.row());
    switch (role) {
    case RowIdRole:
        return row.id;
    case RowTitleRole:
        return row.title;
    case ItemCountRole:
        return row.totalCount;
    case ItemsRole:
        return QVariant::fromValue(static_cast<QAbstractItemModel *>(row.cards));
    default:
        return {};
    }
}

QHash<int, QByteArray> HomeRowsModel::roleNames() const
{
    return {{RowIdRole, "rowId"},
            {RowTitleRole, "rowTitle"},
            {ItemCountRole, "itemCount"},
            {ItemsRole, "items"}};
}

FocusNavigator *HomeRowsModel::focus()
{
    return &m_focus;
}

QVariantMap HomeRowsModel::cardAt(int row, int column) const
{
    if (row < 0 || row >= m_rows.size()) {
        return {};
    }
    const home_rows::Card *card = m_rows.at(row).cards->cardAt(column);
    if (card == nullptr) {
        return {};
    }
    return {{QStringLiteral("mediaId"), card->mediaId},
            {QStringLiteral("showName"), card->showName},
            {QStringLiteral("opensEpisode"), card->opensEpisode},
            {QStringLiteral("row"), row},
            {QStringLiteral("column"), column}};
}

QVariantMap HomeRowsModel::cardForId(int row, const QString &mediaId) const
{
    if (row < 0 || row >= m_rows.size()) {
        return {};
    }
    const HomeCardModel *cards = m_rows.at(row).cards;
    for (int column = 0; column < cards->rowCount(); ++column) {
        if (cards->cardAt(column)->mediaId == mediaId) {
            return cardAt(row, column);
        }
    }
    return {};
}

bool HomeRowsModel::playSomethingFocused() const
{
    return m_playSomethingFocused;
}

void HomeRowsModel::setPlaySomethingFocused(bool focused)
{
    if (m_playSomethingFocused == focused) {
        return;
    }
    m_playSomethingFocused = focused;
    emit playSomethingFocusedChanged();
}

bool HomeRowsModel::moveUp()
{
    if (m_playSomethingFocused) {
        // The capsule is the top of the tree: Up is spent without moving.
        return true;
    }
    if (m_focus.moveUp()) {
        return true;
    }
    // Up from the first row is the capsule above it. The title bar, and the
    // capsule with it, is hidden while the library holds nothing, so the
    // remote must not come to rest on a control nobody can see. Up is still
    // spent.
    if (!m_items.isEmpty()) {
        setPlaySomethingFocused(true);
    }
    return true;
}

bool HomeRowsModel::moveDown()
{
    if (m_playSomethingFocused) {
        // The card the remote left is still the focused one.
        setPlaySomethingFocused(false);
        return true;
    }
    return m_focus.moveDown();
}

bool HomeRowsModel::moveLeft()
{
    // Left on the capsule is spent without moving: the oracle hands the remote
    // to the sidebar only from a card (HomeDetailView.swift:993).
    return m_playSomethingFocused || m_focus.moveLeft();
}

bool HomeRowsModel::moveRight()
{
    return m_playSomethingFocused || m_focus.moveRight();
}

void HomeRowsModel::focusCard(int row, int column)
{
    setPlaySomethingFocused(false);
    m_focus.setPosition(row, column);
}

void HomeRowsModel::resetFocus()
{
    setPlaySomethingFocused(false);
    QVector<int> rowLengths;
    rowLengths.reserve(m_rows.size());
    for (const RowSlot &row : std::as_const(m_rows)) {
        rowLengths.push_back(row.cards->rowCount());
    }
    placeFirstTarget(std::move(rowLengths));
}

void HomeRowsModel::placeFirstTarget(QVector<int> rowLengths)
{
    m_focus.setRows(std::move(rowLengths));
    m_focus.reset();
}

QStringList HomeRowsModel::playSomethingCandidates() const
{
    // A fresh salt per press (AppState.swift:239), so consecutive presses
    // differ.
    const QString salt = m_saltSource ? m_saltSource()
                                      : QUuid::createUuid().toString(QUuid::WithoutBraces);
    QStringList ids;
    for (const MediaItem &item : play_something::candidates(m_items, salt)) {
        ids.push_back(item.id);
    }
    return ids;
}

QString HomeRowsModel::playSomethingPick() const
{
    const QStringList ids = playSomethingCandidates();
    return ids.isEmpty() ? QString() : ids.constFirst();
}

void HomeRowsModel::setPlaySomethingSaltForTest(std::function<QString()> salt)
{
    m_saltSource = std::move(salt);
}

void HomeRowsModel::setClockForTest(std::function<QDateTime()> clock)
{
    m_clock = std::move(clock);
    recompose();
}

QDateTime HomeRowsModel::now() const
{
    return m_clock ? m_clock() : QDateTime::currentDateTimeUtc();
}

void HomeRowsModel::replaceItems(QVector<MediaItem> items)
{
    m_items = std::move(items);
    if (m_items.isEmpty()) {
        // The capsule goes with the title bar when the library empties.
        setPlaySomethingFocused(false);
    }
    recompose();
}

void HomeRowsModel::applyWatchProgress(const QString &mediaId,
                                       qint64 positionMs,
                                       qint64 durationMs,
                                       bool completed)
{
    const auto match = std::find_if(m_items.begin(), m_items.end(), [&mediaId](const MediaItem &item) {
        return item.id == mediaId;
    });
    if (match == m_items.end()) {
        return;
    }
    match->resumePositionMs = completed ? 0 : positionMs;
    if (durationMs > 0) {
        match->durationSeconds = durationMs / 1000;
    }
    match->watched = completed;
    match->lastPlayedAt = now();
    recompose();
}

HomeCardModel *HomeRowsModel::cardModelFor(const QString &rowId)
{
    HomeCardModel *&model = m_cardModels[rowId];
    if (model == nullptr) {
        model = new HomeCardModel(this);
    }
    return model;
}

void HomeRowsModel::recompose()
{
    QVector<home_rows::Row> composed = home_rows::compose(m_items, now());

    // The remote follows the card it rests on, not its row and column number:
    // a row inserted above it would otherwise hand it a different title.
    QString focusedRowId;
    QString focusedMediaId;
    if (!m_focus.empty() && m_focus.row() < m_rows.size()) {
        const RowSlot &focused = m_rows.at(m_focus.row());
        focusedRowId = focused.id;
        if (const home_rows::Card *card = focused.cards->cardAt(m_focus.column())) {
            focusedMediaId = card->mediaId;
        }
    }
    const int focusedColumn = m_focus.column();

    // Rows that survive keep their delegates: a viewing recorded while Home is
    // on screen adds or drops a row and updates cards, and must not rebuild the
    // rows the remote is resting on. The composition has one fixed order of
    // ids, so the survivors are in the same relative order in both lists; if
    // they are not, the whole list is replaced.
    QStringList survivors;
    QStringList survivorsNow;
    for (const RowSlot &row : std::as_const(m_rows)) {
        const bool kept = std::any_of(composed.cbegin(), composed.cend(),
                                      [&row](const home_rows::Row &next) { return next.id == row.id; });
        if (kept) {
            survivors.push_back(row.id);
        }
    }
    for (const home_rows::Row &row : std::as_const(composed)) {
        if (std::any_of(m_rows.cbegin(), m_rows.cend(),
                        [&row](const RowSlot &old) { return old.id == row.id; })) {
            survivorsNow.push_back(row.id);
        }
    }

    if (survivors != survivorsNow) {
        beginResetModel();
        m_rows.clear();
        for (home_rows::Row &row : composed) {
            HomeCardModel *cards = cardModelFor(row.id);
            cards->replaceCards(std::move(row.cards));
            m_rows.push_back(RowSlot{.id = row.id,
                                     .title = row.title,
                                     .totalCount = row.totalCount,
                                     .cards = cards});
        }
        endResetModel();
    } else {
        for (int index = static_cast<int>(m_rows.size()) - 1; index >= 0; --index) {
            const QString id = m_rows.at(index).id;
            if (!std::any_of(composed.cbegin(), composed.cend(),
                             [&id](const home_rows::Row &next) { return next.id == id; })) {
                beginRemoveRows({}, index, index);
                m_rows.removeAt(index);
                endRemoveRows();
            }
        }
        for (int index = 0; index < composed.size(); ++index) {
            home_rows::Row &next = composed[index];
            HomeCardModel *cards = cardModelFor(next.id);
            if (index < m_rows.size() && m_rows.at(index).id == next.id) {
                RowSlot &slot = m_rows[index];
                cards->replaceCards(std::move(next.cards));
                if (slot.title != next.title || slot.totalCount != next.totalCount) {
                    slot.title = next.title;
                    slot.totalCount = next.totalCount;
                    emit dataChanged(this->index(index), this->index(index));
                }
                continue;
            }
            // The card model is filled before the row appears, so a delegate
            // is never created over an empty list.
            cards->replaceCards(std::move(next.cards));
            beginInsertRows({}, index, index);
            m_rows.insert(index, RowSlot{.id = next.id,
                                         .title = next.title,
                                         .totalCount = next.totalCount,
                                         .cards = cards});
            endInsertRows();
        }
    }

    // A shorter or emptied composition must not leave the remote addressing a
    // card that is gone, and a row inserted above it must not move it onto a
    // different title.
    QVector<int> rowLengths;
    rowLengths.reserve(m_rows.size());
    for (const RowSlot &row : std::as_const(m_rows)) {
        rowLengths.push_back(row.cards->rowCount());
    }
    if (focusedRowId.isEmpty()) {
        m_focus.setRows(std::move(rowLengths));
        return;
    }
    const auto found = std::find_if(m_rows.cbegin(), m_rows.cend(), [&focusedRowId](const RowSlot &row) {
        return row.id == focusedRowId && row.cards->rowCount() > 0;
    });
    if (found == m_rows.cend()) {
        // The row the remote rested on is gone. The oracle's repair
        // (HomeFocusContentPolicy.repair, :1128-1134) sends focus to the first
        // card of the first row that has one, and so does this.
        placeFirstTarget(std::move(rowLengths));
        return;
    }
    // The same card where the row still holds it; otherwise the column it was
    // at, clamped to the row's new length (repair, :1115-1126).
    int column = focusedColumn;
    for (int index = 0; index < found->cards->rowCount(); ++index) {
        if (found->cards->cardAt(index)->mediaId == focusedMediaId) {
            column = index;
            break;
        }
    }
    m_focus.setRows(std::move(rowLengths),
                    static_cast<int>(std::distance(m_rows.cbegin(), found)), column);
}
