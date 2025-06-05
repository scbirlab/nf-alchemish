// id, [split_rep, init_rep], [pool, val, test], labelled_idx, init_model, acq
process predict {

    tag "${id}:${xy.target}:${acq}"
    label "gpu_single"

    errorStrategy 'retry'  // sometimes GPU fails
    maxRetries 1

    publishDir "${params.outputs}", mode: 'copy', pattern: "prediction.{png,csv}"

    // [id, split_rep, init_rep], [structure, target], acq, [pool, val, test], idx, model, [start, stop]
    input:
    tuple val( id ), path( model ), path( pool ), val( start_stop )
    val xy
    val acq

    // [id, split_rep, init_rep], [structure, target], acq, prediction
    output:
    tuple val( id ), path( "predicted-*-*.parquet" )

    script:
    def acq_flag = ( acq == "doubtscore" ? "--doubtscore" : ( acq == "information sensitivity" ? "--information-sensitivity" : ""))
    """
    duvida predict \
        --test "${pool}" \
        -S "${xy.structure}" ${acq_flag} \
        --extras rowid \
        --start "${start_stop[0]}" \
        --end "${start_stop[1]}" \
        --tanimoto \
        --variance \
        --optimality \
        --checkpoint "${model}" \
        --output "predicted-${start_stop.join('-')}.parquet" \
        --cache cache

    """

}