#include <QtTest>

#include <QDir>
#include <QFile>
#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickItem>
#include <QQuickWindow>
#include <QTemporaryDir>
#include <QUrl>

#include <algorithm>

#include "app/AppPaths.hpp"
#include "app/ApplicationController.hpp"
#include "navigation/NavigationController.hpp"
#include "settings/SettingsSession.hpp"
#include "settings/SettingsStore.hpp"

namespace
{
[[nodiscard]] bool writeFile(const QString &path, const QByteArray &bytes)
{
    QDir().mkpath(QFileInfo(path).absolutePath());
    QFile file(path);
    return file.open(QIODevice::WriteOnly) && file.write(bytes) == bytes.size();
}

struct Shell
{
    QTemporaryDir runtimeRoot;
    QTemporaryDir library;
    std::unique_ptr<ApplicationController> controller;
    std::unique_ptr<QQmlApplicationEngine> engine;
    QQuickWindow *window = nullptr;
    QQuickItem *screen = nullptr;

    ~Shell()
    {
        engine.reset();
        controller.reset();
        AppPaths::clearRuntimeRoot();
    }
};

void press(Shell &shell, Qt::Key key)
{
    QTest::keyClick(shell.window, key);
    QCoreApplication::processEvents();
}

[[nodiscard]] QQuickItem *find(const Shell &shell, const char *objectName)
{
    return shell.window->findChild<QQuickItem *>(QString::fromLatin1(objectName));
}

[[nodiscard]] bool hasText(const QQuickItem *item, const QString &text)
{
    if (item->property("text").toString() == text) {
        return true;
    }
    const auto children = item->childItems();
    return std::any_of(children.begin(), children.end(), [&text](const QQuickItem *child) {
        return hasText(child, text);
    });
}

[[nodiscard]] bool focusedIs(const Shell &shell, const char *objectName)
{
    auto *item = find(shell, objectName);
    return item != nullptr && item->property("focused").toBool();
}
}

class TestSettingsScreen : public QObject
{
    Q_OBJECT

    // Loads the shipped module and lands on the settings route with one
    // scanned fixture root, the remote handed in from the sidebar.
    [[nodiscard]] bool openSettings(Shell &shell)
    {
        AppPaths::setRuntimeRoot(shell.runtimeRoot.path());
        if (!writeFile(shell.library.path() + QStringLiteral("/Heat.1995.mkv"), "media")) {
            return false;
        }
        shell.controller = std::make_unique<ApplicationController>();
        shell.controller->setStartFullscreen(false);
        shell.controller->settings()->setLibraryRoots({shell.library.path()});
        if (!QTest::qWaitFor([&] { return shell.controller->library()->rowCount() == 1; })) {
            return false;
        }
        shell.engine = std::make_unique<QQmlApplicationEngine>();
        shell.engine->rootContext()->setContextProperty(QStringLiteral("appController"),
                                                        shell.controller.get());
        shell.engine->loadFromModule(QStringLiteral("Marquee"), QStringLiteral("Main"));
        if (shell.engine->rootObjects().size() != 1) {
            return false;
        }
        shell.window = qobject_cast<QQuickWindow *>(shell.engine->rootObjects().front());
        if (shell.window == nullptr) {
            return false;
        }
        shell.window->resize(1600, 900);
        shell.window->show();
        shell.window->requestActivate();
        if (!QTest::qWaitForWindowActive(shell.window)) {
            return false;
        }
        shell.controller->chooseProfile(
            shell.controller->profiles()->profileAt(0).value(QStringLiteral("id")).toString());
        if (!QTest::qWaitFor([&] { return !shell.controller->profileExitInFlight(); })) {
            return false;
        }
        shell.controller->navigation()->openRoute(NavigationController::Route::Settings);
        if (!QTest::qWaitFor([&] {
                shell.screen = find(shell, "settingsScroller");
                return shell.screen != nullptr;
            })) {
            return false;
        }
        shell.screen = shell.screen->parentItem();
        // The sidebar holds the remote on arrival; Right hands it over.
        press(shell, Qt::Key_Right);
        return QTest::qWaitFor([&] { return shell.screen->hasActiveFocus(); });
    }

private slots:
    void showsTheHeaderOverviewAndEverySection()
    {
        Shell shell;
        QVERIFY(openSettings(shell));

        auto *title = find(shell, "settingsTitle");
        QVERIFY(title != nullptr);
        QCOMPARE(title->property("text").toString(), QStringLiteral("Settings"));

        for (const char *section : {"librarySection", "playbackSection", "soundSection",
                                    "storageSection", "aboutSection"}) {
            auto *item = find(shell, section);
            QVERIFY2(item != nullptr, section);
            QVERIFY2(item->isVisible(), section);
        }

        auto *capsule = find(shell, "scanStatusCapsule");
        QVERIFY(capsule != nullptr);
        QTRY_VERIFY(!shell.controller->scanning());

        auto *overview = find(shell, "settingsOverview");
        QVERIFY(overview != nullptr);
        QCOMPARE(overview->property("columns").toInt(), 4);

        auto *version = find(shell, "versionLabel");
        QVERIFY(version != nullptr);
        QCOMPARE(version->property("text").toString(),
                 QStringLiteral("Version %1").arg(shell.controller->version()));
    }

