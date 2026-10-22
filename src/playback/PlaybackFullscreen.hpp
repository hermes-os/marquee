#pragma once

#include <QObject>
#include <QPointer>
#include <QWindow>
#include <QtQml/qqmlregistration.h>

/// Takes the window fullscreen while a film plays and puts it back when the
/// player closes, unless the viewer changed fullscreen in between. This
/// differs from the released app on purpose: the macOS player stays in
/// whatever window state it found.
///
/// The rule: on entering, a window that is not fullscreen is made fullscreen
/// and its previous state (normal or maximized) is remembered. On leaving,
/// that state is restored only when the viewer did not change fullscreen
/// during playback: the HUD control, F and F11 all go through `toggle()`. A
/// viewer who left the window windowed, or fullscreen, finds it as set. Moving to the next episode does not leave the player route, so it
/// toggles nothing.
// Qt derives a wrapper from every QML-creatable type, so this cannot be final.
class PlaybackFullscreen : public QObject
{
    Q_OBJECT
    QML_ELEMENT

    Q_PROPERTY(QWindow *window READ window WRITE setWindow NOTIFY windowChanged)
    /// True while the player route is up.
    Q_PROPERTY(bool active READ active WRITE setActive NOTIFY activeChanged)

public:
    explicit PlaybackFullscreen(QObject *parent = nullptr);

    [[nodiscard]] QWindow *window() const;
    void setWindow(QWindow *window);
    [[nodiscard]] bool active() const;
    void setActive(bool active);

    /// The viewer's own fullscreen toggle (F11, F, the HUD control).
    Q_INVOKABLE void toggle();

signals:
    void windowChanged();
    void activeChanged();

private:
    void enter();
    void leave();

    QPointer<QWindow> m_window;
    bool m_active{false};
    bool m_viewerChanged{false};
    bool m_restoreOnLeave{false};
    bool m_wasMaximized{false};
};
