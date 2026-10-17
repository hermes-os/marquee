#pragma once

#include <QObject>
#include <QString>
#include <QVector>
#include <QtQml/qqmlregistration.h>

class NavigationController : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_UNCREATABLE("NavigationController is owned by ApplicationController")

public:
    enum class Route {
        ProfilePicker,
        Home,
        Search,
        Movies,
        Shows,
        Settings,
        Details,
        /// TVShowsDetailView.swift:110-116: one show's detail, presented over
        /// the shows grid and dismissed back to it.
        ShowDetail,
        Player
    };
    Q_ENUM(Route)

    Q_PROPERTY(Route route READ route NOTIFY routeChanged)
    Q_PROPERTY(QString selectedMediaId READ selectedMediaId NOTIFY selectedMediaIdChanged)
    Q_PROPERTY(bool canGoBack READ canGoBack NOTIFY canGoBackChanged)

    explicit NavigationController(QObject *parent = nullptr);

    [[nodiscard]] Route route() const;
    [[nodiscard]] QString selectedMediaId() const;
    [[nodiscard]] bool canGoBack() const;

    Q_INVOKABLE void openRoute(Route route);
    Q_INVOKABLE void openDetails(const QString &mediaId);
    /// Opens `showName`'s detail; `selectedMediaId` carries the show name
    /// while this route is current.
    Q_INVOKABLE void openShowDetail(const QString &showName);
    Q_INVOKABLE void openPlayer(const QString &mediaId);
    Q_INVOKABLE void showProfilePicker();
    Q_INVOKABLE void goHome();
    Q_INVOKABLE void goBack();
    Q_INVOKABLE void resetTo(Route route, const QString &mediaId = QString());

signals:
    void routeChanged();
    void selectedMediaIdChanged();
    void canGoBackChanged();

private:
    struct Entry
    {
        Route route{Route::Home};
        QString selectedMediaId;
    };

    void transitionTo(Entry next, bool recordHistory);
    [[nodiscard]] Entry currentEntry() const;

    Route m_route{Route::ProfilePicker};
    QString m_selectedMediaId;
    QVector<Entry> m_history;
};
