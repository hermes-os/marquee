#include "search/SearchSession.hpp"

#include "models/BrowseSemantics.hpp"
#include "models/LibraryModel.hpp"

#include <QChar>
#include <QCollator>
#include <QFileInfo>
#include <QSet>
#include <QUrl>

#include <algorithm>
#include <cstdlib>

namespace
{
// `BrowseSemanticPolicy.franchiseKey(for:)`, `BrowseSnapshotStore.swift:1824-1862`.
[[nodiscard]] QString franchiseKeyOf(const QStringList &titleTokens)
{
    if (titleTokens.isEmpty()) {
        return {};
    }
    const QString compact = titleTokens.join(QString());
    static const QVector<QPair<QString, QString>> compactRules = {
        {QStringLiteral("kingsman"), QStringLiteral("kingsman")},
        {QStringLiteral("harrypotter"), QStringLiteral("harry potter")},
        {QStringLiteral("starwars"), QStringLiteral("star wars")},
        {QStringLiteral("missionimpossible"), QStringLiteral("mission impossible")},
        {QStringLiteral("fastfurious"), QStringLiteral("fast furious")},
        {QStringLiteral("jurassicpark"), QStringLiteral("jurassic")},
        {QStringLiteral("jurassicworld"), QStringLiteral("jurassic")},
        {QStringLiteral("lordoftherings"), QStringLiteral("middle earth")},
        {QStringLiteral("thehobbit"), QStringLiteral("middle earth")},
        {QStringLiteral("spiderman"), QStringLiteral("spider man")},
        {QStringLiteral("spiderverse"), QStringLiteral("spider man")},
        {QStringLiteral("darkknight"), QStringLiteral("batman")},
        {QStringLiteral("batman"), QStringLiteral("batman")},
        {QStringLiteral("xmen"), QStringLiteral("x men")},
        {QStringLiteral("avengers"), QStringLiteral("avengers")},
        {QStringLiteral("guardiansofthegalaxy"), QStringLiteral("guardians of the galaxy")},
    };
    for (const auto &rule : compactRules) {
        if (compact.contains(rule.first)) {
            return rule.second;
        }
    }
    QStringList meaningful;
    for (const QString &token : titleTokens) {
        if (token != QLatin1String("a") && token != QLatin1String("an")
            && token != QLatin1String("the")) {
            meaningful.push_back(token);
        }
    }
    if (meaningful.isEmpty()) {
        return {};
    }
    if (meaningful.first().size() >= 5) {
        return meaningful.first();
    }
    if (meaningful.size() >= 2) {
        return meaningful.mid(0, 2).join(QLatin1Char(' '));
    }
    return {};
}

// `BrowseSemanticPolicy.isEditDistanceOne`, `BrowseSnapshotStore.swift:1980-2012`.
[[nodiscard]] bool isEditDistanceOne(const QString &lhs, const QString &rhs)
{
    if (lhs == rhs) {
        return false;
    }
    if (std::min(lhs.size(), rhs.size()) < 4) {
        return false;
    }
    const auto countDelta = std::abs(lhs.size() - rhs.size());
    if (countDelta > 1) {
        return false;
    }
    if (lhs.size() == rhs.size()) {
        int mismatches = 0;
        for (qsizetype i = 0; i < lhs.size(); ++i) {
            if (lhs[i] != rhs[i]) {
                ++mismatches;
            }
        }
        return mismatches == 1;
    }
    const QString &shorter = lhs.size() < rhs.size() ? lhs : rhs;
    const QString &longer = lhs.size() < rhs.size() ? rhs : lhs;
    qsizetype shortIndex = 0;
    qsizetype longIndex = 0;
    int edits = 0;
    while (shortIndex < shorter.size() && longIndex < longer.size()) {
        if (shorter[shortIndex] == longer[longIndex]) {
            ++shortIndex;
            ++longIndex;
        } else {
            ++edits;
            if (edits > 1) {
                return false;
            }
            ++longIndex;
        }
    }
    return true;
}

// `BrowseSemanticPolicy.tokenMatches`, `BrowseSnapshotStore.swift:1968-1979`.
[[nodiscard]] bool tokenMatches(const QString &queryToken,
                                const QString &token,
                                bool prefixRequired,
                                bool allowEditDistanceOne)
{
    if (prefixRequired ? token.startsWith(queryToken) : token.contains(queryToken)) {
        return true;
    }
    return allowEditDistanceOne && isEditDistanceOne(queryToken, token);
}

// `BrowseSemanticPolicy.containsQueryTokensInOrder`, `BrowseSnapshotStore.swift:1940-1967`.
[[nodiscard]] bool containsQueryTokensInOrder(const QStringList &queryTokens,
                                              const QStringList &tokens,
                                              bool prefixRequired,
                                              bool allowEditDistanceOne = false)
{
    if (queryTokens.isEmpty()) {
        return false;
    }
    qsizetype tokenIndex = 0;
    for (const QString &queryToken : queryTokens) {
        bool found = false;
        while (tokenIndex < tokens.size()) {
            const QString &candidate = tokens[tokenIndex];
            ++tokenIndex;
            if (tokenMatches(queryToken, candidate, prefixRequired, allowEditDistanceOne)) {
                found = true;
                break;
            }
        }
        if (!found) {
            return false;
        }
    }
    return true;
}

// `BrowseSemanticPolicy.searchScore`, `BrowseSnapshotStore.swift:1864-1937`,
// returning zero where the released function returns nil.
[[nodiscard]] int searchScore(const QString &query,
                              const QStringList &queryTokens,
                              const QString &normalizedText,
                              const QStringList &tokens,
                              const QString &franchiseKey,
                              int baseScore,
                              bool allowsSubstring,
                              bool allowsEditDistanceOne)
{
    if (query.isEmpty()) {
        return 0;
    }
    const QString compactQuery = queryTokens.join(QString());
    if (normalizedText == query) {
        return baseScore + 120;
    }
    if (tokens.join(QString()) == compactQuery) {
        return baseScore + 120;
    }
    if (!franchiseKey.isEmpty()) {
        const QString compactFranchise =
            SearchSession::normalizedText(franchiseKey).split(QLatin1Char(' '), Qt::SkipEmptyParts)
                .join(QString());
        if (compactFranchise == compactQuery) {
            return baseScore + 105;
        }
        if (compactFranchise.startsWith(compactQuery) || compactFranchise.contains(compactQuery)) {
            return baseScore + 92;
        }
    }
    if (queryTokens.size() > 1 && containsQueryTokensInOrder(queryTokens, tokens, true)) {
        return baseScore + 88;
    }
    for (const QString &token : tokens) {
        if (token.startsWith(query)) {
            return baseScore + 72;
        }
    }
    if (allowsEditDistanceOne && queryTokens.size() > 1
        && containsQueryTokensInOrder(queryTokens, tokens, true, true)) {
        return baseScore + 44;
    }
    if (allowsEditDistanceOne && queryTokens.size() == 1 && query.size() >= 4) {
        for (const QString &token : tokens) {
            if (isEditDistanceOne(query, token)) {
                return baseScore + 36;
            }
        }
    }
    if (allowsSubstring) {
        if (normalizedText.startsWith(query)
            || normalizedText.contains(QLatin1Char(' ') + query)) {
            return baseScore + 58;
        }
        if (query.size() >= 2 && normalizedText.contains(query)) {
            return baseScore + 24;
        }
        if (queryTokens.size() > 1 && containsQueryTokensInOrder(queryTokens, tokens, false)) {
            return baseScore + 18;
        }
    }
    return 0;
}

// `SearchView.swift:1328-1336` joins the year and the runtime with a middle
// dot; `MediaItem.swift:143-151` derives the runtime.
[[nodiscard]] QString subtitleOf(const MediaItem &item)
{
    QStringList parts;
    if (item.year > 0) {
        parts.push_back(QString::number(item.year));
    }
    if (const QString runtime = item.displayRuntime(); !runtime.isEmpty()) {
        parts.push_back(runtime);
    }
    return parts.join(QStringLiteral(" \u00B7 "));
}

// `localizedCaseInsensitiveCompare`, which the released sorts use: locale
// collation, so a superscript digit sorts as a digit rather than by code point.
[[nodiscard]] const QCollator &localizedCollator()
{
    static const QCollator collator = [] {
        QCollator instance;
        instance.setCaseSensitivity(Qt::CaseInsensitive);
        return instance;
    }();
    return collator;
}
}

