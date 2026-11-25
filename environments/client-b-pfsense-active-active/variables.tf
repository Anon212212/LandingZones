variable "subscription_id" {
  description = "The client's Azure subscription."
  type        = string
}

variable "admin_password" {
  description = "Initial firewall admin password. Pass via TF_VAR_admin_password or a secret store – never commit it."
  type        = string
  sensitive   = true
}
