#!/bin/bash

# Export pcbnew Python module path so MCP servers can import pcbnew
PCBNEW_PATH=$(cat /etc/pcbnew_path 2>/dev/null || echo "")
if [ -n "$PCBNEW_PATH" ]; then
    export PYTHONPATH="${PCBNEW_PATH}:${PYTHONPATH}"
fi

export PATH="/opt/venv/bin:/root/.cargo/bin:/root/.bun/bin:$PATH"

exec "$@"
