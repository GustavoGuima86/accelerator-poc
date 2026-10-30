# -----------------------------------------------------------------------------
# SSM document that runs the benchmark + report generation on the instance.
# Driving the instance via SSM Run Command (rather than SSH or user-data-only)
# means the benchmark can be re-run on demand, any time after apply, without
# opening any inbound ports.
# -----------------------------------------------------------------------------
resource "aws_ssm_document" "run_benchmark" {
  name            = "${var.project_name}-run-benchmark"
  document_type   = "Command"
  document_format = "YAML"

  content = yamlencode({
    schemaVersion = "2.2"
    description   = "Runs the global latency benchmark and publishes the HTML report to S3."
    mainSteps = [
      {
        action = "aws:runShellScript"
        name   = "runBenchmark"
        inputs = {
          # HTTP readiness wait (<=10 min/target) + DB readiness wait + measuring.
          timeoutSeconds = 3600
          runCommand = [
            templatefile("${path.module}/templates/run_benchmark.sh.tpl", {
              client_region    = data.aws_region.current.name
              artifacts_bucket = aws_s3_bucket.artifacts.id
              reports_bucket   = aws_s3_bucket.reports.id
            })
          ]
        }
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# Automatically runs the benchmark once, right after the instance and all
# targets exist, so a working report is available without any manual step.
# Re-running later (e.g. to refresh the report) is done with:
#   ./scripts/trigger_benchmark.sh
# which uses the same SSM document and instance.
# -----------------------------------------------------------------------------
resource "null_resource" "initial_benchmark_run" {
  triggers = {
    instance_id = aws_instance.benchmark.id
    document    = aws_ssm_document.run_benchmark.name
    targets_md5 = md5(jsonencode(var.targets))
    db_enabled  = nonsensitive(var.db_config != null)
    wait_for    = join(",", var.wait_for)
  }

  provisioner "local-exec" {
    command = "${var.trigger_script_path} '${aws_instance.benchmark.id}' '${aws_ssm_document.run_benchmark.name}' '${data.aws_region.current.name}'"
  }

  depends_on = [
    aws_s3_object.benchmark_script,
    aws_s3_object.db_benchmark_script,
    aws_s3_object.report_script,
    aws_s3_object.targets,
    aws_iam_role_policy.benchmark_s3,
    aws_iam_role_policy_attachment.ssm_core,
  ]
}
