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

SCRIPT_PATH="${BASH_SOURCE[0]}"

# resolve symlinks
while [ -h "$SCRIPT_PATH" ]; do
  DIR="$( cd -P "$( dirname "$SCRIPT_PATH" )" >/dev/null 2>&1 && pwd )"
  SCRIPT_PATH="$( readlink "$SCRIPT_PATH" )"
  [[ "$SCRIPT_PATH" != /* ]] && SCRIPT_PATH="$DIR/$SCRIPT_PATH"
done

# absolute directory
script_dir="$( cd -P "$( dirname "$SCRIPT_PATH" )" >/dev/null 2>&1 && pwd )"
if [ "$slurm" == "slurm" ]
then
    inner_runner="sbatch -o nf-alchemish-inner.log"
    profile=standard
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

nextflow run "$script_dir"/.. \
    --workflow init \
    --outputs "$outputs" \
    -profile "$profile" \
    -resume

n_cycles=1
output_dirs=( "$outputs"/*/ )
start_dir=$(pwd)
for id in "${output_dirs[@]}"
do  
    echo "id = $id"
    for split in "$id"/split-*/
    do  
        echo "split = $split"
        for sample in "$split"/sample-*/
        do  
            echo "sample = $sample"
            for acq in "$sample"/*/
            do
                if [[ $(basename "$acq") != "cycle-"* ]]
                then
                    echo "acq = $acq"
                    if [ ! -e "$acq"/work ]
                    then
                        mkdir -p "$acq"/work
                    fi
                    ln -sf "$(readlink -f "$start_dir"/work/conda)" "$acq"/work/conda
                    cd "$acq"
                    $inner_runner \
                        "$script_dir"/run-inner-cycle.sh \
                        "." "$max_cycles" "$profile" "$script_dir"
                    cd "$start_dir"
                fi
                done
        done
    done
done
