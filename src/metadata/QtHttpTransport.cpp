#include "metadata/QtHttpTransport.hpp"

#include <QNetworkReply>
#include <QNetworkRequest>

#include <utility>

namespace
{
// ImageCacheService.swift:13-18 allows 30 seconds a request.
constexpr int kRequestTimeoutMs = 30'000;
}

QtHttpTransport::QtHttpTransport(QObject *parent)
    : QObject(parent)
{
}

void QtHttpTransport::get(const QUrl &url, std::function<void(HttpReply)> done)
{
    QNetworkRequest request(url);
    request.setTransferTimeout(kRequestTimeoutMs);
    request.setAttribute(QNetworkRequest::RedirectPolicyAttribute,
                         QNetworkRequest::NoLessSafeRedirectPolicy);
    request.setHeader(QNetworkRequest::UserAgentHeader, QByteArrayLiteral("Marquee"));

    QNetworkReply *reply = m_network.get(request);
    connect(reply, &QNetworkReply::finished, this, [reply, done = std::move(done)] {
        HttpReply result;
        result.status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        if (result.status == 0) {
            // No HTTP answer arrived. The error text is deliberately not kept:
            // Qt includes the request URL in it, and the URL holds the key.
            result.error = HttpReply::Error::Network;
        } else {
            result.body = reply->readAll();
            const QByteArray retryAfter = reply->rawHeader("Retry-After");
            bool numeric = false;
            const int seconds = retryAfter.trimmed().toInt(&numeric);
            result.retryAfterSeconds = numeric ? seconds : -1;
        }
        reply->deleteLater();
        done(std::move(result));
    });
}
