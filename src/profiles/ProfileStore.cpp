#include "profiles/ProfileStore.hpp"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSaveFile>
#include <QUuid>

#include <algorithm>

#include "support/Logging.hpp"

namespace
{
struct CatalogAvatar
{
    const char *icon;
    const char *color;
};

// Marquee/Models/UserProfile.swift:17-48, in catalog order.
constexpr CatalogAvatar kAvatarCatalog[] = {
    {"hare.fill", "#FF6B6B"},
    {"tortoise.fill", "#4ECDC4"},
    {"cat.fill", "#FFB347"},
    {"dog.fill", "#87CEEB"},
    {"bird.fill", "#DDA0DD"},
    {"fish.fill", "#48D1CC"},
    {"ant.fill", "#F0E68C"},
    {"ladybug.fill", "#FF6347"},
    {"leaf.fill", "#90EE90"},
    {"flame.fill", "#FF4500"},
    {"bolt.fill", "#FFD700"},
    {"moon.fill", "#B0C4DE"},
    {"sun.max.fill", "#FFA500"},
    {"cloud.fill", "#87CEFA"},
    {"snowflake", "#ADD8E6"},
    {"star.fill", "#FFD700"},
    {"heart.fill", "#FF69B4"},
    {"crown.fill", "#DAA520"},
    {"theatermasks.fill", "#9E86FF"},
    {"gamecontroller.fill", "#00CED1"},
    {"headphones", "#FF8C00"},
    {"music.note", "#DA70D6"},
    {"paintbrush.fill", "#FF1493"},
    {"eye.fill", "#20B2AA"},
    {"camera.fill", "#778899"},
    {"airplane", "#6495ED"},
    {"globe.americas.fill", "#3CB371"},
    {"mountain.2.fill", "#708090"},
    {"trophy.fill", "#FFD700"},
    {"face.smiling", "#FFD93D"},
};

constexpr int kMaximumProfiles = 5;

[[nodiscard]] int clampedMaturity(int level)
{
    return std::clamp(level,
                      static_cast<int>(ProfileStore::Maturity::Kids),
                      static_cast<int>(ProfileStore::Maturity::Adult));
}

[[nodiscard]] QString newProfileId()
{
    return QUuid::createUuid().toString(QUuid::WithoutBraces).toUpper();
}

[[nodiscard]] QJsonObject toJson(const Profile &profile)
{
    // The released file's shape (UserProfile.swift:52-58 with the nested
    // avatar of :5-8), so a catalog exported from the macOS application reads
    // back unchanged.
    QJsonObject avatar;
    avatar.insert(QStringLiteral("icon"), profile.avatarIcon);
    avatar.insert(QStringLiteral("colorHex"), profile.avatarColor.mid(1));

    QJsonObject object;
    object.insert(QStringLiteral("id"), profile.id);
    object.insert(QStringLiteral("name"), profile.name);
    object.insert(QStringLiteral("avatar"), avatar);
    object.insert(QStringLiteral("maturityLevel"), profile.maturityLevel);
    if (!profile.characterAvatarName.isEmpty()) {
        object.insert(QStringLiteral("characterAvatarName"), profile.characterAvatarName);
    }
    return object;
}

[[nodiscard]] std::optional<Profile> fromJson(const QJsonValue &value)
{
    if (!value.isObject()) {
        return std::nullopt;
    }
    const QJsonObject object = value.toObject();
    Profile profile;
    profile.id = object.value(QStringLiteral("id")).toString().trimmed();
    profile.name = object.value(QStringLiteral("name")).toString();
    const QJsonObject avatar = object.value(QStringLiteral("avatar")).toObject();
    profile.avatarIcon = avatar.value(QStringLiteral("icon")).toString();
    const QString colorHex = avatar.value(QStringLiteral("colorHex")).toString().trimmed();
    profile.avatarColor = colorHex.startsWith(QLatin1Char('#'))
        ? colorHex.toUpper()
        : QLatin1Char('#') + colorHex.toUpper();
    profile.characterAvatarName =
        object.value(QStringLiteral("characterAvatarName")).toString();
    profile.maturityLevel = clampedMaturity(
        object.value(QStringLiteral("maturityLevel")).toInt(
            static_cast<int>(ProfileStore::Maturity::Adult)));
    if (profile.id.isEmpty() || profile.name.isEmpty() || profile.avatarIcon.isEmpty()
        || !QColor::isValidColorName(profile.avatarColor)) {
        return std::nullopt;
    }
    return profile;
}

// UserProfile.swift:104-107.
[[nodiscard]] QVector<Profile> defaultProfiles()
{
    Profile main;
    main.id = newProfileId();
    main.name = QStringLiteral("Main");
    main.avatarIcon = QStringLiteral("theatermasks.fill");
    main.avatarColor = QStringLiteral("#9E86FF");
    main.maturityLevel = static_cast<int>(ProfileStore::Maturity::Adult);

    Profile kids;
    kids.id = newProfileId();
    kids.name = QStringLiteral("Kids");
    kids.avatarIcon = QStringLiteral("hare.fill");
    kids.avatarColor = QStringLiteral("#FF6B6B");
    kids.maturityLevel = static_cast<int>(ProfileStore::Maturity::Kids);

    return {main, kids};
}

[[nodiscard]] QVariantMap toVariant(const Profile &profile)
{
    QVariantMap map;
    map.insert(QStringLiteral("profileId"), profile.id);
    map.insert(QStringLiteral("name"), profile.name);
    map.insert(QStringLiteral("avatarIcon"), profile.avatarIcon);
    map.insert(QStringLiteral("avatarColor"), QColor(profile.avatarColor));
    map.insert(QStringLiteral("maturityLevel"), profile.maturityLevel);
    map.insert(QStringLiteral("maturityLabel"),
               ProfileStore::maturityLabel(profile.maturityLevel));
    return map;
}
}

