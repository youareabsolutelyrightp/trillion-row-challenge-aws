SELECT
    station,
    min(measure) AS min_measure,
    max(measure) AS max_measure,
    avg(measure) AS mean_measure
FROM s3Cluster(
    'one_trc',
    {s3_url: String},
    'Parquet',
    'station String, measure Float64',
    'none',
    headers('x-amz-request-payer' = 'requester')
)
GROUP BY station
ORDER BY station
SETTINGS
    max_download_buffer_size = 52428800,
    use_uncompressed_cache = 0;
