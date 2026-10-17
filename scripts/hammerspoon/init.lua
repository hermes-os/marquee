-- Marquee home theater remote bridge.
-- Satechi R2 buttons arrive as Bluetooth HID key events. Hammerspoon translates
-- those events into Marquee keyboard navigation and Roku ECP commands.

-- ============ CAPTURE MODE ============
-- Set this to true to log every key press to the Hammerspoon console.
-- Press each R2 button in Media mode, then repeat in Presenter mode if you
-- want to use the hardware side switch as a Marquee-vs-Roku router.
local CAPTURE_MODE = false

-- ============ USER SETUP ============
-- Copy config.example.lua to ~/.hammerspoon/marquee-remote.local.lua and set a
-- fallback Roku address if SSDP discovery isn't reliable on the local network.
local configLoaded, userConfig = pcall(
  dofile,
  hs.configdir .. "/marquee-remote.local.lua"
)
if not configLoaded or type(userConfig) ~= "table" then
  userConfig = {}
end

local ROKU_IP_DEFAULT = userConfig.rokuIP
local TV_INPUT = "InputHDMI1"
local TV_INPUT_ACTIVE_APP_ID = "tvinput.hdmi1"
local TV_POWER_RETRY_DELAYS = {0.0, 0.9, 2.1}
local TV_INPUT_RETRY_DELAYS = {1.0, 2.5, 4.5, 7.0, 10.0, 13.5}
local MARQUEE_APP_NAME = "Marquee"
local MARQUEE_BUNDLE_ID = "com.marquee.app"
local STEAM_APP_NAME = "Steam"
local MUSIC_APP_NAME = "Music"

local MODE_FILE = "/tmp/marquee-mode"
local KEYBOARD_LONG_PRESS_SECONDS = 1.0
local HOME_LONG_PRESS_SECONDS = 2.0
local ENABLE_PRESENTER_ROKU_MODE = true
local CAPTURE_UNKNOWN_SYSTEM_EVENTS = false
local PRESENTER_SELECT_KEY = "f18"
local R2_REMOTE_HID_MATCHING = '{"VendorID":0x1915,"ProductID":0xeeee,"PrimaryUsagePage":1,"PrimaryUsage":6}'
local R2_REMOTE_RETURN_TO_F18_MAPPING = '{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":0x700000028,"HIDKeyboardModifierMappingDst":0x70000006D}]}'
local R2_REMAP_REFRESH_SECONDS = 300

local runtime = rawget(_G, "MarqueeRemoteRuntime")
if runtime then
  if runtime.remoteTap then pcall(function() runtime.remoteTap:stop() end) end
  if runtime.watchdog then pcall(function() runtime.watchdog:stop() end) end
  if runtime.discoveryTimer then pcall(function() runtime.discoveryTimer:stop() end) end
  if runtime.presenterSelectRemapTimer then pcall(function() runtime.presenterSelectRemapTimer:stop() end) end
  if runtime.hotkeys then
    for _, hotkey in ipairs(runtime.hotkeys) do
      pcall(function() hotkey:delete() end)
    end
  end
end

runtime = {
  hotkeys = {},
  loadedAt = os.date("%Y-%m-%d %H:%M:%S"),
  tapRestarts = 0,
}
_G.MarqueeRemoteRuntime = runtime

pcall(function()
  require("hs.ipc")
  if hs.ipc and hs.ipc.cliInstall then
    hs.ipc.cliInstall()
  end
end)

-- Fill these in after running CAPTURE_MODE and pressing each R2 button.
-- Common values: "SOUND_UP", "SOUND_DOWN", "PLAY", "NEXT", "PREVIOUS", "MUTE"
local SYS_KEY_MAP = {
  up    = "SOUND_UP",
  down  = "SOUND_DOWN",
  left  = "PREVIOUS",
  right = "NEXT",
  play  = "PLAY",
  mute  = "MUTE",
  home  = "POWER",
  keyboard = "EJECT",
  mic   = nil,
}

-- Key names can vary slightly across macOS/Hammerspoon versions, but the R2's
-- system-defined key codes were stable in capture mode on this setup.
local SYS_KEY_CODE_MAP = {
  [0] = "up",
  [1] = "down",
  [18] = "left",
  [17] = "right",
  [16] = "play",
  [7] = "mute",
  [6] = "home",
  [14] = "keyboard",
}

-- Optional fallback for buttons that emit ordinary keystrokes instead of
-- system-defined media keys. The captured R2 emits POWER/EJECT as system keys,
-- so these stay disabled to avoid hijacking normal Cmd+H or F4 behavior.
local HOTKEY_MAP = {
  home = nil,
  keyboard = nil,
}

