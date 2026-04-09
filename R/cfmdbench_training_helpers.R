#!/usr/bin/env Rscript
# cfmdbench_training_helpers.R
# Build learners, configure pipelines, define search spaces, run the
# inner-CV tuning loop, and save tuned models to disk.

# ── Learner construction ───────────────────────────────────────────────────────

#' Build the full set of base learner objects (all methods, pre-method-selection).
#' Only learners in `methods` will actually be used; building all is cheap.
#'
#' @param seed    Random seed forwarded to MLP / TabPFN.
#' @param kfold   Number of folds (used for MLP num_threads).
#' @return Named list of mlr3 Learner objects.
cfmdbench_build_learners <- function(seed = 42L, kfold = 10L) {
  learners <- list(
    glmnet      = mlr3learners::lrn("classif.glmnet",      predict_type = "prob"),
    kknn        = mlr3learners::lrn("classif.kknn",        predict_type = "prob"),
    lda         = mlr3learners::lrn("classif.lda",         predict_type = "prob"),
    naive_bayes = mlr3learners::lrn("classif.naive_bayes", predict_type = "prob"),
    ranger      = mlr3learners::lrn("classif.ranger",      predict_type = "prob"),
    svm         = mlr3learners::lrn("classif.svm",
                                     type = "C-classification",
                                     predict_type = "prob"),
    xgboost     = mlr3learners::lrn("classif.xgboost",     predict_type = "prob")
  )

  # MLP (mlr3torch) — only if loaded
  if (requireNamespace("mlr3torch", quietly = TRUE)) {
    learners$mlp <- mlr3torch::lrn(
      "classif.mlp",
      activation        = torch::nn_relu,
      loss              = mlr3torch::t_loss("cross_entropy"),
      device            = "auto",
      optimizer         = mlr3torch::t_opt("adamw"),
      measures_valid    = mlr3::msrs(c("classif.bacc", "classif.logloss")),
      measures_train    = mlr3::msrs(c("classif.bacc", "classif.logloss")),
      callbacks         = list(mlr3torch::t_clbk("history"),
                               mlr3torch::t_clbk("progress")),
      validate          = NULL,
      eval_freq         = 5L,
      predict_type      = "prob",
      patience          = 3L,
      min_delta         = 0.01,
      num_threads       = kfold,
      seed              = seed,
      jit_trace         = TRUE
    )
  }

  # TabPFN (reticulate / mlr3extralearners) — only if loaded
  if (requireNamespace("mlr3extralearners", quietly = TRUE) &&
      "classif.tabpfn" %in% mlr3::mlr_learners$keys()) {
    learners$tabpfn <- mlr3extralearners::lrn(
      "classif.tabpfn",
      ignore_pretraining_limits = TRUE,
      device                    = "auto",
      balance_probabilities     = TRUE,
      predict_type              = "prob",
      n_jobs                    = 1L
    )
  }

  learners
}

# ── Resampling strategy ────────────────────────────────────────────────────────

#' Select inner-CV resampling based on dataset size and method.
cfmdbench_choose_tuning_resampling <- function(method, min_count, num_obs,
                                               kfold = 10L, repeats = 5L) {
  if (min_count <= kfold) {
    mlr3::rsmp("bootstrap", repeats = repeats, ratio = 1)
  } else if (num_obs >= 500L || method %in% c("mlp", "tabpfn", "xgboost")) {
    mlr3::rsmp("cv", folds = kfold)
  } else {
    mlr3::rsmp("repeated_cv", repeats = repeats, folds = kfold)
  }
}

# ── Learner pipeline ───────────────────────────────────────────────────────────

#' Combine preprocessing_pipe with the base learner into a GraphLearner.
#' Inserts a subsampler (fast_tuning) or a PCA step (lda) as appropriate.
cfmdbench_build_learner_pipe <- function(method, base_learner,
                                         preprocessing_pipe, fast_tuning) {
  if (fast_tuning && method %in% c("glmnet", "kknn", "naive_bayes", "svm")) {
    preprocessing_pipe %>>%
      mlr3pipelines::po("subsample") %>>%
      base_learner
  } else if (fast_tuning && method == "lda") {
    preprocessing_pipe %>>%
      mlr3pipelines::po("subsample") %>>%
      mlr3pipelines::po("pca") %>>%
      base_learner
  } else if (!fast_tuning && method == "lda") {
    preprocessing_pipe %>>%
      mlr3pipelines::po("pca") %>>%
      base_learner
  } else {
    preprocessing_pipe %>>% base_learner
  }
}

