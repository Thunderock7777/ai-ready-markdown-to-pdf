# Markdown to PDF

A Windows workflow for turning Markdown or plain-text notes into a PDF with
Pandoc, XeLaTeX, and two Lua filters. Executable code fences in Python, C, C++,
and Java can run during the build with universal caching and approval controls,
while LaTeX fences render source snippets without executing them.

**Current project version: 1.3.1**.

> **Paste an AI chat response and compile it directly.** A copied response from
> ChatGPT, Gemini chat, or NotebookLM can be compiled as-is when it uses
> supported Markdown and code fences. Code execution requires standard language
> fences (e.g. ```` ```python ````, ```` ```c ````, ```` ```cpp ````, ```` ```java ````).

## Features

- **Direct AI Chat Compilation**: Compile copied responses from ChatGPT, Gemini, or NotebookLM with zero manual editing for supported content.
- **Multi-File Concatenation**: Compile one or several `.md`, `.markdown`, or `.txt` files in a specified order into a single unified PDF.
- **Universal Executable Code Fences**: Python, C, C++, and Java blocks execute with persistent SHA-1 caching, interactive confirmation prompts (`trusted=true` bypass), output capture, and compiler/runtime error reporting.
- **Uniform Fence Syntax**: Standard fenced code blocks (```` ```<lang> ... ``` ```` or ```` ```{.<lang> ...} ````) across all languages; raw delimiters like `---` are reserved for horizontal rules and never treated as metadata.
- **Block Boundary Spacing & Clean Tables**: Standalone horizontal rules (`---`) and fences are automatically padded with empty lines. Non-standard `simple_tables` are disabled to prevent narrow column collapses, ensuring pipe tables (`| col | col |`) render reliably.
- **Code Fence Isolation & Stray TeX Protection**: LaTeX fences are locally scoped (`{\begingroup...\par\endgroup}`), preventing definitions or colors from leaking. Unfenced LaTeX commands in prose are treated as literal text (`-raw_tex`).
- **Localized XeLaTeX Error Recovery**: Neutralizes localized LaTeX document errors with red `[!!!]` badges in the PDF and yellow console diagnostics instead of crashing the build.
- **Page Layout & Title Controls**: Toggle between standard A4 and 16:9 presentation layout, or hide the horizontal title divider rule using YAML front matter.
- **Non-Destructive Processing**: Source files are never modified; generated PDFs are saved beside the primary input file.

## Best use

Use the workflow to turn AI-assisted literature notes, research summaries, and
technical drafts into publication-quality PDFs, and to generate figures dynamically
from Python. Always verify citations, claims, and data yourself: this tool formats
and compiles content, but does not validate research accuracy.

## Folder layout

Keep the compiler and its configuration files together:

```text
your-tool-folder/
├── compile.bat
├── README.md
├── documentation/
│   ├── rendering-rules.md
│   ├── installation-and-usage.md
│   ├── workflow-architecture.md
│   ├── markdown-normalizer-architecture.md
│   ├── code-fence-runner-architecture.md
│   ├── contributing-and-versioning.md
│   ├── workflow-assessment.md
│   ├── filter-feature-regression.md
│   ├── filter-feature-regression-part-2.md
│   └── compiled-fence-test.md
└── config/
    ├── custom.tex
    ├── markdown-normalizer.lua
    ├── code-fence-runner.lua
    └── error-annotator.lua
```

The compiler creates `md2pdf_cache/` beside `compile.bat`. It is safe to remove
that folder when no build is running; cached results will be regenerated.

## Requirements

- **Pandoc** with Lua-filter support: [installation instructions](https://pandoc.org/installing.html)
- **XeLaTeX**, included with a LaTeX distribution:
  [MiKTeX for Windows](https://miktex.org/download) or
  [TeX Live for Windows](https://tug.org/texlive/windows.html)
- **Python 3.8 or newer**, only if using Python fences. The workflow invokes the
  Windows Python launcher, `py`: [Python downloads](https://www.python.org/downloads/windows/)
- **Python packages are not installed by this workflow.** Install third-party
  packages imported by your Python blocks into the interpreter used by `py`
  before compiling. For example, Matplotlib is needed only for code that imports
  it: `py -m pip install matplotlib`.

For LaTeX packages, use MiKTeX with automatic package installation enabled or a
full TeX Live installation. See [installation-and-usage.md](documentation/installation-and-usage.md) for
installation steps, command-line options, troubleshooting, and examples.

## Quick start

Drag an input file onto `compile.bat`, or run it from Command Prompt:

```bat
"C:\path\to\your-tool-folder\compile.bat" "C:\path\to\notes.md"
```

In PowerShell, if your current directory is the tool folder, use `.\compile.bat`.
These two cases show how to specify the input:

```powershell
# Input file is in the same folder as compile.bat
.\compile.bat ".\notes.txt"

# Input file is in a different folder (absolute path shown)
.\compile.bat "C:\Users\you\Documents\notes.txt"
```

You can also pass a relative path from the tool folder, for example
`.\compile.bat ".\documentation\filter-feature-regression.md"`. The PDF is saved
beside the first input file, not necessarily beside `compile.bat`.

Combine files by passing their quoted paths in the desired order:

```bat
"C:\path\to\your-tool-folder\compile.bat" "C:\notes\part-1.txt" "C:\notes\part-2.txt"
```

The output is named after the first input (`part-1.pdf` in this example) and
saved beside that input. Relative image and data paths are resolved from the
first input's directory, including paths mentioned by later inputs.

### Compile an AI response without editing it

1. Copy a complete response from ChatGPT, Gemini chat, NotebookLM, or another assistant.
2. Paste it as-is into a `.txt` or `.md` file and save it (do not wrap the whole document in a single code fence).
3. Compile that file with `compile.bat`.

Supported Markdown formatting, math, citations, and fenced code blocks will render and run automatically. Code blocks must use standard Markdown fences (```` ```python ````, ```c```, etc.) to be recognized and executed.

