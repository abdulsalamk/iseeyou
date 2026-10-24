"""Remove the previous month's protective deny so the new monthly budget can run."""
import os


def handler(event, context):
    import boto3
    iam = boto3.client('iam')
    policy = os.environ['BUDGET_POLICY_ARN']
    for role in (os.environ['WORKER_ROLE_NAME'], os.environ['LEARNING_ROLE_NAME']):
        try:
            iam.detach_role_policy(RoleName=role, PolicyArn=policy)
        except Exception as exc:
            if getattr(exc, 'response', {}).get('Error', {}).get('Code') != 'NoSuchEntity':
                raise
    return {'status': 'monthly_budget_lock_cleared'}
