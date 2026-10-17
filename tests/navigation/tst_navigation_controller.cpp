#include <QtTest>

#include "navigation/NavigationController.hpp"

class NavigationControllerTest final : public QObject
{
    Q_OBJECT

private slots:
    void recordsAndRestoresRouteHistory()
    {
        NavigationController navigation;
        navigation.resetTo(NavigationController::Route::Home);
        navigation.openRoute(NavigationController::Route::Movies);
        navigation.openDetails(QStringLiteral("movie-1"));
        navigation.openPlayer(QStringLiteral("movie-1"));

        QCOMPARE(navigation.route(), NavigationController::Route::Player);
        QCOMPARE(navigation.selectedMediaId(), QStringLiteral("movie-1"));
        QVERIFY(navigation.canGoBack());

        navigation.goBack();
        QCOMPARE(navigation.route(), NavigationController::Route::Details);
        QCOMPARE(navigation.selectedMediaId(), QStringLiteral("movie-1"));

        navigation.goBack();
        QCOMPARE(navigation.route(), NavigationController::Route::Movies);
        QVERIFY(navigation.selectedMediaId().isEmpty());

        navigation.goBack();
        QCOMPARE(navigation.route(), NavigationController::Route::Home);
        QVERIFY(!navigation.canGoBack());
    }

    void ignoresInvalidDetailsAndPlayerRequests()
    {
        NavigationController navigation;
        navigation.resetTo(NavigationController::Route::Home);
        navigation.openDetails(QStringLiteral("  "));
        navigation.openPlayer(QString{});
        QCOMPARE(navigation.route(), NavigationController::Route::Home);
        QVERIFY(!navigation.canGoBack());
    }

    void resetClearsHistory()
    {
        NavigationController navigation;
        navigation.resetTo(NavigationController::Route::Home);
        navigation.openRoute(NavigationController::Route::Search);
        QVERIFY(navigation.canGoBack());
        navigation.resetTo(NavigationController::Route::ProfilePicker);
        QCOMPARE(navigation.route(), NavigationController::Route::ProfilePicker);
        QVERIFY(!navigation.canGoBack());
    }

    void resetRejectsInvalidDetailsAndPlayerRoutes()
    {
        NavigationController navigation;
        navigation.resetTo(NavigationController::Route::Home);
        navigation.resetTo(NavigationController::Route::Details, QString());
        QCOMPARE(navigation.route(), NavigationController::Route::Home);
        navigation.resetTo(NavigationController::Route::Player, QString());
        QCOMPARE(navigation.route(), NavigationController::Route::Home);
        navigation.resetTo(NavigationController::Route::Details, QStringLiteral("item-123"));
        QCOMPARE(navigation.route(), NavigationController::Route::Details);
        QCOMPARE(navigation.selectedMediaId(), QStringLiteral("item-123"));
        QCOMPARE(navigation.canGoBack(), false);
    }
};

QTEST_MAIN(NavigationControllerTest)
#include "tst_navigation_controller.moc"
