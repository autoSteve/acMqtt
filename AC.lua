--[[
Pushes CBus events to MQTT resident scripts via internal sockets.

Tag required objects with the "AC" keyword and this script will run whenever one of those objects change.
VERSION: 1
--]]

local logging = false

-- Send an event to publish to broker
if logging then log('Setting '..event.dst..' to '..event.getvalue()) end
require('socket').udp():sendto(event.dst.."/"..event.getvalue(), '127.0.0.1', 5432)