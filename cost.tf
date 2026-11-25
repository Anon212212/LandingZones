#############################################
# [Cost] Monthly budget across the landing-zone resource groups
#############################################

resource "azurerm_consumption_budget_subscription" "landing_zone" {
  count = var.monthly_budget_amount > 0 && length(var.alert_email_addresses) > 0 ? 1 : 0

  name            = "budget-${var.org_prefix}-lz-${local.suffix}"
  subscription_id = data.azurerm_subscription.current.id
  amount          = var.monthly_budget_amount
  time_grain      = "Monthly"

  time_period {
    # First day of the current month at creation time (ignored afterwards).
    start_date = formatdate("YYYY-MM-01'T'00:00:00Z", timestamp())
  }

  filter {
    dimension {
      name   = "ResourceGroupName"
      values = [azurerm_resource_group.connectivity.name, azurerm_resource_group.management.name]
    }
  }

  notification {
    enabled        = true
    threshold      = 80
    operator       = "GreaterThan"
    threshold_type = "Actual"
    contact_emails = var.alert_email_addresses
    contact_groups = local.action_group_ids
  }

  notification {
    enabled        = true
    threshold      = 100
    operator       = "GreaterThan"
    threshold_type = "Forecasted"
    contact_emails = var.alert_email_addresses
    contact_groups = local.action_group_ids
  }

  notification {
    enabled        = true
    threshold      = 100
    operator       = "GreaterThan"
    threshold_type = "Actual"
    contact_emails = var.alert_email_addresses
    contact_groups = local.action_group_ids
  }

  lifecycle {
    # start_date is only meaningful at creation.
    ignore_changes = [time_period]
  }
}
