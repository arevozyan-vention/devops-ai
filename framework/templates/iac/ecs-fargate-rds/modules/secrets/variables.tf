variable "project_name" {
  description = "Short project identifier; used as the leading path segment in the secret name."
  type        = string
}

variable "env" {
  description = "Environment name (dev | stage | prod)."
  type        = string
}

variable "name_prefix" {
  description = "Prefix used in tags / display names."
  type        = string
}

variable "common_tags" {
  description = "Tags applied to every secret."
  type        = map(string)
  default     = {}
}

variable "secret_keys" {
  description = "Application secret keys to provision (e.g. DATABASE_PASSWORD)."
  type        = list(string)
  default     = []
}

# Per-secret byte_length override for the random hex generator. Each entry
# maps a key in `secret_keys` to a length in BYTES (output length is 2× hex
# chars). Keys not listed default to 32 bytes (64 hex chars) — matches what
# JWT / cipher-key conventions expect. Use this to satisfy app-specific
# constraints, e.g.:
#   secret_byte_lengths = {
#     AP_ENCRYPTION_KEY = 16   # → 32 hex chars (apps that want 16-byte AES key)
#   }
variable "secret_byte_lengths" {
  description = "Per-secret byte length override (key → bytes). Default 32 if unspecified."
  type        = map(number)
  default     = {}
}

variable "recovery_window_in_days" {
  description = "Number of days AWS retains the secret after delete (0 = immediate)."
  type        = number
  default     = 0
}
