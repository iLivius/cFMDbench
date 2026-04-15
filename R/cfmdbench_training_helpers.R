#!/usr/bin/env Rscript
# cfmdbench_training_helpers.R
# Build learners, configure pipelines, define search spaces, run the
# inner-CV tuning loop, and save tuned models to disk.

# ── Learner construction ───────────────────────────────────────────────────────

#' Build the full set of base learner objects (all supported methods).
#'
#' These are plain mlr3 Learner objects — no pipeline, no tuning yet. They are
#' cloned and wrapped inside GraphLearners later in cfmdbench_train_methods().
#'
#' predict_type = "prob" is required by all probability-based metrics (AUC,
#' logloss, PR-AUC) and by the SMOTE PipeOp, which needs class probabilities
#' to generate synthetic samples.
#'
#' MLP and TabPFN are conditional on the `methods` argument because:
#'   - mlr3torch triggers an interactive torch-download prompt on first use.
#'   - TabPFN requires a conda environment and can conflict with mlr3torch
#'     (both try to initialise a CUDA context in the same process).
#' By skipping their construction when not selected we avoid those side effects.
#'
#' Notable MLP parameters:
#'   - device = "auto": use CUDA if available, else CPU.
#'   - patience / min_delta: early stopping via the mlr3torch callback system.
#'   - jit_trace = TRUE: compiles the forward pass for faster CPU inference.
#'   - num_threads = kfold: each CV fold runs in a separate thread during tuning.
#'
#' Notable TabPFN parameters:
#'   - ignore_pretraining_limits: bypasses the default 1000-sample / 100-feature
#'     guard, which would otherwise refuse to run on larger datasets.
#'   - n_jobs = 1: TabPFN is called via reticulate and parallelism must be
#'     handled at the outer (future) level, not inside Python.
#'
#' @param seed    Random seed forwarded to MLP / TabPFN for reproducibility.
#' @param kfold   Number of CV folds; also sets MLP num_threads.
#' @param methods Character vector of selected method IDs (from
#'   cfmdbench_resolve_methods()); pass NULL to build every method.
#' @return Named list of mlr3 Learner objects.
cfmdbench_build_learners <- function(seed = 42L, kfold = 10L, methods = NULL) {
  learners <- list(
    glmnet      = mlr3::lrn("classif.glmnet",      predict_type = "prob"),
    kknn        = mlr3::lrn("classif.kknn",        predict_type = "prob"),
    lda         = mlr3::lrn("classif.lda",         predict_type = "prob"),
    naive_bayes = mlr3::lrn("classif.naive_bayes", predict_type = "prob"),
    ranger      = mlr3::lrn("classif.ranger",      predict_type = "prob"),
    svm         = mlr3::lrn("classif.svm",
                             type = "C-classification",
                             predict_type = "prob"),
    xgboost     = mlr3::lrn("classif.xgboost",     predict_type = "prob")
  )

  # MLP (mlr3torch) — only when explicitly selected.
  # mlr3torch registers "classif.mlp" into mlr3's own learner registry at load
  # time, so lrn() is called via mlr3::lrn() (not mlr3torch::lrn()).
  if (is.null(methods) || "mlp" %in% methods) {
    if (requireNamespace("mlr3torch", quietly = TRUE)) {
      learners$mlp <- mlr3::lrn(
        "classif.mlp",
        activation        = torch::nn_relu,
        loss              = mlr3torch::t_loss("cross_entropy"),
        device            = "auto",            # GPU if available, else CPU
        optimizer         = mlr3torch::t_opt("adamw"),
        measures_valid    = mlr3::msrs(c("classif.bacc", "classif.logloss")),
        measures_train    = mlr3::msrs(c("classif.bacc", "classif.logloss")),
        callbacks         = list(mlr3torch::t_clbk("history"),   # record per-epoch metrics
                                 mlr3torch::t_clbk("progress")), # show training progress bar
        validate          = NULL,   # validation split set later in configure_final_learner
        eval_freq         = 5L,     # evaluate validation metrics every 5 epochs
        predict_type      = "prob",
        patience          = 3L,     # stop after 3 non-improving epochs
        min_delta         = 0.01,   # minimum improvement to reset patience counter
        num_threads       = kfold,  # one thread per CV fold during inner tuning
        seed              = seed,
        jit_trace         = TRUE    # JIT-compile the forward pass for faster CPU inference
      )
    } else {
      warning("mlp selected but mlr3torch is not installed — skipping.")
    }
  }

  # TabPFN (reticulate / mlr3extralearners) — only when explicitly selected.
  # "classif.tabpfn" is registered by mlr3extralearners into mlr3's registry, so
  # we check both that the package is present and that the learner key exists.
  if (is.null(methods) || "tabpfn" %in% methods) {
    if (requireNamespace("mlr3extralearners", quietly = TRUE) &&
        "classif.tabpfn" %in% mlr3::mlr_learners$keys()) {
      learners$tabpfn <- mlr3::lrn(
        "classif.tabpfn",
        ignore_pretraining_limits = TRUE,   # bypass 1000-row / 100-col guard
        device                    = "auto",
        balance_probabilities     = TRUE,   # post-hoc calibration for imbalanced classes
        predict_type              = "prob",
        n_jobs                    = 1L      # parallelism managed at outer future level
      )
    } else {
      warning("tabpfn selected but mlr3extralearners/TabPFN is not available — skipping.")
    }
  }

  learners
}

