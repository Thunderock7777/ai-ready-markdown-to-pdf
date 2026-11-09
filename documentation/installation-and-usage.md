INSTALLATION AND QUICK START
============================

What this tool does
-------------------
This Windows tool turns one or more Markdown (.md/.markdown) or plain-text
(.txt) files into a PDF. It uses Pandoc to parse the document, two Lua filters
to clean and process it, and XeLaTeX to create the PDF.

Keep this folder structure together:

    your-tool-folder\
        compile.bat
        README.md
        config\
            custom.tex
            markdown-normalizer.lua
            code-fence-runner.lua
            error-annotator.lua
        documentation\
            rendering-rules.md
            installation-and-usage.md
            workflow-architecture.md
            markdown-normalizer-architecture.md
            code-fence-runner-architecture.md
            workflow-assessment.md
            contributing-and-versioning.md
            filter-feature-regression.md
            filter-feature-regression-part-2.md
            compiled-fence-test.md

The documentation\ folder contains the workflow guides and regression fixture; it is
not a required location for your own notes. Keep personal input files wherever
convenient. The generated PDF is saved beside the first input file; compiling a
file from documentation\ puts its PDF there. The config folder contains only the
template and filters.

Required tool files: compile.bat in the root, plus custom.tex,
markdown-normalizer.lua, code-fence-runner.lua, and error-annotator.lua inside config.

Best use
--------
Use this workflow to organize AI-assisted scientific literature-study notes
into a PDF and create visualizations from supplied data with Python. Verify the
papers, citations, claims, and data yourself; the tool formats and compiles
content but does not validate scientific sources or AI conclusions. Python
fences execute with your permissions, so run only code you trust.

You do not need to install LaTeX packages separately one by one if you use
MiKTeX with package installation enabled or a full TeX Live installation.
Optional Python plotting needs the extra Matplotlib package.

What to install
---------------
1. Pandoc
   Required to read Markdown, run the Lua filters, and produce LaTeX.

   Website:
   https://pandoc.org/installing.html
   Windows installer:
   https://github.com/jgm/pandoc/releases/latest

   Command line (Windows Package Manager):
   winget install --source winget --exact --id JohnMacFarlane.Pandoc

2. A LaTeX distribution that includes XeLaTeX
   Required for PDF creation. XeLaTeX is included with the distribution; it is
   not a separate program to download.

   Recommended easy option — MiKTeX:
   Website and Windows installer:
   https://miktex.org/download
   Keep MiKTeX's automatic package installation enabled. If it asks to install
   missing LaTeX packages during a build, allow it. Open MiKTeX Console and
   check for updates after installation.

   Command line:
   winget install --exact --id MiKTeX.MiKTeX

   Alternative — TeX Live:
   Windows installation instructions:
   https://tug.org/texlive/windows.html
   A full TeX Live installation is the simplest option if you want the broadest
   package coverage, but it requires substantially more disk space.

   This template uses core packages for page layout, mathematics, fonts,
   tables, hyperlinks, code, graphics, and Unicode. It loads optional packages
   only when they are present. If a pasted command uses an absent optional
   package, XeLaTeX may report an undefined command; install that package or
   remove the command.

PDF page layout
---------------
The default PDF size is A4. To create wide 16:9 landscape pages with 0.5-inch
margins, add this YAML metadata block at the start of an input:

    ```yaml
    page-layout: presentation
    ```

This changes page dimensions, not the document into a Beamer slide deck.
Unsupported page-layout values produce a warning and keep the A4 layout.

Title rule
----------
The template draws a horizontal rule below the title by default. To hide it,
add this YAML boolean to the input's metadata block:

    ```yaml
    title-rule: false
    ```

Omit the option or set it to true to keep the rule. Quoted values are not
booleans; invalid values produce a warning and keep the rule.

Compile `documentation\compiled-fence-test.md` to check fenced YAML metadata and title-rule options.

Document metadata blocks
------------------------
Metadata options (including title, author, date, page-layout, and title-rule)
can be authored inside fenced code blocks:

    ```yaml
    title: "Document Title"
    author: "Biswanath Sen"
    date: "2026-11-07"
    ```