    // The language and size rows have a consumer (MpvVideoItem reads them when
    // a file opens), so none of the Playback copy may call them inert.
    void playbackRowsThatApplyDoNotSaySaved()
    {
        Shell shell;
        QVERIFY(openSettings(shell));

        QStringList titles;
        for (const char *row : {"subtitleLanguageRow", "subtitleSizeRow", "audioLanguageRow"}) {
            auto *item = find(shell, row);
            QVERIFY2(item != nullptr, row);
            for (auto *text : item->findChildren<QQuickItem *>()) {
                const QVariant value = text->property("text");
                if (value.typeId() == QMetaType::QString) {
                    titles.append(value.toString());
                }
            }
        }
        QVERIFY(titles.contains(QStringLiteral("Default Subtitle Language")));
        QVERIFY(titles.contains(QStringLiteral("Subtitle Size")));
        QVERIFY(titles.contains(QStringLiteral("Default Audio Language")));
        for (const QString &text : std::as_const(titles)) {
            QVERIFY2(!text.contains(QStringLiteral("Saved")), qPrintable(text));
        }
        QVERIFY2(find(shell, "playbackPendingNote") == nullptr,
                 "The note that calls the Playback rows inert is still shown");
    }

    void listsTheConfiguredRootAndRemovesItFromTheRemote()
    {
        Shell shell;
        QVERIFY(openSettings(shell));

        auto *repeater = find(shell, "folderRepeater");
        QVERIFY(repeater != nullptr);
        QCOMPARE(repeater->property("count").toInt(), 1);
        QVERIFY(focusedIs(shell, "folderRepeater") == false);
        QCOMPARE(shell.screen->property("focusIndex").toInt(), 0);

        press(shell, Qt::Key_Return);
        QTRY_COMPARE(shell.controller->settings()->libraryRoots(), QStringList{});
        QTRY_COMPARE(repeater->property("count").toInt(), 0);
        QTRY_VERIFY(focusedIs(shell, "addFolderControl"));
    }

    void walksTheControlsInReadingOrder()
    {
        Shell shell;
        QVERIFY(openSettings(shell));

        press(shell, Qt::Key_Down);
        QTRY_VERIFY(focusedIs(shell, "addFolderControl"));
        // SettingsDetailView.swift:194-197: the TV Shows list follows the
        // movies list, empty here, so only its Add Folder is in the walk.
        press(shell, Qt::Key_Down);
        QTRY_VERIFY(focusedIs(shell, "addTvFolderControl"));
        press(shell, Qt::Key_Down);
        QTRY_VERIFY(focusedIs(shell, "onlineMetadataRow"));
        press(shell, Qt::Key_Down);
        QTRY_VERIFY(focusedIs(shell, "rescanRow"));
        press(shell, Qt::Key_Down);
        QTRY_VERIFY(focusedIs(shell, "hardwareDecodingRow"));
        press(shell, Qt::Key_Down);
        QTRY_VERIFY(focusedIs(shell, "autoPlayRow"));
        press(shell, Qt::Key_Down);
        QTRY_VERIFY(focusedIs(shell, "subtitleLanguageRow"));
        press(shell, Qt::Key_Down);
        QTRY_VERIFY(focusedIs(shell, "subtitleSizeRow"));
        press(shell, Qt::Key_Down);
        QTRY_VERIFY(focusedIs(shell, "audioLanguageRow"));
        press(shell, Qt::Key_Down);
        QTRY_VERIFY(focusedIs(shell, "interfaceSoundsRow"));
        press(shell, Qt::Key_Down);
        QTRY_VERIFY(focusedIs(shell, "launchIdentRow"));
        press(shell, Qt::Key_Down);
        QTRY_VERIFY(focusedIs(shell, "soundPackRow"));
        press(shell, Qt::Key_Down);
        QTRY_VERIFY(focusedIs(shell, "imageCacheRow"));
        press(shell, Qt::Key_Down);
        QTRY_VERIFY(focusedIs(shell, "watchHistoryRow"));
        press(shell, Qt::Key_Down);
        QTRY_VERIFY(focusedIs(shell, "diagnosticsRow"));

        // The last control keeps the remote.
        press(shell, Qt::Key_Down);
        QTRY_VERIFY(focusedIs(shell, "diagnosticsRow"));

        // The scroller followed the focus down the page.
        auto *scroller = find(shell, "settingsScroller");
        QVERIFY(scroller != nullptr);
        QTRY_VERIFY(scroller->property("contentY").toReal() > 0);
    }

