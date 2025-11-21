# LandingZones

# Hub & Spoke Networking Deployment with HA NVA – Terraform

This Terraform configuration deploys an Azure **Hub & Spoke network topology** with a **high-availability (HA) Network Virtual Appliance (NVA)** pair behind an **Internal Load Balancer**, along with multiple spokes, management infrastructure, Azure Bastion, and routing.

This design is suitable for:

- Enterprise landing zones  
- Azure Virtual Desktop (AVD)  
- Segmented shared/prod workloads  
- Appliance-based routing requirements  
- Lab or production environments needing HA network security appliances  

---

#  Architecture Overview

##  Hub VNet – `10.145.0.0/24`

| Subnet Name           | CIDR             | Role          | Color        |
|-----------------------|------------------|---------------|--------------|
| `nva-external-snet`   | `10.145.0.0/27`  | NVA External  | 🟥 Critical   |
| `nva-internal-snet`   | `10.145.0.32/27` | NVA Internal  | 🟥 Critical   |
| `mgmt-snet`           | `10.145.0.64/27` | Management    | 🟦 Management |
| `AzureBastionSubnet`  | `10.145.0.96/27` | Bastion       | 🟩 Access     |

---

##  Shared VNet – `10.145.1.0/24`

| Subnet Name        | CIDR             | Purpose          | Color     |
|--------------------|------------------|-------------------|-----------|
| `shared-app-snet`  | `10.145.1.0/24`  | Shared workloads  | 🟨 Shared |

---

##  Prod VNet – `10.145.2.0/24`

| Subnet Name      | CIDR             | Purpose           | Color   |
|------------------|------------------|--------------------|---------|
| `prod-app-snet`  | `10.145.2.0/24`  | Production apps    | 🟧 Prod |

---

##  AVD VNet – `10.145.3.0/24`

| Subnet Name              | CIDR             | Purpose              | Color |
|--------------------------|------------------|-----------------------|-------|
| `avd-sessionhosts-snet`  | `10.145.3.0/24`  | AVD Session Hosts     | 🟪 AVD |

---

#  High Availability NVA Pair

Two Linux-based NVAs are deployed for high availability:

- **nva-1 → Zone 1**  
- **nva-2 → Zone 2**

### NVA NIC Layout

| NIC Type     | NVA1 IP        | NVA2 IP        | Subnet              |
|--------------|----------------|----------------|----------------------|
| External NIC | `10.145.0.4`   | `10.145.0.5`   | `nva-external-snet`  |
| Internal NIC | `10.145.0.36`  | `10.145.0.37`  | `nva-internal-snet`  |

---

#  Internal Load Balancer (ILB)

- **LB Frontend IP:** `10.145.0.34`  
- Located in: `nva-internal-snet`  
- Uses **HA Ports** to forward *all* traffic  
- Backend pool contains both NVAs’ internal NICs  
- Health probe: **TCP 22**

### Purpose of ILB

Provides active-active flow distribution for:

- East–west traffic  
- Spoke-to-spoke routing  
- Spoke-to-Internet routing (if NVAs perform NAT)  
- On-prem routing (if VPN/ER gateway exists)  

---

# Azure Bastion

Azure Bastion is deployed in:

- **Subnet:** `AzureBastionSubnet`  
- **Public IP:** Standard SKU  

Provides secure SSH/RDP access without any VM public IP exposure.

Used for:

- NVA management  
- Management subnet access  
- Workload VM access  

---

# 🛣 Routing (UDRs)

Each spoke subnet forwards all traffic to the NVA HA Load Balancer:

