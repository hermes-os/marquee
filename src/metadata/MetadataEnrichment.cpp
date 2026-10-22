#include "metadata/MetadataEnrichment.hpp"

#include <QDir>
#include <QHash>
#include <QSet>
#include <QTimer>

#include <exception>
#include <optional>
#include <utility>

#include "app/AppPaths.hpp"
#include "metadata/ArtworkCache.hpp"
#include "metadata/MetadataSwitch.hpp"
#include "metadata/QtHttpTransport.hpp"
#include "metadata/TmdbApiKey.hpp"
#include "support/Logging.hpp"

namespace
{
using Kind = artwork_cache::Kind;
}

struct MetadataEnrichment::Image
{
    Kind kind{Kind::Poster};
    QString ownerKind;
    int tmdbId{0};
    QString remotePath;
    /// Where the cached file's name is recorded: the title, or one episode.
    QString ownerKey;
    bool episodeStill{false};
    QString stem;
};

struct MetadataEnrichment::Run
{
    QVector<MetadataTarget> targets;
    qsizetype targetIndex{-1};
    Summary summary;

    MetadataTarget target;
    std::optional<int> tmdbId;
    QString posterRemote;
    QString backdropRemote;
    qsizetype episodeIndex{0};
    // Seasons already asked about in this run; an empty list is a season TMDB
    // does not have.
    QHash<int, QVector<tmdb::SeasonEpisode>> seasons;
    QSet<int> seasonsMissing;
    bool artworkAllowed{true};
};

MetadataSetup defaultMetadataSetup()
{
    MetadataSetup setup;
    setup.transportFactory = [] { return std::make_unique<QtHttpTransport>(); };
    setup.keyProvider = tmdb_key::provider();
    setup.allowed = [] { return metadata_switch::enabled(); };
    setup.now = [] { return QDateTime::currentDateTimeUtc(); };
    setup.cache = {.fullDirectory = AppPaths::artworkCacheDirectory(),
                   .thumbnailDirectory = AppPaths::thumbnailCacheDirectory()};
    return setup;
}

MetadataEnrichment::MetadataEnrichment(QString catalogPath, MetadataSetup setup, QObject *parent)
    : QObject(parent)
    , m_catalogPath(std::move(catalogPath))
    , m_setup(std::move(setup))
{
    qRegisterMetaType<MetadataEnrichment::Summary>();
}

MetadataEnrichment::~MetadataEnrichment() = default;

bool MetadataEnrichment::running() const
{
    return m_run != nullptr;
}

void MetadataEnrichment::stop()
{
    m_stopRequested = true;
}

bool MetadataEnrichment::mayContinue()
{
    if (m_stopRequested || (m_setup.allowed && !m_setup.allowed())) {
        finish(Outcome::Stopped);
        return false;
    }
    return true;
}

bool MetadataEnrichment::interrupted(MetadataClient::Status status)
{
    if (!MetadataClient::endsRun(status)) {
        return false;
    }
    qCInfo(logMetadata) << "enrichment interrupted; what was fetched is kept";
    finish(Outcome::Interrupted);
    return true;
}

bool MetadataEnrichment::artworkCacheIsSafe(const QStringList &rootPaths) const
{
    return !artwork_cache::isInsideAny(m_setup.cache.fullDirectory, rootPaths)
        && !artwork_cache::isInsideAny(m_setup.cache.thumbnailDirectory, rootPaths);
}

void MetadataEnrichment::restart()
{
    if (!m_lastRoots.isEmpty()) {
        start(m_lastRoots);
    }
}

