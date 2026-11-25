import io
import json

from lzdesigner import pricing


def test_baseline_estimate_has_expected_lines(cfg):
    est = pricing.estimate(cfg)
    cats = est.by_category()
    assert {"Compute", "Networking", "Monitoring", "Backup", "Storage"} <= set(cats)
    assert est.total > est.fixed > 0
    assert est.source == "baseline" and est.currency == "EUR"


def test_choices_move_the_estimate(cfg):
    base = pricing.estimate(cfg).total
    cfg.bastion_sku = "Basic"
    cfg.enable_nat_gateway = False
    cheaper = pricing.estimate(cfg).total
    assert cheaper < base
    cfg.apply_resilience("maximum")
    cfg.ddos_protection_plan_id = "/subscriptions/x/resourceGroups/y/providers/Microsoft.Network/ddosProtectionPlans/z"
    assert pricing.estimate(cfg).total > base + 2900


def test_hybrid_benefit_reduces_dc_cost(cfg):
    dc = lambda est: sum(line.monthly for line in est.lines if line.item.startswith("DC VMs"))  # noqa: E731
    with_licence = dc(pricing.estimate(cfg))
    cfg.dc_hybrid_benefit = True
    assert dc(pricing.estimate(cfg)) < with_licence


def test_pick_vm_rate_ignores_spot_and_windows_for_linux():
    items = [
        {"type": "Consumption", "unitOfMeasure": "1 Hour", "productName": "Virtual Machines Dsv5 Series", "skuName": "D2s v5", "meterName": "D2s v5", "retailPrice": 0.11},
        {"type": "Consumption", "unitOfMeasure": "1 Hour", "productName": "Virtual Machines Dsv5 Series", "skuName": "D2s v5 Spot", "meterName": "D2s v5 Spot", "retailPrice": 0.02},
        {"type": "Consumption", "unitOfMeasure": "1 Hour", "productName": "Virtual Machines Dsv5 Series Windows", "skuName": "D2s v5", "meterName": "D2s v5", "retailPrice": 0.20},
        {"type": "Reservation", "unitOfMeasure": "1 Hour", "productName": "Virtual Machines Dsv5 Series", "skuName": "D2s v5", "meterName": "D2s v5", "retailPrice": 0.05},
    ]
    assert pricing.pick_vm_rate(items, "linux") == 0.11
    assert pricing.pick_vm_rate(items, "windows") == 0.20


def test_live_refresh_uses_retail_api(cfg):
    calls = []

    def opener(url, timeout):
        calls.append(url)
        windows = "Standard_D2s_v5" in url and ("westeurope" in url or "northeurope" in url)
        items = [{"type": "Consumption", "unitOfMeasure": "1 Hour", "productName": "Virtual Machines Dsv5 Series",
                  "skuName": "D2s v5", "meterName": "D2s v5", "retailPrice": 0.12},
                 {"type": "Consumption", "unitOfMeasure": "1 Hour", "productName": "Virtual Machines Dsv5 Series Windows",
                  "skuName": "D2s v5", "meterName": "D2s v5", "retailPrice": 0.22}] if windows else []
        return io.BytesIO(json.dumps({"Items": items, "NextPageLink": None}).encode())

    book = pricing.refresh_live_prices(cfg, "EUR", opener=opener)
    assert book.live and book.currency == "EUR"
    assert book.vm[("northeurope", "Standard_D2s_v5", "linux")] == 0.12
    assert book.vm[("westeurope", "Standard_D2s_v5", "windows")] == 0.22
    assert all("currencyCode=EUR" in u and "prices.azure.com" in u for u in calls)
    est = pricing.estimate(cfg, book)
    assert est.source == "live" and est.currency == "EUR"


def test_default_currency_is_euro():
    assert pricing.PriceBook().currency == "EUR" and pricing.BASELINE_CURRENCY == "EUR"