-- Presenter mode emits ordinary keyboard events on many R2 revisions. Keep
-- this disabled until capture mode confirms this specific remote's key names;
-- otherwise Hammerspoon would steal normal Mac keys globally.
local PRESENTER_ROKU_HOTKEY_MAP = {
  up = nil,      -- Example after capture: { mods = {}, key = "pageup" }
  down = nil,    -- Example after capture: { mods = {}, key = "pagedown" }
  left = nil,
  right = nil,
  select = nil,
  back = nil,
  home = nil,
  play = nil,
}

local rokuIP = ROKU_IP_DEFAULT
local homeButtonDownAt = nil
local keyboardButtonDownAt = nil

local function log(message)
  pcall(print, os.date("%Y-%m-%d %H:%M:%S") .. " [MarqueeRemote] " .. message)
end

local function executablePython()
  local candidates = {"/usr/bin/python3", "/usr/local/bin/python3"}
  for _, path in ipairs(candidates) do
    if hs.fs.attributes(path) then
      return path
    end
  end
  return "/usr/bin/python3"
end

-- SSDP discovery is the primary Roku lookup path when a stable fallback address
-- isn't configured.
local function discoverRoku()
  local pythonScript = [[
import socket
msg = b'M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: "ssdp:discover"\r\nMX: 2\r\nST: roku:ecp\r\n\r\n'
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 2)
s.settimeout(3)
s.sendto(msg, ("239.255.255.250", 1900))
try:
  while True:
    data, addr = s.recvfrom(1024)
    if b"roku" in data.lower():
      print(addr[0])
      break
except socket.timeout:
  pass
]]
  local task = hs.task.new(executablePython(), function(exitCode, stdOut, stdErr)
    if exitCode == 0 and stdOut and #stdOut > 0 then
      local ip = stdOut:match("(%d+%.%d+%.%d+%.%d+)")
      if ip then
        rokuIP = ip
        log("Discovered Roku at " .. ip)
      end
    elseif stdErr and #stdErr > 0 then
      log("Roku discovery error: " .. stdErr:gsub("%s+$", ""))
    end
  end, {"-c", pythonScript})
  task:start()
end

discoverRoku()
runtime.discoveryTimer = hs.timer.doEvery(3600, discoverRoku)

local function runAfter(delay, fn)
  if delay <= 0 then
    fn()
  else
    hs.timer.doAfter(delay, fn)
  end
end

local function shallowCopy(tableValue)
  local result = {}
  for key, value in pairs(tableValue or {}) do
    result[key] = value
  end
  return result
end

local function applyR2PresenterSelectRemap(reason)
  local task = hs.task.new("/usr/bin/hidutil", function(exitCode, stdOut, stdErr)
    if exitCode == 0 then
      runtime.presenterSelectRemap = "applied " .. tostring(reason)
      runtime.presenterSelectRemapAt = os.date("%Y-%m-%d %H:%M:%S")
      return
    end

    runtime.presenterSelectRemap = "failed " .. tostring(reason) .. " exit " .. tostring(exitCode)
    log("R2 presenter Select remap failed: " .. tostring(stdErr or stdOut or exitCode))
  end, {
    "property",
    "--matching", R2_REMOTE_HID_MATCHING,
    "--set", R2_REMOTE_RETURN_TO_F18_MAPPING,
  })
  task:start()
end

applyR2PresenterSelectRemap("config load")
runtime.presenterSelectRemapTimer = hs.timer.doEvery(R2_REMAP_REFRESH_SECONDS, function()
  applyR2PresenterSelectRemap("refresh")
end)

local function rokuPostPath(path, label, options)
  options = options or {}
  if not rokuIP then
    log("Roku address unavailable for " .. label .. "; starting discovery")
    discoverRoku()
    if options.onComplete then options.onComplete(false, nil) end
    return
  end
  local attempt = options.attempt or 1
  local maxAttempts = options.maxAttempts or 2
  hs.http.asyncPost(
    "http://" .. rokuIP .. ":8060" .. path,
    "",
    {},
    function(status, body, headers)
      if status ~= 200 then
        log("Roku command failed for " .. label .. " attempt " .. tostring(attempt) ..
            " (status " .. tostring(status) .. "), re-discovering")
        discoverRoku()
        if attempt < maxAttempts then
          local retryOptions = shallowCopy(options)
          retryOptions.attempt = attempt + 1
          runAfter(0.45 * attempt, function()
            rokuPostPath(path, label, retryOptions)
          end)
          return
        end
        if options.onComplete then options.onComplete(false, status) end
        return
      end
      if options.onComplete then options.onComplete(true, status) end
    end
  )
