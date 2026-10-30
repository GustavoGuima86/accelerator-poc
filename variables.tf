variable "aws_region" {
  description = "Primary AWS region where the origin resources (S3 bucket, ALB) are deployed. This simulates the 'far' region from the client's perspective."
  type        = string
  default     = "ap-southeast-2"
}

variable "global_accelerator_region" {
  description = "AWS Global Accelerator is a global service, but the Terraform/CLI API calls that manage it must target us-west-2, regardless of where the accelerator's endpoints live."
  type        = string
  default     = "us-west-2"
}

variable "client_region" {
  description = "The 'near' region simulating where end users/clients are located. The benchmark EC2 instance (and its reports bucket) are deployed here so that measured latency reflects real client-to-origin network conditions."
  type        = string
  default     = "eu-central-1"
}

variable "enable_benchmark_client" {
  description = "Whether to deploy the self-contained Frankfurt benchmark EC2 instance, reports bucket, and supporting IAM/SSM resources. Disable to skip the automated benchmarking pieces and only deploy the core CloudFront/Global Accelerator POC infrastructure."
  type        = bool
  default     = true
}

variable "benchmark_instance_type" {
  description = "EC2 instance type for the Frankfurt benchmark client (kept small/cheap; it only runs curl loops via SSM)."
  type        = string
  default     = "t3.micro"
}

variable "enable_interactive_page" {
  description = "Deploy the interactive benchmark web page. Static assets and the API are timed from the visitor's own browser. With Aurora also enabled, it includes database probes through the near-region Lambda."
  type        = bool
  default     = true
}

variable "enable_aurora" {
  description = "Deploy the Aurora PostgreSQL global database (writer in the far region, replica in the near region) and benchmark the different ways to reach it. Requires enable_benchmark_client. Aurora has no free tier: expect a few dollars per day while it runs."
  type        = bool
  default     = true
}

variable "aurora_engine_version" {
  description = "Aurora PostgreSQL version. Must support Global Database, Serverless v2 and global write forwarding (all 16.x do)."
  type        = string
  default     = "16.8"
}

variable "aurora_min_acu" {
  type    = number
  default = 0.5
}

variable "aurora_max_acu" {
  type    = number
  default = 4
}

variable "aurora_extra_client_cidrs" {
  description = "Additional CIDRs (e.g. your office IP as x.x.x.x/32) allowed to reach the public Aurora writer endpoint and Global Accelerator forwarder. The near-region NAT egress /32 is always allowed for the benchmark and interactive probe."
  type        = list(string)
  default     = []
}

variable "far_vpc_cidr" {
  description = "CIDR of the dedicated VPC in the far (database) region."
  type        = string
  default     = "10.20.0.0/16"
}

variable "near_vpc_cidr" {
  description = "CIDR of the dedicated VPC in the near (client) region. Must not overlap far_vpc_cidr (VPC peering requirement)."
  type        = string
  default     = "10.10.0.0/16"
}

variable "db_sessions" {
  description = "Fresh DB sessions measured per access path and workload."
  type        = number
  default     = 5
}

variable "db_queries_per_session" {
  description = "Sequential statements per session (the 'chatty' part of the workload)."
  type        = number
  default     = 20
}

variable "benchmark_runs_per_target" {
  description = "Number of sequential HTTP requests per target used to compute min/avg/p95 latency in the benchmark report."
  type        = number
  default     = 30
}

variable "project_name" {
  description = "Short name used to prefix and tag resources created by this POC."
  type        = string
  default     = "global-latency-poc"
}

variable "vpc_id" {
  description = "VPC ID to deploy the ALB into. Leave null to use the default VPC in the target region."
  type        = string
  default     = null
}

variable "subnet_ids" {
  description = "Subnet IDs to deploy the ALB into. Leave null to use all default subnets in the default VPC."
  type        = list(string)
  default     = null
}

variable "allowed_cidr_blocks" {
  description = "CIDR blocks allowed to reach the ALB and S3 website directly (for the 'direct access' baseline test). Restrict this to your test client's IP/CIDR in real use."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "mock_api_response_body" {
  description = "Body returned by the ALB's fixed-response listener, simulating an EKS API endpoint."
  type        = string
  default     = "{\"status\":\"ok\",\"source\":\"direct-alb-or-global-accelerator\"}"
}
