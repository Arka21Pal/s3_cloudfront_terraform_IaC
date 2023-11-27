# Define local variables
locals {
  s3_origin_id = format("%s-origin", aws_s3_bucket.website_bucket.bucket)

  content_types = {
    "html" = "text/html",
    "css"  = "text/css",
    "js"   = "application/javascript",
    "jpg"  = "image/jpeg",
    "png"  = "image/png",
    "json" = "text/json",
#     "map" = "application/json+map"
  }

  keys = fileset(var.file_path, "**")
  modified_keys = toset([
    for key in local.keys:
      key if !(strcontains(key, ".git"))
  ])
  objects = {
    for key in local.modified_keys : key => {
      content_type = lookup(local.content_types, reverse(split(".", key))[0], "text/html")
      source       = "${var.file_path}/${key}"
      extension = reverse(split(".", key))[0]
    }
  }
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
    object_ownership = "BucketOwnerEnforced"
  }
}

# Disable versioning of objects in bucket
resource "aws_s3_bucket_versioning" "website_bucket_versioning_status" {
  bucket = aws_s3_bucket.website_bucket.id
  versioning_configuration {
    status = "Disabled"
  }
}

# ---

resource "aws_cloudfront_origin_access_identity" "website_bucket_OAI" {
  comment = "OAI for S3 bucket"
}

# ---

# Upload files to S3
resource "aws_s3_object" "website_bucket_upload_object_1" {
  for_each = local.objects
  bucket      = aws_s3_bucket.website_bucket.bucket
  key          = each.key
  content_type = each.value.content_type
  source       = each.value.source
  source_hash  = filemd5(each.value.source)
  force_destroy = true
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
    allowed_methods = ["GET", "HEAD"]
    allowed_origins = ["${var.subdomain_FQDN}", "${aws_cloudfront_distribution.website_bucket_distribution.domain_name}"]
    expose_headers  = ["ETag"]
    max_age_seconds = 3600
  }
}

# ---

# IAM access policy for S3
data "aws_iam_policy_document" "website_bucket_IAM_policy" {
  statement {
    principals {
      type = "AWS"
      identifiers = ["arn:aws:iam::cloudfront:user/CloudFront Origin Access Identity ${aws_cloudfront_origin_access_identity.website_bucket_OAI.id}"] # https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/private-content-restricting-access-to-s3.html#private-content-restricting-access-to-s3-oai (check the format of the OAI)
#       I have no idea why "iam_arn" from Terraform didn't work for me, but the formatting above works for now.
#       identifiers = ["aws_cloudfront_origin_access_identity.website_bucket_OAI.iam_arn"]
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

# Fetch the primary zone
data "aws_route53_zone" "primary" {
  name = var.route53_public_domain
  private_zone = false
}

# Create the CNAME record to redirect to Cloudfront
resource "aws_route53_record" "subdomain_CNAME_record" {
    zone_id = data.aws_route53_zone.primary.zone_id
    name = var.route53_public_subdomain_record
    type = "CNAME" # I want to use the CNAME because I would like to know how to use this for redirections outside of AWS
    ttl = "300"
    records = [aws_cloudfront_distribution.website_bucket_distribution.domain_name]
}

# Create the certificate
resource "aws_acm_certificate" "subdomain_cert" {
    domain_name = var.subdomain_FQDN
    validation_method = "DNS"
    lifecycle {
        create_before_destroy = true
    }
    tags = var.tags
}

# Create redirects to validate certificate for subdomain
resource "aws_route53_record" "subdomain_cert_validation_records" {
  for_each = {
    for dvo in aws_acm_certificate.subdomain_cert.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  name            = each.value.name
  records         = [each.value.record]
  ttl             = 120
  type            = each.value.type
  zone_id = data.aws_route53_zone.primary.zone_id
}

# Employ certificate validation
resource "aws_acm_certificate_validation" "subdomain_cert_validation" {
  certificate_arn = aws_acm_certificate.subdomain_cert.arn
  validation_record_fqdns = [for r in aws_route53_record.subdomain_cert_validation_records : r.fqdn]
}

# ---

# Create Cloudfront distribution using OAI
resource "aws_cloudfront_distribution" "website_bucket_distribution" {
  comment = "This is the Cloudfront distribution for the CS424 project"

  enabled = true

  origin {
    origin_id = local.s3_origin_id
    domain_name = aws_s3_bucket.website_bucket.bucket_regional_domain_name

    s3_origin_config {
      origin_access_identity = aws_cloudfront_origin_access_identity.website_bucket_OAI.cloudfront_access_identity_path
    }
  }

  # https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudfront_distribution#cache-behavior-arguments
  default_cache_behavior {
    allowed_methods          = ["GET", "HEAD", "OPTIONS"]
    cached_methods           = ["GET", "HEAD"]
    target_origin_id         = local.s3_origin_id
    cache_policy_id          = "b2884449-e4de-46a7-ac36-70bc7f1ddd6d" # https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/using-managed-cache-policies.html#managed-cache-caching-optimized-uncompressed
    origin_request_policy_id = "88a5eaf4-2fd4-4709-b370-b4c650ea3fcf" # https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/using-managed-origin-request-policies.html#managed-origin-request-policy-cors-s3
    viewer_protocol_policy   = "redirect-to-https"
  }

  default_root_object = "index.html"
  is_ipv6_enabled     = false
  price_class         = "PriceClass_100"
  aliases = [var.subdomain_FQDN]
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
    acm_certificate_arn = aws_acm_certificate.subdomain_cert.arn
    ssl_support_method = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
    # https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudfront_distribution#cloudfront_default_certificate
#     cloudfront_default_certificate = true # Change this for custom domain names
  }
}
