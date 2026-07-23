@echo off
setlocal EnableDelayedExpansion

REM ==============================================
REM Build Configuration
REM ==============================================
set "EXECUTABLE=memscan.exe"
set "SOURCE_DIR=src"
set "OUTPUT_DIR=.out"
set "DEBUG_DIR=%OUTPUT_DIR%\debug"
set "RELEASE_DIR=%OUTPUT_DIR%\release"
set "COMPILER=odin"
set "COMMON_FLAGS=-ignore-unknown-attributes -vet-shadowing -error-pos-style:unix"
REM raylib is STATICALLY linked. raylib.lib and Win32 User32.lib (pulled in for the global hotkeys) both
REM define CloseWindow/ShowCursor; without help the linker binds them to user32's (wrong - the raylib
REM window then never closes). /WHOLEARCHIVE:raylib.lib forces raylib's whole archive in first so its
REM own CloseWindow wins and user32's is never pulled. No raylib.dll needed at runtime.
REM
REM msvcrt.lib is re-added explicitly for the leaderboards feature (vendor:curl). The prebuilt libcurl.lib
REM ships a "/NODEFAULTLIB:msvcrt" directive (it was built against the STATIC CRT, libcmt), which strips the
REM DYNAMIC CRT. But raylib.lib is built against the DYNAMIC CRT (msvcrt) and needs its __imp_* imports
REM (fmin/strtok/atof/...). Naming msvcrt.lib explicitly overrides curl's exclusion so BOTH CRTs are present
REM again - the same benign msvcrt(raylib)+libcmt(raygui/curl) mix the project already linked pre-curl. curl
REM keeps its memory internal (response bytes are copied into our own Odin-allocated buffer), so nothing
REM crosses the CRT boundary at runtime.
set "LINK_FLAGS=-extra-linker-flags:"/WHOLEARCHIVE:raylib.lib msvcrt.lib""
set "DEBUG_FLAGS=-debug"
set "RELEASE_FLAGS=-o:speed -disable-assert -no-bounds-check"

REM ==============================================
REM Enable Colors
REM ==============================================
for /f "tokens=*" %%a in ('echo prompt $E^|cmd') do set "ESC=%%a"
set "RED=%ESC%[1;91m"
set "GREEN=%ESC%[1;92m"
set "BLUE=%ESC%[1;94m"
set "RESET=%ESC%[0m"

REM ==============================================
REM Validate Input & Environment
REM ==============================================
if "%1"=="" (
    echo Usage: build.bat [debug^|release] [tracy]
    exit /b 1
)

if /i "%1"=="debug" (
    set "BUILD_DIR=%DEBUG_DIR%"
    set "BUILD_FLAGS=%DEBUG_FLAGS%"
) else if /i "%1"=="release" (
    set "BUILD_DIR=%RELEASE_DIR%"
    set "BUILD_FLAGS=%RELEASE_FLAGS%"
) else (
    echo Invalid build mode. Use 'debug' or 'release'
    exit /b 1
)

REM Optional 2nd arg 'tracy' (alias 'profile') enables the Tracy profiler, independent of
REM debug/release. Off by default: without the define, every tracy.* call compiles to nothing
REM (see lib/odin-tracy/wrapper.odin), so normal builds are unaffected. tracy.lib is always
REM linked but stays dormant until instrumentation runs. View captures with tool\tracy\tracy-profiler.exe.
set "PROFILE_FLAGS="
if /i "%2"=="tracy"   set "PROFILE_FLAGS=-define:TRACY_ENABLE=true"
if /i "%2"=="profile" set "PROFILE_FLAGS=-define:TRACY_ENABLE=true"

REM ==============================================
REM Build
REM ==============================================
echo %BLUE%^> Creating output directories%RESET%
if not exist "%OUTPUT_DIR%" mkdir "%OUTPUT_DIR%"
if not exist "%BUILD_DIR%" mkdir "%BUILD_DIR%"

echo %BLUE%^> Generating build hash%RESET%
powershell -NoProfile -ExecutionPolicy Bypass -File "tool\gen_build_hash.ps1"
if %ERRORLEVEL% neq 0 (
    echo %RED%Failed to generate build hash%RESET%
    exit /b 1
)

echo %BLUE%^> %COMPILER% build %SOURCE_DIR% -out:%BUILD_DIR%\%EXECUTABLE% %COMMON_FLAGS% %BUILD_FLAGS% %LINK_FLAGS% %PROFILE_FLAGS%%RESET%
REM Stream odin's output straight to the console (preserves newlines/indentation and any '!' in
REM messages - the old redirect-into-a-delayed-expansion-variable approach mangled all three) and
REM capture only its exit code.
%COMPILER% build %SOURCE_DIR% -out:%BUILD_DIR%\%EXECUTABLE% %COMMON_FLAGS% %BUILD_FLAGS% %LINK_FLAGS% %PROFILE_FLAGS%
set "BUILD_ERROR=%ERRORLEVEL%"

if not "%BUILD_ERROR%"=="0" (
    echo %RED%^> build FAILED ^(odin exit %BUILD_ERROR%^)%RESET%
    if "%BUILD_ERROR%"=="1104" echo %RED%  ^(LNK1104: '%EXECUTABLE%' is locked - close the running instance, then rebuild.^)%RESET%
    exit /b %BUILD_ERROR%
)

echo %GREEN%^> build OK -^> %BUILD_DIR%\%EXECUTABLE%%RESET%

echo %BLUE%^> Copying resources%RESET%
if exist "resources" (
    xcopy /E /I /Y "resources" "%BUILD_DIR%\resources" > nul
)
exit /b 0