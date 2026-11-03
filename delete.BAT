@echo off
setlocal EnableExtensions

echo.
echo ==========================================
echo       DELETE GENERATED PDF FILES
echo ==========================================
echo.

REM Default to the folder containing this script.
set "SCRIPT_DIR=%~dp0"
set /p "TARGET_DIR=Folder containing PDFs to delete (Enter for this tool folder): "

if not defined TARGET_DIR set "TARGET_DIR=%SCRIPT_DIR%"

REM Resolve the supplied path to an absolute path.
for %%I in ("%TARGET_DIR%") do set "TARGET_DIR=%%~fI"

if not exist "%TARGET_DIR%\." (
    echo.
    echo ERROR: The specified folder does not exist:
    echo "%TARGET_DIR%"
    echo.
    pause
    endlocal
    exit /b 1
)

echo.
echo Target folder:
echo "%TARGET_DIR%"
echo.
echo This will delete PDF files directly inside this folder only.
echo It will NOT search subfolders or delete TXT, MD, HTML, or other files.
echo.

dir /b /a-d "%TARGET_DIR%\*.pdf" >nul 2>&1
if errorlevel 1 (
    echo No PDF files were found in the target folder.
    echo.
    pause
    endlocal
    exit /b 0
)

choice /c YN /n /m "Delete these PDF files? [Y/N]: "
if errorlevel 2 (
    echo.
    echo Deletion canceled.
    echo.
    pause
    endlocal
    exit /b 0
)

del /q "%TARGET_DIR%\*.pdf"
if errorlevel 1 (
    echo.
    echo ERROR: One or more PDF files could not be deleted.
    echo Check whether they are open or whether you have permission.
    echo.
    pause
    endlocal
    exit /b 1
)

echo.
echo PDF cleanup completed.
echo.
pause
endlocal
exit /b 0
