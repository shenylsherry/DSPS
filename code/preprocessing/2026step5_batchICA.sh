#!/bin/bash

set -u


# ============================================================
# Settings
# ============================================================

root_dir=/mnt/d/imagetransfer2026/Analysis_FSL

# Subjects: H00648KY etc.
SUBJ_GLOB='H00*'

# Number of runs per subject
NRUNS=6

# Maximum number of subjects processed simultaneously
CONCURRENT_SUBJECTS=5

# EPI directory
EPI_DIR_NAME=epi

# Input EPI:
#   epi/run1_norm.nii.gz
#   epi/run2_norm.nii.gz
#   ...
RUN_SUFFIX=_norm.nii.gz

# TR
TR=1.0

# Mean EPI generated from all six runs
MEAN_NAME=Mean_ICA.nii.gz

# 0 = skip existing ICA result
# 1 = remove existing ICA result and rerun
FORCE_ICA=0


# ============================================================
# Check commands
# ============================================================

for cmd in \
    flirt \
    fslmaths \
    fslmerge \
    fslval \
    melodic \
    realpath
do

    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: $cmd not found in PATH" >&2
        exit 1
    fi

done


# ============================================================
# Function: pre-ICA processing for ONE run
#
# $1 = subject directory
# $2 = input EPI
# $3 = T1 image
#
# Runs within one subject are processed sequentially.
# Different subjects are processed in parallel.
# ============================================================

calc_preica() {

    local inputdir
    inputdir=$(realpath "$1")

    local input
    input=$(realpath "$2")

    local t1image
    t1image=$(realpath "$3")

    local inputname
    inputname=$(basename "$input")

    # run1_norm.nii.gz -> run1_norm
    local runname="${inputname%.nii.gz}"

    local epidir="${inputdir}/${EPI_DIR_NAME}"

    # Example:
    # run1_norm.nii.gz
    # ->
    # preica_run1_norm.nii.gz
    local outfile="${epidir}/preica_${inputname}"

    # Unique temporary directory for this run
    local tdl
    tdl=$(mktemp -d "${inputdir}/calc_preica.${runname}.XXXXX")


    echo
    echo "------------------------------------------------------------"
    echo "Pre-ICA"
    echo "Subject : $(basename "$inputdir")"
    echo "Run     : $runname"
    echo "Input   : $input"
    echo "T1      : $t1image"
    echo "Output  : $outfile"
    echo "------------------------------------------------------------"


    cd "$tdl" || return 1


    # ========================================================
    # 1. T1 -> Mean EPI
    #
    # This follows the original ICA pipeline.
    #
    # T1 is taken from:
    # run1.feat/reg/highres2standard.nii.gz
    # ========================================================

    flirt \
        -ref "${inputdir}/${MEAN_NAME}" \
        -in "$t1image" \
        -omat "${inputdir}/T12epi.mat"

    if [[ $? -ne 0 ]]; then
        echo "ERROR: T1 -> Mean registration failed"
        cd "$inputdir"
        rm -rf "$tdl"
        return 1
    fi


    flirt \
        -ref "${inputdir}/${MEAN_NAME}" \
        -in "$t1image" \
        -applyxfm \
        -init "${inputdir}/T12epi.mat" \
        -out "${inputdir}/T1fromEPI"

    if [[ $? -ne 0 ]]; then
        echo "ERROR: T1fromEPI creation failed"
        cd "$inputdir"
        rm -rf "$tdl"
        return 1
    fi


    # ========================================================
    # 2. Temporal filtering
    # ========================================================

    fslmaths \
        "$input" \
        -Tmean \
        tempMean

    if [[ $? -ne 0 ]]; then
        echo "ERROR: Tmean failed"
        cd "$inputdir"
        rm -rf "$tdl"
        return 1
    fi


    fslmaths \
        "$input" \
        -bptf 62.5 -1 \
        -add tempMean \
        "filtered_func_data_${runname}"

    if [[ $? -ne 0 ]]; then
        echo "ERROR: temporal filtering failed"
        cd "$inputdir"
        rm -rf "$tdl"
        return 1
    fi


    # ========================================================
    # 3. Current run -> Mean EPI space
    # ========================================================

    flirt \
        -ref "${inputdir}/${MEAN_NAME}" \
        -in tempMean \
        -omat "${inputdir}/EPI2downsampEPI.mat"

    if [[ $? -ne 0 ]]; then
        echo "ERROR: EPI -> Mean registration failed"
        cd "$inputdir"
        rm -rf "$tdl"
        return 1
    fi


    flirt \
        -ref "${inputdir}/${MEAN_NAME}" \
        -in "filtered_func_data_${runname}" \
        -applyxfm \
        -init "${inputdir}/EPI2downsampEPI.mat" \
        -out "lowres_filtered_func_data_${runname}"

    if [[ $? -ne 0 ]]; then
        echo "ERROR: EPI resampling failed"
        cd "$inputdir"
        rm -rf "$tdl"
        return 1
    fi


    # ========================================================
    # 4. Standardization
    # ========================================================

    local filtimg="lowres_filtered_func_data_${runname}"


    fslmaths \
        "$filtimg" \
        -Tmin \
        temp_Tmin.nii.gz


    fslmaths \
        "$filtimg" \
        -Tmax \
        temp_Tmax.nii.gz


    fslmaths \
        "$filtimg" \
        -sub temp_Tmin.nii.gz \
        temp_numerator.nii.gz


    fslmaths \
        temp_Tmax.nii.gz \
        -sub temp_Tmin.nii.gz \
        temp_denominator.nii.gz


    fslmaths \
        temp_numerator.nii.gz \
        -div temp_denominator.nii.gz \
        temp1_rescaling.nii.gz


    fslmaths \
        temp1_rescaling.nii.gz \
        -Tmean \
        temp_Tmean.nii.gz


    fslmaths \
        temp1_rescaling.nii.gz \
        -Tstd \
        temp_Tstd.nii.gz


    fslmaths \
        temp1_rescaling.nii.gz \
        -sub temp_Tmean.nii.gz \
        temp1_centering.nii.gz


    fslmaths \
        temp1_centering.nii.gz \
        -div temp_Tstd.nii.gz \
        "${epidir}/standard_${inputname}"


    if [[ $? -ne 0 ]]; then
        echo "ERROR: standardization failed"
        cd "$inputdir"
        rm -rf "$tdl"
        return 1
    fi


    # ========================================================
    # 5. Add Mean EPI back
    # ========================================================

    fslmaths \
        "${epidir}/standard_${inputname}" \
        -add "${inputdir}/${MEAN_NAME}" \
        "$outfile"


    if [[ $? -ne 0 ]]; then
        echo "ERROR: adding Mean EPI failed"
        cd "$inputdir"
        rm -rf "$tdl"
        return 1
    fi


    cd "$inputdir" || return 1

    rm -rf "$tdl"


    if [[ -f "$outfile" ]]; then

        echo "DONE pre-ICA: $runname"

        return 0

    else

        echo "ERROR pre-ICA: $runname" >&2

        return 1

    fi
}


