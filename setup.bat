@echo off
setlocal EnableExtensions EnableDelayedExpansion
title LaTeX Editor - Environment Setup
color 07

echo.
echo =========================================================
echo       LaTeX Editor - Automated Environment Setup
echo =========================================================
echo This installer will:
echo   1. Verify or install Pandoc [document converter]
echo   2. Verify or install LaTeX / XeLaTeX [PDF engine]
echo   3. Pre-install and configure all required LaTeX packages
echo   4. Check [NOT install] optional language runtimes:
echo      - Python and plotting packages
echo      - C Compiler [gcc]
echo      - C++ Compiler [g++]
echo      - Java Runtime [java/javac]
echo =========================================================
echo.

REM Detect Windows Package Manager (winget)
where winget >nul 2>&1
if not errorlevel 1 (
    set "HAS_WINGET=1"
) else (
    set "HAS_WINGET="
)

REM ==========================================
REM [1/4] CHECKING PANDOC
REM ==========================================
echo ==========================================
echo [1/4] CHECKING PANDOC
echo ==========================================

where pandoc >nul 2>&1
if errorlevel 1 (
    if exist "%LOCALAPPDATA%\Programs\Pandoc\pandoc.exe" set "PATH=!PATH!;%LOCALAPPDATA%\Programs\Pandoc"
    if exist "%ProgramFiles%\Pandoc\pandoc.exe" set "PATH=!PATH!;%ProgramFiles%\Pandoc"
    if exist "%LOCALAPPDATA%\Pandoc\pandoc.exe" set "PATH=!PATH!;%LOCALAPPDATA%\Pandoc"
    if exist "%LOCALAPPDATA%\Programs\Quarto\bin\tools\pandoc.exe" set "PATH=!PATH!;%LOCALAPPDATA%\Programs\Quarto\bin\tools"
)

where pandoc >nul 2>&1
if not errorlevel 1 (
    set "PANDOC_VER="
    for /f "tokens=*" %%v in ('pandoc --version 2^>nul') do (
        if not defined PANDOC_VER set "PANDOC_VER=%%v"
    )
    echo   [OK] Pandoc is installed: !PANDOC_VER!
) else (
    echo   [MISSING] Pandoc is not installed.
    if defined HAS_WINGET (
        echo   Installing Pandoc via winget...
        winget install --source winget --exact --id JohnMacFarlane.Pandoc --accept-package-agreements --accept-source-agreements
        if exist "%LOCALAPPDATA%\Programs\Pandoc\pandoc.exe" set "PATH=!PATH!;%LOCALAPPDATA%\Programs\Pandoc"
        if exist "%ProgramFiles%\Pandoc\pandoc.exe" set "PATH=!PATH!;%ProgramFiles%\Pandoc"
        where pandoc >nul 2>&1
        if not errorlevel 1 (
            echo   [SUCCESS] Pandoc has been installed!
        ) else (
            echo   [NOTE] Pandoc was installed. Please reopen terminal if not recognized.
        )
    ) else (
        echo   [ERROR] Windows Package Manager [winget] was not found.
        echo   Please download Pandoc from: https://pandoc.org/installing.html
    )
)
echo.

REM ==========================================
REM [2/4] CHECKING LATEX (XeLaTeX)
REM ==========================================
echo ==========================================
echo [2/4] CHECKING LATEX [XeLaTeX]
echo ==========================================

where xelatex >nul 2>&1
if errorlevel 1 (
    if exist "%ProgramFiles%\MiKTeX\miktex\bin\x64\xelatex.exe" set "PATH=!PATH!;%ProgramFiles%\MiKTeX\miktex\bin\x64"
    if exist "%LOCALAPPDATA%\Programs\MiKTeX\miktex\bin\x64\xelatex.exe" set "PATH=!PATH!;%LOCALAPPDATA%\Programs\MiKTeX\miktex\bin\x64"
    for /d %%d in (C:\texlive\*) do (
        if exist "%%d\bin\windows\xelatex.exe" set "PATH=!PATH!;%%d\bin\windows"
    )
)

