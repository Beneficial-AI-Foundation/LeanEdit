#!/usr/bin/env python3
"""Recheck the Lean proofs and compile EditorLean.tex to EditorLean.pdf."""
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent

def main():
    subprocess.run([sys.executable, str(ROOT/'editor_lean/check_proofs.py')], cwd=ROOT, check=True)
    latexmk = shutil.which('latexmk') or '/Library/TeX/texbin/latexmk'
    output = ROOT/'tmp/pdfs/editorlean-latex'
    output.mkdir(parents=True, exist_ok=True)
    subprocess.run([latexmk, '-pdf', '-interaction=nonstopmode', '-halt-on-error',
                    '-file-line-error', '-outdir='+str(output), 'EditorLean.tex'], cwd=ROOT, check=True)
    shutil.copy2(output/'EditorLean.pdf', ROOT/'EditorLean.pdf')
    print('Compiled:',ROOT/'EditorLean.pdf')

if __name__ == '__main__':
    main()
