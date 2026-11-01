"""SageMaker entry point: train a private shadow YOLO checkpoint from Nova pseudo-labels."""
import hashlib
import json
import os
import shutil
from pathlib import Path


def overlap(a, b):
    area = max(0, min(a[2], b[2]) - max(a[0], b[0])) * max(0, min(a[3], b[3]) - max(a[1], b[1]))
    union = max(0, a[2]-a[0]) * max(0, a[3]-a[1]) + max(0, b[2]-b[0]) * max(0, b[3]-b[1]) - area
    return area / max(union, 1e-12)


def class_metrics(truth, predictions, names):
    metrics = {}
    for name in names:
        ground = {key: [obj['box'] for obj in rows if obj['label'].casefold() == name.casefold()]
                  for key, rows in truth.items()}
        support = sum(map(len, ground.values()))
        detections = sorted(((row['confidence'], key, row['box']) for key, rows in predictions.items()
                             for row in rows if row['label'].casefold() == name.casefold()), reverse=True)
        matched, tp, fp, curve = set(), 0, 0, []
        for confidence, key, box in detections:
            options = [(overlap(box, target), index) for index, target in enumerate(ground.get(key, [])) if (key, index) not in matched]
            score, index = max(options, default=(0, -1))
            if score >= .5:
                matched.add((key, index)); tp += 1
            else:
                fp += 1
            curve.append((tp / max(support, 1), tp / max(tp + fp, 1)))
        ap50 = sum(max((precision for recall, precision in curve if recall >= point / 100), default=0)
                   for point in range(101)) / 101
        visible = [item for item in detections if item[0] >= .4]
        matched, true = set(), 0
        for _, key, box in visible:
            options = [(overlap(box, target), index) for index, target in enumerate(ground.get(key, [])) if (key, index) not in matched]
            score, index = max(options, default=(0, -1))
            if score >= .5:
                matched.add((key, index)); true += 1
        metrics[name] = {'support': support, 'ap50': ap50,
                         'precision': true / max(len(visible), 1), 'recall': true / max(support, 1)}
    return metrics


def predict(model, dataset, frames, names, device):
    import hashlib
    by_id = {row['frame_id']: row for row in frames}
    image_paths = [dataset / 'images' / 'test' / (hashlib.sha256(frame_id.encode()).hexdigest()[:24] + '.jpg')
                   for frame_id in by_id]
    predictions = {}
    class_map = {int(index): str(label) for index, label in model.names.items()} if isinstance(model.names, dict) else dict(enumerate(model.names))
    for frame_id, image_path, result in zip(by_id, image_paths,
            model.predict([str(path) for path in image_paths], imgsz=640, conf=.001, iou=.7, device=device, verbose=False)):
        rows = []
        for class_id, confidence, box in zip(result.boxes.cls.tolist(), result.boxes.conf.tolist(), result.boxes.xyxyn.tolist()):
            label = class_map.get(int(class_id))
            if label and label.casefold() in {name.casefold() for name in names}:
                rows.append({'label': label, 'confidence': float(confidence), 'box': list(map(float, box))})
        predictions[frame_id] = rows
    return predictions


def evaluate_shadow(baseline, candidate, manifest, dataset, names):
    frames = [row for row in manifest['frames'] if row['split'] == 'test']
    truth = {row['frame_id']: row['objects'] for row in frames}
    baseline_metrics = class_metrics(truth, predict(baseline, dataset, frames, names, 0), names)
    candidate_metrics = class_metrics(truth, predict(candidate, dataset, frames, names, 0), names)
    original = {name.casefold() for name in baseline.names.values()} if isinstance(baseline.names, dict) else {str(x).casefold() for x in baseline.names}
    failures = []
    for name in names:
        before, after = baseline_metrics[name], candidate_metrics[name]
        if after['support'] < (5 if name.casefold() not in original else 3):
            failures.append('insufficient_test_support:' + name)
        elif name.casefold() not in original:
            if after['ap50'] < .5 or after['recall'] < .6 or after['precision'] < .8 or after['ap50'] <= before['ap50']:
                failures.append('new_class_gate:' + name)
        elif any(after[key] < before[key] - .03 for key in ('ap50', 'precision', 'recall')):
            failures.append('existing_class_regression:' + name)
    return {'split': 'test', 'annotation_source': 'nova_pseudo_labels', 'dataset_sha256': hashlib.sha256(
                json.dumps(manifest, sort_keys=True, separators=(',', ':')).encode()).hexdigest(),
            'test_frames': [{'frame_id': row['frame_id'], 'image_key': row['image_key'],
                             'image_version': row['image_version']} for row in frames],
            'baseline': baseline_metrics,
            'candidate': candidate_metrics, 'failures': failures, 'passed': not failures}


