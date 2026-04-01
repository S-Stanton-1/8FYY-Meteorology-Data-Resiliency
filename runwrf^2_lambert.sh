#!/usr/bin/env bash

# Script fails if an error is encountered
set -euo pipefail
set -E
trap 'rc=$?; echo "FATAL: exit=$rc at ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2; exit $rc' ERR

#SAVE CHECK

# Dependencies
export DIR="/content/wrf_dependencies"
export LD_LIBRARY_PATH="/content/wrf_dependencies/grib2/lib/"
export NETCDF=$DIR/netcdf
export PATH=$NETCDF/bin:$DIR/mpich/bin:${PATH}
export JASPERLIB=$DIR/grib2/lib
export JASPERINC=$DIR/grib2/include
export OMPI_ALLOW_RUN_AS_ROOT=1
export OMPI_ALLOW_RUN_AS_ROOT_CONFIRM=1

# ==================
# Directories
# ==================

BDIR="/content"
WPS="/content/WPS"
WRF="/content/WRF/test/em_real"
WRFDA="/content/WRFDA/WRFDA"
OBS="/content/drive/MyDrive/colab/obsdata"
SAT="/content/drive/MyDrive/colab/satdata"
UPDATE="$WRFDA/var/test/update_bc"

# Output root 
trial="no_bogus_test"
OUTPUT_DIR="$BDIR/model_runs/$trial"

# ==================
# Time variables - adjust here
# day(s) only set here. follow pattern in update_namelist functions to change hours/sec/etc 
# ==================
start_date="2023-02-20_00:00:00"
end_date="2023-02-23_00:00:00"
days=3
cycle_hours=6
is_cold_start=true

# WPS/REAL LBC interval
interval=21600

# Coarse WRF output interval (minutes) used to drive ndown/fine LBC cadence
coarse_history_interval_min=60
coarse_interval_seconds=$((coarse_history_interval_min * 60))

# ==================
# Domain variables 
# ==================
evert=51

# Nest ratios
parent_grid_ratio_1=1
parent_grid_ratio_2=3

# i/j
# __1 is parent, __2 is child

ip1=1
jp1=1

ip2=36
jp2=27

ewe1=306
esn1=172
dx1=15000
dy1=15000

ewe2=523
esn2=334
dx2=5000
dy2=5000

# ==================
# DA Variables (bulk toggles)
# flip to "false" to not assimilate
# ==================
satinclude=false
insituinclude=true

# Satellite switches
amsua=$satinclude
hirs4=$satinclude
mhs=$satinclude
iasi=$satinclude
ssmis=$satinclude
atms=$satinclude
geoamv=$satinclude
polaramv=$satinclude

# In-situ switches
synop=$insituinclude
ships=$insituinclude
metar=$insituinclude
sound=$insituinclude
pilot=$insituinclude
airep=$insituinclude
buoy=$insituinclude
profiler=$insituinclude

bogus=false



# ==================
# Cores
# ==================
cores=$(nproc)

# ==================
# Physics Options
# ==================

mp=16
cu=2
bl=1
sfclay=1

# ==================
# Utilities
# ==================
advance_time() {
    local t="${1//_/ }"
    date -u -d "$t UTC + ${cycle_hours} hours" +%Y-%m-%d_%H:%M:%S
}

remove_bom_if_present() {
    local file="$1"
    if [[ -f "$file" ]]; then
        sed -i '1s/^\xEF\xBB\xBF//' "$file"
    fi
}

require_file() {
    local f="$1"
    [[ -f "$f" ]] || { echo "ERROR: Missing required file: $f" >&2; exit 1; }
}

safe_rm_glob() {
    shopt -s nullglob
    rm -f "$@" || true
    shopt -u nullglob
}

# ==================
# NAMELIST UPDATERS
# ==================

update_namelist_wps() {
    local start="$1"
    local end="$2"
    local wpsfile="$WPS/namelist.wps"
    remove_bom_if_present "$wpsfile"

    local s_fmt
    local e_fmt
    s_fmt=$(date -u -d "${start//_/ } UTC" +%Y-%m-%d_%H:%M:%S)
    e_fmt=$(date -u -d "${end//_/ } UTC" +%Y-%m-%d_%H:%M:%S)

    cp "$wpsfile" "${wpsfile}.bak"

    # time
    sed -i "s/^[[:space:]]*start_date.*/    start_date = '$s_fmt', '$s_fmt',/" "$wpsfile"
    sed -i "s/^[[:space:]]*end_date.*/      end_date   = '$e_fmt', '$e_fmt',/" "$wpsfile"

    # domains
    sed -i "s/^[[:space:]]*parent_grid_ratio.*/      parent_grid_ratio   = $parent_grid_ratio_1, $parent_grid_ratio_2,/" "$wpsfile"
    sed -i "s/^[[:space:]]*i_parent_start.*/      i_parent_start   = $ip1, $ip2,/" "$wpsfile"
    sed -i "s/^[[:space:]]*j_parent_start.*/      j_parent_start   = $jp1, $jp2,/" "$wpsfile"

    sed -i "s/^[[:space:]]*e_we.*/      e_we   = $ewe1, $ewe2,/" "$wpsfile"
    sed -i "s/^[[:space:]]*e_sn.*/      e_sn   = $esn1, $esn2,/" "$wpsfile"

    sed -i "s/^[[:space:]]*dx.*/      dx   = $dx1,/" "$wpsfile"
    sed -i "s/^[[:space:]]*dy.*/      dy   = $dy1,/" "$wpsfile"

    sed -i "s/^[[:space:]]*interval_seconds.*/      interval_seconds   = $interval,/" "$wpsfile"

    echo "===== namelist.wps updated ====="
    grep -E 'start_date|end_date|e_we|e_sn|dx|dy|interval_seconds|parent_grid_ratio|i_parent_start|j_parent_start' "$wpsfile" || true
    echo "================================"
}

