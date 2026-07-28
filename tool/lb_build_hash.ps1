# Prints the BUILD_HASH actually compiled into the built memscan exe - the ground truth for the
# leaderboard allowlist. Reads it from the exe's own `version` output, so it can NEVER drift from a
# stale/regenerated src/build_hash.g.odin (that file tracks the source tree, not the last compile).
# Used by set-lb-hash.bat. Exits non-zero (prints nothing) if the exe is missing or unparsable.
param([string]$Exe = "")
$ErrorActionPreference = "Stop"

# Only a REPL build can answer `version`: a MAIN-module build (build.bat <mode> <module>, see
# MAIN_MODULE in src/main.odin) opens its UI instead of reading stdin, so driving one would hang here.
# Its exe carries the module name (memscan-<ver>-<mode>-<module>[-tracy].exe) - that is how we skip it.
$MODULE_BUILD = '-(flyff)(-|\.)'

if (-not $Exe) {
    # Exe names carry version + variant now, so pick the newest REPL build in .out\debug.
    $repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
    $Exe = Get-ChildItem (Join-Path $repo ".out\debug") -Filter "memscan*.exe" -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch $MODULE_BUILD } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1 -ExpandProperty FullName
}
if (-not $Exe) { exit 1 }
if (-not (Test-Path $Exe)) { exit 1 }
# Explicitly-passed main-module exe: bail rather than block forever on a window that never reads stdin.
if ((Split-Path -Leaf $Exe) -match $MODULE_BUILD) { exit 3 }

# Drive the REPL: `version` prints "memscan v<ver> (build <hash>)", then quit.
$out = ("version", "quit" | & $Exe 2>$null) | Out-String
if ($out -match '\(build ([0-9a-f]+)\)') {
    Write-Output $Matches[1]
} else {
    exit 2
}
