"""MLX Whisper sidecar for the patched Meetily build.

Protocol over stdin/stdout (stdout carries protocol only):
  startup   -> {"ready": true, "model": "..."}
  request   <- one JSON line {"n": <samples>, "language": <str|null>} followed by
               n little-endian float32 samples (16 kHz mono)
  response  -> one JSON line {"text": "...", "segments": [...], "language": "..."}
               or {"error": "..."}
"""
import json
import os
import sys

import numpy as np

MODEL_DIR = os.environ.get(
    "MEETILY_MLX_MODEL",
    os.path.expanduser(
        "~/Library/Application Support/com.meetily.ai/models/mlx-whisper-large-v3"
    ),
)


def send(obj):
    sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def read_exact(stream, n):
    buf = bytearray()
    while len(buf) < n:
        chunk = stream.read(n - len(buf))
        if not chunk:
            raise EOFError
        buf.extend(chunk)
    return bytes(buf)


def main():
    import mlx_whisper

    def run(audio, language):
        return mlx_whisper.transcribe(
            audio,
            path_or_hf_repo=MODEL_DIR,
            language=language,
            condition_on_previous_text=False,
            verbose=None,
        )

    run(np.zeros(16000, dtype=np.float32), None)  # load + warm up
    send({"ready": True, "model": MODEL_DIR})

    stdin = sys.stdin.buffer
    while True:
        line = stdin.readline()
        if not line:
            return
        try:
            req = json.loads(line)
            n = int(req["n"])
            audio = np.frombuffer(read_exact(stdin, n * 4), dtype="<f4").copy()
        except EOFError:
            return
        except Exception as e:  # malformed request; stream is likely broken
            send({"error": f"bad request: {e}"})
            return
        try:
            lang = req.get("language")
            if lang in (None, "", "auto", "auto-translate"):
                lang = None
            r = run(audio, lang)
            segs = [
                {"start": s["start"], "end": s["end"], "text": s["text"],
                 "avg_logprob": s.get("avg_logprob"),
                 "no_speech_prob": s.get("no_speech_prob")}
                for s in r.get("segments", [])
            ]
            send({"text": r.get("text", "").strip(), "segments": segs,
                  "language": r.get("language")})
        except Exception as e:
            send({"error": str(e)})


if __name__ == "__main__":
    main()
