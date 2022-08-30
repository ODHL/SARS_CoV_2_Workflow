output_dir=$1
project_name_full=$2
pipeline_config=$3
cecret_config=$4
multiqc_config=$5
date_stamp=$6
pipeline_log=$7
qc_flag=$8
partial_flag=$9

#########################################################
# functions
#########################################################
parse_yaml() {
   local prefix=$2
   local s='[[:space:]]*' w='[a-zA-Z0-9_]*' fs=$(echo @|tr @ '\034')
   sed -ne "s|^\($s\)\($w\)$s:$s\"\(.*\)\"$s\$|\1$fs\2$fs\3|p" \
-e "s|^\($s\)\($w\)$s:$s\(.*\)$s\$|\1$fs\2$fs\3|p"  $1 |
   awk -F$fs '{
      indent = length($1)/2;
      vname[indent] = $2;
      for (i in vname) {if (i > indent) {delete vname[i]}}
      if (length($3) > 0) {
 vn=""; for (i=0; i<indent; i++) {vn=(vn)(vname[i])("_")}
 printf("%s%s%s=\"%s\"\n", "'$prefix'",vn, $2, $3);
      }
   }'
}

#########################################################
# Set dirs, files, args
#########################################################
# read in config
eval $(parse_yaml ${pipeline_config} "config_")
final_results=$analysis_dir/final_results_$date_stamp.csv
pangolin_id=$config_pangolin_version
nextclade_id=$config_nextclade_version

# set dir
log_dir=$output_dir/logs
cecret_dir=$output_dir/cecret
fastq_dir=$output_dir/fastq

analysis_dir=$output_dir/analysis
intermed_dir=$analysis_dir/intermed
fasta_dir=$analysis_dir/fasta

qc_dir=$output_dir/qc
qcreport_dir=$qc_dir/covid19_qcreport

tmp_dir=$output_dir/tmp
fastqc_dir=$tmp_dir/fastqc

# set files
merged_samples=$log_dir/completed_samples.txt
merged_cecret=$intermed_dir/cecret_results.txt
merged_nextclade=$intermed_dir/nextclade_results.csv
merged_pangolin=$intermed_dir/lineage_report.csv
merged_summary=$intermed_dir/cecret_summary.csv
merged_fragment=$qc_dir/fragment.txt

sample_id_file=$log_dir/sample_ids.txt

fragement_plot=$qc_dir/fragment_plot.png

final_nextclade=$intermed_dir/final_nextclade.txt
final_pangolin=$intermed_dir/final_pangolin.txt
final_cecret=$intermed_dir/final_cecret.txt
final_results=$analysis_dir/final_results_$date_stamp.csv

# Convert user selected numbers to complete software names
pangolin_version=`cat config/software_versions.txt | awk '$1 ~ /pangolin/' | awk -v pid="$pangolin_id" '$2 ~ pid' | awk '{ print $3 }'`
nextclade_version=`cat config/software_versions.txt | awk '$1 ~ /nextclade/' | awk -v pid="$nextclade_id" '$2 ~ pid' | awk '{ print $3 }'`
if [[ "$pangolin_version" == "" ]] | [[ "$nextclade_version" == "" ]]; then
    echo "Choose the correct version of PANGOLIN/NEXTCLADE in /project/logs/config_pipeline.yaml"
    echo "PANGOLIN: $pangolin_version"
    echo "NEXTCLADE: $nextclade_version"
    exit
fi

#############################################################################################
# CECRET UPDATES
#############################################################################################
# Update CECRET config dependent on user input
## update corrected software versions cecret config
old_cmd="pangolin_container = 'staphb\/pangolin:latest'"
new_cmd="pangolin_container = 'staphb\/pangolin:$pangolin_version'"
sed -i "s/$old_cmd/$new_cmd/" $cecret_config

old_cmd="nextclade_container = 'nextstrain\/nextclade:latest'"
new_cmd="nextclade_container = 'nextstrain\/nextclade:$nextclade_version'"
sed -i "s/$old_cmd/$new_cmd/" $cecret_config

## update config if QC is not needed
if [[ "$qc_flag" == "N" ]]; then
	old_cmd="params.samtools_stats = true"
    new_cmd="params.samtools_stats = false"
	sed -i "s/$old_cmd/$new_cmd/" $cecret_config

	old_cmd="params.fastqc = true"
	new_cmd="params.fastqc = false"
    sed -i "s/$old_cmd/$new_cmd/" $cecret_config
