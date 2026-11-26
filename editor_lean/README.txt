EditorLean 1.0.4 — the NEdit-style editor rewritten in Lean
======================================================

Open ../dist/EditorLean.app. The ZIP is ../dist/EditorLean-AppleSilicon.zip.
This build is for Apple silicon and macOS 14 or later. Python, Lean, Homebrew,
and an internet connection are not required to RUN the packaged app.
The original editor.py and Editor.app have been retained separately.

IMPLEMENTATION

EditorLean.lean contains the document model, file-change checks, editing and
search commands, menus and keyboard bindings, split panes, bookmarks, ctags,
macros, asynchronous shell jobs, and tests. Lean generates generated/EditorLean.c;
leanc compiles that C and links it into the native executable.

bridge.c is a small handwritten bridge for Tcl/Tk widgets, callbacks, Unicode
character classification and atomic POSIX file replacement. The interface still
uses Tcl/Tk, as the original editor did. This is a Lean rewrite of the editor
logic, not a Python launcher. Lean code is type-checked; this is not a formally
proved editor.

GUI SELF-TEST FIX AFTER 1.0.4 TESTING (26 NOVEMBER 2026)

When stdin is /dev/null (CI, scripts, launchd), macOS Tk sent stdout/stderr to
/dev/null, so --gui-self-test results and failure messages were lost, and the
run overwrote EditorLean-Finder-startup.log with its own command trace. Test
mode now restores the output streams after Tk starts and never writes the
Finder log. A new GUI check guards the output streams.

FINDER STARTUP CHANGE IN 1.0.4

Finder normally starts applications with stdin attached to /dev/null. The
previous embedding left Tcl's startup-script field empty, so macOS Tk took
its interactive Wish-console startup path, creating a second interpreter.
Terminal launch did not take that path. The native entry now registers the
bundled native-startup.tcl marker, sets tcl_interactive=0 and initializes the
Tcl argv variables before loading Tk. The marker is not executed by our native
main. TK_CONSOLE is cleared so inherited shell settings cannot force a console.

Native tests verify the startup configuration with a minimal environment and
stdin=/dev/null. Finder activation itself still requires desktop confirmation.
Save work and quit all running EditorLean windows before trying the rebuilt app
in Finder, so macOS does not reactivate an older running executable.

Finder-style launches now record startup stages in EditorLean-Finder-startup.log
beside the app, if that folder is writable. The stream is kept separately from
stdout/stderr because Tk can redirect those to /dev/null. This permits diagnosis
without launching from Terminal. Startup command arguments and document contents
are not traced. The diagnostic .command launcher remains available.

TYPING FIX IN 1.0.3

The generic keyboard binding previously substituted Tk's %A value directly into
an expression. Ordinary letters were then parsed as bare Tcl expression tokens,
causing an Application Error popup. The binding now passes the character and
modifier state as arguments to a procedure, whose expression uses variables.
Regression tests run that exact procedure through the bundled Tcl interpreter
for ordinary text, whitespace, quotes, brackets, Unicode, shortcut modifiers,
and command-like strings. Real key-event checks were also added to the GUI suite.

Quit any older running EditorLean instance, saving work first, and relaunch
using ../dist/Diagnose EditorLean.command. The user confirmed that this launch
path opens the editor. Normal Finder activation is still not confirmed working.

DESKTOP DIAGNOSTICS IN 1.0.2

The user still reports a macOS "not responding" popup after the 1.0.1 thread
fix. The remaining cause is not confirmed. Do not treat the native test suite
as proof that Finder launches the app successfully.

From Finder, double-click ../dist/Diagnose EditorLean.command. This starts the
exact bundled executable directly, opens a Terminal window, and captures its
startup stages and errors in ../dist/EditorLean-startup.log. It does not stop
any existing editor instance. Close a working editor normally to end the
launcher. The diagnostics are disabled for ordinary launches; only startup
command names, not document contents or command arguments, are traced.

STARTUP FIX IN 1.0.1

