use ahash::AHashMap;
use anyhow::{anyhow, bail, Context, Result};
use arrow::array::{Array, ArrayRef, Float64Array, StringArray, UInt64Array};
use arrow::datatypes::{DataType, Field, Schema};
use arrow::ipc::reader::StreamReader;
use arrow::ipc::writer::StreamWriter;
use arrow::record_batch::RecordBatch;
use aws_config::BehaviorVersion;
use aws_sdk_s3::primitives::ByteStream;
use aws_sdk_s3::Client as S3Client;
use bytes::Bytes;
use chrono::{DateTime, Utc};
use clap::{Parser, Subcommand};
use parquet::arrow::arrow_reader::ParquetRecordBatchReaderBuilder;
use serde::{Deserialize, Serialize};
use std::io::{Cursor, Read, Write};
use std::net::{TcpStream, ToSocketAddrs};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::task::JoinSet;
use tracing::info;

const DEFAULT_BUCKET: &str = "coiled-datasets-rp";
const DEFAULT_PREFIX: &str = "1trc/measurements-";
const DEFAULT_SUFFIX: &str = ".parquet";
const DEFAULT_TOTAL_FILES: usize = 100_000;
const FULL_TOTAL_ROWS: u64 = 1_000_000_000_000;
const FULL_TOTAL_STATIONS: usize = 412;

#[derive(Parser, Debug)]
#[command(name = "trc-batch")]
#[command(about = "Custom AWS Batch reducer for the 1TRC Parquet workload")]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand, Debug)]
enum Command {
    Worker(WorkerArgs),
    Reduce(ReduceArgs),
}

#[derive(Parser, Debug)]
struct WorkerArgs {
    #[arg(long, env = "RUN_ID")]
    run_id: String,
    #[arg(long, env = "OUTPUT_BUCKET")]
    output_bucket: String,
    #[arg(long, env = "AWS_REGION", default_value = "us-east-1")]
    region: String,
    #[arg(long, env = "DATASET_BUCKET", default_value = DEFAULT_BUCKET)]
    dataset_bucket: String,
    #[arg(long, env = "DATASET_PREFIX", default_value = DEFAULT_PREFIX)]
    dataset_prefix: String,
    #[arg(long, env = "DATASET_SUFFIX", default_value = DEFAULT_SUFFIX)]
    dataset_suffix: String,
    #[arg(long, env = "FILE_COUNT", default_value_t = DEFAULT_TOTAL_FILES)]
    file_count: usize,
    #[arg(long, env = "ARRAY_SIZE")]
    array_size: usize,
    #[arg(long, env = "SHARD_INDEX")]
    shard_index: Option<usize>,
    #[arg(long, env = "BATCH_SIZE", default_value_t = 65_536)]
    batch_size: usize,
    #[arg(long, env = "WORKER_FILE_CONCURRENCY")]
    file_concurrency: Option<usize>,
}

#[derive(Parser, Debug)]
struct ReduceArgs {
    #[arg(long, env = "RUN_ID")]
    run_id: String,
    #[arg(long, env = "OUTPUT_BUCKET")]
    output_bucket: String,
    #[arg(long, env = "AWS_REGION", default_value = "us-east-1")]
    region: String,
    #[arg(long, env = "ARRAY_SIZE")]
    array_size: usize,
    #[arg(long, env = "MODE", default_value = "full")]
    mode: String,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
struct PartialAgg {
    station: String,
    min_measure: f64,
    max_measure: f64,
    sum_measure: f64,
    count: u64,
}

impl PartialAgg {
    fn new(station: &str, measure: f64) -> Self {
        Self {
            station: station.to_owned(),
            min_measure: measure,
            max_measure: measure,
            sum_measure: measure,
            count: 1,
        }
    }

    fn add(&mut self, measure: f64) {
        self.min_measure = self.min_measure.min(measure);
        self.max_measure = self.max_measure.max(measure);
        self.sum_measure += measure;
        self.count += 1;
    }

    fn merge(&mut self, other: &PartialAgg) {
        self.min_measure = self.min_measure.min(other.min_measure);
        self.max_measure = self.max_measure.max(other.max_measure);
        self.sum_measure += other.sum_measure;
        self.count += other.count;
    }

    fn mean(&self) -> f64 {
        self.sum_measure / self.count as f64
    }
}

#[derive(Debug)]
struct AggState {
    index: AHashMap<String, usize>,
    values: Vec<PartialAgg>,
}

impl AggState {
    fn with_capacity(capacity: usize) -> Self {
        Self {
            index: AHashMap::with_capacity(capacity),
            values: Vec::with_capacity(capacity),
        }
    }

    fn add_measure(&mut self, station: &str, measure: f64) {
        if let Some(index) = self.index.get(station).copied() {
            self.values[index].add(measure);
            return;
        }

        let index = self.values.len();
        self.index.insert(station.to_owned(), index);
        self.values.push(PartialAgg::new(station, measure));
    }

    fn merge(&mut self, agg: PartialAgg) {
        if let Some(index) = self.index.get(agg.station.as_str()).copied() {
            self.values[index].merge(&agg);
            return;
        }

        let index = self.values.len();
        self.index.insert(agg.station.clone(), index);
        self.values.push(agg);
    }

    fn merge_many(&mut self, values: impl IntoIterator<Item = PartialAgg>) {
        for value in values {
            self.merge(value);
        }
    }

    fn into_vec(self) -> Vec<PartialAgg> {
        self.values
    }

