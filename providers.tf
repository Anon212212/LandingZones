terraform {
  required_version = ">= 1.9"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.70"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
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

# Connectivity subscription (hub, spokes, NVAs).
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

# [Security] Dedicated tier-0 identity subscription (DCs, vaults, tier-0
# Key Vault and Log Analytics). Same tenant as the connectivity subscription.
provider "azurerm" {
  alias           = "identity"
  subscription_id = var.identity_subscription_id

  storage_use_azuread = true

  features {
    resource_group {
      prevent_deletion_if_contains_resources = true
    }

    storage {
      data_plane_available = false
    }

    key_vault {
      # Never purge tier-0 secrets on destroy; recover if re-created.
      purge_soft_delete_on_destroy    = false
      recover_soft_deleted_key_vaults = true
    }

    recovery_service {
      # Keep recovery points if Terraform ever removes protection.
      vm_backup_stop_protection_and_retain_data_on_destroy = true
      purge_protected_items_from_vault_on_destroy          = false
    }

    virtual_machine {
      # Keep a DC's OS disk if the VM is ever destroyed.
      delete_os_disk_on_deletion = false
    }

    log_analytics_workspace {
      permanently_delete_on_destroy = false
    }
  }
}
