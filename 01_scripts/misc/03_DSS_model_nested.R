#!/usr/bin/env Rscript
## Working script for DML / DMR quantification using DSS

args <- commandArgs(T)
# args <- "~/Projects/safo_epi/methylUtil/config_unpaired.yml"; setwd("~/Projects/safo_epi/methylUtil")
# args <- "config_juvenile_samples_8x8.yml"; setwd("~/Desktop/sasa_epi/methylUtil")

## Sanity checking
if (length(args) != 1)
    stop("Usage: DSS_model.R <config_nested.yml>")

## Install and load necessary packages
for (p in c("data.table", "BiocManager", "DSS", "bsseq", "dmrseq", "parallel", "configr", "tidyverse")) {
    if (!suppressMessages(require(p, character.only = T))) {
        message(paste("Installing:", p))
        if(p %in% c("DSS", "bsseq")) {
            BiocManager::install(p)
        } else {
            install.packages(p, repos = "https://mirror.its.dal.ca/cran", dependencies = T)}
        suppressMessages(require(p, character.only = T))}
    rm(p)
}

if (!is.yaml.file(args[1]))
    stop("You must supply a configuration file in YAML format.\nUsage: DSS_DML_DMR.R <config.yml>")

config <- read.config(args[1])

if (!grepl(config$options$analysis_type, "wald|glm|dmrseq", ignore.case = TRUE))
    stop("Invalid analysis type.")


# Parse formula
if (is.null(config$options$formula) | !grepl("\\~", config$options$formula))
    stop("Invalid formula. You must provide a design formula beginning with a tilde (e.g. \'~ Treatment\')")

formula <- as.formula(config$options$formula)
formula_parts <- attr(terms(formula), "term.labels")

if (length(formula_parts) > 1 & grepl(config$options$analysis_type, "wald", ignore.case = TRUE))
    stop("You specified a Wald test with more than one factor.\nPlease verify your input.")

# Load files and set up design
samples <- read.table(config$input$sample_info, header = T, stringsAsFactors = FALSE)

if(!all(c("sample", "file", formula_parts) %in% colnames(samples)))
    stop("Samples file must contain a header row with names: \'sample\', \'file\', and given factor(s).")

if (grepl(config$options$analysis_type, "wald", ignore.case = TRUE)) {
    grp <- formula_parts
    ref <- config$options$reference_condition
    treat <- config$options$treatment_condition
    if (!(ref %in% with(samples, get(grp))) | !(treat %in% with(samples, get(grp))))
        stop("Specified factor levels not found in factor names.\nPlease verify your input.")
    design <- data.frame(group = factor(samples[, grp], levels = c(ref, treat)))
    grp1 = samples[samples[, grp] == levels(design$group)[1], "sample"]
    grp2 = samples[samples[, grp] == levels(design$group)[2], "sample"]
}

if (grepl(config$options$analysis_type, "glm", ignore.case = TRUE)) {
    to_test <- setdiff(unlist(strsplit(config$options$factors_to_test, split = ", *")), formula_parts)
    if (any(!to_test %in% colnames(samples)))
        stop("Factors specified in formula design are not present in the samples file!")
    design <- data.frame(samples[sample(1:16, replace = FALSE), c(formula_parts, to_test)])
    design[] <- lapply(design, factor)
    names(design) <- c(formula_parts, to_test)
    mm <- model.matrix(formula, design)
    contrast_list <- lapply(to_test, function(i) {
        if (nlevels(design[,i]) == 2) {
            xtab <- table(design[, c(formula_parts, i)])[,1]
            xtab[xtab != 0] <- 1
            xtab[xtab == 0] <- -1
            contrast <- matrix(as.numeric(xtab), ncol = 1)
            return(contrast)
        } else {
            xtab <- table(design[, c(formula_parts, i)])
            contrast <- matrix(as.numeric(xtab > 0), nrow = nlevels(design[, formula_parts]))
            return(contrast)
        }
    })
    names(contrast_list) <- to_test
}

# Set number of cores for parallel computing
if (is.null(config$options$n_cores)) {
    warning("\'n_cores\' not specified. Default to using 1 core.")
    n_cores <- 1
    setDTthreads(n_cores)
} else {
    if (config$options$n_cores == 0)
        warning("Using all cores will require a lot of memory")
    n_cores <- ifelse(config$options$n_cores == 0, detectCores(), config$options$n_cores)
    setDTthreads(n_cores)
}

