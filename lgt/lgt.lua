local events = require('events')
local component = require('component')
local event = require('event')
local sides = require('sides')

local modem = component.modem
local redstone = component.redstone
local PORT = 1337

local currentEU = 0
local totalEU = 1

local function onBatteryData(_, _, _, _, _, msgType, current, total)
    if msgType == "lgt_battery" then
        currentEU = current
        totalEU = total
    end
end

local function isBatteryPercentageAbove(percentage)
    local percent = currentEU / totalEU
    return percent > percentage
end

local charging = true
local function loop()
    if events.needExit() then
        print('received exit command')
        return false
    end

    if isBatteryPercentageAbove(0.99) then
        charging = false
    end
    if not isBatteryPercentageAbove(0.95) then
        charging = true
    end

    if charging then
        redstone.setOutput(sides.east, 15)
    else
        redstone.setOutput(sides.east, 0)
    end
    os.sleep(0.05) -- 1 tick

    return true
end

local function main()
    print('start LGT')
    events.initEvents()
    events.hookEvents()

    modem.open(PORT)
    event.listen("modem_message", onBatteryData)
    print('listening on port ' .. PORT)

    while loop() do
    end

    event.ignore("modem_message", onBatteryData)
    modem.close(PORT)
    events.unhookEvents()
    print('stop LGT')
end

main()