update_namelist_real_two_dom() {
    # REAL must be max_dom=2 so it produces wrfinput_d02 for wrfndi_d02
    local start="$1"
    local end="$2"

    rm -f "$WRF/namelist.input"

    # Here I copy in a namelist that is stored under MyDrive that already had a lot of things set.
    # Made it easier to adjust only a few things at a time since every compile generates
    # a fresh namelist (cuts down on code)
    cp /content/drive/MyDrive/colab/scripts/namelist_wrf.input "$WRF/namelist.input"

    local nml="$WRF/namelist.input"
    remove_bom_if_present "$nml"

    local sY sM sD sH eY eM eD eH
    sY=$(date -u -d "${start//_/ } UTC" +%Y)
    sM=$(date -u -d "${start//_/ } UTC" +%m)
    sD=$(date -u -d "${start//_/ } UTC" +%d)
    sH=$(date -u -d "${start//_/ } UTC" +%H)

    eY=$(date -u -d "${end//_/ } UTC" +%Y)
    eM=$(date -u -d "${end//_/ } UTC" +%m)
    eD=$(date -u -d "${end//_/ } UTC" +%d)
    eH=$(date -u -d "${end//_/ } UTC" +%H)

    cp "$nml" "${nml}.bak.real2"

    # time control (2 columns)
    sed -i "s/^[[:space:]]*start_year.*/ start_year = ${sY}, ${sY},/" "$nml"
    sed -i "s/^[[:space:]]*start_month.*/ start_month = ${sM}, ${sM},/" "$nml"
    sed -i "s/^[[:space:]]*start_day.*/ start_day = ${sD}, ${sD},/" "$nml"
    sed -i "s/^[[:space:]]*start_hour.*/ start_hour = ${sH}, ${sH},/" "$nml"

    sed -i "s/^[[:space:]]*end_year.*/ end_year = ${eY}, ${eY},/" "$nml"
    sed -i "s/^[[:space:]]*end_month.*/ end_month = ${eM}, ${eM},/" "$nml"
    sed -i "s/^[[:space:]]*end_day.*/ end_day = ${eD}, ${eD},/" "$nml"
    sed -i "s/^[[:space:]]*end_hour.*/ end_hour = ${eH}, ${eH},/" "$nml"

    sed -i "s/^[[:space:]]*interval_seconds.*/ interval_seconds = ${interval},/" "$nml"

    sed -i "s/^[[:space:]]*run_days.*/ run_days = $days,/" "$nml"
    sed -i "s/^[[:space:]]*run_hours.*/ run_hours = 0, /" "$nml"
    sed -i "s/^[[:space:]]*run_minutes.*/ run_minutes = 0,  /" "$nml"
    sed -i "s/^[[:space:]]*run_seconds.*/ run_seconds = 0,  /" "$nml"

    # domains
    sed -i "s/^[[:space:]]*max_dom.*/ max_dom = 2,/" "$nml"
    sed -i "s/^[[:space:]]*e_we.*/ e_we = ${ewe1}, ${ewe2},/" "$nml"
    sed -i "s/^[[:space:]]*e_sn.*/ e_sn = ${esn1}, ${esn2},/" "$nml"
    sed -i "s/^[[:space:]]*e_vert.*/ e_vert = ${evert}, ${evert},/" "$nml"
    sed -i "s/^[[:space:]]*dx.*/ dx = ${dx1}, ${dx2},/" "$nml"
    sed -i "s/^[[:space:]]*dy.*/ dy = ${dy1}, ${dy2},/" "$nml"
    
    sed -i "s/^[[:space:]]*i_parent_start.*/ i_parent_start = ${ip1}, ${ip2},/" "$nml"
    sed -i "s/^[[:space:]]*j_parent_start.*/ j_parent_start = ${jp1}, ${jp2},/" "$nml"

    # physics
    sed -i "s/^[[:space:]]*mp_physics.*/ mp_physics = ${mp}, ${mp},/" "$nml"
    sed -i "s/^[[:space:]]*cu_physics.*/ cu_physics = ${cu}, ${cu},/" "$nml"
    sed -i "s/^[[:space:]]*bl_pbl_physics.*/ bl_pbl_physics = ${bl}, ${bl},/" "$nml"
    sed -i "s/^[[:space:]]*sf_sfclay_physics.*/ sf_sfclay_physics = ${sfclay}, ${sfclay},/" "$nml"

    # time
    #sed -i "s/^[[:space:]]*time_step./ time_step = 30, 30,/" "$nml"
    sed -i "s/^[[:space:]]*parent_grid_ratio.*/ parent_grid_ratio = ${parent_grid_ratio_1}, ${parent_grid_ratio_2},/" "$nml"
    sed -i "s/^[[:space:]]*parent_time_step_ratio.*/ parent_time_step_ratio = ${parent_grid_ratio_1}, ${parent_grid_ratio_2},/" "$nml"

    # random things
    #sed -i "s/^[[:space:]]*radt.*/ radt = 60, 60,/" "$nml"
    #sed -i "s/^[[:space:]]*gwd_opt.*/ gwd_opt = 1, 0,/" "$nml"

    # Add prec_acc_dt only if it is not already present
    if ! grep -q "^[[:space:]]*prec_acc_dt[[:space:]]*=" "$nml"; then
      echo "Adding prec_acc_dt = 60 to namelist"
      sed -i "/fractional_seaice/a\ prec_acc_dt = 60," "$nml"
    else
      echo "prec_acc_dt already present"
    fi


    echo "===== namelist.input set for REAL (2 domains) ====="
    grep -E 'start_|end_|interval_seconds|max_dom|e_we|e_sn|e_vert|dx|dy' "$nml" || true
    echo "==================================================="
}

