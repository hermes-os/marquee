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
};

QTEST_MAIN(FocusNavigatorTest)
#include "tst_focus_navigator.moc"
