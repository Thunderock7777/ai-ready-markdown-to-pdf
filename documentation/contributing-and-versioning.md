PROJECT WORKING RULES
====================

Purpose
-------
These rules apply to anyone changing this repository. Read this file before
making a change. The goal is to preserve the workflow's behavior, keep its
documentation trustworthy, and make version changes auditable without wasting
time rebuilding the full regression document for every small edit.

1. Before changing anything
---------------------------
1. Inspect the repository layout and current version-control status. Identify
   generated files, caches, user inputs, and any uncommitted changes. Preserve
   work that is not part of the requested task.
2. Read README.md and every text guide in documentation\ in full before making
   implementation or architecture changes. For a small, isolated change, at
   minimum read the relevant guide sections and check the other guides for
   conflicting statements.
3. Trace the behavior through the actual implementation before editing. The
   principal components are compile.bat, config\markdown-normalizer.lua,
   config\code-fence-runner.lua, and config\custom.tex. Keep their contracts
   and filter order in mind.
4. State the requested behavior and its acceptance check before editing. Keep
   the change focused; do not fold unrelated cleanup into it.
5. If the request, intended behavior, or scope is unclear, do not make a
   change based on assumptions. Ask the user a specific clarifying question
   and wait for the answer before editing.
6. Prefer a logically general solution that addresses the underlying behavior
   over a one-off fix for a single example. Keep the implementation focused on
   the demonstrated requirement; generality must not introduce unrelated
   behavior, speculative edge-case handling, or unnecessary abstraction.
7. Zero hardcoded machine/host paths: Toolchains, compilers, interpreters, and
   runtime paths must never use machine-specific absolute directories or user
   paths. Resolve executables generally via standard system PATH or relative
   project paths so the workflow remains fully portable across machines.
8. Standard code fence rule of thumb for non-Markdown languages:
   Except Markdown itself, any other language (such as LaTeX, Python, YAML, C,
   C++, Java, or any language added in the future) MUST use fenced code block
   syntax (```<lang> ... ``` or ```{.<lang>} ... ```) for execution, configuration,
   metadata, or rendering. Non-fenced delimiters (such as raw YAML `--- ... ---`,
   unescaped top-level language directives, or custom boundary tokens) are
   strictly prohibited to prevent collisions with Markdown syntax and ensure
   consistent, uniform workflow parsing and maintenance.

2. Implementation comments and source changes
----------------------------------------------
- Before implementing a new feature or changing architecture, add or revise a
  concise source comment at the relevant implementation point that records the
  intended behavior, important invariant, or ordering constraint. Then make
  the implementation match that documented intent in the same change.
- For bug fixes, update or add a source comment when the reason or invariant is
  non-obvious. Do not add comments that merely repeat the next line of code.
- If a change touches Lua, batch, or TeX files, review comments in every
  touched implementation file for accuracy. Do not leave stale comments or
  duplicate the documentation verbatim in source.
- Preserve the critical order in compile.bat:
  markdown-normalizer.lua must run before code-fence-runner.lua.
- Do not silently discard content or turn errors into success-shaped output.
  Keep user-visible warnings and failures consistent with the surrounding
  code's conventions.

