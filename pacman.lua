local shell = require("shell")

local function usage()
    print([[usage:  pacman <operation> [...]
operations:
    pacman {-h --help}
    pacman {-V --version}
    pacman {-D --database} <options> <package(s)>
    pacman {-F --files}    [options] [file(s)]
    pacman {-Q --query}    [options] [package(s)]
    pacman {-R --remove}   [options] <package(s)>
    pacman {-S --sync}     [options] [package(s)]
    pacman {-T --deptest}  [options] [package(s)]
    pacman {-U --upgrade}  [options] <file(s)>

use 'pacman {-h --help}' with an operation for available options
]])
end
local repo = "https://raw.githubusercontent.com/TwoDCube/GTNH-Lua/refs/heads/master/"

local args, options = shell.parse(...)

local oHelp = options.help or options.h
local oVersion = options.version or options.V
local oSync = options.sync or options.S

if oHelp then
    usage()
    return 1
end

if oVersion then
    print([[
        
 .--.                  Pacman v1.0.0
/ _.-' .-.  .-.  .-.   Copyright (C) 2025 Zoltan Szepesi
\  '-. '-'  '-'  '-' 
 '--'
                       This program may be freely redistributed under
                       the terms of the GNU General Public License.

    ]])

    return 0
end

if options.S then
    if #args == 0 then
        usage()
        return 1
    end

    if args[1] == "LGT" then
        local scripts = {
            'LGT/LGT.lua'
        }


        shell.execute(string.format('mkdir LGT'))
        shell.execute(string.format('cd LGT'))
        for _, v in pairs(scripts) do
           shell.execute(string.format('wget -f %s%s', repo, v)) 
        end
        print("Successfully installed LGT")
    end
    return 0
end
