# Plans the root module with a tfvars file produced by the designer
# (passed via -var-file) against mocked providers. Run from the repo root:
#   terraform test -test-directory=gui/tests/terraform -var-file=<generated.tfvars>

mock_provider "azurerm" {
  mock_data "azurerm_subscription" {
    defaults = {
      id              = "/subscriptions/00000000-0000-0000-0000-000000000000"
      subscription_id = "00000000-0000-0000-0000-000000000000"
    }
  }

  mock_data "azurerm_location" {
    defaults = {
      display_name = "North Europe"
    }
  }

  mock_data "azurerm_client_config" {
    defaults = {
      tenant_id       = "22222222-2222-2222-2222-222222222222"
      object_id       = "33333333-3333-3333-3333-333333333333"
      subscription_id = "00000000-0000-0000-0000-000000000000"
    }
  }
}

mock_provider "azurerm" {
  alias = "identity"

  mock_data "azurerm_subscription" {
    defaults = {
      id              = "/subscriptions/11111111-1111-1111-1111-111111111111"
      subscription_id = "11111111-1111-1111-1111-111111111111"
    }
  }

  mock_data "azurerm_client_config" {
    defaults = {
      tenant_id       = "22222222-2222-2222-2222-222222222222"
      object_id       = "33333333-3333-3333-3333-333333333333"
      subscription_id = "11111111-1111-1111-1111-111111111111"
    }
  }
}

mock_provider "azurerm" {
  alias = "shared"
}

mock_provider "azurerm" {
  alias = "prod"
}

mock_provider "azurerm" {
  alias = "avd"
}

run "designer_tfvars_plan" {
  command = plan

  assert {
    condition     = length(module.identity) == length(var.identity_regions)
    error_message = "Every identity region from the designer must be planned."
  }
}
