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

MAX_PARALLEL=5  # prevent slurm swamping
SCRIPT_PATH="${BASH_SOURCE[0]}"

run_with_limit() {
    while [ "$(jobs -rp | wc -l)" -ge "$MAX_PARALLEL" ]
    do
        sleep 5
    done
    bash "$1" &
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

job_scripts=()
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
                    acq="$(readlink -f "$acq")"
                    cat > "$acq/run.sh" <<EOF
#!/usr/bin/env bash
bash "${script_dir}/run-inner-cycle.sh" "${acq}" "${max_cycles}" "${profile}" "${script_dir}"
EOF

                    job_scripts+=( "$acq/run.sh" )
                fi
                done
        done
    done
done

if [ "${#job_scripts[@]}" -eq 0 ]; then
    echo "No inner cycle jobs to submit."
    exit 0
fi

printf '%s\n' "${job_scripts[@]}" > job_list.txt
job_list_abs="$(readlink -f job_list.txt)"
if [ "$slurm" == "slurm" ]
then
    sbatch --array=0-$(( ${#job_scripts[@]} - 1 ))%$MAX_PARALLEL \
        --job-name=nf-inner \
        -o nf-inner-%a.log \
        --wrap='bash $(sed -n "$((SLURM_ARRAY_TASK_ID + 1))p" '"${job_list_abs}"')'
else
    for j in "${job_scripts[@]}"
    do
        run_with_limit "$j"
    done
    wait  # block until all finish
fi
for i in $(seq 0 $(( ${#job_scripts[@]} - 1 ))); do
    echo "$(pwd)/nf-inner-${i}.log"
done > logfiles.txt
echo 'tail -f $(cat "logfiles.txt")' > "log-follow.sh"
