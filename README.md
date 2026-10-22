# 1 trillion row challenge on AWS

The [One Trillion Row Challenge](https://github.com/coiled/1trc) asks for the minimum, mean, and maximum temperature of each weather station across one trillion rows. The data is 100,000 Parquet files of 10 million rows each, in a requester pays S3 bucket.

This repository compares two AWS implementations on spot compute:

- ClickHouse
- A custom Rust reducer job on AWS Batch.

Both implementations run in `us-east-1`, validate the final output, save metrics, and destroy resources automatically.

## Results

Processed `100,000` Parquet files, exactly `1,000,000,000,000` rows of weather data.

*My account had a max 96vCPU quota, so I tried different shapes of compute and for c7g this was the best combination for cost+time*

| Implementation | Compute | vCPUs | Timed scope | Time | Total Data read | Read rate | Estimated cost |
|---|---:|---:|---|---:|---:|---:|---:|
| ClickHouse | `12 x c7g.2xlarge` Spot | 96 | Query only | `525.786s` (`8.76 min`) | `2340 GiB` | `4.451 GiB/s` | `~$0.1998` EC2 Spot |
| AWS Batch Rust | `6 x c7g.4xlarge` Spot | 96 | First worker start through reducer stop | `360.792s` (`6.01 min`) | `2340 GiB` | `6.740 GiB/s` | `~$0.1336` EC2 Spot |


| Detail | ClickHouse | Rust job on AWS Batch |
| --- | ---: | ---: |
| Startup, not timed | 240 s provisioning | 83.0 s from submission to first worker |
| Query or worker phase | 525.8 s | 347.3 s |
| Reducer | none | 8.1 s |
| Timed window | 525.8 s | 360.8 s |
| Wrap-up and teardown | 106 s | 214.2 s, including 189 s of OpenTofu destroy |
| Spot price per instance-hour | USD 0.1140 | USD 0.1950 |
| Cost, timed window | USD 0.1998 | USD 0.1173 |
| Cost, whole run | USD 0.3314 | USD 0.1336 |

The Batch run split the files into 120 worker jobs with 4 vCPUs each, and each worker read 12 files at a time. The 96-vCPU quota allowed 24 workers to run at once, and they used about 99% of their CPU. AWS can reclaim Spot instances at any time, so workers were allowed three attempts and the reducer two. All 120 workers and the reducer succeeded on the first attempt.

### Batch run with the new C8g cpu

Ran the same Batch job on c8g instances instead of c7g (Graviton3). It took 11% less time, but the Spot price was 18% higher, so it cost about 9% more.

| Metric | c7g | c8g |
| --- | ---: | ---: |
| Submission to first worker | 83.0 s | 54.7 s |
| Worker phase | 347.3 s | 309.6 s |
| Timed window | 360.8 s | 322.6 s |
| Submission to result | 443.8 s | 377.3 s |
| Average worker job | 65.5 s | 52.8 s |
| Read rate | 6.74 GiB/s | 7.56 GiB/s |
| Recorded instance time | 2,466 s | 2,268 s |
| Spot price per instance-hour | USD 0.1950 | USD 0.2305 |
| Cost, whole run | USD 0.1336 | USD 0.1452 |


## How it works

### ClickHouse on EC2

`OpenTofu → EC2 Spot cluster → Systems Manager → ClickHouse s3Cluster → result on your machine`

1. **Create:** OpenTofu creates the network (VPC, subnet, internet gateway, security group, and S3 gateway endpoint), IAM roles, and 12 c7g.2xlarge Spot instances.
2. **Set up:** Each instance's startup script installs a fixed ClickHouse version and joins the cluster as one shard.
3. **Query:** Systems Manager runs the query on the leader node. ClickHouse's `s3Cluster` function splits the 100,000 files across all nodes, and each node computes partial results per station.
4. **Collect:** The leader merges the partial results. Systems Manager returns the final CSV and query metrics to your machine, where the runner checks and saves them.
5. **Clean up:** OpenTofu deletes everything. As a backup, an EventBridge Scheduler rule terminates each instance after a fixed time limit.

### Rust MapReduce on AWS Batch

`Docker image → ECR → Batch worker array → partial results in S3 → reducer job → result on your machine`

1. **Create and build:** OpenTofu creates the network, an encrypted S3 bucket for outputs, an ECR repository, a Batch compute environment on Spot instances, the job queue and job definitions, IAM roles, and a CloudWatch Logs group. Docker Buildx builds the ARM64 Rust image and pushes it to ECR.
2. **Split:** Batch scales from zero up to 96 vCPUs (6 c7g.4xlarge instances) and runs 120 worker jobs. Each worker gets a fixed share of the files and reads up to 12 at a time from S3.
3. **Map:** Each worker reads only the `station` and `measure` columns and keeps the min, max, sum, and count per station in memory. It writes these partial results to the output bucket as a small Arrow IPC file.
4. **Reduce:** A reducer job starts once every worker has succeeded. It merges the partial results, checks that exactly one trillion rows were counted, and writes the final CSV and a metrics JSON to S3.
5. **Collect and clean up:** The runner downloads and checks the results, records which instances ran each job, and then deletes everything.

## Running it

### Prerequisites

- An AWS account with IAM Identity Center, since the scripts sign in through AWS SSO. You need permission to create EC2, VPC, IAM, Systems Manager, EventBridge Scheduler, Batch, ECR, CloudWatch Logs, and S3 resources.
- A quota of at least 96 vCPUs for Standard Spot instances in us-east-1. [Check it in Service Quotas](https://console.aws.amazon.com/servicequotas/home/services/ec2/quotas).
- The AWS CLI v2 and OpenTofu.
- For the Batch run only: [Docker Desktop](https://docs.docker.com/desktop/) or another Docker Engine, running.

### AWS profile

Each implementation reads its AWS profile and region from its `run-config.env`. The defaults are:

```bash
AWS_PROFILE=1trc
AWS_REGION=us-east-1
```

If the profile doesn't exist, the runner starts AWS SSO setup. Answer the prompts like this:

```text
SSO session name (Recommended): 1trc
SSO start URL [None]: https://<your-identity-center-start-url>.awsapps.com/start
SSO region [None]: us-east-1
SSO registration scopes [sso:account:access]: press Enter
CLI default client Region [None]: us-east-1
CLI default output format [None]: json
```

### Run ClickHouse

Defaults: 12 c7g.2xlarge Spot instances (96 vCPUs), ClickHouse 26.5.2.39, `max_threads=128`.

```bash
cd infra/clickhouse
./scripts/run-clickhouse-e2e.sh
```

To watch progress, run this from the same folder in another terminal:

```bash
./scripts/progress-query.sh --watch --interval 30
```

### Run the Rust job on AWS Batch

Defaults: c7g.4xlarge Spot instances up to 96 vCPUs, 120 workers with 4 vCPUs each, 12 file reads at a time per worker.

```bash
cd infra/batch
./scripts/run-batch-e2e.sh
```

To watch progress, run this from the same folder in another terminal:

```bash
./scripts/progress-batch.sh --watch --interval 30
```

### Cleanup

Both runners delete their resources when they finish. If a run stops partway, delete them yourself.

ClickHouse:

```bash
cd infra/clickhouse
tofu destroy -auto-approve
```

Batch:

```bash
cd infra/batch
./scripts/cleanup-batch.sh
```

Then check that no benchmark instances are left:

```bash
aws ec2 describe-instances --profile 1trc --region us-east-1 \
  --filters Name=tag:Project,Values=1trc-clickhouse,1trc-batch-rust \
            Name=instance-state-name,Values=pending,running,stopping,stopped
```
