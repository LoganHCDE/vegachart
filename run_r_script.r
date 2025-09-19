#!/usr/bin/env Rscript

# A robust script for executing user-provided R code (expecting a ggplot object)
# and saving the output as a PNG image.

# --- Argument Parsing ---
args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 2) {
  stop("Usage: Rscript run_r_script.R <input_r_code_file> <output_image_file> [csv_data_file]", call. = FALSE)
}

input_r_code_file <- args[1]
output_image_file <- args[2]
csv_data_file <- if (length(args) >= 3) args[3] else NULL

# --- Pre-flight Checks ---
if (!file.exists(input_r_code_file)) {
  stop(paste("Input R code file does not exist:", input_r_code_file), call. = FALSE)
}
if (!is.null(csv_data_file) && !file.exists(csv_data_file)) {
  stop(paste("CSV data file does not exist:", csv_data_file), call. = FALSE)
}

# --- Library Loading ---
# Ensure required packages are available and load them quietly.
suppressPackageStartupMessages({
  if (!requireNamespace("ggplot2", quietly = TRUE)) {
    stop("The 'ggplot2' package is not installed. Please install it in the Docker container or your R environment.", call. = FALSE)
  }
  library(ggplot2)
  
  # Other packages are optional but useful.
  if (requireNamespace("dplyr", quietly = TRUE)) {
    library(dplyr)
  }
  if (requireNamespace("readr", quietly = TRUE)) {
    library(readr)
  }
})

# --- Data Loading ---
# Load the CSV data into a dataframe named 'df' if it's provided.
if (!is.null(csv_data_file)) {
  df <- tryCatch({
    # Prefer the faster readr::read_csv if available
    if (requireNamespace("readr", quietly = TRUE)) {
      # **FIX: Removed the 'show_col_types' argument for compatibility with older readr versions**
      readr::read_csv(csv_data_file, progress = FALSE)
    } else {
      read.csv(csv_data_file, stringsAsFactors = FALSE, check.names = FALSE)
    }
  }, error = function(e) {
    stop(paste("Failed to read CSV data:", e$message), call. = FALSE)
  })
} else {
  # Create an empty dataframe if no data is provided.
  df <- data.frame()
}

# --- Code Execution ---
# Execute the user's script in a clean environment and look for a ggplot object named 'p'.
p <- NULL
tryCatch({
  user_env <- new.env(parent = .GlobalEnv)
  user_env$df <- df # Make the 'df' dataframe available to the script
  source(input_r_code_file, local = user_env, chdir = FALSE)
  
  if (exists("p", envir = user_env, inherits = FALSE)) {
    p <- get("p", envir = user_env)
  } else {
    # If 'p' isn't explicitly assigned, try to grab the last plot made.
    p <- ggplot2::last_plot()
  }
  
  if (!inherits(p, "ggplot")) {
    stop("The R code must produce a ggplot object. Ensure your code creates a plot assigned to a variable named 'p'.", call. = FALSE)
  }
  
  # Apply consistent background and slightly larger margins to prevent clipping.
  p <- p + theme(
    plot.background = element_rect(fill = "#0a0a0a", color = NA),
    plot.margin = margin(t = 20, r = 25, b = 55, l = 15) # Increased bottom margin for rotated labels
  )
  
}, error = function(e) {
  # Catch errors from the user's code and report them clearly.
  stop(paste("Error executing R code:", e$message), call. = FALSE)
})


# --- Image Saving ---
# Save the final plot object to the specified output file.
tryCatch({
  ggsave(
    filename = output_image_file,
    plot = p,
    device = "png",
    width = 7.68,
    height = 4.8,
    units = "in",
    dpi = 150,
    bg = "#0a0a0a",
    limitsize = FALSE
  )
}, error = function(e) {
  stop(paste("Failed to save the ggplot image:", e$message), call. = FALSE)
})

# Final verification
if (!file.exists(output_image_file) || file.size(output_image_file) == 0) {
  stop("Script finished, but the output image file was not created or is empty.", call. = FALSE)
}