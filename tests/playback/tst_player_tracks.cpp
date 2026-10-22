#include <clocale>

#include <QDir>
#include <QElapsedTimer>
#include <QFile>
#include <QFileInfo>
#include <QGuiApplication>
#include <QProcess>
#include <QSignalSpy>
#include <QStandardPaths>
#include <QTemporaryDir>
#include <QTest>
#include <QThread>
#include <QUrl>

#include <mpv/client.h>

#include "playback/MpvVideoItem.hpp"

namespace
{
constexpr auto kSrt = "1\n00:00:00,000 --> 00:00:01,500\nHello\n";

[[nodiscard]] bool writeText(const QString &path, const QByteArray &text)
{
    QFile file(path);
    return file.open(QIODevice::WriteOnly) && file.write(text) == text.size();
}

/// A two-second clip with two audio tracks (eng, spa) and two subtitle tracks
/// (eng, fra), made by the real ffmpeg so libmpv reads the same container
/// metadata a library file carries. `dispositions` adds ffmpeg output options
/// (the container's default flags).
[[nodiscard]] bool writeTrackClip(const QString &directory, const QString &path,
                                  const QStringList &dispositions = {})
{
    const QString subtitleOne = QDir(directory).filePath(QStringLiteral("one.srt"));
    const QString subtitleTwo = QDir(directory).filePath(QStringLiteral("two.srt"));
    if (!writeText(subtitleOne, kSrt) || !writeText(subtitleTwo, kSrt)) {
        return false;
    }
    QStringList arguments{"-v", "error", "-y",
                          "-f", "lavfi", "-i", "color=c=black:s=64x64:d=2:r=10",
                          "-f", "lavfi", "-i", "sine=d=2",
                          "-f", "lavfi", "-i", "sine=f=880:d=2",
                          "-i", subtitleOne, "-i", subtitleTwo,
                          "-map", "0", "-map", "1", "-map", "2", "-map", "3", "-map", "4",
                          "-c:v", "mpeg4", "-c:a", "aac", "-c:s", "srt",
                          "-metadata:s:a:0", "language=eng", "-metadata:s:a:1", "language=spa",
                          "-metadata:s:s:0", "language=eng", "-metadata:s:s:1", "language=fra"};
    arguments += dispositions;
    arguments.append(path);
    QProcess ffmpeg;
    ffmpeg.start(QStringLiteral("ffmpeg"), arguments);
    return ffmpeg.waitForFinished(60000) && ffmpeg.exitStatus() == QProcess::NormalExit
        && ffmpeg.exitCode() == 0;
}

/// A two-minute clip with a keyframe every second. The audio track is what
/// lets libmpv play it on a host with no render context.
[[nodiscard]] bool writeScrubClip(const QString &path)
{
    QProcess ffmpeg;
    ffmpeg.start(QStringLiteral("ffmpeg"),
                 {"-v", "error", "-y", "-f", "lavfi", "-i", "color=c=black:s=64x64:d=120:r=2",
                  "-f", "lavfi", "-i", "sine=d=120", "-c:v", "mpeg4", "-g", "2",
                  "-keyint_min", "2", "-c:a", "aac", path});
    return ffmpeg.waitForFinished(120000) && ffmpeg.exitStatus() == QProcess::NormalExit
        && ffmpeg.exitCode() == 0;
}

/// A two-second clip with one audio track and no subtitles.
[[nodiscard]] bool writePlainClip(const QString &path)
{
    QProcess ffmpeg;
    ffmpeg.start(QStringLiteral("ffmpeg"),
                 {"-v", "error", "-y", "-f", "lavfi", "-i", "color=c=black:s=64x64:d=2:r=10",
                  "-f", "lavfi", "-i", "sine=d=2", "-c:v", "mpeg4", "-c:a", "aac", path});
    return ffmpeg.waitForFinished(60000) && ffmpeg.exitStatus() == QProcess::NormalExit
        && ffmpeg.exitCode() == 0;
}

/// A two-second clip with one audio track and one embedded subtitle track (eng).
[[nodiscard]] bool writeEmbeddedSubtitleClip(const QString &directory, const QString &path)
{
    const QString subtitle = QDir(directory).filePath(QStringLiteral("embedded.srt"));
    if (!writeText(subtitle, kSrt)) {
        return false;
    }
    QProcess ffmpeg;
    ffmpeg.start(QStringLiteral("ffmpeg"),
                 {"-v", "error", "-y", "-f", "lavfi", "-i", "color=c=black:s=64x64:d=2:r=10",
                  "-f", "lavfi", "-i", "sine=d=2", "-i", subtitle,
                  "-map", "0", "-map", "1", "-map", "2",
                  "-c:v", "mpeg4", "-c:a", "aac", "-c:s", "srt",
                  "-metadata:s:s:0", "language=eng", path});
    return ffmpeg.waitForFinished(60000) && ffmpeg.exitStatus() == QProcess::NormalExit
        && ffmpeg.exitCode() == 0;
}

// Without a render context libmpv plays only the audio, whose packets are
// about a tenth of a second long, so "exact" is judged to a quarter second; a
// keyframe landing would be off by up to the one second between the scrub
// clip's keyframes.
constexpr double kLandingTolerance = 0.25;

[[nodiscard]] QVariantMap trackAt(const QVariantList &tracks, int index)
{
    return tracks.value(index).toMap();
}
}

class PlayerTracksTest final : public QObject
{
    Q_OBJECT

private:
    QTemporaryDir m_directory;
    QString m_clip;
    QString m_scrubClip;

    /// Opens `m_clip` the way the player screen does once the scene graph has
    /// handed the item a render context: the context's arrival is the only
    /// step this host cannot take, and it is delivered through the item's own
    /// slot. The audio output is the null one because the host has no sound
    /// device.
    void open(MpvVideoItem &video, const QString &path = QString())
    {
        video.useNullAudioOutputForTest();
        video.setSource(QUrl::fromLocalFile(path.isEmpty() ? m_clip : path));
        QVERIFY(QMetaObject::invokeMethod(&video, "onRenderContextReady"));
    }

private slots:
    void initTestCase()
    {
        if (QStandardPaths::findExecutable(QStringLiteral("ffmpeg")).isEmpty()) {
            QSKIP("ffmpeg is not installed, so the test clip cannot be made");
        }
        QVERIFY(m_directory.isValid());
        m_clip = QDir(m_directory.path()).filePath(QStringLiteral("clip.mkv"));
        QVERIFY2(writeTrackClip(m_directory.path(), m_clip), "ffmpeg could not make the clip");
        m_scrubClip = QDir(m_directory.path()).filePath(QStringLiteral("scrub.mkv"));
        QVERIFY2(writeScrubClip(m_scrubClip), "ffmpeg could not make the scrub clip");
    }

