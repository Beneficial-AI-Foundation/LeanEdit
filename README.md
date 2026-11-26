# EditorLean

A native text editor with its application logic written in Lean and a small C bridge to Tcl/Tk. The current version is 1.0.4 and targets Apple silicon on macOS 14 or later, and x86_64 Linux.

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

### Linux (x86_64)

Prerequisites are Lean 4.35.0-rc3 (via elan), Python 3, a system C compiler (`cc`), and the X11/Xft/fontconfig development libraries. Tcl/Tk 9.0.4 is not packaged by most distributions, so build it from the official source tarballs into a local prefix:

```sh
# from tcl9.0.4/unix and then tk9.0.4/unix
./configure --prefix=$PWD/../../../tcltk-9.0.4 --enable-shared --disable-zipfs [--enable-xft for Tk]
make && make install
```

The build defaults to the prefix `.editor-lean-build/tcltk-9.0.4`; use `--tk-bundle /path/to/prefix` to override it.

```sh
python3 editor_lean/build.py
```

This compiles the application, runs the native self-tests, and creates a relocatable tree `dist/EditorLean/` (`bin/`, bundled Tcl/Tk in `lib/`, script libraries in `share/editorlean/`, a `.desktop` file, and `diagnose-editorlean.sh`) plus `dist/EditorLean-linux-x86_64.tar.gz`. The app uses the system X11 libraries and runs under XWayland on Wayland desktops. On Linux, shortcuts use Control and the editor font is the fontconfig `Monospace` family.

## Verification

```sh
python3 editor_lean/check_proofs.py
dist/EditorLean.app/Contents/MacOS/EditorLean --self-test   # macOS
dist/EditorLean/bin/EditorLean --self-test                   # Linux
```

On Linux (Arch, GNOME on Wayland via XWayland), 64 native and 20 GUI self-tests pass. The macOS build has not been rebuilt or retested since the Linux port; its code paths are kept behind platform checks but are unverified on a Mac.

The proof checker compiles a fresh application import, checks all 21 theorems, audits their axioms, and regenerates `editor_lean/verification.json` and an ignored verification log. The record omits the host platform, so macOS and Linux runs produce the same file. Set `EDITORLEAN_LEAN` to override the Lean executable.

To rebuild the PDF, install a LaTeX distribution with `latexmk` and run:

```sh
python3 editor_lean/build_document.py
```

The GUI self-test must run in a normal logged-in desktop session and uses temporary editor windows and the clipboard:

```sh
dist/EditorLean.app/Contents/MacOS/EditorLean --gui-self-test
```

The existing release notes report 64 passing native tests. The diagnostic launcher has been confirmed to work; ordinary Finder activation and the full GUI suite remain unverified. The formal proofs cover selected operations, not the entire editor.
