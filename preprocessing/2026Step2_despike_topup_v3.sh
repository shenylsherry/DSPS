#!/bin/bash
# Integrated preprocessing that runs despike followed by topup
#   epi.nii.gz --3dDespike--> epi_desp.nii.gz --applytopup--> epi_desp_topup.nii.gz
# Because topup field estimation depends only on the fieldmaps, reuse existing results;
# otherwise compute and cache the result once per fieldmap set.

set -u

root_dir=${root_dir:-/mnt/d/imagetransfer2026/Analysis_FSL}
SUBJ_GLOB=${SUBJ_GLOB:-'*'}

IN_NAME=${IN_NAME:-epi.nii.gz}                    # Input (raw EPI before distortion correction)
DESP_NAME=${DESP_NAME:-epi_desp.nii.gz}           # Despike output
OUT_NAME=${OUT_NAME:-epi_desp_topup.nii.gz}       # Final output

TRT=${TRT:-0.0772471}          # Value measured from JSON metadata
FUNC_PE=${FUNC_PE:-PA}         # Phase-encoding direction of functional images (PA | AP)
CONCURRENT=${CONCURRENT:-8}
FORCE=${FORCE:-0}
CACHE_TOPUP=${CACHE_TOPUP:-1}  # 1: calculate topup only once per fieldmap set
NEW=${NEW:-1}                  # 3dDespike -NEW
IGNORE=${IGNORE:-0}            # 3dDespike -ignore N
DESP_OPTS=${DESP_OPTS:-}       # Example: '-nomask'
LOGDIR=${LOGDIR:-$root_dir/logs_desptopup}
LOCK_WAIT=${LOCK_WAIT:-3600}   # Maximum seconds to wait for topup on the same set

if (return 0 2>/dev/null); then
    echo "ERROR: run with 'bash $0'; do not source this script" >&2
    return 1
fi

fatal() { echo "ERROR: $*" >&2; echo "--- FSLDIR=${FSLDIR:-not_set} PATH=$PATH" >&2; exit 1; }

if [[ -z ${FSLDIR:-} ]]; then
    for p in /usr/local/fsl /usr/share/fsl/6.0 /usr/share/fsl/5.0 "$HOME/fsl" /opt/fsl; do
        [[ -d "$p" ]] && { export FSLDIR="$p"; break; }
    done
fi
if [[ -z ${TOPUP_CFG:-} ]]; then
    for p in "${FSLDIR:-}/src/topup/flirtsch/b02b0.cnf" \
             "${FSLDIR:-}/etc/flirtsch/b02b0.cnf" \
             "${FSLDIR:-}/share/fsl/etc/flirtsch/b02b0.cnf"; do
        [[ -f "$p" ]] && { TOPUP_CFG="$p"; break; }
    done
fi

[[ -d "$root_dir" ]] || fatal "root_dir does not exist: $root_dir"
[[ -n ${TOPUP_CFG:-} && -f "$TOPUP_CFG" ]] || fatal "b02b0.cnf was not found"
for c in 3dDespike fslmerge fslval topup applytopup; do
    command -v "$c" >/dev/null || fatal "$c is not in PATH"
done

mkdir -p "$LOGDIR"

desp_opts=()
(( NEW ))        && desp_opts+=(-NEW)
(( IGNORE > 0 )) && desp_opts+=(-ignore "$IGNORE")
(( FORCE ))      && desp_opts+=(-overwrite)
# shellcheck disable=SC2206
[[ -n "$DESP_OPTS" ]] && desp_opts+=($DESP_OPTS)

# ---------- helper ----------

resolve_fmap() {   # $1=run dir $2=AP|PA
    local d="$1" ax="$2" f
    [[ -f "$d/fmap_${ax}.nii.gz" ]] && { printf '%s' "$d/fmap_${ax}.nii.gz"; return 0; }
    for f in "$d"/SEFieldMap_${ax}*.nii.gz; do
        [[ -f "$f" ]] && { printf '%s' "$f"; return 0; }
    done
    return 1
}