update_namelist_wrf_coarse_96h() {
    local start="$1"
    local end="$2"
    local nml="$WRF/namelist.input"
    remove_bom_if_present "$nml"

    local sY sM sD sH eY eM eD eH
    sY=$(date -u -d "${start//_/ } UTC" +%Y)
    sM=$(date -u -d "${start//_/ } UTC" +%m)
    sD=$(date -u -d "${start//_/ } UTC" +%d)
    sH=$(date -u -d "${start//_/ } UTC" +%H)

    eY=$(date -u -d "${end//_/ } UTC" +%Y)
    eM=$(date -u -d "${end//_/ } UTC" +%m)
    eD=$(date -u -d "${end//_/ } UTC" +%d)
    eH=$(date -u -d "${end//_/ } UTC" +%H)

    cp "$nml" "${nml}.bak.coarse"

    # time (single column)
    sed -i "s/^[[:space:]]*start_year.*/ start_year = ${sY},/" "$nml"
    sed -i "s/^[[:space:]]*start_month.*/ start_month = ${sM},/" "$nml"
    sed -i "s/^[[:space:]]*start_day.*/ start_day = ${sD},/" "$nml"
    sed -i "s/^[[:space:]]*start_hour.*/ start_hour = ${sH},/" "$nml"

    sed -i "s/^[[:space:]]*end_year.*/ end_year = ${eY},/" "$nml"
    sed -i "s/^[[:space:]]*end_month.*/ end_month = ${eM},/" "$nml"
    sed -i "s/^[[:space:]]*end_day.*/ end_day = ${eD},/" "$nml"
    sed -i "s/^[[:space:]]*end_hour.*/ end_hour = ${eH},/" "$nml"

    # coarse run is standalone d01
    sed -i "s/^[[:space:]]*max_dom.*/ max_dom = 1,/" "$nml"
    sed -i "s/^[[:space:]]*e_we.*/ e_we = ${ewe1},/" "$nml"
    sed -i "s/^[[:space:]]*e_sn.*/ e_sn = ${esn1},/" "$nml"
    sed -i "s/^[[:space:]]*dx.*/ dx = ${dx1},/" "$nml"
    sed -i "s/^[[:space:]]*dy.*/ dy = ${dy1},/" "$nml"
    sed -i "s/^[[:space:]]*e_vert.*/ e_vert = ${evert},/" "$nml"

    sed -i "s/^[[:space:]]*run_days.*/ run_days = $days,/" "$nml"
    sed -i "s/^[[:space:]]*run_hours.*/ run_hours = 0,/" "$nml"
    sed -i "s/^[[:space:]]*run_minutes.*/ run_minutes = 0,/" "$nml"
    sed -i "s/^[[:space:]]*run_seconds.*/ run_seconds = 0,/" "$nml"

    sed -i "s/^[[:space:]]*i_parent_start.*/ i_parent_start = ${ip1}, ${ip2},/" "$nml"
    sed -i "s/^[[:space:]]*j_parent_start.*/ j_parent_start = ${jp1}, ${jp2},/" "$nml"

    # physics
    sed -i "s/^[[:space:]]*mp_physics.*/ mp_physics = ${mp}, ${mp},/" "$nml"
    sed -i "s/^[[:space:]]*cu_physics.*/ cu_physics = ${cu}, ${cu},/" "$nml"
    sed -i "s/^[[:space:]]*bl_pbl_physics.*/ bl_pbl_physics = ${bl}, ${bl},/" "$nml"
    sed -i "s/^[[:space:]]*sf_sfclay_physics.*/ sf_sfclay_physics = ${sfclay}, ${sfclay},/" "$nml"

    # time
    #sed -i "s/^[[:space:]]*time_step./ time_step = 30, 30,/" "$nml"
    sed -i "s/^[[:space:]]*parent_grid_ratio.*/ parent_grid_ratio = ${parent_grid_ratio_1}, ${parent_grid_ratio_2},/" "$nml"
    sed -i "s/^[[:space:]]*parent_time_step_ratio.*/ parent_time_step_ratio = ${parent_grid_ratio_1}, ${parent_grid_ratio_2},/" "$nml"

    # random things
    #sed -i "s/^[[:space:]]*radt.*/ radt = 60, 60,/" "$nml"
    #sed -i "s/^[[:space:]]*gwd_opt.*/ gwd_opt = 1, 0,/" "$nml"



    # GFS LBC interval for coarse run
    sed -i "s/^[[:space:]]*interval_seconds.*/ interval_seconds = ${interval},/" "$nml"

    # Ensure coarse wrfout cadence for ndown
    # history_interval is minutes; if namelist has multiple columns, overwrite first
    sed -i "s/^[[:space:]]*history_interval.*/ history_interval = ${coarse_history_interval_min},/" "$nml"

    echo "===== namelist.input set for COARSE (d01) ====="
    grep -E 'start_|end_|max_dom|e_we|e_sn|dx|dy|interval_seconds|history_interval' "$nml" || true
    echo "==================================================="
}

update_namelist_ndown() {
    # ndown must see interval_seconds = coarse wrfout interval in seconds
    local start="$1"
    local end="$2"
    local nml="$WRF/namelist.input"
    remove_bom_if_present "$nml"

    local sY sM sD sH eY eM eD eH
    sY=$(date -u -d "${start//_/ } UTC" +%Y)
    sM=$(date -u -d "${start//_/ } UTC" +%m)
    sD=$(date -u -d "${start//_/ } UTC" +%d)
    sH=$(date -u -d "${start//_/ } UTC" +%H)

    eY=$(date -u -d "${end//_/ } UTC" +%Y)
    eM=$(date -u -d "${end//_/ } UTC" +%m)
    eD=$(date -u -d "${end//_/ } UTC" +%d)
    eH=$(date -u -d "${end//_/ } UTC" +%H)

    cp "$nml" "${nml}.bak.ndown"

    sed -i "s/^[[:space:]]*start_year.*/ start_year = ${sY}, ${sY},/" "$nml"
    sed -i "s/^[[:space:]]*start_month.*/ start_month = ${sM}, ${sM},/" "$nml"
    sed -i "s/^[[:space:]]*start_day.*/ start_day = ${sD}, ${sD},/" "$nml"
    sed -i "s/^[[:space:]]*start_hour.*/ start_hour = ${sH}, ${sH},/" "$nml"

    sed -i "s/^[[:space:]]*end_year.*/ end_year = ${eY}, ${eY},/" "$nml"
    sed -i "s/^[[:space:]]*end_month.*/ end_month = ${eM}, ${eM},/" "$nml"
    sed -i "s/^[[:space:]]*end_day.*/ end_day = ${eD}, ${eD},/" "$nml"
    sed -i "s/^[[:space:]]*end_hour.*/ end_hour = ${eH}, ${eH},/" "$nml"

    sed -i "s/^[[:space:]]*interval_seconds.*/ interval_seconds = ${coarse_interval_seconds},/" "$nml"

    sed -i "s/^[[:space:]]*max_dom.*/ max_dom = 2,/" "$nml"
    sed -i "s/^[[:space:]]*e_we.*/ e_we = ${ewe1}, ${ewe2},/" "$nml"
    sed -i "s/^[[:space:]]*e_sn.*/ e_sn = ${esn1}, ${esn2},/" "$nml"
    sed -i "s/^[[:space:]]*dx.*/ dx = ${dx1}, ${dx2},/" "$nml"
    sed -i "s/^[[:space:]]*dy.*/ dy = ${dy1}, ${dy2},/" "$nml"
    sed -i "s/^[[:space:]]*e_vert.*/ e_vert = ${evert}, ${evert},/" "$nml"

    # Required for ndown
    if grep -qE "^[[:space:]]*io_form_auxinput2" "$nml"; then
        sed -i "s/^[[:space:]]*io_form_auxinput2.*/ io_form_auxinput2 = 2,/" "$nml"
    else
        sed -i "/&time_control/a\\ io_form_auxinput2 = 2," "$nml"
    fi

    echo "===== namelist.input set for NDOWN ====="
    grep -E 'io_form_auxinput2|interval_seconds|max_dom|e_we|e_sn|dx|dy|start_|end_' "$nml" || true
    echo "========================================"
}