void MetadataEnrichment::start(const QStringList &rootPaths)
{
    m_lastRoots = rootPaths;
    if (m_run) {
        // A scan that lands during a run may have added titles the run's list
        // does not hold, so the run is followed by another over the new
        // roots. A stop requested earlier no longer applies: the viewer has
        // asked for metadata again.
        m_stopRequested = false;
        m_restartRequested = true;
        return;
    }
    m_stopRequested = false;

    // With no key, or the switch off, the app behaves as it did before this
    // existed: no object is built, no request is made.
    const QString key = m_setup.keyProvider ? m_setup.keyProvider() : QString();
    if (key.isEmpty() || (m_setup.allowed && !m_setup.allowed())) {
        emit finished({.outcome = Outcome::Disabled});
        return;
    }

    m_run = std::make_unique<Run>();
    try {
        m_store = std::make_unique<MetadataStore>(m_catalogPath);
        const QDateTime now = m_setup.now ? m_setup.now() : QDateTime::currentDateTimeUtc();
        m_run->targets = m_store->pendingTargets(rootPaths, now, m_setup.cache);
    } catch (const std::exception &error) {
        qCWarning(logMetadata) << "enrichment could not read the catalog:" << error.what();
        m_store.reset();
        finish(Outcome::Failed);
        return;
    }
    if (m_run->targets.isEmpty()) {
        finish(Outcome::UpToDate);
        return;
    }

    m_run->artworkAllowed = artworkCacheIsSafe(rootPaths);
    if (!m_run->artworkAllowed) {
        qCWarning(logMetadata) << "the artwork cache lies under a library root; "
                                  "artwork is not downloaded";
    }

    if (!m_transport) {
        m_transport = m_setup.transportFactory ? m_setup.transportFactory()
                                               : std::make_unique<QtHttpTransport>();
    }
    MetadataClient::Config config;
    config.apiKey = key;
    config.minRequestIntervalMs = m_setup.minRequestIntervalMs;
    m_client = std::make_unique<MetadataClient>(*m_transport, std::move(config));

    qCInfo(logMetadata) << "enrichment run:" << m_run->targets.size() << "titles";
    // Start from the event loop, so a caller that connected `finished` after
    // calling start() still hears it.
    QTimer::singleShot(0, this, [this] { next(); });
}

void MetadataEnrichment::finish(Outcome outcome)
{
    if (!m_run) {
        return;
    }
    Summary summary = m_run->summary;
    summary.outcome = outcome;
    // Late answers belong to the run that is over.
    m_client.reset();
    m_store.reset();
    m_run.reset();
    qCInfo(logMetadata) << "enrichment finished: saved" << summary.titlesSaved << "unmatched"
                        << summary.titlesUnmatched << "failed" << summary.titlesFailed
                        << "episodes" << summary.episodesSaved << "images" << summary.imagesCached;
    emit finished(summary);
    if (m_restartRequested && outcome != Outcome::Failed) {
        m_restartRequested = false;
        start(m_lastRoots);
    }
    m_restartRequested = false;
}

void MetadataEnrichment::next()
{
    if (!m_run || !mayContinue()) {
        return;
    }
    ++m_run->targetIndex;
    if (m_run->targetIndex >= m_run->targets.size()) {
        finish(Outcome::Finished);
        return;
    }
    beginTarget();
}

void MetadataEnrichment::beginTarget()
{
    Run &run = *m_run;
    run.target = run.targets.at(run.targetIndex);
    run.tmdbId = run.target.tmdbId;
    run.posterRemote = run.target.posterRemotePath;
    run.backdropRemote = run.target.backdropRemotePath;
    run.episodeIndex = 0;

    if (!run.target.needsDetails) {
        // Only artwork or episodes are missing: TMDB already matched the title.
        afterDetails();
        return;
    }
    if (run.tmdbId) {
        fetchDetails(*run.tmdbId);
        return;
    }
    searchThenDetails();
}