    fn into_sorted_vec(mut self) -> Vec<PartialAgg> {
        self.values
            .sort_by(|left, right| left.station.cmp(&right.station));
        self.values
    }
}

#[derive(Clone, Debug)]
struct EcsStatsSnapshot {
    sampled_at_utc: DateTime<Utc>,
    source: String,
    network_rx_bytes: Option<u64>,
    network_tx_bytes: Option<u64>,
    cpu_total_usage: Option<u64>,
    system_cpu_usage: Option<u64>,
    online_cpus: Option<u64>,
}

#[derive(Clone, Debug, Default)]
struct EcsStatsDelta {
    sample_seconds: Option<f64>,
    network_rx_bytes: Option<u64>,
    network_tx_bytes: Option<u64>,
    network_rx_bytes_per_second: Option<f64>,
    network_tx_bytes_per_second: Option<f64>,
    cpu_usage_seconds_estimated: Option<f64>,
    cpu_utilization_estimated: Option<f64>,
}

#[derive(Clone, Debug)]
struct ProcNetDevSnapshot {
    rx_bytes: u64,
    tx_bytes: u64,
}

#[derive(Debug, Serialize, Deserialize)]
struct WorkerMetrics {
    run_id: String,
    shard_index: usize,
    array_size: usize,
    started_at_utc: String,
    finished_at_utc: String,
    file_start: usize,
    file_end_exclusive: usize,
    files_processed: usize,
    file_concurrency: usize,
    rows_processed: u64,
    bytes_read: u64,
    stations_seen: usize,
    s3_read_seconds: f64,
    parquet_decode_and_aggregate_seconds: f64,
    per_file_s3_read_seconds: Option<PercentileStats>,
    per_file_parquet_decode_and_aggregate_seconds: Option<PercentileStats>,
    partial_write_seconds: f64,
    total_worker_seconds: f64,
    process_cpu_seconds_estimated: Option<f64>,
    process_cpu_utilization_of_one_vcpu_estimated: Option<f64>,
    peak_rss_kib: Option<u64>,
    container_vcpus: Option<String>,
    memory_mib: Option<String>,
    aws_batch_job_id: Option<String>,
    aws_batch_job_array_index: Option<String>,
    ecs_container_metadata_uri_v4: Option<String>,
    ecs_stats_source: Option<String>,
    ecs_task_availability_zone: Option<String>,
    ecs_task_pull_seconds: Option<f64>,
    ecs_network_sample_seconds: Option<f64>,
    ecs_network_rx_bytes: Option<u64>,
    ecs_network_tx_bytes: Option<u64>,
    ecs_network_rx_bytes_per_second: Option<f64>,
    ecs_network_tx_bytes_per_second: Option<f64>,
    ecs_cpu_usage_seconds_estimated: Option<f64>,
    ecs_cpu_utilization_estimated: Option<f64>,
    proc_net_rx_bytes: Option<u64>,
    proc_net_tx_bytes: Option<u64>,
    proc_net_rx_bytes_per_second: Option<f64>,
    proc_net_tx_bytes_per_second: Option<f64>,
    instance_id: Option<String>,
    instance_type: Option<String>,
    availability_zone: Option<String>,
}

#[derive(Debug, Serialize, Deserialize)]
struct PercentileStats {
    count: usize,
    min: f64,
    p50: f64,
    p95: f64,
    max: f64,
    avg: f64,
    sum: f64,
}

struct FileAggregateResult {
    rows_processed: u64,
    bytes_read: u64,
    s3_read_seconds: f64,
    parquet_decode_and_aggregate_seconds: f64,
    aggregates: Vec<PartialAgg>,
}

#[derive(Debug, Serialize, Deserialize)]
struct WorkerMetricsSummary {
    workers_found: usize,
    files_processed: usize,
    file_concurrency_values: Vec<usize>,
    rows_processed: u64,
    bytes_read: u64,
    worker_started_at_min_utc: Option<String>,
    worker_finished_at_max_utc: Option<String>,
    worker_phase_span_seconds: Option<f64>,
    worker_seconds: Option<PercentileStats>,
    s3_read_seconds: Option<PercentileStats>,
    parquet_decode_and_aggregate_seconds: Option<PercentileStats>,
    per_file_s3_read_seconds_p50_by_worker: Option<PercentileStats>,
    per_file_s3_read_seconds_p95_by_worker: Option<PercentileStats>,
    per_file_parquet_decode_and_aggregate_seconds_p50_by_worker: Option<PercentileStats>,
    per_file_parquet_decode_and_aggregate_seconds_p95_by_worker: Option<PercentileStats>,
    partial_write_seconds: Option<PercentileStats>,
    rows_per_second_worker_phase_span: Option<f64>,
    bytes_per_second_worker_phase_span: Option<f64>,
    rows_per_second_sum_worker_seconds: Option<f64>,
    bytes_per_second_sum_worker_seconds: Option<f64>,
    process_cpu_seconds_estimated_sum: Option<f64>,
    process_cpu_utilization_of_allocated_vcpu_estimated: Option<f64>,
    peak_rss_mib: Option<PercentileStats>,
    container_vcpus_values: Vec<String>,
    memory_mib_values: Vec<String>,
    workers_with_cpu_metrics: usize,
    workers_with_memory_metrics: usize,
    ecs_task_availability_zones: Vec<String>,
    ecs_network_rx_bytes_sum: Option<u64>,
    ecs_network_tx_bytes_sum: Option<u64>,
    ecs_network_rx_mib_per_second_worker_phase_span: Option<f64>,
    ecs_network_tx_mib_per_second_worker_phase_span: Option<f64>,
    ecs_network_rx_mib_per_second: Option<PercentileStats>,
    ecs_network_tx_mib_per_second: Option<PercentileStats>,
    proc_net_rx_bytes_sum: Option<u64>,
    proc_net_tx_bytes_sum: Option<u64>,
    proc_net_rx_mib_per_second_worker_phase_span: Option<f64>,
    proc_net_tx_mib_per_second_worker_phase_span: Option<f64>,
    proc_net_rx_mib_per_second: Option<PercentileStats>,
    proc_net_tx_mib_per_second: Option<PercentileStats>,
    ecs_cpu_seconds_estimated_sum: Option<f64>,
    ecs_cpu_utilization_of_allocated_vcpu_estimated: Option<f64>,
    workers_with_ecs_network_metrics: usize,
    workers_with_proc_net_metrics: usize,
    workers_with_ecs_cpu_metrics: usize,
    ecs_stats_sources: Vec<String>,
}

#[derive(Debug, Serialize, Deserialize)]
struct RunSummary {
    run_id: String,
    mode: String,
    generated_at_utc: String,
    partials_expected: usize,
    partials_found: usize,
    worker_metrics_found: usize,
    rows_reduced: u64,
    stations: usize,
    reducer_seconds: f64,
    worker_metrics: WorkerMetricsSummary,
    final_csv_s3: String,
    final_metrics_s3: String,
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .init();