# ============================================================
# Function: process ONE subject
#
# Processing order:
#
# 1. Check six runs
# 2. Create Mean EPI from all six runs
# 3. preICA run1 -> run6 sequentially
# 4. concatenate all six preICA runs
# 5. MELODIC -d 800
#
# Different subjects can run in parallel.
# ============================================================

process_subject() {

    local sub="$1"

    local subname
    subname=$(basename "$sub")

    local epidir="$sub/$EPI_DIR_NAME"


    echo
    echo "============================================================"
    echo "START SUBJECT: $subname"
    echo "============================================================"


    # ========================================================
    # Check epi directory
    # ========================================================

    if [[ ! -d "$epidir" ]]; then

        echo "ERROR [$subname]: epi directory not found:"
        echo "  $epidir"

        return 1

    fi


    # ========================================================
    # T1 image
    #
    # Use the anatomical image from FEAT.
    #
    # Same subject uses the same T1 across runs,
    # so run1.feat is used here.
    # ========================================================

    local t1image="$sub/run1.feat/reg/highres2standard.nii.gz"


    if [[ ! -f "$t1image" ]]; then

        echo "ERROR [$subname]: T1 image not found:"
        echo "  $t1image"

        return 1

    fi


    echo "T1:"
    echo "  $t1image"


    # ========================================================
    # Collect exactly six runs
    #
    # Explicit ordering:
    #
    # run1
    # run2
    # run3
    # run4
    # run5
    # run6
    # ========================================================

    local run_files=()

    local run
    local img


    for run in $(seq 1 "$NRUNS"); do

        img="$epidir/run${run}${RUN_SUFFIX}"


        if [[ ! -f "$img" ]]; then

            echo "ERROR [$subname]: missing run${run}:"
            echo "  $img"

            return 1

        fi


        run_files+=( "$img" )

    done


    # ========================================================
    # Check input volumes
    # ========================================================

    echo
    echo "Input runs:"


    local total_volumes=0
    local nvol


    for img in "${run_files[@]}"; do

        nvol=$(fslval "$img" dim4 | tr -d '[:space:]')

        echo "  $(basename "$img") : $nvol volumes"

        total_volumes=$((total_volumes + nvol))

    done


    echo "Total input volumes: $total_volumes"


    # Optional warning if expected 604 volumes/run
    for img in "${run_files[@]}"; do

        nvol=$(fslval "$img" dim4 | tr -d '[:space:]')

        if [[ "$nvol" -ne 604 ]]; then

            echo "WARNING [$subname]:"
            echo "  $(basename "$img") has $nvol volumes instead of 604"

        fi

    done


    # ========================================================
    # STEP 1
    #
    # Create Mean EPI using ALL six runs
    #
    # six runs
    #     |
    #     v
    # fslmerge -t
    #     |
    #     v
    # Tmean
    #     |
    #     v
    # subsamp2
    # ========================================================

    if [[ ! -f "$sub/$MEAN_NAME" ]]; then

        echo
        echo "[$subname] Creating Mean EPI..."


        fslmerge \
            -t \
            "$sub/temp_Tmean.nii.gz" \
            "${run_files[@]}"


        if [[ $? -ne 0 ]]; then

            echo "ERROR [$subname]: fslmerge for Mean failed"

            rm -f "$sub/temp_Tmean.nii.gz"

            return 1

        fi


        fslmaths \
            "$sub/temp_Tmean.nii.gz" \
            -Tmean \
            -subsamp2 \
            "$sub/$MEAN_NAME"


        if [[ $? -ne 0 ]]; then

            echo "ERROR [$subname]: Mean EPI creation failed"

            rm -f "$sub/temp_Tmean.nii.gz"

            return 1

        fi


        rm -f "$sub/temp_Tmean.nii.gz"


        echo "[$subname] Created Mean:"
        echo "  $sub/$MEAN_NAME"

    else

        echo
        echo "[$subname] Use existing Mean:"
        echo "  $sub/$MEAN_NAME"

    fi


    # ========================================================
    # STEP 2
    #
    # Pre-ICA processing
    #
    # IMPORTANT:
    #
    # Within each subject:
    #
    # run1 -> run2 -> ... -> run6
    #
    # sequentially.
    #
    # This avoids simultaneous writing of:
    #
    # T12epi.mat
    # EPI2downsampEPI.mat
    # T1fromEPI
    #
    # Different subjects have independent directories,
    # so subject-level parallelization is safe.
    # ========================================================

    echo
    echo "[$subname] Starting pre-ICA..."


    local outfile


    for run in $(seq 1 "$NRUNS"); do

        img="$epidir/run${run}${RUN_SUFFIX}"

        outfile="$epidir/preica_run${run}${RUN_SUFFIX}"


        if [[ -f "$outfile" ]]; then

            echo "[$subname] SKIP existing:"
            echo "  $outfile"

            continue

        fi


        if ! calc_preica "$sub" "$img" "$t1image"; then

            echo
            echo "ERROR [$subname]:"
            echo "pre-ICA failed at run${run}"

            return 1

        fi

    done


    # ========================================================
    # STEP 3
    #
    # Build preICA list explicitly
    #
    # This prevents old unrelated preica files
    # from accidentally entering the concatenation.
    # ========================================================

    local preica_files=()


    for run in $(seq 1 "$NRUNS"); do

        outfile="$epidir/preica_run${run}${RUN_SUFFIX}"


        if [[ ! -f "$outfile" ]]; then

            echo "ERROR [$subname]: missing preICA:"
            echo "  $outfile"

            return 1

        fi


        preica_files+=( "$outfile" )

    done


    # ========================================================
    # Check preICA volumes
    # ========================================================

    echo
    echo "[$subname] Pre-ICA files:"


    total_volumes=0


    for img in "${preica_files[@]}"; do

        nvol=$(fslval "$img" dim4 | tr -d '[:space:]')

        echo "  $(basename "$img") : $nvol volumes"

        total_volumes=$((total_volumes + nvol))

    done


    echo "[$subname] Total preICA volumes: $total_volumes"


    # ========================================================
    # STEP 4
    #
    # Temporal concatenate all six runs
    #
    # run1 | run2 | run3 | run4 | run5 | run6
    #                    |
    #                    v
    #              concat.nii.gz
    # ========================================================

    local concat="$epidir/concat.nii.gz"


    rm -f \
        "$epidir/concat.nii" \
        "$epidir/concat.nii.gz"


    echo
    echo "[$subname] Concatenating 6 pre-ICA runs..."


    fslmerge \
        -t \
        "$concat" \
        "${preica_files[@]}"


    if [[ $? -ne 0 || ! -f "$concat" ]]; then

        echo "ERROR [$subname]: concatenation failed"

        return 1

    fi


    local concat_volumes

    concat_volumes=$(fslval "$concat" dim4 | tr -d '[:space:]')


    echo
    echo "[$subname] Concat complete:"
    echo "  $concat"
    echo "  volumes = $concat_volumes"


    # Expected:
    #
    # 604 volumes x 6 runs = 3624 volumes

    if [[ "$concat_volumes" -ne 3624 ]]; then

        echo
        echo "WARNING [$subname]:"
        echo "Expected 3624 volumes (604 x 6)"
        echo "Actual   $concat_volumes volumes"

    fi


    # ========================================================
    # STEP 5
    #
    # MELODIC ICA
    #
    # Fixed dimensionality:
    #
    # -d 800
    #
    # One MELODIC decomposition per subject.
    # ========================================================

    local gica_dir="$sub/${subname}.gica"

    local bg_image="$sub/T1fromEPI"


    # --------------------------------------------------------
    # Existing ICA
    # --------------------------------------------------------

    if [[ -d "$gica_dir" ]]; then

        if (( FORCE_ICA == 1 )); then

            echo
            echo "[$subname] FORCE_ICA=1"
            echo "Removing existing ICA:"
            echo "  $gica_dir"

            rm -rf "$gica_dir"

        else

            echo
            echo "[$subname] SKIP existing ICA:"
            echo "  $gica_dir"

            echo
            echo "============================================================"
            echo "DONE SUBJECT: $subname"
            echo "============================================================"

            return 0

        fi

    fi


    # --------------------------------------------------------
    # Check background image
    # --------------------------------------------------------

    if [[ ! -f "${bg_image}.nii.gz" && ! -f "$bg_image" ]]; then

        echo "ERROR [$subname]: T1fromEPI not found:"
        echo "  $bg_image"

        return 1

    fi


    # --------------------------------------------------------
    # MELODIC
    # --------------------------------------------------------

    echo
    echo "[$subname] Running MELODIC..."
    echo
    echo "Input:"
    echo "  $concat"
    echo
    echo "Output:"
    echo "  $gica_dir"
    echo
    echo "ICA dimensionality:"
    echo "  800"


    melodic \
        -i "$concat" \
        -o "$gica_dir" \
        --Oall \
        -v \
        --report \
        --tr="$TR" \
        --mmthresh=0.5 \
        --vn \
        --nobet \
        --bgthreshold=10 \
        --bgimage="$bg_image" \
        -d 800 \
        --guireport="$gica_dir/report.html"


    if [[ $? -ne 0 ]]; then

        echo
        echo "ERROR [$subname]: MELODIC returned an error"

        return 1

    fi


    if [[ ! -d "$gica_dir" ]]; then

        echo
        echo "ERROR [$subname]: MELODIC output directory not found"

        return 1

    fi


    echo
    echo "============================================================"
    echo "DONE SUBJECT: $subname"
    echo "ICA dimensionality: 800"
    echo "Input volumes: $concat_volumes"
    echo "============================================================"


    return 0
}


