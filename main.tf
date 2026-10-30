locals {
  # Extra payload sizes for the interactive page's size selector (the 1 MB file
  # is the module's built-in sample asset). Both origins hold identical files.
  extra_assets = {
    "dummy-10kb.bin"  = "${path.module}/files/dummy-10kb.bin"
    "dummy-100kb.bin" = "${path.module}/files/dummy-100kb.bin"
    "dummy-5mb.bin"   = "${path.module}/files/dummy-5mb.bin"
  }
}

module "static_site" {
  source = "./modules/static_site"

  project_name      = var.project_name
  index_html_path   = "${path.module}/files/index.html"
  sample_asset_path = "${path.module}/files/dummy-1mb.bin"
  extra_assets      = local.extra_assets
}

# Deliberately insecure, public S3 website-hosting bucket with the SAME
# sample files as module.static_site, used only to produce an honest
# "direct access" baseline for the latency benchmark. The OAC-protected
# bucket in module.static_site cannot be used for this because it correctly
# refuses direct requests (that's the point of OAC).
module "insecure_direct_site" {
  source = "./modules/insecure_direct_site"

  project_name      = var.project_name
  index_html_path   = "${path.module}/files/index.html"
  sample_asset_path = "${path.module}/files/dummy-1mb.bin"
  extra_assets      = local.extra_assets
}

module "api_endpoint" {
  source = "./modules/api_endpoint"

  providers = {
    aws                    = aws
    aws.global_accelerator = aws.global_accelerator
  }

  project_name           = var.project_name
  vpc_id                 = var.vpc_id
  subnet_ids             = var.subnet_ids
  allowed_cidr_blocks    = var.allowed_cidr_blocks
  mock_api_response_body = var.mock_api_response_body
  endpoint_group_region  = var.aws_region
}

locals {
  benchmark_targets = [
    {
      name      = "static_direct_s3_page"
      label     = "Direct S3 website (insecure, web page)"
      category  = "static"
      optimized = false
      url       = module.insecure_direct_site.index_url
    },
    {
      name      = "static_direct_s3_asset"
      label     = "Direct S3 website (insecure, 1MB asset)"
      category  = "static"
      optimized = false
      url       = module.insecure_direct_site.sample_asset_url
    },
    {
      name      = "static_cloudfront_page"
      label     = "CloudFront (web page)"
      category  = "static"
      optimized = true
      url       = "https://${module.static_site.cloudfront_domain_name}/index.html"
    },
    {
      name      = "static_cloudfront_asset"
      label     = "CloudFront (1MB asset)"
      category  = "static"
      optimized = true
      url       = "https://${module.static_site.cloudfront_domain_name}/${module.static_site.sample_asset_key}"
    },
    {
      name      = "static_oac_protected_direct_blocked"
      label     = "Direct S3 (OAC-protected bucket, expected to fail)"
      category  = "security"
      optimized = false
      url       = "https://${module.static_site.bucket_regional_domain_name}/index.html"
    },
    {
      name      = "api_direct_alb"
      label     = "Direct ALB"
      category  = "api"
      optimized = false
      url       = "http://${module.api_endpoint.direct_alb_dns_name}/"
    },
    {
      name      = "api_global_accelerator"
      label     = "AWS Global Accelerator"
      category  = "api"
      optimized = true
      url       = "http://${module.api_endpoint.global_accelerator_ip[0]}/"
    },
  ]
}

# -----------------------------------------------------------------------------
# Aurora PostgreSQL global database: writer in the far region, read replica
# (with write forwarding) in the near region, plus the access paths compared
# by the benchmark. Needs the benchmark client, whose public IP is the only
# address allowed to reach the public writer endpoint.
# -----------------------------------------------------------------------------
locals {
  aurora_enabled = var.enable_aurora && var.enable_benchmark_client

  # Addresses allowed on the public DB paths: the Frankfurt benchmark client
  # and the near-region NAT gateway. The benchmark EC2 and interactive DB
  # probe Lambda both leave from this one stable address.
  db_client_cidrs = local.aurora_enabled ? concat(
    ["${module.vpc_near[0].nat_public_ip}/32"],
    var.aurora_extra_client_cidrs,
  ) : []

  interactive_enabled    = var.enable_interactive_page
  interactive_db_enabled = local.aurora_enabled && var.enable_interactive_page
}

# Dedicated VPCs: the account's default VPCs share 172.31.0.0/16 in every
# region, which VPC peering cannot connect.
module "vpc_far" {
  count  = local.aurora_enabled ? 1 : 0
  source = "./modules/vpc"

