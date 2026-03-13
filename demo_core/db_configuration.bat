@echo off
title Eden Database Configuration
color 0A

echo =========================================
echo      Eden Database Setup Script
echo =========================================
echo.

:: Check if psql is available in the system PATH
where psql >nul 2>nul
if %ERRORLEVEL% NEQ 0 (
    echo [ERROR] psql command not found.
    echo Please ensure PostgreSQL is installed and the 'bin' folder is added to your system PATH.
    pause
    exit /b 1
)

:: Prompt for database credentials
set /p DB_USER="Enter PostgreSQL username (default: postgres): "
if "%DB_USER%"=="" set DB_USER=postgres

set /p DB_PASSWORD="Enter PostgreSQL password: "
:: Set PGPASSWORD environment variable so psql doesn't prompt again
set PGPASSWORD=%DB_PASSWORD%

set DB_NAME=eden_db
set DB_PORT=5432

echo.
echo [INFO] Creating database '%DB_NAME%'...
:: Connect to the default 'postgres' database to create the new one
psql -U %DB_USER% -p %DB_PORT% -d postgres -c "CREATE DATABASE %DB_NAME%;" >nul 2>&1

if %ERRORLEVEL% EQU 0 (
    echo [SUCCESS] Database '%DB_NAME%' created successfully.
) else (
    echo [INFO] Database '%DB_NAME%' might already exist. Proceeding...
)

echo.
echo [INFO] Applying schema from schema.sql...
if not exist schema.sql (
    echo [ERROR] schema.sql not found in the current directory.
    echo Please ensure this batch file is in the same folder as schema.sql.
    pause
    exit /b 1
)

:: Apply the schema to the newly created database
psql -U %DB_USER% -p %DB_PORT% -d %DB_NAME% -f schema.sql

if %ERRORLEVEL% EQU 0 (
    echo [SUCCESS] Schema applied successfully!
) else (
    echo [ERROR] Failed to apply schema. Please check the console output for errors.
)

echo.
echo =========================================
echo Setup complete. Don't forget to update your eden_config.json!
echo =========================================
pause