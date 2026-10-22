#include <QtTest>

#include "navigation/FocusNavigator.hpp"

class FocusNavigatorTest final : public QObject
{
    Q_OBJECT

private slots:
    void clampsAtHorizontalBoundaries()
    {
        FocusNavigator navigator;
        navigator.setRows({3, 2});

        QVERIFY(!navigator.moveLeft());
        QCOMPARE(navigator.column(), 0);
        QVERIFY(navigator.moveRight());
        QVERIFY(navigator.moveRight());
        QVERIFY(!navigator.moveRight());
        QCOMPARE(navigator.column(), 2);
    }

    void remembersColumnPerRow()
    {
        FocusNavigator navigator;
        navigator.setRows({5, 2, 6});
        navigator.setPosition(0, 4);

        QVERIFY(navigator.moveDown());
        QCOMPARE(navigator.row(), 1);
        QCOMPARE(navigator.column(), 1);
        navigator.setPosition(1, 1);

        QVERIFY(navigator.moveDown());
        QCOMPARE(navigator.row(), 2);
        QCOMPARE(navigator.column(), 1);
        navigator.setPosition(2, 5);

        QVERIFY(navigator.moveUp());
        QCOMPARE(navigator.row(), 1);
        QCOMPARE(navigator.column(), 1);
        QVERIFY(navigator.moveUp());
        QCOMPARE(navigator.row(), 0);
        QCOMPARE(navigator.column(), 4);
    }

    void skipsEmptyRows()
    {
        FocusNavigator navigator;
        navigator.setRows({2, 0, 0, 3});
        QVERIFY(navigator.moveDown());
        QCOMPARE(navigator.row(), 3);
        QVERIFY(navigator.moveUp());
        QCOMPARE(navigator.row(), 0);
    }

    void reconcilesWhenRowsShrink()
    {
        FocusNavigator navigator;
        navigator.setRows({4, 4});
        navigator.setPosition(1, 3);
        navigator.setRows({1});
        QCOMPARE(navigator.row(), 0);
        QCOMPARE(navigator.column(), 0);
    }

    void treatsAllZeroRowsAsEmpty()
    {
        FocusNavigator navigator;
        navigator.setRows({0, 0, 0});
        QVERIFY(navigator.empty());
        QVERIFY(!navigator.moveRight());
        QVERIFY(!navigator.moveDown());
    }

    void resetReturnsToTheFirstCardAndForgetsRememberedColumns()
    {
        FocusNavigator navigator;
        navigator.setRows({5, 5, 5});
        navigator.setPosition(1, 3);
        navigator.setPosition(2, 4);
        QSignalSpy spy(&navigator, &FocusNavigator::focusChanged);

        navigator.reset();
        QCOMPARE(navigator.row(), 0);
        QCOMPARE(navigator.column(), 0);
        QCOMPARE(spy.count(), 1);

        // Row 1 was left on column 3; a rebuilt surface carries the column
        // of the card it came from, not the old memory.
        QVERIFY(navigator.moveDown());
        QCOMPARE(navigator.column(), 0);

        // Already first: nothing is announced, memory is still cleared.
        navigator.setPosition(2, 4);
        navigator.reset();
        navigator.reset();
        // reset, moveDown, setPosition, and one reset that moved.
        QCOMPARE(spy.count(), 4);
    }

    void resetSkipsALeadingEmptyRow()
    {
        FocusNavigator navigator;
        navigator.setRows({0, 3});
        navigator.setPosition(1, 2);
        navigator.reset();
        QCOMPARE(navigator.row(), 1);
        QCOMPARE(navigator.column(), 0);
    }

    void rememberedColumnsFollowTheirRowIdsAndResetForgetsThem()
    {
        FocusNavigator navigator;
        navigator.setRows({3, 4, 5}, -1, 0, {"a", "b", "c"});
        navigator.setPosition(1, 3);
        navigator.setPosition(2, 4);
        navigator.setPosition(0, 0);

        // "a" vanishes: "b" and "c" slide up and keep their own columns.
        navigator.setRows({4, 5}, 0, 3, {"b", "c"});
        QVERIFY(navigator.moveDown());
        QCOMPARE(navigator.column(), 4);
        QVERIFY(navigator.moveUp());
        QCOMPARE(navigator.column(), 3);

        // "n" appears above: "c" is still where it was left, "n" has nothing.
        navigator.setRows({2, 4, 5}, 1, 3, {"n", "b", "c"});
        QVERIFY(navigator.moveDown());
        QCOMPARE(navigator.column(), 4);
        QVERIFY(navigator.moveUp());
        QVERIFY(navigator.moveUp());
        QCOMPARE(navigator.column(), 1);

        navigator.reset();
        QVERIFY(navigator.moveDown());
        QVERIFY(navigator.moveDown());
        QCOMPARE(navigator.column(), 0);
    }
};

QTEST_MAIN(FocusNavigatorTest)
#include "tst_focus_navigator.moc"
