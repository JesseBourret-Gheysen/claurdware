# Claude Hardware Design Environment
## Agent Setup Reference — CLAUDE.md

This file is written for Claude Code agents. Read it fully before beginning any hardware design task.
It describes the complete text-prompt-to-schematic pipeline: tools, install paths, workflows, and
decision logic for choosing between approaches.

**Platform:** Docker container (`claurdware`) running on Linux. All tools are pre-installed in the
container. The host Claude Code instance calls MCP servers via `docker exec`. Designs are persisted
to the `./designs` volume.

---

## Table of Contents

0. [Docker Workflow](#0-docker-workflow)
1. [Stack Overview](#1-stack-overview)
2. [Environment Verification](#2-environment-verification)
3. [KiCad 9.0 — Container Setup](#3-kicad-90--container-setup)
4. [Diode Zener + pcb CLI — Primary Path](#4-diode-zener--pcb-cli--primary-path)
5. [MCP Servers](#5-mcp-servers)
6. [Claude Code Skills — kicad-happy](#6-claude-code-skills--kicad-happy)
7. [circuit-synth — Python-Based Alternative](#7-circuit-synth--python-based-alternative)
8. [EDA Tools MCP — FPGA/ASIC Path](#8-eda-tools-mcp--fpgaasic-path)
9. [Complete MCP Config](#9-complete-mcp-config)
10. [Environment Verification Script](#10-environment-verification-script)
11. [Agent Decision Logic](#11-agent-decision-logic)
12. [Quick Reference Tables](#12-quick-reference-tables)

---

## 0. Docker Workflow

Everything runs inside the `claurdware` container. Never install tools on the host for this stack.

### First-time setup

```bash
# 1. Build the image (~10 min first run — downloads and compiles all tools)
docker build -t claurdware .

# 2. Start the container
docker compose up -d

# 3. Verify all tools are working
docker exec -it claurdware /opt/scripts/verify_env.sh

# 4. Install kicad-happy Claude Code skills on the HOST
bash scripts/install_host_skills.sh

# 5. Add MCP servers to host Claude Code config
#    Copy config/mcp_servers.json content into:
#    ~/.config/Claude/claude_desktop_config.json
#    Then restart Claude Code.
```

### Running designs

```bash
# Interactive shell in the container
docker exec -it claurdware bash

# Build/validate a Zener design
docker exec -it claurdware pcb build /designs/<project>/main.zen

# Run Python circuit-synth design
docker exec -it claurdware python3 /designs/<project>/main.py
```

### Persisted paths

| Host path | Container path | Contents |
|---|---|---|
| `./designs/` | `/designs/` | Your design projects (bind mount) |
| `kicad-data` volume | `/root/KiCad/` | KiCad user settings + 3rd-party libraries |

---

## 1. Stack Overview

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

## 2. Environment Verification

Before starting any design task, verify the container is healthy:

```bash
docker exec -it claurdware /opt/scripts/verify_env.sh
```

All `[N]` checks must pass. `WARN` items are optional tools.

To check a specific tool manually:

```bash
# pcb CLI
docker exec -it claurdware pcb --version

# pcbnew Python API
docker exec -it claurdware python3 -c "import pcbnew; print(pcbnew.GetBuildVersion())"

# kicad-cli
docker exec -it claurdware kicad-cli --version
```

---

## 3. KiCad 9.0 — Container Setup

KiCad 9.0 is pre-installed in the container via `ppa:kicad/kicad-9.0-releases`. The Python
scripting API (`pcbnew`) is available inside the container. No Windows install is needed.

### Python API path

The entrypoint script (`/opt/scripts/entrypoint.sh`) reads `/etc/pcbnew_path` and exports it as
`PYTHONPATH` automatically. To verify:

```bash
docker exec -it claurdware python3 -c "import pcbnew; print(pcbnew.GetBuildVersion())"
```

If this fails, check the stored path:

```bash
docker exec -it claurdware cat /etc/pcbnew_path
docker exec -it claurdware find /usr -name "pcbnew.py" 2>/dev/null
```

### kicad-cli

`kicad-cli` is installed at `/usr/bin/kicad-cli` and available in `PATH`:

```bash
docker exec -it claurdware kicad-cli --version
```

### Headless limitation

`pcb layout` opens the KiCad GUI and **does not work** inside the headless container.
Use `pcb build` for schematic generation and validation; use `kicad-cli` for export operations.

---

## 4. Diode Zener + pcb CLI — Primary Path

This is the Anthropic-validated, Claude-native schematic authoring path.

**Background:** Diode Computers partnered with Anthropic to develop this pipeline. Claude was given
file I/O tools, bash execution, access to the Zener compiler, and Zener documentation. In blind
head-to-head evaluations by Diode's electrical engineers, Claude Sonnet 4.5 reference designs were
preferred 8/10 times overall, 60/40 over Opus 4, and 82/18 over Sonnet 4.

250+ published reference designs covering sensors, MCUs, power stages, and analog chains are
available at zener.diode.computer.

**Installed at:** `/opt/pcb` — binary in `PATH` as `pcb`

### 4.1 Zener Language Reference for Agent Use

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

### 4.2 pcb CLI Command Reference

| Command | Description |
|---|---|
| `pcb build [PATH]` | Build and validate .zen files — reports ERC and type errors |
| `pcb open [PATH]` | Open existing KiCad layout (requires GUI — not available headlessly) |
| `pcb fmt [PATH]` | Format .zen files using ruff fmt |

PATH can be a .zen file or a directory. When omitted, operates on the current directory.

**Note:** `pcb layout` is omitted — it opens KiCad GUI and does not work in the container.
Use `kicad-cli` for exporting schematics after `pcb build` succeeds.

### 4.3 Agent Workflow: Text Prompt to Schematic

Follow this sequence for any hardware design request using the Zener path:

1. Create a project directory inside the designs volume:
   ```bash
   docker exec -it claurdware mkdir -p /designs/<project_name>
   ```

2. Query `pcbparts-mcp` to find real in-stock components matching the design requirements.
   Record LCSC part numbers, values, and footprints for each major component before writing any .zen.

3. Write `/designs/<project_name>/main.zen` using Zener syntax. Reference components by their
   KiCad symbol strings. Use the reference designs at zener.diode.computer as patterns.

4. Validate:
   ```bash
   docker exec -it claurdware pcb build /designs/<project_name>/main.zen
   # Iterate on errors until clean
   ```

5. Export schematic via kicad-cli after generating the KiCad project:
   ```bash
   docker exec -it claurdware kicad-cli sch export pdf /designs/<project_name>/<project>.kicad_sch
   ```

6. Pass the KiCad project to `kicad` MCP server for DRC, ERC, BOM export, and Gerber generation.

### 4.4 Common Errors and Fixes

| Error | Cause | Fix |
|---|---|---|
| `symbol not found` | Wrong library:symbol string | Check KiCad library browser or pcbparts-mcp pinout data |
| `footprint not found` | Footprint path incorrect | Use standard KiCad footprint names from pcbparts-mcp |
| `net has only one connection` | Dangling net | All nets need at least two connected pins |
| `duplicate ref designator` | Two components with same ref | Use unique ref strings or let Zener auto-assign |

---

## 5. MCP Servers

All MCP servers are accessed from the **host** Claude Code instance. Local servers run via
`docker exec` into the container. See `config/mcp_servers.json` for the complete host config.

### 5.1 pcbparts-mcp — Component Sourcing (No Auth Required)

**Endpoint:** https://pcbparts.dev/mcp
**Install:** Remote HTTP — no local install needed.

Covers JLCPCB, Mouser, and DigiKey from one server. 1.5M+ parts with parametric filtering,
KiCad footprint downloads, pinout data, sensor recommendation across 1,500+ sensors, and 41
curated PCB design reference files.

**Queries this server handles well:**

- `"Find logic-level MOSFETs with Vgs(th) < 2V and Id >= 5A in stock at JLCPCB"`
- `"Search STM32F411 — show pricing and stock at JLCPCB"`
- `"Get KiCad footprint for ESP32-S3-WROOM-1"`
- `"What sensor measures CO2 with I2C, compatible with ESP32, in stock?"`
- `"Show how MCP73831 is typically used in real boards"`
- `"What are the design rules for USB-C?"`

### 5.2 mixelpixx/KiCAD-MCP-Server — Full KiCad Control

**Installed at:** `/opt/KiCAD-MCP-Server` (built, `dist/index.js` present)
**Accessed via:** `docker exec -i claurdware node /opt/KiCAD-MCP-Server/dist/index.js`

Capabilities: project setup, schematic editing, component placement, routing, DRC/ERC, custom symbol
and footprint generation, JLCPCB parts catalog with pricing and stock, export (Gerbers, PDF, SVG,
STEP/VRML 3D, BOM).

### 5.3 Seeed-Studio/kicad-mcp-server — Embedded/MCU Focus

**Installed at:** `/opt/seeed-kicad-mcp`
**Accessed via:** `docker exec -i claurdware /opt/venv/bin/python3 -m kicad_mcp_server`
**PYTHONPATH:** `/opt/seeed-kicad-mcp/src`

39 tools in 7 categories. Use when the design is MCU-heavy and you need device tree (.dts)
generation for STM32, pin conflict detection, or C test code generated alongside the schematic.

Tool categories: Analysis, Validation (DRC/ERC, pin conflicts), Pin Analysis (STM32 and 5 other
MCU families), Code Generation (12 tools including .dts and test code), Editing, Project Management.

### 5.4 EDA Tools MCP — FPGA / Verilog Synthesis

For Verilog synthesis, simulation, ASIC design flows, and waveform analysis.

yosys and iverilog are pre-installed in the container. The MCP server itself runs on the host via
npx (fetched on demand — no local install needed).

---

## 6. Claude Code Skills — kicad-happy

**Installed at:** `/opt/kicad-happy` (inside container)
**Host install:** Run `bash scripts/install_host_skills.sh` on the host to symlink skills into
`~/.claude/skills/`. Restart Claude Code after running.

12 Claude Code skills for KiCad electronics design. Validated against 5,800+ open-source KiCad
projects.

### Skill Reference

| Skill | Function | Auth Required |
|---|---|---|
| `kicad` | Schematic/PCB analysis, layout review, DRC interpretation | None |
| `spice` | SPICE simulation and waveform analysis | None (ngspice installed in container) |
| `emc` | EMC pre-compliance checks, IPC-2141/IPC-7711 references | None |
| `datasheets` | Download datasheets from LCSC, DigiKey, Mouser, Element14 | None for LCSC |
| `bom` | BOM generation, CSV/JSON output, cross-referencing | None |
| `lcsc` | LCSC component search and pricing | None |
| `element14` | Element14/Farnell component search | None |
| `jlcpcb` | JLCPCB parts catalog, pricing, assembly tiers | None |
| `pcbway` | PCBWay DFM analysis and pricing | None |
| `kidoc` | KiCad documentation lookup, scripting API reference | None |
| `digikey` | DigiKey component search and pricing | DigiKey API key |
| `mouser` | Mouser component search and pricing | Mouser API key |

---

## 7. circuit-synth — Python-Based Alternative

**Installed in venv:** `/opt/venv` — `import circuit_synth` works directly
**Repo:** github.com/circuit-synth/circuit-synth

Python-defined circuits with KiCad integration. Fully bi-directional — imports existing
`.kicad_sch` files into Python for modification.

Use circuit-synth when:
- The prompt involves repeated or parameterized subcircuit blocks
- Modifying an existing KiCad schematic systematically
- The circuit structure maps cleanly to Python functions

Use Zener/pcb when:
- Starting from chip datasheets or reference designs
- The Diode reference library at zener.diode.computer has relevant examples
- Fine-grained ERC validation during authoring is needed

### Circuit Definition Pattern

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

Run inside the container:

```bash
docker exec -it claurdware python3 /designs/<project>/main.py
```

---

## 8. EDA Tools MCP — FPGA/ASIC Path

For Verilog synthesis targeting FPGA (iCE40, Xilinx) or ASIC flows.

Backend tools installed in the container: `yosys`, `iverilog`, `nextpnr-ice40`, `fpga-icestorm`.

The MCP server runs on the host via npx (no local install needed):

```json
"eda-tools": {
  "command": "npx",
  "args": ["-y", "eda-mcp"]
}
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

The file `config/mcp_servers.json` in this repo is the complete host MCP config.

Copy its contents into your host Claude Code global config:

```bash
# Claude Code global config (Linux)
~/.config/Claude/claude_desktop_config.json
```

All `command: "docker"` entries require the `claurdware` container to be running
(`docker compose up -d`) before Claude Code is started.

**Summary of servers:**

| Server | Transport | Notes |
|---|---|---|
| `pcbparts` | Remote HTTP (npx mcp-remote) | No container needed |
| `kicad` | stdio via docker exec | Container must be running |
| `kicad-seeed` | stdio via docker exec | Container must be running |
| `eda-tools` | Local (npx on-demand) | No container needed |

---

## 10. Environment Verification Script

Run this inside the container to verify all tools are functional:

```bash
docker exec -it claurdware /opt/scripts/verify_env.sh
```

Expected: all numbered checks pass, WARN items are optional.

---

## 11. Agent Decision Logic

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

Is the circuit structure best expressed as parameterized Python functions,
or does it involve modifying an existing .kicad_sch file?
  YES → Use circuit-synth (Section 7)
  NO  → Use Diode Zener + pcb CLI (Section 4) — default path
```

### 11.2 Component Selection Order

For every component in a design, follow this order:

1. Query `pcbparts-mcp` first — covers JLCPCB, Mouser, and DigiKey; provides KiCad footprints,
   pinout data, and real-board usage patterns
2. Filter for `in_stock=true` and, where possible, `basic_only=true` for JLCPCB basic parts
   (no extra setup fee)
3. If parametric search returns no result, use `pcbparts-mcp` sensor recommendation or the
   reference board search to find how similar designs solved the same problem

### 11.3 Validation Order

After schematic is generated, run checks in this order:

1. `pcb build` — Zener ERC before generating KiCad files
2. KiCad ERC via `kicad-seeed` or `kicad` MCP server
3. KiCad DRC via `kicad` MCP server
4. `kicad-happy/emc` skill — EMC pre-compliance
5. BOM export via `kicad-happy/bom` skill
6. Gerber export via `kicad` MCP server

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

### Tool Paths (inside container)

| Tool | Path |
|---|---|
| pcb CLI (Zener) | in `PATH` — built from `/opt/pcb` |
| KiCAD-MCP-Server | `/opt/KiCAD-MCP-Server/dist/index.js` |
| Seeed KiCad MCP | `/opt/seeed-kicad-mcp` (Python module) |
| kicad-happy skills | `/opt/kicad-happy/skills/` |
| Python venv | `/opt/venv` |
| circuit-synth | `/opt/venv` (pip installed) |
| Designs volume | `/designs/` |
| pcbnew Python path | stored in `/etc/pcbnew_path` |

### Repository Index

| Tool | Repository |
|---|---|
| Diode pcb + Zener CLI | github.com/diodeinc/pcb |
| Diode reference designs | zener.diode.computer |
| mixelpixx KiCAD-MCP-Server | github.com/mixelpixx/KiCAD-MCP-Server |
| Seeed Studio KiCad MCP | github.com/Seeed-Studio/kicad-mcp-server |
| kicad-happy Claude Code skills | github.com/aklofas/kicad-happy |
| circuit-synth | github.com/circuit-synth/circuit-synth |
| pcbparts-mcp | pcbparts.dev/mcp (remote) |

### Tool Stack by Use Case

| Use Case | Primary Tool | Supporting Tools |
|---|---|---|
| Chip reference design from datasheet | Diode Zener + pcb CLI | pcbparts-mcp, kicad-happy/datasheets |
| MCU board needing device tree (.dts) | Seeed KiCad MCP | kicad-happy/kicad |
| Python-parameterized circuit | circuit-synth | kicad-happy/kicad |
| DRC / BOM / Gerber export | kicad MCP (mixelpixx) | kicad-happy/bom |
| Component sourcing and footprints | pcbparts-mcp | — |
| FPGA / Verilog synthesis | EDA Tools MCP | yosys, iverilog (in container) |
| EMC pre-compliance review | kicad-happy/emc | kicad-happy/spice |

### Known Limitations

| Issue | Detail |
|---|---|
| `pcb layout` | Opens KiCad GUI — not available in headless container |
| KiCad library installs | 3rd-party libraries install to `/root/KiCad/` (persisted in named volume) |
| kicad-happy DigiKey/Mouser skills | Paid API keys required; LCSC/JLCPCB are free |
| Seeed KiCad MCP PCB editing | Schematic editing stable; PCB layout editing marked experimental |
| All AI-generated schematics | Require qualified engineering review before fabrication |

---

*Adapted for Docker/Linux — May 2026. Original Windows/WSL2 reference at `CLAUDE_HARDWARE_DESIGN.md`.*
