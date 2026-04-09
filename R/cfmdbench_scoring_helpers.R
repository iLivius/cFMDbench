#!/usr/bin/env Rscript
# cfmdbench_scoring_helpers.R
# Utilities for benchmarking, prediction collection, and metric display.

# ── Label helpers ──────────────────────────────────────────────────────────────

#' Translate mlr3 measure IDs to human-readable labels.
cfmdbench_label_measure <- function(measure_id) {
  lut <- c(
    classif.acc         = "accuracy",
    classif.bacc        = "balanced accuracy",
    classif.logloss     = "logloss",
    classif.precision   = "precision",
    classif.recall      = "recall",
    classif.specificity = "specificity",
    classif.fbeta       = "f1",
    classif.auc         = "auc",
    classif.prauc       = "pr auc"
  )
  dplyr::recode(measure_id, !!!lut, .default = measure_id)
}

#' Translate learner IDs to display names.
cfmdbench_recode_methods <- function(learner_ids) {
  dplyr::case_when(
    stringr::str_detect(learner_ids, "glmnet")      ~ "GLM elastic net",
    stringr::str_detect(learner_ids, "kknn")        ~ "K-Nearest Neighbor",
    stringr::str_detect(learner_ids, "lda")         ~ "Linear Discriminant Analysis",
    stringr::str_detect(learner_ids, "mlp")         ~ "Multi-layer Perceptron",
    stringr::str_detect(learner_ids, "naive_bayes") ~ "Naive Bayes",
    stringr::str_detect(learner_ids, "ranger")      ~ "Random Forest",
    stringr::str_detect(learner_ids, "svm")         ~ "Support Vector Machine",
    stringr::str_detect(learner_ids, "tabpfn")      ~ "TabPFN",
    stringr::str_detect(learner_ids, "xgboost")     ~ "XGBoost",
    TRUE                                             ~ "Other"
  )
}

# ── Preprocessing pipeline summary ────────────────────────────────────────────

#' Inspect a trained GraphLearner's preprocessing output and return a summary.
#'
#' When the PipeOp referenced by `after` has a valid Task output the function
#' returns features and class distribution. Otherwise it falls back to a table
#' of filter statistics.
#'
#' @param graph_learner A trained GraphLearner (must be trained already).
#' @param after         ID of the PipeOp whose output to inspect (default "smote").
#' @return A list with elements `features`, `n_features`, `class_distribution`,
#'   `filter_summary`, `features_per_filter`.
cfmdbench_get_preproc_summary <- function(graph_learner, after = "smote") {
  stopifnot(inherits(graph_learner, "GraphLearner"))

  pipeops_out <- graph_learner$graph_model$pipeops
  po_out      <- pipeops_out[[after]]$.result$output

  # Fallback: collect filter statistics regardless of po_out validity
  filter_summary      <- data.frame(filter_id = character(),
                                    considered = integer(),
                                    selected   = integer(),
                                    stringsAsFactors = FALSE)
  features_per_filter <- list()

  for (id in names(pipeops_out)) {
    po <- pipeops_out[[id]]
    if (inherits(po, "PipeOpFilter")) {
      considered <- length(po$state$affected_cols)
      selected   <- length(po$state$features)
      filter_summary <- rbind(
        filter_summary,
        data.frame(filter_id  = id,
                   considered = considered,
                   selected   = selected,
                   stringsAsFactors = FALSE)
      )
      features_per_filter[[id]] <- po$state$features
    }
  }

  if (is.null(po_out) || !("Task" %in% class(po_out))) {
    warning(sprintf(
      "PipeOp '%s' has no valid Task output (training may have used a fallback). ",
      after), "Only filter summary available.", call. = FALSE)
    print(filter_summary)
    return(list(features = NA, n_features = NA,
                class_distribution = NA,
                filter_summary = filter_summary,
                features_per_filter = features_per_filter))
  }

  features_summary <- po_out$feature_names
  class_data       <- po_out$data(cols = "target")
  class_counts     <- if ("target" %in% colnames(class_data))
                        table(class_data$target) else NA

  list(features           = features_summary,
       n_features         = length(features_summary),
       class_distribution = class_counts,
       filter_summary     = filter_summary,
       features_per_filter = features_per_filter)
}

# ── Load tuned learners for benchmarking ──────────────────────────────────────