fi

## check reference files exist in reference dir, update reference files
# for each reference file find matching output in config_pipeline
# remove refence file name and leave reference value
# create full path to reference value
# check file existence
# escape / with \/ for sed replacement
# replace the cecret config file with the reference selected
reference_list=("reference_genome" "gff_file" "primer_bed" "amplicon_bed")
for ref_file in ${reference_list[@]}; do
    ref_line=$(cat "${pipeline_config}" | grep $ref_file)
    ref_path=`echo $config_reference_dir/${ref_line/"$ref_file": /} | tr -d '"'`
    if [[ -f $ref_path ]]; then
        old_cmd="params.$ref_file = \"TBD\""
        new_cmd="params.$ref_file = \"$ref_path\""
        new_cmd=$(echo $new_cmd | sed 's/\//\\\//g')
        sed -i "s/$old_cmd/$new_cmd/" $cecret_config
    else
        echo "Reference file ($ref_file) is missing from $ref_path. Please update $pipeline_config"
        exit 1
    fi
done

# replace the primer set used
old_cmd="params.primer_set = 'TBD'"
new_cmd="params.primer_set = \'$config_primer_set\'"
sed -i "s/$old_cmd/$new_cmd/" $cecret_config

#############################################################################################
# LOG INFO TO CONFIG
#############################################################################################
echo "------------------------------------------------------------------------"
echo "------------------------------------------------------------------------" >> $pipeline_log
echo "*** CONFIG INFORMATION ***"
echo "*** CONFIG INFORMATION ***" >> $pipeline_log
echo "Cecret config: $cecret_config" >> $pipeline_log
echo "Sequence run date: $date_stamp" >> $pipeline_log
echo "Analysis date:" `date` >> $pipeline_log
echo "Pangolin version: $pangolin_version" >> $pipeline_log
echo "Pangolin version: $pangolin_version"
echo "Nexclade version: $nextclade_version" >> $pipeline_log
echo "Nexclade version: $nextclade_version"
cat "$cecret_config" | grep "params.reference_genome" >> $pipeline_log
cat "$cecret_config" | grep "params.gff_file" >> $pipeline_log
cat "$cecret_config" | grep "params.primer_bed" >> $pipeline_log
cat "$cecret_config" | grep "params.amplicon_bed" >> $pipeline_log
echo "------------------------------------------------------------------------" >> $pipeline_log

echo "------------------------------------------------------------------------"
echo "------------------------------------------------------------------------" >> $pipeline_log
echo "*** STARTING CECRET PIPELINE ***"
echo "*** STARTING CECRET PIPELINE ***" >> $pipeline_log
echo "Starting time: `date`" >> $pipeline_log
echo "Starting space: `df . | sed -n '2 p' | awk '{print $5}'`" >> $pipeline_log

#############################################################################################
# Project Downloads
#############################################################################################	
#get project id
project_id=`$config_basespace_cmd list projects --filter-term="${project_name_full}" | sed -n '4 p' | awk '{split($0,a,"|"); print a[3]}' | sed 's/ //g'`
	
# if the project name does not match completely with basespace an ID number will not be found
# display all available ID's to re-run project	
if [ -z "$project_id" ] && [ "$partial_flag" != "Y" ]; then
	echo "The project id was not found from $project_name_full. Review available project names below and try again"
	exit
fi

# if a QC report is to be created (qc_flag=Y) then download the necessary project analysis files
# if it is not needed, and a full run is being completed
# then download smaller json files to determine all sample ids in project
if [[ "$qc_flag" == "Y" ]]; then
	echo "--Downloading analysis files (this may take a few minutes to begin)"
	echo "--Downloading analysis files" >> $pipeline_log
	echo "---Starting time: `date`" >> $pipeline_log
	$config_basespace_cmd download project --quiet -i $project_id -o "$tmp_dir" --extension=zip		echo "---Ending time: `date`" >> $pipeline_log
    echo "---Ending space: `df . | sed -n '2 p' | awk '{print $5}'`" >> $pipeline_log
elif [[ "$partial_flag" == "N" ]]; then
	echo "--Downloading sample list (this may take a few minutes to begin)"
	echo "--Downloading sample list" >> $pipeline_log
	echo "---Starting time: `date`" >> $pipeline_log
	$config_basespace_cmd download project --quiet -i $project_id -o "$tmp_dir" --extension=json
    echo "---Ending time: `date`" >> $pipeline_log
    echo "---Ending space: `df . | sed -n '2 p' | awk '{print $5}'`" >> $pipeline_log
