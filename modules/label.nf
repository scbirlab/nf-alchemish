process GenerateRequestedLabels {
    tag "${id}:${mode}"

    publishDir "${params.outputs}/request", mode: 'copy'

    input:
    tuple val( id ), path( requested )
    val mode
    path script

    output:
    tuple val( id ), path( "labeled.csv" )

    script:
    if ( mode == "retrospective" ) {
        """
        cp "${requested}" "labeled.csv"
        """
    } 
    else if ( mode == "functional" ) {
        """
        source "${script}" ${requested} > "labeled.csv"
        """
    }
}