end

local function rokuPress(key, options)
  rokuPostPath("/keypress/" .. key, key, options)
end

local function rokuLaunchApp(appID, options)
  rokuPostPath("/launch/" .. appID, "launch " .. appID, options)
end

local function queryRokuActiveApp(callback, attempt)
  attempt = attempt or 1
  if not rokuIP then
    log("Roku address unavailable for active-app query; starting discovery")
    discoverRoku()
    callback(false, nil)
    return
  end
  hs.http.asyncGet(
    "http://" .. rokuIP .. ":8060/query/active-app",
    {},
    function(status, body, headers)
      if status ~= 200 then
        log("Roku active input query failed attempt " .. tostring(attempt) ..
            " (status " .. tostring(status) .. "), re-discovering")
        discoverRoku()
        if attempt < 2 then
          runAfter(0.5, function()
            queryRokuActiveApp(callback, attempt + 1)
          end)
          return
        end
        callback(false, nil)
        return
      end
      callback(true, body or "")
    end
  )
end

local function bodyShowsTVInputActive(body)
  local text = string.lower(body or "")
  return string.find(text, TV_INPUT_ACTIVE_APP_ID, 1, true) ~= nil
end

local function selectTVInputIfNeeded(reason)
  reason = reason or "unspecified"
  runtime.lastTVEnsure = os.date("%Y-%m-%d %H:%M:%S") .. " " .. reason

  for attempt, delay in ipairs(TV_POWER_RETRY_DELAYS) do
    runAfter(delay, function()
      rokuPress("PowerOn", { maxAttempts = 2 })
      runtime.lastTVPower = "PowerOn attempt " .. tostring(attempt) .. " for " .. reason
    end)
  end

  for attempt, delay in ipairs(TV_INPUT_RETRY_DELAYS) do
    runAfter(delay, function()
      queryRokuActiveApp(function(ok, body)
        if ok and bodyShowsTVInputActive(body) then
          runtime.lastTVInput = "already active after attempt " .. tostring(attempt) ..
              " for " .. reason
          return
        end

        runtime.lastTVInput = "sent " .. TV_INPUT .. " attempt " .. tostring(attempt) ..
            " for " .. reason
        rokuPress(TV_INPUT, { maxAttempts = 2 })
        rokuLaunchApp(TV_INPUT_ACTIVE_APP_ID, { maxAttempts = 2 })
      end)
    end)
  end
end

local function frontAppName()
  local app = hs.application.frontmostApplication()
  return app and app:name() or ""
end

local function appIdentityMatches(app, expectedName, expectedBundleID)
  if not app then return false end

  local nameOk, appName = pcall(function() return app:name() end)
  if nameOk and appName == expectedName then return true end

  if expectedBundleID then
    local bundleOk, bundleID = pcall(function() return app:bundleID() end)
    if bundleOk and bundleID == expectedBundleID then return true end
  end

  return false
end

local function runningApp(expectedName, expectedBundleID)
  for _, app in ipairs(hs.application.runningApplications()) do
    if appIdentityMatches(app, expectedName, expectedBundleID) then
      return app
    end
  end
  return nil
end

local function marqueeApp()
  return runningApp(MARQUEE_APP_NAME, MARQUEE_BUNDLE_ID)
end

local function activateApp(name, bundleID)
  if bundleID then
    hs.application.launchOrFocusByBundleID(bundleID)
  else
    hs.application.launchOrFocus(name)
  end
  local app = runningApp(name, bundleID)
  if app then
    app:activate(true)
  end
  return app
end

local function marqueeIsRunning()
  return marqueeApp() ~= nil
end

local function marqueeIsFrontmost()
  return frontAppName() == MARQUEE_APP_NAME
end

local function marqueeMode()
  local file = io.open(MODE_FILE, "r")
  if not file then return "browsing" end
  local value = file:read("*l")
  file:close()
  if value == "playing" then return "playing" end
  return "browsing"
end

local function writeMarqueeMode(mode)
  local tmp = MODE_FILE .. ".hammerspoon"
  local file = io.open(tmp, "w")
  if not file then return end
  file:write(mode .. "\n")
  file:close()
  os.rename(tmp, MODE_FILE)
end