    void itListsTheFilesAudioAndSubtitleTracks()
    {
        MpvVideoItem video;
        QVERIFY2(!video.failed(), qPrintable(video.errorMessage()));
        open(video);

        QTRY_COMPARE_WITH_TIMEOUT(video.audioTracks().size(), 2, 10000);
        QTRY_COMPARE(video.subtitleTracks().size(), 2);

        const QVariantMap english = trackAt(video.audioTracks(), 0);
        QCOMPARE(english.value("id").toInt(), 1);
        QCOMPARE(english.value("language").toString(), QStringLiteral("eng"));
        QCOMPARE(english.value("codec").toString(), QStringLiteral("aac"));
        QCOMPARE(english.value("label").toString(), QStringLiteral("English (aac)"));
        QVERIFY(english.contains("isDefault"));
        QVERIFY(english.contains("forced"));
        QVERIFY(english.contains("title"));
        const QVariantMap spanish = trackAt(video.audioTracks(), 1);
        QCOMPARE(spanish.value("id").toInt(), 2);
        QCOMPARE(spanish.value("language").toString(), QStringLiteral("spa"));

        QCOMPARE(trackAt(video.subtitleTracks(), 0).value("language").toString(),
                 QStringLiteral("eng"));
        QCOMPARE(trackAt(video.subtitleTracks(), 1).value("label").toString(),
                 QStringLiteral("French (subrip)"));
    }

    void itSwitchesTracksDuringPlayback()
    {
        MpvVideoItem video;
        // Default Subtitle Language "None" and English audio: the defaults.
        open(video);
        QTRY_COMPARE_WITH_TIMEOUT(video.audioTracks().size(), 2, 10000);
        QTRY_COMPARE(video.audioTrackId(), 1);
        QCOMPARE(video.subtitleTrackId(), 0);

        QSignalSpy audioChanged(&video, &MpvVideoItem::audioTrackIdChanged);
        video.selectAudioTrack(2);
        QTRY_COMPARE_WITH_TIMEOUT(video.audioTrackId(), 2, 5000);
        QCOMPARE(audioChanged.count(), 1);

        video.selectSubtitleTrack(2);
        QTRY_COMPARE_WITH_TIMEOUT(video.subtitleTrackId(), 2, 5000);
        video.selectSubtitleTrack(1);
        QTRY_COMPARE_WITH_TIMEOUT(video.subtitleTrackId(), 1, 5000);
        video.selectSubtitleTrack(0);
        QTRY_COMPARE_WITH_TIMEOUT(video.subtitleTrackId(), 0, 5000);

        // A track the file does not list changes nothing and is not a failure.
        QTest::ignoreMessage(QtWarningMsg,
                             QRegularExpression(QStringLiteral("no audio track 9")));
        video.selectAudioTrack(9);
        QTest::qWait(200);
        QCOMPARE(video.audioTrackId(), 2);
        QVERIFY(!video.failed());
    }

    void theSavedLanguagesChooseTheTracksAFileOpensWith()
    {
        MpvVideoItem video;
        video.setDefaultAudioLanguage(QStringLiteral("Spanish"));
        video.setDefaultSubtitleLanguage(QStringLiteral("French"));
        open(video);

        QTRY_COMPARE_WITH_TIMEOUT(video.audioTrackId(), 2, 10000);
        QTRY_COMPARE(video.subtitleTrackId(), 2);
    }

    // The file flags its Spanish audio and French subtitles as defaults. A
    // saved language the file lacks must leave libmpv's own audio pick (the
    // flagged track, not the first) and keep subtitles Off, so a rule that
    // fell back to the first track or to the file's flags would fail here.
    void aLanguageTheFileLacksLeavesSubtitlesOffAndAudioAtLibmpvsChoice()
    {
        const QString flagged = QDir(m_directory.path()).filePath(QStringLiteral("flagged.mkv"));
        QVERIFY(writeTrackClip(m_directory.path(), flagged,
                               {"-disposition:a:0", "0", "-disposition:a:1", "default",
                                "-disposition:s:0", "0", "-disposition:s:1", "default"}));

        MpvVideoItem video;
        video.setDefaultAudioLanguage(QStringLiteral("Japanese"));
        video.setDefaultSubtitleLanguage(QStringLiteral("German"));
        open(video, flagged);

        QTRY_COMPARE_WITH_TIMEOUT(video.audioTracks().size(), 2, 10000);
        QTRY_COMPARE(video.audioTrackId(), 2);
        QTest::qWait(300);
        QCOMPARE(video.audioTrackId(), 2);
        QCOMPARE(video.subtitleTrackId(), 0);
    }

    // libmpv keeps aid and sid across loadfile, and auto-play next reuses the
    // item, so the selection of one file must not reach the next. With a saved
    // language the next file lacks, nothing picks audio on load, so only the
    // reset before loadfile keeps the carried track from staying.
    void aSelectionDoesNotCarryIntoTheNextFile_data()
    {
        QTest::addColumn<QString>("audioLanguage");
        QTest::newRow("a language the file has") << "English";
        QTest::newRow("a language the file lacks") << "Japanese";
    }

    void aSelectionDoesNotCarryIntoTheNextFile()
    {
        QFETCH(QString, audioLanguage);
        const QString second = QDir(m_directory.path()).filePath(QStringLiteral("second.mkv"));
        if (!QFileInfo::exists(second)) {
            QVERIFY(QFile::copy(m_clip, second));
        }

        MpvVideoItem video;
        video.setDefaultAudioLanguage(QStringLiteral("English"));
        video.setDefaultSubtitleLanguage(QStringLiteral("None"));
        open(video);
        QTRY_COMPARE_WITH_TIMEOUT(video.audioTracks().size(), 2, 10000);
        QTRY_COMPARE(video.audioTrackId(), 1);
        video.selectAudioTrack(2);
        video.selectSubtitleTrack(2);
        QTRY_COMPARE_WITH_TIMEOUT(video.audioTrackId(), 2, 5000);
        QTRY_COMPARE(video.subtitleTrackId(), 2);

        video.setDefaultAudioLanguage(audioLanguage);
        video.setSource(QUrl::fromLocalFile(second));
        QTRY_COMPARE_WITH_TIMEOUT(video.audioTrackId(), 1, 10000);
        QTRY_COMPARE(video.audioTracks().size(), 2);
        QTRY_COMPARE(video.subtitleTracks().size(), 2);
        // Settled: libmpv's late reports for the second file do not bring the
        // first file's choice back.
        QTest::qWait(500);
        QCOMPARE(video.audioTrackId(), 1);
        QCOMPARE(video.subtitleTrackId(), 0);
    }

