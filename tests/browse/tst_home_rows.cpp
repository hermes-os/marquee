#include <QtTest>

#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QScopeGuard>
#include <QSet>
#include <QSqlQuery>
#include <QTemporaryDir>

#include "app/AppPaths.hpp"
#include "app/ApplicationController.hpp"
#include "catalog/CatalogDatabase.hpp"
#include "catalog/CatalogStore.hpp"
#include "catalog/LibraryScanner.hpp"
#include "models/HomeRowsModel.hpp"
#include "models/ShowsModel.hpp"
#include "profiles/ProfileStore.hpp"

namespace
{
const QDateTime kNow = QDateTime(QDate(2026, 10, 15), QTime(12, 0), QTimeZone::UTC);

[[nodiscard]] QDateTime daysAgo(int days)
{
    return kNow.addDays(-days);
}

[[nodiscard]] MediaItem movie(const QString &title,
                              int year,
                              const QDateTime &modified = daysAgo(100))
{
    MediaItem item;
    item.id = QStringLiteral("root/") + title;
    item.relativePath = title + QStringLiteral(".mkv");
    item.title = title;
    item.mediaKind = QStringLiteral("movie");
    item.year = year;
    item.modifiedAt = modified;
    return item;
}

[[nodiscard]] MediaItem episode(const QString &show,
                                int season,
                                int number,
                                const QDateTime &modified = daysAgo(100))
{
    MediaItem item;
    item.id = QStringLiteral("root/%1/S%2E%3").arg(show).arg(season).arg(number);
    item.relativePath = item.id + QStringLiteral(".mkv");
    item.title = QStringLiteral("%1 S%2E%3").arg(show).arg(season).arg(number);
    item.mediaKind = QStringLiteral("episode");
    item.showName = show;
    item.seasonNumber = season;
    item.episodeNumber = number;
    item.modifiedAt = modified;
    return item;
}

void inProgress(MediaItem &item, const QDateTime &playedAt)
{
    item.resumePositionMs = 60'000;
    item.lastPlayedAt = playedAt;
}

void watched(MediaItem &item, const QDateTime &playedAt)
{
    item.watched = true;
    item.lastPlayedAt = playedAt;
}

[[nodiscard]] QStringList ids(const QVector<home_rows::Card> &cards)
{
    QStringList result;
    for (const home_rows::Card &card : cards) {
        result.push_back(card.mediaId);
    }
    return result;
}

[[nodiscard]] QStringList rowIds(const QVector<home_rows::Row> &rows)
{
    QStringList result;
    for (const home_rows::Row &row : rows) {
        result.push_back(row.id);
    }
    return result;
}

[[nodiscard]] const home_rows::Row *rowNamed(const QVector<home_rows::Row> &rows, const QString &id)
{
    for (const home_rows::Row &row : rows) {
        if (row.id == id) {
            return &row;
        }
    }
    return nullptr;
}

[[nodiscard]] bool writeFile(const QString &path)
{
    QDir().mkpath(QFileInfo(path).absolutePath());
    QFile file(path);
    return file.open(QIODevice::WriteOnly) && file.write("media") == 5;
}

[[nodiscard]] QString catalogIdOf(const QVector<MediaItem> &items, const QString &title)
{
    for (const MediaItem &item : items) {
        if (item.title == title) {
            return item.id;
        }
    }
    return {};
}
}

class HomeRowsTest final : public QObject
{
    Q_OBJECT

private slots:
    void aStartedShowFoldsIntoOneCardForTheEpisodeAfterTheLastWatched()
    {
        MediaItem first = episode(QStringLiteral("Bluey"), 1, 1);
        MediaItem second = episode(QStringLiteral("Bluey"), 1, 2);
        const MediaItem third = episode(QStringLiteral("Bluey"), 1, 3);
        watched(first, daysAgo(3));
        watched(second, daysAgo(2));

        const QVector<home_rows::Card> cards =
            home_rows::continueWatching({third, first, second}, kNow);

        // The oracle lists a show only once its up-next episode has progress,
        // so this show would have left Home after every finished episode.
        QCOMPARE(cards.size(), 1);
        QCOMPARE(cards.first().mediaId, third.id);
        QCOMPARE(cards.first().showName, QStringLiteral("Bluey"));
        QVERIFY(cards.first().opensEpisode);
        QCOMPARE(cards.first().metadata, QStringLiteral("S1 E3"));
    }

    void anEpisodeInProgressWinsOverTheOneAfterTheLastWatched()
    {
        MediaItem first = episode(QStringLiteral("Bluey"), 1, 1);
        MediaItem second = episode(QStringLiteral("Bluey"), 1, 2);
        MediaItem third = episode(QStringLiteral("Bluey"), 1, 3);
        const MediaItem fourth = episode(QStringLiteral("Bluey"), 1, 4);
        watched(first, daysAgo(9));
        inProgress(second, daysAgo(5));
        // The viewer jumped ahead and finished the third: "the one after the
        // last watched" would name the fourth, but they left the second open.
        watched(third, daysAgo(2));

        const QVector<home_rows::Card> cards =
            home_rows::continueWatching({first, second, third, fourth}, kNow);

        QCOMPARE(ids(cards), QStringList{second.id});
    }

    void ofSeveralEpisodesInProgressTheMostRecentlyPlayedIsTheCard()
    {
        MediaItem first = episode(QStringLiteral("Bluey"), 1, 1);
        MediaItem second = episode(QStringLiteral("Bluey"), 1, 2);
        inProgress(first, daysAgo(1));
        inProgress(second, daysAgo(8));

        QCOMPARE(ids(home_rows::continueWatching({first, second}, kNow)), QStringList{first.id});
    }

