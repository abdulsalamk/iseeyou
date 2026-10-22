"""Convert the official MIT-licensed CLIP image tower for the door experiment.

PYTHONPATH must include the pinned official openai/CLIP checkout. No camera
data is used by this script. This is conversion, not door-state training.
"""
import argparse
import json
from pathlib import Path
import numpy as np
import torch
import clip
import coremltools as ct
import coremltools.optimize.coreml as cto

class ImageTower(torch.nn.Module):
    def __init__(self, visual):
        super().__init__()
        self.visual = visual
        self.register_buffer("mean", torch.tensor([0.48145466, 0.4578275, 0.40821073]).view(1,3,1,1))
        self.register_buffer("std", torch.tensor([0.26862954, 0.26130258, 0.27577711]).view(1,3,1,1))
    def forward(self, image):
        return self.visual((image - self.mean) / self.std)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    torch.set_num_threads(4)
    torch.backends.mha.set_fastpath_enabled(False)
    source, _ = clip.load(str(args.checkpoint), device="cpu", jit=False)
    wrapper = ImageTower(source.visual.float()).eval()
    torch.manual_seed(17)
    sample = torch.rand(1,3,224,224)
    with torch.no_grad():
        traced = torch.jit.trace(wrapper, sample)
    model = ct.convert(traced, source="pytorch", convert_to="mlprogram",
        inputs=[ct.ImageType(name="image", shape=sample.shape, scale=1/255)],
        outputs=[ct.TensorType(name="imageEmbedding")],
        minimum_deployment_target=ct.target.iOS17,
        compute_precision=ct.precision.FLOAT16)
    config = cto.OptimizationConfig(global_config=cto.OpLinearQuantizerConfig(
        mode="linear_symmetric", dtype=np.int8, weight_threshold=2048))
    model = cto.linear_quantize_weights(model, config=config)
    model.short_description = "Experimental CLIP ViT-B/32 image tower; not a trained door detector"
    model.license = "MIT; see models/licenses/CLIP-Model-MIT.txt"
    model.user_defined_metadata["source"] = "https://github.com/openai/CLIP"
    model.user_defined_metadata["source_commit"] = "d05afc436d78f1c48dc0dbf8e5980a9d471f35f6"
    args.output.parent.mkdir(parents=True, exist_ok=True)
    model.save(str(args.output))
    # Conversion-only parity: quantized Core ML and PyTorch on the same pixels.
    from PIL import Image
    comparisons=[]
    for seed in [1,2,3]:
        array=np.random.default_rng(seed).integers(0,256,(224,224,3),dtype=np.uint8)
        image=Image.fromarray(array)
        tensor=torch.from_numpy(array.copy()).permute(2,0,1).unsqueeze(0).float()/255
        with torch.no_grad(): expected=wrapper(tensor).numpy().reshape(-1)
        actual=model.predict({"image":image})["imageEmbedding"].reshape(-1)
        similarity=float(np.dot(expected,actual)/(np.linalg.norm(expected)*np.linalg.norm(actual)))
        comparisons.append({"seed":seed,"cosine":similarity})
        assert np.isfinite(actual).all() and similarity > .99
    (args.output.parent.parent.parent/"models"/"door-conversion-parity.json").write_text(json.dumps(comparisons,indent=2)+"\n")
    print("Saved",args.output,comparisons,flush=True)

if __name__ == "__main__": main()
