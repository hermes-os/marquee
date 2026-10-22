#include <QCoreApplication>
#include <QGuiApplication>
#include <QTest>
#include <QThread>
#include <QWindow>
#include <qpa/qwindowsysteminterface.h>

#include "playback/PlaybackFullscreen.hpp"

namespace
{
// The window system's own report of a window state, the way a compositor's
// configure reaches the application: the window does not follow a request
// until one arrives.
void report(QWindow *window, Qt::WindowState state, bool queued = false)
{
    if (queued) {
        QWindowSystemInterface::handleWindowStateChanged<QWindowSystemInterface::AsynchronousDelivery>(
            window, state);
    } else {
        QWindowSystemInterface::handleWindowStateChanged(window, state);
    }
}

// Time passing with the event loop running, then whatever it had pending.
void elapse(int ms)
{
    QThread::msleep(static_cast<unsigned long>(ms));
    QCoreApplication::processEvents();
}

// The GUI thread busy: nothing is delivered until it comes back.
void stall(int ms)
{
    QThread::msleep(static_cast<unsigned long>(ms));
}
}

// What the window is left as when the player closes. The decision is taken at
// close from the window's state then, so none of these depends on how late a
// state report arrives.
class PlaybackFullscreenTest final : public QObject
{
    Q_OBJECT

private:
    struct Fixture
    {
        QWindow window;
        PlaybackFullscreen playback;

        explicit Fixture(Qt::WindowState before = Qt::WindowNoState)
        {
            window.resize(320, 200);
            if (before == Qt::WindowMaximized) {
                window.showMaximized();
            } else if (before == Qt::WindowFullScreen) {
                window.showFullScreen();
            } else {
                window.show();
            }
            playback.setWindow(&window);
        }

        void open()
        {
            playback.setActive(true);
            // The window system confirms the request.
            report(&window, Qt::WindowFullScreen);
        }

        void close() { playback.setActive(false); }
    };

private slots:
    void initTestCase()
    {
        // The window follows reports only, so the minimal platform is the one
        // that adds no states of its own.
        QVERIFY2(QGuiApplication::platformName() == QLatin1String("minimal"),
                 qPrintable(QGuiApplication::platformName()));
        // A report is handled where it is made, unless a case queues it.
        QWindowSystemInterface::setSynchronousWindowSystemEvents(true);
    }

    void anUntouchedWindowIsGivenBackWindowed()
    {
        Fixture f;
        QCOMPARE(f.window.visibility(), QWindow::Windowed);
        f.playback.setActive(true);
        report(&f.window, Qt::WindowFullScreen);
        QCOMPARE(f.window.visibility(), QWindow::FullScreen);
        f.close();
        QCOMPARE(f.window.visibility(), QWindow::Windowed);
    }

    void anUntouchedMaximizedWindowIsGivenBackMaximized()
    {
        Fixture f(Qt::WindowMaximized);
        QCOMPARE(f.window.visibility(), QWindow::Maximized);
        f.open();
        f.close();
        QCOMPARE(f.window.visibility(), QWindow::Maximized);
    }

    void aWindowThatWasFullscreenStaysFullscreen()
    {
        Fixture f(Qt::WindowFullScreen);
        QCOMPARE(f.window.visibility(), QWindow::FullScreen);
        f.open();
        f.close();
        QCOMPARE(f.window.visibility(), QWindow::FullScreen);
    }

    // The window system passes through the old state before the new one.
    void aWindowedThenFullscreenEchoAt100msIsPlaybacksOwn()
    {
        Fixture f;
        f.playback.setActive(true);
        elapse(100);
        report(&f.window, Qt::WindowNoState);
        report(&f.window, Qt::WindowFullScreen);
        f.close();
        QCOMPARE(f.window.visibility(), QWindow::Windowed);
    }

    void aWindowedThenFullscreenEchoHandledLateIsPlaybacksOwn()
    {
        Fixture f;
        f.playback.setActive(true);
        elapse(450);
        report(&f.window, Qt::WindowNoState);
        report(&f.window, Qt::WindowFullScreen);
        f.close();
        QCOMPARE(f.window.visibility(), QWindow::Windowed);
    }

    void aLoneFullscreenEchoHandledLateIsPlaybacksOwn()
    {
        Fixture f;
        f.playback.setActive(true);
        elapse(450);
        report(&f.window, Qt::WindowFullScreen);
        f.close();
        QCOMPARE(f.window.visibility(), QWindow::Windowed);
    }

