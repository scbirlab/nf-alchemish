 #!/usr/bin/env bash

set -exuo pipefail

GITHUB=${1:-no}
script_dir="$(dirname $0)"

if [ "$GITHUB" == "gh" ]
then
    export NXF_CONTAINER_ENGINE=docker
    docker_flag='-profile gh'
else
    export SINGULARITY_FAKEROOT=1
    docker_flag=''
fi

cd "$script_dir"/spark
bash ../../scripts/run-active-learning.sh 3 . no "$GITHUB"
cd ..
