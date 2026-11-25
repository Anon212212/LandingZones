# Offline check that this client's configuration plans (mocked azurerm).
#   terraform init -backend=false && terraform test

mock_provider "azurerm" {}

variables {
  subscription_id = "00000000-0000-0000-0000-000000000000"
  admin_password  = "Not-a-real-Passw0rd!"
}

run "plans" {
  command = plan

  assert {
    condition     = length(output.firewalls) == 1
    error_message = "Expected 1 firewall(s) for single."
  }
}