    let cli = Cli::parse();
    match cli.command {
        Command::Worker(args) => run_worker(args).await,
        Command::Reduce(args) => run_reduce(args).await,
    }
}

async fn run_worker(args: WorkerArgs) -> Result<()> {
    if args.array_size == 0 {
        bail!("array_size must be greater than zero");
    }
    let shard_index = match args.shard_index {
        Some(value) => value,
        None => std::env::var("AWS_BATCH_JOB_ARRAY_INDEX")
            .context("worker needs --shard-index or AWS_BATCH_JOB_ARRAY_INDEX")?
            .parse()
            .context("AWS_BATCH_JOB_ARRAY_INDEX must be an integer")?,
    };
    if shard_index >= args.array_size {
        bail!(
            "shard_index {shard_index} must be < array_size {}",
            args.array_size
        );
    }

    let worker_started_at = Utc::now();
    let total_start = Instant::now();
    let cpu_start = process_cpu_seconds_estimated();
    let proc_net_start = proc_net_dev_snapshot();
    let ecs_metadata_uri = std::env::var("ECS_CONTAINER_METADATA_URI_V4").ok();
    let ecs_container_metadata = fetch_ecs_container_metadata(&ecs_metadata_uri).await;
    let ecs_task_metadata = fetch_ecs_task_metadata(&ecs_metadata_uri).await;
    let ecs_stats_start = fetch_ecs_stats(&ecs_metadata_uri, ecs_container_metadata.as_ref()).await;
    let (file_start, file_end) = shard_bounds(args.file_count, args.array_size, shard_index)?;
    let total_files = file_end - file_start;
    let file_concurrency = worker_file_concurrency(args.file_concurrency);
    let client = s3_client(&args.region).await;
    let mut state = AggState::with_capacity(512);
    let mut files_processed = 0usize;
    let mut rows_processed = 0u64;
    let mut bytes_read = 0u64;
    let mut s3_read_seconds = 0.0;
    let mut aggregate_seconds = 0.0;
    let mut per_file_s3_read_seconds = Vec::with_capacity(total_files);
    let mut per_file_decode_seconds = Vec::with_capacity(total_files);
    let mut next_file_index = file_start;
    let mut tasks = JoinSet::new();

    info!(
        file_start,
        file_end, total_files, file_concurrency, "worker starting"
    );

    while next_file_index < file_end || !tasks.is_empty() {
        while next_file_index < file_end && tasks.len() < file_concurrency {
            let key = format!(
                "{}{}{}",
                args.dataset_prefix, next_file_index, args.dataset_suffix
            );
            let client = client.clone();
            let dataset_bucket = args.dataset_bucket.clone();
            let batch_size = args.batch_size;
            let file_index = next_file_index;
            tasks.spawn(async move {
                process_dataset_file(client, dataset_bucket, key, batch_size)
                    .await
                    .with_context(|| format!("failed to process file index {file_index}"))
            });
            next_file_index += 1;
        }

        let result = tasks
            .join_next()
            .await
            .ok_or_else(|| anyhow!("worker task set ended unexpectedly"))?
            .context("worker file task panicked")??;
        state.merge_many(result.aggregates);
        rows_processed += result.rows_processed;
        bytes_read += result.bytes_read;
        s3_read_seconds += result.s3_read_seconds;
        aggregate_seconds += result.parquet_decode_and_aggregate_seconds;
        per_file_s3_read_seconds.push(result.s3_read_seconds);
        per_file_decode_seconds.push(result.parquet_decode_and_aggregate_seconds);
        files_processed += 1;
        if files_processed.is_multiple_of(100) || files_processed == total_files {
            info!(
                files_processed,
                rows_processed, total_files, "worker progress"
            );
        }
    }

    let aggregates = state.into_sorted_vec();
    let stations_seen = aggregates.len();

    let write_start = Instant::now();
    let partial_key = partial_key(&args.run_id, shard_index);
    let partial_body = partial_aggs_to_ipc(&aggregates)?;
    put_bytes(
        &client,
        &args.output_bucket,
        &partial_key,
        partial_body,
        "application/vnd.apache.arrow.stream",
    )
    .await?;
    let partial_write_seconds = write_start.elapsed().as_secs_f64();
    let total_worker_seconds = total_start.elapsed().as_secs_f64();
    let proc_net_end = proc_net_dev_snapshot();
    let proc_net_rx_bytes = match (proc_net_start.as_ref(), proc_net_end.as_ref()) {
        (Some(start), Some(end)) => option_delta(Some(start.rx_bytes), Some(end.rx_bytes)),
        _ => None,
    };
    let proc_net_tx_bytes = match (proc_net_start.as_ref(), proc_net_end.as_ref()) {
        (Some(start), Some(end)) => option_delta(Some(start.tx_bytes), Some(end.tx_bytes)),
        _ => None,
    };
    let proc_net_rx_bytes_per_second =
        proc_net_rx_bytes.map(|bytes| bytes as f64 / total_worker_seconds.max(0.000_001));
    let proc_net_tx_bytes_per_second =
        proc_net_tx_bytes.map(|bytes| bytes as f64 / total_worker_seconds.max(0.000_001));
    let cpu_seconds = match (cpu_start, process_cpu_seconds_estimated()) {
        (Some(start), Some(end)) if end >= start => Some(end - start),
        _ => None,
    };
    let cpu_util = cpu_seconds.map(|seconds| seconds / total_worker_seconds.max(0.000_001));
    let ecs_stats_end = fetch_ecs_stats(&ecs_metadata_uri, ecs_container_metadata.as_ref()).await;
    let ecs_stats_source = ecs_stats_end.as_ref().map(|value| value.source.clone());
    let ecs_delta = ecs_stats_delta(ecs_stats_start.as_ref(), ecs_stats_end.as_ref());
    let ecs_task_availability_zone = ecs_task_metadata
        .as_ref()
        .and_then(|value| json_string(value, "AvailabilityZone"));
    let ecs_task_pull_seconds = ecs_task_metadata.as_ref().and_then(task_pull_seconds);
    let metrics = WorkerMetrics {
        run_id: args.run_id.clone(),
        shard_index,
        array_size: args.array_size,
        started_at_utc: worker_started_at.to_rfc3339(),
        finished_at_utc: Utc::now().to_rfc3339(),
        file_start,
        file_end_exclusive: file_end,
        files_processed,
        file_concurrency,
        rows_processed,
        bytes_read,
        stations_seen,
        s3_read_seconds,
        parquet_decode_and_aggregate_seconds: aggregate_seconds,
        per_file_s3_read_seconds: percentile_stats(&per_file_s3_read_seconds),
        per_file_parquet_decode_and_aggregate_seconds: percentile_stats(&per_file_decode_seconds),
        partial_write_seconds,
        total_worker_seconds,
        process_cpu_seconds_estimated: cpu_seconds,
        process_cpu_utilization_of_one_vcpu_estimated: cpu_util,
        peak_rss_kib: peak_rss_kib(),
        container_vcpus: std::env::var("CONTAINER_VCPUS").ok(),
        memory_mib: std::env::var("CONTAINER_MEMORY_MIB").ok(),
        aws_batch_job_id: std::env::var("AWS_BATCH_JOB_ID").ok(),
        aws_batch_job_array_index: std::env::var("AWS_BATCH_JOB_ARRAY_INDEX").ok(),
        ecs_container_metadata_uri_v4: ecs_metadata_uri,
        ecs_stats_source,
        ecs_task_availability_zone,
        ecs_task_pull_seconds,
        ecs_network_sample_seconds: ecs_delta.sample_seconds,
        ecs_network_rx_bytes: ecs_delta.network_rx_bytes,
        ecs_network_tx_bytes: ecs_delta.network_tx_bytes,
        ecs_network_rx_bytes_per_second: ecs_delta.network_rx_bytes_per_second,
        ecs_network_tx_bytes_per_second: ecs_delta.network_tx_bytes_per_second,
        ecs_cpu_usage_seconds_estimated: ecs_delta.cpu_usage_seconds_estimated,
        ecs_cpu_utilization_estimated: ecs_delta.cpu_utilization_estimated,
        proc_net_rx_bytes,
        proc_net_tx_bytes,
        proc_net_rx_bytes_per_second,
        proc_net_tx_bytes_per_second,
        instance_id: std::env::var("EC2_INSTANCE_ID").ok(),
        instance_type: std::env::var("EC2_INSTANCE_TYPE").ok(),
        availability_zone: std::env::var("AWS_AVAILABILITY_ZONE").ok(),
    };
    let metrics_key = metric_key(&args.run_id, shard_index);
    put_json(&client, &args.output_bucket, &metrics_key, &metrics).await?;

    info!(
        partial_key,
        metrics_key, file_concurrency, "worker finished"
    );
    Ok(())
}

async fn process_dataset_file(
    client: S3Client,
    dataset_bucket: String,
    key: String,
    batch_size: usize,
) -> Result<FileAggregateResult> {
    let read_start = Instant::now();
    let object = client
        .get_object()
        .bucket(&dataset_bucket)
        .key(&key)
        .request_payer(aws_sdk_s3::types::RequestPayer::Requester)
        .send()
        .await
        .with_context(|| format!("failed to read s3://{dataset_bucket}/{key}"))?;
    let bytes = object.body.collect().await?.into_bytes();
    let s3_read_seconds = read_start.elapsed().as_secs_f64();
    let bytes_read = bytes.len() as u64;

    let agg_start = Instant::now();
    let (rows_processed, aggregates) = tokio::task::spawn_blocking(move || {
        let (rows_processed, aggregates) = aggregate_parquet_bytes(bytes, batch_size)?;
        Ok::<_, anyhow::Error>((rows_processed, aggregates))
    })
    .await
    .context("parquet aggregation task panicked")??;
    let parquet_decode_and_aggregate_seconds = agg_start.elapsed().as_secs_f64();

    Ok(FileAggregateResult {
        rows_processed,
        bytes_read,
        s3_read_seconds,
        parquet_decode_and_aggregate_seconds,
        aggregates,
    })
}

fn worker_file_concurrency(explicit: Option<usize>) -> usize {
    let value = explicit
        .or_else(|| {
            std::env::var("CONTAINER_VCPUS")
                .ok()
                .and_then(|value| value.parse::<usize>().ok())
        })
        .unwrap_or(1);
    value.clamp(1, 16)
}

fn aggregate_parquet_bytes(bytes: Bytes, batch_size: usize) -> Result<(u64, Vec<PartialAgg>)> {
    let reader = ParquetRecordBatchReaderBuilder::try_new(bytes)?
        .with_batch_size(batch_size)
        .build()?;
    let mut rows = 0u64;
    let mut state = AggState::with_capacity(512);
    for batch in reader {
        let batch = batch?;
        rows += batch.num_rows() as u64;
        aggregate_batch(&batch, &mut state)?;
    }
    Ok((rows, state.into_vec()))
}

fn aggregate_batch(batch: &RecordBatch, state: &mut AggState) -> Result<()> {
    let station_col = batch
        .column_by_name("station")
        .ok_or_else(|| anyhow!("missing station column"))?;
    let measure_col = batch
        .column_by_name("measure")
        .ok_or_else(|| anyhow!("missing measure column"))?;
    let stations = station_col
        .as_any()
        .downcast_ref::<StringArray>()
        .ok_or_else(|| anyhow!("station column is not Utf8"))?;
    let measures = measure_col
        .as_any()
        .downcast_ref::<Float64Array>()
        .ok_or_else(|| anyhow!("measure column is not Float64"))?;

    if stations.null_count() == 0 && measures.null_count() == 0 {
        for row in 0..batch.num_rows() {
            let measure = measures.value(row);
            if measure.is_finite() {
                state.add_measure(stations.value(row), measure);
            }
        }
        return Ok(());
    }

    for row in 0..batch.num_rows() {
        if stations.is_null(row) || measures.is_null(row) {
            continue;
        }
        let measure = measures.value(row);
        if measure.is_finite() {
            state.add_measure(stations.value(row), measure);
        }
    }
    Ok(())
}

fn partial_schema() -> Arc<Schema> {
    Arc::new(Schema::new(vec![
        Field::new("station", DataType::Utf8, false),
        Field::new("min_measure", DataType::Float64, false),
        Field::new("max_measure", DataType::Float64, false),
        Field::new("sum_measure", DataType::Float64, false),
        Field::new("count", DataType::UInt64, false),
    ]))
}

fn partial_aggs_to_ipc(aggregates: &[PartialAgg]) -> Result<Vec<u8>> {
    let schema = partial_schema();
    let station_values: Vec<&str> = aggregates
        .iter()
        .map(|item| item.station.as_str())
        .collect();
    let min_values = aggregates.iter().map(|item| item.min_measure);
    let max_values = aggregates.iter().map(|item| item.max_measure);
    let sum_values = aggregates.iter().map(|item| item.sum_measure);
    let count_values = aggregates.iter().map(|item| item.count);
    let columns: Vec<ArrayRef> = vec![
        Arc::new(StringArray::from(station_values)),
        Arc::new(Float64Array::from_iter_values(min_values)),
        Arc::new(Float64Array::from_iter_values(max_values)),
        Arc::new(Float64Array::from_iter_values(sum_values)),
        Arc::new(UInt64Array::from_iter_values(count_values)),
    ];
    let batch = RecordBatch::try_new(schema.clone(), columns)?;

    let mut bytes = Vec::new();
    {
        let mut writer = StreamWriter::try_new(&mut bytes, schema.as_ref())?;
        writer.write(&batch)?;
        writer.finish()?;
    }
    Ok(bytes)
}

fn partial_aggs_from_ipc(bytes: Bytes) -> Result<Vec<PartialAgg>> {
    let reader = StreamReader::try_new(Cursor::new(bytes), None)?;
    let mut aggregates = Vec::with_capacity(512);
    for batch in reader {
        let batch = batch?;
        let stations = batch
            .column_by_name("station")
            .ok_or_else(|| anyhow!("partial missing station column"))?
            .as_any()
            .downcast_ref::<StringArray>()
            .ok_or_else(|| anyhow!("partial station column is not Utf8"))?;
        let min_values = batch
            .column_by_name("min_measure")
            .ok_or_else(|| anyhow!("partial missing min_measure column"))?
            .as_any()
            .downcast_ref::<Float64Array>()
            .ok_or_else(|| anyhow!("partial min_measure column is not Float64"))?;
        let max_values = batch
            .column_by_name("max_measure")
            .ok_or_else(|| anyhow!("partial missing max_measure column"))?
            .as_any()
            .downcast_ref::<Float64Array>()
            .ok_or_else(|| anyhow!("partial max_measure column is not Float64"))?;
        let sum_values = batch
            .column_by_name("sum_measure")
            .ok_or_else(|| anyhow!("partial missing sum_measure column"))?
            .as_any()
            .downcast_ref::<Float64Array>()
            .ok_or_else(|| anyhow!("partial sum_measure column is not Float64"))?;
        let count_values = batch
            .column_by_name("count")
            .ok_or_else(|| anyhow!("partial missing count column"))?
            .as_any()
            .downcast_ref::<UInt64Array>()
            .ok_or_else(|| anyhow!("partial count column is not UInt64"))?;

        for row in 0..batch.num_rows() {
            if stations.is_null(row)
                || min_values.is_null(row)
                || max_values.is_null(row)
                || sum_values.is_null(row)
                || count_values.is_null(row)
            {
                continue;
            }
            aggregates.push(PartialAgg {
                station: stations.value(row).to_owned(),
                min_measure: min_values.value(row),
                max_measure: max_values.value(row),
                sum_measure: sum_values.value(row),
                count: count_values.value(row),
            });
        }
    }
    Ok(aggregates)
}

async fn run_reduce(args: ReduceArgs) -> Result<()> {
    let start = Instant::now();
    let client = s3_client(&args.region).await;
    let mut merged = AggState::with_capacity(512);
    let mut worker_metrics = Vec::with_capacity(args.array_size);
    let mut found = 0usize;

    for shard_index in 0..args.array_size {
        let key = partial_key(&args.run_id, shard_index);
        let partial_bytes = get_bytes(&client, &args.output_bucket, &key)
            .await
            .with_context(|| format!("missing partial {key}"))?;
        let partial_aggregates = partial_aggs_from_ipc(partial_bytes)
            .with_context(|| format!("invalid Arrow IPC partial {key}"))?;
        let metrics_key = metric_key(&args.run_id, shard_index);
        let metrics: WorkerMetrics = get_json(&client, &args.output_bucket, &metrics_key)
            .await
            .with_context(|| format!("missing or invalid worker metrics {metrics_key}"))?;
        if metrics.run_id != args.run_id
            || metrics.shard_index != shard_index
            || metrics.array_size != args.array_size
        {
            bail!("worker metrics do not match reducer run or shard: {metrics_key}");
        }
        merged.merge_many(partial_aggregates);
        worker_metrics.push(metrics);
        found += 1;
    }

    let final_rows = merged.into_sorted_vec();
    let rows_reduced: u64 = final_rows.iter().map(|agg| agg.count).sum();
    let worker_rows: u64 = worker_metrics
        .iter()
        .map(|metrics| metrics.rows_processed)
        .sum();
    if worker_rows != rows_reduced {
        bail!("worker metrics report {worker_rows} rows but partials contain {rows_reduced}");
    }
    if args.mode == "full" {
        if rows_reduced != FULL_TOTAL_ROWS {
            bail!("full run reduced {rows_reduced} rows, expected {FULL_TOTAL_ROWS}");
        }
        if final_rows.len() != FULL_TOTAL_STATIONS {
            bail!(
                "full run produced {} stations, expected {FULL_TOTAL_STATIONS}",
                final_rows.len()
            );
        }
    }

    let final_csv = render_final_csv(&final_rows)?;
    let final_key = format!("runs/{}/final/result.csv", args.run_id);
    put_bytes(
        &client,
        &args.output_bucket,
        &final_key,
        final_csv.into_bytes(),
        "text/csv",
    )
    .await?;

    let metrics_key = format!("runs/{}/final/metrics.json", args.run_id);
    let summary = RunSummary {
        run_id: args.run_id.clone(),
        mode: args.mode.clone(),
        generated_at_utc: Utc::now().to_rfc3339(),
        partials_expected: args.array_size,
        partials_found: found,
        worker_metrics_found: worker_metrics.len(),
        rows_reduced,
        stations: final_rows.len(),
        reducer_seconds: start.elapsed().as_secs_f64(),
        worker_metrics: summarize_worker_metrics(&worker_metrics),
        final_csv_s3: format!("s3://{}/{}", args.output_bucket, final_key),
        final_metrics_s3: format!("s3://{}/{}", args.output_bucket, metrics_key),
    };
    put_json(&client, &args.output_bucket, &metrics_key, &summary).await?;

    info!(final_key, metrics_key, rows_reduced, "reducer finished");
    Ok(())
}

fn summarize_worker_metrics(metrics: &[WorkerMetrics]) -> WorkerMetricsSummary {
    let files_processed = metrics.iter().map(|item| item.files_processed).sum();
    let rows_processed = metrics.iter().map(|item| item.rows_processed).sum();
    let bytes_read = metrics.iter().map(|item| item.bytes_read).sum();
    let worker_seconds_values: Vec<_> = metrics
        .iter()
        .map(|item| item.total_worker_seconds)
        .collect();
    let s3_read_values: Vec<_> = metrics.iter().map(|item| item.s3_read_seconds).collect();
    let decode_values: Vec<_> = metrics
        .iter()
        .map(|item| item.parquet_decode_and_aggregate_seconds)
        .collect();
    let file_s3_p50_values: Vec<_> = metrics
        .iter()
        .filter_map(|item| {
            item.per_file_s3_read_seconds
                .as_ref()
                .map(|stats| stats.p50)
        })
        .collect();
    let file_s3_p95_values: Vec<_> = metrics
        .iter()
        .filter_map(|item| {
            item.per_file_s3_read_seconds
                .as_ref()
                .map(|stats| stats.p95)
        })
        .collect();
    let file_decode_p50_values: Vec<_> = metrics
        .iter()
        .filter_map(|item| {
            item.per_file_parquet_decode_and_aggregate_seconds
                .as_ref()
                .map(|stats| stats.p50)
        })
        .collect();
    let file_decode_p95_values: Vec<_> = metrics
        .iter()
        .filter_map(|item| {
            item.per_file_parquet_decode_and_aggregate_seconds
                .as_ref()
                .map(|stats| stats.p95)
        })
        .collect();
    let write_values: Vec<_> = metrics
        .iter()
        .map(|item| item.partial_write_seconds)
        .collect();
    let rss_values: Vec<_> = metrics
        .iter()
        .filter_map(|item| item.peak_rss_kib.map(|kib| kib as f64 / 1024.0))
        .collect();
    let cpu_values: Vec<_> = metrics
        .iter()
        .filter_map(|item| item.process_cpu_seconds_estimated)
        .collect();
    let cpu_seconds_sum = optional_sum(&cpu_values);
    let ecs_rx_values: Vec<_> = metrics
        .iter()
        .filter_map(|item| {
            item.ecs_network_rx_bytes_per_second
                .map(|value| value / 1_048_576.0)
        })
        .collect();
    let ecs_tx_values: Vec<_> = metrics
        .iter()
        .filter_map(|item| {
            item.ecs_network_tx_bytes_per_second
                .map(|value| value / 1_048_576.0)
        })
        .collect();
    let ecs_rx_values_raw: Vec<_> = metrics
        .iter()
        .filter_map(|item| item.ecs_network_rx_bytes)
        .collect();
    let ecs_tx_values_raw: Vec<_> = metrics
        .iter()
        .filter_map(|item| item.ecs_network_tx_bytes)
        .collect();
    let ecs_rx_sum = optional_sum_u64(&ecs_rx_values_raw);
    let ecs_tx_sum = optional_sum_u64(&ecs_tx_values_raw);
    let proc_net_rx_values: Vec<_> = metrics
        .iter()
        .filter_map(|item| {
            item.proc_net_rx_bytes_per_second
                .map(|value| value / 1_048_576.0)
        })
        .collect();
    let proc_net_tx_values: Vec<_> = metrics
        .iter()
        .filter_map(|item| {
            item.proc_net_tx_bytes_per_second
                .map(|value| value / 1_048_576.0)
        })
        .collect();
    let proc_net_rx_values_raw: Vec<_> = metrics
        .iter()
        .filter_map(|item| item.proc_net_rx_bytes)
        .collect();
    let proc_net_tx_values_raw: Vec<_> = metrics
        .iter()
        .filter_map(|item| item.proc_net_tx_bytes)
        .collect();
    let proc_net_rx_sum = optional_sum_u64(&proc_net_rx_values_raw);
    let proc_net_tx_sum = optional_sum_u64(&proc_net_tx_values_raw);
    let ecs_cpu_values: Vec<_> = metrics
        .iter()
        .filter_map(|item| item.ecs_cpu_usage_seconds_estimated)
        .collect();
    let ecs_cpu_seconds_sum = optional_sum(&ecs_cpu_values);
    let allocated_vcpu_seconds: f64 = metrics
        .iter()
        .filter_map(|item| {
            item.container_vcpus
                .as_deref()
                .and_then(|value| value.parse::<f64>().ok())
                .map(|vcpus| vcpus * item.total_worker_seconds)
        })
        .sum();
    let worker_started = metrics
        .iter()
        .filter_map(|item| parse_rfc3339(&item.started_at_utc))
        .min();
    let worker_finished = metrics
        .iter()
        .filter_map(|item| parse_rfc3339(&item.finished_at_utc))
        .max();
    let worker_phase_span_seconds = match (worker_started.as_ref(), worker_finished.as_ref()) {
        (Some(started), Some(finished)) => Some(
            finished
                .signed_duration_since(*started)
                .num_milliseconds()
                .max(0) as f64
                / 1000.0,
        ),
        _ => None,
    };
    let worker_started_at_min_utc = worker_started.as_ref().map(|value| value.to_rfc3339());
    let worker_finished_at_max_utc = worker_finished.as_ref().map(|value| value.to_rfc3339());
    let worker_seconds_sum: f64 = worker_seconds_values.iter().sum();

    WorkerMetricsSummary {
        workers_found: metrics.len(),
        files_processed,
        file_concurrency_values: unique_usize_values(
            metrics.iter().map(|item| item.file_concurrency),
        ),
        rows_processed,
        bytes_read,
        worker_started_at_min_utc,
        worker_finished_at_max_utc,
        worker_phase_span_seconds,
        worker_seconds: percentile_stats(&worker_seconds_values),
        s3_read_seconds: percentile_stats(&s3_read_values),
        parquet_decode_and_aggregate_seconds: percentile_stats(&decode_values),
        per_file_s3_read_seconds_p50_by_worker: percentile_stats(&file_s3_p50_values),
        per_file_s3_read_seconds_p95_by_worker: percentile_stats(&file_s3_p95_values),
        per_file_parquet_decode_and_aggregate_seconds_p50_by_worker: percentile_stats(
            &file_decode_p50_values,
        ),
        per_file_parquet_decode_and_aggregate_seconds_p95_by_worker: percentile_stats(
            &file_decode_p95_values,
        ),
        partial_write_seconds: percentile_stats(&write_values),
        rows_per_second_worker_phase_span: worker_phase_span_seconds
            .map(|seconds| rows_processed as f64 / seconds.max(0.000_001)),
        bytes_per_second_worker_phase_span: worker_phase_span_seconds
            .map(|seconds| bytes_read as f64 / seconds.max(0.000_001)),
        rows_per_second_sum_worker_seconds: Some(
            rows_processed as f64 / worker_seconds_sum.max(0.000_001),
        ),
        bytes_per_second_sum_worker_seconds: Some(
            bytes_read as f64 / worker_seconds_sum.max(0.000_001),
        ),
        process_cpu_seconds_estimated_sum: cpu_seconds_sum,
        process_cpu_utilization_of_allocated_vcpu_estimated: cpu_seconds_sum.and_then(|cpu| {
            if allocated_vcpu_seconds > 0.0 {
                Some(cpu / allocated_vcpu_seconds)
            } else {
                None
            }
        }),
        peak_rss_mib: percentile_stats(&rss_values),
        container_vcpus_values: unique_values(
            metrics
                .iter()
                .filter_map(|item| item.container_vcpus.clone()),
        ),
        memory_mib_values: unique_values(metrics.iter().filter_map(|item| item.memory_mib.clone())),
        workers_with_cpu_metrics: cpu_values.len(),
        workers_with_memory_metrics: rss_values.len(),
        ecs_task_availability_zones: unique_values(
            metrics
                .iter()
                .filter_map(|item| item.ecs_task_availability_zone.clone()),
        ),
        ecs_network_rx_bytes_sum: ecs_rx_sum,
        ecs_network_tx_bytes_sum: ecs_tx_sum,
        ecs_network_rx_mib_per_second_worker_phase_span: match (
            ecs_rx_sum,
            worker_phase_span_seconds,
        ) {
            (Some(bytes), Some(seconds)) => {
                Some(bytes as f64 / 1_048_576.0 / seconds.max(0.000_001))
            }
            _ => None,
        },
        ecs_network_tx_mib_per_second_worker_phase_span: match (
            ecs_tx_sum,
            worker_phase_span_seconds,
        ) {
            (Some(bytes), Some(seconds)) => {
                Some(bytes as f64 / 1_048_576.0 / seconds.max(0.000_001))
            }
            _ => None,
        },
        ecs_network_rx_mib_per_second: percentile_stats(&ecs_rx_values),
        ecs_network_tx_mib_per_second: percentile_stats(&ecs_tx_values),
        proc_net_rx_bytes_sum: proc_net_rx_sum,
        proc_net_tx_bytes_sum: proc_net_tx_sum,
        proc_net_rx_mib_per_second_worker_phase_span: match (
            proc_net_rx_sum,
            worker_phase_span_seconds,
        ) {
            (Some(bytes), Some(seconds)) => {
                Some(bytes as f64 / 1_048_576.0 / seconds.max(0.000_001))
            }
            _ => None,
        },
        proc_net_tx_mib_per_second_worker_phase_span: match (
            proc_net_tx_sum,
            worker_phase_span_seconds,
        ) {
            (Some(bytes), Some(seconds)) => {
                Some(bytes as f64 / 1_048_576.0 / seconds.max(0.000_001))
            }
            _ => None,
        },
        proc_net_rx_mib_per_second: percentile_stats(&proc_net_rx_values),
        proc_net_tx_mib_per_second: percentile_stats(&proc_net_tx_values),
        ecs_cpu_seconds_estimated_sum: ecs_cpu_seconds_sum,
        ecs_cpu_utilization_of_allocated_vcpu_estimated: ecs_cpu_seconds_sum.and_then(|cpu| {
            if allocated_vcpu_seconds > 0.0 {
                Some(cpu / allocated_vcpu_seconds)
            } else {
                None
            }
        }),
        workers_with_ecs_network_metrics: ecs_rx_values_raw.len(),
        workers_with_proc_net_metrics: proc_net_rx_values_raw.len(),
        workers_with_ecs_cpu_metrics: ecs_cpu_values.len(),
        ecs_stats_sources: unique_values(
            metrics
                .iter()
                .filter_map(|item| item.ecs_stats_source.clone()),
        ),
    }
}

fn percentile_stats(values: &[f64]) -> Option<PercentileStats> {
    if values.is_empty() {
        return None;
    }
    let mut sorted = values.to_vec();
    sorted.sort_by(|left, right| left.total_cmp(right));
    let sum: f64 = sorted.iter().sum();
    Some(PercentileStats {
        count: sorted.len(),
        min: sorted[0],
        p50: percentile_sorted(&sorted, 0.50),
        p95: percentile_sorted(&sorted, 0.95),
        max: *sorted.last().unwrap(),
        avg: sum / sorted.len() as f64,
        sum,
    })
}

fn percentile_sorted(sorted: &[f64], percentile: f64) -> f64 {
    let index = ((sorted.len() as f64 * percentile).ceil() as usize).saturating_sub(1);
    sorted[index.min(sorted.len() - 1)]
}

fn optional_sum(values: &[f64]) -> Option<f64> {
    if values.is_empty() {
        None
    } else {
        Some(values.iter().sum())
    }
}

fn optional_sum_u64(values: &[u64]) -> Option<u64> {
    if values.is_empty() {
        None
    } else {
        Some(values.iter().sum())
    }
}

fn unique_values(values: impl Iterator<Item = String>) -> Vec<String> {
    let mut values: Vec<_> = values.collect();
    values.sort();
    values.dedup();
    values
}

fn unique_usize_values(values: impl Iterator<Item = usize>) -> Vec<usize> {
    let mut values: Vec<_> = values.collect();
    values.sort();
    values.dedup();
    values
}

fn parse_rfc3339(value: &str) -> Option<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(value)
        .ok()
        .map(|value| value.with_timezone(&Utc))
}

