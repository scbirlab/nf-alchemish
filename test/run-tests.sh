 #!/usr/bin/env bash

set -exuo pipefail

LOCATION=${1:-no}
script_dir="$(dirname $0)"

if [ "$LOCATION" == "gh" ]
then
    export NXF_CONTAINER_ENGINE=docker
    docker_flag='-profile gh'
    SLURM_FLAG="no"
elif  [ "$LOCATION" == "crick" ]
then
    export NXF_CONTAINER_ENGINE=conda
    docker_flag=''
    SLURM_FLAG="slurm"
    module load Singularity Nextflow
else
    docker_flag='-profile local'
    SLURM_FLAG="no"
fi

cd "$script_dir"/spark
bash ../../scripts/run-active-learning.sh 3 . "$SLURM_FLAG" "$LOCATION"
cd ..