    void aSurfaceReloadKeepsTheViewersTracks()
    {
        MpvVideoItem video;
        video.setDefaultAudioLanguage(QStringLiteral("English"));
        open(video);
        QTRY_COMPARE_WITH_TIMEOUT(video.audioTrackId(), 1, 10000);
        video.selectAudioTrack(2);
        video.selectSubtitleTrack(1);
        QTRY_COMPARE_WITH_TIMEOUT(video.audioTrackId(), 2, 5000);
        QTRY_COMPARE(video.subtitleTrackId(), 1);

        QVERIFY(QMetaObject::invokeMethod(&video, "onRenderContextLost"));
        QVERIFY(QMetaObject::invokeMethod(&video, "onRenderContextReady"));
        QTest::qWait(1500);
        QTRY_COMPARE(video.audioTrackId(), 2);
        QCOMPARE(video.subtitleTrackId(), 1);
    }

    void subtitleSizeIsLibmpvsSubScale()
    {
        MpvVideoItem video;
        QCOMPARE(video.subScaleForTest().toDouble(), 1.35);
        video.setSubtitleScale(2.0);
        QCOMPARE(video.subScaleForTest().toDouble(), 2.0);
        video.setSubtitleLeanBack(true);
        QVERIFY(qAbs(video.subScaleForTest().toDouble() - 2.3) < 1e-6);
        video.setSubtitleScale(5.0);
        QVERIFY(qAbs(video.subScaleForTest().toDouble() - 2.2 * 1.15) < 1e-6);
    }

    void aSidecarSubtitleFileIsListedWithItsLanguageAndFormat()
    {
        const QString plain = QDir(m_directory.path()).filePath(QStringLiteral("plain.mkv"));
        QVERIFY(writePlainClip(plain));
        QVERIFY(writeText(QDir(m_directory.path()).filePath(QStringLiteral("plain.fr.srt")), kSrt));

        MpvVideoItem video;
        video.setDefaultSubtitleLanguage(QStringLiteral("French"));
        video.useNullAudioOutputForTest();
        video.setSource(QUrl::fromLocalFile(plain));
        QVERIFY(QMetaObject::invokeMethod(&video, "onRenderContextReady"));

        QTRY_COMPARE_WITH_TIMEOUT(video.subtitleTracks().size(), 1, 10000);
        QCOMPARE(trackAt(video.subtitleTracks(), 0).value("label").toString(),
                 QStringLiteral("French (SRT)"));
        QVERIFY(trackAt(video.subtitleTracks(), 0).value("external").toBool());
        QTRY_COMPARE(video.subtitleTrackId(), 1);
    }

    // libmpv's own fuzzy search lists "Clip 10.en.srt" for "Clip 1.mkv" as an
    // English track and selects it; the player must not show another
    // episode's subtitles.
    void anotherEpisodesSubtitleFileIsNotListed()
    {
        const QString directory = QDir(m_directory.path()).filePath(QStringLiteral("episodes"));
        QVERIFY(QDir().mkpath(directory));
        const QString clip = QDir(directory).filePath(QStringLiteral("Clip 1.mkv"));
        QVERIFY(writePlainClip(clip));
        QVERIFY(writeText(QDir(directory).filePath(QStringLiteral("Clip 10.en.srt")), kSrt));
        QVERIFY(writeText(QDir(directory).filePath(QStringLiteral("Clip 1.fr.srt")), kSrt));

        MpvVideoItem video;
        video.setDefaultSubtitleLanguage(QStringLiteral("English"));
        open(video, clip);

        QTRY_COMPARE_WITH_TIMEOUT(video.subtitleTracks().size(), 1, 10000);
        QTest::qWait(500);
        QCOMPARE(video.subtitleTracks().size(), 1);
        const QVariantMap listed = trackAt(video.subtitleTracks(), 0);
        QCOMPARE(listed.value("label").toString(), QStringLiteral("French (SRT)"));
        // English is saved and only a French file belongs to the clip.
        QCOMPARE(video.subtitleTrackId(), 0);
    }

    // The same, with nothing else beside the clip: the list stays empty.
    void aNeighbouringFilesSubtitlesAloneLeaveTheListEmpty()
    {
        const QString directory = QDir(m_directory.path()).filePath(QStringLiteral("alone"));
        QVERIFY(QDir().mkpath(directory));
        const QString clip = QDir(directory).filePath(QStringLiteral("Clip 1.mkv"));
        QVERIFY(writePlainClip(clip));
        QVERIFY(writeText(QDir(directory).filePath(QStringLiteral("Clip 10.en.srt")), kSrt));

        MpvVideoItem video;
        video.setDefaultSubtitleLanguage(QStringLiteral("English"));
        open(video, clip);

        QTRY_COMPARE_WITH_TIMEOUT(video.audioTracks().size(), 1, 10000);
        QTest::qWait(500);
        QCOMPARE(video.subtitleTracks().size(), 0);
        QCOMPARE(video.subtitleTrackId(), 0);
    }

    // The released app lists "Film_en.srt" and "Film - eng.srt"; libmpv's
    // exact search drops both.
    void separatedSidecarNamesAreListedWithTheirLanguage()
    {
        const QString directory = QDir(m_directory.path()).filePath(QStringLiteral("separated"));
        QVERIFY(QDir().mkpath(directory));
        const QString clip = QDir(directory).filePath(QStringLiteral("Film.mkv"));
        QVERIFY(writePlainClip(clip));
        QVERIFY(writeText(QDir(directory).filePath(QStringLiteral("Film_en.srt")), kSrt));
        QVERIFY(writeText(QDir(directory).filePath(QStringLiteral("Film - fre.srt")), kSrt));
        QVERIFY(QDir().mkpath(QDir(directory).filePath(QStringLiteral("Subs"))));
        QVERIFY(writeText(QDir(directory).filePath(QStringLiteral("Subs/Film.de.ass")), kSrt));

        MpvVideoItem video;
        video.setDefaultSubtitleLanguage(QStringLiteral("French"));
        open(video, clip);

        QTRY_COMPARE_WITH_TIMEOUT(video.subtitleTracks().size(), 3, 10000);
        QStringList labels;
        for (const QVariant &track : video.subtitleTracks()) {
            labels.append(track.toMap().value("label").toString());
        }
        labels.sort();
        QCOMPARE(labels, (QStringList{"English (SRT)", "French (SRT)", "German (ASS)"}));
        // The saved French picks the file named for it.
        QTRY_VERIFY(video.subtitleTrackId() > 0);
        const QVariantMap chosen = video.subtitleTracks().at(video.subtitleTrackId() - 1).toMap();
        QCOMPARE(chosen.value("label").toString(), QStringLiteral("French (SRT)"));
    }

