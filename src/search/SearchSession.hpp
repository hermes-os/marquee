#pragma once

#include <QAbstractListModel>
#include <QByteArray>
#include <QHash>
#include <QObject>
#include <QPair>
#include <QString>
#include <QStringList>
#include <QVector>
#include <QtQml/qqmlregistration.h>

#include "catalog/MediaItem.hpp"

class LibraryModel;

/// The search surface's projection of the library, evaluated the way
/// `Marquee/Features/Browse/BrowseSnapshotStore.swift` evaluates it: the same
/// normalisation, the same scope prefixes, the same scoring ladder, and the
/// same fuzzy second pass, over the facts the v3 catalog holds. The released
/// index also scores collections, directors, cast, keywords, genres, and
/// overviews; those columns arrive with metadata enrichment, so today every
/// hit is a title or a file-name match and reports itself as such.
///
/// The released session evaluates on a worker and coalesces stale keystrokes
/// with a generation token; a library of local files evaluates in well under a
/// frame here, so the projection is refreshed synchronously and `generation`
/// still advances per request for the surfaces that key on it.
class SearchSession final : public QAbstractListModel
{
    Q_OBJECT
    QML_ELEMENT
    QML_UNCREATABLE("SearchSession is owned by ApplicationController")

    /// The raw query as typed. `SearchView.swift:167-176` requests an
    /// evaluation on every change.
    Q_PROPERTY(QString query READ query WRITE setQuery NOTIFY queryChanged)
    /// `SearchView.swift:867`: the query with surrounding whitespace removed,
    /// which decides between the landing state and a search.
    Q_PROPERTY(QString trimmedQuery READ trimmedQuery NOTIFY queryChanged)
    /// `BrowseSnapshotStore.swift:964-980`: up to eight indexed values that
    /// contain the normalised query, once it is two characters long.
    Q_PROPERTY(QStringList suggestions READ suggestions NOTIFY resultsChanged)
    /// `SearchView.swift:879`: the count the "N results for 'q'" label shows.
    Q_PROPERTY(int totalCount READ totalCount NOTIFY resultsChanged)
    /// `SearchSession.swift:128`: the generation of the newest evaluation.
    Q_PROPERTY(quint64 generation READ generation NOTIFY resultsChanged)

public:
    enum Role {
        MediaIdRole = Qt::UserRole + 1,
        TitleRole,
        PosterUrlRole,
        // `SearchView.swift:1328-1336`: year and runtime joined by a middle dot.
        SubtitleRole,
        // `BrowseSearchMatchType` as its raw value, `BrowseSnapshotStore.swift:884`.
        MatchTypeRole,
        // The released detail string for the match, empty for a title match.
        MatchDetailRole,
        FormatBadgeRole
    };
    Q_ENUM(Role)

    // `BrowseSnapshotStore.swift:884-892`, in the released order, which is also
    // the tie-break order between equal scores.
    enum MatchType {
        Title = 0,
        Collection = 1,
        Director = 2,
        Cast = 3,
        Keyword = 4,
        Genre = 5,
        Overview = 6,
        FileName = 7
    };
    Q_ENUM(MatchType)

    explicit SearchSession(LibraryModel *library, QObject *parent = nullptr);

    [[nodiscard]] int rowCount(const QModelIndex &parent = QModelIndex{}) const override;
    [[nodiscard]] QVariant data(const QModelIndex &index, int role) const override;
    [[nodiscard]] QHash<int, QByteArray> roleNames() const override;

    [[nodiscard]] QString query() const;
    void setQuery(const QString &query);
    [[nodiscard]] QString trimmedQuery() const;
    [[nodiscard]] QStringList suggestions() const;
    [[nodiscard]] int totalCount() const;
    [[nodiscard]] quint64 generation() const;

    /// `SearchView.swift:1011-1012`: the media identity at `row`, which is
    /// what the surface hands to details.
    [[nodiscard]] Q_INVOKABLE QString mediaIdAt(int row) const;

    /// `BrowseSemanticPolicy.normalizedText`, `BrowseSnapshotStore.swift:1784`:
    /// diacritics folded, lowercased, every non-alphanumeric run collapsed to
    /// one space, and the ends trimmed.
    [[nodiscard]] static QString normalizedText(const QString &value);

signals:
    void queryChanged();
    void resultsChanged();

private:
    struct Hit {
        MediaItem item;
        MatchType matchType{Title};
        QString matchDetail;
        int score{0};
    };

    void evaluate();
    [[nodiscard]] QVector<Hit> searchPass(const QString &query,
                                          const QStringList &queryTokens,
                                          bool titleOnly,
                                          bool allowsEditDistanceOne) const;
    void rebuildSuggestionValues();

    LibraryModel *m_library;
    QString m_query;
    QVector<Hit> m_hits;
    QStringList m_suggestions;
    // `BrowseSnapshotStore.swift:1676-1770`: every distinct display value the
    // index offers as a suggestion, sorted case-insensitively.
    QVector<QPair<QString, QString>> m_suggestionValues;
    quint64 m_generation{0};
};
