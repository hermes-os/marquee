#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QTemporaryDir>
#include <QTest>

#include "playback/SubtitleDiscovery.hpp"

namespace
{
[[nodiscard]] bool touch(const QString &directory, const QString &relativePath)
{
    const QFileInfo target(QDir(directory).filePath(relativePath));
    if (!QDir().mkpath(target.absolutePath())) {
        return false;
    }
    QFile file(target.absoluteFilePath());
    return file.open(QIODevice::WriteOnly);
}

[[nodiscard]] QStringList namesOf(const QList<SidecarSubtitle> &found)
{
    QStringList names;
    for (const SidecarSubtitle &subtitle : found) {
        names.append(QFileInfo(subtitle.path).fileName());
    }
    return names;
}
}

class SubtitleDiscoveryTest final : public QObject
{
    Q_OBJECT

private slots:
    // The released rule, one name at a time: the video's name, then nothing or
    // a "." "_" "-" or space (`SubtitleDiscovery.swift:111-127`).
    void theReleasedNamesMatch_data()
    {
        QTest::addColumn<QString>("subtitle");
        QTest::addColumn<QString>("video");
        QTest::addColumn<bool>("matches");
        QTest::addColumn<QString>("language");

        QTest::newRow("bare") << "Film.srt" << "Film" << true << "";
        QTest::newRow("dot language") << "Film.en.srt" << "Film" << true << "en";
        QTest::newRow("underscore language") << "Film_en.srt" << "Film" << true << "en";
        QTest::newRow("dash language") << "Film - eng.srt" << "Film" << true << "eng";
        QTest::newRow("space language") << "Film fre.ass" << "Film" << true << "fre";
        QTest::newRow("year in the name") << "Example (2024).en.srt" << "Example (2024)" << true
                                          << "en";
        QTest::newRow("unknown word") << "Film.forced.srt" << "Film" << true << "";
        QTest::newRow("upper case") << "FILM.EN.SRT" << "Film" << true << "en";
        QTest::newRow("ssa") << "Film.ssa" << "Film" << true << "";
        QTest::newRow("vtt") << "Film.de.vtt" << "Film" << true << "de";
        QTest::newRow("a word that is not a language")
            << "Film.the.srt" << "Film" << true << "";

        QTest::newRow("unseparated digit") << "Example (2024)2.srt" << "Example (2024)" << false
                                           << "";
        QTest::newRow("another episode") << "Clip 10.en.srt" << "Clip 1" << false << "";
        // The released rule takes a space as a separator, so a sequel's file
        // is listed; it names no language, so no saved language selects it.
        QTest::newRow("a sequel's file") << "Cars 2.en.srt" << "Cars" << true << "";
        QTest::newRow("a sequel, unseparated") << "Cars2.en.srt" << "Cars" << false << "";
        QTest::newRow("unrelated") << "Unrelated.srt" << "Film" << false << "";
        QTest::newRow("not a subtitle") << "Film.en.txt" << "Film" << false << "";
        QTest::newRow("shorter name") << "Fil.srt" << "Film" << false << "";
    }

    void theReleasedNamesMatch()
    {
        QFETCH(QString, subtitle);
        QFETCH(QString, video);
        QFETCH(bool, matches);
        QFETCH(QString, language);

        SidecarSubtitle found;
        QCOMPARE(SubtitleDiscovery::matches(subtitle, video, &found), matches);
        if (matches) {
            QCOMPARE(found.language, language);
        }
    }

    void sidecarsBesideTheVideoAndInTheSubfoldersAreFound()
    {
        QTemporaryDir directory;
        QVERIFY(directory.isValid());
        QVERIFY(touch(directory.path(), "Example (2024).mkv"));
        QVERIFY(touch(directory.path(), "Example (2024).en.srt"));
        QVERIFY(touch(directory.path(), "Subs/Example (2024).fre.ass"));
        QVERIFY(touch(directory.path(), "subs/Example (2024)_de.srt"));
        QVERIFY(touch(directory.path(), "Subtitles/Example (2024) - es.vtt"));
        QVERIFY(touch(directory.path(), "subtitles/Example (2024).ssa"));
        QVERIFY(touch(directory.path(), "Example (2024)2.srt"));
        QVERIFY(touch(directory.path(), "Unrelated.srt"));
        QVERIFY(touch(directory.path(), "Other/Example (2024).it.srt"));

        const QList<SidecarSubtitle> found = SubtitleDiscovery::discover(
            QDir(directory.path()).filePath("Example (2024).mkv"));

        // On a case-insensitive file system Subs and subs are one folder;
        // either way each file is listed once.
        QStringList names = namesOf(found);
        names.sort();
        QCOMPARE(names,
                 (QStringList{"Example (2024) - es.vtt", "Example (2024).en.srt",
                              "Example (2024).fre.ass", "Example (2024).ssa",
                              "Example (2024)_de.srt"}));
        for (const SidecarSubtitle &subtitle : found) {
            QVERIFY2(QFileInfo(subtitle.path).isAbsolute(), qPrintable(subtitle.path));
            QVERIFY2(QFileInfo::exists(subtitle.path), qPrintable(subtitle.path));
        }
    }

    // The release keeps "Episode 10.en.srt" for episode 10: libmpv's fuzzy
    // search would hand it to "Episode 1.mkv" as an English track.
    void anotherEpisodesSubtitlesAreNotThisOnes()
    {
        QTemporaryDir directory;
        QVERIFY(directory.isValid());
        QVERIFY(touch(directory.path(), "Clip 1.mkv"));
        QVERIFY(touch(directory.path(), "Clip 10.en.srt"));
        QVERIFY(touch(directory.path(), "Clip 1.fr.srt"));

        const QList<SidecarSubtitle> found =
            SubtitleDiscovery::discover(QDir(directory.path()).filePath("Clip 1.mkv"));
        QCOMPARE(namesOf(found), QStringList{"Clip 1.fr.srt"});
        QCOMPARE(found.constFirst().language, QStringLiteral("fr"));
    }

    void aSubfolderReachedUnderTwoNamesIsScannedOnce()
    {
        QTemporaryDir directory;
        QVERIFY(directory.isValid());
        QVERIFY(touch(directory.path(), "Example.mkv"));
        QVERIFY(touch(directory.path(), "sidecar-store/Example.en.srt"));
        // The files sit outside the candidate names, so the folder is reached
        // only through the two links.
        const QString store = QDir(directory.path()).filePath("sidecar-store");
        QVERIFY(QFile::link(store, QDir(directory.path()).filePath("Subs")));
        QVERIFY(QFile::link(store, QDir(directory.path()).filePath("subtitles")));

        const QList<SidecarSubtitle> found =
            SubtitleDiscovery::discover(QDir(directory.path()).filePath("Example.mkv"));
        QCOMPARE(namesOf(found), QStringList{"Example.en.srt"});
    }

    void aVideoWithNoNeighboursHasNoSidecars()
    {
        QTemporaryDir directory;
        QVERIFY(directory.isValid());
        QVERIFY(touch(directory.path(), "Alone.mkv"));
        QVERIFY(SubtitleDiscovery::discover(QDir(directory.path()).filePath("Alone.mkv")).isEmpty());
        QVERIFY(SubtitleDiscovery::discover(QDir(directory.path()).filePath("gone/Alone.mkv"))
                    .isEmpty());
    }
};

QTEST_APPLESS_MAIN(SubtitleDiscoveryTest)

#include "tst_subtitle_discovery.moc"
