@echo off
rem Builds dist\frontier.love and dist\Frontier-Windows\Frontier.exe on Windows.
rem Needs LOVE 11.5 installed (default: C:\Program Files\LOVE). Uses PowerShell for zipping.
setlocal
cd /d "%~dp0\.."
if "%LOVE_DIR%"=="" set LOVE_DIR=C:\Program Files\LOVE
if not exist dist mkdir dist
if exist dist\frontier.zip del dist\frontier.zip
if exist dist\frontier.love del dist\frontier.love
powershell -NoProfile -Command "Compress-Archive -Path main.lua,conf.lua,net.lua,profile.lua,weapons.lua,enemies.lua,utility.lua,armor.lua -DestinationPath dist\frontier.zip"
move /y dist\frontier.zip dist\frontier.love >nul
if exist dist\Frontier-Windows rmdir /s /q dist\Frontier-Windows
mkdir dist\Frontier-Windows
copy /b "%LOVE_DIR%\love.exe"+dist\frontier.love dist\Frontier-Windows\Frontier.exe >nul
copy "%LOVE_DIR%\*.dll" dist\Frontier-Windows\ >nul
copy "%LOVE_DIR%\license.txt" dist\Frontier-Windows\ >nul
echo Built dist\Frontier-Windows\Frontier.exe
endlocal
