#include <clocale>

#include <QAbstractItemModel>
#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QGuiApplication>
#include <QFileInfo>
#include <QIODevice>
#include <QList>
#include <QScopeGuard>
#include <QSemaphore>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickItem>
#include <QQuickWindow>
#include <QSignalSpy>
#include <QSqlQuery>
#include <QStringList>
#include <QTemporaryDir>
#include <QTimer>
#include <QVariant>
#include <QVariantList>
#include <QtTest>

#include <stdexcept>

#include "app/AppPaths.hpp"
#include "app/ApplicationController.hpp"
#include "catalog/CatalogDatabase.hpp"
#include "catalog/CatalogStore.hpp"
#include "catalog/LibraryScanner.hpp"
#include "models/LibraryModel.hpp"
#include "navigation/NavigationController.hpp"
#include "playback/PlayerController.hpp"
#include "profiles/ProfileStore.hpp"

namespace
{
constexpr auto kFilmRelativePath = "Arrival (2016)/Arrival (2016).mkv";
constexpr auto kProfile = "profile-main";
// Visible to the seeded Kids profile as well as to Main (a "Kids" folder).
constexpr auto kKidsFilmRelativePath = "Kids/Wonder (2017).mkv";

/// The seeded adult profile's identity in the runtime root, created on first
/// use and read back unchanged by every controller started there afterwards.
[[nodiscard]] QString mainProfileId()
{
    AppPaths::ensureDirectories();
    const ProfileStore profiles(AppPaths::profilesFile());
    return profiles.profiles().at(0).id;
}

[[nodiscard]] QString profileNamed(ApplicationController &controller, const QString &name)
{
    for (const Profile &profile : controller.profiles()->profiles()) {
        if (profile.name == name) {
            return profile.id;
        }
    }
    return {};
}

/// Chooses a profile and waits out the picker's exit fade, as a viewer does.
[[nodiscard]] bool chooseProfileNamed(ApplicationController &controller, const QString &name)
{
    if (!controller.chooseProfile(profileNamed(controller, name))) {
        return false;
    }
    return QTest::qWaitFor([&] { return !controller.profileExitInFlight(); });
}

/// Chooses the seeded adult profile, the way a viewer leaves the picker, so
/// the controller has someone to save progress for.
[[nodiscard]] bool chooseMainProfile(ApplicationController &controller)
{
    return controller.chooseProfile(controller.profiles()->profiles().at(0).id);
}

[[nodiscard]] bool writeMediaFile(const QString &root, const QString &relativePath)
{
    const QFileInfo target(QDir(root).filePath(relativePath));
    if (!QDir().mkpath(target.absolutePath())) {
        return false;
    }

    QFile file(target.absoluteFilePath());
    if (!file.open(QIODevice::WriteOnly)) {
        return false;
    }
    return file.write(QByteArrayLiteral("media")) == 5;
}

[[nodiscard]] QVector<MediaItem> refresh(CatalogStore &store,
                                         const QString &libraryPath,
                                         const QString &profileId = QLatin1String(kProfile))
{
    const QVector<LibraryRoot> roots = store.registerRoots({libraryPath});
    for (const LibraryRoot &root : roots) {
        store.applyScan(root, LibraryScanner::scan(root));
    }
    return store.projection(roots, profileId);
}

/// The stored row as position, duration, and completion, or an empty list when
/// the catalog holds no progress for that title.
[[nodiscard]] QVariantList storedProgress(const QString &catalogPath,
                                          const QString &mediaId,
                                          const QString &profileId)
{
    CatalogDatabase catalog(catalogPath);
    QSqlQuery query(catalog.connection());
    if (!query.prepare(QStringLiteral("SELECT position_ms, duration_ms, completed "
                                      "FROM watch_progress "
                                      "WHERE profile_id = ? AND media_id = ?"))) {
        return {};
    }
    query.addBindValue(profileId);
    query.addBindValue(mediaId);
    if (!query.exec() || !query.next()) {
        return {};
    }
    return {query.value(0), query.value(1), query.value(2)};
}

[[nodiscard]] qint64 durablePosition(const QString &profileId, const QString &mediaId)
{
    const QVariantList row = storedProgress(AppPaths::catalogFile(), mediaId, profileId);
    return row.size() == 3 ? row.at(0).toLongLong() : qint64{-1};
}

[[nodiscard]] int storedRowCount(const QString &profileId)
{
    CatalogDatabase catalog(AppPaths::catalogFile());
    QSqlQuery query(catalog.connection());
    if (!query.prepare(QStringLiteral("SELECT count(*) FROM watch_progress "
                                      "WHERE profile_id = ?"))) {
        return -1;
    }
    query.addBindValue(profileId);
    return query.exec() && query.next() ? query.value(0).toInt() : -1;
}
}

class WatchProgressTest final : public QObject
{
    Q_OBJECT

private slots:
    void leavingThePlayerRecordsWhereTheViewerStopped()
    {
        PlayerController player;
        QSignalSpy recorded(&player, &PlayerController::progressRecorded);

        player.prepare(QStringLiteral("/library/arrival.mkv"),
                       QStringLiteral("Arrival"),
                       QStringLiteral("root-1/arrival"),
                       0);
        player.reportPlayback(1800.0, 7200.0, false);
        player.endSession();

        QCOMPARE(recorded.count(), 1);
        const QList<QVariant> arguments = recorded.constFirst();
        QCOMPARE(arguments.at(0).toString(), QStringLiteral("root-1/arrival"));
        QCOMPARE(arguments.at(1).toLongLong(), 1'800'000);
        QCOMPARE(arguments.at(2).toLongLong(), 7'200'000);
        QCOMPARE(arguments.at(3).toBool(), false);
    }

    void endingASessionTwiceRecordsItOnce()
    {
        PlayerController player;
        QSignalSpy recorded(&player, &PlayerController::progressRecorded);

        player.prepare(QStringLiteral("/library/arrival.mkv"),
                       QStringLiteral("Arrival"),
                       QStringLiteral("root-1/arrival"),
                       0);
        player.reportPlayback(1800.0, 7200.0, false);
        player.endSession();
        player.endSession();

        QCOMPARE(recorded.count(), 1);
    }

