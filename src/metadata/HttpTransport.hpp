#pragma once

#include <QByteArray>
#include <QUrl>

#include <functional>

/// What the metadata client needs from the network. The real transport is Qt's
/// `QNetworkAccessManager`; tests substitute one that answers from memory, so
/// no test reaches the network.
struct HttpReply
{
    enum class Error {
        None,
        /// No connection, DNS failure, timeout, TLS failure: anything where
        /// no HTTP answer arrived.
        Network
    };

    Error error{Error::None};
    int status{0};
    QByteArray body;
    /// Seconds from a `Retry-After` header, or -1 when there was none.
    int retryAfterSeconds{-1};
};

class HttpTransport
{
public:
    HttpTransport() = default;
    virtual ~HttpTransport() = default;

    HttpTransport(const HttpTransport &) = delete;
    HttpTransport &operator=(const HttpTransport &) = delete;

    /// Starts a GET and calls `done` exactly once, later, from the thread the
    /// transport lives on. The URL may carry the API key, so an implementation
    /// must not log it unmasked.
    virtual void get(const QUrl &url, std::function<void(HttpReply)> done) = 0;
};
