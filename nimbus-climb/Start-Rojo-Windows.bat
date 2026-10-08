@echo off
setlocal EnableExtensions
title Nimbus Climb - Rojo server (keep this window open)
cd /d "%~dp0"

rem Rojo 7.7.1 matches the "Rojo 7.7.1" Studio plugin. Downloaded once, then reused.
set "ROJO_VERSION=7.7.1"
set "ROJO_DIR=%LOCALAPPDATA%\NimbusClimb\rojo-%ROJO_VERSION%"
set "ROJO_EXE=%ROJO_DIR%\rojo.exe"

echo.
echo  ===== Nimbus Climb - Rojo server =====
echo.

if not exist "default.project.json" (
    echo  ERROR: I can't find default.project.json next to this file.
    echo.
    echo  Please EXTRACT the downloaded ZIP first: right-click the ZIP, Extract All.
    echo  Then open the "nimbus-climb" folder inside it and double-click this file again.
    echo  Do not run it from inside the ZIP.
    goto :end
)

if exist "%ROJO_EXE%" goto :run

echo  First run: downloading Rojo %ROJO_VERSION% (about 5 MB). Please wait...
if not exist "%ROJO_DIR%" mkdir "%ROJO_DIR%"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; $zip=Join-Path $env:ROJO_DIR 'rojo.zip'; Invoke-WebRequest -UseBasicParsing -Uri ('https://github.com/rojo-rbx/rojo/releases/download/v' + $env:ROJO_VERSION + '/rojo-' + $env:ROJO_VERSION + '-windows-x86_64.zip') -OutFile $zip; Expand-Archive -LiteralPath $zip -DestinationPath $env:ROJO_DIR -Force; Remove-Item -LiteralPath $zip"
if not exist "%ROJO_EXE%" (
    echo.
    echo  ERROR: the download failed. Check your internet connection and try again.
    goto :end
)

:run
echo  Starting the Rojo server...
echo.
echo  NEXT STEPS
echo    1. Leave THIS window open. Closing it stops the server.
echo    2. In Roblox Studio: open a Baseplate place, then Plugins - Rojo - Connect.
echo    3. Press Play.
echo.
"%ROJO_EXE%" serve default.project.json
echo.
echo  The Rojo server stopped.

:end
echo.
pause
endlocal