ProfileStore::ProfileStore(const QString &storagePath, QObject *parent)
    : QAbstractListModel(parent),
      m_storagePath(storagePath)
{
    load();
    if (m_profiles.isEmpty()) {
        m_profiles = defaultProfiles();
        save();
    }
}

int ProfileStore::rowCount(const QModelIndex &parent) const
{
    return parent.isValid() ? 0 : static_cast<int>(m_profiles.size());
}

QVariant ProfileStore::data(const QModelIndex &index, int role) const
{
    if (!index.isValid() || index.row() < 0 || index.row() >= m_profiles.size()) {
        return {};
    }
    const Profile &profile = m_profiles.at(index.row());
    switch (role) {
    case ProfileIdRole:
        return profile.id;
    case NameRole:
        return profile.name;
    case AvatarIconRole:
        return profile.avatarIcon;
    case AvatarColorRole:
        return QColor(profile.avatarColor);
    case MaturityLevelRole:
        return profile.maturityLevel;
    case MaturityLabelRole:
        return maturityLabel(profile.maturityLevel);
    default:
        return {};
    }
}

QHash<int, QByteArray> ProfileStore::roleNames() const
{
    return {
        {ProfileIdRole, "profileId"},
        {NameRole, "name"},
        {AvatarIconRole, "avatarIcon"},
        {AvatarColorRole, "avatarColor"},
        {MaturityLevelRole, "maturityLevel"},
        {MaturityLabelRole, "maturityLabel"},
    };
}

int ProfileStore::count() const
{
    return static_cast<int>(m_profiles.size());
}

QString ProfileStore::selectedProfileId() const
{
    return m_selectedProfileId;
}

bool ProfileStore::canAddProfile() const
{
    return m_profiles.size() < kMaximumProfiles;
}

QVariantList ProfileStore::avatarCatalog() const
{
    QVariantList catalog;
    for (const CatalogAvatar &avatar : kAvatarCatalog) {
        QVariantMap entry;
        entry.insert(QStringLiteral("icon"), QString::fromLatin1(avatar.icon));
        entry.insert(QStringLiteral("color"), QColor(QString::fromLatin1(avatar.color)));
        catalog.push_back(entry);
    }
    return catalog;
}

QString ProfileStore::storageError() const
{
    return m_storageError;
}

const QVector<Profile> &ProfileStore::profiles() const
{
    return m_profiles;
}

