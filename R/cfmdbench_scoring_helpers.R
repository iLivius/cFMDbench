#!/usr/bin/env Rscript
# cfmdbench_scoring_helpers.R
# Utilities for benchmarking, prediction collection, and metric display.

# ── Label helpers ──────────────────────────────────────────────────────────────

#' Translate mlr3 measure IDs to human-readable labels.
#'
#' mlr3 uses prefixed IDs like "classif.bacc" internally. These are fine for
#' code but cluttered in tables and plots, so we remap them to short plain-
#' English strings before any output is produced.
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
#'
#' mlr3 GraphLearner IDs contain the full pipeline path (e.g.
#' "removeconstants.smote.scale.classif.ranger"), so substring matching is
#' more robust than exact equality here.
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
#' After training, each PipeOp stores its last output in
#' `$graph_model$pipeops[[id]]$.result`. We look at the output of the PipeOp
#' named by `after` (typically the last preprocessing step before the learner,
#' e.g. "smote" or "scale") to verify what the data looked like at that point:
#' how many features survived, and whether SMOTE rebalanced the classes as
#' expected.
#'
#' When the named PipeOp has no valid Task output (e.g. because SMOTE was
#' bypassed via a "nop" branch), the function degrades gracefully and returns
#' just the filter statistics collected from any PipeOpFilter nodes found
#' anywhere in the graph.
#'
#' @param graph_learner A trained GraphLearner (must already be trained).
#' @param after         ID of the PipeOp whose output to inspect (default "smote").
#'   Pass "scale" when SMOTE was not applied.
#' @return A list with elements `features`, `n_features`, `class_distribution`,
#'   `filter_summary`, `features_per_filter`.
cfmdbench_get_preproc_summary <- function(graph_learner, after = "smote") {
  stopifnot(inherits(graph_learner, "GraphLearner"))

  pipeops_out <- graph_learner$graph_model$pipeops
  po_out      <- pipeops_out[[after]]$.result$output

  # Walk all PipeOps regardless of whether po_out is valid, collecting filter
  # statistics (features considered vs. selected by each PipeOpFilter). This
  # is always available after training and is useful for debugging pipelines
  # that use variance, correlation, or information-gain filters.
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

  list(features            = features_summary,
       n_features          = length(features_summary),
       class_distribution  = class_counts,
       filter_summary      = filter_summary,
       features_per_filter = features_per_filter)
}

# ── Load tuned learners for benchmarking ──────────────────────────────────────

#' Load tuned learners from memory (trained_learners list) or disk, prepare
#' them for benchmarking (unmarshal, set threads, retrain on task_train).
#'
#' In-memory learners (from cfmdbench_train_methods()) are preferred over disk
#' because they avoid an RDS round-trip. Disk loading is the fallback for
#' methods that failed or were skipped in the current session but whose saved
#' model files are available from a previous run.
#'
#' mlr3torch (MLP) models are serialised in a "marshalled" state — tensors
#' converted to raw bytes — to make them safe to write to RDS files. They must
#' be unmarshalled before use. The silent try() is intentional: non-torch
#' learners simply do not have an unmarshal() method and that is fine.
#'
#' Thread count is reduced to 1 here because the benchmark() call that follows
#' runs multiple learners in parallel at the outer level. Letting individual
#' learners spawn threads on top of that would over-subscribe the CPU.
#'
#' @param methods          Named character vector of method IDs to load
#'   (from cfmdbench_resolve_methods()).
#' @param trained_learners Named list returned by cfmdbench_train_methods();
#'   entries may be NULL for methods not trained in this session.
#' @param save_dir         Directory where `<method>_tuned_learner.rds` files live.
#' @param task_train       Training task used to re-fit each learner on the
#'   full training set before benchmarking.
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

    # Unmarshal mlr3torch (MLP) models; silently ignored for all other types.
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
#' mlr3's aggregate() output includes bookkeeping columns (nr, resample_result,
#' task_id, resampling_id, iters) that are not useful for reporting. We drop
#' them and rename the metric columns via cfmdbench_label_measure() so the
#' result can be printed or joined with test-set predictions directly.
#'
#' @param bmr          mlr3 BenchmarkResult object.
#' @param bmr_measures Character vector of measure IDs (from bmr_measures in
#'   the parameters chunk; differs between binary and multi-class tasks).
#' @return A data.frame (one row per method) with readable metric column names.
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
#' The prediction chunk uses assign() to write objects named
#' `<method>_test_predict` into the chunk environment. This function discovers
#' them automatically via ls(pattern = ...) so we do not need to maintain an
#' explicit list. The method name is recovered by stripping the known suffix.
#'
#' @param env R environment to search (default: the caller's environment, which
#'   in a qmd chunk is the chunk execution environment).
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

#' Collect all `<method>_pred_df` score vectors from the calling environment,
#' harmonise column names, and return a tidy data.frame that mirrors the
#' structure of the benchmark `bench_df`.
#'
#' Like cfmdbench_gather_pred_tabs(), this relies on the `<method>_pred_df`
#' naming convention set by assign() in the prediction chunk. Scalar metric
#' vectors (a named numeric from pred$score()) are transposed to single-row
#' data.frames before binding. The optional bench_df argument restricts the
#' result to the same columns so it can be compared side-by-side with the
#' cross-validated benchmark scores.
#'
#' @param env      R environment to search.
#' @param bench_df Optional reference data.frame (from cfmdbench_format_bench_df())
#'   used to align columns; pass NULL to keep all.
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