3. Documentation review after every project change
--------------------------------------------------
After a behavior, feature, bug-fix, or architecture change:
1. Explicit Documentation Audit Checklist:
   Every project change MUST review README.md and explicitly audit each markdown file
   in the documentation\ folder by name against the modified behavior:
   - README.md: Root entry point, quick start, feature summary, current version number, and code fence options.
   - documentation\rendering-rules.md: Master language rendering reference, TeX group isolation guarantees, and execution models across all supported languages.
   - documentation\installation-and-usage.md: Setup prerequisites, CLI commands, workflow rules of thumb, and beginner-to-advanced usage guidelines.
   - documentation\workflow-architecture.md: Pipeline stages, filter execution order, multi-pass compilation, error annotator recovery, and persistence architecture.
   - documentation\markdown-normalizer-architecture.md: Text cleaning passes, Unicode symbol normalization, citation resolution, and AST mutation contracts for markdown-normalizer.lua.
   - documentation\code-fence-runner-architecture.md: Code execution, language dispatch, policy tables, wrapper synthesis, and cache hash specifications for code-fence-runner.lua.
   - documentation\contributing-and-versioning.md: Working rules, documentation audit requirements, testing guidelines, and the cumulative line-count version ledger.
   - documentation\workflow-assessment.md: Technical assessment scorecard, operational security analysis, and architectural limitations.
   - documentation\filter-feature-regression.md: Primary end-to-end regression fixture exercising normalized formatting, preamble extraction, and standard behaviors.
   - documentation\filter-feature-regression-part-2.md: Companion regression fixture verifying multi-input concatenation order and single-output execution guarantees.
   - documentation\compiled-fence-test.md: Comprehensive executable fence test suite exercising all supported language runtimes, attributes, and failure modes.
2. Update README.md and each affected guide in the same change. Keep definitions,
   syntax, policy tables, error diagnostics, and feature descriptions synchronized.
3. Confirm that unaffected guides remain accurate. Do not edit unrelated files
   merely to make every document appear changed; record no change when the
   content is still correct.
4. Keep command examples, paths, folder layout, feature descriptions, known
   limitations, and expected results consistent across all documentation files.
   The README is the GitHub entry point and must never contradict any guide.

Documentation-only edits still require checking links and nearby references,
but do not require a PDF build unless a documentation test specifically needs
one.

4. Testing and the regression fixture
-------------------------------------
- Mandatory for every feature addition and bug fix: create or update a focused
  test input (.md or .txt) that exercises the changed behavior, then run that input
  through the real `compile.bat` workflow. Verify the relevant PDF content,
  console warning/error, or Python side effect—not merely that the process
  exited. Keep the case in the regression fixture when it is a lasting
  supported behavior; otherwise use a disposable test file and remove it
  after the test.
- If the behavior is specifically multi-input, use at least two inputs.
  If it involves Python, exercise it only with trusted test code and verify the
  expected output/cache/side effect. For an expected failure, confirm the
  expected diagnostic and whether the PDF is or is not produced/preserved.
- Additional focused checks such as Lua filter loading, static path/link
  checks, or cache-unit probes are useful, but do not replace the required
  workflow test for a feature or bug fix.
- Documentation-only, comment-only, and formatting-only changes do not require
  a compile test unless they alter a documented example or expected behavior;
  validate links, paths, and wording instead.
- Do NOT compile filter-feature-regression.md after every change. It is a
  comparatively large end-to-end demonstration; rebuilding it for an unrelated
  documentation edit or a small isolated change wastes time and compute.
- The mandatory test is a small, targeted test case, not a requirement to
  rebuild the full FILTER_FEATURE_REGRESSION fixture. A short disposable test
  input is sufficient when it verifies the exact change.
- The regression fixture is available to any user as an end-to-end workflow
  check. Its single-input and two-input commands, expected warnings, marker
  checks, and output location are documented in
  filter-feature-regression.md.
- Run the relevant fixture when changing the pipeline, either Lua filter,
  template behavior, Python execution/cache behavior, or when a complete
  integration check is needed. Run it before a release when practical, or when
  the user explicitly requests full validation. Do not claim it was run if it
  was not run.
- Do not mark a feature or bug fix complete until its focused test has
  run through `compile.bat` and its expected behavior has been checked. If
  required dependencies or tools are unavailable, report the test as blocked
  and state the blocker; do not silently substitute a weaker check.
- When a test is skipped, state why and report which focused checks were run.
  Expected Python failure messages inside the fixture are not themselves a
  failed PDF build; verify the expected PDF/output as documented.