# ── Search spaces ──────────────────────────────────────────────────────────────

#' Return the paradox search space for a given method and tuning mode.
#'
#' @param method        Method ID string.
#' @param fast_tuning   Logical; TRUE = budget-parameter search spaces.
#' @param num_feat      Number of features in the training task.
#' @param num_obs       Number of rows in the training task.
#' @param preproc_params List of preprocessing paradox parameters to prepend.
#' @param kfold         Number of CV folds (used for MLP epoch budget).
#' @param eval_metrics  Named vector for xgboost (binary or multi-class).
#' @param base_learner  The base learner; mutated in-place for xgboost/tabpfn.
cfmdbench_get_search_space <- function(method, fast_tuning, num_feat, num_obs,
                                       preproc_params = list(), kfold = 10L,
                                       eval_metrics = c("merror", "mlogloss"),
                                       base_learner = NULL) {
  p_dbl <- paradox::p_dbl; p_int <- paradox::p_int; p_fct <- paradox::p_fct

  if (fast_tuning) {
    learner_params <- switch(method,
      glmnet = list(
        subsample.frac           = p_dbl(0.1, 1.0, tags = "budget"),
        classif.glmnet.s         = p_dbl(1e-4, 1e4, logscale = TRUE),
        classif.glmnet.alpha     = p_dbl(0, 1)
      ),
      kknn = list(
        subsample.frac    = p_dbl(0.1, 1.0, tags = "budget"),
        classif.kknn.k    = p_int(1, 50, logscale = TRUE)
      ),
      lda = list(
        subsample.frac        = p_dbl(0.1, 1.0, tags = "budget"),
        pca.rank.             = p_int(2L, min(num_feat, num_obs - 1L)),
        classif.lda.method    = p_fct(levels = c("moment", "mle", "mve", "t")),
        classif.lda.tol       = p_dbl(1e-6, 1e-2, logscale = TRUE),
        classif.lda.nu        = p_int(3L, 10L,
                                      depends = quote(classif.lda.method == "t"))
      ),
      mlp = list(
        classif.mlp.neurons       = p_int(32L, 512L, tags = "budget"),
        classif.mlp.n_layers      = p_int(1L, 3L),
        classif.mlp.batch_size    = p_int(32L, 32L),
        classif.mlp.epochs        = p_int(upper = 100L, tags = "internal_tuning",
                                          aggr = function(x) as.integer(mean(unlist(x)))),
        classif.mlp.p             = p_dbl(0.1, 0.5),
        classif.mlp.opt.lr        = p_dbl(1e-4, 1e-1, logscale = TRUE),
        classif.mlp.opt.weight_decay = p_dbl(1e-5, 1e-3, logscale = TRUE)
      ),
      naive_bayes = list(
        subsample.frac                    = p_dbl(0.1, 1.0, tags = "budget"),
        classif.naive_bayes.eps           = p_dbl(1e-9, 0.2),
        classif.naive_bayes.laplace       = p_dbl(1e-6, 2),
        classif.naive_bayes.threshold     = p_dbl(1e-9, 0.1)
      ),
      ranger = list(
        classif.ranger.num.trees       = p_int(10L, 1000L, tags = "budget"),
        classif.ranger.mtry.ratio      = p_dbl(0.1, 1),
        classif.ranger.sample.fraction = p_dbl(0.1, 1)
      ),
      svm = list(
        subsample.frac        = p_dbl(0.1, 1.0, tags = "budget"),
        classif.svm.kernel    = p_fct(levels = c("polynomial", "radial", "sigmoid")),
        classif.svm.cost      = p_dbl(1e-4, 1e4, logscale = TRUE),
        classif.svm.gamma     = p_dbl(1e-4, 1e4, logscale = TRUE,
                                      depends = quote(classif.svm.kernel %in%
                                                      c("polynomial", "radial"))),
        classif.svm.degree    = p_int(1L, 5L,
                                      depends = quote(classif.svm.kernel == "polynomial"))
      ),
      tabpfn = {
        if (!is.null(base_learner))
          base_learner$encapsulate("callr",
            fallback = mlr3::lrn("classif.featureless", predict_type = "prob"))
        list(
          classif.tabpfn.n_estimators       = p_int(4L, 4L),
          classif.tabpfn.softmax_temperature = p_dbl(0.9, 0.9)
        )
      },
      xgboost = {
        if (!is.null(base_learner))
          base_learner$param_set$set_values(
            eval_metric = eval_metrics, early_stopping_rounds = 10L)
        list(
          classif.xgboost.nrounds            = p_int(10L, 1000L, tags = "budget"),
          classif.xgboost.eta                = p_dbl(1e-4, 1, logscale = TRUE),
          classif.xgboost.max_depth          = p_int(1L, 20L),
          classif.xgboost.colsample_bytree   = p_dbl(0.1, 1),
          classif.xgboost.colsample_bylevel  = p_dbl(0.1, 1),
          classif.xgboost.lambda             = p_dbl(1e-3, 1e3, logscale = TRUE),
          classif.xgboost.alpha              = p_dbl(1e-3, 1e3, logscale = TRUE),
          classif.xgboost.subsample          = p_dbl(0.1, 1)
        )
      },
      stop(sprintf("No fast search space defined for method '%s'.", method))
    )
  } else {
    learner_params <- switch(method,
      glmnet = list(
        classif.glmnet.s     = p_dbl(1e-4, 1e4, logscale = TRUE),
        classif.glmnet.alpha = p_dbl(0, 1)
      ),
      kknn = list(
        classif.kknn.k = p_int(1L, 50L, logscale = TRUE)
      ),
      lda = list(
        pca.rank.          = p_int(2L, min(num_feat, num_obs - 1L)),
        classif.lda.method = p_fct(levels = c("moment", "mle", "mve", "t")),
        classif.lda.tol    = p_dbl(1e-6, 1e-2, logscale = TRUE),
        classif.lda.nu     = p_int(3L, 10L,
                                   depends = quote(classif.lda.method == "t"))
      ),
      mlp = list(
        classif.mlp.n_layers = p_int(1L, 3L),
        l1 = p_int(32L, 512L),
        l2 = p_int(32L, 512L),
        l3 = p_int(32L, 512L),
        .extra_trafo = function(x, ps) {
          nL     <- x[["classif.mlp.n_layers"]]
          widths <- as.integer(unlist(x[c("l1", "l2", "l3")], use.names = FALSE))
          x[["classif.mlp.neurons"]] <- widths[seq_len(nL)]
          x[c("classif.mlp.n_layers", "l1", "l2", "l3")] <- NULL
          x
        },
        classif.mlp.epochs     = p_int(upper = 1000L, tags = "internal_tuning",
                                       aggr = function(x) as.integer(mean(unlist(x)))),
        classif.mlp.batch_size = p_int(16L, 64L, tags = "budget"),
        classif.mlp.p          = p_dbl(0.1, 0.5),
        classif.mlp.opt.lr     = p_dbl(1e-4, 1e-1, logscale = TRUE),
        classif.mlp.opt.weight_decay = p_dbl(1e-5, 1e-3, logscale = TRUE)
      ),
      naive_bayes = list(
        classif.naive_bayes.eps       = p_dbl(1e-9, 0.2),
        classif.naive_bayes.laplace   = p_dbl(1e-6, 2),
        classif.naive_bayes.threshold = p_dbl(1e-9, 0.1)
      ),
      ranger = list(
        classif.ranger.num.trees       = p_int(10L, 1000L, tags = "budget"),
        classif.ranger.mtry.ratio      = p_dbl(0.1, 1),
        classif.ranger.sample.fraction = p_dbl(0.1, 1)
      ),
      svm = list(
        classif.svm.kernel = p_fct(levels = c("polynomial", "radial", "sigmoid")),
        classif.svm.cost   = p_dbl(1e-4, 1e4, logscale = TRUE),
        classif.svm.gamma  = p_dbl(1e-4, 1e4, logscale = TRUE,
                                   depends = quote(classif.svm.kernel %in%
                                                   c("polynomial", "radial"))),
        classif.svm.degree = p_int(1L, 5L,
                                   depends = quote(classif.svm.kernel == "polynomial"))
      ),
      tabpfn = {
        if (!is.null(base_learner))
          base_learner$encapsulate("callr",
            fallback = mlr3::lrn("classif.featureless", predict_type = "prob"))
        list(
          classif.tabpfn.n_estimators        = p_int(4L, 4L),
          classif.tabpfn.softmax_temperature = p_dbl(0.9, 0.9)
        )
      },
      xgboost = {
        if (!is.null(base_learner))
          base_learner$param_set$set_values(
            eval_metric = eval_metrics, early_stopping_rounds = 10L)
        list(
          classif.xgboost.nrounds           = p_int(10L, 1000L, tags = "budget"),
          classif.xgboost.eta               = p_dbl(1e-4, 1, logscale = TRUE),
          classif.xgboost.max_depth         = p_int(1L, 20L),
          classif.xgboost.colsample_bytree  = p_dbl(0.1, 1),
          classif.xgboost.colsample_bylevel = p_dbl(0.1, 1),
          classif.xgboost.lambda            = p_dbl(1e-3, 1e3, logscale = TRUE),
          classif.xgboost.alpha             = p_dbl(1e-3, 1e3, logscale = TRUE),
          classif.xgboost.subsample         = p_dbl(0.1, 1)
        )
      },
      stop(sprintf("No search space defined for method '%s'.", method))
    )
  }

  # Add MLP layer dependencies when not fast-tuning
  ss <- do.call(paradox::ps, c(preproc_params, learner_params))
  if (!fast_tuning && method == "mlp") {
    ss$add_dep("l2", on = "classif.mlp.n_layers", paradox::CondAnyOf$new(2:3))
    ss$add_dep("l3", on = "classif.mlp.n_layers", paradox::CondEqual$new(3L))
  }
  ss
}

