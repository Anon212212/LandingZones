variable "name" {
  type = string
}

variable "location" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "subnet_id" {
  type = string
}

variable "private_ip" {
  description = "Static private IP of the primary IP configuration."
  type        = string
}

variable "data_plane" {
  description = "untrust/trust NICs: IP forwarding + accelerated networking on."
  type        = bool
}

variable "public_ip_id" {
  description = "Public IP on the primary IP configuration (single-mode untrust, optional mgmt)."
  type        = string
  default     = null
}

variable "vip" {
  description = "Floating secondary IP config (active-standby node 0). Moved by the firewall on failover."
  type = object({
    private_ip   = string
    public_ip_id = optional(string)
  })
  default = null
}

variable "vip_ip_config_name" {
  type    = string
  default = "ipconfig-vip"
}

variable "floating" {
  description = "active-standby: ignore IP-config drift caused by firewall-driven failover."
  type        = bool
  default     = false
}

variable "join_lb_pool" {
  description = "Join lb_backend_pool_id (a plan-time-known flag; the pool ID itself is only known after apply)."
  type        = bool
  default     = false
}

variable "lb_backend_pool_id" {
  description = "Load balancer backend pool to join (active-active)."
  type        = string
  default     = null
}
