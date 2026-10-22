#pragma once

#include <QObject>
#include <QPointer>
#include <QWindow>
#include <QtQml/qqmlregistration.h>

/// Takes the window fullscreen while a film plays and puts it back when the
/// player closes, unless the viewer changed the window state in between. This
/// differs from the released app on purpose: the macOS player stays in
/// whatever window state it found.
///
/// The rule, decided at close from the window's state then and from whether
/// the viewer used `toggle()` (the HUD control, F and F11): on entering, a
/// window that is not fullscreen is made fullscreen and its previous state
/// (normal or maximized) is remembered. On leaving, a viewer who toggled keeps
/// the window as it is. Otherwise a window that is not fullscreen any more
/// (a window manager's own key, Super+F on Hyprland, took it out) is left as
/// it is, and one that is still fullscreen gets the remembered state back.
/// The state reports on the way in are never read: a window system's late
/// echo of an earlier state cannot be told from the window manager's own
/// change by order or timing, so no timing is involved. A window manager
/// that takes the window out of fullscreen and back in is therefore treated
/// like an untouched window. Moving to the next episode does not leave the
/// player route, so it toggles nothing.
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
    bool m_toggled{false};
    bool m_restoreOnLeave{false};
    bool m_wasMaximized{false};
};