fn process_cpu_seconds_estimated() -> Option<f64> {
    let stat = std::fs::read_to_string("/proc/self/stat").ok()?;
    let fields = stat
        .rsplit_once(") ")?
        .1
        .split_whitespace()
        .collect::<Vec<_>>();
    let user_ticks = fields.get(11)?.parse::<f64>().ok()?;
    let system_ticks = fields.get(12)?.parse::<f64>().ok()?;
    Some((user_ticks + system_ticks) / 100.0)
}

fn peak_rss_kib() -> Option<u64> {
    let status = std::fs::read_to_string("/proc/self/status").ok()?;
    for key in ["VmHWM:", "VmRSS:"] {
        if let Some(line) = status.lines().find(|line| line.starts_with(key)) {
            return line
                .split_whitespace()
                .nth(1)
                .and_then(|value| value.parse().ok());
        }
    }
    None
}

fn proc_net_dev_snapshot() -> Option<ProcNetDevSnapshot> {
    let contents = std::fs::read_to_string("/proc/net/dev").ok()?;
    let mut rx_bytes = 0u64;
    let mut tx_bytes = 0u64;
    let mut found = false;

    for line in contents.lines().skip(2) {
        let Some((iface, values)) = line.split_once(':') else {
            continue;
        };
        if iface.trim() == "lo" {
            continue;
        }
        let fields: Vec<_> = values.split_whitespace().collect();
        if fields.len() < 16 {
            continue;
        }
        let Some(rx) = fields.first().and_then(|value| value.parse::<u64>().ok()) else {
            continue;
        };
        let Some(tx) = fields.get(8).and_then(|value| value.parse::<u64>().ok()) else {
            continue;
        };
        rx_bytes += rx;
        tx_bytes += tx;
        found = true;
    }

    found.then_some(ProcNetDevSnapshot { rx_bytes, tx_bytes })
}

