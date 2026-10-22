#include "metadata/MetadataSwitch.hpp"

#include <atomic>

namespace
{
std::atomic<bool> gEnabled{true};
}

bool metadata_switch::enabled()
{
    return gEnabled.load(std::memory_order_relaxed);
}

void metadata_switch::setEnabled(bool value)
{
    if (gEnabled.exchange(value, std::memory_order_relaxed) != value) {
        emit notifier().enabledChanged(value);
    }
}

metadata_switch::Notifier &metadata_switch::notifier()
{
    static Notifier instance;
    return instance;
}