void MetadataEnrichment::searchThenDetails()
{
    const MetadataTarget &target = m_run->target;
    const auto found = [this](MetadataClient::Result<int> result) {
        if (!m_run || !mayContinue()) {
            return;
        }
        if (interrupted(result.status)) {
            return;
        }
        if (result.status == MetadataClient::Status::Ok) {
            m_run->tmdbId = result.value;
            Run &run = *m_run;
            if (run.target.rematch && run.target.previousState == metadata_state::matched
                && run.target.previousTmdbId == std::optional<int>(result.value)) {
                // The current matcher agrees with the old one: the stored
                // data stays, and only what is still missing is fetched.
                try {
                    m_store->keepMatch(run.target.ownerKey);
                } catch (const std::exception &error) {
                    qCWarning(logMetadata) << "enrichment could not write the catalog:"
                                           << error.what();
                    finish(Outcome::Failed);
                    return;
                }
                run.target.wantPoster = run.target.wantPoster && !run.posterRemote.isEmpty()
                    && !run.target.posterCached;
                run.target.wantBackdrop = run.target.wantBackdrop && !run.backdropRemote.isEmpty()
                    && !run.target.backdropCached;
                afterDetails();
                return;
            }
            fetchDetails(result.value);
            return;
        }
        // TMDB answered and has nobody by that name: wait before asking again.
        const bool notFound = result.status == MetadataClient::Status::NotFound;
        try {
            if (m_run->target.previousState == metadata_state::matched) {
                // A match made by an older matcher stays when the new one
                // finds nothing better; only a clean "no match" settles it,
                // anything else is asked again on the next run.
                if (notFound) {
                    m_store->keepMatch(m_run->target.ownerKey);
                }
            } else {
                m_store->saveAttempt(m_run->target,
                                     notFound ? metadata_state::unmatched : metadata_state::failed,
                                     m_setup.now());
            }
        } catch (const std::exception &error) {
            qCWarning(logMetadata) << "enrichment could not write the catalog:" << error.what();
            finish(Outcome::Failed);
            return;
        }
        // A Malformed answer is stored as failed, so it counts as failed.
        if (notFound) {
            ++m_run->summary.titlesUnmatched;
        } else {
            ++m_run->summary.titlesFailed;
        }
        titleDone();
    };
    if (target.kind == MetadataTarget::Kind::Movie) {
        m_client->findMovie(target.title, target.year, found);
    } else {
        m_client->findShow(target.title, target.year, found);
    }
}

void MetadataEnrichment::fetchDetails(int tmdbId)
{
    const auto details = [this, tmdbId](MetadataClient::Result<TitleMetadata> result) {
        if (!m_run || !mayContinue()) {
            return;
        }
        if (interrupted(result.status)) {
            return;
        }
        try {
            if (result.status != MetadataClient::Status::Ok) {
                // The match is kept, so the next try goes straight to details.
                m_store->saveAttempt(m_run->target, metadata_state::failed, m_setup.now(),
                                     tmdbId);
                ++m_run->summary.titlesFailed;
                titleDone();
                return;
            }
            m_store->saveTitle(m_run->target, result.value, m_setup.now());
            if (m_run->target.rematch && m_run->target.previousState == metadata_state::matched
                && m_run->target.previousTmdbId != std::optional<int>(tmdbId)) {
                // Another show than before: nothing stored about the old
                // one's episodes applies, so all of them are fetched afresh.
                m_run->target.episodes = m_run->target.allEpisodes;
            }
            m_run->posterRemote = result.value.posterRemotePath;
            m_run->backdropRemote = result.value.backdropRemotePath;
            ++m_run->summary.titlesSaved;
        } catch (const std::exception &error) {
            qCWarning(logMetadata) << "enrichment could not write the catalog:" << error.what();
            finish(Outcome::Failed);
            return;
        }
        afterDetails();
    };
    if (m_run->target.kind == MetadataTarget::Kind::Movie) {
        m_client->movieDetails(tmdbId, details);
    } else {
        m_client->showDetails(tmdbId, details);
    }
}

void MetadataEnrichment::afterDetails()
{
    downloadImages();
}

void MetadataEnrichment::downloadImages()
{
    Run &run = *m_run;
    QVector<Image> images;
    if (run.artworkAllowed && run.tmdbId) {
        const bool movie = run.target.kind == MetadataTarget::Kind::Movie;
        const QString ownerKind = movie ? QStringLiteral("movie") : QStringLiteral("tv");
        // A title fetched just now may have lost or gained an image, so the
        // remote paths come from the answer, not from the earlier row.
        if (run.target.wantPoster) {
            images.push_back({.kind = Kind::Poster, .ownerKind = ownerKind, .tmdbId = *run.tmdbId,
                              .remotePath = run.posterRemote, .ownerKey = run.target.ownerKey,
                              .episodeStill = false,
                              .stem = artwork_cache::stem(ownerKind, *run.tmdbId, Kind::Poster)});
        }
        if (run.target.wantBackdrop) {
            images.push_back({.kind = Kind::Backdrop, .ownerKind = ownerKind, .tmdbId = *run.tmdbId,
                              .remotePath = run.backdropRemote, .ownerKey = run.target.ownerKey,
                              .episodeStill = false,
                              .stem = artwork_cache::stem(ownerKind, *run.tmdbId, Kind::Backdrop)});
        }
    }
    downloadNextImage(std::move(images), 0);
}

