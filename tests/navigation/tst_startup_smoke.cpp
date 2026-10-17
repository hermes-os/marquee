#include <QCoreApplication>
#include <QDir>
#include <QProcess>
#include <QFileInfo>
#include <QTest>

class StartupSmokeTest final : public QObject
{
    Q_OBJECT

private:
    static QString marqueeExecutable()
    {
        const QDir basePath = QDir::currentPath();
        const QStringList candidates = {
            basePath.filePath(QStringLiteral("../marquee")),
            basePath.filePath(QStringLiteral("../../marquee")),
            basePath.filePath(QStringLiteral("../../../marquee")),
            QDir(QCoreApplication::applicationDirPath()).filePath(QStringLiteral("../marquee")),
            QDir(QCoreApplication::applicationDirPath()).filePath(QStringLiteral("../../marquee"))
        };
        for (const QString &candidate : candidates) {
            if (QFileInfo::exists(candidate) && QFileInfo(candidate).isFile()) {
                return candidate;
            }
        }
        return {};
    }

private slots:
    void startsInTestMode()
    {
        const QString executable = marqueeExecutable();
        QVERIFY2(!executable.isEmpty(), "Could not locate built marquee executable");

        QProcess process;
        process.setProgram(executable);
        process.setArguments({QStringLiteral("--test-mode")});
        process.setProcessChannelMode(QProcess::ForwardedChannels);

        process.start();
        QVERIFY(process.waitForStarted());
        QTest::qWait(50);
        QCOMPARE(process.state(), QProcess::Running);

        process.terminate();
        if (!process.waitForFinished(2000)) {
            process.kill();
            QVERIFY(process.waitForFinished(1000));
        }
        QCOMPARE(process.state(), QProcess::NotRunning);
    }
};

QTEST_MAIN(StartupSmokeTest)
#include "tst_startup_smoke.moc"
