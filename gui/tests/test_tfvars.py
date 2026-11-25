import re
from pathlib import Path

from lzdesigner import tfvars

ROOT = Path(__file__).resolve().parents[2]
TF_VARS = set(re.findall(r'^variable "([a-z0-9_]+)"', (ROOT / "variables.tf").read_text(), re.M))

# Terraform variables the designer deliberately leaves at their defaults.
NOT_EXPOSED = {"log_analytics_sku", "network_watcher_name", "network_watcher_resource_group"}


def test_every_designer_value_is_a_terraform_variable(cfg):
    assert set(tfvars.tfvars_values(cfg)) <= TF_VARS


def test_every_terraform_variable_is_covered(cfg):
    assert TF_VARS - set(tfvars.tfvars_values(cfg)) == NOT_EXPOSED


def test_render_shapes(cfg):
    text = tfvars.render(cfg)
    assert re.search(r'identity_subscription_id\s+= "11111111-1111-1111-1111-111111111111"', text)
    assert 'primary   = {' in text or 'primary = {' in text
    assert 'dc_zones      = ["1", "2"]' in text
    assert "ddos_protection_plan_id" not in text   # empty → omitted (null)


def test_strings_are_escaped(cfg):
    cfg.owner = 'team "blue"'
    assert 'owner       = "team \\"blue\\""' in tfvars.render(cfg)


def test_spokes_render_with_rules(cfg):
    from lzdesigner.model import NsgRule
    cfg.spokes[0].nsg_rules = [NsgRule("Allow-HTTPS", 300, ["10.145.0.0/24"], ["443"])]
    values = tfvars.tfvars_values(cfg)["spokes"]
    assert values["shared"]["nsg_rules"][0]["priority"] == 300
    assert "nsg_rules" not in values["prod"]
    text = tfvars.render(cfg)
    assert '"Allow-HTTPS"' in text and "spokes = {" in text


def test_spoke_subscriptions_render(cfg):
    v = tfvars.tfvars_values(cfg)
    assert v["spokes"]["shared"]["subscription"] == "shared" and v["spokes"]["avd"]["subscription"] == "connectivity"
    assert v["production_subscription_id"] == "55555555-5555-5555-5555-555555555555"
    for sp in cfg.spokes:
        sp.subscription = "connectivity"
    cfg.shared_services_subscription_id = ""
    assert "shared_services_subscription_id = " not in tfvars.render(cfg)
