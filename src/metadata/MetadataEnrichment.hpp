#pragma once

#include <QDateTime>
#include <QObject>
#include <QString>
#include <QStringList>
#include <QVector>

#include <functional>
#include <memory>

#include "catalog/MetadataStore.hpp"
#include "catalog/TitleMetadata.hpp"
#include "metadata/HttpTransport.hpp"
#include "metadata/MetadataClient.hpp"

/// What one enrichment run needs from outside: the network, the key, the
/// clock, the switch and where to cache artwork. The defaults are the app's;
/// tests replace the transport, the key, the clock and the directories.
struct MetadataSetup
{
    /// Builds the transport on the thread that will use it.
    std::function<std::unique_ptr<HttpTransport>()> transportFactory;
    /// The API key, read at the start of each run so a key added later takes
    /// effect on the next scan. Empty means no key.
    std::function<QString()> keyProvider;
    /// False stops the run before its next request (Settings switch).
    std::function<bool()> allowed;
    std::function<QDateTime()> now;
    MetadataStore::CacheDirectories cache;
    int minRequestIntervalMs{200};
};

/// The defaults the application uses.
[[nodiscard]] MetadataSetup defaultMetadataSetup();

/// Fills the catalog from TMDB in the background (TMDBEnrichmentService). It
/// belongs to one thread with an event loop and never blocks it: every request
/// is asynchronous, so the thread keeps serving its other work between two
/// titles.
///
/// Titles are handled one at a time and every answer is committed before the
/// next request, so a run stopped by the switch, a lost network or a quit
/// resumes exactly where it was: the next run asks the catalog what is still
/// missing (`MetadataStore::pendingTargets`) and fetched titles are not
/// asked again. With no key, or with the switch off, nothing is requested and
/// nothing changes.
class MetadataEnrichment final : public QObject
{
    Q_OBJECT

public:
    enum class Outcome {
        /// Every pending title was handled.
        Finished,
        /// The switch was turned off, or the run was asked to stop.
        Stopped,
        /// No TMDB key, or the switch is off from the start.
        Disabled,
        /// The network was unreachable, the key refused, or the rate limit
        /// did not lift; what was fetched is kept and the rest waits.
        Interrupted,
        /// There was nothing to fetch.
        UpToDate,
        /// The catalog could not be read or written.
        Failed
    };
    Q_ENUM(Outcome)

    struct Summary
    {
        Outcome outcome{Outcome::UpToDate};
        int titlesSaved{0};
        int titlesUnmatched{0};
        int titlesFailed{0};
        int episodesSaved{0};
        int imagesCached{0};
    };

    MetadataEnrichment(QString catalogPath, MetadataSetup setup, QObject *parent = nullptr);
    ~MetadataEnrichment() override;

    [[nodiscard]] bool running() const;

public slots:
    /// Starts a run over the titles under `rootPaths`. A run already going on
    /// is left to finish; it will have seen the same catalog.
    void start(const QStringList &rootPaths);
    /// Ends the run after the request in flight.
    void stop();
    /// Starts a run again over the roots of the last one; does nothing before the first.
    void restart();

signals:
    void finished(MetadataEnrichment::Summary summary);

private:
    struct Run;
    struct Image;

    void next();
    void finish(Outcome outcome);
    void beginTarget();
    void searchThenDetails();
    void fetchDetails(int tmdbId);
    void afterDetails();
    void downloadImages();
    void downloadNextImage(QVector<Image> images, qsizetype index);
    void afterImages();
    void nextEpisode();
    void handleEpisode(const EpisodeTarget &episode);
    void downloadStill(const EpisodeTarget &episode, const QString &remotePath);
    void titleDone();
    /// Whether the run may issue another request: not stopped, still allowed.
    [[nodiscard]] bool mayContinue();
    /// Handles a status that ends the whole run; true when it did.
    [[nodiscard]] bool interrupted(MetadataClient::Status status);
    /// Library roots are read-only mounts. The artwork cache must never lie
    /// under one, so a run whose cache does downloads no artwork.
    [[nodiscard]] bool artworkCacheIsSafe(const QStringList &rootPaths) const;

    QString m_catalogPath;
    MetadataSetup m_setup;
    std::unique_ptr<HttpTransport> m_transport;
    std::unique_ptr<MetadataStore> m_store;
    std::unique_ptr<MetadataClient> m_client;
    std::unique_ptr<Run> m_run;
    bool m_stopRequested{false};
    bool m_restartRequested{false};
    QStringList m_lastRoots;
};
Q_DECLARE_METATYPE(MetadataEnrichment::Summary)
