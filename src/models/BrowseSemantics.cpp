#include "models/BrowseSemantics.hpp"

#include <QChar>
#include <QLatin1Char>
#include <QLatin1String>
#include <QStringList>

namespace browse
{
// BrowseSnapshotStore.swift:1784-1802 folds diacritics and width, lowercases,
// and reduces every run of non-alphanumerics to one space.
QString normalizedText(const QString &value)
{
    // Compatibility decomposition separates the combining marks the diacritic
    // fold drops and maps the full-width forms the width fold maps.
    const QString decomposed = value.normalized(QString::NormalizationForm_KD).toLower();

    QString normalized;
    normalized.reserve(decomposed.size());
    bool lastWasSpace = true;
    for (const QChar character : decomposed) {
        if (character.isMark()) {
            continue;
        }
        if (character.isLetterOrNumber()) {
            normalized.append(character);
            lastWasSpace = false;
        } else if (!lastWasSpace) {
            normalized.append(QLatin1Char(' '));
            lastWasSpace = true;
        }
    }

    return normalized.trimmed();
}

// BrowseSnapshotStore.swift:1824-1862: the compact franchise rules first, then
// a leading token long enough to stand on its own, then the first two
// meaningful tokens. An empty key means the title has no family of its own.
QString franchiseKey(const QString &title)
{
    const QStringList titleTokens =
        normalizedText(title).split(QLatin1Char(' '), Qt::SkipEmptyParts);
    if (titleTokens.isEmpty()) {
        return {};
    }

    struct CompactRule
    {
        QLatin1String needle;
        QLatin1String key;
    };
    static const CompactRule compactRules[]{
        {QLatin1String("kingsman"), QLatin1String("kingsman")},
        {QLatin1String("harrypotter"), QLatin1String("harry potter")},
        {QLatin1String("starwars"), QLatin1String("star wars")},
        {QLatin1String("missionimpossible"), QLatin1String("mission impossible")},
        {QLatin1String("fastfurious"), QLatin1String("fast furious")},
        {QLatin1String("jurassicpark"), QLatin1String("jurassic")},
        {QLatin1String("jurassicworld"), QLatin1String("jurassic")},
        {QLatin1String("lordoftherings"), QLatin1String("middle earth")},
        {QLatin1String("thehobbit"), QLatin1String("middle earth")},
        {QLatin1String("spiderman"), QLatin1String("spider man")},
        {QLatin1String("spiderverse"), QLatin1String("spider man")},
        {QLatin1String("darkknight"), QLatin1String("batman")},
        {QLatin1String("batman"), QLatin1String("batman")},
        {QLatin1String("xmen"), QLatin1String("x men")},
        {QLatin1String("avengers"), QLatin1String("avengers")},
        {QLatin1String("guardiansofthegalaxy"), QLatin1String("guardians of the galaxy")}};

    const QString compact = titleTokens.join(QString());
    for (const CompactRule &rule : compactRules) {
        if (compact.contains(rule.needle)) {
            return QString(rule.key);
        }
    }

    QStringList meaningful;
    meaningful.reserve(titleTokens.size());
    for (const QString &token : titleTokens) {
        if (token != QLatin1String("a") && token != QLatin1String("an")
            && token != QLatin1String("the")) {
            meaningful.push_back(token);
        }
    }
    if (meaningful.isEmpty()) {
        return {};
    }
    if (meaningful.constFirst().size() >= 5) {
        return meaningful.constFirst();
    }
    if (meaningful.size() >= 2) {
        return meaningful.constFirst() + QLatin1Char(' ') + meaningful.at(1);
    }
    return {};
}

}
