terraform {
  required_version = ">= 1.9"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.70"
    }
  }

  # [OpEx] Keep state remotely with Entra ID auth (no storage keys), versioning
  # and soft delete on the container. Replace with your own details.
  # backend "azurerm" {
  #   resource_group_name  = "rg-tfstate"
  #   storage_account_name = "sttfstate<unique>"
  #   container_name       = "tfstate"
  #   key                  = "landingzones.tfstate"
  #   use_azuread_auth     = true
  # }
}

provider "azurerm" {
  # null → falls back to the ARM_SUBSCRIPTION_ID environment variable.
  subscription_id = var.subscription_id

  # [Security] Talk to storage with Entra ID, never shared keys.
  storage_use_azuread = true

  features {
    resource_group {
      # [Reliability] Never let Terraform delete an RG holding unmanaged resources.
      prevent_deletion_if_contains_resources = true
    }

    storage {
      # [Security] The flow-log storage account is firewalled; Terraform only
      # needs the management plane.
      data_plane_available = false
    }

    log_analytics_workspace {
      permanently_delete_on_destroy = false
    }
  }
}
