#include <QDir>
#include <QFile>
#include <QScopeGuard>
#include <QSignalSpy>
#include <QTemporaryDir>
#include <QtTest>

#include "app/AppPaths.hpp"
#include "metadata/MetadataSwitch.hpp"
#include "metadata/TmdbApiKey.hpp"
#include "settings/SettingsStore.hpp"

class MetadataSwitchTest final : public QObject
{
    Q_OBJECT

private slots:
    void cleanup()
    {
        AppPaths::clearRuntimeRoot();
        metadata_switch::setEnabled(true);
    }

    void theSwitchIsOnByDefaultAsReleased()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        SettingsStore fresh;
        QCOMPARE(fresh.onlineMetadataEnabled(), true);
        QCOMPARE(metadata_switch::enabled(), true);
    }

    void theSwitchPersistsAndReachesTheEnrichment()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        {
            SettingsStore settings;
            QSignalSpy changes(&metadata_switch::notifier(), &metadata_switch::Notifier::enabledChanged);
            settings.setOnlineMetadataEnabled(false);
            QCOMPARE(metadata_switch::enabled(), false);
            QCOMPARE(changes.size(), 1);
            QCOMPARE(changes.first().first().toBool(), false);
            settings.setOnlineMetadataEnabled(true);
            QCOMPARE(metadata_switch::enabled(), true);
            QCOMPARE(changes.size(), 2);
            settings.setOnlineMetadataEnabled(false);
        }
        SettingsStore reader;
        QCOMPARE(reader.onlineMetadataEnabled(), false);
        // Loading the setting also publishes it, so the worker starts right.
        QCOMPARE(metadata_switch::enabled(), false);
    }

    void withoutAKeyTheNoteSaysNoTmdbKeyInPlainWords()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        SettingsStore settings;
        QCOMPARE(settings.tmdbKeyPresent(), false);
        QVERIFY2(settings.onlineMetadataNote().startsWith(QStringLiteral("No TMDB key")),
                 qPrintable(settings.onlineMetadataNote()));
        QVERIFY(settings.onlineMetadataNote().contains(QStringLiteral("MARQUEE_TMDB_API_KEY")));
        QVERIFY(settings.onlineMetadataNote().contains(QStringLiteral("tmdb-api-key")));
        // A note never holds a key, and without one there is nothing to leak.
    }

    void aKeyFileAddedLaterIsFoundAndTheNoteSaysWhatTheSwitchDoes()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        AppPaths::ensureDirectories();
        SettingsStore settings;
        QCOMPARE(settings.tmdbKeyPresent(), false);
        QSignalSpy noteChanges(&settings, &SettingsStore::onlineMetadataNoteChanged);

        QFile keyFile(AppPaths::tmdbKeyFile());
        QVERIFY(keyFile.open(QIODevice::WriteOnly));
        keyFile.write("fake-key-0123456789abcdef\n");
        keyFile.close();
        settings.recheckTmdbKey();

        QCOMPARE(settings.tmdbKeyPresent(), true);
        QVERIFY(!noteChanges.isEmpty());
        const QString note = settings.onlineMetadataNote();
        QVERIFY2(note.contains(QStringLiteral("TMDB")) && !note.startsWith(QStringLiteral("No TMDB key")),
                 qPrintable(note));
        // The key is never in the text the screen shows.
        QVERIFY(!note.contains(QStringLiteral("fake-key-0123456789abcdef")));

        settings.setOnlineMetadataEnabled(false);
        QVERIFY2(note != settings.onlineMetadataNote() && settings.onlineMetadataNote().startsWith(QStringLiteral("Off")),
                 qPrintable(settings.onlineMetadataNote()));
        QVERIFY(!settings.onlineMetadataNote().contains(QStringLiteral("fake-key-0123456789abcdef")));
    }

    void aTestRuntimeNeverReadsTheEnvironmentKey()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        qputenv("MARQUEE_TMDB_API_KEY", "fake-environment-key");
        const auto restore = qScopeGuard([] { qunsetenv("MARQUEE_TMDB_API_KEY"); });
        QCOMPARE(tmdb_key::load(), QString());
        QCOMPARE(tmdb_key::provider()(), QString());
    }
};

QTEST_MAIN(MetadataSwitchTest)
#include "tst_metadata_switch.moc"
