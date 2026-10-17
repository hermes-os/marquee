#!/usr/bin/env bash
set -euo pipefail

# The Satechi R2 Presenter center button emits the same Return key event as a
# normal keyboard once it reaches Hammerspoon. macOS still exposes the R2 as a
# separate HID service, so remap only that device's Return usage to F18.
MATCHING='{"VendorID":0x1915,"ProductID":0xeeee,"PrimaryUsagePage":1,"PrimaryUsage":6}'
MAPPING='{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":0x700000028,"HIDKeyboardModifierMappingDst":0x70000006D}]}'

/usr/bin/hidutil property --matching "${MATCHING}" --set "${MAPPING}"
/usr/bin/hidutil property --matching "${MATCHING}" --get UserKeyMapping
