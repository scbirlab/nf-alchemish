process write_init_info {

    tag "${id}:${xy}:${acq}"
    
    publishDir(
        "${params.outputs}", 
        mode: 'copy', 
        saveAs: { "${id.id}/runs/method_${id.split_method}/fold_${id.split_rep}/sample_${id.init_rep}/${acq.replaceAll(' ', '_')}/${it}" },
        pattern: "*.json",
    )

    // [id, split_rep, init_rep], [structure, target], acq, config, epochs
    input:
    tuple val( id ), val( xy ), val( acq ), val( model_config ), val( epochs ), val( batch_size )

    output:
    tuple val( id ), path( "info.json" )

    script:
    """
    echo '{
        "id": "${id.id}", 
        "split_rep": ${id.split_rep}, 
        "batch_rep": ${id.init_rep}, 
        "structure": "${xy.structure}", 
        "target": "${xy.target}", 
        "acquisition_fn": "${acq}",
        "sample_size": "${batch_size}",
        "model_config": "${model_config}",
        "epochs": ${epochs}
    }' > info.json

    """
}