5. Git and change hygiene
-------------------------
- Check `git status` before and after work. Never discard or overwrite unrelated
  user changes.
- Keep each commit focused and explain the user-visible reason. Review the
  staged diff, including documentation and generated files, before committing.
- Do not commit md2pdf_cache contents, temporary build files, or personal
  input/output files. This repository already tracks a regression PDF; update
  that existing artifact only when the requested deliverable or an agreed
  release process requires it. Do not regenerate or stage it for routine edits.
- Do not use destructive history rewriting or force-push shared branches.
- Keep user changes and generated artifacts separate from source changes. The
  repository's .gitignore is the authority for ignored runtime files; review it
  before adding new generated output.

6. Version policy and line-change tracking
-------------------------------------------
Starting version: 1.0.0
Line-change budget: 500 changed lines per version cycle; releases may occur earlier
Starting accumulated count: 0

The project adopts 1.0.0 as its working baseline when this policy is accepted.
Version tags and published releases are managed separately from this ledger.
If a formal baseline tag is used, name it v1.0.0; do not move an existing tag.

The 500-line budget is a tracking threshold, not a requirement to delay a
release. A user-facing feature or other meaningful change may be versioned
before the threshold. Apply the project's version increment rules to each
intentional release:
- Bug fixes and small, backward-compatible feature additions increment the
  patch number: for example, 1.2.0 -> 1.2.1 -> 1.2.2.
- A major feature addition increments the middle number and resets the patch
  number: for example, 1.2.2 -> 1.3.0 -> 1.4.0.
- An incompatible public behavior/API change increments the first number and
  resets the other numbers: for example, 1.4.0 -> 2.0.0.
- Documentation-only or maintenance-only releases use the patch increment
  unless they are included in another versioned change.

A version increment starts a new line-count cycle at zero regardless of the
previous cycle's count. This ledger records version changes; Git commits, tags,
and publication are managed separately.

Counting rule:
- Count changed lines only in project-maintained system files whose content
  directly affects workflow execution, processing, configuration, or output.
  Exclude documentation, regression fixtures, sample/user inputs, and other
  non-implementation content. A replacement counts as one deletion plus one
  addition. Renames with no content changes count as zero.
- Do not count .git internals, caches, temporary files, generated PDFs or other
  generated binaries, or personal documents that are not project-maintained.
- For each merged/accepted change, record its date or commit identifier, a
  short description, the added/deleted line counts for qualifying system
  files only, and the new cumulative total in the ledger below. Use Git diff
  statistics, classify changed paths by their role in the workflow, sum
  numeric additions and deletions for qualifying files, and skip binary rows.
  Do not stage personal files or generated artifacts just to count them, and
  do not estimate from file length.
- When a release is made, record its version and reason, then reset the new
  cycle's count to zero. The 500-line budget may prompt a release review but
  does not force a release or determine the version increment.
- Update this ledger and any version references in README.md in the same
  versioning change. Create the corresponding Git tag/release only after the
  versioned change is committed and validated.

Line-count ledger
-----------------
Baseline
  Version: 1.0.0
  Starting count: 0 / 500

Change ledger
  2026-11-04 | Python consent and workspace-scoped cache | source +41 / -16 | 57 / 500
  2026-11-05 | Mixed-input rollback and nested table math formatting | source +87 / -13 | 157 / 500
  2026-11-05 | Added manual normalizer fix fixture | source +0 / -0 | 157 / 500
  2026-11-05 | YAML presentation page-size preset | source +22 / -6 | 185 / 500
  2026-11-05 | Versioned presentation page-size feature as 1.1.0 (MINOR)

Version 1.1.0 cycle
  Starting count: 0 / 500

Change ledger
  2026-11-05 | YAML-controlled title-rule visibility | source +24 / -2 | 24 / 500
  2026-11-05 | Versioned title-rule option as 1.2.0 (MINOR)

