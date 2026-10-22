#include "settings/SettingsStore.hpp"

#include <QSettings>
#include <QVariant>

#include <algorithm>

#include "app/AppPaths.hpp"
#include "metadata/MetadataSwitch.hpp"
#include "metadata/TmdbApiKey.hpp"

namespace
{
// `UserSettings.swift:194-236`.
const QStringList kSubtitleLanguages = {
    QStringLiteral("None"),       QStringLiteral("English"),   QStringLiteral("Spanish"),
    QStringLiteral("French"),     QStringLiteral("German"),    QStringLiteral("Italian"),
    QStringLiteral("Portuguese"), QStringLiteral("Japanese"),  QStringLiteral("Korean"),
    QStringLiteral("Chinese"),    QStringLiteral("Russian"),   QStringLiteral("Arabic"),
    QStringLiteral("Hindi"),      QStringLiteral("Dutch"),     QStringLiteral("Swedish"),
    QStringLiteral("Norwegian"),  QStringLiteral("Danish"),    QStringLiteral("Finnish"),
    QStringLiteral("Polish"),     QStringLiteral("Turkish")};
const QStringList kSoundPacks = {
    QStringLiteral("velvet"), QStringLiteral("hearth"), QStringLiteral("nocturne")};

[[nodiscard]] QString languageOrDefault(const QString &stored,
                                        const QStringList &options,
                                        const QString &fallback)
{
    return options.contains(stored) ? stored : fallback;
}

// `SettingsDetailView.swift:509`: the slider's range.
[[nodiscard]] double clampedSubtitleScale(double value)
{
    return std::clamp(value, 0.8, 2.2);
}

// `AudioIdentityService.swift:50-54`: an unknown pack reads as none chosen.
[[nodiscard]] QString soundPackOrNone(const QString &stored)
{
    return kSoundPacks.contains(stored) ? stored : QString();
}

[[nodiscard]] QStringList normalizedRoots(const QStringList &roots)
{
    QStringList result;
    for (const QString &root : roots) {
        const QString trimmed = root.trimmed();
        if (!trimmed.isEmpty() && !result.contains(trimmed)) {
            result.push_back(trimmed);
        }
    }
    return result;
}
}

SettingsStore::SettingsStore(QObject *parent)
    : QObject(parent)
{
    try {
        QSettings settings(AppPaths::settingsFile(), QSettings::IniFormat);
        m_libraryRoots = normalizedRoots(
            settings.value(QStringLiteral("library/roots"), QStringList{}).toStringList());
        m_tvShowsRoots = normalizedRoots(
            settings.value(QStringLiteral("library/tvShowsRoots"), QStringList{}).toStringList());
        m_startFullscreen = settings.value(
            QStringLiteral("ui/startFullscreen"), true).toBool();
        m_reduceMotion = settings.value(
            QStringLiteral("ui/reduceMotion"), false).toBool();
        m_leanBackMode = settings.value(
            QStringLiteral("ui/leanBackMode"), true).toBool();
        m_interfaceSounds = settings.value(
            QStringLiteral("audio/interfaceSounds"), true).toBool();
        // UserSettings.swift:182 seeds the switch on; here it is on for any
        // settings that never stored a choice, not only for a new install.
        m_onlineMetadataEnabled = settings.value(
            QStringLiteral("metadata/onlineEnabled"), true).toBool();
        m_hardwareDecodingEnabled = settings.value(
            QStringLiteral("playback/hardwareDecoding"), true).toBool();
        m_autoPlayNextEpisode = settings.value(
            QStringLiteral("playback/autoPlayNextEpisode"), true).toBool();
        m_defaultSubtitleLanguage = languageOrDefault(
            settings.value(QStringLiteral("playback/defaultSubtitleLanguage")).toString(),
            subtitleLanguages(), m_defaultSubtitleLanguage);
        m_defaultAudioLanguage = languageOrDefault(
            settings.value(QStringLiteral("playback/defaultAudioLanguage")).toString(),
            audioLanguages(), m_defaultAudioLanguage);
        m_subtitleScale = clampedSubtitleScale(
            settings.value(QStringLiteral("playback/subtitleScale"), m_subtitleScale).toDouble());
        m_launchIdentEnabled = settings.value(
            QStringLiteral("audio/launchIdent"), true).toBool();
        m_soundPack = soundPackOrNone(
            settings.value(QStringLiteral("audio/soundPack")).toString());
        if (settings.status() != QSettings::NoError) {
            setStorageError(QStringLiteral("Unable to read settings from disk"));
        }
    } catch (const std::exception &error) {
        setStorageError(QString::fromStdString(error.what()));
    }
    m_tmdbKeyPresent = !tmdb_key::load().isEmpty();
    metadata_switch::setEnabled(m_onlineMetadataEnabled);
}

