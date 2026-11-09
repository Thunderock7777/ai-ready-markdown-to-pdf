```yaml
title: "Universal Code Fence & Rendering Verification Suite"
author: "Antigravity Test Harness"
date: "2026-11-08"
header-left: "Pipeline Verification"
page-layout: default
title-rule: true
```

# Universal Code Fence & Rendering Verification Suite

This document is the comprehensive verification suite exercising every supported language, attribute, execution model, run value, and failure-handling resilience path documented in `rendering-rules.md`.

---

## 1. Document Configuration (YAML)

### 1.1. Metadata Extraction Mode (Default)
The fenced YAML block at the top of this document configured document metadata:
* `title`: Sets the document title block.
* `author`: Sets the author name.
* `date`: Sets the date stamp.
* `header-left`: Overrides the default "Notes" running header to "Pipeline Verification".
* `title-rule: true`: Keeps the horizontal rule under the title block.

### 1.2. Verbatim Code Listing Mode (`run=false`)
The following block has `run=false`. It must **not** be extracted as document metadata; it must render as a syntax-highlighted YAML code listing:

```yaml run=false
# Verbatim code listing: not applied to document settings
service:
  name: "auth-gateway"
  port: 8443
  ssl:
    enabled: true
    cert: "/etc/ssl/certs/gateway.crt"
```

---

## 2. Markdown & Typographic Normalization

### 2.1. Unicode Math Symbol Mapping
Unicode Greek letters and mathematical symbols in prose are automatically mapped to their LaTeX equivalents:
* Greek: α, β, γ, δ, θ, λ, π, σ, ω $\rightarrow$ automatically converted.
* Relations & Operators: ≤, ≥, ≠, ≈, ±, ×, ÷ $\rightarrow$ automatically converted.
* Calculus & Sets: The integral ∫ from $0$ to $\infty$ of $e^{-x}\,dx = 1$, and $x \in A \cap B \implies x \in A$.
* Stacked Superscripts: $x¹²$ automatically gathers into $x^{12}$.

### 2.2. Pipe Tables & Math Cells

| Component | Variable | Nominal Value | Equation |
|---|:---:|:---:|---|
| Resistor | $R$ | $100\,\Omega$ | $V = I R$ |
| Capacitor | $C$ | $10\,\mu\text{F}$ | $Q = C V$ |
| Inductor | $L$ | $2.5\,\text{mH}$ | $V = L \frac{dI}{dt}$ |

### 2.3. Task Lists & Visual Dividers
- [x] Pre-cleaning and Unicode mapping active
- [x] Block boundary spacing preserved
- [ ] Manual verification checklist item

---

### 2.4. Stray TeX Protection (`-raw_tex`)
Because `-raw_tex` is disabled, typing a command like `\lhead{ShouldNotRun}` or `\custommacro` in ordinary Markdown prose does not execute or crash XeLaTeX; it renders as safe literal text.

---

## 3. LaTeX / TeX Fences

### 3.1. Default Rendered LaTeX (`run=true` or Omitted)
Rendered directly as vector graphics inside the PDF:

```latex
\begin{tikzpicture}[scale=1.0]
  \draw[thick, fill=blue!15] (0,0) rectangle (3,1.5);
  \node at (1.5,0.75) {\textbf{Isolated TikZ Block}};
\end{tikzpicture}
```

### 3.2. Universal TeX Group Isolation
The block below defines a local color and font size. Because every LaTeX fence is wrapped in `{\begingroup ... \par\endgroup}`, these local changes cannot leak into the surrounding document.

```latex
\color{red}\Large
This text is red and large inside the isolated block.
```

The text right here is normal black text, proving that group isolation prevented the red color from leaking!

### 3.3. Show Source Code AND Render Output (`show=true`)

```latex show=true
\colorbox{green!20}{\textbf{Visible Source + Rendered Result:}} Both appear!
```

### 3.4. Code Listing Only (`run=false`)

```latex run=false
% This LaTeX code listing is not rendered or executed
\documentclass{article}
\usepackage{amsmath}
\begin{document}
\[ E = mc^2 \]
\end{document}
```

### 3.5. Scaffolding Macro Protection (Failure Resilience)
The block below attempts to redefine `\maketitle`. The pipeline automatically detects this destructive redefinition and safely demotes the block to a syntax-highlighted code listing (`run=false`) rather than breaking the XeLaTeX document build:

```latex
\renewcommand{\maketitle}{%
  \begin{center}\Huge Accidental Destruction\end{center}%
}
```