async fn fetch_ecs_container_metadata(uri: &Option<String>) -> Option<serde_json::Value> {
    let uri = uri.as_ref()?;
    fetch_json(uri).await
}

async fn fetch_ecs_task_metadata(uri: &Option<String>) -> Option<serde_json::Value> {
    let uri = uri.as_ref()?;
    fetch_json(&format!("{uri}/task")).await
}

async fn fetch_ecs_stats(
    uri: &Option<String>,
    container_metadata: Option<&serde_json::Value>,
) -> Option<EcsStatsSnapshot> {
    let uri = uri.as_ref()?;
    let sampled_at_utc = Utc::now();

    if let Some(value) = fetch_json(&format!("{uri}/stats")).await {
        if let Some(snapshot) = stats_snapshot_from_value(sampled_at_utc, "container/stats", &value)
        {
            return Some(snapshot);
        }
    }

    let docker_id = container_metadata.and_then(|value| json_string(value, "DockerId"));
    let task_stats = fetch_json(&format!("{uri}/task/stats")).await?;
    if let Some(docker_id) = docker_id.as_deref() {
        if let Some(value) = task_stats.get(docker_id) {
            if let Some(snapshot) = stats_snapshot_from_value(sampled_at_utc, "task/stats", value) {
                return Some(snapshot);
            }
        }
    }

    task_stats
        .as_object()?
        .values()
        .find_map(|value| stats_snapshot_from_value(sampled_at_utc, "task/stats:first", value))
}

