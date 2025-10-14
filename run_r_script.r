#!/usr/bin/env Rscript

# A robust script for executing user-provided R code (expecting a ggplot object)
# and saving the output as a PNG image.

# --- Argument Parsing ---
args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 2) {
  stop("Usage: Rscript run_r_script.R <input_r_code_file> <output_image_file> [csv_data_file] [img_bg_choice] [chart_bg_choice] [show_grid_flag]", call. = FALSE)
}

input_r_code_file <- args[1]
output_image_file <- args[2]
remaining_args <- if (length(args) > 2) args[3:length(args)] else character(0)

csv_data_file <- NULL
img_bg_choice <- NULL
chart_bg_choice <- NULL
show_grid_flag <- NULL

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

# Optional 6th argument controlling panel grid line visibility (true/false)
if (length(remaining_args) >= 1) {
  show_grid_flag <- remaining_args[1]
  remaining_args <- remaining_args[-1]
}

# Map UI image and chart background selections to colors
resolve_image_bg <- function(choice) {
  if (is.null(choice) || is.na(choice) || choice == "") {
    choice <- "default"
  }
  res <- switch(tolower(choice),
    transparent = list(plot = NA, ggsave = NA, text = "#ffffff", transparent = TRUE),
    white       = list(plot = "#f3f3f3", ggsave = "#f3f3f3", text = "#111827", transparent = FALSE),
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
    blue        = list(panel = "#8ac0db", grid = "#374151"),
    green       = list(panel = "#8adba5", grid = "#065f46"),
    yellow      = list(panel = "#fee14e", grid = "#7c2d12"),
    orange      = list(panel = "#fd732d", grid = "#7c2d12"),
    purple      = list(panel = "#ce8adb", grid = "#4c1d95"),
    teal        = list(panel = "#76d3cf", grid = "#134e4a"),
    # NOTE: Previously 'default' (Dark) used panel = NA which caused the panel to inherit
    # the plot background, making the Chart Background Dark option appear to do nothing.
    # We now supply an explicit near-black panel fill so the distinction is visible.
    default     = list(panel = "#111827", grid = "#374151")
  )
  if (is.null(res)) {
    # Fallback also uses the new dark fill to stay consistent.
    res <- list(panel = "#111827", grid = "#374151")
  }
  res
}

image_bg <- resolve_image_bg(img_bg_choice)
chart_bg <- resolve_chart_bg(if (!is.null(chart_bg_choice) && chart_bg_choice != "") chart_bg_choice else img_bg_choice)

# Determine if panel grid lines should be shown based on optional flag
grid_enabled <- TRUE
if (!is.null(show_grid_flag) && !is.na(show_grid_flag) && nzchar(show_grid_flag)) {
  flag_lower <- tolower(show_grid_flag)
  grid_enabled <- flag_lower %in% c('true', '1', 'yes', 'on')
}

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
  # Ensure a writable user library path exists and is in .libPaths()
  ensure_user_lib <- function() {
    # Honor R_LIBS_USER if set; otherwise construct a sane default
    user_lib <- Sys.getenv("R_LIBS_USER")
    if (identical(user_lib, "")) {
      r_minor <- strsplit(R.version$minor, "\\.")[[1]][1]
      user_lib <- file.path(Sys.getenv("HOME"), "R", paste0(R.version$major, ".", r_minor), "library")
    }
    try({ dir.create(user_lib, recursive = TRUE, showWarnings = FALSE) }, silent = TRUE)
    if (!(user_lib %in% .libPaths())) {
      .libPaths(c(user_lib, .libPaths()))
    }
    invisible(user_lib)
  }

  options(repos = c(CRAN = 'https://cloud.r-project.org'))
  user_lib_path <- ensure_user_lib()

  need_install <- !requireNamespace("ggplot2", quietly = TRUE)
  if (need_install) {
    install_err <- NULL
    tryCatch({
      install.packages("ggplot2", dependencies = TRUE)
    }, error = function(e) {
      install_err <<- conditionMessage(e)
    })
    # Try again to load after install
    if (!requireNamespace("ggplot2", quietly = TRUE)) {
      msg <- paste0(
        "The 'ggplot2' package is not installed and could not be installed. ",
        "Lib paths: ", paste(.libPaths(), collapse = "; "), ". ",
        if (!is.null(install_err)) paste0("Install error: ", install_err) else ""
      )
      stop(msg, call. = FALSE)
    }
  }

  library(ggplot2)
  
  # Other packages are optional but useful.
  if (requireNamespace("dplyr", quietly = TRUE)) {
    library(dplyr)
  }
  if (requireNamespace("readr", quietly = TRUE)) {
    library(readr)
  }
  if (requireNamespace("tidyr", quietly = TRUE)) {
    library(tidyr)
  }
  if (requireNamespace("purrr", quietly = TRUE)) {
    library(purrr)
  }
  if (requireNamespace("stringr", quietly = TRUE)) {
    library(stringr)
  }
  if (requireNamespace("lubridate", quietly = TRUE)) {
    library(lubridate)
  }
})

