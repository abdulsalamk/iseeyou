# AWS bootstrap

This is separate from iPhone application deployment. The user explicitly requested an AWS S3-state and GitHub-OIDC foundation using local profile `abdul`, in London (`eu-west-2`). The iOS hosted-build workflows remain disabled. No GPU training, Bedrock invocation, endpoint, image collection or image upload is started here.

The state bucket is private, versioned, AES256-encrypted, bucket-owner enforced, and requires TLS. Terraform uses native S3 lock files; no DynamoDB table is needed. The GitHub role trusts only this repository's immutable OIDC identity on main, with the STS audience. It has state-prefix permissions, not account-administrator or application-provisioning permissions.

The selected local profile must already exist; no access keys are written to this repository or GitHub. Initial bootstrap uses the AWS CLI:

```sh
PATH="/opt/homebrew/bin:$PATH" python3 scripts/aws/bootstrap.py \
  --profile abdul --expected-account 885625664603 --apply
```

Manage the bootstrap with Terraform locally after importing the CLI-created resources. Authentication comes from `AWS_PROFILE=abdul`; do not commit state files or credentials.

```sh
cd infra/bootstrap
AWS_PROFILE=abdul terraform init -backend-config=backend.hcl
AWS_PROFILE=abdul terraform validate
AWS_PROFILE=abdul terraform plan
```

The GitHub OIDC connection check is manual and accesses only the dedicated state smoke-test prefix. It must not re-enable the iOS build or installation bridge. Any future ML infrastructure needs its own service-specific Terraform resources and narrowly scoped role permissions once the architecture is specified.

S3 requests/storage and GitHub Actions usage may incur charges. No always-running compute is created by this foundation.