    void togglesSwitchesAndStepsPickersAndTheSlider()
    {
        Shell shell;
        QVERIFY(openSettings(shell));
        auto *settings = shell.controller->settings();

        press(shell, Qt::Key_Down);
        press(shell, Qt::Key_Down);
        press(shell, Qt::Key_Down);
        QTRY_VERIFY(focusedIs(shell, "onlineMetadataRow"));
        const bool onlineBefore = settings->onlineMetadataEnabled();
        press(shell, Qt::Key_Return);
        QTRY_COMPARE(settings->onlineMetadataEnabled(), !onlineBefore);

        for (int step = 0; step < 4; ++step) {
            press(shell, Qt::Key_Down);
        }
        QTRY_VERIFY(focusedIs(shell, "subtitleLanguageRow"));
        QCOMPARE(settings->defaultSubtitleLanguage(), QStringLiteral("None"));
        press(shell, Qt::Key_Right);
        QTRY_COMPARE(settings->defaultSubtitleLanguage(), QStringLiteral("English"));
        press(shell, Qt::Key_Left);
        QTRY_COMPARE(settings->defaultSubtitleLanguage(), QStringLiteral("None"));

        press(shell, Qt::Key_Down);
        QTRY_VERIFY(focusedIs(shell, "subtitleSizeRow"));
        const double scaleBefore = settings->subtitleScale();
        press(shell, Qt::Key_Right);
        QTRY_VERIFY(qFuzzyCompare(settings->subtitleScale(), scaleBefore + 0.05));
        auto *value = find(shell, "subtitleScaleValue");
        QVERIFY(value != nullptr);
        QCOMPARE(value->property("text").toString(),
                 QStringLiteral("%1%").arg(qRound((scaleBefore + 0.05) * 100)));

        for (int step = 0; step < 4; ++step) {
            press(shell, Qt::Key_Down);
        }
        QTRY_VERIFY(focusedIs(shell, "soundPackRow"));
        QCOMPARE(settings->soundPack(), QString());
        press(shell, Qt::Key_Right);
        QTRY_COMPARE(settings->soundPack(), QStringLiteral("velvet"));
        auto *picker = find(shell, "soundPackPicker");
        QVERIFY(picker != nullptr);
        QCOMPARE(picker->property("currentIndex").toInt(), 0);
        // AudioIdentityService.swift:39-41: the pack reads capitalized.
        auto *label = picker->findChild<QQuickItem *>(QStringLiteral("pickerLabel"));
        QVERIFY(label != nullptr);
        QTRY_COMPARE(label->property("text").toString(), QStringLiteral("Velvet"));
    }