# ── Resampling strategy ────────────────────────────────────────────────────────

#' Select the inner-CV resampling strategy for tuning based on dataset size.
#'
#' There are three cases:
#'
#'   1. Bootstrap (min_count <= kfold): some classes have fewer samples than
#'      there are folds. Standard k-fold would end up with empty test strata,
#'      so we fall back to bootstrap resampling instead.
#'
#'   2. Plain k-fold (large datasets, or MLP / TabPFN / XGBoost): for methods
#'      that are already slow or for datasets with >= 500 observations, the
#'      extra variance from repeated CV is not worth the additional computation.
#'
#'   3. Repeated k-fold (small datasets, fast methods): multiple repetitions
#'      reduce variance in the CV estimate when n is small, giving the tuner
#'      a more reliable signal with minimal extra cost for fast learners.
#'
#' @param method     Method ID string (used to detect slow learners).
#' @param min_count  Size of the smallest class in the training set.
#' @param num_obs    Total number of training observations.
#' @param kfold      Number of folds (from execution$kfold in config.yaml).
#' @param repeats    Repetitions for repeated CV (from execution$repeats in config.yaml).
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

#' Combine preprocessing_pipe with the base learner into a single Graph.
#'
#' The resulting Graph is wrapped into a GraphLearner by the caller. Two
#' special cases are handled here:
#'
#'   fast_tuning + glmnet/kknn/naive_bayes/svm: a PipeOpSubsample is inserted
#'   between preprocessing and the learner. Its `frac` parameter is tagged
#'   "budget" in the search space, which tells hyperband / successive_halving
#'   to use it as the resource variable (start cheap, scale up for survivors).
#'
#'   lda (fast or not): a PipeOpPCA step is inserted. LDA requires n_features
#'   < n_samples within each class; without PCA it fails on high-dimensional
#'   microbiome data. The PCA rank is a tuning parameter in the search space.
#'
#' @param method            Method ID string.
#' @param base_learner      The base Learner (not yet cloned here — caller does that).
#' @param preprocessing_pipe mlr3pipelines Graph built in the preprocess2 chunk.
#' @param fast_tuning       Logical; TRUE = insert subsample step for budget-based tuning.
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
#' The search space is a paradox::ParamSet that defines which hyperparameters
#' to tune and their allowed ranges. Key concepts:
#'
#'   tags = "budget": marks a parameter as the multi-fidelity resource.
#'   Hyperband / successive_halving start with small budgets (e.g. few trees,
#'   small subsample fraction) and allocate more resources to promising configs.
#'
#'   tags = "internal_tuning" + aggr: tells mlr3 that the learner handles this
#'   parameter internally (e.g. XGBoost early stopping picks the best nrounds
#'   automatically). The aggr function averages the per-fold optimal values into
#'   a single integer for the final model.
#'
#'   .extra_trafo (MLP, full mode): translates the flat l1/l2/l3 width params
#'   and n_layers into a variable-length neurons vector, because mlr3torch's MLP
#'   takes a vector argument but paradox only supports scalar parameters.
#'
#'   LDA's pca.rank. (trailing dot): the dot is part of the PipeOpPCA parameter
#'   naming convention in mlr3pipelines.
#'
#'   XGBoost / TabPFN side effects on base_learner: the search space construction
#'   also mutates the base learner (sets eval_metric + early_stopping_rounds for
#'   XGBoost; sets callr encapsulation for TabPFN). This is intentional — these
#'   settings must be on the learner before it is embedded in a pipeline.
#'
#'   preproc_params: preprocessing parameters (filter fractions, SMOTE params)
#'   are prepended to the learner parameters so they are tuned jointly.
#'
#' @param method        Method ID string.
#' @param fast_tuning   Logical; TRUE = budget-parameter search spaces.
#' @param num_feat      Number of features in the training task.
#' @param num_obs       Number of rows in the training task.
#' @param preproc_params List of preprocessing paradox parameters to prepend.
#' @param kfold         Number of CV folds (used to scale MLP epoch budget).
#' @param eval_metrics  Named vector for xgboost ("error"/"logloss" for binary,
#'   "merror"/"mlogloss" for multi-class).
#' @param base_learner  The base learner; mutated in-place for xgboost/tabpfn.
cfmdbench_get_search_space <- function(method, fast_tuning, num_feat, num_obs,
                                       preproc_params = list(), kfold = 10L,
                                       eval_metrics = c("merror", "mlogloss"),
                                       base_learner = NULL) {
  p_dbl <- paradox::p_dbl; p_int <- paradox::p_int; p_fct <- paradox::p_fct

  if (fast_tuning) {
    learner_params <- switch(method,

      # subsample.frac is the "budget" parameter: successive_halving starts with
      # frac=0.1 and scales up, only keeping the best configurations.
      glmnet = list(
        subsample.frac           = p_dbl(0.1, 1.0, tags = "budget"),
        classif.glmnet.s         = p_dbl(1e-4, 1e4, logscale = TRUE),  # lambda (regularisation)
        classif.glmnet.alpha     = p_dbl(0, 1)     # 0 = ridge, 1 = lasso, in-between = elastic net
      ),

      kknn = list(
        subsample.frac    = p_dbl(0.1, 1.0, tags = "budget"),
        classif.kknn.k    = p_int(1, 50, logscale = TRUE)   # number of neighbours
      ),

      lda = list(
        subsample.frac        = p_dbl(0.1, 1.0, tags = "budget"),
        pca.rank.             = p_int(2L, min(num_feat, num_obs - 1L)),  # PCA dimensionality
        classif.lda.method    = p_fct(levels = c("moment", "mle", "mve", "t")),
        classif.lda.tol       = p_dbl(1e-6, 1e-2, logscale = TRUE),
        classif.lda.nu        = p_int(3L, 10L,
                                      depends = quote(classif.lda.method == "t"))  # df for t-distribution
      ),

      # MLP uses neurons (layer width) as the budget; hyperband progressively
      # allows wider networks for the best configurations.
      # epochs uses "internal_tuning": PyTorch early stopping picks the best
      # epoch count during training; the aggr function averages across CV folds.
      mlp = list(
        classif.mlp.neurons       = p_int(32L, 512L, tags = "budget"),
        classif.mlp.n_layers      = p_int(1L, 3L),
        classif.mlp.batch_size    = p_int(32L, 32L),  # fixed at 32 for fast mode
        classif.mlp.epochs        = p_int(upper = 100L, tags = "internal_tuning",
                                          aggr = function(x) as.integer(mean(unlist(x)))),
        classif.mlp.p             = p_dbl(0.1, 0.5),  # dropout probability
        classif.mlp.opt.lr        = p_dbl(1e-4, 1e-1, logscale = TRUE),
        classif.mlp.opt.weight_decay = p_dbl(1e-5, 1e-3, logscale = TRUE)
      ),

      naive_bayes = list(
        subsample.frac                    = p_dbl(0.1, 1.0, tags = "budget"),
        classif.naive_bayes.eps           = p_dbl(1e-9, 0.2),   # smoothing for zero-probability cells
        classif.naive_bayes.laplace       = p_dbl(1e-6, 2),     # Laplace correction
        classif.naive_bayes.threshold     = p_dbl(1e-9, 0.1)    # minimum probability floor
      ),

      # ranger uses num.trees as the budget (more trees = more resource).
      ranger = list(
        classif.ranger.num.trees       = p_int(10L, 1000L, tags = "budget"),
        classif.ranger.mtry.ratio      = p_dbl(0.1, 1),          # fraction of features per split
        classif.ranger.sample.fraction = p_dbl(0.1, 1)           # fraction of rows per tree
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

      # TabPFN has almost no tunable parameters; the main job here is to wrap
      # it in callr encapsulation so Python errors don't crash R.
      # n_estimators and softmax_temperature are fixed (no real search).
      tabpfn = {
        if (!is.null(base_learner))
          base_learner$encapsulate("callr",
            fallback = mlr3::lrn("classif.featureless", predict_type = "prob"))
        list(
          classif.tabpfn.n_estimators       = p_int(4L, 4L),      # fixed: 4 ensemble members
          classif.tabpfn.softmax_temperature = p_dbl(0.9, 0.9)    # fixed calibration temperature
        )
      },

      # xgboost uses nrounds as the budget; early_stopping_rounds (set below)
      # prevents overfitting by halting when the validation metric stops improving.
      # eval_metric and early_stopping_rounds are set on the learner object here
      # because they must be present before the pipeline wraps it.
      xgboost = {
        if (!is.null(base_learner))
          base_learner$param_set$set_values(
            eval_metric = eval_metrics, early_stopping_rounds = 10L)
        list(
          classif.xgboost.nrounds            = p_int(10L, 1000L, tags = "budget"),
          classif.xgboost.eta                = p_dbl(1e-4, 1, logscale = TRUE),   # learning rate
          classif.xgboost.max_depth          = p_int(1L, 20L),
          classif.xgboost.colsample_bytree   = p_dbl(0.1, 1),   # features sampled per tree
          classif.xgboost.colsample_bylevel  = p_dbl(0.1, 1),   # features sampled per level
          classif.xgboost.lambda             = p_dbl(1e-3, 1e3, logscale = TRUE), # L2 regularisation
          classif.xgboost.alpha              = p_dbl(1e-3, 1e3, logscale = TRUE), # L1 regularisation
          classif.xgboost.subsample          = p_dbl(0.1, 1)    # rows sampled per boosting round
        )
      },
      stop(sprintf("No fast search space defined for method '%s'.", method))
    )
  } else {
    # Full (non-fast) search space: no subsample budget parameter; uses grid
    # search or hyperband with a proper resource parameter.
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

      # Full MLP search space: per-layer widths (l1/l2/l3) are separate scalar
      # parameters so paradox can handle them. The .extra_trafo function fuses
      # them into a variable-length neurons vector that mlr3torch actually accepts.
      # Layer dependencies ensure l2 is only sampled when n_layers >= 2, and
      # l3 only when n_layers == 3 (added via ss$add_dep() below).
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

  # Merge preprocessing parameters (filter fractions, SMOTE settings) with the
  # learner parameters into a single ParamSet. This means the tuner searches
  # over both simultaneously — a pipeline-level tuning approach.
  ss <- do.call(paradox::ps, c(preproc_params, learner_params))

  # MLP layer-width dependencies must be added after the ParamSet is assembled
  # because add_dep() requires the set to already contain both parameters.
  if (!fast_tuning && method == "mlp") {
    ss$add_dep("l2", on = "classif.mlp.n_layers", paradox::CondAnyOf$new(2:3))
    ss$add_dep("l3", on = "classif.mlp.n_layers", paradox::CondEqual$new(3L))
  }
  ss
}

# ── Final learner configuration ────────────────────────────────────────────────

#' Set id, threading, validation split, and optional callr encapsulation on the
#' assembled GraphLearner before the tuning instance is created.
#'
#' keep_results = TRUE: after training, each PipeOp stores its last output in
#' $graph_model$pipeops[[id]]$.result. This is needed by cfmdbench_get_preproc_summary()
#' (called in the benchmark chunk) to inspect the data state after each preprocessing
#' step — e.g. how many features survived filtering, what the class distribution
#' looked like after SMOTE.
#'
#' set_validate(0.2): MLP and XGBoost both use early stopping, which requires a
#' held-out validation subset during training to monitor the stopping criterion.
#' mlr3 handles this by reserving 20% of the training data internally.
#'
#' set_threads: thread-level parallelism is applied only to learners that support
#' it (ranger, xgboost). The count is scaled down by num_jobs because the outer
#' benchmark/tuning loop already parallelises across folds — over-subscribing
#' would thrash the CPU.
#'
#' callr encapsulation: wraps the learner in a separate R process so that a
#' crash inside the learner (Python error, memory overflow, segfault) does not
#' kill the entire tuning session. The featureless fallback is used as a
#' placeholder when the learner fails; learner_fallback is a config.yaml option.
#'
#' @param method            Method ID string.
#' @param final_learner     GraphLearner to configure (mutated in-place).
#' @param num_threads       Total available CPU threads.
#' @param num_jobs          Number of parallel outer jobs (= kfold in training).
#' @param fast_tuning       Logical; affects whether callr is applied.
#' @param learner_fallback  Logical; from execution$learner_fallback in config.yaml.
#' @param kfold             Number of CV folds (unused directly but kept for clarity).
cfmdbench_configure_final_learner <- function(method, final_learner,
                                              num_threads, num_jobs,
                                              fast_tuning, learner_fallback,
                                              kfold = 10L) {
  final_learner$id                     <- method
  final_learner$graph$keep_results     <- TRUE   # needed by cfmdbench_get_preproc_summary()

  # MLP and XGBoost use early stopping — they need an internal validation split.
  if (method %in% c("mlp", "xgboost"))
    mlr3::set_validate(final_learner, 0.2)

  # Cap per-learner threads to avoid over-subscribing when running num_jobs in parallel.
  if (method %in% c("ranger", "xgboost"))
    mlr3::set_threads(final_learner, n = ceiling(num_threads / num_jobs))

  # Wrap in callr unless this is TabPFN (which handles encapsulation in the
  # search space builder via its own callr setup).
  if (learner_fallback && method != "tabpfn")
    final_learner$encapsulate("callr",
      fallback = mlr3::lrn("classif.featureless", predict_type = "prob"))

  final_learner
}

# ── Tuners & terminators ───────────────────────────────────────────────────────

#' Return the mlr3tuning tuner for a given method and tuning mode.
#'
#' Two families of tuner are used:
#'
#'   Multi-fidelity (hyperband / successive_halving): exploit the "budget"
#'   parameter in the search space. They start with many configurations at low
#'   resource (few trees, small subsample) and progressively discard the worst
#'   performers while allocating more resource to survivors. eta controls the
#'   halving factor (eta=2 halves the field each round; eta=3 is more aggressive).
#'   repetitions runs the bracket multiple times with different random configs.
#'   Both hyperband and successive_halving are registered by mlr3hyperband but
#'   accessed through mlr3tuning::tnr() (mlr3hyperband doesn't export tnr()).
#'
#'   Grid search: used when there is no "budget" parameter (non-fast glmnet,
#'   kknn, lda, naive_bayes, svm) or when the search space is effectively fixed
#'   (tabpfn). batch_size controls how many configurations are evaluated in
#'   parallel per round.
#'
#' @param method      Method ID string.
#' @param fast_tuning Logical; TRUE = multi-fidelity tuners.
#' @param num_threads Total available CPU threads.
#' @param num_jobs    Number of parallel outer jobs.
cfmdbench_get_tuner <- function(method, fast_tuning, num_threads, num_jobs) {
  bs <- floor(num_threads / num_jobs)   # batch size for grid search
  if (fast_tuning) {
    switch(method,
      # successive_halving for methods with subsample.frac as budget
      glmnet      = mlr3tuning::tnr("successive_halving", eta = 2, repetitions = 3),
      kknn        = mlr3tuning::tnr("successive_halving", eta = 2, repetitions = 3),
      lda         = mlr3tuning::tnr("successive_halving", eta = 2, repetitions = 3),
      # hyperband for methods with a natural resource parameter (trees/epochs/rounds)
      mlp         = mlr3tuning::tnr("hyperband", eta = 2, repetitions = 1),
      naive_bayes = mlr3tuning::tnr("successive_halving", eta = 2, repetitions = 3),
      svm         = mlr3tuning::tnr("successive_halving", eta = 2, repetitions = 3),
      # TabPFN's search space is essentially fixed; grid search covers it trivially
      tabpfn      = mlr3tuning::tnr("grid_search", resolution = 3, batch_size = bs),
      ranger      = mlr3tuning::tnr("hyperband", eta = 2, repetitions = 1),
      xgboost     = mlr3tuning::tnr("hyperband", eta = 3, repetitions = 1),  # more aggressive
      stop(sprintf("No fast tuner defined for '%s'.", method))
    )
  } else {
    switch(method,
      glmnet      = mlr3tuning::tnr("grid_search", resolution = 5, batch_size = bs),
      kknn        = mlr3tuning::tnr("grid_search", resolution = 5, batch_size = bs),
      lda         = mlr3tuning::tnr("grid_search", resolution = 5, batch_size = bs),
      mlp         = mlr3tuning::tnr("hyperband", eta = 2, repetitions = 3),
      naive_bayes = mlr3tuning::tnr("grid_search", resolution = 5, batch_size = bs),
      svm         = mlr3tuning::tnr("grid_search", resolution = 5, batch_size = bs),
      tabpfn      = mlr3tuning::tnr("grid_search", resolution = 3, batch_size = bs),
      ranger      = mlr3tuning::tnr("hyperband", eta = 2, repetitions = 3),
      xgboost     = mlr3tuning::tnr("hyperband", eta = 2, repetitions = 3),
      stop(sprintf("No tuner defined for '%s'.", method))
    )
  }
}

#' Return the mlr3tuning terminator for a given method.
#'
#' The terminator controls when tuning stops. There are four variants used here:
#'
#'   trm("none"): hyperband and successive_halving are self-terminating — they
#'   exhaust their bracket schedule and stop naturally. For those methods we
#'   pass "none" so the tuner controls its own lifecycle.
#'
#'   trm("evals", n_evals): cap the total number of hyperparameter configurations
#'   evaluated. n_evals is scaled by 1/kfold because each configuration is
#'   evaluated kfold times (once per CV fold).
#'
#'   trm("run_time", secs): wall-clock time limit — useful for SVM, which can
#'   be slow on large feature sets. term_min comes from execution$term_min in
#'   config.yaml (default 20 minutes).
#'
#'   trm("combo", any=TRUE): stop when EITHER of two conditions is met. Used for
#'   ranger and TabPFN to provide both a computation budget and a safety time limit.
#'
#' @param method    Method ID string.
#' @param kfold     Number of CV folds; scales the eval-based budget.
#' @param term_min  Time limit in minutes (from execution$term_min in config.yaml).
cfmdbench_get_terminator <- function(method, kfold = 10L, term_min = NULL) {
  if (is.null(term_min)) stop(
    "`term_min` must be supplied (minutes); ",
    "check execution$term_min in config.yaml."
  )
  switch(method,
    # hyperband / successive_halving are self-terminating
    glmnet      = mlr3tuning::trm("none"),
    kknn        = mlr3tuning::trm("none"),
    lda         = mlr3tuning::trm("none"),
    naive_bayes = mlr3tuning::trm("none"),
    # MLP: cap evaluations (hyperband manages resource through epochs internally)
    mlp         = mlr3tuning::trm("evals", n_evals = 250L %/% kfold),
    # SVM with grid search: no self-termination, so use a wall-clock limit
    svm         = mlr3tuning::trm("run_time", secs = 60 * term_min),
    # TabPFN: either cap evals or hit the time limit, whichever comes first
    tabpfn      = mlr3tuning::trm("combo", list(
                    mlr3tuning::trm("evals",    n_evals = 50L %/% kfold),
                    mlr3tuning::trm("run_time", secs = 60 * term_min)
                  ), any = TRUE),
    # ranger: same combo pattern — evals budget OR time limit
    ranger      = mlr3tuning::trm("combo", list(
                    mlr3tuning::trm("evals",    n_evals = 250L %/% kfold),
                    mlr3tuning::trm("run_time", secs = 60 * term_min)
                  ), any = TRUE),
    # xgboost: hyperband + early stopping together control termination
    xgboost     = mlr3tuning::trm("none"),
    stop(sprintf("No terminator defined for '%s'.", method))
  )
}

# ── Main training orchestrator ─────────────────────────────────────────────────

#' Tune and train all selected methods.
#'
#' This is the function called from the `train` chunk in the notebook. For each
#' selected method it:
#'
#'   1. Checks for an existing completed tuning instance on disk and skips
#'      retraining if found. This allows interrupted runs to be resumed cleanly
#'      without redoing already-finished methods.
#'
#'   2. Adjusts effective_fast_tuning: fast_tuning is automatically disabled
#'      when the dataset is very small (< 25 features or < 500 observations)
#'      because subsampling-based budgets are unreliable in that regime.
#'
#'   3. Assembles the full pipeline: preprocessing_pipe → (optional subsample /
#'      PCA) → base_learner, wrapped in a GraphLearner.
#'
#'   4. Runs inner-CV tuning via mlr3tuning's optimize(). The tuning instance
#'      (all configurations tried, their scores) is saved to disk as
#'      <method>_tuned_instance.rds so it can be inspected or resumed later.
#'
#'   5. Picks the best configuration by balanced accuracy (primary) then logloss
#'      (tiebreaker), sets those parameters on the final learner, and trains it
#'      on the full training set.
#'
#'   6. Marshals MLP models before saving: mlr3torch tensors must be converted
#'      to raw bytes (marshalled) to be safely written to RDS files. The
#'      unmarshal step happens in cfmdbench_load_benchmark_learners().
#'
#'   7. Saves the trained GraphLearner to <method>_tuned_learner.rds.
#'
#' TabPFN forces sequential execution because it runs via reticulate (Python),
#' which cannot be called from inside future workers.
#'
#' @param methods          Named character vector from cfmdbench_resolve_methods().
#' @param base_learners    Named list from cfmdbench_build_learners() (all methods).
#' @param preprocessing_pipe  mlr3pipelines Graph built in the preprocess2 chunk.
#' @param preproc_params   List of preprocessing paradox parameters (filter fractions,
#'   SMOTE settings); empty list if no preprocessing parameters are tuned.
#' @param task_train       mlr3 TaskClassif for tuning (the 80% training split).
#' @param train_measures   Character vector of measure IDs for inner CV evaluation
#'   (e.g. c("classif.bacc", "classif.logloss")).
#' @param dataset_attr     "binary" or "multi-class"; controls xgboost eval metrics.
#' @param save_dir         Directory for saving instances and tuned learners. The
#'   directory name is derived from run_date + dataset ID + version in config.yaml.
#' @param kfold,repeats,num_threads,num_jobs,fast_tuning,learner_fallback,term_min
#'   Execution settings forwarded from config.yaml (execution section).
#' @return Named list of trained GraphLearner objects (also saved to disk).
cfmdbench_train_methods <- function(methods, base_learners, preprocessing_pipe,
                                    preproc_params = list(), task_train,
                                    train_measures, dataset_attr,
                                    save_dir,
                                    kfold = 10L, repeats = 5L,
                                    num_threads = parallel::detectCores(),
                                    num_jobs = kfold,
                                    fast_tuning = TRUE, learner_fallback = FALSE,
                                    term_min = NULL) {
  if (is.null(term_min)) stop(
    "`term_min` must be supplied (minutes); ",
    "check execution$term_min in config.yaml."
  )
  # XGBoost uses different metric names for binary vs multi-class classification.
  eval_metrics <- if (dataset_attr == "binary") c("error", "logloss")
                  else                          c("merror", "mlogloss")

  # Derive dataset properties used throughout the loop.
  min_count <- task_train$data() %>%
    dplyr::count(target) %>%
    dplyr::arrange(n) %>%
    dplyr::slice_head(n = 1L) %>%
    dplyr::pull(n)
  num_feat  <- task_train$ncol  - 1L   # subtract the target column
  num_obs   <- task_train$nrow

  # Disable fast_tuning automatically when data is too small: with < 25 features
  # there is no benefit from the subsample budget, and with < 500 observations
  # subsampling would make individual evaluations too noisy to guide the tuner.
  effective_fast_tuning <- fast_tuning && !(num_feat < 25L || num_obs < 500L)

  trained_learners <- list()

  for (i in seq_along(methods)) {
    method <- names(methods)[i]
    start  <- Sys.time()
    cat("\n##### Method:", methods[[i]], "#####\n")
    cat(" Start:", format(start, "%Y-%m-%d %H:%M:%S"), "\n")

    instance_file <- file.path(save_dir, paste0(method, "_tuned_instance.rds"))
    learner_file  <- file.path(save_dir, paste0(method, "_tuned_learner.rds"))

    # Resume logic: skip re-tuning if the final trained learner already exists.
    # The learner file is saved last (after tuning + final train), so its
    # existence is the definitive signal that the method completed successfully.
    # Note: is_terminated is NOT used here because trm("none") (used by xgboost
    # and other self-terminating tuners) always returns FALSE, even after a
    # successful run.
    if (file.exists(learner_file)) {
      cat(" Skipping (already finished):", method, "\n")
      trained_learners[[method]] <- readRDS(learner_file)
      next
    }
    # Load partial instance for resumption if tuning was interrupted mid-run.
    if (file.exists(instance_file)) {
      instance <- readRDS(instance_file)
    }

    base_learner      <- base_learners[[method]]$clone(deep = TRUE)
    tuning_resampling <- cfmdbench_choose_tuning_resampling(
      method, min_count, num_obs, kfold, repeats)

    # TabPFN uses reticulate (Python) and cannot run inside future workers.
    # Force sequential and single-job execution for this method only.
    if (method == "tabpfn") {
      future::plan(future::sequential)
      num_jobs <- 1L
    }

    learner_pipe  <- cfmdbench_build_learner_pipe(
      method, base_learner, preprocessing_pipe, effective_fast_tuning)
    final_learner <- mlr3pipelines::GraphLearner$new(learner_pipe)
    final_learner <- cfmdbench_configure_final_learner(
      method, final_learner, num_threads, num_jobs,
      effective_fast_tuning, learner_fallback, kfold)

    search_space <- cfmdbench_get_search_space(
      method, effective_fast_tuning, num_feat, num_obs,
      preproc_params, kfold, eval_metrics, base_learner)
    cat("Search space:\n"); print(search_space)

    tuner      <- cfmdbench_get_tuner(method, effective_fast_tuning, num_threads, num_jobs)
    terminator <- cfmdbench_get_terminator(method, kfold, term_min)

    # Only create a fresh TuningInstance if no partial instance exists on disk.
    # If a partial instance was loaded above, reuse it so the tuner continues
    # from where it stopped rather than restarting from scratch.
    if (!file.exists(instance_file)) {
      instance <- mlr3tuning::ti(
        task_train, final_learner, tuning_resampling,
        mlr3::msrs(train_measures),
        terminator,
        search_space          = search_space,
        store_benchmark_result = TRUE,    # keep per-fold results for diagnostics
        store_models           = FALSE    # don't store intermediate models (saves memory)
      )
    }

    tuner$optimize(instance)
    saveRDS(instance, instance_file)   # checkpoint: preserve full tuning history

    results <- instance$archive$data
    if (!nrow(results)) {
      warning("Tuning results empty for method: ", method)
      next
    }

    # Select best configuration: highest balanced accuracy, then lowest logloss.
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

    # MLP serialisation: mlr3torch stores tensors as live R objects which cannot
    # be written to RDS directly. marshal() converts them to raw bytes first.
    # unmarshal() (in cfmdbench_load_benchmark_learners) reverses this before use.
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