fn stats_snapshot_from_value(
    sampled_at_utc: DateTime<Utc>,
    source: &str,
    value: &serde_json::Value,
) -> Option<EcsStatsSnapshot> {
    let snapshot = EcsStatsSnapshot {
        sampled_at_utc,
        source: source.to_owned(),
        network_rx_bytes: network_stat_sum(value, "rx_bytes"),
        network_tx_bytes: network_stat_sum(value, "tx_bytes"),
        cpu_total_usage: value
            .pointer("/cpu_stats/cpu_usage/total_usage")
            .and_then(|value| value.as_u64()),
        system_cpu_usage: value
            .pointer("/cpu_stats/system_cpu_usage")
            .and_then(|value| value.as_u64()),
        online_cpus: value
            .pointer("/cpu_stats/online_cpus")
            .and_then(|value| value.as_u64()),
    };

    if snapshot.network_rx_bytes.is_some()
        || snapshot.network_tx_bytes.is_some()
        || snapshot.cpu_total_usage.is_some()
    {
        Some(snapshot)
    } else {
        None
    }
}

async fn fetch_json(url: &str) -> Option<serde_json::Value> {
    let url = url.to_owned();
    tokio::task::spawn_blocking(move || fetch_json_blocking(&url))
        .await
        .ok()
        .flatten()
}