# --- Data Loading ---
# Load the CSV data into a dataframe named 'df' if it's provided.
if (!is.null(csv_data_file)) {
  df <- tryCatch({
    # Prefer the faster readr::read_csv if available
    suppressMessages({
      if (requireNamespace("readr", quietly = TRUE)) {
        # **FIX: Removed the 'show_col_types' argument for compatibility with older readr versions**
        readr::read_csv(csv_data_file, progress = FALSE)
      } else {
        read.csv(csv_data_file, stringsAsFactors = FALSE, check.names = FALSE)
      }
    })
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
  if (!is.null(csv_data_file)) {
    fallback_df <- df
    missing_file_pattern <- "cannot open|No such file|does not exist|cannot find|not found"

    make_safe_reader <- function(reader_fn) {
      force(reader_fn)
      function(...) {
        if (is.null(reader_fn)) {
          return(fallback_df)
        }
        tryCatch(
          reader_fn(...),
          error = function(e) {
            msg <- conditionMessage(e)
            if (grepl(missing_file_pattern, msg, ignore.case = TRUE)) {
              return(fallback_df)
            }
            stop(e)
          }
        )
      }
    }

    reader_overrides <- list()

    utils_ns <- asNamespace("utils")
    utils_readers <- c("read.csv", "read.csv2", "read.delim", "read.delim2", "read.table")
    for (fname in utils_readers) {
      if (exists(fname, envir = utils_ns, inherits = FALSE)) {
        reader_overrides[[fname]] <- make_safe_reader(get(fname, envir = utils_ns))
      }
    }

    if (requireNamespace("readr", quietly = TRUE)) {
      readr_ns <- asNamespace("readr")
      readr_readers <- c("read_csv", "read_csv2", "read_delim", "read_delim2", "read_tsv", "read_table")
      for (fname in readr_readers) {
        if (exists(fname, envir = readr_ns, inherits = FALSE)) {
          reader_overrides[[fname]] <- make_safe_reader(get(fname, envir = readr_ns))
        }
      }
    } else {
      fallback_names <- c("read_csv", "read_csv2", "read_delim", "read_delim2", "read_tsv", "read_table")
      for (fname in fallback_names) {
        reader_overrides[[fname]] <- function(...) fallback_df
      }
    }

    if (!("read_delim2" %in% names(reader_overrides)) && "read_delim" %in% names(reader_overrides)) {
      reader_overrides[["read_delim2"]] <- reader_overrides[["read_delim"]]
    }

    for (fname in names(reader_overrides)) {
      assign(fname, reader_overrides[[fname]], envir = user_env)
    }
  }

  source(input_r_code_file, local = user_env, chdir = FALSE)
  
  if (exists("p", envir = user_env, inherits = FALSE)) {
    p <- get("p", envir = user_env)
  } else {
    # If 'p' isn't explicitly assigned, try to grab the last plot made.
    p <- ggplot2::last_plot()
  }
  
  if (!inherits(p, "ggplot")) {
    # Look for any ggplot object in the user environment as a fallback
    env_objects <- ls(envir = user_env, all.names = TRUE)
    if (length(env_objects) > 0) {
      for (obj_name in env_objects) {
        if (identical(obj_name, "df")) next
        candidate <- tryCatch(get(obj_name, envir = user_env), error = function(...) NULL)
        if (!is.null(candidate) && inherits(candidate, "ggplot")) {
          p <- candidate
          break
        }
      }
    }
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

  if (isTRUE(grid_enabled)) {
    if (!is.null(chart_bg$grid) && !(length(chart_bg$grid) == 1 && is.na(chart_bg$grid))) {
      theme_args$panel.grid <- element_line(color = chart_bg$grid)
    }
  } else {
    theme_args$panel.grid <- element_blank()
  }

  # Special case: Pie/Donut charts (coord_polar) often show a visible ring
  # along the outer edge due to the panel grid/border. For these charts,
  # blank out panel grid, border, and axis lines/ticks to avoid the ring.
  is_polar_chart <- FALSE
  try({
    is_polar_chart <- inherits(p$coordinates, "CoordPolar")
    if (!is_polar_chart) {
      # Fallback detection via ggplot_build when available
      built <- ggplot2::ggplot_build(p)
      coord_cls <- class(built$layout$coord)
      if (length(coord_cls) > 0) {
        is_polar_chart <- any(grepl("CoordPolar", coord_cls, fixed = TRUE))
      }
    }
  }, silent = TRUE)

  if (isTRUE(is_polar_chart)) {
    theme_args$panel.grid <- element_blank()
    theme_args$panel.border <- element_blank()
    theme_args$axis.ticks <- element_blank()
    theme_args$axis.line <- element_blank()
  }

  p <- p + do.call(theme, theme_args)
  
}, error = function(e) {
  # Clean up the error message to be more user-friendly
  error_msg <- e$message
  
  # Remove R internal prefixes that confuse users
  error_msg <- sub("^Error in.*?:\\s*", "", error_msg)
  error_msg <- sub("^Error:\\s*", "", error_msg)
  
  # Provide more specific messages for common errors
  if (grepl("could not find function", error_msg, ignore.case = TRUE)) {
    error_msg <- paste("Missing R package or function. Make sure all required packages are installed and loaded.")
  } else if (grepl("object.*not found", error_msg, ignore.case = TRUE)) {
    error_msg <- paste("Variable or column not found. Check that your data columns exist and are spelled correctly.")
  } else if (grepl("unexpected", error_msg, ignore.case = TRUE)) {
    error_msg <- paste("Syntax error in your R code. Check for missing commas, brackets, or quotes.")
  } else if (grepl("non-numeric", error_msg, ignore.case = TRUE)) {
    error_msg <- paste("Data type error. You're trying to use numeric operations on non-numeric data.")
  }
  
  # Truncate very long error messages
  if (nchar(error_msg) > 200) {
    error_msg <- paste(substr(error_msg, 1, 200), "...")
  }
  
  stop(paste("R code execution failed:", error_msg), call. = FALSE)
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
  # Clean up ggsave error messages
  error_msg <- e$message
  error_msg <- sub("^Error in.*?:\\s*", "", error_msg)
  
  if (grepl("device.*not found", error_msg, ignore.case = TRUE)) {
    error_msg <- "Unable to create PNG image. This might be a system graphics issue."
  } else if (grepl("invalid", error_msg, ignore.case = TRUE)) {
    error_msg <- "Invalid plot configuration. Check your ggplot settings."
  }
  
  stop(paste("Failed to generate chart image:", error_msg), call. = FALSE)
})

# Final verification
if (!file.exists(output_image_file) || file.size(output_image_file) == 0) {
  stop("Script finished, but the output image file was not created or is empty.", call. = FALSE)
}




