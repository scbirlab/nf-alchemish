process split_data_remote {

    tag "${id}.${split_rep}:${split_method}"

    publishDir "${params.outputs}/${id}", mode: 'copy'

    // id, dataset, structure, split method, split_rep
    input:
    tuple val( id ), val( dataset ), val( structure ), val( split_method ), val( split_rep )
    val split_p
    val knn

    // id, split_rep, [pool, val, test]
    output:
    tuple val( id ), val( split_method ), path( "split-*/splits/data_*.parquet" ), emit: data
    tuple val( id ), val( split_method ), path( "split-plot*.{png,csv}" ), emit: plot

    script:
    """
    set -eoux pipefail

    HF_HOME=cache eluent split \
        "${dataset}" \
        --train "${split_p.pool}" \
        --validation "${split_p.val}" \
        --kfold ${split_rep} \
        --test "${split_p.test}" \
        --structure "${structure}" \
        --type "${split_method}" \
        -k ${knn} \
        --seed "${split_rep}" \
        --cache cache \
        --output data.parquet \
        --plot-seed 0 \
        --plot split-plot.png

    for f in fold_*/data_train.parquet
    do
        duckdb -c '
            PRAGMA threads=${task.cpus};
            COPY (
                SELECT 
                    row_number() OVER () AS rowid, 
                    *
                FROM read_parquet("'"\$f"'")
            ) TO "data_train-indexed.parquet" (FORMAT Parquet);
        '
        rm "\$f" && mv "data_train-indexed.parquet" "\$f"
    done

    for d in fold_*
    do
        mv "\$d" "\${d//fold_/split-${split_method}-}"
    done

    for d in split-*/
    do
        mkdir -p "\$d"/splits
        for f in "\$d"/data_*.parquet
        do
            mv "\$f" "\$d"/splits
        done
    done

    """

}


process split_data_local {

    tag "${id}.${split_rep}:${split_method}"

    publishDir "${params.outputs}/${id}", mode: 'copy'

    // id, dataset, structure, split method, split_rep
    input:
    tuple val( id ), path( dataset ), val( structure ), val( split_method ), val( split_rep )
    val split_p
    val knn

    // id, split_rep, [pool, val, test]
    output:
    tuple val( id ), val( split_rep ), path( "split_*.parquet" ), emit: data
    tuple val( id ), val( split_rep ), path( "split-plot.{png,csv}" ), emit: plot

    script:
    """
    HF_HOME=cache eluent split \
        "${dataset}" \
        --train "${split_p.pool}" \
        --validation "${split_p.val}" \
        --test "${split_p.test}" \
        --structure "${structure}" \
        --type "${split_method}" \
        -k ${knn} \
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
