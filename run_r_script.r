#!/usr/bin/env Rscript

# Standalone R script for executing user R code via subprocess
# Arguments: input_r_code_file output_image_file [csv_data_file]

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 2) {
  stop("Usage: Rscript run_r_script.R <input_r_code_file> <output_image_file> [csv_data_file]")
}

input_r_code_file <- args[1]
output_image_file <- args[2]
csv_data_file <- if (length(args) >= 3) args[3] else NULL

if (!file.exists(input_r_code_file)) {
  stop(paste("Input R code file does not exist:", input_r_code_file))
}
if (!is.null(csv_data_file) && !file.exists(csv_data_file)) {
  stop(paste("CSV data file does not exist:", csv_data_file))
}

# Diagnostics
cat("R version:", paste(R.version$major, R.version$minor, sep = "."), "\n")
cat("Platform:", R.version$platform, "\n")
cat("Capabilities(cairo):", tryCatch(isTRUE(capabilities("cairo")), error = function(e) FALSE), "\n")
cat("Env VC_USE_RAGG:", Sys.getenv("VC_USE_RAGG", "0"), "\n")
cat("Input file:", input_r_code_file, "\n")
cat("Output file:", output_image_file, "\n")

# Load required libraries
cat("Loading libraries...\n")
tryCatch({
  suppressPackageStartupMessages({
    if (!requireNamespace("ggplot2", quietly = TRUE)) {
      stop("The 'ggplot2' package is not installed. Please install it in R with: install.packages('ggplot2')")
    }
    library(ggplot2)
    # dplyr is optional; load if available
    if (requireNamespace("dplyr", quietly = TRUE)) {
      library(dplyr)
    }
  })
  cat("Libraries loaded OK\n")
}, error = function(e) {
  stop(paste("Failed to load required packages:", e$message))
})

# On Windows, prefer Cairo
if (.Platform$OS.type == "windows") {
  options(bitmapType = "cairo")
}

# Load CSV data (if provided)
if (!is.null(csv_data_file)) {
  df <- tryCatch({
    if (requireNamespace("readr", quietly = TRUE)) {
      readr::read_csv(csv_data_file, show_col_types = FALSE)
    } else {
      read.csv(csv_data_file, stringsAsFactors = FALSE, check.names = FALSE)
    }
  }, error = function(e1) {
    warning(paste("readr::read_csv failed (", e1$message, "); falling back to base::read.csv", sep = ""))
    read.csv(csv_data_file, stringsAsFactors = FALSE, check.names = FALSE)
  })
  cat(paste("Loaded CSV data with", nrow(df), "rows and", ncol(df), "columns\n"))
} else {
  df <- data.frame()
  cat("No CSV provided; using empty df\n")
}

# Execute user R code; expect ggplot object 'p'
p <- NULL
tryCatch({
  cat("Executing user R code...\n")
  user_env <- new.env(parent = .GlobalEnv)
  user_env$df <- df
  sys.source(input_r_code_file, envir = user_env, chdir = FALSE)
  if (!exists("p", envir = user_env, inherits = FALSE)) {
    # Fallback: try to use last ggplot if available
    last <- try(ggplot2::last_plot(), silent = TRUE)
    if (!inherits(last, "try-error") && inherits(last, "ggplot")) {
      p <- last
      assign("p", p, envir = user_env)
      cat("'p' not found; using ggplot2::last_plot() as fallback\n")
    } else {
      stop("The R code must create a plot object named 'p'. Please ensure your R code ends with: p <- ggplot(...) + ...")
    }
  } else {
    p <- get("p", envir = user_env)
  }
  if (!inherits(p, "ggplot")) {
    if (inherits(p, "recordedplot") || is.function(p)) {
      stop("The object 'p' appears to be a base R plot. Please use ggplot2 for creating plots.")
    } else {
      stop(paste("The object 'p' must be a ggplot object. Current class:", paste(class(p), collapse = ", ")))
    }
  }
  cat(sprintf("Plot object 'p' found (class: %s)\n", paste(class(p), collapse = ", ")))
  # Normalize background and margins
  bg_color <- "#0a0a0a"
  p <- p + ggplot2::theme(
    plot.background = ggplot2::element_rect(fill = bg_color, color = NA),
    # UPDATED: Increased margins to prevent labels from being cut off.
    # The bottom margin (b) is larger to account for rotated x-axis text.
    plot.margin = ggplot2::margin(t = 15, r = 25, b = 45, l = 15)
  )
}, error = function(e) {
  stop(paste("Error executing R code:", e$message))
})

