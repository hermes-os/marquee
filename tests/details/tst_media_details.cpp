#include <array>
#include <cmath>
#include <numbers>

#include <QCollator>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QFont>
#include <QGuiApplication>
#include <QImage>
#include <QIODevice>
#include <QLocale>
#include <QQmlApplicationEngine>
#include <QQmlComponent>
#include <QQmlContext>
#include <QQmlEngine>
#include <QQuickItem>
#include <QQuickWindow>
#include <QScopeGuard>
#include <QSignalSpy>
#include <QTemporaryDir>
#include <QTest>
#include <QUrl>

#include "app/AppPaths.hpp"
#include "app/ApplicationController.hpp"
#include "catalog/MediaItem.hpp"
#include "models/BrowseSemantics.hpp"
#include "models/HomeRowsModel.hpp"
#include "models/LibraryModel.hpp"
#include "models/ShowsModel.hpp"
#include "navigation/NavigationController.hpp"
#include "support/RenderProbe.hpp"

namespace
{
[[nodiscard]] bool writeMediaFile(const QString &root, const QString &relativePath,
                                  qint64 bytes)
{
    const QFileInfo target(QDir(root).filePath(relativePath));
    if (!QDir().mkpath(target.absolutePath())) {
        return false;
    }

    QFile file(target.absoluteFilePath());
    if (!file.open(QIODevice::WriteOnly)) {
        return false;
    }
    const QByteArray contents(static_cast<qsizetype>(bytes), 'm');
    return file.write(contents) == contents.size();
}

[[nodiscard]] bool writePosterFile(const QString &root, const QString &relativePath)
{
    const QFileInfo target(QDir(root).filePath(relativePath));
    if (!QDir().mkpath(target.absolutePath())) {
        return false;
    }

    QImage poster(20, 30, QImage::Format_RGB32);
    poster.fill(Qt::darkCyan);
    return poster.save(target.absoluteFilePath(), "PNG");
}

// A projected row, built here rather than scanned, so the facts a size or a
// badge is composed from are stated by the test itself.
[[nodiscard]] MediaItem projectedItem(qint64 fileSize)
{
    return MediaItem{
        .id = QStringLiteral("root-1/arrival"),
        .libraryRootId = QStringLiteral("root-1"),
        .relativePath = QStringLiteral("Arrival (2016)/Arrival (2016).mkv"),
        .absolutePath = QStringLiteral("/library/Arrival (2016)/Arrival (2016).mkv"),
        .title = QStringLiteral("Arrival"),
        .sortTitle = QStringLiteral("arrival"),
        .mediaKind = QStringLiteral("movie"),
        .year = 2016,
        .posterRelativePath = QStringLiteral("Arrival (2016)/poster.jpg"),
        .posterAbsolutePath = QStringLiteral("/library/Arrival (2016)/poster.jpg"),
        .fileSize = fileSize,
        .modifiedAt = QDateTime::currentDateTimeUtc(),
        .resumePositionMs = 0,
        .watched = false,
        .showName = QString(),
        .seasonNumber = 0,
        .episodeNumber = 0,
        .episodeTitle = QString(),
        .showPosterRelativePath = QString(),
        .showPosterAbsolutePath = QString(),
        .showBackdropRelativePath = QString(),
        .showBackdropAbsolutePath = QString(),
        .seasonPosterRelativePath = QString(),
        .seasonPosterAbsolutePath = QString(),
        .episodeStillRelativePath = QString(),
        .episodeStillAbsolutePath = QString()};
}

// A projected episode row, built here rather than scanned, so the TV half of
// the episodes-only Home state is stated by the test itself while still
// flowing through the production ShowsModel projection.
[[nodiscard]] MediaItem projectedEpisode(const QString &id, const QString &showName, int season,
                                        int episode)
{
    MediaItem item = projectedItem(1024);
    item.id = id;
    item.mediaKind = QStringLiteral("episode");
    item.showName = showName;
    item.seasonNumber = season;
    item.episodeNumber = episode;
    return item;
}
}

class MediaDetailsTest final : public QObject
{
    Q_OBJECT

private:
    // Loads the shipped Marquee module linked into this binary so these tests
    // exercise the real Main.qml and its screens, not a replica.
    QQuickWindow *loadMainWindow(ApplicationController &controller,
                                 QQmlApplicationEngine &engine)
    {
        // A fullscreen window has no usable geometry on the test platform.
        controller.setStartFullscreen(false);

        engine.rootContext()->setContextProperty(
            QStringLiteral("appController"), &controller);
        engine.loadFromModule(QStringLiteral("Marquee"), QStringLiteral("Main"));
        if (engine.rootObjects().size() != 1) {
            return nullptr;
        }
        auto *window = qobject_cast<QQuickWindow *>(engine.rootObjects().front());
        if (window != nullptr) {
            window->resize(1600, 900);
            window->requestActivate();
        }
        return window;
    }

    [[nodiscard]] static QQuickItem *itemNamed(QQuickWindow *window, const char *name)
    {
        return window->findChild<QQuickItem *>(QLatin1String(name));
    }

    [[nodiscard]] static QString textOf(QQuickWindow *window, const char *name)
    {
        QQuickItem *item = itemNamed(window, name);
        return item == nullptr ? QString() : item->property("text").toString();
    }

    [[nodiscard]] static QString idAt(const LibraryModel *model, int row)
    {
        return model->data(model->index(row, 0), LibraryModel::IdRole).toString();
    }

    [[nodiscard]] static QImage canvasImage(QQuickItem *canvas)
    {
        QString dataUrl;
        const bool invoked = QMetaObject::invokeMethod(
            canvas, "toDataURL", Q_RETURN_ARG(QString, dataUrl),
            Q_ARG(QString, QStringLiteral("image/png")));
        const QString prefix = QStringLiteral("data:image/png;base64,");
        if (!invoked || !dataUrl.startsWith(prefix)) {
            return {};
        }
        return QImage::fromData(
            QByteArray::fromBase64(dataUrl.mid(prefix.size()).toLatin1()), "PNG");
    }

    // A show of one long season, through the production ShowsModel projection.
    static constexpr int kLongSeasonEpisodes = 400;
    // What fits on the 900 px test window plus the list's cache, with room for
    // the rows the view keeps while it moves.
    static constexpr int kLiveRowBound = 16;

    static void fillLongSeason(ApplicationController &controller)
    {
        QVector<MediaItem> episodes;
        for (int number = 1; number <= kLongSeasonEpisodes; ++number) {
            episodes.push_back(projectedEpisode(QStringLiteral("long-%1").arg(number),
                                                QStringLiteral("Long Show"), 1, number));
        }
        controller.shows()->replaceItems(episodes);
    }

    // The episode rows that exist and are not parked in the list's pool.
    [[nodiscard]] static QList<QQuickItem *> liveEpisodeRows(QQuickWindow *window)
    {
        QList<QQuickItem *> rows;
        QQuickItem *list = itemNamed(window, "showDetailEpisodes");
        if (list == nullptr) {
            return rows;
        }
        for (QQuickItem *child : list->childItems()) {
            if (child->objectName().startsWith(QLatin1String("showDetailEpisode_"))
                && child->isVisible()) {
                rows.push_back(child);
            }
        }
        return rows;
    }

    [[nodiscard]] static QQuickItem *liveEpisodeRow(QQuickWindow *window, int index)
    {
        const QString name = QStringLiteral("showDetailEpisode_%1").arg(index);
        for (QQuickItem *row : liveEpisodeRows(window)) {
            if (row->objectName() == name) {
                return row;
            }
        }
        return nullptr;
    }

    // A Behavior builds its animation on the first change, so build it now and
    // give it a duration the test can outwait. Returns how many it slowed.
    [[nodiscard]] static int slowFades(QQuickItem *row)
    {
        int slowed = 0;
        for (QObject *child : row->findChildren<QObject *>()) {
            if (!child->inherits("QQuickBehavior")) {
                continue;
            }
            qmlExecuteDeferred(child);
            for (QObject *fade : child->children()) {
                if (fade->property("duration").isValid()) {
                    fade->setProperty("duration", 4000);
                    ++slowed;
                }
            }
        }
        return slowed;
    }

    [[nodiscard]] static bool isOnScreen(QQuickWindow *window, QQuickItem *row)
    {
        const QPointF top = row->mapToScene(QPointF(0, 0));
        return top.y() >= 0 && top.y() + row->height() <= window->height();
    }

    // Opens the long show's page after the profile is chosen, which reloads
    // the catalog. `watchedThrough` marks that many leading episodes watched;
    // `request` names the episode the page lands on, as a Home card for it
    // would.
    [[nodiscard]] QQuickItem *openLongShow(ApplicationController &controller,
                                           QQuickWindow *window, int watchedThrough = 0,
                                           const QString &request = {})
    {
        window->show();
        window->requestActivate();
        // The first frame can hold the GUI thread for seconds on the
        // software scene graph, so the waits are longer than the default.
        if (!QTest::qWaitForWindowActive(window, 30000)
            || !controller.chooseProfile(controller.profiles()->profiles().at(0).id)
            || !QTest::qWaitFor([&] { return !controller.profileExitInFlight(); }, 30000)) {
            return nullptr;
        }
        fillLongSeason(controller);
        // The page opens on the episode after the last one watched.
        if (watchedThrough > 0) {
            controller.shows()->applyWatchProgress(
                QStringLiteral("long-%1").arg(watchedThrough), 0, 0, true);
        }
        controller.navigation()->goHome();
        if (!request.isEmpty()) {
            controller.shows()->requestEpisodeFocus(request);
        }
        controller.navigation()->openShowDetail(QStringLiteral("Long Show"));
        QQuickItem *scroll = nullptr;
        if (!QTest::qWaitFor([&] {
                scroll = itemNamed(window, "showDetailScroll");
                return scroll != nullptr;
            })) {
            return nullptr;
        }
        QQuickItem *screen = scroll->parentItem();
        // The remote starts on the sidebar; Right hands it to the page.
        QTest::keyClick(window, Qt::Key_Right);
        return QTest::qWaitFor([&] { return screen->hasActiveFocus(); }) ? screen : nullptr;
    }

private slots:
    void aLongSeasonBuildsOnlyTheEpisodeRowsNearTheTop()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
        ApplicationController controller;
        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY(window != nullptr);

