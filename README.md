The views expressed in this thesis are those of the author and do not reflect the official policy or
position of the United States Air Force, the Department of Defense or the United States Government.
This material is declared a work of the United States Government and is not subject to copyright
protection in the United States

Information contained within this directory is free to use for further research. In particular, the WRF colab compilation script may come in handy.

Workflow was structured as follows (Linux recommended):
1. Compile WRF within Google CoLab (WRFtest.ipynb)
2. Run WRF for each trial within CoLab via runwrf^2_lambert.sh inside terminal (opening script and changing name and assimilated observations as needed)
3. Create one local top-level directory for analysis.
4. Zip wrfouts within Drive. Download locally. Unzip and place into folder corresponding to trial name (fulldata, nosat, noinsitu, noda, etc)
5. Within these directories, run chart+dir+rain to extract necessary information for other scripts. Rename outputted csv such that it is easy to recognize.
6. Run analysis scripts.
7. Some scripts, such as allskewt, are placed in the top level analysis directory and automatically scan subdirectories for the corresponding wrfout files. Please see the script itself to see usage.