# ── Final learner configuration ────────────────────────────────────────────────

#' Set id, threading, validation split, and optional callr encapsulation on the
#' assembled GraphLearner.
cfmdbench_configure_final_learner <- function(method, final_learner,
                                              num_threads, num_jobs,
                                              fast_tuning, learner_fallback,
                                              kfold = 10L) {
  final_learner$id                     <- method
  final_learner$graph$keep_results     <- TRUE

  if (method %in% c("mlp", "xgboost"))
    mlr3::set_validate(final_learner, 0.2)

  if (method %in% c("ranger", "xgboost"))
    mlr3::set_threads(final_learner, n = ceiling(num_threads / num_jobs))

  if (learner_fallback && method != "tabpfn")
    final_learner$encapsulate("callr",
      fallback = mlr3::lrn("classif.featureless", predict_type = "prob"))

  final_learner
}

# ── Tuners & terminators ───────────────────────────────────────────────────────

#' Return the mlr3tuning tuner for a given method.
cfmdbench_get_tuner <- function(method, fast_tuning, num_threads, num_jobs) {
  bs <- floor(num_threads / num_jobs)
  if (fast_tuning) {
    switch(method,
      glmnet      = mlr3tuning::tnr("successive_halving", eta = 2, repetitions = 3),
      kknn        = mlr3tuning::tnr("successive_halving", eta = 2, repetitions = 3),
      lda         = mlr3tuning::tnr("successive_halving", eta = 2, repetitions = 3),
      mlp         = mlr3hyperband::tnr("hyperband", eta = 2, repetitions = 1),
      naive_bayes = mlr3tuning::tnr("successive_halving", eta = 2, repetitions = 3),
      svm         = mlr3tuning::tnr("successive_halving", eta = 2, repetitions = 3),
      tabpfn      = mlr3tuning::tnr("grid_search", resolution = 3, batch_size = bs),
      ranger      = mlr3hyperband::tnr("hyperband", eta = 2, repetitions = 1),
      xgboost     = mlr3hyperband::tnr("hyperband", eta = 3, repetitions = 1),
      stop(sprintf("No fast tuner defined for '%s'.", method))
    )
  } else {
    switch(method,
      glmnet      = mlr3tuning::tnr("grid_search", resolution = 5, batch_size = bs),
      kknn        = mlr3tuning::tnr("grid_search", resolution = 5, batch_size = bs),
      lda         = mlr3tuning::tnr("grid_search", resolution = 5, batch_size = bs),
      mlp         = mlr3hyperband::tnr("hyperband", eta = 2, repetitions = 3),
      naive_bayes = mlr3tuning::tnr("grid_search", resolution = 5, batch_size = bs),
      svm         = mlr3tuning::tnr("grid_search", resolution = 5, batch_size = bs),
      tabpfn      = mlr3tuning::tnr("grid_search", resolution = 3, batch_size = bs),
      ranger      = mlr3hyperband::tnr("hyperband", eta = 2, repetitions = 3),
      xgboost     = mlr3hyperband::tnr("hyperband", eta = 2, repetitions = 3),
      stop(sprintf("No tuner defined for '%s'.", method))
    )
  }
}

