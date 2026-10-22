#pragma once

#include <QNetworkAccessManager>
#include <QObject>

#include "metadata/HttpTransport.hpp"

/// The production transport. It must be created on the thread that will use
/// it, because `QNetworkAccessManager` delivers its replies there.
class QtHttpTransport final : public QObject, public HttpTransport
{
    Q_OBJECT

public:
    explicit QtHttpTransport(QObject *parent = nullptr);

    void get(const QUrl &url, std::function<void(HttpReply)> done) override;

private:
    QNetworkAccessManager m_network;
};
