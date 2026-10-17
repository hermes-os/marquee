#include "playback/TrackSelection.hpp"

#include <algorithm>

#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLocale>
#include <QMap>

namespace {

// `SubtitleDiscovery.swift:171-218` and `:220-273`: the released app's tables
// of ISO 639-1 and 639-2 codes. Both resolve to the names the Settings
// pickers use (`UserSettings.swift:194-236`), which is what a saved language
// is matched against.
const QMap<QString, QString> &languageTable()
{
    static const QMap<QString, QString> table = [] {
        QMap<QString, QString> names;
        const struct {
            const char *code;
            const char *name;
        } entries[] = {
            {"en", "English"},     {"es", "Spanish"},    {"fr", "French"},
            {"de", "German"},      {"it", "Italian"},    {"pt", "Portuguese"},
            {"ru", "Russian"},     {"ja", "Japanese"},   {"ko", "Korean"},
            {"zh", "Chinese"},     {"ar", "Arabic"},     {"hi", "Hindi"},
            {"nl", "Dutch"},       {"sv", "Swedish"},    {"no", "Norwegian"},
            {"da", "Danish"},      {"fi", "Finnish"},    {"pl", "Polish"},
            {"cs", "Czech"},       {"hu", "Hungarian"},  {"ro", "Romanian"},
            {"tr", "Turkish"},     {"el", "Greek"},      {"he", "Hebrew"},
            {"th", "Thai"},        {"vi", "Vietnamese"}, {"id", "Indonesian"},
            {"ms", "Malay"},       {"uk", "Ukrainian"},  {"bg", "Bulgarian"},
            {"hr", "Croatian"},    {"sk", "Slovak"},     {"sl", "Slovenian"},
            {"sr", "Serbian"},     {"lt", "Lithuanian"}, {"lv", "Latvian"},
            {"et", "Estonian"},
            {"eng", "English"},    {"spa", "Spanish"},   {"fre", "French"},
            {"fra", "French"},     {"ger", "German"},    {"deu", "German"},
            {"ita", "Italian"},    {"por", "Portuguese"},{"rus", "Russian"},
            {"jpn", "Japanese"},   {"kor", "Korean"},    {"chi", "Chinese"},
            {"zho", "Chinese"},    {"ara", "Arabic"},    {"hin", "Hindi"},
            {"dut", "Dutch"},      {"nld", "Dutch"},     {"swe", "Swedish"},
            {"nor", "Norwegian"},  {"dan", "Danish"},    {"fin", "Finnish"},
            {"pol", "Polish"},     {"cze", "Czech"},     {"ces", "Czech"},
            {"hun", "Hungarian"},  {"rum", "Romanian"},  {"ron", "Romanian"},
            {"tur", "Turkish"},    {"gre", "Greek"},     {"ell", "Greek"},
            {"heb", "Hebrew"},     {"tha", "Thai"},      {"vie", "Vietnamese"},
            {"ind", "Indonesian"}, {"may", "Malay"},     {"msa", "Malay"},
            {"ukr", "Ukrainian"},  {"bul", "Bulgarian"}, {"hrv", "Croatian"},
            {"slo", "Slovak"},     {"slk", "Slovak"},    {"slv", "Slovenian"},
            {"srp", "Serbian"},    {"lit", "Lithuanian"},{"lav", "Latvian"},
            {"est", "Estonian"},
        };
        for (const auto &entry : entries) {
            names.insert(QString::fromLatin1(entry.code), QString::fromLatin1(entry.name));
        }
        return names;
    }();
    return table;
}

QString primaryTag(const QString &tag)
{
    QString primary = tag.trimmed().toLower();
    for (qsizetype index = 0; index < primary.size(); ++index) {
        if (primary.at(index) == QLatin1Char('-') || primary.at(index) == QLatin1Char('_')) {
            primary.truncate(index);
            break;
        }
    }
    return primary;
}

QString sidecarFormat(const MediaTrack &track)
{
    return QFileInfo(track.externalFilename).suffix().toUpper();
}

bool namesLanguage(const MediaTrack &track, const QString &language)
{
    // The released rule is a case-insensitive "contains" on the track's
    // display name (AVPlayerService.swift:376, :388). The only display names
    // that rule was written against lead with the language's name
    // (AVPlayerService.swift:253-257, :331-335) and fall back to the stream's
    // own name only when the tag names no language; the menu label of this
    // build leads with the file's title instead, so matching it alone would
    // let a title such as "Commentary" hide an `eng` tag. The language's name
    // therefore stands in whenever the tag has one.
    const QString name = TrackSelection::languageName(track.language);
    const QString text = name.isEmpty() ? TrackSelection::label(track) : name;
    return text.contains(language, Qt::CaseInsensitive);
}

}

