#!/usr/bin/env python3
"""Check proofs against freshly compiled editor source; audit theorem dependencies."""
from pathlib import Path
import hashlib
import json
import os
import re
import subprocess

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / 'editor_lean'
BUILD = ROOT / '.editor-lean-build/proofs'
LEAN = Path(os.environ.get('EDITORLEAN_LEAN', str(Path.home() / '.elan/toolchains/leanprover--lean4---v4.35.0-rc3/bin/lean')))


def main():
    BUILD.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, LEAN_PATH=str(BUILD))
    def run(*args):
        result = subprocess.run([str(LEAN), *map(str,args)], cwd=ROOT, env=env, text=True, capture_output=True)
        if result.returncode:
            raise SystemExit(result.stdout + result.stderr)
        return result.stdout + result.stderr
    version = run('--version').strip()
    run('-R', SOURCE, '-o', BUILD / 'EditorLean.olean', SOURCE / 'EditorLean.lean')
    audit = run('-DwarningAsError=true', '-R', SOURCE, '-o', BUILD / 'EditorLeanProofs.olean', SOURCE / 'EditorLeanProofs.lean')
    proof_text = (SOURCE / 'EditorLeanProofs.lean').read_text()
    names = re.findall(r'^theorem (\w+)', proof_text, re.M)
    entries = re.findall(r"'EditorLeanProofs\.(\w+)' depends on axioms: \[([^\]]*)\]", audit)
    assert {name for name, _ in entries} == set(names), 'Missing theorem audit output'
    permitted = {'propext', 'Classical.choice', 'Quot.sound'}
    for name, axioms in entries:
        found = {a.strip() for a in axioms.split(',') if a.strip()}
        assert found <= permitted, (name, found - permitted)
    evidence = {'toolchain': version, 'theorem_count': len(names), 'theorems': names,
                'axioms': sorted(permitted), 'sha256': {name: hashlib.sha256((SOURCE/name).read_bytes()).hexdigest()
                    for name in ['EditorLean.lean','EditorLeanProofs.lean']}}
    (SOURCE / 'verification.log').write_text(version + '\n' + audit + f'\nPASS: {len(names)} universal theorems checked.\n')
    (SOURCE / 'verification.json').write_text(json.dumps(evidence, indent=2) + '\n')
    print(f'PASS: {len(names)} universal theorems; fresh application import; standard-axiom audit passed.')

if __name__ == '__main__':
    main()
