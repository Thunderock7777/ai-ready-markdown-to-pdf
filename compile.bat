@echo off
color 07
setlocal EnableExtensions

REM =========================================================
REM WORKFLOW ARCHITECTURE
REM =========================================================
REM Accept one or more quoted Markdown/TXT paths; validate all before creating output.
REM Preserve argument order, pass absolute paths to Pandoc, and name the PDF after input 1.
REM Companion template and filters live in config\; generated PDFs stay beside input 1.
REM markdown-normalizer.lua normalizes/rebuilds the AST; code-fence-runner.lua executes/renders blocks.
REM XeLaTeX runs in a temporary directory, with up to three reference passes.

echo.
echo ==========================================
echo    Markdown + LaTeX  ->  PDF
echo ==========================================
echo If you want to terminate the job, press Ctrl + C
echo.

REM =========================================================
REM FILE PATHS
REM =========================================================
set "INPUT=%~f1"
set "INPUT_DIR=%~dp1"
set "SCRIPT_DIR=%~dp0"
set "CONFIG_DIR=%SCRIPT_DIR%config"
set "BASENAME=%~dp1%~n1"
set "PDF_OUTPUT=%BASENAME%.pdf"
set "PANDOC_INPUTS="
set "TEMPLATE=%CONFIG_DIR%\custom.tex"
set "NORMALIZER_FILTER=%CONFIG_DIR%\markdown-normalizer.lua"
set "CODE_FENCE_FILTER=%CONFIG_DIR%\code-fence-runner.lua"
set "ANNOTATOR_SCRIPT=%CONFIG_DIR%\error-annotator.lua"
if not defined PYTHON set "PYTHON=py"
if not defined C_COMPILER set "C_COMPILER=gcc"
if not defined CPP_COMPILER set "CPP_COMPILER=g++"
if not defined JAVA_RUNNER set "JAVA_RUNNER=java"
if not defined JAVAC_COMPILER set "JAVAC_COMPILER=javac"

REM If pandoc is not on PATH directly, check standard Quarto tools directory
where pandoc >nul 2>&1
if errorlevel 1 (
    if exist "%LOCALAPPDATA%\Programs\Quarto\bin\tools\pandoc.exe" (
        set "PATH=%PATH%;%LOCALAPPDATA%\Programs\Quarto\bin\tools"
    )
    if exist "%LOCALAPPDATA%\Pandoc\pandoc.exe" (
        set "PATH=%PATH%;%LOCALAPPDATA%\Pandoc"
    )
    if exist "%LOCALAPPDATA%\Programs\Pandoc\pandoc.exe" (
        set "PATH=%PATH%;%LOCALAPPDATA%\Programs\Pandoc"
    )
    if exist "%ProgramFiles%\Pandoc\pandoc.exe" (
        set "PATH=%PATH%;%ProgramFiles%\Pandoc"
    )
)

set "MD2PDF_CACHE=%SCRIPT_DIR%md2pdf_cache"
if not exist "%MD2PDF_CACHE%" mkdir "%MD2PDF_CACHE%" >nul 2>&1

REM Temporary working folder (deleted at the end)
set "WORK=%TEMP%\md2pdf_%RANDOM%%RANDOM%"

set "TEX_OUTPUT=%WORK%\%~n1.tex"
set "WORK_PDF=%WORK%\%~n1.pdf"
set "LOG_FILE=%WORK%\%~n1.log"

REM =========================================================
REM CHECKS
REM =========================================================
if "%INPUT%"=="" (
    color 0E
    echo ERROR: No input file was supplied.
    echo Supply one or more .md or .txt files to compile.bat.
    echo.
    pause
    exit /b 1
)

:VALIDATE_INPUTS
if "%~1"=="" goto INPUTS_VALIDATED
if not exist "%~f1" (
    color 0E
    echo ERROR: Input file does not exist:
    echo "%~f1"
    echo.
    pause
    exit /b 1
)
set "PANDOC_INPUTS=%PANDOC_INPUTS% "%~f1""
shift
goto VALIDATE_INPUTS

:INPUTS_VALIDATED

if not exist "%TEMPLATE%" (
    color 0E
    echo ERROR: config\custom.tex not found:
    echo "%TEMPLATE%"
    echo.
    pause
    exit /b 1
)

if not exist "%NORMALIZER_FILTER%" (
    color 0E
    echo ERROR: config\markdown-normalizer.lua not found:
    echo "%NORMALIZER_FILTER%"
    echo.
    pause
    exit /b 1
)

if not exist "%CODE_FENCE_FILTER%" (
    color 0E
    echo ERROR: config\code-fence-runner.lua not found:
    echo "%CODE_FENCE_FILTER%"
    echo.
    pause
    exit /b 1
)

if not exist "%ANNOTATOR_SCRIPT%" (
    color 0E
    echo ERROR: config\error-annotator.lua not found:
    echo "%ANNOTATOR_SCRIPT%"
    echo.
    pause
    exit /b 1
)
cd /d "%INPUT_DIR%"
mkdir "%WORK%" >nul 2>&1

echo Inputs: %PANDOC_INPUTS%
echo PDF   : "%PDF_OUTPUT%"
echo.

REM =========================================================
REM PANDOC  (writes the .tex into the temp folder only)
REM =========================================================
echo ==========================================
echo               PREPARING
echo ==========================================
echo.
echo Executable code fences run by default. You will be asked to approve uncached runs.
echo Forced fresh runs (run=new or cache=false) always require approval.
echo.

