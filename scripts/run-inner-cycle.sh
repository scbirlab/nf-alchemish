#!/usr/bin/env bash

#SBATCH --job-name=nf-inner
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem-per-cpu=16G
#SBATCH --time=5-0:00:00

set -ex

init_dir=$1
max_cycles=${2:-10}
profile=${3:-"local"}
script_dir=${4:-$(readlink -f $(dirname "$0"))}

splits_dir="$init_dir/../../splits"
if [ ! -e "$splits_dir" ]
then
    echo "ERROR: $splits_dir doesn't exist!"
    exit 1
fi

info_file="$init_dir/info.json"
if [ ! -e "$info_file" ]
then
    echo "ERROR: $info_file doesn't exist!"
    exit 1
fi

splits_dir=$(readlink -f "$splits_dir")
info_file=$(readlink -f "$info_file")
structure=$(jq -r '.structure' < "$info_file")
target=$(jq -r '.target' < "$info_file")
acq=$(jq -r '.acquisition_fn' < "$info_file")
epochs=$(jq -r '.epochs' < "$info_file")
model_config=$(jq -r '.model_config' < "$info_file")

if [ "$acq" == "tanimoto" ]
then
    inv_flag='--invert'
else
    inv_flag=
fi

model="$init_dir/../cycle-0/model_cycle-0.dv"
training_idx="$init_dir/../cycle-0/idx_cycle-0.csv"
n_cycles=1
while [ "$n_cycles" -le "$max_cycles" ]
do
    cycle_dir="$init_dir/cycle-$n_cycles"
    mkdir -p "$cycle_dir"
    nextflow run "$script_dir"/.. \
        --workflow cycle \
        --pool "$splits_dir/split_train.parquet" \
        --val "$splits_dir/split_validation.parquet" \
        --test "$splits_dir/split_test.parquet" \
        --structure "$structure" \
        --target "$target" \
        --acquisition "$acq" "$inv_flag" \
        --cycle "$n_cycles" \
        --model "$model" \
        --epochs "$epochs" \
        --model_config "$model_config" \
        --training_idx "$training_idx" \
        --outputs "$cycle_dir" \
        -resume \
        -profile "$profile" #\
        # -with-report "$cycle_dir/report_cycle-${n_cycles}.html"

    # After each run, update the variables for the next iteration:
    model="$cycle_dir/model_cycle-$n_cycles.dv"
    training_idx="$cycle_dir/idx-all_cycle-$n_cycles.csv"

    n_cycles=$(( $n_cycles + 1 ))
done
