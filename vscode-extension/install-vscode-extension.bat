@echo off
setlocal enabledelayedexpansion

REM Portable installer for Whiteboard HTML Preview (VS Code)
REM Installs directly into %USERPROFILE%\.vscode\extensions without requiring vsce or .vsix.

set "EXT_SRC=%~dp0"
if "%EXT_SRC:~-1%"=="\" set "EXT_SRC=%EXT_SRC:~0,-1%"
set "REPO_ROOT=%EXT_SRC%\.."
set "EXT_DEST=%USERPROFILE%\.vscode\extensions\thunderock7777.whiteboard-html-preview-1.0.0"

echo.
echo ==========================================
echo   Installing Whiteboard HTML Preview
echo ==========================================
echo Source : "%EXT_SRC%"
echo Target : "%EXT_DEST%"
echo.

if not exist "%EXT_SRC%\extension.js" (
    echo ERROR: extension.js not found in "%EXT_SRC%".
    pause
    exit /b 1
)

if exist "%EXT_DEST%" rmdir /s /q "%EXT_DEST%" >nul 2>&1
mkdir "%EXT_DEST%" >nul 2>&1
if errorlevel 1 (
    echo ERROR: Could not create "%EXT_DEST%".
    pause
    exit /b 1
)

copy /Y "%EXT_SRC%\package.json" "%EXT_DEST%\" >nul
copy /Y "%EXT_SRC%\extension.js" "%EXT_DEST%\" >nul
if exist "%EXT_SRC%\README.md" copy /Y "%EXT_SRC%\README.md" "%EXT_DEST%\" >nul

REM Bundle core repo config files so the extension works from any VS Code folder offline.
if exist "%REPO_ROOT%\config\markdown-normalizer.lua" (
    mkdir "%EXT_DEST%\config" >nul 2>&1
    copy /Y "%REPO_ROOT%\config\*.lua" "%EXT_DEST%\config\" >nul 2>&1
    copy /Y "%REPO_ROOT%\config\custom.tex" "%EXT_DEST%\config\" >nul 2>&1
    copy /Y "%REPO_ROOT%\config\latex.css" "%EXT_DEST%\config\" >nul 2>&1
    copy /Y "%REPO_ROOT%\config\wb-viewer.js" "%EXT_DEST%\config\" >nul 2>&1
    if exist "%REPO_ROOT%\config\markmap\build-graph.js" (
        mkdir "%EXT_DEST%\config\markmap" >nul 2>&1
        copy /Y "%REPO_ROOT%\config\markmap\build-graph.js" "%EXT_DEST%\config\markmap\" >nul 2>&1
    )
    if exist "%REPO_ROOT%\config\markmap\vendor" (
        xcopy /E /I /Y /Q "%REPO_ROOT%\config\markmap\vendor" "%EXT_DEST%\config\markmap\vendor" >nul 2>&1
    )
)

echo.
echo Installed successfully to:
echo   "%EXT_DEST%"
echo.
echo Next step:
echo   In VS Code, press Ctrl+Shift+P and run "Developer: Reload Window"
echo   (or restart VS Code), then open a page-layout: whiteboard_html file.
echo.
pause
endlocal
exit /b 0
