local event = require('event')
local component = require('component')
local self = component.computer
local needExitFlag = false

local function keyboardEvent(eventName, keyboardAddress, charNum, codeNum, playerName)
    -- Exit if 'q' was pressed
    if charNum == 113 then
        needExitFlag = true
        print('===== !!! ===== !!! ===== !!! =====')
        self.beep(1000, 1)
        return false -- Unregister this event listener
    end
end

local function hookEvents()
    event.listen("key_up", keyboardEvent)
end


local function unhookEvents()
    event.ignore("key_up", keyboardEvent)
end


local function needExit()
    return needExitFlag
end

local function initEvents()
    needExitFlag = false
end

return {
    initEvents = initEvents,
    hookEvents = hookEvents,
    unhookEvents = unhookEvents,
    needExit = needExit,
}
