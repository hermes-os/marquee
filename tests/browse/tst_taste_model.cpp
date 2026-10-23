#include <QtTest>

#include <QLocale>

#include <memory>

#include "catalog/MediaItem.hpp"
#include "models/TasteModel.hpp"

namespace
{
const QDateTime kBase = QDateTime(QDate(2026, 1, 1), QTime(12, 0), QTimeZone::UTC);

[[nodiscard]] MediaItem movie(const QString &title,
                              int year,
                              const QStringList &genres = {},
                              int daysOld = 0)
{
    MediaItem item;
    item.id = QStringLiteral("root/") + title;
    item.relativePath = title + QStringLiteral(".mkv");
    item.title = title;
    item.mediaKind = QStringLiteral("movie");
    item.year = year;
    item.modifiedAt = kBase.addDays(-daysOld);
    auto metadata = std::make_shared<TitleMetadata>();
    metadata->tmdbId = 1;
    metadata->genres = genres;
    item.metadata = metadata;
    return item;
}

[[nodiscard]] TitleMetadata &editable(MediaItem &item)
{
    auto copy = std::make_shared<TitleMetadata>(*item.metadata);
    TitleMetadata &ref = *copy;
    item.metadata = std::move(copy);
    return ref;
}

[[nodiscard]] QVector<CastMember> castOf(const QStringList &names)
{
    QVector<CastMember> cast;
    for (const QString &name : names) {
        cast.push_back(CastMember{.name = name, .character = {}, .profilePath = {}, .personId = 1});
    }
    return cast;
}

[[nodiscard]] QStringList titlesOf(const QVector<MediaItem> &items)
{
    QStringList titles;
    for (const MediaItem &item : items) {
        titles.push_back(item.title);
    }
    return titles;
}
}

class TasteModelTest final : public QObject
{
    Q_OBJECT

private slots:
    void initTestCase()
    {
        QLocale::setDefault(QLocale(QLocale::English, QLocale::UnitedStates));
    }

    // :255-257: no finished title, no model.
    void nothingFinishedGivesNoModel()
    {
        QVERIFY(!browse::TasteModel::build({}).has_value());
        QVERIFY(!browse::TasteModel::build({movie(QStringLiteral("Aster"), 2001, {QStringLiteral("Drama")})})
                     .has_value());
        // A title with only part-way progress is not finished.
        MediaItem partway = movie(QStringLiteral("Aster"), 2001);
        partway.resumePositionMs = 90'000;
        QVERIFY(!browse::TasteModel::build({partway}).has_value());
    }

    // :267-280: 80 a genre, 90 the director, 75 down to 30 the first five
    // billed, 95 a keyword; the score reads every name of the candidate.
    void aFinishedTitleWeighsItsGenresDirectorCastAndKeywords()
    {
        MediaItem seen = movie(QStringLiteral("Aster"), 2001, {QStringLiteral("Drama"), QStringLiteral("Crime")});
        seen.watched = true;
        {
            TitleMetadata &metadata = editable(seen);
            metadata.director = QStringLiteral("Dana Fixture");
            metadata.cast = castOf({QStringLiteral("A One"), QStringLiteral("B Two"), QStringLiteral("C Three"),
                                    QStringLiteral("D Four"), QStringLiteral("E Five"), QStringLiteral("F Six")});
            metadata.keywords = {MetadataKeyword{.id = 7, .name = QStringLiteral("Heist")}};
        }
        const auto model = browse::TasteModel::build({seen});
        QVERIFY(model.has_value());

        MediaItem plain = movie(QStringLiteral("Bramble"), 2002, {QStringLiteral("Drama")});
        QCOMPARE(model->affinityScore(plain), 80.0);

        MediaItem rich = movie(QStringLiteral("Cedar"), 2003, {QStringLiteral("crime")});
        {
            TitleMetadata &metadata = editable(rich);
            metadata.director = QStringLiteral("DANA  fixture");
            // The fifth billed weighs 35; the sixth was never counted.
            metadata.cast = castOf({QStringLiteral("E Five"), QStringLiteral("F Six"),
                                    QStringLiteral("Nobody")});
            metadata.keywords = {MetadataKeyword{.id = 7, .name = QStringLiteral("heist")}};
        }
        QCOMPARE(model->affinityScore(rich), 80.0 + 90.0 + 35.0 + 95.0);
    }

    // :262-280: weights add up over the watch history, and an episode counts.
    void weightsAccumulateAcrossFinishedTitlesAndEpisodes()
    {
        MediaItem first = movie(QStringLiteral("Aster"), 2001, {QStringLiteral("Drama")});
        MediaItem second = movie(QStringLiteral("Bramble"), 2002, {QStringLiteral("Drama")});
        MediaItem episode;
        episode.id = QStringLiteral("root/Show/S1E1");
        episode.title = QStringLiteral("Show S1E1");
        episode.mediaKind = QStringLiteral("episode");
        episode.showName = QStringLiteral("Show");
        episode.seasonNumber = 1;
        episode.episodeNumber = 1;
        auto metadata = std::make_shared<TitleMetadata>();
        metadata->genres = {QStringLiteral("Drama")};
        episode.metadata = metadata;
        MediaItem third = movie(QStringLiteral("Dune"), 2004, {QStringLiteral("Drama")});
        first.watched = second.watched = third.watched = episode.watched = true;

        const auto model = browse::TasteModel::build({first, second, third, episode});
        QVERIFY(model.has_value());
        QCOMPARE(model->affinityScore(movie(QStringLiteral("Cedar"), 2003, {QStringLiteral("Drama")})), 320.0);
        // The ceiling a consumer mixes against (:245, :334-336).
        QCOMPARE(model->clampedAffinityScore(movie(QStringLiteral("Cedar"), 2003, {QStringLiteral("Drama")})),
                 browse::TasteModel::kAffinityCeiling);
    }

