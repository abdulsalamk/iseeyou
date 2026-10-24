import importlib.util
import io
import json
import os
import unittest
from unittest.mock import Mock, patch
from pathlib import Path

spec = importlib.util.spec_from_file_location('teacher', Path(__file__).parents[2] / 'infra/teacher/lambda/teacher.py')
teacher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(teacher)

class TeacherTests(unittest.TestCase):
    def manifest(self):
        return {'schema_version': 1, 'consent': True, 'frame_id': 'sample', 'captured_at': '2026-10-24T00:00:00Z',
                'model_version': 'test', 'image_key': 'raw/images/sample.png', 'image_version': 'image-v1',
                'predictions': [{'label': 'cabinet', 'confidence': 0.8, 'box': [0, 0, 1, 1]}]}
    def record(self):
        return {'s3': {'bucket': {'name': 'test-bucket'}, 'object': {'key': 'raw/manifests/sample.json', 'versionId': 'v1'}}}
    def test_consent_and_geometry(self):
        doc = self.manifest()
        doc['consent'] = False
        with self.assertRaises(ValueError): teacher.validate_manifest(doc)
        doc['consent'] = True
        doc['predictions'][0]['box'] = [0.9, 0, 0.1, 1]
        with self.assertRaises(ValueError): teacher.validate_manifest(doc)
    def test_teacher_geometry_rejected(self):
        with self.assertRaises(ValueError):
            teacher.parse_proposal('{"objects":[{"label":"door","box":[0,0,2,1]}]}')
    @patch.dict(os.environ, {'BUCKET': 'test-bucket', 'MODEL_ID': 'test-model'})
    def test_completed_retry_does_not_invoke(self):
        s3, model = Mock(), Mock()
        import hashlib
        key = 'candidates/' + hashlib.sha256(b'raw/manifests/sample.json:v1').hexdigest() + '.json'
        s3.list_objects_v2.return_value = {'Contents': [{'Key': key}]}
        teacher.process_record(self.record(), s3, model)
        model.converse.assert_not_called()
        s3.get_object.assert_not_called()
    @patch.dict(os.environ, {'BUCKET': 'test-bucket', 'MODEL_ID': 'test-model'})
    def test_versioned_proposal_and_comparison(self):
        s3, model = Mock(), Mock()
        s3.list_objects_v2.return_value = {}
        s3.get_object.side_effect = [{'Body': io.BytesIO(json.dumps(self.manifest()).encode())},
                                     {'Body': io.BytesIO(b'\x89PNG\r\n\x1a\nimage')}]
        model.converse.return_value = {'output': {'message': {'content': [{'text': '{"objects":[{"label":"door","box":null}]}'}]}}}
        teacher.process_record(self.record(), s3, model)
        self.assertEqual(s3.get_object.call_args_list[1].kwargs['VersionId'], 'image-v1')
        result = json.loads(s3.put_object.call_args.kwargs['Body'])
        self.assertFalse(result['training_eligible'])
        self.assertEqual(result['comparison']['teacher_only_labels'], ['door'])
        self.assertEqual(s3.put_object.call_args.kwargs['IfNoneMatch'], '*')
    @patch.dict(os.environ, {'BUCKET': 'test-bucket', 'MODEL_ID': 'test-model'})
    def test_wrong_bucket_and_oversized_manifest_never_invoke(self):
        s3, model = Mock(), Mock()
        record = self.record()
        record['s3']['bucket']['name'] = 'untrusted'
        with self.assertRaises(ValueError): teacher.process_record(record, s3, model)
        s3.list_objects_v2.return_value = {}
        s3.get_object.return_value = {'Body': io.BytesIO(b'x' * 65537)}
        with self.assertRaises(ValueError): teacher.process_record(self.record(), s3, model)
        model.converse.assert_not_called()
        s3.put_object.assert_not_called()
    @patch.object(teacher, 'clients')
    @patch.object(teacher, 'process_record')
    def test_partial_failures(self, process, clients):
        clients.return_value = Mock(), Mock()
        process.side_effect = [ValueError('bad'), None]
        body = json.dumps({'Records': [self.record()]})
        answer = teacher.handler({'Records': [{'messageId': 'a', 'body': body}, {'messageId': 'b', 'body': body}]}, None)
        self.assertEqual(answer, {'batchItemFailures': [{'itemIdentifier': 'a'}]})

if __name__ == '__main__': unittest.main()
