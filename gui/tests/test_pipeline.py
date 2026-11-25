import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def test_bootstrap_dry_run_matches_designer_command(cfg):
    cfg.github_repo = "contoso/landingzones"
    args = cfg.bootstrap_command().replace("\\\n", " ").split()[1:]
    proc = subprocess.run(["bash", str(ROOT / "scripts/bootstrap.sh"), "--dry-run", *args],
                          capture_output=True, text=True, timeout=60)
    assert proc.returncode == 0, proc.stderr
    trace = proc.stderr
    assert "--allow-shared-key-access false" in trace and "--sku Standard_ZRS" in trace
    assert "repo:contoso/landingzones:pull_request" in trace
    assert "repo:contoso/landingzones:environment:production" in trace
    # connectivity, identity, shared services and production
    assert trace.count("Reader") == 4 and trace.count("User\\ Access\\ Administrator") == 4
    assert "/subscriptions/55555555-5555-5555-5555-555555555555" in trace
    assert "AZURE_APPLY_CLIENT_ID" in proc.stdout


def test_bootstrap_requires_arguments():
    proc = subprocess.run(["bash", str(ROOT / "scripts/bootstrap.sh"), "--dry-run"], capture_output=True, text=True)
    assert proc.returncode != 0 and "Usage" in proc.stdout + proc.stderr


def test_deploy_workflow_separates_plan_and_apply():
    wf = (ROOT / ".github/workflows/deploy.yml").read_text()
    assert "AZURE_PLAN_CLIENT_ID" in wf and "AZURE_APPLY_CLIENT_ID" in wf
    assert "environment: ${{ vars.TF_ENVIRONMENT || 'production' }}" in wf
    assert "-refresh=false" in wf and "-lockfile=readonly" in wf and "id-token: write" in wf
    assert "${{ secrets." not in wf      # OIDC only – no stored credentials


def test_lock_file_covers_all_platforms():
    lock = (ROOT / ".terraform.lock.hcl").read_text()
    for provider in ("hashicorp/azurerm", "hashicorp/random"):
        block = lock.split(f'provider "registry.terraform.io/{provider}"')[1].split("}")[0]
        assert block.count("h1:") >= 4


def test_state_names_are_valid(cfg):
    rg, sa = cfg.state_names()
    assert rg == "rg-contoso-tfstate-prod-neu"
    assert sa.isalnum() and sa.islower() and 3 <= len(sa) <= 24
