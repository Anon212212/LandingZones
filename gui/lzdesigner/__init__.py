"""Landing Zone Designer – core library (no GUI dependencies).

model       configuration model mirroring the Terraform variables
catalog     regions, sizes and presets offered in the GUI
validation  checks that mirror (and extend) the Terraform validations
tfvars      renders terraform.tfvars (HCL)
compliance  WAF / NIS2 / DORA control catalogue, evaluation and enforcement
diagram     live architecture diagram (SVG and editable draw.io)
"""

__version__ = "0.1.0"
