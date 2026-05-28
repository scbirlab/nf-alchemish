#!/usr/bin/env nextflow

/*
========================================================================================
   Active Learning Nextflow Workflow
========================================================================================
   Github   : https://github.com/scbirlab/nf-alchemish
   Contact  : Eachan Johnson <eachan.johnson@crick.ac.uk>
----------------------------------------------------------------------------------------
*/

nextflow.enable.dsl=2
pipeline_title = """\
                  S C B I R   A C T I V E   L E A R N I N G   P I P E L I N E
                  ===========================================================

                  Nextflow pipeline to run active learning experiments for chemical
                  property prediction generalization.

                  """
                  .stripIndent()

/*
========================================================================================
   Help text
========================================================================================
*/
if ( params.help ) {
   println pipeline_title + """\
         Usage:
            nextflow run sbcirlab/nf-alchemish --sample_sheet <csv>
            nextflow run sbcirlab/nf-alchemish -c <config-file>

         The parameters can be provided either in the `nextflow.config` file or on the `nextflow run` command.
   
   """.stripIndent()
   System.exit(0)
}

/*
========================================================================================
   Check parameters
========================================================================================
*/
if ( !params.workflow ) {
   throw new Exception("!!! PARAMETER MISSING: Please provide a --workflow mode.")
}

if ( params.workflow == "init" ) {
  if ( !params.sample_sheet ) {
    throw new Exception("!!! PARAMETER MISSING: Please provide a path to sample_sheet")
  }
}

log.info pipeline_title + """\
  mode             : ${params.workflow}
  test             : ${params.test}
  settings
    init. batch    : ${params.init_batch_size}
    split reps     : ${params.split_replicates}
    init. reps     : ${params.init_replicates}
    acquisition    : ${params.acquisition}
    invert acq.    : ${params.invert}
  data
    structure      : ${params.structure}
    target         : ${params.target}
    pool           : ${params.pool}
    validation     : ${params.val}
    test           : ${params.test}
  training
    model          : ${params.model_config}
    epochs         : ${params.epochs}
  inputs
    input dir.     : ${params.inputs}
    sample sheet   : ${params.sample_sheet}
  output           : ${params.outputs}
  """
  .stripIndent()

/*
========================================================================================
   MAIN Workflow
========================================================================================
*/

include { 
  take_first_batch;
  GetBestObserved;
  Acquire; 
} from './modules/batches.nf'
include { 
  split_data_remote;
  split_data_remote as split_data_local;
} from './modules/data-prep.nf'
include { 
  get_chunk_indices; 
} from './modules/db-stats.nf'
include { 
  write_init_info; 
} from './modules/info.nf'
include { 
  predict;
  CleanUpModelFiles;
} from './modules/predicting.nf'
include { 
  train; 
  train_initial_model; 
} from './modules/training.nf'

workflow {

  if ( params.workflow == "init" ) {
    
    init(
      Channel.fromPath( 
        "${params.sample_sheet}",
        checkIfExists: true,
      ),
      Channel.value( [ 
        pool: params.pool, 
        val: params.validation, 
        test: params.test,
      ] ),
      Channel.value( params.k ),
      Channel.value( params.n_partitions ),
      Channel.value( params.init_batch_size ),
      Channel.of( params.split_replicates ),
      Channel.of( 1..params.init_replicates ),
      Channel.fromList( params.acquisitions ),
      Channel.value( file( params.model_config, checkIfExists: true ) ),
      Channel.value( params.epochs ),
    )

  }

  else if ( params.workflow == "cycle" ) {

    active_learning(
      Channel.of( [ 
        params.cycle, 
        file( params.training_idx, checkIfExists: true  ), 
        file( params.model, checkIfExists: true ) 
      ] ),
      Channel.of( [ 
        file( params.pool, checkIfExists: true ), 
        file( params.val, checkIfExists: true ), 
        file( params.test, checkIfExists: true ) 
      ] ),
      Channel.value( [
        structure: params.structure, 
        target: params.target,
      ] ),
      Channel.value( params.acquisition ),
      Channel.value( params.batch_size ),
      Channel.value( file( params.model_config, checkIfExists: true ) ),
      Channel.value( params.epochs ),
      Channel.value( params.n_partitions ),
      Channel.value( params.this_split_rep ),
      Channel.value( params.this_sample_rep ),
    )

  }

  else {
    throw new Exception("Workflow mode '${params.workflow}' is not valid. Use 'init' or 'cycle'.")
  }
  
}

