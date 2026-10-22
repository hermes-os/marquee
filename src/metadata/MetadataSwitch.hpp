#pragma once

#include <QObject>

/// Whether online metadata enrichment is allowed right now.
///
/// The settings store owns the preference and lives on the GUI thread; the
/// enrichment runs on the catalog worker's thread and has to notice a change
/// between two requests, without a queued signal that would only be delivered
/// once the work in progress yields. The store publishes its value here, and
/// the run reads it before every request.
namespace metadata_switch
{
/// `UserSettingsData.defaults` seeds a fresh install on
/// (UserSettings.swift:182). Without a key nothing is fetched whatever this
/// says.
[[nodiscard]] bool enabled();
void setEnabled(bool value);

/// Emits `enabledChanged` from the thread that called `setEnabled`, so a
/// worker on another thread connects to it and runs its slot in its own.
class Notifier final : public QObject
{
    Q_OBJECT
signals:
    void enabledChanged(bool enabled);
};
[[nodiscard]] Notifier &notifier();
}
