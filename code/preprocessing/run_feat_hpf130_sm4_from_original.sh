#!/bin/bash

# Apply ONLY:
#   - FEAT/SUSAN spatial smoothing: 4 mm FWHM
#   - FEAT high-pass temporal filtering: 130 s
#
# Input:
#   post_run1_norm.nii.gz ... post_run6_norm.nii.gz
#
# Root:
#   /mnt/d/imagetransfer2026/Analysis_FSL/finished/icafinished/H00xxx/epi
#
# Usage:
#   bash run_feat_hpf130_sm4_from_original.sh
#   bash run_feat_hpf130_sm4_from_original.sh H00863NS
#
# Rerun existing outputs:
#   FORCE=1 bash run_feat_hpf130_sm4_from_original.sh H00863NS

set -u
set -o pipefail

ROOT_DIR="/mnt/e/2026languageRSA/icafinished"
FSLDIR="${FSLDIR:-/home/sylsherry/fsl}"
EXPECTED_RUNS=6
EXPECTED_NPTS=604
FORCE="${FORCE:-0}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
FSF_TEMPLATE="$SCRIPT_DIR/feat_hpf130_sm4_from_original.fsf"

if [[ -f "$FSLDIR/etc/fslconf/fsl.sh" ]]; then
    source "$FSLDIR/etc/fslconf/fsl.sh"
fi

export FSLDIR
export PATH="$FSLDIR/bin:$PATH"

for cmd in feat fslval; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: $cmd not found. FSLDIR=$FSLDIR"
        exit 1
    fi
done

if [[ ! -f "$FSF_TEMPLATE" ]]; then
    echo "ERROR: FSF template missing:"
    echo "$FSF_TEMPLATE"
    exit 1
fi

subjects=()

if [[ $# -gt 0 ]]; then
    for subname in "$@"; do
        sub="$ROOT_DIR/$subname"
        if [[ ! -d "$sub" ]]; then
            echo "ERROR: subject directory not found:"
            echo "$sub"
            exit 1
        fi
        subjects+=("$sub")
    done
else
    shopt -s nullglob
    subjects=("$ROOT_DIR"/MRI19vb)
    shopt -u nullglob
fi

if (( ${#subjects[@]} == 0 )); then
    echo "ERROR: no MRI* subjects found under:"
    echo "$ROOT_DIR"
    exit 1
fi

overall_failed=0

for sub in "${subjects[@]}"; do

    subname="$(basename "$sub")"
    epi="$sub/epi"

    echo
    echo "============================================================"
    echo "SUBJECT: $subname"
    echo "============================================================"

    if [[ ! -d "$epi" ]]; then
        echo "ERROR: epi directory missing: $epi"
        overall_failed=1
        continue
    fi

    work_dir="$epi/feat_hpf130_sm4"
    fsf_dir="$work_dir/fsf"
    mkdir -p "$fsf_dir"

    subject_failed=0

    for run in $(seq 1 "$EXPECTED_RUNS"); do

        input="$epi/post_run${run}_norm.nii.gz"
        output_feat="$work_dir/post_run${run}_norm_hpf130_sm4.feat"
        run_fsf="$fsf_dir/post_run${run}_norm_hpf130_sm4.fsf"

        echo
        echo "------------------------------------------------------------"
        echo "$subname / run${run}"
        echo "Input : $input"
        echo "Output: $output_feat"
        echo "------------------------------------------------------------"

        if [[ ! -f "$input" ]]; then
            echo "ERROR: input missing"
            subject_failed=1
            continue
        fi

        npts="$(fslval "$input" dim4 2>/dev/null || echo 0)"
        tr="$(fslval "$input" pixdim4 2>/dev/null || echo 0)"
        dim1="$(fslval "$input" dim1 2>/dev/null || echo 0)"
        dim2="$(fslval "$input" dim2 2>/dev/null || echo 0)"
        dim3="$(fslval "$input" dim3 2>/dev/null || echo 0)"

        if [[ "$npts" -ne "$EXPECTED_NPTS" ]]; then
            echo "ERROR: dim4=$npts; expected $EXPECTED_NPTS"
            subject_failed=1
            continue
        fi

        if awk -v tr="$tr" 'BEGIN {exit !(tr > 0)}'; then
            :
        else
            echo "ERROR: invalid TR=$tr"
            subject_failed=1
            continue
        fi

        total_voxels=$((dim1 * dim2 * dim3 * npts))

        echo "TR        : $tr s"
        echo "Volumes   : $npts"
        echo "HPF       : 130 s"
        echo "Smoothing : 4 mm FWHM"

        if [[ -d "$output_feat" ]]; then

            if [[ "$FORCE" == "1" ]]; then
                echo "FORCE=1: deleting existing output"
                rm -rf "$output_feat"

            elif [[ -f "$output_feat/filtered_func_data.nii.gz" ]]; then

                out_npts="$(fslval "$output_feat/filtered_func_data.nii.gz" dim4 2>/dev/null || echo 0)"

                if [[ "$out_npts" -eq "$EXPECTED_NPTS" ]]; then
                    echo "Already complete; skipping."
                    continue
                fi

                echo "ERROR: existing filtered_func_data dim4=$out_npts"
                echo "Use FORCE=1 to rebuild."
                subject_failed=1
                continue

            else
                echo "ERROR: incomplete .feat directory exists"
                echo "Use FORCE=1 to rebuild."
                subject_failed=1
                continue
            fi
        fi

        sed \
            -e "s|__SUBJECT_DIR__|$sub|g" \
            -e "s|__INPUT__|$input|g" \
            -e "s|__OUTPUTDIR__|$output_feat|g" \
            -e "s|__TR__|$tr|g" \
            -e "s|__NPTS__|$npts|g" \
            -e "s|__TOTALVOXELS__|$total_voxels|g" \
            "$FSF_TEMPLATE" > "$run_fsf"

        if grep -q '__[A-Z][A-Z_]*__' "$run_fsf"; then
            echo "ERROR: unreplaced placeholder remains:"
            grep '__[A-Z][A-Z_]*__' "$run_fsf"
            subject_failed=1
            continue
        fi

        echo "Running FEAT..."

        if ! feat "$run_fsf"; then
            echo "ERROR: FEAT failed"
            subject_failed=1
            continue
        fi

        filtered="$output_feat/filtered_func_data.nii.gz"

        if [[ ! -f "$filtered" ]]; then
            echo "ERROR: filtered_func_data.nii.gz missing"
            subject_failed=1
            continue
        fi

        out_npts="$(fslval "$filtered" dim4 2>/dev/null || echo 0)"

        if [[ "$out_npts" -ne "$EXPECTED_NPTS" ]]; then
            echo "ERROR: output dim4=$out_npts; expected $EXPECTED_NPTS"
            subject_failed=1
            continue
        fi

        echo "SUCCESS:"
        echo "$filtered"
    done

    if [[ "$subject_failed" -eq 0 ]]; then
        echo
        echo "SUBJECT COMPLETE: $subname"
    else
        echo
        echo "SUBJECT HAS FAILURES: $subname"
        overall_failed=1
    fi
done

exit "$overall_failed"
