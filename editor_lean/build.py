#!/usr/bin/env python3
"""Compile Lean -> C -> native macOS app; Python is only a build tool."""
import argparse
import os
from pathlib import Path
import plistlib
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / 'editor_lean'
BUILD = ROOT / '.editor-lean-build'
APP = ROOT / 'dist/EditorLean.app'
VERSION = 'leanprover--lean4---v4.35.0-rc3'


def run(*args):
    print('+', ' '.join(map(str, args)), flush=True)
    subprocess.run(list(map(str, args)), cwd=ROOT, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--toolchain', type=Path, default=Path.home() / '.elan/toolchains' / VERSION)
    parser.add_argument('--tk-bundle', type=Path, default=ROOT / 'dist/Editor.app/Contents/Frameworks')
    parser.add_argument('--gui-test', action='store_true')
    options = parser.parse_args()
    toolchain = options.toolchain.resolve()
    runtime = options.tk_bundle.resolve()
    if not (toolchain / 'bin/lean').exists():
        parser.error('Install Lean 4.35.0-rc3 or supply --toolchain.')
    if not (runtime / 'libtcl9.0.dylib').exists():
        parser.error('Supply --tk-bundle with Tcl/Tk 9.0.4 libraries and _tcl_data/_tk_data.')
    icon = SOURCE / 'icon/EditorLean.icns'
    if not icon.exists():
        parser.error(f'App icon missing: {icon}. Restore it from git (its source is icon/EditorLean.svg).')
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
    (resources / 'native-startup.tcl').write_text(
        '# EditorLean has a native Lean entry point.\n'
        '# This startup marker prevents Tk from creating an interactive Wish console.\n')
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

if __name__ == '__main__':
    main()