    void addFolderOpensTheFolderDialogAndAppendsTheChoice()
    {
        Shell shell;
        QVERIFY(openSettings(shell));

        press(shell, Qt::Key_Down);
        QTRY_VERIFY(focusedIs(shell, "addFolderControl"));
        auto *dialog = shell.screen->findChild<QObject *>(QStringLiteral("folderDialog"));
        QVERIFY(dialog != nullptr);
        QVERIFY(!dialog->property("visible").toBool());

        press(shell, Qt::Key_Return);
        QTRY_VERIFY(dialog->property("visible").toBool());
        // The panel is modal (:298): while it is up the page ignores the
        // remote and keeps its place.
        press(shell, Qt::Key_Down);
        QCOMPARE(shell.screen->property("focusIndex").toInt(), 1);
        QVERIFY(focusedIs(shell, "addFolderControl"));

        // SettingsDetailView.swift:298-302: the chosen folder is appended
        // unless already listed.
        QTemporaryDir another;
        QVERIFY(QMetaObject::invokeMethod(dialog, "close"));
        QTRY_VERIFY(!dialog->property("visible").toBool());
        // The remote comes back to the control that opened the panel.
        QTRY_VERIFY(shell.screen->hasActiveFocus());
        QVERIFY(focusedIs(shell, "addFolderControl"));
        shell.controller->settingsSession()->addLibraryRoot(
            QUrl::fromLocalFile(another.path()).toString());
        QCOMPARE(shell.controller->settings()->libraryRoots(),
                 (QStringList{shell.library.path(), another.path()}));
        shell.controller->settingsSession()->addLibraryRoot(another.path());
        QCOMPARE(shell.controller->settings()->libraryRoots().size(), 2);
        auto *repeater = find(shell, "folderRepeater");
        QTRY_COMPARE(repeater->property("count").toInt(), 2);
        // The new root's scan finishes before the directory goes away.
        QTRY_VERIFY(!shell.controller->scanning());
    }

    // SettingsDetailView.swift:701: Recently Added does not hide watched
    // titles, so the text may not name it.
    void watchHistoryTextIsTheReleasedWording()
    {
        Shell shell;
        QVERIFY(openSettings(shell));
        const QQuickItem *row = find(shell, "watchHistoryRow");
        QVERIFY(row != nullptr);
        QVERIFY(hasText(row, QStringLiteral("Watch History")));
        QVERIFY(hasText(row,
                        QStringLiteral("Clears Continue Watching, Recently Watched, and all saved playback positions.")));
    }

    void confirmsBeforeClearingHistoryAndSaysCleared()
    {
        Shell shell;
        QVERIFY(openSettings(shell));

        for (int step = 0; step < 14; ++step) {
            press(shell, Qt::Key_Down);
        }
        QTRY_VERIFY(focusedIs(shell, "watchHistoryRow"));
        QVERIFY(find(shell, "clearHistoryButton")->isVisible());
        QVERIFY(!find(shell, "clearHistoryConfirmButton")->isVisible());

        press(shell, Qt::Key_Return);
        QTRY_VERIFY(find(shell, "clearHistoryConfirmButton")->isVisible());
        QVERIFY(!find(shell, "clearHistoryButton")->isVisible());

        // Escape is the pointer's Cancel.
        press(shell, Qt::Key_Escape);
        QTRY_VERIFY(find(shell, "clearHistoryButton")->isVisible());
        QVERIFY(shell.screen->hasActiveFocus());

        press(shell, Qt::Key_Return);
        press(shell, Qt::Key_Return);
        QTRY_VERIFY(shell.controller->settingsSession()->historyCleared());
        QTRY_VERIFY(find(shell, "historyClearedLabel")->isVisible());
        QTRY_VERIFY(!find(shell, "clearHistoryButton")->isVisible());
    }

    void leftAndEscapeReturnTheRemoteToTheSidebar()
    {
        Shell shell;
        QVERIFY(openSettings(shell));
        auto *sidebar = find(shell, "sidebar");
        QVERIFY(sidebar != nullptr);

        press(shell, Qt::Key_Left);
        QTRY_VERIFY(sidebar->hasActiveFocus());
        QCOMPARE(shell.screen->property("focusIndex").toInt(), -1);

        press(shell, Qt::Key_Right);
        QTRY_VERIFY(shell.screen->hasActiveFocus());
        QCOMPARE(shell.screen->property("focusIndex").toInt(), 0);

        press(shell, Qt::Key_Escape);
        QTRY_VERIFY(sidebar->hasActiveFocus());
        QCOMPARE(shell.controller->navigation()->route(), NavigationController::Route::Settings);
    }
};

QTEST_MAIN(TestSettingsScreen)
#include "tst_settings_screen.moc"
