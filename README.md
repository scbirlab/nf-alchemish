# nf-alchemish

![GitHub Workflow Status (with branch)](https://img.shields.io/github/actions/workflow/status/scbirlab/nf-alchemish/nf-test.yml)
[![Nextflow](https://img.shields.io/badge/nextflow%20DSL2-%E2%89%A524.0.0-23aa62.svg)](https://www.nextflow.io/)
[![run with conda](https://img.shields.io/badge/run%20with-conda-3EB049?labelColor=000000&logo=anaconda)](https://docs.conda.io/en/latest/)
[![run with docker](https://img.shields.io/badge/run%20with-docker-0db7ed?labelColor=000000&logo=docker)](https://www.docker.com/)
[![run with singularity](https://img.shields.io/badge/run%20with-singularity-1d355c.svg?labelColor=000000)](https://sylabs.io/docs/)

**scbirlab/nf-alchemish** is a [Nextflow](https://www.nextflow.io/) DSL2 pipeline for running **active learning experiments on chemical datasets**. It iteratively trains neural network ensembles to predict molecular properties (e.g. antimicrobial activity), then uses acquisition functions to select the most informative compounds from an unlabelled pool for the next round of labelling and retraining.

## Table of contents

- [Overview](#overview)
- [Pipeline architecture](#pipeline-architecture)
- [Requirements](#requirements)
- [Installation](#installation)
- [Quick start](#quick-start)
- [Usage](#usage)
  - [Input: sample sheet](#input-sample-sheet)
  - [Input: dataset format](#input-dataset-format)
  - [Running the init workflow](#running-the-init-workflow)
  - [Running active learning cycles](#running-active-learning-cycles)
  - [Using the orchestration scripts](#using-the-orchestration-scripts)
- [Parameters](#parameters)
- [Acquisition functions](#acquisition-functions)
- [Model configurations](#model-configurations)
- [Output structure](#output-structure)
- [Execution profiles](#execution-profiles)
- [Container and environment](#container-and-environment)
- [Testing](#testing)
- [License](#license)

## Overview

Active learning is a machine learning strategy where the model iteratively selects which data points to label next, focusing on the samples that are expected to be most informative. In the context of drug discovery, this means selecting which chemical compounds to assay next in order to build the best predictive model with the fewest experiments.

nf-alchemish automates this process end-to-end:

1. **Split** a chemical dataset into pool (unlabelled), validation, and test sets using scaffold-based or FAISS-based diversity splitting.
2. **Sample** an initial batch of compounds from the pool using reservoir sampling.
3. **Train** a neural network ensemble on the labelled subset.
4. **Predict** on the remaining unlabelled pool, computing uncertainty and diversity metrics.
5. **Acquire** the next batch of compounds using one of several acquisition functions.
6. **Retrain** the model on the expanded labelled set.
7. **Repeat** steps 4-6 for a configurable number of cycles.

The pipeline runs multiple split replicates, initialisation replicates, and acquisition functions in parallel, producing a comprehensive comparison of active learning strategies.

## Pipeline architecture

The pipeline has two workflow modes controlled by the `--workflow` parameter:

### `init` workflow

Handles all initial setup: reading the sample sheet, splitting data, drawing the first labelled batch, training the initial model, and writing metadata for each experimental configuration.

```
sample_sheet.csv
      |
      v
  split_data  (scaffold or FAISS splitting, multiple replicates)
      |
      v
  take_first_batch  (reservoir sampling of initial labelled set)
      |
      v
  train_initial_model  (train ensemble on initial labelled data)
      |
      v
  write_init_info  (record metadata as info.json)
```

### `cycle` workflow

Runs a single active learning iteration: predicting on the pool, acquiring new samples, and retraining. The orchestration scripts call this workflow repeatedly in a loop.

```
  model + training_idx
      |
      v
  get_chunk_indices  (partition pool into chunks for parallel prediction)
      |
      v
  predict  (run model on each chunk, output uncertainty/diversity scores)
      |
      v
  acquire  (select next batch using acquisition function)
      |
      v
  train  (retrain model on expanded labelled set)
      |
      v
  new model + updated training_idx
```

### Modules

| Module | File | Purpose |
|--------|------|---------|
| Data preparation | `modules/data-prep.nf` | Split datasets into pool/validation/test using `duvida split`. Supports local files and remote sources (HuggingFace, HTTPS). Adds `rowid` column for index tracking. |
| Batch sampling | `modules/batches.nf` | `take_first_batch`: reservoir sampling for initial labelled set. `acquire`: select next batch using acquisition functions via DuckDB SQL. |
| Training | `modules/training.nf` | `train_initial_model`: train on first labelled batch. `train`: retrain on expanded labelled set in subsequent cycles. Both use `duvida train`. |
| Prediction | `modules/predicting.nf` | Run model inference on pool data chunks. Outputs prediction variance, Tanimoto nearest-neighbour distance, optimality scores, and optionally doubt scores or information sensitivity. |
| Chunking | `modules/db-stats.nf` | Partition the pool into fixed-size chunks (default 1000 rows) for parallelised prediction. |
| Metadata | `modules/info.nf` | Write `info.json` files recording experimental configuration (structure column, target, acquisition function, model config, epochs). |

## Requirements

- [Nextflow](https://www.nextflow.io/) >= 24.0.0
- One of:
  - [Docker](https://www.docker.com/)
  - [Singularity](https://sylabs.io/docs/)
  - [Conda](https://docs.conda.io/en/latest/) / [Micromamba](https://mamba.readthedocs.io/)
- GPU recommended for training and prediction (CUDA-compatible)

## Installation

Clone the repository:

```bash
git clone https://github.com/scbirlab/nf-alchemish.git
cd nf-alchemish
```

Or run directly with Nextflow:

```bash
nextflow run scbirlab/nf-alchemish --workflow init --sample_sheet sample-sheet.csv
```

The pipeline container image is available at `ghcr.io/scbirlab/nf-alchemish:latest`.

## Quick start

```bash
# Run the full active learning pipeline (init + 10 cycles) locally
bash scripts/run-active-learning.sh 10 .
```

Or step by step:

```bash
# Step 1: Initialise (split data, train initial models)
nextflow run scbirlab/nf-alchemish \
    --workflow init \
    --sample_sheet sample-sheet.csv \
    -profile local

# Step 2: Run active learning cycles (handled by the orchestration scripts)
bash scripts/run-inner-cycle.sh outputs/1/split-1/sample-1/random 10 local
```

## Usage

### Input: sample sheet

A CSV file with the following columns:

| Column | Description |
|--------|-------------|
| `id` | Experiment identifier (used in output directory naming) |
| `dataset` | Path to a local CSV file, or a remote source prefixed with `hf:` (HuggingFace) or `https:` |
| `structure` | Name of the column containing molecular representations (e.g. `smiles`) |
| `split` | Data splitting method: `scaffold` (Murcko scaffold) or `faiss` (FAISS-based diversity) |
| `target` | Name of the column containing the property to predict (e.g. `pmic`) |

Example:

```csv
id,dataset,structure,split,target
1,inputs/e-coli-training-data-sample.csv,smiles,scaffold,pmic
1,inputs/e-coli-training-data-sample.csv,smiles,faiss,pmic
```

Multiple rows with the same `id` but different `split` methods will produce separate split replicates under the same experiment directory.

### Input: dataset format

CSV files with at minimum:

- A **structure column** containing SMILES strings (or other molecular representations supported by `duvida`).
- A **target column** containing numeric property values to predict.

Additional columns are preserved but not used by the pipeline.

### Running the init workflow

```bash
nextflow run scbirlab/nf-alchemish \
    --workflow init \
    --sample_sheet sample-sheet.csv \
    --pool 0.8 \
    --validation 0.1 \
    --test 0.1 \
    --init_batch_size 100 \
    --split_replicates 3 \
    --init_replicates 3 \
    --epochs 10 \
    --model_config models/configs/ffn-5x16x10.json \
    -profile local
```

### Running active learning cycles

The `cycle` workflow runs a single active learning iteration. It is normally invoked by the orchestration scripts rather than directly:

```bash
nextflow run scbirlab/nf-alchemish \
    --workflow cycle \
    --pool splits/split_train.parquet \
    --val splits/split_validation.parquet \
    --test splits/split_test.parquet \
    --structure smiles \
    --target pmic \
    --acquisition variance \
    --cycle 1 \
    --model model_cycle-0.dv \
    --training_idx idx_cycle-0.csv \
    --outputs outputs/cycle-1 \
    -profile local
```

### Using the orchestration scripts

The recommended way to run the full pipeline is via the shell scripts in `scripts/`:

**`scripts/run-active-learning.sh`** orchestrates the complete experiment:

```bash
bash scripts/run-active-learning.sh [max_cycles] [output_dir] [slurm|no] [gh|no]
```

| Argument | Default | Description |
|----------|---------|-------------|
| `max_cycles` | `10` | Number of active learning cycles |
| `output_dir` | `.` | Base output directory |
| `slurm` | `no` | Set to `slurm` to submit jobs via SBATCH |
| `github` | `no` | Set to `gh` for GitHub Actions execution |

This script:
1. Runs the `init` workflow.
2. Iterates over all generated experiment/split/sample/acquisition directories.
3. Launches `run-inner-cycle.sh` for each configuration.

**`scripts/run-inner-cycle.sh`** runs the cycle loop for one acquisition function:

```bash
bash scripts/run-inner-cycle.sh <init_dir> [max_cycles] [profile] [script_dir]
```

It reads `info.json` from the init directory to recover structure, target, acquisition function, epochs, and model config, then loops through cycles sequentially, updating the model and training indices after each iteration.

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `--workflow` | *(required)* | `init` or `cycle` |
| `--sample_sheet` | *(required for init)* | Path to sample sheet CSV |
| `--pool` | `0.8` | Fraction of data allocated to the unlabelled pool (init) or path to pool parquet (cycle) |
| `--validation` | `0.1` | Fraction for validation set (init) or path to validation parquet (cycle) |
| `--test` | `0.1` | Fraction for test set (init) or path to test parquet (cycle) |
| `--k` | `3` | Number of neighbours for FAISS splitting |
| `--init_batch_size` | `100` | Number of compounds in the initial labelled batch |
| `--batch_size` | `100` | Number of compounds acquired per cycle |
| `--epochs` | `10` | Training epochs per model |
| `--split_replicates` | `3` | Number of independent data split replicates |
| `--init_replicates` | `3` | Number of independent initial batch replicates |
| `--acquisitions` | `["random", "tanimoto", "variance", "doubtscore", "information sensitivity"]` | List of acquisition functions to evaluate |
| `--model_config` | `models/configs/ffn-5x16x10.json` | Path to neural network configuration JSON |
| `--cycles` | `10` | Number of active learning cycles |
| `--invert` | `false` | Invert acquisition function ordering |
| `--outputs` | `outputs` | Output directory |
| `--help` | `false` | Print help text and exit |

## Acquisition functions

The pipeline evaluates five acquisition strategies:

| Function | Description | Score source |
|----------|-------------|--------------|
| **random** | Uniform random sampling (baseline). Uses DuckDB reservoir sampling. | None |
| **variance** | Selects compounds where the ensemble has highest prediction variance (uncertainty sampling). | `prediction variance` from `duvida predict --variance` |
| **tanimoto** | Selects compounds most dissimilar to the training set by Tanimoto nearest-neighbour distance (diversity sampling). | `tanimoto_nn` from `duvida predict --tanimoto` |
| **doubtscore** | Selects compounds with highest doubt score, a combined uncertainty metric. | `doubtscore` from `duvida predict --doubtscore` |
| **information sensitivity** | Selects compounds where predictions are most sensitive to input perturbations. | `information sensitivity` from `duvida predict --information-sensitivity` |

Non-random acquisition functions use a weighted pseudorandom sampling scheme (based on [Moertel 2024](https://blog.moertel.com/posts/2024-08-23-sampling-with-sql.html)) implemented in DuckDB SQL, where compounds with higher acquisition scores have proportionally higher probability of selection.

## Model configurations

Two neural network configurations are provided in `models/configs/`:

### `ffn-5x16x10.json` (default)

A fingerprint-based feed-forward ensemble:

- **Architecture**: 5 hidden layers, 16 units each, residual connections (depth 2)
- **Ensemble**: 20 members (for uncertainty quantification)
- **Features**: 2D molecular descriptors + molecular fingerprints
- **Learning rate**: 1e-5, no dropout

### `ffn-5x16x10+llm.json`

Same architecture augmented with a transformer-based molecular featuriser:

- **Extra featuriser**: `scbirlab/lchemme-base-zinc22-lteq300` (mean pooling over SMILES tokens)
- **Ensemble**: 10 members (reduced to offset computational cost of the transformer)

## Output structure

```
outputs/
  {id}/
    split-{split_rep}/
      splits/
        split_train.parquet        # Pool data (with rowid column)
        split_validation.parquet   # Validation set
        split_test.parquet         # Test set
        split-plot.png             # Visualisation of splits
        split-plot.csv             # Plot data
      sample-{init_rep}/
        cycle-0/
          idx_cycle-0.csv          # Initial labelled indices
          model_cycle-0.dv/        # Initial trained model checkpoint
            *.csv                  # Evaluation predictions
            *.png                  # Training curves, plots
            *.json                 # Metrics, hyperparameters
        {acquisition_fn}/
          info.json                # Experiment metadata
          cycle-1/
            idx_cycle-1.csv        # Newly acquired indices
            idx-all_cycle-1.csv    # Cumulative labelled indices
            predicted-*.parquet    # Predictions on pool chunks
            model_cycle-1.dv/      # Retrained model
          cycle-2/
            ...
```

Key output files:

- **`idx_cycle-N.csv`**: Row IDs of compounds selected in cycle N.
- **`idx-all_cycle-N.csv`**: Cumulative row IDs of all labelled compounds up to and including cycle N.
- **`predicted-{start}-{stop}.parquet`**: Model predictions on pool chunks, including variance, Tanimoto distance, and acquisition-specific scores.
- **`model_cycle-N.dv/`**: `duvida` model checkpoint directory containing weights and evaluation outputs.

## Execution profiles

| Profile | Executor | Description |
|---------|----------|-------------|
| `standard` | SLURM | For HPC clusters with GPU nodes. Uses `ga100` queue, cuDNN 8.9.2/CUDA 12.1.1 modules. GPU tasks get 1 GPU and 128 GB RAM. Email notifications to `$USER@crick.ac.uk`. |
| `local` | Local | For local machines with reduced memory allocations. |
| `gh` | Local | For GitHub Actions CI. Conda-based, 12 GB memory limit, Docker disabled. |

GPU-labelled processes (`gpu_single`): training and prediction.
CPU-only processes: data splitting, batch sampling, chunking, metadata writing.

## Container and environment

### Docker / Singularity

The container image (`ghcr.io/scbirlab/nf-alchemish:latest`) is built from `mambaorg/micromamba:1.5.6` and includes:

- Python 3.12
- [duvida](https://github.com/scbirlab/duvida) (with `chem`, `splits`, and `transformers` extras) -- the core ML toolkit for chemical property prediction
- DuckDB CLI -- for efficient SQL-based data manipulation on CSV/Parquet files
- jq -- for JSON processing in shell scripts
- Build tools (gcc, g++) for compiled dependencies

### Conda

The same environment can be created locally from `environment.yml`:

```bash
conda env create -f environment.yml
conda activate nf-alchemish
```

Note: `duvida` is installed from a specific git branch (`chem-splitting`), not from a release on PyPI.

## Testing

The test suite in `test/` runs a scaled-down version of the full pipeline on a sample E. coli antimicrobial activity dataset (~750 compounds):

```bash
# Run tests locally
bash test/run-tests.sh

# Run tests as in GitHub Actions
bash test/run-tests.sh gh
```

The test configuration (`test/spark/nextflow.config`) uses reduced parameters:
- Pool fraction: 0.3 (vs 0.8)
- 3 epochs (vs 10)
- 2 split/init replicates (vs 3)
- 3 active learning cycles (vs 10)

CI runs automatically on push via GitHub Actions (`.github/workflows/nf-test.yml`).

## License

MIT License. See [LICENSE](LICENSE) for details.
