#!/usr/bin/env python3
"""Download per-level task files (description/error/patch/repo-fix) from the
official CyberGym HuggingFace dataset.

Only fetches the files the agent workspace needs per official DIFFICULTY_FILES:
  level0: repo-vul.tar.gz            (already local)
  level1: + description.txt
  level2: + error.txt
  level3: + repo-fix.tar.gz, patch.diff

Usage (on x86):
  python3 download_level_files.py --data-dir /data/cybergym_src \
      --tasks "arvo:47101,arvo:3938,arvo:24993,arvo:1065,arvo:10400,arvo:368,oss-fuzz:42535201,oss-fuzz:42535468,oss-fuzz:370689421,oss-fuzz:385167047"
"""

import argparse
import time
from pathlib import Path
from urllib.request import Request, urlopen

HF_BASE = "https://huggingface.co/datasets/sunblaze-ucb/cybergym/resolve/main/data"
LEVEL_FILES = ["description.txt", "error.txt", "patch.diff", "repo-fix.tar.gz"]


def fetch(url: str, dest: Path, retries: int = 3) -> tuple[bool, int]:
    for attempt in range(retries):
        try:
            req = Request(url, headers={"User-Agent": "cybergym-data/1.0"})
            with urlopen(req, timeout=120) as resp, open(dest, "wb") as f:
                data = resp.read()
                f.write(data)
                return True, len(data)
        except Exception as e:
            if attempt == retries - 1:
                print(f"    FAIL {url}: {e}")
                return False, 0
            time.sleep(2 * (attempt + 1))
    return False, 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--data-dir", type=Path, required=True)
    parser.add_argument("--tasks", type=str, required=True, help="comma-separated task ids")
    parser.add_argument("--files", type=str, default=",".join(LEVEL_FILES))
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()

    files = args.files.split(",")
    tasks = [t.strip() for t in args.tasks.split(",") if t.strip()]

    ok = fail = skip = 0
    for task_id in tasks:
        subset, sub_id = task_id.split(":")
        task_dir = args.data_dir / subset / sub_id
        task_dir.mkdir(parents=True, exist_ok=True)
        for name in files:
            dest = task_dir / name
            if dest.exists() and dest.stat().st_size > 0 and not args.force:
                skip += 1
                continue
            url = f"{HF_BASE}/{subset}/{sub_id}/{name}"
            success, size = fetch(url, dest)
            if success:
                ok += 1
                print(f"  {task_id}/{name}: {size} bytes")
            else:
                fail += 1
                if dest.exists() and dest.stat().st_size == 0:
                    dest.unlink()

    print(f"\ndone: ok={ok} skip={skip} fail={fail}")
    raise SystemExit(1 if fail else 0)


if __name__ == "__main__":
    main()
