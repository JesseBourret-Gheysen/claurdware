# Claude Hardware Design Environment
## Agent Setup Reference — CLAUDE.md

This file is written for Claude Code agents. Read it fully before beginning any hardware design task.
It describes the complete text-prompt-to-schematic pipeline: tools, install paths, workflows, and
decision logic for choosing between approaches.

---

## Table of Contents

1. [Stack Overview](#1-stack-overview)
2. [Prerequisites Verification](#2-prerequisites-verification)
3. [KiCad 9.0 Setup](#3-kicad-90-setup)
4. [Diode Zener + pcb CLI — Primary Path](#4-diode-zener--pcb-cli--primary-path)
5. [MCP Servers](#5-mcp-servers)
6. [Claude Code Skills — kicad-happy](#6-claude-code-skills--kicad-happy)
7. [circuit-synth — Python-Based Alternative](#7-circuit-synth--python-based-alternative)
8. [EDA Tools MCP — FPGA/ASIC Path](#8-eda-tools-mcp--fpgaasic-path)
9. [Complete MCP Config](#9-complete-mcp-config)
10. [Environment Verification](#10-environment-verification)
11. [Agent Decision Logic](#11-agent-decision-logic)
12. [Quick Reference Tables](#12-quick-reference-tables)

---

## 1. Stack Overview

**Platform target:** Windows 11 + WSL2 (Kali/Debian/Ubuntu base). All shell commands run inside
WSL2 unless explicitly stated. Windows support for the Diode pcb CLI is experimental — never run
pcb commands outside WSL.

**What this stack does:** Accepts a text prompt describing a hardware circuit or board, and produces
KiCad schematic files, a BOM with real in-stock parts, and optionally Gerber manufacturing files —
without manual GUI interaction.

**Four functional layers:**

| Layer | Purpose | Primary Tool |
|---|---|---|
| Schematic authoring | Text/code → .kicad_sch | Diode Zener + pcb CLI |
| EDA control | Agent controls KiCad directly | mixelpixx/KiCAD-MCP-Server |
| Component sourcing | Find real parts during design | pcbparts-mcp |
| Validation | ERC, DRC, BOM export | kicad-happy skills + KiCad MCP |

---

## 2. Prerequisites Verification

Before any install steps, verify these. Missing items must be resolved first.

### 2.1 WSL2 (not WSL1)

```bash
wsl --list --verbose
# VERSION column must show 2 for your distro
# If not:
wsl --set-version <DistroName> 2
```

### 2.2 System packages

```bash
sudo apt-get update && sudo apt-get install -y \
  git curl wget build-essential python3 python3-pip \
  nodejs npm unzip ca-certificates
```

### 2.3 Node.js v20+

The apt version of Node.js is usually outdated. Install v20 via NodeSource:

```bash
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt-get install -y nodejs
node --version   # must be v20.x or higher
npm --version
```

### 2.4 Python 3.8+

```bash
python3 --version   # must be 3.8 or higher
pip3 --version
```

### 2.5 Rust toolchain

Required to build the Diode pcb CLI from source:

```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source $HOME/.cargo/env
rustc --version
```

### 2.6 Claude Code alias

Claude Code is installed on Windows and accessed from WSL via a shell alias:

```bash
claude --version
# Must resolve. If not, add to ~/.bashrc:
# alias claude='/mnt/c/Users/<username>/.local/bin/claude.exe'
```

---

## 3. KiCad 9.0 Setup

KiCad 9.0 must be installed on Windows (not in WSL). The MCP servers call KiCad's Python API,
which must be reachable from WSL via PYTHONPATH.

### 3.1 Install KiCad on Windows

Download and run the KiCad 9.0 installer from kicad.org/download/windows.
Use default install options. Ensure Python scripting is included (it is by default).

### 3.2 Verify the Python API is accessible from WSL

```bash
export PYTHONPATH='/mnt/c/Program Files/KiCad/9.0/lib/python3/dist-packages'
python3 -c "import pcbnew; print(pcbnew.GetBuildVersion())"
# Expected: version string like 9.0.x
```

Add the export to `~/.bashrc` for persistence:

```bash
echo "export PYTHONPATH='/mnt/c/Program Files/KiCad/9.0/lib/python3/dist-packages'" >> ~/.bashrc
```

If the import fails, the KiCad Python path may differ. Check:

```bash
ls "/mnt/c/Program Files/KiCad/9.0/lib/"
# Look for a python3 or python directory
```

### 3.3 kicad-cli alias

kicad-cli is bundled with KiCad 9.0 on Windows and is accessible from WSL:

```bash
alias kicad-cli='/mnt/c/Program Files/KiCad/9.0/bin/kicad-cli.exe'
kicad-cli --version
# Add to ~/.bashrc for persistence
```

---

## 4. Diode Zener + pcb CLI — Primary Path

This is the Anthropic-validated, Claude-native schematic authoring path.

**Background:** Diode Computers partnered with Anthropic to develop this pipeline. Claude was given
file I/O tools, bash execution, access to the Zener compiler, and Zener documentation. In blind
head-to-head evaluations by Diode's electrical engineers, Claude Sonnet 4.5 reference designs were
preferred 8/10 times overall, 60/40 over Opus 4, and 82/18 over Sonnet 4.

250+ published reference designs covering sensors, MCUs, power stages, and analog chains are
available at zener.diode.computer.

**Repo:** github.com/diodeinc/pcb

### 4.1 Install

```bash
git clone https://github.com/diodeinc/pcb.git ~/pcb
cd ~/pcb
./install.sh
# Builds from Rust source — approximately 2-5 minutes first run

pcb --version
```

### 4.2 Zener Language Reference for Agent Use

Zener is a DSL built on Starlark (a strict subset of Python). Feed this context block to yourself
at the start of any hardware design session.

**Core primitives:**

```python
# Declare a component
R1 = Component(
    symbol='Device:R',        # KiCad library:symbol
    ref='R',                  # Reference designator prefix
    value='10k',              # Component value
    footprint='Resistor_SMD:R_0402_1005Metric'
)

# Declare a net
vcc = Net('VCC')
gnd = Net('GND')

# Connect a pin to a net
R1[1] += vcc
R1[2] += gnd

# Reusable sub-circuit (module)
@module
def ldo_3v3(vin, vout, gnd):
    reg = Component(symbol='Regulator_Linear:AMS1117-3.3', ref='U',
                    footprint='Package_TO_SOT_SMD:SOT-223-3_TabPin2')
    cin  = Component(symbol='Device:C', ref='C', value='10uF',
                     footprint='Capacitor_SMD:C_0805_2012Metric')
    cout = Component(symbol='Device:C', ref='C', value='22uF',
                     footprint='Capacitor_SMD:C_0805_2012Metric')
    reg['VI']  += vin;   reg['VO']  += vout;  reg['GND'] += gnd
    cin[1]     += vin;   cin[2]     += gnd
    cout[1]    += vout;  cout[2]    += gnd

# Load an existing reference design
load('//components/regulators/ams1117-3.3.zen', 'AMS1117_3V3')

# Top-level entry point
@module
def main():
    vbus = Net('VBUS')
    v3v3 = Net('VCC_3V3')
    gnd  = Net('GND')
    ldo_3v3(vbus, v3v3, gnd)
```

**KiCad symbol naming convention:** `Library:SymbolName` — e.g., `Device:R`, `Device:C`,
`Device:LED`, `MCU_ST_STM32F4:STM32F411CEUx`, `RF_Module:ESP32-S3-WROOM-1`.

### 4.3 pcb CLI Command Reference

| Command | Description |
|---|---|
| `pcb build [PATH]` | Build and validate .zen files — reports ERC and type errors |
| `pcb layout [PATH]` | Generate KiCad project and open in KiCad for manual layout |
| `pcb open [PATH]` | Open existing KiCad layout without regenerating schematics |
| `pcb fmt [PATH]` | Format .zen files using ruff fmt |

PATH can be a .zen file or a directory. When omitted, operates on the current directory.

### 4.4 Agent Workflow: Text Prompt to Schematic

Follow this sequence for any hardware design request using the Zener path:

1. Create a project directory:
   ```bash
   mkdir -p ~/designs/<project_name> && cd ~/designs/<project_name>
   ```

2. Query `pcbparts-mcp` to find real in-stock components matching the design requirements.
   Record LCSC part numbers, values, and footprints for each major component before writing any .zen.

3. Write `main.zen` using Zener syntax. Reference components by their KiCad symbol strings.
   Use the reference designs at zener.diode.computer as patterns for common sub-circuits.

4. Validate:
   ```bash
   pcb build main.zen
   # Iterate on errors until clean
   ```

5. Generate KiCad output:
   ```bash
   pcb layout main.zen
   # Generates .kicad_pro, .kicad_sch files in a subdirectory
   ```

6. Pass the KiCad project to `mixelpixx/KiCAD-MCP-Server` for DRC, ERC, BOM export,
   and Gerber generation.

### 4.5 Common Errors and Fixes

| Error | Cause | Fix |
|---|---|---|
| `symbol not found` | Wrong library:symbol string | Check KiCad library browser or pcbparts-mcp pinout data |
| `footprint not found` | Footprint path incorrect | Use standard KiCad footprint names from pcbparts-mcp |
| `net has only one connection` | Dangling net | All nets need at least two connected pins |
| `duplicate ref designator` | Two components with same ref | Use unique ref strings or let Zener auto-assign |

---

## 5. MCP Servers

### 5.1 pcbparts-mcp — Component Sourcing (No Auth Required)

**Repo:** github.com/Averyy/pcbparts-mcp
**Endpoint:** https://pcbparts.dev/mcp
**Install:** Remote HTTP — no local install needed.

Covers JLCPCB, Mouser, and DigiKey from one server. 1.5M+ parts with parametric filtering,
KiCad footprint downloads via SamacSys, pinout data from EasyEDA symbols, sensor recommendation
across 1,500+ sensors and 56 measurement types, 285 OSHW reference board schematics, and 41
curated PCB design reference files (power, protection, interfaces, MCUs, layout, EMC).

Add to MCP config:

```json
"pcbparts": {
  "command": "npx",
  "args": ["-y", "mcp-remote", "https://pcbparts.dev/mcp"]
}
```

**Queries this server handles well:**

- `"Find logic-level MOSFETs with Vgs(th) < 2V and Id >= 5A in stock at JLCPCB"`
- `"Search STM32F411 — show pricing and stock at JLCPCB"`
- `"Get KiCad footprint for ESP32-S3-WROOM-1"`
- `"What sensor measures CO2 with I2C, compatible with ESP32, in stock?"`
- `"Show how MCP73831 is typically used in real boards"`
- `"What are the design rules for USB-C?"`
- `"Show LDO design best practices"`

### 5.2 @jlcpcb/mcp — JLCPCB Library + KiCad Symbols

**Repo:** github.com/anthropics/ai-eda (packages/jlc-mcp)

Fetches components from JLCPCB/EasyEDA library and installs them as KiCad-compatible symbol and
footprint libraries under `${KICAD9_3RD_PARTY}` for portable paths. Up to 10 components can be
installed in parallel.

Install:

```bash
# Install bun if not present
curl -fsSL https://bun.sh/install | bash
source ~/.bashrc

git clone https://github.com/anthropics/ai-eda.git ~/ai-eda
cd ~/ai-eda/packages/jlc-mcp
bun install && bun run build
```

Add to MCP config:

```json
"jlc": {
  "command": "node",
  "args": ["/home/<username>/ai-eda/packages/jlc-mcp/dist/index.js"]
}
```

KiCad libraries install to: `~/Documents/KiCad/9.0/3rdparty/jlc_mcp/`

### 5.3 mixelpixx/KiCAD-MCP-Server — Full KiCad Control

**Repo:** github.com/mixelpixx/KiCAD-MCP-Server
**Built on:** MCP 2025-06-18 spec
**Stack:** TypeScript MCP server + Python KiCad interface via pcbnew Python API + kicad-skip

Capabilities: project setup, schematic editing, component placement, routing, DRC/ERC, custom symbol
and footprint generation, JLCPCB parts catalog with pricing and stock, Freerouting integration for
automatic PCB routing via Java/Docker, export (Gerbers, PDF, SVG, STEP/VRML 3D, BOM).

Install:

```bash
git clone https://github.com/mixelpixx/KiCAD-MCP-Server.git ~/KiCAD-MCP-Server
cd ~/KiCAD-MCP-Server
npm install
pip3 install -r requirements.txt
npm run build
```

Add to MCP config:

```json
"kicad": {
  "command": "node",
  "args": ["/home/<username>/KiCAD-MCP-Server/dist/index.js"],
  "env": {
    "NODE_ENV": "production",
    "PYTHONPATH": "/mnt/c/Program Files/KiCad/9.0/lib/python3/dist-packages",
    "LOG_LEVEL": "info"
  }
}
```

Troubleshoot Python API connection:

```bash
python3 -c "import pcbnew; print(pcbnew.GetBuildVersion())"
# If this fails, PYTHONPATH is wrong — see Section 3.2
```

### 5.4 Seeed-Studio KiCad MCP — Embedded/MCU Focus

**Repo:** github.com/Seeed-Studio/kicad-mcp-server

39 tools in 7 categories. Use this when the design is MCU-heavy and you need device tree (.dts)
generation for STM32, pin conflict detection, or C test code generated alongside the schematic.

Tool categories: Analysis (schematic/PCB, netlist tracing), Validation (DRC/ERC, pin conflicts),
Pin Analysis (pin functions, pinmux for STM32 and 5 other MCU families), Code Generation (12 tools
including .dts and test code), Editing (schematic + experimental PCB layout), Project Management.

Install:

```bash
git clone https://github.com/Seeed-Studio/kicad-mcp-server.git ~/seeed-kicad-mcp
cd ~/seeed-kicad-mcp
pip3 install -r requirements.txt
```

Add to MCP config:

```json
"kicad-seeed": {
  "type": "stdio",
  "command": "python3",
  "args": ["-m", "kicad_mcp_server"],
  "cwd": "/home/<username>/seeed-kicad-mcp",
  "env": {
    "PYTHONPATH": "/home/<username>/seeed-kicad-mcp/src"
  }
}
```

### 5.5 EasyEDA Pro MCP — Optional Full GUI Automation

**Repo:** github.com/teileelektronik/easyeda-mcp

Use when EasyEDA Pro (free desktop app) is installed on Windows and you want fully autonomous
design from component search through manufacturing export with visual feedback at each step.

Architecture:
```
Claude Code → MCP (stdio) → MCP Server (72 tools) → Claude API (Layer 3 AI-assisted tools)
                                                    → JLCPCB/LCSC API (component search)
                                                    → WebSocket :18601
                                                    → Bridge Extension (267 methods)
                                                    → EasyEDA Pro Desktop
```

Three layers of tools:
- **Layer 1:** Atomic operations (place component, add wire, etc.)
- **Layer 2:** Compound workflows (route power rails, add decoupling caps to all power pins)
- **Layer 3:** LLM-orchestrated multi-step tasks — sends task + engineering knowledge to Claude,
  plans a sequence of Layer 1/2 calls, executes with verification, recovers from errors

**Prerequisites:** EasyEDA Pro desktop app must be running on Windows before the MCP server starts.
Download from easyeda.com/page/download.

Install:

```bash
git clone https://github.com/teileelektronik/easyeda-mcp.git ~/easyeda-mcp
cd ~/easyeda-mcp
npm install && npm run build
```

Install the bridge extension in EasyEDA Pro:
- Top Menu → Settings → Extensions → Extension Manager → Import
- Select: `~/easyeda-mcp/src/bridge/dist/`

Add to MCP config (add separately when using this workflow, not in the combined config):

```json
"easyeda": {
  "command": "node",
  "args": ["/home/<username>/easyeda-mcp/dist/server/index.js"],
  "env": {
    "ANTHROPIC_API_KEY": "sk-ant-..."
  }
}
```

No LCSC/JLCPCB API key needed — component search uses public endpoints. If both
ANTHROPIC_API_KEY and GEMINI_API_KEY are set, Claude takes priority.

**Full-board example prompt for EasyEDA MCP:**

```
Design a USB-C powered ESP32-S3 board with:
- USB-C with PD sink (5V/9V)
- 3.3V LDO from VBUS
- SPI TFT display connector (4-wire SPI)
- I2S DAC (PCM5102A) for audio output
- 3 tactile buttons with hardware debouncing
- WS2812B RGB LED
Run full DRC on both schematic and PCB.
Export manufacturing files (Gerbers, BOM, pick-and-place).
```

### 5.6 EDA Tools MCP — FPGA / Verilog Synthesis

**Registry:** pulsemcp.com/servers/eda-tools

For Verilog synthesis, simulation, ASIC design flows, and waveform analysis. Not for discrete PCB
design — use for FPGA targets or digital logic verification workflows.

Required backend tools:

```bash
sudo apt-get install -y yosys iverilog

# For iCE40 FPGA targets:
sudo apt-get install -y nextpnr-ice40 icestorm
```

Add to MCP config:

```json
"eda-tools": {
  "command": "npx",
  "args": ["-y", "eda-mcp"]
}
```

---

## 6. Claude Code Skills — kicad-happy

**Repo:** github.com/aklofas/kicad-happy

12 Claude Code skills for KiCad electronics design. These install as agent skills, not MCP servers.
Validated against 5,800+ open-source KiCad projects spanning hobby boards, production hardware,
motor controllers, RF frontends, BMS, audio amplifiers, 2-layer through 6-layer.

### 6.1 Install

```bash
git clone https://github.com/aklofas/kicad-happy.git ~/kicad-happy
cd ~/kicad-happy

mkdir -p ~/.claude/skills
for skill in kicad spice emc datasheets bom digikey mouser lcsc element14 jlcpcb pcbway kidoc; do
    ln -sf "$(pwd)/skills/$skill" ~/.claude/skills/$skill
done
```

### 6.2 Skill Reference

| Skill | Function | Auth Required |
|---|---|---|
| `kicad` | Schematic/PCB analysis, layout review, DRC interpretation | None |
| `spice` | SPICE simulation and waveform analysis | None (needs ngspice or LTspice) |
| `emc` | EMC pre-compliance checks, IPC-2141/IPC-7711 references | None |
| `datasheets` | Download datasheets from LCSC, DigiKey, Mouser, Element14 | None for LCSC |
| `bom` | BOM generation, CSV/JSON output, cross-referencing | None |
| `digikey` | DigiKey component search and pricing | DigiKey API key |
| `mouser` | Mouser component search and pricing | Mouser API key |
| `lcsc` | LCSC component search and pricing | None |
| `element14` | Element14/Farnell component search | None |
| `jlcpcb` | JLCPCB parts catalog, pricing, assembly tiers | None |
| `pcbway` | PCBWay DFM analysis and pricing | None |
| `kidoc` | KiCad documentation lookup, scripting API reference | None |

Two-tier PR review: deterministic schematic/PCB analysis runs with no API key. AI-powered review
requires `ANTHROPIC_API_KEY` set in the environment.

---

## 7. circuit-synth — Python-Based Alternative

**Repo:** github.com/circuit-synth/circuit-synth

Python-defined circuits with KiCad integration. Use this when generating circuits programmatically
in Python is preferred over the Zener DSL, or when systematically modifying existing KiCad projects.
Fully bi-directional — imports existing `.kicad_sch` files into Python for modification.

Use circuit-synth when:
- The prompt involves repeated or parameterized subcircuit blocks
- Modifying an existing KiCad schematic systematically
- The circuit structure maps cleanly to Python functions

Use Zener/pcb when:
- Starting from chip datasheets or reference designs
- The Diode reference library at zener.diode.computer has relevant examples
- Fine-grained ERC validation during authoring is needed

### 7.1 Install

```bash
pip3 install circuit-synth

# Verify with the example project
cs-new-project smoke_test
cd smoke_test
python3 main.py
# Generates ESP32_C6_Dev_Board/ESP32_C6_Dev_Board.kicad_pro
```

### 7.2 Circuit Definition Pattern

```python
from circuit_synth import *

@circuit(name="Power_Supply")
def power_supply(vbus_in, vcc_3v3_out, gnd):
    """5V to 3.3V power regulation"""
    regulator = Component(
        symbol="Regulator_Linear:AMS1117-3.3",
        ref="U",
        footprint="Package_TO_SOT_SMD:SOT-223-3_TabPin2"
    )
    cap_in  = Component(symbol="Device:C", ref="C", value="10uF",
                        footprint="Capacitor_SMD:C_0805_2012Metric")
    cap_out = Component(symbol="Device:C", ref="C", value="22uF",
                        footprint="Capacitor_SMD:C_0805_2012Metric")
    regulator["VI"] += vbus_in
    regulator["VO"] += vcc_3v3_out
    regulator["GND"] += gnd
    cap_in[1] += vbus_in;    cap_in[2]  += gnd
    cap_out[1] += vcc_3v3_out; cap_out[2] += gnd

@circuit(name="Main_Circuit")
def main_circuit():
    vbus = Net("VBUS")
    vcc_3v3 = Net("VCC_3V3")
    gnd = Net("GND")
    power_supply(vbus, vcc_3v3, gnd)

if __name__ == "__main__":
    circuit = main_circuit()
    circuit.generate_kicad_project("my_board")
```

---

## 8. EDA Tools MCP — FPGA/ASIC Path

For Verilog synthesis targeting FPGA (iCE40, Xilinx) or ASIC flows. Separate concern from PCB
design — use for digital hardware or when validating HDL alongside a PCB design.

Backend tools required before the MCP server will work:

```bash
sudo apt-get install -y yosys iverilog

# iCE40 FPGA:
sudo apt-get install -y nextpnr-ice40 icestorm

# Xilinx Vivado (separate download from xilinx.com — large install):
# Use Vivado MCP if targeting Xilinx FPGAs
```

Example synthesis prompt:

```
Synthesize this Verilog counter module for an iCE40 FPGA and report logic cell usage:

module counter(
  input clk, input rst, output [7:0] count
);
  reg [7:0] count_reg;
  assign count = count_reg;
  always @(posedge clk or posedge rst) begin
    if (rst) count_reg <= 8'b0;
    else     count_reg <= count_reg + 1;
  end
endmodule
```

---

## 9. Complete MCP Config

Drop this into your Claude Desktop or Claude Code MCP config file. Replace all `<username>` and
absolute path placeholders before use.

**Config file locations:**

- Claude Desktop (Windows): `%APPDATA%\Claude\claude_desktop_config.json`
- Claude Code (WSL, project-level): `.claude/claude_desktop_config.json`
- Claude Code (WSL, global): `~/.config/Claude/claude_desktop_config.json`

```json
{
  "mcpServers": {

    "pcbparts": {
      "command": "npx",
      "args": ["-y", "mcp-remote", "https://pcbparts.dev/mcp"]
    },

    "jlc": {
      "command": "node",
      "args": ["/home/<username>/ai-eda/packages/jlc-mcp/dist/index.js"]
    },

    "kicad": {
      "command": "node",
      "args": ["/home/<username>/KiCAD-MCP-Server/dist/index.js"],
      "env": {
        "NODE_ENV": "production",
        "PYTHONPATH": "/mnt/c/Program Files/KiCad/9.0/lib/python3/dist-packages",
        "LOG_LEVEL": "info"
      }
    },

    "kicad-seeed": {
      "type": "stdio",
      "command": "python3",
      "args": ["-m", "kicad_mcp_server"],
      "cwd": "/home/<username>/seeed-kicad-mcp",
      "env": {
        "PYTHONPATH": "/home/<username>/seeed-kicad-mcp/src"
      }
    },

    "eda-tools": {
      "command": "npx",
      "args": ["-y", "eda-mcp"]
    }

  }
}
```

> **Note:** easyeda-mcp is excluded from this combined config. EasyEDA Pro must be running before
> the MCP server is started — add it in a separate config or session when using that workflow.

---

## 10. Environment Verification

### 10.1 Automated Verification Script

Save as `~/verify_hardware_env.sh` and run after setup. All checks must pass.

```bash
#!/bin/bash
set -e
echo "=== Claude Hardware Design Environment Check ==="

echo "[1] Node.js..."
node --version | grep -E 'v(1[89]|[2-9][0-9])\.' || (echo "FAIL: Node < 18" && exit 1)

echo "[2] Python..."
python3 -c "import sys; assert sys.version_info >= (3,8), 'Python too old'" \
  || (echo "FAIL: Python < 3.8" && exit 1)
python3 --version

echo "[3] Rust..."
rustc --version || (echo "FAIL: Rust not installed" && exit 1)

echo "[4] KiCad Python API..."
python3 -c "import pcbnew; print(pcbnew.GetBuildVersion())" \
  || (echo "FAIL: KiCad Python API not found — check PYTHONPATH" && exit 1)

echo "[5] pcb CLI (Diode Zener)..."
pcb --version || (echo "FAIL: pcb not in PATH — run ~/pcb/install.sh" && exit 1)

echo "[6] KiCAD-MCP-Server build..."
test -f ~/KiCAD-MCP-Server/dist/index.js \
  || (echo "FAIL: KiCAD-MCP-Server not built — run npm run build" && exit 1)

echo "[7] Seeed KiCad MCP..."
python3 -c "import sys; sys.path.insert(0, '$HOME/seeed-kicad-mcp/src'); import kicad_mcp_server" \
  || echo "WARN: Seeed KiCad MCP not installed"

echo "[8] circuit-synth..."
python3 -c "import circuit_synth" || echo "WARN: circuit-synth not installed"

echo "[9] Claude Code..."
claude --version || (echo "FAIL: claude alias not configured" && exit 1)

echo ""
echo "=== All required checks passed ==="
```

```bash
chmod +x ~/verify_hardware_env.sh && ~/verify_hardware_env.sh
```

### 10.2 Functional Smoke Test

Compile a minimal Zener file to verify the end-to-end authoring pipeline:

```bash
mkdir -p ~/designs/smoke_test && cd ~/designs/smoke_test

cat > smoke.zen << 'EOF'
# Minimal LED + resistor smoke test
R1 = Component(
    symbol='Device:R', ref='R', value='330R',
    footprint='Resistor_SMD:R_0402_1005Metric'
)
LED1 = Component(
    symbol='Device:LED', ref='D',
    footprint='LED_SMD:LED_0402_1005Metric'
)
vcc = Net('VCC')
gnd = Net('GND')
R1[1] += vcc
R1[2] += LED1['A']
LED1['K'] += gnd
EOF

pcb build smoke.zen
echo "Smoke test passed — Zener + pcb CLI working"
```

---

## 11. Agent Decision Logic

Use this logic to select the correct tool for a given design task.

### 11.1 Schematic Authoring Path

```
Input: text prompt describing hardware

Is the design primarily digital (FPGA, ASIC, Verilog/VHDL)?
  YES → Use EDA Tools MCP (Section 8)
  NO  → Continue

Does the prompt reference a specific chip and its datasheet?
  YES → Use Diode Zener + pcb CLI (Section 4)
        Load relevant reference from zener.diode.computer
        Query pcbparts-mcp for supporting passives

Is the prompt a full-board description needing a GUI and visual DRC feedback?
  YES → Use EasyEDA Pro MCP (Section 5.5) if EasyEDA Pro is running
  NO  → Continue

Is the circuit structure best expressed as parameterized Python functions,
or does it involve modifying an existing .kicad_sch file?
  YES → Use circuit-synth (Section 7)
  NO  → Use Diode Zener + pcb CLI (Section 4) — default path
```

### 11.2 Component Selection Order

For every component in a design, follow this order:

1. Query `pcbparts-mcp` first — it covers JLCPCB, Mouser, and DigiKey and provides
   KiCad footprints, pinout data, and real-board usage patterns
2. Filter for `in_stock=true` and, where possible, `basic_only=true` for JLCPCB basic library parts
   (no extra setup fee at JLCPCB)
3. Use `@jlcpcb/mcp` to install the symbol and footprint into KiCad if pcbparts-mcp does not
   provide a footprint directly
4. If parametric search returns no result, use `pcbparts-mcp` sensor recommendation or the
   reference board search to find how similar designs solved the same problem

### 11.3 Validation Order

After schematic is generated, run checks in this order:

1. `pcb build` — Zener ERC before generating KiCad files
2. KiCad ERC via `kicad-seeed` or `mixelpixx/KiCAD-MCP-Server`
3. KiCad DRC via `mixelpixx/KiCAD-MCP-Server`
4. `kicad-happy/emc` skill — EMC pre-compliance
5. BOM export via `kicad-happy/bom` skill
6. Gerber export via `mixelpixx/KiCAD-MCP-Server`

### 11.4 What Requires Human Review

Do not pass any of the following to manufacturing without explicit human engineer review:

- Any design for medical, automotive, aerospace, or safety-critical applications
- Designs with mains voltage (> 50V AC or > 75V DC)
- RF designs (antenna matching, impedance-controlled traces)
- High-current power stages (> 5A continuous)
- Any schematic generated for a first-time design on a new chip family

AI-generated schematics from any tool in this stack are starting points, not finished designs.

---

## 12. Quick Reference Tables

### Repository Index

| Tool | Repository |
|---|---|
| Diode pcb + Zener CLI | github.com/diodeinc/pcb |
| Diode reference designs | zener.diode.computer |
| Anthropic AI-EDA (jlc-mcp) | github.com/anthropics/ai-eda |
| mixelpixx KiCAD-MCP-Server | github.com/mixelpixx/KiCAD-MCP-Server |
| Seeed Studio KiCad MCP | github.com/Seeed-Studio/kicad-mcp-server |
| kicad-happy Claude Code skills | github.com/aklofas/kicad-happy |
| EasyEDA Pro MCP | github.com/teileelektronik/easyeda-mcp |
| EasyEDA Pro analyzer | github.com/badbat75/easyeda-pro-analyzer |
| pcbparts-mcp | github.com/Averyy/pcbparts-mcp |
| circuit-synth | github.com/circuit-synth/circuit-synth |
| claude-eda CLI | mcpxel.com/skills/claude-eda |

### Tool Stack by Use Case

| Use Case | Primary Tool | Supporting Tools |
|---|---|---|
| Chip reference design from datasheet | Diode Zener + pcb CLI | pcbparts-mcp, kicad-happy/datasheets |
| Full board from natural language prompt | EasyEDA Pro MCP | pcbparts-mcp |
| MCU board needing device tree (.dts) | Seeed KiCad MCP | kicad-happy/kicad |
| Python-parameterized circuit | circuit-synth | kicad-happy/kicad |
| DRC / BOM / Gerber export | mixelpixx KiCAD-MCP | kicad-happy/bom |
| Component sourcing and footprints | pcbparts-mcp | @jlcpcb/mcp |
| FPGA / Verilog synthesis | EDA Tools MCP | yosys, iverilog |
| EMC pre-compliance review | kicad-happy/emc | kicad-happy/spice |
| Inspect existing EasyEDA .eprj file | easyeda-pro-analyzer | — |

### Known Limitations

| Issue | Detail |
|---|---|
| pcb CLI Windows native | Experimental — always run inside WSL2 |
| KiCad Python API in WSL | Requires correct PYTHONPATH pointing to Windows KiCad install |
| EasyEDA Pro MCP startup order | EasyEDA Pro desktop must be running before MCP server starts |
| circuit-synth auto-numbering | Re-import from KiCad after manual ref designator changes |
| kicad-happy DigiKey/Mouser | Paid API keys required for those two skills; LCSC/JLCPCB free |
| Seeed KiCad MCP PCB editing | Schematic editing stable; PCB layout editing marked experimental |
| All AI-generated schematics | Require qualified engineering review before fabrication |

---

*Compiled May 2026. Verify all repo URLs and install procedures against upstream sources before
running — the hardware EDA MCP ecosystem is moving fast. Core reference:
claude.com/blog/making-claude-a-better-electrical-engineer*
