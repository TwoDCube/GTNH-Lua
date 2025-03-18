local events = require('events')
local component = require('component')
local sides = require('sides')

local function isBatteryPercentageAbove(percentage)
    local current = 0
    local total = 0
    for i=1, 64 do
        if component.gt_batterybuffer.getBatteryCharge(i) ~= nil then
            current = current + component.gt_batterybuffer.getBatteryCharge(i)
        else
            break
        end
        if component.gt_batterybuffer.getMaxBatteryCharge(i) ~= nil then
            total = total + component.gt_batterybuffer.getMaxBatteryCharge(i)
        end
    end

    return current / total > percentage
end

local charging = true
local function loop()
    if events.needExit() then
        print('received exit command')
        return false
    end

    if isBatteryPercentageAbove(0.8) then
        charging = false
    end
    if not isBatteryPercentageAbove(0.2) then
        charging = true
    end

    if charging then
        component.transposer.transferFluid(sides.up, sides.down, 10000)
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
