#! /bin/bash

# Given a subject ID, session, and tgz directory:
#   1) Copy all tgzs to compute node's disk
#   2) Unpack tgzs
#   3) Convert dcms to niftis in BIDS
#   4) Select the best SEFM
#   5) Rename and move Eprime files
#   6) Copy back to Lustre

## Necessary dependencies
# dcm2bids (https://github.com/DCAN-Labs/Dcm2Bids)
# microgl_lx (https://github.com/rordenlab/dcm2niix)
# pigz-2.4 (https://zlib.net/pigz)
# run_order_fix.py (in this repo)
# sefm_eval_and_json_editor.py (in this repo)
# Mrtrix 3 (https://www.mrtrix.org/)
# FSL

# If output folder is given as a command line arg, get it; otherwise use
# ./data as the default. Added by Greg 2019-06-06
if [ "x$4" = "x" ]; then
    ROOT_BIDSINPUT=./data
else
    ROOT_BIDSINPUT=$4
fi

# If temp files folder is given as a command line arg, get it; otherwise use
# ./temp as the default. Added by Greg 2019-06-07
if [ "x$5" = "x" ]; then
    ScratchSpaceDir=./temp
else
    ScratchSpaceDir=$5
fi

# Get FSL and MRE directory paths from command line; added by Greg Conan on
# 2019-06-10
if [[ ! "x$6" = "x" && ! "x$7" = "x" ]]; then
    FSL_DIR=$6
    MRE_DIR=$7
fi

SUB=$1 # Full BIDS formatted subject ID (sub-SUBJECTID)
VISIT=$2 # Full BIDS formatted session ID (ses-SESSIONID)
TGZDIR=$3 # Path to directory containing all .tgz for this subject's session

ABCD2BIDS_DIR="$(dirname `dirname $0`)"

participant=`echo ${SUB} | sed 's|sub-||'`
session=`echo ${VISIT} | sed 's|ses-||'`

date
hostname
echo ${SLURM_JOB_ID}
echo Running under group: `id -g`

# Setup scratch space directory
if [ ! -d ${ScratchSpaceDir} ]; then
    mkdir -p ${ScratchSpaceDir}
    # chown :fnl_lab ${ScratchSpaceDir} || true 
    chmod 770 ${ScratchSpaceDir} || true
fi
RandomHash=$(printf '%s' $(echo "$RANDOM" | md5sum) | cut -c 1-16)
TempSubjectDir=${ScratchSpaceDir}/${RandomHash}
mkdir -p ${TempSubjectDir}
# chown :fnl_lab ${TempSubjectDir} || true

