#!/bin/bash
# DICOM-to-NIfTI conversion and fieldmap pairing
# Changes: (1) exclude SBRef, (2) sort numerically by series number, and
#          (3) automatically pair each run with the immediately preceding fieldmap set.
#          (4) Skip a subject when its output folder already exists (SKIP_EXISTING).

set -u

DCMdir=${DCMdir:-/mnt/d/imagetransfer2026}
analyze_dir=${analyze_dir:-/mnt/d/imagetransfer2026/Analysis_FSL}


SUBJ_GLOB=${SUBJ_GLOB:-'*'}          # Pattern for subject folders directly under DCMdir
SERIES_MAX_DEPTH=${SERIES_MAX_DEPTH:-3}   # Maximum depth for locating series folders below a subject folder
STRIP_SPACES=${STRIP_SPACES:-0}      # If 1, remove spaces from series folder names (renames source data)

FUNC_INC='^taskfMRI'                 # Prefix of functional-image folder names
FUNC_EXC='SBRef'                     # Exclusion term
T1_INC='^T1w'
FMAP_AP_INC='^SEFieldMap_AP'
FMAP_PA_INC='^SEFieldMap_PA'
SERIES_RE='-[[:space:]]*([0-9]+)$'   # Trailing series number (allows spaces)

CONVERT_SBREF=${CONVERT_SBREF:-0}    # If 1, also create run*/sbref.nii.gz
FMAP_MODE=${FMAP_MODE:-symlink}      # symlink | copy
SKIP_EXISTING=${SKIP_EXISTING:-1}    # 1 skips subjects with output; 0 overwrites as before
SKIP_CHECK=${SKIP_CHECK:-dir}        # dir = determine completion from the subject folder
                                     # mapping = determine completion from run_fmap_mapping.tsv (resume interrupted work)
EXTRA_DIRS=(FFA1 FFA2 IMG1 IMG2)

mkdir -p "$analyze_dir"

# ---------- helper ----------

