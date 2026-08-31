#!/usr/bin/env bash

# Run first-level FEAT analyses for every H00* subject.
#
# For each subject:
#   1. Check all 6 functional runs and T1w
#   2. Create T1w_brain if necessary
#   3. Generate six subject-specific FSF files
#   4. Run run1-run6 FEAT IN PARALLEL
#   5. Wait until all 6 runs finish
#   6. Continue to the next subject

set -uo pipefail

# ============================================================
# Paths
# ============================================================

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

analyze_dir="${ANALYZE_DIR:-${script_dir}/Analysis_FSL}"
design_dir="${DESIGN_DIR:-${script_dir}}"

subject_placeholder="__SUBJECT_DIR__"


# ============================================================
# Check commands
# ============================================================

for command_name in bet2 feat; do

    if ! command -v "${command_name}" >/dev/null 2>&1; then
        echo "ERROR: ${command_name} was not found."
        echo "Run this script in an FSL environment." >&2
        exit 1
    fi

done


# ============================================================
# Check analysis directory
# ============================================================

if [[ ! -d "${analyze_dir}" ]]; then
    echo "ERROR: Analysis directory not found:"
    echo "  ${analyze_dir}" >&2
    exit 1
fi


# ============================================================
# Check FSF templates
# ============================================================

for run in {1..6}; do

    if [[ ! -f "${design_dir}/design_run${run}.fsf" ]]; then
        echo "ERROR: Design template not found:"
        echo "  ${design_dir}/design_run${run}.fsf" >&2
        exit 1
    fi

done


# ============================================================
# Subject list
# ============================================================

shopt -s nullglob

subjects=("${analyze_dir}"/H00*)


if (( ${#subjects[@]} == 0 )); then

    echo "ERROR: No H00* subject directories found in:"
    echo "  ${analyze_dir}" >&2

    exit 1

fi


# ============================================================
# Main loop
# ============================================================

overall_status=0


for subdir in "${subjects[@]}"; do

    [[ -d "${subdir}" ]] || continue


    subname="$(basename -- "${subdir}")"


    echo
    echo "============================================================"
    echo "Subject: ${subname}"
    echo "============================================================"


    # ========================================================
    # Check inputs
    # ========================================================

    subject_ready=1


    # --------------------------------------------------------
    # Functional runs
    # --------------------------------------------------------

    for run in {1..6}; do

        epi_base="${subdir}/run${run}/epi_desp_topup.nii"

        if [[ ! -f "${epi_base}" && ! -f "${epi_base}.gz" ]]; then

            echo "ERROR: Functional image not found:"
            echo "  ${epi_base}[.gz]" >&2

            subject_ready=0

        fi

    done


    # --------------------------------------------------------
    # Structural image
    # --------------------------------------------------------

    t1_nii="${subdir}/T1w/T1w.nii"


    if [[ -f "${t1_nii}.gz" ]]; then

        t1_input="${t1_nii}.gz"

    elif [[ -f "${t1_nii}" ]]; then

        t1_input="${t1_nii}"

    else

        echo "ERROR: Structural image not found:"
        echo "  ${t1_nii}[.gz]" >&2

        subject_ready=0

    fi


    # --------------------------------------------------------
    # Skip subject if input is incomplete
    # --------------------------------------------------------

    if (( subject_ready == 0 )); then

        echo "===> SKIP ${subname}: required input missing" >&2

        overall_status=1

        continue

    fi


    # ========================================================
    # BET structural image
    # ========================================================

    brain_stem="${subdir}/T1w/T1w_brain"


    if [[ ! -f "${brain_stem}.nii" &&
          ! -f "${brain_stem}.nii.gz" ]]; then

        echo
        echo "===> Creating skull-stripped T1w"
        echo "     BET threshold = 0.2"


        if ! bet2 \
            "${t1_input}" \
            "${brain_stem}" \
            -f 0.2
        then

            echo "ERROR: BET failed for ${subname}" >&2

            overall_status=1

            continue

        fi

    else

        echo
        echo "===> Existing T1w_brain found"

    fi


    # ========================================================
    # Generate subject-specific FSF files
    # ========================================================

    echo
    echo "===> Creating FSF files"


    escaped_subdir="${subdir//&/\\&}"


    for run in {1..6}; do

        subject_design="${subdir}/design_run${run}.fsf"


        cp -- \
            "${design_dir}/design_run${run}.fsf" \
            "${subject_design}"


        sed -i \
            "s|${subject_placeholder}|${escaped_subdir}|g" \
            "${subject_design}"


        echo "     run${run}: ${subject_design}"

    done


    # ========================================================
    # Run all 6 FEAT analyses IN PARALLEL
    # ========================================================

    echo
    echo "============================================================"
    echo "Starting 6 FEAT runs in parallel: ${subname}"
    echo "============================================================"


    pids=()
    runs=()


    for run in {1..6}; do

        echo "===> START ${subname} run${run}"


        feat "${subdir}/design_run${run}.fsf" \
            > "${subdir}/feat_run${run}.log" \
            2>&1 &


        pids+=( "$!" )
        runs+=( "${run}" )

    done


    # ========================================================
    # Wait for all 6 runs
    # ========================================================

    subject_status=0


    echo
    echo "===> All 6 runs submitted"
    echo "===> Waiting for completion..."
    echo


    for idx in "${!pids[@]}"; do

        pid="${pids[$idx]}"
        run="${runs[$idx]}"


        if wait "${pid}"; then

            echo "===> DONE   ${subname} run${run}"

        else

            status=$?

            echo "ERROR: FEAT failed:"
            echo "       subject = ${subname}"
            echo "       run     = run${run}"
            echo "       status  = ${status}"
            echo "       log     = ${subdir}/feat_run${run}.log" >&2

            subject_status=1
            overall_status=1

        fi

    done


    # ========================================================
    # Subject summary
    # ========================================================

    echo

    if (( subject_status == 0 )); then

        echo "============================================================"
        echo "ALL 6 RUNS FINISHED: ${subname}"
        echo "============================================================"

    else

        echo "============================================================"
        echo "SOME RUNS FAILED: ${subname}"
        echo "Check:"
        echo "  ${subdir}/feat_run*.log"
        echo "============================================================"

    fi

done


# ============================================================
# Final summary
# ============================================================

echo
echo "============================================================"

if (( overall_status == 0 )); then

    echo "ALL SUBJECTS FINISHED SUCCESSFULLY"

else

    echo "PROCESSING FINISHED WITH ERRORS"

fi

echo "============================================================"


exit "${overall_status}"