    void aShowWhoseFinaleIsWatchedHasNoCard()
    {
        MediaItem first = episode(QStringLiteral("Bluey"), 1, 1);
        MediaItem second = episode(QStringLiteral("Bluey"), 1, 2);
        watched(first, daysAgo(3));
        watched(second, daysAgo(2));

        QVERIFY(home_rows::continueWatching({first, second}, kNow).isEmpty());
        QCOMPARE(home_rows::continueIndexOf({first, second}), -1);
    }

    // Duplicate files of one episode: the copy of a watched episode is not
    // "the next one".
    void anUnwatchedCopyOfAWatchedEpisodeIsNotUpNext()
    {
        MediaItem first = episode(QStringLiteral("Bluey"), 1, 1);
        watched(first, daysAgo(2));
        MediaItem copy = episode(QStringLiteral("Bluey"), 1, 1);
        copy.id += QStringLiteral(" (copy)");
        const MediaItem second = episode(QStringLiteral("Bluey"), 1, 2);

        // The copy sorts right behind the watched file, then comes S1E2.
        QCOMPARE(ids(home_rows::continueWatching({first, copy, second}, kNow)),
                 QStringList{second.id});
        QCOMPARE(home_rows::continueIndexOf({first, copy, second}), 2);
        // Nothing follows the episode: no card, not the copy.
        QVERIFY(home_rows::continueWatching({first, copy}, kNow).isEmpty());
        QCOMPARE(home_rows::continueIndexOf({first, copy}), -1);
    }

    void anUnwatchedCopyOfAWatchedFinaleGivesNoCard()
    {
        MediaItem first = episode(QStringLiteral("Bluey"), 1, 1);
        MediaItem finale = episode(QStringLiteral("Bluey"), 1, 2);
        watched(first, daysAgo(3));
        watched(finale, daysAgo(2));
        MediaItem copy = episode(QStringLiteral("Bluey"), 1, 2);
        copy.id += QStringLiteral(" (copy)");

        QVERIFY(home_rows::continueWatching({first, finale, copy}, kNow).isEmpty());
        QCOMPARE(home_rows::continueIndexOf({first, finale, copy}), -1);
    }

    void aShowNobodyStartedHasNoCard()
    {
        QVERIFY(home_rows::continueWatching({episode(QStringLiteral("Bluey"), 1, 1),
                                             episode(QStringLiteral("Bluey"), 1, 2)},
                                            kNow)
                    .isEmpty());
        QCOMPARE(home_rows::continueIndexOf({}), -1);
    }

    void aMovieNeedsAResumePointAndAWatchedOneHasNone()
    {
        MediaItem resumable = movie(QStringLiteral("Arrival"), 2016);
        inProgress(resumable, daysAgo(2));
        MediaItem finished = movie(QStringLiteral("Coco"), 2017);
        watched(finished, daysAgo(2));
        const MediaItem untouched = movie(QStringLiteral("Dune"), 2021);

        QCOMPARE(ids(home_rows::continueWatching({resumable, finished, untouched}, kNow)),
                 QStringList{resumable.id});
    }

    void continueWatchingIsOrderedByWhatWasPlayedMostRecently()
    {
        MediaItem oldMovie = movie(QStringLiteral("Arrival"), 2016);
        inProgress(oldMovie, daysAgo(20));
        MediaItem newMovie = movie(QStringLiteral("Dune"), 2021);
        inProgress(newMovie, daysAgo(1));
        MediaItem showEpisode = episode(QStringLiteral("Bluey"), 1, 1);
        inProgress(showEpisode, daysAgo(5));

        QCOMPARE(ids(home_rows::continueWatching({oldMovie, newMovie, showEpisode}, kNow)),
                 (QStringList{newMovie.id, showEpisode.id, oldMovie.id}));
    }

