#pragma once

#include <QAbstractListModel>
#include <QByteArray>
#include <QHash>
#include <QList>
#include <QModelIndex>
#include <QString>
#include <QVariant>
#include <QVariantList>
#include <QVariantMap>
#include <QVector>

#include <optional>

#include "catalog/MediaItem.hpp"

/// The library projection as QML sees it. Rows arrive from the catalog worker
/// through a queued connection, which is what keeps every mutation of this
/// model on the GUI thread.
class LibraryModel final : public QAbstractListModel
{
    Q_OBJECT

    /// Every title the projection holds, which is what
    /// `Marquee/Features/Home/Views/HomeDetailView.swift:385` counts for the
    /// Home title bar and what `:191` asks before drawing Home at all. It
    /// counts the projection rather than a view, so a surface that has laid out
    /// no delegates yet still answers with the library it has.
    Q_PROPERTY(int titleCount READ titleCount NOTIFY titleCountChanged)

public:
    enum Role {
        IdRole = Qt::UserRole + 1,
        TitleRole,
        YearRole,
        KindRole,
        PosterUrlRole,
        MetadataRole,
        // The container format the fallback artwork names when a title has no
        // usable artwork.
        FormatBadgeRole,
        // TMDB metadata (MediaItem.swift `metadata`, TMDBMetadata.swift:5-22).
        // Absent values are empty, or null for numbers; `hasMetadata` says
        // whether TMDB matched the title at all. The later Rows and Details
        // tasks bind to these; nothing draws them yet.
        HasMetadataRole,
        TmdbIdRole,
        OverviewRole,
        DirectorRole,
        CertificationRole,
        ReleaseDateRole,
        VoteAverageRole,
        VoteCountRole,
        PopularityRole,
        CollectionIdRole,
        CollectionNameRole,
        RuntimeMinutesRole,
        GenresRole,
        CastRole,
        KeywordsRole,
        BackdropUrlRole
    };
    Q_ENUM(Role)

    explicit LibraryModel(QObject *parent = nullptr);

    [[nodiscard]] int rowCount(const QModelIndex &parent = QModelIndex{}) const override;
    [[nodiscard]] QVariant data(const QModelIndex &index, int role) const override;
    [[nodiscard]] QHash<int, QByteArray> roleNames() const override;

    [[nodiscard]] int titleCount() const;

    /// The projected item carrying `mediaId`, or nothing when the projection no
    /// longer holds it. Surfaces address items by identity rather than by row,
    /// because a rescan replaces every row.
    [[nodiscard]] std::optional<MediaItem> itemForId(const QString &mediaId) const;

    /// The catalog facts the details surface draws for `mediaId`, or an empty
    /// map when the projection no longer holds it. Sizes and the format badge
    /// are composed here so one surface cannot describe a file differently from
    /// another.
    [[nodiscard]] Q_INVOKABLE QVariantMap detailsForId(const QString &mediaId) const;

    /// BrowseSnapshotStore.swift:148-159, through
    /// BrowseRecommendationEngine: up to `limit` other movies ranked by
    /// franchise, shared decade, and browse order, for "More Like This".
    /// Each entry is the map the movie card binds to: mediaId, title, year,
    /// posterUrl, metadata, and formatBadge. An empty list means the section
    /// has nothing to draw, which the surface renders as the oracle does for
    /// an empty `similar` (it draws nothing).
    [[nodiscard]] Q_INVOKABLE QVariantList similarMovies(const QString &mediaId,
                                                        int limit = 10) const;

public slots:
    /// Takes a fresh projection from the catalog. Titles it no longer holds
    /// also lose their progress ordering, so a title that returns later
    /// starts from what the catalog then says about it.
    void replaceItems(QVector<MediaItem> items);

    /// Applies the runtime and resume point recorded for `mediaId`. The catalog
    /// holds the durable row; this keeps the projection the surfaces read from
    /// agreeing with it between scans, so a title played twice in one session
    /// opens where the first viewing left it. A changed runtime emits the
    /// metadata role so visible delegates refresh without a rescan.
    ///
    /// The same row reaches this model twice, directly from the recorder and
    /// later echoed from the catalog after it is written, and the echo of an
    /// older row can arrive after a newer row was applied directly. `sequence`
    /// is the recorder's ordering: a row older than the newest one applied to
    /// this title in this process is ignored, so an echo can restate progress
    /// a rescan replaced but never move a title backwards.
    void applyWatchProgress(const QString &mediaId,
                            qint64 positionMs,
                            qint64 durationMs,
                            quint64 sequence);

signals:
    void titleCountChanged();

private:
    QVector<MediaItem> m_items;
    // Newest progress sequence applied per title, kept across projection
    // replacements for the titles that survive them.
    QHash<QString, quint64> m_progressSequences;
};
