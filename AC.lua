--[[
Event-based, execute during ramping, name: "AC"

Pushes CBus events to MQTT resident scripts via internal sockets.

Tag required objects with the "AC" keyword and this script will run whenever one of those objects change.
--]]

-- Send an event to publish to broker
require('socket').udp():sendto(event.dst .. "/" .. event.getvalue(), '127.0.0.1', 5432)
