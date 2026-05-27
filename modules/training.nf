// id, split_rep, init_rep, [pool, val, test], labelled_idx, structure, target
process train_initial_model {

    tag "${id}:${xy.target}"
    // label "gpu_single"

    // errorStrategy 'retry'  // sometimes GPU fails
    // maxRetries 3

    publishDir(
        "${params.outputs}", 
        mode: 'copy', 
        saveAs: { "${id.id}/runs/method_${id.split_method}/fold_${id.split_rep}/sample_${id.init_rep}/cycle_0/${it}" },
        pattern: "*.dv",
    )

    // [id, split_rep, init_rep], [structure, target], [pool, val, test], labelled_idx
    input:
    tuple val( id ), val( xy ), path( data_splits ), path( idx )
    path model_config
    val epochs

    output:
    tuple val( id ), path( "*.dv" ), emit: checkpoint
    tuple val( id ), path( "*.dv/*.{csv,png,json}" ), emit: eval

    // TODO: When duvidnn in new version can remove the -x clogp input
    script:
    """
    duckdb -c "
    PRAGMA threads=${task.cpus};
    COPY (
        SELECT * 
        FROM read_parquet('${data_splits[0]}')
        INNER JOIN read_csv('${idx}', header=false, names=['rowid']) 
        USING (rowid)
    ) TO 'train.csv' (FORMAT CSV);
    "

    XDG_HOME=cache DUVIDNN_CACHE=cache duvidnn train \
        -1 "train.csv" \
        -2 "${data_splits[1]}" \
        --test "${data_splits[2]}" \
        -x clogp \
        -S "${xy.structure}" \
        -y "${xy.target}" \
        -c "${model_config}" \
        --early-stopping 10 \
        --output "model.dv" \
        --cache cache \
        --epochs "${epochs}"

    rm -rf cache

    """

}


process train {

    tag "${id}:${xy.target}"
    // label "gpu_single"
    label "big_time"

    // errorStrategy 'retry'  // sometimes GPU fails
    maxRetries 1

    publishDir(
        "${params.outputs}", 
        mode: 'copy', 
        pattern: "*.dv",
    )

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
    duckdb -c "
    PRAGMA threads=${task.cpus};
        COPY (
            SELECT * 
            FROM read_parquet('${pool}') 
            INNER JOIN read_csv('${idx}', header=false, names=['rowid']) USING (rowid)
        ) TO 'train.csv' (FORMAT CSV);
    "

    if [ ! -e "train.csv" ]
    then 
        echo "ERROR: train.csv does not exist!"
        exit 1
    fi

    XDG_HOME=cache DUVIDNN_CACHE=cache duvidnn train \
        -1 "train.csv" \
        -2 "${validation}" \
        --test ${test} \
        -x clogp \
        -S "${xy.structure}" \
        -y "${xy.target}" \
        -c "${model_config}" \
        --early-stopping 10 \
        --output "model.dv" \
        --cache cache \
        --epochs "${epochs}"

    rm -rf cache

    """

}