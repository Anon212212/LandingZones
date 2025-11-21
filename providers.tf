terraform {
  required_version = ">= 1.6"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.105"
    }
  }
  # Optional: remote state (replace with your storage details)
  # backend "azurerm" {
  #   resource_group_name  = "tfstate-rg"
  #   storage_account_name = "tfstateacct123"
  #   container_name       = "tfstate"
  #   key                  = "landingzones.tfstate"
  # }
}

provider "azurerm" {
  features {}
}