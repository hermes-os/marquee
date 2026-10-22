#include "playback/PlaybackFullscreen.hpp"

PlaybackFullscreen::PlaybackFullscreen(QObject *parent)
    : QObject(parent)
{
    m_settle.setSingleShot(true);
    m_settle.setInterval(kSettleMs);
    connect(&m_settle, &QTimer::timeout, this, [this] { m_awaitingFullscreen = false; });
}

QWindow *PlaybackFullscreen::window() const
{
    return m_window;
}

void PlaybackFullscreen::setWindow(QWindow *window)
{
    if (m_window == window) {
        return;
    }
    if (m_window != nullptr) {
        disconnect(m_window, &QWindow::visibilityChanged, this, nullptr);
    }
    m_window = window;
    m_awaitingFullscreen = false;
    if (m_window != nullptr) {
        connect(m_window, &QWindow::visibilityChanged, this,
                &PlaybackFullscreen::onVisibilityChanged);
    }
    emit windowChanged();
    if (m_active) {
        enter();
    }
}

bool PlaybackFullscreen::active() const
{
    return m_active;
}

void PlaybackFullscreen::setActive(bool active)
{
    if (m_active == active) {
        return;
    }
    m_active = active;
    if (m_active) {
        enter();
    } else {
        leave();
    }
    emit activeChanged();
}

void PlaybackFullscreen::toggle()
{
    if (m_window == nullptr) {
        return;
    }
    // The viewer's own controls are a change however the window system
    // reports it.
    m_viewerChanged = m_active;
    if (m_window->visibility() == QWindow::FullScreen) {
        m_window->showNormal();
    } else {
        m_window->showFullScreen();
    }
}

void PlaybackFullscreen::onVisibilityChanged(QWindow::Visibility visibility)
{
    if (!m_active) {
        return;
    }
    // Whatever the window reports while our request settles is ours: a
    // window system passes through the states before and after it, and a
    // late echo of an earlier one can arrive after fullscreen did. Each
    // report extends the wait. Once it is quiet, a further change was not
    // asked for here: the window manager's own fullscreen key, a tiling
    // shortcut, a maximize button.
    if (m_awaitingFullscreen) {
        m_settle.start();
        return;
    }
    m_viewerChanged = true;
}

void PlaybackFullscreen::enter()
{
    m_viewerChanged = false;
    m_restoreOnLeave = false;
    m_awaitingFullscreen = false;
    m_settle.stop();
    if (m_window == nullptr || m_window->visibility() == QWindow::FullScreen) {
        return;
    }
    // Only a shown window has a windowed state worth giving back.
    const QWindow::Visibility before = m_window->visibility();
    m_wasMaximized = before == QWindow::Maximized;
    m_restoreOnLeave = before == QWindow::Windowed || before == QWindow::Maximized;
    m_awaitingFullscreen = m_restoreOnLeave;
    if (m_awaitingFullscreen) {
        m_settle.start();
    }
    m_window->showFullScreen();
}

void PlaybackFullscreen::leave()
{
    const bool restore = m_restoreOnLeave && !m_viewerChanged;
    m_restoreOnLeave = false;
    m_viewerChanged = false;
    m_awaitingFullscreen = false;
    m_settle.stop();
    if (!restore || m_window == nullptr
        || m_window->visibility() != QWindow::FullScreen) {
        return;
    }
    if (m_wasMaximized) {
        m_window->showMaximized();
    } else {
        m_window->showNormal();
    }
}
