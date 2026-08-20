#!/usr/bin/env python3
"""
Minimal end-to-end test: 1 rollout → 1 reward computation.

This validates the full pipeline without running a full GRPO training loop.
"""
import sys
sys.path.insert(0, '/workspace-verl')

import torch
from torch.utils.data import DataLoader
from transformers import AutoTokenizer
from omegaconf import DictConfig
from verl.utils.dataset.rl_dataset import RLHFDataset

# Load tokenizer
tokenizer_path = '/data_nv1/models/DeepSeek-V4-Flash-DSpark-BF16'
print('Loading tokenizer...')
tokenizer = AutoTokenizer.from_pretrained(tokenizer_path, trust_remote_code=True)

# Create dataset
config = DictConfig({
    'prompt_key': 'prompt',
    'max_prompt_length': 4096,
    'truncation': 'error',
    'cache_dir': '/tmp/verl_cache',
})

dataset = RLHFDataset(
    data_files=['/data/dataset/cybergym/train.parquet'],
    tokenizer=tokenizer,
    config=config,
)

print(f'Dataset size: {len(dataset)}')

# Create dataloader (batch_size=1, single sample)
dataloader = DataLoader(
    dataset=dataset,
    batch_size=1,
    shuffle=False,
    num_workers=0,
)

# Get one batch
batch = next(iter(dataloader))
print(f'\nBatch keys: {list(batch.keys())}')
print(f'Batch size: {len(batch["raw_prompt"])}')

# Check batch structure
print(f'\nBatch structure:')
for key in batch.keys():
    val = batch[key]
    if isinstance(val, list):
        print(f'  {key}: list[{len(val)}]')
        if len(val) > 0 and isinstance(val[0], dict):
            print(f'    [0] keys: {list(val[0].keys())}')
    elif isinstance(val, torch.Tensor):
        print(f'  {key}: tensor{val.shape}')
    else:
        print(f'  {key}: {type(val)}')

# Extract first sample's data
first_sample_idx = 0
data_source = batch['data_source'][first_sample_idx] if isinstance(batch['data_source'], list) else batch['data_source']
extra_info = batch['extra_info']

# Extract ground_truth from reward_model
reward_model = batch['reward_model']
print(f'\nreward_model structure: {reward_model}')
if isinstance(reward_model, dict):
    if 'ground_truth' in reward_model:
        gt = reward_model['ground_truth']
        ground_truth = gt[first_sample_idx] if isinstance(gt, list) else gt
    else:
        ground_truth = extra_info.get('task_id', '') if isinstance(extra_info, dict) else ''
else:
    ground_truth = str(reward_model)

print(f'\nExtracted: data_source={data_source}, ground_truth={ground_truth}')

# Simulate a rollout: generate a fake response with code
fake_response = """Based on the vulnerability description, I'll craft a PoC:

```python
import struct
import sys

# Buffer overflow: 64 bytes padding + overwritten return address
poc = b"A" * 64 + struct.pack("<Q", 0xdeadbeefdeadbeef)
sys.stdout.buffer.write(poc)
```

This should trigger a crash in the vulnerable function."""

# Encode the response
response_ids = tokenizer.encode(fake_response, return_tensors='pt')
print(f'\nFake response tokens: {response_ids.shape}')

# Call mock reward function
sys.path.insert(0, '/data/z00666713/deepseek0715/cybergym_integration/verl_integration')
from cybergym_reward_mock import compute_score

result = compute_score(
    data_source=data_source,
    solution_str=fake_response,
    ground_truth=ground_truth,
    extra_info=extra_info,
)

print(f'\nReward result: {result}')
print(f'Score: {result["score"]}')

# Verify
assert result['score'] > 0, "Should have positive reward for code output"
assert result['has_code'], "Should detect Python code"

print('\n✅ End-to-end test passed!')