#' Load tuned learners from memory (trained_learners list) or disk, prepare
#' them for benchmarking (unmarshal, set threads, retrain on task_train).
#'
#' @param methods         Named character vector of methods to load.
#' @param trained_learners Named list returned by cfmdbench_train_methods().
#' @param save_dir        Directory where `<method>_tuned_learner.rds` files live.
#' @param task_train      Training task used to re-fit loaded learners.
#' @return Named list of ready-to-benchmark GraphLearner objects.
cfmdbench_load_benchmark_learners <- function(methods, trained_learners,
                                              save_dir, task_train) {
  learners_best <- list()

  for (method in names(methods)) {
    obj <- trained_learners[[method]]

    if (is.null(obj)) {
      path <- file.path(save_dir, paste0(method, "_tuned_learner.rds"))
      if (!file.exists(path)) {
        cat("SKIP:", method, "— no tuned learner in memory or on disk.\n")
        next
      }
      cat("Loading from disk:", path, "\n")
      obj <- tryCatch(readRDS(path),
                      error = function(e) {
                        cat("Error loading", method, ":", e$message, "\n"); NULL
                      })
      if (is.null(obj)) next
    } else {
      cat("Using in-memory learner:", method, "\n")
    }

    # Unmarshal mlr3torch models
    try(obj$unmarshal(), silent = TRUE)

    obj <- tryCatch(mlr3::set_threads(obj, n = 1L),
                    error = function(e) {
                      cat("Error setting threads for", method, ":", e$message, "\n"); NULL
                    })
    if (is.null(obj)) next

    cat(" Training:", method, "\n")
    tryCatch({
      obj$train(task_train)
      learners_best[[method]] <- obj
      cat(" OK:", method, "\n")
    }, error = function(e) {
      cat("Error training", method, ":", e$message, "\n")
    })
  }

  learners_best
}

# ── Aggregate benchmark results ────────────────────────────────────────────────

#' Convert a BenchmarkResult aggregate to a tidy data.frame with readable labels.
#'
#' @param bmr          mlr3 BenchmarkResult object.
#' @param bmr_measures Character vector of measure IDs.
#' @return A data.frame (one row per method) with renamed metric columns.
cfmdbench_format_bench_df <- function(bmr, bmr_measures) {
  bench_df <- as.data.frame(bmr$aggregate(measures = lapply(bmr_measures, mlr3::msr)))

  bench_df %>%
    dplyr::mutate(method = cfmdbench_recode_methods(learner_id)) %>%
    dplyr::relocate(method) %>%
    dplyr::select(-nr, -resample_result, -task_id, -resampling_id, -iters) %>%
    dplyr::rename_with(cfmdbench_label_measure) %>%
    dplyr::mutate(dplyr::across(dplyr::where(is.numeric), ~ round(.x, 4L)))
}

# ── Test-set prediction collection ────────────────────────────────────────────

#' Collect all `<method>_test_predict` data.frames from the calling environment
#' and bind them into one long data.frame with a `method` column.
#'
#' @param env R environment to search (default: parent of this function's caller).
cfmdbench_gather_pred_tabs <- function(env = parent.frame()) {
  objs <- ls(envir = env, pattern = "_test_predict$")
  if (!length(objs)) stop("No *_test_predict objects found in the environment.")

  lapply(objs, function(nm) {
    df <- get(nm, envir = env)
    df$learner_id <- sub("_test_predict$", "", nm)
    df
  }) %>%
    dplyr::bind_rows() %>%
    dplyr::mutate(method = cfmdbench_recode_methods(learner_id))
}

#' Collect all `<method>_pred_df` vectors / data.frames from the calling
#' environment, harmonise column names, and return a tidy data.frame that
#' mirrors the structure of the benchmark `bench_df`.
#'
#' @param env      R environment to search.
#' @param bench_df Optional reference data.frame used to align column order.
cfmdbench_gather_pred_performance <- function(env = parent.frame(), bench_df = NULL) {
  pred_df_names <- ls(envir = env, pattern = "_pred_df$")
  if (!length(pred_df_names)) stop("No *_pred_df objects found in the environment.")

  pred_list <- lapply(pred_df_names, function(nm) {
    x <- get(nm, envir = env)
    if (!is.data.frame(x)) x <- as.data.frame(t(x))
    x$method <- sub("_pred_df$", "", nm)
    x
  })

  pred_df <- dplyr::bind_rows(pred_list) %>%
    dplyr::relocate(method) %>%
    dplyr::rename_with(cfmdbench_label_measure) %>%
    dplyr::rename(learner_id = method) %>%
    dplyr::mutate(
      method = cfmdbench_recode_methods(learner_id),
      dplyr::across(dplyr::where(is.numeric), ~ round(.x, 4L))
    )

  if (!is.null(bench_df)) {
    common_cols <- intersect(names(bench_df), names(pred_df))
    pred_df     <- pred_df[, common_cols, drop = FALSE]
  }

  pred_df
}
