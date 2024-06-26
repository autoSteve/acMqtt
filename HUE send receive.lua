--[[ CHANGE TO SUIT ENVIRONMENT --]]
local bridge = '192.168.10.15'
local checkForChanges = true       -- When true the script will periodically check for create/update/delete of object keywords (disable to lower CPU load)
local checkChanges = 30            -- Interval in seconds to check for changes to object keywords

--[[
Gateway between an Automation Controller and Philips Hue bridge

Script: 'HUE send receive', resident zero sleep

Permission to use/modify freely is granted, and acknowledging the author or sending beer would be nice.

>>> HUE

For Philips Hue devices, bi-directional sync with CBus occurs. Add the keyword 'HUE' to CBus objects, plus...
  pn= Preferred name (which needs to match exactly the name of the Hue device.)

Keyword examples:

HUE, pn=Steve's bedside light
HUE, pn=Steve's electric blanket

A useful result is that Philips Hue devices can then be added to CBus scenes, like an 'All off' function.

The CBus groups for Hue devices are usually not used for any purpose other than controlling their Hue device.
Turning on/off one of these groups will result in the Philips Hue hub turning the loads on/off. It is possible
that these CBus Hue groups could be used to also control CBus loads, giving them dual purpose.

Ramping in CBus is by way of selecting a 'ramp rate'. This is not the same as 'transition time' for Philips Hue.
A translation of ramp rate to an approximate transition time for Hue devices is done to align CBus level with
that of the Hue device. A CBus ramp rate is the time to transition from fully off to on (0->255), so to ramp
from 0->127 using a ramp rate of eight seconds will take just four seconds to transition.

Note: This script only handles on/off, as well as levels for dimmable Hue devices, but not colours/colour
temperature, as that's not a CBus thing. Colour details will return to previously set values done in the Hue app.

While executing a CBus ramp the status of lamps in HomeAssistant will not match the actual hue bulb state. This
is likely because the Hue event stream does not provide notification that a transition from one state to another
is occurring, and so HomeAssistant adjusts its status as updates during the transition are received. This looks
a little crazy, especially when triggering a CBus scene from HomeAssistant but it works.

### Known issues ###
- Ramp on/off of a CBus group address is unreliable at present. See https://github.com/autoSteve/acMqtt/issues/19.
--]]

-- Runtime global variable checking. Globals must be explicitly declared, which will catch variable name typos
local declaredNames = {['vprint'] = true, ['vprinthex'] = true, ['maxgroup'] = true, ['ssl'] = true}
local function declare(name, initval) rawset(_G, name, initval) declaredNames[name] = true end
local exclude = {['ngx'] = true, }
setmetatable(_G, {
  __newindex = function (t, n, v) if not declaredNames[n] then log('Warning: Write to undeclared global variable "'..n..'"') end rawset(t, n, v) end,
  __index = function (_, n) if not exclude[n] and not declaredNames[n] then log('Warning: Read undeclared global variable "'..n..'"') end return nil end,
})

local logging = false        -- Enable detailed logging
local logms = false          -- Include timestamp in milliseconds for logs

local eventStream = '/eventstream/clip/v2'
local resource = '/clip/v2/resource'
local connectivity = '/clip/v2/resource/zigbee_connectivity'
local clientKeyStorage = 'huesendreceive'
local clientKey

local busTimeout = 0.1       -- Lower = higher CPU, higher = less responsiveness - both timeouts often occur each main loop
local bridgeTimeout = 0.1    -- Lower = higher CPU, higher = less responsiveness
local ignoreTimeout = 8      -- Timeout for stale ignore messages in seconds (eight seconds is a long time, but it happens...)
local minHueBri = 0.39       -- Transitioning a Hue light arrives at a low brightness level, with the lamp then turned off 
local retryDelay = 10        -- If there's an error getting resources using REST then delay and try again (tolerate bridge restarts)
local rampTimeout = 3        -- Time beyond ramp to declare an orphan in seconds
local pendingTimeout = 10    -- Time beyond pending end ramp to declare an orphan in seconds (occasionally the eventstream updates are quite delayed from lights)
local sendHeartbeat = 30     -- Send a heartbeat to the 'Heartbeat' script every n seconds (zero to disable heartbeat)
local heartbeatConditions = { ['max'] = 120, ['storageExists'] = 'hueactive' }  -- At most two minutes without a heartbeat or else restart, but only if hueactive exists

local huePort = 5435         -- Listening port to receive messages from 'HUE' and 'HUE final' scripts
local port = 443             -- Listening port of the Hue bridge
local protocol = 'tlsv12'    -- TLS 1.2 is used for bridge eventstream

