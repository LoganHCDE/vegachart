#!/usr/bin/env Rscript

# A robust script for executing user-provided R code (expecting a ggplot object)
# and saving the output as a PNG image.

# --- Argument Parsing ---
args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 2) {
  stop("Usage: Rscript run_r_script.R <input_r_code_file> <output_image_file> [csv_data_file] [img_bg_choice] [chart_bg_choice]", call. = FALSE)
}

input_r_code_file <- args[1]
output_image_file <- args[2]
remaining_args <- if (length(args) > 2) args[3:length(args)] else character(0)

csv_data_file <- NULL
img_bg_choice <- NULL
chart_bg_choice <- NULL

if (length(remaining_args) >= 1) {
  candidate <- remaining_args[1]
  if (!identical(candidate, "") && file.exists(candidate)) {
    csv_data_file <- candidate
    remaining_args <- remaining_args[-1]
  }
}

if (length(remaining_args) >= 1) {
  img_bg_choice <- remaining_args[1]
  remaining_args <- remaining_args[-1]
}

if (length(remaining_args) >= 1) {
  chart_bg_choice <- remaining_args[1]
  remaining_args <- remaining_args[-1]
}

# Map UI image and chart background selections to colors
resolve_image_bg <- function(choice) {
  if (is.null(choice) || is.na(choice) || choice == "") {
    choice <- "default"
  }
  res <- switch(tolower(choice),
    transparent = list(plot = NA, ggsave = NA, text = "#ffffff", transparent = TRUE),
    white       = list(plot = "#ffffff", ggsave = "#ffffff", text = "#111827", transparent = FALSE),
    blue        = list(plot = "#0b1220", ggsave = "#0b1220", text = "#e5e7eb", transparent = FALSE),
    default     = list(plot = "#0a0a0a", ggsave = "#0a0a0a", text = "#ffffff", transparent = FALSE)
  )
  if (is.null(res)) {
    res <- list(plot = "#0a0a0a", ggsave = "#0a0a0a", text = "#ffffff", transparent = FALSE)
  }
  res
}

resolve_chart_bg <- function(choice) {
  if (is.null(choice) || is.na(choice) || choice == "") {
    choice <- "default"
  }
  res <- switch(tolower(choice),
    transparent = list(panel = NA, grid = "gray60"),
    white       = list(panel = "#ffffff", grid = "#d1d5db"),
    blue        = list(panel = "#0b1220", grid = "#374151"),
    green       = list(panel = "#10b981", grid = "#065f46"),
    yellow      = list(panel = "#f59e0b", grid = "#7c2d12"),
    orange      = list(panel = "#fb923c", grid = "#7c2d12"),
    purple      = list(panel = "#8b5cf6", grid = "#4c1d95"),
    teal        = list(panel = "#14b8a6", grid = "#134e4a"),
    default     = list(panel = NA, grid = "#374151")
  )
  if (is.null(res)) {
    res <- list(panel = NA, grid = "#374151")
  }
  res
}

image_bg <- resolve_image_bg(img_bg_choice)
chart_bg <- resolve_chart_bg(if (!is.null(chart_bg_choice) && chart_bg_choice != "") chart_bg_choice else img_bg_choice)

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
  
  # Apply background and margins to respect UI selections
  plot_bg_element <- if (isTRUE(image_bg$transparent)) {
    element_rect(fill = NA, color = NA)
  } else {
    element_rect(fill = image_bg$plot, color = NA)
  }

  panel_bg_element <- element_rect(fill = chart_bg$panel, color = NA)

  theme_args <- list(
    plot.background = plot_bg_element,
    panel.background = panel_bg_element,
    text = element_text(color = image_bg$text),
    plot.margin = margin(t = 20, r = 25, b = 20, l = 15)
  )

  if (!is.null(chart_bg$grid) && !(length(chart_bg$grid) == 1 && is.na(chart_bg$grid))) {
    theme_args$panel.grid <- element_line(color = chart_bg$grid)
  }

  p <- p + do.call(theme, theme_args)
  
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
    bg = if (isTRUE(image_bg$transparent)) NA else image_bg$ggsave,
    limitsize = FALSE
  )
}, error = function(e) {
  stop(paste("Failed to save the ggplot image:", e$message), call. = FALSE)
})

# Final verification
if (!file.exists(output_image_file) || file.size(output_image_file) == 0) {
  stop("Script finished, but the output image file was not created or is empty.", call. = FALSE)
}