SearchSession::SearchSession(LibraryModel *library, QObject *parent)
    : QAbstractListModel(parent)
    , m_library(library)
{
    rebuildSuggestionValues();
    const auto refresh = [this] {
        rebuildSuggestionValues();
        evaluate();
    };
    connect(m_library, &QAbstractItemModel::modelReset, this, refresh);
    connect(m_library, &QAbstractItemModel::rowsInserted, this, refresh);
    connect(m_library, &QAbstractItemModel::rowsRemoved, this, refresh);
    connect(m_library, &QAbstractItemModel::dataChanged, this, refresh);
}

int SearchSession::rowCount(const QModelIndex &parent) const
{
    return parent.isValid() ? 0 : static_cast<int>(m_hits.size());
}

QVariant SearchSession::data(const QModelIndex &index, int role) const
{
    if (!index.isValid() || index.row() < 0 || index.row() >= m_hits.size()) {
        return {};
    }
    const Hit &hit = m_hits[index.row()];
    switch (role) {
    case MediaIdRole:
        return hit.item.id;
    case TitleRole:
        return hit.item.title;
    case PosterUrlRole:
        return hit.item.posterAbsolutePath.isEmpty()
            ? QUrl()
            : QUrl::fromLocalFile(hit.item.posterAbsolutePath);
    case SubtitleRole:
        return subtitleOf(hit.item);
    case MatchTypeRole:
        return static_cast<int>(hit.matchType);
    case MatchDetailRole:
        return hit.matchDetail;
    case FormatBadgeRole:
        return QFileInfo(hit.item.relativePath).suffix().toUpper();
    default:
        return {};
    }
}