# Set coverage options for filtering
if (is.null(config$options$max_coverage)) {
    warning("\'max_coverage\' not specified. Default to using a value of 30.")
    max_cov <- 30L
} else {
    max_cov <- config$options$max_coverage
}

if (is.null(config$options$max_coverage)) {
    warning("\'max_coverage\' not specified. Default to using a value of 10.")
    min_cov <- 10L
} else {
    min_cov <- config$options$min_coverage
}

if (is.null(config$options$max_coverage)) {
    warning("\'min_individuals\' not specified. Requiring coverage for all individuals.")
    min_ind <- nrow(samples)
} else {
    min_ind <- config$options$min_individuals
}

if (is.null(config$options$pval_threshold) | !is.numeric(config$options$pval_threshold)) {
    warning("Invalid pval threshold. Default to using a value of 1e-5.")
    pval <- 1e-5
} else {
    pval <- config$options$pval_threshold
}

if (grepl(config$options$analysis_type, "wald", ignore.case = TRUE) & (is.null(config$options$delta) | !is.numeric(config$options$delta))) {
    warning("Delta required for Wald tests. Default to using a value of 0.1.")
    delta <- 0.1
} else {
    delta <- config$options$delta
}


## Load and save BSseq object
bs_obj_path <- paste0(config$output$outfile_prefix, "_min", min_cov, "_max", max_cov)
if (file.exists(bs_obj_path)) {
    message("Loading existing BSseq object")
    bs_obj <- readRDS(file = bs_obj_path)
} else if (file.exists(paste0("06_methylation_results/", gsub("\\..*", "", config$input$sample_info), "_all_data.rds"))) {
    message("Loading existing BSseq object")
    bs_obj_all <- readRDS(file = paste0("06_methylation_results/", gsub("\\..*", "", config$input$sample_info), "_all_data.rds"))
    keep <- (rowSums(getCoverage(bs_obj_all, type = "Cov") >= min_cov & getCoverage(bs_obj_all, type = "Cov") <= max_cov)) >= min_ind
    bs_obj <- bs_obj_all[keep, ]
    rm(bs_obj_all, keep)
    message("Saving BSseq obj for future use...")
    saveRDS(object = bs_obj, file = bs_obj_path, compress = "gzip")
} else {    
    bs_obj_all <- lapply(1:nrow(samples), function(i) {
        message(paste0("Loading sample: ", samples[i, "sample"]))
        samp <- fread(samples[i, "file"], header = FALSE)[,c(-3:-4)]
        samp[, V7 := V5 + V6] # Combine me+ and me- counts for total coverage
        #bs_obj <- makeBSseqData(list(samp[, .("chr" = V1, "pos" = V2, "N" = V7, "X" = V5)]), samples[i,"sample"])
        return(samp[, .("chr" = V1, "pos" = V2, "N" = V7, "X" = V5)])
    })
    bs_obj_all <- suppressWarnings(makeBSseqData(dat = bs_obj_all, sampleNames = samples$sample))
    bs_obj_all <- bs_obj_all[(rowSums(getCoverage(bs_obj_all, type = "Cov") >= 1) == ncol(bs_obj_all)), ]
    saveRDS(bs_obj_all, paste0("06_methylation_results/", gsub("\\..*", "", basename(config$input$sample_info)), "_all_data.rds"), compress = "gzip")
    
    # Filter CpGs on min and max coverage in min individuals
    keep <- (rowSums(getCoverage(bs_obj_all, type = "Cov") >= min_cov & getCoverage(bs_obj_all, type = "Cov") <= max_cov)) >= min_ind
    bs_obj <- bs_obj_all[keep, ]
    rm(bs_obj_all, keep)
    message("Saving BSseq obj for future use...")
    saveRDS(object = bs_obj, file = bs_obj_path, compress = "gzip")
}