  name       = "${var.project_name}-far"
  cidr_block = var.far_vpc_cidr
}

module "vpc_near" {
  count  = local.aurora_enabled ? 1 : 0
  source = "./modules/vpc"

  providers = {
    aws = aws.client
  }

  name       = "${var.project_name}-near"
  cidr_block = var.near_vpc_cidr
  # Benchmark + probe use private subnets. NAT gives them outbound access and
  # one stable egress IP for the public database baseline and GA endpoint SG.
  enable_nat = local.aurora_enabled
}

module "vpc_peering" {
  count  = local.aurora_enabled ? 1 : 0
  source = "./modules/vpc_peering"

  providers = {
    aws.requester = aws.client
    aws.accepter  = aws
  }

  name                             = "${var.project_name}-near-to-far"
  requester_vpc_id                 = module.vpc_near[0].vpc_id
  requester_dns_resolution_enabled = false
  requester_cidr                   = module.vpc_near[0].cidr_block
  requester_route_table_ids        = module.vpc_near[0].route_table_ids
  accepter_vpc_id                  = module.vpc_far[0].vpc_id
  accepter_dns_resolution_enabled  = true
  accepter_cidr                    = module.vpc_far[0].cidr_block
  accepter_route_table_ids         = module.vpc_far[0].route_table_ids
}

module "aurora" {
  count  = local.aurora_enabled ? 1 : 0
  source = "./modules/aurora_global"

  providers = {
    aws           = aws
    aws.secondary = aws.client
  }

  name           = var.project_name
  engine_version = var.aurora_engine_version
  min_acu        = var.aurora_min_acu
  max_acu        = var.aurora_max_acu

  primary_vpc_id       = module.vpc_far[0].vpc_id
  primary_subnet_ids   = module.vpc_far[0].subnet_ids
  secondary_vpc_id     = module.vpc_near[0].vpc_id
  secondary_vpc_cidr   = module.vpc_near[0].cidr_block
  secondary_subnet_ids = module.vpc_near[0].private_subnet_ids
  public_client_cidrs  = local.db_client_cidrs
}

# Access path 1: Global Accelerator. Accelerators cannot target Aurora
# directly (endpoints must be ALB/NLB/EC2/EIP), so a small TCP forwarder sits
# in the far region and the accelerator gets a second listener (port 5432) on
# the SAME static IPs as the API path.
module "db_accelerator" {
  count  = local.aurora_enabled ? 1 : 0
  source = "./modules/db_accelerator"

  providers = {
    aws                    = aws
    aws.global_accelerator = aws.global_accelerator
  }

  name                     = var.project_name
  vpc_id                   = module.vpc_far[0].vpc_id
  subnet_id                = module.vpc_far[0].subnet_ids[0]
  aurora_endpoint          = module.aurora[0].primary_endpoint
  aurora_security_group_id = module.aurora[0].primary_security_group_id
  client_cidrs             = local.db_client_cidrs
  accelerator_arn          = module.api_endpoint.accelerator_arn
  endpoint_group_region    = var.aws_region
}

# Access path 5: one HTTPS call to a function next to the database that runs
# the whole batch of queries locally.
module "db_batch_api" {
  count  = local.aurora_enabled ? 1 : 0
  source = "./modules/db_batch_api"

  name        = var.project_name
  source_dir  = "${path.module}/lambda_src"
  schema_init = local.aurora_enabled
  vpc_id      = module.vpc_far[0].vpc_id
  # This function only connects to Aurora over the local VPC route, so public
  # subnets are fine (Lambda ENIs still have no public IP) and avoid a second
  # NAT gateway in Sydney.
  subnet_ids               = module.vpc_far[0].subnet_ids
  aurora_security_group_id = module.aurora[0].primary_security_group_id
  db_host                  = module.aurora[0].primary_endpoint
  db_name                  = module.aurora[0].database_name
  db_user                  = module.aurora[0].master_username
  db_password              = module.aurora[0].master_password
  query_count              = var.db_queries_per_session
}

# Interactive page, database half: a Lambda in the NEAR region that runs one DB
# session per request against a chosen access path. Browsers cannot speak the
# Postgres protocol, so this is the HTTP face of the Frankfurt-to-Sydney paths.
module "db_probe" {
  count  = local.interactive_db_enabled ? 1 : 0
  source = "./modules/db_probe"

  providers = {
    aws = aws.client
  }

