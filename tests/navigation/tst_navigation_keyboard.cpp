#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickItem>
#include <QQuickWindow>
#include <QTemporaryDir>
#include <QTest>
#include <QUrl>

#include "app/ApplicationController.hpp"
#include "app/AppPaths.hpp"
#include "navigation/NavigationController.hpp"

class NavigationKeyboardTest final : public QObject
{
    Q_OBJECT

private:
    // Loads the shipped Marquee module linked into this binary so these tests
    // exercise qml/Main.qml itself, not a reimplementation of it.
    QQuickWindow *loadMainWindow(ApplicationController &controller,
                                 QQmlApplicationEngine &engine)
    {
        engine.rootContext()->setContextProperty(
            QStringLiteral("appController"), &controller);
        engine.loadFromModule(QStringLiteral("Marquee"), QStringLiteral("Main"));
        if (engine.rootObjects().size() != 1) {
            return nullptr;
        }
        auto *window = qobject_cast<QQuickWindow *>(engine.rootObjects().front());
        if (window != nullptr) {
            window->requestActivate();
        }
        return window;
    }

private slots:
    void focusMovesBetweenSidebarAndContent()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());

        ApplicationController controller;
        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY2(window != nullptr, "qml/Main.qml did not load from the module");

        // The shell composes only once a profile is chosen
        // (ContentView.swift:41); the sidebar exists on the Home route.
        controller.navigation()->goHome();

        auto *sidebar = window->findChild<QQuickItem *>(QStringLiteral("sidebar"));
        auto *content = window->findChild<QQuickItem *>(QStringLiteral("contentFocus"));
        QVERIFY(sidebar != nullptr);
        QVERIFY(content != nullptr);
        QTRY_VERIFY(sidebar->hasActiveFocus());

        QTest::keyClick(window, Qt::Key_Right);
        QTRY_VERIFY(content->hasActiveFocus());

        QTest::keyClick(window, Qt::Key_Left);
        QTRY_VERIFY(sidebar->hasActiveFocus());

        AppPaths::clearRuntimeRoot();
    }

    void escapeAndBackKeysDriveNavigationHistory()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());

        ApplicationController controller;
        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY2(window != nullptr, "qml/Main.qml did not load from the module");

        auto *navigation = controller.navigation();
        QTRY_VERIFY(window->activeFocusItem() != nullptr);
        navigation->goHome();
        navigation->openRoute(NavigationController::Route::Search);
        QCOMPARE(navigation->route(), NavigationController::Route::Search);

        // SearchView.swift:352-381 answers Back on the field by handing the
        // remote to the sidebar; only a Back the sidebar owns is the shell's
        // history back.
        auto *sidebar = window->findChild<QQuickItem *>(QStringLiteral("sidebar"));
        QVERIFY(sidebar != nullptr);
        QTest::keyClick(window, Qt::Key_Escape);
        QTRY_VERIFY(sidebar->hasActiveFocus());
        QCOMPARE(navigation->route(), NavigationController::Route::Search);
        QTest::keyClick(window, Qt::Key_Escape);
        QTRY_COMPARE(navigation->route(), NavigationController::Route::Home);

        QTest::keyClick(window, Qt::Key_Back);
        QTRY_COMPARE(navigation->route(), NavigationController::Route::ProfilePicker);

        AppPaths::clearRuntimeRoot();
    }
};

int main(int argc, char *argv[])
{
    QGuiApplication app(argc, argv);
    NavigationKeyboardTest test;
    return QTest::qExec(&test, argc, argv);
}

#include "tst_navigation_keyboard.moc"
