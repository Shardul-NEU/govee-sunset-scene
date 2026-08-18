variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
}

variable "govee_api_key" {
  description = "Govee Developer API key (Govee Home app -> profile icon -> Settings -> About Us -> Apply for API Key)"
  type        = string
  sensitive   = true
}

variable "govee_device_filter" {
  description = "Comma-separated sku:deviceId pairs to restrict which bulbs are controlled. Blank controls every device the API key can see."
  type        = string
  default     = ""
}

variable "latitude" {
  description = "Decimal degrees latitude"
  type        = string
}

variable "longitude" {
  description = "Decimal degrees longitude"
  type        = string
}

variable "timezone" {
  description = "IANA timezone name, e.g. America/Chicago"
  type        = string
  default     = "America/Chicago"
}

variable "start_kelvin" {
  description = "Color temperature at sunset (lower = warmer)"
  type        = number
  default     = 4300
}

variable "end_kelvin" {
  description = "Color temperature at local midnight"
  type        = number
  default     = 2200
}

variable "step_count" {
  description = "Number of points between sunset and midnight, including both ends"
  type        = number
  default     = 6
}

variable "plan_cron_utc" {
  description = "UTC cron expression for the daily 'plan tonight' run, e.g. cron(0 18 * * ? *). Must run before your earliest sunset of the year."
  type        = string
}

variable "schedule_group" {
  description = "EventBridge Scheduler group name"
  type        = string
  default     = "default"
}
