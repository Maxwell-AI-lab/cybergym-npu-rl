"""
DeepSeek native tool-call format parser for verl tool_agent_loop.

Why this exists (verified on cluster, 2026-08-21):
- DeepSeek V4 Flash chat template IGNORES the `tools` parameter (renders
  identically with/without tools), so tool definitions must come from the
  system prompt.
- Hermes markers `<tool_call>` are NOT in the vocab (id=None), while the
  native markers ARE registered special tokens:
    <｜tool▁calls▁begin｜> 128806   <｜tool▁calls▁end｜>  128807
    <｜tool▁call▁begin｜>  128808   <｜tool▁call▁end｜>   128809
    <｜tool▁sep｜>         128814
- Because these are SPECIAL tokens, decode() strips them by default —
  extraction MUST decode with skip_special_tokens=False (gpt-oss parser
  precedent in verl).

Native format the model was pretrained with:

    <｜tool▁calls▁begin｜><｜tool▁call▁begin｜>function<｜tool▁sep｜>read_file
    ```json
    {"path": "description.txt"}
    ```<｜tool▁call▁end｜><｜tool▁calls▁end｜>

Registration timing: ToolAgentLoop.__init__ loads tools via
initialize_tools_from_config() (line 107) BEFORE calling
ToolParser.get_tool_parser(format) (line 110). Importing this module from
cybergym_tools_verl.py (which tool_config.yaml loads) therefore registers
"deepseek" into ToolParser._registry in time.

Tool responses are rendered back by the chat template's tool role as
`<｜User｜><tool_result>...</tool_result><｜Assistant｜><think>` (verified),
so no manual response formatting is needed (unlike gpt-oss).
"""

import json
import logging
import os
from typing import Optional

import regex

from verl.experimental.agent_loop.tool_parser import FunctionCall, ToolParser
from verl.utils.ray_utils import get_event_loop
from verl.utils.rollout_trace import rollout_trace_op

logger = logging.getLogger(__file__)
logger.setLevel(os.getenv("VERL_LOGGING_LEVEL", "WARN"))

# Exact special-token strings (U+2581 '▁' separators, U+FF5C '｜' bars).
CALLS_BEGIN = "<｜tool▁calls▁begin｜>"
CALLS_END = "<｜tool▁calls▁end｜>"
CALL_BEGIN = "<｜tool▁call▁begin｜>"
CALL_END = "<｜tool▁call▁end｜>"
TOOL_SEP = "<｜tool▁sep｜>"


@ToolParser.register("deepseek")
class DeepSeekToolParser(ToolParser):
    """Parse DeepSeek-native tool calls from generated token ids."""

    def __init__(self, tokenizer) -> None:
        super().__init__(tokenizer)
        # Dialect 1 (native): <｜tool▁call▁begin｜>function<｜tool▁sep｜>NAME\n```json\nARGS\n```
        self.call_regex = regex.compile(
            regex.escape(CALL_BEGIN)
            + r"function"
            + regex.escape(TOOL_SEP)
            + r"([^\n`]+?)\s*```(?:json)?\s*\n(.*?)\n?```",
            regex.DOTALL,
        )
        self.block_regex = regex.compile(
            regex.escape(CALLS_BEGIN) + r".*?" + regex.escape(CALLS_END),
            regex.DOTALL,
        )
        # Dialect 2 (XML, observed in S5 run 2026-08-21):
        #   <tool_call><invoke_name>NAME</invoke_name><parameters><k>v</k>...</parameters></tool_call>
        # The model was pretrained with this dialect and emits it even when
        # native-format examples are shown in the system prompt.
        self.xml_regex = regex.compile(
            r"<tool_call>\s*<invoke_name>([^<]+)</invoke_name>"
            r"\s*<parameters>(.*?)</parameters>\s*</tool_call>",
            regex.DOTALL,
        )
        self.xml_block_regex = regex.compile(
            r"<tool_call>\s*<invoke_name>.*?</parameters>\s*</tool_call>",
            regex.DOTALL,
        )
        self.param_regex = regex.compile(r"<(\w+)>(.*?)</\1>", regex.DOTALL)

    def _xml_params_to_json(self, params_xml: str) -> str:
        """Convert XML <k>v</k> parameters to a JSON arguments string."""
        args: dict = {}
        for key, value in self.param_regex.findall(params_xml):
            value = value.strip()
            if value.lower() == "true":
                args[key] = True
            elif value.lower() == "false":
                args[key] = False
            else:
                args[key] = value
        return json.dumps(args, ensure_ascii=False)

    @rollout_trace_op
    async def extract_tool_calls(
        self,
        responses_ids: list[int],
        tools: Optional[list] = None,
    ) -> tuple[str, list[FunctionCall]]:
        loop = get_event_loop()

        # Special tokens must be preserved to see the native markers.
        raw = await loop.run_in_executor(
            None, lambda: self.tokenizer.decode(responses_ids, skip_special_tokens=False)
        )

        function_calls: list[FunctionCall] = []

        # Dialect 1: native special-token markers.
        if CALLS_BEGIN in raw and CALL_BEGIN in raw:
            for block in self.block_regex.findall(raw):
                for name, args in self.call_regex.findall(block):
                    name, args = name.strip(), args.strip()
                    try:
                        json.loads(args)  # validate; keep raw string on success
                        function_calls.append(FunctionCall(name=name, arguments=args))
                    except Exception as e:
                        logger.error(f"Failed to decode tool call {name!r}: {e}")

        # Dialect 2: XML <tool_call> dialect (plain text, survives decode).
        for name, params_xml in self.xml_regex.findall(raw):
            function_calls.append(
                FunctionCall(name=name.strip(), arguments=self._xml_params_to_json(params_xml))
            )

        if not function_calls:
            text = await loop.run_in_executor(None, lambda: self.tokenizer.decode(responses_ids))
            return text, []

        # Content for downstream consumers: strip both dialects + special tokens.
        no_blocks = self.block_regex.sub("", raw)
        no_blocks = self.xml_block_regex.sub("", no_blocks)
        content = await loop.run_in_executor(
            None, lambda: self.tokenizer.decode(
                self.tokenizer.encode(no_blocks, add_special_tokens=False)
            )
        )
        return content, function_calls
