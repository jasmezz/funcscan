/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    VALIDATE INPUTS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

def summary_params = NfcoreSchema.paramsSummaryMap(workflow, params)

// Validate input parameters
WorkflowFuncscan.initialise(params, log)

// Check input path parameters to see if they exist
def checkPathParamList = [ params.input, params.multiqc_config, params.annotation_bakta_db,
                            params.amp_hmmsearch_models, params.amp_ampcombi_db,
                            params.arg_amrfinderplus_db, params.arg_deeparg_data,
                            params.bgc_antismash_databases, params.bgc_antismash_installationdirectory,
                            params.bgc_deepbgc_database, params.bgc_hmmsearch_models ]
for (param in checkPathParamList) { if (param) { file(param, checkIfExists: true) } }

// Check mandatory parameters
if (params.input) { ch_input = file(params.input) } else { exit 1, 'Input samplesheet not specified!' }

// Validate fARGene inputs
// Split input into array, find the union with our valid classes, extract only
// invalid classes, and if they exist, exit. Note `tokenize` used here as this
// works for `interesect` and other groovy functions, but require `split` for
// `Channel.of` creation. See `arg.nf` for latter.
def fargene_classes = params.arg_fargene_hmmmodel
def fargene_valid_classes = [ "class_a", "class_b_1_2", "class_b_3",
                            "class_c", "class_d_1", "class_d_2",
                            "qnr", "tet_efflux", "tet_rpg", "tet_enzyme"
                            ]
def fargene_user_classes = fargene_classes.tokenize(',')
def fargene_classes_valid = fargene_user_classes.intersect( fargene_valid_classes )
def fargene_classes_missing = fargene_user_classes - fargene_classes_valid

if ( fargene_classes_missing.size() > 0 ) exit 1, "[nf-core/funcscan] ERROR: invalid class present in --arg_fargene_hmmodel. Please check input. Invalid class: ${fargene_classes_missing.join(', ')}"

// Validate DeepARG inputs

if ( params.run_arg_screening && !params.arg_skip_deeparg && !params.arg_deeparg_data ) exit 1, "[nf-core/funcscan] ERROR: DeepARG database server is currently broken. Automated download is not possible. Please see https://nf-co.re/funcscan/usage#deeparg for instructions on trying to download manually, or run with `--arg_skip_deeparg`."

// Validate antiSMASH inputs
// 1. Make sure that either both or none of the antiSMASH directories are supplied
if ( ( params.run_bgc_screening && !params.bgc_antismash_databases && params.bgc_antismash_installationdirectory && !params.bgc_skip_antismash) || ( params.run_bgc_screening && params.bgc_antismash_databases && !params.bgc_antismash_installationdirectory && !params.bgc_skip_antismash ) ) exit 1, "[nf-core/funcscan] ERROR: You supplied either the antiSMASH database or its installation directory, but not both. Please either supply both directories or none (letting the pipeline download them instead)."

// 2. If both are supplied: Exit if we have a name collision error
else if ( params.run_bgc_screening && params.bgc_antismash_databases && params.bgc_antismash_installationdirectory && !params.bgc_skip_antismash ) {
    antismash_database_dir = new File(params.bgc_antismash_databases)
    antismash_install_dir = new File(params.bgc_antismash_installationdirectory)
    if ( antismash_database_dir.name == antismash_install_dir.name ) exit 1, "[nf-core/funcscan] ERROR: Your supplied antiSMASH database and installation directories have identical names: \"" + antismash_install_dir.name + "\".\nPlease make sure to name them differently, for example:\n - Database directory:      "+ antismash_database_dir.parent + "/antismash_db\n - Installation directory:  " + antismash_install_dir.parent + "/antismash_dir"
}

// 3. Give warning if not using container system assuming conda