    void aTitleIdleForAYearLeavesContinueWatchingButKeepsItsWatchState()
    {
        MediaItem stale = movie(QStringLiteral("Arrival"), 2016);
        inProgress(stale, daysAgo(home_rows::kIdleDays));
        MediaItem fresh = movie(QStringLiteral("Dune"), 2021);
        inProgress(fresh, daysAgo(home_rows::kIdleDays - 1));
        MediaItem staleShow = episode(QStringLiteral("Bluey"), 1, 1);
        watched(staleShow, daysAgo(400));
        const MediaItem staleShowNext = episode(QStringLiteral("Bluey"), 1, 2);
        MediaItem freshShow = episode(QStringLiteral("Heartstopper"), 1, 1);
        watched(freshShow, daysAgo(2));
        const MediaItem freshShowNext = episode(QStringLiteral("Heartstopper"), 1, 2);

        const QVector<MediaItem> items{stale, fresh, staleShow, staleShowNext, freshShow,
                                       freshShowNext};
        const QVector<MediaItem> before = items;

        QCOMPARE(ids(home_rows::continueWatching(items, kNow)),
                 (QStringList{freshShowNext.id, fresh.id}));

        // Only the row forgets: nothing was written to the items, and the
        // title still resumes where it was left.
        QCOMPARE(items.size(), before.size());
        QVERIFY(items.at(0).hasProgress());
        QCOMPARE(items.at(0).resumePositionMs, qint64{60'000});
        QVERIFY(items.at(2).watched);
        // Playing it again brings it back at once.
        MediaItem replayed = stale;
        replayed.lastPlayedAt = kNow;
        QCOMPARE(ids(home_rows::continueWatching({replayed}, kNow)), QStringList{stale.id});
    }

    void recentlyWatchedHoldsWatchedMoviesAndOneEpisodePerShowWithNoIdleWindow()
    {
        MediaItem coco = movie(QStringLiteral("Coco"), 2017);
        watched(coco, daysAgo(500));
        MediaItem arrival = movie(QStringLiteral("Arrival"), 2016);
        watched(arrival, daysAgo(4));
        MediaItem unfinished = movie(QStringLiteral("Dune"), 2021);
        inProgress(unfinished, daysAgo(1));
        MediaItem first = episode(QStringLiteral("Bluey"), 1, 1);
        MediaItem second = episode(QStringLiteral("Bluey"), 1, 2);
        watched(first, daysAgo(9));
        watched(second, daysAgo(2));

        const QVector<home_rows::Card> cards =
            home_rows::recentlyWatched({coco, arrival, unfinished, first, second});

        QCOMPARE(ids(cards), (QStringList{second.id, arrival.id, coco.id}));
    }

    void recentlyAddedHoldsOneCardPerShowNewestFileFirst()
    {
        const MediaItem oldMovie = movie(QStringLiteral("Arrival"), 2016, daysAgo(50));
        const MediaItem newMovie = movie(QStringLiteral("Dune"), 2021, daysAgo(2));
        const MediaItem showOld = episode(QStringLiteral("Bluey"), 1, 1, daysAgo(40));
        // A new episode of a long-running show brings the show forward.
        const MediaItem showNew = episode(QStringLiteral("Bluey"), 1, 2, daysAgo(10));

        const QVector<home_rows::Card> cards =
            home_rows::recentlyAdded({oldMovie, showOld, newMovie, showNew});

        QCOMPARE(cards.size(), 3);
        QCOMPARE(cards.at(0).mediaId, newMovie.id);
        QCOMPARE(cards.at(1).showName, QStringLiteral("Bluey"));
        QVERIFY(!cards.at(1).opensEpisode);
        QCOMPARE(cards.at(1).metadata, QStringLiteral("1 Season"));
        QCOMPARE(cards.at(2).mediaId, oldMovie.id);
    }

    void recentlyAddedHidesWhatTheProfileHasWatched()
    {
        MediaItem seen = movie(QStringLiteral("Arrival"), 2016, daysAgo(1));
        watched(seen, daysAgo(1));
        const MediaItem unseen = movie(QStringLiteral("Dune"), 2021, daysAgo(2));
        MediaItem doneFirst = episode(QStringLiteral("Done"), 1, 1);
        MediaItem doneSecond = episode(QStringLiteral("Done"), 1, 2);
        watched(doneFirst, daysAgo(1));
        watched(doneSecond, daysAgo(1));
        MediaItem partFirst = episode(QStringLiteral("Part"), 1, 1);
        const MediaItem partSecond = episode(QStringLiteral("Part"), 1, 2);
        watched(partFirst, daysAgo(1));

        const QVector<home_rows::Card> cards = home_rows::recentlyAdded(
            {seen, unseen, doneFirst, doneSecond, partFirst, partSecond});

        QStringList names;
        for (const home_rows::Card &card : cards) {
            names.push_back(card.title);
        }
        names.sort();
        // The watched movie and the show watched through are hidden; one
        // episode left keeps its show.
        QCOMPARE(names, (QStringList{QStringLiteral("Dune"), QStringLiteral("Part")}));
    }

    void decadeRowsNeedTwoMoviesAndRunNewestDecadeFirst()
    {
        const QVector<MediaItem> items{
            movie(QStringLiteral("Heat"), 1995),    movie(QStringLiteral("Casino"), 1995),
            movie(QStringLiteral("Dune"), 2021),    movie(QStringLiteral("Coco"), 2017),
            movie(QStringLiteral("Alone"), 1985),   movie(QStringLiteral("Undated"), 0),
            movie(QStringLiteral("Arrival"), 2016),
        };

        const QVector<home_rows::Row> rows = home_rows::decadeRows(items);

        QCOMPARE(rowIds(rows), (QStringList{QStringLiteral("decade-2010s"),
                                            QStringLiteral("decade-1990s")}));
        QCOMPARE(rows.at(0).title, QStringLiteral("The 2010s"));
        QCOMPARE(ids(rows.at(1).cards),
                 (QStringList{QStringLiteral("root/Casino"), QStringLiteral("root/Heat")}));
    }

    void rowsComposeInTheReleasedOrderAndOmitEmptyOnes()
    {
        MediaItem resumed = movie(QStringLiteral("Arrival"), 2016, daysAgo(5));
        inProgress(resumed, daysAgo(1));
        MediaItem seen = movie(QStringLiteral("Coco"), 2017, daysAgo(6));
        watched(seen, daysAgo(2));

        const QVector<home_rows::Row> rows =
            home_rows::compose({resumed, seen, movie(QStringLiteral("Dune"), 2021)}, kNow);

        // No taste or seasonal rows exist yet. Play Something sits between
        // Recently Watched and Recently Added (BrowseSnapshotStore.swift
        // :2856-2860), and the 2010s hold two movies, so they get their row.
        QCOMPARE(rowIds(rows),
                 (QStringList{QStringLiteral("continue-watching"),
                              QStringLiteral("recently-watched"),
                              QStringLiteral("play-something"),
                              QStringLiteral("recently-added"), QStringLiteral("decade-2010s"),
                              QStringLiteral("all-movies")}));
        QCOMPARE(rowNamed(rows, QStringLiteral("play-something"))->title,
                 QStringLiteral("Play Something"));
        QCOMPARE(rowNamed(rows, QStringLiteral("continue-watching"))->title,
                 QStringLiteral("Continue Watching"));
        QCOMPARE(rowNamed(rows, QStringLiteral("recently-watched"))->title,
                 QStringLiteral("Recently Watched"));
        QCOMPARE(rowNamed(rows, QStringLiteral("recently-added"))->title,
                 QStringLiteral("Recently Added"));
        QCOMPARE(rowNamed(rows, QStringLiteral("all-movies"))->title,
                 QStringLiteral("All Movies"));

        // Nothing watched and nothing started: only the unconditional rows.
        QCOMPARE(rowIds(home_rows::compose({movie(QStringLiteral("Dune"), 2021)}, kNow)),
                 (QStringList{QStringLiteral("play-something"), QStringLiteral("recently-added"),
                              QStringLiteral("all-movies")}));
        QVERIFY(home_rows::compose({}, kNow).isEmpty());
    }

    void aRowDrawsAtMostEightCardsAndStillCountsItsWholeLength()
    {
        QVector<MediaItem> items;
        for (int index = 0; index < 11; ++index) {
            items.push_back(movie(QStringLiteral("Film %1").arg(index, 2, 10, QLatin1Char('0')),
                                  2000 + index, daysAgo(index + 1)));
        }

        const QVector<home_rows::Row> rows = home_rows::compose(items, kNow);

        for (const home_rows::Row &row : rows) {
            QVERIFY2(row.cards.size() <= home_rows::kCardsPerRow, qPrintable(row.id));
        }
        const home_rows::Row *all = rowNamed(rows, QStringLiteral("all-movies"));
        QVERIFY(all != nullptr);
        QCOMPARE(all->cards.size(), 8);
        QCOMPARE(all->totalCount, 11);
        const home_rows::Row *added = rowNamed(rows, QStringLiteral("recently-added"));
        QCOMPARE(added->cards.size(), 8);
        // Recently Added keeps its order past the cut: newest eight.
        QCOMPARE(added->cards.first().mediaId, QStringLiteral("root/Film 00"));
        QCOMPARE(added->cards.last().mediaId, QStringLiteral("root/Film 07"));
    }

    void aLibraryOfOnlyEpisodesComposesTvRowsAndNoMovieRow()
    {
        MediaItem first = episode(QStringLiteral("Bluey"), 1, 1);
        const MediaItem second = episode(QStringLiteral("Bluey"), 1, 2);
        watched(first, daysAgo(1));
        const MediaItem other = episode(QStringLiteral("The Wire"), 1, 1);

        const QVector<home_rows::Row> rows = home_rows::compose({first, second, other}, kNow);

        QCOMPARE(rowIds(rows),
                 (QStringList{QStringLiteral("continue-watching"),
                              QStringLiteral("recently-watched"),
                              QStringLiteral("recently-added")}));
        QCOMPARE(ids(rowNamed(rows, QStringLiteral("continue-watching"))->cards),
                 QStringList{second.id});
        QCOMPARE(rowNamed(rows, QStringLiteral("recently-added"))->totalCount, 2);
    }

    void aRecordedViewingMovesTheShowIntoContinueWatchingWithoutARescan()
    {
        HomeRowsModel model;
        model.setClockForTest([] { return kNow; });
        model.replaceItems({episode(QStringLiteral("Bluey"), 1, 1),
                            episode(QStringLiteral("Bluey"), 1, 2)});
        QCOMPARE(model.rowCount(), 1);
        QCOMPARE(model.data(model.index(0), HomeRowsModel::RowIdRole).toString(),
                 QStringLiteral("recently-added"));

        model.applyWatchProgress(QStringLiteral("root/Bluey/S1E1"), 0, 1'440'000, true);

        QCOMPARE(model.rowCount(), 3);
        QCOMPARE(model.data(model.index(0), HomeRowsModel::RowIdRole).toString(),
                 QStringLiteral("continue-watching"));
        const QVariantMap card = model.cardAt(0, 0);
        QCOMPARE(card.value(QStringLiteral("mediaId")).toString(),
                 QStringLiteral("root/Bluey/S1E2"));
        QCOMPARE(card.value(QStringLiteral("showName")).toString(), QStringLiteral("Bluey"));
        QVERIFY(card.value(QStringLiteral("opensEpisode")).toBool());
        QVERIFY(model.cardAt(0, 1).isEmpty());
        QVERIFY(model.cardAt(9, 0).isEmpty());
    }

    // A viewing recorded while Home is on screen must not rebuild the rows the
    // remote is resting on: the new row is inserted, and a card whose facts
    // changed is updated in place.
    void aRecordedViewingInsertsItsRowAndUpdatesCardsInPlace()
    {
        HomeRowsModel model;
        model.setClockForTest([] { return kNow; });
        model.replaceItems({movie(QStringLiteral("Arrival"), 2016),
                            movie(QStringLiteral("Coco"), 2017)});
        QCOMPARE(model.rowCount(), 4);
        const QModelIndex lastRow = model.index(model.rowCount() - 1);
        const auto *cards = qobject_cast<const HomeCardModel *>(
            model.data(lastRow, HomeRowsModel::ItemsRole).value<QObject *>());
        QVERIFY(cards != nullptr);
        QCOMPARE(cards->data(cards->index(0), HomeCardModel::MetadataRole).toString(),
                 QStringLiteral("2016"));

        QSignalSpy reset(&model, &QAbstractItemModel::modelReset);
        QSignalSpy inserted(&model, &QAbstractItemModel::rowsInserted);
        QSignalSpy cardsChanged(cards, &QAbstractItemModel::dataChanged);
        QSignalSpy cardsReset(cards, &QAbstractItemModel::modelReset);

        model.applyWatchProgress(QStringLiteral("root/Arrival"), 600'000, 7'200'000, false);

        QCOMPARE(reset.count(), 0);
        QCOMPARE(inserted.count(), 1);
        QCOMPARE(inserted.constFirst().at(1).toInt(), 0);
        QCOMPARE(model.data(model.index(0), HomeRowsModel::RowIdRole).toString(),
                 QStringLiteral("continue-watching"));
        // The All Movies card kept its delegate and learned its runtime.
        QCOMPARE(cardsReset.count(), 0);
        QVERIFY(cardsChanged.count() > 0);
        QCOMPARE(cards->data(cards->index(0), HomeCardModel::MetadataRole).toString(),
                 QStringLiteral("2016 2h 0m"));

        // Watching it to the end drops the row again without a reset.
        QSignalSpy removed(&model, &QAbstractItemModel::rowsRemoved);
        model.applyWatchProgress(QStringLiteral("root/Arrival"), 0, 7'200'000, true);
        QCOMPARE(reset.count(), 0);
        QVERIFY(removed.count() >= 1);
        QVERIFY(model.rowCount() >= 3);
        // The title now watched is no longer offered by Play Something.
        const auto *offered = qobject_cast<const HomeCardModel *>(
            model.data(model.index(1), HomeRowsModel::ItemsRole).value<QObject *>());
        QCOMPARE(model.data(model.index(1), HomeRowsModel::RowIdRole).toString(),
                 QStringLiteral("play-something"));
        QCOMPARE(offered->rowCount(), 1);
        QCOMPARE(offered->data(offered->index(0), HomeCardModel::MediaIdRole).toString(),
                 QStringLiteral("root/Coco"));
    }

    // The remote follows the card it rests on. A row inserted above it moves
    // the card's row number, and Enter must still open the same title.
    void theRemoteKeepsItsCardWhenARowIsInsertedAboveIt()
    {
        HomeRowsModel model;
        model.setClockForTest([] { return kNow; });
        model.replaceItems({movie(QStringLiteral("Arrival"), 2016), movie(QStringLiteral("Coco"), 2017),
                            movie(QStringLiteral("Dune"), 2021), movie(QStringLiteral("Tenet"), 2020)});
        const int allMovies = model.rowCount() - 1;
        QCOMPARE(model.data(model.index(allMovies), HomeRowsModel::RowIdRole).toString(),
                 QStringLiteral("all-movies"));
        model.focus()->setPosition(allMovies, 2);
        QCOMPARE(model.cardAt(model.focus()->row(), model.focus()->column())
                     .value(QStringLiteral("mediaId")).toString(),
                 QStringLiteral("root/Dune"));

        QSignalSpy focusChanged(model.focus(), &FocusNavigator::focusChanged);
        model.applyWatchProgress(QStringLiteral("root/Dune"), 600'000, 7'200'000, false);

        QCOMPARE(model.data(model.index(0), HomeRowsModel::RowIdRole).toString(),
                 QStringLiteral("continue-watching"));
        QCOMPARE(model.focus()->row(), model.rowCount() - 1);
        QCOMPARE(model.focus()->column(), 2);
        const QVariantMap focused = model.cardAt(model.focus()->row(), model.focus()->column());
        QCOMPARE(focused.value(QStringLiteral("mediaId")).toString(), QStringLiteral("root/Dune"));
        // One announcement, with the remote already on its card.
        QCOMPARE(focusChanged.count(), 1);

        // The same holds when the row goes again, and when the card moves
        // within its row.
        model.applyWatchProgress(QStringLiteral("root/Dune"), 0, 7'200'000, false);
        QCOMPARE(model.cardAt(model.focus()->row(), model.focus()->column())
                     .value(QStringLiteral("mediaId")).toString(),
                 QStringLiteral("root/Dune"));
    }

    // When the row the remote rested on is gone there is no card to follow.
    // The oracle's repair (HomeFocusContentPolicy.repair) goes to the first
    // card of the first row that has one, and so does the model.
    void theRemoteMovesToTheFirstCardWhenItsRowDisappears()
    {
        HomeRowsModel model;
        model.setClockForTest([] { return kNow; });
        model.replaceItems({movie(QStringLiteral("Arrival"), 2016), movie(QStringLiteral("Coco"), 2017),
                            movie(QStringLiteral("Dune"), 2021)});
        model.applyWatchProgress(QStringLiteral("root/Coco"), 0, 7'200'000, true);
        model.applyWatchProgress(QStringLiteral("root/Arrival"), 600'000, 7'200'000, false);
        QCOMPARE(model.data(model.index(0), HomeRowsModel::RowIdRole).toString(),
                 QStringLiteral("continue-watching"));
        QCOMPARE(model.data(model.index(1), HomeRowsModel::RowIdRole).toString(),
                 QStringLiteral("recently-watched"));
        model.focus()->setPosition(1, 0);

        // Un-watching Coco empties Recently Watched. The remote is not handed
        // to whatever row slid into its number; it goes to the first card.
        model.applyWatchProgress(QStringLiteral("root/Coco"), 0, 7'200'000, false);

        QCOMPARE(model.data(model.index(1), HomeRowsModel::RowIdRole).toString(),
                 QStringLiteral("play-something"));
        QCOMPARE(model.focus()->row(), 0);
        QCOMPARE(model.focus()->column(), 0);
        QCOMPARE(model.cardAt(0, 0).value(QStringLiteral("mediaId")).toString(),
                 QStringLiteral("root/Arrival"));

        // Nothing left: no card to address.
        model.replaceItems({});
        QVERIFY(model.focus()->empty());
        QCOMPARE(model.rowCount(), 0);
    }

    // The repair announces one focus change, and the columns the remote
    // remembers for the other rows survive it (HomeDetailView.swift:1128-1134
    // touches only the focused target).
    void theRepairAnnouncesOneChangeAndKeepsTheRememberedColumns()
    {
        HomeRowsModel model;
        model.setClockForTest([] { return kNow; });
        model.replaceItems({movie(QStringLiteral("Arrival"), 2016), movie(QStringLiteral("Coco"), 2017),
                            movie(QStringLiteral("Dune"), 2021)});
        model.applyWatchProgress(QStringLiteral("root/Coco"), 0, 7'200'000, true);
        model.applyWatchProgress(QStringLiteral("root/Arrival"), 600'000, 7'200'000, false);
        QCOMPARE(model.data(model.index(1), HomeRowsModel::RowIdRole).toString(),
                 QStringLiteral("recently-watched"));
        model.focus()->setPosition(2, 1);
        model.focus()->setPosition(1, 0);

        QSignalSpy focusChanged(model.focus(), &FocusNavigator::focusChanged);
        model.applyWatchProgress(QStringLiteral("root/Coco"), 0, 7'200'000, false);

        QCOMPARE(model.focus()->row(), 0);
        QCOMPARE(model.focus()->column(), 0);
        QCOMPARE(focusChanged.count(), 1);
        QVERIFY(model.moveDown());
        QVERIFY(model.moveDown());
        QCOMPARE(model.focus()->row(), 2);
        QCOMPARE(model.focus()->column(), 1);
    }

    // A profile choice rebuilds Home at the top (ContentView.swift:391-407):
    // off the capsule, on the first card, with no column kept for any row.
    void resetFocusReturnsTheRemoteToTheFirstCard()
    {
        HomeRowsModel model;
        model.setClockForTest([] { return kNow; });
        model.replaceItems({movie(QStringLiteral("Arrival"), 2016), movie(QStringLiteral("Coco"), 2017),
                            movie(QStringLiteral("Dune"), 2021), movie(QStringLiteral("Tenet"), 2020)});
        QVERIFY(model.rowCount() >= 2);

        // On the capsule: Up from the first row reaches it.
        QVERIFY(model.moveUp());
        QVERIFY(model.playSomethingFocused());
        model.resetFocus();
        QVERIFY(!model.playSomethingFocused());
        QCOMPARE(model.focus()->row(), 0);
        QCOMPARE(model.focus()->column(), 0);

        // Deep in the rows, with a remembered column on the row left behind.
        model.focus()->setPosition(model.rowCount() - 1, 2);
        model.focus()->setPosition(1, 3);
        model.resetFocus();
        QCOMPARE(model.focus()->row(), 0);
        QCOMPARE(model.focus()->column(), 0);
        QVERIFY(model.moveDown());
        QCOMPARE(model.focus()->column(), 0);

        // Empty Home: nothing to address, and no capsule to rest on.
        model.replaceItems({});
        model.resetFocus();
        QVERIFY(!model.playSomethingFocused());
    }

    // BrowseSnapshotStore.swift:369-385 and HomeDetailView.swift:668: the row
    // holds up to twelve candidates, Home draws eight of them, and the row
    // counts twelve. Episodes never appear (docs/ARCHITECTURE_V3.md).
    void thePlaySomethingRowHoldsTwelveUnwatchedMoviesAndDrawsEight()
    {
        QVector<MediaItem> items;
        for (int index = 0; index < 15; ++index) {
            items.push_back(movie(QStringLiteral("Film %1").arg(index, 2, 10, QLatin1Char('0')),
                                  1950 + index * 10));
        }
        MediaItem seen = movie(QStringLiteral("Seen"), 1990);
        watched(seen, daysAgo(2));
        items.push_back(seen);
        items.push_back(episode(QStringLiteral("Bluey"), 1, 1));

        const QVector<home_rows::Card> cards = home_rows::playSomethingCards(items);
        QCOMPARE(cards.size(), 12);
        for (const home_rows::Card &card : cards) {
            QVERIFY(!card.isEpisode());
            QVERIFY(card.mediaId != seen.id);
        }

        const QVector<home_rows::Row> composed = home_rows::compose(items, kNow);
        const home_rows::Row *row = rowNamed(composed, QStringLiteral("play-something"));
        QVERIFY(row != nullptr);
        QCOMPARE(row->cards.size(), home_rows::kCardsPerRow);
        QCOMPARE(row->totalCount, 12);
        QCOMPARE(ids(row->cards), ids(cards).mid(0, home_rows::kCardsPerRow));
    }

    void thePlaySomethingRowIsOmittedWhenNothingIsLeftToPlay()
    {
        MediaItem seen = movie(QStringLiteral("Seen"), 1999);
        watched(seen, daysAgo(2));
        const QVector<home_rows::Row> allSeen = home_rows::compose({seen}, kNow);
        QVERIFY(rowNamed(allSeen, QStringLiteral("play-something")) == nullptr);
        // A library of shows alone has no Play Something row either.
        const QVector<home_rows::Row> showsOnly =
            home_rows::compose({episode(QStringLiteral("Bluey"), 1, 1)}, kNow);
        QVERIFY(rowNamed(showsOnly, QStringLiteral("play-something")) == nullptr);
    }

    // Enter on the capsule plays a title at once (AppState.swift:235-245); the
    // model only chooses, from a salt a test can fix.
    void aPressDrawsAFreshSaltAndChoosesAnUnwatchedMovie()
    {
        HomeRowsModel model;
        QVector<MediaItem> items;
        for (int index = 0; index < 10; ++index) {
            items.push_back(movie(QStringLiteral("Film %1").arg(index), 2000 + index));
        }
        MediaItem seen = movie(QStringLiteral("Seen"), 2011);
        watched(seen, daysAgo(2));
        items.push_back(seen);
        model.replaceItems(items);

        QVERIFY(model.playSomethingPick().startsWith(QStringLiteral("root/Film")));

        int press = 0;
        model.setPlaySomethingSaltForTest([&press] { return QStringLiteral("p%1").arg(press++); });
        QSet<QString> picked;
        for (int index = 0; index < 80; ++index) {
            const QString id = model.playSomethingPick();
            QVERIFY(id != seen.id);
            QVERIFY(!id.isEmpty());
            picked.insert(id);
        }
        QCOMPARE(press, 80);
        QVERIFY(picked.size() > 5);

        // The same salt gives the same title.
        model.setPlaySomethingSaltForTest([] { return QStringLiteral("fixed"); });
        QCOMPARE(model.playSomethingPick(), model.playSomethingPick());

        // Nothing unwatched: an empty id, so the press does nothing.
        model.replaceItems({seen});
        QVERIFY(model.playSomethingPick().isEmpty());
        model.replaceItems({});
        QVERIFY(model.playSomethingPick().isEmpty());
    }

    // HomeDetailView.swift:46-77, :992-1008: the capsule is the first stop of
    // the vertical tree. Up from the first row reaches it, Down returns to the
    // card the remote left, and Left and Right are spent without moving.
    void theCapsuleIsReachedWithUpAndLeftBackWithDown()
    {
        HomeRowsModel model;
        model.replaceItems({movie(QStringLiteral("Arrival"), 2016), movie(QStringLiteral("Coco"), 2017),
                            movie(QStringLiteral("Dune"), 2021)});
        QVERIFY(!model.playSomethingFocused());
        QVERIFY(model.moveRight());
        QCOMPARE(model.focus()->column(), 1);

        QSignalSpy changed(&model, &HomeRowsModel::playSomethingFocusedChanged);
        QVERIFY(model.moveUp());
        QVERIFY(model.playSomethingFocused());
        QCOMPARE(changed.count(), 1);
        // Held still: Up, Left and Right do not leave the capsule or move a card.
        QVERIFY(model.moveUp());
        QVERIFY(model.moveLeft());
        QVERIFY(model.moveRight());
        QVERIFY(model.playSomethingFocused());
        QCOMPARE(model.focus()->row(), 0);
        QCOMPARE(model.focus()->column(), 1);
        QCOMPARE(changed.count(), 1);

        QVERIFY(model.moveDown());
        QVERIFY(!model.playSomethingFocused());
        QCOMPARE(model.focus()->row(), 0);
        QCOMPARE(model.focus()->column(), 1);
        QCOMPARE(changed.count(), 2);

        // A pointer that touches a card takes the remote off the capsule.
        QVERIFY(model.moveUp());
        model.focusCard(1, 2);
        QVERIFY(!model.playSomethingFocused());
        QCOMPARE(model.focus()->row(), 1);
        QCOMPARE(model.focus()->column(), 2);

        // Left at a first card is not spent, so the shell can reach the sidebar.
        model.focusCard(0, 0);
        QVERIFY(!model.moveLeft());
    }

    // The title bar, and the capsule in it, is hidden while the library holds
    // nothing: Up is spent but the remote must not rest on a control nobody
    // can see.
    void theCapsuleIsNotFocusedWhileTheLibraryIsEmpty()
    {
        HomeRowsModel model;
        model.replaceItems({});
        QVERIFY(model.moveUp());
        QVERIFY(!model.playSomethingFocused());

        // A library that empties under the capsule takes the focus off it.
        model.replaceItems({movie(QStringLiteral("Arrival"), 2016)});
        QVERIFY(model.moveUp());
        QVERIFY(model.playSomethingFocused());
        model.replaceItems({});
        QVERIFY(!model.playSomethingFocused());
    }

    void candidatesAreTheSaltedOrderAndThePickIsTheFirst()
    {
        HomeRowsModel model;
        QVector<MediaItem> items;
        for (int index = 0; index < 6; ++index) {
            items.push_back(movie(QStringLiteral("Film %1").arg(index), 2000 + index));
        }
        MediaItem seen = movie(QStringLiteral("Seen"), 2011);
        watched(seen, daysAgo(2));
        items.push_back(seen);
        model.replaceItems(items);
        model.setPlaySomethingSaltForTest([] { return QStringLiteral("fixed"); });

        const QStringList order = model.playSomethingCandidates();
        QCOMPARE(order.size(), 6);
        QVERIFY(!order.contains(seen.id));
        QCOMPARE(model.playSomethingPick(), order.constFirst());

        model.replaceItems({seen});
        QVERIFY(model.playSomethingCandidates().isEmpty());
    }

    void theRemoteIsClampedWhenARecompositionShortensTheRows()
    {
        HomeRowsModel model;
        QVector<MediaItem> items;
        for (int index = 0; index < 5; ++index) {
            items.push_back(movie(QStringLiteral("Film %1").arg(index), 2000 + index));
        }
        model.replaceItems(items);
        model.focus()->setPosition(1, 4);
        QCOMPARE(model.focus()->row(), 1);
        QCOMPARE(model.focus()->column(), 4);

        model.replaceItems({movie(QStringLiteral("Film 0"), 2000)});
        QVERIFY(model.focus()->row() <= 1);
        QCOMPARE(model.focus()->column(), 0);

        model.replaceItems({});
        QVERIFY(model.focus()->empty());
        QCOMPARE(model.rowCount(), 0);
    }

    // The catalog side: progress is read per profile with the time it was
    // recorded, so Home's rows can differ between two viewers of one library.
    void twoProfilesOfOneLibraryGetTheirOwnRows()
    {
        QTemporaryDir runtimeRoot;
        QTemporaryDir library;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
        QVERIFY(writeFile(library.path() + QStringLiteral("/Arrival (2016).mkv")));
        QVERIFY(writeFile(library.path() + QStringLiteral("/Coco (2017).mkv")));

        AppPaths::ensureDirectories();
        CatalogDatabase catalog(AppPaths::catalogFile());
        catalog.migrate();
        CatalogStore store(AppPaths::catalogFile());
        const QVector<LibraryRoot> roots = store.registerRoots({library.path()});
        for (const LibraryRoot &root : roots) {
            store.applyScan(root, LibraryScanner::scan(root));
        }
        const QString arrival = catalogIdOf(store.projection(roots, QStringLiteral("a")),
                                            QStringLiteral("Arrival"));
        const QString coco = catalogIdOf(store.projection(roots, QStringLiteral("a")),
                                         QStringLiteral("Coco"));
        store.recordWatchProgress(QStringLiteral("a"), arrival, 600'000, 7'200'000, false);
        store.recordWatchProgress(QStringLiteral("b"), coco, 0, 6'000'000, true);

        const QDateTime now = QDateTime::currentDateTimeUtc();
        const QVector<home_rows::Row> forA =
            home_rows::compose(store.projection(roots, QStringLiteral("a")), now);
        const QVector<home_rows::Row> forB =
            home_rows::compose(store.projection(roots, QStringLiteral("b")), now);
        const QVector<home_rows::Row> forC =
            home_rows::compose(store.projection(roots, QStringLiteral("c")), now);

        QCOMPARE(ids(rowNamed(forA, QStringLiteral("continue-watching"))->cards),
                 QStringList{arrival});
        QVERIFY(rowNamed(forA, QStringLiteral("recently-watched")) == nullptr);
        QVERIFY(rowNamed(forB, QStringLiteral("continue-watching")) == nullptr);
        QCOMPARE(ids(rowNamed(forB, QStringLiteral("recently-watched"))->cards),
                 QStringList{coco});
        // B has watched Coco, so it is not offered as new to B, and A has not.
        QCOMPARE(ids(rowNamed(forB, QStringLiteral("recently-added"))->cards),
                 QStringList{arrival});
        // Arrival is only part-way through for A, so it is still new to A.
        QCOMPARE(rowNamed(forA, QStringLiteral("recently-added"))->totalCount, 2);
        QCOMPARE(rowIds(forC), (QStringList{QStringLiteral("play-something"),
                                            QStringLiteral("recently-added"),
                                            QStringLiteral("decade-2010s"),
                                            QStringLiteral("all-movies")}));
        // Play Something counts each profile's own watch state: Arrival is
        // only part-way through for A, so it is still offered; Coco is
        // finished for B alone.
        QCOMPARE(rowNamed(forA, QStringLiteral("play-something"))->totalCount, 2);
        QCOMPARE(ids(rowNamed(forB, QStringLiteral("play-something"))->cards),
                 QStringList{arrival});
        QCOMPARE(rowNamed(forC, QStringLiteral("play-something"))->totalCount, 2);
        QCOMPARE(rowNamed(forC, QStringLiteral("recently-added"))->totalCount, 2);
    }

    void aYearOldViewingLeavesTheRowButTheCatalogStillResumesIt()
    {
        QTemporaryDir runtimeRoot;
        QTemporaryDir library;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
        QVERIFY(writeFile(library.path() + QStringLiteral("/Arrival (2016).mkv")));

        AppPaths::ensureDirectories();
        CatalogDatabase catalog(AppPaths::catalogFile());
        catalog.migrate();
        CatalogStore store(AppPaths::catalogFile());
        const QVector<LibraryRoot> roots = store.registerRoots({library.path()});
        for (const LibraryRoot &root : roots) {
            store.applyScan(root, LibraryScanner::scan(root));
        }
        const QString arrival = store.projection(roots, QStringLiteral("a")).constFirst().id;
        store.recordWatchProgress(QStringLiteral("a"), arrival, 600'000, 7'200'000, false);

        const QDateTime now = QDateTime::currentDateTimeUtc();
        QCOMPARE(ids(home_rows::continueWatching(store.projection(roots, QStringLiteral("a")), now)),
                 QStringList{arrival});

        QSqlQuery age(catalog.connection());
        QVERIFY(age.prepare(QStringLiteral("UPDATE watch_progress SET updated_at = ? "
                                           "WHERE profile_id = 'a'")));
        age.addBindValue(now.addDays(-400).toUTC().toString(Qt::ISODateWithMs));
        QVERIFY(age.exec());

        const QVector<MediaItem> projected = store.projection(roots, QStringLiteral("a"));
        QVERIFY(home_rows::continueWatching(projected, now).isEmpty());
        QCOMPARE(projected.constFirst().resumePositionMs, qint64{600'000});
        QVERIFY(projected.constFirst().hasProgress());
        QVERIFY(projected.constFirst().lastPlayedAt.isValid());
    }
};

QTEST_MAIN(HomeRowsTest)
#include "tst_home_rows.moc"