    // The sidecar is added while libmpv waits at on_preloaded, so a surface
    // reload that restores the viewer's sid finds it listed. Added from
    // START_FILE, libmpv's own track pick raced the add and turned the
    // subtitles off or moved them to another track.
    void aSurfaceReloadKeepsTheChosenSidecarSubtitle()
    {
        const QString directory = QDir(m_directory.path()).filePath(QStringLiteral("reload"));
        QVERIFY(QDir().mkpath(directory));
        const QString clip = QDir(directory).filePath(QStringLiteral("clip.mkv"));
        QVERIFY(writeTrackClip(directory, clip));
        QVERIFY(writeText(QDir(directory).filePath(QStringLiteral("clip.fr.srt")), kSrt));

        MpvVideoItem video;
        open(video, clip);
        QTRY_COMPARE_WITH_TIMEOUT(video.subtitleTracks().size(), 3, 10000);
        QTRY_COMPARE(video.audioTrackId(), 1);
        // The sidecar comes after the two embedded subtitle tracks.
        QVERIFY(trackAt(video.subtitleTracks(), 2).value("external").toBool());
        video.selectSubtitleTrack(3);
        QTRY_COMPARE_WITH_TIMEOUT(video.subtitleTrackId(), 3, 5000);

        QVERIFY(QMetaObject::invokeMethod(&video, "onRenderContextLost"));
        QVERIFY(QMetaObject::invokeMethod(&video, "onRenderContextReady"));
        QTest::qWait(1500);
        QTRY_COMPARE_WITH_TIMEOUT(video.subtitleTracks().size(), 3, 5000);
        QCOMPARE(video.subtitleTrackId(), 3);
    }

    // A clip with one embedded subtitle track and a sidecar: the embedded
    // track keeps id 1, so the menu order and the default pick do not change
    // from run to run.
    // Probabilistic: the old add-sidecar-at-START_FILE code lost this race in
    // only some loads, and on this host it never lost in 15, so a pass proves
    // nothing about the race and the case does not fail on the old code here.
    void anEmbeddedSubtitleKeepsIdOneAheadOfASidecar()
    {
        const QString directory = QDir(m_directory.path()).filePath(QStringLiteral("order"));
        QVERIFY(QDir().mkpath(directory));
        const QString clip = QDir(directory).filePath(QStringLiteral("clip.mkv"));
        QVERIFY(writeEmbeddedSubtitleClip(directory, clip));
        QVERIFY(writeText(QDir(directory).filePath(QStringLiteral("clip.fr.srt")), kSrt));

        // The race shows in a fraction of the loads, so a fresh item opens the
        // clip repeatedly; one stray order fails the case.
        for (int load = 0; load < 15; ++load) {
            MpvVideoItem video;
            video.setDefaultSubtitleLanguage(QStringLiteral("French"));
            open(video, clip);

            QTRY_COMPARE_WITH_TIMEOUT(video.subtitleTracks().size(), 2, 10000);
            const QVariantMap first = trackAt(video.subtitleTracks(), 0);
            QCOMPARE(first.value("id").toInt(), 1);
            QVERIFY(!first.value("external").toBool());
            QCOMPARE(first.value("language").toString(), QStringLiteral("eng"));
            const QVariantMap second = trackAt(video.subtitleTracks(), 1);
            QCOMPARE(second.value("id").toInt(), 2);
            QVERIFY(second.value("external").toBool());
            // The saved French picks the sidecar, the only French track.
            QTRY_COMPARE(video.subtitleTrackId(), 2);
        }
    }

    // The on_preloaded hook holds the load until the item answers it, so a
    // stop, a replaced source, and an item destroyed while it waits must each
    // leave libmpv free to go on.
    void aLoadStoppedReplacedOrAbandonedAtTheHookNeverHangs()
    {
        const QString directory = QDir(m_directory.path()).filePath(QStringLiteral("hook"));
        QVERIFY(QDir().mkpath(directory));
        const QString first = QDir(directory).filePath(QStringLiteral("first.mkv"));
        const QString second = QDir(directory).filePath(QStringLiteral("second.mkv"));
        QVERIFY(writeEmbeddedSubtitleClip(directory, first));
        QVERIFY(QFile::copy(first, second));
        QVERIFY(writeText(QDir(directory).filePath(QStringLiteral("first.fr.srt")), kSrt));
        QVERIFY(writeText(QDir(directory).filePath(QStringLiteral("second.de.srt")), kSrt));

        for (int round = 0; round < 10; ++round) {
            // Stopped right after the load was issued, then opened again.
            {
                MpvVideoItem video;
                open(video, first);
                video.stop();
                open(video, second);
                QTRY_COMPARE_WITH_TIMEOUT(video.subtitleTracks().size(), 2, 10000);
                QCOMPARE(trackAt(video.subtitleTracks(), 1).value("language").toString(),
                         QStringLiteral("de"));
                QVERIFY(!video.failed());
            }
            // Replaced before the first load got its sidecars: only the
            // second file's sidecar is listed.
            {
                MpvVideoItem video;
                open(video, first);
                video.setSource(QUrl::fromLocalFile(second));
                QTRY_COMPARE_WITH_TIMEOUT(video.subtitleTracks().size(), 2, 10000);
                QTest::qWait(100);
                QCOMPARE(video.subtitleTracks().size(), 2);
                QCOMPARE(trackAt(video.subtitleTracks(), 1).value("language").toString(),
                         QStringLiteral("de"));
                QVERIFY(!video.failed());
            }
            // Destroyed with the load in flight, before any event was drained.
            {
                MpvVideoItem video;
                open(video, first);
            }
        }
    }

    // The tracks go in the same call as the stop, not with libmpv's later
    // report, so a menu opened right after never lists the stopped file.
    void stoppingClearsTheTracks()
    {
        MpvVideoItem video;
        open(video);
        QTRY_COMPARE_WITH_TIMEOUT(video.audioTracks().size(), 2, 10000);
        QTRY_COMPARE(video.audioTrackId(), 1);
        video.stop();
        QCOMPARE(video.audioTracks().size(), 0);
        QCOMPARE(video.subtitleTracks().size(), 0);
        QCOMPARE(video.audioTrackId(), 0);
        QCOMPARE(video.subtitleTrackId(), 0);
        // And libmpv's own report afterwards leaves them cleared.
        QTest::qWait(500);
        QCOMPARE(video.audioTracks().size(), 0);
    }