Fenced YAML blocks (tagged `yaml` or `{.yaml}`) are extracted as document
metadata before parsing, avoiding collisions with Markdown hyphens and rules.
Traditional `--- ... ---` blocks are deliberately NOT recognized as metadata and
are treated as plain Markdown (thematic breaks or body text). To display a
verbatim YAML code listing without treating it as metadata, specify `run=false`
(e.g., ```` ```yaml run=false ````).

3. Python (only if you use Python code fences)
   The workflow invokes the Windows Python launcher as "py". Install Python
   from python.org and make sure the Python launcher is installed. The runner
   needs Python 3.8 or newer; Python 3.12.0 was used to validate this workflow.

   Website:
   https://www.python.org/downloads/windows/

   Command line (Windows Package Manager):
   winget search --id Python.Python
   winget install --exact --id Python.Python.3.12

   If your selected Python version has a different package ID, use the exact ID
   shown by the search command. Close and reopen Command Prompt after install.
   The workflow does not install Python packages for you. Python code blocks use
   the standard library unless the code imports third-party packages; install
   each such package before compiling, into the same Python interpreter that
   "py" selects. For example, run `py -m pip install package-name`. A missing
   package causes that Python fence to fail; the PDF build does not install it
   automatically.

4. Optional: NumPy and Matplotlib
   Needed only for Python code that imports them. The regression fixture's
   probability/running-average graph uses both; ordinary text/math PDFs and
   standard-library-only Python fences do not need them. Install before
   compiling the graph example:

   Command line:
   py -m pip install numpy matplotlib

   Project website:
   https://matplotlib.org/stable/install/

5. C, C++, and Java Compilers and Runners (for executable compiled fences)
   - C fences use `gcc` by default. Override with the `C_COMPILER` environment
     variable (e.g. `set C_COMPILER=clang`).
   - C++ fences use `g++` by default. Override with the `CPP_COMPILER` environment
     variable (e.g. `set CPP_COMPILER=clang++`).
   - Java fences use `java` by default (override with `JAVA_RUNNER`) and `javac`
     for compilation (override with `JAVAC_COMPILER`). Java 11+ single-file
     execution is supported even when `javac` is not installed on PATH.
   All three languages support full standalone programs (with `main`) and bare
   snippets (automatically wrapped in standard headers and a `main` entry point).
   Compile `documentation\compiled-fence-test.md` to verify these fences.

Quick installation by command line
----------------------------------
Open Command Prompt or PowerShell and run:

    winget install --source winget --exact --id JohnMacFarlane.Pandoc
    winget install --exact --id MiKTeX.MiKTeX
    winget search --id Python.Python
    winget install --exact --id Python.Python.3.12

The Python installation command is needed only if you use Python fences. If
Winget does not have the requested Python package ID on your Windows version,
use the official Python website above. Restart the terminal after installing
software so PATH changes are recognized.

Install optional Python dependencies separately, before compiling. For the
regression fixture's probability graph:

    py -m pip install numpy matplotlib

Check that installation worked
------------------------------
Open a new terminal and run:

    pandoc --version
    xelatex --version
    py --version

The Python check is optional if you will not use Python fences. Each command
should print a version instead of "not recognized". If xelatex is not found,
finish the MiKTeX/TeX Live setup and reopen the terminal.

Create your first PDF
---------------------
1. Save your notes as .txt or .md.
2. Keep referenced local images and data files beside the first input file
   (relative paths are resolved from that file's folder).
3. Drag the input file onto compile.bat, or run:

       "C:\path\to\compile.bat" "C:\path\to\my-notes.txt"

   In PowerShell, from the folder containing compile.bat:

       .\compile.bat ".\my-notes.txt"

   If the input is in a different folder, pass its absolute path (or a relative
   path from the current directory):

       .\compile.bat "C:\Users\you\Documents\my-notes.txt"
       .\compile.bat ".\documentation\filter-feature-regression.md"

4. Find the PDF beside the first input file. Therefore, a file in
   Documents\ produces its PDF in Documents\, not beside compile.bat. The config
   folder contains only the template and filters.

Compile an AI response without editing it
-----------------------------------------
Copy a complete, uncorrupted response from ChatGPT, Gemini chat, NotebookLM, or
another assistant, paste it as-is into a .txt file, and compile that file with
compile.bat. Supported content can be compiled with zero editing. Do not wrap
the entire response in a code fence.

This does not guarantee that every arbitrary LaTeX command, attachment, or
service-specific format will work unchanged. In particular, Gemini search-
engine suggestions usually do not include fenced code blocks. Code in such a
suggestion will not be recognized or executed as a code block unless the
required fence is added; prose-only suggestions can still be compiled as text.

To combine files, pass quoted paths in the desired order:

    "C:\path\to\compile.bat" "C:\notes\part-1.txt" "C:\notes\part-2.txt"

The PDF is named after the first input and is saved beside it. The compiler
checks all input paths before building. Text normalization does not modify
source files, though Python fences can write files they explicitly open.

Simple writing rules
--------------------

Rule of thumb:
    Normal writing, headings, lists, tables, links, and formulas: use Markdown
    or plain text without a language fence. Headings use standard `#`, `##`, `###` syntax;
    standalone `---` produces a horizontal divider line; tables use pipe syntax (`| col | col |`).
    Pasted LaTeX source that should be rendered: use a latex fence.
    All non-Markdown code must be fenced; unfenced LaTeX in Markdown prose is treated
    as literal text and will not execute (-raw_tex). Each LaTeX fence is strictly isolated
    ({\begingroup ... \par\endgroup}): packages, TikZ libraries, and preamble-only declarations
    (\DeclareMathOperator, \newunicodechar, \DeclarePairedDelimiter) are hoisted to the preamble
    (\DeclareMathOperator guarded with \let\cmd\relax), while custom macros, font families
    (\newfontfamily, \newfontface, etc.), and environments remain strictly local to the fence.
    Cross-fence redefinition of global commands or conflicting package imports automatically
    demote to code listings (run=false) with a console warning.
    Python source that should execute: use a python fence.

Markdown / ordinary text — no fence:

    # Heading

    This is **bold**, *italic*, and inline math is $a^2 + b^2 = c^2$.

    | Name | Value |
    |---|---:|
    | x | 10 |

For a checklist, include the list marker before the checkbox:

    - [ ] First task
    - [x] Completed task

Writing `[ ] First task` without the leading `-` is just paragraph text, not a
list.

LaTeX — use a LaTeX fence to render a snippet (not execute it):

    ```{.latex}
    \[
    \int_0^1 x^2\,dx = \frac{1}{3}.
    \]
    ```

To display LaTeX source code as a syntax-highlighted code listing without
rendering it, specify `run=false` (e.g., ```` ```latex run=false ````). To
display code fences literally, in Markdown rules, 4 backticks on the outside
prevent the 3 backticks on the inside from closing the block, so the entire code
fence prints visibly as plain text in the PDF:

    ````markdown
    ```latex
    \lhead{Notes}
    ```
    ````

Crash-proof / zero-rules raw text:
To paste completely arbitrary, unformatted, or potentially broken text (such as
unbalanced braces, raw TeX macros, code dumps, or special characters like %, $, _, &, #)
with zero chance of a LaTeX error, wrap it in a text fence (```` ```text ... ``` ````).
Inside a text block, the template's `fvextra` engine treats every character as inert ASCII
and automatically wraps long lines, making it 100% crash-proof without needing manual escaping.
If the text itself contains triple-backtick fences (e.g. a nested ```yaml block), wrap the
outer block in 4 backticks (```` ````text ... ```` ````) and add `run=false` on any inner YAML
block so the normalizer does not extract it as document metadata:

    ````text
    ```yaml run=false
    title: none
    ```
    Paste literally anything here: % $ & _ { } \ ^ ~ # < > |
    \begin{broken_command} \not_real_macro{{{
    No rules, no syntax checks, no math parsing, no formatting.
    ````



Python — a Python fence runs by default:

    ```{.python}
    print("Hello from Python")
    ```

Before an uncached Python block runs, compile.bat shows its code and asks
whether you trust it. Enter Y to run it; any other response leaves it as a
source listing. A valid cached result is reused without asking. `trusted=true`
skips the prompt for a normal first run.

Python execution and caching:
    - No run attribute or run=true: run when needed; ask before the first
      uncached run, then reuse unchanged valid results without asking.
    - run=new: bypass cache and ask before every fresh run, then refresh its
      cache on success.
    - cache=false: also bypass cache and ask before every fresh run.
    - run=false: do not execute; show it as a normal code listing.
    - trusted=true: skip the confirmation for an ordinary uncached run;
      run=new and cache=false still require confirmation.
    - show=false: hide the source listing.
    - output=false: hide printed output in the PDF.
    - figures=false: do not embed captured figures; code may still save files.

Example forced Python run:

    ```{.python run=new show=false}
    print("Always execute this block for this build.")
    ```

Use run=new for code that depends on information the cache cannot detect, such
as network responses, environment variables, or changing external services.
Review the displayed code before approving it. The confirmation prompt is not a
sandbox: approved Python code executes with your user permissions.

Common problems
---------------
- "pandoc is not recognized": install Pandoc and reopen the terminal.
- "xelatex is not recognized": install/update MiKTeX or TeX Live and reopen the
  terminal; verify that XeLaTeX is included and on PATH.
- A missing .sty package: allow MiKTeX to install it, update the distribution,
  or install the package using your distribution's package manager.
- Python fence says Python is missing: install Python with its Windows launcher,
  then check py --version. The batch compiler sets PYTHON=py.
- A Python import fails: the workflow does not install Python packages
  automatically. Install the package into the interpreter used by py, for
  example `py -m pip install matplotlib`.
- A glyph is blank: the template may not map that character or the font may not
  contain it. Check the XeLaTeX log and the template's Unicode notes.
- A Python block is unexpectedly cached: add run=new or cache=false.
- The PDF is open and cannot be replaced: close it in the PDF viewer and run
  compile.bat again.
- The build reports errors: read the Pandoc/XeLaTeX messages printed by
  compile.bat. When XeLaTeX encounters localized document-body errors, the
  workflow triggers an error recovery pass that annotates the offending site
  directly in the final PDF with a red bold [!!!] badge and detokenized code,
  switching console colors to yellow (color 0E) to report the mapped errors.

What you do not need
--------------------
- No separate XeTeX download: it comes with MiKTeX or TeX Live.
- No extra Python packages for ordinary Markdown, math, LaTeX fences, or
  standard-library Python examples.
- No manual install of every template package when using a full TeX Live
  installation or MiKTeX's package-on-demand feature.

For detailed filter order, cache internals, metadata behavior, supported input
contracts, failure modes, and extension guidance, read
documentation\workflow-architecture.md.
