process split_data {

    tag "${id}.${split_rep}:${split_method}"

    publishDir "${params.outputs}/${id}/split-${split_rep}/splits", mode: 'copy'

    // id, dataset, structure, split method, split_rep
    input:
    tuple val( id ), val( dataset ), val( structure ), val( split_method ), val( split_rep )
    val split_p

    // id, split_rep, [pool, val, test]
    output:
    tuple val( id ), val( split_rep ), path( "split_*.parquet" ), emit: data
    tuple val( id ), val( split_rep ), path( "split-plot.{png,csv}" ), emit: plot

    script:
    """
    duvida split \
        "${dataset}" \
        --train "${split_p.pool}" \
        --validation "${split_p.val}" \
        --test "${split_p.test}" \
        --structure "${structure}" \
        --type "${split_method}" \
        -k 5 \
        --seed "${split_rep}" \
        --cache cache \
        --output split.parquet \
        --plot-seed 0 \
        --plot split-plot.png

    duckdb -c '
        PRAGMA threads=${task.cpus};
        COPY (
            SELECT 
                row_number() OVER () AS rowid, 
                *
            FROM read_parquet("split_train.parquet")
        ) TO "split_train-indexed.parquet" (FORMAT Parquet);
    '
    rm "split_train.parquet" && mv "split_train-indexed.parquet" "split_train.parquet"
    """

}