workflow init {

  take:
  sample_sheet
  split_fracs
  knn
  n_partitions
  init_batch_size
  split_replicates
  init_replicates
  acquisitions
  model_config
  epochs

  main:
  sample_sheet
    .splitCsv( header: true )
    .map { [ 
      it.id, 
      it.dataset, 
      it.structure, 
      it.split, 
      it.target,
     ] }
    .unique()
    .set { csv_rows }  // id, dataset, structure, split method, target

  csv_rows
    .map { it[0..-2] }  // id, dataset, structure, split method
    .combine( split_replicates )
    .branch { v ->
      remote: (v[1].startsWith("hf://") || v[1].startsWith("https://"))
      local: true
    }
    .set { data_ch }  // id, dataset, structure, split method, split_rep

  // Workflow
  split_data_local( 
    data_ch.local
      .map { [ it[0], file( it[1], checkIfExists: true ) ] + it[2..-1] },
    split_fracs,
    knn,
    n_partitions,
  )  // id, split_method, [pool, val, test]
  split_data_remote( 
    data_ch.remote,
    split_fracs,
    knn,
    n_partitions,
  )  // test_val -> id, split_method, [test, val] // pool -> id, split_method, pool

  split_data_local.out.pool
    .concat( split_data_remote.out.pool )
    .transpose()
    .map { v -> [ v[0], v[1], v[2].parent.name.split("_")[-1], v[2] ] }
    .groupTuple( by: [0, 1, 2] )   // [id, split_method, fold, [all partition files]]
    .set { pool_by_fold }

  split_data_local.out.test_val
    .concat( split_data_remote.out.test_val )
    .transpose()
    .map { v -> [ v[0], v[1], v[2].parent.name.split("_")[-1], v[2] ] }
    .groupTuple( by: [0, 1, 2] )   // [id, split_method, fold, [val, test]]
    .set { tv_by_fold }

  pool_by_fold
    .combine( tv_by_fold, by: [0, 1, 2] )
    .map { v -> [
        [id: v[0], split_rep: v[2], split_method: v[1]],
        [
          pool: v[3],
          validation: v[4].find { it.name.contains("validation") },
          test: v[4].find { it.name.contains("test") }]
        ] 
    }
    .combine( init_replicates )
    .map { v -> [ 
      v[0] << [init_rep: v[-1]], 
      v[1],
    ] }
    .set { split_data_out }
  
  take_first_batch(
    split_data_out
      .map { v -> [ v[0], v[1].pool ] },
    init_batch_size,
  )  // [id, split_rep, init_rep], labelled_idx
  
  split_data_out
    .combine( 
      take_first_batch.out, 
      by: 0,
    )      // [id, split_rep, init_rep], [pool, val, test], labelled_idx
    .map { [ it[0].id ] + it }
    .combine(
      csv_rows.map { tuple( it[0], [structure: it[2], target: it[4]] ) },
      by: 0,
    )  // [id, split_rep, init_rep], [pool, val, test], labelled_idx, [structure, target]
    .map { [ it[1], it[-1] ] + it[2..-2]  }  // [id, split_rep, init_rep], [structure, target], [pool, val, test], labelled_idx
    .set { init_data }

  train_initial_model(
    init_data.map { [ it[0], it[-1], it[2].pool, it[2].validation, it[2].test, it[1] ] },
    model_config,
    epochs,
  )  // [id, split_rep, init_rep], init_model

  init_data
    .map { it[0..1] }  // [id, split_rep, init_rep], [structure, target], 
    .combine( acquisitions )    // [id, split_rep, init_rep], [structure, target], acq
    .tap { init_info }
    .combine( init_data, by: [0,1])   // [id, split_rep, init_rep], [structure, target], acq, [pool, val, test], labelled_idx
    .combine( train_initial_model.out.checkpoint, by: [0,1] )  // [id, split_rep, init_rep], [structure, target], acq, [pool, val, test], labelled_idx, init_model
    .set { initial_model }

  init_info
    .combine( model_config )
    .combine( epochs )
    .combine( Channel.value( params.batch_size ) ) 
    | write_init_info

  emit:
  initial_model

}

workflow active_learning {

  take:
  iteration_state  // cycle, idx, model
  data_splits  // [pool, val, test]
  xy  // [structure, target]
  acquisiton_fn
  batch_size
  model_config
  epochs
  n_partitions
  this_split_rep
  this_sample_rep

  main:

  data_splits
    .map { it[0] }
    .set { pool_data }

  // get_chunk_indices(
  //   iteration_state
  //     .map { it[0] }
  //     .combine( pool_data ),
  //   Channel.value( 1000 ),
  // )  // cycle, start-stop.txt

  // get_chunk_indices.out
  //   .splitCsv( elem: 1, header: false, sep: '\t' )
  //   .set { chunks }  // cycle, [start, stop]

  predict(
    iteration_state
      .map { [ it[0], it[2] ] }
      .combine( pool_data )
      .combine( Channel.of( 0..<params.n_partitions ) ),  // cycle, model, pool, partition_idx
    xy,
    acquisiton_fn,
  )
  predict.out.main
    .groupTuple( by: 0 )  // cycle, [prediction,...]
    .set { predictions }

  // predict.out.model
  //   .groupTuple( by: 0 )  // cycle, [model,...]
  //   | CleanUpModelFiles

  GetBestObserved(
    iteration_state
      .map { v -> [ v[0], v[1] ] }
      .combine( pool_data ),  // cycle, idx, pool
    xy,
  )
                  
  Acquire(
    predictions
      .combine( iteration_state.map { v -> v[0..1] }, by: 0 )
      .combine( GetBestObserved.out, by: 0 ),  // cycle, [prediction,...], idx
    xy,
    acquisiton_fn,
    batch_size,
    Channel.value( params.invert ),
    Channel.value( params.ucb_beta ? params.ucb_beta : "placeholder" ),
    this_split_rep,
    this_sample_rep
  )  // cycle, new_idx

  train(
    Acquire.out.all_idx.combine( data_splits ), 
    xy,
    model_config,
    epochs,
  )  // cycle, model

  Acquire.out.all_idx
    .combine( train.out.checkpoint, by: 0 )  // cycle, idx, model
    .set { new_state }

  emit:
  new_state

}