    // Volume, mute and speed go to libmpv itself, not only to the item's
    // properties: each is read back from the live core.
    void volumeMuteAndSpeedReachLibmpv()
    {
        MpvVideoItem video;
        open(video);
        QTRY_COMPARE_WITH_TIMEOUT(video.audioTracks().size(), 2, 10000);

        QCOMPARE(video.volume(), 100.0);
        video.setVolume(40.0);
        QCOMPARE(video.propertyForTest(QStringLiteral("volume")).toDouble(), 40.0);
        QCOMPARE(video.volume(), 40.0);
        video.adjustVolume(-15.0);
        QCOMPARE(video.propertyForTest(QStringLiteral("volume")).toDouble(), 25.0);
        // Neither end of the range is passed.
        video.setVolume(250.0);
        QCOMPARE(video.propertyForTest(QStringLiteral("volume")).toDouble(), 100.0);
        video.setVolume(-5.0);
        QCOMPARE(video.propertyForTest(QStringLiteral("volume")).toDouble(), 0.0);

        QCOMPARE(video.propertyForTest(QStringLiteral("mute")), QStringLiteral("no"));
        video.toggleMute();
        QCOMPARE(video.propertyForTest(QStringLiteral("mute")), QStringLiteral("yes"));
        QVERIFY(video.muted());
        video.toggleMute();
        QCOMPARE(video.propertyForTest(QStringLiteral("mute")), QStringLiteral("no"));
        QVERIFY(!video.muted());

        QCOMPARE(video.speed(), 1.0);
        video.setSpeed(2.0);
        QCOMPARE(video.propertyForTest(QStringLiteral("speed")).toDouble(), 2.0);
        video.setSpeed(9.0);
        QCOMPARE(video.propertyForTest(QStringLiteral("speed")).toDouble(), 3.0);
        video.setSpeed(0.1);
        QCOMPARE(video.propertyForTest(QStringLiteral("speed")).toDouble(), 0.5);
        QVERIFY(!video.failed());
    }

    // PlayerView.swift:15, :274-281: 0.5, 0.75, 1, 1.25, 1.5, 2, 3; the ends
    // stay put.
    void bracketKeysStepThroughTheReleasedSpeeds()
    {
        MpvVideoItem video;
        open(video);
        QTRY_COMPARE_WITH_TIMEOUT(video.audioTracks().size(), 2, 10000);

        const auto speed = [&video] {
            return video.propertyForTest(QStringLiteral("speed")).toDouble();
        };
        const QList<double> up{1.25, 1.5, 2.0, 3.0, 3.0};
        for (const double expected : up) {
            video.stepSpeed(1);
            QCOMPARE(speed(), expected);
        }
        const QList<double> down{2.0, 1.5, 1.25, 1.0, 0.75, 0.5, 0.5};
        for (const double expected : down) {
            video.stepSpeed(-1);
            QCOMPARE(speed(), expected);
        }
        // A speed that is not a step counts from 1x.
        video.setSpeed(1.1);
        video.stepSpeed(1);
        QCOMPARE(speed(), 1.25);
    }

    // The oracle starts every playback at 100, unmuted, 1x and keeps nothing
    // (MPVPlayerService.swift:386-395, :606).
    void volumeMuteAndSpeedStartOverWithTheNextFile()
    {
        const QString other = QDir(m_directory.path()).filePath(QStringLiteral("other.mkv"));
        QVERIFY(QFile::copy(m_clip, other));

        MpvVideoItem video;
        open(video);
        QTRY_COMPARE_WITH_TIMEOUT(video.audioTracks().size(), 2, 10000);
        video.setVolume(30.0);
        video.toggleMute();
        video.setSpeed(2.0);

        video.setSource(QUrl::fromLocalFile(other));
        QCOMPARE(video.propertyForTest(QStringLiteral("volume")).toDouble(), 100.0);
        QCOMPARE(video.propertyForTest(QStringLiteral("mute")), QStringLiteral("no"));
        QCOMPARE(video.propertyForTest(QStringLiteral("speed")).toDouble(), 1.0);
        QCOMPARE(video.volume(), 100.0);
        QVERIFY(!video.muted());
        QCOMPARE(video.speed(), 1.0);
    }

    // The oracle builds a fresh player for every file
    // (PlayerController.swift:76-104), so a pause belongs to the file it was
    // pressed in. libmpv keeps it across loadfile, which left the next file
    // paused and stuck in startup.
    void aPausedFileDoesNotPauseTheNextOne()
    {
        const QString other = QDir(m_directory.path()).filePath(QStringLiteral("next.mkv"));
        QVERIFY(QFile::copy(m_clip, other));

        MpvVideoItem video;
        open(video);
        QTRY_COMPARE_WITH_TIMEOUT(video.audioTracks().size(), 2, 10000);
        video.pause();
        QTRY_VERIFY_WITH_TIMEOUT(video.paused(), 5000);

        video.setSource(QUrl::fromLocalFile(other));
        // Before libmpv reports anything about the new file: the HUD already
        // shows playing and the flag libmpv holds is already clear.
        QVERIFY(!video.paused());
        QCOMPARE(video.propertyForTest(QStringLiteral("pause")), QStringLiteral("no"));

        QVERIFY(QMetaObject::invokeMethod(&video, "onRenderContextReady"));
        QTRY_VERIFY_WITH_TIMEOUT(!video.startupPending(), 10000);
        QVERIFY(!video.paused());
        QVERIFY(video.position() >= 0.35);
        QVERIFY2(!video.failed(), qPrintable(video.errorMessage()));
    }

