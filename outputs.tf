output "s3_IAM_policy_document" {
    description = "IAM policy document stating access to S3"
    value = data.aws_iam_policy_document.website_bucket_IAM_policy.json
}
output "cloudfront_domain_endpoint" {
  description = "The domain name of the CloudFront distribution"
  value       = aws_cloudfront_distribution.website_bucket_distribution.domain_name
}

output "cloudfront_domain_arn" {
  description = "The domain name of the CloudFront distribution"
  value       = aws_cloudfront_distribution.website_bucket_distribution.arn
}

output "aws_acm_certificate_domain_validation_options" {
  description = "The domain validation options for the certificate"
  value = aws_acm_certificate.subdomain_cert.domain_validation_options
}

output "aws_acm_certificate_options" {
  description = "Certificate attributes"
  value = [aws_acm_certificate.subdomain_cert.domain_name, aws_acm_certificate.subdomain_cert.status, aws_acm_certificate.subdomain_cert.type]
}
