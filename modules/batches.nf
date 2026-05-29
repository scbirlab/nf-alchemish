// [id, split_rep, init_rep], [pool, val, test]
process take_first_batch {

    tag "${id}:b${batch_size}"
    cpus 1

    publishDir(
        "${params.outputs}", 
        mode: 'copy',
        saveAs: { "${id.id}/runs/method_${id.split_method}/fold_${id.split_rep}/sample_${id.init_rep}/cycle_0/${it}" },
    )

    input:
    tuple val( id ), path( pool )
    val batch_size

    output:
    tuple val( id ), path( "idx_all.csv" )

    script:
    if ( batch_size > 0) {
        """
        duckdb -c "
            PRAGMA threads=${task.cpus};
            COPY (
                SELECT rowid
                FROM read_parquet('data_pool-partition_id_*.parquet')
                USING SAMPLE reservoir(${batch_size} ROWS) REPEATABLE (${id.init_rep})
            ) TO 'idx.csv' (FORMAT CSV);
        "

        cat "idx.csv" | grep -v '^rowid\$' > "idx_all.csv"

        """
    }
    else {
        """
        duckdb -c "
            PRAGMA threads=${task.cpus};
            COPY (
                SELECT rowid
                FROM read_parquet('data_pool-partition_id_*.parquet')
            ) TO 'idx.csv' (FORMAT CSV);
        "

        cat "idx.csv" | grep -v '^rowid\$' > "idx_all.csv"

        """
    }

}

process GetBestObserved {

    tag "${id}:${xy.target}"

    input:
    tuple val( id ), path( idx ), path( pool )
    val xy

    output:
    tuple val( id ), env( y_star )

    script:
    """
    y_star=\$(duckdb -c "
        SELECT MAX(\\"${xy.target}\\")
        FROM read_parquet('data_pool-partition_id_*.parquet')
        INNER JOIN read_csv('${idx}', header=false, names=['rowid']) 
            USING (rowid);
    " | tail -n1)
    """
}


