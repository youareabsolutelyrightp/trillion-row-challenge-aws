# 1 trillion row challenge on AWS

This repository compares two AWS implementations of 1TRC on spot compute:

- ClickHouse
- A custom Rust reducer on AWS Batch.

Both implementations run in `us-east-1`, validate the final output, save metrics, and destroy resources automatically.

## Results

Processed `100,000` Parquet files, exactly `1,000,000,000,000` rows of weather data.

*My account had a max 96vCPU quota, so I tried different shapes of compute and for c7g this was the best combination for cost+time*

| Implementation | Compute | vCPUs | Timed scope | Time | Total Data read | Read rate | Estimated cost |
|---|---:|---:|---|---:|---:|---:|---:|
| ClickHouse | `12 x c7g.2xlarge` Spot | 96 | Query only | `525.786s` (`8.76 min`) | `2340.01 GiB` | `4.451 GiB/s` | `~$0.1998` EC2 Spot |
| AWS Batch Rust | `6 x c7g.4xlarge` Spot | 96 | First worker start through reducer stop | `360.792s` (`6.01 min`) | `2340.58 GiB` | `6.740 GiB/s` | `~$0.1336` EC2 Spot |


| Detail | ClickHouse | AWS Batch Rust |
|---|---:|---:|
| Provisioning or initial queue | `240.000s` provisioning | `83.004s` submit to first worker |
| Query or worker phase | `525.786s` query | `347.257s` worker application span |
| Reducer | Not applicable | `8.069s` application time |
| Continuous processing window | `525.786s` query | `360.792s` (`6.01 min`) |
| Post-processing and teardown | `106.000s` | `214.219s`, including `189s` OpenTofu destroy |
| Worker CPU utilization | Not comparable | ~ `99.2%` of allocated vCPU |
| Spot rate used | `$0.1140` per node-hour | `$0.1950` per node-hour |
| Current-rate EC2 Spot estimate | `$0.1998` query window; `$0.3314` lifecycle | `$0.1173` processing window; `$0.1260` through result; `$0.1336` through placement capture |

The Batch run used `120 x 4`-vCPU workers with `12` concurrent file reads per worker. At most `24` workers ran simultaneously (becaus of the quota). All `120` workers and the reducer succeeded on their first attempt. Configured retry policies (because of spot) were three worker attempts and two reducer attempts.

### Tried the new cpu C8g with the same shape

| Metric | C7g run | C8g run |
|---|---:|---:|
| Worker application span | `347.257s` | `309.566s` |
| Continuous processing | `360.792s` | `322.594s` |
| Submit-to-result | `443.796s` | `377.294s` |
| Submit to first worker | `83.004s` | `54.700s` |
| Source read rate | `6.740 GiB/s` | `7.561 GiB/s` |
| Average worker job runtime | `65.540s` | `52.812s` |
| Captured instance-seconds | `2,466s` | `2,268s` |
| Spot rate | `$0.1950` | `$0.2305` |
| Captured EC2 Spot estimate | `$0.1336` | `$0.1452` |


# How to Run this repo

## Prerequisites

- An AWS account with IAM Identity Center and permission to create EC2, VPC, IAM, SSM, EventBridge Scheduler, AWS Batch, ECR, CloudWatch Logs, and S3 resources.
- Quota for at least `96` Standard Spot vCPUs in `us-east-1`. https://console.aws.amazon.com/servicequotas/home/services/ec2/quotas
- Docker Desktop or a compatible Docker Engine for the Batch implementation: https://docs.docker.com/desktop/. Docker must be installed and running before a Batch run.


## Run ClickHouse

Default config: `12 x c7g.2xlarge` Spot instances, `96` vCPUs total, ClickHouse `26.5.2.39`, `max_threads=128`. If

```bash
cd infra/clickhouse
./scripts/run-clickhouse-e2e.sh
```

### AWS Profile Setup

Set the profile in each `run-config.env`; the default is:

```bash
AWS_PROFILE=1trc
AWS_REGION=us-east-1
```

