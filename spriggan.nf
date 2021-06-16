#!/usr/bin/env nextflow

//Description:
//Author: Kelsey Florek and Abigail Shockey
//email: kelsey.florek@slh.wisc.edu, abigail.shockey@slh.wisc.edu

//setup channel to read in and pair the fastq files
Channel
    .fromFilePairs( "${params.reads}/*{R1,R2,_1,_2}*.{fastq,fq}.gz", size: 2 )
    .ifEmpty { exit 1, "Cannot find any reads matching: ${params.reads} Path must not end with /" }
    .set { raw_reads }

//Preprocess reads - change names
process preProcess {
  input:
  set val(name), file(reads) from raw_reads

  output:
  tuple name, file(outfiles) into read_files_fastqc, read_files_trimming

  script:
  if(params.name_split_on!=""){
    name = name.split(params.name_split_on)[0]
    outfiles = ["${name}_R1.fastq.gz","${name}_R2.fastq.gz"]
    """
    mv ${reads[0]} ${name}_R1.fastq.gz
    mv ${reads[1]} ${name}_R2.fastq.gz
    """
  }else{
    outfiles = reads
    """
    """
  }
}

//FastQC
process fastqc {
  tag "$name"
  publishDir "${params.outdir}/logs/fastqc", mode: 'copy',saveAs: {filename -> filename.indexOf(".zip") > 0 ? "zips/$filename" : "$filename"}

  input:
  set val(name), file(reads) from read_files_fastqc

  output:
  file("*_fastqc.{zip,html}") into fastqc_results

  script:
  """
  fastqc -q  ${reads}
  """
}

//Trim reads and remove PhiX contamination
process clean_reads {
  tag "$name"
  publishDir "${params.outdir}/logs/cleanedreads", mode: 'copy',pattern:"*.stats.txt"

  input:
  set val(name), file(reads) from read_files_trimming

  output:
  tuple name, file("${name}{_1,_2}.clean.fastq.gz") into cleaned_reads_shovill
  file("${name}.phix.stats.txt") into phix_cleanning_stats
  file("${name}.adapters.stats.txt") into adapter_cleanning_stats

  script:
  """
  bbduk.sh in1=${reads[0]} in2=${reads[1]} out1=${name}.trimmed_1.fastq.gz out2=${name}.trimmed_2.fastq.gz qtrim=window,${params.windowsize} trimq=${params.qualitytrimscore} minlength=${params.minlength} tbo tbe
  repair.sh in1=${name}.trimmed_1.fastq.gz in2=${name}.trimmed_2.fastq.gz out1=${name}.paired_1.fastq.gz out2=${name}.paired_2.fastq.gz
  bbduk.sh in1=${name}.paired_1.fastq.gz in2=${name}.paired_2.fastq.gz out1=${name}.rmadpt_1.fastq.gz out2=${name}.rmadpt_2.fastq.gz ref=/bbmap/resources/adapters.fa stats=${name}.adapters.stats.txt ktrim=r k=23 mink=11 hdist=1 tpe tbo
  bbduk.sh in1=${name}.rmadpt_1.fastq.gz in2=${name}.rmadpt_2.fastq.gz out1=${name}_1.clean.fastq.gz out2=${name}_2.clean.fastq.gz outm=${name}.matched_phix.fq ref=/bbmap/resources/phix174_ill.ref.fa.gz k=31 hdist=1 stats=${name}.phix.stats.txt
  """
}

//Assemble trimmed reads with Shovill and map reads back to assembly
process shovill {
  errorStrategy 'ignore'
  tag "$name"
  publishDir "${params.outdir}/results/assembled", mode: 'copy',pattern:"*.fa"
  publishDir "${params.outdir}/results/alignments", mode: 'copy',pattern:"*.sam"

  input:
  set val(name), file(reads) from cleaned_reads_shovill

  output:
  tuple name, file("${name}.contigs.fa") into assembled_genomes_quality, assembled_genomes_annotation, assembled_genomes_ar, assembled_genomes_mash, assembled_genomes_mlst
  tuple name, file("${name}.sam") into sam_files

  script:
  """
  shovill --cpus ${task.cpus} --ram ${task.memory} --outdir ./output --R1 ${reads[0]} --R2 ${reads[1]} --force
  mv ./output/contigs.fa ${name}.contigs.fa
  bwa index ${name}.contigs.fa
  bwa mem ${name}.contigs.fa ${reads[0]} ${reads[1]} > ${name}.sam
  """
}

//Index and sort bam file then calculate coverage
process samtools {
  tag "$name"

  publishDir "${params.outdir}/results/alignments", mode: 'copy', pattern:"*.bam"
  publishDir "${params.outdir}/results/coverage", mode: 'copy', pattern:"*_depth.tsv*"

  input:
  set val(name), file(sam) from sam_files

  output:
  file("${name}_depth.tsv") into cov_files

  shell:
  """
  samtools view -S -b ${name}.sam > ${name}.bam
  samtools sort ${name}.bam > ${name}.sorted.bam
  samtools index ${name}.sorted.bam
  samtools depth -a ${name}.sorted.bam > ${name}_depth.tsv
  """
}

