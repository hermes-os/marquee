#include <QTest>

#include "playback/TrackSelection.hpp"

namespace
{
[[nodiscard]] MediaTrack audio(int id, const QString &language, const QString &title = {},
                               const QString &codec = {})
{
    MediaTrack track;
    track.kind = MediaTrack::Kind::Audio;
    track.id = id;
    track.language = language;
    track.title = title;
    track.codec = codec;
    return track;
}

[[nodiscard]] MediaTrack subtitle(int id, const QString &language, const QString &title = {},
                                  const QString &codec = {})
{
    MediaTrack track = audio(id, language, title, codec);
    track.kind = MediaTrack::Kind::Subtitle;
    return track;
}

[[nodiscard]] MediaTrack sidecar(int id, const QString &language, const QString &filename)
{
    MediaTrack track = subtitle(id, language);
    track.external = true;
    track.externalFilename = filename;
    return track;
}
}

class TrackSelectionTest final : public QObject
{
    Q_OBJECT

private slots:
    // AVPlayerService.swift:371-381: "None" is Off, even with a matching track.
    void noneSubtitleLanguageLeavesSubtitlesOff()
    {
        const auto choice = TrackSelection::choose({}, {subtitle(1, "eng"), subtitle(2, "fra")},
                                                   "English", "None");
        QCOMPARE(choice.subtitleId, 0);
    }

    void subtitleLanguageTurnsOnTheFirstTrackNamingIt()
    {
        const QList<MediaTrack> tracks{subtitle(1, "spa"), subtitle(2, "fra"),
                                       subtitle(3, "fra", "French (SDH)")};
        QCOMPARE(TrackSelection::choose({}, tracks, "English", "French").subtitleId, 2);
        QCOMPARE(TrackSelection::choose({}, tracks, "English", "Spanish").subtitleId, 1);
    }

    // AVPlayerService.swift:376-378: no match selects nothing, so subtitles
    // stay Off rather than falling back to some other language.
    void subtitleLanguageWithNoMatchLeavesSubtitlesOff()
    {
        const QList<MediaTrack> tracks{subtitle(1, "spa"), subtitle(2, "fra")};
        QCOMPARE(TrackSelection::choose({}, tracks, "English", "Japanese").subtitleId, 0);
        QCOMPARE(TrackSelection::choose({}, {}, "English", "English").subtitleId, 0);
    }

    // AVPlayerService.swift:376: a case-insensitive match.
    void languageMatchIgnoresCase()
    {
        QCOMPARE(TrackSelection::choose({}, {subtitle(4, "ENG")}, "English", "english").subtitleId,
                 4);
        QCOMPARE(TrackSelection::choose({audio(2, "SPA")}, {}, "SPANISH", "None").audioId.value_or(-1),
                 2);
    }

    void audioLanguagePicksTheFirstTrackNamingIt()
    {
        const QList<MediaTrack> tracks{audio(1, "jpn"), audio(2, "eng"), audio(3, "eng")};
        QCOMPARE(TrackSelection::choose(tracks, {}, "English", "None").audioId.value_or(-1), 2);
        QCOMPARE(TrackSelection::choose(tracks, {}, "Japanese", "None").audioId.value_or(-1), 1);
    }

    // AVPlayerService.swift:386-391: no match leaves the player's own choice.
    void audioLanguageWithNoMatchLeavesThePlayersChoice()
    {
        const QList<MediaTrack> tracks{audio(1, "jpn"), audio(2, "fra")};
        QVERIFY(!TrackSelection::choose(tracks, {}, "English", "None").audioId.has_value());
        QVERIFY(!TrackSelection::choose({}, {}, "English", "None").audioId.has_value());
        QVERIFY(!TrackSelection::choose(tracks, {}, QString(), "None").audioId.has_value());
    }

    // The released rule reads the track's name, not the file's flags: the
    // default and forced flags decide nothing when a file opens.
    void defaultAndForcedFlagsDoNotChangeTheChoice()
    {
        MediaTrack flaggedAudio = audio(1, "jpn");
        flaggedAudio.isDefault = true;
        MediaTrack flaggedSubtitle = subtitle(1, "eng");
        flaggedSubtitle.forced = true;
        flaggedSubtitle.isDefault = true;

        const auto choice = TrackSelection::choose({flaggedAudio, audio(2, "eng")},
                                                   {flaggedSubtitle, subtitle(2, "fra")},
                                                   "English", "French");
        QCOMPARE(choice.audioId.value_or(-1), 2);
        QCOMPARE(choice.subtitleId, 2);

        const auto off = TrackSelection::choose({}, {flaggedSubtitle}, "English", "None");
        QCOMPARE(off.subtitleId, 0);
    }

    // The language's name decides, not the file's title for the track.
    void aTitleDoesNotHideTheLanguageTag()
    {
        const auto choice = TrackSelection::choose(
            {audio(1, "jpn"), audio(2, "eng", "Director's Commentary")},
            {subtitle(1, "eng", "Commentary")}, "English", "English");
        QCOMPARE(choice.audioId.value_or(-1), 2);
        QCOMPARE(choice.subtitleId, 1);
    }