        QQuickItem *screen = openLongShow(controller, window);
        QVERIFY(screen != nullptr);
        QCOMPARE(screen->property("episodes").toList().size(), kLongSeasonEpisodes);
        QTRY_VERIFY(liveEpisodeRow(window, 0) != nullptr);
        const qsizetype live = liveEpisodeRows(window).size();
        QVERIFY2(live >= 1 && live <= kLiveRowBound,
                 qPrintable(QStringLiteral("%1 live rows at the top").arg(live)));
        // Rows past the cache do not exist yet.
        QVERIFY(liveEpisodeRow(window, 60) == nullptr);
        QVERIFY(liveEpisodeRow(window, kLongSeasonEpisodes - 1) == nullptr);
    }

    void walkingFocusToTheEndOfALongSeasonKeepsTheLiveRowsBounded()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
        ApplicationController controller;
        controller.settings()->setReduceMotion(true);
        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY(window != nullptr);

        QQuickItem *screen = openLongShow(controller, window);
        QVERIFY(screen != nullptr);
        QCOMPARE(screen->property("focusNode").toString(), QStringLiteral("start"));

        // One season: Down from the actions enters the first row. The first
        // rows are walked key by key; each frame costs a software shadow
        // repaint on this platform, so the rest of the 400 are walked in
        // strides of the same one-row focus move, ending on the last row by key.
        QTest::keyClick(window, Qt::Key_Down);
        QCOMPARE(screen->property("focusNode").toString(), QStringLiteral("episode"));
        qsizetype mostLive = liveEpisodeRows(window).size();
        const auto checkFocusedRow = [&](int index) {
            QCOMPARE(screen->property("focusedEpisode").toInt(), index);
            QTRY_VERIFY(liveEpisodeRow(window, index) != nullptr);
            QTRY_VERIFY(isOnScreen(window, liveEpisodeRow(window, index)));
            QVERIFY(liveEpisodeRow(window, index)->property("focused").toBool());
            mostLive = qMax(mostLive, liveEpisodeRows(window).size());
        };
        for (int index = 1; index < 24; ++index) {
            QTest::keyClick(window, Qt::Key_Down);
            checkFocusedRow(index);
        }
        for (int index = 24; index < kLongSeasonEpisodes - 1; index += 19) {
            screen->setProperty("focusedEpisode", index);
            checkFocusedRow(index);
        }
        screen->setProperty("focusedEpisode", kLongSeasonEpisodes - 3);
        QTRY_VERIFY(liveEpisodeRow(window, kLongSeasonEpisodes - 3) != nullptr);
        QTest::keyClick(window, Qt::Key_Down);
        QTest::keyClick(window, Qt::Key_Down);
        checkFocusedRow(kLongSeasonEpisodes - 1);
        // The list's end holds focus when nothing follows it.
        QTest::keyClick(window, Qt::Key_Down);
        checkFocusedRow(kLongSeasonEpisodes - 1);
        QVERIFY2(mostLive <= kLiveRowBound,
                 qPrintable(QStringLiteral("%1 live rows while walking").arg(mostLive)));
        QVERIFY2(liveEpisodeRows(window).size() <= kLiveRowBound,
                 qPrintable(QStringLiteral("%1 live rows at the end").arg(liveEpisodeRows(window).size())));

        // The pointer reaches the row it is over, however far down the list.
        QQuickItem *last = liveEpisodeRow(window, kLongSeasonEpisodes - 1);
        QVERIFY(last != nullptr);
        const QPoint over = last->mapToScene(QPointF(last->width() / 2, last->height() / 2)).toPoint();
        QTest::mouseMove(window, over);
        QTRY_VERIFY(last->property("hovered").toBool());

        // And Up walks back out through the rows to the actions.
        screen->setProperty("focusedEpisode", 3);
        for (int step = 0; step < 3; ++step) {
            QTest::keyClick(window, Qt::Key_Up);
        }
        QCOMPARE(screen->property("focusNode").toString(), QStringLiteral("episode"));
        QCOMPARE(screen->property("focusedEpisode").toInt(), 0);
        QTest::keyClick(window, Qt::Key_Up);
        QCOMPARE(screen->property("focusNode").toString(), QStringLiteral("start"));
        QTRY_VERIFY(liveEpisodeRow(window, 0) != nullptr);
        QTRY_COMPARE(qRound(itemNamed(window, "showDetailScroll")->property("contentY").toReal()),
                     qRound(itemNamed(window, "showDetailScroll")->property("originY").toReal()));
        QVERIFY(liveEpisodeRows(window).size() <= kLiveRowBound);
    }

    void openingOntoAnUpNextEpisodeDeepInALongSeasonShowsItFocused()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
        ApplicationController controller;
        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY(window != nullptr);

        // Row 350 is up next: the 350 before it are watched. A Home card for
        // the up-next episode opens the page on its row.
        QQuickItem *screen = openLongShow(controller, window, 350, QStringLiteral("long-351"));
        QVERIFY(screen != nullptr);
        QCOMPARE(controller.shows()->showDetails(QStringLiteral("Long Show"))
                     .value(QStringLiteral("upNextId")).toString(),
                 QStringLiteral("long-351"));
        QTRY_COMPARE(screen->property("focusNode").toString(), QStringLiteral("episode"));
        QCOMPARE(screen->property("focusedEpisode").toInt(), 350);

        QTRY_VERIFY(liveEpisodeRow(window, 350) != nullptr);
        QQuickItem *row = liveEpisodeRow(window, 350);
        QTRY_VERIFY(isOnScreen(window, row));
        QVERIFY(row->property("focused").toBool());
        QVERIFY(row->findChild<QQuickItem *>(QStringLiteral("episodeRowUpNext"))->isVisible());
        const qsizetype live = liveEpisodeRows(window).size();
        QVERIFY2(live <= kLiveRowBound, qPrintable(QStringLiteral("%1 live rows at row 350").arg(live)));
        QVERIFY(liveEpisodeRow(window, 0) == nullptr);

        // A progress update reloads the episodes. The new model must not
        // bring the list's current item, episode 0, back to keep it built.
        controller.shows()->applyWatchProgress(QStringLiteral("long-351"), 0, 0, true);
        QTRY_VERIFY(liveEpisodeRow(window, 350) != nullptr);
        QTRY_VERIFY(isOnScreen(window, liveEpisodeRow(window, 350)));
        QVERIFY(liveEpisodeRow(window, 350)->property("focused").toBool());
        QVERIFY(liveEpisodeRow(window, 0) == nullptr);

        // The remote walks on from there, one row each way.
        QTest::keyClick(window, Qt::Key_Down);
        QCOMPARE(screen->property("focusedEpisode").toInt(), 351);
        QTRY_VERIFY(liveEpisodeRow(window, 351) != nullptr);
        QTRY_VERIFY(isOnScreen(window, liveEpisodeRow(window, 351)));
        QTest::keyClick(window, Qt::Key_Up);
        QTest::keyClick(window, Qt::Key_Up);
        QCOMPARE(screen->property("focusedEpisode").toInt(), 349);
        QTRY_VERIFY(liveEpisodeRow(window, 349) != nullptr);
        QTRY_VERIFY(isOnScreen(window, liveEpisodeRow(window, 349)));
    }

    void aRowScrolledOutMidFadeComesBackAtRest()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
        ApplicationController controller;
        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY(window != nullptr);
        QQuickItem *screen = openLongShow(controller, window);
        QVERIFY(screen != nullptr);
        QQuickItem *scroll = itemNamed(window, "showDetailScroll");
        QVERIFY(scroll != nullptr);

        // Slow every live row's fades so a fade begun by the remote is still
        // under way when the wheel takes the page away.
        QTRY_VERIFY(liveEpisodeRow(window, 0) != nullptr);
        for (QQuickItem *row : liveEpisodeRows(window)) {
            QVERIFY(slowFades(row) == 2);
        }

        // Down onto row 1: its scale fade up is under way when the wheel
        // takes the page far away.
        QTest::keyClick(window, Qt::Key_Down);
        QCOMPARE(screen->property("focusNode").toString(), QStringLiteral("episode"));
        QTest::keyClick(window, Qt::Key_Down);
        QCOMPARE(screen->property("focusedEpisode").toInt(), 1);
        QTRY_VERIFY(liveEpisodeRow(window, 1) != nullptr);
        QQuickItem *fading = liveEpisodeRow(window, 1)
                                 ->findChild<QQuickItem *>(QStringLiteral("episodeRowSurface"));
        QVERIFY(fading != nullptr);
        QTRY_VERIFY_WITH_TIMEOUT(fading->scale() > 1.0005 && fading->scale() < 1.03, 3000);

        scroll->setProperty("contentY", scroll->property("contentY").toReal() + 140.0 * 200);
        QVERIFY(QMetaObject::invokeMethod(scroll, "forceLayout"));
        QVERIFY(liveEpisodeRow(window, 0) == nullptr);
        QVERIFY(!liveEpisodeRows(window).isEmpty());

        // Every row on the page now shows an unfocused episode. None may
        // still be partway through the scale of the one it showed before,
        // and no wait lets a leftover fade finish first.
        for (QQuickItem *row : liveEpisodeRows(window)) {
            QQuickItem *surface = row->findChild<QQuickItem *>(QStringLiteral("episodeRowSurface"));
            QVERIFY(surface != nullptr);
            QVERIFY2(!row->property("focused").toBool(), qPrintable(row->objectName()));
            QVERIFY2(qFuzzyCompare(surface->scale(), 1.0),
                     qPrintable(QStringLiteral("%1 at scale %2").arg(row->objectName()).arg(surface->scale())));
        }
    }

    void detailsDescribeTheCatalogFactsOfTheProjectedTitle()
    {
        LibraryModel model;
        const MediaItem item = projectedItem(1610612736);
        model.replaceItems({item});

        const QVariantMap details = model.detailsForId(item.id);

        QCOMPARE(details.value(QStringLiteral("mediaId")).toString(), item.id);
        QCOMPARE(details.value(QStringLiteral("title")).toString(),
                 QStringLiteral("Arrival"));
        QCOMPARE(details.value(QStringLiteral("year")).toInt(), 2016);
        QCOMPARE(details.value(QStringLiteral("posterUrl")).toUrl(),
                 QUrl::fromLocalFile(item.posterAbsolutePath));
        QCOMPARE(details.value(QStringLiteral("formatBadge")).toString(),
                 QStringLiteral("MKV"));
        QCOMPARE(details.value(QStringLiteral("fileSizeText")).toString(),
                 QStringLiteral("1.5 GB"));
        // The path inside the library, which locates the file without recording
        // where its root is currently mounted.
        QCOMPARE(details.value(QStringLiteral("relativePath")).toString(),
                 item.relativePath);
        // No viewing has recorded a runtime or a position, so Resume has no
        // input: the pair is Start alone and the runtime slot is empty.
        QCOMPARE(details.value(QStringLiteral("hasResume")).toBool(), false);
        QVERIFY(details.value(QStringLiteral("resumeTime")).toString().isEmpty());
        QVERIFY(details.value(QStringLiteral("runtime")).toString().isEmpty());
    }

    void detailsResumeFactsAreEmptyUntilAViewingRecordsThem()
    {
        LibraryModel model;
        MediaItem item = projectedItem(1610612736);
        model.replaceItems({item});

        QVERIFY(!model.detailsForId(item.id).value(QStringLiteral("hasResume")).toBool());

        model.applyWatchProgress(item.id, 600'000, 7'200'000, 1);

        const QVariantMap resumed = model.detailsForId(item.id);
        QVERIFY(resumed.value(QStringLiteral("hasResume")).toBool());
        QCOMPARE(resumed.value(QStringLiteral("resumeTime")).toString(),
                 QStringLiteral("10:00"));
        QCOMPARE(resumed.value(QStringLiteral("runtime")).toString(),
                 QStringLiteral("2h 0m"));
    }

    void detailsResumeTimesFollowTheReleasedPlaybackFormat_data()
    {
        QTest::addColumn<qint64>("positionMs");
        QTest::addColumn<QString>("expected");

        QTest::newRow("seconds") << qint64{65'000} << QStringLiteral("1:05");
        QTest::newRow("minutes") << qint64{600'000} << QStringLiteral("10:00");
        QTest::newRow("hours") << qint64{3'723'000} << QStringLiteral("1:02:03");
    }

    void detailsResumeTimesFollowTheReleasedPlaybackFormat()
    {
        QFETCH(qint64, positionMs);
        QFETCH(QString, expected);

        LibraryModel model;
        MediaItem item = projectedItem(1610612736);
        model.replaceItems({item});
        model.applyWatchProgress(item.id, positionMs, 7'200'000, 1);

        QCOMPARE(model.detailsForId(item.id).value(QStringLiteral("resumeTime")).toString(),
                 expected);
    }

    void detailsSimilarMoviesRankFranchiseBeforeDecadeAndShareNothing()
    {
        // The recommendation engine's franchise-first ranking over the
        // offline facts the projection holds: a shared family first, then a
        // shared decade, then nothing at all for a title with no overlap.
        auto movie = [](const QString &id, const QString &title, int year) {
            MediaItem item = projectedItem(1024);
            item.id = id;
            item.title = title;
            item.sortTitle = title.toLower();
            item.year = year;
            return item;
        };
        LibraryModel model;
        model.replaceItems({movie(QStringLiteral("root-1/dune-part-two"),
                                  QStringLiteral("Dune Part Two"), 2024),
                            movie(QStringLiteral("root-1/dune"), QStringLiteral("Dune"), 2021),
                            movie(QStringLiteral("root-1/oppenheimer"),
                                  QStringLiteral("Oppenheimer"), 2023),
                            movie(QStringLiteral("root-1/moon"), QStringLiteral("Moon"), 2009)});

        const QVariantList similar =
            model.similarMovies(QStringLiteral("root-1/dune-part-two"), 10);
        QCOMPARE(similar.size(), 2);
        QCOMPARE(similar.at(0).toMap().value(QStringLiteral("mediaId")).toString(),
                 QStringLiteral("root-1/dune"));
        QCOMPARE(similar.at(1).toMap().value(QStringLiteral("mediaId")).toString(),
                 QStringLiteral("root-1/oppenheimer"));

        QVERIFY(model.similarMovies(QStringLiteral("root-1/moon"), 10).isEmpty());
        QVERIFY(model.similarMovies(QStringLiteral("not-a-media-id"), 10).isEmpty());
    }

    void detailsSimilarMoviesBreakEqualScoreTiesInTheBrowseOrderYearFirst()
    {
        // BrowseSnapshotStore.swift:2016-2041: the movie browse order is
        // franchise family, then year ascending, then title — equal-score
        // recommendations hold that order, not an alphabetical one. Both
        // candidates share the source's family and sit two years either side
        // of it inside the same decade, so their franchise, proximity, and
        // decade terms are identical by construction; only the tie-break
        // separates them, and the alphabetical order (Beta before Zulu) is
        // the reverse of the year order (2022 before 2026).
        auto movie = [](const QString &id, const QString &title, int year) {
            MediaItem item = projectedItem(1024);
            item.id = id;
            item.title = title;
            item.sortTitle = title.toLower();
            item.year = year;
            return item;
        };
        LibraryModel model;
        model.replaceItems(
            {movie(QStringLiteral("root-1/avatar"), QStringLiteral("Avatar"), 2024),
             movie(QStringLiteral("root-1/avatar-beta"), QStringLiteral("Avatar Beta"), 2026),
             movie(QStringLiteral("root-1/avatar-zulu"), QStringLiteral("Avatar Zulu"), 2022)});

        const QVariantList similar =
            model.similarMovies(QStringLiteral("root-1/avatar"), 10);
        QCOMPARE(similar.size(), 2);
        QCOMPARE(similar.at(0).toMap().value(QStringLiteral("mediaId")).toString(),
                 QStringLiteral("root-1/avatar-zulu"));
        QCOMPARE(similar.at(1).toMap().value(QStringLiteral("mediaId")).toString(),
                 QStringLiteral("root-1/avatar-beta"));

        // Unknown years sort last (the oracle's `year ?? Int.max`,
        // BrowseSnapshotStore.swift:2039). The undated source below keeps
        // every candidate at the bare family score — no proximity term
        // (source or candidate year unknown) and no decade term (source
        // decade unknown) — so the three candidates tie genuinely and
        // only the year arm separates them. Dropping the INT_MAX
        // sentinel (comparing raw `year` with 0 < every date) fails here
        // with the undated title first.
        auto undated = [](const QString &id, const QString &title, int year) {
            MediaItem item = projectedItem(1024);
            item.id = id;
            item.title = title;
            item.sortTitle = title.toLower();
            item.year = year;
            return item;
        };
        model.replaceItems(
            {undated(QStringLiteral("root-1/avatar"), QStringLiteral("Avatar"), 0),
             undated(QStringLiteral("root-1/avatar-beta"), QStringLiteral("Avatar Beta"), 2026),
             undated(QStringLiteral("root-1/avatar-zulu"), QStringLiteral("Avatar Zulu"), 2022),
             undated(QStringLiteral("root-1/avatar-aaa"), QStringLiteral("Avatar Aaa"), 0)});
        const QVariantList withUndated =
            model.similarMovies(QStringLiteral("root-1/avatar"), 10);
        QCOMPARE(withUndated.size(), 3);
        QCOMPARE(withUndated.at(0).toMap().value(QStringLiteral("mediaId")).toString(),
                 QStringLiteral("root-1/avatar-zulu"));
        QCOMPARE(withUndated.at(1).toMap().value(QStringLiteral("mediaId")).toString(),
                 QStringLiteral("root-1/avatar-beta"));
        QCOMPARE(withUndated.at(2).toMap().value(QStringLiteral("mediaId")).toString(),
                 QStringLiteral("root-1/avatar-aaa"));
    }

    void detailsSimilarMoviesCollateNormalizedFamiliesInTheCurrentLocale()
    {
        const QLocale previousLocale;
        const auto restoreLocale = qScopeGuard([previousLocale] {
            QLocale::setDefault(previousLocale);
        });
        QLocale::setDefault(QLocale(QLocale::English, QLocale::UnitedStates));

        const MediaItem source = projectedItem(1024);
        MediaItem orbital = source;
        orbital.id = QStringLiteral("root-1/orbital");
        orbital.title = QStringLiteral("Ørbital");
        orbital.sortTitle = orbital.title.toLower();
        MediaItem zebra = source;
        zebra.id = QStringLiteral("root-1/zebra");
        zebra.title = QStringLiteral("Zebra");
        zebra.sortTitle = zebra.title.toLower();

        // BrowseSnapshotStore.swift:2034-2042 uses localizedCaseInsensitiveCompare.
        // Ø survives normalization: in en_US, "ørbital" precedes "zebra",
        // but bytewise `<` reverses them. Pin both orders so this fixture
        // cannot silently become an ASCII-only or collator-equivalent pair.
        const QString orbitalFamily = browse::franchiseKey(orbital.title);
        const QString zebraFamily = browse::franchiseKey(zebra.title);
        QCOMPARE(orbitalFamily, QStringLiteral("ørbital"));
        QCOMPARE(zebraFamily, QStringLiteral("zebra"));
        QVERIFY(zebraFamily < orbitalFamily);
        QCollator collator;
        collator.setCaseSensitivity(Qt::CaseInsensitive);
        QVERIFY(collator.compare(orbitalFamily, zebraFamily) < 0);

        // Both candidates share only Arrival's decade, with identical years
        // and scores. The old family `<` puts zebra first in either input
        // order, failing the first result assertion below.
        LibraryModel model;
        for (const bool reverse : {false, true}) {
            model.replaceItems(reverse ? QVector<MediaItem>{source, orbital, zebra}
                                       : QVector<MediaItem>{source, zebra, orbital});
            const QVariantList similar = model.similarMovies(source.id, 10);
            QCOMPARE(similar.size(), 2);
            QCOMPARE(similar.at(0).toMap().value(QStringLiteral("mediaId")).toString(),
                     orbital.id);
            QCOMPARE(similar.at(1).toMap().value(QStringLiteral("mediaId")).toString(),
                     zebra.id);
        }
    }

    void detailsSimilarMoviesCarryWhatTheCardBindsTo()
    {
        LibraryModel model;
        const MediaItem item = projectedItem(1610612736);
        model.replaceItems({item});

        MediaItem sibling = projectedItem(734003200);
        sibling.id = QStringLiteral("root-1/arrival-two");
        sibling.title = QStringLiteral("Arrival Two");
        sibling.sortTitle = QStringLiteral("arrival two");
        model.replaceItems({item, sibling});

        const QVariantList similar = model.similarMovies(item.id, 10);
        QCOMPARE(similar.size(), 1);
        const QVariantMap entry = similar.at(0).toMap();
        QCOMPARE(entry.value(QStringLiteral("mediaId")).toString(), sibling.id);
        QCOMPARE(entry.value(QStringLiteral("title")).toString(),
                 QStringLiteral("Arrival Two"));
        QCOMPARE(entry.value(QStringLiteral("posterUrl")).toUrl(),
                 QUrl::fromLocalFile(sibling.posterAbsolutePath));
        QCOMPARE(entry.value(QStringLiteral("formatBadge")).toString(),
                 QStringLiteral("MKV"));
        QVERIFY(!entry.value(QStringLiteral("metadata")).toString().isEmpty());
    }

    void detailsSizeATitleInGigabytesOnlyOnceItReachesOne_data()
    {
        QTest::addColumn<qint64>("fileSize");
        QTest::addColumn<QString>("expected");

        QTest::newRow("one gigabyte") << qint64{1073741824} << QStringLiteral("1.0 GB");
        QTest::newRow("one and a half gigabytes")
            << qint64{1610612736} << QStringLiteral("1.5 GB");
        QTest::newRow("seven hundred megabytes")
            << qint64{734003200} << QStringLiteral("700 MB");
    }

    void detailsSizeATitleInGigabytesOnlyOnceItReachesOne()
    {
        QFETCH(qint64, fileSize);
        QFETCH(QString, expected);

        LibraryModel model;
        const MediaItem item = projectedItem(fileSize);
        model.replaceItems({item});

        QCOMPARE(model.detailsForId(item.id)
                     .value(QStringLiteral("fileSizeText"))
                     .toString(),
                 expected);
    }

    void detailsForATitleTheProjectionNoLongerHoldsAreEmpty()
    {
        LibraryModel model;
        model.replaceItems({projectedItem(1610612736)});

        QVERIFY(model.detailsForId(QStringLiteral("not-a-media-id")).isEmpty());
    }

    void openingDetailsForAnIdTheLibraryNoLongerHoldsIsReportedNotOpened()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        ApplicationController controller;
        const NavigationController::Route before = controller.navigation()->route();

        controller.showMediaDetails(QStringLiteral("not-a-media-id"));

        QVERIFY(controller.hasError());
        QCOMPARE(controller.errorTitle(), QStringLiteral("Library"));
        QCOMPARE(controller.navigation()->route(), before);
        QVERIFY(controller.navigation()->selectedMediaId().isEmpty());
    }

    // HomeDetailView.swift:191-196 answers a both-empty library with the
    // scanning state while a scan runs and the whole-surface empty state
    // (:477-492) once it has completed. The `!scanning` term therefore
    // lives on `libraryEmptyState`, never on a dead in-rows slot: :632-643
    // is unreachable dead code in the released app (:191 already answers
    // the both-empty state instead of this surface), so v3 deliberately
    // does NOT reproduce `homeSectionEmptyBlock` at all. An episodes-only
    // library stays on the composed surface and shows its TV rows there
    // (Recently Added holds one card per show), not an empty movie grid.
    //
    // Negative controls quoted in the change notes:
    //  - dropping `!root.scanning` from `libraryEmptyState` fails the
    //    both-empty scanning pass with "the settled empty state paints
    //    while a scan is in progress";
    //  - re-adding a `homeSectionEmptyBlock` item fails the upfront
    //    absence check with "Home keeps no in-rows empty block".
    void anEpisodesOnlyLibraryStaysOnTheComposedSurfaceWithoutAMoviesBlock()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        ApplicationController controller;
        controller.settings()->setLeanBackMode(false);
        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY2(window != nullptr, "qml/Main.qml did not load from the module");
        controller.navigation()->goHome();

        // The shell's own first scan settles before the projections below, so
        // its empty result cannot land on top of the driven states.
        QTRY_VERIFY(!controller.scanning());

        QQuickItem *viewport =
            window->findChild<QQuickItem *>(QStringLiteral("homeRowsViewport"));
        QQuickItem *scanState =
            window->findChild<QQuickItem *>(QStringLiteral("libraryScanState"));
        QQuickItem *emptyState =
            window->findChild<QQuickItem *>(QStringLiteral("libraryEmptyState"));
        QVERIFY2(viewport != nullptr, "Home has no grid viewport");
        QVERIFY(scanState != nullptr);
        QVERIFY(emptyState != nullptr);

        // The dead in-rows slot is gone, not hidden: any lookup naming it
        // must come back empty, so a regression re-adding the item fails
        // here rather than hiding behind a visibility check.
        QVERIFY2(window->findChild<QQuickItem *>(QStringLiteral("homeSectionEmptyBlock"))
                     == nullptr,
                 "Home keeps no in-rows empty block");

        // An episodes-only library, settled: the composed surface and nothing
        // else — no block, no whole-surface scanning or empty state. The
        // episodes flow through the production ShowsModel projection — no
        // test shortcut — so this fails if HomeScreen's real episode-count
        // binding breaks.
        const QVector<MediaItem> episodes{
            projectedEpisode(QStringLiteral("ep-1"), QStringLiteral("The Wire"), 1, 1),
            projectedEpisode(QStringLiteral("ep-2"), QStringLiteral("The Wire"), 1, 2),
            projectedEpisode(QStringLiteral("ep-3"), QStringLiteral("The Wire"), 2, 1)};
        controller.library()->replaceItems({});
        controller.shows()->replaceItems(episodes);
        controller.homeRows()->replaceItems(episodes);
        QCOMPARE(controller.shows()->episodeCount(), 3);
        // The composed surface stands with the TV rows the oracle draws there
        // (HomeDetailView.swift:612-648): one Recently Added card for the
        // show, and no movie row.
        QTRY_VERIFY(viewport->isVisible());
        QTRY_COMPARE(controller.homeRows()->rowCount(), 1);
        QCOMPARE(controller.homeRows()
                     ->data(controller.homeRows()->index(0), HomeRowsModel::RowIdRole)
                     .toString(),
                 QStringLiteral("recently-added"));
        QTRY_VERIFY(itemNamed(window, "homeRows") != nullptr);
        QCOMPARE(itemNamed(window, "homeRows")->property("count").toInt(), 1);
        QCOMPARE(textOf(window, "homeTitleCount"),
                 QStringLiteral("0 movies  /  3 episodes"));
        QCOMPARE(controller.library()->rowCount(), 0);
        QVERIFY(!scanState->isVisible());
        QVERIFY(!emptyState->isVisible());

        // An episodes-only library, scanning: still the composed surface —
        // the TV half keeps the library out of the whole-surface scanning
        // state. Driven through the controller's own refresh accounting so
        // the screen's `scanning` binding to `appController.scanning` stays
        // live: writing the screen property directly would replace that
        // binding and stop exercising production from that write on.
        QSignalSpy scanSpy(&controller, &ApplicationController::scanningChanged);
        controller.requestCatalogRefresh();
        QTRY_VERIFY(controller.scanning());
        QVERIFY(!scanState->isVisible());
        QVERIFY(!emptyState->isVisible());
        QTRY_VERIFY(!controller.scanning());

        // A both-empty library, settled: the whole-surface empty state
        // answers (:191-196), and the settled copy reads the oracle's own
        // :483/:486 copy. Dropping `!root.scanning` from `libraryEmptyState`
        // fails the scanning pass below instead.
        controller.shows()->replaceItems({});
        controller.library()->replaceItems({});
        controller.homeRows()->replaceItems({});
        QTRY_VERIFY(emptyState->isVisible());
        QCOMPARE(textOf(window, "libraryEmptyTitle"), QStringLiteral("No content found"));
        QVERIFY(!scanState->isVisible());

        // A both-empty library, scanning: the whole-surface scanning state,
        // never the settled empty one — this is the pass that falsifies the
        // `!scanning` term. A `libraryEmptyState` gate of bare
        // `root.libraryEmpty` fails here with "the settled empty state
        // paints while a scan is in progress".
        controller.requestCatalogRefresh();
        QTRY_VERIFY(controller.scanning());
        QTRY_VERIFY(scanState->isVisible());
        QVERIFY2(!emptyState->isVisible(),
                 "the settled empty state paints while a scan is in progress");
        QTRY_VERIFY(!controller.scanning());

        // A movie arriving restores the composed surface.
        controller.library()->replaceItems({projectedItem(1024)});
        controller.homeRows()->replaceItems({projectedItem(1024)});
        QTRY_VERIFY(viewport->isVisible());

        // The scan-state signal fired for every driven transition above, so
        // the screen's binding to the controller stayed live for the whole
        // case — no direct write ever replaced it.
        QVERIFY(!scanSpy.isEmpty());
    }

    void theDetailsSurfaceShowsTheFactsOfTheTitleItWasOpenedFor()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        QTemporaryDir library;
        QVERIFY(writeMediaFile(library.path(),
                               QStringLiteral("Arrival (2016)/Arrival (2016).mkv"),
                               2 * 1024 * 1024));
        QVERIFY(writePosterFile(library.path(),
                                QStringLiteral("Arrival (2016)/poster.png")));
        QVERIFY(writeMediaFile(library.path(), QStringLiteral("Moon.mkv"),
                               3 * 1024 * 1024));

        ApplicationController controller;
        controller.setTemporaryLibraryRoot(library.path());
        QTRY_COMPARE(controller.library()->rowCount(), 2);

        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY2(window != nullptr, "qml/Main.qml did not load from the module");
        controller.navigation()->goHome();

        controller.showMediaDetails(idAt(controller.library(), 0));
        QTRY_VERIFY(itemNamed(window, "detailsScreen") != nullptr);

        QCOMPARE(textOf(window, "detailsTitle"), QStringLiteral("Arrival"));
        QCOMPARE(textOf(window, "detailsMetadata"), QStringLiteral("2016"));
        QCOMPARE(textOf(window, "detailsFileInfoSize"), QStringLiteral("2 MB"));
        QCOMPARE(textOf(window, "detailsFileInfoPath"),
                 QStringLiteral("Arrival (2016)/Arrival (2016).mkv"));

        QQuickItem *poster = itemNamed(window, "detailsPoster");
        QVERIFY(poster != nullptr);
        auto *art = poster->findChild<QQuickItem *>(QStringLiteral("posterArt"));
        QVERIFY(art != nullptr);
        QCOMPARE(art->property("source").toUrl(),
                 QUrl::fromLocalFile(QDir(library.path())
                                         .filePath(QStringLiteral("Arrival (2016)/poster.png"))));
        // The composed slot draws the poster contract beside the hero preview:
        // its artwork source carries the composed poster, and the hero preview
        // beside it shows the artwork while the composed fallback names the
        // artwork-less title.
        QVERIFY(poster != nullptr);
        QQuickItem *preview = itemNamed(window, "detailsPosterPreview");
        QVERIFY(preview != nullptr);
        QTRY_VERIFY(preview->isVisible());

        // The hero fallback blur sources the plain fallback Image: the
        // blur's own source item is the Image carrying the pixels — not a
        // plain Item with no layer enabled — so the effect stays live when
        // the fallback resolves. A regression that repoints the blur at a
        // layer-less plain Item fails below even though the blur item
        // still exists. (Whether a layer is enabled lives behind the
        // grouped `layer` property, which is not readable back through
        // QObject::property(), so the suite judges the source identity
        // and its Image type instead.)
        auto *heroFallback = itemNamed(window, "detailsHeroFallback");
        QVERIFY2(heroFallback != nullptr, "the details hero paints no fallback image");
        QVERIFY2(heroFallback->inherits("QQuickImage"),
                 "the hero blur source is not the fallback image");
        auto *heroBlur = itemNamed(window, "detailsHeroBlur");
        QVERIFY2(heroBlur != nullptr, "the details hero paints no fallback blur");
        QCOMPARE(heroBlur->property("source").value<QQuickItem *>(), heroFallback);

        // The surface follows the title it is opened for, and a title with no
        // release year is described without a stray separator.
        controller.showMediaDetails(idAt(controller.library(), 1));

        QTRY_COMPARE(textOf(window, "detailsTitle"), QStringLiteral("Moon"));
        QCOMPARE(textOf(window, "detailsMetadata"), QString());
        QCOMPARE(textOf(window, "detailsFileInfoSize"), QStringLiteral("3 MB"));
        QCOMPARE(textOf(window, "detailsFileInfoPath"), QStringLiteral("Moon.mkv"));
        // MovieCard.swift:214-222 draws no artwork for a title without a
        // sidecar; the hero preview beside the composed slot hides with it,
        // and the composed slot's fallback beneath names the title.
        QTRY_COMPARE(art->property("source").toUrl(), QUrl());
        QTRY_VERIFY(!preview->isVisible());
        auto *fallback = poster->findChild<QQuickItem *>(QStringLiteral("posterFallback"));
        QVERIFY(fallback != nullptr);
        QCOMPARE(fallback->findChild<QQuickItem *>(QStringLiteral("posterFallbackTitle"))
                     ->property("text").toString(),
                 QStringLiteral("Moon"));
    }

    void playOnTheDetailsSurfaceOpensThatTitleInThePlayer()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        QTemporaryDir library;
        QVERIFY(writeMediaFile(library.path(), QStringLiteral("Arrival.2016.mkv"),
                               2 * 1024 * 1024));

        ApplicationController controller;
        controller.setTemporaryLibraryRoot(library.path());
        QTRY_COMPARE(controller.library()->rowCount(), 1);

        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY2(window != nullptr, "qml/Main.qml did not load from the module");
        controller.navigation()->goHome();

        const std::optional<MediaItem> expected =
            controller.library()->itemForId(idAt(controller.library(), 0));
        QVERIFY(expected.has_value());

        controller.showMediaDetails(expected->id);

        QQuickItem *screen = nullptr;
        QTRY_VERIFY((screen = itemNamed(window, "detailsScreen")) != nullptr);
        QVERIFY(itemNamed(window, "detailsPlayButton") != nullptr);
        QTRY_VERIFY(screen->hasActiveFocus());

        QTest::keyClick(window, Qt::Key_Return);

        QTRY_COMPARE(controller.navigation()->route(), NavigationController::Route::Player);
        QCOMPARE(controller.navigation()->selectedMediaId(), expected->id);
        QCOMPARE(controller.player()->title(), expected->title);
        QCOMPARE(controller.player()->currentFileUrl(),
                 QUrl::fromLocalFile(expected->absolutePath));
        QVERIFY2(!controller.hasError(), qPrintable(controller.errorMessage()));
    }

    // The movie action pair shares `detailFocusSurface` with the released
    // screen (DetailFocusSurfaceModifier.swift:16-27): no scale, a 20-point
    // glow, and the same padded inner ring and outside shadows as every other
    // focus chrome. The movie actions are radius-8 rounded rectangles
    // (Marquee/Features/Detail/Views/MovieDetailView.swift:402-403 around
    // Start, :436-437 around Resume, cornerRadiusMD in
    // Marquee/Theme/MarqueeTheme.swift:245), and the focus ring follows that
    // surface radius.
    void detailsActionPairMatchesTheReleasedGoldGradientAndFocusSurface()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        QTemporaryDir library;
        QVERIFY(writeMediaFile(library.path(), QStringLiteral("Arrival.2016.mkv"),
                               2 * 1024 * 1024));

        ApplicationController controller;
        controller.setTemporaryLibraryRoot(library.path());
        QTRY_COMPARE(controller.library()->rowCount(), 1);

        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY2(window != nullptr, "qml/Main.qml did not load from the module");
        controller.navigation()->goHome();
        controller.showMediaDetails(idAt(controller.library(), 0));

        QQuickItem *screen = nullptr;
        QTRY_VERIFY((screen = itemNamed(window, "detailsScreen")) != nullptr);
        QTRY_VERIFY(screen->hasActiveFocus());

        // MarqueeTheme.scaled reads lean-back mode, whose default is on; the
        // fixed oracle sizes are the compact ones, so the pair is measured
        // there, as the composition test below does.
        controller.settings()->setLeanBackMode(false);
        QTRY_COMPARE(itemNamed(window, "detailsPlayButton")
                         ->property("horizontalPadding")
                         .toReal(),
                     28.0);

        auto *button = itemNamed(window, "detailsPlayButton");
        QVERIFY(button != nullptr);
        auto *ring = button->findChild<QQuickItem *>(QStringLiteral("focusRing"));
        auto *halo = button->findChild<QQuickItem *>(QStringLiteral("focusHalo"));
        QVERIFY(ring != nullptr);
        QVERIFY(halo != nullptr);
        auto *focusFrame = halo->parentItem();
        QVERIFY(focusFrame != nullptr);

        QTRY_VERIFY(focusFrame->property("active").toBool());
        QVERIFY(focusFrame->isVisible());
        QVERIFY(ring->isVisible());
        QVERIFY(halo->isVisible());
        QCOMPARE(focusFrame->property("focusScale").toReal(), 1.0);
        QCOMPARE(focusFrame->property("focusedGlowRadius").toReal(), 20.0);
        QCOMPARE(focusFrame->property("ringWidth").toReal(), 2.25);
        QCOMPARE(focusFrame->property("ringOpacity").toReal(), 0.95);
        QVERIFY(std::abs(focusFrame->scale() - 1.0) < 0.001);
        QVERIFY(std::abs(button->scale() - 1.0) < 0.001);
        QCOMPARE(focusFrame->width(), button->width());
        QCOMPARE(focusFrame->height(), button->height());
        QCOMPARE(ring->x(), 2.25);
        QCOMPARE(ring->y(), 2.25);
        QCOMPARE(ring->width(), button->width() - 4.5);
        QCOMPARE(ring->height(), button->height() - 4.5);
        QVERIFY(halo->x() < 0.0);
        QVERIFY(halo->y() < 0.0);
        QVERIFY(halo->x() + halo->width() > button->width());
        QVERIFY(halo->y() + halo->height() > button->height());

        // The control fills the released gold gradient
        // (MovieDetailView.swift:402-413): the ring FocusFrame paints above
        // the fill, so it blends over the gradient stops, and the accent glow
        // outside the control tints the background purple. The probe accepts
        // the screen blend over either stop, because the ring's edge crosses
        // the gradient between them.
        const QColor goldTop = QColor("#c9a84c");
        // MovieDetailView.swift:408 composites accentSecondary at 0.85 over
        // the page behind the button, which is dark but not black
        // (:47-49 paints MarqueeTheme.background there; MarqueeTheme.swift:105
        // fixes it at #0d0b1a). The QML blends that composite directly
        // against the screen's pageBackground, so the stop is judged by
        // recomputing the same blend here, not by echoing a literal.
        const QColor pageBackground = screen->property("pageBackground").value<QColor>();
        const QColor goldBottom = render_probe::sourceOverOn(pageBackground, goldTop, 0.85);
        const QColor goldMid((goldTop.red() + goldBottom.red() + 1) / 2,
                             (goldTop.green() + goldBottom.green() + 1) / 2,
                             (goldTop.blue() + goldBottom.blue() + 1) / 2);
        const auto isRingOverGold = [&](const QColor &pixel) {
            return render_probe::isScreenOf(pixel, goldTop, QColor("#7b5ea7"), 0.95)
                || render_probe::isScreenOf(pixel, goldBottom, QColor("#7b5ea7"), 0.95)
                || render_probe::isScreenOf(pixel, goldMid, QColor("#7b5ea7"), 0.95);
        };
        const auto isGlowPixel = render_probe::isAccentGlowPixel;
        // The gradient's own stops are the color contract: the top stop is
        // full gold and the bottom stop is the composited 0.85 ink,
        // top-leading to bottom-trailing on the actual capsule. The
        // direction is the contract too: the suite judges it on the item's
        // diagonalAngle — the live `-atan2(W, H)` contract
        // (DetailCapsuleButton.qml:133; about -79 deg as observed on the
        // Start capsule, never a 45 literal — the capsule is
        // `implicitWidth: content.width + 2 * horizontalPadding`, so its
        // width is text-metric dependent and the figure is illustrative,
        // not derivable) — and on the inner fill that
        // carries it — wide rather than square, centred, rotated so its
        // own gradient axis spans the capsule's diagonal, and long enough
        // to cover every corner of the wide button — with the angle pinned
        // by the binding checks below against independently recomputed
        // `-atan(W/H)` arithmetic, which fail at 45 — so a
        // vertical-gradient regression fails here even though the stops
        // still match, and so does a rotated square that keeps the stops
        // off the visible corners of a wide capsule. The scene probes below
        // judge the ring and the glow on the capture; the stops and the
        // direction are judged on the item, where neither the label, the
        // ring, nor the glow can wash the sample.
        auto *gradient =
            button->findChild<QQuickItem *>(QStringLiteral("capsuleGoldGradient"));
        QVERIFY(gradient != nullptr);
        QVERIFY(gradient->isVisible());
        QCOMPARE(gradient->property("stopTop").value<QColor>(), goldTop);
        // Tolerance 1, not exact equality: both sides blend the same 0.85
        // ink over the page, but the QML blends in float while the probe
        // blends in double, and the blue channel lands on exactly 68.5.
        // The old precomputed literal misses by 2 in red and 3-4 in blue,
        // so this still fails on the old bytes.
        QVERIFY2(render_probe::withinTolerance(
                     gradient->property("stopBottom").value<QColor>(), goldBottom, 1),
                 qPrintable(gradient->property("stopBottom").value<QColor>().name()));
        // The diagonal direction (MovieDetailView.swift:410-411): top-leading
        // to bottom-trailing on the actual capsule. Judged on the rendered
        // pixels where the band reads clean: mid-height on each side edge,
        // six logical pixels inside the outline. The side edges carry the
        // gradient's own stops — source gold on the leading edge, the
        // composited 0.85 ink on the trailing one — while the label, the
        // ring, and the glow cannot wash the samples there: the content
        // row is centred thirty pixels in, the ring stroke spans 2.25-4.5
        // pixels inside the outline, and the corners (where the glow
        // dithers the rotated band's edge) are avoided entirely. Each
        // assertion fails on the old bytes: the +atan2(h, w) fill painted
        // its axis down-and-LEFT, so the sides sampled below carried the
        // opposite stop, and the bare container painted the uncovered
        // corners opaque white, which neither stop matches.
        //
        // The samples sit six logical pixels inside the capsule's side
        // edges at mid-height: inside the paint (the radius-8 arcs
        // only govern the corners), clear of the ring stroke, the content
        // row, and the corner glow dither. A swapped diagonal would put
        // the 0.85 ink at the leading sample and gold at the trailing one,
        // and a flat fill would miss one side.
        //
        auto *gradientFill = gradient->findChild<QQuickItem *>(
            QStringLiteral("capsuleGoldGradientFill"));
        QVERIFY2(gradientFill != nullptr,
                 "the gold gradient paints no diagonal fill");
        auto *buttonContent =
            button->findChild<QQuickItem *>(QStringLiteral("capsuleContent"));
        QVERIFY(buttonContent != nullptr);
        auto *baseFillItem =
            button->findChild<QQuickItem *>(QStringLiteral("capsuleBaseFill"));
        QVERIFY2(baseFillItem != nullptr,
                 "the gold capsule paints no base fill beneath its gradient");
        auto *gradientRounded = gradient->findChild<QQuickItem *>(
            QStringLiteral("capsuleGoldGradientRounded"));
        QVERIFY2(gradientRounded != nullptr,
                 "the gold gradient paints no rounded fill over its diagonal band");
        QVERIFY2(gradientRounded->inherits("QQuickCanvasItem"),
                 "the gold gradient's rounded fill is not a canvas");
        window->show();
        // The stop witnesses: scene points six logical pixels inside each
        // side edge at mid-height, captured live so the probe judges the
        // painted frame, not the QML's own numbers.
        const auto cornerScenePoint = [&](bool trailing) {
            const QRectF local(trailing ? gradient->width() - 6.0 : 6.0, gradient->height() / 2.0,
                               1.0, 1.0);
            return gradient->mapRectToItem(window->contentItem(), local).center();
        };
        const auto cornerStopsPainted = [&](const render_probe::Capture &capture) {
            const QRect leading(QPoint(qRound(cornerScenePoint(false).x()
                                              * capture.devicePixelRatio),
                                       qRound(cornerScenePoint(false).y()
                                              * capture.devicePixelRatio)),
                                QSize(1, 1));
            const QRect trailing(QPoint(qRound(cornerScenePoint(true).x()
                                               * capture.devicePixelRatio),
                                        qRound(cornerScenePoint(true).y()
                                               * capture.devicePixelRatio)),
                                 QSize(1, 1));
            const QRect imageRect = capture.image.rect();
            if (!imageRect.contains(leading.topLeft())
                || !imageRect.contains(trailing.topLeft())) {
                return false;
            }
            // The sides must already carry the two stops' unblended
            // colours (tolerance 12 for renderer quantization); the wait
            // below retries until they do.
            return render_probe::withinTolerance(capture.image.pixelColor(leading.topLeft()),
                                                 goldTop, 12)
                && render_probe::withinTolerance(capture.image.pixelColor(trailing.topLeft()),
                                                 goldBottom, 12);
        };
        const render_probe::Capture cornerCapture = render_probe::captureWindowUntil(
            window, {button, gradient, buttonContent, ring}, cornerStopsPainted);
        QVERIFY(cornerCapture.coherent());
        // No white is ever painted inside the gold capsule: the oracle
        // carries only gold and the composited 0.85 ink here, so every
        // interior pixel must be within tolerance of the segment between
        // the two stops — and no interior pixel may be white. The audit
        // below walks the whole interior (inset by one pixel from the
        // capsule edges, and clear of the centred content row) on the
        // rendered frame alone.
        const QRectF gradientScene = gradient->mapRectToItem(window->contentItem(),
                                                             gradient->boundingRect());
        const QRect gradientPixels = render_probe::imageRect(cornerCapture, gradientScene);
        QVERIFY(!gradientPixels.isEmpty());
        const int edgePixels =
            qMax(1, qRound(1.0 * cornerCapture.devicePixelRatio));
        // The content row paints the white glyph and label over the band.
        // The white audit judges the band, not the row: it skips the row's
        // own ink — the union of the glyph canvas's and the label's scene
        // rectangles, each with a two-pixel antialiased margin — because
        // the row's white ink is the released composition, not container
        // white. The row's own geometry is still judged by the padding
        // assertions further down.
        auto *glyphItem =
            button->findChild<QQuickItem *>(QStringLiteral("capsuleGlyph"));
        QVERIFY(glyphItem != nullptr);
        auto *labelItem = button->findChild<QQuickItem *>(QStringLiteral("capsuleLabel"));
        QVERIFY(labelItem != nullptr);
        const int contentMargin = qMax(1, qRound(2.0 * cornerCapture.devicePixelRatio));
        QRect contentPixels;
        for (QQuickItem *ink : {glyphItem, labelItem}) {
            const QRect inkScene = render_probe::imageRect(
                cornerCapture,
                ink->mapRectToItem(window->contentItem(), ink->boundingRect()));
            contentPixels = contentPixels.united(
                inkScene.adjusted(-contentMargin, -contentMargin, contentMargin,
                                  contentMargin));
        }
        const QRect whiteAudit = gradientPixels.adjusted(edgePixels, edgePixels, -edgePixels,
                                                         -edgePixels);
        QVERIFY(!whiteAudit.isEmpty());
        const QColor white(255, 255, 255);
        int whiteCount = 0;
        int judged = 0;
        for (int y = whiteAudit.top(); y <= whiteAudit.bottom(); ++y) {
            for (int x = whiteAudit.left(); x <= whiteAudit.right(); ++x) {
                const QPoint pixel(x, y);
                if (contentPixels.contains(pixel)) {
                    continue;
                }
                ++judged;
                const QColor painted = cornerCapture.image.pixelColor(pixel);
                if (render_probe::departureFrom(painted, white) <= 24) {
                    ++whiteCount;
                }
            }
        }
        QVERIFY2(judged > 100,
                 qPrintable(QStringLiteral("the white audit judged only %1 pixels").arg(judged)));
        QVERIFY2(whiteCount == 0,
                 qPrintable(QStringLiteral("the gold capsule paints %1 of %2 interior pixels white")
                                .arg(whiteCount)
                                .arg(judged)));
        // The off-segment audit judges the whole interior band: the ring
        // the focus chrome paints over the gradient is excluded by a
        // five-device-pixel inset at unit scale — one edge pixel plus four
        // ring pixels — from the capsule's outline (the corner audit
        // below judges the paint there instead), but the centred content
        // row is NOT excluded — it sits inside the judged region. The row
        // cannot span the band edge to edge (its ~28d of horizontal
        // padding each side leaves its ink ~26d inside the button edge,
        // while the ring inset is only ~5d), so there is no bare-only
        // strip to isolate; the label and glyph paint their white ink
        // inside the judged pixels. Pure white lies on the white-ward ray
        // from the gold segment, so the audit accepts any pixel on that
        // ray as well as the segment itself — the row's white ink passes
        // only through that tolerance. The ray test is the real
        // discriminator for wash, not for placement: halo wash is
        // purple, off both the segment and the ray, and still fails
        // here. A flat band that still covers the interior paints only
        // on-segment colours — every pixel is tested against the whole
        // segment — so it passes here; it fails instead at the painted
        // stop witnesses below (leadingPainted against goldTop and
        // trailingPainted against goldBottom): capsuleGoldGradientFill's
        // width, height and rotation bind only to the gradient rect's
        // extent and diagonalAngle, never to the stops or the canvas
        // paint, so equal stops (or a solid fillStyle) leave the
        // rotation/diagonalAngle/band-height/centring readings unchanged.
        // The equal-stops variant additionally fails the stop property
        // checks above, which read the stops themselves. A
        // rotation-reversed band likewise paints only on-segment
        // colours, so it passes here too; it fails instead at the fill
        // rotation and diagonalAngle assertions below against the oracle
        // axis. A shifted band likewise paints only on-segment colours,
        // so it passes here too; it fails instead at the scene-centring
        // assertion below (band height from the capsule diagonal covers
        // the undersized variant).
        // Stray white outside the row is rejected by the white audit
        // above, which excludes only the row's own ink rectangles (glyph
        // canvas and label, each with a two-pixel antialiased margin).
        // The label's paint fills its layout — the suite pins that
        // equivalence on contentHeight just below — which is what the
        // white audit's exclusion relies on.
        int gradientJudged = 0;
        int gradientOffSegment = 0;
        QString firstGradientOff;
        const int ringPixels =
            qMax(1, qRound(4.0 * cornerCapture.devicePixelRatio));
        const QRect gradientOnly = whiteAudit.adjusted(ringPixels, ringPixels, -ringPixels,
                                                       -ringPixels);
        // The Text item's bounding rect is its ink: the contentHeight it
        // reports fills the layout here (the white audit above excludes
        // the label by exactly that rect, grown by the antialiased
        // margin). The item's height is layout-driven, so no
        // contentHeight-against-height assertion is kept here: comparing
        // the two would restate the binding instead of judging the ink.
        const qreal labelContentHeight = labelItem->property("contentHeight").toReal();
        QVERIFY2(labelContentHeight > 1.0,
                 qPrintable(QStringLiteral("the capsule label reports content height %1")
                                .arg(labelContentHeight)));
        // The judged band is the whole interior band named above: the
        // centred row cannot span it edge to edge (see the arithmetic
        // above), so there is no bare-only strip to isolate. The rectangular
        // inset clears the ring along each straight edge. At a rounded
        // corner, however, the ring follows an arc farther into that inset;
        // classify its band from the same rounded-rectangle signed distance
        // as FocusRing.cpp and exclude it plus one device pixel of
        // antialiasing. Everything beyond that band remains judged, including
        // the centred white row and the surface immediately inside the ring.
        const QRect gradientBare(gradientOnly.left(), gradientOnly.top() + 1,
                                 qMax(0, gradientOnly.width() - 1),
                                 qMax(0, gradientOnly.height() - 2));
        const QRectF ringScene = cornerCapture.geometryOf(ring).sceneRect;
        const qreal ringRadius = ring->property("cornerRadius").toReal();
        const qreal ringLineWidth = ring->property("lineWidth").toReal();
        const auto clearOfRing = [&](const QPoint &pixel) {
            const QPointF scene((pixel.x() + 0.5) / cornerCapture.devicePixelRatio,
                                (pixel.y() + 0.5) / cornerCapture.devicePixelRatio);
            const QPointF centre = ringScene.center();
            const qreal halfWidth = ringScene.width() / 2.0 - ringRadius;
            const qreal halfHeight = ringScene.height() / 2.0 - ringRadius;
            const qreal qx = std::abs(scene.x() - centre.x()) - halfWidth;
            const qreal qy = std::abs(scene.y() - centre.y()) - halfHeight;
            const qreal distance = std::hypot(std::max(qx, 0.0), std::max(qy, 0.0))
                + std::min(std::max(qx, qy), 0.0) - ringRadius;
            return distance < -(ringLineWidth + 1.0 / cornerCapture.devicePixelRatio);
        };
        for (int y = gradientBare.top(); y <= gradientBare.bottom(); ++y) {
            for (int x = gradientBare.left(); x <= gradientBare.right(); ++x) {
                const QPoint pixel(x, y);
                if (!clearOfRing(pixel)) {
                    continue;
                }
                ++gradientJudged;
                const QColor painted = cornerCapture.image.pixelColor(pixel);
                const QColor onSegment =
                    render_probe::nearestOnSegment(painted, goldTop, goldBottom);
                const bool onGold =
                    render_probe::withinTolerance(painted, onSegment, 12);
                // Antialiased text fringe is the segment lightened toward
                // white; halo wash is purple and off that ray. The fringe
                // tolerance is wider than the segment one because the
                // fringe spans the whole lightening range, not one stop.
                const QColor onWhiteRay =
                    render_probe::nearestOnSegment(painted, onSegment, white);
                const bool onFringe =
                    render_probe::withinTolerance(painted, onWhiteRay, 24)
                    && render_probe::departureFrom(onWhiteRay, onSegment) > 0
                    && render_probe::departureFrom(painted, onSegment)
                        <= render_probe::departureFrom(white, onSegment);
                if (!onGold && !onFringe) {
                    ++gradientOffSegment;
                    if (firstGradientOff.isEmpty()) {
                        firstGradientOff =
                            QStringLiteral("(%1,%2) paints %3, off the gold segment %4-%5")
                                .arg(x)
                                .arg(y)
                                .arg(painted.name(), goldTop.name(), goldBottom.name());
                    }
                }
            }
        }
        QVERIFY2(gradientJudged > 100,
                 qPrintable(QStringLiteral("the gradient audit judged only %1 pixels")
                                .arg(gradientJudged)));
        QVERIFY2(gradientOffSegment == 0,
                 qPrintable(QStringLiteral("the gold capsule paints %1 of %2 interior pixels off "
                                           "the gold segment: %3")
                                .arg(gradientOffSegment)
                                .arg(gradientJudged)
                                .arg(firstGradientOff)));
        // The rounded paint: the canvas clips its own ink to the oracle's
        // radius-8 rounded rectangle, so the scene corner outside the arcs
        // reads the halo-cast page while one radius inside the arcs reads
        // the gold band — judged on the rendered frame alone, against the
        // gold segment and the page, never against a second frame that a
        // hidden surface could vacate. The hide/show cycle below still
        // proves the reference machinery removes the surface (a stale
        // grab cannot survive it), but the rounding verdict does not
        // depend on it: squaring the paint moves the corner from page to
        // band ink in THIS frame, which is what the audit counts.
        //
        // A square-cornered regression paints band ink at the scene corner
        // in the rendered frame; a paint that hid too much would paint
        // page at the arc-centre pixel instead. Both are judged below on
        // the rendered frame's own pixels.
        //
        // The corner's band ink is judged against the gold segment it must
        // stand on (tolerance 24: the renderer's quantization plus
        // antialiasing), not against an absolute gold — the halo the focus
        // chrome casts nearby is the same halo the ring/glow assertions at
        // the end of this case already judge.
        const QList<QQuickItem *> maskItems{button, gradient, gradientRounded, buttonContent};
        // Hiding the paint takes effect on the next frame: toggle the
        // canvas through a full show/hide cycle with an update on each
        // leg, and wait for a frame that shows the page through the
        // cutouts, so a stale rounded frame cannot survive into the grab.
        // The reference is machinery validation only — the verdicts below
        // read the rendered frame.
        gradientRounded->setVisible(false);
        // Hiding the canvas removes the golden surface entirely, so the
        // reference frame shows the page (plus the focus halo, which
        // paints independently of the surface) through the cutouts, not an
        // empty hole and not base gold: the base fill hides while the
        // gradient is visible, so it cannot leak through. The repaint the
        // paint shapes is therefore the cutout moving from band ink to the
        // halo-cast page. The wait requires that repaint before judging
        // it, so a reference grabbed before the hide took effect cannot
        // pass the gate below. The reference
        // toggles the paint through a full show/hide cycle with an
        // update on each leg, so a stale rounded frame cannot survive into
        // the grab.
        const QColor pageInk = screen->property("pageBackground").value<QColor>();
        gradientRounded->setVisible(true);
        window->update();
        QTRY_VERIFY(gradientRounded->isVisible());
        gradientRounded->setVisible(false);
        window->update();
        QTRY_VERIFY(!gradientRounded->isVisible());
        const render_probe::Capture unmaskedCapture = render_probe::captureWindowUntil(
            window, maskItems, [&](const render_probe::Capture &capture) {
                if (!capture.sameGeometryAs(cornerCapture) || gradientRounded->isVisible()
                    || capture.geometryOf(gradient) != cornerCapture.geometryOf(gradient)) {
                    return false;
                }
                const QRectF gradientSceneNow = gradient->mapRectToItem(
                    window->contentItem(), gradient->boundingRect());
                const QRect cutoutsNow = render_probe::imageRect(capture, gradientSceneNow);
                // The page, loosely: the halo washes the cutout toward
                // violet, so the wait accepts anything nearer the page than
                // the gold it must stand clear of — the corner loop below
                // judges the departure strictly.
                const QColor cutoutNow =
                    !cutoutsNow.isEmpty() ? capture.image.pixelColor(cutoutsNow.topLeft())
                                          : QColor();
                return !cutoutsNow.isEmpty()
                    && render_probe::departureFrom(
                           cutoutNow, render_probe::nearestOnSegment(cutoutNow, goldTop, goldBottom))
                        > 24
                    && render_probe::departureFrom(cutoutNow, pageInk) < 96;
            });
        gradientRounded->setVisible(true);
        QVERIFY(unmaskedCapture.coherent());
        QVERIFY(unmaskedCapture.sameGeometryAs(cornerCapture));
        // Validation: the mask reference really is the same scene with only
        // the rounded paint hidden — nothing above the capsule moved
        // between the two grabs. The cutout pixels below are the rounded
        // paint's own work, not a shifted layout.
        QCOMPARE(render_probe::changedPixels(
                     cornerCapture, unmaskedCapture,
                     QRect(0, 0, cornerCapture.image.width(), gradientPixels.top()), 3),
                 0);
        // The radius-8 arc check: the paint contract the suite also reads
        // as a property below. Kept, but it is NOT the corner witness —
        // the pixel verdicts above are.
        const qreal maskRadius = gradientRounded->property("cornerRadius").toReal();
        QVERIFY2(std::abs(maskRadius - 8.0) < 0.001,
                 qPrintable(QStringLiteral("the rounded fill carries radius %1, not the oracle 8")
                                .arg(maskRadius)));
        const int cutoutStep = qMax(1, qRound(cornerCapture.devicePixelRatio));
        // Outward points out of the paint at each corner: top-left's
        // outward is up-and-left (-1,-1), top-right's is up-and-right, and
        // so on. Inward is its negation and walks into the paint.
        const std::array<QPoint, 4> cutoutOutward{{{-1, -1}, {1, -1}, {-1, 1}, {1, 1}}};
        int cutoutJudged = 0;
        int squareCorners = 0;
        QString firstSquareCorner;
        QString firstReferenceDetail;
        // The corner witness is the scene corner pixel itself — outside
        // the radius-8 arcs at every ratio, clear of the content row by
        // construction — and the inside witness is the arc-centre pixel
        // one radius in on each axis, which the paint never hides. Both
        // are judged on the rendered frame alone: the corner must read
        // the halo-cast page (far from the gold segment) while the arc
        // centre still reads band ink (on the segment). Squaring the
        // paint moves the corner onto the segment; hiding too much moves
        // the arc centre off it. The hidden reference frame is judged
        // alongside as machinery validation — it must read page at both
        // witnesses, proving the surface really left — but a corner
        // counts square or hollow from the rendered frame's own pixels,
        // so no verdict can pass vacuously when the reference vacates.
        for (size_t corner = 0; corner < cutoutOutward.size(); ++corner) {
            // The paint's scene corner in device pixels, from the geometry
            // sampled with the grab (never the live scene: the layout must
            // not move between the grab and the witness). The captured
            // rectangle's integer bounds can sit up to a pixel outside the
            // true scene rect, so the corner is re-derived here: the
            // leading edges round into the paint, the trailing edges round
            // out of it, and the corner names the last pixel row the paint
            // owns on each axis.
            const QRectF cornerScene =
                cornerCapture.geometryOf(gradient).sceneRect;
            const int xSign = cutoutOutward[corner].x();
            const int ySign = cutoutOutward[corner].y();
            const int sceneLeft =
                qRound(cornerScene.left() * cornerCapture.devicePixelRatio);
            const int sceneTop =
                qRound(cornerScene.top() * cornerCapture.devicePixelRatio);
            const int sceneRight =
                qRound(cornerScene.right() * cornerCapture.devicePixelRatio) - 1;
            const int sceneBottom =
                qRound(cornerScene.bottom() * cornerCapture.devicePixelRatio) - 1;
            const QPoint aligned(xSign < 0 ? sceneLeft : sceneRight,
                                 ySign < 0 ? sceneTop : sceneBottom);
            const QPoint inward = QPoint(-xSign, -ySign);
            // The scene corner pixel itself: outside the radius-8 arcs, so
            // the rounded paint leaves the halo-cast page there while a
            // squared paint would carry band ink.
            const QPoint outside = aligned;
            const QPoint inside(aligned.x() + inward.x() * qRound(maskRadius) * cutoutStep,
                                aligned.y() + inward.y() * qRound(maskRadius) * cutoutStep);
            if (!cornerCapture.image.rect().contains(outside)
                || !cornerCapture.image.rect().contains(inside)
                || !unmaskedCapture.image.rect().contains(outside)
                || !unmaskedCapture.image.rect().contains(inside)) {
                continue;
            }
            ++cutoutJudged;
            const QColor renderedOutside = cornerCapture.image.pixelColor(outside);
            const QColor unmaskedOutside = unmaskedCapture.image.pixelColor(outside);
            const QColor renderedInside = cornerCapture.image.pixelColor(inside);
            const QColor unmaskedInside = unmaskedCapture.image.pixelColor(inside);
            // The verdicts read the rendered frame alone, against the gold
            // segment the oracle paints (departure 24: the renderer's
            // quantization plus antialiasing), not against an absolute
            // page colour — the halo the focus chrome casts around the
            // corner is the same halo the ring/glow assertions at the end
            // of this case already judge. The scene corner must stand far
            // off the segment (page) while the arc centre stands on it
            // (band ink). Squaring the paint moves the corner onto the
            // segment; hiding too much moves the arc centre off it. The arc
            // centre's own verdict belongs to the whole-interior
            // off-segment audit above, which walks every interior pixel
            // including it, so only the corner verdict is counted here.
            const bool renderedCornerShowsPage =
                render_probe::departureFrom(
                    renderedOutside,
                    render_probe::nearestOnSegment(renderedOutside, goldTop, goldBottom))
                > 24;
            // Machinery validation: the hidden frame really removed the
            // surface — page at both witnesses — so a stale rounded frame
            // cannot masquerade as the reference. A corner whose
            // reference still shows band ink is not the paint's work and
            // is not judged.
            const bool referenceOutsideShowsPage =
                render_probe::departureFrom(
                    unmaskedOutside,
                    render_probe::nearestOnSegment(unmaskedOutside, goldTop, goldBottom))
                > 24;
            const bool referenceInsideShowsPage =
                render_probe::departureFrom(
                    unmaskedInside,
                    render_probe::nearestOnSegment(unmaskedInside, goldTop, goldBottom))
                > 24;
            if (!referenceOutsideShowsPage || !referenceInsideShowsPage) {
                --cutoutJudged;
                if (firstReferenceDetail.isEmpty()) {
                    firstReferenceDetail =
                        QStringLiteral("corner %1 rendered %2 unmasked %3, inside %4 vs %5")
                            .arg(corner)
                            .arg(renderedOutside.name(), unmaskedOutside.name(),
                                 renderedInside.name(), unmaskedInside.name());
                }
                continue;
            }
            // Rounded: the rendered scene corner carries the page — far
            // from the segment. The arc centre is read for the reference
            // validation above and for the failure detail, not for a
            // second verdict here.
            if (!renderedCornerShowsPage) {
                ++squareCorners;
                if (firstSquareCorner.isEmpty()) {
                    firstSquareCorner =
                        QStringLiteral("corner %1 paints %2 at its scene corner, on the gold segment %3-%4")
                            .arg(corner)
                            .arg(renderedOutside.name(), goldTop.name(), goldBottom.name());
                }
            }
            // Full: the arc-centre pixel still shows the gradient in the
            // rendered frame. A paint that hid too much would paint page
            // at the arc-centre in the rendered frame too. That verdict
            // belongs to the whole-interior off-segment audit above, which
            // walks every interior pixel including this one: judging it
            // again here would duplicate that audit, so this block counts
            // only the square-corner verdict.
        }
        QVERIFY2(cutoutJudged > 0,
                 qPrintable(QStringLiteral("the rounded-corner audit judged no corners: %1")
                                .arg(firstReferenceDetail)));
        QVERIFY2(cutoutJudged == 4,
                 qPrintable(QStringLiteral("the rounded-corner audit judged %1 of 4 corners: %2")
                                .arg(cutoutJudged)
                                .arg(firstReferenceDetail)));
        QVERIFY2(squareCorners == 0,
                 qPrintable(QStringLiteral("the gold capsule paints %1 of 4 corner cutouts square: %2")
                                .arg(squareCorners)
                                .arg(firstSquareCorner)));
        // Over-masking is covered by the whole-interior off-segment audit
        // above, which walks every interior pixel including the arc
        // centres: a paint that hid too much fails there (a single 1px
        // interior hole reads "the gold capsule paints 1 of 6409 interior
        // pixels off the gold segment"), so no second hollow-interior
        // assertion is kept here.
        // The leading/trailing stop witnesses reuse the grab's own geometry:
        // cornerScenePoint above already waited for the stops at these scene
        // points, so sampling the same capture through the geometry it was
        // grabbed with must agree. Sampling through the live scene instead
        // would let any layout motion between the grab and this line move
        // the sample. Both witnesses sit at mid-height, six inside each
        // side edge — the same points the wait judged.
        const QRectF gradientSceneGrabbed = cornerCapture.geometryOf(gradient).sceneRect;
        const QPoint leadingPixel(
            qRound((gradientSceneGrabbed.left() + 6.5) * cornerCapture.devicePixelRatio),
            qRound((gradientSceneGrabbed.top() + gradientSceneGrabbed.bottom()) / 2.0
                   * cornerCapture.devicePixelRatio));
        const QPoint trailingPixel(
            qRound((gradientSceneGrabbed.right() - 6.5) * cornerCapture.devicePixelRatio),
            qRound((gradientSceneGrabbed.top() + gradientSceneGrabbed.bottom()) / 2.0
                   * cornerCapture.devicePixelRatio));
        QVERIFY2(cornerCapture.image.rect().contains(leadingPixel), "the gold capsule's leading corner is off-frame");
        QVERIFY2(cornerCapture.image.rect().contains(trailingPixel),
                 "the gold capsule's trailing corner is off-frame");
        const QColor leadingPainted = cornerCapture.image.pixelColor(leadingPixel);
        const QColor trailingPainted = cornerCapture.image.pixelColor(trailingPixel);
        // Gold sits at the visible leading side: fails on the old
        // +atan2(h, w) bytes, which painted the axis down-and-LEFT and left
        // this side carrying the 0.85 ink.
        QVERIFY2(render_probe::withinTolerance(leadingPainted, goldTop, 12),
                 qPrintable(QStringLiteral("the gold gradient's leading side paints %1, not gold %2")
                                .arg(leadingPainted.name(), goldTop.name())));
        // The composited 0.85 ink sits at the visible trailing side:
        // fails on the old bytes, which painted this side gold.
        QVERIFY2(render_probe::withinTolerance(trailingPainted, goldBottom, 12),
                 qPrintable(QStringLiteral("the gold gradient's trailing side paints %1, not the 0.85 ink %2")
                                .arg(trailingPainted.name(), goldBottom.name())));
        // The fill still covers every corner of the capsule: the rotation
        // is bound to the capsule's own extent, so assert the binding reads
        // the live width and height rather than a constant. The expected
        // axis is -atan2(W, H) in degrees — the angle whose +y maps to the
        // oracle's (W, H)/|D| direction — recomputed here from the live
        // extent with independent arithmetic (a plain quotient and atan,
        // not the QML's own expression).
        const double liveWidth = gradient->width();
        const double liveHeight = gradient->height();
        QVERIFY(liveWidth > 1.0);
        QVERIFY(liveHeight > 1.0);
        const double expectedRotation =
            -std::atan(liveWidth / liveHeight) * 180.0 / std::numbers::pi;
        QVERIFY2(std::abs(gradientFill->property("rotation").toReal() - expectedRotation) < 1.0,
                 qPrintable(QStringLiteral("the diagonal fill misses the oracle axis: rotation %1, oracle axis %2")
                                .arg(gradientFill->property("rotation").toReal())
                                .arg(expectedRotation)));
        // diagonalAngle is the live contract the fill above reads — not a
        // nominal literal — so it must equal the same oracle axis. The old
        // bytes carried 45 here while painting +atan2(h, w); both halves
        // of that mismatch fail below.
        QVERIFY2(std::abs(gradient->property("diagonalAngle").toReal() - expectedRotation) < 1.0,
                 qPrintable(QStringLiteral("the diagonal contract misses the oracle axis: diagonalAngle %1, oracle axis %2")
                                .arg(gradient->property("diagonalAngle").toReal())
                                .arg(expectedRotation)));
        // The band must genuinely cover the capsule. The width carries
        // hypot + height of slack while the height carries none. A
        // `width >= hypot` check would restate the bandWidth binding
        // instead of judging the paint, so no width check is kept here.
        // The sibling height check below is the same restate-the-binding
        // shape — it reads `gradientFill->height()`, bound to
        // `bandHeight = sqrt(w^2+h^2)` (DetailCapsuleButton.qml:175-176,
        // :249), against `std::hypot` recomputed from the same live
        // extent — differing only in being two-sided. It is falsifiable
        // against one regression class, not against paint: the old square
        // bytes that added a full capsule height to both axes fail it
        // while the width check still passes on them, while a band
        // narrowed below the diagonal instead fails the corner-cutout
        // and stop-witness pixel verdicts above.
        // The band is centred by its anchors, not by its size: shrinking
        // the band must move its scene edges with it. The suite judges
        // that on the scene — the band's own edges against the capsule's
        // — so a band parked off-centre fails even though its width and
        // height still cover the diagonal, and so does a band whose
        // centreIn anchor was replaced by a top-left one.
        const QRectF bandScene =
            gradientFill->mapRectToItem(window->contentItem(), gradientFill->boundingRect());
        const QRectF capsuleScene = gradient->mapRectToItem(window->contentItem(),
                                                            gradient->boundingRect());
        QVERIFY2(std::abs(bandScene.left() - (capsuleScene.center().x() - bandScene.width() / 2.0))
                         < 2.0
                     && std::abs(bandScene.top()
                                 - (capsuleScene.center().y() - bandScene.height() / 2.0))
                         < 2.0,
                 qPrintable(QStringLiteral("the diagonal fill is not centred on the capsule: "
                                           "band %1x%2 at (%3,%4), capsule %5x%6 at (%7,%8)")
                                .arg(bandScene.width())
                                .arg(bandScene.height())
                                .arg(bandScene.left())
                                .arg(bandScene.top())
                                .arg(capsuleScene.width())
                                .arg(capsuleScene.height())
                                .arg(capsuleScene.left())
                                .arg(capsuleScene.top())));
        // The band's height is the capsule's own diagonal plus nothing
        // else: exactly the `height: sqrt(w*w + h*h)` binding above, with
        // no extra capsule height of slack. The width carries that slack
        // instead. Read against std::hypot recomputed from the same live
        // extent (DetailCapsuleButton.qml:175-176, :249), this is the same
        // restate-the-binding shape the deleted width check had — differing
        // only in being two-sided — and it is falsifiable against one
        // regression class, not against paint: it fails on the old square
        // bytes, which added a full capsule height to both axes, while the
        // width check above still passes on them.
        QVERIFY2(std::abs(gradientFill->height() - std::hypot(liveWidth, liveHeight)) < 1.0,
                 qPrintable(QStringLiteral("the diagonal fill is taller than the capsule diagonal: "
                                           "height %1, diagonal %2")
                                .arg(gradientFill->property("height").toReal())
                                .arg(std::hypot(liveWidth, liveHeight))));
        // Radius follows the 8-point rounded-rectangle surface, not the show
        // pill: the rounded paint, the base fill, and the focus frame
        // carry cornerRadiusMD (MovieDetailView.swift:402-403, :436-437,
        // :417-421, :441-445; MarqueeTheme.swift:245). The base hides while
        // the gold gradient is visible — the canvas is the surface
        // then — so its radius is judged where it shows: on the Resume
        // button below and on the show-pill probe further down.
        auto *baseFill =
            button->findChild<QQuickItem *>(QStringLiteral("capsuleBaseFill"));
        QVERIFY(baseFill != nullptr);
        QVERIFY2(!baseFill->isVisible(),
                 "the Start base fill must hide while its gradient paint shows");
        QCOMPARE(baseFill->property("radius").toReal(), 8.0);
        QCOMPARE(gradientRounded->property("cornerRadius").toReal(), 8.0);
        QCOMPARE(button->property("surfaceRadius").toReal(), 8.0);
        // (R4 note: the movie `effectiveRadius == 8.0` assertion the entry
        // names is NOT removed here. With `surfaceRadius == 8.0` pinned on
        // the line above, it reads the non-negative arm of
        // `surfaceRadius < 0 ? h/2 : surfaceRadius`
        // (DetailCapsuleButton.qml:49) — the same binding-read shape as
        // the removed pill check, kept deliberately here as cheap cover
        // for that arm, not because it judges paint. The oracle-8 paint
        // coverage beside it is the painted `radius` reads and the
        // corner-cutout pixel verdicts.)
        QCOMPARE(button->property("effectiveRadius").toReal(), 8.0);
        QCOMPARE(focusFrame->property("radius").toReal(), 8.0);
        // Padding and type follow the movie Start values, not the show pill:
        // :400-401 pads 28/12, :394-397 sets label 15 bold and glyph play.fill
        // 14, :393 sets the inner HStack spacing 8. Content padding is read off the button's
        // own width and height against its row, so a coordinated regression
        // cannot hide behind the QML's own properties.
        auto *content = button->findChild<QQuickItem *>(QStringLiteral("capsuleContent"));
        QVERIFY(content != nullptr);
        auto *glyph = button->findChild<QQuickItem *>(QStringLiteral("capsuleGlyph"));
        QVERIFY(glyph != nullptr);
        auto *label = button->findChild<QQuickItem *>(QStringLiteral("capsuleLabel"));
        QVERIFY(label != nullptr);
        QCOMPARE(button->property("horizontalPadding").toReal(), 28.0);
        QCOMPARE(button->property("verticalPadding").toReal(), 12.0);
        QCOMPARE(button->property("contentSpacing").toReal(), 8.0);
        QCOMPARE(label->property("font").value<QFont>().pixelSize(), 15);
        QCOMPARE(label->property("font").value<QFont>().weight(), QFont::Bold);
        QCOMPARE(glyph->width(), 14.0);
        QCOMPARE(button->width(), content->width() + 2 * 28.0);
        QCOMPARE(button->height(), content->height() + 2 * 12.0);
        QCOMPARE(content->property("spacing").toReal(), 8.0);
        // The show pill keeps its own geometry: padding 20/10, label 13
        // DemiBold, glyph backward.end.fill 11 (ShowDetailView.swift:396-404).
        // The padding, spacing, and label values are the shared component's
        // defaults, judged here on a second instance so the movie overrides
        // above cannot move them. The glyph is set explicitly on that probe,
        // so it witnesses only the size there; the shipped `play.fill`
        // default is pinned on a probe below that leaves glyph unset.
        QQmlComponent capsuleProbe(&engine);
        capsuleProbe.setData(QByteArrayLiteral("import QtQuick\nimport Marquee 3.0\n"
                                               "DetailCapsuleButton { label: \"Start From Beginning\"; glyph: \"backward.end.fill\" }\n"),
                            QUrl(QStringLiteral("qrc:/details-capsule-defaults-probe.qml")));
        QVERIFY2(!capsuleProbe.isError(), qPrintable(capsuleProbe.errorString()));
        QObject *probeObject = capsuleProbe.create();
        QVERIFY(probeObject != nullptr);
        auto *probe = qobject_cast<QQuickItem *>(probeObject);
        QVERIFY(probe != nullptr);
        QCOMPARE(probe->property("horizontalPadding").toReal(), 20.0);
        QCOMPARE(probe->property("verticalPadding").toReal(), 10.0);
        QCOMPARE(probe->property("contentSpacing").toReal(), 6.0);
        QCOMPARE(probe->property("labelFontSize").toReal(), 13.0);
        auto *probeLabel =
            probe->findChild<QQuickItem *>(QStringLiteral("capsuleLabel"));
        QVERIFY(probeLabel != nullptr);
        QCOMPARE(probeLabel->property("font").value<QFont>().weight(), QFont::DemiBold);
        QCOMPARE(probe->property("glyphSize").toReal(), 11.0);
        QCOMPARE(probe->property("surfaceRadius").toReal(), -1.0);
        // (R4 note: no show-pill effectiveRadius assertion is kept here.
        // The removed check read `effectiveRadius` on the probe root — a
        // property on an unpainted Item — while the surviving line below pins
        // the same pill arm (`height/2` with `surfaceRadius == -1.0`
        // pinned on the line above) on the base fill Rectangle that carries
        // the surface radius, so that one specific removal lost no painted coverage.
        // The kept oracle-8 reads elsewhere are binding reads of the same
        // shape and are kept as cheap cover; the painted-item coverage is
        // what makes this removal, and only this one, safe.)
        auto *probeFill =
            probe->findChild<QQuickItem *>(QStringLiteral("capsuleBaseFill"));
        QVERIFY(probeFill != nullptr);
        QCOMPARE(probeFill->property("radius").toReal(), probe->height() / 2.0);
        delete probeObject;
        // The shipped glyph default is `play.fill`; judge it on a probe
        // that leaves glyph unset so no test-side literal can echo back.
        QQmlComponent glyphDefaultProbe(&engine);
        glyphDefaultProbe.setData(QByteArrayLiteral("import QtQuick\nimport Marquee 3.0\n"
                                                    "DetailCapsuleButton { label: \"x\" }\n"),
                                 QUrl(QStringLiteral("qrc:/details-capsule-glyph-default-probe.qml")));
        QVERIFY2(!glyphDefaultProbe.isError(), qPrintable(glyphDefaultProbe.errorString()));
        QObject *glyphDefaultObject = glyphDefaultProbe.create();
        QVERIFY(glyphDefaultObject != nullptr);
        auto *glyphDefault = qobject_cast<QQuickItem *>(glyphDefaultObject);
        QVERIFY(glyphDefault != nullptr);
        QCOMPARE(glyphDefault->property("glyph").toString(), QStringLiteral("play.fill"));
        delete glyphDefaultObject;
        const QColor goldMidOverPage = goldMid;
        window->show();
        const auto chromePainted = [&](const render_probe::Capture &capture) {
            const QRect buttonRect = render_probe::imageRectForItem(capture, button);
            if (buttonRect.isEmpty()) {
                return false;
            }
            return render_probe::countEdgePixels(capture.image, buttonRect, 6, isRingOverGold) > 0
                && render_probe::countPixelsOutside(capture.image, buttonRect.adjusted(-8, -8, 8, 8),
                                                    buttonRect, isGlowPixel) > 0;
        };
        const render_probe::Capture capture =
            render_probe::captureWindowUntil(window, {button}, chromePainted);
        QVERIFY(capture.coherent());
        const QImage &focused = capture.image;
        const QRect buttonRect = render_probe::imageRectForItem(capture, button);
        QVERIFY(!buttonRect.isEmpty());
        QVERIFY2(render_probe::countEdgePixels(focused, buttonRect, 6, isRingOverGold) > 0,
                 "the Start focus ring was not screen-blended inside the control");
        QVERIFY2(render_probe::countPixelsOutside(focused, buttonRect.adjusted(-8, -8, 8, 8),
                                                  buttonRect, isGlowPixel) > 0,
                 "the Start focus glow did not bloom outside the control");
        // The ring is padded inside the control, so nothing at ring strength
        // is painted across or beyond its edge, and the control is not scaled.
        const auto isRingStrength = [](const QColor &pixel) {
            return pixel.red() > 100 && pixel.blue() > 140;
        };
        QCOMPARE(render_probe::countPixelsOutside(focused, buttonRect.adjusted(-3, -3, 3, 3),
                                                  buttonRect, isRingStrength),
                 0);
        const auto isGoldSpill = [&](const QColor &pixel) {
            return render_probe::withinTolerance(pixel, goldMidOverPage, 8);
        };
        QCOMPARE(render_probe::countPixelsOutside(focused, buttonRect.adjusted(-3, -3, 3, 3),
                                                  buttonRect, isGoldSpill),
                 0);
    }

    void playingATitleWhoseFileVanishedReportsItAndStaysOnTheDetails()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        QTemporaryDir library;
        QVERIFY(writeMediaFile(library.path(), QStringLiteral("Arrival.2016.mkv"),
                               2 * 1024 * 1024));

        ApplicationController controller;
        controller.setTemporaryLibraryRoot(library.path());
        QTRY_COMPARE(controller.library()->rowCount(), 1);

        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY2(window != nullptr, "qml/Main.qml did not load from the module");
        controller.navigation()->goHome();

        controller.showMediaDetails(idAt(controller.library(), 0));

        QQuickItem *screen = nullptr;
        QTRY_VERIFY((screen = itemNamed(window, "detailsScreen")) != nullptr);
        QTRY_VERIFY(screen->hasActiveFocus());

        // The row survives its file going away, so pressing play is the moment
        // the user learns the title itself is gone.
        QVERIFY(QFile::remove(
            QDir(library.path()).filePath(QStringLiteral("Arrival.2016.mkv"))));

        QTest::keyClick(window, Qt::Key_Return);

        QTRY_VERIFY(controller.hasError());
        QCOMPARE(controller.errorTitle(), QStringLiteral("Title unavailable"));
        QVERIFY(controller.errorMessage().contains(QStringLiteral("Arrival")));
        QCOMPARE(controller.navigation()->route(), NavigationController::Route::Details);
        QVERIFY(controller.player()->currentFileUrl().isEmpty());
    }

    void backFromTheDetailsSurfaceReturnsToTheLibrary()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        QTemporaryDir library;
        QVERIFY(writeMediaFile(library.path(), QStringLiteral("Arrival.2016.mkv"),
                               2 * 1024 * 1024));

        ApplicationController controller;
        controller.setTemporaryLibraryRoot(library.path());
        QTRY_COMPARE(controller.library()->rowCount(), 1);

        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY2(window != nullptr, "qml/Main.qml did not load from the module");
        controller.navigation()->goHome();
        QTRY_VERIFY(itemNamed(window, "homeRows") != nullptr);

        controller.showMediaDetails(idAt(controller.library(), 0));
        QTRY_VERIFY(itemNamed(window, "detailsScreen") != nullptr);

        QTest::keyClick(window, Qt::Key_Escape);

        QTRY_COMPARE(controller.navigation()->route(), NavigationController::Route::Home);
        QTRY_VERIFY(itemNamed(window, "homeRows") != nullptr);
        QVERIFY(itemNamed(window, "detailsScreen") == nullptr);
    }

    void aScanThatDropsTheOpenTitleReplacesItsFactsWithAnExplanation()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        QTemporaryDir library;
        QVERIFY(writeMediaFile(library.path(), QStringLiteral("Arrival.2016.mkv"),
                               2 * 1024 * 1024));

        ApplicationController controller;
        controller.setTemporaryLibraryRoot(library.path());
        QTRY_COMPARE(controller.library()->rowCount(), 1);

        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY2(window != nullptr, "qml/Main.qml did not load from the module");
        controller.navigation()->goHome();

        controller.showMediaDetails(idAt(controller.library(), 0));

        QQuickItem *screen = nullptr;
        QTRY_VERIFY((screen = itemNamed(window, "detailsScreen")) != nullptr);
        QTRY_VERIFY(screen->hasActiveFocus());

        // What a scan of a root whose titles are gone publishes.
        controller.library()->replaceItems({});

        QQuickItem *missing = itemNamed(window, "detailsMissingState");
        QVERIFY(missing != nullptr);
        QTRY_VERIFY(missing->isVisible());
        QQuickItem *title = itemNamed(window, "detailsTitle");
        QVERIFY(title != nullptr);
        QVERIFY(!title->isVisible());

        // Nothing is left to play, so the surface stays where it is instead of
        // opening a file the catalog no longer projects.
        QTest::keyClick(window, Qt::Key_Return);

        QCOMPARE(controller.navigation()->route(), NavigationController::Route::Details);
        QVERIFY(controller.player()->currentFileUrl().isEmpty());
        QVERIFY2(!controller.hasError(), qPrintable(controller.errorMessage()));
    }

    // MovieDetailView.swift:47-152 composes the scrollable hero/content
    // surface in one order (hero, actions, synopsis, director, more like
    // this, file info); :571-611 draw the related row only for a non-empty
    // `similar`. The offline catalog (plan section 5) genuinely carries no
    // overview or director, so the oracle omits those sections entirely
    // (:456 wraps SYNOPSIS, :493 wraps the director line, header and prefix
    // included); certification, rating, and genres are skipped by their own
    // @ViewBuilders in the same way.
    void theDetailsSurfaceComposesTheReleasedSectionsInOrder()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        QTemporaryDir library;
        QVERIFY(writeMediaFile(library.path(),
                               QStringLiteral("Arrival (2016)/Arrival (2016).mkv"),
                               2 * 1024 * 1024));
        QVERIFY(writePosterFile(library.path(),
                                QStringLiteral("Arrival (2016)/poster.png")));
        QVERIFY(writeMediaFile(library.path(), QStringLiteral("Arrival Two (2018).mkv"),
                               2 * 1024 * 1024));
        QVERIFY(writeMediaFile(library.path(), QStringLiteral("Moon (2009).mkv"),
                               2 * 1024 * 1024));

        ApplicationController controller;
        controller.setTemporaryLibraryRoot(library.path());
        QTRY_COMPARE(controller.library()->rowCount(), 3);

        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY2(window != nullptr, "qml/Main.qml did not load from the module");
        controller.navigation()->goHome();
        controller.showMediaDetails(idAt(controller.library(), 0));

        QQuickItem *screen = nullptr;
        QTRY_VERIFY((screen = itemNamed(window, "detailsScreen")) != nullptr);

        // MarqueeTheme.scaled reads lean-back mode, whose default is on; the
        // fixed oracle sizes are the compact ones, so the surface is measured
        // there. MovieDetailView.swift:35-45 fixes the hero and poster at
        // 400/560 and 138/210.
        controller.settings()->setLeanBackMode(false);
        QTRY_COMPARE(screen->property("heroHeight").toReal(), 400.0);
        QCOMPARE(screen->property("heroPosterWidth").toReal(), 138.0);
        QCOMPARE(screen->property("heroPosterHeight").toReal(), 207.0);
        // MovieDetailView.swift:263: heroTitleOverlay's title stack is spaced
        // 10, not 8.
        auto *heroTitle = itemNamed(window, "detailsTitle");
        QVERIFY(heroTitle != nullptr);
        QVERIFY(heroTitle->parentItem() != nullptr);
        QCOMPARE(heroTitle->parentItem()->property("spacing").toReal(), 10.0);

        const char *sections[] = {
            "detailsHero",
            "detailsHeroFallback",
            "detailsHeroBlur",
            "detailsBack",
            "detailsTitle",
            "detailsMetadataLine",
            "detailsPosterPreview",
            "detailsActions",
            "detailsPlayButton",
            "detailsMoreLikeThis",
            "detailsMoreLikeThisHeader",
            "detailsMoreLikeThisRow",
            "detailsFileInfo",
            "detailsFileInfoHeader",
            "detailsFileInfoRow",
        };
        for (const char *name : sections) {
            QQuickItem *section = itemNamed(window, name);
            QVERIFY2(section != nullptr, name);
            // The hero fallback pair is source infrastructure, not painted
            // chrome: the fallback Image stays invisible by design and the
            // blur shows only once the fallback resolves, so presence —
            // not visibility — is the contract for those two.
            const QString sectionName = QString::fromUtf8(name);
            if (sectionName == QStringLiteral("detailsHeroFallback")
                || sectionName == QStringLiteral("detailsHeroBlur")) {
                continue;
            }
            QTRY_VERIFY2(section->isVisible(), name);
        }

        // Empty overview and director are omitted whole, not rendered as a
        // header over nothing or a dangling prefix: MovieDetailView.swift:456
        // wraps SYNOPSIS and :493 wraps the director line, header and prefix
        // included. There is no emptiness binding to judge yet: the QML
        // hard-codes `visible: false` on both sections
        // (DetailsScreen.qml:621, :659) and the offline catalog carries no
        // overview and no director field (src/catalog/MediaItem.hpp), so
        // every assertion below checks `!isVisible()` against a constant —
        // and the close-up layout check below passes by the same constant.
        // On the day an overview/director field lands, this suite as
        // written would NOT catch a wiring regression there. An invisible
        // Column child is skipped by the column layout, so no space and no
        // inter-section gap remain.
        auto *synopsis = itemNamed(window, "detailsSynopsis");
        QVERIFY(synopsis != nullptr);
        QVERIFY(!synopsis->isVisible());
        auto *director = itemNamed(window, "detailsDirector");
        QVERIFY(director != nullptr);
        QVERIFY(!director->isVisible());
        QVERIFY(itemNamed(window, "detailsSynopsisHeader") != nullptr);
        QVERIFY(!itemNamed(window, "detailsSynopsisHeader")->isVisible());
        QVERIFY(itemNamed(window, "detailsDirectorPrefix") != nullptr);
        QVERIFY(!itemNamed(window, "detailsDirectorPrefix")->isVisible());
        QVERIFY(itemNamed(window, "detailsDirectorName") != nullptr);
        QVERIFY(!itemNamed(window, "detailsDirectorName")->isVisible());
        // With both sections gone the layout closes up: the action row is
        // the content column's first child (MovieDetailView.swift:135-137),
        // and the related row follows it directly, one section spacing
        // below. The omission half passes by the same constants as above —
        // both omitted sections are hard-coded `visible: false` — so, like
        // the visibility checks, it would NOT catch a failure-to-show
        // regression on the day an overview/director field lands: the suite
        // exercises only empty inputs here. With the old header/prefix
        // bytes the related row would sit lower by those sections' heights
        // plus two spacings.
        auto *content = itemNamed(window, "detailsContent");
        QVERIFY(content != nullptr);
        auto *actionsRow = itemNamed(window, "detailsActions");
        QVERIFY(actionsRow != nullptr);
        QCOMPARE(actionsRow->parentItem(), content);
        QCOMPARE(actionsRow->y(), 0.0);
        auto *moreLike = itemNamed(window, "detailsMoreLikeThis");
        QVERIFY(moreLike != nullptr);
        QCOMPARE(moreLike->y(), actionsRow->y() + actionsRow->height()
                                    + content->property("spacing").toReal());

        // Back chrome: DetailBackChromeLayout (RemoteGridFocus.swift:2842-2859)
        // is a 32/48-point circle 12/14 points from the leading edge, pinned
        // to the oracle constants (:2845-2846), not to the screen's own
        // properties.
        QQuickItem *back = itemNamed(window, "detailsBack");
        QVERIFY(back != nullptr);
        QCOMPARE(back->width(), 32.0);
        QCOMPARE(back->height(), 32.0);
        QCOMPARE(back->x(), 12.0);
        QCOMPARE(screen->property("backButtonSize").toReal(), 32.0);
        QCOMPARE(screen->property("backLeadingPadding").toReal(), 12.0);

        // The oracle's empty-input rendering: SYNOPSIS draws nothing at all
        // and Directed by draws no line; certification, rating, and genres
        // draw nothing.
        QVERIFY(!itemNamed(window, "detailsSynopsisBody")->isVisible());
        QVERIFY(!itemNamed(window, "detailsSynopsisToggle")->isVisible());
        QVERIFY(itemNamed(window, "detailsCertification") != nullptr);
        QVERIFY(!itemNamed(window, "detailsCertification")->isVisible());
        QVERIFY(itemNamed(window, "detailsRating") != nullptr);
        QVERIFY(!itemNamed(window, "detailsRating")->isVisible());
        QVERIFY(itemNamed(window, "detailsGenres") != nullptr);
        QVERIFY(!itemNamed(window, "detailsGenres")->isVisible());

        // The related row shares the franchise with Arrival Two: "Arrival" is
        // the family of both, so the row lists only that title.
        QCOMPARE(textOf(window, "detailsMoreLikeThisHeader"),
                 QStringLiteral("MORE LIKE THIS"));

        // DetailBackChromeLayout.fitsBeforeContent
        // (RemoteGridFocus.swift:2856-2858): the chrome fits in the gutter
        // before content starts.
        QVERIFY(screen->property("backLeadingPadding").toReal()
                    + screen->property("backButtonSize").toReal()
                <= screen->property("outerPadding").toReal());

        // The order on screen is the oracle's order: hero, actions, related,
        // file info. SYNOPSIS and Directed by are absent for these empty
        // inputs, so they take no place in the order.
        // MovieDetailView.swift:53-56 stacks heroSection then contentArea,
        // and :135-137 makes actionButtons contentArea's FIRST child, so the
        // action row begins at or below the hero's BOTTOM edge — never
        // inside the hero. (A `hero top <= actions top` check is true for
        // any ordinarily positioned descendant of the hero and cannot fail.)
        const auto sceneTop = [&](const char *name) {
            QQuickItem *item = itemNamed(window, name);
            return item->mapRectToItem(window->contentItem(), item->boundingRect()).top();
        };
        const auto sceneBottom = [&](const char *name) {
            QQuickItem *item = itemNamed(window, name);
            return item->mapRectToItem(window->contentItem(), item->boundingRect()).bottom();
        };
        QVERIFY2(sceneTop("detailsActions") >= sceneBottom("detailsHero"),
                 qPrintable(QStringLiteral("the action row starts inside the hero: "
                                           "actions top %1, hero bottom %2")
                                .arg(sceneTop("detailsActions"))
                                .arg(sceneBottom("detailsHero"))));
        QVERIFY(sceneTop("detailsActions") < sceneTop("detailsMoreLikeThis"));
        QVERIFY(sceneTop("detailsMoreLikeThis") < sceneTop("detailsFileInfo"));

        // The franchise ranks both ways, so the second title lists the first;
        // Moon shares neither franchise nor decade with Arrival Two, so it
        // draws the related section as the oracle does for an empty `similar`:
        // nothing at all.
        controller.showMediaDetails(idAt(controller.library(), 1));
        QTRY_COMPARE(textOf(window, "detailsTitle"), QStringLiteral("Arrival Two"));
        QTRY_VERIFY(itemNamed(window, "detailsMoreLikeThis")->isVisible());

        controller.showMediaDetails(idAt(controller.library(), 2));
        QTRY_COMPARE(textOf(window, "detailsTitle"), QStringLiteral("Moon"));
        QTRY_VERIFY(!itemNamed(window, "detailsMoreLikeThis")->isVisible());
    }

    // MovieDetailView.swift:220-259: the posterless hero fallback is the
    // surface gradient alone, MarqueeTheme.surfaceElevated (#1a1525) at
    // .topLeading running to the page background (#0d0b1a,
    // MarqueeTheme.swift:105) at .bottomTrailing (:222-229) — a diagonal,
    // not a vertical ramp, and not a horizontal ramp either. The production
    // colours separate the diagonal from a vertical ramp across the hero's
    // top band. A direct grab of the Canvas then uses high-contrast endpoints
    // in the narrowest supported window and compares two same-x pixels: that
    // arrangement makes the native gradient's y component observable, so a
    // horizontal `createLinearGradient(0, 0, width, 0)` fails on painted ink.
    void theHeroFallbackGradientRunsTopLeadingToBottomTrailing()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        QTemporaryDir library;
        QVERIFY(writeMediaFile(library.path(), QStringLiteral("Moon (2009).mkv"),
                               2 * 1024 * 1024));

        ApplicationController controller;
        controller.setTemporaryLibraryRoot(library.path());
        QTRY_COMPARE(controller.library()->rowCount(), 1);

        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY2(window != nullptr, "qml/Main.qml did not load from the module");
        controller.navigation()->goHome();
        controller.settings()->setLeanBackMode(false);
        controller.showMediaDetails(idAt(controller.library(), 0));

        QQuickItem *hero = nullptr;
        QTRY_VERIFY((hero = itemNamed(window, "detailsHero")) != nullptr);
        QTRY_COMPARE(hero->height(), 400.0);

        const QColor elevated(0x1a, 0x15, 0x25);
        const QColor background(0x0d, 0x0b, 0x1a);
        const auto diagonalMix = [&](qreal t) {
            const auto channel = [&](int from, int to) {
                return qRound(from + (to - from) * t);
            };
            return QColor(channel(elevated.red(), background.red()),
                          channel(elevated.green(), background.green()),
                          channel(elevated.blue(), background.blue()));
        };

        // The leading probe clears the Back chrome (12..44 by 16..48) and
        // its resting shadow; both top probes sit six points below the
        // hero's top edge, where the :204-213 vertical page-background
        // scrim is still within the tolerance of 5. Derive both probes from
        // the geometry sampled with each grab: a Wayland compositor may
        // resize the toplevel after its requested size first laid out, and a
        // live rectangle retained across that resize addresses the wrong
        // frame at DPR 2.
        const auto probeAt = [hero](const render_probe::Capture &capture, bool trailing) {
            const QRectF heroScene = capture.geometryOf(hero).sceneRect;
            return QPointF(trailing ? heroScene.right() - 6.0 : heroScene.left() + 90.0,
                           heroScene.top() + 6.0);
        };
        const auto oracleAt = [&](const QRectF &heroScene, const QPointF &probe) {
            const qreal w = heroScene.width();
            const qreal h = heroScene.height();
            const qreal t = ((probe.x() - heroScene.left()) * w
                             + (probe.y() - heroScene.top()) * h)
                / (w * w + h * h);
            return diagonalMix(std::clamp(t, 0.0, 1.0));
        };

        const auto paintedAt = [](const render_probe::Capture &capture,
                                  const QPointF &probe) {
            return capture.image.pixelColor(
                qRound(probe.x() * capture.devicePixelRatio),
                qRound(probe.y() * capture.devicePixelRatio));
        };
        bool ready = false;
        const render_probe::Capture capture = render_probe::captureWindowUntil(
            window, {hero},
            [&](const render_probe::Capture &candidate) {
                const QRectF heroScene = candidate.geometryOf(hero).sceneRect;
                if (heroScene.right() > candidate.logicalSize.width()) {
                    return false;
                }
                const QPointF leadingProbe = probeAt(candidate, false);
                return render_probe::withinTolerance(
                    paintedAt(candidate, leadingProbe), oracleAt(heroScene, leadingProbe), 5);
            },
            5000, &ready);
        QVERIFY2(ready, "the hero fallback never painted its leading ink");

        const QRectF heroScene = capture.geometryOf(hero).sceneRect;
        const QPointF leadingProbe = probeAt(capture, false);
        const QPointF trailingProbe = probeAt(capture, true);
        const QColor expectedLeading = oracleAt(heroScene, leadingProbe);
        const QColor expectedTrailing = oracleAt(heroScene, trailingProbe);
        const QColor paintedLeading = paintedAt(capture, leadingProbe);
        const QColor paintedTrailing = paintedAt(capture, trailingProbe);
        // The capture gate above already required the leading probe within
        // 5 of the oracle mix before the frame was accepted, so the
        // leading check below restates that gate on the accepted frame —
        // it documents the accepted ink, it does not discover it. The
        // discovery assertions are the trailing probe (which the gate
        // never examined) and the vector check after it.
        QVERIFY2(render_probe::withinTolerance(paintedLeading, expectedLeading, 5),
                 qPrintable(QStringLiteral("the hero's leading band paints %1, not %2")
                                .arg(paintedLeading.name(), expectedLeading.name())));
        QVERIFY2(render_probe::withinTolerance(paintedTrailing, expectedTrailing, 5),
                 qPrintable(QStringLiteral("the hero's trailing corner paints %1, not the "
                                           "oracle's diagonal mix %2")
                                .arg(paintedTrailing.name(), expectedTrailing.name())));
        // The diagonal genuinely varies across the top band; a vertical ramp
        // paints both probes the same.
        QVERIFY2(render_probe::departureFrom(paintedTrailing, paintedLeading) >= 8,
                 qPrintable(QStringLiteral("the fallback gradient does not vary across the "
                                           "hero's top band: leading %1, trailing %2")
                                .arg(paintedLeading.name(), paintedTrailing.name())));

        // Read the live Canvas.Image backing store, excluding the hero's
        // scrims and chrome. The display-backed capture above already proves
        // that this Canvas reached the shipped scene; using Canvas.toDataURL
        // here avoids asking grabToImage to re-render it through a second GPU
        // offscreen surface. Its production endpoints must paint the
        // source-backed colours.
        QQuickItem *fallbackGradient = itemNamed(window, "detailsHeroFallbackGradient");
        QVERIFY2(fallbackGradient != nullptr, "the details hero paints no fallback gradient");
        QVERIFY2(fallbackGradient->inherits("QQuickCanvasItem"),
                 "the details hero fallback is not painted by a Canvas");
        const qreal gradientWidth = fallbackGradient->width();
        const qreal gradientHeight = fallbackGradient->height();
        QVERIFY2(gradientWidth > 1000.0,
                 qPrintable(QStringLiteral("the fallback gradient paints no hero-wide rect: width %1")
                                .arg(gradientWidth)));
        QCOMPARE(gradientHeight, 400.0);
        const auto pixelAt = [](const QImage &image, qreal x, qreal y) {
            return image.pixelColor(
                std::clamp(qRound(x * (image.width() - 1)), 0, image.width() - 1),
                std::clamp(qRound(y * (image.height() - 1)), 0, image.height() - 1));
        };
        const QImage adultCanvas = canvasImage(fallbackGradient);
        QVERIFY2(!adultCanvas.isNull(), "the details hero Canvas image could not be read");
        QVERIFY2(render_probe::withinTolerance(pixelAt(adultCanvas, 0.01, 0.01), elevated, 3),
                 qPrintable(QStringLiteral("the Canvas leading endpoint paints %1, not %2")
                                .arg(pixelAt(adultCanvas, 0.01, 0.01).name(), elevated.name())));
        QVERIFY2(render_probe::withinTolerance(pixelAt(adultCanvas, 0.99, 0.99), background, 3),
                 qPrintable(QStringLiteral("the Canvas trailing endpoint paints %1, not %2")
                                .arg(pixelAt(adultCanvas, 0.99, 0.99).name(), background.name())));

        // Kids mode changes the page-background stop while the Details
        // surface remains alive. Observe the Canvas's painted endpoint rather
        // than a property copied before the native call.
        QSignalSpy paintedSpy(fallbackGradient, SIGNAL(painted()));
        QVERIFY(paintedSpy.isValid());
        const qsizetype adultPaintCount = paintedSpy.count();
        const QString kidsProfileId = controller.profiles()->profiles().at(1).id;
        QVERIFY(controller.chooseProfile(kidsProfileId));
        QVERIFY(controller.kidsMode());
        QTRY_VERIFY(paintedSpy.count() > adultPaintCount);
        const QColor kidsBackground(QStringLiteral("#140e28"));
        const QImage kidsCanvas = canvasImage(fallbackGradient);
        QVERIFY2(!kidsCanvas.isNull(), "the kids-mode hero Canvas image could not be read");
        QVERIFY2(render_probe::withinTolerance(
                     pixelAt(kidsCanvas, 0.99, 0.99), kidsBackground, 3),
                 qPrintable(QStringLiteral("the repainted Canvas endpoint paints %1, not %2")
                                .arg(pixelAt(kidsCanvas, 0.99, 0.99).name(),
                                     kidsBackground.name())));

        // At the normal hero ratio the production endpoint colours differ by
        // too little for their y contribution to survive renderer rounding.
        // Narrow the live surface and temporarily use white-to-black stops;
        // the production Canvas and native paint call are unchanged. On this
        // geometry the oracle predicts a large same-x vertical separation.
        window->resize(1100, 900);
        QTRY_VERIFY(fallbackGradient->width() < gradientWidth - 100.0);
        QTRY_COMPARE(fallbackGradient->height(), 400.0);
        const qsizetype contrastPaintCount = paintedSpy.count();
        QVERIFY(fallbackGradient->setProperty("stopStart", QColor(Qt::white)));
        QVERIFY(fallbackGradient->setProperty("stopEnd", QColor(Qt::black)));
        QTRY_VERIFY(paintedSpy.count() > contrastPaintCount);

        const qreal narrowWidth = fallbackGradient->width();
        const qreal narrowHeight = fallbackGradient->height();
        const qreal topY = 0.05;
        const qreal bottomY = 0.95;
        const qreal denominator = narrowWidth * narrowWidth + narrowHeight * narrowHeight;
        const auto expectedGray = [&](qreal y) {
            const qreal t = (0.5 * narrowWidth * narrowWidth
                             + y * narrowHeight * narrowHeight)
                / denominator;
            return qRound(255.0 * (1.0 - std::clamp(t, 0.0, 1.0)));
        };
        const int expectedSeparation = expectedGray(topY) - expectedGray(bottomY);
        QVERIFY2(expectedSeparation >= 20,
                 qPrintable(QStringLiteral("the direct Canvas probe geometry separates the y "
                                           "component by only %1 levels")
                                .arg(expectedSeparation)));

        const QImage contrastCanvas = canvasImage(fallbackGradient);
        QVERIFY2(!contrastCanvas.isNull(),
                 "the high-contrast hero Canvas image could not be read");
        const QColor paintedTop = pixelAt(contrastCanvas, 0.5, topY);
        const QColor paintedBottom = pixelAt(contrastCanvas, 0.5, bottomY);
        const QColor expectedTop(expectedGray(topY), expectedGray(topY), expectedGray(topY));
        const QColor expectedBottom(expectedGray(bottomY), expectedGray(bottomY),
                                    expectedGray(bottomY));
        QVERIFY2(render_probe::withinTolerance(paintedTop, expectedTop, 3),
                 qPrintable(QStringLiteral("the Canvas top probe paints %1, not %2")
                                .arg(paintedTop.name(), expectedTop.name())));
        QVERIFY2(render_probe::withinTolerance(paintedBottom, expectedBottom, 3),
                 qPrintable(QStringLiteral("the Canvas bottom probe paints %1, not %2")
                                .arg(paintedBottom.name(), expectedBottom.name())));
        QVERIFY2(render_probe::departureFrom(paintedTop, paintedBottom)
                     >= expectedSeparation - 3,
                 qPrintable(QStringLiteral("the native Canvas gradient has no observable y "
                                           "component: top %1, bottom %2")
                                .arg(paintedTop.name(), paintedBottom.name())));
    }

    // MovieDetailView.swift:424-447: the Resume action exists only for a title
    // with a position that is not watched, labelled "Resume at <time>" in the
    // released playback format; the pair otherwise is Start alone. Either
    // action opens the player, Resume from the recorded position and Start
    // from the beginning.
    void theDetailsActionPairShowsResumeOnlyForATitleInProgress()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        QTemporaryDir library;
        QVERIFY(writeMediaFile(library.path(), QStringLiteral("Arrival.2016.mkv"),
                               2 * 1024 * 1024));

        ApplicationController controller;
        controller.setTemporaryLibraryRoot(library.path());
        QTRY_COMPARE(controller.library()->rowCount(), 1);

        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY2(window != nullptr, "qml/Main.qml did not load from the module");
        controller.navigation()->goHome();

        const QString mediaId = idAt(controller.library(), 0);
        controller.showMediaDetails(mediaId);
        QQuickItem *screen = nullptr;
        QTRY_VERIFY((screen = itemNamed(window, "detailsScreen")) != nullptr);

        QVERIFY(itemNamed(window, "detailsPlayButton") != nullptr);
        QTRY_VERIFY(!itemNamed(window, "detailsResumeButton")->isVisible());

        controller.library()->applyWatchProgress(mediaId, 600'000, 7'200'000, 1);
        // The open surface re-reads its facts on the model's data change, so
        // the pair appears without reopening the title.
        QQuickItem *resume = itemNamed(window, "detailsResumeButton");
        QVERIFY(resume != nullptr);
        QTRY_VERIFY(resume->isVisible());
        QCOMPARE(resume->property("label").toString(),
                 QStringLiteral("Resume at 10:00"));

        // The remote walks Start to Resume and back.
        QCOMPARE(screen->property("focusNode").toString(), QStringLiteral("start"));
        QTest::keyClick(window, Qt::Key_Right);
        QTRY_COMPARE(screen->property("focusNode").toString(),
                     QStringLiteral("continue"));
        QTest::keyClick(window, Qt::Key_Left);
        QTRY_COMPARE(screen->property("focusNode").toString(),
                     QStringLiteral("start"));

        // MarqueeTheme.scaled reads lean-back mode, whose default is on; the
        // fixed oracle sizes are the compact ones, so the pair is measured
        // there, as the sibling cases do.
        controller.settings()->setLeanBackMode(false);

        // Resume carries the movie geometry too: :433-434 pads 20/12,
        // :426-430 sets label 13 semibold and glyph play.fill 12, :436-437
        // and :441-445 an 8-point rounded rectangle with the radius-8 focus
        // surface. This fails on the old pill bytes (radius height/2,
        // padding 20/10, label 13 DemiBold, glyph 12) the same way Start did.
        // The Resume surface is flat (surfaceLayer), so its base fill is the
        // visible surface and stays at the oracle radius; the gold Start
        // button instead carries its rounding on its gradient canvas
        // while its own base hides.
        QTRY_VERIFY(resume->isVisible());
        auto *resumeContent =
            resume->findChild<QQuickItem *>(QStringLiteral("capsuleContent"));
        QVERIFY(resumeContent != nullptr);
        auto *resumeGlyph =
            resume->findChild<QQuickItem *>(QStringLiteral("capsuleGlyph"));
        QVERIFY(resumeGlyph != nullptr);
        auto *resumeLabel =
            resume->findChild<QQuickItem *>(QStringLiteral("capsuleLabel"));
        QVERIFY(resumeLabel != nullptr);
        auto *resumeFill =
            resume->findChild<QQuickItem *>(QStringLiteral("capsuleBaseFill"));
        QVERIFY(resumeFill != nullptr);
        QVERIFY2(resumeFill->property("visible").toBool(),
                 "the Resume base fill must stay visible: it is the flat surface");
        QCOMPARE(resume->property("surfaceRadius").toReal(), 8.0);
        // (R4 note: same as the Start site above — the Resume
        // `effectiveRadius == 8.0` assertion the entry names is NOT
        // removed. It reads the non-negative arm of
        // `surfaceRadius < 0 ? h/2 : surfaceRadius`
        // (DetailCapsuleButton.qml:49) for `surfaceRadius == 8.0` — the
        // same binding-read shape as the removed pill check, kept
        // deliberately as cheap cover for that arm, not because it judges
        // paint.)
        QCOMPARE(resume->property("effectiveRadius").toReal(), 8.0);
        QCOMPARE(resumeFill->property("radius").toReal(), 8.0);
        QTRY_COMPARE(resume->property("horizontalPadding").toReal(), 20.0);
        QCOMPARE(resume->property("verticalPadding").toReal(), 12.0);
        QCOMPARE(resume->property("contentSpacing").toReal(), 8.0);
        QCOMPARE(resumeLabel->property("font").value<QFont>().pixelSize(), 13);
        QCOMPARE(resumeLabel->property("font").value<QFont>().weight(),
                 QFont::DemiBold);
        QCOMPARE(resumeGlyph->width(), 12.0);
        QCOMPARE(resume->width(), resumeContent->width() + 2 * 20.0);
        QCOMPARE(resume->height(), resumeContent->height() + 2 * 12.0);
    }

    void resumingFromTheDetailsSurfaceStartsAtTheRecordedPosition()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        QTemporaryDir library;
        QVERIFY(writeMediaFile(library.path(), QStringLiteral("Arrival.2016.mkv"),
                               2 * 1024 * 1024));

        ApplicationController controller;
        controller.setTemporaryLibraryRoot(library.path());
        QTRY_COMPARE(controller.library()->rowCount(), 1);

        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY2(window != nullptr, "qml/Main.qml did not load from the module");
        controller.navigation()->goHome();

        const QString mediaId = idAt(controller.library(), 0);
        controller.library()->applyWatchProgress(mediaId, 600'000, 7'200'000, 1);
        controller.showMediaDetails(mediaId);

        QQuickItem *screen = nullptr;
        QTRY_VERIFY((screen = itemNamed(window, "detailsScreen")) != nullptr);
        QTRY_VERIFY(itemNamed(window, "detailsResumeButton")->isVisible());

        QTest::keyClick(window, Qt::Key_Right);
        QTRY_COMPARE(screen->property("focusNode").toString(),
                     QStringLiteral("continue"));
        QTest::keyClick(window, Qt::Key_Return);

        QTRY_COMPARE(controller.navigation()->route(), NavigationController::Route::Player);
        QCOMPARE(controller.player()->startPosition(), 600.0);
    }

    // MovieDetailView.swift:154-182: the leading circular Back control hands
    // the remote back to the library by the same one step the shell's Escape
    // takes.
    void backOnTheDetailsSurfaceReturnsToTheLibrary()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        QTemporaryDir library;
        QVERIFY(writeMediaFile(library.path(), QStringLiteral("Arrival.2016.mkv"),
                               2 * 1024 * 1024));

        ApplicationController controller;
        controller.setTemporaryLibraryRoot(library.path());
        QTRY_COMPARE(controller.library()->rowCount(), 1);

        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY2(window != nullptr, "qml/Main.qml did not load from the module");
        controller.navigation()->goHome();
        controller.showMediaDetails(idAt(controller.library(), 0));

        QQuickItem *screen = nullptr;
        QTRY_VERIFY((screen = itemNamed(window, "detailsScreen")) != nullptr);

        // Up from the actions reaches Back; activating it returns to the grid.
        QTest::keyClick(window, Qt::Key_Up);
        QTRY_COMPARE(screen->property("focusNode").toString(), QStringLiteral("back"));
        QTest::keyClick(window, Qt::Key_Return);
        QTRY_COMPARE(controller.navigation()->route(), NavigationController::Route::Home);
        QTRY_VERIFY(itemNamed(window, "homeRows") != nullptr);
    }
};

int main(int argc, char *argv[])
{
    QGuiApplication app(argc, argv);
    MediaDetailsTest test;
    return QTest::qExec(&test, argc, argv);
}

#include "tst_media_details.moc"
