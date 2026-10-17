#include <clocale>
#include <cstdlib>

#include <QCommandLineOption>
#include <QCommandLineParser>
#include <QCoreApplication>
#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickWindow>
#include <QSGRendererInterface>
#include <QStandardPaths>

#include "app/ApplicationController.hpp"

int main(int argc, char *argv[])
{
    QQuickWindow::setGraphicsApi(QSGRendererInterface::OpenGL);

    QGuiApplication app(argc, argv);
    std::setlocale(LC_NUMERIC, "C");

    QCoreApplication::setOrganizationName(QStringLiteral("HermesOS"));
    QCoreApplication::setOrganizationDomain(QStringLiteral("hermes.local"));
    QCoreApplication::setApplicationName(QStringLiteral("Marquee"));
    QCoreApplication::setApplicationVersion(QStringLiteral(MARQUEE_VERSION));
    QGuiApplication::setDesktopFileName(QStringLiteral("marquee"));

    QCommandLineParser parser;
    parser.setApplicationDescription(
        QStringLiteral("Marquee local home-theater browser"));
    parser.addHelpOption();
    parser.addVersionOption();

    QCommandLineOption fullscreenOption(
        QStringList{QStringLiteral("f"), QStringLiteral("fullscreen")},
        QStringLiteral("Start in fullscreen mode."));
    QCommandLineOption windowedOption(
        QStringList{QStringLiteral("windowed")},
        QStringLiteral("Start in a normal window for development."));
    QCommandLineOption libraryOption(
        QStringList{QStringLiteral("library")},
        QStringLiteral("Temporarily add a library root for this run."),
        QStringLiteral("path"));
    QCommandLineOption tvLibraryOption(
        QStringList{QStringLiteral("tv-library")},
        QStringLiteral("Temporarily add a TV Shows root for this run."),
        QStringLiteral("path"));
    QCommandLineOption playOption(
        QStringList{QStringLiteral("play")},
        QStringLiteral("Play a local media file immediately."),
        QStringLiteral("path"));
    QCommandLineOption testModeOption(
        QStringList{QStringLiteral("test-mode")},
        QStringLiteral("Use Qt test paths instead of user data paths."));

    parser.addOption(fullscreenOption);
    parser.addOption(windowedOption);
    parser.addOption(libraryOption);
    parser.addOption(tvLibraryOption);
    parser.addOption(playOption);
    parser.addOption(testModeOption);
    parser.process(app);

    if (parser.isSet(testModeOption)) {
        QStandardPaths::setTestModeEnabled(true);
    }

    ApplicationController controller;
    if (parser.isSet(fullscreenOption)) {
        controller.setStartFullscreen(true);
    } else if (parser.isSet(windowedOption)) {
        controller.setStartFullscreen(false);
    }
    if (parser.isSet(tvLibraryOption)) {
        controller.setTemporaryTvShowsRoot(parser.value(tvLibraryOption));
    }
    if (parser.isSet(libraryOption)) {
        controller.setTemporaryLibraryRoot(parser.value(libraryOption));
    }
    if (parser.isSet(playOption)) {
        controller.playLocalFile(parser.value(playOption));
    }

    QQmlApplicationEngine engine;
    engine.rootContext()->setContextProperty(
        QStringLiteral("appController"), &controller);

    QObject::connect(
        &engine,
        &QQmlApplicationEngine::objectCreationFailed,
        &app,
        [] { QCoreApplication::exit(EXIT_FAILURE); },
        Qt::QueuedConnection);

    engine.loadFromModule(QStringLiteral("Marquee"), QStringLiteral("Main"));
    return app.exec();
}
