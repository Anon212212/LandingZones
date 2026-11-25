terraform {
  required_version = ">= 1.9"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.70"
    }
  }

  # Remote state per client (see scripts/bootstrap.sh for creating the account):
  # backend "azurerm" {
  #   resource_group_name  = "rg-tfstate"
  #   storage_account_name = "<state account>"
  #   container_name       = "tfstate"
  #   key                  = "client-c-fortinet-active-standby.tfstate"
  #   use_azuread_auth     = true
  # }
}

provider "azurerm" {
  subscription_id = var.subscription_id
  features {}
}
