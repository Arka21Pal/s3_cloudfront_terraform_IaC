variable file_path_1 {
    type = string
    default = ""
}

variable file_path_2 {
    type = string
    default = ""
}

variable file_path_3 {
    type = string
    default = ""
}

variable bucket_name {
    type = string
    default = ""
}

variable "tags" {
  type = map(string)
  default = {
    Name = ""
    Environment = ""
  }
}
