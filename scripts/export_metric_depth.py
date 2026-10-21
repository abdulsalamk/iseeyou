"""Export official Hypersim Small metric depth to fixed portrait Core ML.
Python 3.11; see requirements-depth.txt and docs/DEPTH_PLAN.md.
"""
import argparse, sys, pathlib, json, hashlib, types
import numpy as np
import torch
import coremltools as ct
p = argparse.ArgumentParser()
p.add_argument('--source', required=True)
p.add_argument('--checkpoint', required=True)
p.add_argument('--output', required=True)
a = p.parse_args()
sys.path.insert(0, str(pathlib.Path(a.source) / 'metric_depth'))
from depth_anything_v2.dpt import DepthAnythingV2

torch.set_num_threads(4)
model = DepthAnythingV2(encoder='vits', features=64, out_channels=[48,96,192,384], max_depth=20)
model.load_state_dict(torch.load(a.checkpoint, map_location='cpu', weights_only=True))
model.eval()
# The export has one fixed portrait size. Precompute the exact upstream bicubic
# position embedding once; Core ML need not execute unsupported bicubic resize.
with torch.no_grad():
    tokens = torch.zeros(1, 21 * 37 + 1, model.pretrained.embed_dim)
    position = model.pretrained.interpolate_pos_encoding(tokens, 518, 294)
original_position = model.pretrained.interpolate_pos_encoding
model.pretrained.register_buffer('portrait_position', position)
def fixed_position(self, x, w, h): return self.portrait_position
model.pretrained.interpolate_pos_encoding = types.MethodType(fixed_position, model.pretrained)
class PortraitMetric(torch.nn.Module):
    def __init__(self, network):
        super().__init__(); self.network=network
        self.register_buffer('mean', torch.tensor([.485,.456,.406]).reshape(1,3,1,1))
        self.register_buffer('std', torch.tensor([.229,.224,.225]).reshape(1,3,1,1))
    def forward(self, image):
        return self.network((image-self.mean)/self.std)
wrapped=PortraitMetric(model).eval()
example=torch.rand(1,3,518,294)
with torch.no_grad(): traced=torch.jit.trace(wrapped, example)
converted=ct.convert(traced, inputs=[ct.ImageType(name='image',shape=example.shape,scale=1/255)],
    outputs=[ct.TensorType(name='depthMetres')], convert_to='mlprogram',
    minimum_deployment_target=ct.target.iOS17, compute_precision=ct.precision.FLOAT16)
converted.short_description='Depth Anything V2 Small Metric Hypersim; experimental indoor depth in metres'
converted.license='Apache-2.0'
converted.user_defined_metadata['checkpoint_sha256']=hashlib.sha256(pathlib.Path(a.checkpoint).read_bytes()).hexdigest()
converted.user_defined_metadata['input_transform']='RGB / 255, ImageNet normalization inside model; portrait 294x518 full-frame resize'
converted.save(a.output)
print('SAVED',a.output,flush=True)
# Conversion parity on deterministic structured RGB patterns, independent of physical accuracy.
from PIL import Image
errors=[]
model.pretrained.interpolate_pos_encoding = original_position
patterns = [(f'random-{seed}', np.random.default_rng(seed).integers(0,256,(518,294,3), dtype=np.uint8)) for seed in range(3)]
for path in sorted((pathlib.Path(a.source)/'assets/examples').glob('*.jpg'))[:3]:
    patterns.append((path.name, np.asarray(Image.open(path).convert('RGB').resize((294,518), Image.Resampling.BICUBIC))))
for name, rgb in patterns:
    tensor=torch.from_numpy(rgb.copy()).permute(2,0,1).unsqueeze(0).float()/255
    with torch.no_grad(): reference=wrapped(tensor).numpy()
    actual=converted.predict({'image':Image.fromarray(rgb)})['depthMetres']
    delta=np.abs(reference-actual)
    errors.append({'input':name, 'median_absolute_metres':float(np.median(delta)), 'max_absolute_metres':float(delta.max()),'finite':bool(np.isfinite(actual).all()),'shape':list(actual.shape)})
pathlib.Path(a.output).with_suffix('.parity.json').write_text(json.dumps(errors,indent=2))
print(errors,flush=True)
