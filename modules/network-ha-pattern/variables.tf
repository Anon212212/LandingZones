variable "name_prefix" {
  description = "Prefix for every resource name, e.g. \"clienta-fw-prod\"."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}$", var.name_prefix))
    error_message = "name_prefix must be 2-31 chars: lowercase letters, digits, hyphens, starting with a letter."
  }
}

variable "location" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "resource_group_id" {
  description = "Scope for the active-standby failover role (custom role + assignment)."
  type        = string
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "ha_mode" {
  description = "single (1 firewall) | active-standby (2, Azure API failover, no LB) | active-active (2+, internal + external Standard LBs)."
  type        = string

  validation {
    condition     = contains(["single", "active-standby", "active-active"], var.ha_mode)
    error_message = "ha_mode must be single, active-standby or active-active."
  }
}

variable "instance_count" {
  description = "Firewalls in active-active (>= 2). Ignored for single (1) and active-standby (2)."
  type        = number
  default     = 2

  validation {
    condition     = var.instance_count >= 2 && var.instance_count <= 8
    error_message = "instance_count must be between 2 and 8."
  }
}

variable "address_space" {
  description = "Hub VNet CIDR (/24 or larger). Split into /27-equivalents: untrust, trust, mgmt, hasync."
  type        = string

  validation {
    condition     = can(cidrhost(var.address_space, 0)) && tonumber(split("/", var.address_space)[1]) <= 24
    error_message = "address_space must be a valid CIDR of /24 or larger."
  }
}

variable "zones" {
  description = "Availability Zones to spread firewalls across (round-robin). Empty list = region without zones: an Availability Set is used instead."
  type        = list(string)
  default     = ["1", "2", "3"]
}

variable "enable_mgmt_subnet" {
  description = "Create the dedicated management subnet (vendors that manage via a dedicated NIC)."
  type        = bool
  default     = true
}

variable "enable_hasync" {
  description = "Create the HA sync subnet (only used in active-standby)."
  type        = bool
  default     = false
}

variable "mgmt_source_cidrs" {
  description = "Networks allowed to reach the management interfaces (VPN, jump hosts, Bastion subnet)."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for c in var.mgmt_source_cidrs : can(cidrhost(c, 0)) && !endswith(c, "/0")])
    error_message = "mgmt_source_cidrs must be valid CIDRs and never 0.0.0.0/0."
  }
}

variable "mgmt_ports" {
  description = "Management ports opened to mgmt_source_cidrs."
  type        = list(string)
  default     = ["22", "443"]
}

variable "management_egress" {
  description = "How the management interfaces reach the Internet (licensing, updates): nat_gateway | public_ip | none."
  type        = string
  default     = "nat_gateway"

  validation {
    condition     = contains(["nat_gateway", "public_ip", "none"], var.management_egress)
    error_message = "management_egress must be nat_gateway, public_ip or none."
  }
}

variable "inbound_rules" {
  description = "Published services. Opened on the untrust NSG in every mode; in active-active they also become external LB rules (floating IP on)."
  type = list(object({
    name     = string
    protocol = string # Tcp | Udp
    port     = number
  }))
  default = []

  validation {
    condition     = alltrue([for r in var.inbound_rules : contains(["Tcp", "Udp"], r.protocol) && r.port > 0 && r.port < 65536])
    error_message = "inbound_rules: protocol must be Tcp or Udp and port 1-65535."
  }
}

variable "health_probe_port" {
  description = "Port the load balancers probe on the firewalls (active-active)."
  type        = number
  default     = 22
}

variable "health_probe_protocol" {
  description = "Tcp | Http | Https."
  type        = string
  default     = "Tcp"

  validation {
    condition     = contains(["Tcp", "Http", "Https"], var.health_probe_protocol)
    error_message = "health_probe_protocol must be Tcp, Http or Https."
  }
}

variable "health_probe_path" {
  description = "Request path for Http/Https probes."
  type        = string
  default     = "/"
}

variable "outbound_ports_per_instance" {
  description = "SNAT ports per firewall on the external LB outbound rule (active-active)."
  type        = number
  default     = 10000
}
