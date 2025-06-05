// [id, split_rep, init_rep], [pool, val, test]
process take_first_batch {

    tag "${id}"
    cpus 1

    publishDir "${params.outputs}/${id.id}/split-${id.split_rep}/sample-${id.init_rep}/cycle-0", mode: 'copy'

    input:
    tuple val( id ), path( parquet )
    val batch_size

    output:
    tuple val( id ), path( "*.csv" )

    script:
    """
    duckdb -c '
        PRAGMA threads=${task.cpus};
        COPY (
            SELECT rowid
            FROM read_parquet("${parquet}")
            USING SAMPLE reservoir(${batch_size} ROWS) REPEATABLE (42)
        ) TO "idx_cycle-0.csv" (FORMAT CSV);
    '

    """

}


// [id, split_rep, init_rep], [structure, target], acq, [prediction,...], idx
process acquire {

    tag "${id}:${acq}:b${batch_size}"
    cpus 1

    publishDir "${params.outputs}", mode: 'copy'

    input:
    tuple val( id ), path( '*.parquet' ), path( idx )
    val acq
    val batch_size
    val invert

    // [id, split_rep, init_rep], [structure, target], acq, new_idx
    output:
    tuple val( id ), path( "idx_cycle-*.csv" ), emit: new_idx
    tuple val( id ), path( "idx-all_cycle-*.csv" ), emit: all_idx

    script:
    def colMap = [
        random: null,
        variance: '"prediction variance"',
        tanimoto: 'tanimoto_nn',
        'information sensitivity': '"information sensitivity"'
    ]
    def col = colMap.get(acq, acq)
    def op = invert ? '*' : '/'
    """
    if [ "${acq}" == "random" ]
    then
        duckdb -c \"
            PRAGMA threads=${task.cpus};
            COPY (
                WITH remaining AS (
                    SELECT rowid
                    FROM read_parquet('*.parquet\') 
                    ANTI JOIN read_csv_auto('${idx}')
                    USING(rowid)
                )
                SELECT rowid
                FROM remaining
                USING SAMPLE reservoir(${batch_size} ROWS) REPEATABLE(${id})
            ) TO 'idx_cycle-${id}.csv' (FORMAT CSV);
        \"
    else
        duckdb -c '
            PRAGMA threads=${task.cpus};
            -- From https://blog.moertel.com/posts/2024-08-23-sampling-with-sql.html
            -- Returns a pseudorandom fp64 number in the range [0, 1). The number
            -- is determined by the given `key`, `seed` string, and integer `index`.
            CREATE MACRO pseudorandom_uniform(key, seed, index)
            AS (
                (HASH(key || seed || index) >> 11) * POW(2.0, -53)
            );
            COPY (
                WITH remaining AS (
                    SELECT rowid, ${col}
                    FROM read_parquet('"'*.parquet'"') 
                    ANTI JOIN read_csv_auto('"'${idx}'"')
                    USING(rowid)
                )
                SELECT rowid, ${col}
                FROM remaining
                WHERE ${col} > 0
                ORDER BY -LN(1.0 - pseudorandom_uniform('"'${acq}'"', 42, rowid)) ${op} ${col}
                LIMIT ${batch_size}
            ) TO '"'idx_cycle-${id}.csv'"' (FORMAT CSV);
        '
    fi

    cat "${idx}" <(tail -n+2 "idx_cycle-${id}.csv")  | cut -f1 -d, > "idx-all_cycle-${id}.csv"

    """

}