REM Filter order is intentional: normalize/rebuild the AST before executing or rendering code fences.
set "MD2PDF_CONFIRM_EXEC=1"
set "MD2PDF_CONFIRM_PYTHON=1"
set "MD2PDF_CONFIRM_C=1"
set "MD2PDF_CONFIRM_CPP=1"
set "MD2PDF_CONFIRM_JAVA=1"
set "MD2PDF_WORKING_DIR=%INPUT_DIR%"
pandoc %PANDOC_INPUTS% -f markdown-yaml_metadata_block-simple_tables-raw_tex --lua-filter="%NORMALIZER_FILTER%" --lua-filter="%CODE_FENCE_FILTER%" --wrap=none --template="%TEMPLATE%" -o "%TEX_OUTPUT%"
if errorlevel 1 (
    echo.
    echo ==========================================
    echo             PANDOC FAILED
    echo ==========================================
    goto CLEANUP_FAIL
)

REM =========================================================
REM XELATEX  (all build files go to the temp folder)
REM =========================================================
echo.
echo ==========================================
echo               CREATING PDF
echo ==========================================
echo.

set "PASS=1"
set "RECOVERY_ATTEMPTED="
set "ERRORS_RECOVERED="

:RUN_XELATEX
echo --- XeLaTeX pass %PASS% ---
xelatex -cnf-line=max_print_line=1000 -output-directory="%WORK%" -interaction=nonstopmode -file-line-error "%TEX_OUTPUT%" >nul 2>&1

if not exist "%WORK_PDF%" goto ATTEMPT_RECOVERY

if %PASS% GEQ 3 goto CHECK_POST_PASS_RECOVERY
findstr /C:"Rerun to get" /C:"Label(s) may have changed" "%LOG_FILE%" >nul 2>&1
if errorlevel 1 goto CHECK_POST_PASS_RECOVERY
set /a PASS+=1
goto RUN_XELATEX

:CHECK_POST_PASS_RECOVERY
if "%RECOVERY_ATTEMPTED%"=="1" goto REPORT
goto ATTEMPT_RECOVERY

:ATTEMPT_RECOVERY
REM Invariant: error recovery pass is attempted at most once for localized body errors.
if "%RECOVERY_ATTEMPTED%"=="1" goto PDF_FAILED
set "RECOVERY_ATTEMPTED=1"
if exist "%ANNOTATOR_SCRIPT%" (
    texlua "%ANNOTATOR_SCRIPT%" "%TEX_OUTPUT%" "%LOG_FILE%" >nul 2>&1
    if not errorlevel 1 (
        color 0E
        echo.
        echo --- XeLaTeX error recovery pass ^(marking [!!!]^) ---
        xelatex -cnf-line=max_print_line=1000 -output-directory="%WORK%" -interaction=nonstopmode -file-line-error "%TEX_OUTPUT%" >nul 2>&1
        set "ERRORS_RECOVERED=1"
        if exist "%WORK_PDF%" goto REPORT
    )
)
if not exist "%WORK_PDF%" goto PDF_FAILED
goto REPORT

:PDF_FAILED
color 0E
echo.
echo ==========================================
echo             PDF CREATION FAILED
echo ==========================================
echo.
findstr /R /C:"\.tex:[0-9][0-9]*:" /C:"^!" "%LOG_FILE%"
goto CLEANUP_FAIL

REM =========================================================
REM REPORT LaTeX ERRORS (the PDF is still produced)
REM =========================================================
:REPORT
echo.
if "%ERRORS_RECOVERED%"=="1" (
    color 0E
    echo ------------------------------------------
    echo  LaTeX errors were mapped into the PDF with red [!!!].
    echo ------------------------------------------
)
findstr /R /C:"\.tex:[0-9][0-9]*:" "%LOG_FILE%" 2>nul | findstr /V /C:"Missing character" >nul 2>&1
if not errorlevel 1 (
    color 0E
    echo ------------------------------------------
    echo  LaTeX reported errors ^(PDF may be incomplete^):
    echo ------------------------------------------
    findstr /R /C:"\.tex:[0-9][0-9]*:" "%LOG_FILE%" | findstr /V /C:"Missing character"
    echo ------------------------------------------
    echo Line numbers refer to the temporary .tex ^(deleted on cleanup^).
)

findstr /C:"Missing character" "%LOG_FILE%" >nul 2>&1
if not errorlevel 1 (
    echo ------------------------------------------
    echo  Characters missing from the fonts ^(blank in the PDF^):
    echo ------------------------------------------
    findstr /C:"Missing character" "%LOG_FILE%"
    echo ------------------------------------------
)

REM =========================================================
REM DELIVER PDF + CLEAN UP EVERYTHING ELSE
REM =========================================================
REM Do not delete the previous PDF before the new build succeeds; a failed copy
REM should leave the last good output intact (for example, when it is open).
copy /Y "%WORK_PDF%" "%PDF_OUTPUT%" >nul
if errorlevel 1 (
    color 0E
    echo ERROR: Could not write or replace the generated PDF at:
    echo "%PDF_OUTPUT%"
    echo Close it in any PDF viewer and check that the folder is writable.
    goto CLEANUP_FAIL
)
rmdir /s /q "%WORK%" >nul 2>&1

echo.
echo ==========================================
echo           CONVERSION COMPLETED
echo ==========================================
echo.
echo PDF: "%PDF_OUTPUT%"
echo.
pause
endlocal
exit /b 0

:CLEANUP_FAIL
color 0E
echo.
rmdir /s /q "%WORK%" >nul 2>&1
pause
endlocal
exit /b 1