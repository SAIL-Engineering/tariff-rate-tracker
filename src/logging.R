# =============================================================================
# Logging Module for Tariff Rate Tracker
# =============================================================================
#
# Simple log-to-console-and-file wrapper. No external packages required.
#
# Usage:
#   source('src/logging.R')
#   init_logging('output/logs/pipeline.log', level = 'info')
#   log_info('Processing revision: ', rev_id)
#   log_warn('Missing data for country: ', cty)
#   log_error('Failed to parse JSON: ', path)
#   log_debug('Row count: ', nrow(df))
#
# =============================================================================

# Module-local environment for logging state
if (!exists('.log_env') || !is.environment(.log_env)) {
  .log_env <- new.env(parent = emptyenv())
  .log_env$log_file <- NULL
  .log_env$log_level <- 'info'
  .log_env$initialized <- FALSE
}

# Numeric log levels for comparison
.LOG_LEVELS <- c(debug = 1L, info = 2L, warn = 3L, error = 4L)


#' Initialize logging
#'
#' Sets up log file and level. Creates parent directories if needed.
#'
#' @param log_file Path to log file (NULL for console-only)
#' @param level Minimum log level: 'debug', 'info', 'warn', 'error'
#' @return Invisible NULL
init_logging <- function(log_file = NULL, level = 'info') {
  level <- tolower(level)
  if (!level %in% names(.LOG_LEVELS)) {
    stop('Invalid log level: ', level, '. Use: debug, info, warn, error')
  }

  .log_env$log_level <- level
  .log_env$initialized <- TRUE


  if (!is.null(log_file)) {
    log_dir <- dirname(log_file)
    if (!dir.exists(log_dir)) {
      dir.create(log_dir, recursive = TRUE)
    }
    .log_env$log_file <- log_file
    # Write header
    header <- paste0(
      '# Tariff Rate Tracker Log\n',
      '# Started: ', Sys.time(), '\n',
      '# Level: ', level, '\n',
      strrep('#', 60), '\n'
    )
    cat(header, file = log_file, append = FALSE)

    # Tee plain message() output into the log as well.
    #
    # init_logging() only ever captured log_info() calls, and the pipeline
    # barely uses them: 00_build_timeseries.R has 9, while 06_calculate_rates.R
    # has ZERO and emits 85 message() calls. Every per-revision diagnostic —
    # dual-content derivatives, EO 14289 suppressions, Column 2 re-basing, the
    # §201 drops — went to stderr and was lost unless the operator happened to
    # redirect it. A 14-hour build whose findings exist only in a terminal
    # scrollback is not reviewable.
    #
    # The handler does NOT muffle, so the message still reaches the console; it
    # is duplicated, not diverted. Warnings are teed too, since a warning is
    # exactly the thing you want to find afterwards.
    if (exists('globalCallingHandlers')) {
      .log_env$tee_con <- file(log_file, open = 'at')
      globalCallingHandlers(
        message = function(m) {
          # .log_write() emits via message() AND writes the file itself, so
          # without this guard every log_info() would be recorded twice.
          if (isTRUE(.log_env$in_log_write)) return(invisible(NULL))
          try(cat(conditionMessage(m), file = .log_env$tee_con, sep = ''), silent = TRUE)
          try(flush(.log_env$tee_con), silent = TRUE)
        },
        warning = function(w) {
          try(cat('[WARNING] ', conditionMessage(w), '\n',
                  file = .log_env$tee_con, sep = ''), silent = TRUE)
          try(flush(.log_env$tee_con), silent = TRUE)
        }
      )
    }
  } else {
    .log_env$log_file <- NULL
  }

  return(invisible(NULL))
}


#' Write a log message
#'
#' @param level Character log level
#' @param ... Message parts (pasted together)
.log_write <- function(level, ...) {
  # Check level threshold
  if (.LOG_LEVELS[level] < .LOG_LEVELS[.log_env$log_level]) {
    return(invisible(NULL))
  }

  msg_body <- paste0(...)
  timestamp <- format(Sys.time(), '%Y-%m-%d %H:%M:%S')
  tag <- toupper(level)
  formatted <- paste0('[', timestamp, '] [', tag, '] ', msg_body)

  # Console output. Flagged so the message() tee handler installed by
  # init_logging() does not record this line a second time.
  .log_env$in_log_write <- TRUE
  on.exit(.log_env$in_log_write <- FALSE, add = TRUE)
  message(formatted)

  # File output
  if (!is.null(.log_env$log_file)) {
    cat(formatted, '\n', file = .log_env$log_file, append = TRUE, sep = '')
  }

  return(invisible(NULL))
}


#' Log an informational message
#'
#' @param ... Message parts
log_info <- function(...) {
  .log_write('info', ...)
}


#' Log a warning message
#'
#' @param ... Message parts
log_warn <- function(...) {
  .log_write('warn', ...)
}


#' Log an error message
#'
#' @param ... Message parts
log_error <- function(...) {
  .log_write('error', ...)
}


#' Log a debug message
#'
#' @param ... Message parts
log_debug <- function(...) {
  .log_write('debug', ...)
}