### 3.6. Preamble Hoisting, Delimiter Safety & Low-Level TeX Primitives
Preamble-only declarations like `\DeclareMathOperator` and `\DeclarePairedDelimiter` are hoisted to the document preamble, guarded by `\let\cmd\relax` against template and kernel collisions. Low-level TeX primitives (`\def`, `\let`), font family declarations (`\newfontfamily`, `\newfontface`), and macros remain strictly local to this fence:

```latex
\documentclass{article}
\usepackage{amsmath}
\usepackage{mathtools}
\DeclareMathOperator{\CompiledTrace}{Tr}
\DeclarePairedDelimiter{\CompiledNorm}{\lVert}{\rVert}
\newfontfamily\CompiledSansFont{Noto Sans}[Scale=0.9]
\def\CompiledReal{\mathbb{R}}
\let\CompiledOldTheta\theta
\newcommand{\CompiledScopedTag}{\textbf{[Isolated Macro]}}
\begin{document}
Hoisted operator and delimiter: \(\CompiledTrace(M) = \CompiledNorm{v}\).
Scoped font, def primitive, and local tag: {\CompiledSansFont \CompiledScopedTag\ \(\CompiledReal\) and \(\CompiledOldTheta\).}
\end{document}
```

### 3.7. Cross-Fence Global Command Conflict Protection (Automatic Demotion)
The block below attempts to redeclare `\CompiledTrace` which was already declared globally in Section 3.6. The pipeline catches the duplicate global declaration across fences, demotes this block to a code listing (`run=false`), and issues a console warning without failing the document build:

```latex
\documentclass{article}
\DeclareMathOperator{\CompiledTrace}{Tr}
\begin{document}
This body will not render because duplicate global command triggers demotion to run=false.
\end{document}
```

---

## 4. Python Fences

### 4.1. Standard Python Execution (`trusted=true`)
Executes code and captures printed stdout text:

```python trusted=true
data = [12.4, 15.8, 18.2, 14.1, 16.9]
mean = sum(data) / len(data)
print(f"Dataset: {data}")
print(f"Calculated Mean: {mean:.2f}")
```

### 4.2. Embedded Matplotlib Visualization (`trusted=true show=false`)
Generates and automatically embeds a figure in the PDF without displaying the underlying Python script:

```python trusted=true show=false
import numpy as np
import matplotlib.pyplot as plt

t = np.linspace(0, 2 * np.pi, 150)
s = np.sin(2 * t)

plt.figure(figsize=(5.5, 2.2))
plt.plot(t, s, color='crimson', lw=2)
plt.title("Waveform Output")
plt.xlabel("Time (s)")
plt.ylabel("Amplitude")
plt.grid(True, alpha=0.3)
plt.tight_layout()
plt.show()
```

### 4.3. Output Line Limits (`maxlines=3`)
Limits displayed stdout output to 3 lines, truncating with an ellipsis:

```python trusted=true maxlines=3
for i in range(1, 10):
    print(f"Iteration step {i}")
```

### 4.4. Hidden Output (`output=false`)
Executes the code, but suppresses the printed text from the PDF:

```python trusted=true output=false
# This computation executes silently
x = 100 * 200
print(f"Hidden result: {x}")
```

### 4.5. Forced Fresh Execution (`run=new trusted=true`)
Bypasses the persistent cache and executes freshly on every build:

```python run=new trusted=true
import datetime
print(f"Fresh execution timestamp: {datetime.datetime.now().strftime('%H:%M:%S')}")
```

### 4.6. Python Code Listing Only (`run=false`)

```python run=false
def quicksort(arr):
    if len(arr) <= 1:
        return arr
    pivot = arr[len(arr) // 2]
    left = [x for x in arr if x < pivot]
    middle = [x for x in arr if x == pivot]
    right = [x for x in arr if x > pivot]
    return quicksort(left) + middle + quicksort(right)
```

### 4.7. Python Error Resilience (Intentional Runtime Failure)
The block below raises a deliberate runtime exception (`ZeroDivisionError`). The pipeline catches the traceback and renders a clear red error diagnostic box in the PDF without failing the document build:

```python trusted=true
# Intentional exception to verify diagnostic error box rendering
numerator = 100
denominator = 0
result = numerator / denominator
```

---

## 5. C Code Fences

### 5.1. Bare C Snippet (Auto-Wrapped in `main()`)
Bare statements without `#include` or `main()` are synthesized automatically with standard headers and `int main(void)`:

```c trusted=true
double radius = 3.5;
double circumference = 2.0 * M_PI * radius;
printf("Circle radius: %.1f | Circumference: %.3f\n", radius, circumference);
```

### 5.2. Full C Program
A complete standalone program with its own headers and `int main(void)`:

```c trusted=true
#include <stdio.h>

int is_prime(int n) {
    if (n <= 1) return 0;
    for (int i = 2; i * i <= n; i++) {
        if (n % i == 0) return 0;
    }
    return 1;
}

int main(void) {
    printf("Primes under 15: ");
    for (int i = 2; i < 15; i++) {
        if (is_prime(i)) printf("%d ", i);
    }
    printf("\n");
    return 0;
}
```

### 5.3. C Output Truncation (`maxlines=2`)

```c trusted=true maxlines=2
for (int i = 1; i <= 6; i++) {
    printf("Line %d of C output\n", i);
}
```

### 5.4. C Code Listing Only (`run=false`)

```c run=false
#include <stdio.h>

int main(void) {
    printf("This C listing is never compiled or executed.\n");
    return 0;
}
```

### 5.5. C Compiler Error Resilience (Intentional Compilation Failure)
The block below contains an intentional syntax error. The pipeline catches GCC's compilation error and renders a red diagnostic box:

```c trusted=true
// Intentional syntax error to verify compiler diagnostic frame
int valid_var = 10;
this_variable_is_never_declared = 42;
```

---

## 6. C++ Code Fences

### 6.1. Modern C++17 Bare Snippet (Auto-Wrapped)
Bare statements are synthesized with modern C++ headers (`<iostream>`, `<vector>`, `<string>`, `<algorithm>`):

```cpp trusted=true
std::vector<std::string> names = {"Alpha", "Beta", "Gamma"};
std::cout << "Elements: ";
for (const auto& name : names) {
    std::cout << name << " ";
}
std::cout << std::endl;
```

### 6.2. Full C++ Class & Program

```cpp trusted=true
#include <iostream>

class Box {
private:
    double length, width, height;
public:
    Box(double l, double w, double h) : length(l), width(w), height(h) {}
    double volume() const { return length * width * height; }
};

int main() {
    Box b(2.0, 3.5, 4.0);
    std::cout << "Calculated Box Volume: " << b.volume() << std::endl;
    return 0;
}
```

### 6.3. C++ Code Listing Only (`run=false`)

```cpp run=false
#include <iostream>
int main() {
    std::cout << "Unexecuted C++ listing.\n";
    return 0;
}
```

### 6.4. C++ Compiler Error Resilience (Intentional Compilation Failure)
The block below contains an intentional C++ type mismatch error. G++'s error output is caught and formatted in a red diagnostic box:

```cpp trusted=true
// Intentional syntax error to verify G++ diagnostic frame
std::vector<int> v;
v.push_back("incompatible string literal");
```

---

## 7. Java Code Fences

### 7.1. Bare Java Snippet (Auto-Wrapped in `class Main`)
Statements are synthesized inside `public class Main` with standard `java.util.*` and stream imports:

```java trusted=true
List<String> planets = Arrays.asList("Mercury", "Venus", "Earth", "Mars");
System.out.println("Planets count: " + planets.size());
planets.forEach(p -> System.out.println(" - " + p));
```

### 7.2. Full Java Class Execution

```java trusted=true
public class Calculator {
    public static void main(String[] args) {
        int a = 25, b = 17;
        System.out.println("Addition: " + (a + b));
        System.out.println("Multiplication: " + (a * b));
    }
}
```

### 7.3. Java Code Listing Only (`run=false`)

```java run=false
public class TestListing {
    public static void main(String[] args) {
        System.out.println("This Java code listing is never executed.");
    }
}
```

### 7.4. Java Error Resilience (Intentional Compilation Failure)
The block below contains an intentional type error. The pipeline captures the compiler diagnostic and renders an error box:

```java trusted=true
// Intentional type error to verify Java error rendering
int number = "This string cannot be assigned to an integer";
System.out.println(number);
```

---

## 8. Raw / Gibberish Text & Crash-Proof Verbatim Mode

### 8.1. 100% Crash-Proof Arbitrary Text (`text`)
Rendered through LaTeX's `fvextra` engine. All characters are completely inert, long lines wrap automatically, and special characters cannot cause LaTeX errors:

```text
Raw dump of chaotic characters and broken macros:
% $ & _ { } \ ^ ~ # < > | [ ] @ ! *
\begin{broken_environment} \not_a_real_macro{{{
Even completely corrupted text or unbalanced braces are 100% immune to LaTeX crashes!
```

### 8.2. The 4-Backtick Nesting Rule
Using 4 backticks on the outer fence allows displaying inner 3-backtick code blocks literally in the PDF:

````text
Here is a literal YAML code fence printed inside a text box:

```yaml run=false
title: "Tutorial Document"
author: "Demo"
```

The outer 4 backticks prevent the inner 3 backticks from prematurely closing the block.
````