## Writing rules

Use ordinary Markdown or plain text for prose, headings, lists, tables, and
formulas. Headings use standard `#`, `##`, `###` syntax. Standalone `---` produces
a horizontal divider rule (`\hrulefill`). Tables use standard Markdown pipe syntax
(`| col | col |`). Do not fence normal Markdown:

```markdown
# Results

The answer is **42**, and inline math works: $a^2 + b^2 = c^2$.

| Name | Value |
|---|---:|
| x | 10 |
```

The PDF uses A4 by default. To use a 16:9 landscape page with 0.5-inch margins,
add this YAML metadata block at the start of the input:

```yaml
page-layout: presentation
```

Other `page-layout` values are unsupported; they produce a warning and use A4.

The horizontal rule below the title appears by default. To hide it, add the
boolean option to the YAML front matter:

```yaml
title-rule: false
```

Omit this option or set it to `true` to keep the rule.

Document metadata (such as `title`, `author`, `date`, `page-layout`, and
`title-rule`) must be authored inside fenced ```` ```yaml ... ``` ```` blocks
(or ```` ```{.yaml} ... ``` ````). Traditional `--- ... ---` blocks are NOT
recognized as metadata and are treated as standard Markdown content (horizontal
rules or body text). If you want to show a verbatim YAML code listing in the PDF
without applying it as metadata, add `run=false` (e.g. ```` ```yaml run=false ````).

Use a `latex` fence for LaTeX snippets that should be rendered, not executed:

````markdown
```{.latex}
\[
\int_0^1 x^2\,dx = \frac{1}{3}.
\]
```
````

Executable code fences (`python`, `c`, `cpp` / `c++`, `java`) execute by default.
On the first run of a block without a valid cached result, the build asks whether you
trust the code and displays it for review. Enter `Y` to run it; any other response leaves
it as a code listing. A valid cached result is reused without asking. `trusted=true`
skips the confirmation for a normal first run:

````markdown
```{.python}
print("This block runs after you approve it.")
```
````

For C, C++, and Java, both full standalone programs (with `main`) and bare snippets
(statements without `main`) are supported. Snippets are automatically wrapped in
standard includes and a `main` entry point for compilation.

Supported executable-language names:
- **Python**: `python`, `py`, `python3`, `py3` (configurable via `PYTHON`, default `py`)
- **C**: `c` (configurable via `C_COMPILER`, default `gcc`)
- **C++**: `cpp`, `c++`, `cxx`, `cc` (configurable via `CPP_COMPILER`, default `g++`)
- **Java**: `java` (configurable via `JAVA_RUNNER`, default `java`; `JAVAC_COMPILER`, default `javac`)
- **LaTeX rendering**: `latex`, `tex` (rendered into the PDF, not executed)

### Code fence options

Options are written as Pandoc fence attributes (e.g. ```` ```{.python run=new show=false} ```` or ```` ```python run=new show=false ````):

| Attribute | Effect |
|---|---|
| `trusted=true` | Skip confirmation for a normal first run across any executable language. Forced fresh runs still ask. |
| Omitted `run` or `run=true` | Execute by default; ask before the first uncached run and reuse a valid cached result. |
| `run=new` | Ask and force execution for this build; refresh the cache on success. |
| `cache=false` | Also ask and force a fresh execution. |
| `run=false` | Do not execute; render as a syntax-highlighted code listing. |
| `show=false` | Hide the source listing. |
| `output=false` | Hide captured standard output in the PDF. |
| `error=false` | Hide the rendered error; the error is still reported in the console. |
| `maxlines=N` | Limit the number of displayed output lines. |
| `deps="a.csv,b.npy"` | Include these files in the block's cache key. |
| `figures=false` | Python only: do not embed captured figures in the PDF. |

The regression guide compares default cached Python, `run=new` fresh execution,
and `run=false` source-only rendering. Compile `documentation\compiled-fence-test.md`
to verify all language code fences, compilation, execution, and error handling.
Optional Python graphs require `py -m pip install numpy matplotlib`.

Use `run=new` or `cache=false` for blocks whose results depend on changing
external state, such as network responses or environment variables. Cache
tracking cannot account for every external dependency.

**Only compile documents you trust:** Executable code fences run with your user
permissions and can access local files and system resources.

## Validation and documentation

To run the bundled end-to-end regression document, compile it by itself:

```powershell
.\compile.bat ".\documentation\filter-feature-regression.md"
```

Run this command from the tool root. The fixture PDF is written beside the
input, in `documentation\`. The fixture intentionally contains expected warnings and
Python failures to exercise error handling; read its opening section for
expected results.

The companion fixture also tests combining two inputs in order:

```powershell
.\compile.bat ".\documentation\filter-feature-regression.md" ".\documentation\filter-feature-regression-part-2.md"
```

The expected markers and verification steps are documented in the regression
fixture.

To test all supported code fences (Python, C, C++, Java, LaTeX, YAML, etc.), compile the test suite:

```powershell
.\compile.bat ".\documentation\compiled-fence-test.md"
```

- [rendering-rules.md](documentation/rendering-rules.md) — complete language-by-language rendering rules, execution pipeline, and attribute reference.
- [installation-and-usage.md](documentation/installation-and-usage.md) — installation and usage guide.
- [workflow-architecture.md](documentation/workflow-architecture.md) — detailed pipeline,
  filter-order, cache, and maintenance documentation.
- [markdown-normalizer-architecture.md](documentation/markdown-normalizer-architecture.md) —
  normalizer function reference, stages, state, and change/test guide.
- [code-fence-runner-architecture.md](documentation/code-fence-runner-architecture.md) —
  runner function reference, Python wrapper/cache flow, and change/test guide.
- [contributing-and-versioning.md](documentation/contributing-and-versioning.md) —
  project change, documentation, mandatory focused testing, and
  version-tracking rules.
- [workflow-assessment.md](documentation/workflow-assessment.md) — candid scorecard,
  limitations, and documentation audit.
- [filter-feature-regression.md](documentation/filter-feature-regression.md) — broad
  feature and failure-path validation input.
- [filter-feature-regression-part-2.md](documentation/filter-feature-regression-part-2.md) —
  companion input for the multi-file regression check.
- [compiled-fence-test.md](documentation/compiled-fence-test.md) —
  master test fixture validating code fences across all supported languages, execution attributes, and error modes.

## Known limitations

- This is a Windows `.bat` workflow and requires XeLaTeX.
- Bibliographies use Pandoc citeproc conventions; raw natbib/biblatex workflows
  are not supported.
- Python dependencies must be installed separately, and cache tracking cannot
  capture every external input or side effect.
- Optional LaTeX packages and fonts may need to be installed; missing glyphs or
  unsupported commands can result in warnings or incomplete output.

For exact supported behavior and caveats, consult the architecture guide and the
feature regression document.

## License

This project is distributed under the [MIT License](LICENSE).