def main():
    import boto3
    import yaml
    from ultralytics import YOLO

    hps = json.loads(os.environ.get('SM_HPS', '{}'))
    bucket = os.environ['BUCKET']
    session_id = hps['session_id']
    job_name = hps['job_name']
    training_dir = Path(os.environ.get('SM_CHANNEL_TRAINING', '/opt/ml/input/data/training'))
    manifest_path = next(training_dir.glob('*.json'))
    manifest = json.loads(manifest_path.read_text())
    s3 = boto3.client('s3')
    work = Path('/opt/ml/tmp/iseeyou-yolo')
    work.mkdir(parents=True, exist_ok=True)
    dataset = work / 'dataset'
    names = manifest['names']
    name_to_id = {name: i for i, name in enumerate(names)}
    for split in ('train', 'val', 'test'):
        (dataset / 'images' / split).mkdir(parents=True, exist_ok=True)
        (dataset / 'labels' / split).mkdir(parents=True, exist_ok=True)
    rows = []
    for row in manifest['frames']:
        stem = hashlib.sha256(row['frame_id'].encode()).hexdigest()[:24]
        image = dataset / 'images' / row['split'] / (stem + '.jpg')
        s3.download_file(bucket, row['image_key'], str(image), ExtraArgs={'VersionId': row['image_version']})
        labels = []
        for obj in row['objects']:
            label = obj['label']
            class_id = name_to_id.get(label)
            if class_id is None:
                class_id = next((i for name, i in name_to_id.items() if name.casefold() == label.casefold()), None)
            if class_id is None:
                continue
            x1, y1, x2, y2 = obj['box']
            labels.append(f'{class_id} {(x1+x2)/2:.8f} {(y1+y2)/2:.8f} {x2-x1:.8f} {y2-y1:.8f}')
        (dataset / 'labels' / row['split'] / (stem + '.txt')).write_text('\n'.join(labels) + ('\n' if labels else ''))
        rows.append({'frame_id': row['frame_id'], 'group': row['group'], 'split': row['split']})
    config = {'path': str(dataset), 'train': 'images/train', 'val': 'images/val', 'test': 'images/test', 'names': names}
    data_yaml = work / 'data.yaml'
    data_yaml.write_text(yaml.safe_dump(config, sort_keys=False))
    checkpoint = work / 'baseline.pt'
    baseline = hps['baseline_uri'].removeprefix('s3://' + bucket + '/')
    s3.download_file(bucket, baseline, str(checkpoint))
    model = YOLO(str(checkpoint))
    fit_dir = work / 'fit'
    model.train(data=str(data_yaml), epochs=int(hps.get('epochs', '10')), imgsz=640, batch=2, workers=2,
                device=0, seed=2026, deterministic=True, project=str(work), name='fit', exist_ok=False,
                pretrained=True, plots=False, cache=False)
    best = fit_dir / 'weights' / 'best.pt'
    if not best.is_file():
        raise RuntimeError('SageMaker training produced no candidate checkpoint')
    baseline_model = YOLO(str(checkpoint))
    candidate_model = YOLO(str(best))
    evaluation = evaluate_shadow(baseline_model, candidate_model, manifest, dataset, names)
    if not evaluation['passed']:
        boto3.client('dynamodb').update_item(TableName=os.environ['TABLE'], Key={'id': {'S': 'session#' + session_id}},
            UpdateExpression='SET #s = :s, evaluation_status = :e, evaluation_failures = :f',
            ExpressionAttributeNames={'#s': 'status'}, ExpressionAttributeValues={
                ':s': {'S': 'evaluation_rejected'}, ':e': {'S': 'rejected'},
                ':f': {'S': json.dumps(evaluation['failures'])[:2000]}})
        raise RuntimeError('YOLO candidate failed held-out pseudo-label evaluation gates')
    output = Path(os.environ.get('SM_MODEL_DIR', '/opt/ml/model'))
    output.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(best, output / 'yolo-pseudo-candidate.pt')
    (output / 'evaluation.json').write_text(json.dumps(evaluation, allow_nan=False, indent=2) + '\n')
    coreml_package = Path(candidate_model.export(format='coreml', imgsz=640, nms=True, quantize=16, device='cpu', conf=.001))
    shutil.copytree(coreml_package, output / 'candidate.mlpackage')
    digest = hashlib.sha256((output / 'yolo-pseudo-candidate.pt').read_bytes()).hexdigest()
    (output / 'provenance.json').write_text(json.dumps({
        'session_id': session_id, 'dataset_sha256': hashlib.sha256(manifest_path.read_bytes()).hexdigest(),
        'checkpoint_sha256': digest, 'annotation_source': 'nova_pseudo_labels', 'evaluation_passed': True,
        'model_promoted': False,
        'grouped_splits': rows, 'ultralytics_version': __import__('ultralytics').__version__}, indent=2) + '\n')
    try:
        db = boto3.client('dynamodb')
        db.update_item(TableName=os.environ['TABLE'], Key={'id': {'S': 'session#' + session_id}},
            UpdateExpression='SET #s = :s, model_uri = :u, evaluation_status = :e', ExpressionAttributeNames={'#s': 'status'},
            ExpressionAttributeValues={':s': {'S': 'training_complete'},
            ':u': {'S': f"s3://{bucket}/learning/models/{job_name}/output/model.tar.gz"}, ':e': {'S': 'passed'}})
    except Exception:
        print('Could not update the session receipt; training artifact remains in the SageMaker output bucket.')


if __name__ == '__main__':
    main()
