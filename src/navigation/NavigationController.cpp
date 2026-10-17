#include "navigation/NavigationController.hpp"

#include "support/Logging.hpp"

#include <utility>

NavigationController::NavigationController(QObject *parent)
    : QObject(parent)
{
}

NavigationController::Route NavigationController::route() const
{
    return m_route;
}

QString NavigationController::selectedMediaId() const
{
    return m_selectedMediaId;
}

bool NavigationController::canGoBack() const
{
    return !m_history.isEmpty();
}

void NavigationController::openRoute(Route route)
{
    if (route == Route::Details || route == Route::ShowDetail || route == Route::Player) {
        return;
    }
    transitionTo({.route = route, .selectedMediaId = {}}, true);
}

void NavigationController::openDetails(const QString &mediaId)
{
    if (mediaId.trimmed().isEmpty()) {
        return;
    }
    transitionTo({.route = Route::Details, .selectedMediaId = mediaId}, true);
}

void NavigationController::openShowDetail(const QString &showName)
{
    if (showName.trimmed().isEmpty()) {
        return;
    }
    transitionTo({.route = Route::ShowDetail, .selectedMediaId = showName}, true);
}

void NavigationController::openPlayer(const QString &mediaId)
{
    if (mediaId.trimmed().isEmpty()) {
        return;
    }
    transitionTo({.route = Route::Player, .selectedMediaId = mediaId}, true);
}

void NavigationController::showProfilePicker()
{
    transitionTo({.route = Route::ProfilePicker, .selectedMediaId = {}}, true);
}

void NavigationController::goHome()
{
    transitionTo({.route = Route::Home, .selectedMediaId = {}}, true);
}

void NavigationController::goBack()
{
    if (m_history.isEmpty()) {
        if (m_route != Route::Home && m_route != Route::ProfilePicker) {
            transitionTo({.route = Route::Home, .selectedMediaId = {}}, false);
        }
        return;
    }

    const Entry destination = m_history.takeLast();
    const bool oldCanGoBack = true;
    transitionTo(destination, false);
    if (oldCanGoBack != canGoBack()) {
        emit canGoBackChanged();
    }
}

void NavigationController::resetTo(Route route, const QString &mediaId)
{
    const QString normalizedMediaId = mediaId.trimmed();
    if ((route == Route::Details || route == Route::ShowDetail || route == Route::Player)
        && normalizedMediaId.isEmpty()) {
        qCWarning(logNavigation)
            << "Ignoring resetTo for details/player route without media id";
        return;
    }

    const bool hadHistory = !m_history.isEmpty();
    m_history.clear();
    transitionTo(
        {.route = route, .selectedMediaId = normalizedMediaId},
        false);
    if (hadHistory) {
        emit canGoBackChanged();
    }
}

void NavigationController::transitionTo(Entry next, bool recordHistory)
{
    if (next.route == m_route && next.selectedMediaId == m_selectedMediaId) {
        return;
    }

    const bool oldCanGoBack = canGoBack();
    if (recordHistory) {
        const Entry current = currentEntry();
        if (m_history.isEmpty()
            || m_history.constLast().route != current.route
            || m_history.constLast().selectedMediaId != current.selectedMediaId) {
            m_history.push_back(current);
        }
    }

    const bool routeChangedValue = m_route != next.route;
    const bool mediaChangedValue = m_selectedMediaId != next.selectedMediaId;

    m_route = next.route;
    m_selectedMediaId = std::move(next.selectedMediaId);

    qCInfo(logNavigation) << "route=" << static_cast<int>(m_route)
                          << "historyDepth=" << m_history.size();

    if (routeChangedValue) {
        emit routeChanged();
    }
    if (mediaChangedValue) {
        emit selectedMediaIdChanged();
    }
    if (oldCanGoBack != canGoBack()) {
        emit canGoBackChanged();
    }
}

NavigationController::Entry NavigationController::currentEntry() const
{
    return {.route = m_route, .selectedMediaId = m_selectedMediaId};
}
