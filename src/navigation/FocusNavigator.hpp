#pragma once

#include <QObject>
#include <QVector>
#include <QVariant>
#include <QtQml/qqmlregistration.h>

class FocusNavigator : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_UNCREATABLE("FocusNavigator is not creatable from QML")

    Q_PROPERTY(int row READ row NOTIFY focusChanged)
    Q_PROPERTY(int column READ column NOTIFY focusChanged)
    Q_PROPERTY(bool empty READ empty NOTIFY structureChanged)

public:
    explicit FocusNavigator(QObject *parent = nullptr);

    [[nodiscard]] int row() const;
    [[nodiscard]] int column() const;
    [[nodiscard]] bool empty() const;

    Q_INVOKABLE void setRowLengths(const QVariantList &rowLengths);
    /// Replaces the row lengths. A non-negative `focusRow` also moves the
    /// remote to that row and column (clamped to the new rows) in the same
    /// announcement, for a model that knows where the card it rests on went.
    void setRows(QVector<int> rowLengths, int focusRow = -1, int focusColumn = 0);

    Q_INVOKABLE bool moveLeft();
    Q_INVOKABLE bool moveRight();
    Q_INVOKABLE bool moveUp();
    Q_INVOKABLE bool moveDown();
    Q_INVOKABLE void setPosition(int row, int column);
    Q_INVOKABLE void reset();
    /// Moves to `row` the way a vertical move reaches it: at the column the
    /// remote last rested on there, or the current column where it never has.
    /// A missing or empty row, or the row the remote is on, changes nothing.
    void moveToRow(int row);

signals:
    void focusChanged();
    void structureChanged();
    void boundaryHit();

private:
    [[nodiscard]] bool moveVertical(int delta);
    void enterRow(int destination);
    [[nodiscard]] int clampedColumn(int row, int requested) const;
    [[nodiscard]] bool hasNonEmptyRows() const;
    void reconcile();
    static void sanitizeRows(QVector<int> &rows);

    QVector<int> m_rowLengths;
    QVector<int> m_rememberedColumns;
    int m_row{0};
    int m_column{0};
};
