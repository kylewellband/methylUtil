#!/usr/bin/env Rscript
# compare_DMRs.R

for (p in c("png", "tidyverse", "data.table", "BiocManager", "ggplot2", "ggrepel", "ggforce", "GenomicRanges", "limma")) {
if (!suppressMessages(require(p, character.only = T))) {
    message(paste("Installing:", p))
    if(p %in% c("GenomicRanges", "limma")) {
        BiocManager::install(p)
    } else {
        install.packages(p, dependencies = T)}
    suppressMessages(library(p, character.only = T))}
rm(p)
}

args <- commandArgs(TRUE)
# setwd("~/Desktop/methylUtil/"); args <- c("06_methylation_results/adults_6x7_min5_max20_groupWild_dmr_pval0.001.txt.gz", "06_methylation_results/juveniles_7x8_min5_max20_groupWild_dmr_pval0.001.txt.gz") ; setwd("~/Projects/sasa_adults/methylUtil")
# args <- c("juveniles_7x7_glm_min5_max20_groupWild_dmr_pval0.001.txt.gz", "juveniles_7x7_glm_min10_max20_groupWild_dmr_pval0.001.txt.gz")

## Sanity checking
if (length(args) != 2)
    stop("Usage: compare_DMRs.R <DMR_result_1> <DMR_result_2>")

makeDMRgrange <- function(dmr_dt) {
    dmr_gr <- GRanges(
        seqnames = Rle(dmr_dt$chr),
        range = IRanges(start = dmr_dt$start, end = dmr_dt$end),
        score = dmr_dt$areaStat
    )
    return(sort(dmr_gr))
}

dmr1 <- fread(args[1])
dmr2 <- fread(args[2])

dmr1_name <- sub("(.*/)(.+)(_min.*)", "\\2", args[1])
dmr2_name <- sub("(.*/)(.+)(_min.*)", "\\2", args[2])

dmr1 <- makeDMRgrange(dmr1)
dmr2 <- makeDMRgrange(dmr2)

hits <- suppressWarnings(findOverlaps(dmr1, dmr2, ignore.strand = TRUE))

# dmr1[queryHits(hits)]
# dmr2[subjectHits(hits)]
# 
# overlaps <- pintersect(dmr1[queryHits(hits)], dmr2[subjectHits(hits)])
# width(overlaps) / width(dmr2[subjectHits(hits)])
# width(overlaps) / width(dmr1[queryHits(hits)])
# 
# hits <- hits[percentOverlap > 0.5]
# TPR <- length(hits) / attr(hits, "nRnode")
# FDR <- (attr(hits, "nLnode") - length(hits)) / attr(hits, "nLnode")

dmr1_hits <- length(unique(queryHits(hits)))
dmr2_hits <- length(unique(subjectHits(hits)))

df_vdc <- data.frame(Counts = c(length(dmr1) - dmr1_hits, length(dmr2) - dmr2_hits, ifelse(dmr1_hits == dmr2_hits, dmr1_hits, paste(dmr1_hits, dmr2_hits, sep = "/")))) %>%
    mutate(x = c(-1, 1, 0), y = c(0, 0, 0))

df_venn <- data.frame(x = c(-0.5, 0.5),
                      y = c(0, 0),
                      labels = c(dmr1_name, dmr2_name))

venn_plot <- ggplot(df_venn) +
    geom_circle(aes(x0 = x, y0 = y, r = 1, fill = labels), alpha = 0.5, size = 1, colour = 'grey40') +
    coord_fixed() +
    theme_void() +
    labs(fill = NULL) +
    annotate("text", x = df_vdc$x, y = df_vdc$y, label = df_vdc$Counts, size = 6) +
    scale_fill_brewer(palette = "Dark2")
ggsave(filename = paste0("06_methylation_results/", dmr1_name, "_", dmr2_name, "_overlap.png"),
       device = "png", plot = venn_plot, width = 3.5, height = 3, units = "in", dpi = 300)
