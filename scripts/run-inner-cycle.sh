#!/usr/bin/env bash

#SBATCH --job-name=nf-inner
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem-per-cpu=16G
#SBATCH --time=7-0:00:00

set -exuo pipefail

init_dir="$1"
max_cycles="${2:-10}"
profile="${3:-"local"}"
script_dir="${4:-$(readlink -f $(dirname "$0"))}"

init_dir_0="$init_dir"
init_dir="."
cd "$init_dir_0"

splits_dir="$(readlink -f "$init_dir/../../../../../splits")"
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
split_rep=$(jq -r '.split_rep' < "$info_file")
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

model="$init_dir/../cycle_0/model.dv"
training_idx="$init_dir/../cycle_0/idx_all.csv"
n_cycles=1
while [ "$n_cycles" -le "$max_cycles" ]
do
    cycle_dir="$init_dir/cycle_$n_cycles"
    mkdir -p "$cycle_dir"
    nextflow run "$script_dir"/.. \
        --workflow cycle \
        --pool "$splits_dir"/method_*/"fold_$split_rep/data_train.parquet" \
        --val "$splits_dir"/method_*/"fold_$split_rep/data_validation.parquet" \
        --test "$splits_dir"/method_*/"fold_$split_rep/data_test.parquet" \
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
        -with-dag inner.html \
        -work-dir "$(readlink -f "$splits_dir"/../../..)"/work \
        -profile "$profile" #\
        # -with-report "$cycle_dir/report_cycle-${n_cycles}.html"

    if [ "$n_cycles" -lt "$max_cycles" ] && [ "$n_cycles" -gt "3" ]
    then
        # clean up models if not first or final cycle
        old_cycle=$(( $n_cycles - 2 ))
        old_cycle_dir="$init_dir/cycle_$old_cycle"
        old_model="$old_cycle_dir/model.dv"
        for bname in input-data.hf training-data.hf params.pt
        do
            filename="${old_model}/$bname"
            if [ -f "$filename" ]
            then
                rm -r "$filename"
            fi
        done
    fi
    # After each run, update the variables for the next iteration:
    model="$cycle_dir/model.dv"
    training_idx="$cycle_dir/idx_all.csv"

    n_cycles=$(( $n_cycles + 1 ))
done
