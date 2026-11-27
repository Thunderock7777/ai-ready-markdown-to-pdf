# Whiteboard HTML Preview for VS Code

Side-by-side live preview inside VS Code strictly for documents declaring `page-layout: whiteboard_html` in a fenced ```` ```yaml ```` block (`.md`, `.markdown`, `.txt`).

## Features

- **Side-by-Side Webview Preview**: Click the preview icon in the editor title bar or run **Whiteboard HTML: Open Preview to the Side** (`whiteboardHtml.openPreviewToSide`).
- **Auto-Refresh on Save**: Updates the preview automatically whenever you press `Ctrl+S`.
- **Scope Guard**: Only compiles `page-layout: whiteboard_html` documents; other layouts show a clear warning instead of running PDF builds.
- **Local Webview Assets**: Serves `config/latex.css`, `config/wb-viewer.js`, and `config/markmap/vendor/` (`d3.min.js`, `markmap-view.min.js`, `katex.min.css` + fonts) directly from disk via `webview.asWebviewUri`.
- **VS Code Save Bridge**: **Save HTML** / **Save As** buttons in the preview open VS Code's native Save dialog.

## Requirements

- `pandoc` on `PATH` (or configured via `whiteboardHtml.pandocPath`)
- Optional for full math/diagram/Tree View fidelity: `texlua` and `node` with `config/markmap/node_modules` installed
- An `ai-ready-markdown-to-pdf` `config/` folder in your workspace, a parent folder, or configured via `whiteboardHtml.configPath`

## Running / Installing Locally

### Option 1: Portable One-Click Installer (Recommended after cloning)

Double-click `install-vscode-extension.bat` (or run it from Command Prompt):

```powershell
d:\latex_editor\vscode-extension\install-vscode-extension.bat
```

It installs the extension directly into `%USERPROFILE%\.vscode\extensions\thunderock7777.whiteboard-html-preview-1.0.0\` without needing `vsce`, `npm`, or internet.

### Option 2: Extension Development Host (`F5`)

1. Open `d:\latex_editor\vscode-extension` in VS Code.
2. Press `F5` to launch an Extension Development Host window.
3. Open a `page-layout: whiteboard_html` `.md` or `.txt` file and click the **Open Preview to the Side** button in the editor title bar.

### Option 3: Build and Install `.vsix`

```powershell
cd d:\latex_editor\vscode-extension
npx @vscode/vsce package
code --install-extension whiteboard-html-preview-1.0.0.vsix
```
