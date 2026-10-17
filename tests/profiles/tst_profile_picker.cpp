#include <QtTest>

#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickItem>
#include <QQuickWindow>
#include <QScopeGuard>
#include <QSignalSpy>
#include <QTemporaryDir>

#include "app/AppPaths.hpp"
#include "app/ApplicationController.hpp"
#include "navigation/NavigationController.hpp"
#include "profiles/ProfileStore.hpp"

namespace
{
[[nodiscard]] QQuickItem *itemNamed(QObject *root, const QString &name)
{
    return root->findChild<QQuickItem *>(name);
}

// A Repeater's delegates live outside the QObject tree, so a card is asked of
// the repeater that owns it.
[[nodiscard]] QQuickItem *repeaterItem(QObject *root, const QString &repeaterName, int index)
{
    auto *repeater = root->findChild<QQuickItem *>(repeaterName);
    if (repeater == nullptr) {
        return nullptr;
    }
    QQuickItem *item = nullptr;
    QMetaObject::invokeMethod(repeater, "itemAt", Q_RETURN_ARG(QQuickItem *, item), Q_ARG(int, index));
    return item;
}

[[nodiscard]] QString focusKind(QQuickItem *picker)
{
    return picker->property("focusKind").toString();
}

[[nodiscard]] QString focusProfileId(QQuickItem *picker)
{
    return picker->property("focusProfileId").toString();
}
}

class ProfilePickerTest final : public QObject
{
    Q_OBJECT

private:
    QQuickWindow *loadMainWindow(ApplicationController &controller, QQmlApplicationEngine &engine)
    {
        controller.setStartFullscreen(false);
        engine.rootContext()->setContextProperty(QStringLiteral("appController"), &controller);
        engine.loadFromModule(QStringLiteral("Marquee"), QStringLiteral("Main"));
        if (engine.rootObjects().size() != 1) {
            return nullptr;
        }
        auto *window = qobject_cast<QQuickWindow *>(engine.rootObjects().front());
        if (window != nullptr) {
            window->resize(1280, 800);
            window->requestActivate();
        }
        return window;
    }

    [[nodiscard]] QQuickItem *pickerOf(QQuickWindow *window)
    {
        auto *loader = itemNamed(window, QStringLiteral("profilePickerLoader"));
        if (loader == nullptr) {
            return nullptr;
        }
        return loader->property("item").value<QQuickItem *>();
    }

private slots:
    // ContentView.swift:29-40: the application opens on the picker, over the
    // whole window with no sidebar, and the header copy is the released
    // prompt over the library summary.
    void theApplicationOpensOnThePickerWithoutTheSidebar()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restore = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        ApplicationController controller;
        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY2(window != nullptr, "qml/Main.qml did not load from the module");

        QCOMPARE(controller.navigation()->route(), NavigationController::Route::ProfilePicker);
        QQuickItem *picker = pickerOf(window);
        QVERIFY(picker != nullptr);
        QTRY_VERIFY(picker->hasActiveFocus());

        QQuickItem *sidebar = itemNamed(window, QStringLiteral("sidebar"));
        QVERIFY(sidebar != nullptr);
        QVERIFY(!sidebar->isVisible());

        QCOMPARE(itemNamed(picker, QStringLiteral("profilePickerPrompt"))->property("text").toString(),
                 QStringLiteral("Who's watching?"));
        QCOMPARE(itemNamed(picker, QStringLiteral("profilePickerSummary"))->property("text").toString(),
                 QStringLiteral("0 movies  /  0 episodes"));