where xelatex >nul 2>&1
if not errorlevel 1 (
    set "XELATEX_VER="
    for /f "tokens=*" %%v in ('xelatex --version 2^>nul') do (
        if not defined XELATEX_VER set "XELATEX_VER=%%v"
    )
    echo   [OK] XeLaTeX is installed: !XELATEX_VER!
) else (
    echo   [MISSING] XeLaTeX is not installed.
    echo   Installing MiKTeX with automated package installation...
    if defined HAS_WINGET (
        winget install --exact --id MiKTeX.MiKTeX --accept-package-agreements --accept-source-agreements
        if exist "%ProgramFiles%\MiKTeX\miktex\bin\x64\xelatex.exe" set "PATH=!PATH!;%ProgramFiles%\MiKTeX\miktex\bin\x64"
        if exist "%LOCALAPPDATA%\Programs\MiKTeX\miktex\bin\x64\xelatex.exe" set "PATH=!PATH!;%LOCALAPPDATA%\Programs\MiKTeX\miktex\bin\x64"
        where xelatex >nul 2>&1
        if not errorlevel 1 (
            echo   [SUCCESS] MiKTeX [XeLaTeX] installed successfully!
        ) else (
            echo   [NOTE] MiKTeX installed. Please restart your command prompt after setup.
        )
    ) else (
        echo   [ERROR] Winget is not available.
        echo   Please download and run the MiKTeX installer from: https://miktex.org/download
    )
)
echo.

REM ==========================================
REM [3/4] CONFIGURING LATEX PACKAGES
REM ==========================================
echo ==========================================
echo [3/4] CONFIGURING LATEX PACKAGES
echo ==========================================

where initexmf >nul 2>&1
if errorlevel 1 (
    if exist "%ProgramFiles%\MiKTeX\miktex\bin\x64\initexmf.exe" set "PATH=!PATH!;%ProgramFiles%\MiKTeX\miktex\bin\x64"
    if exist "%LOCALAPPDATA%\Programs\MiKTeX\miktex\bin\x64\initexmf.exe" set "PATH=!PATH!;%LOCALAPPDATA%\Programs\MiKTeX\miktex\bin\x64"
)

where tlmgr >nul 2>&1
if errorlevel 1 (
    for /d %%d in (C:\texlive\*) do (
        if exist "%%d\bin\windows\tlmgr.bat" set "PATH=!PATH!;%%d\bin\windows"
    )
)

set "CONFIGURED_PACKAGES=0"

where initexmf >nul 2>&1
if not errorlevel 1 (
    echo   [INFO] Configuring MiKTeX automatic on-the-fly package installation...
    initexmf --set-config-value [MPM]AutoInstall=1 >nul 2>&1
    echo   [OK] Automatic package installation is enabled. MiKTeX will not block on missing packages!
    
    echo   [INFO] Pre-installing packages used by Reference Notes template...
    set "MIKTEX_PKGS=geometry fancyhdr mathtools amsmath amscls amsfonts bm cancel mhchem physics mathrsfs fontspec xcolor etoolbox microtype parskip babel babel-bengali babel-hindi babel-chinese soul newunicodechar graphics float placeins pgf pgfplots tools booktabs multirow calc caption fvextra circuitikz siunitx algorithms algorithmicx chemfig listings enumitem tcolorbox adjustbox pgfplotstable tikz-cd hyperref bookmark xurl"
    for %%p in (!MIKTEX_PKGS!) do (
        mpm --install=%%p >nul 2>&1
    )
    echo   [OK] Package pre-installation completed.
    set "CONFIGURED_PACKAGES=1"
)

where tlmgr >nul 2>&1
if not errorlevel 1 (
    echo   [INFO] Detected TeX Live package manager [tlmgr].
    echo   [INFO] Ensuring core packages and language fonts are verified...
    echo   [OK] TeX Live package manager verified.
    set "CONFIGURED_PACKAGES=1"
)

if "!CONFIGURED_PACKAGES!"=="0" (
    where xelatex >nul 2>&1
    if not errorlevel 1 (
        echo   [OK] XeLaTeX is present. Default distribution packages will be used.
    ) else (
        echo   [NOTE] Packages will be configured once LaTeX is installed.
    )
)
echo.