# ============================================================
# Subject directories
# ============================================================

subdirs=( "$root_dir"/$SUBJ_GLOB )


# ============================================================
# Main
#
# Parallelization strategy:
#
# Subject level:
#     maximum 5 subjects simultaneously
#
# Within each subject:
#     run1-run6 sequential
#
# Each subject:
#
# run1_norm
#     |
# run2_norm
#     |
# run3_norm
#     |
# run4_norm
#     |
# run5_norm
#     |
# run6_norm
#     |
#     v
# preICA
#     |
#     v
# concatenate
#     |
#     v
# 3624 volumes
#     |
#     v
# MELODIC -d 800
# ============================================================

echo
echo "============================================================"
echo "MULTI-RUN ICA PIPELINE"
echo "============================================================"
echo
echo "Root directory       : $root_dir"
echo "Subjects             : $SUBJ_GLOB"
echo "Runs / subject       : $NRUNS"
echo "Concurrent subjects  : $CONCURRENT_SUBJECTS"
echo "TR                    : $TR"
echo "ICA dimensionality    : 800"
echo


for sub in "${subdirs[@]}"; do

    [[ -d "$sub" ]] || continue


    # --------------------------------------------------------
    # Maximum five subjects simultaneously
    # --------------------------------------------------------

    while (( $(jobs -rp | wc -l) >= CONCURRENT_SUBJECTS )); do

        wait -n 2>/dev/null || sleep 1

    done


    # Entire subject pipeline runs as one background job
    process_subject "$sub" &

done


# Wait for final subjects
wait


echo
echo "============================================================"
echo "ALL SUBJECTS FINISHED"
echo "============================================================"