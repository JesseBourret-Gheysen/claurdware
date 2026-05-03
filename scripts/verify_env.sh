#!/bin/bash
set -e
echo "=== Claurdware Environment Check ==="

echo "[1] Node.js..."
node --version | grep -E 'v(1[89]|[2-9][0-9])\.' || { echo "FAIL: Node < 18"; exit 1; }

echo "[2] Python..."
python3 -c "import sys; assert sys.version_info >= (3,8), 'Python too old'" \
    || { echo "FAIL: Python < 3.8"; exit 1; }
python3 --version

echo "[3] Rust..."
rustc --version || { echo "FAIL: Rust not installed"; exit 1; }

echo "[4] KiCad Python API (pcbnew)..."
PCBNEW_PATH=$(cat /etc/pcbnew_path 2>/dev/null || echo "")
PYTHONPATH="${PCBNEW_PATH}:${PYTHONPATH}" python3 -c \
    "import pcbnew; print('  pcbnew', pcbnew.GetBuildVersion())" \
    || { echo "FAIL: pcbnew not importable — check /etc/pcbnew_path"; exit 1; }

echo "[5] pcb CLI (Diode Zener)..."
pcb --version || { echo "FAIL: pcb not in PATH"; exit 1; }

echo "[6] KiCAD-MCP-Server build..."
test -f /opt/KiCAD-MCP-Server/dist/index.js \
    || { echo "FAIL: /opt/KiCAD-MCP-Server/dist/index.js not found"; exit 1; }
echo "  OK"

echo "[7] Seeed KiCad MCP..."
PYTHONPATH=/opt/seeed-kicad-mcp/src python3 -c "import kicad_mcp_server" \
    || echo "  WARN: kicad_mcp_server import failed"

echo "[8] circuit-synth..."
python3 -c "import circuit_synth; print('  circuit-synth OK')" \
    || echo "  WARN: circuit-synth not importable"

echo "[9] yosys..."
yosys --version || echo "  WARN: yosys not found"

echo "[10] iverilog..."
iverilog -V 2>&1 | head -1 || echo "  WARN: iverilog not found"

echo "[11] kicad-cli..."
kicad-cli --version || echo "  WARN: kicad-cli not found"

echo "[12] Zener smoke test..."
pcb build /opt/scripts/smoke.zen \
    && echo "  Zener smoke test passed" \
    || echo "  WARN: Zener smoke test failed"

echo ""
echo "=== All required checks passed ==="