# copy all tgz to the scratch space dir
echo `date`" :COPYING TGZs TO SCRATCH: ${TempSubjectDir}"
cp ${TGZDIR}/image03/* ${TempSubjectDir}

# unpack tgz to ABCD_DCMs directory
mkdir ${TempSubjectDir}/DCMs
echo `date`" :UNPACKING DCMs: ${TempSubjectDir}/DCMs"
for tgz in ${TempSubjectDir}/*.tgz; do
    echo $tgz
    tar -xzf ${tgz} -C ${TempSubjectDir}/DCMs
done

if [ -e ${TempSubjectDir}/DCMs/${SUB}/${VISIT}/func ]; then
    ${ABCD2BIDS_DIR}/src/remove_RawDataStorage_dcms.py ${TempSubjectDir}/DCMs/${SUB}/${VISIT}/func
fi


# # IMPORTANT PATH DEPENDENCY VARIABLES AT OHSU IN SLURM CLUSTER
# export PATH=.../anaconda2/bin:${PATH} # relevant Python path with dcm2bids
# export PATH=.../mricrogl_lx/:${PATH} # relevant dcm2niix path
# export PATH=.../pigz-2.4/:${PATH} # relevant pigz path for improved (de)compression


# convert DCM to BIDS and move to ABCD directory
mkdir ${TempSubjectDir}/BIDS_unprocessed
cp ${ABCD2BIDS_DIR}/dataset_description.json ${TempSubjectDir}/BIDS_unprocessed/
echo ${participant}
echo `date`" :RUNNING dcm2bids"
dcm2bids -d ${TempSubjectDir}/DCMs/${SUB} -p ${participant} -s ${session} -c ${ABCD2BIDS_DIR}/abcd_dcm2bids.conf -o ${TempSubjectDir}/BIDS_unprocessed --forceDcm2niix --clobber


echo " " > ${TGZDIR}/log_id_failed_dwi_formatting.txt

# replace bvals and bvecs with files supplied by the NDA
if [ -e ${TempSubjectDir}/DCMs/${SUB}/${VISIT}/dwi ]; then
    first_dcm=$(find "${TempSubjectDir}/DCMs/${SUB}/${VISIT}/dwi/" -mindepth 2 -type f -name '*.dcm' | sort | head -n1)

    echo "Replacing bvals and bvecs with files supplied by the NDA"
    for dwi in ${TempSubjectDir}/BIDS_unprocessed/${SUB}/${VISIT}/dwi/${SUB}_${VISIT}*.nii.gz; do
        orig_bval=`echo $dwi | sed 's|.nii.gz|.bval|'`
        orig_bvec=`echo $dwi | sed 's|.nii.gz|.bvec|'`

        if [[ `dcmdump --search 0008,0070 ${first_dcm} 2>/dev/null` == *GE* ]]; then
            echo "Replacing GE bvals and bvecs and splitting reverse b0s"
            rm ${TempSubjectDir}/BIDS_unprocessed/${SUB}/${VISIT}/fmap/*.bval
            rm ${TempSubjectDir}/BIDS_unprocessed/${SUB}/${VISIT}/fmap/*.bvec
            fmap_AP=${TempSubjectDir}/BIDS_unprocessed/${SUB}/${VISIT}/fmap/*AP_epi.nii.gz
            fmap_AP_json=`echo $fmap_AP | sed 's|.nii.gz|.json|'`
            fmap_PA=`echo $fmap_AP | sed 's|AP|PA|'`
            fmap_PA_json=`echo $fmap_PA | sed 's|.nii.gz|.json|'`
            fslsplit $fmap_AP ${TempSubjectDir}/BIDS_unprocessed/${SUB}/${VISIT}/fmap/vol -t
            mv ${TempSubjectDir}/BIDS_unprocessed/${SUB}/${VISIT}/fmap/vol0000.nii.gz ${fmap_AP}
            mv ${TempSubjectDir}/BIDS_unprocessed/${SUB}/${VISIT}/fmap/vol0001.nii.gz ${fmap_PA}
            cp $fmap_AP_json $fmap_PA_json
            rm ${TempSubjectDir}/BIDS_unprocessed/${SUB}/${VISIT}/fmap/vol*
            cp `dirname $0`/ABCD_Release_2.0_Diffusion_Tables/GE_bvals_DV25.txt ${orig_bval}
            cp `dirname $0`/ABCD_Release_2.0_Diffusion_Tables/GE_bvecs_DV25.txt ${orig_bvec}
            nvols=`mrinfo -size $dwi | cut -f4 -d' '`
            # Validating that the dwi file contains the right number of volume. This is necessary
            # since software version 26 acquires one more b0 at the beginning than the software version
            # 25.
            if [ $nvols -eq 104 ]; then
                echo "DWI file contains 104 volumes, removing the first one."
                fslsplit $dwi ${TempSubjectDir}/BIDS_unprocessed/${SUB}/${VISIT}/dwi/vol -t
                # Remove first volume as it is the only one that differs from software version 25 and 26.
                rm ${TempSubjectDir}/BIDS_unprocessed/${SUB}/${VISIT}/dwi/vol0000.nii.gz
                # Concatenating all volumes back together.
                mrcat ${TempSubjectDir}/BIDS_unprocessed/${SUB}/${VISIT}/dwi/vol* $dwi -force
                # Removing all single volumes file.
                rm ${TempSubjectDir}/BIDS_unprocessed/${SUB}/${VISIT}/dwi/vol*
                # Validate the final number
                nvols_f=`mrinfo -size $dwi | cut -f4 -d' '`
                if [ $nvols_f -ne 103 ]; then
                    echo "${SUB} failed to performed formatting, see log file in ${TGZDIR}"
                    echo "${SUB} doesn't have the right number of volumes. Validate source data" >> ${TGZDIR}/log_id_failed_dwi_formatting.txt
                fi
            fi
        elif [[ `dcmdump --search 0008,0070 ${first_dcm} 2>/dev/null` == *Philips* ]]; then
            if [[ -e $dwi ]]; then
                echo "Concatenating Phillips scans."
            else
                echo "Phillips scans already concatenated. Skipping to next file."
                break
            fi
            dwi=`echo $dwi | sed 's/_run-..//'`
            new_json=`echo $dwi | sed 's/_run-..//' | sed 's|.nii.gz|.json|'`
            run01=`cat ${TempSubjectDir}/BIDS_unprocessed/${SUB}/${VISIT}/dwi/*run-01_dwi.json | jq -r '.SeriesNumber'`
            run02=`cat ${TempSubjectDir}/BIDS_unprocessed/${SUB}/${VISIT}/dwi/*run-02_dwi.json | jq -r '.SeriesNumber'`
            if [[ run01 -lt run02 ]]; then
                mrcat ${TempSubjectDir}/BIDS_unprocessed/${SUB}/${VISIT}/dwi/*run-01_dwi.nii.gz \
                      ${TempSubjectDir}/BIDS_unprocessed/${SUB}/${VISIT}/dwi/*run-02_dwi.nii.gz \
                      ${dwi}
            else
                mrcat ${TempSubjectDir}/BIDS_unprocessed/${SUB}/${VISIT}/dwi/*run-02_dwi.nii.gz \
                      ${TempSubjectDir}/BIDS_unprocessed/${SUB}/${VISIT}/dwi/*run-01_dwi.nii.gz \
                      ${dwi}
            fi
            cp ${TempSubjectDir}/BIDS_unprocessed/${SUB}/${VISIT}/dwi/*run-01_dwi.json $new_json
            echo "Replacing Philips bvals and bvecs with the merged (s1 + s2) files."
            merged_bval=`echo $dwi | sed 's|.nii.gz|.bval|'`
            merged_bvec=`echo $dwi | sed 's|.nii.gz|.bvec|'`
            cp `dirname $0`/ABCD_Release_2.0_Diffusion_Tables/Philips_bvals_merged.txt ${merged_bval}
            cp `dirname $0`/ABCD_Release_2.0_Diffusion_Tables/Philips_bvecs_merged.txt ${merged_bvec}
            echo "Removing non-concatenated files for each run."
            rm ${TempSubjectDir}/BIDS_unprocessed/${SUB}/${VISIT}/dwi/*run-01*
            rm ${TempSubjectDir}/BIDS_unprocessed/${SUB}/${VISIT}/dwi/*run-02*
        elif [[ `dcmdump --search 0008,0070 ${first_dcm} 2>/dev/null` == *SIEMENS* ]]; then
            echo "Replacing Siemens bvals and bvecs"
            cp `dirname $0`/ABCD_Release_2.0_Diffusion_Tables/Siemens_bvals.txt ${orig_bval}
            cp `dirname $0`/ABCD_Release_2.0_Diffusion_Tables/Siemens_bvecs.txt ${orig_bvec}
        else
            echo "ERROR setting up DWI: Manufacturer not recognized"
            exit
        fi
        # Validating that dwi file matches the number of bvalues in the sidecar file.
        nvol=`mrinfo -size $dwi | cut -f4 -d' '`
        nb_bval=$(wc -w < ${TempSubjectDir}/BIDS_unprocessed/${SUB}/${VISIT}/dwi/*.bval)
        if [ $nvol -ne $nb_bval ]; then
          echo "ERROR: Number of bvalues doesn't match the number of volumes in dwi for ${SUB}. Please see the log file in ${TGZDIR}"
          echo "${SUB} doesn't have matching bvalues and number of volumes in dwi." >> ${TGZDIR}log_id_failed_dwi_formatting.txt
        fi
    done
fi


if [[ -e ${TempSubjectDir}/BIDS_unprocessed/${SUB}/${VISIT}/func ]]; then
    echo `date`" :CHECKING BIDS ORDERING OF EPIs"
    i=0
    while [ "`${ABCD2BIDS_DIR}/src/run_order_fix.py ${TempSubjectDir}/BIDS_unprocessed ${TempSubjectDir}/bids_order_error.json ${TempSubjectDir}/bids_order_map.json --all --subject ${SUB}`" != ${SUB} ] && [ $i -ne 3 ]; do
        ((i++))
        echo `date`" :  WARNING: BIDS functional scans incorrectly ordered. Attempting to reorder. Attempt #$i"
    done        
    if [ "`${ABCD2BIDS_DIR}/src/run_order_fix.py ${TempSubjectDir}/BIDS_unprocessed ${TempSubjectDir}/bids_order_error.json ${TempSubjectDir}/bids_order_map.json --all --subject ${SUB}`" == ${SUB} ]; then
        echo `date`" : BIDS functional scans correctly ordered"
    else
        echo `date`" :  ERROR: BIDS incorrectly ordered even after running run_order_fix.py"
        exit
    fi
fi
# select best fieldmap and update sidecar jsons
echo `date`" :RUNNING SEFM SELECTION AND EDITING SIDECAR JSONS"
if [ -d ${TempSubjectDir}/BIDS_unprocessed/${SUB}/${VISIT}/fmap ]; then
    ${ABCD2BIDS_DIR}/src/sefm_eval_and_json_editor.py ${TempSubjectDir}/BIDS_unprocessed ${FSL_DIR} ${MRE_DIR} --participant-label=${participant} --output_dir $ROOT_BIDSINPUT
fi

# Fix all json extra data errors
for j in ${TempSubjectDir}/BIDS_unprocessed/${SUB}/${VISIT}/*/*.json; do
    mv ${j} ${j}.temp
    # print only the valid part of the json back into the original json
    jq '.' ${j}.temp > ${j}
    rm ${j}.temp
