#!/usr/bin/env python3
"""On-demand local learning. Teacher proposals are never automatic ground truth."""
import argparse
import hashlib
import json
import math
import shutil
import subprocess
import sys
import tempfile
import time
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
# Explicit separators preserve compound COCO names and the existing class IDs.
COCO = ['person','bicycle','car','motorcycle','airplane','bus','train','truck','boat','traffic light','fire hydrant','stop sign','parking meter','bench','bird','cat','dog','horse','sheep','cow','elephant','bear','zebra','giraffe','backpack','umbrella','handbag','tie','suitcase','frisbee','skis','snowboard','sports ball','kite','baseball bat','baseball glove','skateboard','surfboard','tennis racket','bottle','wine glass','cup','fork','knife','spoon','bowl','banana','apple','sandwich','orange','broccoli','carrot','hot dog','pizza','donut','cake','chair','couch','potted plant','bed','dining table','toilet','tv','laptop','mouse','remote','keyboard','cell phone','microwave','oven','toaster','sink','refrigerator','book','clock','vase','scissors','teddy bear','hair drier','toothbrush']
SPLITS = ('train', 'val', 'test')


def sha(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as f:
        for block in iter(lambda: f.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def load(path):
    return json.loads(Path(path).read_text())


def write(path, value):
    Path(path).write_text(json.dumps(value, indent=2, allow_nan=False) + '\n')


def require(condition, message):
    if not condition:
        raise ValueError(message)


def aws(*args):
    r = subprocess.run(['aws', '--profile', 'abdul', '--region', 'eu-west-2', '--output', 'json', '--no-cli-pager', *args],
                       capture_output=True, text=True, timeout=120)
    require(r.returncode == 0, 'AWS operation failed; credentials and service errors remain local')
    return json.loads(r.stdout) if r.stdout.strip() else {}


def fetch(args):
    """Review workspace includes all proposals; nothing is approved by fetching."""
    require(0 < args.limit <= 1000, "Review fetch limit must be 1..1000")
    dest = Path(args.output).resolve()
    require(not dest.exists(), 'Output already exists')
    dest.mkdir(mode=0o700, parents=True)
    bucket = 'iseeyou-teacher-data-885625664603-eu-west-2'
    require(aws('sts', 'get-caller-identity')['Account'] == '885625664603', 'Wrong AWS account')
    pages, token = [], None
    while True:
        options = ['--continuation-token', token] if token else []
        page = aws('s3api', 'list-objects-v2', '--bucket', bucket, '--prefix', 'candidates/', *options)
        pages.extend(page.get('Contents', []))
        token = page.get('NextContinuationToken')
        if not token:
            break
    samples = []
    for i, item in enumerate(sorted(pages, key=lambda x: x['LastModified'], reverse=True)[:args.limit]):
        candidate = dest / f'proposal-{i}.json'
        meta = aws('s3api', 'get-object', '--bucket', bucket, '--key', item['Key'], str(candidate))
        doc = load(candidate)
        if doc.get('status') != 'proposed_only':
            continue
        source = doc['source']
        # Synthetic fixtures and explicit mock output never enter the review dataset.
        if source.get('model_version', '').startswith('synthetic') or source.get('frame_id', '').startswith('synthetic'):
            continue
        image = dest / f'image-{i}.jpg'
        aws('s3api', 'get-object', '--bucket', bucket, '--key', source['image_key'],
            '--version-id', source['image_version'], str(image))
        samples.append({'id': f'sample-{i}', 'image': image.name, 'sha256': sha(image),
                        'group': '', 'split': '', 'reviewed_by': '', 'complete_annotation': False,
                        'objects': [], 'source': {'candidate_key': item['Key'], 'candidate_version': meta['VersionId'],
                        'image_key': source['image_key'], 'image_version': source['image_version']},
                        'teacher_proposal': doc['proposal']})
    write(dest / 'review.json', {'schema_version': 1, 'names': COCO, 'samples': samples})
    print(f'{len(samples)} unapproved samples downloaded for review; annotate every visible supported object and assign independent scene/session groups.')


def validate_names(doc):
    names = doc.get('names')
    require(isinstance(names, list) and len(names) >= len(COCO) and names[:len(COCO)] == COCO,
            'The original COCO class IDs must remain unchanged')
    added = names[len(COCO):]
    require(all(isinstance(x, str) and x.strip() == x and 1 <= len(x) <= 100 for x in added),
            'Additional class names must be nonempty reviewed labels')
    require(added == sorted(added, key=str.casefold) and len({x.casefold() for x in names}) == len(names),
            'Additional labels must be unique and sorted alphabetically after the original classes')
    return names


def validate_review(doc, base):
    require(doc.get('schema_version') == 1, 'Unsupported review schema')
    names = validate_names(doc)
    samples = doc.get('samples')
    require(isinstance(samples, list) and samples, 'No reviewed samples')
    groups, hashes, ids, rows = {}, set(), set(), []
    counts = {s: Counter() for s in SPLITS}
    for sample in samples:
        identifier = sample['id']
        require(isinstance(identifier, str) and identifier.replace('-', '').isalnum() and identifier not in ids, 'Invalid/duplicate sample ID')
        ids.add(identifier)
        split, group = sample['split'], sample['group']
        require(split in SPLITS and isinstance(group, str) and group.strip(), 'Assign train/val/test and a scene/session group')
        require(groups.setdefault(group, split) == split, 'Scene/session leakage across splits')
        require(isinstance(sample.get('reviewed_by'), str) and sample['reviewed_by'].strip() and sample.get('complete_annotation') is True,
                'Human reviewer and complete spatial annotations are required')
        require(not sample.get('synthetic', False), 'Synthetic fixtures are not training examples')
        source = sample.get('source', {})
        require(not source.get('mock', False), 'Mock data is excluded')
        image = (base / sample['image']).resolve()
        require(image.is_relative_to(base.resolve()) and image.is_file(), 'Image must be inside review workspace')
        digest = sha(image)
        require(digest == sample['sha256'] and digest not in hashes, 'Changed image or duplicate image across dataset')
        hashes.add(digest)
        objects = sample['objects']
        require(isinstance(objects, list) and len(objects) <= 100, 'Invalid object annotations')
        labels = []
        for obj in objects:
            require(obj.get('label') in names, 'Add newly reviewed classes to the names list, sorted after the existing classes')
            box = obj.get('box')
            require(isinstance(box, list) and len(box) == 4 and all(type(x) in (int, float) and math.isfinite(x) and 0 <= x <= 1 for x in box), 'Expected finite normalized xyxy boxes')
            require(box[0] < box[2] and box[1] < box[3], 'Annotation box must have area')
            labels.append(obj['label'])
        counts[split].update(set(labels))
        rows.append((sample, image))
    # Separate scene groups are the reviewer's responsibility; exact duplicates are also rejected.
    reasons = []
    for split in SPLITS:
        for name in names:
            minimum = {'train': 20, 'val': 5, 'test': 5}[split] if name not in COCO else {'train': 5, 'val': 2, 'test': 3}[split]
            if counts[split][name] < minimum:
                reasons.append(f'{split}/{name}: {counts[split][name]} images, requires {minimum}')
    return rows, reasons


def curate(args):
    path = Path(args.review).resolve()
    doc = load(path)
    rows, reasons = validate_review(doc, path.parent)
    require(not reasons, 'Insufficient reviewed data and historical replay:\n' + '\n'.join(reasons))
    dest = Path(args.output).resolve()
    require(not dest.exists(), 'Dataset output already exists; create a new version')
    with tempfile.TemporaryDirectory(dir=dest.parent, prefix='.dataset-') as temporary:
        stage = Path(temporary)
        names = validate_names(doc)
        for split in SPLITS:
            (stage / 'images' / split).mkdir(parents=True)
            (stage / 'labels' / split).mkdir(parents=True)
        for sample, image in rows:
            stem, split = sample['id'], sample['split']
            require(image.suffix.lower() in ('.jpg', '.jpeg', '.png'), 'Expected JPEG/PNG')
            shutil.copyfile(image, stage / 'images' / split / (stem + image.suffix.lower()))
            lines = []
            for obj in sample['objects']:
                x1, y1, x2, y2 = obj['box']
                lines.append(f'{names.index(obj["label"])} {(x1+x2)/2:.9f} {(y1+y2)/2:.9f} {x2-x1:.9f} {y2-y1:.9f}')
            (stage / 'labels' / split / (stem + '.txt')).write_text('\n'.join(lines) + '\n')
        write(stage / 'review.json', doc)
        # JSON is valid YAML; validation never uses the held-out test split for fitting.
        write(stage / 'data.yaml', {'path': str(dest), 'train': 'images/train', 'val': 'images/val', 'test': 'images/test', 'names': dict(enumerate(names))})
        files = {str(p.relative_to(stage)): sha(p) for p in sorted(stage.rglob('*')) if p.is_file()}
        write(stage / 'dataset.json', {'schema_version': 1, 'files': files, 'review_sha256': sha(path)})
        shutil.copytree(stage, dest)
    print(f'Versioned dataset ready: {dest}')


def check_dataset(path):
    path = Path(path).resolve()
    manifest = load(path / 'dataset.json')
    require(manifest.get('schema_version') == 1, 'Invalid dataset manifest')
    expected = manifest['files']
    require(set(expected) == {str(p.relative_to(path)) for p in path.rglob('*') if p.is_file()} - {'dataset.json'}, 'Dataset files changed')
    for name, digest in expected.items():
        file = (path / name).resolve()
        require(file.is_relative_to(path) and sha(file) == digest, 'Dataset checksum mismatch')
    return path, sha(path / 'dataset.json')


def train(args):
    require(1 <= args.epochs <= 100, 'Epoch count must be 1..100')
    dataset, digest = check_dataset(args.dataset)
    require(shutil.disk_usage(dataset).free >= 5 * 1024**3, 'Need at least 5 GiB free for training/export; no cleanup is automatic')
    dest = Path(args.output).resolve()
    require(not dest.exists(), 'Run output already exists')
    from ultralytics import YOLO
    model = YOLO(str(ROOT / 'models/yolo11n.pt'))
    require(list(model.names.values()) == COCO, 'Baseline class IDs do not match')
    # Ultralytics creates label caches. Fit in a run-local copy so the curated dataset stays immutable.
    dest.mkdir(parents=True)
    training_data = dest / 'data'
    shutil.copytree(dataset, training_data)
    config = load(training_data / 'data.yaml'); config['path'] = str(training_data)
    write(training_data / 'data.yaml', config)
    # CPU is explicit: this command never provisions cloud resources or silently uses a GPU.
    model.train(data=str(training_data / 'data.yaml'), epochs=args.epochs, imgsz=640, batch=4, workers=0,
                device='cpu', seed=2026, deterministic=True, project=str(dest), name='fit', exist_ok=False,
                pretrained=True, plots=False)
    checkpoint = dest / 'fit/weights/best.pt'
    require(checkpoint.is_file(), 'Training did not produce a best checkpoint')
    packages = subprocess.run([sys.executable, '-m', 'pip', 'freeze'], capture_output=True, text=True, check=True).stdout
    (dest / 'requirements-lock.txt').write_text(packages)
    write(dest / 'run.json', {'dataset_sha256': digest, 'checkpoint_sha256': sha(checkpoint),
                            'baseline_sha256': sha(ROOT / 'models/yolo11n.pt'), 'epochs': args.epochs, 'seed': 2026, 'device': 'cpu'})
    print('Training complete; candidate is not approved or installed')


def iou(a, b):
    area = max(0, min(a[2], b[2])-max(a[0], b[0])) * max(0, min(a[3], b[3])-max(a[1], b[1]))
    return area / max(1e-12, (a[2]-a[0])*(a[3]-a[1])+(b[2]-b[0])*(b[3]-b[1])-area)


def metrics(truth, predictions, names=COCO):
    result = {}
    for name in names:
        gt = {k: [o['box'] for o in v if o['label'] == name] for k, v in truth.items()}
        n = sum(map(len, gt.values()))
        detections = sorted([(p['confidence'], key, p['box']) for key, values in predictions.items() for p in values if p['label'] == name], reverse=True)
        matched, tp, fp, points = set(), 0, 0, []
        for score, key, box in detections:
            candidates = [(iou(box, b), i) for i, b in enumerate(gt.get(key, [])) if (key, i) not in matched]
            best = max(candidates, default=(0, -1))
            if best[0] >= 0.5:
                matched.add((key, best[1])); tp += 1
            else:
                fp += 1
            points.append((tp / max(n, 1), tp / (tp + fp)))
        # Standard 101-point interpolated AP at IoU .5; fixed inference floor .001.
        ap = sum(max((p for r, p in points if r >= threshold / 100), default=0) for threshold in range(101)) / 101
        # User-visible precision/recall at the app's default .4 threshold.
        high = [d for d in detections if d[0] >= 0.4]
        used, true = set(), 0
        for _, key, box in high:
            best = max(((iou(box, b), i) for i, b in enumerate(gt.get(key, [])) if (key, i) not in used), default=(0, -1))
            if best[0] >= 0.5:
                used.add((key, best[1])); true += 1
        result[name] = {'ap50': ap, 'recall': true / max(n, 1), 'precision': true / max(len(high), 1), 'support': n}
    return result


def gate(baseline, candidate, names):
    failures = []
    for name in names:
        a, b = baseline[name], candidate[name]
        require(all(type(row.get(k)) in (int, float) and math.isfinite(row[k]) and 0 <= row[k] <= 1 for row in (a, b) for k in ('ap50', 'recall', 'precision')), 'Nonfinite or invalid evaluation metric')
        is_new = name not in COCO
        if b['support'] < (5 if is_new else 3):
            failures.append('missing held-out support: ' + name)
        if not is_new and (b['ap50'] < a['ap50'] - .03 or b['recall'] < a['recall'] - .03 or b['precision'] < a['precision'] - .03):
            failures.append('regression: ' + name)
        if is_new and (b['ap50'] < .5 or b['recall'] < .6 or b['precision'] < .8 or b['ap50'] <= a['ap50']):
            failures.append('new-class quality/improvement gate failed: ' + name)
    return failures


def predict(model, dataset, rows):
    out = {}
    for sample in rows:
        image = next((dataset / 'images/test').glob(sample['id'] + '.*'))
        r = model.predict(str(image), imgsz=640, conf=.001, iou=.7, device='cpu', verbose=False)[0]
        out[sample['id']] = [{'label': r.names[int(c)], 'confidence': float(score), 'box': list(map(float, box))}
                             for c, score, box in zip(r.boxes.cls.tolist(), r.boxes.conf.tolist(), r.boxes.xyxyn.tolist())]
    return out


def evaluate(args):
    dataset, digest = check_dataset(args.dataset)
    checkpoint = Path(args.checkpoint).resolve()
    from ultralytics import YOLO
    candidate = YOLO(str(checkpoint))
    review = load(dataset / 'review.json')
    names = validate_names(review)
    require(list(candidate.names.values()) == names, 'Candidate class IDs do not match the reviewed dataset')
    rows = [s for s in review['samples'] if s['split'] == 'test']
    truth = {s['id']: s['objects'] for s in rows}
    baseline = metrics(truth, predict(YOLO(str(ROOT / 'models/yolo11n.pt')), dataset, rows), names)
    proposed = metrics(truth, predict(candidate, dataset, rows), names)
    failures = gate(baseline, proposed, names)
    require(not Path(args.output).exists(), 'Evaluation output already exists')
    write(args.output, {'schema_version': 1, 'names': names, 'dataset_sha256': digest, 'checkpoint_sha256': sha(checkpoint),
                       'baseline_sha256': sha(ROOT / 'models/yolo11n.pt'), 'baseline': baseline, 'candidate': proposed,
                       'failures': failures, 'quality_passed': not failures,
                       'deployment_approved': False, 'note': 'Object-label benchmark only; physical CoreML performance and safety signoff still required'})
    print('Quality passed; device verification still required' if not failures else 'Candidate rejected: ' + '; '.join(failures))
    return 0 if not failures else 2


def export(args):
    report, checkpoint = load(args.evaluation), Path(args.checkpoint)
    require(report.get('quality_passed') is True and not report.get('failures'), 'Evaluation did not pass')
    require(report['checkpoint_sha256'] == sha(checkpoint), 'Checkpoint differs from evaluated candidate')
    dest = Path(args.output).resolve()
    require(not dest.exists(), 'Export destination already exists')
    require(not checkpoint.with_suffix('.mlpackage').exists(), 'Internal export package already exists; use a fresh candidate checkpoint directory')
    from ultralytics import YOLO
    model = YOLO(str(checkpoint))
    names = report.get('names')
    require(isinstance(names, list) and list(model.names.values()) == names, 'Unexpected class mapping')
    package = Path(model.export(format='coreml', imgsz=640, nms=True, half=True, device='cpu', conf=.001))
    shutil.copytree(package, dest)
    files = package_files(dest)
    write(dest.parent / (dest.name + '.evaluation.json'), {'evaluation_sha256': sha(args.evaluation),
            'checkpoint_sha256': sha(checkpoint), 'files': files, 'quality_passed': True})
    print('CoreML candidate exported; physical-device evidence is required before signing/delivery')


def package_files(package):
    require(package.is_dir() and package.suffix == '.mlpackage', 'Expected .mlpackage directory')
    require(not any(p.is_symlink() for p in package.rglob('*')), 'Symlinks are forbidden')
    return [{'path': str(p.relative_to(package)), 'size': p.stat().st_size, 'sha256': sha(p)}
            for p in sorted(package.rglob('*')) if p.is_file()]


def stage_validation(args):
    """A shadow-only handoff; this directory cannot be loaded by the live detector."""
    package = Path(args.package).resolve()
    files = package_files(package)
    dataset, digest = check_dataset(args.dataset)
    evidence = load(package.parent / (package.name + '.evaluation.json'))
    require(evidence['files'] == files and evidence['quality_passed'] is True, 'Candidate export changed or failed quality gates')
    with tempfile.TemporaryDirectory(prefix='iseeyou-validation-') as temp:
        stage = Path(temp) / 'ModelValidation'; stage.mkdir()
        shutil.copytree(package, stage / 'candidate.mlpackage')
        test = dataset / 'images/test'
        shutil.copytree(test, stage / 'images')
        rows = [s for s in load(dataset / 'review.json')['samples'] if s['split'] == 'test']
        write(stage / 'benchmark.json', {'dataset_sha256': digest, 'images': [next(test.glob(s['id'] + '.*')).name for s in rows]})
        subprocess.run(['xcrun', 'devicectl', 'device', 'copy', 'to', '--device', args.device, '--source', str(stage),
                        '--destination', 'Documents/ModelValidation', '--domain-type', 'appDataContainer',
                        '--domain-identifier', 'com.iseeyou.research'], check=True)
    digest = hashlib.sha256(json.dumps(files, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    print('Shadow benchmark staged; run UnitChecks/DetectorModelStoreTests/testStagedCandidateBenchmark on the physical phone.')
    print('Package files SHA256 for device report: ' + digest)
    print('Measurements do not approve recognition, thermal, battery, camera alignment or speech checks.')


def release(args):
    package, report = Path(args.package).resolve(), load(args.device_report)
    evidence = load(package.parent / (package.name + '.evaluation.json'))
    files = package_files(package)
    require(files == evidence['files'] and evidence['quality_passed'] is True, 'Export changed since evaluation')
    require(report.get('package_files_sha256') == hashlib.sha256(json.dumps(files, sort_keys=True, separators=(',', ':')).encode()).hexdigest(), 'Device report must identify exact package files')
    require(report.get('reviewed_by') and report.get('physical_device') is True and report.get('duration_seconds', 0) >= 300,
            'Physical device identity, reviewer and at least five minutes of observation required')
    for name in ('coreml_label_parity', 'camera_alignment', 'speech_regression', 'rollback_tested', 'thermal_acceptable', 'battery_acceptable', 'recognition_accepted'):
        require(report.get(name) is True, 'Missing device check: ' + name)
    require(type(report.get('fps')) in (int, float) and math.isfinite(report['fps']) and report['fps'] >= 10, 'Physical throughput must be >=10 FPS')
    require(type(report.get('p95_inference_ms')) in (int, float) and math.isfinite(report['p95_inference_ms']) and 0 < report['p95_inference_ms'] <= 500, 'Physical p95 inference must be <=500ms')
    require(args.version.replace('-', '').isalnum() and len(args.version) <= 80, 'Invalid version')
    dest = Path(args.output).resolve()
    require(not dest.exists(), 'Release output exists; versions are immutable')
    require(len(files) <= 64 and sum(f['size'] for f in files) <= 100_000_000, 'Release exceeds device limits')
    dest.mkdir(parents=True, mode=0o700)
    shutil.copytree(package, dest / 'candidate.mlpackage')
    payload = {'schema_version': 1, 'version': args.version, 'files': files, 'evaluation_sha256': evidence['evaluation_sha256'],
               'device_report_sha256': sha(args.device_report)}
    write(dest / 'payload.json', payload)
    subprocess.run(['swift', str(ROOT / 'scripts/learning/sign.swift'), 'sign', args.key, str(dest / 'payload.json'), str(dest / 'release.json')], check=True)
    print('Signed staged release ready. Delivery never starts camera capture.')


def deliver(args):
    release_dir = Path(args.release).resolve()
    require((release_dir / 'release.json').is_file() and (release_dir / 'candidate.mlpackage').is_dir(), 'Not a signed release directory')
    subprocess.run(['xcrun', 'devicectl', 'device', 'copy', 'to', '--device', args.device,
                    '--source', str(release_dir), '--destination', 'Documents/ModelUpdate',
                    '--domain-type', 'appDataContainer', '--domain-identifier', 'com.iseeyou.research'], check=True)
    print('Staged on iPhone. Relaunch while stopped to verify/compile; camera never starts automatically. Roll back using Use bundled detector.')


def publish(args):
    """Publish an already signed, physically reviewed release for phone pull."""
    release_dir = Path(args.release).resolve()
    release_file, payload_file = release_dir / 'release.json', release_dir / 'payload.json'
    package = release_dir / 'candidate.mlpackage'
    require(release_file.is_file() and payload_file.is_file() and package.is_dir(), 'Expected a signed release directory')
    subprocess.run(['swift', str(ROOT / 'scripts/learning/sign.swift'), 'verify',
                    str(ROOT / 'ISeeYou/ModelSigningPublicKey.txt'), str(release_file), str(payload_file)], check=True)
    payload = load(payload_file)
    version = payload.get('version', '')
    require(isinstance(version, str) and version.replace('-', '').isalnum() and 1 <= len(version) <= 80,
            'Invalid release version')
    files = package_files(package)
    require(files == payload.get('files'), 'Package does not match the signed inventory')
    require(len(files) <= 64 and sum(row['size'] for row in files) <= 100_000_000, 'Release exceeds phone limits')
    require(aws('sts', 'get-caller-identity')['Account'] == '885625664603', 'Wrong AWS account')
    bucket = 'iseeyou-teacher-data-885625664603-eu-west-2'
    prefix = f'learning/releases/{version}'
    # Release versions are immutable. The pointer only moves after every file
    # and the signed envelope are stored successfully.
    for row in files:
        key = f"{prefix}/candidate.mlpackage/{row['path']}"
        aws('s3api', 'put-object', '--bucket', bucket, '--key', key, '--body', str(package / row['path']),
            '--server-side-encryption', 'AES256', '--if-none-match', '*', '--content-type', 'application/octet-stream')
    release_key = prefix + '/release.json'
    aws('s3api', 'put-object', '--bucket', bucket, '--key', release_key, '--body', str(release_file),
        '--server-side-encryption', 'AES256', '--if-none-match', '*', '--content-type', 'application/json')
    record = {'id': {'S': 'model-release#' + version}, 'version': {'S': version}, 'release_key': {'S': release_key},
              'file_count': {'N': str(len(files))}, 'published_at': {'S': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}}
    aws('dynamodb', 'put-item', '--table-name', 'iseeyou-teacher-uploads', '--item', json.dumps(record),
        '--condition-expression', 'attribute_not_exists(id)')
    latest = {'id': {'S': 'model-release#latest'}, 'version': {'S': version}, 'release_key': {'S': release_key}}
    aws('dynamodb', 'put-item', '--table-name', 'iseeyou-teacher-uploads', '--item', json.dumps(latest))
    print('Signed model release published. It is staged on phones after download and still requires explicit installation.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    p = sub.add_parser('fetch'); p.add_argument('--output', required=True); p.add_argument('--limit', type=int, default=100)
    p = sub.add_parser('curate'); p.add_argument('--review', required=True); p.add_argument('--output', required=True)
    p = sub.add_parser('train'); p.add_argument('--dataset', required=True); p.add_argument('--output', required=True); p.add_argument('--epochs', type=int, default=30)
    p = sub.add_parser('evaluate'); p.add_argument('--dataset', required=True); p.add_argument('--checkpoint', required=True); p.add_argument('--output', required=True)
    p = sub.add_parser('export'); p.add_argument('--evaluation', required=True); p.add_argument('--checkpoint', required=True); p.add_argument('--output', required=True)
    p = sub.add_parser('stage-validation'); p.add_argument('--package', required=True); p.add_argument('--dataset', required=True); p.add_argument('--device', required=True)
    p = sub.add_parser('release'); p.add_argument('--package', required=True); p.add_argument('--device-report', required=True); p.add_argument('--version', required=True); p.add_argument('--key', required=True); p.add_argument('--output', required=True)
    p = sub.add_parser('deliver'); p.add_argument('--release', required=True); p.add_argument('--device', required=True)
    p = sub.add_parser('publish'); p.add_argument('--release', required=True)
    args = parser.parse_args()
    try:
        return globals()[args.command.replace('-', '_')](args) or 0
    except (ValueError, KeyError, OSError, subprocess.SubprocessError) as exc:
        print(str(exc), file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
