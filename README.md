# Markdown to PDF

A Windows workflow for turning Markdown or plain-text notes into a PDF with
Pandoc, XeLaTeX, and two Lua filters. Python code fences can run during the
build, while LaTeX fences render source snippets without executing them.

**Current project version: 1.0.0** (working baseline; release tag pending).

> **Paste an AI chat response and compile it directly.** An intact, uncorrupted
> copied response from ChatGPT, Gemini chat, or NotebookLM can be compiled as-is
> with no editing when it uses supported content. This does not cover Gemini
> search-engine suggestions: these usually lack fenced code blocks, so code in
> them will not be recognized or executed as a code block. Unsupported commands,
> missing packages, or missing fonts may still need attention.

## Features

- Compile AI-generated responses from ChatGPT, Gemini, or NotebookLM directly,
  without manual editing of supported content.
- Compile one or several `.md`, `.markdown`, or `.txt` files in a specified order.
- Render Markdown, math, tables, citations, selected pasted LaTeX, and code.
- Execute Python fences with optional output, source, figure, and cache controls.
- Reuse valid Python results from cache, or force a fresh run when needed.
- The text-processing stages leave source files unchanged. Python fences can
  still write files they explicitly open; PDFs are saved beside the first input.

## Best use

Use the workflow to turn AI-assisted scientific literature-study notes into a
readable PDF and to create visualizations from supplied data with Python. Check
the papers, citations, claims, and data yourself: this tool formats and
compiles content, but does not verify research or validate an AI's conclusions.
Python code runs with your permissions, so run only code you trust.

## Folder layout

Keep the compiler and its configuration files together:

```text
your-tool-folder/
├── compile.bat
├── README.md
├── manual/
│   ├── FILTER_FEATURE_REGRESSION.txt
│   ├── FILTER_FEATURE_REGRESSION_PART2.txt
│   ├── CONTRIBUTING_AND_VERSIONING.txt
│   ├── INSTALL_AND_USE.txt
│   ├── CODE_FENCE_RUNNER_ARCHITECTURE.txt
│   ├── MARKDOWN_NORMALIZER_ARCHITECTURE.txt
│   ├── WORKFLOW_ARCHITECTURE.txt
│   └── WORKFLOW_ASSESSMENT.txt
└── config/
    ├── custom.tex
    ├── markdown-normalizer.lua
    └── code-fence-runner.lua
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
full TeX Live installation. See [INSTALL_AND_USE.txt](manual/INSTALL_AND_USE.txt) for
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
`.\compile.bat ".\manual\FILTER_FEATURE_REGRESSION.txt"`. The PDF is saved
beside the first input file, not necessarily beside `compile.bat`.

Combine files by passing their quoted paths in the desired order:

```bat
"C:\path\to\your-tool-folder\compile.bat" "C:\notes\part-1.txt" "C:\notes\part-2.txt"
```

The output is named after the first input (`part-1.pdf` in this example) and
saved beside that input. Relative image and data paths are resolved from the
first input's directory, including paths mentioned by later inputs.

### Compile an AI response without editing it

1. Copy a complete, uncorrupted response from ChatGPT, Gemini chat, NotebookLM,
   or another assistant.
2. Paste it as-is into a `.txt` file and save it. Do not wrap the entire
   response in a code fence.
3. Compile that `.txt` file with `compile.bat`.

For supported content, the copied response can be compiled with zero editing.
The response must not be corrupted or truncated, and arbitrary commands,
attachments, or unsupported formats are not guaranteed to work. Gemini
search-engine suggestions are a specific limitation: they usually do not
include fenced code blocks, so code in those suggestions cannot be recognized
or executed as a code block without adding the required fence. Prose-only
suggestions can still be compiled as text.

## Writing rules

Use ordinary Markdown or plain text for prose, headings, lists, tables, and
formulas. Do not fence normal Markdown:

```markdown
# Results

The answer is **42**, and inline math works: $a^2 + b^2 = c^2$.

