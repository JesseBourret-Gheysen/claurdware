FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# ── 1. Base system packages ───────────────────────────────────────────────────
RUN apt-get update && apt-get install -y \
    git curl wget build-essential \
    python3 python3-pip python3-venv \
    unzip ca-certificates \
    software-properties-common \
    gpg-agent \
    && rm -rf /var/lib/apt/lists/*

# ── 2. Node.js v20 ────────────────────────────────────────────────────────────
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# ── 3. FOSS EDA tools ─────────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y \
    yosys iverilog nextpnr-ice40 fpga-icestorm ngspice \
    && rm -rf /var/lib/apt/lists/*

# ── 4. KiCad 9.0 (headless — kicad-cli + pcbnew Python API) ──────────────────
RUN add-apt-repository -y ppa:kicad/kicad-9.0-releases \
    && apt-get update \
    && apt-get install -y kicad \
    && rm -rf /var/lib/apt/lists/*

# Detect and record pcbnew Python module directory for use in entrypoint
RUN PCBNEW_DIR=$(find /usr -name "pcbnew.py" 2>/dev/null | head -1 | xargs -I{} dirname {} 2>/dev/null) \
    && echo "${PCBNEW_DIR:-/usr/lib/python3/dist-packages}" > /etc/pcbnew_path \
    && echo "Stored pcbnew path: $(cat /etc/pcbnew_path)"

# ── 5. Rust toolchain ─────────────────────────────────────────────────────────
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
ENV PATH="/root/.cargo/bin:$PATH"

# ── 6. diodeinc/pcb — Zener DSL compiler ─────────────────────────────────────
RUN git clone https://github.com/diodeinc/pcb.git /opt/pcb \
    && cd /opt/pcb \
    && ./install.sh

# ── 7. bun ────────────────────────────────────────────────────────────────────
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/root/.bun/bin:$PATH"

# ── 8. mixelpixx/KiCAD-MCP-Server ────────────────────────────────────────────
RUN git clone https://github.com/mixelpixx/KiCAD-MCP-Server.git /opt/KiCAD-MCP-Server \
    && cd /opt/KiCAD-MCP-Server \
    && npm ci \
    && npm run build

# ── 9. Seeed-Studio/kicad-mcp-server ─────────────────────────────────────────
RUN git clone https://github.com/Seeed-Studio/kicad-mcp-server.git /opt/seeed-kicad-mcp

# ── 10. aklofas/kicad-happy (Claude Code skills — copied to host via script) ──
RUN git clone https://github.com/aklofas/kicad-happy.git /opt/kicad-happy

# ── 11. Python venv ───────────────────────────────────────────────────────────
RUN python3 -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

RUN pip install --upgrade pip \
    && pip install circuit-synth \
    && pip install -r /opt/KiCAD-MCP-Server/requirements.txt \
    && pip install -r /opt/seeed-kicad-mcp/requirements.txt

# ── 12. Workspace dirs ────────────────────────────────────────────────────────
RUN mkdir -p /designs /workspace

COPY scripts/ /opt/scripts/
RUN chmod +x /opt/scripts/*.sh

WORKDIR /workspace

ENTRYPOINT ["/opt/scripts/entrypoint.sh"]
CMD ["bash"]