local function context()
  local name = frontAppName()
  if name == MARQUEE_APP_NAME then
    return marqueeMode()
  elseif marqueeIsRunning() then
    return marqueeMode()
  elseif name == STEAM_APP_NAME then
    return "steam"
  elseif name == MUSIC_APP_NAME then
    return "music"
  end
  return "idle"
end

local function stroke(key)
  hs.eventtap.keyStroke({}, key, 0)
end

local function marqueeWindow()
  local app = marqueeApp()
  if not app then return nil end

  local win = app:mainWindow() or app:focusedWindow()
  if win then return win end

  for _, candidate in ipairs(app:allWindows()) do
    local ok, standard = pcall(function() return candidate:isStandard() end)
    if ok and standard then
      return candidate
    end
  end
  return nil
end

local function marqueeWindowIsFullscreen()
  local win = marqueeWindow()
  if not win then return false end
  local ok, fullscreen = pcall(function() return win:isFullScreen() end)
  return ok and fullscreen == true
end

local function marqueeReadyForRemoteSelect()
  return marqueeIsFrontmost() and marqueeWindowIsFullscreen()
end

local function focusMarquee(forceFullscreen, afterFocus)
  activateApp(MARQUEE_APP_NAME, MARQUEE_BUNDLE_ID)
  local attempts = 0

  local function tryFocus()
    attempts = attempts + 1
    local app = marqueeApp()
    if app then
      app:activate(true)
    end

    local win = marqueeWindow()
    if win then
      pcall(function()
        if win:isMinimized() then win:unminimize() end
      end)
      pcall(function() win:raise() end)
      pcall(function() win:focus() end)
      if forceFullscreen then
        local fullscreenOk, isFullscreen = pcall(function() return win:isFullScreen() end)
        if (not fullscreenOk) or (not isFullscreen) then
          pcall(function() win:setFullScreen(true) end)
        end
      end

      if afterFocus then
        hs.timer.doAfter(forceFullscreen and 0.9 or 0.1, afterFocus)
      end
      return
    end

    if attempts < 12 then
      hs.timer.doAfter(0.25, tryFocus)
    elseif afterFocus then
      afterFocus()
    end
  end

  hs.timer.doAfter(0.15, tryFocus)
end

local function postKeyToMarqueeApp(key, isDown)
  local app = marqueeApp()
  local event = hs.eventtap.event.newKeyEvent({}, key, isDown)
  if app then
    event:post(app)
  else
    event:post()
  end
end

local function postKeyMarquee(key, isDown)
  if marqueeIsFrontmost() then
    postKeyToMarqueeApp(key, isDown)
    return
  end

  focusMarquee(false, function()
    postKeyToMarqueeApp(key, isDown)
  end)
end

local function tapMarqueeKey(key)
  if marqueeIsFrontmost() then
    postKeyToMarqueeApp(key, true)
    hs.timer.doAfter(0.02, function()
      postKeyToMarqueeApp(key, false)
    end)
    return
  end

  focusMarquee(false, function()
    postKeyToMarqueeApp(key, true)
    hs.timer.doAfter(0.02, function()
      postKeyToMarqueeApp(key, false)
    end)
  end)
end

local function quitApp(name)
  local script = 'tell application "' .. name .. '" to quit'
  local task = hs.task.new("/usr/bin/osascript", function() end, {"-e", script})
  task:start()
  hs.timer.doAfter(1, function()
    pcall(function()
      if task and task:isRunning() then
        task:terminate()
      end
    end)
  end)
end

local function launchMarquee(afterFocus)
  selectTVInputIfNeeded("launchMarquee")
  focusMarquee(true, afterFocus)
end

local function launchMarqueeFromPlayButton()
  log("Center play routed to Marquee launcher: PowerOn + " .. TV_INPUT .. " + " .. MARQUEE_APP_NAME)
  launchMarquee()
end

local function launchSteamBigPicture()
  selectTVInputIfNeeded("launchSteamBigPicture")
  hs.execute("/usr/bin/open steam://open/bigpicture >/dev/null 2>&1 &", true)
  hs.timer.doAfter(2.5, function()
    activateApp(STEAM_APP_NAME)
  end)
end

local function launchMusic()
  selectTVInputIfNeeded("launchMusic")
  hs.execute("/usr/bin/open -a Music >/dev/null 2>&1 &", true)
  hs.timer.doAfter(1.0, function()
    activateApp(MUSIC_APP_NAME)
    hs.eventtap.keyStroke({"cmd", "ctrl"}, "f", 0)
  end)
end

