local events = require('events')
local component = require('component')
local sides = require('sides')

local function formatEU(value)
    if value >= 1e12 then
        return string.format("%.2f TEU", value / 1e12)
    elseif value >= 1e9 then
        return string.format("%.2f GEU", value / 1e9)
    elseif value >= 1e6 then
        return string.format("%.2f MEU", value / 1e6)
    elseif value >= 1e3 then
        return string.format("%.2f kEU", value / 1e3)
    else
        return string.format("%.0f EU", value)
    end
end

local function isBatteryPercentageAbove(percentage)
    local current = component.gt_machine.getEUStored()
    local total = component.gt_machine.getEUMaxStored()
    local percent = current / total

    return percent > percentage
end

local charging = true
local redstone = component.redstone
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

    while loop() do
    end

    events.unhookEvents()
    print('stop LGT')
end

main()
