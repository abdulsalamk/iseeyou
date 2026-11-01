import base64
import hashlib
import io
import json
import os
import sys
import unittest
from datetime import datetime, timezone
from pathlib import Path
from unittest.mock import Mock, patch
sys.path.insert(0, str(Path(__file__).parents[2] / 'infra/teacher/lambda'))
import corrections
import ingestion

class CorrectionsTests(unittest.TestCase):
    def record(self):
        identifier = '00000000-0000-0000-0000-000000000001'
        now = datetime.now(timezone.utc).isoformat()
        return {'schemaVersion': 1, 'id': identifier, 'capturedAt': now, 'triggeredAt': now,
            'transcriptText': 'Correction, this is a piano', 'correctedLabel': 'piano',
            'modelVersion': 'yolo26n', 'source': 'iPhone camera', 'processingState': 'awaiting_validation',
            'frameObjectKey': f'corrections/{identifier}/frame.jpg', 'frameSHA256': hashlib.sha256(b'jpeg').hexdigest(),
            'originalDetection': {'label': 'laptop', 'confidence': .9, 'boundingBox': {'x': .1, 'y': .2, 'width': .3, 'height': .4}}}
    def test_uuid_and_geometry_validation(self):
        doc = self.record(); self.assertEqual(corrections.validate(doc), doc['id'])
        doc['frameObjectKey'] = 'raw/unrelated.jpg'
        with self.assertRaises(ValueError): corrections.validate(doc)
        doc = self.record(); doc['originalDetection']['boundingBox']['width'] = 1
        with self.assertRaises(ValueError): corrections.validate(doc)
    def test_transcript_label_and_frame_must_agree(self):
        doc = self.record(); doc['transcriptText'] = 'Correction. This is a piano!'
        self.assertEqual(corrections.validate(doc), doc['id'])
        doc = self.record(); doc['correctedLabel'] = 'door'
        with self.assertRaises(ValueError): corrections.validate(doc)
        doc = self.record(); doc['triggeredAt'] = '2026-01-01T00:00:00Z'
        with self.assertRaises(ValueError): corrections.validate(doc)
    def test_ticket_retry_reuses_record_and_rejects_changes(self):
        doc = self.record(); body = {'correction': doc, 'image_size': 4}
        payload = json.dumps(body, sort_keys=True, separators=(',', ':'))
        db, s3 = Mock(), Mock()
        db.get_item.return_value = {'Item': {'fingerprint': {'S': hashlib.sha256(payload.encode()).hexdigest()}, 'expires_at': {'N': '9999999999'}}}
        s3.generate_presigned_url.return_value = 'https://example'
        self.assertEqual(corrections.handle('POST', '/corrections', body, s3, db, 'bucket', 'table')[0], 201)
        db.put_item.assert_not_called(); db.update_item.assert_not_called()
        body['image_size'] = 5
        self.assertEqual(corrections.handle('POST', '/corrections', body, s3, db, 'bucket', 'table')[0], 409)
    def test_completion_checks_media_before_metadata(self):
        doc = self.record(); db, s3 = Mock(), Mock()
        db.get_item.return_value = {'Item': {'doc': {'S': json.dumps({'correction': doc, 'image_size': 4})}, 'expires_at': {'N': '9999999999'}}}
        s3.head_object.return_value = {'ContentLength': 4, 'ChecksumSHA256': 'wrong'}
        path = f"/corrections/{doc['id']}/complete"
        with self.assertRaises(ValueError): corrections.handle('POST', path, {}, s3, db, 'bucket', 'table')
        s3.put_object.assert_not_called()
        s3.head_object.return_value['ChecksumSHA256'] = base64.b64encode(bytes.fromhex(doc['frameSHA256'])).decode()
        code, result = corrections.handle('POST', path, {}, s3, db, 'bucket', 'table')
        self.assertEqual(code, 200); self.assertFalse(result['training_eligible'])
        saved = json.loads(s3.put_object.call_args.kwargs['Body'])
        self.assertEqual(saved['id'], doc['id']); self.assertEqual(saved['correctedLabel'], 'piano')
        self.assertEqual(s3.put_object.call_args.kwargs['IfNoneMatch'], '*')
    @patch.dict(os.environ, {'TOKEN_HASH': hashlib.sha256(b'test-token').hexdigest(), 'TABLE': 'table', 'BUCKET': 'bucket'})
    @patch.object(ingestion, 'clients')
    def test_authenticated_route_and_no_workflow(self, clients):
        s3, db = Mock(), Mock(); clients.return_value = s3, db; db.get_item.return_value = {}
        s3.generate_presigned_url.return_value = 'https://example'
        event = {'headers': {'authorization': 'Bearer test-token'}, 'rawPath': '/corrections',
            'requestContext': {'http': {'method': 'POST'}}, 'body': json.dumps({'correction': self.record(), 'image_size': 4})}
        self.assertEqual(ingestion.handler(event, None)['statusCode'], 201)
        event['headers']['authorization'] = 'Bearer wrong'
        self.assertEqual(ingestion.handler(event, None)['statusCode'], 401)

if __name__ == '__main__': unittest.main()
