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


@pytest.mark.parametrize("preset,frameworks,extra_region", [
    ("standard", ["WAF"], False),
    ("maximum", ["WAF", "NIS2", "DORA"], True),
])
def test_generated_tfvars_plan(cfg, tmp_path, preset, frameworks, extra_region):
    cfg.apply_resilience(preset)
    cfg.frameworks = frameworks
    cfg.alert_email_addresses = ["oncall@contoso.com"]
    if extra_region:
        cfg.add_identity_region()
    compliance.enforce(cfg)
    var_file = tmp_path / "designer.tfvars"
    var_file.write_text(tfvars.render(cfg))
    proc = subprocess.run([TF, "test", "-no-color", "-test-directory=gui/tests/terraform", f"-var-file={var_file}"],
                          cwd=ROOT, capture_output=True, text=True, timeout=600)
    assert proc.returncode == 0, proc.stdout + proc.stderr
    assert "1 passed, 0 failed" in proc.stdout
