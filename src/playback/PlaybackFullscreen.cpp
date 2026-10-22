#include "playback/PlaybackFullscreen.hpp"

PlaybackFullscreen::PlaybackFullscreen(QObject *parent)
    : QObject(parent)
{
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
    m_window = window;
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
    // Only the viewer's own controls count as a change. A window system
    // reports the states it passes through (the state before a request is
    // carried out, a late echo of an earlier one) in an order that differs
    // between platforms, so the visibility signal cannot tell who asked.
    m_viewerChanged = m_active;
    if (m_window->visibility() == QWindow::FullScreen) {
        m_window->showNormal();
    } else {
        m_window->showFullScreen();
    }
}

void PlaybackFullscreen::enter()
{
    m_viewerChanged = false;
    m_restoreOnLeave = false;
    if (m_window == nullptr || m_window->visibility() == QWindow::FullScreen) {
        return;
    }
    // Only a shown window has a windowed state worth giving back.
    const QWindow::Visibility before = m_window->visibility();
    m_wasMaximized = before == QWindow::Maximized;
    m_restoreOnLeave = before == QWindow::Windowed || before == QWindow::Maximized;
    m_window->showFullScreen();
}

void PlaybackFullscreen::leave()
{
    const bool restore = m_restoreOnLeave && !m_viewerChanged;
    m_restoreOnLeave = false;
    m_viewerChanged = false;
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