//Calculate median coverage
process coverage_stats {
  publishDir "${params.outdir}/results/coverage", mode: 'copy'

  input:
  file(cov) from cov_files.collect()

  output:
  file('coverage_stats.txt')

  script:
  '''
  #!/usr/bin/env python3
  import glob
  import os
  from numpy import median
  from numpy import average

  results = []

  files = glob.glob("*_depth.tsv*")
  for file in files:
    nums = []
    sid = os.path.basename(file).split('_')[0]
    with open(file,'r') as inFile:
      for line in inFile:
        nums.append(int(line.strip().split()[2]))
      med = median(nums)
      avg = average(nums)
      results.append(f"{sid}\\t{med}\\t{avg}\\n")

  with open('coverage_stats.txt', 'w') as outFile:
    outFile.write("Sample\\tMedian Coverage\\tAverage Coverage\\n")
    for result in results:
      outFile.write(result)
  '''
}

//Assembly Quality Report
process quast {
  errorStrategy 'ignore'
  publishDir "${params.outdir}/logs/quast",mode:'copy'

  input:
  set val(name), file(assembly) from assembled_genomes_quality

  output:
  file("${name}.quast.tsv") into quast_report

  script:
  """
  quast.py ${assembly} -o .
  mv report.txt ${name}.quast.tsv
  """
}

//Find AR genes with amrfinder+
process amrfinder {
  tag "$name"
  publishDir "${params.outdir}/results/amrfinder",mode:'copy'

  input:
  set val(name), file(assembly) from assembled_genomes_ar

  output:
  file("${name}.tsv") into ar_predictions

  script:
  """
  amrfinder -n ${assembly} -o ${name}.tsv
  """
}

//Summarize amrfinder+ results
process amrfinder_summary {
  tag "$name"
  publishDir "${params.outdir}/results",mode:'copy'

  input:
  file(predictions) from ar_predictions.collect()

  output:
  file("ar_predictions.tsv") into ar_tsv

  script:
  """
  #!/usr/bin/env python3
  import os
  import glob
  import pandas as pd

  files = glob.glob("*.tsv")
  dfs = []
  for file in files:
      sample_id = os.path.basename(file).split(".")[0]
      print(sample_id)
      df = pd.read_csv(file, header=0, delimiter="\\t")
      df.columns=df.columns.str.replace(' ', '_')
      print(df)
      df = df.assign(Sample=sample_id)
      df = df[['Sample','Gene_symbol','%_Coverage_of_reference_sequence','%_Identity_to_reference_sequence']]
      df = df.rename(columns={'%_Coverage_of_reference_sequence':'Coverage','%_Identity_to_reference_sequence':'Identity','Gene_symbol':'Gene'})
      dfs.append(df)

  concat = pd.concat(dfs)
  concat.to_csv('ar_predictions.tsv',sep='\\t', index=False, header=True, na_rep='NaN')
  """
}

process mlst {
  errorStrategy 'ignore'
  publishDir "${params.outdir}/results",mode:'copy'

  input:
  file(assemblies) from assembled_genomes_mlst.collect()

  output:
  file("mlst.tsv") into mlst_results

  script:
  """
  mlst --nopath *.fa > mlst.tsv
  """
}

process mlst_formatting {
  errorStrategy 'ignore'
  publishDir "${params.outdir}/results",mode:'copy'

  input:
  file(mlst) from mlst_results

  output:
  file("mlst_formatted.tsv")

  script:
  """
  #!/usr/bin/env python3
  import csv

  string_map = {}

  with open('mlst.tsv','r') as csvfile:
    dialect = csv.Sniffer().sniff(csvfile.read(1024))
    csvfile.seek(0)
    reader = csv.reader(csvfile,dialect,delimiter='\t')
    for row in reader:
      id_string = row[0]
      sp_string = row[1]
      st_string = row[2]
      string_map[id_string] = [sp_string,st_string]

  mlst = []
  for key in string_map:
    id = key
    id = id.replace('.contigs.fa','')
    species = string_map[key][0]
    st = string_map[key][1]
    if species == 'abaumannii':
        st = 'PubMLST ST' + str(st) + ' (Oxford)'
    if species == 'abaumannii_2':
        st = 'PubMLST ST' + str(st) + ' (Pasteur)'
    else:
        st = 'PubMLST ST' + str(st)
    if '-' in st:
        st = 'NA'
    mlst.append(f'{id}\\t{st}\\n')

  with open('mlst_formatted.tsv','w') as outFile:
    outFile.write('Sample\\tMLST Scheme\\n')
    for scheme in mlst:
      outFile.write(scheme)

  """
}
