#!/usr/bin/env python3
"""Test parquet data loading with verl's RLHFDataset."""
import sys
sys.path.insert(0, '/workspace-verl')

from verl.utils.dataset.rl_dataset import RLHFDataset
from transformers import AutoTokenizer
from omegaconf import DictConfig

# Load tokenizer
tokenizer_path = '/data_nv1/models/DeepSeek-V4-Flash-DSpark-BF16'
print(f'Loading tokenizer from {tokenizer_path}...')
tokenizer = AutoTokenizer.from_pretrained(tokenizer_path, trust_remote_code=True)

# Create config
config = DictConfig({
    'prompt_key': 'prompt',
    'max_prompt_length': 4096,
    'truncation': 'error',
    'cache_dir': '/tmp/verl_cache',
})

# Load dataset
dataset = RLHFDataset(
    data_files=['/data/dataset/cybergym/train.parquet'],
    tokenizer=tokenizer,
    config=config,
)

print(f'\nDataset loaded: {len(dataset)} samples')

# Check first sample
sample = dataset[0]
print(f'\nSample 0 keys: {list(sample.keys())}')

# Decode raw_prompt (list of messages)
raw_prompt = sample['raw_prompt']
print(f'\nRaw prompt type: {type(raw_prompt)}')
print(f'Raw prompt length: {len(raw_prompt)}')

# Print first message
if isinstance(raw_prompt, list) and len(raw_prompt) > 0:
    print(f'\nFirst message role: {raw_prompt[0].get("role", "N/A")}')
    content = raw_prompt[0].get("content", "")
    print(f'First message content (first 300 chars):\n{content[:300]}...')

print(f'\nData source: {sample.get("data_source", "N/A")}')
print(f'Extra info: {sample.get("extra_info", "N/A")}')

print('\nParquet loading test passed!')