    void pausingRecordsProgressWithoutLeavingThePlayer()
    {
        PlayerController player;
        QSignalSpy recorded(&player, &PlayerController::progressRecorded);

        player.prepare(QStringLiteral("/library/arrival.mkv"),
                       QStringLiteral("Arrival"),
                       QStringLiteral("root-1/arrival"),
                       0);
        player.reportPlayback(600.0, 7200.0, false);
        player.reportPlayback(600.0, 7200.0, true);

        QCOMPARE(recorded.count(), 1);
        QCOMPARE(recorded.constFirst().at(1).toLongLong(), 600'000);
    }

    void playingRecordsProgressOnItsOwnCadence()
    {
        PlayerController player;
        QSignalSpy recorded(&player, &PlayerController::progressRecorded);

        player.prepare(QStringLiteral("/library/arrival.mkv"),
                       QStringLiteral("Arrival"),
                       QStringLiteral("root-1/arrival"),
                       0);
        player.reportPlayback(600.0, 7200.0, false);

        // Nothing here pauses or leaves, so only the cadence can record this.
        QTRY_VERIFY_WITH_TIMEOUT(recorded.count() > 0, 20000);
        QCOMPARE(recorded.constFirst().at(1).toLongLong(), 600'000);
    }

    void watchingToTheEndRecordsCompletionAndNoResumePoint()
    {
        PlayerController player;
        QSignalSpy recorded(&player, &PlayerController::progressRecorded);

        player.prepare(QStringLiteral("/library/arrival.mkv"),
                       QStringLiteral("Arrival"),
                       QStringLiteral("root-1/arrival"),
                       0);
        player.reportPlayback(6900.0, 7200.0, false);
        player.endSession();

        QCOMPARE(recorded.count(), 1);
        const QList<QVariant> arguments = recorded.constFirst();
        QCOMPARE(arguments.at(1).toLongLong(), 0);
        QCOMPARE(arguments.at(2).toLongLong(), 7'200'000);
        QCOMPARE(arguments.at(3).toBool(), true);
    }

    void stoppingInsideTheClosingCreditsCountsAsWatched()
    {
        // Under nine tenths of a forty-minute film, but inside its last five
        // minutes.
        QVERIFY(PlayerController::watchedToTheEnd(2'101'000, 2'400'000));
        QVERIFY(!PlayerController::watchedToTheEnd(2'000'000, 2'400'000));
    }

    void aShortFileIsNotWatchedJustByBeingShorterThanTheCredits()
    {
        QVERIFY(!PlayerController::watchedToTheEnd(10'000, 120'000));
        QVERIFY(PlayerController::watchedToTheEnd(115'000, 120'000));
    }

    void aResumePointNeedsTwoMinutesIntoATitleOfFiveMinutesOrMore()
    {
        constexpr qint64 kFilm = 7'200'000;
        QVERIFY(!PlayerController::isResumePoint(3'000, kFilm));
        QVERIFY(!PlayerController::isResumePoint(119'999, kFilm));
        QVERIFY(PlayerController::isResumePoint(120'000, kFilm));
        // Under five minutes long: never, however far in.
        QVERIFY(!PlayerController::isResumePoint(200'000, 299'999));
        QVERIFY(PlayerController::isResumePoint(200'000, 300'000));
        // A length libmpv has not reported yet cannot rule the title out.
        QVERIFY(PlayerController::isResumePoint(200'000, 0));
        QVERIFY(!PlayerController::isResumePoint(0, 0));
    }

    void aPeekIntoATitleRecordsNothing()
    {
        PlayerController player;
        QSignalSpy recorded(&player, &PlayerController::progressRecorded);
        player.prepare(QStringLiteral("/library/arrival.mkv"),
                       QStringLiteral("Arrival"), QStringLiteral("root-1/arrival"), 0);

        player.reportPlayback(3.0, 7200.0, false);
        player.reportPlayback(3.0, 7200.0, true);
        player.reportPlayback(119.0, 7200.0, true);
        player.endSession();

        QCOMPARE(recorded.count(), 0);
    }

    void aStopBeforeTwoMinutesLeavesTheOlderResumePointAlone()
    {
        PlayerController player;
        QSignalSpy recorded(&player, &PlayerController::progressRecorded);
        // Opened at the older point, the viewer seeks back to the start and
        // leaves 30 s in: the stored 600 s must not be replaced or erased.
        player.prepare(QStringLiteral("/library/arrival.mkv"),
                       QStringLiteral("Arrival"), QStringLiteral("root-1/arrival"), 600'000);
        player.reportPlayback(30.0, 7200.0, false);
        player.endSession();
        QCOMPARE(recorded.count(), 0);

        // Past two minutes it is recorded as usual.
        player.prepare(QStringLiteral("/library/arrival.mkv"),
                       QStringLiteral("Arrival"), QStringLiteral("root-1/arrival"), 600'000);
        player.reportPlayback(121.0, 7200.0, false);
        player.endSession();
        QCOMPARE(recorded.count(), 1);
        QCOMPARE(recorded.constFirst().at(1).toLongLong(), 121'000);
    }

    // 5:01 long, so the last five minutes start three seconds in: a peek that
    // is "inside the credits" by the watched rule alone.
    void aPeekIntoATitleJustOverFiveMinutesIsNotWatched()
    {
        PlayerController player;
        QSignalSpy recorded(&player, &PlayerController::progressRecorded);
        player.prepare(QStringLiteral("/library/arrival.mkv"),
                       QStringLiteral("Arrival"), QStringLiteral("root-1/arrival"), 0);

        player.reportPlayback(10.0, 301.0, false);
        player.endSession();

        QCOMPARE(recorded.count(), 0);
    }

    void aTitleUnderFiveMinutesRecordsNoResumePoint()
    {
        PlayerController player;
        QSignalSpy recorded(&player, &PlayerController::progressRecorded);
        player.prepare(QStringLiteral("/library/short.mkv"),
                       QStringLiteral("Short"), QStringLiteral("root-1/short"), 0);

        // 150 s into a 280 s title: past two minutes, not yet watched.
        player.reportPlayback(150.0, 280.0, false);
        player.reportPlayback(150.0, 280.0, true);
        player.endSession();

        QCOMPARE(recorded.count(), 0);
    }

    void watchingAShortTitleToItsEndStillMarksItWatched()
    {
        PlayerController player;
        QSignalSpy recorded(&player, &PlayerController::progressRecorded);
        player.prepare(QStringLiteral("/library/short.mkv"),
                       QStringLiteral("Short"), QStringLiteral("root-1/short"), 0);

        player.reportPlayback(270.0, 280.0, false);
        player.endSession();

        QCOMPARE(recorded.count(), 1);
        QCOMPARE(recorded.constFirst().at(1).toLongLong(), 0);
        QCOMPARE(recorded.constFirst().at(3).toBool(), true);
    }

    void aFileOfUnknownLengthIsNeverWatchedToItsEnd()
    {
        QVERIFY(!PlayerController::watchedToTheEnd(1'800'000, 0));
    }

    void unloadingTheSurfaceDoesNotEraseWhereTheViewerGot()
    {
        PlayerController player;
        QSignalSpy recorded(&player, &PlayerController::progressRecorded);

        player.prepare(QStringLiteral("/library/arrival.mkv"),
                       QStringLiteral("Arrival"),
                       QStringLiteral("root-1/arrival"),
                       0);
        player.reportPlayback(1800.0, 7200.0, false);
        // Stopping clears the surface's position before its duration, so the
        // way out is reported as a zero position against the length it still
        // knows, and then as nothing at all.
        player.reportPlayback(0.0, 7200.0, false);
        player.reportPlayback(0.0, 0.0, false);
        player.endSession();

        QCOMPARE(recorded.count(), 1);
        QCOMPARE(recorded.constFirst().at(1).toLongLong(), 1'800'000);
        QCOMPARE(recorded.constFirst().at(2).toLongLong(), 7'200'000);
    }

    void openingAnotherTitleRecordsTheOneItReplaces()
    {
        PlayerController player;
        QSignalSpy recorded(&player, &PlayerController::progressRecorded);

        player.prepare(QStringLiteral("/library/arrival.mkv"),
                       QStringLiteral("Arrival"),
                       QStringLiteral("root-1/arrival"),
                       0);
        player.reportPlayback(1200.0, 7200.0, false);
        player.prepare(QStringLiteral("/library/dune.mkv"),
                       QStringLiteral("Dune"),
                       QStringLiteral("root-1/dune"),
                       0);

        QCOMPARE(recorded.count(), 1);
        QCOMPARE(recorded.constFirst().at(0).toString(),
                 QStringLiteral("root-1/arrival"));
        QCOMPARE(recorded.constFirst().at(1).toLongLong(), 1'200'000);
    }

    void aFileWithoutACatalogIdentityRecordsNothing()
    {
        PlayerController player;
        QSignalSpy recorded(&player, &PlayerController::progressRecorded);

        player.prepare(QStringLiteral("/tmp/handed-in.mkv"), QStringLiteral("Clip"));
        player.reportPlayback(1200.0, 7200.0, false);
        player.endSession();

        QCOMPARE(recorded.count(), 0);
    }

    void restartingRecordsTheTitleAtItsBeginning()
    {
        PlayerController player;
        QSignalSpy recorded(&player, &PlayerController::progressRecorded);

        player.prepare(QStringLiteral("/library/arrival.mkv"),
                       QStringLiteral("Arrival"),
                       QStringLiteral("root-1/arrival"),
                       2'400'000);
        player.reportPlayback(2400.0, 7200.0, false);
        player.reportRestart();

        QCOMPARE(recorded.count(), 1);
        const QList<QVariant> arguments = recorded.constFirst();
        QCOMPARE(arguments.at(0).toString(), QStringLiteral("root-1/arrival"));
        QCOMPARE(arguments.at(1).toLongLong(), 0);
        QCOMPARE(arguments.at(2).toLongLong(), 7'200'000);
        // Starting a film again is not finishing it.
        QCOMPARE(arguments.at(3).toBool(), false);
    }

    void leavingRightAfterARestartDoesNotResumeWhereItWasRestartedFrom()
    {
        PlayerController player;
        QSignalSpy recorded(&player, &PlayerController::progressRecorded);

        player.prepare(QStringLiteral("/library/arrival.mkv"),
                       QStringLiteral("Arrival"),
                       QStringLiteral("root-1/arrival"),
                       2'400'000);
        // A film restarted while it is paused reports no position of its own
        // afterwards, so the session's own position is what the way out writes.
        player.reportPlayback(2400.0, 7200.0, true);
        player.reportRestart();
        player.endSession();

        QCOMPARE(recorded.count(), 2);
        QCOMPARE(recorded.constFirst().at(1).toLongLong(), 2'400'000);
        QCOMPARE(recorded.constLast().at(1).toLongLong(), 0);
    }

    void restartingAFileWithoutACatalogIdentityRecordsNothing()
    {
        PlayerController player;
        QSignalSpy recorded(&player, &PlayerController::progressRecorded);

        player.prepare(QStringLiteral("/tmp/handed-in.mkv"), QStringLiteral("Clip"));
        player.reportPlayback(1200.0, 7200.0, false);
        player.reportRestart();

        QCOMPARE(recorded.count(), 0);
    }

    void aTitleThatHasNotStartedKeepsTheResumePointItOpenedWith()
    {
        PlayerController player;
        QSignalSpy recorded(&player, &PlayerController::progressRecorded);

        player.prepare(QStringLiteral("/library/arrival.mkv"),
                       QStringLiteral("Arrival"),
                       QStringLiteral("root-1/arrival"),
                       1'800'000);
        QCOMPARE(player.startPosition(), 1800.0);

        // libmpv reports position zero until the resuming seek lands.
        player.reportPlayback(0.0, 7200.0, false);
        player.endSession();

        QCOMPARE(recorded.count(), 0);
    }

    void recordedProgressSurvivesReopeningTheCatalog()
    {
        QTemporaryDir dataDirectory;
        QTemporaryDir library;
        const QString catalogPath =
            QDir(dataDirectory.path()).filePath(QStringLiteral("catalog.sqlite"));
        QVERIFY(writeMediaFile(library.path(), QLatin1String(kFilmRelativePath)));

        {
            CatalogDatabase catalog(catalogPath);
            catalog.migrate();
        }

        QString mediaId;
        {
            CatalogStore store(catalogPath);
            const QVector<MediaItem> items = refresh(store, library.path());
            QCOMPARE(items.size(), 1);
            QCOMPARE(items.constFirst().resumePositionMs, 0);
            mediaId = items.constFirst().id;
            store.recordWatchProgress(QLatin1String(kProfile), mediaId, 1'800'000, 7'200'000, false);
        }

        CatalogStore reopened(catalogPath);
        const QVector<MediaItem> items = refresh(reopened, library.path());
        QCOMPARE(items.size(), 1);
        QCOMPARE(items.constFirst().id, mediaId);
        QCOMPARE(items.constFirst().resumePositionMs, 1'800'000);
    }

    void aWatchedTitleIsRecordedAsWatchedAndProjectsNoResumePoint()
    {
        QTemporaryDir dataDirectory;
        QTemporaryDir library;
        const QString catalogPath =
            QDir(dataDirectory.path()).filePath(QStringLiteral("catalog.sqlite"));
        QVERIFY(writeMediaFile(library.path(), QLatin1String(kFilmRelativePath)));

        {
            CatalogDatabase catalog(catalogPath);
            catalog.migrate();
        }

        CatalogStore store(catalogPath);
        const QString mediaId = refresh(store, library.path()).constFirst().id;
        store.recordWatchProgress(QLatin1String(kProfile), mediaId, 1'800'000, 7'200'000, false);
        store.recordWatchProgress(QLatin1String(kProfile), mediaId, 0, 7'200'000, true);

        QCOMPARE(refresh(store, library.path()).constFirst().resumePositionMs, 0);
        const QVariantList row = storedProgress(catalogPath, mediaId, QLatin1String(kProfile));
        QCOMPARE(row.size(), 3);
        QCOMPARE(row.at(0).toLongLong(), 0);
        QCOMPARE(row.at(1).toLongLong(), 7'200'000);
        QCOMPARE(row.at(2).toInt(), 1);
    }

    void progressIsForgottenWithTheTitleItDescribes()
    {
        QTemporaryDir dataDirectory;
        QTemporaryDir library;
        const QString catalogPath =
            QDir(dataDirectory.path()).filePath(QStringLiteral("catalog.sqlite"));
        QVERIFY(writeMediaFile(library.path(), QLatin1String(kFilmRelativePath)));

        {
            CatalogDatabase catalog(catalogPath);
            catalog.migrate();
        }

        CatalogStore store(catalogPath);
        const QString mediaId = refresh(store, library.path()).constFirst().id;
        store.recordWatchProgress(QLatin1String(kProfile), mediaId, 1'800'000, 7'200'000, false);
        QCOMPARE(storedProgress(catalogPath, mediaId, QLatin1String(kProfile)).size(), 3);

        QVERIFY(QFile::remove(QDir(library.path()).filePath(
            QLatin1String(kFilmRelativePath))));
        QVERIFY(refresh(store, library.path()).isEmpty());

        QVERIFY(storedProgress(catalogPath, mediaId, QLatin1String(kProfile)).isEmpty());
    }

    void progressForATitleTheCatalogDoesNotHoldIsRejected()
    {
        QTemporaryDir dataDirectory;
        const QString catalogPath =
            QDir(dataDirectory.path()).filePath(QStringLiteral("catalog.sqlite"));

        {
            CatalogDatabase catalog(catalogPath);
            catalog.migrate();
        }

        CatalogStore store(catalogPath);
        QVERIFY_EXCEPTION_THROWN(
            store.recordWatchProgress(
                QLatin1String(kProfile), QStringLiteral("root-1/gone"), 1'800'000, 7'200'000, false),
            std::runtime_error);
    }

    void aTitleReopensWhereItWasLeftInTheSameSession()
    {
        QTemporaryDir runtimeRoot;
        QTemporaryDir library;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
        QVERIFY(writeMediaFile(library.path(), QLatin1String(kFilmRelativePath)));

        ApplicationController controller;
        QVERIFY2(!controller.hasError(), qPrintable(controller.errorMessage()));
        QVERIFY(chooseMainProfile(controller));
        controller.setTemporaryLibraryRoot(library.path());
        QTRY_COMPARE(controller.library()->rowCount(), 1);

        const QString mediaId = controller.library()
                                    ->data(controller.library()->index(0, 0),
                                           LibraryModel::IdRole)
                                    .toString();

        controller.playMediaId(mediaId);
        QCOMPARE(controller.navigation()->route(), NavigationController::Route::Player);
        QCOMPARE(controller.player()->startPosition(), 0.0);

        controller.player()->reportPlayback(300.0, 7200.0, false);
        controller.navigation()->goHome();

        controller.playMediaId(mediaId);
        QCOMPARE(controller.player()->startPosition(), 300.0);
    }

    void aRecordedPointSurvivesARefreshQueuedBeforeItsWrite()
    {
        QTemporaryDir runtimeRoot;
        QTemporaryDir library;
        QTemporaryDir refreshRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
        QVERIFY(writeMediaFile(library.path(), QLatin1String(kFilmRelativePath)));

        ApplicationController controller;
        QVERIFY2(!controller.hasError(), qPrintable(controller.errorMessage()));
        QVERIFY(chooseMainProfile(controller));
        controller.setTemporaryLibraryRoot(library.path());
        QTRY_COMPARE(controller.library()->rowCount(), 1);
        const QString mediaId = controller.library()
                                    ->data(controller.library()->index(0, 0),
                                           LibraryModel::IdRole)
                                    .toString();

        QSemaphore refreshEntered;
        QSemaphore releaseRefresh;
        bool refreshReleased = false;
        QSignalSpy projectionReset(controller.library(), &QAbstractItemModel::modelReset);
        const QMetaObject::Connection gate = QObject::connect(
            &controller, &ApplicationController::catalogRefreshStarted,
            &controller,
            [&] {
                refreshEntered.release();
                releaseRefresh.acquire();
            },
            Qt::DirectConnection);
        const auto releaseGate = qScopeGuard([&] {
            if (!refreshReleased) {
                releaseRefresh.release();
            }
        });

        controller.setTemporaryLibraryRoot(refreshRoot.path());
        QVERIFY2(refreshEntered.tryAcquire(1, 5000),
                 "the refresh did not reach its deterministic gate");

        QSignalSpy recorded(controller.player(), &PlayerController::progressRecorded);
        QSignalSpy progressPersisted(&controller,
                                     &ApplicationController::catalogProgressPersisted);
        controller.playMediaId(mediaId);
        controller.player()->reportPlayback(300.0, 7200.0, false);
        controller.player()->endSession();
        QCOMPARE(recorded.count(), 1);
        QCOMPARE(controller.library()->itemForId(mediaId)->resumePositionMs,
                 qint64{300'000});

        refreshReleased = true;
        releaseRefresh.release();
        QObject::disconnect(gate);

        // Both signals can land in one event-loop pass, so count rather than wait.
        QTRY_VERIFY_WITH_TIMEOUT(projectionReset.count() >= 1, 5000);
        QTRY_COMPARE_WITH_TIMEOUT(progressPersisted.count(), 1, 5000);
        const QList<QVariant> persisted = progressPersisted.constFirst();
        QCOMPARE(persisted.at(0).toString(), mediaId);
        QCOMPARE(persisted.at(1).toLongLong(), qint64{300'000});

        const auto projectedPosition = [&controller, &mediaId] {
            const auto item = controller.library()->itemForId(mediaId);
            return item ? item->resumePositionMs : qint64{-1};
        };
        QCOMPARE(projectedPosition(), qint64{300'000});

        const auto durablePosition = [&] {
            const QVariantList row = storedProgress(AppPaths::catalogFile(), mediaId, mainProfileId());
            return row.size() == 3 ? row.at(0).toLongLong() : qint64{-1};
        };
        QCOMPARE(durablePosition(), qint64{300'000});
    }

    void quittingBehindAnInFlightRefreshStillPersistsFinalProgress()
    {
        QTemporaryDir runtimeRoot;
        QTemporaryDir library;
        QTemporaryDir refreshRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
        QVERIFY(writeMediaFile(library.path(), QLatin1String(kFilmRelativePath)));

        QSemaphore refreshEntered;
        QSemaphore releaseRefresh;
        bool refreshReleased = false;
        const auto releaseGate = qScopeGuard([&] {
            if (!refreshReleased) {
                releaseRefresh.release();
            }
        });

        QString mediaId;
        {
            ApplicationController controller;
            QVERIFY2(!controller.hasError(), qPrintable(controller.errorMessage()));
            QVERIFY(chooseMainProfile(controller));
            controller.setTemporaryLibraryRoot(library.path());
            QTRY_COMPARE(controller.library()->rowCount(), 1);
            mediaId = controller.library()
                          ->data(controller.library()->index(0, 0),
                                 LibraryModel::IdRole)
                          .toString();

            const QMetaObject::Connection gate = QObject::connect(
                &controller, &ApplicationController::catalogRefreshStarted,
                &controller,
                [&] {
                    refreshEntered.release();
                    releaseRefresh.acquire();
                },
                Qt::DirectConnection);

            controller.setTemporaryLibraryRoot(refreshRoot.path());
            QVERIFY2(refreshEntered.tryAcquire(1, 5000),
                     "the refresh did not reach its deterministic gate");

            controller.playMediaId(mediaId);
            controller.player()->reportPlayback(420.0, 7200.0, false);

            // Let the worker remain blocked beyond the old 250 ms shutdown
            // budget. The controller's nested shutdown loop must keep this
            // callback live until the refresh can finish.
            QTimer::singleShot(500, QCoreApplication::instance(), [&] {
                refreshReleased = true;
                releaseRefresh.release();
            });
        }

        const auto durablePosition = [&] {
            const QVariantList row = storedProgress(AppPaths::catalogFile(), mediaId, mainProfileId());
            return row.size() == 3 ? row.at(0).toLongLong() : qint64{-1};
        };
        QTRY_COMPARE_WITH_TIMEOUT(durablePosition(), qint64{420'000}, 5000);
    }

    // libmpv reports positions before it knows a file's length. A row
    // written in that gap has no length, and the length must complete it as
    // soon as it arrives, without waiting for another position or pause.
    void aLengthArrivingAfterARowWithoutOneCompletesThatRow()
    {
        PlayerController player;
        QSignalSpy recorded(&player, &PlayerController::progressRecorded);
        player.prepare(QStringLiteral("/library/arrival.mkv"),
                       QStringLiteral("Arrival"), QStringLiteral("root-1/arrival"));
        player.reportPlayback(600.0, 0.0, false);
        player.reportPlayback(600.0, 0.0, true);
        QCOMPARE(recorded.count(), 1);
        QCOMPARE(recorded.at(0).at(2).toLongLong(), 0);

        player.reportPlayback(600.0, 7200.0, true);
        QCOMPARE(recorded.count(), 2);
        QCOMPARE(recorded.at(1).at(1).toLongLong(), 600'000);
        QCOMPARE(recorded.at(1).at(2).toLongLong(), 7'200'000);

        // Once the length is on record, its arrival is not a reason to write again.
        player.reportPlayback(601.0, 7200.0, true);
        QCOMPARE(recorded.count(), 2);
    }

    void aTransientZeroLengthDoesNotForgetAKnownOne()
    {
        PlayerController player;
        QSignalSpy recorded(&player, &PlayerController::progressRecorded);
        player.prepare(QStringLiteral("/library/arrival.mkv"),
                       QStringLiteral("Arrival"), QStringLiteral("root-1/arrival"));
        player.reportPlayback(600.0, 7200.0, false);
        player.reportPlayback(700.0, 0.0, false);
        player.reportPlayback(700.0, 0.0, true);
        QCOMPARE(recorded.count(), 1);
        QCOMPARE(recorded.at(0).at(1).toLongLong(), 700'000);
        QCOMPARE(recorded.at(0).at(2).toLongLong(), 7'200'000);
    }

    void aKnownLengthDoesNotCarryIntoTheNextSession()
    {
        PlayerController player;
        QSignalSpy recorded(&player, &PlayerController::progressRecorded);
        player.prepare(QStringLiteral("/library/arrival.mkv"),
                       QStringLiteral("Arrival"), QStringLiteral("root-1/arrival"));
        player.reportPlayback(600.0, 7200.0, false);
        player.prepare(QStringLiteral("/library/dune.mkv"),
                       QStringLiteral("Dune"), QStringLiteral("root-1/dune"));
        player.reportPlayback(300.0, 0.0, false);
        player.reportPlayback(300.0, 0.0, true);
        QCOMPARE(recorded.count(), 2);
        QCOMPARE(recorded.at(1).at(0).toString(), QStringLiteral("root-1/dune"));
        QCOMPARE(recorded.at(1).at(2).toLongLong(), 0);
    }

    // The same ordering through the shipped player surface: the video item
    // learns a position, the viewer pauses so a row is written without a
    // length, and then only the length arrives. The surface must report that
    // arrival on its own, and the projection on screen and the stored row
    // must both carry it before anything else happens.
    void theSurfaceReportsALengthThatArrivesAfterTheFirstRow()
    {
        QTemporaryDir runtimeRoot;
        QTemporaryDir library;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
        QVERIFY(writeMediaFile(library.path(), QLatin1String(kFilmRelativePath)));

        ApplicationController controller;
        QVERIFY2(!controller.hasError(), qPrintable(controller.errorMessage()));
        controller.setStartFullscreen(false);

        QQmlApplicationEngine engine;
        engine.rootContext()->setContextProperty(QStringLiteral("appController"),
                                                 &controller);
        engine.loadFromModule(QStringLiteral("Marquee"), QStringLiteral("Main"));
        QCOMPARE(engine.rootObjects().size(), 1);
        auto *window = qobject_cast<QQuickWindow *>(engine.rootObjects().front());
        QVERIFY2(window != nullptr, "qml/Main.qml did not load from the module");

        QVERIFY(chooseMainProfile(controller));
        controller.setTemporaryLibraryRoot(library.path());
        QTRY_COMPARE(controller.library()->rowCount(), 1);
        const QString mediaId = controller.library()
                                    ->data(controller.library()->index(0, 0), LibraryModel::IdRole)
                                    .toString();
        controller.playMediaId(mediaId);

        QQuickItem *video = nullptr;
        QTRY_VERIFY((video = window->findChild<QQuickItem *>(
                         QStringLiteral("videoSurface"))) != nullptr);
        QSignalSpy recorded(controller.player(), &PlayerController::progressRecorded);

        // What libmpv would report, in this order, delivered through the
        // item's own property changes so the surface's bindings are what is
        // under test.
        QVERIFY(QMetaObject::invokeMethod(video, "setPositionValue", Q_ARG(double, 600.0)));
        QVERIFY(QMetaObject::invokeMethod(video, "setPausedValue", Q_ARG(bool, true)));
        QTRY_COMPARE(recorded.count(), 1);
        QCOMPARE(recorded.at(0).at(2).toLongLong(), 0);
        QCOMPARE(controller.library()->itemForId(mediaId)->durationSeconds, 0);

        QVERIFY(QMetaObject::invokeMethod(video, "setDurationValue", Q_ARG(double, 7200.0)));
        QTRY_COMPARE(recorded.count(), 2);
        QCOMPARE(recorded.at(1).at(1).toLongLong(), 600'000);
        QCOMPARE(recorded.at(1).at(2).toLongLong(), 7'200'000);
        QTRY_COMPARE(controller.library()->itemForId(mediaId)->durationSeconds, 7200);
        QTRY_COMPARE(controller.library()
                         ->data(controller.library()->index(0, 0), LibraryModel::MetadataRole)
                         .toString(),
                     QStringLiteral("2016 2h 0m"));

        // And the row the catalog keeps.
        QTRY_VERIFY([&] {
            CatalogStore store(AppPaths::catalogFile());
            const QVector<MediaItem> projection =
                refresh(store, library.path(), mainProfileId());
            return !projection.isEmpty() && projection.constFirst().durationSeconds == 7200;
        }());
    }

    // The same row reaches the projection twice: directly when it is
    // recorded and again when the catalog echoes the write. The echo of an
    // older row can arrive after a newer row was applied directly, and must
    // not move the title backwards in position or length; it may restate the
    // newest row after a rescan replaced the projection, and a title the
    // rescan dropped starts over from what the catalog says when it returns.
    void aDelayedEchoOfAnOlderRowCannotMoveATitleBackwards()
    {
        MediaItem arrival;
        arrival.id = QStringLiteral("root-1/arrival");
        arrival.title = QStringLiteral("Arrival");
        arrival.year = 2016;
        LibraryModel model;
        model.replaceItems({arrival});

        model.applyWatchProgress(arrival.id, 600'000, 0, 1);
        model.applyWatchProgress(arrival.id, 900'000, 7'200'000, 2);
        QCOMPARE(model.itemForId(arrival.id)->resumePositionMs, 900'000);
        QCOMPARE(model.itemForId(arrival.id)->durationSeconds, 7200);

        // The catalog's echo of the first row, arriving late.
        model.applyWatchProgress(arrival.id, 600'000, 0, 1);
        QCOMPARE(model.itemForId(arrival.id)->resumePositionMs, 900'000);
        QCOMPARE(model.itemForId(arrival.id)->durationSeconds, 7200);

        // A rescan replaces the projection with what the catalog held before
        // either write; the newest row's echo restates it, an older echo cannot.
        model.replaceItems({arrival});
        QCOMPARE(model.itemForId(arrival.id)->durationSeconds, 0);
        model.applyWatchProgress(arrival.id, 600'000, 0, 1);
        QCOMPARE(model.itemForId(arrival.id)->resumePositionMs, 0);
        QCOMPARE(model.itemForId(arrival.id)->durationSeconds, 0);
        model.applyWatchProgress(arrival.id, 900'000, 7'200'000, 2);
        QCOMPARE(model.itemForId(arrival.id)->resumePositionMs, 900'000);
        QCOMPARE(model.itemForId(arrival.id)->durationSeconds, 7200);

        // The same sequence again is the echo of what was applied; a newer
        // row still moves the title forward, and a genuine later reset to an
        // unknown length is a newer row, not an older one.
        model.applyWatchProgress(arrival.id, 900'000, 7'200'000, 2);
        model.applyWatchProgress(arrival.id, 1'200'000, 7'200'000, 3);
        QCOMPARE(model.itemForId(arrival.id)->resumePositionMs, 1'200'000);
        model.applyWatchProgress(arrival.id, 100'000, 0, 4);
        QCOMPARE(model.itemForId(arrival.id)->resumePositionMs, 100'000);
        QCOMPARE(model.itemForId(arrival.id)->durationSeconds, 0);

        // A title the rescan drops forgets its ordering; when it returns, the
        // catalog's own row for it counts again from whatever it says.
        model.replaceItems({});
        model.replaceItems({arrival});
        model.applyWatchProgress(arrival.id, 300'000, 5'400'000, 1);
        QCOMPARE(model.itemForId(arrival.id)->resumePositionMs, 300'000);
        QCOMPARE(model.itemForId(arrival.id)->durationSeconds, 5400);
    }

    // The queued path itself: with the catalog worker held inside a refresh,
    // a row without a length and then the same row with its length are both
    // recorded and applied directly, and both echoes arrive only after the
    // worker is released. That refresh replaces the whole projection, so what
    // the surface shows is announced as a model reset as well as a row change
    // and both have to be observed: the reset carries the catalog rows the
    // refresh read before either write ran, and the older echo delivered
    // behind the newer row must not restate what it brought back.
    void anEchoDelayedBehindARefreshDoesNotRevertTheLengthOnScreen()
    {
        QTemporaryDir runtimeRoot;
        QTemporaryDir library;
        QTemporaryDir refreshRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
        QVERIFY(writeMediaFile(library.path(), QLatin1String(kFilmRelativePath)));

        ApplicationController controller;
        QVERIFY2(!controller.hasError(), qPrintable(controller.errorMessage()));
        QVERIFY(chooseMainProfile(controller));
        controller.setTemporaryLibraryRoot(library.path());
        QTRY_COMPARE(controller.library()->rowCount(), 1);
        const QString mediaId = controller.library()
                                    ->data(controller.library()->index(0, 0),
                                           LibraryModel::IdRole)
                                    .toString();

        QSemaphore refreshEntered;
        QSemaphore releaseRefresh;
        bool refreshReleased = false;
        const QMetaObject::Connection gate = QObject::connect(
            &controller, &ApplicationController::catalogRefreshStarted,
            &controller,
            [&] {
                refreshEntered.release();
                releaseRefresh.acquire();
            },
            Qt::DirectConnection);
        const auto releaseGate = qScopeGuard([&] {
            if (!refreshReleased) {
                releaseRefresh.release();
            }
        });

        controller.setTemporaryLibraryRoot(refreshRoot.path());
        QVERIFY2(refreshEntered.tryAcquire(1, 5000),
                 "the refresh did not reach its deterministic gate");

        // Every runtime the projection shows for the title, in the order the
        // model announced it, named by how it was announced. `replaceItems`
        // publishes a whole-model reset rather than a row change, so a
        // projection that dropped the runtime would be invisible to a
        // `dataChanged` observer on its own.
        QStringList runtimesShown;
        const auto recordRuntime = [&](const QString &announcement) {
            const auto item = controller.library()->itemForId(mediaId);
            runtimesShown.append(QStringLiteral("%1:%2").arg(
                announcement, QString::number(item ? item->durationSeconds : qint64{-1})));
        };
        QObject::connect(controller.library(), &QAbstractItemModel::modelReset, &controller,
                         [&] { recordRuntime(QStringLiteral("reset")); });
        QObject::connect(controller.library(), &QAbstractItemModel::dataChanged, &controller,
                         [&](const QModelIndex &topLeft, const QModelIndex &, const QList<int> &) {
                             if (controller.library()->data(topLeft, LibraryModel::IdRole).toString()
                                 == mediaId) {
                                 recordRuntime(QStringLiteral("row"));
                             }
                         });

        QSignalSpy recorded(controller.player(), &PlayerController::progressRecorded);
        QSignalSpy progressPersisted(&controller,
                                     &ApplicationController::catalogProgressPersisted);
        controller.playMediaId(mediaId);
        controller.player()->reportPlayback(600.0, 0.0, false);
        controller.player()->reportPlayback(600.0, 0.0, true);
        controller.player()->reportPlayback(600.0, 7200.0, true);
        QCOMPARE(recorded.count(), 2);
        QCOMPARE(recorded.at(0).at(2).toLongLong(), 0);
        QCOMPARE(recorded.at(1).at(2).toLongLong(), 7'200'000);
        QVERIFY(recorded.at(1).at(4).toULongLong() > recorded.at(0).at(4).toULongLong());
        QCOMPARE(controller.library()->itemForId(mediaId)->durationSeconds, 7200);
        QCOMPARE(runtimesShown, (QStringList{QStringLiteral("row:7200")}));

        refreshReleased = true;
        releaseRefresh.release();
        QObject::disconnect(gate);

        // Both echoes, in the order they were written, behind the refresh.
        QTRY_COMPARE(progressPersisted.count(), 2);
        QCOMPARE(progressPersisted.at(0).at(1).toLongLong(), 600'000);
        QCOMPARE(progressPersisted.at(1).at(1).toLongLong(), 600'000);
        QCOMPARE(controller.library()->itemForId(mediaId)->durationSeconds, 7200);
        QCOMPARE(controller.library()->itemForId(mediaId)->resumePositionMs, 600'000);

        const auto describe = [&] { return runtimesShown.join(QLatin1Char(' ')); };

        // The refresh really replaced the projection, which is what makes the
        // echoes behind it meaningful: exactly one reset, carrying the catalog
        // rows the refresh read before either write ran. A projection does not
        // retain a runtime the catalog does not yet hold, so the reset shows
        // it as unknown again.
        int resetIndex = -1;
        int resets = 0;
        for (int index = 0; index < runtimesShown.size(); ++index) {
            if (runtimesShown.at(index).startsWith(QLatin1String("reset:"))) {
                ++resets;
                resetIndex = index;
            }
        }
        QVERIFY2(resets == 1, qPrintable(QStringLiteral("expected one projection reset, saw %1: %2")
                                             .arg(resets).arg(describe())));
        QCOMPARE(runtimesShown.at(resetIndex), QStringLiteral("reset:0"));

        // What the ordering rule owns: once the projection has been replaced,
        // the older echo delivered behind it cannot restate that unknown, and
        // the newer row is the only thing that moves the runtime again.
        QVERIFY2(resetIndex + 1 < runtimesShown.size(),
                 qPrintable(QStringLiteral("nothing restored the runtime after the reset: %1")
                                .arg(describe())));
        for (int index = resetIndex + 1; index < runtimesShown.size(); ++index) {
            QVERIFY2(runtimesShown.at(index).endsWith(QLatin1String(":7200")),
                     qPrintable(QStringLiteral("the runtime on screen fell back after the "
                                               "projection was replaced: %1")
                                    .arg(describe())));
        }

        const QVariantList row = storedProgress(AppPaths::catalogFile(), mediaId, mainProfileId());
        QCOMPARE(row.size(), 3);
        QCOMPARE(row.at(0).toLongLong(), 600'000);
        QCOMPARE(row.at(1).toLongLong(), 7'200'000);
    }

    void aRestartedTitleReopensAtItsBeginning()
    {
        QTemporaryDir runtimeRoot;
        QTemporaryDir library;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
        QVERIFY(writeMediaFile(library.path(), QLatin1String(kFilmRelativePath)));

        QString mediaId;
        {
            ApplicationController controller;
            QVERIFY2(!controller.hasError(), qPrintable(controller.errorMessage()));
            QVERIFY(chooseMainProfile(controller));
            controller.setTemporaryLibraryRoot(library.path());
            QTRY_COMPARE(controller.library()->rowCount(), 1);

            mediaId = controller.library()
                          ->data(controller.library()->index(0, 0),
                                 LibraryModel::IdRole)
                          .toString();

            controller.playMediaId(mediaId);
            controller.player()->reportPlayback(300.0, 7200.0, false);
            controller.navigation()->goHome();
            controller.playMediaId(mediaId);
            QCOMPARE(controller.player()->startPosition(), 300.0);

            controller.player()->reportPlayback(300.0, 7200.0, false);
            controller.player()->reportRestart();
            controller.navigation()->goHome();
            controller.playMediaId(mediaId);

            QCOMPARE(controller.player()->startPosition(), 0.0);
        }

        const QVariantList stored = storedProgress(AppPaths::catalogFile(), mediaId, mainProfileId());
        QCOMPARE(stored.at(0).toLongLong(), 0);
        // The restart keeps the length the session already knew.
        QCOMPARE(stored.at(1).toLongLong(), 7'200'000);
        QCOMPARE(stored.at(2).toBool(), false);
    }

    void thePlayerSurfaceOpensTheFileWhereTheCatalogSaid()
    {
        QTemporaryDir runtimeRoot;
        QTemporaryDir library;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
        QVERIFY(writeMediaFile(library.path(), QLatin1String(kFilmRelativePath)));

        {
            AppPaths::ensureDirectories();
            CatalogDatabase catalog(AppPaths::catalogFile());
            catalog.migrate();
            CatalogStore store(AppPaths::catalogFile());
            const QString seeded = refresh(store, library.path()).constFirst().id;
            store.recordWatchProgress(mainProfileId(), seeded, 300'000, 7'200'000, false);
        }

        ApplicationController controller;
        QVERIFY2(!controller.hasError(), qPrintable(controller.errorMessage()));
        controller.setStartFullscreen(false);

        // The shipped module, so the binding under test is the one that ships.
        QQmlApplicationEngine engine;
        engine.rootContext()->setContextProperty(QStringLiteral("appController"),
                                                 &controller);
        engine.loadFromModule(QStringLiteral("Marquee"), QStringLiteral("Main"));
        QCOMPARE(engine.rootObjects().size(), 1);
        auto *window = qobject_cast<QQuickWindow *>(engine.rootObjects().front());
        QVERIFY2(window != nullptr, "qml/Main.qml did not load from the module");

        QVERIFY(chooseMainProfile(controller));
        controller.setTemporaryLibraryRoot(library.path());
        QTRY_COMPARE(controller.library()->rowCount(), 1);
        controller.playMediaId(controller.library()
                                   ->data(controller.library()->index(0, 0),
                                          LibraryModel::IdRole)
                                   .toString());

        QQuickItem *video = nullptr;
        QTRY_VERIFY((video = window->findChild<QQuickItem *>(
                         QStringLiteral("videoSurface"))) != nullptr);
        QCOMPARE(video->property("startPosition").toDouble(), 300.0);
    }

    void progressSurvivesQuittingWithThePlayerOpen()
    {
        QTemporaryDir runtimeRoot;
        QTemporaryDir library;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
        QVERIFY(writeMediaFile(library.path(), QLatin1String(kFilmRelativePath)));

        QString mediaId;
        {
            ApplicationController controller;
            QVERIFY2(!controller.hasError(), qPrintable(controller.errorMessage()));
            QVERIFY(chooseMainProfile(controller));
            controller.setTemporaryLibraryRoot(library.path());
            QTRY_COMPARE(controller.library()->rowCount(), 1);

            mediaId = controller.library()
                          ->data(controller.library()->index(0, 0),
                                 LibraryModel::IdRole)
                          .toString();
            controller.playMediaId(mediaId);
            controller.player()->reportPlayback(420.0, 7200.0, false);
        }

        QCOMPARE(storedProgress(AppPaths::catalogFile(), mediaId, mainProfileId()).at(0).toLongLong(),
                 420'000);

        ApplicationController restarted;
        QVERIFY(chooseMainProfile(restarted));
        restarted.setTemporaryLibraryRoot(library.path());
        QTRY_COMPARE(restarted.library()->rowCount(), 1);
        restarted.playMediaId(mediaId);

        QCOMPARE(restarted.player()->startPosition(), 420.0);
    }

    void twoProfilesKeepSeparateProgressForTheSameTitle()
    {
        QTemporaryDir dataDirectory;
        QTemporaryDir library;
        const QString catalogPath =
            QDir(dataDirectory.path()).filePath(QStringLiteral("catalog.sqlite"));
        QVERIFY(writeMediaFile(library.path(), QLatin1String(kFilmRelativePath)));
        {
            CatalogDatabase catalog(catalogPath);
            catalog.migrate();
        }

        CatalogStore store(catalogPath);
        const QString mediaId = refresh(store, library.path(), QStringLiteral("adult")).constFirst().id;
        store.recordWatchProgress(QStringLiteral("adult"), mediaId, 1'800'000, 7'200'000, false);
        store.recordWatchProgress(QStringLiteral("kids"), mediaId, 0, 7'200'000, true);

        const MediaItem adult = refresh(store, library.path(), QStringLiteral("adult")).constFirst();
        QCOMPARE(adult.resumePositionMs, 1'800'000);
        QVERIFY(!adult.watched);
        const MediaItem kids = refresh(store, library.path(), QStringLiteral("kids")).constFirst();
        QCOMPARE(kids.resumePositionMs, 0);
        QVERIFY(kids.watched);

        // Writing again for one profile moves only that profile.
        store.recordWatchProgress(QStringLiteral("adult"), mediaId, 3'600'000, 7'200'000, false);
        QCOMPARE(refresh(store, library.path(), QStringLiteral("adult")).constFirst().resumePositionMs,
                 3'600'000);
        QVERIFY(refresh(store, library.path(), QStringLiteral("kids")).constFirst().watched);

        // A profile that never watched it sees an unwatched title.
        const MediaItem stranger = refresh(store, library.path(), QStringLiteral("new")).constFirst();
        QCOMPARE(stranger.resumePositionMs, 0);
        QVERIFY(!stranger.watched);
        QCOMPARE(refresh(store, library.path(), QString()).constFirst().resumePositionMs, 0);
    }

    void progressWithNoProfileChosenIsRefused()
    {
        QTemporaryDir dataDirectory;
        QTemporaryDir library;
        const QString catalogPath =
            QDir(dataDirectory.path()).filePath(QStringLiteral("catalog.sqlite"));
        QVERIFY(writeMediaFile(library.path(), QLatin1String(kFilmRelativePath)));
        {
            CatalogDatabase catalog(catalogPath);
            catalog.migrate();
        }

        CatalogStore store(catalogPath);
        const QString mediaId = refresh(store, library.path()).constFirst().id;
        QVERIFY_EXCEPTION_THROWN(
            store.recordWatchProgress(QString(), mediaId, 1'800'000, 7'200'000, false),
            std::runtime_error);
        CatalogDatabase catalog(catalogPath);
        QSqlQuery query(catalog.connection());
        QVERIFY(query.exec(QStringLiteral("SELECT count(*) FROM watch_progress")));
        QVERIFY(query.next());
        QCOMPARE(query.value(0).toInt(), 0);
    }

    void aSessionWithNoProfileSavesNothingAndShowsNoProgress()
    {
        QTemporaryDir runtimeRoot;
        QTemporaryDir library;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
        QVERIFY(writeMediaFile(library.path(), QLatin1String(kFilmRelativePath)));

        QString mediaId;
        {
            ApplicationController controller;
            QVERIFY2(!controller.hasError(), qPrintable(controller.errorMessage()));
            controller.setTemporaryLibraryRoot(library.path());
            QTRY_COMPARE(controller.library()->rowCount(), 1);
            mediaId = controller.library()
                          ->data(controller.library()->index(0, 0), LibraryModel::IdRole)
                          .toString();

            controller.playMediaId(mediaId);
            controller.player()->reportPlayback(300.0, 7200.0, false);
            controller.navigation()->goHome();

            QCOMPARE(controller.library()->itemForId(mediaId)->resumePositionMs, qint64{0});
            controller.playMediaId(mediaId);
            QCOMPARE(controller.player()->startPosition(), 0.0);
            // Clearing history with no profile has nothing to clear.
            controller.clearWatchHistory();
        }

        CatalogDatabase catalog(AppPaths::catalogFile());
        QSqlQuery query(catalog.connection());
        QVERIFY(query.exec(QStringLiteral("SELECT count(*) FROM watch_progress")));
        QVERIFY(query.next());
        QCOMPARE(query.value(0).toInt(), 0);
    }

    void kidsAndAdultsKeepTheirOwnResumePointsThroughTheShell()
    {
        QTemporaryDir runtimeRoot;
        QTemporaryDir library;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
        QVERIFY(writeMediaFile(library.path(), QLatin1String(kKidsFilmRelativePath)));

        QString mediaId;
        QString mainId;
        QString kidsId;
        {
            ApplicationController controller;
            QVERIFY2(!controller.hasError(), qPrintable(controller.errorMessage()));
            controller.setTemporaryLibraryRoot(library.path());
            mainId = profileNamed(controller, QStringLiteral("Main"));
            kidsId = profileNamed(controller, QStringLiteral("Kids"));

            QVERIFY(chooseProfileNamed(controller, QStringLiteral("Main")));
            QTRY_COMPARE(controller.library()->rowCount(), 1);
            mediaId = controller.library()
                          ->data(controller.library()->index(0, 0), LibraryModel::IdRole)
                          .toString();
            controller.playMediaId(mediaId);
            controller.player()->reportPlayback(300.0, 7200.0, false);
            controller.navigation()->goHome();

            // Kids has not watched it: it opens at the beginning, not at
            // the point Main reached.
            controller.switchProfile();
            QVERIFY(chooseProfileNamed(controller, QStringLiteral("Kids")));
            QTRY_COMPARE(controller.library()->itemForId(mediaId)->resumePositionMs, qint64{0});
            controller.playMediaId(mediaId);
            QCOMPARE(controller.player()->startPosition(), 0.0);
            controller.player()->reportPlayback(900.0, 7200.0, false);
            controller.navigation()->goHome();

            // And Main still resumes where Main stopped, not where Kids did.
            controller.switchProfile();
            QVERIFY(chooseProfileNamed(controller, QStringLiteral("Main")));
            QTRY_COMPARE(controller.library()->itemForId(mediaId)->resumePositionMs,
                         qint64{300'000});
            controller.playMediaId(mediaId);
            QCOMPARE(controller.player()->startPosition(), 300.0);
            controller.navigation()->goHome();

            controller.switchProfile();
            QVERIFY(chooseProfileNamed(controller, QStringLiteral("Kids")));
            QTRY_COMPARE(controller.library()->itemForId(mediaId)->resumePositionMs,
                         qint64{900'000});
        }

        QCOMPARE(durablePosition(mainId, mediaId), qint64{300'000});
        QCOMPARE(durablePosition(kidsId, mediaId), qint64{900'000});
    }

    void aWatchedTitleStaysWatchedOnlyForTheProfileThatFinishedIt()
    {
        QTemporaryDir runtimeRoot;
        QTemporaryDir library;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
        QVERIFY(writeMediaFile(library.path(), QLatin1String(kKidsFilmRelativePath)));

        ApplicationController controller;
        QVERIFY2(!controller.hasError(), qPrintable(controller.errorMessage()));
        controller.setTemporaryLibraryRoot(library.path());
        QVERIFY(chooseProfileNamed(controller, QStringLiteral("Kids")));
        QTRY_COMPARE(controller.library()->rowCount(), 1);
        const QString mediaId = controller.library()
                                    ->data(controller.library()->index(0, 0), LibraryModel::IdRole)
                                    .toString();
        controller.playMediaId(mediaId);
        controller.player()->reportPlayback(7100.0, 7200.0, false);
        controller.navigation()->goHome();

        const auto catalogWatched = [&](const QString &profileId) {
            CatalogStore store(AppPaths::catalogFile());
            return refresh(store, library.path(), profileId).constFirst().watched;
        };
        QTRY_VERIFY(catalogWatched(profileNamed(controller, QStringLiteral("Kids"))));
        QVERIFY(!catalogWatched(profileNamed(controller, QStringLiteral("Main"))));

        controller.switchProfile();
        QVERIFY(chooseProfileNamed(controller, QStringLiteral("Main")));
        QTRY_VERIFY(!controller.library()->itemForId(mediaId)->watched);
    }

    void deletingAProfileRemovesItsProgressAndOnlyItsProgress()
    {
        QTemporaryDir runtimeRoot;
        QTemporaryDir library;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
        QVERIFY(writeMediaFile(library.path(), QLatin1String(kKidsFilmRelativePath)));

        ApplicationController controller;
        QVERIFY2(!controller.hasError(), qPrintable(controller.errorMessage()));
        controller.setTemporaryLibraryRoot(library.path());
        const QString mainId = profileNamed(controller, QStringLiteral("Main"));
        const QString kidsId = profileNamed(controller, QStringLiteral("Kids"));

        QVERIFY(chooseProfileNamed(controller, QStringLiteral("Kids")));
        QTRY_COMPARE(controller.library()->rowCount(), 1);
        const QString mediaId = controller.library()
                                    ->data(controller.library()->index(0, 0), LibraryModel::IdRole)
                                    .toString();
        controller.playMediaId(mediaId);
        controller.player()->reportPlayback(900.0, 7200.0, false);
        controller.navigation()->goHome();
        controller.switchProfile();
        QVERIFY(chooseProfileNamed(controller, QStringLiteral("Main")));
        controller.playMediaId(mediaId);
        controller.player()->reportPlayback(300.0, 7200.0, false);
        controller.navigation()->goHome();
        QTRY_COMPARE(storedRowCount(kidsId), 1);
        QTRY_COMPARE(storedRowCount(mainId), 1);

        controller.profiles()->deleteProfile(kidsId);

        QTRY_COMPARE(storedRowCount(kidsId), 0);
        QCOMPARE(durablePosition(mainId, mediaId), qint64{300'000});
    }

    void deletingTheActiveProfileMovesToTheFallbacksProgress()
    {
        QTemporaryDir runtimeRoot;
        QTemporaryDir library;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
        QVERIFY(writeMediaFile(library.path(), QLatin1String(kKidsFilmRelativePath)));

        ApplicationController controller;
        QVERIFY2(!controller.hasError(), qPrintable(controller.errorMessage()));
        controller.setTemporaryLibraryRoot(library.path());
        const QString kidsId = profileNamed(controller, QStringLiteral("Kids"));

        QVERIFY(chooseProfileNamed(controller, QStringLiteral("Main")));
        QTRY_COMPARE(controller.library()->rowCount(), 1);
        const QString mediaId = controller.library()
                                    ->data(controller.library()->index(0, 0), LibraryModel::IdRole)
                                    .toString();
        controller.playMediaId(mediaId);
        controller.player()->reportPlayback(300.0, 7200.0, false);
        controller.navigation()->goHome();
        controller.switchProfile();
        QVERIFY(chooseProfileNamed(controller, QStringLiteral("Kids")));
        controller.playMediaId(mediaId);
        controller.player()->reportPlayback(900.0, 7200.0, false);
        controller.navigation()->goHome();

        controller.profiles()->deleteProfile(kidsId);

        QCOMPARE(controller.activeProfileId(), profileNamed(controller, QStringLiteral("Main")));
        QTRY_COMPARE(controller.library()->itemForId(mediaId)->resumePositionMs,
                     qint64{300'000});
        QTRY_COMPARE(storedRowCount(kidsId), 0);
    }

    void clearingWatchHistoryClearsOnlyTheActiveProfile()
    {
        QTemporaryDir runtimeRoot;
        QTemporaryDir library;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
        QVERIFY(writeMediaFile(library.path(), QLatin1String(kKidsFilmRelativePath)));

        ApplicationController controller;
        QVERIFY2(!controller.hasError(), qPrintable(controller.errorMessage()));
        controller.setTemporaryLibraryRoot(library.path());
        const QString mainId = profileNamed(controller, QStringLiteral("Main"));
        const QString kidsId = profileNamed(controller, QStringLiteral("Kids"));

        QVERIFY(chooseProfileNamed(controller, QStringLiteral("Main")));
        QTRY_COMPARE(controller.library()->rowCount(), 1);
        const QString mediaId = controller.library()
                                    ->data(controller.library()->index(0, 0), LibraryModel::IdRole)
                                    .toString();
        controller.playMediaId(mediaId);
        controller.player()->reportPlayback(300.0, 7200.0, false);
        controller.navigation()->goHome();
        controller.switchProfile();
        QVERIFY(chooseProfileNamed(controller, QStringLiteral("Kids")));
        controller.playMediaId(mediaId);
        controller.player()->reportPlayback(900.0, 7200.0, false);
        controller.navigation()->goHome();
        QTRY_COMPARE(storedRowCount(kidsId), 1);
        QTRY_COMPARE(storedRowCount(mainId), 1);

        QSignalSpy cleared(&controller, &ApplicationController::watchHistoryCleared);
        controller.clearWatchHistory();
        QTRY_COMPARE(cleared.count(), 1);

        QCOMPARE(storedRowCount(kidsId), 0);
        QCOMPARE(controller.library()->itemForId(mediaId)->resumePositionMs, qint64{0});
        QCOMPARE(durablePosition(mainId, mediaId), qint64{300'000});

        controller.switchProfile();
        QVERIFY(chooseProfileNamed(controller, QStringLiteral("Main")));
        QTRY_COMPARE(controller.library()->itemForId(mediaId)->resumePositionMs,
                     qint64{300'000});
    }
};

int main(int argc, char *argv[])
{
    QGuiApplication app(argc, argv);
    // libmpv refuses to start under a locale whose decimal separator is not a
    // dot, exactly as the application entry point guards against.
    std::setlocale(LC_NUMERIC, "C");
    WatchProgressTest test;
    return QTest::qExec(&test, argc, argv);
}
#include "tst_watch_progress.moc"
