# GTNH-Lua

OpenComputers scripts for GregTech New Horizons.

## Installation

```bash
oppm register TwoDCube/GTNH-Lua
```

## Packages

### lgt-admin

Reads EU data from a GT machine (via adapter) and broadcasts it over the network.

Install on the computer connected to the GT machine adapter:

```bash
oppm install lgt-admin -f
```

### lgt

Receives EU data from the network and controls redstone output based on battery percentage:
- Turns ON when battery drops below 95%
- Turns OFF when battery reaches 99%

Install on the computer with the redstone controller:

```bash
oppm install lgt -f
```

## Setup

1. Connect `lgt-admin` computer to GT machine via adapter
2. Connect `lgt` computer to redstone control
3. Ensure both computers have network cards and can communicate
4. Both scripts auto-run on boot via `.shrc`
