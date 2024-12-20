process WHATSHAP {
    label 'process_high'

    container "${ workflow.containerEngine == 'singularity' && !task.ext.singularity_pull_docker_container ?
        'ghcr.io/dhslab/docker-whatshap:latest' :
        'ghcr.io/dhslab/docker-whatshap:latest' }"

    input:
        tuple val(meta),path(reference_fasta),path(index),path(vcf_file),path(bam_file)

    output:
        tuple val(meta), path("${meta.sample}*.haplotagged.bam")     , emit: bam
        tuple val(meta), path("${meta.sample}*.haplotagged.bam.bai") , emit: bai
        path  ("versions.yml")                                       , emit: versions

    script:
    """
    whatshap haplotag --tag-supplementary --ignore-read-groups --output-threads=${task.cpus} \\
    -o ${meta.sample}.haplotagged.bam --reference ${reference_fasta} $vcf_file $bam_file && \\
    samtools index ${meta.sample}.haplotagged.bam

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        whatshap: \$(whatshap --version)")
    END_VERSIONS
    """
}
