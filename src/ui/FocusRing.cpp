#include "ui/FocusRing.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <memory>

#include <QMatrix4x4>
#include <QOpenGLBuffer>
#include <QOpenGLContext>
#include <QOpenGLFunctions>
#include <QOpenGLShaderProgram>
#include <QOpenGLVertexArrayObject>
#include <QPainter>
#include <QPainterPath>
#include <QQuickWindow>
#include <QSGRendererInterface>
#include <QSGRenderNode>
#include <QVector4D>

namespace
{
struct RingShape
{
    QRectF rect;
    qreal cornerRadius = 0.0;
    qreal lineWidth = 0.0;
    QColor color;
};

// Rounded-rectangle signed distance in item units, negative inside. The band
// between -lineWidth and 0 is the ring, so its outer edge sits on the item's
// own bounds and its corners keep the requested radius.
constexpr auto kVertexShader = R"(
attribute highp vec2 position;
uniform highp mat4 matrix;
varying highp vec2 itemPosition;
void main() {
    itemPosition = position;
    gl_Position = matrix * vec4(position, 0.0, 1.0);
}
)";

constexpr auto kFragmentShader = R"(
#ifdef GL_ES
precision highp float;
#endif
uniform highp vec4 rect;
uniform highp float cornerRadius;
uniform highp float lineWidth;
uniform highp float unitsPerPixel;
uniform lowp vec4 color;
varying highp vec2 itemPosition;
void main() {
    highp vec2 centre = rect.xy + rect.zw * 0.5;
    highp vec2 halfSize = rect.zw * 0.5 - vec2(cornerRadius);
    highp vec2 q = abs(itemPosition - centre) - halfSize;
    highp float distance = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - cornerRadius;
    highp float outer = clamp(0.5 - distance / unitsPerPixel, 0.0, 1.0);
    highp float inner = clamp(0.5 + (distance + lineWidth) / unitsPerPixel, 0.0, 1.0);
    gl_FragColor = color * (outer * inner);
}
)";

class FocusRingNode final : public QSGRenderNode
{
public:
    explicit FocusRingNode(QQuickWindow *window)
        : m_window(window)
    {
    }

    ~FocusRingNode() override
    {
        releaseResources();
    }

    void sync(const RingShape &shape)
    {
        m_shape = shape;
    }

    [[nodiscard]] StateFlags changedStates() const override
    {
        return BlendState | ScissorState | StencilState;
    }

    [[nodiscard]] RenderingFlags flags() const override
    {
        return BoundedRectRendering;
    }

    [[nodiscard]] QRectF rect() const override
    {
        return m_shape.rect;
    }

    void render(const RenderState *state) override
    {
        if (m_shape.lineWidth <= 0.0 || m_shape.rect.isEmpty()) {
            return;
        }
        switch (m_window->rendererInterface()->graphicsApi()) {
        case QSGRendererInterface::Software:
            renderWithPainter(state);
            return;
        case QSGRendererInterface::OpenGL:
            renderWithOpenGL(state);
            return;
        default:
            return;
        }
    }

    void releaseResources() override
    {
        m_vertexArray.reset();
        m_vertexBuffer.reset();
        m_program.reset();
    }

private:
    [[nodiscard]] QColor strokeColor() const
    {
        QColor color = m_shape.color;
        color.setAlphaF(color.alphaF() * float(inheritedOpacity()));
        return color;
    }

