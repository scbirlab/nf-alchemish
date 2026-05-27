#!/usr/bin/env bash

#SBATCH --job-name=nf-alchemish
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem-per-cpu=16G
#SBATCH --time=7-0:00:00
#SBATCH --mail-type=ALL
#SBATCH --output=nf-alchemish.log

set -exuo pipefail

max_cycles=${1:-10}
output_dir=${2:-"."}
slurm=${3:-"no"}
github=${4:-"no"}

outputs="$output_dir/outputs"

MAX_BATCH_SIZE=100  # prevent slurm swamping
SCRIPT_PATH="${BASH_SOURCE[0]}"

all_jobs=()
batch_jobs=()

submit_batch() {
    local jobids=$(IFS=:; echo "${batch_jobs[*]}")
    all_jobs+=("${batch_jobs[@]}")
    batch_jobs=()

    echo "Submitted batch: $jobids"
}

# resolve symlinks
while [ -h "$SCRIPT_PATH" ]; do
  DIR="$( cd -P "$( dirname "$SCRIPT_PATH" )" >/dev/null 2>&1 && pwd )"
  SCRIPT_PATH="$( readlink "$SCRIPT_PATH" )"
  [[ "$SCRIPT_PATH" != /* ]] && SCRIPT_PATH="$DIR/$SCRIPT_PATH"
done

# absolute directory
script_dir="$( cd -P "$( dirname "$SCRIPT_PATH" )" >/dev/null 2>&1 && pwd )"
script_dir="$(readlink -f "$script_dir")"
if [ "$slurm" == "slurm" ]
then
    inner_runner="sbatch -o nf-alchemish-inner.log"
    profile=standard
    if [ -f "interrupt.sh" ]
    then
        rm "interrupt.sh"
    fi

    for x in inner active
    do
        echo "squeue -h --me -o "'"%i %j"'" | awk '\$2 ~ /^nf-$x/ {print \$1}' | xargs scancel" \
        >> interrupt.sh
    done
else
    inner_runner="bash"
    if [ "$github" == "gh" ]
    then
        profile=gh
        script_dir=$(readlink -f $(dirname "$0"))
    else
        profile=local
    fi
fi

echo 'find ~/.cache/duvidnn/0.0.1/parquet -mindepth 1 -maxdepth 1 -type d -mmin +120 -exec rm -rf {} +' \
> clean-cache.sh

nextflow run "$script_dir"/.. \
    --workflow init \
    --outputs "$outputs" \
    -profile "$profile" \
    -with-dag init.html \
    -resume

n_cycles=1
output_dirs=( "$outputs"/*/ )
start_dir=$(pwd)
if [ -f "logfiles.txt" ]
then
    mv "logfiles.txt" "logfiles_old.txt"
fi

for id in "${output_dirs[@]}"
do  
    echo "id = $id"
    for split in "$id"runs/method_*/
    do  
        echo "split = $split"
        for sample in "$split"fold_*/sample_*/
        do  
            echo "sample = $sample"
            for acq in "$sample"*/
            do
                if [ "$(basename "$acq")" != "cycle_0" ]
                then
                    echo "acq = $acq"
                    if [ "$slurm" == "slurm" ]
                    then
                        log_filename="$acq""nf-alchemish-inner.log"
                        inner_runner="sbatch -o $log_filename"
                        echo "$log_filename" >> "logfiles.txt"
                    else
                        inner_runner="bash"
                    fi
                    acq="$(readlink -f "$acq")"
                    cmd="$inner_runner '"$script_dir"'/run-inner-cycle.sh '"$acq"' $max_cycles '"$profile"' '"$script_dir"'"
                    echo "$cmd" > "$acq"run.sh
                    bash "$acq"run.sh
                fi
                done
        done
    done
done
echo 'tail -f $(cat "logfiles.txt")' > "log-follow.sh"