void MetadataEnrichment::downloadNextImage(QVector<Image> images, qsizetype index)
{
    if (!m_run || !mayContinue()) {
        return;
    }
    // Skip what TMDB has no image for, or names unsafely.
    while (index < images.size() && images.at(index).remotePath.isEmpty()) {
        ++index;
    }
    if (index >= images.size()) {
        afterImages();
        return;
    }
    const Image image = images.at(index);

    const auto settle = [this, image](const QString &thumbnailName, bool forgetRemote) {
        try {
            if (image.episodeStill) {
                m_store->saveEpisodeStill(image.ownerKey, thumbnailName, forgetRemote);
            } else {
                m_store->saveArtwork(image.ownerKey, image.kind == Kind::Poster, thumbnailName,
                                     forgetRemote);
            }
        } catch (const std::exception &error) {
            qCWarning(logMetadata) << "enrichment could not write the catalog:" << error.what();
            finish(Outcome::Failed);
            return false;
        }
        return true;
    };

    if (!artwork_cache::isSafeRemotePath(image.remotePath)) {
        qCWarning(logMetadata) << "ignored an image path TMDB sent that is not a plain file name";
        if (settle(QString(), true)) {
            downloadNextImage(images, index + 1);
        }
        return;
    }

    const MetadataClient::ImageSize size = image.kind == Kind::Poster ? MetadataClient::ImageSize::Poster
        : image.kind == Kind::Backdrop                                 ? MetadataClient::ImageSize::Backdrop
                                                                       : MetadataClient::ImageSize::Still;
    m_client->downloadImage(
        image.remotePath, size,
        [this, images, index, image, settle](MetadataClient::Result<QByteArray> result) {
            if (!m_run || !mayContinue()) {
                return;
            }
            if (interrupted(result.status)) {
                return;
            }
            if (result.status == MetadataClient::Status::Ok) {
                const QString name = artwork_cache::store(result.value, image.stem, image.kind,
                                                          m_setup.cache.fullDirectory,
                                                          m_setup.cache.thumbnailDirectory);
                if (!name.isEmpty()) {
                    ++m_run->summary.imagesCached;
                    if (!settle(name, false)) {
                        return;
                    }
                }
                // Bytes that were not an image leave it uncached: the next run
                // asks once more.
            } else if (result.status == MetadataClient::Status::NotFound) {
                // The image is gone from TMDB; there is nothing to retry.
                if (!settle(QString(), true)) {
                    return;
                }
            }
            downloadNextImage(images, index + 1);
        });
}

void MetadataEnrichment::afterImages()
{
    Run &run = *m_run;
    const bool show = run.target.kind == MetadataTarget::Kind::Show;
    if (!show || !run.tmdbId || run.target.episodes.isEmpty()) {
        titleDone();
        return;
    }
    run.episodeIndex = 0;
    nextEpisode();
}

void MetadataEnrichment::nextEpisode()
{
    if (!m_run || !mayContinue()) {
        return;
    }
    Run &run = *m_run;
    if (run.episodeIndex >= run.target.episodes.size()) {
        titleDone();
        return;
    }
    handleEpisode(run.target.episodes.at(run.episodeIndex++));
}

