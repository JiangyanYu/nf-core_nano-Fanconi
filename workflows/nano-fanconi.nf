/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    VALIDATE INPUTS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

def summary_params = NfcoreSchema.paramsSummaryMap(workflow, params)

// Validate input parameters
WorkflowNanofanconi.initialise(params, log)

// TODO nf-core: Add all file path parameters for the pipeline to the list below
// Check input path parameters to see if they exist
def checkPathParamList = [ params.input, params.multiqc_config, params.fasta ]
for (param in checkPathParamList) { if (param) { file(param, checkIfExists: true) } }

// Check mandatory parameters
if (params.input) { ch_input = file(params.input) } else { exit 1, 'Input samplesheet not specified!' }
/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    CONFIG FILES
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

 ch_multiqc_config          = Channel.fromPath("$projectDir/assets/multiqc_config.yml", checkIfExists: true)
 ch_multiqc_custom_config   = params.multiqc_config ? Channel.fromPath( params.multiqc_config, checkIfExists: true ) : Channel.empty()
 ch_multiqc_logo            = params.multiqc_logo   ? Channel.fromPath( params.multiqc_logo, checkIfExists: true ) : Channel.empty()
 ch_multiqc_custom_methods_description = params.multiqc_methods_description ? file(params.multiqc_methods_description, checkIfExists: true) : file("$projectDir/assets/methods_description_template.yml", checkIfExists: true)

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT LOCAL MODULES/SUBWORKFLOWS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

//
// SUBWORKFLOW: Consisting of a mix of local and nf-core/modules
//
include { INPUT_CHECK } from '../subworkflows/local/input_check'

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT NF-CORE MODULES/SUBWORKFLOWS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

//
// MODULE: Installed directly from nf-core/modules
//

include { FAST5_TO_POD5                                 } from '../modules/local/FAST5_TO_POD5'
include { DORADO_BASECALLER                             } from '../modules/local/DORADO_BASECALLER'
include { MERGE_BASECALL as MERGE_BASECALL_ID           } from '../modules/local/MERGE_BASECALL'
include { MERGE_BASECALL as MERGE_BASECALL_SAMPLE       } from '../modules/local/MERGE_BASECALL'
include { DORADO_BASECALL_SUMMARY                       } from '../modules/local/DORADO_BASECALL_SUMMARY'
include { PYCOQC                                        } from '../modules/local/PYCOQC'
include { DORADO_ALIGNER                                } from '../modules/local/DORADO_ALIGNER'
include { SAMTOOLS_SORT                                 } from '../modules/local/SAMTOOLS_SORT'
include { SAMTOOLS_INDEX                                } from '../modules/local/SAMTOOLS_INDEX'
include { CUSTOM_DUMPSOFTWAREVERSIONS                   } from '../modules/nf-core/custom/dumpsoftwareversions/main'
include { MULTIQC                                       } from '../modules/local/MULTIQC'
include { SAMTOOLS_STATS                                } from '../modules/local/SAMTOOLS_STATS.nf'
// include { WHATSHAP                                      } from '../modules/local/WHATSHAP.nf'
// include { PEPPER                                        } from '../modules/local/PEPPER'
// include { MOSDEPTH                                      } from '../modules/local/MOSDEPTH'
// include { MODKIT                                        } from '../modules/local/MODKIT'
// include { MODKIT_TO_BW                                  } from '../modules/local/MODKIT_TO_BW'


/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    RUN MAIN WORKFLOW
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

// Info required for completion email and summary
def multiqc_report = []

