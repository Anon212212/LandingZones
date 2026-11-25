# Environments

One `<environment>.tfvars` per GitHub environment (e.g. `production.tfvars`). The deploy workflow (`.github/workflows/deploy.yml`) plans and applies `environments/${TF_ENVIRONMENT}.tfvars`.

Generate these files with the Landing Zone Designer: **Export → Write environments/<name>.tfvars**. They contain no secrets (subscription IDs and an SSH *public* key), so they're committed, unlike a local `terraform.tfvars`. Every change goes through a pull request (plan) and an approved apply.