update_namelist_wrf_fine_segment() {
    # Fine standalone WRF (max_dom=1) running a 6-hour segment
    local start="$1"
    local end="$2"
    local nml="$WRF/namelist.input"
    remove_bom_if_present "$nml"

    local sY sM sD sH eY eM eD eH
    sY=$(date -u -d "${start//_/ } UTC" +%Y)
    sM=$(date -u -d "${start//_/ } UTC" +%m)
    sD=$(date -u -d "${start//_/ } UTC" +%d)
    sH=$(date -u -d "${start//_/ } UTC" +%H)

    eY=$(date -u -d "${end//_/ } UTC" +%Y)
    eM=$(date -u -d "${end//_/ } UTC" +%m)
    eD=$(date -u -d "${end//_/ } UTC" +%d)
    eH=$(date -u -d "${end//_/ } UTC" +%H)

    cp "$nml" "${nml}.bak.fine"

    sed -i "s/^[[:space:]]*start_year.*/ start_year = ${sY},/" "$nml"
    sed -i "s/^[[:space:]]*start_month.*/ start_month = ${sM},/" "$nml"
    sed -i "s/^[[:space:]]*start_day.*/ start_day = ${sD},/" "$nml"
    sed -i "s/^[[:space:]]*start_hour.*/ start_hour = ${sH},/" "$nml"

    sed -i "s/^[[:space:]]*end_year.*/ end_year = ${eY},/" "$nml"
    sed -i "s/^[[:space:]]*end_month.*/ end_month = ${eM},/" "$nml"
    sed -i "s/^[[:space:]]*end_day.*/ end_day = ${eD},/" "$nml"
    sed -i "s/^[[:space:]]*end_hour.*/ end_hour = ${eH},/" "$nml"

    # Fine standalone domain 
    sed -i "s/^[[:space:]]*max_dom.*/ max_dom = 1,/" "$nml"
    sed -i "s/^[[:space:]]*e_we.*/ e_we = ${ewe2},/" "$nml"
    sed -i "s/^[[:space:]]*e_sn.*/ e_sn = ${esn2},/" "$nml"
    sed -i "s/^[[:space:]]*dx.*/ dx = ${dx2},/" "$nml"
    sed -i "s/^[[:space:]]*dy.*/ dy = ${dy2},/" "$nml"
    sed -i "s/^[[:space:]]*e_vert.*/ e_vert = ${evert},/" "$nml"

    # Fine BC cadence must match ndown-produced wrfbdy cadence
    sed -i "s/^[[:space:]]*interval_seconds.*/ interval_seconds = ${coarse_interval_seconds},/" "$nml"

    # ndown-only key not needed during wrf.exe
    sed -i "/^[[:space:]]*io_form_auxinput2[[:space:]]*=.*/d" "$nml" || true

    sed -i "s/^[[:space:]]*run_days.*/ run_days = 0,/" "$nml"
    sed -i "s/^[[:space:]]*run_hours.*/ run_hours = ${cycle_hours},/" "$nml"
    sed -i "s/^[[:space:]]*run_minutes.*/ run_minutes = 0,/" "$nml"
    sed -i "s/^[[:space:]]*run_seconds.*/ run_seconds = 0,/" "$nml"


    echo "===== namelist.input set for FINE (6h segment) ====="
    grep -E 'start_|end_|max_dom|e_we|e_sn|dx|dy|interval_seconds' "$nml" || true
    echo "===================================================="
}