workflow NANOFANCONI {

    ch_versions = Channel.empty()
    
process CHECK_WGET {
    label 'process_medium'

    input:
    val(meta), path(fast5)

    output:
    path("logs/*")

    script:
    """
    echo "Inside script block, checking wget installation..."

    # Debugging info to check working directory
    echo "Working directory: \${task.workDir}"

    # Check if wget is installed and write output to log
    echo "Checking if wget is installed..." > \${task.workDir}/logs/check_log.txt

    if ! command -v wget &> /dev/null; then
        echo "wget could not be found, please install it." >> \${task.workDir}/logs/check_log.txt
        exit 1
    else
        echo "wget is installed and ready to use." >> \${task.workDir}/logs/check_log.txt
    fi

    # Check file download from URL
    echo "Attempting to download from: https://github.com/JiangyanYu/nf-core_nano-fanconi/blob/main/assets/056c66f4-e2fd-483a-b058-ff44843cf8a3.fast5" >> \${task.workDir}/logs/check_log.txt
    wget -v "https://github.com/JiangyanYu/nf-core_nano-fanconi/raw/main/assets/056c66f4-e2fd-483a-b058-ff44843cf8a3.fast5" -O \${task.workDir}/downloads/056c66f4.fast5 >> \${task.workDir}/logs/check_log.txt 2>&1
    """
}

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    NANOFANCONI: input check
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

    //
    // SUBWORKFLOW: Read in samplesheet, validate and stage input files
    //
    INPUT_CHECK (
        ch_input
    )
    ch_versions = ch_versions.mix(INPUT_CHECK.out.versions)
    ch_phased_vcf = INPUT_CHECK.out.reads.map{ meta, files -> [[sample: meta.sample],meta.fast5_path, meta.vcf, meta.vcf_tbi] }.dump(tag: "ch_phased_vcf")

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    NANOFANCONI: fast5-pod5
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

    // fast5 input
    if (params.reads_format == 'fast5') {
        INPUT_CHECK
        .out
        .reads
        .map { meta, files -> 
            def fast5_path = meta.fast5_path
            
            // Debug print
            // println "Meta: ${meta}, Fast5 Path: ${fast5_path}"
    
            // Check if fast5_path is null or empty
            if (!fast5_path) {
                throw new IllegalArgumentException("fast5_path is null or empty")
            }
        
            def fast5_files = []
    
            // If the path is a URL (HTTP/S), download the file using wget
            if (fast5_path.startsWith("http://") || fast5_path.startsWith("https://")) {
                def fileName = fast5_path.split('/').last()  // Extract the file name from the URL
                def downloadDir = "${launchDir}/downloads"  // Set custom download directory
                file(downloadDir).mkdirs()  // Create the download directory if it doesn't exist
                
                // Define the local file name within the download directory
                fast5_files = [file("${downloadDir}/${fileName}")] 
                
                println "Downloading file from: ${fast5_path}"
                def downloadedFile = file("${downloadDir}/${fileName}")
    
                // Download the file using wget
                script:
                
                """
                wget -O ${downloadDir}/${fileName} ${fast5_path} || { echo "Failed to download ${fast5_path}"; exit 1; }  // Download file from URL to the download directory
                """

                println "Downloaded file: ${downloadedFile} exists: ${downloadedFile.exists()}"
                fast5_files = [downloadedFile]

            }
            
            // If it's a directory or a local file path, handle accordingly
            else if (file(fast5_path).isDirectory()) {
                fast5_files = file("${fast5_path}/*.fast5")
            } else if (fast5_path.endsWith('.fast5')) {
                fast5_files = [file(fast5_path)]
            }
            
            [meta, fast5_files]
        }
        .flatMap { meta, files ->
            def chunks = files.toList().collate(params.dorado_files_chunksize)  // chunk files into groups of 2
            def chunkList = []
            for (int i = 0; i < chunks.size(); i++) {
                def newMeta = meta.clone()  // clone the meta to avoid modifying the original
                newMeta.chunkNumber = i + 1  // add chunk number, starting from 1
                chunkList << [newMeta, chunks[i]]
            }
            return chunkList
        }
        // .dump(tag: 'input', pretty: true)
        .set { ch_fast5 }

    FAST5_TO_POD5 (
        ch_fast5
    )

    FAST5_TO_POD5
    .out
    .pod5
    .set { ch_pod5 } 

    ch_versions = ch_versions.mix(FAST5_TO_POD5.out.versions)

    } else if (params.reads_format == 'pod5') {
    INPUT_CHECK
    .out
    .reads
    .map { meta, pod5_path -> 
        def pod5_files = []
        if (file(pod5_path).isDirectory()) {
            pod5_files = file("${pod5_path}/*.pod5")
        } else if (pod5_path.endsWith('.pod5')) {
            pod5_files = [file(pod5_path)]
        }
        [meta, pod5_files]
    }
    .flatMap { meta, files ->
        def chunks = files.toList().collate(params.dorado_files_chunksize)  // chunk files into groups of 2
        def chunkList = []
        for (int i = 0; i < chunks.size(); i++) {
            def newMeta = meta.clone()  // clone the meta to avoid modifying the original
            newMeta.chunkNumber = i + 1  // add chunk number, starting from 1
            chunkList << [newMeta, chunks[i]]
        }
        return chunkList
    }
    // .dump(tag: 'input_pod5', pretty: true)
    .set { ch_pod5 }
    }


    if (params.reads_format == 'pod5' || params.reads_format == 'fast5') {
        DORADO_BASECALLER (
            ch_pod5
        )
        ch_versions = ch_versions.mix(DORADO_BASECALLER.out.versions)
        DORADO_BASECALLER
        .out
        .bam
        .map { meta, bam -> [[id: meta.id, sample: meta.sample, flowcell: meta.flowcell, batch: meta.batch, kit: meta.kit] , bam]} // make sample name the only mets (remove flow cell and other info)
        .groupTuple(by: 0) // group bams by meta (i.e sample) which zero indexed
        // .dump(pretty: true)
        .set { ch_basecall_single_bams }

        MERGE_BASECALL_ID (
        ch_basecall_single_bams
        )
        ch_versions = ch_versions.mix(MERGE_BASECALL_ID.out.versions)

        MERGE_BASECALL_ID
        .out
        .merged_bam
        // .dump(tag: 'basecall_id', pretty: true)
        .set { ch_basecall_id_merged_bams }

        // Dorado basecall summary
        DORADO_BASECALL_SUMMARY (
            ch_basecall_id_merged_bams
        )

        //
        // CHANNEL: Channel operation group unaligned bams paths by sample (i.e bams of reads from multiple flow cells but the same sample streamed together to be fed for alignment module)
        //
        ch_basecall_id_merged_bams
        .map { meta, bam -> [[sample: meta.sample] , bam]} // make sample name the only mets (remove flow cell and other info)
        .groupTuple(by: 0) // group bams by meta (i.e sample) which zero indexed
        // .dump(tag: 'basecall_sample', pretty: true)
        .set { ch_basecall_sample_merged_bams } // set channel name


        DORADO_BASECALL_SUMMARY
        .out
        .summary
        // .dump(pretty: true)
        .set { ch_basecall_summary }


        // MODULE: PycoQC (QC from Basecall results)
        PYCOQC (
            ch_basecall_summary
        )
        ch_versions = ch_versions.mix(PYCOQC.out.versions)

    }

if (params.reads_format == 'bam' ) {
    INPUT_CHECK
    .out
    .reads
    .flatMap { meta, bam_path -> 
        def bam_files = []
        if (file(bam_path).isDirectory()) {
            bam_files = file("${bam_path}/*.bam")
        } else if (bam_path.endsWith('.bam')) {
            bam_files = [file(bam_path)]
        }
        bam_files.collect { [[sample: meta.sample], it] }  // Create a list of [meta, file] pairs
    }
    .groupTuple(by: 0) // group bams by meta (i.e sample) which is zero-indexed
    // .dump(tag: 'basecall_sample', pretty: true)
    .set { ch_basecall_sample_merged_bams } // set channel name
}

    MERGE_BASECALL_SAMPLE (
        ch_basecall_sample_merged_bams
    )
    ch_versions = ch_versions.mix(MERGE_BASECALL_SAMPLE.out.versions)
    

    DORADO_ALIGNER (
        MERGE_BASECALL_SAMPLE.out.merged_bam,
        file(params.fasta)
    )
    ch_versions = ch_versions.mix(DORADO_ALIGNER.out.versions)


    //
    // MODULE: Samtools sort and indedx aligned bams
    //
    SAMTOOLS_SORT (
        DORADO_ALIGNER.out.bam
    )
    ch_versions = ch_versions.mix(SAMTOOLS_SORT.out.versions)


    /*
    // MODULE: PEPPER
    //
    ch_pepper_input = SAMTOOLS_SORT.out.bam.mix(SAMTOOLS_SORT.out.bai).groupTuple(size:2).map{ meta, files -> [ meta, files.flatten() ]}
    ch_pepper_input.dump(tag: "pepper")
    PEPPER (
        ch_pepper_input,
        file(params.fasta)
    )
    ch_versions = ch_versions.mix(PEPPER.out.versions)
    */

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    NANOFANCONI: currently remove whatshap
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

/*
    if (params.run_whatshap) {
        //
        // MODULE: Index PEPPER bam
        //
        ch_whatshap_input = SAMTOOLS_SORT.out.bam.mix(SAMTOOLS_SORT.out.bai,PEPPER.out.vcf).groupTuple(size:3).map{ meta, files -> [ meta, files.flatten() ]}
        input = ch_whatshap_input.join(ch_phased_vcf).dump(tag: "joined")
        ch_whatshap_input.dump(tag: "whatshap")
        WHATSHAP (
            input,
            file(params.fasta),
            file(params.fasta_index)
        )
        ch_versions = ch_versions.mix(WHATSHAP.out.versions)


        //
        // MODULE: MOSDEPTH for depth calculation
        //
        ch_mosdepth_input = WHATSHAP.out.bam.mix(WHATSHAP.out.bai).groupTuple(size:2).map{ meta, files -> [ meta, files.flatten() ]}
        MOSDEPTH (
            ch_mosdepth_input
        )
        ch_versions = ch_versions.mix(MOSDEPTH.out.versions)


        //
        // MODULE: MODKIT to extract methylation data
        //
        
        if (params.extract_methylation) {
            ch_modkit_input = WHATSHAP.out.bam.mix(WHATSHAP.out.bai).groupTuple(size:2).map{ meta, files -> [ meta, files.flatten() ]}
            MODKIT (
                ch_modkit_input,
                file(params.fasta)
            )
            ch_versions = ch_versions.mix(MODKIT.out.versions)

            ch_modkit_to_bw_input = MODKIT.out.hap1_bed.join(MODKIT.out.hap2_bed).join(MODKIT.out.combined_bed)
            MODKIT_TO_BW (
                ch_modkit_to_bw_input,
                file(params.fasta_index)
            )
            ch_versions = ch_versions.mix(MODKIT_TO_BW.out.versions)

            SAMTOOLS_STATS (
                WHATSHAP.out.bam
            )
            ch_versions = ch_versions.mix(SAMTOOLS_STATS.out.versions)
        }
    }
*/

    CUSTOM_DUMPSOFTWAREVERSIONS (
        ch_versions.unique().collectFile(name: 'collated_versions.yml')
    )

    //
    // MODULE: MultiQC
    //
    workflow_summary    = WorkflowNanofanconi.paramsSummaryMultiqc(workflow, summary_params)
    ch_workflow_summary = Channel.value(workflow_summary)

    methods_description    = WorkflowNanofanconi.methodsDescriptionText(workflow, ch_multiqc_custom_methods_description)
    ch_methods_description = Channel.value(methods_description)

    ch_multiqc_files = Channel.empty()
    ch_multiqc_files = ch_multiqc_files.mix(ch_workflow_summary.collectFile(name: 'workflow_summary_mqc.yaml'))
    ch_multiqc_files = ch_multiqc_files.mix(ch_methods_description.collectFile(name: 'methods_description_mqc.yaml'))
    ch_multiqc_files = ch_multiqc_files.mix(CUSTOM_DUMPSOFTWAREVERSIONS.out.mqc_yml.collect())

    if (params.reads_format == 'fast5' || params.reads_format == 'pod5') {
        ch_multiqc_files = ch_multiqc_files.mix(PYCOQC.out.json.collect{it[1]}.ifEmpty([]))
    }

    if (params.run_whatshap) {
        ch_multiqc_files = ch_multiqc_files.mix(MOSDEPTH.out.global_txt.collect{it[1]}.ifEmpty([]))
        ch_multiqc_files = ch_multiqc_files.mix(MOSDEPTH.out.summary_txt.collect{it[1]}.ifEmpty([]))
        ch_multiqc_files = ch_multiqc_files.mix(MOSDEPTH.out.regions_txt.collect{it[1]}.ifEmpty([]))
        ch_multiqc_files = ch_multiqc_files.mix(MOSDEPTH.out.regions_bed.collect{it[1]}.ifEmpty([]))
        ch_multiqc_files = ch_multiqc_files.mix(MOSDEPTH.out.regions_csi.collect{it[1]}.ifEmpty([]))
        ch_multiqc_files = ch_multiqc_files.mix(MOSDEPTH.out.quantized_bed.collect{it[1]}.ifEmpty([]))
        ch_multiqc_files = ch_multiqc_files.mix(MOSDEPTH.out.quantized_csi.collect{it[1]}.ifEmpty([]))
    }

    MULTIQC (
        ch_multiqc_files.collect(),
        ch_multiqc_config.toList(),
        ch_multiqc_custom_config.toList(),
        ch_multiqc_logo.toList()
    )
    multiqc_report = MULTIQC.out.report.toList()
}

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    COMPLETION EMAIL AND SUMMARY
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

workflow.onComplete {
    if (params.email || params.email_on_fail) {
        NfcoreTemplate.email(workflow, params, summary_params, projectDir, log, multiqc_report)
    }
    NfcoreTemplate.summary(workflow, params, log)
    if (params.hook_url) {
        NfcoreTemplate.IM_notification(workflow, params, summary_params, projectDir, log)
    }
}

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    THE END
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/