QStringList SettingsStore::libraryRoots() const
{
    return m_libraryRoots;
}

QString SettingsStore::storageError() const
{
    return m_storageError;
}

void SettingsStore::setLibraryRoots(const QStringList &roots)
{
    const QStringList next = normalizedRoots(roots);
    if (m_libraryRoots == next) {
        return;
    }
    m_libraryRoots = next;
    writeValue(QStringLiteral("library/roots"), m_libraryRoots);
    emit libraryRootsChanged();
}

QStringList SettingsStore::tvShowsRoots() const
{
    return m_tvShowsRoots;
}

void SettingsStore::setTvShowsRoots(const QStringList &roots)
{
    const QStringList next = normalizedRoots(roots);
    if (m_tvShowsRoots == next) {
        return;
    }
    m_tvShowsRoots = next;
    writeValue(QStringLiteral("library/tvShowsRoots"), m_tvShowsRoots);
    emit tvShowsRootsChanged();
}

bool SettingsStore::startFullscreen() const
{
    return m_startFullscreen;
}

void SettingsStore::setStartFullscreen(bool value)
{
    if (m_startFullscreen == value) {
        return;
    }
    m_startFullscreen = value;
    writeValue(QStringLiteral("ui/startFullscreen"), value);
    emit startFullscreenChanged();
}

bool SettingsStore::reduceMotion() const
{
    return m_reduceMotion;
}

void SettingsStore::setReduceMotion(bool value)
{
    if (m_reduceMotion == value) {
        return;
    }
    m_reduceMotion = value;
    writeValue(QStringLiteral("ui/reduceMotion"), value);
    emit reduceMotionChanged();
}

bool SettingsStore::leanBackMode() const
{
    return m_leanBackMode;
}

void SettingsStore::setLeanBackMode(bool value)
{
    if (m_leanBackMode == value) {
        return;
    }
    m_leanBackMode = value;
    writeValue(QStringLiteral("ui/leanBackMode"), value);
    emit leanBackModeChanged();
}

bool SettingsStore::interfaceSounds() const
{
    return m_interfaceSounds;
}

void SettingsStore::setInterfaceSounds(bool value)
{
    if (m_interfaceSounds == value) {
        return;
    }
    m_interfaceSounds = value;
    writeValue(QStringLiteral("audio/interfaceSounds"), value);
    emit interfaceSoundsChanged();
}

bool SettingsStore::onlineMetadataEnabled() const
{
    return m_onlineMetadataEnabled;
}

void SettingsStore::setOnlineMetadataEnabled(bool value)
{
    if (m_onlineMetadataEnabled == value) {
        return;
    }
    m_onlineMetadataEnabled = value;
    writeValue(QStringLiteral("metadata/onlineEnabled"), value);
    // Publishing first lets a run in progress see the change before its next
    // request; turning it on starts a run that fills in what is missing.
    metadata_switch::setEnabled(value);
    emit onlineMetadataEnabledChanged();
    emit onlineMetadataNoteChanged();
    if (value) {
        recheckTmdbKey();
    }
}

bool SettingsStore::tmdbKeyPresent() const
{
    return m_tmdbKeyPresent;
}

QString SettingsStore::onlineMetadataNote() const
{
    if (!m_onlineMetadataEnabled) {
        return QStringLiteral("Off. Marquee shows only what is in your folders and sends "
                              "nothing to TMDB.");
    }
    if (!m_tmdbKeyPresent) {
        return QStringLiteral("No TMDB key, so nothing is fetched. Put a TMDB v3 API key in "
                              "the MARQUEE_TMDB_API_KEY environment variable, or in a file "
                              "named tmdb-api-key next to marquee.ini.");
    }
    return QStringLiteral("After each scan, fetch TMDB details (overview, cast, rating, "
                          "genres) and fill missing artwork into the app cache. Artwork in "
                          "your folders always wins.");
}