fi

# remove scrubbed files, as they are zipped FASTQS and will be downloaded in batches later
rm -r $tmp_dir/Scrubbed*	

#############################################################################################
# Batching
#############################################################################################
#break project into batches of N = batch_limit set above, create manifests for each
sample_count=1
batch_count=0

# All project ID's download from BASESPACE will be processed into batches
# Batch count depends on user input from pipeline_config.yaml
# If a partial run is being performed, a batch file is required as user input
echo "--Creating batch files"
if [[ "$partial_flag" == "N" ]]; then
    #create sample_id file - grab all files in dir, split by _, exclude noro- file names
    ls $tmp_dir | cut -f1 -d "_" | grep "202[0-9]." | grep -v "noro.*" > $sample_id_file

    #read in text file with all project id's
    IFS=$'\n' read -d '' -r -a sample_list < $sample_id_file
            
    for sample_id in ${sample_list[@]}; do
        #if the sample count is 1 then create new batch
        if [[ "$sample_count" -eq 1 ]]; then
            batch_count=$((batch_count+1))

            #remove previous versions of batch log
            if [[ "$batch_count" -gt 9 ]]; then batch_name=$batch_count; else batch_name=0${batch_count}; fi
        
            #remove previous versions of batch log
            batch_manifest=$log_dir/batch_${batch_name}.txt
            if [[ -f $batch_manifest ]]; then rm $batch_manifest; fi
        
            #create batch manifest
            touch $log_dir/batch_${batch_name}.txt
        fi
            
        #set batch manifest
        batch_manifest=$log_dir/batch_${batch_name}.txt
                
        #echo sample id to the batch
        echo ${sample_id} >> $batch_manifest
                
        #increase sample counter
        ((sample_count+=1))
            
        #reset counter when equal to batch_limit
        if [[ "$sample_count" -gt "$config_batch_limit" ]]; then sample_count=1 fi
    done
    
    #gather final count
	sample_count=${#sample_list[@]}
	batch_min=1
else
	# Partial runs allow the user to submit pre-defined batch files with samples
	# Determine how many batch files are to be used and total number of samples within files
	batch_min=`ls $log_dir/batch* | cut -f2 -d"_" | cut -f1 -d "." | sed "s/$0//" | sort | head -n1`
	batch_count=`ls $log_dir/batch* | cut -f2 -d"_" | cut -f1 -d "." | sed "s/$0//" | sort | tail -n1`
	tmp_count=0

	for (( batch_id=$batch_min; batch_id<=$batch_count; batch_id++ )); do
        if [[ "$batch_id" -gt 9 ]]; then batch_name=$batch_id; else batch_name=0${batch_id}; fi
        tmp_count=`wc -l < ${log_dir}/batch_${batch_name}.txt`
        sample_count=`expr $tmp_count + $sample_count`
	done

	if [[ "$sample_count" -eq 0 ]]; then
        echo "At least one batch file is required for partial runs. Please create $log_dir/batch_01.txt"
        exit
	fi
fi
	
# For testing scenarios two batches of two samples will be run
# Take the first four samples and remove all other batches
if [[ "$testing_flag" == "Y" ]]; then
		
	for (( batch_id=1; batch_id<=$batch_count; batch_id++ )); do
        batch_manifest=$log_dir/batch_0$batch_id.txt
        
        if [[ "$batch_id" == 1 ]] || [[ "$batch_id" == 2 ]]; then
            head -2 $batch_manifest > tmp.txt
            mv tmp.txt $batch_manifest
        else
            rm $batch_manifest
        fi
	done
		
	# set new batch count
	batch_count=2
	sample_count=4
fi
       
#log
echo "--A total of $sample_count samples will be processed in $batch_count batches, with a maximum of $config_batch_limit samples per batch"
echo "--A total of $sample_count samples will be processed in $batch_count batches, with a maximum of $config_batch_limit samples per batch" >> $pipeline_log

#merge all batched outputs
touch $merged_samples
touch $merged_cecret
touch $merged_nextclade
touch $merged_pangolin
touch $merged_summary
touch $merged_fragment

#############################################################################################
# Analysis
#############################################################################################
#log
echo "--Processing batches:"
echo "--Processing batches:" >> $pipeline_log

#for each batch
for (( batch_id=$batch_min; batch_id<=$batch_count; batch_id++ )); do

	# set batch name
	if [[ "$batch_id" -gt 9 ]]; then batch_name=$batch_id; else batch_name=0${batch_id}; fi
		
	#set manifest
	batch_manifest=$log_dir/batch_${batch_name}.txt

	fastq_batch_dir=$fastq_dir/batch_$batch_id
	cecret_batch_dir=$cecret_dir/batch_$batch_id
	if [[ ! -d $fastq_batch_dir ]]; then mkdir $fastq_batch_dir; fi
	if [[ ! -d $cecret_batch_dir ]]; then mkdir $cecret_batch_dir; fi

	#read text file
	IFS=$'\n' read -d '' -r -a sample_list < $batch_manifest

	#log
	# print number of lines in file without file name "<"
	n_samples=`wc -l < $batch_manifest`
	echo "----Batch_$batch_id ($n_samples samples)"
	echo "----Batch_$batch_id ($n_samples samples)" >> $pipeline_log


	#run per sample, download files
	for sample_id in ${sample_list[@]}; do		
       $config_basespace_cmd download biosample --quiet -n "${sample_id}" -o $fastq_dir

    	# move files to batch fasta dir
        #rm -r $fastq_dir/*L001*
        mv $fastq_dir/*${sample_id}*/*fastq.gz $fastq_batch_dir
    
        # If generating a QC report, BASESPACE files need to be unzipped
        # and selected files moved for downstream analysis
        if [[ "$qc_flag" == "Y" ]]; then

            #make sample tmp_dir: tmp_dir/sample_id
            if [[ ! -d "$tmp_dir/${sample_id}" ]]; then mkdir $tmp_dir/${sample_id}; fi

            #unzip analysis file downloaded from DRAGEN to sample tmp dir - used in QC
            unzip -o -q $tmp_dir/${sample_id}_[0-9]*/*_all_output_files.zip -d $tmp_dir/${sample_id}

            #move needed files to general tmp dir
            mv $tmp_dir/${sample_id}/ma/* $tmp_dir/unzipped
    	
            #remove sample tmp dir, downloaded proj dir
            rm -r --force $tmp_dir/${sample_id}
        fi

        # remove downloaded tmp dir
        rm -r --force $tmp_dir/${sample_id}_[0-9]*/
	done

	#log
	echo "------CECRET"
	echo "------CECRET" >> $pipeline_log
	echo "-------Starting time: `date`" >> $pipeline_log
    echo "-------Starting space: `df . | sed -n '2 p' | awk '{print $5}'`" >> $pipeline_log
    
	#run cecret
	staphb-wf cecret $fastq_batch_dir --reads_type paired --config $cecret_config --output $cecret_batch_dir

    echo "-------Ending time: `date`" >> $pipeline_log
	echo "-------Ending space: `df . | sed -n '2 p' | awk '{print $5}'`" >> $pipeline_log

	#############################################################################################
	# Clean-up
	#############################################################################################
	#add to master sample log
	cat $log_dir/batch_${batch_name}.txt >> $merged_samples
	
	#add to  master cecret results
	cat $cecret_batch_dir/cecret_results.txt >> $merged_cecret

	#add to master nextclade results
	cat $cecret_batch_dir/nextclade/nextclade.csv >> $merged_nextclade

    #add to master pangolin results
	cat $cecret_batch_dir/pangolin/lineage_report.csv >> $merged_pangolin

	#add to master cecret summary
	cat $cecret_batch_dir/summary/combined_summary.csv >> $merged_summary

	# If QC report is being created, generate stats on fragment length
    if [[ "$qc_flag" == "Y" ]]; then
        for f in $cecret_batch_dir/samtools_stats/aligned/*.stats.txt; do
            frag_length=`cat $f | grep "average length" | awk '{print $4}'`
            file_name=`echo $f | rev | cut -f1 -d "/" | rev`
            file_name=${file_name%.stats*}
            echo -e "${file_name}\t${frag_length}\t${batch_id}" >> $merged_fragment
        done
	fi

	# move FASTQC files
	if [[ "$qc_flag" == "Y" ]]; then mv $cecret_batch_dir/fastqc/* $fastqc_dir; fi
		
	# move FASTA files
	mv $cecret_batch_dir/consensus/* $fasta_dir/not_uploaded

	#remove intermediate files
	sudo rm -r --force work
	sudo rm -r --force $cecret_batch_dir
	sudo rm -r --force $fastq_batch_dir

	# changes in software adds project name to some sample_ids. In order to ensure consistency throughout naming and for downstream
	# uploading, project name should be removed.
	## remove from the fasta files header, names
	for f in $fasta_dir/not_uploaded/*; do
        # remove projectid from header
        sed -i "s/$project_id//g" $f

        # rename files
        new_id=`echo $f | awk -v p_id=$project_id '{ gsub(p_id,"",$1) ; print }'`
        if [[ $f != $new_id ]]; then mv $f $new_id; fi
	done
		
	## remove from intermediate output files
	for f in $intermed_dir/*; do
        # remove projectid
        sed -i "s/$project_id//g" $f
	done

	## remove from FASTQC,unzipped file names
    for f in $fastqc_dir/*; do
        # rename files
        new_id=`echo $f | awk -v p_id=$project_id '{ gsub(p_id,"",$1) ; print }'`
        if [[ $f != $new_id ]]; then mv $f $new_id; fi
	done
		
    for f in $tmp_dir/unzipped/*; do
        # rename files
        new_id=`echo $f | awk -v p_id=$project_id '{ gsub(p_id,"",$1) ; print }'`
        if [[ $f != $new_id ]]; then mv $f $new_id; fi
	done
done

#############################################################################################
# Create reports
#############################################################################################
if [[ "$qc_flag" == "Y" ]]; then
	#log
	echo "--Creating QC Report"
    echo "--Creating QC Report" >> $pipeline_log
	echo "---Starting time: `date`" >> $pipeline_log
	echo "---Starting space: `df . | sed -n '2 p' | awk '{print $5}'`" >> $pipeline_log

	#-d -dd 1 adds dir name to sample name
	multiqc -f -v \
    -c $multiqc_config \
	$fastqc_dir \
	$tmp_dir/unzipped \
	-o $qcreport_dir
	
	#create fragment plot
	python scripts/fragment_plots.py $merged_fragment $fragement_plot
else
	rm -r $qc_dir
fi 
	
# merge batch outputs into intermediate files
# join contents of cecret and nextclade into final output table	
# from nextclade: sampleid, AAsubstitutions
cat $merged_nextclade | sort | uniq -u | awk -F';' '{print $1,$27}' | \
awk '{ gsub(/Consensus_/,"",$1) gsub(/\.consensus_[a-z0-9._]*/,"",$1); print }'| awk -v q="\"" '{ print $1","q $2 q }' | awk '{ gsub(/"/,"",$2); print }' > $final_nextclade

# from pangloin: sampleid, pangolin_status, lineage
cat $merged_pangolin | sort | uniq -u |  awk -F',' '{print $1,$12,$2}'| \
awk '{ gsub(/Consensus_/,"",$1) gsub(/\.consensus_[a-z0-9._]*/,"",$1); print }' | awk '{print $1","$2","$3}' > $final_pangolin
	
# from cecret: sample_id,pangolin_status,nextclade_clade,pangolin_lineage,pangolin_scorpio
# cecret results change col positions depending on whether or not there are conflicts
awk -F'\t' -vcols=sample_id,pangolin_status,nextclade_clade,pangolin_lineage,pangolin_scorpio_call '(NR==1){n=split(cols,cs,",");for(c=1;c<=n;c++){for(i=1;i<=NF;i++)if($(i)==cs[c])ci[c]=i}}{for(i=1;i<=n;i++)printf "%s" FS,$(ci[i]);printf "\n"}' $merged_cecret | sed -s "s/\t/,/g" | sed 's/.$//' | grep -v "sample" >> $final_cecret

# create final results
echo "sample_id,pango_qc,nextclade_clade,pangolin_lineage,pangolin_scorpio,aa_substitutions" > $final_results
join <(sort $final_cecret) <(sort $final_nextclade) -t $',' >> $final_results

#remove all proj files
rm -r --force $tmp_dir
rm -r --force $cecret_dir
rm -r --force $fastq_dir
rm -r --force $fastqc_dir

echo "Ending time: `date`" >> $pipeline_log
echo "Ending space: `df . | sed -n '2 p' | awk '{print $5}'`" >> $pipeline_log
echo "*** CECRET PIPELINE COMPLETE ***"
echo "*** CECRET PIPELINE COMPLETE ***" >> $pipeline_log
echo "------------------------------------------------------------------------"
echo "------------------------------------------------------------------------" >> $pipeline_log