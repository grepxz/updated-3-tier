terraform {
  # Partial config — actual values in backend.hcl (gitignored).
  # Init with: terraform init -backend-config=backend.hcl
  backend "s3" {}
}
