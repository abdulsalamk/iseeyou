import hashlib
import importlib.util
import json
import os
import sys
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

root = Path(__file__).parents[2] / 'infra/teacher/lambda'
sys.path.insert(0, str(root))
for name in ('teacher', 'ingestion'):
    spec = importlib.util.spec_from_file_location(name, root / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
ingestion = sys.modules['ingestion']

class IngestionTests(unittest.TestCase):
    @patch.dict(os.environ, {'TOKEN_HASH': hashlib.sha256(b'test-token').hexdigest()})
    @patch.object(ingestion, 'clients')
    def test_unauthorized_cannot_touch_storage(self, clients):
        self.assertEqual(ingestion.handler({'headers': {'authorization': 'Bearer wrong'}}, None)['statusCode'], 401)
        clients.assert_not_called()

    @patch.dict(os.environ, {'TOKEN_HASH': hashlib.sha256(b'test-token').hexdigest(), 'TABLE': 'table', 'BUCKET': 'bucket'})
    @patch.object(ingestion, 'clients')
    def test_invalid_consent_never_issues_upload(self, clients):
        s3, db = Mock(), Mock(); clients.return_value = s3, db
        event = {'headers': {'authorization': 'Bearer test-token'}, 'rawPath': '/samples',
                 'requestContext': {'http': {'method': 'POST'}},
                 'body': json.dumps({'sample_id': '00000000-0000-0000-0000-000000000001', 'consent': False})}
        self.assertEqual(ingestion.handler(event, None)['statusCode'], 400)
        db.put_item.assert_not_called(); s3.generate_presigned_url.assert_not_called()

    @patch.dict(os.environ, {'TOKEN_HASH': hashlib.sha256(b'test-token').hexdigest(), 'TABLE': 'table', 'BUCKET': 'bucket'})
    @patch.object(ingestion, 'clients')
    def test_completion_rejects_checksum_mismatch(self, clients):
        s3, db = Mock(), Mock(); clients.return_value = s3, db
        db.get_item.return_value = {'Item': {'doc': {'S': json.dumps({'expires_at': 9999999999,
            'image_key': 'raw/images/a.jpg', 'image_size': 10, 'image_sha256': 'expected'})}}}
        s3.head_object.return_value = {'ContentLength': 10, 'ChecksumSHA256': 'wrong'}
        event = {'headers': {'authorization': 'Bearer test-token'},
                 'rawPath': '/samples/00000000-0000-0000-0000-000000000001/complete',
                 'requestContext': {'http': {'method': 'POST'}}}
        self.assertEqual(ingestion.handler(event, None)['statusCode'], 409)
        s3.put_object.assert_not_called()

    @patch.dict(os.environ, {'TOKEN_HASH': hashlib.sha256(b'test-token').hexdigest(), 'TABLE': 'table',
                             'BUCKET': 'bucket', 'WORKFLOW_ARN': 'arn:aws:states:eu-west-2:885625664603:stateMachine:test'})
    @patch.object(ingestion, 'start_workflow')
    @patch.object(ingestion, 'clients')
    def test_session_close_starts_async_workflow_and_is_idempotent(self, clients, start_workflow):
        s3, db = Mock(), Mock(); clients.return_value = s3, db
        session_id = '00000000-0000-0000-0000-000000000001'
        sample_id = '00000000-0000-0000-0000-000000000002'
        db.get_item.return_value = {'Item': {'doc': {'S': json.dumps({'session_id': session_id})}}}
        event = {'headers': {'authorization': 'Bearer test-token'}, 'rawPath': f'/sessions/{session_id}/complete',
                 'requestContext': {'http': {'method': 'POST'}}, 'body': json.dumps({'sample_count': 1})}
        self.assertEqual(ingestion.handler(event, None)['statusCode'], 202)
        start_workflow.assert_called_once_with(os.environ['WORKFLOW_ARN'], session_id,
            {'session_id': session_id, 'attempt': 0})
        db.put_item.assert_called_once()

    @patch.dict(os.environ, {'TOKEN_HASH': hashlib.sha256(b'test-token').hexdigest(), 'TABLE': 'table', 'BUCKET': 'bucket'})
    @patch.object(ingestion, 'clients')
    def test_session_close_rejects_sample_count_above_bound(self, clients):
        s3, db = Mock(), Mock(); clients.return_value = s3, db
        db.get_item.return_value = {}
        event = {'headers': {'authorization': 'Bearer test-token'},
                 'rawPath': '/sessions/00000000-0000-0000-0000-000000000001/complete',
                 'requestContext': {'http': {'method': 'POST'}},
                 'body': json.dumps({'sample_count': 2001})}
        self.assertEqual(ingestion.handler(event, None)['statusCode'], 400)
        s3.head_object.assert_not_called()

    @patch.dict(os.environ, {'TOKEN_HASH': hashlib.sha256(b'test-token').hexdigest(), 'TABLE': 'table', 'BUCKET': 'bucket'})
    @patch.object(ingestion, 'clients')
    def test_ticket_includes_uploads_for_all_camera_frames(self, clients):
        s3, db = Mock(), Mock(); clients.return_value = s3, db
        s3.generate_presigned_url.return_value = 'https://bucket.s3.eu-west-2.amazonaws.com/upload'
        db.get_item.return_value = {}
        checksum = 'A' * 43 + '='
        sample_id = '00000000-0000-0000-0000-000000000003'
        frames = [{'frame_id': f'{sample_id}-{i}', 'captured_at': '2026-10-24T00:00:00Z',
                   'offset_seconds': i, 'image_size': 100 + i, 'image_sha256': checksum,
                   'predictions': []} for i in range(3)]
        body = {'sample_id': sample_id, 'session_id': '00000000-0000-0000-0000-000000000001',
            'consent': True, 'frame_id': frames[0]['frame_id'], 'captured_at': frames[0]['captured_at'],
            'model_version': 'test', 'source': 'iPhone camera', 'duration_seconds': 3,
            'image_size': frames[0]['image_size'], 'image_sha256': checksum,
            'clip_size': 1000, 'clip_sha256': checksum, 'predictions': [], 'clip_frames': frames}
        event = {'headers': {'authorization': 'Bearer test-token'}, 'rawPath': '/samples',
                 'requestContext': {'http': {'method': 'POST'}}, 'body': json.dumps(body)}
        result = ingestion.handler(event, None)
        self.assertEqual(result['statusCode'], 201)
        ticket = json.loads(result['body'])
        self.assertEqual(len(ticket['frames']), 2)
        self.assertEqual(s3.generate_presigned_url.call_count, 4)

if __name__ == '__main__': unittest.main()
