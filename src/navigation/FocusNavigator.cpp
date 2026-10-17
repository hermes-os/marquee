#include "navigation/FocusNavigator.hpp"

#include <QVariant>
#include <algorithm>

FocusNavigator::FocusNavigator(QObject *parent)
    : QObject(parent)
{
}

int FocusNavigator::row() const
{
    return m_row;
}

int FocusNavigator::column() const
{
    return m_column;
}

bool FocusNavigator::empty() const
{
    return !hasNonEmptyRows();
}

void FocusNavigator::setRowLengths(const QVariantList &rowLengths)
{
    QVector<int> rows;
    rows.reserve(rowLengths.size());
    for (const QVariant &value : rowLengths) {
        rows.push_back(std::max(0, value.toInt()));
    }
    setRows(std::move(rows));
}

void FocusNavigator::setRows(QVector<int> rowLengths, int focusRow, int focusColumn)
{
    sanitizeRows(rowLengths);
    const bool structural = m_rowLengths != rowLengths;
    const bool placed = focusRow >= 0;
    if (!structural && !placed) {
        return;
    }

    const int previousRow = m_row;
    const int previousColumn = m_column;
    if (structural) {
        const qsizetype previousSize = m_rememberedColumns.size();
        m_rowLengths = std::move(rowLengths);
        m_rememberedColumns.resize(m_rowLengths.size());
        for (qsizetype index = previousSize; index < m_rememberedColumns.size(); ++index) {
            m_rememberedColumns[index] = -1;
        }
    }
    // The caller's target replaces the old position before it is reconciled
    // with the new rows, so one change is announced and a view never sees the
    // remote on a card it was only passing through.
    if (placed) {
        m_row = focusRow;
        m_column = std::max(0, focusColumn);
    }
    reconcile();
    if (structural) {
        emit structureChanged();
    }
    if (structural || m_row != previousRow || m_column != previousColumn) {
        emit focusChanged();
    }
}

bool FocusNavigator::moveLeft()
{
    if (empty() || m_column <= 0) {
        emit boundaryHit();
        return false;
    }
    --m_column;
    m_rememberedColumns[m_row] = m_column;
    emit focusChanged();
    return true;
}

bool FocusNavigator::moveRight()
{
    if (empty() || m_rowLengths.isEmpty() || m_rowLengths[m_row] <= 0
        || m_column + 1 >= m_rowLengths.value(m_row)) {
        emit boundaryHit();
        return false;
    }
    ++m_column;
    m_rememberedColumns[m_row] = m_column;
    emit focusChanged();
    return true;
}

bool FocusNavigator::moveUp()
{
    return moveVertical(-1);
}

bool FocusNavigator::moveDown()
{
    return moveVertical(1);
}

void FocusNavigator::setPosition(int rowValue, int columnValue)
{
    if (empty()) {
        return;
    }
    const int nextRow = std::clamp(rowValue, 0, static_cast<int>(m_rowLengths.size() - 1));
    const int nextColumn = clampedColumn(nextRow, columnValue);
    if (nextRow == m_row && nextColumn == m_column) {
        return;
    }
    m_row = nextRow;
    m_column = nextColumn;
    m_rememberedColumns[m_row] = m_column;
    emit focusChanged();
}

void FocusNavigator::reset()
{
    if (empty()) {
        return;
    }
    if (m_row == 0 && m_column == 0) {
        return;
    }
    m_row = 0;
    m_column = clampedColumn(0, 0);
    if (!m_rememberedColumns.isEmpty()) {
        m_rememberedColumns[0] = m_column;
    }
    emit focusChanged();
}

bool FocusNavigator::moveVertical(int delta)
{
    if (empty()) {
        emit boundaryHit();
        return false;
    }

    int destination = m_row + delta;
    while (destination >= 0
           && destination < m_rowLengths.size()
           && m_rowLengths[destination] == 0) {
        destination += delta;
    }

    if (destination < 0 || destination >= m_rowLengths.size()) {
        emit boundaryHit();
        return false;
    }

    m_rememberedColumns[m_row] = m_column;
    const int storedColumn = m_rememberedColumns.value(destination, -1);
    const int requestedColumn = storedColumn >= 0 ? storedColumn : m_column;
    m_row = destination;
    m_column = clampedColumn(destination, requestedColumn);
    m_rememberedColumns[m_row] = m_column;
    emit focusChanged();
    return true;
}

int FocusNavigator::clampedColumn(int rowValue, int requested) const
{
    if (rowValue < 0 || rowValue >= m_rowLengths.size()) {
        return 0;
    }
    const int length = m_rowLengths[rowValue];
    return length <= 0 ? 0 : std::clamp(requested, 0, length - 1);
}

bool FocusNavigator::hasNonEmptyRows() const
{
    for (const int length : m_rowLengths) {
        if (length > 0) {
            return true;
        }
    }
    return false;
}

void FocusNavigator::reconcile()
{
    if (m_rowLengths.isEmpty() || !hasNonEmptyRows()) {
        m_row = 0;
        m_column = 0;
        m_rememberedColumns.clear();
        return;
    }

    m_row = std::clamp(m_row, 0, static_cast<int>(m_rowLengths.size() - 1));
    if (m_rowLengths[m_row] == 0) {
        const auto firstNonEmpty = std::find_if(
            m_rowLengths.cbegin(), m_rowLengths.cend(), [](int count) { return count > 0; });
        m_row = firstNonEmpty == m_rowLengths.cend()
            ? 0
            : static_cast<int>(std::distance(m_rowLengths.cbegin(), firstNonEmpty));
    }
    m_column = clampedColumn(m_row, m_column);
    if (!m_rememberedColumns.isEmpty()) {
        m_rememberedColumns[m_row] = m_column;
    }
}

void FocusNavigator::sanitizeRows(QVector<int> &rows)
{
    for (int &length : rows) {
        length = std::max(0, length);
    }
}
