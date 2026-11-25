from lzdesigner import compliance as c


def by_id(results):
    return {r.control.id: r for r in results}


def test_waf_only_defaults_have_no_required_failures(cfg):
    sc = c.scores(c.evaluate(cfg), cfg.frameworks)
    assert sc["WAF"]["fail"] == 0


def test_dora_enforces_and_locks(cfg):
    cfg.frameworks = ["WAF", "DORA"]
    changed = c.enforce(cfg)
    assert cfg.log_retention_days == 365
    assert cfg.identity_backup_storage_mode == "GeoRedundant"
    assert any("REL-11" in x for x in changed)
    locks = c.locked_fields(cfg)
    assert "identity_backup_storage_mode" in locks and "DORA" in locks["identity_backup_storage_mode"]
    assert "Art. 12(3)" in locks["identity_backup_storage_mode"]


def test_missing_recipients_fail_only_where_required(cfg):
    cfg.frameworks = ["WAF", "NIS2", "DORA"]
    c.enforce(cfg)
    results = c.evaluate(cfg)
    assert by_id(results)["OPS-10"].status == c.FAIL
    sc = c.scores(results, cfg.frameworks)
    assert sc["WAF"]["fail"] == 0          # advisory under WAF
    assert sc["NIS2"]["fail"] == 1 and sc["DORA"]["fail"] == 1
    cfg.alert_email_addresses = ["oncall@contoso.com"]
    assert all(s["fail"] == 0 for s in c.scores(c.evaluate(cfg), cfg.frameworks).values())


def test_waf_only_controls_hidden_for_eu_frameworks(cfg):
    cfg.frameworks = ["NIS2"]
    ids = by_id(c.evaluate(cfg))
    assert "COS-10" not in ids and "NET-01" in ids


def test_every_control_is_mapped_to_waf():
    assert all("WAF" in ctl.refs for ctl in c.CONTROLS)


def test_report_contains_disclaimer_and_frameworks(cfg):
    cfg.frameworks = ["WAF", "NIS2", "DORA"]
    md = c.report_markdown(cfg)
    assert c.DISCLAIMER in md and "| NIS2 |" in md and "Art. 21(2)(c)" in md
