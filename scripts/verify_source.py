#!/usr/bin/env python3
"""Integrity verification for downloaded CyberGym source packages.

Four checks, run on the relay after download completes:
  1. MANIFEST  — every repo-vul.tar.gz from the official HF repo is present
  2. SIZE      — local file size exactly matches HF metadata (catches
                 truncation and HTML-error-page pollution)
  3. GZIP      — every file passes `gzip -t` (parallel, catches corruption)
  4. TAR       — random sample of 5 packages actually extracts

Usage: python3 verify_source.py [--skip-gzip]
"""
import argparse
import gzip
import random
import subprocess
import sys
import tarfile
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

from huggingface_hub import HfApi

SRC = Path("/data/z00666713/cybergym_src/data/arvo")


def check_gzip(path: str) -> tuple[str, bool]:
    try:
        with gzip.open(path, "rb") as f:
            while f.read(1 << 20):
                pass
        return path, True
    except Exception:
        return path, False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--skip-gzip", action="store_true")
    args = ap.parse_args()

    print("== 1. MANIFEST (HF authoritative file list) ==")
    tree = HfApi().list_repo_tree("sunblaze-ucb/cybergym", repo_type="dataset",
                                  recursive=True, path_in_repo="data/arvo")
    remote = {}
    for f in tree:
        if f.path.endswith("repo-vul.tar.gz"):
            tid = f.path.split("/")[2]
            remote[tid] = f.size
    local_dirs = {d.name for d in SRC.iterdir() if d.is_dir()}
    missing = set(remote) - local_dirs
    print(f"   remote={len(remote)} local={len(local_dirs)} missing={len(missing)}")
    if missing:
        print(f"   MISSING SAMPLE: {sorted(missing)[:10]}")

    print("== 2. SIZE (exact match vs HF metadata) ==")
    bad_size, bad_file = [], []
    for tid, rsize in remote.items():
        p = SRC / tid / "repo-vul.tar.gz"
        if not p.exists():
            continue
        lsize = p.stat().st_size
        if lsize != rsize:
            bad_size.append((tid, lsize, rsize))
        elif lsize < 1000:  # HTML error pages are tiny
            bad_file.append((tid, lsize))
    print(f"   size mismatches={len(bad_size)} suspicious-small={len(bad_file)}")
    for t in (bad_size + bad_file)[:10]:
        print(f"   BAD: {t}")

    if not args.skip_gzip:
        print("== 3. GZIP integrity (all files, parallel) ==")
        paths = [str(SRC / t / "repo-vul.tar.gz") for t in remote
                 if (SRC / t / "repo-vul.tar.gz").exists()]
        bad_gz = []
        with ProcessPoolExecutor(max_workers=8) as ex:
            for path, ok in ex.map(check_gzip, paths, chunksize=16):
                if not ok:
                    bad_gz.append(path)
        print(f"   checked={len(paths)} corrupt={len(bad_gz)}")
        for p in bad_gz[:10]:
            print(f"   CORRUPT: {p}")

    print("== 4. TAR extraction smoke test (random 5) ==")
    sample = random.sample(sorted(local_dirs), min(5, len(local_dirs)))
    for tid in sample:
        p = SRC / tid / "repo-vul.tar.gz"
        try:
            with tarfile.open(p) as tf:
                names = tf.getnames()[:3]
            print(f"   OK {tid}: {len(names)}+ entries e.g. {names[0] if names else '?'}")
        except Exception as e:
            print(f"   FAIL {tid}: {e}")

    n_bad = len(missing) + len(bad_size) + len(bad_file) + (
        0 if args.skip_gzip else len(bad_gz if 'bad_gz' in dir() else []))
    print(f"\nVERDICT: {'ALL-CLEAN' if n_bad == 0 else f'{n_bad} PROBLEMS — re-download bad ids'}")


if __name__ == "__main__":
    main()