local function bedtime()
  writeMarqueeMode("browsing")
  quitApp(MARQUEE_APP_NAME)
  quitApp(STEAM_APP_NAME)
  quitApp(MUSIC_APP_NAME)
  hs.timer.doAfter(0.2, function() rokuPress("PowerOff") end)
  hs.timer.doAfter(0.6, function()
    hs.execute("/usr/bin/pmset displaysleepnow >/dev/null 2>&1 &", true)
  end)
end

local function handleHomeShort()
  local ctx = context()
  if ctx == "playing" then
    tapMarqueeKey("escape")
  elseif ctx == "browsing" then
    tapMarqueeKey("escape")
  elseif ctx == "idle" then
    rokuPress("Home")
  elseif ctx == "steam" then
    quitApp(STEAM_APP_NAME)
    rokuPress("Home")
  elseif ctx == "music" then
    quitApp(MUSIC_APP_NAME)
    rokuPress("Home")
  end
end

local function handleKeyboardShortcut(isLongPress)
  local ctx = context()
  if isLongPress then
    if ctx == "music" then
      launchSteamBigPicture()
    else
      launchMusic()
    end
  else
    if ctx == "steam" or ctx == "music" then
      launchMarquee()
    else
      launchSteamBigPicture()
    end
  end
end

local function handleHomeSystem(isDown, isRepeat)
  if isRepeat then return true end
  if isDown then
    homeButtonDownAt = hs.timer.secondsSinceEpoch()
    return true
  end

  local started = homeButtonDownAt
  homeButtonDownAt = nil
  if not started then return true end

  if hs.timer.secondsSinceEpoch() - started >= HOME_LONG_PRESS_SECONDS then
    bedtime()
  else
    handleHomeShort()
  end
  return true
end

local function handleKeyboardSystem(isDown, isRepeat)
  if isRepeat then return true end
  if isDown then
    keyboardButtonDownAt = hs.timer.secondsSinceEpoch()
    return true
  end

  local started = keyboardButtonDownAt
  keyboardButtonDownAt = nil
  if not started then return true end

  handleKeyboardShortcut(hs.timer.secondsSinceEpoch() - started >= KEYBOARD_LONG_PRESS_SECONDS)
  return true
end

local ROKU_PRESENTER_ACTIONS = {
  up = "Up",
  down = "Down",
  left = "Left",
  right = "Right",
  select = "Select",
  back = "Back",
  home = "Home",
  play = "Play",
}

local function handlePresenterRokuAction(action)
  local rokuKey = ROKU_PRESENTER_ACTIONS[action]
  if not rokuKey then return end
  rokuPress(rokuKey)
end

local function actionForSystemEvent(sys)
  for action, mappedKey in pairs(SYS_KEY_MAP) do
    if mappedKey and mappedKey == sys.key then
      return action
    end
  end
  return SYS_KEY_CODE_MAP[sys.keyCode]
end

local function captureSystemEvent(sys, event)
  local raw = nil
  pcall(function() raw = event:getRawEventData() end)
  local rawFlags = nil
  pcall(function() rawFlags = event:rawFlags() end)
  log("systemDefined key=" .. tostring(sys.key) ..
      " keyCode=" .. tostring(sys.keyCode) ..
      " down=" .. tostring(sys.down) ..
      " repeat=" .. tostring(sys["repeat"]) ..
      " rawFlags=" .. tostring(rawFlags) ..
      " raw=" .. hs.inspect(raw))
end

local function captureKeyEvent(label, event)
  local chars = ""
  pcall(function() chars = event:getCharacters() or "" end)
  local keyCode = event:getKeyCode()
  local keyName = hs.keycodes.map[keyCode] or tostring(keyCode)
  local rawFlags = nil
  pcall(function() rawFlags = event:rawFlags() end)
  local keyboardType = nil
  pcall(function() keyboardType = event:getProperty(hs.eventtap.event.properties.keyboardEventKeyboardType) end)
  local raw = nil
  pcall(function() raw = event:getRawEventData() end)
  log(label .. " key=" .. tostring(keyName) ..
      " keyCode=" .. tostring(keyCode) ..
      " flags=" .. hs.inspect(event:getFlags()) ..
      " rawFlags=" .. tostring(rawFlags) ..
      " keyboardType=" .. tostring(keyboardType) ..
      " chars=" .. tostring(chars) ..
      " raw=" .. hs.inspect(raw))
end

