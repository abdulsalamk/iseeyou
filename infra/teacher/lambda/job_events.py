"""Record terminal SageMaker training status and release the single-job lock."""
import os
import uuid


def handler(event, context):
    import boto3
    detail = event.get('detail', {})
    job = detail.get('TrainingJobName', '')
    status = detail.get('TrainingJobStatus', '')
    prefix = 'iseeyou-yolo-'
    if not job.startswith(prefix) or status not in ('Completed', 'Failed', 'Stopped'):
        return {'status': 'ignored'}
    try:
        session_id = str(uuid.UUID(hex=job[len(prefix):]))
    except ValueError:
        return {'status': 'ignored'}
    db = boto3.client('dynamodb')
    table = os.environ['TABLE']
    mapped = {'Completed': 'training_complete', 'Failed': 'training_failed', 'Stopped': 'training_stopped'}[status]
    if status == 'Completed':
        item = db.get_item(TableName=table, Key={'id': {'S': 'session#' + session_id}}, ConsistentRead=True).get('Item', {})
        if item.get('evaluation_status', {}).get('S') == 'rejected':
            mapped = 'evaluation_rejected'
    db.update_item(TableName=table, Key={'id': {'S': 'session#' + session_id}},
        UpdateExpression='SET #s = :status', ExpressionAttributeNames={'#s': 'status'},
        ExpressionAttributeValues={':status': {'S': mapped}})
    try:
        db.delete_item(TableName=table, Key={'id': {'S': 'training-lock'}},
            ConditionExpression='training_job = :job', ExpressionAttributeValues={':job': {'S': job}})
    except Exception as exc:
        if getattr(exc, 'response', {}).get('Error', {}).get('Code') != 'ConditionalCheckFailedException':
            raise
    return {'status': mapped}
