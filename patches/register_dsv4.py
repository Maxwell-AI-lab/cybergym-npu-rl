"""Register DeepSeek V4 model type with HuggingFace transformers (idempotent)."""
import sys, json, os, importlib

MODEL_DIR = "/data/model/DeepSeek-V4-Flash-bf16-deploy"
sys.path.insert(0, MODEL_DIR)

with open(os.path.join(MODEL_DIR, "config.json")) as f:
    cfg = json.load(f)

model_type = cfg["model_type"]
config_cls_path = cfg["auto_map"]["Config"]
mod_name, cls_name = config_cls_path.rsplit(".", 1)
mod = importlib.import_module(mod_name)
cls = getattr(mod, cls_name)

from transformers import AutoConfig

# Idempotent: ignore "already used" error if model_type is already registered
try:
    AutoConfig.register(model_type, cls)
    print(f"[register_dsv4] Registered model_type={model_type!r} → {cls_name}", file=sys.stderr)
except ValueError as e:
    if "already used" in str(e):
        print(f"[register_dsv4] model_type={model_type!r} already registered, skip", file=sys.stderr)
    else:
        raise
