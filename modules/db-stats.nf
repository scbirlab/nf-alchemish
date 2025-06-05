process get_chunk_indices {

    tag "${id}"
    cpus 1

    // [id, split_rep, init_rep], pool
    input:
    tuple val( id ),  path( parquet )
    val chunk_size

    output:
    tuple val( id ), path( "chunk-indices.txt" )

    script:
    """
    duckdb -c '
        PRAGMA threads=${task.cpus};
        COPY (
            SELECT count(*) AS n_rows
            FROM read_parquet("${parquet}")
        ) TO "row-count.csv" (FORMAT CSV);
    '

    nrows=\$(tail -n1 "row-count.csv")
    echo \$(seq 1 "${chunk_size}" "\$nrows") | tr ' ' \$'\n' > "start-stop.txt"
    paste "start-stop.txt" <(tail -n+2 "start-stop.txt" | cat - <(echo "\$nrows")) | head -n-1 > "chunk-indices.txt"

    """
}