namespace TrackSelection {

QList<MediaTrack> parseTrackList(const QByteArray &json)
{
    QList<MediaTrack> tracks;
    const QJsonDocument document = QJsonDocument::fromJson(json);
    if (!document.isArray()) {
        return tracks;
    }

    for (const QJsonValue &value : document.array()) {
        const QJsonObject object = value.toObject();
        const QString type = object.value(QStringLiteral("type")).toString();
        MediaTrack track;
        if (type == QStringLiteral("audio")) {
            track.kind = MediaTrack::Kind::Audio;
        } else if (type == QStringLiteral("sub")) {
            track.kind = MediaTrack::Kind::Subtitle;
        } else {
            continue;
        }
        track.id = object.value(QStringLiteral("id")).toInt();
        if (track.id <= 0) {
            continue;
        }
        track.language = object.value(QStringLiteral("lang")).toString();
        track.title = object.value(QStringLiteral("title")).toString();
        track.codec = object.value(QStringLiteral("codec")).toString();
        track.isDefault = object.value(QStringLiteral("default")).toBool();
        track.forced = object.value(QStringLiteral("forced")).toBool();
        track.external = object.value(QStringLiteral("external")).toBool();
        track.externalFilename = object.value(QStringLiteral("external-filename")).toString();
        tracks.append(track);
    }
    return tracks;
}

QString releasedLanguageName(const QString &code)
{
    return languageTable().value(code.trimmed().toLower());
}

QString languageName(const QString &tag)
{
    const QString primary = primaryTag(tag);
    if (primary.isEmpty()) {
        return {};
    }
    const QString known = releasedLanguageName(primary);
    if (!known.isEmpty()) {
        return known;
    }
    // The released app asks Foundation for a name, which knows every ISO 639
    // code; Qt's table is the closest thing this build has to that.
    const QLocale::Language language =
        QLocale::codeToLanguage(primary, QLocale::AnyLanguageCode);
    if (language == QLocale::AnyLanguage || language == QLocale::C) {
        return {};
    }
    return QLocale::languageToString(language);
}

QString label(const MediaTrack &track)
{
    if (track.external && track.kind == MediaTrack::Kind::Subtitle) {
        // `SubtitleDiscovery.swift:156-161`: "<Language> (<FORMAT>)", with
        // "External" standing in when the file names no known language.
        const QString name = languageName(track.language);
        const QString format = sidecarFormat(track);
        const QString base = name.isEmpty() ? QStringLiteral("External") : name;
        return format.isEmpty() ? base : QStringLiteral("%1 (%2)").arg(base, format);
    }

    // `MPVPlayerService.swift:2753-2766`.
    QString text;
    if (!track.title.isEmpty()) {
        text = track.title;
    } else if (!track.language.isEmpty()) {
        const QString name = languageName(track.language);
        text = name.isEmpty() ? track.language : name;
    } else {
        text = QStringLiteral("Track %1").arg(track.id);
    }
    if (!track.codec.isEmpty()) {
        text += QStringLiteral(" (%1)").arg(track.codec);
    }
    return text;
}

TrackChoice choose(const QList<MediaTrack> &audioTracks,
                   const QList<MediaTrack> &subtitleTracks,
                   const QString &audioLanguage,
                   const QString &subtitleLanguage)
{
    TrackChoice choice;

    // `AVPlayerService.swift:371-381`.
    if (!subtitleLanguage.isEmpty() && subtitleLanguage != QStringLiteral("None")) {
        const auto match = std::find_if(
            subtitleTracks.cbegin(), subtitleTracks.cend(),
            [&](const MediaTrack &track) { return namesLanguage(track, subtitleLanguage); });
        if (match != subtitleTracks.cend()) {
            choice.subtitleId = match->id;
        }
    }

    // `AVPlayerService.swift:383-392`.
    if (!audioLanguage.isEmpty()) {
        const auto match = std::find_if(
            audioTracks.cbegin(), audioTracks.cend(),
            [&](const MediaTrack &track) { return namesLanguage(track, audioLanguage); });
        if (match != audioTracks.cend()) {
            choice.audioId = match->id;
        }
    }
    return choice;
}

double subtitleScale(double saved, bool leanBack)
{
    return std::clamp(saved, 0.8, 2.2) * (leanBack ? 1.15 : 1.0);
}

QVariantMap toVariant(const MediaTrack &track)
{
    return {
        {QStringLiteral("id"), track.id},
        {QStringLiteral("language"), track.language},
        {QStringLiteral("title"), track.title},
        {QStringLiteral("codec"), track.codec},
        {QStringLiteral("isDefault"), track.isDefault},
        {QStringLiteral("forced"), track.forced},
        {QStringLiteral("external"), track.external},
        {QStringLiteral("label"), label(track)},
    };
}

}
