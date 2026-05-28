// id, [split_rep, init_rep], [pool, val, test], labelled_idx, init_model, acq
process predict {

    tag "${id}:${xy.target}:${acq}"
    // label "gpu_single"

    // errorStrategy 'retry'  // sometimes GPU fails
    // maxRetries 3

    publishDir "${params.outputs}", mode: 'copy', pattern: "prediction.{png,csv}"

    // [id, split_rep, init_rep], [structure, target], acq, [pool, val, test], idx, model, [start, stop]
    input:
    tuple val( id ), path( model ), path( pool ), val( partition_idx )
    val xy
    val acq

    // [id, split_rep, init_rep], [structure, target], acq, prediction
    output:
    tuple val( id ), path( "predicted-*-*.parquet" ), emit: main
    tuple val( id ), path( model ), emit: model

    script:
    def acq_flag = ( acq == "doubtscore" ? "--doubtscore" : ( acq == "information sensitivity" ? "--information-sensitivity" : ""))
    """
    XDG_HOME=cache DUVIDNN_CACHE=cache duvidnn predict \
        --test "${pool}/rowid%*=${partition_idx}/data.parquet" \
        -S "${xy.structure}" ${acq_flag} \
        --extras rowid \
        --tanimoto \
        --variance \
        --optimality \
        --checkpoint "${model}" \
        --output "predicted-${partition_idx}.parquet" \
        --cache cache

    rm -rf cache

    """

}


// id, [split_rep, init_rep], [pool, val, test], labelled_idx, init_model, acq
process CleanUpModelFiles {

    tag "${id}:${xy.target}:${acq}"
    // label "gpu_single"

    // errorStrategy 'retry'  // sometimes GPU fails
    // maxRetries 3

    // [id, split_rep, init_rep], [structure, target], acq, [pool, val, test], idx, model, [start, stop]
    input:
    tuple val( id ), path( models )
    // [id, split_rep, init_rep], [structure, target], acq, prediction

    output:
    val id

    script:
    """
    for m in ${models}
    do
        for bname in input-data.hf training-data.hf params.pt
        do
            filename="\$m/\$bname"
            if [ -f "\$filename" ]
            then
                rm -r "\$filename"
            fi
        done
    done

    """

}