local function isRemoteCaptureKeyEvent(event)
  local keyCode = event:getKeyCode()
  local keyName = hs.keycodes.map[keyCode] or tostring(keyCode)
  local flags = event:getFlags()
  local fnOnly = flags.fn == true
      and not flags.cmd
      and not flags.alt
      and not flags.ctrl
      and not flags.shift

  return (fnOnly and (keyName == "up" or keyName == "down" or keyName == "left" or keyName == "right"))
      or keyName == "return"
      or keyName == PRESENTER_SELECT_KEY
end

local function presenterActionForKeyEvent(event)
  local keyCode = event:getKeyCode()
  local keyName = hs.keycodes.map[keyCode] or tostring(keyCode)
  local flags = event:getFlags()
  local fnOnly = flags.fn == true
      and not flags.cmd
      and not flags.alt
      and not flags.ctrl
      and not flags.shift

  if fnOnly then
    if keyName == "up" then return "up" end
    if keyName == "down" then return "down" end
    if keyName == "left" then return "left" end
    if keyName == "right" then return "right" end
  end

  -- Presenter center emits plain Return at the Hammerspoon layer. This config
  -- applies a device-scoped hidutil remap for the R2 Remote only, converting
  -- that Return usage to F18 so normal keyboards keep their Return behavior.
  if keyName == PRESENTER_SELECT_KEY
      and not flags.cmd
      and not flags.alt
      and not flags.ctrl
      and not flags.shift then
    return "select"
  end

  return nil
end

local function handlePresenterKeyEvent(event, isDown)
  if not ENABLE_PRESENTER_ROKU_MODE then return false end

  local action = presenterActionForKeyEvent(event)
  if not action then return false end

  local keyName = hs.keycodes.map[event:getKeyCode()] or tostring(event:getKeyCode())

  runtime.lastAction = "presenter-" .. action
  runtime.lastContext = context()
  runtime.lastEventAt = os.date("%Y-%m-%d %H:%M:%S")
  runtime.lastSystemKey = keyName
  runtime.lastSystemKeyCode = event:getKeyCode()

  if isDown then
    log("route presenter action=" .. tostring(action) .. " key=" .. tostring(keyName))
    handlePresenterRokuAction(action)
  end

  return true
end

local function handleMarqueeBrowsing(action, isDown, isRepeat)
  if not isDown then return true end
  if action == "up" then
    tapMarqueeKey("up")
    return true
  end
  if action == "down" then
    tapMarqueeKey("down")
    return true
  end
  if action == "left" then tapMarqueeKey("left"); return true end
  if action == "right" then tapMarqueeKey("right"); return true end
  if action == "play" and not isRepeat then
    selectTVInputIfNeeded("marqueeBrowsingPlay")
    if marqueeReadyForRemoteSelect() then
      tapMarqueeKey("return")
    else
      focusMarquee(true, nil)
    end
    return true
  end
  if action == "mute" and not isRepeat then rokuPress("VolumeMute"); return true end
  return false
end

local function handleMarqueePlaying(action, isDown, isRepeat)
  if action == "up" then
    if isDown and isRepeat then
      rokuPress("VolumeUp")
    elseif isDown then
      tapMarqueeKey("up")
    end
    return true
  elseif action == "down" then
    if isDown and isRepeat then
      rokuPress("VolumeDown")
    elseif isDown then
      tapMarqueeKey("down")
    end
    return true
  elseif action == "left" then
    if not isRepeat then postKeyMarquee("left", isDown) end
    return true
  elseif action == "right" then
    if not isRepeat then postKeyMarquee("right", isDown) end
    return true
  elseif action == "play" then
    if isDown and not isRepeat then tapMarqueeKey("space") end
    return true
  elseif action == "mic" then
    if isDown and not isRepeat then stroke("s") end
    return true
  elseif action == "mute" then
    if isDown and not isRepeat then rokuPress("VolumeMute") end
    return true
  end
  return false
end

local function handleSteam(action, isDown, isRepeat)
  if not isDown then return true end
  if action == "up" then stroke("up"); return true end
  if action == "down" then stroke("down"); return true end
  if action == "left" then stroke("left"); return true end
  if action == "right" then stroke("right"); return true end
  if action == "play" and not isRepeat then stroke("return"); return true end
  if action == "mute" and not isRepeat then rokuPress("VolumeMute"); return true end
  return false
end

local function handleMusic(action, isDown, isRepeat)
  if action == "play" then
    if isDown and not isRepeat then
      launchMarqueeFromPlayButton()
    end
    return true
  end

  if action == "up" then
    if isDown then rokuPress("VolumeUp") end
    return true
  elseif action == "down" then
    if isDown then rokuPress("VolumeDown") end
    return true
  elseif action == "mute" then
    if isDown and not isRepeat then rokuPress("VolumeMute") end
    return true
  end
  return false