# Save plot with fallbacks
target_width_in <- 6.4
target_height_in <- 4.8
target_dpi <- 150
bg_color <- "#0a0a0a"
output_dir <- dirname(output_image_file)
if (!dir.exists(output_dir)) dir.create(output_dir, recursive = TRUE)

# Validate plot build
tryCatch({
  built_plot <- ggplot2::ggplot_build(p)
  if (is.null(built_plot)) stop("Plot build returned NULL")
  if (length(built_plot$data) == 0) warning("Built plot has no data layers; saving anyway")
}, error = function(e) {
  stop(paste("Plot validation failed:", e$message))
})

# Avoid ragg by default; opt-in via VC_USE_RAGG=1
use_ragg <- FALSE
if (identical(tolower(Sys.getenv("VC_USE_RAGG", "0")), "1")) {
  use_ragg <- isTRUE(requireNamespace("ragg", quietly = TRUE))
}
cat(sprintf("Saving plot (ragg=%s, cairo=%s)\n", use_ragg, isTRUE(capabilities("cairo"))))

save_ok <- FALSE
save_err <- NULL

# 1) Optional ragg path
if (!save_ok && use_ragg) {
  try({
    ragg::agg_png(
      filename = output_image_file,
      width = as.integer(target_width_in * target_dpi),
      height = as.integer(target_height_in * target_dpi),
      background = bg_color,
      res = target_dpi
    )
    print(p)
    dev.off()
    save_ok <- TRUE
  }, silent = TRUE)
}

# 2) ggsave with cairo when available
if (!save_ok) {
  tryCatch({
    if (isTRUE(capabilities("cairo"))) {
      ggsave(
        filename = output_image_file,
        plot = p,
        width = target_width_in,
        height = target_height_in,
        dpi = target_dpi,
        units = "in",
        bg = bg_color,
        device = "png",
        type = "cairo",
        limitsize = FALSE
      )
    } else {
      ggsave(
        filename = output_image_file,
        plot = p,
        width = target_width_in,
        height = target_height_in,
        dpi = target_dpi,
        units = "in",
        bg = bg_color,
        device = "png",
        limitsize = FALSE
      )
    }
    save_ok <- TRUE
  }, error = function(e) { save_err <<- e })
}

# 3) Fallback: base png()
if (!save_ok) {
  tryCatch({
    if (isTRUE(capabilities("cairo"))) {
      png(
        filename = output_image_file,
        width = as.integer(target_width_in * target_dpi),
        height = as.integer(target_height_in * target_dpi),
        res = target_dpi,
        bg = bg_color,
        type = "cairo"
      )
    } else {
      png(
        filename = output_image_file,
        width = as.integer(target_width_in * target_dpi),
        height = as.integer(target_height_in * target_dpi),
        res = target_dpi,
        bg = bg_color
      )
    }
    print(p)
    dev.off()
    save_ok <- TRUE
  }, error = function(e) { save_err <<- e })
}

if (!save_ok) {
  stop(paste("Failed to save plot with all devices.", if (!is.null(save_err)) paste("Last error:", save_err$message) else ""))
}

# Verify output
if (!file.exists(output_image_file)) stop("Output image file was not created")
file_size <- file.size(output_image_file)
if (is.na(file_size) || file_size == 0) stop("Output image file is empty")

cat(sprintf(
  "R script execution completed successfully (%dx%d px). Output file size: %d bytes\n",
  as.integer(target_width_in * target_dpi),
  as.integer(target_height_in * target_dpi),
  file_size
))
