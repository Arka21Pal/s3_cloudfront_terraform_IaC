# Define local variables
locals {
  s3_origin_id = format("%s-origin", aws_s3_bucket.website_bucket.bucket)
  file_path_1 = var.file_path_1
  file_path_2 = var.file_path_2
  file_path_3 = var.file_path_3
}

# Define bucket
resource "aws_s3_bucket" "website_bucket" {
  bucket        = var.bucket_name # Needs an unique name
  force_destroy = true # Deletes S3 bucket even with files in it, not possible with Cloudformation
  tags = var.tags
}

# Define ownership controls for bucket
# Relevant: https://github.com/hashicorp/terraform-provider-aws/issues/28353
resource "aws_s3_bucket_ownership_controls" "website_bucket_controls" {
  bucket = aws_s3_bucket.website_bucket.id
  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

# Allow public read ACLs
resource "aws_s3_bucket_public_access_block" "website_bucket_public_access" {
  bucket = aws_s3_bucket.website_bucket.id

  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

# Grant public-read access using an ACL
resource "aws_s3_bucket_acl" "website_bucket_public_read_acl" {
  depends_on = [
    aws_s3_bucket_ownership_controls.website_bucket_controls,
    aws_s3_bucket_public_access_block.website_bucket_public_access,
  ]

  bucket = aws_s3_bucket.website_bucket.id
  acl    = "public-read"
}

# Disable versioning of objects in bucket
resource "aws_s3_bucket_versioning" "website_bucket_versioning_status" {
  bucket = aws_s3_bucket.website_bucket.id
  versioning_configuration {
    status = "Disabled"
  }
}

# Upload files to S3
resource "aws_s3_object" "website_bucket_upload_object_1" {
  for_each    = fileset(local.file_path_1, "*")
  bucket      = aws_s3_bucket.website_bucket.bucket
  key         = each.value
  source      = "${local.file_path_1}/${each.value}"
  source_hash = filemd5("${local.file_path_1}/${each.value}")
  force_destroy = true
  content_type = "text/html"
}

# Upload files to S3
resource "aws_s3_object" "website_bucket_upload_object_2" {
  for_each    = fileset(local.file_path_2, "*")
  bucket      = aws_s3_bucket.website_bucket.bucket
  key         = "${key2_suffix}/${each.value}"
  source      = "${local.file_path_2}/${each.value}"
  source_hash = filemd5("${local.file_path_2}/${each.value}")
  force_destroy = true
  content_type = "application/json"
}

# Upload files to S3
resource "aws_s3_object" "website_bucket_upload_object_3" {
  for_each    = fileset(local.file_path_3, "*")
  bucket      = aws_s3_bucket.website_bucket.bucket
  key         = "${var.key3_suffix}/${each.value}"
  source      = "${local.file_path_3}/${each.value}"
  source_hash = filemd5("${local.file_path_3}/${each.value}")
  force_destroy = true
  content_type = "application/json"
}

# Configure SSE with AES256 with default S3 key
resource "aws_s3_bucket_server_side_encryption_configuration" "website_bucket_SSE" {
  bucket = aws_s3_bucket.website_bucket.id

  # This is so that Cloudfront could read my files. Anything other than AES256 and Cloudfront doesn't support hosting files using S3 as an origin
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "AES256"
    }
  }
}

# ---


# S3 bucket CORs configuration
resource "aws_s3_bucket_cors_configuration" "website_bucket_cors_configuration" {
  bucket = aws_s3_bucket.website_bucket.id

  cors_rule {
    allowed_headers = ["*"]
    allowed_methods = ["GET"]
    allowed_origins = ["${aws_cloudfront_distribution.website_bucket_distribution.domain_name}"]
    expose_headers  = ["ETag"]
    max_age_seconds = 3600
  }
}

# S3 bucket website configuration
resource "aws_s3_bucket_website_configuration" "website_bucket_hosting_configuration" {
  bucket = aws_s3_bucket.website_bucket.id

  index_document {
    suffix = "index.html"
  }

  error_document {
    key = "error.html"
  }
}

# ---

# IAM access policy for S3
data "aws_iam_policy_document" "website_bucket_IAM_policy" {
  statement {
    principals {
      type = "AWS"
      identifiers = ["*"]
    }

    effect = "Allow"

    actions = [
      "s3:GetObject"
    ]

    resources = [
      "${aws_s3_bucket.website_bucket.arn}/*",
    ]
  }
}

# Utilise configured IAM policy for S3 bucket
resource "aws_s3_bucket_policy" "website_bucket_IAM_policy" {
  bucket = aws_s3_bucket.website_bucket.id
  policy = data.aws_iam_policy_document.website_bucket_IAM_policy.json
}

# ---

# Create Cloudfront distribution using OAI
resource "aws_cloudfront_distribution" "website_bucket_distribution" {
  comment = "This is the definition of the Cloudfront distribution for website_bucket"

  enabled = true

  origin {
    origin_id   = local.s3_origin_id
    domain_name = aws_s3_bucket_website_configuration.website_bucket_hosting_configuration.website_endpoint

    # https://stackoverflow.com/questions/54097734/why-am-i-getting-a-customoriginconfig-instead-of-s3originconfig
    # https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudfront_distribution#custom-origin-config-arguments
    custom_origin_config {
      http_port = "80"
      https_port = "443"
      origin_protocol_policy = "http-only" # This is because we are using S3's web-hosting features as a back-end, which are HTTP only
      origin_ssl_protocols = ["TLSv1", "TLSv1.1", "TLSv1.2", "SSLv3"]
    }
  }

  # https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudfront_distribution#cache-behavior-arguments
  default_cache_behavior {
    allowed_methods          = ["GET", "HEAD"]
    cached_methods           = ["GET", "HEAD"]
    target_origin_id         = local.s3_origin_id
    cache_policy_id          = "b2884449-e4de-46a7-ac36-70bc7f1ddd6d" # https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/using-managed-cache-policies.html#managed-cache-caching-optimized-uncompressed
    origin_request_policy_id = "88a5eaf4-2fd4-4709-b370-b4c650ea3fcf" # https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/using-managed-origin-request-policies.html#managed-origin-request-policy-cors-s3
    viewer_protocol_policy   = "redirect-to-https"
  }

  default_root_object = "index.html"
  is_ipv6_enabled     = false
  price_class         = "PriceClass_100"

  # Error response for 4XX and 5XX codes
  custom_error_response {
    error_caching_min_ttl = 60
    error_code            = 400
    response_code         = 200
    response_page_path    = "/error.html"
  }

  custom_error_response {
    error_caching_min_ttl = 60
    error_code            = 500
    response_code         = 200
    response_page_path    = "/index.html"
  }

  restrictions {
    geo_restriction {
      restriction_type = "whitelist"
      locations        = ["US", "CA", "GB", "DE", "FR", "IN"]
    }
  }

  tags = var.tags

  viewer_certificate {
    # https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudfront_distribution#cloudfront_default_certificate
    cloudfront_default_certificate = true # Change this for custom domain names
  }
}
