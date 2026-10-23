#!/usr/bin/env python3
"""One-time AWS CLI bootstrap; credentials stay in the selected local profile."""
import argparse
import json
from pathlib import Path
import subprocess

REGION = "eu-west-2"
PROJECT = "iseeyou"
REPOSITORY = "abdulsalamk/iseeyou"
ROLE = "iseeyou-github-terraform"
SUBJECT = "repo:abdulsalamk@6270608/iseeyou@1427983832:ref:refs/heads/main"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", required=True)
    parser.add_argument("--expected-account", required=True)
    parser.add_argument("--apply", action="store_true", required=True)
    args = parser.parse_args()

    def aws(service, operation, *options, missing=None):
        command = ["aws", "--profile", args.profile, "--region", REGION,
                   service, operation, *options, "--output", "json"]
        result = subprocess.run(command, capture_output=True, text=True, timeout=90)
        if result.returncode:
            if missing and missing in result.stderr:
                return None
            raise RuntimeError(f"AWS {service} {operation} failed; no credentials logged")
        return json.loads(result.stdout) if result.stdout.strip() else {}

    account = aws("sts", "get-caller-identity")["Account"]
    if account != args.expected_account:
        raise RuntimeError("Selected profile targets an unexpected AWS account")
    bucket = f"{PROJECT}-terraform-state-{account}-{REGION}"
    bucket_arn = f"arn:aws:s3:::{bucket}"
    provider_arn = f"arn:aws:iam::{account}:oidc-provider/token.actions.githubusercontent.com"
    tags = [{"Key": "Project", "Value": PROJECT}, {"Key": "Purpose", "Value": "TerraformBootstrap"}]

    # Check the account inventory rather than interpreting an ambiguous HeadBucket 403.
    buckets = {item["Name"] for item in aws("s3api", "list-buckets")["Buckets"]}
    if bucket not in buckets:
        aws("s3api", "create-bucket", "--bucket", bucket,
            "--create-bucket-configuration", json.dumps({"LocationConstraint": REGION}))
        aws("s3api", "put-bucket-tagging", "--bucket", bucket,
            "--tagging", json.dumps({"TagSet": tags}))
    else:
        existing = aws("s3api", "get-bucket-tagging", "--bucket", bucket)
        if {t["Key"]: t["Value"] for t in existing["TagSet"]}.get("Project") != PROJECT:
            raise RuntimeError("Refusing to modify a bucket without the project ownership tag")
    aws("s3api", "put-public-access-block", "--bucket", bucket,
        "--public-access-block-configuration", json.dumps({
            "BlockPublicAcls": True, "IgnorePublicAcls": True,
            "BlockPublicPolicy": True, "RestrictPublicBuckets": True}))
    aws("s3api", "put-bucket-ownership-controls", "--bucket", bucket,
        "--ownership-controls", json.dumps({"Rules": [{"ObjectOwnership": "BucketOwnerEnforced"}]}))
    aws("s3api", "put-bucket-versioning", "--bucket", bucket,
        "--versioning-configuration", json.dumps({"Status": "Enabled"}))
    aws("s3api", "put-bucket-encryption", "--bucket", bucket,
        "--server-side-encryption-configuration", json.dumps({"Rules": [{
            "ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"}}]}))
    aws("s3api", "put-bucket-policy", "--bucket", bucket, "--policy", json.dumps({
        "Version": "2012-10-17", "Statement": [{"Sid": "DenyInsecureTransport", "Effect": "Deny",
            "Principal": "*", "Action": "s3:*", "Resource": [bucket_arn, bucket_arn + "/*"],
            "Condition": {"Bool": {"aws:SecureTransport": "false"}}}]}))

    providers = aws("iam", "list-open-id-connect-providers")["OpenIDConnectProviderList"]
    if provider_arn not in [p["Arn"] for p in providers]:
        aws("iam", "create-open-id-connect-provider", "--url", "https://token.actions.githubusercontent.com",
            "--client-id-list", "sts.amazonaws.com", "--tags", json.dumps(tags))
    provider = aws("iam", "get-open-id-connect-provider", "--open-id-connect-provider-arn", provider_arn)
    if "sts.amazonaws.com" not in provider["ClientIDList"]:
        raise RuntimeError("Existing GitHub OIDC provider does not accept the STS audience")
    trust = {"Version": "2012-10-17", "Statement": [{"Effect": "Allow",
        "Principal": {"Federated": provider_arn}, "Action": "sts:AssumeRoleWithWebIdentity",
        "Condition": {"StringEquals": {"token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
                                      "token.actions.githubusercontent.com:sub": SUBJECT}}}]}
    role = aws("iam", "get-role", "--role-name", ROLE, missing="NoSuchEntity")
    if role is None:
        aws("iam", "create-role", "--role-name", ROLE, "--assume-role-policy-document", json.dumps(trust),
            "--max-session-duration", "3600", "--tags", json.dumps(tags))
    elif role["Role"]["AssumeRolePolicyDocument"] != trust:
        raise RuntimeError("Existing role trust differs; refusing an implicit permission change")
    permissions = {"Version": "2012-10-17", "Statement": [
        {"Sid": "ReadStateBucketConfiguration", "Effect": "Allow", "Action": [
            "s3:GetBucketLocation", "s3:GetBucketVersioning", "s3:GetEncryptionConfiguration",
            "s3:GetBucketPublicAccessBlock"], "Resource": bucket_arn},
        {"Sid": "ListProjectState", "Effect": "Allow", "Action": "s3:ListBucket",
         "Resource": bucket_arn, "Condition": {"StringLike": {"s3:prefix": ["bootstrap/*", "states/iseeyou/*"]}}},
        {"Sid": "ReadWriteState", "Effect": "Allow", "Action": ["s3:GetObject", "s3:PutObject"],
         "Resource": [bucket_arn + "/bootstrap/terraform.tfstate", bucket_arn + "/states/iseeyou/*"]},
        {"Sid": "ManageStateLocksAndSmokeTest", "Effect": "Allow", "Action": [
            "s3:GetObject", "s3:PutObject", "s3:DeleteObject"], "Resource": [
            bucket_arn + "/bootstrap/terraform.tfstate.tflock", bucket_arn + "/states/iseeyou/*.tflock",
            bucket_arn + "/bootstrap/checks/*"]}]}
    aws("iam", "put-role-policy", "--role-name", ROLE, "--policy-name", "TerraformStateAccess",
        "--policy-document", json.dumps(permissions))
    print(json.dumps({"region": REGION, "state_bucket": bucket,
                      "github_role_arn": f"arn:aws:iam::{account}:role/{ROLE}",
                      "github_subject": SUBJECT, "permissions": "state bucket only"}, indent=2))


if __name__ == "__main__":
    main()
