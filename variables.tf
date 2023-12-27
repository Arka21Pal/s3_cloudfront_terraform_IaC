variable file_path {
    type = string
    default = ""
}

variable bucket_name {
    type = string
    default = ""
}

variable tags {
  type = map(string)
  default = {
    Name = ""
    Environment = ""
  }
}

# ---
# Domain

variable route53_public_domain {
  type = string
  default = ""
}

variable route53_public_subdomain_record {
  type = string
  default = ""
}