    // The echo arrived on time and sat in the queue while the GUI thread was
    // busy.
    void aStalledGuiWithAQueuedEchoPairIsPlaybacksOwn()
    {
        Fixture f;
        f.playback.setActive(true);
        report(&f.window, Qt::WindowNoState, true);
        report(&f.window, Qt::WindowFullScreen, true);
        stall(600);
        QCoreApplication::processEvents();
        QCOMPARE(f.window.visibility(), QWindow::FullScreen);
        f.close();
        QCOMPARE(f.window.visibility(), QWindow::Windowed);
    }

    void aStalledGuiWithAQueuedLoneEchoIsPlaybacksOwn()
    {
        Fixture f;
        f.playback.setActive(true);
        report(&f.window, Qt::WindowFullScreen, true);
        stall(600);
        QCoreApplication::processEvents();
        QCOMPARE(f.window.visibility(), QWindow::FullScreen);
        f.close();
        QCOMPARE(f.window.visibility(), QWindow::Windowed);
    }

    // Hyprland's Super+F and the like take the window out of fullscreen
    // without going through toggle(): the window stays as the manager left it.
    void aWindowManagerExitFromFullscreenIsLeftAsSet()
    {
        Fixture f;
        f.open();
        elapse(50);
        report(&f.window, Qt::WindowNoState);
        QCOMPARE(f.window.visibility(), QWindow::Windowed);
        f.close();
        QCOMPARE(f.window.visibility(), QWindow::Windowed);
    }

    void aWindowManagerMaximizeFromFullscreenIsLeftAsSet()
    {
        Fixture f;
        f.open();
        report(&f.window, Qt::WindowMaximized);
        QCOMPARE(f.window.visibility(), QWindow::Maximized);
        f.close();
        QCOMPARE(f.window.visibility(), QWindow::Maximized);
    }

    // The one case the rule gives up: out of fullscreen and back in cannot be
    // told from a late echo, so the window is treated as untouched.
    void aWindowManagerOutAndBackInIsGivenBackLikeAnUntouchedWindow()
    {
        Fixture f;
        f.open();
        report(&f.window, Qt::WindowNoState);
        report(&f.window, Qt::WindowFullScreen);
        f.close();
        QCOMPARE(f.window.visibility(), QWindow::Windowed);
    }

    void minimizingAndRestoringDuringPlaybackIsGivenBackWindowed()
    {
        Fixture f;
        f.open();
        report(&f.window, Qt::WindowMinimized);
        QCOMPARE(f.window.visibility(), QWindow::Minimized);
        report(&f.window, Qt::WindowFullScreen);
        QCOMPARE(f.window.visibility(), QWindow::FullScreen);
        f.close();
        QCOMPARE(f.window.visibility(), QWindow::Windowed);
    }

    void aWindowLeftMinimizedAtCloseIsLeftAlone()
    {
        Fixture f;
        f.open();
        report(&f.window, Qt::WindowMinimized);
        f.close();
        QCOMPARE(f.window.visibility(), QWindow::Minimized);
    }

    // toggle() is the viewer's change however the window system reports it.
    void aToggleOutAndBackInIsLeftFullscreen()
    {
        Fixture f;
        f.open();
        f.playback.toggle();
        report(&f.window, Qt::WindowNoState);
        QCOMPARE(f.window.visibility(), QWindow::Windowed);
        f.playback.toggle();
        report(&f.window, Qt::WindowFullScreen);
        QCOMPARE(f.window.visibility(), QWindow::FullScreen);
        f.close();
        QCOMPARE(f.window.visibility(), QWindow::FullScreen);
    }

    void aToggleOutOfFullscreenIsLeftWindowed()
    {
        Fixture f(Qt::WindowMaximized);
        f.open();
        f.playback.toggle();
        report(&f.window, Qt::WindowNoState);
        f.close();
        QCOMPARE(f.window.visibility(), QWindow::Windowed);
    }

    void aToggleOutsidePlaybackDoesNotCountForTheNextOne()
    {
        Fixture f;
        f.playback.toggle();
        report(&f.window, Qt::WindowFullScreen);
        f.playback.toggle();
        report(&f.window, Qt::WindowNoState);
        QCOMPARE(f.window.visibility(), QWindow::Windowed);
        f.open();
        f.close();
        QCOMPARE(f.window.visibility(), QWindow::Windowed);
    }

    void aSecondPlaybackStartsFromItsOwnState()
    {
        Fixture f;
        f.open();
        f.playback.toggle();
        report(&f.window, Qt::WindowNoState);
        f.close();
        QCOMPARE(f.window.visibility(), QWindow::Windowed);
        f.open();
        f.close();
        QCOMPARE(f.window.visibility(), QWindow::Windowed);
    }
};

int main(int argc, char *argv[])
{
    QGuiApplication app(argc, argv);
    PlaybackFullscreenTest test;
    return QTest::qExec(&test, argc, argv);
}

#include "tst_playback_fullscreen.moc"
