#pragma once

#include <QColor>
#include <QQuickItem>
#include <QtQml/qqmlregistration.h>

/// Focus ring stroked inside its own bounds and screen-blended over whatever
/// the scene graph has already painted beneath it, as the released
/// application's focus chrome overlay does.
///
/// Qt Quick composites items source-over only, so the ring is a render node:
/// it paints through the software backend's QPainter with the screen
/// composition mode and through the OpenGL backend with the equivalent blend
/// function, instead of copying the artwork into a second buffer.
// Qt derives a wrapper from every QML-creatable type, so this cannot be final.
class FocusRing : public QQuickItem
{
    Q_OBJECT
    QML_ELEMENT

    Q_PROPERTY(qreal lineWidth READ lineWidth WRITE setLineWidth NOTIFY lineWidthChanged)
    Q_PROPERTY(qreal cornerRadius READ cornerRadius WRITE setCornerRadius NOTIFY cornerRadiusChanged)
    Q_PROPERTY(QColor color READ color WRITE setColor NOTIFY colorChanged)

public:
    explicit FocusRing(QQuickItem *parent = nullptr);

    [[nodiscard]] qreal lineWidth() const;
    void setLineWidth(qreal width);

    /// Radius of the ring's outer edge; the inner edge follows it inward.
    [[nodiscard]] qreal cornerRadius() const;
    void setCornerRadius(qreal radius);

    /// Stroke colour before the item's own opacity is applied.
    [[nodiscard]] QColor color() const;
    void setColor(const QColor &color);

signals:
    void lineWidthChanged();
    void cornerRadiusChanged();
    void colorChanged();

protected:
    QSGNode *updatePaintNode(QSGNode *oldNode, UpdatePaintNodeData *data) override;

private:
    qreal m_lineWidth = 2.25;
    qreal m_cornerRadius = 8.0;
    QColor m_color = Qt::white;
};