std::optional<Profile> ProfileStore::profile(const QString &id) const
{
    const auto it = std::find_if(m_profiles.cbegin(), m_profiles.cend(),
                                 [&id](const Profile &entry) { return entry.id == id; });
    if (it == m_profiles.cend()) {
        return std::nullopt;
    }
    return *it;
}

std::optional<Profile> ProfileStore::selectedProfile() const
{
    if (auto remembered = profile(m_selectedProfileId)) {
        return remembered;
    }
    if (m_profiles.isEmpty()) {
        return std::nullopt;
    }
    return m_profiles.first();
}

QString ProfileStore::maturityLabel(int level)
{
    switch (static_cast<Maturity>(clampedMaturity(level))) {
    case Maturity::Kids:
        return QStringLiteral("Kids");
    case Maturity::Family:
        return QStringLiteral("Family");
    case Maturity::Teen:
        return QStringLiteral("Teen");
    case Maturity::Adult:
        return QStringLiteral("Adult");
    }
    return {};
}

QString ProfileStore::maturityExamples(int level)
{
    switch (static_cast<Maturity>(clampedMaturity(level))) {
    case Maturity::Kids:
        return QStringLiteral("G, PG, TV-Y");
    case Maturity::Family:
        return QStringLiteral("G, PG");
    case Maturity::Teen:
        return QStringLiteral("PG-13, TV-14");
    case Maturity::Adult:
        return QStringLiteral("R, TV-MA");
    }
    return {};
}

QString ProfileStore::maturityLabelFor(int level) const
{
    return maturityLabel(level);
}

QString ProfileStore::maturityExamplesFor(int level) const
{
    return maturityExamples(level);
}

int ProfileStore::indexOf(const QString &profileId) const
{
    for (int index = 0; index < m_profiles.size(); ++index) {
        if (m_profiles.at(index).id == profileId) {
            return index;
        }
    }
    return -1;
}

QVariantMap ProfileStore::profileAt(int index) const
{
    if (index < 0 || index >= m_profiles.size()) {
        return {};
    }
    return toVariant(m_profiles.at(index));
}

QVariantMap ProfileStore::profileById(const QString &profileId) const
{
    const auto found = profile(profileId);
    return found ? toVariant(*found) : QVariantMap{};
}

QString ProfileStore::addProfile(const QString &name,
                                 const QString &avatarIcon,
                                 const QString &avatarColor,
                                 int maturityLevel)
{
    const QString trimmed = name.trimmed();
    if (trimmed.isEmpty() || !canAddProfile()) {
        return {};
    }
    Profile profile;
    profile.id = newProfileId();
    profile.name = trimmed;
    profile.avatarIcon = avatarIcon;
    profile.avatarColor = QColor(avatarColor).name(QColor::HexRgb).toUpper();
    profile.maturityLevel = clampedMaturity(maturityLevel);

    const int row = static_cast<int>(m_profiles.size());
    beginInsertRows(QModelIndex(), row, row);
    m_profiles.push_back(profile);
    endInsertRows();
    save();
    emit countChanged();
    emit profilesChanged();
    return profile.id;
}

void ProfileStore::updateProfile(const QString &profileId,
                                 const QString &name,
                                 const QString &avatarIcon,
                                 const QString &avatarColor,
                                 int maturityLevel)
{
    const int row = indexOf(profileId);
    const QString trimmed = name.trimmed();
    if (row < 0 || trimmed.isEmpty()) {
        return;
    }
    Profile &profile = m_profiles[row];
    profile.name = trimmed;
    profile.avatarIcon = avatarIcon;
    profile.avatarColor = QColor(avatarColor).name(QColor::HexRgb).toUpper();
    profile.maturityLevel = clampedMaturity(maturityLevel);
    // ProfileEditorView.swift:1540 clears the character image whenever the
    // catalog avatar is chosen; v3 offers only catalog avatars.
    profile.characterAvatarName.clear();
    const QModelIndex changed = index(row);
    emit dataChanged(changed, changed);
    save();
    emit profilesChanged();
}

