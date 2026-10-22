#include <QtTest>

#include <QLocale>
#include <QSet>

#include "catalog/MediaItem.hpp"
#include "models/PlaySomething.hpp"
#include "profiles/ContentPolicy.hpp"
#include "profiles/ProfileStore.hpp"

namespace
{
[[nodiscard]] MediaItem movie(const QString &title, const QString &folder = QString())
{
    MediaItem item;
    item.id = QStringLiteral("root/") + title;
    item.relativePath = (folder.isEmpty() ? QString() : folder + QLatin1Char('/')) + title
        + QStringLiteral(".mkv");
    item.title = title;
    item.mediaKind = QStringLiteral("movie");
    item.year = 2000;
    return item;
}

[[nodiscard]] MediaItem episode(const QString &show, int number)
{
    MediaItem item;
    item.id = QStringLiteral("root/%1/E%2").arg(show).arg(number);
    item.relativePath = item.id + QStringLiteral(".mkv");
    item.title = show;
    item.mediaKind = QStringLiteral("episode");
    item.showName = show;
    item.seasonNumber = 1;
    item.episodeNumber = number;
    return item;
}

[[nodiscard]] QStringList ids(const QVector<MediaItem> &items)
{
    QStringList result;
    for (const MediaItem &item : items) {
        result.push_back(item.id);
    }
    return result;
}

[[nodiscard]] QString saltNumber(int n)
{
    return QStringLiteral("press-%1").arg(n);
}
}

class PlaySomethingTest final : public QObject
{
    Q_OBJECT

private slots:
    // The family collator is built from the default locale on first use. A
    // process with no LANG would collate by code point, so pin the locale the
    // collation cases are written for before any of them runs.
    void initTestCase()
    {
        QLocale::setDefault(QLocale(QLocale::English, QLocale::UnitedStates));
    }

    void onlyUnwatchedMoviesAreEligible()
    {
        MediaItem seen = movie(QStringLiteral("Seen"));
        seen.watched = true;
        seen.lastPlayedAt = QDateTime::currentDateTimeUtc();
        // Part-way is not watched: the oracle offers it (`!item.isWatched`).
        MediaItem partway = movie(QStringLiteral("Partway"));
        partway.resumePositionMs = 90'000;
        const QVector<MediaItem> items{seen,
                                       partway,
                                       movie(QStringLiteral("Fresh")),
                                       episode(QStringLiteral("Bluey"), 1),
                                       episode(QStringLiteral("Bluey"), 2)};

        QStringList eligible = ids(play_something::candidates(items, saltNumber(1)));
        eligible.sort();

        // No episode is ever eligible (docs/ARCHITECTURE_V3.md: movie-only).
        QCOMPARE(eligible, (QStringList{QStringLiteral("root/Fresh"), QStringLiteral("root/Partway")}));
        for (int press = 0; press < 50; ++press) {
            const auto pick = play_something::pick(items, saltNumber(press));
            QVERIFY(pick.has_value());
            QVERIFY(pick->isMovie());
            QVERIFY(!pick->watched);
        }
    }

    void aPressNeverRepeatsATitleWithinOneShuffle()
    {
        QVector<MediaItem> items;
        for (int index = 0; index < 30; ++index) {
            items.push_back(movie(QStringLiteral("Film %1").arg(index)));
        }
        // A title listed twice is still one candidate.
        items.push_back(items.first());

        const QVector<MediaItem> ordered = play_something::candidates(items, saltNumber(7));

        const QStringList orderedIds = ids(ordered);
        QCOMPARE(ordered.size(), 30);
        QCOMPARE(QSet<QString>(orderedIds.cbegin(), orderedIds.cend()).size(), 30);
    }

    void theSameSaltShufflesTheSameWayAndAnotherSaltDoesNot()
    {
        QVector<MediaItem> items;
        for (int index = 0; index < 12; ++index) {
            items.push_back(movie(QStringLiteral("Film %1").arg(index)));
        }

        QCOMPARE(ids(play_something::candidates(items, QStringLiteral("a"))),
                 ids(play_something::candidates(items, QStringLiteral("a"))));
        QVERIFY(ids(play_something::candidates(items, QStringLiteral("a")))
                != ids(play_something::candidates(items, QStringLiteral("b"))));

        // Presses draw fresh salts, so the picks spread over the library
        // rather than settling on one favourite.
        QSet<QString> picked;
        for (int press = 0; press < 200; ++press) {
            picked.insert(play_something::pick(items, saltNumber(press))->id);
        }
        QCOMPARE(picked.size(), 12);
    }

    void aPosterTitleIsFavouredButNeverAlone()
    {
        MediaItem posted = movie(QStringLiteral("Posted"));
        posted.posterAbsolutePath = QStringLiteral("/tmp/poster.jpg");
        const QVector<MediaItem> items{posted, movie(QStringLiteral("Plain"))};

        int postedWins = 0;
        for (int press = 0; press < 400; ++press) {
            postedWins += play_something::pick(items, saltNumber(press))->id == posted.id ? 1 : 0;
        }

        QVERIFY2(postedWins > 200, qPrintable(QString::number(postedWins)));
        QVERIFY2(postedWins < 400, qPrintable(QString::number(postedWins)));
    }

