#include <QAbstractItemModel>
#include <QCoreApplication>
#include <QEventLoop>
#include <QModelIndex>
#include <QScopeGuard>
#include <QSemaphore>
#include <QTimer>

#include "app/AppPaths.hpp"
#include "app/ApplicationController.hpp"
#include "models/LibraryModel.hpp"
#include "profiles/ProfileStore.hpp"

namespace
{
constexpr int kWaitForProjectionMs = 5'000;
constexpr int kRefreshReleaseDelayMs = 500;

[[nodiscard]] bool waitForOneLibraryItem(ApplicationController &controller)
{
    if (controller.library()->rowCount() == 1) {
        return true;
    }

    QEventLoop loop;
    bool ready = false;
    const QMetaObject::Connection connection = QObject::connect(
        controller.library(), &QAbstractItemModel::modelReset, &loop, [&] {
            if (controller.library()->rowCount() == 1) {
                ready = true;
                loop.quit();
            }
        });
    QTimer::singleShot(kWaitForProjectionMs, &loop, &QEventLoop::quit);
    loop.exec();
    QObject::disconnect(connection);
    return ready;
}
}

int main(int argc, char *argv[])
{
    if (argc != 4) {
        return 2;
    }

    QCoreApplication app(argc, argv);
    AppPaths::setRuntimeRoot(QString::fromLocal8Bit(argv[1]));
    const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });
    const QString libraryPath = QString::fromLocal8Bit(argv[2]);
    const QString refreshPath = QString::fromLocal8Bit(argv[3]);

    QSemaphore releaseRefresh;
    {
        ApplicationController controller;
        bool shutdownScheduled = false;
        const auto releaseGateOnFailure = qScopeGuard([&] {
            if (!shutdownScheduled) {
                releaseRefresh.release();
            }
        });

        if (controller.hasError()) {
            return 3;
        }

        // Progress is saved for a profile, so the viewer has chosen one.
        if (!controller.chooseProfile(controller.profiles()->profiles().at(0).id)) {
            return 8;
        }
        controller.setTemporaryLibraryRoot(libraryPath);
        if (!waitForOneLibraryItem(controller)) {
            return 4;
        }

        const QString mediaId = controller.library()
                                    ->data(controller.library()->index(0, 0),
                                           LibraryModel::IdRole)
                                    .toString();
        if (mediaId.isEmpty()) {
            return 5;
        }

        QEventLoop refreshLoop;
        bool refreshObserved = false;
        const QMetaObject::Connection observer = QObject::connect(
            &controller, &ApplicationController::catalogRefreshStarted,
            &refreshLoop,
            [&] {
                refreshObserved = true;
                refreshLoop.quit();
            },
            Qt::QueuedConnection);
        const QMetaObject::Connection gate = QObject::connect(
            &controller, &ApplicationController::catalogRefreshStarted,
            &controller,
            [&] { releaseRefresh.acquire(); },
            Qt::DirectConnection);

        controller.setTemporaryLibraryRoot(refreshPath);
        QTimer::singleShot(kWaitForProjectionMs, &refreshLoop, &QEventLoop::quit);
        refreshLoop.exec();
        QObject::disconnect(observer);
        if (!refreshObserved) {
            QObject::disconnect(gate);
            return 6;
        }

        controller.playMediaId(mediaId);
        controller.player()->reportPlayback(420.0, 7'200.0, false);

        // This release is deliberately later than the candidate's 250 ms
        // shutdown wait. Only a live shutdown event loop can reach it before
        // the child process exits.
        shutdownScheduled = true;
        QTimer::singleShot(kRefreshReleaseDelayMs, &app,
                           [&releaseRefresh] { releaseRefresh.release(); });
        QTimer::singleShot(0, &app, [&app] { app.quit(); });
        const int exitCode = app.exec();
        QObject::disconnect(gate);
        if (exitCode != 0) {
            return 7;
        }
    }

    return 0;
}