# Wald tests
if (grepl(config$options$analysis_type, "wald", ignore.case = TRUE)) {
    
    if (file.exists(paste0(bs_obj_path, "_all_sites.txt.gz"))) {
        dml_test <- fread(paste0(bs_obj_path, "_all_sites.txt.gz"))
    } else {
        dml_list <- lapply(unique(seqnames(bs_obj)), function(chr) {
            # Run linear models
            # Standard beta-binomial two group test
            message(paste0("Processing chromosome: ", chr))
            capture.output(dml_test <- DMLtest(bs_obj[seqnames(bs_obj) == chr, ], group1 = grp1, group2 = grp2, smoothing = TRUE))
            return(dml_test)
        })
        dml_test <- do.call(rbind, dml_list)
        dml_test$fdr <- p.adjust(dml_test$pval, method = "BH")
        # Write complete outfile...
        fwrite(dml_test, file = paste0(bs_obj_path, "_all_sites.txt.gz"), quote = FALSE, sep = "\t")
    }
    
    # Call DML and DMR
    dml <- callDML(dml_test, delta = delta, p.threshold = pval)
    dmr <- callDMR(dml_test, delta = delta, p.threshold = pval)
    
    # Write DML/DMR outfiles...
    fwrite(dml, file = paste0(bs_obj_path, "_dml_delta", delta, "_pval", pval,".txt.gz"), quote = FALSE, sep = "\t")
    fwrite(dmr, file = paste0(bs_obj_path, "_dmr_delta", delta, "_pval", pval,".txt.gz"), quote = FALSE, sep = "\t")
}

# glm
if (grepl(config$options$analysis_type, "glm", ignore.case = TRUE)) {
    for (coef in c(to_test)) {
        # swap colon for period to use in file paths
        if (file.exists(paste0(bs_obj_path, "_", coef, "_all_sites.txt.gz"))) {
            message(paste0("Previous model results detected, loading results for: ", coef))
            dml_factor_test <- fread(paste0(bs_obj_path, "_", coef, "_all_sites.txt.gz"))
            dml_factor_test <- as.data.frame(dml_factor_test)
            class(dml_factor_test) <- c(class(dml_factor_test), "DMLtest.multiFactor")
        } else {
            if(!exists("dml_list")) {
                dml_list <- lapply(unique(seqnames(bs_obj)), function(chr) {
                    # Run linear models
                    # Linear model with family nested in treatment
                    message(paste0("Fitting model for chromosome: ", chr))
                    capture.output(dml_test <- DMLfit.multiFactor(bs_obj[seqnames(bs_obj) == chr,], design = design, formula = as.formula(paste0("~0+", formula_parts, collapse = "+")), smoothing = TRUE))
                    return(dml_test)
                })
            }
            dml_factor_test <- lapply(dml_list, function(chr) {
                if (coef %in% formula_parts) {
                    test <- DMLtest.multiFactor(chr, term = coef)
                    return(test)
                } else {
                    test <- DMLtest.multiFactor(chr, Contrast = contrast_list[[coef]])
                    return(test)
                }
            })
            dml_factor_test <- do.call(rbind, dml_factor_test)
            dml_factor_test$fdrs <- p.adjust(dml_factor_test$pval, method = "BH")
            # Write complete outfile...
            fwrite(dml_factor_test, file = paste0(bs_obj_path, "_", coef, "_nested_all_sites.txt.gz"), quote = FALSE, sep = "\t")
        }
        
        # Call DML and DMR
        dml <- callDML(dml_factor_test, delta = 0, p.threshold = pval)
        dmr <- callDMR(dml_factor_test, delta = 0, p.threshold = pval)
        
        # Write DML/DMR outfiles...
        fwrite(dml, file = paste0(bs_obj_path, "_", coef, "_nested_dml_pval", pval,".txt.gz"), quote = FALSE, sep = "\t")
        fwrite(dmr, file = paste0(bs_obj_path, "_", coef, "_nested_dmr_pval", pval,".txt.gz"), quote = FALSE, sep = "\t")
        
    }
}

if (grepl(config$options$analysis_type, "dmrseq", ignore.case = TRUE)) {
    if (length(formula_parts) > 1)
        stop("dmrseq imlementation currently only supports one factor")
    pData(bs_obj) <- samples
    regions <- dmrseq(bs_obj, testCovariate = formula_parts,
                      cutoff = 0.05, BPPARAM = MulticoreParam(1))
    fwrite(as.data.frame(regions), file = paste0(bs_obj_path, "_", formula_parts, "_dmrseq_pval", pval,".txt.gz"), quote = FALSE, sep = "\t")
    
}
