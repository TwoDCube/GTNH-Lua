local events = require('events')
local component = require('component')
local event = require('event')

local modem = component.modem
local PORT = 1337

local function getBatteryData()
    local current = component.gt_machine.getEUStored()
    local total = component.gt_machine.getEUMaxStored()
    return current, total
end

local function broadcast()
    local current, total = getBatteryData()
    modem.broadcast(PORT, "lgt_battery", current, total)
end

local function loop()
    if events.needExit() then
        print('received exit command')
        return false
    end

    broadcast()
    os.sleep(0.05) -- 1 tick

    return true
end

local function main()
    print('start LGT-Admin')
    events.initEvents()
    events.hookEvents()

    modem.open(PORT)
    print('broadcasting on port ' .. PORT)

    while loop() do
    end

    modem.close(PORT)
    events.unhookEvents()
    print('stop LGT-Admin')
end

main()
