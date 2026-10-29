# nf-alchemish

![GitHub Workflow Status](https://img.shields.io/github/actions/workflow/status/scbirlab/nf-alchemish/nf-test.yml)
[![Nextflow](https://img.shields.io/badge/nextflow%20DSL2-%E2%89%A524.0.0-23aa62.svg)](https://www.nextflow.io/)
[![run with conda](https://img.shields.io/badge/run%20with-conda-3EB049?labelColor=000000&logo=anaconda)](https://docs.conda.io/en/latest/)
[![run with docker](https://img.shields.io/badge/run%20with-docker-0db7ed?labelColor=000000&logo=docker)](https://www.docker.com/)
[![run with singularity](https://img.shields.io/badge/run%20with-singularity-1d355c.svg?labelColor=000000)](https://sylabs.io/docs/)

Nextflow pipeline for benchmarking active learning strategies for chemical property prediction.

You have a large compound library and a property you care about — antimicrobial activity, solubility, binding affinity. Measuring everything is expensive. Active learning addresses this by iteratively selecting the most informative compounds to label next, training a model on the growing labeled set, and repeating. Different acquisition strategies (uncertainty sampling, diversity, greedy exploitation) have different strengths depending on the dataset and the property distribution.

nf-alchemish automates this benchmark: for a given dataset it runs the full active learning loop across multiple acquisition functions, data splits, and random seeds, producing directly comparable learning curves. All compute is managed by Nextflow and dispatched to SLURM (or run locally).

---

## Quick start

### 1. Install prerequisites

[Nextflow](https://www.nextflow.io/docs/latest/install.html) ≥ 24.0, and one of conda, Docker, or Singularity.

### 2. Prepare a sample sheet

A CSV with one row per dataset × split method × target combination:

```csv
id,dataset,structure,split,target
ecoli,data/compounds.csv,smiles,scaffold,mic
ecoli,data/compounds.csv,smiles,faiss,mic
```

| Column | Description |
|---|---|
| `id` | Experiment identifier, used in output paths |
| `dataset` | Path to CSV/parquet, or `hf://` / `https://` URL |
| `structure` | Column name containing SMILES strings |
| `split` | Split strategy: `scaffold` or `faiss` |
| `target` | Column name for the numeric property to predict |

### 3. Run

```bash
bash scripts/run-active-learning.sh \
    10 \
    /path/to/experiment \
    slurm
```

Arguments: `max_cycles` (default 10), `output_dir` (default `.`), `slurm` (pass `slurm` for SLURM, omit for local).

This runs `init` first — splitting data, sampling the initial labeled set, training the initial model — then submits the active learning cycles as a SLURM job array (or parallel local processes). A `logfiles.txt` and convenience `log-follow.sh` are written to the working directory.

---

## How it works

The pipeline has two phases.

### Phase 1 — Init

For each row in the sample sheet:

1. **Split**: the dataset is split into pool / validation / test using the specified method, repeated `split_replicates` times (different random seeds). Splits are written as Parquet to `outputs/{id}/splits/`.
2. **Sample**: `init_batch_size` compounds are drawn uniformly at random from the pool as the initial labeled set.
3. **Train**: an ensemble model is trained on the initial labeled set.
4. **Expand**: one output directory is created per acquisition function, containing an `info.json` that records all parameters for that combination.

The init workflow produces one directory tree per (id × split method × fold × initial sample replicate × acquisition function).

### Phase 2 — Cycle loop

For each leaf directory from init, a separate process runs the active learning loop up to `max_cycles` times:

1. **Predict**: the current model scores all unlabeled compounds in the pool. The pool is chunked (1,000 rows at a time) and predictions run in parallel.
2. **Acquire**: the acquisition function ranks predictions and selects the next `batch_size` compounds.
3. **Train**: a new model is trained from scratch on all labeled compounds so far.
4. **Iterate**: the new model and updated index become the input to the next cycle.

```
outputs/
└── {id}/
    ├── splits/
    │   └── method_{split}/
    │       └── fold_{n}/
    │           ├── data_train.parquet
    │           ├── data_validation.parquet
    │           └── data_test.parquet
    └── runs/
        └── method_{split}/
            └── fold_{n}/
                └── sample_{n}/
                    └── {acquisition}/
                        ├── info.json
                        ├── cycle_0/
                        │   ├── idx_all.csv
                        │   └── model.dv/
                        ├── cycle_1/
                        │   ├── idx_all.csv
                        │   ├── idx_new.csv
                        │   ├── prediction.csv
                        │   └── model.dv/
                        └── cycle_N/
                            └── ...
```

Each `idx_all.csv` is the full labeled set at that cycle; `idx_new.csv` is the batch acquired in that cycle. Model checkpoints are in `model.dv/`.

---

## Parameters

Parameters can be set in a `nextflow.config` file in your working directory or passed on the command line with `--param value`.

### Data

| Parameter | Default | Description |
|---|---|---|
| `sample_sheet` | — | Path to sample sheet CSV (required for `init`) |
| `structure` | — | SMILES column name (required for `cycle`) |
| `target` | — | Target column name (required for `cycle`) |
| `pool` | `0.8` | Fraction of data used as the compound pool |
| `validation` | `0.1` | Fraction held out for validation |
| `test` | `0.1` | Fraction held out for final evaluation |
| `k` | `3` | Number of neighbours for FAISS splitting |

### Experiment design

| Parameter | Default | Description |
|---|---|---|
| `split_replicates` | `3` | Number of independent data splits (folds) |
| `init_replicates` | `3` | Number of random initial sample replicates per fold |
| `init_batch_size` | `100` | Compounds in the initial labeled set |
| `batch_size` | `100` | Compounds acquired per cycle |
| `cycles` | `5` | Number of active learning cycles |
| `acquisitions` | see below | List of acquisition functions to benchmark |

Default acquisition list:

```groovy
acquisitions = ["random", "greedy", "tanimoto", "variance", "doubtscore", "information sensitivity"]
```

### Model

| Parameter | Default | Description |
|---|---|---|
| `model_config` | `ffn-5x16x10.json` | Path to model architecture JSON |
| `epochs` | `10` | Maximum training epochs (early stopping at 10 without improvement) |

### Paths

| Parameter | Default | Description |
|---|---|---|
| `inputs` | `inputs` | Input data directory |
| `outputs` | `outputs` | Output directory |

---

## Acquisition functions

| Name | Strategy |
|---|---|
| `random` | Uniform random sampling — baseline |
| `greedy` | Selects highest predicted values (pure exploitation) |
| `variance` | Selects highest ensemble prediction variance (uncertainty sampling) |
| `tanimoto` | Selects most structurally dissimilar to the current labeled set (diversity) |
| `doubtscore` | Combined uncertainty + diversity score |
| `information sensitivity` | Selects compounds with highest gradient-based information sensitivity |

For `tanimoto`, acquisition is automatically inverted (lower similarity = higher rank) — the `--invert` flag is set automatically in `run-inner-cycle.sh` based on `info.json`.

---

## Model configurations

Bundled configs are in `models/configs/`. Each is a JSON file passed to `duvidnn`.

| File | Architecture | Notes |
|---|---|---|
| `ffn-5x16x10.json` | 5-layer fingerprint FFN, 16 units, ensemble of 10 | Default |
| `ffn-3x16x5.json` | 3-layer fingerprint FFN, 16 units, ensemble of 10 | Lighter |
| `ffn-5x16x10+3d.json` | As default + 3D conformer features | Requires 3D coords |
| `ffn-5x16x10+llm.json` | As default + LLM embeddings from `lchemme-base` | Slower; requires network on first run |
| `cp-5x16x10.json` | ChemProp message-passing GNN, ensemble of 10 | Best for scaffold generalisation |

To use a custom config:

```bash
nextflow run scbirlab/nf-alchemish --model_config /path/to/my-model.json ...
```

---

## Running on SLURM

The `standard` profile submits all Nextflow processes as SLURM jobs. The outer script manages concurrency of the per-combination inner loops via a SLURM job array.

```bash
bash scripts/run-active-learning.sh 10 /scratch/my-experiment slurm
```

Key SLURM settings (in `nextflow.config`):

```groovy
executor {
    queueSize = 100         // max concurrent Nextflow-managed jobs
    submitRateLimit = '10/1min'
}
process {
    array = 100             // use SLURM array jobs where possible
}
```

`MAX_PARALLEL` in `run-active-learning.sh` (default 5) caps how many inner cycle loops run simultaneously, preventing the orchestration jobs from consuming all available SLURM slots.

To cancel all running jobs for this pipeline:

```bash
bash interrupt.sh   # generated at runtime when slurm mode is active
```

### GPU processes

GPU processes use the `gpu_single` label, targeting the `ga100` queue. To enable them, uncomment the `label "gpu_single"` lines in `modules/training.nf` and `modules/predicting.nf`, and adjust the queue name to match your cluster:

```groovy
withLabel: gpu_single {
    queue = 'your-gpu-queue'
    clusterOptions = '--gres=gpu:1'
}
```

---

## Advanced usage

### Remote datasets

The `dataset` column in the sample sheet accepts HuggingFace dataset URLs and HTTPS paths:

```csv
id,dataset,structure,split,target
chembl,hf://datasets/org/chembl-props,smiles,scaffold,logp
```

Remote datasets use `split_data_remote`; local paths use `split_data_local`. The pipeline branches automatically.

### Resuming an interrupted run

All Nextflow processes use `-resume`. If an inner cycle loop is interrupted, re-run `run-active-learning.sh` with the same arguments — init will resume from cache, and each cycle loop re-submits with `-resume`, picking up from the last completed cycle.

Each cycle runs in a shared `-work-dir` rooted at the experiment directory, so resume works across re-submissions.

### Adjusting batch and init sizes independently

`init_batch_size` and `batch_size` are independent parameters. A typical design:

```groovy
// nextflow.config in your working directory
params {
    init_batch_size = 50    // small cold start
    batch_size = 25         // fine-grained learning curve
    cycles = 20
}
```

### Cleaning the prediction cache

`duvidnn` caches featurized structures. A convenience script is generated at runtime:

```bash
bash clean-cache.sh     # removes cache entries older than 2 hours
```

---

## Developer guide

### Repository structure

```
nf-alchemish/
├── main.nf                         # Workflow definitions (init, active_learning)
├── nextflow.config                 # Parameters and profiles
├── modules/
│   ├── batches.nf                  # take_first_batch, acquire
│   ├── data-prep.nf                # split_data_remote, split_data_local
│   ├── db-stats.nf                 # get_chunk_indices
│   ├── info.nf                     # write_init_info
│   ├── predicting.nf               # predict, CleanUpModelFiles
│   └── training.nf                 # train, train_initial_model
├── scripts/
│   ├── run-active-learning.sh      # Outer orchestration (init + job array)
│   └── run-inner-cycle.sh          # Single-combination cycle loop
├── models/configs/                 # Bundled model architecture JSONs
└── test/spark/                     # Integration test inputs
```

### Architecture

Nextflow's DAG model does not natively support iterative feedback loops (each cycle's trained model is the input to the next cycle's prediction step). The pipeline works around this by keeping the sequential cycle loop in `run-inner-cycle.sh`, which calls `nextflow run --workflow cycle` once per cycle. Each invocation is a complete Nextflow execution that resumes from the previous cycle's output.

The outer `run-active-learning.sh` runs `--workflow init` once, then dispatches one `run-inner-cycle.sh` per (id × fold × init replicate × acquisition function) combination as a SLURM job array with concurrency capped at `MAX_PARALLEL`.

All cycle runs within an experiment share a single `-work-dir`, so Nextflow's task cache is shared and `-resume` works across all of them.

### Adding an acquisition function

1. Add the acquisition logic to the `acquire` process in `modules/batches.nf`. The process branches on `acq` name; add a new branch in the `colMap` or add a new conditional block for more complex logic.

2. Add the name to the default `acquisitions` list in `nextflow.config` if it should run by default.

3. If the function requires inverted ranking (lower score = better, like `tanimoto`), add a condition for `inv_flag` in `run-inner-cycle.sh`:

```bash
if [ "$acq" == "tanimoto" ] || [ "$acq" == "my-diversity-fn" ]
then
    inv_flag='--invert'
fi
```

### Testing

Tests use [nf-test](https://nf-co.re/docs/contributing/nf-test/). The test dataset is an E. coli growth inhibition screen (`test/spark/`).

```bash
cd test
bash run-tests.sh
```

The test config uses reduced parameters (2 folds, 2 init replicates, 3 cycles, 3 epochs) to keep runtime tractable. The `gh` profile is used in CI.

### Dependencies

Core tools, managed via conda (`environment.yml`) or the container (`ghcr.io/scbirlab/nf-alchemish:latest`):

| Tool | Role |
|---|---|
| [`duvidnn`](https://github.com/scbirlab/duvidnn) | Ensemble neural network training and prediction |
| [`eluent`](https://github.com/scbirlab/eluent) | Chemical dataset splitting (scaffold, FAISS) |
| `duckdb` | In-process SQL for batch sampling and index management |
| `jq` | JSON parsing in shell scripts |

The container is built from `Dockerfile` and published to `ghcr.io/scbirlab/nf-alchemish` on push to `main`.