local hue = {}               -- Hue device details (name, state, dimmable, etc) 
local hueDevices = {}        -- Quick lookup to determine whether an object is a Hue device
local hueDeviceStatus = {}   -- Hue device status
local hueConnected = false   -- Event stream is being received
local hueIds = {}            -- Lookup Hue object ID using metadata name
local hueV1Ids = {}          -- Lookup Hue object V1 ID using metadata name
local cbusMessages = {}      -- Incoming message queue
local bridgeMessages = {}    -- Incoming message queue
local ignoreCbus = {}        -- To prevent message loops
local ignoreBridge = {}      -- To prevent message loops
local ramp = {}              -- Keeps track of CBus ramping
local pendingEndRamp = {}    -- Keeps track of the end of Hue transition (always occurs after the CBus ramp conclusion is reported)
local nonTargetUpdate = {}   -- Watch for non-ramp target Hue updates 

local FORCE = true

local lastLevel = storage.get('lastlvlhue', {})

local started = socket.gettime()

local function logger(msg, force) local ts if logging or force then if logms then ts = string.format('%.3f ', socket.gettime()-started) else ts = '' end log(ts..msg) end end -- Log helper
local function len(dict) local i = 0; local k; for k, _ in pairs(dict) do i = i + 1 end return(i) end -- Get number of dictionary members
local function equals(o1, o2, ignoreMt)
  if ignoreMt == nil then ignoreMt = true end
  if o1 == o2 then return true end
  local o1Type = type(o1) local o2Type = type(o2)
  if o1Type ~= o2Type then return false end if o1Type ~= 'table' then return false end
  if not ignoreMt then local mt1 = getmetatable(o1) if mt1 and mt1.__eq then return o1 == o2 end end
  local keySet = {}
  for key1, value1 in pairs(o1) do local value2 = o2[key1] if value2 == nil or equals(value1, value2, ignoreMt) == false then return false end keySet[key1] = true end
  for key2, _ in pairs(o2) do if not keySet[key2] then return false end end
  return true
end


--[[
Register with the Heartbeat script
--]]
local function isRegistered() local hbeat = storage.get('heartbeat', {}); local k; for k, _ in pairs(hbeat) do if k == _SCRIPTNAME then return true, hbeat end end return false, hbeat end
if sendHeartbeat > 0 then
  -- Check whether registration is required, and if not registered (or conditions changed) then register
  local r, hbeat = isRegistered()
  if not r or (r and not equals(hbeat[_SCRIPTNAME], heartbeatConditions)) then
    local k, v, vals
    vals = '' for k, v in pairs(heartbeatConditions) do vals = vals..k..'='..v..' ' end
    logger('Registering '.._SCRIPTNAME..' with Heartbeat of '..vals, FORCE)
    hbeat[_SCRIPTNAME] = heartbeatConditions
    storage.set('heartbeat', hbeat)
  end
else -- Remove script from hearbeat registration
  local r, hbeat = isRegistered() if r then hbeat[_SCRIPTNAME] = nil storage.set('heartbeat', hbeat) end
end
local heartbeat = os.time()

storage.set('hueactive', nil) -- Initially not connected


