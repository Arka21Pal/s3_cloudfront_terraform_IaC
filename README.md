Let's go over the infrastructure utilised in this repo and (some) specific notes about the deployment.

1. The bucket itself, through `resource "aws_s3_bucket" "website_bucket"`:
    - Using `object_ownership = "BucketOwnerEnforced"` forcibly disallows public read access to the bucket. Essentially, the bucket can only really be accessed by the bucket owner and any specific entities allowed in the bucket policy.
2. Uploading files to the bucket; this part required me to get into some HCL (Hashicorp Configuration Language) trickery for the first time.
    - Step 1: Define the content type of the files to be uploaded.
    ```
    content_types = {
        "html" = "text/html",
        "css"  = "text/css",
        "js"   = "application/javascript",
        "jpg"  = "image/jpeg",
        "png"  = "image/png",
        "json" = "text/json",
        #     "map" = "application/json+map"
    }
    ```
    - Step 2 is to declare the files I need to upload. Since I'm not going to do that statically, here goes a loop:
    ```
    keys = fileset(var.file_path, "**") # file_path is a static variable pointing to the root directory of my files
    modified_keys = toset([
    for key in local.keys: # For every file found in the path
      key if !(strcontains(key, ".git")) # If the file_path does not contain ".git" (do not include the ".git" directory)
    ]) # Create a set of strings which are filepaths to files other than in the ".git" directory

    objects = { # Define a variable called "objects" with sub-variables which will be used in the function later
        for key in local.modified_keys : key => { # Go over the set defined earlier
            # Define the three variables in a loop, so as to get all of the relevant values to be used later
            content_type = lookup(local.content_types, reverse(split(".", key))[0], "text/html") # Put the correct content type using the dictionary defined earlier
            source       = "${var.file_path}/${key}" # The full filepath
            extension = reverse(split(".", key))[0] # Split the name of the file, reverse it to get the extension first, then take the first string
            }
        }
    ```
3. I needed to use AES256 to encrypt objects in S3 to be able to use that as an origin with Cloudfront.
4. The CORS configuration for the bucket needs to allow at least the "HEAD" and "GET" options for Cloudfront to be able to access content from the origin (in this case, S3)
5. The identifier used in the IAM role must be of the format: `identifiers = ["arn:aws:iam::cloudfront:user/CloudFront Origin Access Identity ${aws_cloudfront_origin_access_identity.website_bucket_OAI.id}"]` as of 2023-12-27. This format is a topic of contention amongst many using Terraform and AWS services, but as of right now, following the official documentation for Cloudfront identifier from AWS, this is the correct way to define it (and as of my testing, this is the only format that works right now).
6. On DNS:
    - Create a primary zone (required to manage domains, created automatically for Route53 domains)
    - Create a CNAME record to redirect a subdomain to the Cloudfront distribution.
        - If it's just a subdomain of the main domain, a distinct hosted zone is not required. However, if this is more that a level down, I would need a separate hosted domain.
    - Create a certificate.
    - I needed to create subdomain validation records to validate that I own the domain. AWS provides specific servers to validate domains, which can be utilised using this piece of logic below:
        - Made for multiple subdomains:
        ```
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
        ```
    - Then, a new resource to use these domains for validation would look like:
    ```
    # Employ certificate validation
    resource "aws_acm_certificate_validation" "subdomain_cert_validation" {
      certificate_arn = aws_acm_certificate.subdomain_cert.arn
      validation_record_fqdns = [for r in aws_route53_record.subdomain_cert_validation_records : r.fqdn]
    }
    ```
7. Finally, let's go over the configuration of the Cloudfront distribution. I will mention a few specific options but for the most part, Terraform documentation is pretty good.
    - `origin` configuration (easy because I'm using S3)
    - `default_cache_behavior` for caching. Custom cache behaviour can be configured but I didn't need it for this project.
    - `aliases`: Important so that Cloudfront knows which URLs will redirect to it.
    - `custom_error_response` for error responses. In my template I have defined pages for all `4XX` and `5XX` error responses.
    - `viewer_certificate`: Parameters for viewers accessing the site.
        - `minimum_protocol_version` needs to be selected from a specific list defined by AWS.

This is my attempt to make some simple infrastructure for static websites. The main aim of this endeavour was to learn a little bit about Terraform, and I am pleased with what I have seen till now!
