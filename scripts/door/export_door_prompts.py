"""Build fixed text embeddings with the matching official OpenAI CLIP encoder.

Run with the existing model environment. Camera images never leave the phone;
only these fixed public phrases are processed during preparation.
"""
import argparse
import hashlib
import json
from pathlib import Path
import numpy as np
import torch
import clip
from simple_tokenizer import SimpleTokenizer

PROMPTS = {
    "closed": ["a photo of a closed indoor door", "an interior doorway with the door shut", "a closed door blocking the doorway"],
    "partlyOpen": ["a photo of a partly open indoor door", "an interior door left ajar", "a half open door in its doorway"],
    "open": ["a photo of a fully open indoor door", "an open doorway with the door swung open", "a doorway with the door open to the side"],
    "wall": ["a photo of a blank wall", "an indoor wall with no doorway"],
    "window": ["a photo of an indoor window", "a window in a wall"],
    "cabinet": ["a photo of a cupboard with cabinet doors", "a wardrobe or kitchen cabinet"],
    "mirror": ["a photo of a mirror on a wall", "a bathroom mirror"],
    "screen": ["a television or computer screen", "a framed picture on a wall"],
    "room": ["a photo of a room with furniture", "a photo of a corridor with no visible door"],
    "curtain": ["a curtain covering a window", "a photo of a hanging curtain"],
}

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    model, _ = clip.load(str(args.checkpoint), device="cpu", jit=False)
    model.eval()
    tokenizer = SimpleTokenizer()
    groups = []
    for key, prompts in PROMPTS.items():
        vectors = []
        for prompt in prompts:
            tokens = [tokenizer.encoder['<|startoftext|>']] + tokenizer.encode(prompt) + [tokenizer.encoder['<|endoftext|>']]
            values = np.zeros((1, 77), dtype=np.int32)
            values[0, :len(tokens)] = tokens
            with torch.no_grad():
                vector = model.encode_text(torch.from_numpy(values).long()).numpy().reshape(-1).astype(float)
            vector /= np.linalg.norm(vector)
            vectors.append(vector)
        average = np.mean(vectors, axis=0)
        average /= np.linalg.norm(average)
        groups.append({"label": key, "prompts": prompts, "embedding": average.tolist()})
        print(key, len(average), flush=True)
    manifest = {"model": "openai/CLIP", "revision": "d05afc436d78f1c48dc0dbf8e5980a9d471f35f6",
                "variant": "ViT-B/32", "purpose": "Experimental zero-shot door scene comparison; not door-specific training", "groups": groups}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(manifest, indent=2) + "\n")
    print("sha256", hashlib.sha256(args.output.read_bytes()).hexdigest())

if __name__ == "__main__":
    main()
