#!/usr/bin/env bash
# Runs every step's main scene headless for 120 frames and fails on any ERROR,
# SCRIPT ERROR or WARNING line (the project treats a warning as a bug), then lists
# the GDScript warnings of every script (tools/check_warnings.py).
# Usage: tools/smoke_steps.sh   (from anywhere)
set -u

project="$(cd "$(dirname "$0")/.." && pwd)"
failed=0

for step_dir in "$project"/steps/step_*/; do
	step="$(basename "$step_dir")"
	log="$(godot --headless --path "$project" --quit-after 120 "res://steps/$step/main.tscn" 2>&1)"
	code=$?
	problems="$(printf '%s\n' "$log" | grep -E 'ERROR|WARNING' || true)"
	if [ "$code" -ne 0 ] || [ -n "$problems" ]; then
		echo "FAIL $step (exit $code)"
		printf '%s\n' "$problems" | sed 's/^/     /'
		failed=1
	else
		echo "PASS $step"
	fi
done

# GDScript warnings are only reported by the editor, so ask a headless editor.
if python3 -I "$project/tools/check_warnings.py" "$project"; then
	echo "PASS check_warnings: no GDScript error or warning in the project"
else
	echo "FAIL check_warnings"
	failed=1
fi

exit "$failed"