void MetadataEnrichment::handleEpisode(const EpisodeTarget &episode)
{
    Run &run = *m_run;

    const auto afterFacts = [this, episode](const std::optional<EpisodeMetadata> &facts) {
        // The still named by what TMDB just said, or by the earlier row.
        const QString stillRemote = facts ? facts->stillRemotePath : episode.stillRemotePath;
        if (episode.wantStill && m_run->artworkAllowed && !stillRemote.isEmpty()) {
            downloadStill(episode, stillRemote);
            return;
        }
        nextEpisode();
    };

    if (!episode.needsDetails) {
        afterFacts(std::nullopt);
        return;
    }

    const auto useSeason = [this, episode, afterFacts](int season) {
        std::optional<EpisodeMetadata> facts;
        for (const tmdb::SeasonEpisode &listed : m_run->seasons.value(season)) {
            if (listed.episodeNumber == episode.episodeNumber) {
                facts = listed.metadata;
                break;
            }
        }
        try {
            m_store->saveEpisode(episode.mediaId, facts, m_setup.now());
        } catch (const std::exception &error) {
            qCWarning(logMetadata) << "enrichment could not write the catalog:" << error.what();
            finish(Outcome::Failed);
            return;
        }
        if (facts) {
            ++m_run->summary.episodesSaved;
        }
        afterFacts(facts);
    };

    if (run.seasons.contains(episode.seasonNumber) || run.seasonsMissing.contains(episode.seasonNumber)) {
        useSeason(episode.seasonNumber);
        return;
    }
    m_client->seasonEpisodes(
        *run.tmdbId, episode.seasonNumber,
        [this, episode, useSeason](MetadataClient::Result<QVector<tmdb::SeasonEpisode>> result) {
            if (!m_run || !mayContinue()) {
                return;
            }
            if (interrupted(result.status)) {
                return;
            }
            if (result.status == MetadataClient::Status::Ok) {
                m_run->seasons.insert(episode.seasonNumber, std::move(result.value));
            } else {
                m_run->seasonsMissing.insert(episode.seasonNumber);
            }
            useSeason(episode.seasonNumber);
        });
}

void MetadataEnrichment::downloadStill(const EpisodeTarget &episode, const QString &remotePath)
{
    const Image still{.kind = Kind::Still,
                      .ownerKind = QStringLiteral("tv"),
                      .tmdbId = *m_run->tmdbId,
                      .remotePath = remotePath,
                      .ownerKey = episode.mediaId,
                      .episodeStill = true,
                      .stem = artwork_cache::episodeStillStem(*m_run->tmdbId, episode.seasonNumber,
                                                              episode.episodeNumber)};
    const auto afterStill = [this] { nextEpisode(); };
    if (!artwork_cache::isSafeRemotePath(remotePath)) {
        try {
            m_store->saveEpisodeStill(episode.mediaId, QString(), true);
        } catch (const std::exception &error) {
            qCWarning(logMetadata) << "enrichment could not write the catalog:" << error.what();
            finish(Outcome::Failed);
            return;
        }
        afterStill();
        return;
    }
    m_client->downloadImage(
        remotePath, MetadataClient::ImageSize::Still,
        [this, still, afterStill](MetadataClient::Result<QByteArray> result) {
            if (!m_run || !mayContinue()) {
                return;
            }
            if (interrupted(result.status)) {
                return;
            }
            try {
                if (result.status == MetadataClient::Status::Ok) {
                    const QString name = artwork_cache::store(result.value, still.stem, still.kind,
                                                              m_setup.cache.fullDirectory,
                                                              m_setup.cache.thumbnailDirectory);
                    if (!name.isEmpty()) {
                        m_store->saveEpisodeStill(still.ownerKey, name, false);
                        ++m_run->summary.imagesCached;
                    }
                } else if (result.status == MetadataClient::Status::NotFound) {
                    m_store->saveEpisodeStill(still.ownerKey, QString(), true);
                }
            } catch (const std::exception &error) {
                qCWarning(logMetadata) << "enrichment could not write the catalog:" << error.what();
                finish(Outcome::Failed);
                return;
            }
            afterStill();
        });
}

void MetadataEnrichment::titleDone()
{
    if (!m_run) {
        return;
    }
    // Hand control back to the event loop between titles, so a stop request
    // or another queued job runs before the next request.
    QTimer::singleShot(0, this, [this] { next(); });
}
