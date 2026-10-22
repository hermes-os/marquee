#pragma once

#include <QObject>
#include <QStringList>
#include <QVariant>

class SettingsStore final : public QObject
{
    Q_OBJECT

    /// UserSettings.swift:155-156 keeps the movie and TV folder lists apart;
    /// `libraryRoots` is the movies list and `tvShowsRoots` the TV list.
    Q_PROPERTY(QStringList libraryRoots
               READ libraryRoots
               WRITE setLibraryRoots
               NOTIFY libraryRootsChanged)
    Q_PROPERTY(QStringList tvShowsRoots
               READ tvShowsRoots
               WRITE setTvShowsRoots
               NOTIFY tvShowsRootsChanged)
    Q_PROPERTY(bool startFullscreen
               READ startFullscreen
               WRITE setStartFullscreen
               NOTIFY startFullscreenChanged)
    Q_PROPERTY(bool reduceMotion
               READ reduceMotion
               WRITE setReduceMotion
               NOTIFY reduceMotionChanged)
    Q_PROPERTY(bool leanBackMode
               READ leanBackMode
               WRITE setLeanBackMode
               NOTIFY leanBackModeChanged)
    Q_PROPERTY(bool interfaceSounds
               READ interfaceSounds
               WRITE setInterfaceSounds
               NOTIFY interfaceSoundsChanged)
    Q_PROPERTY(bool onlineMetadataEnabled
               READ onlineMetadataEnabled
               WRITE setOnlineMetadataEnabled
               NOTIFY onlineMetadataEnabledChanged)
    /// Whether a TMDB key exists (never the key itself). Without one the
    /// switch changes nothing and the note says so.
    Q_PROPERTY(bool tmdbKeyPresent
               READ tmdbKeyPresent
               NOTIFY tmdbKeyPresentChanged)
    /// What the Online Metadata row's text says, from the switch and the key.
    Q_PROPERTY(QString onlineMetadataNote
               READ onlineMetadataNote
               NOTIFY onlineMetadataNoteChanged)
    // The remaining released preferences, `Marquee/Models/UserSettings.swift:
    // 22-58`, with the defaults `:154-184` seeds a fresh install with.
    Q_PROPERTY(bool hardwareDecodingEnabled
               READ hardwareDecodingEnabled
               WRITE setHardwareDecodingEnabled
               NOTIFY hardwareDecodingEnabledChanged)
    Q_PROPERTY(bool autoPlayNextEpisode
               READ autoPlayNextEpisode
               WRITE setAutoPlayNextEpisode
               NOTIFY autoPlayNextEpisodeChanged)
    Q_PROPERTY(QString defaultSubtitleLanguage
               READ defaultSubtitleLanguage
               WRITE setDefaultSubtitleLanguage
               NOTIFY defaultSubtitleLanguageChanged)
    Q_PROPERTY(QString defaultAudioLanguage
               READ defaultAudioLanguage
               WRITE setDefaultAudioLanguage
               NOTIFY defaultAudioLanguageChanged)
    Q_PROPERTY(double subtitleScale
               READ subtitleScale
               WRITE setSubtitleScale
               NOTIFY subtitleScaleChanged)
    Q_PROPERTY(bool launchIdentEnabled
               READ launchIdentEnabled
               WRITE setLaunchIdentEnabled
               NOTIFY launchIdentEnabledChanged)
    // One of `soundPacks()` or empty for no pack chosen,
    // `Marquee/Services/AudioIdentityService.swift:31-48`.
    Q_PROPERTY(QString soundPack
               READ soundPack
               WRITE setSoundPack
               NOTIFY soundPackChanged)
    Q_PROPERTY(QStringList subtitleLanguages READ subtitleLanguages CONSTANT)
    Q_PROPERTY(QStringList audioLanguages READ audioLanguages CONSTANT)
    Q_PROPERTY(QStringList soundPacks READ soundPacks CONSTANT)
    Q_PROPERTY(QString storageError
               READ storageError
               NOTIFY storageErrorChanged)

public:
    explicit SettingsStore(QObject *parent = nullptr);

    [[nodiscard]] QStringList libraryRoots() const;
    void setLibraryRoots(const QStringList &roots);
    [[nodiscard]] QStringList tvShowsRoots() const;
    void setTvShowsRoots(const QStringList &roots);

    [[nodiscard]] bool startFullscreen() const;
    void setStartFullscreen(bool value);

    [[nodiscard]] bool reduceMotion() const;
    void setReduceMotion(bool value);

    [[nodiscard]] bool leanBackMode() const;
    void setLeanBackMode(bool value);

    [[nodiscard]] bool interfaceSounds() const;
    void setInterfaceSounds(bool value);

    [[nodiscard]] bool onlineMetadataEnabled() const;
    void setOnlineMetadataEnabled(bool value);
    [[nodiscard]] bool tmdbKeyPresent() const;
    [[nodiscard]] QString onlineMetadataNote() const;
    /// Looks for the key again (environment, then the key file), because the
    /// owner may have added it while the app was running. Only whether one
    /// exists is kept.
    Q_INVOKABLE void recheckTmdbKey();
    [[nodiscard]] bool hardwareDecodingEnabled() const;
    void setHardwareDecodingEnabled(bool value);
    [[nodiscard]] bool autoPlayNextEpisode() const;
    void setAutoPlayNextEpisode(bool value);
    [[nodiscard]] QString defaultSubtitleLanguage() const;
    void setDefaultSubtitleLanguage(const QString &value);
    [[nodiscard]] QString defaultAudioLanguage() const;
    void setDefaultAudioLanguage(const QString &value);
    [[nodiscard]] double subtitleScale() const;
    void setSubtitleScale(double value);
    [[nodiscard]] bool launchIdentEnabled() const;
    void setLaunchIdentEnabled(bool value);
    [[nodiscard]] QString soundPack() const;
    void setSoundPack(const QString &value);
    [[nodiscard]] static QStringList subtitleLanguages();
    [[nodiscard]] static QStringList audioLanguages();
    [[nodiscard]] static QStringList soundPacks();
    [[nodiscard]] QString storageError() const;

signals:
    void libraryRootsChanged();
    void tvShowsRootsChanged();
    void startFullscreenChanged();
    void reduceMotionChanged();
    void leanBackModeChanged();
    void interfaceSoundsChanged();
    void onlineMetadataEnabledChanged();
    void tmdbKeyPresentChanged();
    void onlineMetadataNoteChanged();
    void hardwareDecodingEnabledChanged();
    void autoPlayNextEpisodeChanged();
    void defaultSubtitleLanguageChanged();
    void defaultAudioLanguageChanged();
    void subtitleScaleChanged();
    void launchIdentEnabledChanged();
    void soundPackChanged();
    void storageErrorChanged();

private:
    void writeValue(const QString &key, const QVariant &value);
    void setStorageError(const QString &message);

    QStringList m_libraryRoots;
    QStringList m_tvShowsRoots;
    bool m_startFullscreen{true};
    bool m_reduceMotion{false};
    bool m_leanBackMode{true};
    bool m_interfaceSounds{true};
    bool m_onlineMetadataEnabled{true};
    bool m_tmdbKeyPresent{false};
    bool m_hardwareDecodingEnabled{true};
    bool m_autoPlayNextEpisode{true};
    QString m_defaultSubtitleLanguage{QStringLiteral("None")};
    QString m_defaultAudioLanguage{QStringLiteral("English")};
    double m_subtitleScale{1.35};
    bool m_launchIdentEnabled{true};
    QString m_soundPack;
    QString m_storageError;
};