    // A track with no language tag can still be named by its title.
    void anUntaggedTrackMatchesOnItsTitle()
    {
        const auto choice = TrackSelection::choose({audio(1, QString(), "English 5.1")}, {},
                                                   "English", "None");
        QCOMPARE(choice.audioId.value_or(-1), 1);
        QVERIFY(!TrackSelection::choose({audio(1, QString())}, {}, "English", "None")
                     .audioId.has_value());
    }

    void sidecarSubtitleMatchesByTheLanguageInItsName()
    {
        const QList<MediaTrack> tracks{sidecar(1, "fr", "/m/Film.fr.srt"),
                                       sidecar(2, "en", "/m/Film.en.srt")};
        QCOMPARE(TrackSelection::choose({}, tracks, "English", "English").subtitleId, 2);
    }

    // MPVPlayerService.swift:2753-2766.
    void streamLabelsFollowTheReleasedMenu()
    {
        QCOMPARE(TrackSelection::label(audio(1, "eng", "Surround", "ac3")),
                 QStringLiteral("Surround (ac3)"));
        QCOMPARE(TrackSelection::label(audio(1, "spa", {}, "aac")),
                 QStringLiteral("Spanish (aac)"));
        QCOMPARE(TrackSelection::label(audio(2, "fre")), QStringLiteral("French"));
        QCOMPARE(TrackSelection::label(audio(2, "pt-BR", {}, "eac3")),
                 QStringLiteral("Portuguese (eac3)"));
        // A tag that names no language is shown as it is.
        QCOMPARE(TrackSelection::label(audio(3, "zzz", {}, "dts")),
                 QStringLiteral("zzz (dts)"));
        // Untitled and unknown language.
        QCOMPARE(TrackSelection::label(audio(4, QString(), {}, "opus")),
                 QStringLiteral("Track 4 (opus)"));
        QCOMPARE(TrackSelection::label(audio(5, QString())), QStringLiteral("Track 5"));
        QCOMPARE(TrackSelection::label(subtitle(2, "fra", {}, "subrip")),
                 QStringLiteral("French (subrip)"));
    }

    // SubtitleDiscovery.swift:156-161.
    void sidecarLabelsNameLanguageAndFormat()
    {
        QCOMPARE(TrackSelection::label(sidecar(1, "en", "/m/Film.en.srt")),
                 QStringLiteral("English (SRT)"));
        QCOMPARE(TrackSelection::label(sidecar(2, "fra", "/m/Subs/Film.fra.ass")),
                 QStringLiteral("French (ASS)"));
        QCOMPARE(TrackSelection::label(sidecar(3, QString(), "/m/Film.srt")),
                 QStringLiteral("External (SRT)"));
    }

    // SubtitleOverlayView.swift:49-52, :56-58 and SettingsDetailView.swift:529.
    void subtitleSizeIsTheSavedScaleClampedAndScaledForLeanBack()
    {
        QCOMPARE(TrackSelection::subtitleScale(1.35, false), 1.35);
        QCOMPARE(TrackSelection::subtitleScale(0.1, false), 0.8);
        QCOMPARE(TrackSelection::subtitleScale(9.0, false), 2.2);
        QVERIFY(qAbs(TrackSelection::subtitleScale(1.0, true) - 1.15) < 1e-9);
        QVERIFY(qAbs(TrackSelection::subtitleScale(2.2, true) - 2.53) < 1e-9);
    }

    void parsesTheTrackListLibmpvReports()
    {
        const QByteArray json = R"([
            {"id":1,"type":"video","codec":"h264"},
            {"id":1,"type":"audio","lang":"eng","codec":"aac","default":true},
            {"id":2,"type":"audio","lang":"spa","title":"Doblaje","codec":"ac3"},
            {"id":1,"type":"sub","lang":"fra","codec":"subrip","forced":true},
            {"id":2,"type":"sub","external":true,"external-filename":"/m/Film.en.srt","codec":"subrip"}
        ])";
        const QList<MediaTrack> tracks = TrackSelection::parseTrackList(json);
        QCOMPARE(tracks.size(), 4);
        QCOMPARE(tracks[0].kind, MediaTrack::Kind::Audio);
        QCOMPARE(tracks[0].language, QStringLiteral("eng"));
        QVERIFY(tracks[0].isDefault);
        QCOMPARE(tracks[1].title, QStringLiteral("Doblaje"));
        QCOMPARE(tracks[2].kind, MediaTrack::Kind::Subtitle);
        QVERIFY(tracks[2].forced);
        QVERIFY(tracks[3].external);
        QCOMPARE(tracks[3].externalFilename, QStringLiteral("/m/Film.en.srt"));

        QVERIFY(TrackSelection::parseTrackList("").isEmpty());
        QVERIFY(TrackSelection::parseTrackList("not json").isEmpty());
        QVERIFY(TrackSelection::parseTrackList("{}").isEmpty());
    }
};

QTEST_APPLESS_MAIN(TrackSelectionTest)

#include "tst_track_selection.moc"