    void renderWithPainter(const RenderState *state)
    {
        auto *painter = static_cast<QPainter *>(m_window->rendererInterface()->getResource(
            m_window, QSGRendererInterface::PainterResource));
        if (painter == nullptr) {
            return;
        }

        painter->save();
        const QRegion *clipRegion = state->clipRegion();
        if (clipRegion != nullptr && !clipRegion->isEmpty()) {
            painter->setClipRegion(*clipRegion, Qt::ReplaceClip);
        }
        painter->setTransform(matrix()->toTransform());
        painter->setRenderHint(QPainter::Antialiasing, true);
        painter->setCompositionMode(QPainter::CompositionMode_Screen);

        const qreal halfWidth = m_shape.lineWidth / 2.0;
        const qreal centreRadius = std::max(0.0, m_shape.cornerRadius - halfWidth);
        QPainterPath path;
        path.addRoundedRect(
            m_shape.rect.adjusted(halfWidth, halfWidth, -halfWidth, -halfWidth),
            centreRadius, centreRadius);
        painter->setPen(QPen(strokeColor(), m_shape.lineWidth));
        painter->setBrush(Qt::NoBrush);
        painter->drawPath(path);
        painter->restore();
    }

    void renderWithOpenGL(const RenderState *state)
    {
        QOpenGLContext *context = QOpenGLContext::currentContext();
        if (context == nullptr) {
            return;
        }
        QOpenGLFunctions *gl = context->functions();
        if (!m_program && !createOpenGLResources()) {
            return;
        }

        const QMatrix4x4 combined = *state->projectionMatrix() * *matrix();
        const QRectF rect = m_shape.rect;
        const std::array<float, 8> vertices{
            float(rect.left()), float(rect.top()),
            float(rect.right()), float(rect.top()),
            float(rect.left()), float(rect.bottom()),
            float(rect.right()), float(rect.bottom())};

        m_program->bind();
        m_program->setUniformValue("matrix", combined);
        m_program->setUniformValue("rect",
                                   QVector4D(float(rect.x()), float(rect.y()),
                                             float(rect.width()), float(rect.height())));
        m_program->setUniformValue("cornerRadius", float(m_shape.cornerRadius));
        m_program->setUniformValue("lineWidth", float(m_shape.lineWidth));
        m_program->setUniformValue("unitsPerPixel", float(unitsPerPixel(gl, combined)));
        const QColor color = strokeColor();
        const float alpha = float(color.alphaF());
        m_program->setUniformValue("color",
                                   QVector4D(float(color.redF()) * alpha,
                                             float(color.greenF()) * alpha,
                                             float(color.blueF()) * alpha, alpha));

        QOpenGLVertexArrayObject::Binder binder(m_vertexArray.get());
        m_vertexBuffer->bind();
        m_vertexBuffer->write(0, vertices.data(), int(sizeof(vertices)));
        m_program->enableAttributeArray("position");
        m_program->setAttributeBuffer("position", GL_FLOAT, 0, 2);

        // Screen: destination + source * (1 - destination), with the source
        // already premultiplied by the ring's opacity and edge coverage.
        gl->glEnable(GL_BLEND);
        gl->glBlendFunc(GL_ONE_MINUS_DST_COLOR, GL_ONE);
        gl->glDisable(GL_DEPTH_TEST);
        gl->glDisable(GL_CULL_FACE);
        if (state->scissorEnabled()) {
            const QRect scissor = state->scissorRect();
            gl->glEnable(GL_SCISSOR_TEST);
            gl->glScissor(scissor.x(), scissor.y(), scissor.width(), scissor.height());
        } else {
            gl->glDisable(GL_SCISSOR_TEST);
        }
        if (state->stencilEnabled()) {
            gl->glEnable(GL_STENCIL_TEST);
            gl->glStencilFunc(GL_EQUAL, state->stencilValue(), 0xff);
            gl->glStencilOp(GL_KEEP, GL_KEEP, GL_KEEP);
        } else {
            gl->glDisable(GL_STENCIL_TEST);
        }

        gl->glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);

