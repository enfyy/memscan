@echo off
setlocal EnableExtensions
REM ===========================================================================
REM set-lb-hash.bat - push the current client BUILD_HASH to the leaderboard
REM server's allowlist (LB_ALLOWED_HASHES) and restart it, so submissions from
REM the build you just made are accepted again. Run it right after build.bat.
REM
REM Usage:
REM   set-lb-hash.bat            reads the hash from src\build_hash.g.odin (last build)
REM   set-lb-hash.bat <hash>     use that hash instead (e.g. to re-allow a specific build)
REM   set-lb-hash.bat off        clear the allowlist (accept ANY build; rely on the secret)
REM ===========================================================================

REM --- deployment config (edit these if the VPS / user / key / path changes) ---
set "KEY=%USERPROFILE%\.ssh\memscan_vps_deploy"
set "HOST=enfy@46.225.107.90"
set "REMOTE_DIR=~/memscan-server"

REM --- determine the hash to set ---
REM We read it from the BUILT EXE (via tool\lb_build_hash.ps1), NOT src\build_hash.g.odin: that .g file
REM tracks the source tree and silently drifts from the compiled binary whenever source changes without a
REM rebuild (e.g. a VERSION bump), which would push a hash your running exe does not actually have.
set "HASH=%~1"
if /i "%HASH%"=="off" set "HASH="
if defined HASH goto :have_hash
if "%~1"=="off" goto :have_hash

for /f "usebackq delims=" %%h in (`powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tool\lb_build_hash.ps1"`) do set "HASH=%%h"
if not defined HASH (
  echo ERROR: could not read the build hash from .out\debug\memscan.exe - run build.bat first, or pass a hash explicitly.
  exit /b 1
)

:have_hash
if "%~1"=="off" (
  echo Clearing the leaderboard allowlist ^(server will accept ANY build; secret still gates^).
) else (
  echo Setting leaderboard allowlist to build hash: %HASH%
)
echo   server: %HOST%  ^(%REMOTE_DIR%^)
echo.

ssh -i "%KEY%" -o BatchMode=yes %HOST% "sed -i 's/^LB_ALLOWED_HASHES=.*/LB_ALLOWED_HASHES=%HASH%/' %REMOTE_DIR%/lb.env && kill $(ss -ltnp 2>/dev/null | grep :8080 | grep -oP 'pid=\K[0-9]+' | head -1) 2>/dev/null; sleep 1; %REMOTE_DIR%/run.sh; sleep 1; echo -n 'server allowlist now: '; grep -oP 'LB_ALLOWED_HASHES=\K.*' %REMOTE_DIR%/lb.env; tail -1 %REMOTE_DIR%/server.log"

if errorlevel 1 (
  echo.
  echo FAILED - could not reach the server or apply the change.
  exit /b 1
)
echo.
echo Done.
exit /b 0
