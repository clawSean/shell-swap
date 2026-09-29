#!/bin/sh
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
/bin/sh -n "$SCRIPT_DIR/switch.sh"
python3 "$SCRIPT_DIR/test_switch.py" -v