update_namelist_wrfdavar_fine() {
    # WRFDA namelist is copied into the per-cycle run directory; edit $PWD/namelist.input
    local start="$1"
    local end="$2"
    local wrffile="$PWD/namelist.input"

    local tmin
    local tmax
    tmin=$(date -u -d "${start//_/ } UTC -3 hours" +%Y-%m-%d_%H:%M:%S)
    tmax=$(date -u -d "${start//_/ } UTC +3 hours" +%Y-%m-%d_%H:%M:%S)

    cp "$wrffile" "${wrffile}.bak"

    sed -i "s|^[[:space:]]*analysis_date.*|    analysis_date=\"${start}.0000\",|" "$wrffile"
    sed -i "s|^[[:space:]]*time_window_min.*|    time_window_min=\"${tmin}.0000\",|" "$wrffile"
    sed -i "s|^[[:space:]]*time_window_max.*|    time_window_max=\"${tmax}.0000\",|" "$wrffile"

    # Force WRFDA domain geometry to the fine standalone grid
    sed -i "s/^[[:space:]]*e_we.*/ e_we=$ewe2,/" "$wrffile"
    sed -i "s/^[[:space:]]*e_sn.*/ e_sn=$esn2,/" "$wrffile"
    sed -i "s/^[[:space:]]*dx.*/   dx=$dx2,/" "$wrffile"
    sed -i "s/^[[:space:]]*dy.*/   dy=$dy2,/" "$wrffile"
    sed -i "s/^[[:space:]]*e_vert.*/ e_vert=$evert,/" "$wrffile"

    # DA switches 
    sed -i "s/^[[:space:]]*use_amsuaobs.*/ use_amsuaobs=$amsua,/" "$wrffile"
    sed -i "s/^[[:space:]]*use_mhsobs.*/ use_mhsobs=$mhs,/" "$wrffile"
    sed -i "s/^[[:space:]]*use_hirs4obs.*/ use_hirs4obs=$hirs4,/" "$wrffile"
    sed -i "s/^[[:space:]]*use_iasiobs.*/ use_iasiobs=$iasi,/" "$wrffile"


    sed -i "s/^[[:space:]]*use_ssmisobs.*/ use_ssmisobs=$ssmis/" "$wrffile"
    sed -i "s/^[[:space:]]*use_atmsobs.*/ use_atmsobs=$atms,/" "$wrffile"

    sed -i "s/^[[:space:]]*use_synopobs.*/ use_synopobs=$synop,/" "$wrffile"
    sed -i "s/^[[:space:]]*use_shipsobs.*/ use_shipsobs=$ships,/" "$wrffile"
    sed -i "s/^[[:space:]]*use_metarobs.*/ use_metarobs=$metar,/" "$wrffile"
    sed -i "s/^[[:space:]]*use_soundobs.*/ use_soundobs=$sound,/" "$wrffile"
    sed -i "s/^[[:space:]]*use_pilotobs.*/ use_pilotobs=$pilot,/" "$wrffile"
    sed -i "s/^[[:space:]]*use_airepobs.*/ use_airepobs=$airep,/" "$wrffile"
    sed -i "s/^[[:space:]]*use_geoamvobs.*/ use_geoamvobs=$geoamv,/" "$wrffile"
    sed -i "s/^[[:space:]]*use_polaramvobs.*/ use_polaramvobs=$polaramv,/" "$wrffile"
    sed -i "s/^[[:space:]]*use_bogusobs.*/ use_bogusobs=$bogus,/" "$wrffile"
    sed -i "s/^[[:space:]]*use_buoyobs.*/ use_buoyobs=$buoy,/" "$wrffile"
    sed -i "s/^[[:space:]]*use_profilerobs.*/ use_profilerobs=$profiler,/" "$wrffile"

    # physics
    sed -i "s/^[[:space:]]*mp_physics.*/ mp_physics = ${mp}, /" "$wrffile"
    sed -i "s/^[[:space:]]*cu_physics.*/ cu_physics = ${cu}, /" "$wrffile"
    sed -i "s/^[[:space:]]*bl_pbl_physics.*/ bl_pbl_physics = ${bl}, /" "$wrffile"
    sed -i "s/^[[:space:]]*sf_sfclay_physics.*/ sf_sfclay_physics = ${sfclay}, /" "$wrffile"

    # Print verification 
    # DOUBLE CHECK WHILE RUNNING TO MAKE SURE EVERYTHING LINKED OVER CORRECTLY!
    echo "===== WRFDA namelist.input updated (FINE) ====="
    grep -E 'analysis_date|time_window|min|max' "$wrffile" || true
    grep -E 'e_we|e_sn|dx|dy|e_vert' "$wrffile" || true

    echo "DA Sources Assimilated:"
    echo "Satellites:"
    grep -E '^[[:space:]]*use_amsuaobs'   "$wrffile" || true
    grep -E '^[[:space:]]*use_mhsobs'     "$wrffile" || true
    grep -E '^[[:space:]]*use_hirs4obs'   "$wrffile" || true
    grep -E '^[[:space:]]*use_iasiobs'    "$wrffile" || true
    grep -E '^[[:space:]]*use_ssmisobs'    "$wrffile" || true
    grep -E '^[[:space:]]*use_atmsobs'    "$wrffile" || true

    echo "In-situ:"
    grep -E '^[[:space:]]*use_synopobs'     "$wrffile" || true
    grep -E '^[[:space:]]*use_shipsobs'     "$wrffile" || true
    grep -E '^[[:space:]]*use_metarobs'     "$wrffile" || true
    grep -E '^[[:space:]]*use_soundobs'     "$wrffile" || true
    grep -E '^[[:space:]]*use_pilotobs'     "$wrffile" || true
    grep -E '^[[:space:]]*use_airepobs'     "$wrffile" || true
    grep -E '^[[:space:]]*use_geoamvobs'    "$wrffile" || true
    grep -E '^[[:space:]]*use_polaramvobs'  "$wrffile" || true
    grep -E '^[[:space:]]*use_bogusobs'     "$wrffile" || true
    grep -E '^[[:space:]]*use_buoyobs'      "$wrffile" || true
    grep -E '^[[:space:]]*use_profilerobs'  "$wrffile" || true
    echo "==============================================="
}

# ==================
# EXECUTION BLOCKS
# ==================

run_wps() {
    local start="$1"
    local end="$2"
    cd "$WPS" || { echo "ERROR: Cannot cd to $WPS"; exit 1; }

    # Safe cleanup (avoid strict-mode glob failures)
    safe_rm_glob geo_em* met_em* GRIBFILE.* FILE:* PFILE:* Vtable

    update_namelist_wps "$start" "$end"

    ./link_grib.csh /content/drive/MyDrive/colab/gfs/gfs*
    ln -sf ungrib/Variable_Tables/Vtable.GFS Vtable

    echo "Running geogrid.exe..."
    ./geogrid.exe > geogrid.log 2>&1

    echo "Running ungrib.exe..."
    ./ungrib.exe > ungrib.log 2>&1

    echo "Running metgrid.exe..."
    ./metgrid.exe > metgrid.log 2>&1

    if ls met_em.d01* 1>/dev/null 2>&1; then
        echo "WPS run successful, met_em files generated."
    else
        echo "ERROR: No met_em output found. Check geogrid.log, ungrib.log, metgrid.log"
        exit 1
    fi
}