    void anEmptyOrExhaustedLibraryPicksNothing()
    {
        QVERIFY(!play_something::pick({}, saltNumber(1)).has_value());
        QVERIFY(play_something::candidates({}, saltNumber(1)).isEmpty());

        MediaItem seen = movie(QStringLiteral("Seen"));
        seen.watched = true;
        QVERIFY(!play_something::pick({seen}, saltNumber(1)).has_value());
        // A library of shows alone has nothing to play either.
        QVERIFY(!play_something::pick({episode(QStringLiteral("Bluey"), 1)}, saltNumber(1))
                     .has_value());
    }

    void aLibraryOfOneUnwatchedMoviePicksItEveryPress()
    {
        MediaItem seen = movie(QStringLiteral("Seen"));
        seen.watched = true;
        const QVector<MediaItem> items{seen, movie(QStringLiteral("Only"))};

        for (int press = 0; press < 20; ++press) {
            QCOMPARE(play_something::pick(items, saltNumber(press))->id, QStringLiteral("root/Only"));
        }
    }

    void aKidsProfileIsOnlyOfferedWhatItsPolicyAllows()
    {
        const QVector<MediaItem> library{movie(QStringLiteral("Wonder"), QStringLiteral("Kids")),
                                         movie(QStringLiteral("WALL-E"), QStringLiteral("Family")),
                                         movie(QStringLiteral("Heat"), QStringLiteral("Drama")),
                                         movie(QStringLiteral("Casino"), QStringLiteral("Drama")),
                                         movie(QStringLiteral("Unsorted"))};

        // The caller hands in the profile's projection, as
        // `ApplicationController::publishProjection` does.
        const QVector<MediaItem> visible = content_policy::filtered(
            static_cast<int>(ProfileStore::Maturity::Kids), library);
        QVERIFY(!visible.isEmpty());
        QVERIFY(visible.size() < library.size());

        QSet<QString> picked;
        for (int press = 0; press < 200; ++press) {
            picked.insert(play_something::pick(visible, saltNumber(press))->id);
        }
        QVERIFY(!picked.contains(QStringLiteral("root/Heat")));
        QVERIFY(!picked.contains(QStringLiteral("root/Casino")));
        QVERIFY(!picked.contains(QStringLiteral("root/Unsorted")));
        QVERIFY(picked.contains(QStringLiteral("root/Wonder")));
        QVERIFY(picked.contains(QStringLiteral("root/WALL-E")));
    }

    void watchStateIsTheStateTheProjectionCarries()
    {
        // Two profiles over one library differ only in the flags the catalog
        // joined for each; the pick follows them.
        MediaItem a = movie(QStringLiteral("A"));
        MediaItem b = movie(QStringLiteral("B"));
        MediaItem aSeen = a;
        aSeen.watched = true;

        QCOMPARE(ids(play_something::candidates({aSeen, b}, saltNumber(1))),
                 (QStringList{QStringLiteral("root/B")}));
        QCOMPARE(play_something::candidates({a, b}, saltNumber(1)).size(), 2);
    }

    // Equal keys fall to compareMoviesForBrowsing (BrowseSnapshotStore.swift:
    // 2034-2042): family, then year with unknown last, then title. The two ids
    // below hash to the same key under the salt "tie" (FNV-1a of "id|tie",
    // modulo a million), so only the tie-break orders them.
    void equalKeysBreakByBrowseOrderNotByTitle()
    {
        MediaItem early = movie(QStringLiteral("Star Wars Zeta"));
        early.id = QStringLiteral("root/Zeta24");
        early.year = 1977;
        MediaItem late = movie(QStringLiteral("Star Wars Alpha"));
        late.id = QStringLiteral("root/Alpha839");
        late.year = 2002;
        MediaItem undated = movie(QStringLiteral("Star Wars Alpha"));
        undated.id = QStringLiteral("root/Alpha839");
        undated.year = 0;

        const QStringList expected{early.id, late.id};
        QCOMPARE(ids(play_something::candidates({early, late}, QStringLiteral("tie"))), expected);
        QCOMPARE(ids(play_something::candidates({late, early}, QStringLiteral("tie"))), expected);
        // An unknown year sorts last.
        QCOMPARE(ids(play_something::candidates({undated, early}, QStringLiteral("tie"))), expected);
    }

    // The family compare uses the collator the Movies page uses, not code
    // point order, which would put "zebra" before "aeon" spelled with an
    // ash. The ids hash to the same key under the salt "tie".
    void equalKeysCompareFamiliesWithTheLocaleCollator()
    {
        MediaItem ash = movie(QStringLiteral("\u00C6on Flux"));
        ash.id = QStringLiteral("x1181");
        MediaItem zebra = movie(QStringLiteral("Zebra"));
        zebra.id = QStringLiteral("x10");

        const QStringList expected{ash.id, zebra.id};
        QCOMPARE(ids(play_something::candidates({zebra, ash}, QStringLiteral("tie"))), expected);
        QCOMPARE(ids(play_something::candidates({ash, zebra}, QStringLiteral("tie"))), expected);
    }
};

QTEST_APPLESS_MAIN(PlaySomethingTest)

#include "tst_play_something.moc"
