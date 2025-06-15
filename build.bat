@echo off
setlocal EnableDelayedExpansion

REM ==============================================
REM Build Configuration
REM ==============================================
set "EXECUTABLE=flyff_in_2025.exe"
set "SOURCE_DIR=src"
set "OUTPUT_DIR=.out"
set "DEBUG_DIR=%OUTPUT_DIR%\debug"
set "RELEASE_DIR=%OUTPUT_DIR%\release"
set "COMPILER=odin"
set "COMMON_FLAGS=-ignore-unknown-attributes -vet-shadowing -error-pos-style:unix"
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

echo %BLUE%^> %COMPILER% run %SOURCE_DIR% -out:%BUILD_DIR%\%EXECUTABLE% %COMMON_FLAGS% %BUILD_FLAGS%%RESET%
%COMPILER% build %SOURCE_DIR% -out:%BUILD_DIR%\%EXECUTABLE% %COMMON_FLAGS% %BUILD_FLAGS% > "%TEMP%\build_output.txt" 2>&1
set BUILD_ERROR=%ERRORLEVEL%

set "BUILD_OUTPUT="
for /f "delims=" %%i in ('type "%TEMP%\build_output.txt"') do (
    set "BUILD_OUTPUT=!BUILD_OUTPUT!%%i!NL!"
)
del "%TEMP%\build_output.txt"

if %BUILD_ERROR% neq 0 (
    echo %RED%!BUILD_OUTPUT!%RESET%
    exit /b %BUILD_ERROR%
)

echo %GREEN%!BUILD_OUTPUT!%RESET%

echo %BLUE%^> Copying resources%RESET%
if exist "resources" (
    xcopy /E /I /Y "resources" "%BUILD_DIR%\resources" > nul
)
exit /b 0