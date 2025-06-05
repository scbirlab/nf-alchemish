// id, split_rep, init_rep, [pool, val, test], labelled_idx, structure, target
process train_initial_model {

    tag "${id}:${xy.target}"
    label "gpu_single"

    errorStrategy 'retry'  // sometimes GPU fails
    maxRetries 1

    publishDir "${params.outputs}/${id.id}/split-${id.split_rep}/sample-${id.init_rep}/cycle-0", mode: 'copy', pattern: "*.dv"

    // [id, split_rep, init_rep], [structure, target], [pool, val, test], labelled_idx
    input:
    tuple val( id ), val( xy ), path( data_splits ), path( idx )
    path model_config
    val epochs

    output:
    tuple val( id ), path( "*.dv" ), emit: checkpoint
    tuple val( id ), path( "*.dv/*.{csv,png,json}" ), emit: eval

    script:
    """
    duckdb -c '
    PRAGMA threads=${task.cpus};
    COPY (
        SELECT * 
        FROM read_parquet("${data_splits[0]}")
        INNER JOIN read_csv("${idx}") USING (rowid)
    ) TO "train.csv" (FORMAT CSV);
    '

    duvida train \
        -1 "train.csv" \
        -2 "${data_splits[1]}" \
        --test "${data_splits[2]}" \
        -S "${xy.structure}" \
        -y "${xy.target}" \
        -c "${model_config}" \
        --output "model_cycle-0.dv" \
        --cache cache \
        --epochs "${epochs}"

    """

}


process train {

    tag "${id}:${xy.target}"
    label "gpu_single"

    errorStrategy 'retry'  // sometimes GPU fails
    maxRetries 1

    publishDir "${params.outputs}", mode: 'copy', pattern: "*.dv"

    // [id, split_rep, init_rep], [structure, target], acq, [pool, val, test], idx
    input:
    tuple val( id ), path( idx ), path( pool ), path( validation ), path( test )
    val xy
    path model_config
    val epochs

    output:
    tuple val( id ), path( "*.dv" ), emit: checkpoint
    tuple val( id ), path( "*.dv/*.{csv,png,json}" ), emit: eval

    script:
    """
    duckdb -c '
    PRAGMA threads=${task.cpus};
        COPY (
            SELECT * 
            FROM read_parquet("${pool}") 
            INNER JOIN read_csv("${idx}") USING (rowid)
        ) TO "train.csv" (FORMAT CSV);
    '

    if [ ! -e "train.csv" ]
    then 
        echo "ERROR: train.csv does not exist!"
        exit 1
    fi

    duvida train \
        -1 "train.csv" \
        -2 "${validation}" \
        --test ${test} \
        -S "${xy.structure}" \
        -y "${xy.target}" \
        -c "${model_config}" \
        --output "model_cycle-${id}.dv" \
        --cache cache \
        --epochs "${epochs}"

    """

}