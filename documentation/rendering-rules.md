# Pipeline Rendering Rules & Language Reference

This document is the authoritative reference for how content is parsed, transformed, executed, and rendered across all supported languages in the latest version of the Markdown-to-PDF pipeline.

---

## 1. Architectural Pipeline Overview

Every document processed by `compile.bat` flows through a strictly ordered multi-stage pipeline:

```
Input File (.md / .txt)
   │
   ▼
[Stage A: Source Normalization] ─── markdown-normalizer.lua
   │  • Unicode math symbol mapping & invisible character scrubbing
   │  • Fenced YAML metadata extraction & stripping
   │  • Universal block boundary spacing & table math preservation
   │
   ▼
[Pandoc AST Parsing]
   │  • -raw_tex: Disables raw TeX parsing so backslashes in prose are safely escaped
   │  • -simple_tables: Disables fragile dash-parsing to avoid breaking Markdown prose
   │  • -yaml_metadata_block: Suppresses classic '---' blocks in favor of fenced YAML
   │
   ▼
[Stage B: AST Transformation] ─── markdown-normalizer.lua
   │  • Header, figure, task list, and math font normalization (\mathbf, \mathnormal)
   │  • Table formatting & bibliography resolution (--citeproc)
   │
   ▼
[Stage C: Code Fence Execution & Caching] ─── code-fence-runner.lua
   │  • Language dispatch (Python, C, C++, Java, LaTeX, YAML, Text)
   │  • Universal TeX group isolation: {\begingroup ... \par\endgroup}
   │  • Preamble hoisting with \let\cmd\relax safety & local font-family scoping
   │  • Cross-fence global command conflict protection (demotion to run=false)
   │  • Snippet auto-wrapping (#line 1 in C/C++; class Main in Java)
   │  • SHA-1 cache lookup & dependency tracking (rf4 cache schema)
   │
   ▼
[XeLaTeX Multi-Pass Compilation] ─── compile.bat
   │  • Passes 1 to 3 with label/reference change detection
   │  • max_print_line=1000 for full error message capture
   │
   ▼
[Error Recovery Fallback] ─── error-annotator.lua
   │  • Localizes syntax crashes to the offending line
   │  • Neutralizes the line with \detokenize and marks it with red [!!!] boxes
   │
   ▼
Final Output PDF (Delivered beside first input file)
```

---

## 2. Master Language Index & Classification

The pipeline recognizes **7 distinct language categories**, each with its own execution model, isolation guarantees, and output formatting:

| Language Identifier | Aliases | Classification | Execution Engine | Primary Output in PDF |
|---|---|---|---|---|
| **Markdown** | `md`, `markdown`, *(plain prose)* | Document Body & Typography | Pandoc + `markdown-normalizer.lua` | Formatted text, headings, tables, formulas |
| **YAML** | `yaml`, `.yaml`, `{yaml}`, `{.yaml}` | Document Configuration | Lua Pre-processor (Stage A) | Metadata injection (or code listing if `run=false`) |
| **LaTeX / TeX** | `latex`, `tex` | Direct Vector & Math Typesetting | XeLaTeX via `code-fence-runner.lua` | Rendered document graphics/math inside local TeX group |
| **Python** | `python`, `py`, `python3`, `py3` | Dynamic Script Execution | Windows `py` launcher + SHA-1 Cache | Console stdout + Matplotlib figures + Error boxes |
| **C** | `c` | Compiled Native Binary | `gcc -O2` + Auto-Wrapper + Cache | Console stdout + Compiler errors |
| **C++** | `cpp`, `c++`, `cxx`, `cc` | Compiled Native Binary | `g++ -O2 -std=c++17` + Auto-Wrapper + Cache | Console stdout + Compiler errors |
| **Java** | `java` | JVM Compiled / Script Execution | `javac` / `java` + Auto-Wrapper + Cache | Console stdout + JVM diagnostics |
| **Raw / Gibberish Text** | `text`, `txt`, *(no tag)* | 100% Crash-Proof Verbatim | LaTeX `fvextra` Verbatim Engine | Verbatim text box with automatic line-wrapping |

---


## 3. Language-by-Language Deep Dive

---

### 3.1. Markdown (`md`, `markdown`, Plain Prose)

