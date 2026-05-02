#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

resolve_powershell() {
  if [[ -n "${TIME_TRACKER_PWSH_PATH:-}" ]]; then
    printf '%s\n' "$TIME_TRACKER_PWSH_PATH"
    return 0
  fi

  local candidates=(
    "pwsh"
    "powershell"
    "/opt/homebrew/bin/pwsh"
    "/usr/local/bin/pwsh"
    "/Applications/PowerShell.app/Contents/MacOS/pwsh"
  )

  local candidate
  for candidate in "${candidates[@]}"; do
    if command -v "$candidate" >/dev/null 2>&1; then
      command -v "$candidate"
      return 0
    fi
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  printf 'Unable to locate pwsh or powershell. Set TIME_TRACKER_PWSH_PATH.\n' >&2
  return 1
}

PS_EXE="$(resolve_powershell)"
exec "$PS_EXE" -NoProfile -File "$SCRIPT_DIR/run.ps1" "$@"
