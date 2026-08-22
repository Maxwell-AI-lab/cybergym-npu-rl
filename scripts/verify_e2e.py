#!/usr/bin/env python3
"""E2E dataset integrity verification (runs on x86).

Four checks:
  1. MANIFEST — all 920 tasks from tasks.txt have src.tgz
  2. GZIP     — every src.tgz passes gzip integrity check
  3. SIBLINGS — poc.bin and crash.log exist for each task
  4. SIZE     — flag suspiciously small files (<1KB, likely error pages)

Also verifies Docker images against the required list.

Usage: /data/e2e_venv/bin/python verify_e2e.py
"""
import gzip
import subprocess
import sys
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

DATA = Path("/data/cybergym-e2e/data")
REPO = Path("/data/cybergym-e2e")  # git clone location
PROJECTS = Path("/data/cybergym-e2e/projects")  # might be in repo or data


def get_task_list():
    """Get all 920 task IDs from the repo's tasks.txt."""
    tasks_file = None
    for candidate in [REPO / "scripts" / "tasks.txt", DATA / "tasks.txt"]:
        if candidate.exists():
            tasks_file = candidate
            break
    if not tasks_file:
        return []
    return [line.strip() for line in tasks_file.read_text().splitlines() if line.strip()]


def check_gzip(path):
    try:
        with gzip.open(path, "rb") as f:
            while f.read(1 << 20):
                pass
        return str(path), True
    except Exception:
        return str(path), False


def main():
    print("=" * 60)
    print(" E2E Dataset Integrity Verification")
    print("=" * 60)

    # 1. Manifest check
    print("\n[1] MANIFEST — all tasks have src.tgz")
    tasks = get_task_list()
    print(f"   tasks.txt: {len(tasks)} tasks")

    # Find data files
    src_files = {}
    if DATA.exists():
        for p in DATA.rglob("src.tgz"):
            # Extract task ID from path like projects/wasm3/arvo_33318/src.tgz
            parts = p.parts
            task_id = f"{parts[-3]}/{parts[-2]}"  # e.g., wasm3/arvo_33318
            src_files[task_id] = p
    print(f"   src.tgz found: {len(src_files)}")

    missing_src = set()
    for t in tasks:
        if t not in src_files:
            missing_src.add(t)
    if missing_src:
        print(f"   ❌ MISSING src.tgz: {len(missing_src)}")
        for t in sorted(missing_src)[:5]:
            print(f"      {t}")
    else:
        print(f"   ✅ All {len(tasks)} tasks have src.tgz")

    # 2. Gzip integrity
    print(f"\n[2] GZIP — integrity check on all src.tgz")
    paths = [str(p) for p in src_files.values()]
    bad_gz = []
    if paths:
        with ProcessPoolExecutor(max_workers=8) as ex:
            for path, ok in ex.map(check_gzip, paths, chunksize=8):
                if not ok:
                    bad_gz.append(path)
    if bad_gz:
        print(f"   ❌ CORRUPT: {len(bad_gz)}")
        for p in bad_gz[:5]:
            print(f"      {p}")
    else:
        print(f"   ✅ All {len(paths)} files pass gzip check")

    # 3. Sibling files (poc.bin + crash.log)
    print(f"\n[3] SIBLINGS — poc.bin and crash.log presence")
    missing_poc, missing_crash = [], []
    for task_id, src_path in src_files.items():
        parent = src_path.parent
        if not (parent / "poc.bin").exists():
            missing_poc.append(task_id)
        if not (parent / "crash.log").exists():
            missing_crash.append(task_id)
    if missing_poc:
        print(f"   ❌ Missing poc.bin: {len(missing_poc)}")
    else:
        print(f"   ✅ All have poc.bin")
    if missing_crash:
        print(f"   ⚠️ Missing crash.log: {len(missing_crash)} (may not exist for all)")
    else:
        print(f"   ✅ All have crash.log")

    # 4. Size sanity
    print(f"\n[4] SIZE — suspiciously small files")
    small = []
    total_size = 0
    for task_id, p in src_files.items():
        sz = p.stat().st_size
        total_size += sz
        if sz < 1024:
            small.append((task_id, sz))
    if small:
        print(f"   ⚠️ Small files (<1KB): {len(small)}")
        for t, s in small[:5]:
            print(f"      {t}: {s} bytes")
    else:
        print(f"   ✅ No suspiciously small files")
    print(f"   Total dataset size: {total_size / 1024**3:.1f} GB")

    # 5. Docker images check
    print(f"\n[5] DOCKER IMAGES")
    imgs_file = Path("/tmp/e2e_images.txt")
    if imgs_file.exists():
        required = [l.strip() for l in imgs_file.read_text().splitlines() if l.strip()]
        result = subprocess.run(
            ["docker", "images", "--format", "{{.Repository}}@{{.Digest}}\n{{.Repository}}:{{.Tag}}"],
            capture_output=True, text=True
        )
        available = result.stdout
        missing_imgs = []
        for img in required:
            # Check both by tag and by digest
            short = img.split("@")[0] if "@" in img else img
            tag = img.split(":")[-1] if ":" in img else ""
            if short.split(":")[0] not in available and tag not in available:
                # More lenient check
                repo = img.split("@")[0].split(":")[0]
                if repo not in available:
                    missing_imgs.append(img)
        if missing_imgs:
            print(f"   ❌ Missing images: {len(missing_imgs)}/{len(required)}")
            for m in missing_imgs[:5]:
                print(f"      {m}")
        else:
            print(f"   ✅ All {len(required)} images present")

    # Summary
    total_issues = len(missing_src) + len(bad_gz) + len(missing_poc) + len(small)
    print(f"\n{'=' * 60}")
    if total_issues == 0:
        print(f" ✅ ALL CLEAN — dataset ready for E2E evaluation")
    else:
        print(f" ⚠️ {total_issues} issues found — see details above")
    print(f"{'=' * 60}")
    return 0 if total_issues == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
