#include <QtTest>

#include <QLocale>
#include <QSignalSpy>

#include "catalog/MediaItem.hpp"
#include "models/LibraryModel.hpp"
#include "search/SearchSession.hpp"

namespace
{
MediaItem item(const QString &id, const QString &title, int year, const QString &fileName)
{
    MediaItem entry;
    entry.id = id;
    entry.title = title;
    entry.year = year;
    entry.relativePath = QStringLiteral("Movies/") + fileName;
    entry.absolutePath = QStringLiteral("/library/") + entry.relativePath;
    entry.mediaKind = QStringLiteral("movie");
    return entry;
}

QVector<MediaItem> sampleLibrary()
{
    return {
        item(QStringLiteral("alien"), QStringLiteral("Alien"), 1979, QStringLiteral("Alien.1979.mkv")),
        item(QStringLiteral("aliens"), QStringLiteral("Aliens"), 1986, QStringLiteral("Aliens.1986.mkv")),
        item(QStringLiteral("alien3"), QStringLiteral("Alien³"), 1992, QStringLiteral("Alien3.1992.mkv")),
        item(QStringLiteral("heat"), QStringLiteral("Heat"), 1995, QStringLiteral("Heat.1995.mp4")),
        item(QStringLiteral("blade"), QStringLiteral("Blade Runner"), 1982,
             QStringLiteral("Blade.Runner.Final.Cut.1982.mkv")),
        item(QStringLiteral("cut"), QStringLiteral("The Final Cut"), 2004,
             QStringLiteral("The.Final.Cut.2004.mkv")),
        item(QStringLiteral("amelie"), QStringLiteral("Amélie"), 2001,
             QStringLiteral("Amelie.2001.mkv")),
        item(QStringLiteral("aa"), QStringLiteral("Astronaut Adventures"), 2010,
             QStringLiteral("Astronaut.Adventures.2010.mkv")),
    };
}

QStringList idsOf(const SearchSession &session)
{
    QStringList ids;
    for (int row = 0; row < session.rowCount(); ++row) {
        ids.push_back(session.data(session.index(row), SearchSession::MediaIdRole).toString());
    }
    return ids;
}
}

class TestSearchSession : public QObject
{
    Q_OBJECT

private slots:
    // The localized collator is built from the default locale on first use. A
    // process with no LANG would collate by code point, so pin the locale the
    // ordering cases are written for before any of them runs.
    void initTestCase()
    {
        QLocale::setDefault(QLocale(QLocale::English, QLocale::UnitedStates));
    }

    void normalisesLikeTheReleasedIndex()
    {
        // BrowseSnapshotStore.swift:1784-1802: folded, lowercased, one space
        // per non-alphanumeric run, trimmed.
        QCOMPARE(SearchSession::normalizedText(QStringLiteral("  Amélie — Le Fabuleux!! ")),
                 QStringLiteral("amelie le fabuleux"));
        // A superscript digit is a Unicode number, which CharacterSet.alphanumerics
        // keeps, and :1786's folding leaves it as it is.
        QCOMPARE(SearchSession::normalizedText(QStringLiteral("Alien³")), QStringLiteral("alien³"));
        QCOMPARE(SearchSession::normalizedText(QString()), QString());
    }

    void emptyQueryHasNoResultsAndNoSuggestions()
    {
        LibraryModel library;
        library.replaceItems(sampleLibrary());
        SearchSession session(&library);

        QCOMPARE(session.rowCount(), 0);
        QCOMPARE(session.totalCount(), 0);
        QVERIFY(session.suggestions().isEmpty());

        session.setQuery(QStringLiteral("   "));
        QCOMPARE(session.trimmedQuery(), QString());
        QCOMPARE(session.rowCount(), 0);
    }

    void exactTitleOutranksPrefixAndSubstring()
    {
        LibraryModel library;
        library.replaceItems(sampleLibrary());
        SearchSession session(&library);

        session.setQuery(QStringLiteral("alien"));

        // :1878 exact = 1020; :1902 token prefix = 972 for "Aliens" and
        // "Alien³"; that tie breaks by browse order, :2034-2042, whose
        // families here are the whole titles compared with localized
        // collation, where the superscript three sorts as a digit before "s".
        QCOMPARE(idsOf(session),
                 (QStringList{QStringLiteral("alien"), QStringLiteral("alien3"),
                              QStringLiteral("aliens")}));
        QCOMPARE(session.totalCount(), 3);
        for (int row = 0; row < session.rowCount(); ++row) {
            QCOMPARE(session.data(session.index(row), SearchSession::MatchTypeRole).toInt(),
                     static_cast<int>(SearchSession::Title));
            QCOMPARE(session.data(session.index(row), SearchSession::MatchDetailRole).toString(),
                     QString());
        }
    }

    void singleCharacterSearchesTitlePrefixesOnly()
    {
        LibraryModel library;
        library.replaceItems(sampleLibrary());
        SearchSession session(&library);

        session.setQuery(QStringLiteral("a"));

        // :993-995 narrows a one-character query to titles, without the
        // substring rung, so "Blade Runner" (which contains an "a") is out
        // while every title with a token starting in "a" is in.
        const QStringList ids = idsOf(session);
        QVERIFY(ids.contains(QStringLiteral("alien")));
        QVERIFY(ids.contains(QStringLiteral("amelie")));
        QVERIFY(ids.contains(QStringLiteral("aa")));
        QVERIFY(!ids.contains(QStringLiteral("blade")));
        QVERIFY(!ids.contains(QStringLiteral("heat")));
    }

