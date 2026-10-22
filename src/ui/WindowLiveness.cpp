#include "ui/WindowLiveness.hpp"

#include <QEvent>

WindowLiveness::WindowLiveness(QObject *parent)
    : QObject(parent)
{
}

QWindow *WindowLiveness::window() const
{
    return m_window;
}

void WindowLiveness::setWindow(QWindow *window)
{
    if (m_window == window) {
        return;
    }
    if (m_window) {
        m_window->removeEventFilter(this);
        disconnect(m_window, nullptr, this, nullptr);
    }
    m_window = window;
    if (m_window) {
        m_window->installEventFilter(this);
        connect(m_window, &QWindow::visibleChanged, this, &WindowLiveness::refresh);
        connect(m_window, &QWindow::visibilityChanged, this, &WindowLiveness::refresh);
    }
    emit windowChanged();
    refresh();
}

bool WindowLiveness::live() const
{
    return m_live;
}

bool WindowLiveness::eventFilter(QObject *watched, QEvent *event)
{
    if (watched == m_window.data()) {
        switch (event->type()) {
        case QEvent::Expose:
        case QEvent::Show:
        case QEvent::Hide:
        case QEvent::WindowStateChange:
            // The filter runs before the window handles the event, so the
            // answer is read once the event has been delivered.
            QMetaObject::invokeMethod(this, &WindowLiveness::refresh, Qt::QueuedConnection);
            break;
        default:
            break;
        }
    }
    return QObject::eventFilter(watched, event);
}

void WindowLiveness::refresh()
{
    const bool live = m_window && m_window->isVisible() && m_window->isExposed()
        && m_window->visibility() != QWindow::Minimized
        && m_window->visibility() != QWindow::Hidden
        && !(m_window->windowStates() & Qt::WindowMinimized);
    if (live == m_live) {
        return;
    }
    m_live = live;
    emit liveChanged();
}