# Obtain the fieldmap set number from the symlink target; return empty if unavailable
fmap_set_of() {
    local d="$1" t
    t=$(basename "$(readlink -f "$d/fmap_PA.nii.gz" 2>/dev/null)" 2>/dev/null)
    t=${t//[!0-9]/}
    printf '%s' "$t"
}

make_acqparams() {  # $1=output file, $2=PA, $3=AP -> return inindex
    local out="$1" pa="$2" ap="$3" npa nap v
    npa=$(fslval "$pa" dim4 | tr -d '[:space:]')
    nap=$(fslval "$ap" dim4 | tr -d '[:space:]')
    [[ "$npa" =~ ^[0-9]+$ && "$nap" =~ ^[0-9]+$ ]] || return 1
    (( npa > 0 && nap > 0 )) || return 1
    : > "$out"
    for ((v=0; v<npa; v++)); do printf '0 1 0 %s\n'  "$TRT" >> "$out"; done
    for ((v=0; v<nap; v++)); do printf '0 -1 0 %s\n' "$TRT" >> "$out"; done
    if [[ "$FUNC_PE" == PA ]]; then printf '%s' 1; else printf '%s' $((npa+1)); fi
}

# $1=topup base, $2=PA, $3=AP, $4=acqparams -> ensure the field exists and return 0
ensure_topup() {
    local base="$1" pa="$2" ap="$3" acq="$4" lock="${base}.lock" i
    [[ -f "${base}_fieldcoef.nii.gz" && -f "${base}_movpar.txt" ]] && return 0

    if mkdir "$lock" 2>/dev/null; then
        trap "rmdir '$lock' 2>/dev/null" RETURN
        fslmerge -t "${base}_PAAP.nii.gz" "$pa" "$ap" || return 1
        topup --imain="${base}_PAAP.nii.gz" --datain="$acq" \
              --config="$TOPUP_CFG" --out="$base" --iout="${base}_iout" || return 1
        return 0
    fi

    # Another process is computing the same set; wait for completion
    for ((i=0; i<LOCK_WAIT/10; i++)); do
        [[ -f "${base}_fieldcoef.nii.gz" && -f "${base}_movpar.txt" ]] && return 0
        [[ -d "$lock" ]] || break
        sleep 10
    done
    [[ -f "${base}_fieldcoef.nii.gz" && -f "${base}_movpar.txt" ]]
}

process_run() {
    local d="$1" subj tag log pa ap idx base setno
    subj=$(basename "$(dirname "$d")")
    tag="${subj}_$(basename "$d")"
    log="$LOGDIR/${tag}.log"

    if (( FORCE == 0 )) && [[ -f "$d/$OUT_NAME" ]]; then
        echo "SKIP (done): $tag"; return 0
    fi

    pa=$(resolve_fmap "$d" PA) || { echo "ERROR: no PA fieldmap: $tag" >&2; return 1; }
    ap=$(resolve_fmap "$d" AP) || { echo "ERROR: no AP fieldmap: $tag" >&2; return 1; }

    idx=$(make_acqparams "$d/acqparams.txt" "$pa" "$ap") \
        || { echo "ERROR: failed to generate acqparams: $tag" >&2; return 1; }

    # Select the topup base: existing run result > set cache > new calculation within the run
    setno=$(fmap_set_of "$d")
    if [[ -f "$d/topup_AP_PA_epi_fieldcoef.nii.gz" ]]; then
        base="$d/topup_AP_PA_epi"                       # Reuse the result of a previous run
    elif (( CACHE_TOPUP )) && [[ -n "$setno" ]]; then
        base="$(dirname "$d")/fmap/topup_set${setno}"
    else
        base="$d/topup_AP_PA_epi"
    fi

    echo "RUN: $tag (set=${setno:-?} topup=$(basename "$base"))"
    {
        echo "### $tag  $(date)"
        echo "in      : $d/$IN_NAME"
        echo "despike : $d/$DESP_NAME"
        echo "topup   : $base"
        echo "out     : $d/$OUT_NAME"
        echo "inindex : $idx"
        cat "$d/acqparams.txt"

        # --- 1. Despike (before distortion correction) ---
        if (( FORCE == 1 )) || [[ ! -f "$d/$DESP_NAME" ]]; then
            3dDespike "${desp_opts[@]}" -prefix "$d/$DESP_NAME" "$d/$IN_NAME" || exit 1
        else
            echo "-- despike: using existing output"
        fi

        # --- 2. Topup (the field depends only on the fieldmaps) ---
        ensure_topup "$base" "$pa" "$ap" "$d/acqparams.txt" || exit 1

        # --- 3. applytopup ---
        applytopup --imain="$d/$DESP_NAME" --topup="$base" --method=jac \
                   --datain="$d/acqparams.txt" --inindex="$idx" \
                   --out="${d}/${OUT_NAME%.nii.gz}" || exit 1

        echo "### DONE $(date)"
    } >> "$log" 2>&1 || { echo "ERROR: $tag failed -> $log" >&2; return 1; }
    return 0
}

# ---------- List target runs ----------
PREV_IFS=$IFS
IFS=$'\n'
subj_dirs=( "$root_dir"/$SUBJ_GLOB )
IFS=$PREV_IFS

run_dirs=()
for s in "${subj_dirs[@]}"; do
    [[ -d "$s" ]] || continue
    case "$(basename "$s")" in logs|logs_*|fmap) continue;; esac
    found=0
    for d in "$s"/*; do
        [[ -d "$d" && -f "$d/$IN_NAME" ]] || continue
        run_dirs+=("$d"); found=$((found+1))
    done
    (( found == 0 )) && echo "SKIP (no $IN_NAME): $(basename "$s")" >&2 \
                     || echo "$(basename "$s"): $found runs"
done

n_total=${#run_dirs[@]}
echo "---------------------------------------------------------------"
echo "total runs: $n_total / concurrency: $CONCURRENT / cache_topup: $CACHE_TOPUP"
(( n_total == 0 )) && exit 0

for d in "${run_dirs[@]}"; do
    while (( $(jobs -rp | wc -l) >= CONCURRENT )); do
        wait -n 2>/dev/null || sleep 10
    done
    process_run "$d" &
done

wait
ok=0; for d in "${run_dirs[@]}"; do [[ -f "$d/$OUT_NAME" ]] && ok=$((ok+1)); done
echo "---------------------------------------------------------------"
echo "done: $ok / $n_total"
grep -L '### DONE' "$LOGDIR"/*.log 2>/dev/null | sed 's/^/INCOMPLETE: /'
