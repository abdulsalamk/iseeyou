# Adopt exactly the resources created by scripts/aws/bootstrap.py.
# Keep these blocks as a record of the initial CLI-to-Terraform handover.
import {
  to = aws_s3_bucket.state
  id = local.bucket_name
}
import {
  to = aws_s3_bucket_public_access_block.state
  id = local.bucket_name
}
import {
  to = aws_s3_bucket_ownership_controls.state
  id = local.bucket_name
}
import {
  to = aws_s3_bucket_versioning.state
  id = local.bucket_name
}
import {
  to = aws_s3_bucket_server_side_encryption_configuration.state
  id = local.bucket_name
}
import {
  to = aws_s3_bucket_policy.state
  id = local.bucket_name
}
import {
  to = aws_iam_openid_connect_provider.github
  id = "arn:aws:iam::${var.account_id}:oidc-provider/token.actions.githubusercontent.com"
}
import {
  to = aws_iam_role.github
  id = "iseeyou-github-terraform"
}
import {
  to = aws_iam_role_policy.state
  id = "iseeyou-github-terraform:TerraformStateAccess"
}
