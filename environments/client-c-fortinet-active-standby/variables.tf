variable "subscription_id" {
  description = "The client's Azure subscription."
  type        = string
}

variable "admin_password" {
  description = "Initial firewall admin password. Pass via TF_VAR_admin_password or a secret store – never commit it."
  type        = string
  sensitive   = true
}

variable "fortigate_license_tokens" {
  description = "FortiFlex tokens, one per FortiGate (fw01, fw02). Pass via TF_VAR_fortigate_license_tokens or a secret store."
  type        = list(string)
  sensitive   = true
}