#' Return the mlr3tuning terminator for a given method.
cfmdbench_get_terminator <- function(method, kfold = 10L, term_min = 20) {
  switch(method,
    glmnet      = mlr3tuning::trm("none"),
    kknn        = mlr3tuning::trm("none"),
    lda         = mlr3tuning::trm("none"),
    mlp         = mlr3tuning::trm("evals", n_evals = 250L %/% kfold),
    naive_bayes = mlr3tuning::trm("none"),
    svm         = mlr3tuning::trm("run_time", secs = 60 * term_min),
    tabpfn      = mlr3tuning::trm("combo", list(
                    mlr3tuning::trm("evals",    n_evals = 50L %/% kfold),
                    mlr3tuning::trm("run_time", secs = 60 * term_min)
                  ), any = TRUE),
    ranger      = mlr3tuning::trm("combo", list(
                    mlr3tuning::trm("evals",    n_evals = 250L %/% kfold),
                    mlr3tuning::trm("run_time", secs = 60 * term_min)
                  ), any = TRUE),
    xgboost     = mlr3tuning::trm("none"),
    stop(sprintf("No terminator defined for '%s'.", method))
  )
}

# ── Main training orchestrator ─────────────────────────────────────────────────

#' Tune and train all selected methods.
#'
#' For each method: if a finished tuning instance already exists on disk it is
#' loaded (allowing reruns / restarts). The trained learner is saved to
#' `save_dir` as `<method>_tuned_learner.rds`.
#'
#' @param methods          Named character vector from cfmdbench_resolve_methods().
#' @param base_learners    Named list of base Learner objects (all methods).
#' @param preprocessing_pipe  mlr3pipelines pipeline applied before each learner.
#' @param preproc_params   List of preprocessing paradox parameters.
#' @param task_train       mlr3 TaskClassif used for tuning.
#' @param train_measures   Character vector of measure IDs for inner CV.
#' @param dataset_attr     "binary" or "multi-class".
#' @param save_dir         Directory for saving instances and tuned learners.
#' @param kfold,repeats,num_threads,num_jobs,fast_tuning,learner_fallback,term_min
#'   Execution settings forwarded from config.
#' @return Named list of trained GraphLearner objects.
cfmdbench_train_methods <- function(methods, base_learners, preprocessing_pipe,
                                    preproc_params = list(), task_train,
                                    train_measures, dataset_attr,
                                    save_dir,
                                    kfold = 10L, repeats = 5L,
                                    num_threads = parallel::detectCores(),
                                    num_jobs = kfold,
                                    fast_tuning = TRUE, learner_fallback = FALSE,
                                    term_min = 20) {
  eval_metrics <- if (dataset_attr == "binary") c("error", "logloss")
                  else                          c("merror", "mlogloss")

  min_count <- task_train$data() %>%
    dplyr::count(target) %>%
    dplyr::arrange(n) %>%
    dplyr::slice_head(n = 1L) %>%
    dplyr::pull(n)
  num_feat  <- task_train$ncol  - 1L
  num_obs   <- task_train$nrow

  # Disable fast_tuning when data is small
  effective_fast_tuning <- fast_tuning && !(num_feat < 25L || num_obs < 500L)

  trained_learners <- list()

  for (i in seq_along(methods)) {
    method <- names(methods)[i]
    start  <- Sys.time()
    cat("\n##### Method:", methods[[i]], "#####\n")
    cat(" Start:", format(start, "%Y-%m-%d %H:%M:%S"), "\n")

    instance_file <- file.path(save_dir, paste0(method, "_tuned_instance.rds"))
    learner_file  <- file.path(save_dir, paste0(method, "_tuned_learner.rds"))

    # Skip if already tuned and trained
    if (file.exists(instance_file)) {
      instance <- readRDS(instance_file)
      if (instance$is_terminated && file.exists(learner_file)) {
        cat(" Skipping (already finished):", method, "\n")
        trained_learners[[method]] <- readRDS(learner_file)
        next
      }
    }

    base_learner      <- base_learners[[method]]$clone(deep = TRUE)
    tuning_resampling <- cfmdbench_choose_tuning_resampling(
      method, min_count, num_obs, kfold, repeats)

    # TabPFN forces sequential execution
    if (method == "tabpfn") {
      future::plan(future::sequential)
      num_jobs <- 1L
    }

    learner_pipe  <- cfmdbench_build_learner_pipe(
      method, base_learner, preprocessing_pipe, effective_fast_tuning)
    final_learner <- mlr3pipelines::as_learner(learner_pipe)
    final_learner <- cfmdbench_configure_final_learner(
      method, final_learner, num_threads, num_jobs,
      effective_fast_tuning, learner_fallback, kfold)

    search_space <- cfmdbench_get_search_space(
      method, effective_fast_tuning, num_feat, num_obs,
      preproc_params, kfold, eval_metrics, base_learner)
    cat("Search space:\n"); print(search_space)

    tuner      <- cfmdbench_get_tuner(method, effective_fast_tuning, num_threads, num_jobs)
    terminator <- cfmdbench_get_terminator(method, kfold, term_min)

    if (!file.exists(instance_file)) {
      instance <- mlr3tuning::ti(
        task_train, final_learner, tuning_resampling,
        mlr3::msrs(train_measures),
        terminator,
        search_space          = search_space,
        store_benchmark_result = TRUE,
        store_models           = FALSE
      )
    }

    tuner$optimize(instance)
    saveRDS(instance, instance_file)

    results <- instance$archive$data
    if (!nrow(results)) {
      warning("Tuning results empty for method: ", method)
      next
    }

    results  <- results[order(-results$classif.bacc, results$classif.logloss), ]
    best_idx <- results$uhash[1L]

    if (is.na(best_idx)) {
      warning("No valid best model found for method: ", method)
      next
    }

    best_params <- instance$result_learner_param_vals[[
      which(results$uhash == best_idx)]]
    final_learner$param_set$values <- as.list(best_params)
    final_learner$train(task_train)

    if (method == "mlp") {
      final_learner$marshal()
      best_torch <- instance$archive$best()
      cat("Best n_layers:", length(best_torch$x_domain[[1L]]$classif.mlp.neurons), "\n")
      cat("Best neurons: ",
          paste(best_torch$x_domain[[1L]]$classif.mlp.neurons, collapse = "-"), "\n")
      cat("Balanced accuracy:", mean(best_torch$classif.bacc), "\n")
      cat("Logloss:          ", mean(best_torch$classif.logloss), "\n")
    }

    saveRDS(final_learner, learner_file)
    trained_learners[[method]] <- final_learner

    elapsed <- difftime(Sys.time(), start, units = "secs")
    if (elapsed < 60) {
      cat(" Time:", round(as.numeric(elapsed), 1), "seconds\n")
    } else {
      cat(" Time:", round(as.numeric(elapsed) / 60, 2), "minutes\n")
    }
  }

  trained_learners
}
