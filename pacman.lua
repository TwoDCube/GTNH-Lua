local shell = require("shell")

local function usage()
    print("Usage: pacman "..[[

    --help display this help and exit
]])
end

local args, options = shell.parse(...)
if #args == 0 or options.help then
    usage()
    return 1
end

