# Prints the BUILD_HASH actually compiled into the built memscan.exe - the ground truth for the
# leaderboard allowlist. Reads it from the exe's own `version` output, so it can NEVER drift from a
# stale/regenerated src/build_hash.g.odin (that file tracks the source tree, not the last compile).
# Used by set-lb-hash.bat. Exits non-zero (prints nothing) if the exe is missing or unparsable.
param([string]$Exe = "")
$ErrorActionPreference = "Stop"

if (-not $Exe) {
    $repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
    $Exe = Join-Path $repo ".out\debug\memscan.exe"
}
if (-not (Test-Path $Exe)) { exit 1 }

# Drive the REPL: `version` prints "memscan v<ver> (build <hash>)", then quit.
$out = ("version", "quit" | & $Exe 2>$null) | Out-String
if ($out -match '\(build ([0-9a-f]+)\)') {
    Write-Output $Matches[1]
} else {
    exit 2
}