    // libmpv can still report the old file's position after setSource when
    // the GUI thread was busy. That report must not count as the new file's:
    // it cleared startup at once and let the next-episode handoff drop.
    void aStalePositionDoesNotEndTheNewFilesStartup()
    {
        const QString other = QDir(m_directory.path()).filePath(QStringLiteral("stale.mkv"));
        QVERIFY(QFile::copy(m_clip, other));

        MpvVideoItem video;
        open(video);
        QTRY_VERIFY_WITH_TIMEOUT(video.position() > 1.0, 10000);

        // Reports for the old file pile up in libmpv's queue while the GUI
        // thread is away, then the next file is opened.
        QThread::msleep(120);
        QElapsedTimer sinceSource;
        qint64 releasedAfterMs = -1;
        connect(&video, &MpvVideoItem::startupPendingChanged, this, [&] {
            if (!video.startupPending() && releasedAfterMs < 0) {
                releasedAfterMs = sinceSource.elapsed();
            }
        });
        sinceSource.start();
        video.setSource(QUrl::fromLocalFile(other));
        QVERIFY(video.startupPending());

        // The queued report arrives after the new source is set, as libmpv
        // delivers it: deterministic here, where the real race is not.
        double stalePosition = 1.4;
        mpv_event_property positionProperty{};
        positionProperty.name = "time-pos";
        positionProperty.format = MPV_FORMAT_DOUBLE;
        positionProperty.data = &stalePosition;
        mpv_event positionEvent{};
        positionEvent.event_id = MPV_EVENT_PROPERTY_CHANGE;
        positionEvent.data = &positionProperty;
        QVERIFY(QMetaObject::invokeMethod(&video, "applyEvent",
                                         Q_ARG(mpv_event *, &positionEvent)));
        QVERIFY(video.startupPending());
        QCOMPARE(video.position(), 0.0);

        QVERIFY(QMetaObject::invokeMethod(&video, "onRenderContextReady"));
        QVERIFY(video.startupPending());
        QTRY_VERIFY_WITH_TIMEOUT(!video.startupPending(), 10000);
        // Released by the new file's own 0.35 s of playback, not at once.
        QVERIFY2(releasedAfterMs >= 300, qPrintable(QString::number(releasedAfterMs)));
        QVERIFY(video.position() >= 0.35);
        QVERIFY(video.position() < 1.0);
        QVERIFY2(!video.failed(), qPrintable(video.errorMessage()));
    }

    // An end-of-file report that belongs to the file setSource replaced must
    // not end the new one; the new file's own end still does.
    void aStaleEndDoesNotEndTheNewFile()
    {
        const QString other = QDir(m_directory.path()).filePath(QStringLiteral("stale-end.mkv"));
        QVERIFY(QFile::copy(m_clip, other));

        MpvVideoItem video;
        open(video);
        QTRY_COMPARE_WITH_TIMEOUT(video.audioTracks().size(), 2, 10000);
        QSignalSpy ended(&video, &MpvVideoItem::playbackEnded);

        int eofFlag = 1;
        mpv_event_property eofProperty{};
        eofProperty.name = "eof-reached";
        eofProperty.format = MPV_FORMAT_FLAG;
        eofProperty.data = &eofFlag;
        mpv_event eofEvent{};
        eofEvent.event_id = MPV_EVENT_PROPERTY_CHANGE;
        eofEvent.data = &eofProperty;

        video.setSource(QUrl::fromLocalFile(other));
        QVERIFY(QMetaObject::invokeMethod(&video, "applyEvent", Q_ARG(mpv_event *, &eofEvent)));
        QCOMPARE(ended.count(), 0);

        QVERIFY(QMetaObject::invokeMethod(&video, "onRenderContextReady"));
        QTRY_VERIFY_WITH_TIMEOUT(!video.startupPending(), 10000);
        QCOMPARE(ended.count(), 0);

        // Once the file is loaded an end counts again.
        QVERIFY(QMetaObject::invokeMethod(&video, "applyEvent", Q_ARG(mpv_event *, &eofEvent)));
        QCOMPARE(ended.count(), 1);
    }

    // The controls are cleared once for a new source. A pause pressed while
    // the source waits for a render surface is the viewer's, and the
    // surface's arrival must not take it back.
    void aPauseBeforeTheSurfaceArrivesSurvivesIt()
    {
        MpvVideoItem video;
        video.useNullAudioOutputForTest();
        video.setSource(QUrl::fromLocalFile(m_clip));
        video.pause();
        QTRY_VERIFY_WITH_TIMEOUT(video.paused(), 5000);

        QVERIFY(QMetaObject::invokeMethod(&video, "onRenderContextReady"));
        QCOMPARE(video.propertyForTest(QStringLiteral("pause")), QStringLiteral("yes"));
        QTRY_COMPARE_WITH_TIMEOUT(video.audioTracks().size(), 2, 10000);
        QVERIFY(video.paused());
    }

    // A key pressed before the file has opened has nothing to seek, and
    // libmpv's refusal would otherwise put up the failure card.
    void aSeekBeforeAnyFileIsOpenChangesNothingAndFailsNothing()
    {
        MpvVideoItem video;
        QVERIFY(!video.seekAbsolute(5.0));
        QVERIFY(!video.seekRelative(30.0));
        QVERIFY2(!video.failed(), qPrintable(video.errorMessage()));
    }

    // The screen marks itself seeking only for a seek that was issued, so the
    // answer has to say which it was.
    void aSeekOfALoadedFileSaysItWasIssued()
    {
        MpvVideoItem video;
        open(video);
        QTRY_COMPARE_WITH_TIMEOUT(video.audioTracks().size(), 2, 10000);
        video.pause();
        QTRY_VERIFY_WITH_TIMEOUT(video.paused(), 5000);
        QVERIFY(video.seekAbsolute(0.2));
        QVERIFY(video.seekRelative(1.0));
        QVERIFY2(!video.failed(), qPrintable(video.errorMessage()));
    }

    void aRelativeSeekMovesFromWhereTheFileIs()
    {
        MpvVideoItem video;
        open(video);
        QTRY_COMPARE_WITH_TIMEOUT(video.audioTracks().size(), 2, 10000);
        video.pause();
        QTRY_VERIFY_WITH_TIMEOUT(video.paused(), 5000);
        video.seekAbsolute(0.2);
        QTRY_VERIFY_WITH_TIMEOUT(video.position() > 0.15 && video.position() < 0.6, 5000);

        video.seekRelative(1.0);
        QTRY_VERIFY_WITH_TIMEOUT(video.position() > 0.9, 5000);
        const double forward = video.position();
        video.seekRelative(-0.5);
        QTRY_VERIFY_WITH_TIMEOUT(video.position() < forward - 0.2, 5000);
        QVERIFY(!video.failed());
    }

    // Opens the long clip, paused at `at` seconds, ready to scrub.
    void openForScrub(MpvVideoItem &video, double at)
    {
        open(video, m_scrubClip);
        QTRY_VERIFY_WITH_TIMEOUT(video.duration() > 100.0, 10000);
        video.pause();
        QTRY_VERIFY_WITH_TIMEOUT(video.paused(), 5000);
        QVERIFY(video.seekAbsolute(at));
        QTRY_VERIFY_WITH_TIMEOUT(qAbs(video.position() - at) < 0.6, 5000);
    }

    [[nodiscard]] static double timePosition(const MpvVideoItem &video)
    {
        return video.propertyForTest(QStringLiteral("time-pos")).toDouble();
    }