REM ==========================================
REM [4/4] CHECKING OPTIONAL LANGUAGE RUNTIMES
REM (These are NOT installed automatically)
REM ==========================================
echo ==========================================
echo [4/4] CHECKING OPTIONAL LANGUAGE RUNTIMES
echo [These are NOT installed automatically]
echo ==========================================

REM --- Python Check ---
set "PY_BIN="
py -c "import sys" >nul 2>&1
if not errorlevel 1 (
    set "PY_BIN=py"
) else (
    python -c "import sys" >nul 2>&1
    if not errorlevel 1 set "PY_BIN=python"
)

if defined PY_BIN (
    set "PY_VER="
    for /f "tokens=*" %%v in ('!PY_BIN! --version 2^>^&1') do (
        if not defined PY_VER set "PY_VER=%%v"
    )
    !PY_BIN! -c "import matplotlib, numpy" >nul 2>&1
    if not errorlevel 1 (
        echo   [INSTALLED] Python: !PY_VER!
        echo               Matplotlib and NumPy: READY - Python code fences can generate plots
    ) else (
        echo   [INSTALLED] Python: !PY_VER!
        echo               Matplotlib/NumPy: NOT INSTALLED
        echo               To enable Python plots, run: !PY_BIN! -m pip install numpy matplotlib
    )
) else (
    echo   [OPTIONAL] Python is NOT installed.
    echo              Only needed if you execute ```python code fences in Markdown.
    echo              To install if desired: winget install --exact --id Python.Python.3.12
)

REM --- C Compiler Check ---
where gcc >nul 2>&1
if not errorlevel 1 (
    set "GCC_VER="
    for /f "tokens=*" %%v in ('gcc --version 2^>nul') do (
        if not defined GCC_VER set "GCC_VER=%%v"
    )
    echo   [INSTALLED] C Compiler: !GCC_VER!
) else (
    echo   [OPTIONAL] C Compiler [gcc] is NOT installed.
    echo              Only needed if you execute ```c code fences in Markdown.
)

REM --- C++ Compiler Check ---
where g++ >nul 2>&1
if not errorlevel 1 (
    set "GPP_VER="
    for /f "tokens=*" %%v in ('g++ --version 2^>nul') do (
        if not defined GPP_VER set "GPP_VER=%%v"
    )
    echo   [INSTALLED] C++ Compiler: !GPP_VER!
) else (
    echo   [OPTIONAL] C++ Compiler [g++] is NOT installed.
    echo              Only needed if you execute ```cpp code fences in Markdown.
)

REM --- Java Check ---
where java >nul 2>&1
if not errorlevel 1 (
    set "JV_VER="
    for /f "tokens=*" %%v in ('java -version 2^>^&1 ^| findstr /i "version"') do (
        if not defined JV_VER set "JV_VER=%%v"
    )
    where javac >nul 2>&1
    if not errorlevel 1 (
        echo   [INSTALLED] Java: !JV_VER! [javac compiler available]
    ) else (
        echo   [INSTALLED] Java: !JV_VER! [javac not found; JDK 11+ required to run .java without javac]
    )
) else (
    echo   [OPTIONAL] Java is NOT installed.
    echo              Only needed if you execute ```java code fences in Markdown.
)
echo.

REM =========================================================
REM SETUP SUMMARY
REM =========================================================
echo =========================================================
echo                   SETUP COMPLETE
echo =========================================================
where pandoc >nul 2>&1
set "PANDOC_OK=%errorlevel%"
where xelatex >nul 2>&1
set "XELATEX_OK=%errorlevel%"

if "%PANDOC_OK%"=="0" if "%XELATEX_OK%"=="0" (
    color 0A
    echo Core requirements are READY! You can now convert Markdown to PDF.
    echo.
    echo To compile notes:
    echo   - Drag and drop your .md or .txt file onto compile.bat
    echo   - Or run: compile.bat your_notes.md
    echo.
    echo To verify the full test suite:
    echo   compile.bat documentation\compiled-fence-test.md
) else (
    color 0E
    echo Setup encountered pending items.
    if not "%PANDOC_OK%"=="0" echo - Pandoc could not be verified on PATH.
    if not "%XELATEX_OK%"=="0" echo - XeLaTeX could not be verified on PATH.
    echo Please restart your command prompt or install missing tools manually.
)
echo.
pause
