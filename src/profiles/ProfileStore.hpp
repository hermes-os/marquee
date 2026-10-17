#pragma once

#include <QAbstractListModel>
#include <QColor>
#include <QString>
#include <QVariantList>
#include <QVector>
#include <QtQml/qqmlregistration.h>

/// One viewer profile, as `Marquee/Models/UserProfile.swift:52-81` defines it:
/// a name, a catalog avatar (symbol plus colour), and a maturity level.
/// The released `characterAvatarName` names a rendered character image from an
/// online avatar service v3 does not have, so it is carried through storage
/// untouched and never shown.
struct Profile
{
    QString id;
    QString name;
    QString avatarIcon;
    QString avatarColor;
    QString characterAvatarName;
    int maturityLevel{3};
};

/// The profile catalog and its persistence, after
/// `Marquee/Models/UserProfile.swift:84-198`'s `ProfileStore`: an ordered list
/// of profiles with one remembered selection, stored as JSON in the
/// application data directory and seeded with the released "Main" and "Kids"
/// defaults when nothing is stored yet.
class ProfileStore final : public QAbstractListModel
{
    Q_OBJECT
    QML_ELEMENT
    QML_UNCREATABLE("ProfileStore is owned by ApplicationController")

    Q_PROPERTY(int count READ count NOTIFY countChanged)
    Q_PROPERTY(QString selectedProfileId READ selectedProfileId NOTIFY selectedProfileIdChanged)
    /// `ProfilePickerView.swift:527` admits a new profile only below five.
    Q_PROPERTY(bool canAddProfile READ canAddProfile NOTIFY countChanged)
    /// The thirty catalog avatars `UserProfile.swift:17-48` offers the editor,
    /// as `{ icon, color }` maps in catalog order.
    Q_PROPERTY(QVariantList avatarCatalog READ avatarCatalog CONSTANT)
    Q_PROPERTY(QString storageError READ storageError NOTIFY storageErrorChanged)

public:
    enum Role {
        ProfileIdRole = Qt::UserRole + 1,
        NameRole,
        AvatarIconRole,
        AvatarColorRole,
        MaturityLevelRole,
        MaturityLabelRole
    };
    Q_ENUM(Role)

    /// `Marquee/Models/MaturityLevel.swift:5-9`, ordered so a lower level
    /// admits less.
    enum class Maturity {
        Kids = 0,
        Family = 1,
        Teen = 2,
        Adult = 3
    };
    Q_ENUM(Maturity)

    /// Reads the stored profiles from `storagePath`, or seeds the released
    /// defaults when the file does not exist. An empty path keeps the store in
    /// memory only, which is what a test without a data directory needs.
    explicit ProfileStore(const QString &storagePath, QObject *parent = nullptr);

    [[nodiscard]] int rowCount(const QModelIndex &parent = QModelIndex()) const override;
    [[nodiscard]] QVariant data(const QModelIndex &index, int role) const override;
    [[nodiscard]] QHash<int, QByteArray> roleNames() const override;

    [[nodiscard]] int count() const;
    [[nodiscard]] QString selectedProfileId() const;
    [[nodiscard]] bool canAddProfile() const;
    [[nodiscard]] QVariantList avatarCatalog() const;
    [[nodiscard]] QString storageError() const;

    [[nodiscard]] const QVector<Profile> &profiles() const;
    [[nodiscard]] std::optional<Profile> profile(const QString &id) const;
    /// `UserProfile.swift:172-177`: the remembered selection when it still
    /// exists, otherwise the first profile.
    [[nodiscard]] std::optional<Profile> selectedProfile() const;

    /// `MaturityLevel.swift:15-22`.
    [[nodiscard]] static QString maturityLabel(int level);
    /// `MaturityLevel.swift:24-31`.
    [[nodiscard]] static QString maturityExamples(int level);

    Q_INVOKABLE QString maturityLabelFor(int level) const;
    Q_INVOKABLE QString maturityExamplesFor(int level) const;
    Q_INVOKABLE int indexOf(const QString &profileId) const;
    Q_INVOKABLE QVariantMap profileAt(int index) const;
    Q_INVOKABLE QVariantMap profileById(const QString &profileId) const;

    /// `UserProfile.swift:110-113`. Returns the new profile's identity.
    Q_INVOKABLE QString addProfile(const QString &name,
                                   const QString &avatarIcon,
                                   const QString &avatarColor,
                                   int maturityLevel);
    /// `UserProfile.swift:115-119`.
    Q_INVOKABLE void updateProfile(const QString &profileId,
                                   const QString &name,
                                   const QString &avatarIcon,
                                   const QString &avatarColor,
                                   int maturityLevel);
    /// `UserProfile.swift:121-127`: swaps the profile with its neighbour in
    /// `direction`, which is -1 or 1, and does nothing at either end.
    Q_INVOKABLE void moveProfile(const QString &profileId, int direction);
    /// `UserProfile.swift:129-135`: removes the profile, and moves the
    /// remembered selection to the first remaining profile when it was the one
    /// removed.
    Q_INVOKABLE void deleteProfile(const QString &profileId);
    /// `UserProfile.swift:137-140`.
    Q_INVOKABLE void selectProfile(const QString &profileId);

signals:
    void countChanged();
    void selectedProfileIdChanged();
    void storageErrorChanged();
    /// A profile's stored fields changed, or the list was reordered or
    /// resized. The active profile the shell shows is re-read on this.
    void profilesChanged();
    /// A profile was removed. Whatever else is kept per profile, such as watch
    /// progress, goes with it; emitted before `profilesChanged`.
    void profileDeleted(QString profileId);

private:
    void load();
    void save();
    void setStorageError(const QString &message);

    QString m_storagePath;
    QVector<Profile> m_profiles;
    QString m_selectedProfileId;
    QString m_storageError;
};