if ( params.run_bgc_screening && ( !params.bgc_antismash_databases || !params.bgc_antismash_installationdirectory ) && !params.bgc_skip_antismash && ( session.config.conda && session.config.conda.enabled ) ) { log.warn "[nf-core/funcscan] Running antiSMASH download database module, and detected conda has been enabled. Assuming using conda for pipeline run, check config if this is not expected!" }

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

include { AMP } from '../subworkflows/local/amp'
include { ARG } from '../subworkflows/local/arg'
include { BGC } from '../subworkflows/local/bgc'

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT NF-CORE MODULES/SUBWORKFLOWS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

//
// MODULE: Installed directly from nf-core/modules
//
include { MULTIQC                     } from '../modules/nf-core/multiqc/main'
include { CUSTOM_DUMPSOFTWAREVERSIONS } from '../modules/nf-core/custom/dumpsoftwareversions/main'
include { GUNZIP                      } from '../modules/nf-core/gunzip/main'
include { BIOAWK                      } from '../modules/nf-core/bioawk/main'
include { PROKKA                      } from '../modules/nf-core/prokka/main'
include { PRODIGAL as PRODIGAL_GFF    } from '../modules/nf-core/prodigal/main'
include { PRODIGAL as PRODIGAL_GBK    } from '../modules/nf-core/prodigal/main'
include { BAKTA_BAKTADBDOWNLOAD       } from '../modules/nf-core/bakta/baktadbdownload/main'
include { BAKTA_BAKTA                 } from '../modules/nf-core/bakta/bakta/main'

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    RUN MAIN WORKFLOW
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

// Info required for completion email and summary
def multiqc_report = []

