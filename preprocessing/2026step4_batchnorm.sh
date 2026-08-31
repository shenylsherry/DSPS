#!/bin/bash

set -u

# ============================================================
# Settings
# ============================================================

analyze_dir=/mnt/d/imagetransfer2026/Analysis_FSL

# Current subject ID, for example H00648KY
SUBJ_GLOB='H00875SA'

# Expect 6 runs per subject
NRUNS=6

# Maximum number of runs processed concurrently per subject
CONCURRENT_RUNS=6


# ============================================================
# Function: process one run
# ============================================================

process_run() {

    local sub="$1"
    local run="$2"

    local subname
    subname=$(basename "$sub")

    local featdir="$sub/run${run}.feat"

    local input="$featdir/filtered_func_data.nii.gz"

    local premat="$featdir/reg/example_func2highres.mat"

    local warp="$featdir/reg/highres2standard_warp.nii.gz"

    local ref="$featdir/reg/standard.nii.gz"

    # Use the output name required by the legacy ICA pipeline
    local output="$sub/epi/run${run}_norm.nii.gz"


    echo
    echo "[$subname] ---- run${run} ----"


    # --------------------------------------------------------
    # Check FEAT directory
    # --------------------------------------------------------

    if [[ ! -d "$featdir" ]]; then

        echo "[$subname run${run}] SKIP: FEAT directory not found:"
        echo "  $featdir"

        return 1
    fi


    # --------------------------------------------------------
    # Check files
    # --------------------------------------------------------

    if [[ ! -f "$input" ]]; then

        echo "[$subname run${run}] ERROR: input not found:"
        echo "  $input"

        return 1
    fi


    if [[ ! -f "$premat" ]]; then

        echo "[$subname run${run}] ERROR: example_func2highres.mat not found:"
        echo "  $premat"

        return 1
    fi


    if [[ ! -f "$warp" ]]; then

        echo "[$subname run${run}] ERROR: highres2standard_warp not found:"
        echo "  $warp"

        return 1
    fi


    if [[ ! -f "$ref" ]]; then

        echo "[$subname run${run}] ERROR: standard reference not found:"
        echo "  $ref"

        return 1
    fi


    # --------------------------------------------------------
    # Skip if already normalized
    # --------------------------------------------------------

    if [[ -f "$output" ]]; then

        echo "[$subname run${run}] SKIP existing:"
        echo "  $output"

        return 0
    fi


    # --------------------------------------------------------
    # Functional native -> MNI standard space
    #
    # EPI -> T1:
    #   example_func2highres.mat
    #
    # T1 -> MNI:
    #   highres2standard_warp.nii.gz
    #
    # Apply both transforms in a single applywarp call
    # to avoid repeated interpolation
    # --------------------------------------------------------

    echo "[$subname run${run}] START applywarp"

    echo "Input:"
    echo "  $input"

    echo "Output:"
    echo "  $output"


    applywarp \
        --ref="$ref" \
        --in="$input" \
        --out="$output" \
        --premat="$premat" \
        --warp="$warp"


    # --------------------------------------------------------
    # Check result
    # --------------------------------------------------------

    if [[ -f "$output" ]]; then

        echo
        echo "[$subname run${run}] DONE"

        echo -n "  dimensions: "

        fslval "$output" dim1 | tr '\n' ' '
        fslval "$output" dim2 | tr '\n' ' '
        fslval "$output" dim3 | tr '\n' ' '
        fslval "$output" dim4


        echo -n "  voxel size: "

        fslval "$output" pixdim1 | tr '\n' ' '
        fslval "$output" pixdim2 | tr '\n' ' '
        fslval "$output" pixdim3


        return 0

    else

        echo
        echo "[$subname run${run}] ERROR: applywarp failed"

        return 1
    fi
}


# ============================================================
# Check commands
# ============================================================

for cmd in applywarp fslval; do

    if ! command -v "$cmd" >/dev/null 2>&1; then

        echo "ERROR: $cmd not found in PATH" >&2
        exit 1

    fi

done


# ============================================================
# Loop subjects
# ============================================================

for sub in "$analyze_dir"/$SUBJ_GLOB; do

    [[ -d "$sub" ]] || continue


    subname=$(basename "$sub")


    echo
    echo "============================================================"
    echo "Subject: $subname"
    echo "Parallel runs: $CONCURRENT_RUNS"
    echo "============================================================"


    # Prepare the input directory for the legacy ICA pipeline
    mkdir -p "$sub/epi"


    # ========================================================
    # Run 1-6 in parallel
    # ========================================================

    for run in $(seq 1 "$NRUNS"); do

        # ----------------------------------------------------
        # Enforce the maximum concurrency
        # ----------------------------------------------------

        while (( $(jobs -rp | wc -l) >= CONCURRENT_RUNS )); do

            wait -n 2>/dev/null || sleep 1

        done


        # ----------------------------------------------------
        # Process the current run in the background
        # ----------------------------------------------------

        process_run "$sub" "$run" &

    done


    # ========================================================
    # IMPORTANT:
    #
    # Wait for all runs of the current subject to finish
    # before proceeding to the next subject.
    #
    # Therefore, the maximum number running concurrently is:
    #
    # 6 applywarp processes
    #
    # rather than:
    #
    # N subjects × 6 processes
    # ========================================================

    wait


    # ========================================================
    # Check subject results
    # ========================================================

    echo
    echo "------------------------------------------------------------"
    echo "Check outputs: $subname"
    echo "------------------------------------------------------------"


    n_done=0


    for run in $(seq 1 "$NRUNS"); do

        output="$sub/epi/run${run}_norm.nii.gz"

        if [[ -f "$output" ]]; then

            echo "OK      run${run}: $output"

            n_done=$((n_done + 1))

        else

            echo "MISSING run${run}: $output"

        fi

    done


    echo
    echo "$subname: $n_done / $NRUNS runs completed"

done


echo
echo "============================================================"
echo "ALL DONE"
echo "============================================================"
