#!/usr/bin/env python3
"""Tile the 64-row min parquet N times for the resident loop dataset."""
import sys

import pandas as pd

src, dst, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
df = pd.read_parquet(src)
out = pd.concat([df] * n, ignore_index=True)
out.to_parquet(dst)
print(f"{len(df)} x {n} = {len(out)} rows -> {dst}")
