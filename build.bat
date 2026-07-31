@echo off
setlocal EnableDelayedExpansion

REM ==============================================
REM Build Configuration
REM ==============================================
REM The exe name is composed further down from what the build actually IS:
REM   <EXE_BASE>-<version>-<mode>[-<module>][-tracy].exe   e.g. memscan-1.4.0-release-flyff.exe
set "EXE_BASE=memscan"
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
    echo Usage: build.bat [debug^|release] [tracy] [module]
    echo   tracy    - enable the Tracy profiler
    echo   module   - build ^<module^> as the MAIN module: its UI opens on start, no REPL ^(e.g. flyff^)
    exit /b 1
)

if /i "%1"=="debug" (
    set "BUILD_DIR=%DEBUG_DIR%"
    set "BUILD_FLAGS=%DEBUG_FLAGS%"
    set "BUILD_MODE=debug"
) else if /i "%1"=="release" (
    set "BUILD_DIR=%RELEASE_DIR%"
    set "BUILD_FLAGS=%RELEASE_FLAGS%"
    set "BUILD_MODE=release"
) else (
    echo Invalid build mode. Use 'debug' or 'release'
    exit /b 1
)

REM Optional args 2 and 3, in either order:
REM
REM 'tracy' (alias 'profile') enables the Tracy profiler, independent of debug/release. Off by
REM default: without the define, every tracy.* call compiles to nothing (see lib/odin-tracy/wrapper.odin),
REM so normal builds are unaffected. tracy.lib is always linked but stays dormant until instrumentation
REM runs. View captures with tool\tracy\tracy-profiler.exe.
REM
REM Anything else is taken as a MODULE NAME (today: flyff) and builds that module as the MAIN module:
REM it gains control at startup and opens its UI immediately instead of a REPL (see MAIN_MODULE in
REM src\main.odin). Omit it for the normal REPL build; an unknown name fails the build.
set "PROFILE_FLAGS="
set "MAIN_MODULE="
for %%a in (%2 %3) do (
    if /i "%%a"=="tracy" (
        set "PROFILE_FLAGS=-define:TRACY_ENABLE=true"
    ) else if /i "%%a"=="profile" (
        set "PROFILE_FLAGS=-define:TRACY_ENABLE=true"
    ) else (
        set "MAIN_MODULE=%%a"
    )
)
set "MODULE_FLAGS="
if defined MAIN_MODULE set "MODULE_FLAGS=-define:MAIN_MODULE=%MAIN_MODULE%"

REM ==============================================
REM Subsystem: no console window on the SHIPPED exe
REM ==============================================
REM Odin defaults every Windows target to -subsystem:console, which is why launching a build pops a
REM black text window. That window is load-bearing for three of the four variants and pure noise in
REM the fourth, so the flag is scoped to exactly that one:
REM
REM   release + module  -> WINDOWS. The UI opens at startup and there is no REPL to type into, so the
REM                        console was only ever carrying the log. This is the exe you ship.
REM   release, no module-> console. It IS the REPL - a build you cannot type into is not a build.
REM   debug   (either)  -> console. The log is the whole point while developing.
REM
REM Consequence, deliberately accepted: with no console there is no stdout, so every fmt.print in the
REM shipped exe goes nowhere (writes to a NULL handle fail silently - nothing crashes or blocks). Use
REM the debug main-module build, or the REPL build, when you need to watch the log.
REM
REM No WinMain is needed: Odin passes /ENTRY:mainCRTStartup regardless of the subsystem.
set "SUBSYSTEM_FLAGS="
if defined MAIN_MODULE if /i "%BUILD_MODE%"=="release" set "SUBSYSTEM_FLAGS=-subsystem:windows"

REM ==============================================
REM Executable name
REM ==============================================
REM Name the exe after exactly what it is - memscan-<version>-<mode>[-<module>][-tracy].exe - so the
REM variants never overwrite each other: a REPL build and a main-module build sit side by side in the
REM same folder (and a running one can no longer lock the other's rebuild with LNK1104), and an exe
REM copied out of .out still says which build it is. VERSION is read straight out of src\version.odin,
REM so the filename can never drift from what the `version` command prints.
set "VERSION="
for /f tokens^=2^ delims^=^" %%v in ('findstr /b /c:"VERSION ::" "%SOURCE_DIR%\version.odin"') do set "VERSION=%%v"
if not defined VERSION (
    echo Could not read VERSION from %SOURCE_DIR%\version.odin
    exit /b 1
)
set "EXECUTABLE=%EXE_BASE%-%VERSION%-%BUILD_MODE%"
if defined MAIN_MODULE set "EXECUTABLE=%EXECUTABLE%-%MAIN_MODULE%"
if defined PROFILE_FLAGS set "EXECUTABLE=%EXECUTABLE%-tracy"
set "EXECUTABLE=%EXECUTABLE%.exe"

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

if defined MAIN_MODULE echo %BLUE%^> main module: %MAIN_MODULE% ^(opens its UI on start - no REPL^)%RESET%
if defined SUBSYSTEM_FLAGS echo %BLUE%^> subsystem: windows ^(no console window; the log has nowhere to go^)%RESET%
echo %BLUE%^> %COMPILER% build %SOURCE_DIR% -out:%BUILD_DIR%\%EXECUTABLE% %COMMON_FLAGS% %BUILD_FLAGS% %LINK_FLAGS% %PROFILE_FLAGS% %MODULE_FLAGS% %SUBSYSTEM_FLAGS%%RESET%
REM Stream odin's output straight to the console (preserves newlines/indentation and any '!' in
REM messages - the old redirect-into-a-delayed-expansion-variable approach mangled all three) and
REM capture only its exit code.
%COMPILER% build %SOURCE_DIR% -out:%BUILD_DIR%\%EXECUTABLE% %COMMON_FLAGS% %BUILD_FLAGS% %LINK_FLAGS% %PROFILE_FLAGS% %MODULE_FLAGS% %SUBSYSTEM_FLAGS%
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