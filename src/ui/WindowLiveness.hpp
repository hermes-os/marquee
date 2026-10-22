#pragma once

#include <QObject>
#include <QPointer>
#include <QWindow>
#include <QtQml/qqmlregistration.h>

/// Whether a window can be seen at all: shown, not minimized, and exposed to
/// the display. QML reads only `visible` and `visibility`, which a window
/// hidden behind a minimize or an unmapped surface can still report as shown,
/// so an animation or timer that should stop with the window asks this.
class WindowLiveness : public QObject
{
    Q_OBJECT
    QML_ELEMENT

    Q_PROPERTY(QWindow *window READ window WRITE setWindow NOTIFY windowChanged)
    Q_PROPERTY(bool live READ live NOTIFY liveChanged)

public:
    explicit WindowLiveness(QObject *parent = nullptr);

    [[nodiscard]] QWindow *window() const;
    void setWindow(QWindow *window);
    /// True while a window is attached, visible, not minimized and exposed.
    [[nodiscard]] bool live() const;

    bool eventFilter(QObject *watched, QEvent *event) override;

signals:
    void windowChanged();
    void liveChanged();

private:
    void refresh();

    QPointer<QWindow> m_window;
    bool m_live{false};
};