run_real() {
    local tag="$1"
    local rundir="$OUTPUT_DIR/${tag}"
    mkdir -p "$rundir"

    cd "$WRF" || { echo "ERROR: Cannot cd to $WRF"; exit 1; }

    safe_rm_glob met_em*

    cp "$WPS"/met_em.d01* "$WRF"/
    cp "$WPS"/met_em.d02* "$WRF"/

    echo ">>> Starting real.exe..."
    ./real.exe

    require_file "$WRF/wrfinput_d01"
    require_file "$WRF/wrfinput_d02"
    require_file "$WRF/wrfbdy_d01"
}

run_wrf_coarse_96h() {
    local outdir="$OUTPUT_DIR/coarse_96h"
    mkdir -p "$outdir"

    cd "$WRF" || { echo "ERROR: Cannot cd to $WRF"; exit 1; }

    # Coarse run needs wrfinput_d01 & wrfbdy_d01 from REAL
    require_file "$WRF/wrfinput_d01"
    require_file "$WRF/wrfbdy_d01"

    echo ">>> Starting coarse wrf.exe (${days}, d01)..."
    mpirun --oversubscribe -np $cores ./wrf.exe > "$outdir/wrf_coarse.log" 2>&1 || { echo "Cannot WRF"; exit 1;}

    # Archive coarse outputs
    shopt -s nullglob
    local outs=(wrfout_d01_*)
    shopt -u nullglob
    [[ ${#outs[@]} -gt 0 ]] || { echo "ERROR: Coarse run produced no wrfout_d01_*"; exit 1; }

    mv -f wrfout_d01_* "$outdir"/
    echo "Coarse WRF complete. Outputs moved to: $outdir"
    cd $outdir
    cp wrfout_d01* /content/drive/MyDrive/colab/outputs/$trial || true
    # save to MyDrive to preserve
    echo "Copies saved to /content/drive/MyDrive/colab/outputs/$trial" 
}

prepare_wrfndi() {
    # ndown expects wrfndi_d02
    cd "$WRF" || { echo "ERROR: Cannot cd to $WRF"; exit 1; }
    require_file "$WRF/wrfinput_d02"
    cp -f "$WRF/wrfinput_d02" "$WRF/wrfndi_d02"
    require_file "$WRF/wrfndi_d02"
}

run_ndown() {
    local coarse_dir="$OUTPUT_DIR/coarse_96h"
    local stage_dir="$OUTPUT_DIR/fine_stage"
    local ndown_dir="$OUTPUT_DIR/ndown_stage"  
    mkdir -p "$stage_dir" "$ndown_dir"

    export OMP_NUM_THREADS=1

    # --- Sanity checks (fail early) ---
    require_file "$WRF/ndown.exe"
    require_file "$WRF/wrfndi_d02"

    # --- Clean staging directory ---
    # Remove any prior ndown artifacts and stale links
    safe_rm_glob "$ndown_dir"/wrfout_d01_* \
                 "$ndown_dir"/wrfinput_d02 \
                 "$ndown_dir"/wrfbdy_d02 \
                 "$ndown_dir"/namelist.input \
                 "$ndown_dir"/rsl.out.* \
                 "$ndown_dir"/rsl.error.* \
                 "$ndown_dir"/ndown.exe \
                 "$ndown_dir"/wrfndi_d02

    # --- Stage required executables/inputs into sandbox ---
    # Copy ndown.exe locally (keeps rsl logs and runtime files self-contained)
    cp -f "$WRF/ndown.exe" "$ndown_dir/ndown.exe"
    cp -f "$WRF/wrfndi_d02" "$ndown_dir/wrfndi_d02"

    # Link (not copy) coarse wrfout time series (saves disk)
    cp -f "$coarse_dir"/wrfout_d01_* "$ndown_dir/"

    # --- Build namelist.input for ndown in $WRF, then copy into sandbox ---
    # (We keep using your existing update_namelist_ndown() routine)
    cd "$WRF" || { echo "ERROR: Cannot cd to $WRF"; exit 1; }
    update_namelist_ndown "$start_date" "$end_date"
    require_file "$WRF/namelist.input"
    cp -f "$WRF/namelist.input" "$ndown_dir/namelist.input"

    # --- Run ndown in sandbox ---
    cd "$ndown_dir" || { echo "ERROR: Cannot cd to $ndown_dir"; exit 1; }

    echo ">>> Starting ndown.exe in clean staging dir: $ndown_dir"
    # Keep ndown MPI ranks separate from the rest of your workflow
    # (Hard-coded 14 per your current line; consider making this a variable like cores_ndown)
    mpirun --oversubscribe -np $cores ./ndown.exe > "$stage_dir/ndown.log" 2>&1 || { echo "Cannot complete ndown"; exit 1; }

    # --- Verify outputs in sandbox ---
    require_file "$ndown_dir/wrfinput_d02"
    require_file "$ndown_dir/wrfbdy_d02"

    # --- Stage as standalone fine IC/BC (rename to d01 for standalone fine run) ---
    cp -f "$ndown_dir/wrfinput_d02" "$stage_dir/wrfinput_d01"
    cp -f "$ndown_dir/wrfbdy_d02"   "$stage_dir/wrfbdy_d01"

    echo "NDOWN complete. Fine standalone IC/BC staged in: $stage_dir"
}


stage_fine_icbc_into_wrf_dir() {
    local stage_dir="$OUTPUT_DIR/fine_stage"

    cd "$WRF" || { echo "ERROR: Cannot cd to $WRF"; exit 1; }

    require_file "$stage_dir/wrfinput_d01"
    require_file "$stage_dir/wrfbdy_d01"

    cp -f "$stage_dir/wrfinput_d01" "$WRF/wrfinput_d01"
    cp -f "$stage_dir/wrfbdy_d01"   "$WRF/wrfbdy_d01"

    echo "Fine standalone wrfinput_d01/wrfbdy_d01 staged into $WRF"
}

# --------------------------
# Fine-only WRFDA functions
# --------------------------

link_obs_and_sat() {
    local current="$1"
    local obsdir="$OBS"
    local satobs="$SAT"

    local date_code
    local hour_code
    date_code=$(date -u -d "${current//_/ } UTC" +%Y%m%d)
    hour_code=$(date -u -d "${current//_/ } UTC" +%H)

    echo ">>> Date code = $date_code | Hour code = $hour_code"

    # In-situ 
    local obs_file="${obsdir}/prepbufr.gdas.${date_code}.t${hour_code}z.nr"
    if [[ -f "$obs_file" ]]; then
        cp -f "$obs_file" ./ob.bufr
        echo "Linked: ob.bufr"
    else
        echo "WARN: Missing obs file: $obs_file"
    fi

    # Satellite target names expected by WRFDA
    declare -A sat_target=(
        [amsua]="amsua.bufr"
        [hirs4]="hirs4.bufr"
        [atms]="atms.bufr"
        [mhs]="mhs.bufr"
        [ssmis]="ssmis.bufr"
        )

    # Satellite filename patterns 
    declare -A sat_pattern=(
        [amsua]="gdas.1bamua.t${hour_code}z.${date_code}.bufr"
        [hirs4]="gdas.1bhrs4.t${hour_code}z.${date_code}.bufr"
        [atms]="gdas.${date_code}.t${hour_code}z.atms.tm00.bufr_d"
        [mhs]="gdas.1bmhs.t${hour_code}z.${date_code}.bufr"
        [ssmis]="gdas.${date_code}.t${hour_code}z.ssmisu.tm00.bufr_d"
        )

    for s in "${!sat_target[@]}"; do
        local sat_file="${satobs}/${sat_pattern[$s]}"
        local target="${sat_target[$s]}"
        if [[ -f "$sat_file" ]]; then
            cp -f "$sat_file" "$target"
            echo "Linked: $target"
        else
            echo "WARN: Missing sat file: $sat_file"
        fi
    done
}

run_update_warm_fine() {
    # Update low boundary of background (wrfout) using previous analysis wrfinput (wrfvar_output)
    # Produces UPDATE/fg for DA.
    local current="$1"
    local prev_analysis_dir="$2"  
    local bg_wrfout="$3"          

    cd "$UPDATE" || { echo "ERROR: Cannot cd to $UPDATE"; exit 1; }

    safe_rm_glob fg wrfinput_d01 wrfbdy_d01 wrfvar_output

    require_file "$bg_wrfout"
    require_file "$prev_analysis_dir/wrfvar_output"

    cp "$bg_wrfout" fg
    cp "$prev_analysis_dir/wrfvar_output" wrfinput_d01

    # wrfbdy not required for low-boundary update, but many parame.in templates reference it
    if [[ -f "$WRF/wrfbdy_d01" ]]; then
        cp "$WRF/wrfbdy_d01" wrfbdy_d01
    else
        # create an empty placeholder if template insists 
        echo "WARN: $WRF/wrfbdy_d01 missing during warm prep"
    fi

    sed -i "s|^\s*da_file.*| da_file = './fg'|" parame.in
    sed -i "s|^\s*wrf_input.*| wrf_input = './wrfinput_d01'|" parame.in
    sed -i "s|^\s*wrf_bdy_file.*| wrf_bdy_file = './wrfbdy_d01'|" parame.in
    sed -i "s|^[[:space:]]*update_lateral_bdy.*| update_lateral_bdy = .false.|" parame.in
    sed -i "s|^[[:space:]]*update_low_bdy.*| update_low_bdy    = .true.|" parame.in

    ./da_update_bc.exe 2>&1 | grep -E "FATAL|ERROR|WRN" || true

    require_file "$UPDATE/fg"
    echo "Warm background preparation complete: $current"
}

run_wrfdavar_fine() {
    local current="$1"
    local next="$2"
    local fg_source="$3"

    local rundir="$OUTPUT_DIR/fine_cycle/T_${current//[-_:]/}"
    mkdir -p "$rundir"
    cd "$rundir" || exit 1

    # Link runtime files
    cp -f "$WRFDA/var/run/VARBC.in" .
    cp -rpf "$WRFDA/var/run/radiance_info" .
    cp -f "$WRFDA/var/da/da_wrfvar.exe" .
    cp -f "/content/drive/MyDrive/colab/be.dat" .
    cp -f "/content/drive/MyDrive/colab/LANDUSE.TBL" .

    # Stage CRTM coeffs locally (more reliable than cp -r dir on Drive mounts)

    # Hint CRTM explicitly (safe even if ignored)
    export CRTM_COEFF_DIR="$PWD/crtm_coeffs"
    export CRTM_COEF_PATH="$PWD/crtm_coeffs"

    echo ">>> Starting WRFDA cycle at $current"

    # Obs/sat links
    link_obs_and_sat "$current"

    # Fresh WRFDA namelist for this cycle
    cp "/content/drive/MyDrive/colab/scripts/old_wrfda_input.input" ./namelist.input
    update_namelist_wrfdavar_fine "$current" "$next"

    require_file "$fg_source"
    cp -f "$fg_source" fg

    echo ">>> Running da_wrfvar.exe (FINE ONLY)..."
    mpirun --mca orte_base_help_aggregate 0 --oversubscribe -np "$cores" ./da_wrfvar.exe > "$rundir/da_wrfvar.log" 2>&1

    require_file "$rundir/wrfvar_output"
    echo "WRFDA completed: $current"
}

run_update_lateral_fine() {
    # Update fine wrfbdy to be consistent with the analysis (wrfvar_output)
    local current="$1"
    local analysis_dir="$2"   # contains wrfvar_output

    cd "$UPDATE" || { echo "ERROR: Cannot cd to $UPDATE"; exit 1; }

    safe_rm_glob wrfinput_d01 wrfbdy_d01 wrfvar_output

    require_file "$analysis_dir/wrfvar_output"
    require_file "$WRF/wrfbdy_d01"

    cp "$analysis_dir/wrfvar_output" wrfvar_output
    cp "$analysis_dir/wrfvar_output" wrfinput_d01
    cp "$WRF/wrfbdy_d01" wrfbdy_d01

    sed -i "s|^\s*da_file.*| da_file = './wrfvar_output'|" parame.in
    sed -i "s|^\s*wrf_input.*| wrf_input = './wrfinput_d01'|" parame.in
    sed -i "s|^\s*wrf_bdy_file.*| wrf_bdy_file = './wrfbdy_d01'|" parame.in
    sed -i "s|^[[:space:]]*update_lateral_bdy.*| update_lateral_bdy = .true.|" parame.in
    sed -i "s|^[[:space:]]*update_low_bdy.*| update_low_bdy    = .false.|" parame.in

    ./da_update_bc.exe 2>&1 | grep -E "FATAL|ERROR|WRN" || true

    # Copy updated boundary back into the fine WRF run directory
    require_file "$UPDATE/wrfbdy_d01"
    cp -f "$UPDATE/wrfbdy_d01" "$WRF/wrfbdy_d01"

    echo "Cold BC update complete (fine wrfbdy updated): $current"
}

run_wrf_fine_segment() {
    local current="$1"
    local next="$2"
    local analysis_dir="$3"

    local rundir="$OUTPUT_DIR/fine_cycle/T_${current//[-_:]/}"
    mkdir -p "$rundir"

    cd "$WRF" || { echo "ERROR: Cannot cd to $WRF"; exit 1; }

    require_file "$analysis_dir/wrfvar_output"
    require_file "$WRF/wrfbdy_d01"

    # Overwrite wrfinput with the analysis for this segment
    safe_rm_glob wrfinput_d01 wrfout_d01_* rsl.out.* rsl.error.*
    cp -f "$analysis_dir/wrfvar_output" wrfinput_d01

    update_namelist_wrf_fine_segment "$current" "$next"

    echo ">>> Starting fine wrf.exe ($current -> $next)..."
    mpirun --oversubscribe -np $cores ./wrf.exe > "$rundir/wrf_fine.log" 2>&1

    # Archive outputs to per-cycle directory
    ln -sf "$WRF"/wrfout_d01_* "$rundir/" 2>/dev/null || true
    cp $WRF/wrfout* /content/drive/MyDrive/colab/outputs/$trial/fine_backups || true

    echo "Fine WRF completed at ${current}." 
}

###############################################################################
# MAIN
###############################################################################

mkdir -p "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR/coarse_96h" "$OUTPUT_DIR/fine_stage" "$OUTPUT_DIR/fine_cycle"
mkdir -p "/content/drive/MyDrive/colab/outputs/$trial"
mkdir -p "/content/drive/MyDrive/colab/outputs/$trial/fine_backups"

read -p "File structure created for ${trial}. Would you like to continue to WRF? y to proceed, n to abort: " answer

if [[ "$answer" == "y" ]]; then
    echo "Continuing..."
elif [[ "$answer" == "n" ]]; then
    echo "Aborting."
    exit 1
else
    echo "Invalid input. Aborting."
    exit 1
fi

cd /content
wget https://www2.mmm.ucar.edu/wrf/users/wrfda/download/crtm_coeffs_2.2.3.tar.gz
tar -xvf crtm_coeffs_2.2.3.tar.gz
mv crtm_coeffs_2.2.3 crtm_coeffs

echo "==================="
echo "Directories located"
echo "==================="

echo "PHASE A: WPS/REAL (2 dom) + COARSE WRF 96h (d01 only, no DA)"
echo ">>> Running WPS for ${start_date} -> ${end_date}"
run_wps "$start_date" "$end_date"

echo ">>> Configuring REAL for 2 domains"
update_namelist_real_two_dom "$start_date" "$end_date"

echo ">>> Running REAL"
run_real "real_2dom"

echo ">>> Preparing wrfndi_d02 for ndown"
prepare_wrfndi

echo ">>> Configuring COARSE WRF for ${days} days"
update_namelist_wrf_coarse_96h "$start_date" "$end_date"

echo ">>> Running COARSE WRF"
#run_wrf_coarse_96h

echo "PHASE B: NDOWN + FINE 6-hourly cycling with WRFDA"
echo ">>> Running NDOWN"
run_ndown

echo ">>> Staging fine IC/BC into WRF run directory"
stage_fine_icbc_into_wrf_dir

# -------------------------------
# Fine cycling loop
# -------------------------------
current="$start_date"
prev="$start_date"

while [[ "$current" != "$end_date" ]]; do
    next=$(advance_time "$current")

    echo "--------------------------------------------------"
    echo "FINE CYCLE: $current  ->  $next"
    echo "--------------------------------------------------"

    # Determine background for DA:
    # - cold start: use fine wrfinput_d01 from ndown
    # - warm start: use fine wrfout valid at current (low-boundary updated)
    analysis_dir="$OUTPUT_DIR/fine_cycle/T_${current//[-_:]/}"

    if [[ "$is_cold_start" == "true" ]]; then
        echo "Cold-start: using fine wrfinput_d01 as DA background"
        require_file "$WRF/wrfinput_d01"
        fg_source="$WRF/wrfinput_d01"
        is_cold_start=false
    else
        # background wrfout at current time must exist
        bg_wrfout="$WRF/wrfout_d01_${current}"
        if [[ ! -f "$bg_wrfout" ]]; then
            echo "ERROR: Missing background wrfout: $bg_wrfout"
            exit 1
        fi

        # prior analysis directory is previous cycle
        prev_analysis_dir="$OUTPUT_DIR/fine_cycle/T_${prev//[-_:]/}"
        require_file "$prev_analysis_dir/wrfvar_output"

        echo "Warm-start: preparing fg via da_update_bc (update_low_bdy)"
        run_update_warm_fine "$current" "$prev_analysis_dir" "$bg_wrfout"
        fg_source="$UPDATE/fg"
    fi

    # Run DA on fine only
    run_wrfdavar_fine "$current" "$next" "$fg_source"

    # Update fine wrfbdy to match analysis
    run_update_lateral_fine "$current" "$analysis_dir"

    # Forecast 6 hours on fine only using the analysis
    run_wrf_fine_segment "$current" "$next" "$analysis_dir"

    prev="$current"
    current="$next"
done

echo "=================================================="
echo "DONE"
echo "Coarse outputs:  $OUTPUT_DIR/coarse_96h"
echo "Fine staging:    $OUTPUT_DIR/fine_stage"
echo "Fine cycles:     $OUTPUT_DIR/fine_cycle"
echo "=================================================="