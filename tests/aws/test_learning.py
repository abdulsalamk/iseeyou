import importlib.util
import json
import os
import sys
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

root = Path(__file__).parents[2] / 'infra/teacher/lambda'
sys.path.insert(0, str(root))
spec = importlib.util.spec_from_file_location('learning', root / 'learning.py')
learning = importlib.util.module_from_spec(spec)
spec.loader.exec_module(learning)


class LearningTests(unittest.TestCase):
    def candidate(self, group, index):
        return {'status': 'pseudo_labeled', 'pseudo_label_eligible': True,
                'source': {'session_id': group, 'sample_id': f'{group}-{index}'},
                'frames': [{'frame_id': f'{group}-{index}', 'image_key': f'raw/frames/{index}.jpg',
                            'image_version': 'version', 'proposal': {'objects': [
                                {'label': 'novel object', 'box': [0.1, 0.1, 0.8, 0.9]}]}}]}

    def test_grouped_split_is_stable_and_never_leaks_a_session(self):
        splits = {learning.split_for_group(f'session-{i}') for i in range(100)}
        self.assertEqual(splits, {'train', 'val', 'test'})
        self.assertEqual(learning.split_for_group('same-session'), learning.split_for_group('same-session'))

    def test_session_candidates_wait_for_minimum_pseudo_label_coverage(self):
        manifest, reason = learning.build_training_manifest([self.candidate('one-session', i) for i in range(3)])
        self.assertIsNone(manifest)
        self.assertTrue(reason.startswith('coverage_gate:'))

    def test_candidate_dataset_uses_nova_spatial_labels_and_session_splits(self):
        group_ids = {'train': [], 'val': [], 'test': []}
        for i in range(1000):
            group = f'session-{i}'
            split = learning.split_for_group(group)
            if len(group_ids[split]) < {'train': 20, 'val': 5, 'test': 5}[split]:
                group_ids[split].append(group)
            if all(len(group_ids[name]) >= count for name, count in {'train': 20, 'val': 5, 'test': 5}.items()):
                break
        results = [self.candidate(group, i) for split_groups in group_ids.values()
                   for group in split_groups for i in range(1)]
        manifest, reason = learning.build_training_manifest(results)
        self.assertIsNone(reason)
        self.assertEqual(manifest['annotation_source'], 'nova_pseudo_labels')
        self.assertEqual(manifest['names'][-1], 'novel object')
        self.assertEqual({row['split'] for row in manifest['frames']}, {'train', 'val', 'test'})
        self.assertTrue(all(row['group'] == group for group, count in group_ids.items()
                            for row in manifest['frames'] if row['group'] == group))

    def test_unapproved_or_mock_outputs_never_enter_dataset(self):
        row = self.candidate('session', 1)
        row['pseudo_label_eligible'] = False
        manifest, reason = learning.build_training_manifest([row])
        self.assertIsNone(manifest)
        self.assertEqual(reason, 'no_spatial_pseudo_labels')

    def launch_fixture(self):
        groups = {'train': [], 'val': [], 'test': []}
        for i in range(1000):
            group = f'session-{i}'
            split = learning.split_for_group(group)
            if len(groups[split]) < {'train': 20, 'val': 5, 'test': 5}[split]:
                groups[split].append(group)
            if all(len(groups[key]) >= value for key, value in {'train': 20, 'val': 5, 'test': 5}.items()):
                break
        return [self.candidate(group, 0) for values in groups.values() for group in values]

    @patch.dict(os.environ, {'TABLE': 'uploads', 'BUCKET': 'bucket', 'TRAINING_ROLE_ARN': 'role',
        'TRAINING_CODE_KEY': 'learning/code.zip', 'BASELINE_KEY': 'learning/baseline.pt',
        'TRAINING_IMAGE': 'pytorch', 'TRAINING_INSTANCE': 'ml.g4dn.xlarge',
        'TRAINING_MAX_RUNTIME_SECONDS': '900', 'TRAINING_EPOCHS': '10', 'TRAIN_JOB_RESERVE_GBP': '2.00'})
    @patch.object(learning, 'reserve_gbp', return_value=True)
    @patch.object(learning, '_list_candidates')
    @patch.object(learning, '_candidate_for_sample')
    @patch.object(learning, 'clients')
    def test_eligible_session_starts_bounded_shadow_training(self, clients, sample_candidate, all_candidates, reserve):
        s3, db, sm = Mock(), Mock(), Mock()
        clients.return_value = s3, db, sm
        session = '00000000-0000-0000-0000-000000000001'
        sample = '00000000-0000-0000-0000-000000000002'
        db.get_item.side_effect = [
            {'Item': {'sample_ids': {'S': json.dumps([sample])}, 'status': {'S': 'closed'}}},
            {},
        ]
        candidates = self.launch_fixture()
        sample_candidate.return_value = candidates[0]
        all_candidates.return_value = candidates
        class MissingJob(Exception):
            response = {'Error': {'Code': 'ResourceNotFound'}}
        sm.describe_training_job.side_effect = MissingJob()
        with patch.dict(os.environ, {'SESSION_WAIT_ATTEMPTS': '120'}), patch.object(learning, '_session_samples', return_value=[sample]):
            result = learning.handler({'session_id': session, 'attempt': 0}, None)
        self.assertEqual(result['status'], 'training_started')
        self.assertEqual(result['training_job'], 'iseeyou-yolo-' + session.replace('-', '')[:32])
        self.assertEqual(sm.create_training_job.call_args.kwargs['StoppingCondition']['MaxRuntimeInSeconds'], 900)
        self.assertEqual(sm.create_training_job.call_args.kwargs['ResourceConfig']['InstanceCount'], 1)
        reserve.assert_called_once()

    @patch.dict(os.environ, {'TABLE': 'uploads', 'BUCKET': 'bucket', 'TRAINING_ROLE_ARN': 'role',
        'TRAINING_CODE_KEY': 'learning/code.zip', 'BASELINE_KEY': 'learning/baseline.pt',
        'TRAINING_IMAGE': 'pytorch', 'TRAINING_INSTANCE': 'ml.g4dn.xlarge',
        'TRAINING_MAX_RUNTIME_SECONDS': '900', 'TRAINING_EPOCHS': '10', 'TRAIN_JOB_RESERVE_GBP': '2.00'})
    @patch.object(learning, 'reserve_gbp', return_value=False)
    @patch.object(learning, '_list_candidates')
    @patch.object(learning, '_candidate_for_sample')
    @patch.object(learning, 'clients')
    def test_budget_exhaustion_does_not_start_training(self, clients, sample_candidate, all_candidates, reserve):
        s3, db, sm = Mock(), Mock(), Mock()
        clients.return_value = s3, db, sm
        session = '00000000-0000-0000-0000-000000000001'
        sample = '00000000-0000-0000-0000-000000000002'
        db.get_item.side_effect = [
            {'Item': {'sample_ids': {'S': json.dumps([sample])}, 'status': {'S': 'closed'}}},
            {},
        ]
        candidates = self.launch_fixture()
        sample_candidate.return_value = candidates[0]
        all_candidates.return_value = candidates
        class MissingJob(Exception):
            response = {'Error': {'Code': 'ResourceNotFound'}}
        sm.describe_training_job.side_effect = MissingJob()
        with patch.object(learning, '_session_samples', return_value=[sample]):
            result = learning.handler({'session_id': session, 'attempt': 0}, None)
        self.assertEqual(result['status'], 'budget_limited')
        sm.create_training_job.assert_not_called()
        db.put_item.assert_not_called()

    @patch.dict(os.environ, {'TABLE': 'uploads', 'BUCKET': 'bucket', 'SESSION_WAIT_ATTEMPTS': '120'})
    @patch.object(learning, '_session_samples', return_value=[])
    @patch.object(learning, 'clients')
    def test_session_waits_for_eventually_consistent_upload_index(self, clients, session_samples):
        s3, db, sm = Mock(), Mock(), Mock()
        clients.return_value = s3, db, sm
        session = '00000000-0000-0000-0000-000000000001'
        db.get_item.return_value = {'Item': {'expected_samples': {'N': '1'}, 'status': {'S': 'closed'}}}
        result = learning.handler({'session_id': session, 'attempt': 0}, None)
        self.assertTrue(result['wait'])
        self.assertEqual(result['status'], 'waiting_for_upload_index')
        sm.create_training_job.assert_not_called()


if __name__ == '__main__':
    unittest.main()
