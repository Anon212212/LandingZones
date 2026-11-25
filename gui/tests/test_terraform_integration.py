"""The designer's output must satisfy the real Terraform validations.

Runs `terraform test` on the root module with the generated tfvars against
mocked providers. Skipped when terraform isn't available or initialised.
"""

import os
import shutil
import subprocess
from pathlib import Path

import pytest

from lzdesigner import compliance, tfvars

ROOT = Path(__file__).resolve().parents[2]
TF = os.environ.get("TERRAFORM_BIN") or shutil.which("terraform")
data_dir = Path(os.environ.get("TF_DATA_DIR", ROOT / ".terraform"))
if not data_dir.is_absolute():
    data_dir = ROOT / data_dir

pytestmark = pytest.mark.skipif(not TF or not data_dir.exists(),
                                reason="terraform not installed or not initialised (run terraform init)")


@pytest.mark.parametrize("preset,frameworks,extra_region,custom_spokes", [
    ("standard", ["WAF"], False, False),
    ("maximum", ["WAF", "NIS2", "DORA"], True, False),
    ("high", ["WAF", "DORA"], False, True),
])
def test_generated_tfvars_plan(cfg, tmp_path, preset, frameworks, extra_region, custom_spokes):
    cfg.apply_resilience(preset)
    cfg.frameworks = frameworks
    cfg.alert_email_addresses = ["oncall@contoso.com"]
    if extra_region:
        cfg.add_identity_region()
    if custom_spokes:
        from lzdesigner.model import NsgRule
        cfg.add_spoke("web").nsg_rules = [NsgRule("Allow-HTTPS-From-Hub", 300, [cfg.hub_address_space], ["443"]),
                                          NsgRule("Deny-Legacy", 310, ["10.0.0.0/8"], ["1433-1434"], access="Deny")]
        cfg.add_spoke("data")
    compliance.enforce(cfg)
    var_file = tmp_path / "designer.tfvars"
    var_file.write_text(tfvars.render(cfg))
    proc = subprocess.run([TF, "test", "-no-color", "-test-directory=gui/tests/terraform", f"-var-file={var_file}"],
                          cwd=ROOT, capture_output=True, text=True, timeout=600)
    assert proc.returncode == 0, proc.stdout + proc.stderr
    assert "1 passed, 0 failed" in proc.stdout
