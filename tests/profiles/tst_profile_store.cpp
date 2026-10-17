#include <QtTest>

#include <QColor>
#include <QFile>
#include <QFileInfo>
#include <QScopeGuard>
#include <QSignalSpy>
#include <QTemporaryDir>

#include "profiles/ProfileStore.hpp"

namespace
{
[[nodiscard]] QString storagePath(const QTemporaryDir &dir)
{
    return dir.filePath(QStringLiteral("profiles.json"));
}

[[nodiscard]] QString addNamed(ProfileStore &store, const QString &name, int maturity)
{
    return store.addProfile(name, QStringLiteral("star.fill"), QStringLiteral("#FFD700"), maturity);
}
}

class ProfileStoreTest final : public QObject
{
    Q_OBJECT

private slots:
    // UserProfile.swift:104-107: an empty store starts with the released
    // pair, Adult "Main" in theatre masks and Kids "Kids" as the hare.
    void anEmptyStoreSeedsTheReleasedDefaultProfiles()
    {
        QTemporaryDir dir;
        ProfileStore store(storagePath(dir));
        QCOMPARE(store.count(), 2);

        const Profile main = store.profiles().at(0);
        QCOMPARE(main.name, QStringLiteral("Main"));
        QCOMPARE(main.avatarIcon, QStringLiteral("theatermasks.fill"));
        QCOMPARE(QColor(main.avatarColor), QColor(QStringLiteral("#9E86FF")));
        QCOMPARE(main.maturityLevel, int(ProfileStore::Maturity::Adult));

        const Profile kids = store.profiles().at(1);
        QCOMPARE(kids.name, QStringLiteral("Kids"));
        QCOMPARE(kids.avatarIcon, QStringLiteral("hare.fill"));
        QCOMPARE(kids.maturityLevel, int(ProfileStore::Maturity::Kids));

        QVERIFY(QFileInfo::exists(storagePath(dir)));
    }

    // ProfilePickerView.swift:132-141 and :652-662 admit the Add Profile
    // item only below five profiles.
    void addingStopsAtFiveProfiles()
    {
        QTemporaryDir dir;
        ProfileStore store(storagePath(dir));
        QSignalSpy countSpy(&store, &ProfileStore::countChanged);
        for (int index = 3; index <= 5; ++index) {
            QVERIFY(store.canAddProfile());
            QVERIFY(!addNamed(store, QStringLiteral("P%1").arg(index),
                              int(ProfileStore::Maturity::Teen)).isEmpty());
        }
        QCOMPARE(store.count(), 5);
        QVERIFY(!store.canAddProfile());
        QVERIFY(addNamed(store, QStringLiteral("Sixth"), int(ProfileStore::Maturity::Teen)).isEmpty());
        QCOMPARE(store.count(), 5);
        QCOMPARE(countSpy.count(), 3);
    }

    // ProfilePickerView.swift:1535-1540 saves the trimmed name and never an
    // empty one.
    void namesAreTrimmedAndBlankNamesAreRefused()
    {
        QTemporaryDir dir;
        ProfileStore store(storagePath(dir));
        const QString id = store.addProfile(QStringLiteral("  Alex  "), QStringLiteral("cat.fill"),
                                            QStringLiteral("#FFB347"), int(ProfileStore::Maturity::Kids));
        QVERIFY(!id.isEmpty());
        QCOMPARE(store.profileById(id).value(QStringLiteral("name")).toString(), QStringLiteral("Alex"));

        QVERIFY(addNamed(store, QStringLiteral("   "), int(ProfileStore::Maturity::Kids)).isEmpty());
        store.updateProfile(id, QStringLiteral(" "), QStringLiteral("cat.fill"),
                            QStringLiteral("#FFB347"), int(ProfileStore::Maturity::Kids));
        QCOMPARE(store.profileById(id).value(QStringLiteral("name")).toString(), QStringLiteral("Alex"));
    }

    // UserProfile.swift:121-127: the ends do not move outward, and a move
    // swaps with the neighbour. The last-profile guard is the picker's
    // (MarqueeTheme.swift:24-34), not the store's.
    void movingIsBoundedToTheList()
    {
        QTemporaryDir dir;
        ProfileStore store(storagePath(dir));
        const QString main = store.profiles().at(0).id;
        const QString kids = store.profiles().at(1).id;

        store.moveProfile(main, -1);
        QCOMPARE(store.profiles().at(0).id, main);
        store.moveProfile(kids, 1);
        QCOMPARE(store.profiles().at(1).id, kids);

        store.moveProfile(kids, -1);
        QCOMPARE(store.profiles().at(0).id, kids);
        QCOMPARE(store.profiles().at(1).id, main);
    }

    // UserProfile.swift:137-140 and :129-135: the remembered selection
    // follows the profiles, and moves to the first one left when its profile
    // is deleted.
    void theSelectionFollowsDeletion()
    {
        QTemporaryDir dir;
        ProfileStore store(storagePath(dir));
        const QString main = store.profiles().at(0).id;
        const QString kids = store.profiles().at(1).id;

        store.selectProfile(kids);
        QCOMPARE(store.selectedProfileId(), kids);
        QCOMPARE(store.selectedProfile()->id, kids);

        store.deleteProfile(kids);
        QCOMPARE(store.selectedProfile()->id, main);
    }