QHash<int, QByteArray> SearchSession::roleNames() const
{
    return {{MediaIdRole, "mediaId"},
            {TitleRole, "title"},
            {PosterUrlRole, "posterUrl"},
            {SubtitleRole, "subtitle"},
            {MatchTypeRole, "matchType"},
            {MatchDetailRole, "matchDetail"},
            {FormatBadgeRole, "formatBadge"}};
}

QString SearchSession::query() const
{
    return m_query;
}

void SearchSession::setQuery(const QString &query)
{
    if (m_query == query) {
        return;
    }
    m_query = query;
    emit queryChanged();
    evaluate();
}

QString SearchSession::trimmedQuery() const
{
    return m_query.trimmed();
}

QStringList SearchSession::suggestions() const
{
    return m_suggestions;
}

int SearchSession::totalCount() const
{
    return static_cast<int>(m_hits.size());
}

quint64 SearchSession::generation() const
{
    return m_generation;
}

QString SearchSession::mediaIdAt(int row) const
{
    if (row < 0 || row >= m_hits.size()) {
        return {};
    }
    return m_hits[row].item.id;
}

QString SearchSession::normalizedText(const QString &value)
{
    QString normalized;
    normalized.reserve(value.size());
    bool lastWasSpace = true;
    for (const QChar character : value.normalized(QString::NormalizationForm_D).toLower()) {
        if (character.category() == QChar::Mark_NonSpacing) {
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

void SearchSession::rebuildSuggestionValues()
{
    // `BrowseSnapshotStore.swift:1681-1692` keeps the first display value per
    // normalised key; `:1770-1772` sorts them case-insensitively. Genres,
    // directors, cast, collections, and keywords join the list once the
    // catalog carries them.
    QSet<QString> seen;
    m_suggestionValues.clear();
    for (int row = 0; row < m_library->rowCount(); ++row) {
        const QString title = m_library->data(m_library->index(row), LibraryModel::TitleRole)
                                  .toString().trimmed();
        const QString key = normalizedText(title);
        if (key.isEmpty() || seen.contains(key)) {
            continue;
        }
        seen.insert(key);
        m_suggestionValues.push_back({title, key});
    }
    std::sort(m_suggestionValues.begin(), m_suggestionValues.end(),
              [](const QPair<QString, QString> &lhs, const QPair<QString, QString> &rhs) {
                  return localizedCollator().compare(lhs.first, rhs.first) < 0;
              });
}

QVector<SearchSession::Hit> SearchSession::searchPass(const QString &query,
                                                      const QStringList &queryTokens,
                                                      bool titleOnly,
                                                      bool allowsEditDistanceOne) const
{
    QVector<Hit> hits;
    for (int row = 0; row < m_library->rowCount(); ++row) {
        const QString mediaId =
            m_library->data(m_library->index(row), LibraryModel::IdRole).toString();
        const auto item = m_library->itemForId(mediaId);
        if (!item) {
            continue;
        }
        const QString normalizedTitle = normalizedText(item->title);
        const QStringList titleTokens = normalizedTitle.split(QLatin1Char(' '), Qt::SkipEmptyParts);
        const QString franchiseKey = franchiseKeyOf(titleTokens);

        // `BrowseSnapshotStore.swift:1322-1336`: the title scores from 900; a
        // one-character query only ever matches titles, without substrings or
        // the franchise key.
        if (const int score = searchScore(query, queryTokens, normalizedTitle, titleTokens,
                                          titleOnly ? QString() : franchiseKey, 900,
                                          !titleOnly, !titleOnly && allowsEditDistanceOne)) {
            hits.push_back({*item, Title, QString(), score});
            continue;
        }
        if (titleOnly) {
            continue;
        }
        // `:1424-1436`: the file name scores from 320 and reports itself.
        const QString normalizedFileName = normalizedText(QFileInfo(item->relativePath).fileName());
        const QStringList fileNameTokens =
            normalizedFileName.split(QLatin1Char(' '), Qt::SkipEmptyParts);
        if (const int score = searchScore(query, queryTokens, normalizedFileName, fileNameTokens,
                                          franchiseKey, 320, true, allowsEditDistanceOne)) {
            hits.push_back({*item, FileName, QStringLiteral("File name match"), score});
        }
    }
    // `:1044-1050`: score, then match type, then browse order.
    std::sort(hits.begin(), hits.end(), [](const Hit &lhs, const Hit &rhs) {
        if (lhs.score != rhs.score) {
            return lhs.score > rhs.score;
        }
        if (lhs.matchType != rhs.matchType) {
            return lhs.matchType < rhs.matchType;
        }
        return browse::compareMoviesForBrowsing(lhs.item, rhs.item);
    });
    return hits;
}

void SearchSession::evaluate()
{
    ++m_generation;

    // `BrowseSnapshotStore.swift:1233-1249`: a scope prefix narrows the
    // search to one column. The columns it names arrive with metadata
    // enrichment, so a scoped query finds nothing until then, as it would in
    // the released app over a library without that metadata.
    const QString trimmed = m_query.trimmed();
    const QString lowered = trimmed.toLower();
    static const QStringList scopePrefixes = {
        QStringLiteral("collection:"), QStringLiteral("director:"), QStringLiteral("cast:"),
        QStringLiteral("keyword:"), QStringLiteral("genre:")};
    bool scoped = false;
    for (const QString &prefix : scopePrefixes) {
        if (lowered.startsWith(prefix)) {
            scoped = true;
            break;
        }
    }

    const QString query = normalizedText(trimmed);
    const QStringList queryTokens = query.split(QLatin1Char(' '), Qt::SkipEmptyParts);

    // `:964-980`: suggestions need two normalised characters and cap at eight.
    QStringList suggestions;
    if (query.size() >= 2) {
        for (const auto &value : m_suggestionValues) {
            if (value.second.contains(query)) {
                suggestions.push_back(value.first);
                if (suggestions.size() >= 8) {
                    break;
                }
            }
        }
    }

    QVector<Hit> hits;
    if (!query.isEmpty() && !scoped) {
        // `:993-995`: a single character searches titles only. `:996-1015`:
        // the fuzzy pass runs only when the exact pass found nothing.
        const bool titleOnly = query.size() == 1;
        hits = searchPass(query, queryTokens, titleOnly, false);
        if (hits.isEmpty()) {
            hits = searchPass(query, queryTokens, titleOnly, true);
        }
    }

    beginResetModel();
    m_hits = std::move(hits);
    m_suggestions = std::move(suggestions);
    endResetModel();
    emit resultsChanged();
}