workflow FUNCSCAN {

    ch_versions = Channel.empty()
    ch_multiqc_logo = Channel.fromPath("$projectDir/docs/images/nf-core-funcscan_logo_flat_light.png")

    //
    // SUBWORKFLOW: Read in samplesheet, validate and stage input files
    //
    INPUT_CHECK (
        ch_input
    )
    ch_versions = ch_versions.mix(INPUT_CHECK.out.versions)

    // Some tools require uncompressed input
    fasta_prep = INPUT_CHECK.out.contigs
        .branch {
            compressed: it[1].toString().endsWith('.gz')
            uncompressed: it[1]
        }

    GUNZIP ( fasta_prep.compressed )
    ch_versions = ch_versions.mix(GUNZIP.out.versions)

    // Merge all the already uncompressed and newly compressed FASTAs here into
    // a single input channel for downstream
    ch_prepped_fastas = GUNZIP.out.gunzip
                        .mix(fasta_prep.uncompressed)

    // Add to meta the length of longest contig for downstream filtering
    BIOAWK ( ch_prepped_fastas )
    ch_versions = ch_versions.mix(BIOAWK.out.versions)

    ch_prepped_input = ch_prepped_fastas
                        .join( BIOAWK.out.longest )
                        .map{
                            meta, fasta, length ->
                                def meta_new = meta.clone()
                                meta['longest_contig'] = Integer.parseInt(length)
                            [ meta, fasta ]
                        }

    /*
        ANNOTATION
    */

    // Some tools require annotated FASTAs
    // For prodigal run twice, once for gff and once for gbk generation, (for parity with PROKKA which produces both)
    if ( ( params.run_arg_screening && !params.arg_skip_deeparg ) || ( params.run_amp_screening && ( !params.amp_skip_hmmsearch || !params.amp_skip_amplify || !params.amp_skip_ampir ) ) || ( params.run_bgc_screening && ( !params.bgc_skip_hmmsearch || !params.bgc_skip_antismash ) ) ) {

        if ( params.annotation_tool == "prodigal" ) {
            PRODIGAL_GFF ( ch_prepped_input, "gff" )
            ch_versions              = ch_versions.mix(PRODIGAL_GFF.out.versions)
            ch_annotation_faa        = PRODIGAL_GFF.out.amino_acid_fasta
            ch_annotation_fna        = PRODIGAL_GFF.out.nucleotide_fasta
            ch_annotation_gff        = PRODIGAL_GFF.out.gene_annotations
            ch_annotation_gbk        = Channel.empty() // Prodigal doesn't produce GBK

            if ( params.save_annotations == true ) {
                PRODIGAL_GBK ( ch_prepped_input, "gbk" )
                ch_versions              = ch_versions.mix(PRODIGAL_GBK.out.versions)
                ch_annotation_gbk        = PRODIGAL_GBK.out.gene_annotations
            }
        }   else if ( params.annotation_tool == "prokka" ) {
            PROKKA ( ch_prepped_input, [], [] )
            ch_versions              = ch_versions.mix(PROKKA.out.versions)
            ch_annotation_faa        = PROKKA.out.faa
            ch_annotation_fna        = PROKKA.out.fna
            ch_annotation_gff        = PROKKA.out.gff
            ch_annotation_gbk        = PROKKA.out.gbk
        }   else if ( params.annotation_tool == "bakta" ) {

            // BAKTA prepare download
            if ( params.annotation_bakta_db ) {
                ch_bakta_db = Channel
                    .fromPath( params.annotation_bakta_db )
                    .first()
            } else {
                BAKTA_BAKTADBDOWNLOAD ()
                ch_versions = ch_versions.mix( BAKTA_BAKTADBDOWNLOAD.out.versions )
                ch_bakta_db = ( BAKTA_BAKTADBDOWNLOAD.out.db )
            }

            BAKTA_BAKTA ( ch_prepped_input, ch_bakta_db, [], [] )
            ch_versions              = ch_versions.mix(BAKTA_BAKTA.out.versions)
            ch_annotation_faa        = BAKTA_BAKTA.out.faa
            ch_annotation_fna        = BAKTA_BAKTA.out.fna
            ch_annotation_gff        = BAKTA_BAKTA.out.gff
            ch_annotation_gbk        = BAKTA_BAKTA.out.gbff
        }

    } else {

        ch_annotation_faa        = Channel.empty()
        ch_annotation_fna        = Channel.empty()
        ch_annotation_gff        = Channel.empty()
        ch_annotation_gbk        = Channel.empty()

    }

    /*
        SCREENING
    */

    /*
        AMPs
    */
    if ( params.run_amp_screening ) {
        AMP ( ch_prepped_input, ch_annotation_faa )
        ch_versions = ch_versions.mix(AMP.out.versions)
    }

    /*
        ARGs
    */
    if ( params.run_arg_screening ) {
        if (params.arg_skip_deeparg) {
            ARG ( ch_prepped_input, [] )
        } else {
            ARG ( ch_prepped_input, ch_annotation_faa )
        }
        ch_versions = ch_versions.mix(ARG.out.versions)
    }

    /*
        BGCs
    */
    if ( params.run_bgc_screening ) {
        BGC ( ch_prepped_input, ch_annotation_gff, ch_annotation_faa, ch_annotation_gbk )
        ch_versions = ch_versions.mix(BGC.out.versions)
    }

    CUSTOM_DUMPSOFTWAREVERSIONS (
        ch_versions.unique().collectFile(name: 'collated_versions.yml')
    )

    //
    // MODULE: MultiQC
    //
    workflow_summary    = WorkflowFuncscan.paramsSummaryMultiqc(workflow, summary_params)
    ch_workflow_summary = Channel.value(workflow_summary)

    methods_description    = WorkflowFuncscan.methodsDescriptionText(workflow, ch_multiqc_custom_methods_description)
    ch_methods_description = Channel.value(methods_description)

    ch_multiqc_files = Channel.empty()
    ch_multiqc_files = ch_multiqc_files.mix(ch_workflow_summary.collectFile(name: 'workflow_summary_mqc.yaml'))
    ch_multiqc_files = ch_multiqc_files.mix(ch_methods_description.collectFile(name: 'methods_description_mqc.yaml'))
    ch_multiqc_files = ch_multiqc_files.mix(CUSTOM_DUMPSOFTWAREVERSIONS.out.mqc_yml.collect())

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