fn fetch_json_blocking(url: &str) -> Option<serde_json::Value> {
    let rest = url.strip_prefix("http://")?;
    let (host_port, path) = rest.split_once('/')?;
    let path = format!("/{path}");
    let (host, port) = match host_port.split_once(':') {
        Some((host, port)) => (host, port.parse::<u16>().ok()?),
        None => (host_port, 80),
    };
    let addr = (host, port).to_socket_addrs().ok()?.next()?;
    let mut stream = TcpStream::connect_timeout(&addr, Duration::from_secs(1)).ok()?;
    let timeout = Some(Duration::from_secs(2));
    stream.set_read_timeout(timeout).ok()?;
    stream.set_write_timeout(timeout).ok()?;
    write!(
        stream,
        "GET {path} HTTP/1.0\r\nHost: {host_port}\r\nAccept: application/json\r\n\r\n"
    )
    .ok()?;
    let mut response = String::new();
    stream.read_to_string(&mut response).ok()?;
    let (headers, body) = response.split_once("\r\n\r\n")?;
    if !headers.starts_with("HTTP/1.1 200") && !headers.starts_with("HTTP/1.0 200") {
        return None;
    }
    let lower_headers = headers.to_ascii_lowercase();
    let body = if lower_headers.contains("transfer-encoding: chunked") {
        decode_chunked_body(body)?
    } else {
        body.to_owned()
    };
    serde_json::from_str(&body).ok()
}

fn decode_chunked_body(body: &str) -> Option<String> {
    let mut rest = body;
    let mut decoded = String::new();
    loop {
        let (size_line, after_size) = rest.split_once("\r\n")?;
        let size_hex = size_line.split(';').next()?.trim();
        let size = usize::from_str_radix(size_hex, 16).ok()?;
        if size == 0 {
            return Some(decoded);
        }
        if after_size.len() < size + 2 {
            return None;
        }
        decoded.push_str(&after_size[..size]);
        rest = after_size[size..].strip_prefix("\r\n")?;
    }
}