        // ProfilePickerView.swift:511-521: the focus opens on the first
        // profile when none is remembered.
        QCOMPARE(focusKind(picker), QStringLiteral("profile"));
        QCOMPARE(focusProfileId(picker), controller.profiles()->profiles().at(0).id);
    }

    // ProfilePickerView.swift:132-141, :187-235: Right walks the profiles
    // then the add item and stops; Down reaches the manage control; Up
    // returns; Left on the manage control wraps to the far end.
    void theRemoteWalksTheTopRowAndTheManageControl()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restore = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        ApplicationController controller;
        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY(window != nullptr);
        QQuickItem *picker = pickerOf(window);
        QVERIFY(picker != nullptr);
        QTRY_VERIFY(picker->hasActiveFocus());

        const QString main = controller.profiles()->profiles().at(0).id;
        const QString kids = controller.profiles()->profiles().at(1).id;

        QTest::keyClick(window, Qt::Key_Left);
        QCOMPARE(focusProfileId(picker), main);

        QTest::keyClick(window, Qt::Key_Right);
        QCOMPARE(focusKind(picker), QStringLiteral("profile"));
        QCOMPARE(focusProfileId(picker), kids);

        QTest::keyClick(window, Qt::Key_Right);
        QCOMPARE(focusKind(picker), QStringLiteral("add"));

        QTest::keyClick(window, Qt::Key_Right);
        QCOMPARE(focusKind(picker), QStringLiteral("add"));

        QTest::keyClick(window, Qt::Key_Down);
        QCOMPARE(focusKind(picker), QStringLiteral("manage"));

        QTest::keyClick(window, Qt::Key_Down);
        QCOMPARE(focusKind(picker), QStringLiteral("manage"));

        QTest::keyClick(window, Qt::Key_Left);
        QCOMPARE(focusKind(picker), QStringLiteral("add"));

        QTest::keyClick(window, Qt::Key_Down);
        QTest::keyClick(window, Qt::Key_Right);
        QCOMPARE(focusKind(picker), QStringLiteral("profile"));
        QCOMPARE(focusProfileId(picker), main);

        QTest::keyClick(window, Qt::Key_Down);
        QTest::keyClick(window, Qt::Key_Up);
        QCOMPARE(focusKind(picker), QStringLiteral("profile"));
        QCOMPARE(focusProfileId(picker), main);
    }

    // AppState.swift:267-305 and ContentView.swift:29-43: Select on a
    // profile makes it active at once, the picker stops taking input and
    // fades for 0.24 seconds, then the shell shows on Home with the sidebar
    // wearing that profile.
    void selectingAProfileFadesThePickerThenShowsTheShell()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restore = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        ApplicationController controller;
        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY(window != nullptr);
        QQuickItem *picker = pickerOf(window);
        QVERIFY(picker != nullptr);
        QTRY_VERIFY(picker->hasActiveFocus());

        QTest::keyClick(window, Qt::Key_Right);
        const QString kids = controller.profiles()->profiles().at(1).id;
        QCOMPARE(focusProfileId(picker), kids);

        QSignalSpy exitSpy(&controller, &ApplicationController::profileExitInFlightChanged);
        QTest::keyClick(window, Qt::Key_Return);

        QVERIFY(controller.profileExitInFlight());
        QCOMPARE(controller.activeProfileId(), kids);
        QCOMPARE(controller.activeProfileName(), QStringLiteral("Kids"));
        QVERIFY(controller.kidsMode());
        // ProfileSession.swift:80 and ContentView.swift:41-43: the shell is
        // composed beneath the fading picker from the moment of the choice,
        // and the picker keeps the remote until the fade ends (:83-87).
        QCOMPARE(controller.navigation()->route(), NavigationController::Route::Home);
        QCOMPARE(picker->property("exitSelectionId").toString(), kids);
        QQuickItem *shell = itemNamed(window, QStringLiteral("sidebar"));
        QVERIFY(shell != nullptr);
        QVERIFY(shell->isVisible());
        QVERIFY(!shell->isEnabled());
        QVERIFY(picker->hasActiveFocus());

        // A second choice while the exit runs is refused (AppState.swift:267).
        QTest::keyClick(window, Qt::Key_Left);
        QCOMPARE(focusProfileId(picker), kids);
        QTest::keyClick(window, Qt::Key_Return);
        QCOMPARE(controller.activeProfileId(), kids);

        QTRY_VERIFY_WITH_TIMEOUT(!controller.profileExitInFlight(), 2000);
        QCOMPARE(exitSpy.count(), 2);
        QCOMPARE(controller.navigation()->route(), NavigationController::Route::Home);

        QQuickItem *sidebar = itemNamed(window, QStringLiteral("sidebar"));
        QVERIFY(sidebar != nullptr);
        QTRY_VERIFY(sidebar->isVisible());
        QTRY_VERIFY(sidebar->hasActiveFocus());
        QCOMPARE(sidebar->property("activeProfileName").toString(), QStringLiteral("Kids"));
        QCOMPARE(sidebar->property("activeProfileAvatarIcon").toString(), QStringLiteral("hare.fill"));
        QVERIFY(sidebar->property("kidsMode").toBool());
        QVERIFY(pickerOf(window) == nullptr);

        // MarqueeSidebar.swift:110-111: the sidebar's profile control brings
        // the picker back, remembering the active profile as its focus.
        controller.switchProfile();
        QCOMPARE(controller.navigation()->route(), NavigationController::Route::ProfilePicker);
        QQuickItem *reopened = pickerOf(window);
        QVERIFY(reopened != nullptr);
        QTRY_VERIFY(reopened->hasActiveFocus());
        QCOMPARE(focusProfileId(reopened), kids);
        QVERIFY(!sidebar->isVisible());
    }

    // ProfilePickerView.swift:495-497, :664-690, :1022-1031: Manage Profiles
    // swaps the cards for tiles under the "Manage Profiles" prompt, Down from
    // a tile enters its actions (the first profile cannot move left, so Edit
    // is first), Select on an action performs it, and Back leaves management.
    void managementModeExposesTheActionsAndBackLeavesIt()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restore = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        ApplicationController controller;
        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY(window != nullptr);
        QQuickItem *picker = pickerOf(window);
        QVERIFY(picker != nullptr);
        QTRY_VERIFY(picker->hasActiveFocus());

        const QString main = controller.profiles()->profiles().at(0).id;
        const QString kids = controller.profiles()->profiles().at(1).id;

        QTest::keyClick(window, Qt::Key_Down);
        QCOMPARE(focusKind(picker), QStringLiteral("manage"));
        QTest::keyClick(window, Qt::Key_Return);
        QVERIFY(picker->property("managing").toBool());
        QCOMPARE(itemNamed(picker, QStringLiteral("profilePickerPrompt"))->property("text").toString(),
                 QStringLiteral("Manage Profiles"));
        QCOMPARE(itemNamed(picker, QStringLiteral("profileManageLabel"))->property("text").toString(),
                 QStringLiteral("Done"));
        QVERIFY(!itemNamed(picker, QStringLiteral("profileSelectionRow"))->isVisible());
        QVERIFY(itemNamed(picker, QStringLiteral("profileManagementRow"))->isVisible());

        QTest::keyClick(window, Qt::Key_Up);
        QCOMPARE(focusKind(picker), QStringLiteral("profile"));
        QCOMPARE(focusProfileId(picker), main);

        QTest::keyClick(window, Qt::Key_Down);
        QCOMPARE(focusKind(picker), QStringLiteral("action"));
        QCOMPARE(picker->property("focusAction").toInt(), 1);

        // Edit, Delete, Move Right are what the first of two profiles offers.
        QTest::keyClick(window, Qt::Key_Right);
        QCOMPARE(picker->property("focusAction").toInt(), 2);
        QTest::keyClick(window, Qt::Key_Right);
        QCOMPARE(picker->property("focusAction").toInt(), 3);
        QTest::keyClick(window, Qt::Key_Right);
        QCOMPARE(picker->property("focusAction").toInt(), 3);

        // Move Right swaps the profiles and keeps the focus on the moved one.
        QTest::keyClick(window, Qt::Key_Return);
        QCOMPARE(controller.profiles()->profiles().at(0).id, kids);
        QCOMPARE(controller.profiles()->profiles().at(1).id, main);
        QCOMPARE(focusProfileId(picker), main);

        // The last profile cannot move right; its actions are Left, Edit,
        // Delete.
        QTest::keyClick(window, Qt::Key_Up);
        QTest::keyClick(window, Qt::Key_Down);
        QCOMPARE(picker->property("focusAction").toInt(), 0);
        QTest::keyClick(window, Qt::Key_Right);
        QTest::keyClick(window, Qt::Key_Right);
        QCOMPARE(picker->property("focusAction").toInt(), 2);
        QTest::keyClick(window, Qt::Key_Right);
        QCOMPARE(picker->property("focusAction").toInt(), 2);

        // Delete asks first (:591-600); Back declines and nothing changes.
        QTest::keyClick(window, Qt::Key_Return);
        QCOMPARE(picker->property("pendingDeleteId").toString(), main);
        QVERIFY(itemNamed(picker, QStringLiteral("profileDeleteDialog"))->isVisible());
        QCOMPARE(itemNamed(picker, QStringLiteral("confirmDialogTitle"))->property("text").toString(),
                 QStringLiteral("Delete Main?"));
        QTest::keyClick(window, Qt::Key_Escape);
        QCOMPARE(picker->property("pendingDeleteId").toString(), QString());
        QCOMPARE(controller.profiles()->count(), 2);

        // Confirming removes it and the focus stays at that index.
        QTest::keyClick(window, Qt::Key_Return);
        QTest::keyClick(window, Qt::Key_Return);
        QCOMPARE(controller.profiles()->count(), 1);
        QCOMPARE(focusKind(picker), QStringLiteral("profile"));
        QCOMPARE(focusProfileId(picker), kids);

        // Back leaves management (:967-970).
        QTest::keyClick(window, Qt::Key_Escape);
        QVERIFY(!picker->property("managing").toBool());
        QCOMPARE(controller.navigation()->route(), NavigationController::Route::ProfilePicker);
    }

    // ProfilePickerView.swift:812-895 and :1257-1544: the add item opens the
    // editor as New Profile with the first catalog avatar and Adult chosen;
    // Save with a name adds the profile and the picker focuses it.
    void theAddItemOpensTheEditorAndSavingCreatesTheProfile()
    {
        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restore = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        ApplicationController controller;
        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY(window != nullptr);
        QQuickItem *picker = pickerOf(window);
        QVERIFY(picker != nullptr);
        QTRY_VERIFY(picker->hasActiveFocus());

        QTest::keyClick(window, Qt::Key_Right);
        QTest::keyClick(window, Qt::Key_Right);
        QCOMPARE(focusKind(picker), QStringLiteral("add"));
        QTest::keyClick(window, Qt::Key_Return);
        QVERIFY(picker->property("editorOpen").toBool());

        QQuickItem *editor = itemNamed(picker, QStringLiteral("profileEditor"));
        QVERIFY(editor != nullptr);
        QCOMPARE(itemNamed(editor, QStringLiteral("profileEditorTitle"))->property("text").toString(),
                 QStringLiteral("New Profile"));
        QCOMPARE(editor->property("selectedIcon").toString(), QStringLiteral("hare.fill"));
        QCOMPARE(editor->property("maturityLevel").toInt(), int(ProfileStore::Maturity::Adult));
        QVERIFY(!editor->property("canSave").toBool());

        QQuickItem *nameField = itemNamed(editor, QStringLiteral("profileEditorName"));
        QVERIFY(nameField != nullptr);
        QTRY_VERIFY(nameField->hasActiveFocus());
        for (const QChar letter : QStringLiteral("Sam")) {
            QTest::keyClick(window, letter.toLatin1());
        }
        QVERIFY(editor->property("canSave").toBool());
        QTest::keyClick(window, Qt::Key_Return);

        QVERIFY(!picker->property("editorOpen").toBool());
        QCOMPARE(controller.profiles()->count(), 3);
        const Profile created = controller.profiles()->profiles().at(2);
        QCOMPARE(created.name, QStringLiteral("Sam"));
        QCOMPARE(created.avatarIcon, QStringLiteral("hare.fill"));
        QCOMPARE(created.maturityLevel, int(ProfileStore::Maturity::Adult));
        QCOMPARE(focusKind(picker), QStringLiteral("profile"));
        QCOMPARE(focusProfileId(picker), created.id);
        QTRY_VERIFY(picker->hasActiveFocus());
    }

    // ProfilePickerView.swift:435-440 and :735-810: the card column is
    // 150/220 wide, the disc 130/190 inside a 4/6 ring outset, items 24/38
    // apart, in the compact and lean-back measurements.
    void cardsFollowTheReleasedGeometry_data()
    {
        QTest::addColumn<bool>("leanBack");
        QTest::addColumn<qreal>("cardWidth");
        QTest::addColumn<qreal>("spacing");
        QTest::addColumn<qreal>("disc");
        QTest::addColumn<qreal>("frame");
        QTest::newRow("compact") << false << 150.0 << 24.0 << 130.0 << 138.0;
        QTest::newRow("lean-back") << true << 220.0 << 38.0 << 190.0 << 202.0;
    }

    void cardsFollowTheReleasedGeometry()
    {
        QFETCH(bool, leanBack);
        QFETCH(qreal, cardWidth);
        QFETCH(qreal, spacing);
        QFETCH(qreal, disc);
        QFETCH(qreal, frame);

        QTemporaryDir runtimeRoot;
        AppPaths::setRuntimeRoot(runtimeRoot.path());
        const auto restore = qScopeGuard([] { AppPaths::clearRuntimeRoot(); });

        ApplicationController controller;
        controller.settings()->setLeanBackMode(leanBack);
        QQmlApplicationEngine engine;
        QQuickWindow *window = loadMainWindow(controller, engine);
        QVERIFY(window != nullptr);
        QQuickItem *picker = pickerOf(window);
        QVERIFY(picker != nullptr);

        QQuickItem *first = repeaterItem(picker, QStringLiteral("profileCards"), 0);
        QQuickItem *second = repeaterItem(picker, QStringLiteral("profileCards"), 1);
        QVERIFY(first != nullptr && second != nullptr);
        QCOMPARE(first->width(), cardWidth);
        QCOMPARE(second->x() - (first->x() + first->width()), spacing);

        QQuickItem *discItem = itemNamed(first, QStringLiteral("profileCardDisc"));
        QQuickItem *frameItem = itemNamed(first, QStringLiteral("profileCardDiscFrame"));
        QVERIFY(discItem != nullptr && frameItem != nullptr);
        QCOMPARE(discItem->width(), disc);
        QCOMPARE(frameItem->width(), frame);

        QQuickItem *add = itemNamed(picker, QStringLiteral("profileAddCard"));
        QVERIFY(add != nullptr);
        QVERIFY(add->isVisible());
        QCOMPARE(add->width(), cardWidth);
        QCOMPARE(itemNamed(add, QStringLiteral("profileCardTitle"))->property("text").toString(),
                 QStringLiteral("Add Profile"));
    }
};

QTEST_MAIN(ProfilePickerTest)
#include "tst_profile_picker.moc"
