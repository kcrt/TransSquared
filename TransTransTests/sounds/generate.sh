#!/bin/bash
set -euo pipefail

generate_test_audio() {
  local text="$1"
  local output="${2:-output.m4a}"

  uv run --with "kokoro>=0.9.4" --with soundfile python -c "
import sys, subprocess, tempfile, os, soundfile as sf
from kokoro import KPipeline

text, output = sys.argv[1], sys.argv[2]
pipeline = KPipeline(lang_code='a')
for _, _, audio in pipeline(text, voice='af_heart'):
    with tempfile.NamedTemporaryFile(suffix='.wav', delete=False) as tmp:
        sf.write(tmp.name, audio, 24000)
        subprocess.run(['afconvert', '-f', 'm4af', '-d', 'aac ', tmp.name, output], check=True)
        os.unlink(tmp.name)
print(f'Generated: {output}')
" "$text" "$output"
}


generate_test_audio "hello" hello.m4a
generate_test_audio "Formerly most Japanese houses were made of wood." sentence.m4a