fn network_stat_sum(value: &serde_json::Value, key: &str) -> Option<u64> {
    let networks = value.get("networks")?.as_object()?;
    let mut total = 0u64;
    let mut found = false;
    for network in networks.values() {
        if let Some(value) = network.get(key).and_then(|value| value.as_u64()) {
            total += value;
            found = true;
        }
    }
    found.then_some(total)
}

fn ecs_stats_delta(
    start: Option<&EcsStatsSnapshot>,
    end: Option<&EcsStatsSnapshot>,
) -> EcsStatsDelta {
    let (Some(start), Some(end)) = (start, end) else {
        return EcsStatsDelta::default();
    };
    let sample_seconds = end
        .sampled_at_utc
        .signed_duration_since(start.sampled_at_utc)
        .num_milliseconds()
        .max(0) as f64
        / 1000.0;
    let sample_seconds = (sample_seconds > 0.0).then_some(sample_seconds);
    let network_rx_bytes = option_delta(start.network_rx_bytes, end.network_rx_bytes);
    let network_tx_bytes = option_delta(start.network_tx_bytes, end.network_tx_bytes);
    let cpu_delta = option_delta(start.cpu_total_usage, end.cpu_total_usage);
    let system_delta = option_delta(start.system_cpu_usage, end.system_cpu_usage);
    let online_cpus = end.online_cpus.or(start.online_cpus).unwrap_or(1) as f64;
    let cpu_usage_seconds_estimated = cpu_delta.map(|value| value as f64 / 1_000_000_000.0);
    let cpu_utilization_estimated = match (cpu_delta, system_delta) {
        (Some(cpu), Some(system)) if system > 0 => Some(cpu as f64 / system as f64 * online_cpus),
        _ => None,
    };

    EcsStatsDelta {
        sample_seconds,
        network_rx_bytes,
        network_tx_bytes,
        network_rx_bytes_per_second: match (network_rx_bytes, sample_seconds) {
            (Some(bytes), Some(seconds)) => Some(bytes as f64 / seconds),
            _ => None,
        },
        network_tx_bytes_per_second: match (network_tx_bytes, sample_seconds) {
            (Some(bytes), Some(seconds)) => Some(bytes as f64 / seconds),
            _ => None,
        },
        cpu_usage_seconds_estimated,
        cpu_utilization_estimated,
    }
}

fn option_delta(start: Option<u64>, end: Option<u64>) -> Option<u64> {
    match (start, end) {
        (Some(start), Some(end)) if end >= start => Some(end - start),
        _ => None,
    }
}

fn json_string(value: &serde_json::Value, key: &str) -> Option<String> {
    value.get(key)?.as_str().map(ToOwned::to_owned)
}

fn task_pull_seconds(value: &serde_json::Value) -> Option<f64> {
    let started = json_string(value, "PullStartedAt").and_then(|value| parse_rfc3339(&value))?;
    let stopped = json_string(value, "PullStoppedAt").and_then(|value| parse_rfc3339(&value))?;
    Some(
        stopped
            .signed_duration_since(started)
            .num_milliseconds()
            .max(0) as f64
            / 1000.0,
    )
}

fn render_final_csv(rows: &[PartialAgg]) -> Result<String> {
    let mut writer = csv::Writer::from_writer(Vec::new());
    writer.write_record(["station", "min_measure", "max_measure", "mean_measure"])?;
    for row in rows {
        writer.write_record([
            row.station.as_str(),
            &format_float(row.min_measure),
            &format_float(row.max_measure),
            &format_float(row.mean()),
        ])?;
    }
    let bytes = writer.into_inner()?;
    Ok(String::from_utf8(bytes)?)
}

fn format_float(value: f64) -> String {
    format!("{value:.14}")
}

async fn s3_client(region: &str) -> S3Client {
    let config = aws_config::defaults(BehaviorVersion::latest())
        .region(aws_config::Region::new(region.to_owned()))
        .load()
        .await;
    S3Client::new(&config)
}

async fn put_json<T: Serialize>(
    client: &S3Client,
    bucket: &str,
    key: &str,
    value: &T,
) -> Result<()> {
    let body = serde_json::to_vec_pretty(value)?;
    put_bytes(client, bucket, key, body, "application/json").await
}

async fn put_bytes(
    client: &S3Client,
    bucket: &str,
    key: &str,
    body: Vec<u8>,
    content_type: &str,
) -> Result<()> {
    client
        .put_object()
        .bucket(bucket)
        .key(key)
        .content_type(content_type)
        .body(ByteStream::from(body))
        .send()
        .await
        .with_context(|| format!("failed to write s3://{bucket}/{key}"))?;
    Ok(())
}

async fn get_bytes(client: &S3Client, bucket: &str, key: &str) -> Result<Bytes> {
    let object = client.get_object().bucket(bucket).key(key).send().await?;
    Ok(object.body.collect().await?.into_bytes())
}

async fn get_json<T: for<'de> Deserialize<'de>>(
    client: &S3Client,
    bucket: &str,
    key: &str,
) -> Result<T> {
    let bytes = get_bytes(client, bucket, key).await?;
    Ok(serde_json::from_slice(&bytes)?)
}

fn partial_key(run_id: &str, shard_index: usize) -> String {
    format!("runs/{run_id}/partials/shard-{shard_index:06}.arrow")
}

fn metric_key(run_id: &str, shard_index: usize) -> String {
    format!("runs/{run_id}/metrics/shard-{shard_index:06}.json")
}

fn shard_bounds(
    file_count: usize,
    array_size: usize,
    shard_index: usize,
) -> Result<(usize, usize)> {
    if array_size == 0 {
        bail!("array_size must be greater than zero");
    }
    if shard_index >= array_size {
        bail!("shard_index must be less than array_size");
    }
    let base = file_count / array_size;
    let remainder = file_count % array_size;
    let start = shard_index * base + shard_index.min(remainder);
    let len = base + usize::from(shard_index < remainder);
    Ok((start, start + len))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shard_planner_covers_every_file_once() {
        let mut seen = vec![0u8; 100_000];
        for shard in 0..960 {
            let (start, end) = shard_bounds(100_000, 960, shard).unwrap();
            assert!(end >= start);
            for item in seen.iter_mut().take(end).skip(start) {
                *item += 1;
            }
        }
        assert!(seen.iter().all(|count| *count == 1));
    }

    #[test]
    fn shard_planner_handles_single_file() {
        assert_eq!(shard_bounds(1, 1, 0).unwrap(), (0, 1));
    }

    #[test]
    fn partial_merge_updates_bounds_and_count() {
        let mut left = PartialAgg::new("A", 2.0);
        left.add(-1.0);
        let mut right = PartialAgg::new("A", 5.0);
        right.add(1.0);
        left.merge(&right);
        assert_eq!(left.min_measure, -1.0);
        assert_eq!(left.max_measure, 5.0);
        assert_eq!(left.count, 4);
        assert!((left.mean() - 1.75).abs() < 1e-12);
    }

    #[test]
    fn final_csv_is_sorted_by_caller_order() {
        let rows = vec![PartialAgg::new("A", 1.0), PartialAgg::new("B", 2.0)];
        let csv = render_final_csv(&rows).unwrap();
        assert!(csv.starts_with("station,min_measure,max_measure,mean_measure\nA,"));
    }
}
