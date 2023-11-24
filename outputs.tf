output "s3_website_endpoint" {
  description = "The domain name of the S3 website endpoint"
  value       = aws_s3_bucket_website_configuration.website_bucket_hosting_configuration.website_endpoint
}

output "cloudfront_domain_endpoint" {
  description = "The domain name of the CloudFront distribution"
  value       = aws_cloudfront_distribution.website_bucket_distribution.domain_name
}
