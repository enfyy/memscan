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
set "LINK_FLAGS=-extra-linker-flags:/WHOLEARCHIVE:raylib.lib"
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
    echo Usage: build.bat [debug^|release]
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

echo %BLUE%^> %COMPILER% build %SOURCE_DIR% -out:%BUILD_DIR%\%EXECUTABLE% %COMMON_FLAGS% %BUILD_FLAGS% %LINK_FLAGS%%RESET%
REM Stream odin's output straight to the console (preserves newlines/indentation and any '!' in
REM messages - the old redirect-into-a-delayed-expansion-variable approach mangled all three) and
REM capture only its exit code.
%COMPILER% build %SOURCE_DIR% -out:%BUILD_DIR%\%EXECUTABLE% %COMMON_FLAGS% %BUILD_FLAGS% %LINK_FLAGS%
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