    // A hold relaxes libmpv's seek mode for its previews, the clock the
    // session stores stays where the hold began, and letting go lands
    // exactly where the scrub got to with the normal seek mode back. (What
    // the picture shows during the hold is judged where a render context
    // exists: tst_playback.)
    void releaseLandsExactlyAndRestoresTheSeekMode()
    {
        MpvVideoItem video;
        openForScrub(video, 20.0);
        QCOMPARE(video.propertyForTest(QStringLiteral("hr-seek")), QStringLiteral("absolute"));
        const double origin = video.position();

        video.beginScrub();
        QVERIFY(video.scrubbing());
        QTRY_COMPARE_WITH_TIMEOUT(video.propertyForTest(QStringLiteral("hr-seek")),
                                  QStringLiteral("no"), 5000);
        video.previewScrub(origin + 7.3);
        video.previewScrub(origin + 12.37);
        QTest::qWait(300);
        QCOMPARE(video.position(), origin);

        const double landing = origin + 12.37;
        QVERIFY(video.finishScrub(landing));
        QVERIFY(!video.scrubbing());
        QTRY_COMPARE_WITH_TIMEOUT(video.propertyForTest(QStringLiteral("hr-seek")),
                                  QStringLiteral("absolute"), 5000);
        QTRY_VERIFY_WITH_TIMEOUT(qAbs(timePosition(video) - landing) < kLandingTolerance, 5000);
        QTRY_VERIFY_WITH_TIMEOUT(qAbs(video.position() - landing) < kLandingTolerance, 5000);
        QVERIFY(video.paused());
        QVERIFY2(!video.failed(), qPrintable(video.errorMessage()));
    }

    // A hold of ten seconds calls for a preview at every tick; only one seek
    // may be in flight, and nothing keeps moving the picture after release.
    void previewsDoNotPileUpAndLeaveNoBacklogAfterRelease()
    {
        MpvVideoItem video;
        openForScrub(video, 5.0);
        video.beginScrub();
        const int before = video.previewSeeksIssuedForTest();
        for (int step = 1; step <= 200; ++step) {
            video.previewScrub(5.0 + step * 0.5);
        }
        // The loop never yielded to the event loop, so libmpv cannot have
        // answered the first one: the other 199 collapsed into one.
        QCOMPARE(video.previewSeeksIssuedForTest() - before, 1);

        const double landing = 5.0 + 200 * 0.5;
        QVERIFY(video.finishScrub(landing));
        QTRY_VERIFY_WITH_TIMEOUT(qAbs(video.position() - landing) < kLandingTolerance, 5000);

        const int afterRelease = video.previewSeeksIssuedForTest();
        QTest::qWait(600);
        QCOMPARE(video.previewSeeksIssuedForTest(), afterRelease);
        QVERIFY(qAbs(timePosition(video) - landing) < kLandingTolerance);
        QVERIFY(qAbs(video.position() - landing) < kLandingTolerance);
    }

    // A landing where libmpv already is (a hold clamped at 0, a keyframe a
    // preview showed) sends no position report, so the settle would wait for
    // its watchdog. A tap, a bar click or Restart in that window is a newer
    // seek: the clock must follow it, and stay there while paused.
    void aTapRightAfterAHoldClampedAtZeroMovesTheClock()
    {
        MpvVideoItem video;
        openForScrub(video, 20.0);
        video.beginScrub();
        QTRY_COMPARE_WITH_TIMEOUT(video.propertyForTest(QStringLiteral("hr-seek")),
                                  QStringLiteral("no"), 5000);
        video.previewScrub(0.0);
        // Released only once libmpv is already at 0: the exact seek then
        // lands where it is and reports no change.
        QTRY_VERIFY_WITH_TIMEOUT(timePosition(video) < kLandingTolerance, 5000);
        QTest::qWait(300);
        QVERIFY(video.finishScrub(0.0));
        QTest::qWait(200);
        QVERIFY(video.seekRelative(30.0));
        QTRY_VERIFY_WITH_TIMEOUT(timePosition(video) > 25.0, 5000);
        QTRY_VERIFY_WITH_TIMEOUT(qAbs(video.position() - timePosition(video)) < kLandingTolerance,
                                 2000);
        // Paused: nothing more arrives after the settle watchdog would have
        // ended, so a clock left on the old landing would stay wrong.
        QTest::qWait(1800);
        QVERIFY(qAbs(video.position() - timePosition(video)) < kLandingTolerance);
        QVERIFY(video.position() > 25.0);
        QVERIFY(video.paused());
    }

    void aBarClickRightAfterAHoldClampedAtZeroMovesTheClock()
    {
        MpvVideoItem video;
        openForScrub(video, 20.0);
        video.beginScrub();
        QTRY_COMPARE_WITH_TIMEOUT(video.propertyForTest(QStringLiteral("hr-seek")),
                                  QStringLiteral("no"), 5000);
        video.previewScrub(0.0);
        // Released only once libmpv is already at 0: the exact seek then
        // lands where it is and reports no change.
        QTRY_VERIFY_WITH_TIMEOUT(timePosition(video) < kLandingTolerance, 5000);
        QTest::qWait(300);
        QVERIFY(video.finishScrub(0.0));
        QTest::qWait(200);
        QVERIFY(video.seekAbsolute(60.0));
        QTRY_VERIFY_WITH_TIMEOUT(qAbs(video.position() - 60.0) < kLandingTolerance, 5000);
        QTest::qWait(1800);
        QVERIFY(qAbs(video.position() - timePosition(video)) < kLandingTolerance);
        QVERIFY(qAbs(video.position() - 60.0) < kLandingTolerance);
    }

    // A landing on a keyframe the preview already showed sends no position
    // report either, and a host without a render context cannot make libmpv
    // do that on cue, so the reports are delivered by hand (as in
    // aLateRestartDoesNotReleaseTheFirstPreviewOfANewHold): none for the
    // landing, then the one for the Left tap's own seek. The tap's position
    // is what the session must show and store, not the old landing.
    void aLeftTapRightAfterAKeyframeLandingReadsTheNewPosition()
    {
        MpvVideoItem video;
        openForScrub(video, 20.0);
        video.beginScrub();
        video.previewScrub(40.0);
        QVERIFY(video.finishScrub(40.0));
        QCOMPARE(video.position(), 40.0);
        QVERIFY(video.seekRelative(-10.0));

        double reported = 30.0;
        mpv_event_property property{"time-pos", MPV_FORMAT_DOUBLE, &reported};
        mpv_event event{};
        event.event_id = MPV_EVENT_PROPERTY_CHANGE;
        event.data = &property;
        QVERIFY(QMetaObject::invokeMethod(&video, "applyEvent", Q_ARG(mpv_event *, &event)));
        QCOMPARE(video.position(), 30.0);
    }