void ProfileStore::moveProfile(const QString &profileId, int direction)
{
    const int row = indexOf(profileId);
    const int target = row + direction;
    if (row < 0 || (direction != -1 && direction != 1)
        || target < 0 || target >= m_profiles.size()) {
        return;
    }
    // beginMoveRows takes the destination as the row the moved item lands
    // before, so a move down by one names the row two past the source.
    const int destination = direction > 0 ? target + 1 : target;
    if (!beginMoveRows(QModelIndex(), row, row, QModelIndex(), destination)) {
        return;
    }
    std::swap(m_profiles[row], m_profiles[target]);
    endMoveRows();
    save();
    emit profilesChanged();
}

void ProfileStore::deleteProfile(const QString &profileId)
{
    const int row = indexOf(profileId);
    if (row < 0) {
        return;
    }
    beginRemoveRows(QModelIndex(), row, row);
    m_profiles.removeAt(row);
    endRemoveRows();
    if (m_selectedProfileId == profileId) {
        m_selectedProfileId = m_profiles.isEmpty() ? QString() : m_profiles.first().id;
        emit selectedProfileIdChanged();
    }
    save();
    emit countChanged();
    emit profileDeleted(profileId);
    emit profilesChanged();
}

void ProfileStore::selectProfile(const QString &profileId)
{
    if (indexOf(profileId) < 0 || m_selectedProfileId == profileId) {
        return;
    }
    m_selectedProfileId = profileId;
    save();
    emit selectedProfileIdChanged();
}

void ProfileStore::load()
{
    if (m_storagePath.isEmpty()) {
        return;
    }
    QFile file(m_storagePath);
    if (!file.exists()) {
        return;
    }
    if (!file.open(QIODevice::ReadOnly)) {
        // The file is there, so it may hold the viewer's real profiles. Seeding
        // defaults would save over it and clear this error; stop writing instead.
        setStorageError(QStringLiteral("Unable to read profiles: %1").arg(file.errorString()));
        m_storagePath.clear();
        return;
    }
    QJsonParseError parseError{};
    const QJsonDocument document = QJsonDocument::fromJson(file.readAll(), &parseError);
    if (parseError.error != QJsonParseError::NoError || !document.isObject()) {
        // A corrupt file must not be silently replaced by the defaults and
        // then overwritten: the viewer keeps the file and sees the error.
        setStorageError(QStringLiteral("Profiles file is not readable: %1")
                            .arg(parseError.errorString()));
        m_storagePath.clear();
        return;
    }
    const QJsonObject root = document.object();
    QVector<Profile> loaded;
    for (const QJsonValue &value : root.value(QStringLiteral("profiles")).toArray()) {
        if (auto profile = fromJson(value)) {
            loaded.push_back(*profile);
        }
    }
    m_profiles = loaded;
    const QString selected =
        root.value(QStringLiteral("lastSelectedProfileID")).toString().trimmed();
    m_selectedProfileId = indexOf(selected) >= 0 ? selected : QString();
}

void ProfileStore::save()
{
    if (m_storagePath.isEmpty()) {
        return;
    }
    QJsonArray profiles;
    for (const Profile &profile : m_profiles) {
        profiles.push_back(toJson(profile));
    }
    QJsonObject root;
    root.insert(QStringLiteral("profiles"), profiles);
    if (!m_selectedProfileId.isEmpty()) {
        root.insert(QStringLiteral("lastSelectedProfileID"), m_selectedProfileId);
    } else {
        root.insert(QStringLiteral("lastSelectedProfileID"), QJsonValue::Null);
    }

    QSaveFile file(m_storagePath);
    // The application data directory is created by the shell's own path
    // ownership, but the first save can run before that when the store seeds
    // its defaults, and QSettings creates its own directory the same way.
    QFileInfo(m_storagePath).dir().mkpath(QStringLiteral("."));
    if (!file.open(QIODevice::WriteOnly)) {
        setStorageError(QStringLiteral("Unable to write profiles: %1").arg(file.errorString()));
        return;
    }
    file.write(QJsonDocument(root).toJson(QJsonDocument::Indented));
    if (!file.commit()) {
        setStorageError(QStringLiteral("Unable to write profiles: %1").arg(file.errorString()));
        return;
    }
    setStorageError(QString());
}

void ProfileStore::setStorageError(const QString &message)
{
    if (m_storageError == message) {
        return;
    }
    m_storageError = message;
    if (!message.isEmpty()) {
        qCWarning(logApp) << message;
    }
    emit storageErrorChanged();
}