    // :288-294.
    void aFinishedTitleIsNotUnwatched()
    {
        MediaItem seen = movie(QStringLiteral("Aster"), 2001);
        seen.watched = true;
        MediaItem partway = movie(QStringLiteral("Bramble"), 2002);
        partway.resumePositionMs = 90'000;
        const MediaItem fresh = movie(QStringLiteral("Cedar"), 2003);
        const auto model = browse::TasteModel::build({seen, partway, fresh});
        QVERIFY(model.has_value());
        QVERIFY(model->isCompleted(seen));
        QVERIFY(!model->isUnwatched(seen));
        QVERIFY(model->isUnwatched(partway));
        QVERIFY(model->isUnwatched(fresh));
    }

    // :296-307: newest file first, browse order within one date, at most limit.
    void seedsAreTheNewestFinishedTitles()
    {
        MediaItem old = movie(QStringLiteral("Aster"), 2001, {}, 90);
        MediaItem newest = movie(QStringLiteral("Zinnia"), 2005, {}, 1);
        MediaItem sameDayB = movie(QStringLiteral("Bramble"), 2002, {}, 10);
        MediaItem sameDayA = movie(QStringLiteral("Acorn"), 2003, {}, 10);
        const MediaItem unseen = movie(QStringLiteral("Cedar"), 2004, {}, 0);
        old.watched = newest.watched = sameDayB.watched = sameDayA.watched = true;
        const QVector<MediaItem> all{old, sameDayB, unseen, newest, sameDayA};

        const auto model = browse::TasteModel::build(all);
        QVERIFY(model.has_value());
        QCOMPARE(titlesOf(model->completedSeeds(all, 3)),
                 (QStringList{QStringLiteral("Zinnia"), QStringLiteral("Acorn"), QStringLiteral("Bramble")}));
        QCOMPARE(model->completedSeeds(all, 10).size(), 4);
    }

    // :309-324: affinity, then vote average, then newest file, then browse order.
    void candidatesAreRankedByAffinityVoteDateThenBrowseOrder()
    {
        MediaItem seen = movie(QStringLiteral("Aster"), 2001, {QStringLiteral("Drama")});
        seen.watched = true;
        const auto model = browse::TasteModel::build({seen});
        QVERIFY(model.has_value());

        MediaItem liked = movie(QStringLiteral("Zeta"), 2010, {QStringLiteral("Drama")}, 50);
        MediaItem votedHigh = movie(QStringLiteral("Yarrow"), 2011, {QStringLiteral("Comedy")}, 50);
        MediaItem votedLow = movie(QStringLiteral("Xenia"), 2012, {QStringLiteral("Comedy")}, 50);
        MediaItem newerFile = movie(QStringLiteral("Wisp"), 2013, {QStringLiteral("Comedy")}, 5);
        MediaItem tieB = movie(QStringLiteral("Bolt"), 2014, {QStringLiteral("Comedy")}, 5);
        editable(votedHigh).voteAverage = 8.0;
        editable(votedLow).voteAverage = 6.0;
        editable(newerFile).voteAverage = 6.0;
        editable(tieB).voteAverage = 6.0;
        // Same vote and date as Wisp: the browse order breaks the tie, and a
        // title with no vote counts as zero.
        MediaItem noVote = movie(QStringLiteral("Anvil"), 2015, {QStringLiteral("Comedy")}, 5);

        const QVector<MediaItem> ranked = model->rankedCandidates(
            {noVote, tieB, votedLow, newerFile, votedHigh, liked}, 10);
        QCOMPARE(titlesOf(ranked),
                 (QStringList{QStringLiteral("Zeta"), QStringLiteral("Yarrow"), QStringLiteral("Bolt"),
                              QStringLiteral("Wisp"), QStringLiteral("Xenia"), QStringLiteral("Anvil")}));
        QCOMPARE(titlesOf(model->rankedCandidates({noVote, tieB, votedLow, newerFile, votedHigh, liked}, 2)),
                 (QStringList{QStringLiteral("Zeta"), QStringLiteral("Yarrow")}));
    }

    // The profile's own history makes its own model.
    void twoProfilesOfOneLibraryHaveTheirOwnTaste()
    {
        MediaItem dramaForA = movie(QStringLiteral("Aster"), 2001, {QStringLiteral("Drama")});
        MediaItem comedyForB = movie(QStringLiteral("Bramble"), 2002, {QStringLiteral("Comedy")});
        dramaForA.watched = true;
        const QVector<MediaItem> profileA{dramaForA, movie(QStringLiteral("Bramble"), 2002, {QStringLiteral("Comedy")})};
        comedyForB.watched = true;
        const QVector<MediaItem> profileB{movie(QStringLiteral("Aster"), 2001, {QStringLiteral("Drama")}), comedyForB};

        const auto a = browse::TasteModel::build(profileA);
        const auto b = browse::TasteModel::build(profileB);
        QVERIFY(a.has_value() && b.has_value());
        QCOMPARE(a->affinityScore(profileA.at(1)), 0.0);
        QCOMPARE(b->affinityScore(profileB.at(1)), 80.0);
        QCOMPARE(a->affinityScore(profileB.at(0)), 80.0);
        QCOMPARE(b->affinityScore(profileB.at(0)), 0.0);
    }
};

QTEST_APPLESS_MAIN(TasteModelTest)
#include "tst_taste_model.moc"
