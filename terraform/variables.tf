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

variable "group_device_id" {
  description = "Device id of the Govee app group (sku SameModeGroup) containing all controlled bulbs, used for the single sunset-on/1am-off power call. Find it by invoking the Lambda with {\"action\":\"list_devices\"}."
  type        = string
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
  description = "Color temperature at 11pm local time"
  type        = number
  default     = 2200
}

variable "night_kelvin" {
  description = "Color temperature at the last fade point, a few minutes before the 1am shutoff. The fade phase keeps warming from end_kelvin down to this instead of holding flat."
  type        = number
  default     = 2000
}

variable "start_brightness" {
  description = "Brightness percent (1-100) at sunset"
  type        = number
  default     = 60
}

variable "evening_brightness" {
  description = "Brightness percent (1-100) at 11pm local time"
  type        = number
  default     = 30
}

variable "end_brightness" {
  description = "Brightness percent (1-100) just before the 1am shutoff"
  type        = number
  default     = 10
}

variable "fade_step_count" {
  description = "Number of extra warming/dimming points between 11pm and 1am"
  type        = number
  default     = 3
}

variable "fade_end_buffer_minutes" {
  description = "Minutes before 1am that the last fade point lands, so it doesn't fire right on top of the 1am off step"
  type        = number
  default     = 25
}

variable "step_count" {
  description = "Number of points between sunset and 11pm, including both ends"
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
