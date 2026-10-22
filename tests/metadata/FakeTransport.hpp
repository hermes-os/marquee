#pragma once

#include <QByteArray>
#include <QPointer>
#include <QThread>
#include <QTimer>
#include <QUrl>
#include <QUrlQuery>

#include <functional>
#include <utility>

#include "metadata/HttpTransport.hpp"

/// A transport that answers from memory, later and on the thread it is called
/// from, as the real one does. Nothing in the test suite reaches the network.
class FakeTransport final : public HttpTransport
{
public:
    using Responder = std::function<HttpReply(const QUrl &)>;

    explicit FakeTransport(Responder responder = {})
        : m_responder(std::move(responder))
    {
    }

    void setResponder(Responder responder) { m_responder = std::move(responder); }

    void get(const QUrl &url, std::function<void(HttpReply)> done) override
    {
        m_urls.push_back(url);
        m_threads.push_back(QThread::currentThread());
        const HttpReply reply = m_responder ? m_responder(url) : offline();
        // Answers arrive from the event loop, never from inside get().
        QTimer::singleShot(0, [done = std::move(done), reply] { done(reply); });
    }

    [[nodiscard]] const QList<QUrl> &urls() const { return m_urls; }
    [[nodiscard]] const QList<QThread *> &threads() const { return m_threads; }
    [[nodiscard]] int count() const { return static_cast<int>(m_urls.size()); }
    [[nodiscard]] int countContaining(const QString &fragment) const
    {
        int matches = 0;
        for (const QUrl &url : m_urls) {
            if (url.path().contains(fragment)) {
                ++matches;
            }
        }
        return matches;
    }

    [[nodiscard]] static HttpReply json(const QByteArray &body)
    {
        return {.error = HttpReply::Error::None, .status = 200, .body = body};
    }
    [[nodiscard]] static HttpReply status(int code)
    {
        return {.error = HttpReply::Error::None, .status = code, .body = {}};
    }
    [[nodiscard]] static HttpReply offline()
    {
        return {.error = HttpReply::Error::Network, .status = 0, .body = {}};
    }
    [[nodiscard]] static QString queryValue(const QUrl &url, const QString &name)
    {
        return QUrlQuery(url).queryItemValue(name, QUrl::FullyDecoded);
    }

private:
    Responder m_responder;
    QList<QUrl> m_urls;
    QList<QThread *> m_threads;
};