--[[
C-Bus events. Queues various C-Bus messages
--]]
local function eventCallback(event)
  if hue[event.dst] then
    local value
    local ramp
    local parts = string.split(event.dst, '/')
    value = tonumber(string.sub(event.datahex,1,2),16)
    local target = tonumber(string.sub(event.datahex,3,4),16)
    local ramp = tonumber(string.sub(event.datahex,5,8),16)
    if ramp > 0 then
      if value == 0 then -- Queue ramp zero event
        cbusMessages[#cbusMessages + 1] = event.dst.."<"..value
        if logging then log('Setting '..event.dst..' to '..value..', previous='..hue[event.dst].value) end
      end
      if value ~= target then -- Queue intermediate level event
        cbusMessages[#cbusMessages + 1] = event.dst.."/"..value
        if logging then log('Setting '..event.dst..' to '..value..' (ramping), previous='..hue[event.dst].value) end
        return
      end
      if event.meta == 'admin' then return end
    end
    local pre, comp
    if type(value) == 'number' then
      if hue[event.dst].value ~= nil then pre = string.format('%.5f', hue[event.dst].value) else pre = nil end
      comp = string.format('%.5f', value)
    else
      pre = hue[event.dst].value
      comp = value
    end
    if comp == pre then -- Don't publish if already at the level
      if logging then log('Not setting '..event.dst..' to '..value..', same as previous value') end
      return
    end
    hue[event.dst].value = value
    if logging then log('Setting '..event.dst..' to '..value..' (final), previous='..hue[event.dst].value) end
    cbusMessages[#cbusMessages + 1] = event.dst..">"..value -- Queue the event
  end
end

local localbus = require('localbus').new(busTimeout) -- Set up the localbus
localbus:sethandler('groupwrite', eventCallback)


--[[
Representational state transfer (REST) 
--]]

local http = require('socket.http')
local ltn12 = require('ltn12')

local function rest(method, cmd, body)
  if not body then body = '' end
  local respbody = {}
  local headers = {["content-length"] = tostring(#body)}
  if clientKey ~= nil then headers['hue-application-key'] = clientKey end
  local result, respcode, respheaders, respstatus = http.request {
    method = method,
    url = 'https://'..bridge..cmd,
    source = ltn12.source.string(body),
    headers = headers,
    sink = ltn12.sink.table(respbody)
  }
  if respcode ~= 200 then
    local desc = ''
    if len(respbody) > 0 and respbody[1] then
      desc = ' '..json.decode(respbody[1]).errors[1].description
    end
    logger('Error: REST response: '..respcode..' requesting '..method..' '..cmd..desc, FORCE)
    return(nil)
  end
  return table.concat(respbody)
end


--[[
Retrieve or create the client key 
--]]

clientKey = storage.get(clientKeyStorage)
if clientKey == nil then
  logger('Press the Hue bridge link button', FORCE)
  repeat
    response = json.decode(rest('POST', '/api', '{"devicetype":"cbus#ac", "generateclientkey": true}'))[1]
    if response.error and response.error.description:find('not pressed') then
      logger('Waiting for link button...', FORCE)
      socket.sleep(5)
    end
  until response.success
  clientKey = response.success.username
  storage.set(clientKeyStorage, clientKey)
  heartbeat = os.time()
end


--[[
Load lighting devices from the bridge (REST call or in response to the event stream)
--]]

local function getResources(msg)
  local discovered = nil
  local discovering = false
  if not msg then
    discovering = true
    logger('Get light devices')
    local resp = rest('GET', resource..'/light')
    if resp ~= nil then msg = json.decode(resp) end
  end
  if msg ~= nil then
    for _, d in ipairs(msg.data) do
      if d.type == 'light' and not hueDeviceStatus[d.id_v1] then
        if discovered == nil then discovered = {} end
        hueDeviceStatus[d.id_v1] = {id = d.id, rid = d.owner.rid, name = d.metadata.name, on = d.on.on}
        if d.dimming then
          hueDeviceStatus[d.id_v1].brightness = d.dimming.brightness; hueDeviceStatus[d.id_v1].level = math.floor(d.dimming.brightness * 254 / 100 + 0.5)
        else
          hueDeviceStatus[d.id_v1].level = (d.on.on and 255) or 0
        end
        local dmsg = json.decode(rest('GET', resource..'/device/'..d.owner.rid))
        local s
        for _, s in ipairs(dmsg['data'][1].services) do
          if s.rtype == 'zigbee_connectivity' then hueDeviceStatus[d.id_v1].zid = s.rid break end
        end
        hueDeviceStatus[d.id_v1].reachable = json.decode(rest('GET', connectivity..'/'..hueDeviceStatus[d.id_v1].zid))['data'][1].status == 'connected'

        hueIds[d.metadata.name] = d.id
        hueV1Ids[d.metadata.name] = d.id_v1
        discovered[d.id_v1] = hueDeviceStatus[d.id_v1]
      end
    end
    if discovered ~= nil then
      local ds = ''
      for _, d in pairs(discovered) do
        if logging then
          ds = ds..'\n'..d.name..', id: '..d.id
        else
          ds = ds..d.name..', '
        end
      end
      if not logging then ds = ds:sub(1, -3) end
      logger('Discovered devices: '..ds, FORCE)
    end
  else
    if discovering then error('REST call failed discovering devices') end
  end
end


--[[
Connect to the bridge and initiate event stream 
--]]

require('ssl')
local sock = require('socket').tcp()
sock:settimeout(5)

local connected = false
local conTest = socket.gettime() - 30
local oldErr

local gotResources = false
while not gotResources do
  local stat, err = pcall(getResources)
  if stat == false then
    logger('Error: Call to getResources(): '..err..', retrying', FORCE)
    socket.sleep(retryDelay)
  else
    gotResources = true
  end
end

while not connected do
  local res, err = sock:connect(bridge, port)
  if res then
    sock = ssl.wrap(sock, protocol)
    res, err = sock:dohandshake()
    if res then
      sock:settimeout(bridgeTimeout)
      sock:send('GET '..eventStream..' HTTP/1.1\nHost: '..bridge..'\nAccept: text/event-stream\nhue-application-key: '..clientKey..'\n\n')
      logger('Initiated event stream', FORCE)
      connected = true
    else
      logger('Bridge handshake failed: '..tostring(err)..', restarting', FORCE)
      pcall(function () sock:close() end)
    end
  else
    if socket.gettime() - conTest > 30 then
      if err ~= 'closed' then
        logger('Initiate event stream failed: '..err, FORCE)
        oldErr = err
        conTest = socket.gettime()
      end
    end
  end
end


--[[
Create / update / delete Hue devices
--]]

local function cudHue(initial)
  local grps = GetCBusByKW('HUE', 'or')
  local found = {}
  local addition = false
  local k, v, stat, err

  stat, err = pcall(
    function ()
      for k, v in pairs(grps) do
        local net = tonumber(v['address'][1]); local app = tonumber(v['address'][2]); local group = tonumber(v['address'][3])
        local pn = GetCBusGroupTag(net, app, group)
        local alias = net..'/'..app..'/'..group

        table.insert(found, alias)
        if not hue[alias] then hue[alias] = {}; addition = true end

        local tags = v['keywords']
        for _, t in ipairs(tags) do
          local tp = string.split(t, '=')
          tp[1] = trim(tp[1])
          if tp[2] then tp[2] = trim(tp[2]) if tp[1] == 'pn' then pn = tp[2] end end
        end
        hue[alias].name = pn
        hue[alias].hueid = hueIds[pn]
        hue[alias].hueV1id = hueV1Ids[pn]
        if addition then
          if initial then
            local level = nil; pcall(function () level = GetCBusLevel(net, app, group) end); if not level then level = -1 end
            hue[alias].value = level
            local hueLevel = CBusPctToLevel(math.floor(math.round(hueDeviceStatus[hueV1Ids[pn]].brightness)))
            if not ramp[alias] then -- Do not mess with the CBusLevel during ramping
              if level ~= hueLevel and hueDeviceStatus[hueV1Ids[pn]].on then
                logger('Adjusting '..alias..' to match Hue, on=true, level='..level..', hueLevel='..hueLevel)
                SetCBusLevel(net, app, group, hueLevel, 0)
                level = hueLevel
              end
              if level > 0 and not hueDeviceStatus[hueV1Ids[pn]].on then
                logger('Adjusting '..alias..' to match Hue, on=false, level='..level..', hueLevel='..hueLevel)
                SetCBusLevel(net, app, group, 0, 0)
                level = 0
              end
            end
          end
          if not storage.get('pre'..alias) then storage.set('pre'..alias, level) end
          hueDevices[pn] = alias
          hueDeviceStatus[hueV1Ids[pn]].alias = alias
          if hueDeviceStatus[hueV1Ids[pn]].brightness ~= nil then hue[alias].dimmable = true end
        end
      end
    
      -- Handle deletions
      for k, _ in pairs(hue) do
        local f = false; for _, v in ipairs(found) do if k == v then f = true; break end end
        if not f then
          kill = hue[k].name; hue[k] = nil; hueDevices[kill] = nil
        end
      end
    end)
    if stat == false then
      logger('Error: cudHue() failed: '..err, FORCE)
  end
end


--[[
Last level storage
--]]

local function saveLastLevel()
  -- Get old levels to see if anything changed
  local oldLastLevel = storage.get('lastlvlhue', {})
  local changed = {}
  local k, v

  for k, v in pairs(lastLevel) do
    if oldLastLevel[k] == nil or oldLastLevel[k] ~= v then -- Add to changes
      changed[#changed + 1] = k..' '..tostring(oldLastLevel[k])..'->'..tostring(v)
    end
  end

  if #changed then
    storage.set('lastlvlhue', lastLevel)
    logger('Saved last levels. Object(s) changed: '..table.concat(changed, ', '))
  end
end

local function checkNewLastLevel(alias, target)
  if target == nil then
    local parts = string.split(alias, '/')
    target = GetCBusTargetLevel(tonumber(parts[1]), tonumber(parts[2]), tonumber(parts[3]))
  end
  if target ~= 0 then
    if target ~= lastLevel[alias] then
      lastLevel[alias] = target
      logger('Set lastLevel to '..target..' for '..alias)
      saveLastLevel()
    end
  end
end


--[[
Publish Philips Hue objects to bridge
--]]

local function publishHue(alias, level, rampRate, prev)
  local state = (level ~= 0) and true or false
  local hueState
  local payload = {}

  payload.on = state
  if hue[alias].dimmable then
    hueState = level
    payload.bri = (level == 255 and 254) or level -- Max Hue level is 254
    if rampRate then payload.transitiontime = math.floor(rampRate*10 + 0.5); nonTargetUpdate[alias] = false end -- Set transition time
  else
    hueState = state
  end
  
  if not ignoreBridge[alias] then
    -- Publishing to the bridge here will result in outstandingBridgeMessage() below setting the CBus state for the group.
    -- This is undesired, so ignoreCbus[alias] is used to ensure that the bridge change received does not set CBus.
    if hueState ~= prev then ignoreCbus[alias] = socket.gettime(); logger('Setting ignoreCBus for '..alias) end
    local toPut = json.encode(payload)
    local resource = '/api/'..clientKey..hueV1Ids[hue[alias].name]..'/state'
    rest('PUT', resource, toPut)
    logger('Published Hue state and level '..hue[alias].name..' to '..toPut)
  else
    ignoreBridge[alias] = nil
    logger('Ignoring bridge publish for '..alias)
  end
end


--[[
Publish the next queued messages from CBus to bridge
--]]

local function outstandingCbusMessage()
  if logms then logger('Entering outstandingCbusMessage()') end
  local cmd
  for _, cmd in ipairs(cbusMessages) do
    local parts, payload
    local setting = true
    local f = string.split(cmd, '>') -- Final message
    local i = string.split(cmd, '<') -- Zero message
    if f[2] then
      parts = string.split(f[1], '/'); payload = tonumber(f[2])
    elseif i[2] then
      parts = string.split(i[1], '/'); payload = tonumber(i[2])
    else
      parts = string.split(cmd, '/'); payload = tonumber(parts[4])
    end
    local alias = parts[1]..'/'..parts[2]..'/'..parts[3]
    local sKey = 'pre'..alias

    if ramp[alias] and f[2] then -- End of ramp/target level message
      local expectingMore = true
      if ramp[alias].target == 0 and not hueDeviceStatus[hueV1Ids[hue[alias].name]].on and (hueDeviceStatus[hueV1Ids[hue[alias].name]].brightness == minHueBri or hueDeviceStatus[hueV1Ids[hue[alias].name]].brightness == 0) and payload == ramp[alias].target then expectingMore = false end
      if ramp[alias].target > 0 and hueDeviceStatus[hueV1Ids[hue[alias].name]].on then
        if hueDeviceStatus[hueV1Ids[hue[alias].name]].on and hueDeviceStatus[hueV1Ids[hue[alias].name]].level == ramp[alias].target and payload == ramp[alias].target then expectingMore = false end
        if ramp[alias].target == 255 and hueDeviceStatus[hueV1Ids[hue[alias].name]].on and hueDeviceStatus[hueV1Ids[hue[alias].name]].level == 254 and payload == ramp[alias].target then expectingMore = false end
      end
      if expectingMore then
        logger('Clear ramp for '..alias..' (setting pending end ramp to wait for lamp status at target level)')
        -- Hue bulbs can take quite a while after the transition is complete to report their status.
        -- This script can wait for that final status message by setting pendingEndRamp, which will suppress setting lastLevel or any updates beyond the expected transition time.
        pendingEndRamp[alias] = {ts = socket.gettime(), rampts = ramp[alias].ts, target = ramp[alias].target, transitionTime = ramp[alias].transitionTime}
      else
        logger('Clear ramp for '..alias..' (lamp at target level)') -- Transition complete, so no more Hue updates will arrive
      end
      ramp[alias] = nil
      local p = payload
      if tonumber(payload) then p = string.format('%.3f', payload) end
      storage.set(sKey, p) logger('Previous for '..alias..' has been saved in outstandingCbus (final) target level as '..p) -- Save 'previous' for use in the HUE event-based script
      goto next
    end
    
    local net = tonumber(parts[1]); local app = tonumber(parts[2]); local group = tonumber(parts[3])
    local setRamp = false
    if payload == nil then logger('Warning: Nil level for '..alias, FORCE); goto next end

    local prev = tonumber(storage.get(sKey, 0))
    local targetRamp = GetCBusRampRate(net, app, group)
    local targetLevel = GetCBusTargetLevel(net, app, group)
    
    if targetRamp > 0 and payload == targetLevel then
      -- Target level handled above
      if payload == prev then goto next end
    end

    if not hueDeviceStatus[hueV1Ids[hue[alias].name]].reachable then
      if payload ~= prev then
        SetCBusLevel(net, app, group, prev, 0)
        logger('Warning: No connectivity for '..hue[alias].name..' reverting '..alias..' to previous value', FORCE)
        ignoreBridge[alias] = socket.gettime()
        logger('Setting ignoreBridge for '..alias)
      else
        logger('Warning: No connectivity for '..hue[alias].name, FORCE)
      end
      goto next
    end
    
    if not ramp[alias] then
      if pendingEndRamp[alias] then
        setting = false -- End of ramp/target reached, so suppress set 
      else
        checkNewLastLevel(alias, targetLevel)
        setRamp = true
        if targetRamp > 0 then
          local transitionTime = math.abs(targetLevel - prev) / 256 * targetRamp + 1 -- Calculate transition time from ramp rate, plus margin to ensure the transition finishes after the CBus ramp
          ramp[alias] = {
            ts = socket.gettime(),
            ramp = targetRamp,
            target = targetLevel,
            transitionTime = transitionTime
          }
          logger('Set ramp for '..alias)
        end
      end
    else
      if ramp[alias].target ~= targetLevel then -- Target level has changed so change or cancel ramp
        checkNewLastLevel(alias, targetLevel)
        setRamp = true
        if targetRamp > 0 then
          local transitionTime = math.abs(targetLevel - prev) / 256 * targetRamp + 1 -- Calculate transition time from ramp rate, plus margin to ensure the transition finishes after the CBus ramp
          ramp[alias] = {
            ts = socket.gettime(),
            ramp = targetRamp,
            target = targetLevel,
            transitionTime = transitionTime
          }
          logger('Re-set ramp for '..alias)
        else
          ramp[alias] = nil
          logger('Cancel ramp for '..alias)
        end
      end
      if payload == ramp[alias].target then setting = false end -- Final level has not yet arrived, so suppress set
    end
    if setting then
      if setRamp then
        publishHue(alias, (ramp[alias] and ramp[alias].target) or payload, (ramp[alias] and ramp[alias].transitionTime) or nil, prev)
      end
      if ramp[alias] ~= nil then ramp[alias].previous = payload end
      local p = payload
      if tonumber(payload) then p = string.format('%.3f', payload) end
      storage.set(sKey, p) logger('Previous for '..alias..' has been saved in outstandingCbus setting as '..p) -- Save 'previous' for use in the HUE event-based script
    end
    ::next::
  end
  cbusMessages = {}
  if logms then logger('Exiting outstandingCbusMessage()') end
end


--[[
Publish the next queued messages from bridge to CBus
--]]

local function outstandingBridgeMessage()
  local level, msg
  for _, msg in ipairs(bridgeMessages) do
    local id = msg.id
    local alias = hueDeviceStatus[id].alias
    local forceBridge = false
    local lvl

    if alias == nil then goto next end

    local sKey = 'pre'..alias
    local parts = string.split(alias, '/')
    local net = parts[1]; local app = parts[2]; local group = parts[3]
    logger('Message received for '..id..' ('..net..'/'..app..'/'..group..')')
    
    if hueDeviceStatus[id].brightness ~= nil then
      if hue[alias].dimmable == nil then hue[alias].dimmable = true end
      if hueDeviceStatus[id].on and hueDeviceStatus[id].level ~= lastLevel[alias] then lastLevel[alias] = hueDeviceStatus[id].level end
      level = (hueDeviceStatus[id].on and lastLevel[alias]) or 0
    else
      level = (hueDeviceStatus[id].on and 255) or 0
    end
    if hue[alias].dimmable and pendingEndRamp[alias] then
      local pendingDone = false
      if pendingEndRamp[alias].target == 0 then
        if not hueDeviceStatus[id].on and (hueDeviceStatus[id].brightness == minHueBri or hueDeviceStatus[id].brightness == 0) then pendingDone = true end
      end
      if pendingEndRamp[alias].target > 0 then
        if hueDeviceStatus[id].on then
          if pendingEndRamp[alias].target == level then pendingDone = true end
          if pendingEndRamp[alias].target == 255 and level == 254 then pendingDone = true end
        end
      end
      if pendingDone then
        logger('Cleared pending end ramp for '..alias)
        pendingEndRamp[alias] = nil
        ignoreCbus[alias] = nil
      end
      goto next
    end
    if not ignoreCbus[alias] then -- Only set the CBus status/level if this script did not initiate the change
      local p = nil
      if hue[alias].dimmable then
        if not ramp[alias] and not pendingEndRamp[alias] then
          lvl = nil; local stat, err = pcall(function () lvl = GetCBusLevel(net, app, group) end); if lvl == 255 then lvl = 254 end -- Max Hue level is 254
          if lvl ~= level then
            if msg.on and not msg.lvl then -- No level set, so return to lastLevel
              if level > 0 and level ~= lastLevel[alias] then
                forceBridge = true  -- If hueDeviceStatus level is different to lastLevel then force a bridge message
                level = lastLevel[alias]
              end
            end
            logger('Setting '..alias..' to '..level..tostring((forceBridge and ' (last level)') or ''))
            if not forceBridge then p = string.format('%.3f', level) end
            SetCBusLevel(net, app, group, level, 0)
            checkNewLastLevel(alias)
          end
        else
          logger('Not setting '..alias..' - ramp in progress')
        end
      else
        -- Switchable
        local state = nil; pcall(function () state = GetCBusState(net, app, group) end)
        lvl = (state and 255) or 0
        if state ~= hueDeviceStatus[id].on then
          logger('Setting '..alias..' to '..tostring(hueDeviceStatus[id].on))
          SetCBusState(net, app, group, hueDeviceStatus[id].on)
          p = string.format('%.3f', (hueDeviceStatus[id].on and 255) or 0)
        end
      end
      if p ~= nil then storage.set(sKey, p) logger('Previous for '..alias..' has been saved in outstandingBridge as '..p) end -- Save 'previous' for use in the HUE event-based script
    else
      ignoreCbus[alias] = nil
      logger('Ignoring CBus publish for '..alias)

      if ramp[alias] then -- Check for early termination of ramp (usually because a very small level change)
        local expectingMore = true
        if ramp[alias].target == 0 and not hueDeviceStatus[hueV1Ids[hue[alias].name]].on and (hueDeviceStatus[hueV1Ids[hue[alias].name]].brightness == minHueBri or hueDeviceStatus[hueV1Ids[hue[alias].name]].brightness == 0) and ramp[alias].previous == ramp[alias].target then expectingMore = false end
        if ramp[alias].target > 0 and hueDeviceStatus[hueV1Ids[hue[alias].name]].on then
          if hueDeviceStatus[hueV1Ids[hue[alias].name]].level == ramp[alias].target and ramp[alias].previous == ramp[alias].target then expectingMore = false end
          if ramp[alias].target == 255 and hueDeviceStatus[hueV1Ids[hue[alias].name]].level == 254 and ramp[alias].previous == ramp[alias].target then expectingMore = false end
        end
        if not expectingMore then
          logger('Clear ramp early for '..alias..' (lamp at target level)') -- Transition complete, so no more Hue updates will arrive
          ramp[alias] = nil
        end
      end
    end
    ::next::
  end
  ::exit::
  bridgeMessages = {}
end


--[[
Remove any orphaned ramp flags
--]]

local function checkRampOrphans()
  local k, v; local orphan = {}
  for k, v in pairs(ramp) do if socket.gettime() > v.ts + v.ramp + rampTimeout then table.insert(orphan, k) end end
  for _, k in ipairs(orphan) do ramp[k] = nil; logger('Warning: Removing orphaned ramp for '..k, FORCE) end
end

--[[
Remove any orphaned pending end ramp flags
--]]

local function checkEndRampOrphans()
  local k, v; local orphan = {}
  for k, v in pairs(pendingEndRamp) do if socket.gettime() - v.ts > pendingTimeout then table.insert(orphan, k) end end
  for _, k in ipairs(orphan) do pendingEndRamp[k] = nil; logger('Warning: Removing orphaned pending end ramp for '..k, FORCE) end
end

--[[
Remove any orphaned ignore flags
--]]

local function checkIgnoreOrphans()
  local k, v; local orphan = {}
  for k, v in pairs(ignoreBridge) do if socket.gettime() - v > ignoreTimeout then table.insert(orphan, k) end end
  for _, k in ipairs(orphan) do ignoreBridge[k] = nil; logger('Warning: Removing orphaned ignore bridge flag for '..k, FORCE) end
  orphan = {}
  for k, v in pairs(ignoreCbus) do if socket.gettime() - v > ignoreTimeout then table.insert(orphan, k) end end
  for _, k in ipairs(orphan) do ignoreCbus[k] = nil; logger('Warning: Removing orphaned ignore CBus flag for '..k, FORCE) end
end


--[[
Bridge update message
--]]

local function updateMessage(msg)
  if msg.type == 'update' then
    local bridgeMessage = {}
    local d
    for _, d in ipairs(msg.data) do
      if d.type == 'light' then
        local update = false
        local nonTarget = false
        local id = d.id_v1
        if bridgeMessage[id] == nil then bridgeMessage[id] = {id = id, on = nil, bri = nil, lvl = nil, nonTarget = nonTarget} end
        local bri = nil; local lvl = nil;
        local on = nil; if d.on ~= nil then on = d.on.on; if not on then lvl = 0 bri = 0 end update = true end
        if d.dimming then
          update = true
          bri = d.dimming.brightness
          lvl = math.floor(bri * 255 / 100 + 0.5)
          lvl = (lvl == 255 and 254) or lvl
          local alias = hueDeviceStatus[id].alias
          local target = nil
          if ramp[alias] then target = ramp[alias].target end
          if pendingEndRamp[alias] then target = pendingEndRamp[alias].target end
          if lvl ~= target and not nonTargetUpdate[alias] then nonTargetUpdate[alias] = true; nonTarget = true end
        end
        if hueDeviceStatus[id] then
          if on ~= nil then hueDeviceStatus[id].on = on end
          if bri ~= nil then hueDeviceStatus[id].brightness = bri; hueDeviceStatus[id].level = lvl end
          if d.metadata ~= nil and d.metadata.name ~= hueDeviceStatus[id].name then -- Device has been renamed
            local oldName = hueDeviceStatus[id].name
            logger('Device '..oldName..' renamed to '..d.metadata.name, FORCE)
            hueDeviceStatus[id].name = d.metadata.name
            hueIds[d.metadata.name] = hueIds[oldName]; hueIds[oldName] = nil
            hueV1Ids[d.metadata.name] = hueV1Ids[oldName]; hueV1Ids[oldName] = nil
          end
          if update then
            if on ~= nil then bridgeMessage[id].on = on end
            if lvl ~= nil then if lvl == 0 then bridgeMessage[id].on = false else bridgeMessage[id].on = true end end
            if lvl ~= nil then bridgeMessage[id].bri = bri; bridgeMessage[id].lvl = lvl end
            bridgeMessage[id].nonTarget = nonTarget
          end
        end
      elseif d.type == 'zigbee_connectivity' then
        local id = d.id_v1
        local status = nil; if d.status then status = d.status end
        if hueDeviceStatus[id] then
          if status ~= nil  then if status == 'connected' then hueDeviceStatus[id].reachable = true else hueDeviceStatus[id].reachable = false end end
        end
        if id ~= nil and status ~= nil and status then
          logger(hueDeviceStatus[id].name..' is '..tostring((hueDeviceStatus[id].reachable and 'reachable') or 'NOT reachable'), FORCE)
        end
      end
    end
    local u
    for _, u in pairs(bridgeMessage) do
      logger('Hue event '..u.id..', on='..tostring(u.on)..', bri='..tostring(u.bri)..', lvl='..tostring(u.lvl)..tostring((u.nonTarget and ' (non-target update)') or ''))
      bridgeMessages[#bridgeMessages + 1] = u
    end
  elseif msg.type == 'delete' then
    for _, d in ipairs(msg.data) do
      if d.type == 'light' then
        local id = d.id_v1
        if hueDeviceStatus[id] then
          logger('Device '..hueDeviceStatus[id].name..' deleted', FORCE)
          hueIds[hueDeviceStatus[id].name] = nil
          hueV1Ids[hueDeviceStatus[id].name] = nil
          hueDeviceStatus[id] = nil
        end
      end
    end
  elseif msg.type == 'add' then
    local stat, err = pcall(getResources, msg)
    if stat == false then logger('Error: Call to getResources() failed: '..err, FORCE) end
  end
end


--[[
Main loop
--]]

local cud = {
  { func = cudHue, t = socket.gettime() - checkChanges, init = true, script = 'HUE' } -- Create/update/delete script(s)
}

-- Initial load of devices
local c
for _, c in ipairs(cud) do if c.init then c.func(true); if c.script and script.status(c.script) ~= nil then script.disable(c.script); script.enable(c.script) end end end

local lastTest = socket.gettime()
local lastReceived = lastTest

while true do
  -- Read the bridge event stream
  local line, err = sock:receive()

  if not err then
    if line then
      if line:find('data:') and not line:find('geofence_client') then
        local j
        local payload = line:split(': ')[2]
        local stat, err = pcall(function () j = json.decode(payload) end)
        if stat then
          local msg
          for _, msg in ipairs(j) do updateMessage(msg) end
        end
      elseif line:find(': hi') then
        logger('Receiving event stream', FORCE)
        hueConnected = true
        storage.set('hueactive', true)
      end
    end
  else
    if err ~= 'wantread' then
      if err == 'closed' then
        logger('Event stream connection lost, restarting', FORCE)
      else
        logger('Event stream receive failed: Socket error state is '..tostring(err)..', restarting', FORCE)
      end
      pcall(function () sock:close() end)
      do return end
    end
  end

  -- Get the bridge details periodically
  -- If no valid response beyond 60 seconds then restart (http timeout is 60 seconds)
  if socket.gettime() - lastTest >= 15 then
    lastTest = socket.gettime()
    local msg, response
    response = rest('GET', resource..'/bridge')
    if response then
      msg = json.decode(response)
      for k, _ in pairs(msg) do if k == 'data' then lastReceived = lastTest end end
    end
  end
  if socket.gettime() - lastReceived > 60 then
    logger('Timed out getting bridge details, restarting', FORCE)
    pcall(function () sock:close() end)
    do return end
  end

  -- Check for new messages from CBus
  localbus:step()

  if #bridgeMessages > 0 then outstandingBridgeMessage() end -- Send outstanding messages to CBus
  if #cbusMessages > 0 then outstandingCbusMessage() end     -- Send outstanding messages to bridge
  if len(ramp) > 0 then checkRampOrphans() end               -- Some scenarios occasioanlly create ramp orphans (should never happen)
  if len(pendingEndRamp) > 0 then checkEndRampOrphans() end  -- Some scenarios occasioanlly create pending end ramp orphans (should never happen)
  if len(ignoreCbus) > 0 or len(ignoreBridge) > 0 then checkIgnoreOrphans() end  -- Some scenarios occasioanlly create ignore orphans (should never happen)
  if checkForChanges then                                    -- Periodically create/update/delete device items that change
    for _, c in ipairs(cud) do if socket.gettime() - c.t >=checkChanges then c.t = socket.gettime(); c.func() end end
  end

  --[[
  Send a heartbeat periodically to port 5433, listened to by the Heartheat script.
  If execution is disrupted by any error or lockup then this script will be re-started.
  If sending the heartbeat faults, then the loop is exited, which will also re-start this
  script (it being resident/sleep zero).
  --]]

  if sendHeartbeat > 0 then
    local stat, err = pcall(function ()
      if os.time() - heartbeat >= sendHeartbeat then
        heartbeat = os.time(); require('socket').udp():sendto(_SCRIPTNAME..'+'..heartbeat, '127.0.0.1', 5433)
      end
    end)
    if not stat then
      storage.set('hueactive', nil)
      logger('A fault occurred sending heartbeat. f...', FORCE)
      pcall(function () sock:close() end)
      do return end
    end
  end
end