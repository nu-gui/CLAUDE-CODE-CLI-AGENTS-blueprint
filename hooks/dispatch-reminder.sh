#!/bin/bash
# Dispatch Gate Reminder Hook
# This hook runs on prompt submit to remind about the dispatch protocol
# Note: This is advisory - true enforcement is in CLAUDE.md

# Output reminder (this will be shown to Claude as hook feedback)
echo "DISPATCH GATE REMINDER: Before proceeding, complete the mandatory dispatch evaluation from the UNIFIED DISPATCH GATE in CLAUDE.md."
echo "You MUST output a DISPATCH DECISION block before taking any action."

# Always exit 0 (non-blocking reminder)
exit 0