# "Anonymized - H00648KY" -> H00648KY; otherwise replace spaces in folder names with underscores
subj_id_of() {
    local b id
    b=$(basename "$1")
    if [[ "$b" =~ ^[Aa]nonymized[[:space:]]*-[[:space:]]*(.+)$ ]]; then
        id=${BASH_REMATCH[1]}
    else
        id=$b
    fi
    id=${id// /_}
    printf '%s' "$id"
}

# $1=subject ID -> return 0 if output exists, or 1 if unprocessed
# Check both the single-session name "<id>" and multi-session names "<id>_sesN"
subject_done() {
    local id="$1" cand=() c
    shopt -s nullglob
    if [[ "$SKIP_CHECK" == mapping ]]; then
        cand=( "$analyze_dir/$id/run_fmap_mapping.tsv" \
               "$analyze_dir/${id}_ses"*/run_fmap_mapping.tsv )
        shopt -u nullglob
        for c in "${cand[@]}"; do [[ -f "$c" ]] && return 0; done
    else
        cand=( "$analyze_dir/$id" "$analyze_dir/${id}_ses"* )
        shopt -u nullglob
        for c in "${cand[@]}"; do [[ -d "$c" ]] && return 0; done
    fi
    return 1
}

# Return whether $1 directly contains a functional-image folder
has_func_child() {
    local d="$1" c b
    for c in "$d"/*; do
        [[ -d "$c" ]] || continue
        b=$(basename "$c")
        if [[ "$b" =~ $FUNC_INC && "$b" =~ $SERIES_RE ]]; then
            if [[ "$b" =~ $FUNC_EXC ]]; then continue; fi
            return 0
        fi
    done
    return 1
}

# List directories below the subject root that directly contain series folders (= session directories)
find_session_dirs() {
    local root="$1" d
    while IFS= read -r d; do
        has_func_child "$d" && printf '%s\n' "$d"
    done < <(find "$root" -mindepth 0 -maxdepth "$SERIES_MAX_DEPTH" -type d | sort)
}

# Remove spaces from series folder names (only when STRIP_SPACES=1)
strip_spaces() {
    local d base new
    while IFS= read -r d; do
        base=$(basename "$d")
        new=$(dirname "$d")/${base// /}
        [[ "$d" == "$new" ]] && continue
        if [[ -e "$new" ]]; then
            echo "WARNING: rename skipped (exists): $new" >&2
        else
            mv "$d" "$new"
        fi
    done < <(find "$1" -mindepth 1 -maxdepth 1 -type d -name '* *' | sort)
}

# $1=parent dir, $2=inclusion regex, $3=optional exclusion regex -> output "series<TAB>path" in numeric order
list_series() {
    local parent="$1" inc="$2" exc="${3:-}" d base
    for d in "$parent"/*; do
        [[ -d "$d" ]] || continue
        base=$(basename "$d")
        [[ "$base" =~ $inc ]] || continue
        if [[ -n "$exc" && "$base" =~ $exc ]]; then continue; fi
        if [[ "$base" =~ $SERIES_RE ]]; then
            printf '%s\t%s\n' "${BASH_REMATCH[1]}" "$d"
        else
            echo "WARNING: no series number, skipped: $base" >&2
        fi
    done | sort -n -k1,1
}

ser() { printf '%s' "${1%%$'\t'*}"; }
pth() { printf '%s' "${1#*$'\t'}"; }

# $1=DICOM folder, $2=output file (.nii.gz)
convert_dicom_dir() {
    local src="$1" dst="$2" tmp nii n
    tmp=$(mktemp -d)
    dcm2niix -b n -v n -z y -f out -o "$tmp" "$src" >/dev/null 2>&1
    mapfile -t nii < <(find "$tmp" -maxdepth 1 -name '*.nii.gz' | sort)
    n=${#nii[@]}
    if (( n == 0 )); then
        echo "ERROR: conversion failed: $src" >&2
        rm -rf "$tmp"; return 1
    fi
    if (( n > 1 )); then
        echo "WARNING: $n outputs from $src -> largest kept" >&2
        mapfile -t nii < <(ls -S "${nii[@]}")
    fi
    mkdir -p "$(dirname "$dst")"
    mv -f "${nii[0]}" "$dst"
    rm -rf "$tmp"
    echo "  -> $dst"
}

# $1=run directory, $2=one-based fmap set number; references $subdir
attach_fmap() {
    local rundir="$1" idx="$2" ax src
    for ax in AP PA; do
        src="$subdir/fmap/SEFieldMap_${ax}${idx}.nii.gz"
        [[ -f "$src" ]] || { echo "WARNING: missing $src" >&2; continue; }
        if [[ "$FMAP_MODE" == copy ]]; then
            cp -f "$src" "$rundir/fmap_${ax}.nii.gz"
        else
            ln -sfn "../fmap/SEFieldMap_${ax}${idx}.nii.gz" "$rundir/fmap_${ax}.nii.gz"
        fi
    done
}

# $1=target series, $2...="series<TAB>path" -> index of the immediately preceding element (largest value below target), or -1
pick_preceding() {
    local target="$1"; shift
    local i=0 sel=-1 item
    for item in "$@"; do
        (( $(ser "$item") < target )) && sel=$i
        i=$((i+1))
    done
    printf '%s' "$sel"
}

# ---------- Process one session ----------
# $1=DICOM session directory, $2=output subject directory
process_session() {
    local src="$1"
    subdir="$2"

    mkdir -p "$subdir/T1w" "$subdir/fmap"
    local e; for e in "${EXTRA_DIRS[@]}"; do mkdir -p "$subdir/$e"; done
    (( STRIP_SPACES == 1 )) && strip_spaces "$src"

    # ---- fieldmap: pair AP/PA images in index order ----
    local ap_list pa_list n_ap n_pa n_set j ap_s ap_p pa_s pa_p s
    mapfile -t ap_list < <(list_series "$src" "$FMAP_AP_INC")
    mapfile -t pa_list < <(list_series "$src" "$FMAP_PA_INC")
    n_ap=${#ap_list[@]}; n_pa=${#pa_list[@]}
    n_set=$(( n_ap < n_pa ? n_ap : n_pa ))
    (( n_ap != n_pa )) && echo "WARNING: AP=$n_ap PA=$n_pa mismatch -> using only $n_set sets" >&2

    local set_series=()
    for ((j=0; j<n_set; j++)); do
        ap_s=$(ser "${ap_list[j]}"); ap_p=$(pth "${ap_list[j]}")
        pa_s=$(ser "${pa_list[j]}"); pa_p=$(pth "${pa_list[j]}")
        echo "--- fmap set $((j+1)): AP series $ap_s / PA series $pa_s"
        convert_dicom_dir "$ap_p" "$subdir/fmap/SEFieldMap_AP$((j+1)).nii.gz"
        convert_dicom_dir "$pa_p" "$subdir/fmap/SEFieldMap_PA$((j+1)).nii.gz"
        s=$(( ap_s < pa_s ? ap_s : pa_s ))
        set_series+=("${s}"$'\t'"set$((j+1))")
    done

    # ---- T1w ----
    local t1_list
    mapfile -t t1_list < <(list_series "$src" "$T1_INC")
    if (( ${#t1_list[@]} == 0 )); then
        echo "WARNING: no T1w image: $src" >&2
    else
        (( ${#t1_list[@]} > 1 )) && echo "WARNING: found ${#t1_list[@]} T1w images -> using the lowest series number" >&2
        echo "--- T1w: series $(ser "${t1_list[0]}")"
        convert_dicom_dir "$(pth "${t1_list[0]}")" "$subdir/T1w/T1w.nii.gz"
    fi

    # ---- functional images (excluding SBRef) and fmap pairing ----
    local func_list sbref_list map count item f_s f_p rundir sb sel
    mapfile -t func_list < <(list_series "$src" "$FUNC_INC" "$FUNC_EXC")
    mapfile -t sbref_list < <(list_series "$src" "${FUNC_INC}.*${FUNC_EXC}")
    map="$subdir/run_fmap_mapping.tsv"
    printf 'run\tepi_series\tepi_dir\tfmap_set\n' > "$map"

    count=1
    for item in "${func_list[@]}"; do
        f_s=$(ser "$item"); f_p=$(pth "$item")
        rundir="$subdir/run${count}"
        mkdir -p "$rundir"
        echo "--- run${count}: series $f_s ($(basename "$f_p"))"
        convert_dicom_dir "$f_p" "$rundir/epi.nii.gz" || { count=$((count+1)); continue; }

        if (( CONVERT_SBREF == 1 && ${#sbref_list[@]} > 0 )); then
            sb=$(pick_preceding "$f_s" "${sbref_list[@]}")
            (( sb >= 0 )) && convert_dicom_dir "$(pth "${sbref_list[sb]}")" "$rundir/sbref.nii.gz"
        fi

        if (( n_set == 0 )); then
            echo "WARNING: no fieldmap -> run${count} remains unpaired" >&2
            printf 'run%s\t%s\t%s\tNONE\n' "$count" "$f_s" "$(basename "$f_p")" >> "$map"
        else
            sel=$(pick_preceding "$f_s" "${set_series[@]}")
            if (( sel < 0 )); then
                sel=0
                echo "WARNING: no fieldmap precedes run${count} (series $f_s) -> using set 1" >&2
            fi
            attach_fmap "$rundir" "$((sel+1))"
            printf 'run%s\t%s\t%s\t%s\n' "$count" "$f_s" "$(basename "$f_p")" "$((sel+1))" >> "$map"
        fi
        count=$((count+1))
    done

    echo "--- mapping: $map"
    cat "$map"
}

# ---------- main ----------

# Limit IFS to newlines while expanding SUBJ_GLOB so spaces do not trigger word splitting
PREV_IFS=$IFS
IFS=$'\n'
subj_roots=( "$DCMdir"/$SUBJ_GLOB )
IFS=$PREV_IFS

n_skipped=0
n_processed=0

for subj_root in "${subj_roots[@]}"; do
    [[ -d "$subj_root" ]] || continue
    subj_id=$(subj_id_of "$subj_root")

    # ---- Skip the entire subject when output exists (do not scan DICOM files) ----
    if (( SKIP_EXISTING == 1 )) && subject_done "$subj_id"; then
        echo "SKIP (output exists): $subj_id" >&2
        n_skipped=$((n_skipped+1))
        continue
    fi

    mapfile -t sess < <(find_session_dirs "$subj_root")
    n_sess=${#sess[@]}
    if (( n_sess == 0 )); then
        echo "SKIP (no functional series): $subj_root" >&2
        continue
    fi
    (( n_sess > 1 )) && echo "WARNING: found $n_sess candidate sessions for $subj_id -> splitting as _ses1.._ses$n_sess" >&2

    for ((k=0; k<n_sess; k++)); do
        if (( n_sess == 1 )); then
            subname=$subj_id
        else
            subname="${subj_id}_ses$((k+1))"
        fi
        echo "=============== $subname"
        echo "  src: ${sess[k]}"
        process_session "${sess[k]}" "$analyze_dir/$subname"
    done
    n_processed=$((n_processed+1))
done

echo "=============== done: processed=$n_processed skipped=$n_skipped" >&2
