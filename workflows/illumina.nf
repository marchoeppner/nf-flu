#!/usr/bin/env nextflow

nextflow.enable.dsl = 2

//=============================================================================
// NCBI Influenza DB reference data
//=============================================================================

ch_influenza_db_fasta = file(params.ncbi_influenza_fasta)
ch_influenza_metadata = file(params.ncbi_influenza_metadata)

//=============================================================================
// MODULES
//=============================================================================

include { IRMA } from '../modules/local/irma'
include { CHECK_SAMPLE_SHEET } from '../modules/local/check_sample_sheet'
include { SUBTYPING_REPORT } from '../modules/local/subtyping_report'
include { BLAST_MAKEBLASTDB } from '../modules/local/blast_makeblastdb'
include { BLAST_BLASTN } from '../modules/local/blastn'
include { CAT_ILLUMINA_FASTQ } from '../modules/local/cat_illumina_fastq'
include { ZSTD_DECOMPRESS as ZSTD_DECOMPRESS_FASTA; ZSTD_DECOMPRESS as ZSTD_DECOMPRESS_CSV } from '../modules/local/zstd_decompress'
include { CUSTOM_DUMPSOFTWAREVERSIONS as SOFTWARE_VERSIONS } from '../modules/nf-core/modules/custom/dumpsoftwareversions/main'
include { MULTIQC } from '../modules/local/multiqc'
include { MULTIQC_TSV_FROM_LIST as READ_COUNT_FAIL_TSV } from '../modules/local/multiqc_tsv_from_list'
include { MULTIQC_TSV_FROM_LIST as READ_COUNT_PASS_TSV } from '../modules/local/multiqc_tsv_from_list'
include { MINIMAP2 } from '../modules/local/minimap2_new'
include { MOSDEPTH_GENOME } from '../modules/local/mosdepth'
include { BCFTOOLS_STATS } from '../modules/local/bcftools'
include { SEQTK_SEQ } from '../modules/local/seqtk_seq'
include { PULL_TOP_REF_ID } from '../modules/local/pull_top_ref_id'
include { BCF_FILTER as BCF_FILTER_FREEBAYES                     } from '../modules/local/bcftools'
include { VCF_FILTER_FRAMESHIFT                               } from '../modules/local/vcf_filter_frameshift'
include { FREEBAYES                                           } from '../modules/local/freebayes'
include { VADR; VADR_SUMMARIZE_ISSUES                         } from '../modules/local/vadr'
include { PRE_TABLE2ASN; TABLE2ASN; POST_TABLE2ASN            } from '../modules/local/table2asn'
include { CUSTOM_DUMPSOFTWAREVERSIONS  as SOFTWARE_VERSIONS   } from '../modules/nf-core/modules/custom/dumpsoftwareversions/main'

//=============================================================================
// Workflow Params Setup
//=============================================================================

def irma_module = 'FLU-utr'
if (params.irma_module) {
    irma_module = params.irma_module
}

def pass_sample_reads = [:]
def fail_sample_reads = [:]
def summary_params = NfcoreSchema.params_summary_map(workflow, params, "$projectDir/nextflow_schema.json")

//=============================================================================
// WORKFLOW
//=============================================================================

