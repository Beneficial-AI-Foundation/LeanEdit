# Contributing to EditorLean

Thanks for your interest in contributing. EditorLean is a native macOS text
editor whose application logic is written in Lean 4, with a small C bridge to
Tcl/Tk and 21 universal theorems proved about selected editor operations. This
guide covers how to build it, the standards we hold the code to, and how to send
a change. It follows the shared contribution standard used across the
[Beneficial AI Foundation](https://github.com/Beneficial-AI-Foundation) Lean
projects.

## Platform

EditorLean targets **Apple silicon on macOS 14 or later** and is not portable to
other platforms: it builds against a Tcl/Tk 9 runtime, the macOS Keychain-signed
app bundle, and `codesign`/`ditto`. Continuous integration therefore runs on
macOS only.

## Prerequisites

Install [`elan`](https://github.com/leanprover/elan), the Lean toolchain manager.
It reads `editor_lean/lean-toolchain` and fetches the exact Lean version this
project uses (currently `v4.35.0-rc3`), so you don't install Lean by hand:

```sh
curl https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh -sSf | sh
```

Checking the proofs needs only `elan` and Python 3. Building the full
application additionally needs:

- the Apple Command Line Tools for Xcode,
- Homebrew `gmp` and `libuv` (static libraries), and
- a **Tcl/Tk 9.0.4 runtime bundle**. This is an external dependency and is *not*
  included in this repository; its directory must contain `libtcl9.0.dylib`,
  `libtcl9tk9.0.dylib`, `_tcl_data`, `_tk_data` and `tcl9`.

## Building

Checking the proofs (no Tcl/Tk bundle required):

```sh
python3 editor_lean/check_proofs.py
```

Building the signed application bundle (`dist/EditorLean.app`):

```sh
python3 editor_lean/build.py --tk-bundle /absolute/path/to/TclTk/Frameworks
```

Use `--toolchain` to point at a specific elan toolchain if the default location
does not apply, and set `EDITORLEAN_LEAN` to override the Lean executable the
proof checker uses.

## Testing

```sh
python3 editor_lean/check_proofs.py                              # proofs + axiom audit
dist/EditorLean.app/Contents/MacOS/EditorLean --self-test       # native self-tests
dist/EditorLean.app/Contents/MacOS/EditorLean --gui-self-test   # GUI suite (desktop session)
```

Continuous integration runs the proof checker on macOS for every push and pull
request (see `.github/workflows/ci.yml`). The GUI self-test must run in a normal
logged-in desktop session and is not run in CI. Please make sure the proof
checker and the native self-tests pass locally before opening a PR.

## Proof discipline

Correctness of the proved operations comes from machine-checked proofs, so the
sources must stay free of proof escape hatches:

- **No `sorry`, `admit` or `native_decide`** in anything the theorems depend on.
- `check_proofs.py` audits every theorem in `EditorLeanProofs.lean` and fails if
  any of them depends on an axiom other than `propext`, `Classical.choice` and
  `Quot.sound` — which is exactly what catches `sorry` (`sorryAx`) and
  `native_decide` (`Lean.ofReduceBool`).

The formal proofs cover selected operations, not the entire editor; behaviour
outside their scope is covered by the native and GUI self-tests.

## Submitting a change

1. **Branch** off `main` (or fork the repository).
2. Keep each pull request focused, and add or update a theorem or self-test for
   behaviour you change.
3. Make sure `python3 editor_lean/check_proofs.py` and the native self-tests
   pass, and that CI is green.
4. Write a clear PR description: what changed, why, and how you verified it.
5. By contributing, you agree your contribution is licensed under this
   repository's license (see `LICENSE`), and you certify the
   [Developer Certificate of Origin](https://developercertificate.org/) — add a
   `Signed-off-by: Your Name <you@example.com>` line to your commits
   (`git commit -s`).

## Reporting issues

Open a GitHub issue with a clear title, what you expected, what happened, and the
smallest editor action or input that reproduces it. Security-sensitive reports
can be sent privately to **support@beneficialaifoundation.org** instead of a
public issue.

## Code of conduct

Be respectful and constructive. Harassment or abuse is not tolerated. Maintainers
may remove comments, commits or contributions that don't meet this standard.