Version 1.2.0 cycle
  Starting count: 0 / 500

Change ledger
  2026-11-07 | Fenced YAML metadata, unified fence rules, and console color themes | source +109 / -15 | 124 / 500
  2026-11-07 | Versioned fenced YAML, unified fences, and console theme as 1.2.1 (PATCH)

Version 1.2.1 cycle
  Starting count: 0 / 500

Change ledger
  2026-11-07 | Localized XeLaTeX error recovery, list math normalization, and Windows default Python launcher | source +269 / -7 | 276 / 500
  2026-11-07 | Versioned localized XeLaTeX error recovery as 1.2.2 (PATCH)

Version 1.2.2 cycle
  Starting count: 0 / 500

Change ledger
  2026-11-07 | Executable C, C++, and Java code fences with universal attributes and persistent caching | source +281 / -42 | 323 / 500
  2026-11-07 | Versioned C, C++, and Java code fences as 1.3.0 (MINOR)

Version 1.3.0 cycle
  Starting count: 0 / 500

Change ledger
  2026-11-07 | Migrated documentation files from .txt to .md and updated cross-references | source +0 / -0 | 0 / 500
  2026-11-07 | 579a93d | Universal block boundary spacing and disabled simple_tables | source +55 / -3 | 58 / 500
  2026-11-07 | Scaffolding macro redefinition demotion, universal code fence isolation, and disabled raw_tex | source +58 / -11 | 127 / 500
  2026-11-07 | XeLaTeX log unwrap threshold alignment, JAVAC_COMPILER empty guard, and documentation consistency | source +7 / -6 | 140 / 500
  2026-11-08 | 10c8b08 | Premature citeproc warning elimination (moved citation resolution entirely to normalizer) | source +0 / -1 | 141 / 500
  2026-11-08 | LaTeX code fence preamble-only command routing, local macro scoping, and regression fix | source +4 / -2 | 147 / 500
  2026-11-08 | Versioned citeproc fix, preamble-only command routing, and documentation consistency as 1.3.1 (PATCH)

Version 1.3.1 cycle
  Starting count: 0 / 500

Change ledger
  2026-11-09 | 8b9bca6 | LaTeX fence font family extraction, global conflict protection, and operator hoisting safety | source +144 / -8 | 152 / 500
  2026-11-09 | Versioned font family extraction, global conflict protection, and operator hoisting safety as 1.3.2 (PATCH)

Version 1.3.2 cycle
  Starting count: 0 / 500

Change ledger
  2026-11-09 | Synchronized rendering rules, test suites, regression fixtures, and explicit documentation audit checklist | source +0 / -0 | 0 / 500
  2026-11-09 | LaTeX fence paired delimiter hoisting safety and TeX primitive (\def, \let) extraction | source +62 / -7 | 69 / 500
  2026-11-09 | Versioned paired delimiter hoisting safety and TeX primitive extraction as 1.3.3 (PATCH)

Version 1.3.3 cycle
  Starting count: 0 / 500

Change ledger

For each later accepted change, append one entry in this format:

  YYYY-MM-DD | commit-or-change-id | short description | source +added / -deleted | cumulative / 500

After a version increment, add a new cycle header with the new version and
reset count. Retain prior entries so the progression remains reviewable.
Documentation-only or regression-fixture-only changes add a ledger entry with
`source +0 / -0` if they are otherwise being recorded; they do not consume the
500-line budget.

7. Release readiness
-------------------
Before publishing a version:
- Confirm the README and every documentation file are accurate and internally consistent.
- Review the source diff and ensure the version ledger is current.
- Run focused checks for the changed behavior and the single-/multi-input
  regression when changes affect end-to-end compilation.
- Confirm generated PDFs/logs/caches and personal files are not included
  accidentally.
- Verify the version/tag and release notes describe what was actually tested.

These are project maintenance rules, not a promise that every platform,
dependency combination, or arbitrary input is supported.
