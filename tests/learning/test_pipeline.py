import copy
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch, Mock
from argparse import Namespace
from types import SimpleNamespace
import sys

spec = importlib.util.spec_from_file_location('pipeline', Path(__file__).parents[2] / 'scripts/learning/pipeline.py')
p = importlib.util.module_from_spec(spec); spec.loader.exec_module(p)

class LearningTests(unittest.TestCase):
    def sample(self, folder, index=0, split='train', group='scene-a'):
        image = folder / f'{index}.jpg'; image.write_bytes(b'fixture' + str(index).encode())
        return {'id': f'sample-{index}', 'image': image.name, 'sha256': p.sha(image), 'split': split, 'group': group,
                'reviewed_by': 'reviewer', 'complete_annotation': True, 'objects': [{'label': 'piano', 'box': [.1, .1, .9, .9]}]}
    def test_teacher_proposals_cannot_bypass_human_review(self):
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp); sample = self.sample(folder); sample['complete_annotation'] = False
            with self.assertRaisesRegex(ValueError, 'Human reviewer'):
                p.validate_review({'schema_version': 1, 'names': p.NAMES, 'samples': [sample]}, folder)
    def test_group_and_duplicate_leakage_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp); a = self.sample(folder); b = self.sample(folder, 1, 'test')
            doc = {'schema_version': 1, 'names': p.NAMES, 'samples': [a, b]}
            with self.assertRaisesRegex(ValueError, 'leakage'):
                p.validate_review(doc, folder)
            b['group'] = 'scene-b'; b['image'] = a['image']; b['sha256'] = a['sha256']
            with self.assertRaisesRegex(ValueError, 'duplicate image'):
                p.validate_review(doc, folder)
    def test_review_checksum_box_and_mock_validation(self):
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp); sample = self.sample(folder)
            doc = {'schema_version': 1, 'names': p.NAMES, 'samples': [sample]}
            _, reasons = p.validate_review(doc, folder)
            self.assertTrue(any('test/piano' in r for r in reasons))
            for change in ({'sha256': 'wrong'}, {'source': {'mock': True}}, {'objects': [{'label': 'piano', 'box': [0, 0, float('nan'), 1]}]}):
                bad = copy.deepcopy(doc); bad['samples'][0].update(change)
                with self.assertRaises(ValueError): p.validate_review(bad, folder)
    def test_ap_duplicate_detection_and_wrong_class(self):
        truth = {'a': [{'label': 'piano', 'box': [0, 0, 1, 1]}]}
        detection = {'label': 'piano', 'box': [0, 0, 1, 1], 'confidence': .9}
        report = p.metrics(truth, {'a': [detection, dict(detection, confidence=.8)]})
        self.assertEqual(report['piano']['ap50'], 1)
        self.assertEqual(report['piano']['recall'], 1)
        self.assertEqual(report['piano']['precision'], .5)
        wrong = p.metrics(truth, {'a': [dict(detection, label='laptop')]})
        self.assertEqual(wrong['piano']['recall'], 0)
    def test_gate_rejects_old_class_regression_even_with_better_piano(self):
        baseline = {n: {'support': 5, 'ap50': .8, 'precision': .8, 'recall': .8} for n in p.NAMES}
        baseline['piano'].update(ap50=0, recall=0, precision=0)
        candidate = copy.deepcopy(baseline); candidate['piano'].update(ap50=.8, recall=.8, precision=.9)
        self.assertEqual(p.gate(baseline, candidate), [])
        candidate['laptop']['recall'] = .5
        self.assertIn('regression: laptop', p.gate(baseline, candidate))
    def test_dataset_tampering_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp); (folder / 'image').write_bytes(b'original')
            p.write(folder / 'dataset.json', {'schema_version': 1, 'files': {'image': p.sha(folder / 'image')}})
            p.check_dataset(folder)
            (folder / 'image').write_bytes(b'changed')
            with self.assertRaisesRegex(ValueError, 'checksum'): p.check_dataset(folder)
    def test_curate_train_and_evaluate_contract_without_training_a_model(self):
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp); samples = []
            for split, count in [('train', 20), ('val', 5), ('test', 5)]:
                for _ in range(count):
                    sample = self.sample(folder, len(samples), split, 'scene-' + split)
                    sample['objects'] = [{'label': name, 'box': [.1, .1, .9, .9]} for name in p.NAMES]
                    samples.append(sample)
            p.write(folder / 'review.json', {'schema_version': 1, 'names': p.NAMES, 'samples': samples})
            dataset = folder / 'dataset'
            p.curate(Namespace(review=str(folder / 'review.json'), output=str(dataset)))
            _, original_digest = p.check_dataset(dataset)
            model = Mock(); model.names = dict(enumerate(p.COCO))
            def fit(**kwargs):
                checkpoint = folder / 'run/fit/weights/best.pt'
                checkpoint.parent.mkdir(parents=True); checkpoint.write_bytes(b'fake-checkpoint-no-training')
                # Simulate trainer-created cache files without modifying the curated source.
                (folder / 'run/data/labels/train.cache').write_bytes(b'cache')
            model.train.side_effect = fit
            with patch.dict(sys.modules, {'ultralytics': SimpleNamespace(YOLO=Mock(return_value=model))}), \
                 patch.object(p.shutil, 'disk_usage', return_value=SimpleNamespace(free=10*1024**3)), \
                 patch.object(p.subprocess, 'run', return_value=SimpleNamespace(stdout='test-fixture')):
                p.train(Namespace(dataset=str(dataset), output=str(folder / 'run'), epochs=1))
            self.assertEqual(model.train.call_args.kwargs['device'], 'cpu')
            self.assertEqual(p.check_dataset(dataset)[1], original_digest)
            candidate = Mock(); candidate.names = dict(enumerate(p.NAMES))
            def prediction(model, dataset, rows):
                names = p.NAMES if model is candidate else p.COCO
                return {s['id']: [{'label': name, 'box': [.1,.1,.9,.9], 'confidence': .9} for name in names] for s in rows}
            with patch.dict(sys.modules, {'ultralytics': SimpleNamespace(YOLO=Mock(side_effect=[candidate, model]))}), \
                 patch.object(p, 'predict', side_effect=prediction):
                result = p.evaluate(Namespace(dataset=str(dataset), checkpoint=str(folder / 'run/fit/weights/best.pt'), output=str(folder / 'evaluation.json')))
            self.assertEqual(result, 0)
            report = p.load(folder / 'evaluation.json')
            self.assertTrue(report['quality_passed'])
            self.assertFalse(report['deployment_approved'])

    def test_release_without_physical_evidence_is_blocked(self):
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp); package = folder / 'model.mlpackage'; package.mkdir(); (package / 'Manifest.json').write_text('{}')
            p.write(folder / 'model.mlpackage.evaluation.json', {'files': p.package_files(package), 'quality_passed': True})
            p.write(folder / 'device.json', {})
            from argparse import Namespace
            args = Namespace(package=str(package), device_report=str(folder / 'device.json'))
            with self.assertRaisesRegex(ValueError, 'Device report'): p.release(args)

if __name__ == '__main__': unittest.main()