// [id, split_rep, init_rep], [structure, target], acq, [prediction,...], idx
process AcquisitionRequest {

    tag "${id}:${acq}:b${batch_size}"
    cpus 1

    publishDir "${params.outputs}/request", mode: 'copy'

    input:
    tuple val( id ), path( pool, stageAs: 'predicted/pseudopartition_*.parquet' ), path( idx ), val( best )
    val xy
    val acq
    val batch_size
    val invert
    tuple val( beta ), val( scheduled ), val( delta )
    val ei_jitter
    val pi_jitter
    val split_rep
    val sample_rep

    // [id, split_rep, init_rep], [structure, target], acq, new_idx
    output:
    tuple val( id ), path( "idx_new.csv" ), emit: new_idx
    tuple val( id ), path( "idx_all.csv" ), emit: all_idx

    script:
    def colMap = [
        random: null,
        variance: 'prediction variance',
        greedy: "prediction",
        tanimoto: 'tanimoto_nn',
        'information sensitivity': 'information sensitivity'
    ]
    def col = colMap.get(acq, acq)
    def op = invert ? '*' : '/'
    def beta_expr = scheduled
        ? "sqrt(2.0 * ln((SELECT n FROM pool_size) * pow(${id} + 1.0, 2) * pow(pi(), 2) / (6.0 * ${delta})))"
        : "${beta}"

    def pool_files = 'predicted/pseudopartition_*.parquet'
    def pseudorandom_macro = """
        -- From https://blog.moertel.com/posts/2024-08-23-sampling-with-sql.html
        -- Returns a pseudorandom fp64 number in the range [0, 1). The number
        -- is determined by the given `key`, `seed` string, and integer `index`.
        CREATE MACRO pseudorandom_uniform(key, seed, index)
        AS (
            (HASH(key || seed || index) >> 11) * POW(2.0, -53)
        );
    """
    def pseudorandom_seed = "${acq}_${id}_${split_rep}_${sample_rep}"
    def postrun = """
    grep -v '^rowid' idx_new.csv | cut -f1 -d, > idx_new0.csv && mv idx_new0.csv idx_new.csv
    cat "${idx}" "idx_new.csv" | cut -f1 -d, | grep -v '^rowid\$' > "idx_all0.csv"
    mv idx_all0.csv idx_all.csv
    """
    if ( acq == "random" ) {

        """
        duckdb -c "
            PRAGMA threads=${task.cpus};
            COPY (
                WITH remaining AS (
                    SELECT rowid
                    FROM read_parquet('${pool_files}') 
                    ANTI JOIN read_csv('${idx}', header=false, names=['rowid'])
                    USING(rowid)
                )
                SELECT rowid
                FROM remaining
                USING SAMPLE reservoir(${batch_size} ROWS) REPEATABLE(${id})
            ) TO 'idx_new.csv' (FORMAT CSV);
        "
        ${postrun}
        """
    }
    else if ( acq == "ucb" ) {
        """
        duckdb -c "
            PRAGMA threads=${task.cpus};
            COPY (
                WITH 
                pool_size AS (
                    SELECT COUNT(*) AS n FROM read_parquet('${pool_files}')
                    ANTI JOIN read_csv('${idx}', header=false, names=['rowid'])
                    USING(rowid)
                ),
                remaining AS (
                    SELECT rowid
                    FROM read_parquet('${pool_files}') 
                    ANTI JOIN read_csv('${idx}', header=false, names=['rowid'])
                    USING(rowid)
                )
                SELECT rowid
                FROM remaining
                ORDER BY prediction + ${beta_expr} * sqrt(\\"prediction variance\\") DESC
                LIMIT ${batch_size}
            ) TO 'idx_new.csv' (FORMAT CSV);
        "
        ${postrun}
        """
    }
    else if ( acq == "thompson" ) {
        """
        duckdb -c "
            PRAGMA threads=${task.cpus};
            ${pseudorandom_macro}
            COPY (
                WITH remaining AS (
                    SELECT rowid
                    FROM read_parquet('${pool_files}') 
                    ANTI JOIN read_csv('${idx}', header=false, names=['rowid'])
                    USING(rowid)
                )
                SELECT rowid
                FROM remaining
                ORDER BY 
                    prediction + sqrt(\\"prediction variance\\") * 
                    sqrt(-2.0 * ln(pseudorandom_uniform('${pseudorandom_seed}', 42, rowid))) * cos(2.0 * pi() * pseudorandom_uniform('${pseudorandom_seed}', 43, rowid))
                DESC
                LIMIT ${batch_size}
            ) TO 'idx_new.csv' (FORMAT CSV);
        "
        ${postrun}
        """
    }
    else if ( acq == "pi" ) {
        """
        duckdb -c "
            PRAGMA threads=${task.cpus};
            COPY (
                WITH remaining AS (
                    SELECT rowid
                    FROM read_parquet('${pool_files}') 
                    ANTI JOIN read_csv('${idx}', header=false, names=['rowid'])
                    USING(rowid)
                )
                SELECT rowid,
                    (
                        1 + erf(
                            (prediction - ${best} - ${pi_jitter}) 
                            / (sqrt(\\"prediction variance\\") * sqrt(2))
                        )
                    ) / 2 AS pi_score
                FROM remaining
                ORDER BY pi_score DESC
                LIMIT ${batch_size}
            ) TO 'idx_new.csv' (FORMAT CSV);
        "
        ${postrun}
        """
    }
    else if ( acq == "ei" ) {
        """
        duckdb -c "
            PRAGMA threads=${task.cpus};
            COPY (
                WITH remaining AS (
                    SELECT 
                        rowid,
                        prediction AS mu,
                        sqrt(\\"prediction variance\\") AS sigma,
                        (prediction - ${best} - ${ei_jitter}) / NULLIF(sqrt(\\"prediction variance\\"), 0) AS z
                    FROM read_parquet('${pool_files}') 
                    ANTI JOIN read_csv('${idx}', header=false, names=['rowid'])
                    USING(rowid)
                )
                SELECT rowid,
                    CASE WHEN sigma > 0 THEN
                        sigma * (
                            z * 0.5 * (1 + erf(z / sqrt(2))) +
                            exp(-0.5 * z * z) / sqrt(2 * pi())
                        )
                        ELSE 0 END AS ei
                FROM remaining
                ORDER BY ei DESC
                LIMIT ${batch_size}
            ) TO 'idx_new.csv' (FORMAT CSV);
        "
        ${postrun}
        """
    }
    else {
        """
        duckdb -c "
            PRAGMA threads=${task.cpus};
            ${pseudorandom_macro}
            COPY (
                WITH remaining AS (
                    SELECT rowid, \\"${col}\\"
                    FROM read_parquet('${pool_files}') 
                    ANTI JOIN read_csv('${idx}', header=false, names=['rowid'])
                    USING(rowid)
                )
                SELECT rowid, \\"${col}\\"
                FROM remaining
                WHERE \\"${col}\\" > 0
                ORDER BY -LN(1.0 - pseudorandom_uniform('${pseudorandom_seed}', 42, rowid)) ${op} \\"${col}\\"
                LIMIT ${batch_size}
            ) TO 'idx_new.csv' (FORMAT CSV);
        "
        ${postrun}
        """
    }

}

process PublishRequest {

    tag "${id}"
    
    publishDir "${params.outputs}/request", mode: 'copy'

    // [id, split_rep, init_rep], [structure, target], acq, [pool, val, test], idx
    input:
    tuple val( id ), path( idx ), path( pool )

    output:
    tuple val( id ), path( "requested.csv" )

    script:
    """
    duckdb -c "
    PRAGMA threads=${task.cpus};
        COPY (
            SELECT * 
            FROM read_parquet('data_pool-*.parquet') 
            INNER JOIN read_csv('${idx}', header=false, names=['rowid']) USING (rowid)
        ) TO 'requested.csv' (FORMAT CSV);
    "

    """

}
