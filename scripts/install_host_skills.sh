#!/bin/bash
# Run this on the HOST (not inside the container) to install kicad-happy
# Claude Code skills into ~/.claude/skills/.
set -e

CONTAINER="${1:-claurdware}"

echo "Copying kicad-happy from container '${CONTAINER}'..."
docker cp "${CONTAINER}:/opt/kicad-happy" /tmp/kicad-happy

mkdir -p ~/.claude/skills

for skill in kicad spice emc datasheets bom lcsc element14 jlcpcb pcbway kidoc; do
    if [ -d "/tmp/kicad-happy/skills/${skill}" ]; then
        ln -sf "/tmp/kicad-happy/skills/${skill}" ~/.claude/skills/${skill}
        echo "  linked: ${skill}"
    else
        echo "  not found (skipped): ${skill}"
    fi
done

echo ""
echo "kicad-happy skills installed to ~/.claude/skills/"
echo "Restart Claude Code to load the new skills."