#### How It Renders Under the Hood
* **Normalizer Interception:** In Stage A, `markdown-normalizer.lua` scans the document before Pandoc touches it. It scrubs invisible Unicode characters, normalizes lookalike math symbols (converting raw Unicode Greek `α`, `β`, arrows `→`, and operators `≤`, `∫` into their correct LaTeX counterparts `\alpha`, `\beta`, `\to`, `\le`, `\int`), and aggregates stacked super/subscripts (`x¹²` $\rightarrow$ `x^{12}`). Full Latin and Greek subscript coverage (`ₐ ₑ ₕ ᵢ ⱼ ₖ ₗ ₘ ₙ ₒ ₚ ᵣ ₛ ₜ ᵤ ᵥ ₓ` and `ᵦ ᵧ ᵨ ᵩ ᵪ`) is guaranteed in both math mode (`x_{i}`) and text mode without font glyph dropouts.
* **Stray TeX Protection (`-raw_tex`) & AST-Preserved Constructs:** Pandoc runs with `-raw_tex` disabled. Unfenced arbitrary LaTeX commands typed in ordinary paragraphs (e.g. `\lhead{Notes}` or `\mycommand`) are **not** executed by XeLaTeX; they are automatically escaped to literal text (`\textbackslash{}lhead\{Notes\}`) so they can never crash the build. Meanwhile, standard document cross-references (`\ref{...}`, `\eqref{...}`, `\autoref{...}`, `\pageref{...}`, `\nameref{...}`, `\cite{...}`), non-breaking ties (`~` / `\nobreakspace{}`), and HTML remnants (`<sub>...</sub>`, `<sup>...</sup>`, `<br>`) are preserved and converted to native unescaped AST nodes so they render cleanly in LaTeX.
* **CommonMark Code Span Boundaries:** Backticks inside inline code spans are parsed strictly under CommonMark rules: preceding backslashes do not escape closing backticks (e.g. `` `C:\Windows\` `` closes properly and never leaks into subsequent text).
* **Table & Layout Safety (`-simple_tables`):** Pandoc's `simple_tables` extension is disabled. Three consecutive dashes (`---`) typed on their own line are always treated as a visual horizontal rule divider, never as an unclosed table row. Pipe tables (`| col | col |`) receive universal boundary spacing to prevent merging with surrounding text.
* **Nested Environment & Display Math Robustness:** Theorem-like and quote environments can be nested to arbitrary depths (`\begin{theorem}...\begin{quote}...\end{quote}...\end{theorem}`) via a re-entrant stack in `markdown-normalizer.lua`. Bare AMS math environments (`\begin{align}`, `equation`, `gather`, `multline`, etc.) appearing directly in Markdown prose without math delimiters are automatically wrapped in `$$\n...\n$$`, ensuring they are parsed natively as DisplayMath rather than escaped to `\textbackslash begin` under `-raw_tex`. Any custom theorem environment declared via `\newtheorem` is dynamically registered into `REGISTRY.DIV_ENVS`, enabling native Markdown Div conversion. Display math (`$$...$$`) unwraps `\begin{align}` even when preceded or followed by text or comments, and inline currency amounts (e.g. `$50 (base_fee = $30)`) are strictly isolated from math delimiter heuristics.

#### Examples

**Basic Typography and Equations:**
```markdown
# 1. Classical Mechanics

A particle of mass $m$ experiencing a restoring force has potential energy:

$$V(x) = \frac{1}{2} k x^2$$

Unicode symbols like α, β, and ∫ are automatically converted to LaTeX math:
The integral ∫ from 0 to ∞ of $e^{-x}\,dx = 1$.
```

**Pipe Table & Task Lists:**
```markdown
| Parameter | Symbol | Nominal Value | Units |
|---|:---:|:---:|---|
| Mass | $m$ | 1.50 | kg |
| Spring Constant | $k$ | 250 | N/m |

- [x] Derivation verified
- [ ] Experimental calibration completed
```

---

### 3.2. YAML (`yaml`, `.yaml`)

#### How It Renders Under the Hood
* **Stage A Extraction:** Fenced YAML blocks (tagged ```` ```yaml ```` or ```` ```{.yaml} ````) are intercepted and extracted in Stage A **before** Pandoc parses the document body. The metadata is stored in Pandoc's `doc.meta` table, and the YAML fence is completely stripped from the visible body.
* **Elimination of Traditional `--- ... ---`:** Standard Markdown frontmatter (`---`) is deliberately disabled. This ensures that hyphens, horizontal divider rules, and negative numbers can never be misparsed as broken YAML headers.
* **Supported Layout Presets:**
  * `page-layout: presentation`: Switches page geometry from standard portrait A4 to 16:9 widescreen landscape (13.33 in $\times$ 7.5 in, 0.5 in margins) with scaled headings.
  * `title-rule: false`: Disables the horizontal decorative rule rendered beneath the document title block.
  * `header-left: "..."`: Sets the running header on the top left of every page (defaults to "Notes").
* **Verbatim Listing Mode (`run=false`):** When you need to display YAML code in your document without applying it to the document's settings, add `run=false`. The pre-processor ignores it as metadata and leaves it as a syntax-highlighted code block.

#### Examples

**Document Metadata Configuration (Default):**
````markdown
```yaml
title: "Quantum Field Theory: Problem Set 4"
author: "Biswanath Sen"
date: "2026-11-08"
header-left: "Physics 401: QFT"
page-layout: default
title-rule: true
```
````

**Verbatim Code Listing (`run=false`):**
````markdown
```yaml run=false
# This block is NOT applied as document metadata.
# It renders as a syntax-highlighted code block in the PDF!
database:
  host: "127.0.0.1"
  port: 5432
  pool_size: 20
```
````

---

### 3.3. LaTeX / TeX (`latex`, `tex`)

#### How It Renders Under the Hood
* **Direct Raw LaTeX Output:** Code fences tagged `latex` or `tex` are emitted directly into the generated `.tex` file as raw LaTeX.
* **Universal Code Fence Isolation:** Every LaTeX fence is strictly wrapped inside a local group:
  ```latex
  {\begingroup
  <user-code>
  \par\endgroup}
  ```
  This ensures that any macro definitions, low-level TeX primitives (`\def`, `\gdef`, `\edef`, `\let`), font family declarations (`\newfontfamily`, `\newfontface`), color overrides (`\color{...}`), font size changes (`\Huge`), or dimension adjustments (`\setlength`) made inside a block **cannot leak** into subsequent sections or corrupt the outer document geometry.
* **Pasted Document Extraction & Preamble Hoisting:** If a full pasted LaTeX document containing `\begin{document} ... \end{document}` is passed, the runner automatically hoists `\usepackage` declarations, TikZ/PGF libraries, and preamble-only commands (`\DeclareMathOperator`, `\DeclarePairedDelimiter`, `\DeclarePairedDelimiterX`, `\DeclarePairedDelimiterXPP`, `\newtheorem`, `\theoremstyle`, `\hypersetup`, `\mathtoolsset`, `\newunicodechar`) into the global document preamble (`$header-includes$`). Hoisted `\DeclareMathOperator` and `\DeclarePairedDelimiter` (including `X` and `XPP`) declarations accept both braced (`\DeclareMathOperator{\cmd}{...}`) and unbraced (`\DeclareMathOperator\cmd{...}`) syntax with optional argument counts (`[num]`), and are safely guarded with `\let\cmd\relax` to prevent crashes against pre-existing kernel or template operators/delimiters (`\Tr`, `\Pr`, `\Re`, `\abs`, `\norm`, `physics.sty` macros, etc.). `\newtheorem` declarations preserve optional subordinate reset counters (`\newtheorem{env}{Title}[section]`) as well as shared counters (`\newtheorem{env}[shared]{Title}`) and preceding `\theoremstyle` definitions. User-defined macros, low-level TeX primitives (`\def`, `\gdef`, `\edef`, `\let`), custom environments, and fontspec font family/face commands (`\newfontfamily`, `\renewfontfamily`, `\setfontfamily`, `\providefontfamily`, `\newfontface`, `\renewfontface`, `\setfontface`, `\providefontface`) remain strictly local to the fence's `{\begingroup ... \par\endgroup}` body.
* **Cross-Fence Global Command Conflict Protection:** Defining or redefining any global command (`\DeclareMathOperator`, `\DeclarePairedDelimiter`, `\newunicodechar`, `\newtheorem`) or importing a package with conflicting options across multiple fences automatically demotes the offending block to `run=false` (syntax-highlighted code listing) with a console warning.
* **Scaffolding Macro Protection:** If user LaTeX code attempts to redefine critical document scaffolding macros (`\maketitle`, `\tableofcontents`, `\title`, `\author`, `\date`), the runner automatically demotes the block to `run=false` (syntax-highlighted code listing) to prevent fatal document compilation crashes.
* **Incomplete Preamble Protection:** If a LaTeX code fence contains preamble-only commands (`\usepackage` or `\documentclass`) but lacks `\begin{document}`, the runner automatically demotes the block to `run=false` (syntax-highlighted code listing) with a console warning, preventing fatal XeLaTeX document body crashes.

#### Examples

**Rendered TikZ Vector Graphic (Default):**
````markdown
```latex
\begin{tikzpicture}[scale=1.2]
  \draw[thick, ->] (-2,0) -- (2,0) node[right] {$x$};
  \draw[thick, ->] (0,-1) -- (0,2) node[above] {$y$};
  \draw[domain=-1.5:1.5, smooth, variable=\x, blue, thick] plot ({\x}, {\x*\x});
  \node[blue, right] at (1.2, 1.44) {$y = x^2$};
\end{tikzpicture}
```
````

**Preamble Hoisting with Local Scoping & Font Family Extraction:**
````markdown
```latex
\documentclass{article}
\usepackage{amsmath}
\DeclareMathOperator{\sinc}{sinc}
\newfontfamily\NotoSansLight{Noto Sans}[Scale=0.95]
\newcommand{\localbox}[1]{\fbox{\textbf{#1}}}
\begin{document}
Here is a hoisted operator: $\sinc(x) = \frac{\sin x}{x}$,
and a scoped font/macro: {\NotoSansLight \localbox{Local Content}}.
\end{document}
```
````

**Cross-Fence Collision Protection (Automatic Demotion):**
````markdown
```latex
% If an earlier fence already defined \sinc or \Tr, defining it again
% here triggers cross-fence protection and demotes this block to a code listing:
\documentclass{article}
\DeclareMathOperator{\sinc}{sinc}
\begin{document}
Conflict detected: demoted to code listing (run=false).
\end{document}
```
````

**Syntax-Highlighted Listing Only (`run=false`):**
````markdown
```latex run=false
% Prints verbatim in the PDF without compiling
\documentclass{article}
\usepackage{geometry}
\begin{document}
Hello World!
\end{document}
```
````

**Show Source Code AND Render Output (`show=true`):**
````markdown
```latex show=true
\colorbox{yellow!30}{\textbf{Important Note:}} This text is displayed in a colored box.
```
````

---

### 3.4. Python (`python`, `py`, `python3`, `py3`)

#### How It Renders Under the Hood
* **Execution & Launcher:** Python blocks are executed via the Windows Python launcher (`py`). The active working directory is scoped to the directory of the first input file.
* **Wrapper Injection:** The code is executed through a synthesized wrapper script that imports `sys`, `os`, and `io`, monkey-patches `matplotlib.pyplot.show()` to silently export figures to PNG/PDF files on disk, and captures `stdout`/`stderr`.
* **LIFO `atexit` Sequencing:** Python's exit hooks flush stdout before writing dependency records, preventing output buffer truncation.
* **Audit-Hook Dependency Tracking:** Uses Python's native `sys.addaudithook` to passively observe every `open()` call made by user code. Any read files have their SHA-1 digests automatically recorded and added to the block's cache key.
* **Persistent SHA-1 Cache (`rf4` Schema):** A unique key is computed from:
  $$\text{Key} = \text{SHA-1}(\text{Code} + \text{Spec ID} + \text{Python Version} + \text{Installed Packages} + \text{Input Dir} + \text{Dependencies})$$
  Cached outputs (`.out`, `.err`, `.meta`, figures) are reused instantly on subsequent builds.
* **Security & Approval Prompts:** Uncached Python runs display the full code on the Windows console and pause for approval (`[Y/n]`). Passing `trusted=true` skips the prompt for normal runs.
* **Error Resilience:** Python exceptions do not crash the PDF build. The traceback tail (up to 15 lines) is captured and rendered inside a clear red error frame in the PDF.

#### Examples

**Data Calculation with Output Limits:**
````markdown
```python trusted=true maxlines=5
# Output is capped at 5 lines; surplus lines are truncated cleanly
for i in range(1, 20):
    print(f"Sample {i}: reading = {i * 1.414:.4f}")
```
````

**Embedded Matplotlib Visualization:**
````markdown
```python trusted=true show=false
import numpy as np
import matplotlib.pyplot as plt

x = np.linspace(0, 10, 200)
y = np.sin(x) * np.exp(-x / 4)

plt.figure(figsize=(6, 3))
plt.plot(x, y, color='darkblue', lw=2)
plt.title("Damped Harmonic Oscillator")
plt.xlabel("Time (s)")
plt.ylabel("Displacement (m)")
plt.grid(True, alpha=0.3)
plt.tight_layout()
plt.show()
```
````

**Declared File Dependencies & Forced Refresh:**
````markdown
```python run=new trusted=true deps="dataset.csv"
# Forces a fresh execution and invalidates cache if dataset.csv changes
with open("dataset.csv", "r") as f:
    header = f.readline().strip()
print(f"Columns: {header}")
```
````

---

### 3.5. C (`c`)

#### How It Renders Under the Hood
* **Compiler Invocation:** Compiled with `gcc -O2 -o <prefix>_bin.exe <script>.c -lm`.
* **Automatic `main()` Synthesis:** The runner scans the source for `int main` or `main(`. If no `main` function is found:
  * Automatically injects standard headers: `<stdio.h>`, `<stdlib.h>`, `<math.h>`, `<string.h>`, `<stdbool.h>`.
  * Wraps user statements inside `int main(void) { ... return 0; }`.
* **`#line 1 "code"` Error Preservation:** When synthesizing `main()`, the runner injects the preprocessor directive `#line 1 "code"`. If the snippet contains a compilation error, GCC reports the exact line number of your Markdown fence, rather than referencing injected boilerplate lines.
* **Execution & Lifecycle:** The binary executes with OS-level stdin/stdout redirection. Immediately following execution, the compiled binary executable is deleted from disk to prevent filesystem clutter.

#### Examples

**Bare C Snippet (Auto-Wrapped):**
````markdown
```c trusted=true
// No #include or main() required; auto-wrapped by the compiler
double r = 4.5;
double area = M_PI * r * r;
printf("Circle area (radius=%.1f): %.4f\n", r, area);
```
````

**Full C Program:**
````markdown
```c trusted=true
#include <stdio.h>

int factorial(int n) {
    return (n <= 1) ? 1 : n * factorial(n - 1);
}

int main(void) {
    for (int i = 1; i <= 6; i++) {
        printf("%d! = %d\n", i, factorial(i));
    }
    return 0;
}
```
````

---

### 3.6. C++ (`cpp`, `c++`, `cxx`, `cc`)

#### How It Renders Under the Hood
* **Compiler Invocation:** Compiled with `g++ -O2 -std=c++17 -o <prefix>_bin.exe <script>.cpp`.
* **Automatic `main()` Synthesis:** If no `main()` function is detected:
  * Injects standard C++ headers: `<iostream>`, `<vector>`, `<string>`, `<cmath>`, `<algorithm>`, `<memory>`, `<map>`, `<utility>`.
  * Wraps the snippet inside `int main(int argc, char** argv) { ... return 0; }`.
* **Line Number Mapping:** Preprocessor `#line 1 "code"` ensures G++ error diagnostics match snippet line numbers.
* **Temporary Binaries:** Native executables are purged immediately after execution completes.

#### Examples

**Bare C++ Snippet using Modern C++17:**
````markdown
```cpp trusted=true
// Vectors, algorithms, and iostream are available immediately
std::vector<int> data = {7, 2, 9, 1, 5};
std::sort(data.begin(), data.end());

std::cout << "Sorted: ";
for (int n : data) std::cout << n << " ";
std::cout << "\n";
```
````

**Full C++ Class Structure:**
````markdown
```cpp trusted=true
#include <iostream>
#include <string>

class Particle {
public:
    std::string name;
    double energy;
    void print() const {
        std::cout << "Particle: " << name << " | Energy: " << energy << " GeV\n";
    }
};

int main() {
    Particle p{"Higgs Boson", 125.25};
    p.print();
    return 0;
}
```
````

---

### 3.7. Java (`java`)

#### How It Renders Under the Hood
* **Two-Tier Execution Architecture:**
  1. **Full JDK Mode (`javac` available):** Compiles the source into a dedicated cache directory using `javac -d <dir> <Script>.java`, then runs the resulting class with `java -cp <dir> <Class>`.
  2. **Single-File Fallback (JRE-only):** If `javac` is not installed or `JAVAC_COMPILER` is not found, it gracefully falls back to single-file source-code execution (`java <Script>.java`).
* **Environment Variable Safety:** Probes `JAVAC_COMPILER` with non-empty string validation to avoid shell execution traps when empty environment variables are declared.
* **Automatic `Main` Class Synthesis:** If the code does not define a `public class` or `main()` method:
  * Automatically imports `java.util.*`, `java.io.*`, `java.math.*`, `java.time.*`, `java.util.stream.*`.
  * Synthesizes `public class Main { public static void main(String[] args) throws Exception { ... } }`.
* **Class Name Auto-Detection:** If a full class with `public class Foo` is supplied, the runner automatically saves the file as `Foo.java` matching Java's strict source-naming requirements.

#### Examples

**Bare Java Snippet (Auto-Wrapped in `Main`):**
````markdown
```java trusted=true
// Imports (java.util.*, streams, etc.) and class Main are synthesized automatically
List<String> items = Arrays.asList("Proton", "Neutron", "Electron");
items.stream()
     .map(String::toUpperCase)
     .forEach(System.out::println);
```
````

**Full Java Class:**
````markdown
```java trusted=true
public class MatrixMultiplier {
    public static void main(String[] args) {
        int[][] a = {{1, 2}, {3, 4}};
        int[][] b = {{2, 0}, {1, 2}};
        int c00 = a[0][0]*b[0][0] + a[0][1]*b[1][0];
        System.out.println("C[0,0] = " + c00);
    }
}
```
````

---

### 3.8. Raw / Gibberish Text (`text`, `txt`, Verbatim Mode)

#### How It Renders Under the Hood
* **100% Crash-Proof Verbatim Engine:** Rendered through LaTeX's **`fvextra`** package (`Highlighting` verbatim block).
* **Complete Character Inertness:** Inside a text block, **every single character** is treated as pure ASCII glyph data. Special LaTeX control characters (`\`, `%`, `$`, `{`, `}`, `_`, `^`, `&`, `#`, `~`) cannot trigger commands, start math mode, or alter formatting.
* **Automatic Line Wrapping:** Long continuous strings, memory dumps, or log records automatically break at the right margin without overflowing the page boundary.
* **The 4-Backtick Rule (Nesting Code Fences):** In Markdown, an opening fence of 3 backticks (` ``` `) is closed by the first subsequent 3 backticks it encounters. If your text content contains code fences (such as a markdown tutorial or a snippet of YAML):
  * **Wrap the outer block with 4 backticks (` ```` ````).**
  * Add `run=false` to any nested `yaml` blocks so the Stage A pre-processor does not swallow them as document metadata.

#### Examples

**Arbitrary Special Characters & Broken Macros (Never Crashes):**
````markdown
```text
Raw dump of chaotic characters:
% $ & _ { } \ ^ ~ # < > | [ ] @ ! *
\begin{broken_env} \undefined_command{{{
Unbalanced braces and syntax errors here are 100% immune to LaTeX crashes!
```
````

**Nesting Code Blocks with the 4-Backtick Rule:**
`````markdown
````text
Here is an example of a YAML code fence printed literally:

```yaml run=false
title: "My Sub-Document"
author: "Alice"
```

The outer 4 backticks prevent the inner 3 backticks from closing the box!
````
`````

---

## 4. Universal Attribute Reference Table

Use this reference table to see which attributes apply to which languages in the latest version:

| Attribute | Accepted Values | Target Languages | Exact Operational Behavior |
|---|---|---|---|
| **`run`** | `true`, `false`, `new` | All languages | `false` forces listing only; `new` forces cache-bypass and prompts for confirmation. |
| **`trusted`** | `true`, `false` | Python, C, C++, Java | `true` skips confirmation prompt for ordinary uncached executions. |
| **`show`** | `true`, `false` | All executable languages | `false` hides the source code listing; `true` (in LaTeX) shows source *and* renders output. |
| **`output`** | `true`, `false` | Python, C, C++, Java | `false` suppresses stdout text output from the compiled PDF. |
| **`error`** | `true`, `false` | Python, C, C++, Java | `false` suppresses the rendered red error box in the PDF (errors still log to console). |
| **`maxlines`** | Positive integer ($N$) | Python, C, C++, Java | Truncates stdout to $N$ lines with an informative `... [truncated]` marker. |
| **`figures`** | `true`, `false` | Python | `false` suppresses auto-embedding Matplotlib figures in the PDF. |
| **`deps`** | Quoted string | Python | Comma-separated files whose SHA-1 hashes participate in cache invalidation. |
| **`cache`** | `true`, `false` | Python, C, C++, Java | Alias for `run=new`: `cache=false` bypasses cache and prompts for fresh execution. |