  name                    = var.project_name
  source_dir              = "${path.module}/lambda_src"
  vpc_id                  = module.vpc_near[0].vpc_id
  subnet_ids              = module.vpc_near[0].private_subnet_ids
  db_name                 = module.aurora[0].database_name
  db_user                 = module.aurora[0].master_username
  db_password             = module.aurora[0].master_password
  primary_endpoint        = module.aurora[0].primary_endpoint
  replica_endpoint        = module.aurora[0].secondary_reader_endpoint
  global_accelerator_ip   = module.api_endpoint.global_accelerator_ip[0]
  batch_api_url           = module.db_batch_api[0].function_url
  batch_api_token         = module.db_batch_api[0].token
  global_accelerator_port = 5432

  depends_on = [module.vpc_peering, module.db_accelerator]
}

# Interactive page, browser half: static HTML + a generated config.js holding
# the endpoint URLs the visitor's browser will time.
module "interactive_site" {
  count  = local.interactive_enabled ? 1 : 0
  source = "./modules/interactive_site"

  project_name    = var.project_name
  index_html_path = "${path.module}/site/index.html"

  config = {
    title        = "Global latency benchmark"
    originRegion = var.aws_region
    clientRegion = var.client_region
    static = {
      directBase     = "http://${module.insecure_direct_site.website_endpoint}"
      cloudfrontBase = "https://${module.static_site.cloudfront_domain_name}"
      page           = "index.html"
      assets = [
        { label = "10 KB", key = "dummy-10kb.bin", bytes = 10240 },
        { label = "100 KB", key = "dummy-100kb.bin", bytes = 102400 },
        { label = "1 MB", key = module.static_site.sample_asset_key, bytes = 1048576 },
        { label = "5 MB", key = "dummy-5mb.bin", bytes = 5242880 },
      ]
    }
    api = {
      directUrl      = "http://${module.api_endpoint.direct_alb_dns_name}/"
      acceleratorUrl = "http://${module.api_endpoint.global_accelerator_ip[0]}/"
    }
    db = local.interactive_db_enabled ? {
      probeUrl   = module.db_probe[0].function_url
      probeToken = module.db_probe[0].token
      paths = [
        { id = "public_direct", label = "Direct, public internet", optimized = false, writes = true },
        { id = "global_accelerator", label = "Global Accelerator", optimized = true, writes = true },
        { id = "vpc_peering", label = "VPC peering (private)", optimized = true, writes = true },
        { id = "replica_local", label = "Frankfurt replica", optimized = true, writes = true },
        { id = "batched_api", label = "One call to API next to DB", optimized = true, writes = false },
      ]
    } : null
  }
}

locals {
  db_benchmark_config = local.aurora_enabled ? {
    user                  = module.aurora[0].master_username
    password              = module.aurora[0].master_password
    database              = module.aurora[0].database_name
    port                  = module.aurora[0].port
    primary_endpoint      = module.aurora[0].primary_endpoint
    replica_endpoint      = module.aurora[0].secondary_reader_endpoint
    global_accelerator_ip = module.api_endpoint.global_accelerator_ip[0]
    db_accelerator_port   = 5432
    sessions              = var.db_sessions
    queries_per_session   = var.db_queries_per_session
    batch_api_url         = module.db_batch_api[0].function_url
    batch_api_token       = module.db_batch_api[0].token
  } : null
}

# Self-contained Frankfurt benchmark client: an EC2 instance (reachable only
# via SSM Run Command, no inbound ports) that runs a curl-based latency
# benchmark against every target above and publishes a shareable HTML report.
module "benchmark" {
  count  = var.enable_benchmark_client ? 1 : 0
  source = "./modules/benchmark"

  providers = {
    aws = aws.client
  }

  project_name             = var.project_name
  instance_type            = var.benchmark_instance_type
  vpc_id                   = local.aurora_enabled ? module.vpc_near[0].vpc_id : null
  subnet_id                = local.aurora_enabled ? module.vpc_near[0].private_subnet_ids[0] : null
  client_public_ip         = local.aurora_enabled ? module.vpc_near[0].nat_public_ip : null
  benchmark_script_path    = "${path.module}/scripts/benchmark.py"
  db_benchmark_script_path = "${path.module}/scripts/db_benchmark.py"
  report_script_path       = "${path.module}/scripts/generate_report.py"
  trigger_script_path      = "${path.module}/scripts/trigger_benchmark.sh"
  targets                  = local.benchmark_targets
  runs_per_target          = var.benchmark_runs_per_target
  db_config                = local.db_benchmark_config

  # The first benchmark run must not start before the DB paths exist.
  wait_for = local.aurora_enabled ? [
    module.vpc_peering[0].peering_connection_id,
    module.db_accelerator[0].endpoint_group_id,
    module.db_batch_api[0].function_url,
    module.aurora[0].secondary_reader_endpoint,
  ] : []
}