workflow ILLUMINA {
  ch_versions = Channel.empty()

  // Sample Sheet Check
  ch_input = CHECK_SAMPLE_SHEET(Channel.fromPath(params.input, checkIfExists: true))

    ch_input.splitCsv(header: ['sample', 'fastq1', 'fastq2', 'single_end'], sep: ',', skip: 1)
    .map {
      def meta = [:]
      meta.id = it.sample
      meta.single_end = it.single_end.toBoolean()
      def reads = []
      def fastq1 = file(it.fastq1)
      def fastq2
      if (!fastq1.exists()) {
        exit 1, "ERROR: Please check input samplesheet. FASTQ file 1 '${fastq1}' does not exist!"
      }
      if (meta.single_end) {
        reads = [fastq1]
      } else {
        fastq2 = file(it.fastq2)
        if (!fastq2.exists()) {
          exit 1, "ERROR: Please check input samplesheet. FASTQ file 2 '${fastq2}' does not exist!"
        }
        reads = [fastq1, fastq2]
      }
      [ meta, reads ]
    }
    .groupTuple(by: [0])
    .map { meta, reads ->
      return [ meta, reads.flatten() ]
    }
    .set { ch_input_sorted }

  // Read Count Check
  ch_input_sorted
    .map { meta, reads ->
      def count = reads.collect { it.countFastq() }.sum()
      return [ meta, reads, count ]
    }
    .branch { meta, reads, count ->
      pass: count >= params.min_sample_reads
        pass_sample_reads[meta.id] = count
        return [ "${meta.id}\t$count" ]
      fail: count < params.min_sample_reads
        fail_sample_reads[meta.id] = count
        return [ "${meta.id}\t$count" ]
    }
    .set { ch_pass_fail_read_count }

  // Report samples which have reads count < min_sample_reads
  READ_COUNT_FAIL_TSV(
    ch_pass_fail_read_count.fail.collect(),
    ['Sample', 'Read count'],
    'fail_read_count_samples'
  )
  // Report samples which have reads count >= min_sample_reads
  READ_COUNT_PASS_TSV(
    ch_pass_fail_read_count.pass.collect(),
    ['Sample', 'Read count'],
    'pass_read_count_samples'
  )
  // Keep samples which have reads count >= min_sample_reads for downstream analysis
  // Re-arrange channels to have meta map of information for sample
  ch_input_sorted
    .filter { it[2] >= params.min_sample_reads }
    .map { meta, reads, count -> [ meta, reads ] }
    .set { ch_reads }

  // Decompress reference data
  ZSTD_DECOMPRESS_FASTA(ch_influenza_db_fasta, "influenza.fasta")
  ch_versions = ch_versions.mix(ZSTD_DECOMPRESS_FASTA.out.versions)
  ZSTD_DECOMPRESS_CSV(ch_influenza_metadata, "influenza.csv")
  ch_versions = ch_versions.mix(ZSTD_DECOMPRESS_CSV.out.versions)
  BLAST_MAKEBLASTDB(ZSTD_DECOMPRESS_FASTA.out.file)
  ch_versions = ch_versions.mix(BLAST_MAKEBLASTDB.out.versions)

  // Use ch_input_sorted for CAT_ILLUMINA_FASTQ to ensure IRMA triggers
  CAT_ILLUMINA_FASTQ(ch_input_sorted)
  ch_versions = ch_versions.mix(CAT_ILLUMINA_FASTQ.out.versions.first().ifEmpty(null))

  // IRMA processing
  IRMA(CAT_ILLUMINA_FASTQ.out.reads, irma_module)
  ch_versions = ch_versions.mix(IRMA.out.versions.first().ifEmpty(null))

  // BLAST and subtype prediction from IRMA results
  BLAST_BLASTN(IRMA.out.majority_consensus, BLAST_MAKEBLASTDB.out.db)
  ch_versions = ch_versions.mix(BLAST_BLASTN.out.versions)

  // VADR application on IRMA concsensus
  IRMA.out.consensus
    .map { [it[0].id, it[1]] }
    .set { ch_irma_consensus }
  VADR(ch_irma_consensus)
  ch_versions = ch_versions.mix(VADR.out.versions)
  VADR.out.feature_table
    .combine(VADR.out.pass_fasta, by: 0)
    .set { ch_pre_table2asn }
  VADR_SUMMARIZE_ISSUES(VADR.out.vadr_outdir.map { [it[1]] }.collect())
  PRE_TABLE2ASN(ch_pre_table2asn)
  ch_versions = ch_versions.mix(PRE_TABLE2ASN.out.versions)
  TABLE2ASN(PRE_TABLE2ASN.out.table2asn_input)
  ch_versions = ch_versions.mix(TABLE2ASN.out.versions)
  POST_TABLE2ASN(TABLE2ASN.out.genbank)
  ch_versions = ch_versions.mix(POST_TABLE2ASN.out.versions)

  BLAST_BLASTN(IRMA.out.consensus, BLAST_MAKEBLASTDB.out.db)
  ch_versions = ch_versions.mix(BLAST_BLASTN.out.versions.first().ifEmpty(null))

  ch_blast = BLAST_BLASTN.out.txt.collect({ it[1] })
  SUBTYPING_REPORT(
    ZSTD_DECOMPRESS_CSV.out.file,
    ch_blast,
    CHECK_SAMPLE_SHEET.out
  )
  ch_versions = ch_versions.mix(SUBTYPING_REPORT.out.versions)

  // Prepare top ncbi accession id for each segment of each sample (id which has top bitscore)
  PULL_TOP_REF_ID(BLAST_BLASTN.out.txt, ZSTD_DECOMPRESS_CSV.out.file)
  ch_versions = ch_versions.mix(PULL_TOP_REF_ID.out.versions)

  PULL_TOP_REF_ID.out.accession_id
    .map { it[1] }
    .splitCsv(header: false, sep:",")
    .map{ [it[0], it[1], it[2]] }
    .combine(CAT_ILLUMINA_FASTQ.out.reads.map { [it[0].id, it[1]] }, by: 0)
    .set { ch_sample_segment } 

  // Pull segment reference sequence for each sample
  SEQTK_SEQ(ch_sample_segment, ZSTD_DECOMPRESS_FASTA.out.file)
  ch_versions = ch_versions.mix(SEQTK_SEQ.out.versions)

  // Map reads against segment reference sequences using Minimap2
  MINIMAP2(SEQTK_SEQ.out.sample_info)
  ch_versions = ch_versions.mix(MINIMAP2.out.versions)

  // Generate coverage and stats
  MOSDEPTH_GENOME(MINIMAP2.out.alignment)
  ch_versions = ch_versions.mix(MOSDEPTH_GENOME.out.versions)

  FREEBAYES(MINIMAP2.out.alignment)
  ch_versions = ch_versions.mix(FREEBAYES.out.versions)

  BCF_FILTER_FREEBAYES(FREEBAYES.out.vcf, params.major_allele_fraction)
  ch_versions = ch_versions.mix(BCF_FILTER_FREEBAYES.out.versions)
  ch_vcf_filter = BCF_FILTER_FREEBAYES.out.vcf

  VCF_FILTER_FRAMESHIFT(ch_vcf_filter)
  ch_versions = ch_versions.mix(VCF_FILTER_FRAMESHIFT.out.versions)

  BCFTOOLS_STATS(VCF_FILTER_FRAMESHIFT.out.vcf)
  ch_versions = ch_versions.mix(BCFTOOLS_STATS.out.versions)

  workflow_summary    = Schema.params_summary_multiqc(workflow, summary_params)
  ch_workflow_summary = Channel.value(workflow_summary)
  ch_multiqc_config = Channel.fromPath("$projectDir/assets/multiqc_config.yaml")

  // Software Versions
  SOFTWARE_VERSIONS(ch_versions.unique().collectFile(name: 'collated_versions.yml'))

  // MultiQC
  ch_workflow_summary = Channel.value(Schema.params_summary_multiqc(workflow, summary_params))
  ch_multiqc_config = Channel.fromPath("$projectDir/assets/multiqc_config.yaml")

  MULTIQC(
      ch_multiqc_config,
      MINIMAP2.out.stats.collect().ifEmpty([]),
      MOSDEPTH_GENOME.out.mqc.collect().ifEmpty([]),
      BCFTOOLS_STATS.out.stats.collect().ifEmpty([]),
      SOFTWARE_VERSIONS.out.mqc_yml.collect(),
      ch_workflow_summary.collectFile(name: "workflow_summary_mqc.yaml")
  )
}