done


rm ${TempSubjectDir}/BIDS_unprocessed/${SUB}/${VISIT}/fmap/*dir-both* 2> /dev/null || true

# rename EventRelatedInformation
srcdata_dir=${TempSubjectDir}/BIDS_unprocessed/sourcedata/${SUB}/${VISIT}/func
if ls ${TempSubjectDir}/DCMs/${SUB}/${VISIT}/func/*EventRelatedInformation.txt > /dev/null 2>&1; then
    echo `date`" :COPY AND RENAME SOURCE DATA"
    mkdir -p ${srcdata_dir}
    MID_evs=`ls ${TempSubjectDir}/DCMs/${SUB}/${VISIT}/func/*MID*EventRelatedInformation.txt 2>/dev/null`
    SST_evs=`ls ${TempSubjectDir}/DCMs/${SUB}/${VISIT}/func/*SST*EventRelatedInformation.txt 2>/dev/null`
    nBack_evs=`ls ${TempSubjectDir}/DCMs/${SUB}/${VISIT}/func/*nBack*EventRelatedInformation.txt 2>/dev/null`
    echo ${MID_evs}
    echo ${SST_evs}
    echo ${nBack_evs}
    if [ `echo ${MID_evs} | wc -w` -eq 2 ]; then
        i=1
        for ev in ${MID_evs}; do
            cp ${ev} ${srcdata_dir}/${SUB}_${VISIT}_task-MID_run-0${i}_bold_EventRelatedInformation.txt
            ((i++))
        done
    fi
    if [ `echo ${SST_evs} | wc -w` -eq 2 ]; then
        i=1
        for ev in ${SST_evs}; do
            cp ${ev} ${srcdata_dir}/${SUB}_${VISIT}_task-SST_run-0${i}_bold_EventRelatedInformation.txt
            ((i++))
        done
    fi
    if [ `echo ${nBack_evs} | wc -w` -eq 2 ]; then
        i=1
        for ev in ${nBack_evs}; do
            cp ${ev} ${srcdata_dir}/${SUB}_${VISIT}_task-nback_run-0${i}_bold_EventRelatedInformation.txt
            ((i++))
        done
    fi
fi

echo `date`" :COPYING BIDS DATA BACK: ${ROOT_BIDSINPUT}"

TEMPBIDSINPUT=${TempSubjectDir}/BIDS_unprocessed/${SUB}
if [ -d ${TEMPBIDSINPUT} ] ; then
    echo `date`" :CHMOD BIDS INPUT"
    chmod -R g+rw "${TEMPBIDSINPUT}" || true
    echo `date`" :COPY BIDS INPUT"
    mkdir -p ${ROOT_BIDSINPUT}
    cp -r ${TEMPBIDSINPUT} ${ROOT_BIDSINPUT}/
fi

ROOT_SRCDATA=${ROOT_BIDSINPUT}/sourcedata
TEMPSRCDATA=${TempSubjectDir}/BIDS_unprocessed/sourcedata/${SUB}
mkdir -p ${TEMPSRCDATA}
cp -r ${TempSubjectDir}/*.tgz $TEMPSRCDATA/ # Copying raw tgz to sourcedata.
if [ -d ${TEMPSRCDATA} ] ; then
    echo `date`" :CHMOD SOURCEDATA"
    chmod -R g+rw "${TEMPSRCDATA}" || true
    echo `date`" :COPY SOURCEDATA"
    mkdir -p ${ROOT_SRCDATA}
    cp -r ${TEMPSRCDATA} ${ROOT_SRCDATA}/
fi

echo `date`" :REMOVING TEMP FILES"
rm -rf ${TempSubjectDir} # This is much needed if user's disk quota is limited, otherwise it will exceed their allocation.


echo `date`" :UNPACKING AND SETUP COMPLETE: ${SUB}/${VISIT}"