If the profile does not exist, the runner opens AWS SSO setup and you can enter these values:

Example prompt values:

```text
SSO session name (Recommended): 1trc
SSO start URL [None]: https://<your-identity-center-start-url>.awsapps.com/start
SSO region [None]: us-east-1
SSO registration scopes [sso:account:access]: press Enter
CLI default client Region [None]: us-east-1
CLI default output format [None]: json
```

Monitor from another terminal:

```bash
./scripts/progress-query.sh --watch --interval 30
```

## Run AWS Batch Rust Reducer

Default config: fixed `c7g.4xlarge` Spot instances, `96` max vCPUs, `120` workers, `4` vCPUs per worker, `12` concurrent file reads per worker.

```bash
cd infra/batch
./scripts/run-batch-e2e.sh
```

Monitor from another terminal:

```bash
./scripts/progress-batch.sh --watch --interval 30
```



## Cleanup

The runners destroy infrastructure automatically. If a run exits unclearly:

```bash
cd infra/clickhouse
tofu destroy -auto-approve

cd ../batch
./scripts/cleanup-batch.sh
```

Verify no tagged benchmark instances remain:

```bash
aws ec2 describe-instances --profile 1trc --region us-east-1 \
  --filters Name=tag:Project,Values=1trc-clickhouse,1trc-batch-rust \
            Name=instance-state-name,Values=pending,running,stopping,stopped
```

## Architecture and Execution Flow

### ClickHouse on Amazon EC2

`OpenTofu → EC2 Spot cluster → AWS Systems Manager → ClickHouse s3Cluster → local result`

1. **Provision:** OpenTofu creates an Amazon VPC, subnet, Internet Gateway, security group, S3 Gateway Endpoint, IAM roles, and the `12 x c7g.2xlarge` Amazon EC2 Spot cluster.
2. **Bootstrap:** EC2 user data installs the pinned ClickHouse version and configures every node as a shard in one distributed cluster.
3. **Query:** AWS Systems Manager runs the SQL on the leader. ClickHouse `s3Cluster` divides the requester-pays Amazon S3 Parquet files across all nodes, and each node computes local station aggregates.
4. **Collect:** The leader merges the shard results, returns the final CSV and query metrics through Systems Manager, and the local runner validates and records them.
5. **Clean up:** OpenTofu destroys the stack. Amazon EventBridge Scheduler supplies a separate hard-TTL termination safeguard for every EC2 instance.

AWS services: **Amazon EC2 Spot Instances, Amazon VPC, Amazon S3, AWS IAM, AWS Systems Manager, and Amazon EventBridge Scheduler.**

### Custom Rust Reducer on AWS Batch

`Docker image → Amazon ECR → AWS Batch worker array → S3 partials → reducer job → local result`

1. **Provision and build:** OpenTofu creates the VPC resources, encrypted S3 output bucket, Amazon ECR repository, AWS Batch managed EC2 Spot environment, job queue and definitions, IAM roles, and Amazon CloudWatch Logs group. Docker Buildx builds the ARM64 Rust image and pushes it to ECR.
2. **Scatter:** AWS Batch scales from zero to the configured `96`-vCPU ceiling, currently `6 x c7g.4xlarge`, and runs an array of `120` worker jobs through Amazon ECS. Each worker owns a deterministic slice of the 100,000 files and reads up to `12` files concurrently from S3.
3. **Aggregate locally:** Workers decode only `station` and `measure`, calculate `min/max/sum/count` in memory, and write compact Arrow IPC partials to the output bucket.
4. **Reduce:** A dependent Batch reducer job starts only after the worker array succeeds, merges all partials, validates the trillion-row total, and writes the final CSV and metrics JSON to S3.
5. **Collect and clean up:** The runner downloads and validates the artifacts, captures Batch, ECS, and EC2 placement metadata, then destroys the stack.

AWS services: **AWS Batch, Amazon EC2 Spot Instances, Amazon ECS, Amazon ECR, Amazon S3, Amazon VPC, AWS IAM, and Amazon CloudWatch Logs.**