end

local function handleIdle(action, isDown, isRepeat)
  if action == "play" then
    if isDown and not isRepeat then
      launchMarqueeFromPlayButton()
    end
    return true
  end

  if not isDown or isRepeat then return true end
  if action == "up" then
    rokuPress("VolumeUp")
    return true
  elseif action == "down" then
    rokuPress("VolumeDown")
    return true
  elseif action == "mute" then
    rokuPress("VolumeMute")
    return true
  end
  return true
end

runtime.remoteTap = hs.eventtap.new({
  hs.eventtap.event.types.systemDefined,
  hs.eventtap.event.types.keyDown,
  hs.eventtap.event.types.keyUp,
}, function(event)
  local eventType = event:getType()

  if eventType == hs.eventtap.event.types.keyDown or eventType == hs.eventtap.event.types.keyUp then
    if CAPTURE_MODE then
      if isRemoteCaptureKeyEvent(event) then
        captureKeyEvent(eventType == hs.eventtap.event.types.keyDown and "keyDown" or "keyUp", event)
      end
      return false
    end
    return handlePresenterKeyEvent(event, eventType == hs.eventtap.event.types.keyDown)
  end

  local sys = event:systemKey()
  if not sys then return false end
  if CAPTURE_MODE then
    if sys.key or sys.keyCode or CAPTURE_UNKNOWN_SYSTEM_EVENTS then
      captureSystemEvent(sys, event)
    end
    return false
  end

  local action = actionForSystemEvent(sys)
  if not action then return false end

  if action == "home" then
    runtime.lastAction = action
    runtime.lastContext = context()
    runtime.lastEventAt = os.date("%Y-%m-%d %H:%M:%S")
    runtime.lastSystemKey = sys.key
    if sys.down and not sys["repeat"] then
      log("route action=home context=" .. runtime.lastContext .. " key=" .. tostring(sys.key))
    end
    return handleHomeSystem(sys.down, sys["repeat"])
  elseif action == "keyboard" then
    runtime.lastAction = action
    runtime.lastContext = context()
    runtime.lastEventAt = os.date("%Y-%m-%d %H:%M:%S")
    runtime.lastSystemKey = sys.key
    if sys.down and not sys["repeat"] then
      log("route action=keyboard context=" .. runtime.lastContext .. " key=" .. tostring(sys.key))
    end
    return handleKeyboardSystem(sys.down, sys["repeat"])
  end

  local ctx = context()
  runtime.lastAction = action
  runtime.lastContext = ctx
  runtime.lastEventAt = os.date("%Y-%m-%d %H:%M:%S")
  runtime.lastSystemKey = sys.key
  runtime.lastSystemKeyCode = sys.keyCode
  if sys.down and not sys["repeat"] then
    log("route action=" .. tostring(action) .. " context=" .. ctx .. " key=" .. tostring(sys.key))
  end
  if ctx == "browsing" then
    return handleMarqueeBrowsing(action, sys.down, sys["repeat"])
  elseif ctx == "playing" then
    return handleMarqueePlaying(action, sys.down, sys["repeat"])
  elseif ctx == "steam" then
    return handleSteam(action, sys.down, sys["repeat"])
  elseif ctx == "music" then
    return handleMusic(action, sys.down, sys["repeat"])
  else
    return handleIdle(action, sys.down, sys["repeat"])
  end
end)

local function remoteTapEnabled()
  if not runtime.remoteTap then return false end
  local ok, enabled = pcall(function() return runtime.remoteTap:isEnabled() end)
  return ok and enabled == true
end

local function startRemoteTap(reason)
  if not runtime.remoteTap then return end
  if remoteTapEnabled() then return end
  runtime.remoteTap:start()
  runtime.tapRestarts = runtime.tapRestarts + 1
  log("Remote media-key tap started" .. (reason and (" (" .. reason .. ")") or ""))
end

startRemoteTap("config load")

runtime.watchdog = hs.timer.doEvery(5, function()
  local secureOk, secureInput = pcall(function() return hs.eventtap.isSecureInputEnabled() end)
  runtime.secureInput = secureOk and secureInput == true
  if runtime.secureInput then
    runtime.lastWatchdog = "secure input active"
    return
  end
  if not remoteTapEnabled() then
    runtime.lastWatchdog = "tap disabled; restarting"
    startRemoteTap("watchdog")
  else
    runtime.lastWatchdog = "tap enabled"
  end
end)

