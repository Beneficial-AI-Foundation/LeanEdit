#!/usr/bin/env python3
"""Compile Lean -> C -> native macOS app or Linux install tree; Python is only a build tool.

macOS:  python3 editor_lean/build.py --tk-bundle /path/to/TclTk/Frameworks
Linux:  python3 editor_lean/build.py [--tk-bundle /path/to/tcltk-9.0.4-prefix]
On Linux --tk-bundle is a Tcl/Tk 9.0.4 install prefix (lib/libtcl9.0.so,
lib/libtcl9tk9.0.so, lib/tcl9.0, lib/tk9.0); it defaults to
.editor-lean-build/tcltk-9.0.4.
"""
import argparse
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tarfile

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / 'editor_lean'
BUILD = ROOT / '.editor-lean-build'
APP = ROOT / 'dist/EditorLean.app'
LINUX_TREE = ROOT / 'dist/EditorLean'
STARTUP_MARKER = ('# EditorLean has a native Lean entry point.\n'
                  '# This startup marker prevents Tk from creating an interactive Wish console.\n')
VERSION = 'leanprover--lean4---v4.35.0-rc3'


def run(*args):
    print('+', ' '.join(map(str, args)), flush=True)
    subprocess.run(list(map(str, args)), cwd=ROOT, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--toolchain', type=Path, default=Path.home() / '.elan/toolchains' / VERSION)
    default_tk = (ROOT / 'dist/Editor.app/Contents/Frameworks' if sys.platform == 'darwin'
                  else BUILD / 'tcltk-9.0.4')
    parser.add_argument('--tk-bundle', type=Path, default=default_tk,
                        help='macOS: Tcl/Tk runtime bundle; Linux: Tcl/Tk 9.0.4 install prefix')
    parser.add_argument('--gui-test', action='store_true')
    options = parser.parse_args()
    toolchain = options.toolchain.resolve()
    runtime = options.tk_bundle.resolve()
    if not (toolchain / 'bin/lean').exists():
        parser.error('Install Lean 4.35.0-rc3 or supply --toolchain.')
    if sys.platform.startswith('linux'):
        return build_linux(parser, options, toolchain, runtime)
    if sys.platform != 'darwin':
        parser.error('Unsupported platform: ' + sys.platform)
    if not (runtime / 'libtcl9.0.dylib').exists():
        parser.error('Supply --tk-bundle with Tcl/Tk 9.0.4 libraries and _tcl_data/_tk_data.')
    BUILD.mkdir(exist_ok=True)
    generated = SOURCE / 'generated'
    generated.mkdir(exist_ok=True)
    run(toolchain / 'bin/lean', '-c', generated / 'EditorLean.c', SOURCE / 'EditorLean.lean')
    # Only replace our own build artifact after successful Lean compilation.
    if APP.exists():
        shutil.rmtree(APP)
    contents = APP / 'Contents'
    binaries = contents / 'MacOS'
    libraries = contents / 'Frameworks'
    resources = contents / 'Resources'
    for folder in (binaries, libraries, resources):
        folder.mkdir(parents=True, exist_ok=True)
    for name in ('libtcl9.0.dylib', 'libtcl9tk9.0.dylib'):
        shutil.copy2(runtime / name, libraries / name)
    for src, dst in (('_tcl_data', 'tcl9.0'), ('_tk_data', 'tk9.0'), ('tcl9', 'tcl9')):
        shutil.copytree(runtime / src, resources / dst, symlinks=False)
    (resources / 'native-startup.tcl').write_text(STARTUP_MARKER)
    os.environ['LEAN_CC'] = '/usr/bin/clang'
    os.environ['MACOSX_DEPLOYMENT_TARGET'] = '14.0'
    # Use macOS 14-compatible static GMP/libuv; the toolchain copies target macOS 15.
    compat = BUILD / 'compat-libs'
    compat.mkdir(exist_ok=True)
    for name in ('libgmp.a', 'libuv.a'):
        dependency = Path('/opt/homebrew/lib') / name
        if not dependency.exists():
            parser.error('Install Homebrew gmp and libuv (static libraries required).')
        if (compat / name).exists():
            (compat / name).unlink()
        shutil.copy2(dependency, compat / name)
    sdk = subprocess.check_output(['/usr/bin/xcrun', '--show-sdk-path'], text=True).strip()
    run(toolchain / 'bin/leanc', '-O2', '-isysroot', sdk, '-I', SOURCE / 'vendor/tcl9.0.4', '-o', binaries / 'EditorLean',
        generated / 'EditorLean.c', SOURCE / 'bridge.c', '-L', compat, '-L', toolchain / 'lib', '-L', libraries, '-ltcl9.0', '-ltcl9tk9.0',
        '-Wl,-rpath,@executable_path/../Frameworks')
    icon = runtime.parent / 'Resources/icon-windowed.icns'
    if icon.exists():
        shutil.copy2(icon, resources / 'EditorLean.icns')
    info = {
        'CFBundleExecutable': 'EditorLean', 'CFBundleName': 'EditorLean',
        'CFBundleDisplayName': 'EditorLean', 'CFBundleIdentifier': 'local.productivity.EditorLean',
        'CFBundleInfoDictionaryVersion': '6.0',
        'CFBundlePackageType': 'APPL', 'CFBundleShortVersionString': '1.0.4', 'CFBundleVersion': '5',
        'CFBundleIconFile': 'EditorLean.icns', 'LSMinimumSystemVersion': '14.0',
        'NSHighResolutionCapable': True,
        'CFBundleDocumentTypes': [{'CFBundleTypeName': 'UTF-8 Text', 'CFBundleTypeRole': 'Editor',
                                  'LSHandlerRank': 'Alternate', 'LSItemContentTypes': ['public.text']}],
    }
    with (contents / 'Info.plist').open('wb') as stream:
        plistlib.dump(info, stream)
    licenses = resources / 'Licenses'
    licenses.mkdir()
    shutil.copy2(toolchain / 'LICENSE', licenses / 'Lean-LICENSE')
    shutil.copy2(toolchain / 'LICENSES', licenses / 'Lean-dependencies.txt')
    for package, names in [('gmp', ['COPYING', 'COPYING.LESSERv3']), ('libuv', ['LICENSE', 'LICENSE-extra'])]:
        package_root = (Path('/opt/homebrew/opt') / package).resolve()
        for name in names:
            shutil.copy2(package_root / name, licenses / (package + '-' + name))
    for name in ('Tcl-license.terms', 'Tk-license.terms'):
        shutil.copy2(SOURCE / 'vendor' / name, licenses / name)
    run(binaries / 'EditorLean', '--self-test')
    if options.gui_test:
        run(binaries / 'EditorLean', '--gui-self-test')
    for library in libraries.glob('*.dylib'):
        run('/usr/bin/codesign', '--force', '--sign', '-', library)
    run('/usr/bin/codesign', '--force', '--sign', '-', APP)
    run('/usr/bin/codesign', '--verify', '--deep', '--strict', APP)
    zip_path = ROOT / 'dist/EditorLean-AppleSilicon.zip'
    if zip_path.exists():
        zip_path.unlink()
    run('/usr/bin/ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', APP, zip_path)
    diagnostic = ROOT / 'dist/Diagnose EditorLean.command'
    shutil.copy2(SOURCE / 'Diagnose EditorLean.command', diagnostic)
    diagnostic.chmod(0o755)
    print('Diagnostic launcher:', diagnostic)
    print('Built:', APP)
    print('Generated C:', generated / 'EditorLean.c')


LINUX_LIBS = ('libtcl9.0.so', 'libtcl9tk9.0.so')


def build_linux(parser, options, toolchain, prefix):
    """Linux layout: dist/EditorLean/{bin,lib,share/editorlean,share/licenses}."""
    for name in LINUX_LIBS:
        if not (prefix / 'lib' / name).exists():
            parser.error(f'--tk-bundle must be a Tcl/Tk 9.0.4 prefix containing lib/{name} '
                         '(build Tcl/Tk 9.0.4 from source with --prefix=<dir>).')
    for name in ('tcl9.0', 'tk9.0'):
        if not (prefix / 'lib' / name / ('init.tcl' if name == 'tcl9.0' else 'tk.tcl')).exists():
            parser.error(f'Tcl/Tk prefix lacks lib/{name} script library.')
    for name in ('libgmp.a', 'libuv.a'):
        if not (toolchain / 'lib' / name).exists():
            parser.error(f'Toolchain lacks lib/{name}.')
    BUILD.mkdir(exist_ok=True)
    generated = SOURCE / 'generated'
    generated.mkdir(exist_ok=True)
    run(toolchain / 'bin/lean', '-c', generated / 'EditorLean.c', SOURCE / 'EditorLean.lean')
    tree = LINUX_TREE
    if tree.exists():
        shutil.rmtree(tree)
    binaries, libraries = tree / 'bin', tree / 'lib'
    resources, licenses = tree / 'share/editorlean', tree / 'share/licenses/editorlean'
    for folder in (binaries, libraries, resources, licenses):
        folder.mkdir(parents=True, exist_ok=True)
    for name in LINUX_LIBS:
        shutil.copy2(prefix / 'lib' / name, libraries / name)
    for name in ('tcl9.0', 'tk9.0'):
        shutil.copytree(prefix / 'lib' / name, resources / name, symlinks=False)
    # Tcl 9 module path (tcl9/9.0/*.tm: msgcat, tcltest, ...) beside the script library.
    if (prefix / 'lib/tcl9').exists():
        shutil.copytree(prefix / 'lib/tcl9', resources / 'tcl9', symlinks=False)
    (resources / 'native-startup.tcl').write_text(STARTUP_MARKER)
    # The toolchain's clang has no libc headers on Linux (bridge.c needs them),
    # so leanc drives the system compiler; gmp/libuv still link statically
    # from the toolchain's lib directory.
    os.environ.setdefault('LEAN_CC', shutil.which('cc') or shutil.which('gcc') or 'cc')
    run(toolchain / 'bin/leanc', '-O2', '-I', SOURCE / 'vendor/tcl9.0.4', '-o', binaries / 'EditorLean',
        generated / 'EditorLean.c', SOURCE / 'bridge.c', '-L', toolchain / 'lib', '-L', libraries,
        '-ltcl9.0', '-ltcl9tk9.0', '-Wl,-rpath,$ORIGIN/../lib')
    (tree / 'share/applications').mkdir(parents=True)
    (tree / 'share/applications/editorlean.desktop').write_text(
        '[Desktop Entry]\nType=Application\nName=EditorLean\n'
        'Comment=NEdit-style text editor written in Lean\n'
        'Exec=EditorLean %F\nTryExec=EditorLean\nTerminal=false\n'
        'Categories=Utility;TextEditor;\nMimeType=text/plain;\nStartupNotify=false\n')
    shutil.copy2(toolchain / 'LICENSE', licenses / 'Lean-LICENSE')
    # Lean's LICENSES also covers the GMP and libuv code linked from its toolchain.
    shutil.copy2(toolchain / 'LICENSES', licenses / 'Lean-dependencies.txt')
    for name in ('Tcl-license.terms', 'Tk-license.terms'):
        shutil.copy2(SOURCE / 'vendor' / name, licenses / name)
    for package in ('gmp', 'libuv'):
        system = Path('/usr/share/licenses') / package
        if system.is_dir():
            for item in system.iterdir():
                if item.is_file():
                    shutil.copy2(item, licenses / (package + '-' + item.name))
    shutil.copy2(SOURCE / 'README.txt', tree / 'share/editorlean/README.txt')
    run(binaries / 'EditorLean', '--self-test')
    if options.gui_test:
        run(binaries / 'EditorLean', '--gui-self-test')
    diagnostic = tree / 'diagnose-editorlean.sh'
    shutil.copy2(SOURCE / 'diagnose-editorlean.sh', diagnostic)
    diagnostic.chmod(0o755)
    archive = ROOT / 'dist/EditorLean-linux-x86_64.tar.gz'
    if archive.exists():
        archive.unlink()
    with tarfile.open(archive, 'w:gz') as stream:
        stream.add(tree, arcname='EditorLean')
    print('Diagnostic launcher:', diagnostic)
    print('Built:', tree)
    print('Archive:', archive)
    print('Generated C:', generated / 'EditorLean.c')


if __name__ == '__main__':
    main()
