#!/bin/bash

root_dir=/mnt/d/imagetransfer2026/Analysis_FSL/finished
mvdir="$root_dir/icafinished"

# Each run contains exactly 604 volumes
vols_per_run=604

mkdir -p "$mvdir"


calc_fls_regflit() {

    local i
    local subname

    i=$(realpath "$1") || return 1
    subname=$(basename "$i")

    echo "======================================"
    echo "START: $subname"
    echo "======================================"


    # ==================================================
    # 0. Find run files and preica files
    # ==================================================

    local -a run_files
    local -a preica_files
    local f
    local dim4

    shopt -s nullglob

    run_files=("$i"/epi/run*.nii.gz)
    preica_files=("$i"/epi/preica*)

    shopt -u nullglob


    # ---------- check run files ----------

    if (( ${#run_files[@]} == 0 )); then
        echo "ERROR: no run*.nii.gz found in:"
        echo "$i/epi"
        return 1
    fi


    # ---------- check preica files ----------

    if (( ${#preica_files[@]} == 0 )); then
        echo "ERROR: no preica* files found in:"
        echo "$i/epi"
        return 1
    fi


    # Natural sorting:
    # run1, run2, run3 ... instead of run1, run10, run2
    mapfile -t run_files < <(
        printf '%s\n' "${run_files[@]}" | sort -V
    )

    mapfile -t preica_files < <(
        printf '%s\n' "${preica_files[@]}" | sort -V
    )


    # Each run must correspond to one preica* file
    if (( ${#run_files[@]} != ${#preica_files[@]} )); then

        echo "ERROR:"
        echo "number of run files    = ${#run_files[@]}"
        echo "number of preica files = ${#preica_files[@]}"
        echo "These should be identical."

        return 1
    fi


    local nruns=${#run_files[@]}
    local expected_vols=$((nruns * vols_per_run))


    echo "Runs          : $nruns"
    echo "Volumes/run   : $vols_per_run"
    echo "Expected total: $expected_vols"


    # ==================================================
    # Check every original run has 604 volumes
    # ==================================================

    for f in "${run_files[@]}"; do

        dim4=$(fslval "$f" dim4 2>/dev/null) || {

            echo "ERROR: cannot read dim4 from:"
            echo "$f"

            return 1
        }


        if [[ "$dim4" -ne "$vols_per_run" ]]; then

            echo "ERROR:"
            echo "$(basename "$f") has dim4=$dim4"
            echo "Expected dim4=$vols_per_run"

            return 1
        fi

    done



    # ==================================================
    # 1. Merge original runs
    # ==================================================

    local concat="$i/epi/concat_orires.nii.gz"


    # If the file already exists, verify it first
    if [[ -e "$concat" ]]; then

        dim4=$(fslval "$concat" dim4 2>/dev/null || echo 0)


        if [[ "$dim4" -ne "$expected_vols" ]]; then

            echo "Existing concat_orires has wrong dim4=$dim4"
            echo "Expected: $expected_vols"
            echo "Rebuilding concat_orires..."

            rm -f "$concat"

        else

            echo "Existing concat_orires is valid."

        fi
    fi


    # Create it if it does not exist
    if [[ ! -e "$concat" ]]; then

        echo "Merging original runs..."

        if ! fslmerge \
            -t \
            "$concat" \
            "${run_files[@]}"
        then

            echo "ERROR: fslmerge failed"

            rm -f "$concat"

            return 1
        fi
    fi


    # Verify it once more
    dim4=$(fslval "$concat" dim4 2>/dev/null || echo 0)


    if [[ "$dim4" -ne "$expected_vols" ]]; then

        echo "ERROR:"
        echo "concat_orires dim4=$dim4"
        echo "expected=$expected_vols"

        return 1
    fi



    # ==================================================
    # 2. Create Mean_orires
    # ==================================================

    local mean_file="$i/Mean_orires.nii.gz"


    if [[ ! -e "$mean_file" ]]; then

        echo "Creating Mean_orires..."


        if ! fslmaths \
            "$concat" \
            -Tmean \
            "$mean_file"
        then

            echo "ERROR: failed to create Mean_orires"

            rm -f "$mean_file"

            return 1
        fi

    else

        echo "Mean_orires already exists."

    fi



    # ==================================================
    # 3. ICA denoising with fsl_regfilt
    # ==================================================

    local mix_file="$i/$subname.gica/melodic_mix"
    local noise_file="$i/$subname.gica/hand_labels_noise.txt"
    local clean_file="$i/epi/concat_orires_clean.nii.gz"

    local noise_components
    local nvol
    local nmix


    # ---------- melodic_mix ----------

    if [[ ! -e "$mix_file" ]]; then

        echo "ERROR: melodic_mix not found:"
        echo "$mix_file"

        return 1
    fi


    # ---------- noise labels ----------

    if [[ ! -e "$noise_file" ]]; then

        echo "ERROR: hand_labels_noise.txt not found:"
        echo "$noise_file"

        return 1
    fi


    # ---------- check time points ----------

    nvol=$(fslval "$concat" dim4 2>/dev/null || echo 0)

    nmix=$(awk '
        NF {n++}
        END {print n+0}
    ' "$mix_file")


    echo "concat volumes   : $nvol"
    echo "melodic_mix rows : $nmix"


    if [[ "$nvol" -ne "$nmix" ]]; then

        echo "ERROR:"
        echo "concat_orires dim4 != melodic_mix rows"

        return 1
    fi



    # ---------- validate existing clean file ----------

    if [[ -e "$clean_file" ]]; then

        dim4=$(fslval "$clean_file" dim4 2>/dev/null || echo 0)


        if [[ "$dim4" -ne "$expected_vols" ]]; then

            echo "Existing concat_orires_clean has wrong dim4=$dim4"
            echo "Expected=$expected_vols"
            echo "Rebuilding clean file..."

            rm -f "$clean_file"

        else

            echo "Existing concat_orires_clean is valid."

        fi
    fi



    # ---------- run denoising ----------

    if [[ ! -e "$clean_file" ]]; then

        # Example:
        #
        # [1, 2, 4, 7]
        #
        # becomes:
        #
        # 1,2,4,7

        noise_components=$(
            tr -d '[][:space:]' < "$noise_file"
        )


        # Remove a possible trailing comma
        noise_components=${noise_components%,}


        if [[ -z "$noise_components" ]]; then

            echo "No noise components listed."
            echo "Copying original concat as clean data."


            if ! cp \
                -f \
                "$concat" \
                "$clean_file"
            then

                echo "ERROR: failed to create clean file"

                return 1
            fi

        else

            echo "Noise components:"
            echo "$noise_components"

            echo "Running fsl_regfilt..."


            if ! fsl_regfilt \
                -i "$concat" \
                -d "$mix_file" \
                -o "$clean_file" \
                -f "$noise_components"
            then

                echo "ERROR: fsl_regfilt failed"

                rm -f "$clean_file"

                return 1
            fi

        fi

    fi



    # ---------- validate clean output ----------

    dim4=$(fslval "$clean_file" dim4 2>/dev/null || echo 0)


    if [[ "$dim4" -ne "$expected_vols" ]]; then

        echo "ERROR:"
        echo "concat_orires_clean dim4=$dim4"
        echo "expected=$expected_vols"

        return 1
    fi


    echo "finishdenoise"



    # ==================================================
    # 4. Reconstruct individual runs
    #
    # Instead of:
    #
    # fslsplit
    # -> move 604 files
    # -> fslmerge
    #
    # directly extract each run using fslroi.
    # ==================================================

    local count=0
    local j
    local name
    local name2
    local post_file
    local start
    local post_dim4


    for j in "${preica_files[@]}"; do

        name=$(basename "$j")


        # --------------------------------------------------
        # Example:
        #
        # preica_run1_norm.nii.gz
        #
        # becomes:
        #
        # run1_norm
        #
        # Therefore output:
        #
        # post_run1_norm.nii.gz
        # --------------------------------------------------

        name2="${name%.nii.gz}"
        name2="${name2%.nii}"

        name2="${name2#preica_}"
        name2="${name2#preica}"


        if [[ -z "$name2" ]]; then

            echo "ERROR:"
            echo "could not derive output name from:"
            echo "$name"

            return 1
        fi


        post_file="$i/epi/post_$name2.nii.gz"


        # run1: 0
        # run2: 604
        # run3: 1208
        # ...
        start=$((count * vols_per_run))


        echo "--------------------------------------"

        echo "Run $((count + 1))/$nruns"

        echo "Reference:"
        echo "$name"

        echo "Output:"
        echo "$(basename "$post_file")"

        echo "Volumes:"
        echo "$start - $((start + vols_per_run - 1))"



        # ==================================================
        # Existing post file
        # ==================================================

        if [[ -e "$post_file" ]]; then

            post_dim4=$(
                fslval "$post_file" dim4 2>/dev/null || echo 0
            )


            if [[ "$post_dim4" -ne "$vols_per_run" ]]; then

                echo "Existing output has wrong dim4=$post_dim4"
                echo "Rebuilding..."

                rm -f "$post_file"

            else

                echo "Existing output is valid."

            fi
        fi



        # ==================================================
        # Extract this run
        # ==================================================

        if [[ ! -e "$post_file" ]]; then

            echo "Extracting run..."


            if ! fslroi \
                "$clean_file" \
                "$post_file" \
                "$start" \
                "$vols_per_run"
            then

                echo "ERROR:"
                echo "fslroi failed for $name2"

                rm -f "$post_file"

                return 1
            fi
        fi



        # ==================================================
        # Final validation of this run
        # ==================================================

        post_dim4=$(
            fslval "$post_file" dim4 2>/dev/null || echo 0
        )


        if [[ "$post_dim4" -ne "$vols_per_run" ]]; then

            echo "ERROR:"
            echo "$(basename "$post_file")"
            echo "has dim4=$post_dim4"
            echo "expected=$vols_per_run"

            return 1
        fi


        count=$((count + 1))

    done



    # ==================================================
    # 5. Final subject validation
    # ==================================================

    if [[ "$count" -ne "$nruns" ]]; then

        echo "ERROR:"
        echo "reconstructed $count runs"
        echo "expected $nruns runs"

        return 1
    fi



    echo "======================================"
    echo "FINISHED: $subname"
    echo "======================================"

    return 0
}



# ======================================================
# Main loop
# ======================================================

shopt -s nullglob

subjects=("$root_dir"/H00*)

shopt -u nullglob


if (( ${#subjects[@]} == 0 )); then

    echo "No H00* subject directories found under:"
    echo "$root_dir"

    exit 0
fi



for i in "${subjects[@]}"; do

    [[ -d "$i" ]] || continue


    if calc_fls_regflit "$i"; then

        echo
        echo "SUCCESS: $(basename "$i")"
        echo "Moving subject to:"
        echo "$mvdir"
        echo

        mv "$i" "$mvdir/"


    else

        echo
        echo "======================================"
        echo "FAILED: $(basename "$i")"
        echo "Subject was NOT moved."
        echo "======================================"
        echo

    fi

done