        m_program->disableAttributeArray("position");
        m_vertexBuffer->release();
        m_program->release();
    }

    [[nodiscard]] bool createOpenGLResources()
    {
        auto program = std::make_unique<QOpenGLShaderProgram>();
        if (!program->addShaderFromSourceCode(QOpenGLShader::Vertex, kVertexShader)
            || !program->addShaderFromSourceCode(QOpenGLShader::Fragment, kFragmentShader)
            || !program->link()) {
            return false;
        }

        auto vertexArray = std::make_unique<QOpenGLVertexArrayObject>();
        vertexArray->create();
        QOpenGLVertexArrayObject::Binder binder(vertexArray.get());

        auto vertexBuffer = std::make_unique<QOpenGLBuffer>(QOpenGLBuffer::VertexBuffer);
        if (!vertexBuffer->create()) {
            return false;
        }
        vertexBuffer->setUsagePattern(QOpenGLBuffer::DynamicDraw);
        vertexBuffer->bind();
        vertexBuffer->allocate(int(8 * sizeof(float)));
        vertexBuffer->release();

        m_program = std::move(program);
        m_vertexArray = std::move(vertexArray);
        m_vertexBuffer = std::move(vertexBuffer);
        return true;
    }

    // Item units covered by one output pixel, so the edge coverage ramp is
    // one pixel wide whatever scale the item is drawn at.
    [[nodiscard]] static qreal unitsPerPixel(QOpenGLFunctions *gl, const QMatrix4x4 &combined)
    {
        std::array<GLint, 4> viewport{};
        gl->glGetIntegerv(GL_VIEWPORT, viewport.data());
        const QVector4D origin = combined * QVector4D(0.0f, 0.0f, 0.0f, 1.0f);
        const QVector4D unitX = combined * QVector4D(1.0f, 0.0f, 0.0f, 1.0f);
        const QVector4D unitY = combined * QVector4D(0.0f, 1.0f, 0.0f, 1.0f);
        const qreal pixelsPerUnitX = qreal(std::abs(unitX.x() - origin.x())) * viewport[2] / 2.0;
        const qreal pixelsPerUnitY = qreal(std::abs(unitY.y() - origin.y())) * viewport[3] / 2.0;
        const qreal pixelsPerUnit = std::max(pixelsPerUnitX, pixelsPerUnitY);
        return pixelsPerUnit > 0.0 ? 1.0 / pixelsPerUnit : 1.0;
    }

    QQuickWindow *m_window;
    RingShape m_shape;
    std::unique_ptr<QOpenGLShaderProgram> m_program;
    std::unique_ptr<QOpenGLVertexArrayObject> m_vertexArray;
    std::unique_ptr<QOpenGLBuffer> m_vertexBuffer;
};
}

FocusRing::FocusRing(QQuickItem *parent)
    : QQuickItem(parent)
{
    setFlag(ItemHasContents, true);
}

qreal FocusRing::lineWidth() const
{
    return m_lineWidth;
}

void FocusRing::setLineWidth(qreal width)
{
    if (qFuzzyCompare(m_lineWidth, width)) {
        return;
    }
    m_lineWidth = width;
    emit lineWidthChanged();
    update();
}

qreal FocusRing::cornerRadius() const
{
    return m_cornerRadius;
}

void FocusRing::setCornerRadius(qreal radius)
{
    if (qFuzzyCompare(m_cornerRadius, radius)) {
        return;
    }
    m_cornerRadius = radius;
    emit cornerRadiusChanged();
    update();
}

QColor FocusRing::color() const
{
    return m_color;
}

void FocusRing::setColor(const QColor &color)
{
    if (m_color == color) {
        return;
    }
    m_color = color;
    emit colorChanged();
    update();
}

QSGNode *FocusRing::updatePaintNode(QSGNode *oldNode, UpdatePaintNodeData *)
{
    auto *node = static_cast<FocusRingNode *>(oldNode);
    if (node == nullptr) {
        node = new FocusRingNode(window());
    }
    node->sync(RingShape{
        .rect = boundingRect(),
        .cornerRadius = m_cornerRadius,
        .lineWidth = m_lineWidth,
        .color = m_color});
    node->markDirty(QSGNode::DirtyMaterial);
    return node;
}