    // ProfileStore.swift persists to JSON and loads back in order with every
    // field, selection included.
    void profilesRoundTripThroughTheirFile()
    {
        QTemporaryDir dir;
        QString kiddo;
        {
            ProfileStore store(storagePath(dir));
            kiddo = store.addProfile(QStringLiteral("Kiddo"), QStringLiteral("hare.fill"),
                                     QStringLiteral("#FF9F0A"), int(ProfileStore::Maturity::Family));
            store.moveProfile(kiddo, -1);
            store.moveProfile(kiddo, -1);
            store.selectProfile(kiddo);
        }
        ProfileStore reloaded(storagePath(dir));
        QCOMPARE(reloaded.count(), 3);
        const Profile first = reloaded.profiles().at(0);
        QCOMPARE(first.id, kiddo);
        QCOMPARE(first.name, QStringLiteral("Kiddo"));
        QCOMPARE(first.avatarIcon, QStringLiteral("hare.fill"));
        QCOMPARE(QColor(first.avatarColor), QColor(QStringLiteral("#FF9F0A")));
        QCOMPARE(first.maturityLevel, int(ProfileStore::Maturity::Family));
        QCOMPARE(reloaded.profiles().at(1).name, QStringLiteral("Main"));
        QCOMPARE(reloaded.selectedProfileId(), kiddo);
    }

    // A profiles file that exists but cannot be opened holds the viewer's real
    // profiles. Replacing it with defaults would lose them, so the store keeps
    // the bytes and reports why.
    void aProfilesFileThatCannotBeReadIsKeptAndReported()
    {
        QTemporaryDir dir;
        const QByteArray original =
            R"({"profiles":[{"id":"real","name":"Real","avatar":{"icon":"star.fill","colorHex":"#FFD700"}}]})";
        QFile file(storagePath(dir));
        QVERIFY(file.open(QIODevice::WriteOnly));
        QCOMPARE(file.write(original), original.size());
        file.close();
        QVERIFY(QFile::setPermissions(storagePath(dir), QFileDevice::WriteOwner));
        const auto restore = qScopeGuard([&dir] {
            QFile::setPermissions(storagePath(dir),
                                  QFileDevice::ReadOwner | QFileDevice::WriteOwner);
        });
        if (QFile(storagePath(dir)).open(QIODevice::ReadOnly)) {
            QSKIP("This account reads files regardless of their mode");
        }

        {
            ProfileStore store(storagePath(dir));
            QVERIFY(!store.storageError().isEmpty());

            // Later edits must not write through to the file either.
            QVERIFY(!addNamed(store, QStringLiteral("Extra"),
                              int(ProfileStore::Maturity::Adult)).isEmpty());
            QVERIFY(!store.storageError().isEmpty());
        }

        QVERIFY(QFile::setPermissions(storagePath(dir), QFileDevice::ReadOwner));
        QFile unchanged(storagePath(dir));
        QVERIFY(unchanged.open(QIODevice::ReadOnly));
        QCOMPARE(unchanged.readAll(), original);
    }

    // MaturityLevel.swift:15-31.
    void maturityLabelsMatchTheReleasedCopy()
    {
        QCOMPARE(ProfileStore::maturityLabel(0), QStringLiteral("Kids"));
        QCOMPARE(ProfileStore::maturityLabel(1), QStringLiteral("Family"));
        QCOMPARE(ProfileStore::maturityLabel(2), QStringLiteral("Teen"));
        QCOMPARE(ProfileStore::maturityLabel(3), QStringLiteral("Adult"));
        QCOMPARE(ProfileStore::maturityExamples(0), QStringLiteral("G, PG, TV-Y"));
        QCOMPARE(ProfileStore::maturityExamples(1), QStringLiteral("G, PG"));
        QCOMPARE(ProfileStore::maturityExamples(2), QStringLiteral("PG-13, TV-14"));
        QCOMPARE(ProfileStore::maturityExamples(3), QStringLiteral("R, TV-MA"));
    }

    // UserProfile.swift:17-48: thirty catalog avatars, hare first.
    void theAvatarCatalogIsTheReleasedThirty()
    {
        QTemporaryDir dir;
        ProfileStore store(storagePath(dir));
        const QVariantList catalog = store.avatarCatalog();
        QCOMPARE(catalog.size(), 30);
        const QVariantMap first = catalog.first().toMap();
        QCOMPARE(first.value(QStringLiteral("icon")).toString(), QStringLiteral("hare.fill"));
        QCOMPARE(first.value(QStringLiteral("color")).value<QColor>(), QColor(QStringLiteral("#FF6B6B")));
        QCOMPARE(catalog.last().toMap().value(QStringLiteral("icon")).toString(),
                 QStringLiteral("face.smiling"));
    }
};

QTEST_MAIN(ProfileStoreTest)
#include "tst_profile_store.moc"