| Name | Value |
|---|---:|
| x | 10 |
```

Use a `latex` fence for LaTeX snippets that should be rendered, not executed:

````markdown
```{.latex}
\[
\int_0^1 x^2\,dx = \frac{1}{3}.
\]
```
````

Python fences render as source by default. Add `trusted=true` or an explicit
`run=true`/`run=new` to execute a block:

````markdown
```{.python trusted=true}
print("This block only runs because it is explicitly trusted.")
```
````

Supported executable-language names include `python`, `py`, `python3`, and
`py3`; LaTeX rendering recognizes `latex` and `tex`.

### Python fence options

Options are written as Pandoc fence attributes:

````markdown
```{.python trusted=true run=new show=false}
print("This block runs freshly for this build.")
```
````

| Attribute | Effect |
|---|---|
| `trusted=true` | Explicitly mark the block as safe to run. Only trusted Python blocks execute. |
| `run=true` | Explicit opt-in to execute; reuse a valid cached result. |
| `run=new` | Force execution for this build and refresh the cache on success. |
| `cache=false` | Also force a fresh execution. |
| `run=false` | Do not execute; render as a code listing. |
| `show=false` | Hide the source listing. |
| `output=false` | Hide captured standard output in the PDF. |
| `error=false` | Hide the rendered error; the error is still reported in the console. |
| `figures=false` | Do not embed captured Python figures. |
| `maxlines=N` | Limit the number of displayed output lines. |
| `deps="a.csv,b.npy"` | Include these files in the Python block's cache key. |

The regression guide compares default cached Python, `run=new` fresh execution,
and `run=false` source-only rendering with a NumPy/Matplotlib running-average
coin-flip graph. To enable the optional graphs, install both packages with
`py -m pip install numpy matplotlib`.

Use `run=new` or `cache=false` for blocks whose results depend on changing
external state, such as network responses or environment variables. Cache
tracking cannot account for every external dependency.

**Only compile documents you trust:** Python fences execute with your user
permissions and can access files and resources available to your account.

## Validation and documentation

To run the bundled end-to-end regression document, compile it by itself:

```powershell
.\compile.bat ".\manual\FILTER_FEATURE_REGRESSION.txt"
```

Run this command from the tool root. The fixture PDF is written beside the
input, in `manual\`. The fixture intentionally contains expected warnings and
Python failures to exercise error handling; read its opening section for
expected results.

The companion fixture also tests combining two inputs in order:

```powershell
.\compile.bat ".\manual\FILTER_FEATURE_REGRESSION.txt" ".\manual\FILTER_FEATURE_REGRESSION_PART2.txt"
```

The expected markers and verification steps are documented in the regression
fixture.

- [INSTALL_AND_USE.txt](manual/INSTALL_AND_USE.txt) — beginner installation and usage guide.
- [WORKFLOW_ARCHITECTURE.txt](manual/WORKFLOW_ARCHITECTURE.txt) — detailed pipeline,
  filter-order, cache, and maintenance documentation.
- [MARKDOWN_NORMALIZER_ARCHITECTURE.txt](manual/MARKDOWN_NORMALIZER_ARCHITECTURE.txt) —
  normalizer function reference, stages, state, and change/test guide.
- [CODE_FENCE_RUNNER_ARCHITECTURE.txt](manual/CODE_FENCE_RUNNER_ARCHITECTURE.txt) —
  runner function reference, Python wrapper/cache flow, and change/test guide.
- [FILTER_FEATURE_REGRESSION.txt](manual/FILTER_FEATURE_REGRESSION.txt) — broad
  feature and failure-path validation input.
- [CONTRIBUTING_AND_VERSIONING.txt](manual/CONTRIBUTING_AND_VERSIONING.txt) —
  project change, documentation, mandatory focused `.txt` testing, and
  version-tracking rules.
- [WORKFLOW_ASSESSMENT.txt](manual/WORKFLOW_ASSESSMENT.txt) — candid scorecard,
  limitations, and documentation audit.

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