    void diacriticsFoldOnBothSides()
    {
        LibraryModel library;
        library.replaceItems(sampleLibrary());
        SearchSession session(&library);

        session.setQuery(QStringLiteral("amelie"));
        QCOMPARE(idsOf(session), QStringList{QStringLiteral("amelie")});

        session.setQuery(QStringLiteral("Amélie"));
        QCOMPARE(idsOf(session), QStringList{QStringLiteral("amelie")});
    }

    void fileNameMatchReportsItselfBelowTitleMatches()
    {
        LibraryModel library;
        library.replaceItems(sampleLibrary());
        SearchSession session(&library);

        session.setQuery(QStringLiteral("final cut"));

        // "The Final Cut" matches its title (:1897-1899, 988); "Blade Runner"
        // only through its file name (:1424-1436, base 320).
        QCOMPARE(idsOf(session), (QStringList{QStringLiteral("cut"), QStringLiteral("blade")}));
        QCOMPARE(session.data(session.index(1), SearchSession::MatchTypeRole).toInt(),
                 static_cast<int>(SearchSession::FileName));
        QCOMPARE(session.data(session.index(1), SearchSession::MatchDetailRole).toString(),
                 QStringLiteral("File name match"));
    }

    void fuzzyPassRunsOnlyWhenTheExactPassIsEmpty()
    {
        LibraryModel library;
        library.replaceItems(sampleLibrary());
        SearchSession session(&library);

        // :1005 keeps the exact pass when it found anything.
        session.setQuery(QStringLiteral("heat"));
        QCOMPARE(idsOf(session), QStringList{QStringLiteral("heat")});

        // :1007-1014: one edit away and at least four characters, :1917-1921.
        session.setQuery(QStringLiteral("heaf"));
        QCOMPARE(idsOf(session), QStringList{QStringLiteral("heat")});

        // Three characters never fuzz, :1919.
        session.setQuery(QStringLiteral("hex"));
        QCOMPARE(session.rowCount(), 0);
    }

    void scopedQueriesFindNothingWithoutEnrichedMetadata()
    {
        LibraryModel library;
        library.replaceItems(sampleLibrary());
        SearchSession session(&library);

        session.setQuery(QStringLiteral("director:Scott"));
        QCOMPARE(session.rowCount(), 0);
        session.setQuery(QStringLiteral("GENRE: horror"));
        QCOMPARE(session.rowCount(), 0);
    }

    void suggestionsNeedTwoCharactersAndCapAtEight()
    {
        QVector<MediaItem> items = sampleLibrary();
        for (int i = 0; i < 10; ++i) {
            items.push_back(item(QStringLiteral("z%1").arg(i),
                                 QStringLiteral("Zebra Crossing %1").arg(i), 2000 + i,
                                 QStringLiteral("Zebra.%1.mkv").arg(i)));
        }
        LibraryModel library;
        library.replaceItems(items);
        SearchSession session(&library);

        session.setQuery(QStringLiteral("a"));
        QVERIFY(session.suggestions().isEmpty());

        // :964-980 offers indexed values containing the query anywhere
        // ("The Final Cut" carries it too), in localized case-insensitive
        // order (:1770-1772), eight at most.
        session.setQuery(QStringLiteral("al"));
        QCOMPARE(session.suggestions(),
                 (QStringList{QStringLiteral("Alien"), QStringLiteral("Alien³"),
                              QStringLiteral("Aliens"), QStringLiteral("The Final Cut")}));

        session.setQuery(QStringLiteral("zebra"));
        QCOMPARE(session.suggestions().size(), 8);
        QCOMPARE(session.suggestions().first(), QStringLiteral("Zebra Crossing 0"));
    }

    void subtitleJoinsYearAndRuntimeWithAMiddleDot()
    {
        QVector<MediaItem> items = sampleLibrary();
        items[0].durationSeconds = 117 * 60 + 30;
        LibraryModel library;
        library.replaceItems(items);
        SearchSession session(&library);

        session.setQuery(QStringLiteral("alien"));
        QCOMPARE(session.data(session.index(0), SearchSession::SubtitleRole).toString(),
                 QStringLiteral("1979 \u00B7 1h 57m"));
        QCOMPARE(session.data(session.index(0), SearchSession::FormatBadgeRole).toString(),
                 QStringLiteral("MKV"));
        QCOMPARE(session.mediaIdAt(0), QStringLiteral("alien"));
        QCOMPARE(session.mediaIdAt(99), QString());
    }

    void libraryReplacementReevaluatesTheCurrentQuery()
    {
        LibraryModel library;
        SearchSession session(&library);
        QSignalSpy results(&session, &SearchSession::resultsChanged);

        session.setQuery(QStringLiteral("heat"));
        QCOMPARE(session.rowCount(), 0);
        const quint64 before = session.generation();

        library.replaceItems(sampleLibrary());
        QCOMPARE(idsOf(session), QStringList{QStringLiteral("heat")});
        QVERIFY(session.generation() > before);
        QVERIFY(results.count() >= 2);
    }
};

QTEST_GUILESS_MAIN(TestSearchSession)
#include "tst_search_session.moc"
