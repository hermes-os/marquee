#include <QTemporaryDir>
#include <QtTest>

#include <QDir>
#include <QFile>
#include <QFileDevice>

#include "app/AppPaths.hpp"
#include "settings/SettingsStore.hpp"

class SettingsStoreTest final : public QObject
{
    Q_OBJECT

private slots:
    void persistsValuesInIsolatedRoot()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());

        {
            SettingsStore writer;
            writer.setLibraryRoots({"   /tmp/videos  ", "/tmp/music", "/tmp/videos"});
            QCOMPARE(writer.storageError(), QString{});
            QCOMPARE(writer.libraryRoots(), QStringList({"/tmp/videos", "/tmp/music"}));
        }

        SettingsStore reader;
        QCOMPARE(reader.storageError(), QString{});
        QCOMPARE(reader.libraryRoots(), QStringList({"/tmp/videos", "/tmp/music"}));

        AppPaths::clearRuntimeRoot();
    }

    // `UserSettings.swift:154-184` seeds the released defaults; the store
    // starts from the same ones and rejects values outside the released
    // option lists and slider range rather than storing them.
    void seedsReleasedDefaultsAndClampsPlaybackAndSoundValues()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());

        {
            SettingsStore fresh;
            QCOMPARE(fresh.hardwareDecodingEnabled(), true);
            QCOMPARE(fresh.autoPlayNextEpisode(), true);
            QCOMPARE(fresh.defaultSubtitleLanguage(), QStringLiteral("None"));
            QCOMPARE(fresh.defaultAudioLanguage(), QStringLiteral("English"));
            QCOMPARE(fresh.subtitleScale(), 1.35);
            QCOMPARE(fresh.launchIdentEnabled(), true);
            QCOMPARE(fresh.soundPack(), QString{});
            QCOMPARE(SettingsStore::subtitleLanguages().size(), 20);
            QCOMPARE(SettingsStore::audioLanguages().size(), 19);
            QVERIFY(!SettingsStore::audioLanguages().contains(QStringLiteral("None")));
            QCOMPARE(SettingsStore::soundPacks(),
                     (QStringList{QStringLiteral("velvet"), QStringLiteral("hearth"),
                                  QStringLiteral("nocturne")}));

            fresh.setHardwareDecodingEnabled(false);
            fresh.setDefaultSubtitleLanguage(QStringLiteral("French"));
            fresh.setDefaultSubtitleLanguage(QStringLiteral("Klingon"));
            fresh.setDefaultAudioLanguage(QStringLiteral("None"));
            fresh.setSubtitleScale(3.0);
            fresh.setSoundPack(QStringLiteral("hearth"));
            fresh.setSoundPack(QStringLiteral("brass"));
            QCOMPARE(fresh.storageError(), QString{});
        }

        SettingsStore reader;
        QCOMPARE(reader.hardwareDecodingEnabled(), false);
        QCOMPARE(reader.defaultSubtitleLanguage(), QStringLiteral("French"));
        QCOMPARE(reader.defaultAudioLanguage(), QStringLiteral("English"));
        QCOMPARE(reader.subtitleScale(), 2.2);
        QCOMPARE(reader.soundPack(), QString{});

        AppPaths::clearRuntimeRoot();
    }

    void reportsWriteFailuresWhenSettingsAreReadOnly()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        AppPaths::ensureDirectories();

        const QString configDirectory = AppPaths::configDirectory();
        QVERIFY(QFile::setPermissions(
            configDirectory,
            QFileDevice::ReadOwner | QFileDevice::ExeOwner));

        SettingsStore store;
        QCOMPARE(store.storageError(), QString{});

        store.setStartFullscreen(false);
        QVERIFY(!store.storageError().isEmpty());

        AppPaths::clearRuntimeRoot();
    }
};

QTEST_MAIN(SettingsStoreTest)
#include "tst_settings_store.moc"