    // A hold that starts before the last landing has confirmed can see that
    // landing's PLAYBACK_RESTART arrive after its own first preview was
    // issued. It is not that preview's restart: counting it would let the
    // queued target out beside the preview still running. The restart is
    // delivered by hand, before libmpv has answered the preview's command, so
    // the order is fixed.
    void aLateRestartDoesNotReleaseTheFirstPreviewOfANewHold()
    {
        MpvVideoItem video;
        openForScrub(video, 20.0);
        video.beginScrub();
        const int before = video.previewSeeksIssuedForTest();
        video.previewScrub(30.0);
        video.previewScrub(40.0);
        QCOMPARE(video.previewSeeksIssuedForTest() - before, 1);

        mpv_event restart{};
        restart.event_id = MPV_EVENT_PLAYBACK_RESTART;
        QVERIFY(QMetaObject::invokeMethod(&video, "applyEvent", Q_ARG(mpv_event *, &restart)));
        QCOMPARE(video.previewSeeksIssuedForTest() - before, 1);

        // The preview's own restart still releases the queued target.
        QTRY_COMPARE_WITH_TIMEOUT(video.previewSeeksIssuedForTest() - before, 2, 5000);
        video.cancelScrub();
    }

    // Cancelling puts the picture back where the hold began and the seek mode
    // back to normal, without landing anywhere else.
    void cancellingAScrubRestoresThePictureAndTheSeekMode()
    {
        MpvVideoItem video;
        openForScrub(video, 30.0);
        const double origin = video.position();
        video.beginScrub();
        video.previewScrub(origin + 20.0);
        QTest::qWait(300);

        video.cancelScrub();
        QVERIFY(!video.scrubbing());
        QTRY_COMPARE_WITH_TIMEOUT(video.propertyForTest(QStringLiteral("hr-seek")),
                                  QStringLiteral("absolute"), 5000);
        QTRY_VERIFY_WITH_TIMEOUT(qAbs(timePosition(video) - origin) < kLandingTolerance, 5000);
        QTRY_VERIFY_WITH_TIMEOUT(qAbs(video.position() - origin) < kLandingTolerance, 5000);
        QTest::qWait(300);
        QVERIFY(qAbs(video.position() - origin) < kLandingTolerance);
        QVERIFY(video.paused());
    }

    // The player closing: stop() ends the hold and restores the mode.
    void stoppingTheItemMidScrubRestoresTheSeekMode()
    {
        MpvVideoItem video;
        openForScrub(video, 30.0);
        video.beginScrub();
        QTRY_COMPARE_WITH_TIMEOUT(video.propertyForTest(QStringLiteral("hr-seek")),
                                  QStringLiteral("no"), 5000);
        video.previewScrub(60.0);

        video.stop();
        QVERIFY(!video.scrubbing());
        QTRY_COMPARE_WITH_TIMEOUT(video.propertyForTest(QStringLiteral("hr-seek")),
                                  QStringLiteral("absolute"), 5000);
        // A preview that was still queued does not seek the empty player.
        QTest::qWait(300);
        QVERIFY(!video.failed());
    }

    // The next episode: a new source ends the hold and the next file does not
    // inherit the relaxed seek mode.
    void aNewSourceMidScrubRestoresTheSeekMode()
    {
        MpvVideoItem video;
        openForScrub(video, 30.0);
        video.beginScrub();
        QTRY_COMPARE_WITH_TIMEOUT(video.propertyForTest(QStringLiteral("hr-seek")),
                                  QStringLiteral("no"), 5000);

        video.setSource(QUrl::fromLocalFile(m_clip));
        QVERIFY(!video.scrubbing());
        QTRY_COMPARE_WITH_TIMEOUT(video.propertyForTest(QStringLiteral("hr-seek")),
                                  QStringLiteral("absolute"), 5000);
    }

    // A lost render surface takes the hold with it.
    void losingTheRenderSurfaceMidScrubRestoresTheSeekMode()
    {
        MpvVideoItem video;
        openForScrub(video, 30.0);
        video.beginScrub();
        QTRY_COMPARE_WITH_TIMEOUT(video.propertyForTest(QStringLiteral("hr-seek")),
                                  QStringLiteral("no"), 5000);

        QVERIFY(QMetaObject::invokeMethod(&video, "onRenderContextLost"));
        QVERIFY(!video.scrubbing());
        QTRY_COMPARE_WITH_TIMEOUT(video.propertyForTest(QStringLiteral("hr-seek")),
                                  QStringLiteral("absolute"), 5000);
    }

    // Scrubbing to the very end and letting go: the previews on the way are
    // not the film ending, and the film ends once it plays on from the
    // landing, exactly once.
    void scrubbingToTheEndEndsTheFilmOnlyWhenItPlaysOnFromTheLanding()
    {
        MpvVideoItem video;
        openForScrub(video, 60.0);
        QSignalSpy ended(&video, &MpvVideoItem::playbackEnded);
        video.beginScrub();
        video.previewScrub(200.0);
        QTest::qWait(500);
        QCOMPARE(ended.count(), 0);
        QVERIFY(video.finishScrub(video.duration()));
        QTRY_VERIFY_WITH_TIMEOUT(video.position() > video.duration() - 1.0, 5000);
        video.play();
        QTRY_COMPARE_WITH_TIMEOUT(ended.count(), 1, 10000);
        QTest::qWait(300);
        QCOMPARE(ended.count(), 1);
    }

    // The S key: the first subtitle the file lists, then Off.
    void theSubtitleKeyTogglesBetweenOffAndTheFirstTrack()
    {
        MpvVideoItem video;
        open(video);
        QTRY_COMPARE_WITH_TIMEOUT(video.subtitleTracks().size(), 2, 10000);
        QTRY_COMPARE(video.subtitleTrackId(), 0);

        video.toggleSubtitles();
        QTRY_COMPARE_WITH_TIMEOUT(video.subtitleTrackId(), 1, 5000);
        video.toggleSubtitles();
        QTRY_COMPARE_WITH_TIMEOUT(video.subtitleTrackId(), 0, 5000);
    }
};

int main(int argc, char *argv[])
{
    QGuiApplication app(argc, argv);
    // libmpv refuses to start under a locale whose decimal separator is not a
    // dot.
    std::setlocale(LC_NUMERIC, "C");
    PlayerTracksTest test;
    return QTest::qExec(&test, argc, argv);
}

#include "tst_player_tracks.moc"