Lean 4.35's generated launcher normally invokes the application on a worker
thread with a large stack. macOS AppKit/Tk requires the OS main thread. A C
startup constructor now sets Lean's supported LEAN_MAIN_USE_THREAD=0 switch
before the generated main runs, including when launched from Finder. The GUI
bridge also rejects initialization on a worker thread with a clear error.
This fixes a real startup defect in 1.0; the original worker-thread crash was
incorrectly attributed solely to the restricted build session.

Files must be UTF-8. Saves retain the original BOM and newline style, preserve
unchanged file bytes, and prompt before overwriting a changed/deleted file or an
existing Save As destination. Files are staged beside the destination before
atomic replacement. The app checks open files for external changes periodically.
Print opens a local HTML preview in your browser, where Command-P prints it.

BUILD (from the parent project directory)

  python3 editor_lean/build.py

Build prerequisites: Lean 4.35.0-rc3, Apple Command Line Tools, Homebrew GMP and
libuv static libraries, and Tcl/Tk 9.0.4. The build defaults to the already
installed ~/.elan/toolchains/leanprover--lean4---v4.35.0-rc3 and reuses Tcl/Tk
from dist/Editor.app/Contents/Frameworks. --toolchain and --tk-bundle override
those two locations. The Tcl bundle must contain libtcl9.0.dylib,
libtcl9tk9.0.dylib, _tcl_data, _tk_data and tcl9. Public Tcl 9.0.4 headers and
licenses are included in vendor/. No network downloads occur during the build.

The essential compilation steps are:

  lean -c editor_lean/generated/EditorLean.c editor_lean/EditorLean.lean
  leanc -O2 ... editor_lean/generated/EditorLean.c editor_lean/bridge.c ...

build.py supplies the include/library paths and SDK flags, packages the Tcl/Tk
runtime, runs native tests, signs the bundle locally and creates the ZIP.
It sets LEAN_CC=/usr/bin/clang because the bundled Lean compiler's default
header search excludes the macOS SDK headers needed by the GUI bridge.
The Lean runtime is statically linked. Static Homebrew GMP/libuv are used for
macOS 14 compatibility instead of the copies targeting macOS 15 in this Lean
installation. The finished executable dynamically loads only bundled Tcl/Tk
and Apple system libraries. Third-party license texts are in the app Resources.

TESTS

  dist/EditorLean.app/Contents/MacOS/EditorLean --self-test
  dist/EditorLean.app/Contents/MacOS/EditorLean --gui-self-test

64 native tests passed on macOS 14.6.1, covering main-thread startup and rejection
of worker-thread GUI initialization, the C/Lean callback boundary,
Unicode and NUL data, Tcl quoting, document encoding, atomic saves, conflicts,
symlinks, permissions, and asynchronous shell I/O and cancellation.

The GUI suite exercises real widgets, search/replacement, undo, clipboard,
shared split panes, rectangular editing, macros and shell filtering. Run it
from Terminal in a normal logged-in desktop session; it opens temporary editor
windows and uses the clipboard. It can also be requested with build.py --gui-test.
GUI validation still cannot complete in the restricted build session: launching
through macOS Launch Services returns kLSServerCommunicationErr (-10822), and
direct GUI initialization aborts in macOS application registration even on the
main thread. The corrected thread placement is verified independently by the
native tests. In a normal desktop session (25-26 November 2026, macOS 26.5.1),
an end-to-end suite confirmed Launch Services (Finder) activation and all 20
GUI tests.

SOURCE REFERENCES

Lean C backend / FFI:
https://lean-lang.org/doc/reference/latest/Run-Time-Code/Foreign-Function-Interface/
https://lean-lang.org/doc/reference/latest/Elaboration-and-Compilation/
Lean main-thread switch (runtime/thread.cpp, run_with_thread_stack):
https://github.com/leanprover/lean4/blob/v4.35.0-rc3/src/runtime/thread.cpp
Tcl headers: https://github.com/tcltk/tcl/tree/core-9-0-4/generic
Tk runtime: https://github.com/tcltk/tk/tree/core-9-0-4
