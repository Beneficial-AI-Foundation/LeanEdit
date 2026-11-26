# EditorLean

A native macOS text editor with its application logic written in Lean and a small C bridge to Tcl/Tk. The current version is 1.0.4 and targets Apple silicon on macOS 14 or later.

## Contents

- `editor_lean/EditorLean.lean`: editor implementation and native/GUI self-tests.
- `editor_lean/bridge.c`: Tcl/Tk and POSIX bridge.
- `editor_lean/EditorLeanProofs.lean`: 21 universal theorems about selected editor operations.
- `editor_lean/vendor/`: Tcl headers and Tcl/Tk license notices.
- [EditorLean.pdf](EditorLean.pdf): user guide, test catalogue, and verification report.
- `EditorLean.tex`: documentation source.
- [editor_lean/README.txt](editor_lean/README.txt): detailed implementation, build, and diagnostic notes.

This repository preserves the original `editor_lean/` layout so the build and documentation scripts can run from the repository root. Generated C, build caches, logs, and packaged applications are excluded from version control.

## Build

Prerequisites are Lean 4.35.0-rc3, Python 3, Apple Command Line Tools, Homebrew GMP and libuv static libraries, and a Tcl/Tk 9.0.4 runtime bundle. The Tcl/Tk runtime is an external dependency and is not included here. Its directory must contain `libtcl9.0.dylib`, `libtcl9tk9.0.dylib`, `_tcl_data`, `_tk_data`, and `tcl9`.

```sh
python3 editor_lean/build.py --tk-bundle /absolute/path/to/TclTk/Frameworks
```

The build defaults to `~/.elan/toolchains/leanprover--lean4---v4.35.0-rc3`; use `--toolchain` to override it. Without `--tk-bundle`, it looks for a previously packaged Python Editor runtime at `dist/Editor.app/Contents/Frameworks`.

The script compiles the application, runs native self-tests, signs the bundle locally, and creates `dist/EditorLean.app` and `dist/EditorLean-AppleSilicon.zip`.

## Verification

```sh
python3 editor_lean/check_proofs.py
dist/EditorLean.app/Contents/MacOS/EditorLean --self-test
```

The proof checker compiles a fresh application import, checks all 21 theorems, audits their axioms, and regenerates `editor_lean/verification.json` and an ignored verification log. Set `EDITORLEAN_LEAN` to override the Lean executable.

To rebuild the PDF, install a LaTeX distribution with `latexmk` and run:

```sh
python3 editor_lean/build_document.py
```

The GUI self-test must run in a normal logged-in desktop session and uses temporary editor windows and the clipboard:

```sh
dist/EditorLean.app/Contents/MacOS/EditorLean --gui-self-test
```

The native suite reports 70 passing native tests (64 in the 1.0.4 release, plus 2 exit-logging and 4 print-preview checks). On 25–26 November 2026, a Playwright end-to-end suite on macOS 26.5.1 confirmed that Launch Services (Finder) activation works and that all 20 GUI tests pass, including when run without a terminal. The formal proofs cover selected operations, not the entire editor.