void SettingsStore::recheckTmdbKey()
{
    const bool present = !tmdb_key::load().isEmpty();
    if (present == m_tmdbKeyPresent) {
        return;
    }
    m_tmdbKeyPresent = present;
    emit tmdbKeyPresentChanged();
    emit onlineMetadataNoteChanged();
}

void SettingsStore::setStorageError(const QString &message)
{
    if (m_storageError == message) {
        return;
    }
    m_storageError = message;
    emit storageErrorChanged();
}

void SettingsStore::writeValue(const QString &key, const QVariant &value)
{
    try {
        QSettings settings(AppPaths::settingsFile(), QSettings::IniFormat);
        settings.setValue(key, value);
        settings.sync();
        if (settings.status() == QSettings::NoError) {
            setStorageError({});
        } else {
            setStorageError(QStringLiteral("Unable to persist settings"));
        }
    } catch (const std::exception &error) {
        setStorageError(QString::fromStdString(error.what()));
    }
}

bool SettingsStore::hardwareDecodingEnabled() const
{
    return m_hardwareDecodingEnabled;
}

void SettingsStore::setHardwareDecodingEnabled(bool value)
{
    if (m_hardwareDecodingEnabled == value) {
        return;
    }
    m_hardwareDecodingEnabled = value;
    writeValue(QStringLiteral("playback/hardwareDecoding"), value);
    emit hardwareDecodingEnabledChanged();
}

bool SettingsStore::autoPlayNextEpisode() const
{
    return m_autoPlayNextEpisode;
}

void SettingsStore::setAutoPlayNextEpisode(bool value)
{
    if (m_autoPlayNextEpisode == value) {
        return;
    }
    m_autoPlayNextEpisode = value;
    writeValue(QStringLiteral("playback/autoPlayNextEpisode"), value);
    emit autoPlayNextEpisodeChanged();
}

QString SettingsStore::defaultSubtitleLanguage() const
{
    return m_defaultSubtitleLanguage;
}

void SettingsStore::setDefaultSubtitleLanguage(const QString &value)
{
    const QString next = languageOrDefault(value, subtitleLanguages(), m_defaultSubtitleLanguage);
    if (m_defaultSubtitleLanguage == next) {
        return;
    }
    m_defaultSubtitleLanguage = next;
    writeValue(QStringLiteral("playback/defaultSubtitleLanguage"), next);
    emit defaultSubtitleLanguageChanged();
}

QString SettingsStore::defaultAudioLanguage() const
{
    return m_defaultAudioLanguage;
}

void SettingsStore::setDefaultAudioLanguage(const QString &value)
{
    const QString next = languageOrDefault(value, audioLanguages(), m_defaultAudioLanguage);
    if (m_defaultAudioLanguage == next) {
        return;
    }
    m_defaultAudioLanguage = next;
    writeValue(QStringLiteral("playback/defaultAudioLanguage"), next);
    emit defaultAudioLanguageChanged();
}

double SettingsStore::subtitleScale() const
{
    return m_subtitleScale;
}

void SettingsStore::setSubtitleScale(double value)
{
    const double next = clampedSubtitleScale(value);
    if (qFuzzyCompare(m_subtitleScale, next)) {
        return;
    }
    m_subtitleScale = next;
    writeValue(QStringLiteral("playback/subtitleScale"), next);
    emit subtitleScaleChanged();
}

bool SettingsStore::launchIdentEnabled() const
{
    return m_launchIdentEnabled;
}

void SettingsStore::setLaunchIdentEnabled(bool value)
{
    if (m_launchIdentEnabled == value) {
        return;
    }
    m_launchIdentEnabled = value;
    writeValue(QStringLiteral("audio/launchIdent"), value);
    emit launchIdentEnabledChanged();
}

QString SettingsStore::soundPack() const
{
    return m_soundPack;
}

void SettingsStore::setSoundPack(const QString &value)
{
    const QString next = soundPackOrNone(value);
    if (m_soundPack == next) {
        return;
    }
    m_soundPack = next;
    writeValue(QStringLiteral("audio/soundPack"), next);
    emit soundPackChanged();
}

QStringList SettingsStore::subtitleLanguages()
{
    return kSubtitleLanguages;
}

QStringList SettingsStore::audioLanguages()
{
    // `UserSettings.swift:217-236`: the subtitle list without "None".
    return kSubtitleLanguages.mid(1);
}

QStringList SettingsStore::soundPacks()
{
    return kSoundPacks;
}
