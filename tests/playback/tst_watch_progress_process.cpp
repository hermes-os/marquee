#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QIODevice>
#include <QProcess>
#include <QScopeGuard>
#include <QSqlQuery>
#include <QTemporaryDir>
#include <QVariantList>
#include <QtTest>

#include "app/AppPaths.hpp"
#include "catalog/CatalogDatabase.hpp"

namespace
{
constexpr auto kFilmRelativePath = "Arrival (2016)/Arrival (2016).mkv";

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

/// Returns the one stored progress row as media identity and position.
[[nodiscard]] QVariantList storedProgress(const QString &catalogPath)
{
    CatalogDatabase catalog(catalogPath);
    QSqlQuery query(catalog.connection());
    if (!query.exec(QStringLiteral(
            "SELECT media_id, position_ms FROM watch_progress"))
        || !query.next()) {
        return {};
    }
    return {query.value(0), query.value(1)};
}
}

class WatchProgressProcessTest final : public QObject
{
    Q_OBJECT

private slots:
    void finalProgressSurvivesProcessExitAfterDelayedCatalogRefresh()
    {
        QTemporaryDir runtimeRoot;
        QTemporaryDir library;
        QTemporaryDir refreshRoot;
        QVERIFY(writeMediaFile(library.path(), QLatin1String(kFilmRelativePath)));

        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restorePaths = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        const QString childPath = QDir(QCoreApplication::applicationDirPath())
                                       .filePath(QStringLiteral(
                                           "marquee_watch_progress_shutdown_child"));
        QVERIFY2(QFileInfo::exists(childPath),
                 qPrintable(QStringLiteral("missing child executable: %1")
                                .arg(childPath)));

        QProcess child;
        const auto stopChild = qScopeGuard([&] {
            if (child.state() != QProcess::NotRunning) {
                child.kill();
                child.waitForFinished(5'000);
            }
        });
        child.setProgram(childPath);
        child.setArguments({runtimeRoot.path(), library.path(), refreshRoot.path()});

        QSignalSpy finished(&child, &QProcess::finished);
        child.start();
        QVERIFY2(child.waitForStarted(5'000),
                 qPrintable(QStringLiteral("child failed to start: %1")
                                .arg(child.errorString())));
        QVERIFY2(finished.wait(15'000),
                 qPrintable(QStringLiteral("child did not exit: %1")
                                .arg(QString::fromLocal8Bit(
                                    child.readAllStandardError()))));

        QCOMPARE(child.exitStatus(), QProcess::NormalExit);
        QCOMPARE(child.exitCode(), 0);

        const QVariantList row = storedProgress(AppPaths::catalogFile());
        QCOMPARE(row.size(), 2);
        QVERIFY(!row.at(0).toString().isEmpty());
        QCOMPARE(row.at(1).toLongLong(), qint64{420'000});
    }
};

int main(int argc, char *argv[])
{
    QCoreApplication app(argc, argv);
    WatchProgressProcessTest test;
    return QTest::qExec(&test, argc, argv);
}

#include "tst_watch_progress_process.moc"