if HOTKEY_MAP.home then
  local homeHotkey = hs.hotkey.bind(HOTKEY_MAP.home.mods, HOTKEY_MAP.home.key, function()
    if CAPTURE_MODE then
      log("hotkey home down mods=" .. hs.inspect(HOTKEY_MAP.home.mods) .. " key=" .. HOTKEY_MAP.home.key)
      return
    end
    homeButtonDownAt = hs.timer.secondsSinceEpoch()
  end, function()
    if CAPTURE_MODE then
      log("hotkey home up mods=" .. hs.inspect(HOTKEY_MAP.home.mods) .. " key=" .. HOTKEY_MAP.home.key)
      return
    end
    local started = homeButtonDownAt
    homeButtonDownAt = nil
    if not started then return end
    if hs.timer.secondsSinceEpoch() - started >= HOME_LONG_PRESS_SECONDS then
      bedtime()
    else
      handleHomeShort()
    end
  end)
  table.insert(runtime.hotkeys, homeHotkey)
end

if HOTKEY_MAP.keyboard then
  local keyboardHotkey = hs.hotkey.bind(HOTKEY_MAP.keyboard.mods, HOTKEY_MAP.keyboard.key, function()
    if CAPTURE_MODE then
      log("hotkey keyboard down mods=" .. hs.inspect(HOTKEY_MAP.keyboard.mods) .. " key=" .. HOTKEY_MAP.keyboard.key)
      return
    end
    keyboardButtonDownAt = hs.timer.secondsSinceEpoch()
  end, function()
    if CAPTURE_MODE then
      log("hotkey keyboard up mods=" .. hs.inspect(HOTKEY_MAP.keyboard.mods) .. " key=" .. HOTKEY_MAP.keyboard.key)
      return
    end
    local started = keyboardButtonDownAt
    keyboardButtonDownAt = nil
    if not started then return end
    handleKeyboardShortcut(hs.timer.secondsSinceEpoch() - started >= KEYBOARD_LONG_PRESS_SECONDS)
  end)
  table.insert(runtime.hotkeys, keyboardHotkey)
end

if ENABLE_PRESENTER_ROKU_MODE then
  for action, spec in pairs(PRESENTER_ROKU_HOTKEY_MAP) do
    if spec and spec.key then
      local hotkey = hs.hotkey.bind(spec.mods or {}, spec.key, function()
        if CAPTURE_MODE then
          log("presenter roku hotkey action=" .. tostring(action) ..
              " mods=" .. hs.inspect(spec.mods or {}) ..
              " key=" .. tostring(spec.key))
          return
        end
        handlePresenterRokuAction(action)
      end)
      table.insert(runtime.hotkeys, hotkey)
    end
  end
end

runtime.status = function()
  local accessOk, accessibility = pcall(function() return hs.accessibilityState(false) end)
  local secureOk, secureInput = pcall(function() return hs.eventtap.isSecureInputEnabled() end)
  return {
    loadedAt = runtime.loadedAt,
    captureMode = CAPTURE_MODE,
    presenterRokuMode = ENABLE_PRESENTER_ROKU_MODE,
    presenterSelectKey = PRESENTER_SELECT_KEY,
    presenterSelectRemap = runtime.presenterSelectRemap,
    presenterSelectRemapAt = runtime.presenterSelectRemapAt,
    accessibility = accessOk and accessibility == true,
    secureInput = secureOk and secureInput == true,
    tapEnabled = remoteTapEnabled(),
    tapRestarts = runtime.tapRestarts,
    lastWatchdog = runtime.lastWatchdog,
    lastEventAt = runtime.lastEventAt,
    lastAction = runtime.lastAction,
    lastContext = runtime.lastContext,
    lastSystemKey = runtime.lastSystemKey,
    lastSystemKeyCode = runtime.lastSystemKeyCode,
    lastTVInput = runtime.lastTVInput,
    currentContext = context(),
    frontApp = frontAppName(),
    marqueeRunning = marqueeIsRunning(),
    marqueeReadyForRemoteSelect = marqueeReadyForRemoteSelect(),
    marqueeMode = marqueeMode(),
    rokuIP = rokuIP,
  }
end

local rokuMode = ROKU_IP_DEFAULT and "configured fallback plus SSDP" or "SSDP discovery only"
log("Loaded Satechi R2 bridge for Marquee. Roku mode: " .. rokuMode ..
    ". Capture mode: " .. tostring(CAPTURE_MODE))
