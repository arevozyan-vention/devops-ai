variable "name_prefix" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "sku" {
  type    = string
  default = "standard"
}

variable "purge_protection" {
  type    = bool
  default = false
}

variable "soft_delete_days" {
  type    = number
  default = 7
}

variable "secret_names" {
  type        = list(string)
  description = "Names of placeholder secrets to create (operator populates values later)."
  default     = []
}

# Per-secret byte_length override for the random hex generator. Each entry
# maps a name in `secret_names` to a length in BYTES (output is 2× hex chars).
# Names not listed default to 32 bytes (64 hex chars). Use this to satisfy
# app-specific constraints, e.g.:
#   secret_byte_lengths = {
#     "ap-encryption-key" = 16   # → 32 hex chars
#   }
variable "secret_byte_lengths" {
  type        = map(number)
  description = "Per-secret byte length override (name → bytes). Default 32 if unspecified."
  default     = {}
}

variable "tags" {
  type    = map(string)
  default = {}
}
