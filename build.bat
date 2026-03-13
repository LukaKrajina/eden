@echo off
title Eden One-Click Build Script
color 0A

echo =========================================
echo      Eden One-Click Build Script
echo =========================================
echo.

:: Ensure the assets folder exists at the root
if not exist assets\ mkdir assets

:: 1. Build Go Backend (Cain.dll)
echo [1/4] Building Go Core Network (Cain.dll)...
cd p2p_core
go build -o Cain.dll -buildmode=c-shared main.go eve.go
if %ERRORLEVEL% NEQ 0 (
    echo [ERROR] Go build failed. Ensure Go v1.20+ is installed.
    pause
    exit /b 1
)
move Cain.dll ..\assets\ >nul
:: Cleanup the generated C header from Go
move Cain.h ..\assets\ >nul 2>&1 
cd ..
echo [SUCCESS] Cain.dll built successfully.
echo.

:: 2. Build Rust Analytics (demo_core.dll)
echo [2/4] Building Rust Analytics Engine (demo_core.dll)...
cd demo_core
cargo build --release
if %ERRORLEVEL% NEQ 0 (
    echo [ERROR] Rust build failed. Ensure Rust and Cargo are installed.
    pause
    exit /b 1
)
copy target\release\demo_core.dll ..\assets\ >nul
cd ..
echo [SUCCESS] demo_core.dll built successfully.
echo.

:: 3. Build C++ System Bridge (adam.dll)
echo [3/4] Building C++ System Bridge (adam.dll)...
where cl >nul 2>nul
if %ERRORLEVEL% NEQ 0 (
    echo [ERROR] 'cl' compiler not found. 
    echo Please run this script from the "x64 Native Tools Command Prompt for VS".
    pause
    exit /b 1
)
cd p2p_core
:: Compile without wintun.lib. The code dynamically loads it.
cl /LD adam.cpp /Fe:adam.dll /I..\wintun\include ws2_32.lib shell32.lib
if %ERRORLEVEL% NEQ 0 (
    echo [ERROR] C++ build failed. Make sure you removed the wintun.lib pragma from adam.cpp!
    pause
    exit /b 1
)
move adam.dll ..\assets\ >nul
:: Cleanup MSVC build artifacts
del adam.obj adam.lib adam.exp >nul 2>&1
cd ..
echo [SUCCESS] adam.dll built successfully.
echo.

:: 4. Assemble Assets & Flutter Build
echo [4/4] Setting up Assets and building Flutter frontend...

:: Move the Wintun DLL to the assets folder so the Flutter app can access it
if exist wintun\bin\wintun.dll (
    copy wintun\bin\wintun.dll assets\ >nul
    echo [INFO] wintun.dll copied to assets.
) else (
    echo [WARNING] wintun.dll not found in wintun\bin\. Make sure to place it in your assets folder manually!
)

echo [INFO] Fetching Flutter dependencies...
call flutter pub get
if %ERRORLEVEL% NEQ 0 (
    echo [ERROR] Flutter pub get failed.
    pause
    exit /b 1
)

echo [INFO] Building Flutter Windows application...
call flutter build windows
if %ERRORLEVEL% NEQ 0 (
    echo [ERROR] Flutter build failed.
    pause
    exit /b 1
)

echo.
echo =========================================
echo [SUCCESS] Eden built successfully! 
echo =========================================
echo Your executable is located in build\windows\runner\Release\
pause