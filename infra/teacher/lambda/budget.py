"""Conservative monthly spend reservations for the automatic teacher workflow."""
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation
import os
import time


def reserve_gbp(amount, operation):
    """Reserve worst-case budget before an AWS inference or training operation.

    The ledger intentionally stops at the configured soft limit, leaving headroom
    for delayed billing and storage/orchestration charges before the £10 AWS budget.
    """
    try:
        amount = Decimal(str(amount))
        limit = Decimal(os.environ.get('PIPELINE_SOFT_LIMIT_GBP', '8.00'))
    except InvalidOperation:
        return False
    if amount <= 0 or limit <= 0 or amount > limit:
        return False
    import boto3
    table = os.environ['TABLE']
    month = datetime.now(timezone.utc).strftime('%Y-%m')
    key = 'learning-budget#' + month
    try:
        boto3.client('dynamodb').update_item(
            TableName=table,
            Key={'id': {'S': key}},
            UpdateExpression='SET reserved_gbp = if_not_exists(reserved_gbp, :zero) + :amount, '
                             'expires_at = :expires, last_operation = :operation',
            ConditionExpression='attribute_not_exists(reserved_gbp) OR reserved_gbp <= :remaining',
            ExpressionAttributeValues={
                ':zero': {'N': '0'}, ':amount': {'N': str(amount)},
                ':remaining': {'N': str(limit - amount)},
                ':expires': {'N': str(int(time.time()) + 70 * 86400)},
                ':operation': {'S': str(operation)[:80]},
            },
        )
        return True
    except Exception as exc:
        if getattr(exc, 'response', {}).get('Error', {}).get('Code') == 'ConditionalCheckFailedException':
            return False
        raise


def release_gbp(amount):
    """Release a reservation when an AWS job was not created."""
    import boto3
    month = datetime.now(timezone.utc).strftime('%Y-%m')
    boto3.client('dynamodb').update_item(
        TableName=os.environ['TABLE'], Key={'id': {'S': 'learning-budget#' + month}},
        UpdateExpression='SET reserved_gbp = reserved_gbp - :amount',
        ConditionExpression='reserved_gbp >= :amount',
        ExpressionAttributeValues={':amount': {'N': str(Decimal(str(amount))) }},
    )
