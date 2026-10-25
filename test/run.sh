#!/usr/bin/env bash
# Run the mdpreview.nvim test suite with a clean, headless Neovim.
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
status=0

for spec in render_spec integration_spec; do
  echo "== ${spec} =="
  nvim --headless --clean \
    -u "$root/test/minimal_init.lua" \
    -l "$root/test/${spec}.lua" || status=1
  echo
done

exit "$status"
