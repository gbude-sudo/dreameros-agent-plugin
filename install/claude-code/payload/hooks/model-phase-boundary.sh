#!/bin/bash
# Thin wrapper so this hook matches the existing bash-hook registration
# style in settings.json. Passes stdin straight through to Python
# untouched - the earlier debugging session that built this hook found
# that re-encoding the JSON through a shell echo (Windows backslash
# paths through Git Bash string escaping) corrupted the payload even
# though the underlying Python logic was correct. Piping stdin directly,
# as Claude Code itself does when it invokes a hook command, avoids that
# failure mode entirely - it was only ever a manual-testing artifact.
python "__DREAMEROS_CLAUDE_HOME__/hooks/model-phase-boundary.py"
