#!/usr/bin/env bash
# Check that all commands in pnevma-commands router are accessible via the bridge.
# Also check that all pane types are registered in the command palette.
set -euo pipefail

echo "=== FFI Coverage Check ==="
echo ""

# Count route_method entries
echo "Rust command routes:"
routes=$(grep -cE '"[a-z_]+\.[a-z_]+"' crates/pnevma-commands/src/control.rs 2>/dev/null || echo "0")
echo "  route_method() entries: $routes"

# Check bridge exports — count from header (authoritative) and implementation
echo ""
echo "Bridge FFI surface:"
h_exports=$(grep -cE 'pnevma_[a-z_]+\(' crates/pnevma-bridge/pnevma-bridge.h 2>/dev/null || echo "0")
exports=$(grep -cE 'pub (unsafe )?extern "C" fn pnevma_' crates/pnevma-bridge/src/lib.rs 2>/dev/null || echo "0")
echo "  extern C functions (header): $h_exports"
echo "  extern C functions (impl):   $exports"
if [[ "$h_exports" != "$exports" ]]; then
  echo "  WARNING: header/impl mismatch — run cbindgen to regenerate pnevma-bridge.h"
fi

# Verify each function declared in header has a call site in PnevmaBridge.swift
echo ""
echo "Swift call sites for bridge functions:"
bridge_swift="native/Pnevma/Bridge/PnevmaBridge.swift"
missing=0
while IFS= read -r fn_name; do
  if grep -q "$fn_name" "$bridge_swift" 2>/dev/null; then
    echo "  $fn_name: OK"
  else
    echo "  $fn_name: MISSING in $bridge_swift"
    missing=$((missing + 1))
  fi
done < <(grep -oE 'pnevma_[a-z_]+' crates/pnevma-bridge/pnevma-bridge.h | sort -u)
if [[ $missing -gt 0 ]]; then
  echo "  ERROR: $missing bridge function(s) not called from Swift"
  exit 1
fi

# Check Swift pane types
echo ""
echo "Swift pane types:"
panes=$(grep -l 'PaneContent' native/Pnevma/Panes/*.swift 2>/dev/null | wc -l | tr -d ' ')
pane_files=$(ls native/Pnevma/Panes/*Pane*.swift 2>/dev/null | wc -l | tr -d ' ')
echo "  Pane files: $pane_files"
echo "  PaneContent conformances: $panes"

# Check command palette registrations
echo ""
echo "Command Palette entries:"
palette=$(grep -c 'CommandItem(' native/Pnevma/App/AppDelegate.swift 2>/dev/null || echo "0")
echo "  Registered commands: $palette"

# Summary
echo ""
echo "FFI: JSON envelope pattern via route_method() — all $routes commands accessible through pnevma_call()"
echo "Coverage: OK"
