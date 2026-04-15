#!/usr/bin/env Rscript
# cfmdbench_config_helpers.R
# Load, merge, and validate the cFMDbench YAML config; resolve runtime
# environments for optional backends (TabPFN, mlr3torch).

# ── Built-in defaults ──────────────────────────────────────────────────────────

# These are the values used when no config.yaml exists, or when a key is absent
# from the user's config. Keeping defaults here (rather than scattered across
# the codebase) makes it easy to see what every parameter does and what a
# reasonable starting point looks like.
cfmdbench_default_config <- function() {
  list(
    methods = list(
      # Which classifiers to run. "all" expands to every supported method.
      # Default is a fast, reliable pair suitable for initial exploration.
      pick = c("ranger", "xgboost")
    ),
    execution = list(
      seed                       = 42L,
      kfold                      = 10L,  # outer CV folds
      repeats                    = 5L,   # repeats for repeated CV (small datasets)
      num_threads                = NULL, # NULL = detect at runtime
      # Large global objects (e.g. the full dataset) need to cross process
      # boundaries during parallelisation; 2 GB is usually enough headroom.
      future_globals_max_size_gb = 2,
      term_min                   = 20,   # tuning budget in minutes per method
      # fast_tuning activates subsampling inside the tuning pipeline so the
      # tuner can evaluate many configurations cheaply on small data subsets
      # before progressively increasing the subsample ratio for the best ones.
      fast_tuning                = TRUE,
      # When TRUE, a failed learner is replaced by a trivial majority-class
      # predictor rather than causing the whole run to abort.
      learner_fallback           = FALSE
    ),
    dataset = list(
      id       = "cFMD",
      version  = "v1.3.0",  # validated version; upgrading may require code changes in cfmdbench_data_helpers.R
      target   = "category",  # column name of the outcome variable
      run_date = ""            # filled at runtime if left blank
    ),
    data_source = list(
      repo  = "SegataLab/cFMD",
      path  = "cFMD_data",
      # Samples whose taxa abundances sum to less than this threshold are
      # considered incomplete and dropped before modelling.
      completeness_threshold = 99L,
      # GitHub Contents API calls are batched to avoid hammering rate limits.
      api_batch_size         = 10L
    ),
    preprocessing = list(
      # Classes with fewer than this many samples are dropped; they are too
      # rare to estimate performance reliably.
      min_samples_per_class = 25L,
      # Fraction of samples to retain per class before training (1 = keep all).
      samples_to_keep       = 1,
      # SMOTE variant to apply for class imbalance; empty string = auto-decide.
      smote                 = "",
      # "minimal" applies only essential filters (near-zero variance etc.).
      filtering             = "minimal",
      # Whether to run recursive feature selection before modelling.
      selecting             = TRUE
    ),
    feature_selection = list(
      # If ncol >= num_col, target n_features = 10; otherwise 2.
      # If nrow > num_row, use single-learner RFE ("simple");
      # otherwise use ensemble FS across four learners ("ensemble").
      num_col = 100L,
      num_row = 100L
    ),
    visualisation = list(
      # Subsample size for embedding / density plots that would be too slow
      # on the full dataset.
      downsample_n    = 1000L,
      # Features present in fewer than this fraction of samples are excluded
      # from ordination plots.
      prevalence_min  = 0.05,
      # SHAP background dataset size and number of top features to display.
      shap_n_samples  = 100L,
      shap_n_features = 10L
    )
  )
}

# ── Config loading ─────────────────────────────────────────────────────────────

# Deep-merge two nested lists. Any key present in `user` overwrites the
# corresponding key in `defaults`; keys absent from `user` are left at their
# default values. The recursion handles arbitrarily nested sections.
cfmdbench_merge_config <- function(defaults, user) {
  for (key in names(user)) {
    if (is.list(defaults[[key]]) && is.list(user[[key]])) {
      defaults[[key]] <- cfmdbench_merge_config(defaults[[key]], user[[key]])
    } else {
      defaults[[key]] <- user[[key]]
    }
  }
  defaults
}

#' Load config.yaml, merge with built-in defaults, and return the final list.
#'
#' The user's YAML only needs to contain the keys they want to override —
#' everything else falls back to the built-in defaults above.
#'
#' @param path Path to config.yaml (defaults to "config.yaml" in working dir).
cfmdbench_load_config <- function(path = "config.yaml") {
  if (!requireNamespace("yaml", quietly = TRUE))
    stop("Package 'yaml' is required: install.packages('yaml')")

  defaults <- cfmdbench_default_config()

  if (!file.exists(path)) {
    message("config.yaml not found at '", path, "' — using built-in defaults.")
    return(defaults)
  }

  user_cfg <- yaml::read_yaml(path)
  cfmdbench_merge_config(defaults, user_cfg)
}

# ── Method resolution ──────────────────────────────────────────────────────────

#' Resolve `methods$pick` to a named character vector of method -> label pairs.
#'
#' The returned names are the IDs used internally (matching learner keys in
#' cfmdbench_build_learners()); the values are the human-readable labels used
#' in plots and tables. Validated here so bad method names fail immediately
#' rather than deep inside the training loop.
#'
#' @param pick "all" or a character vector / list of method IDs.
cfmdbench_resolve_methods <- function(pick) {
  all_methods <- c(
    glmnet      = "GLM elastic net",
    kknn        = "K-Nearest Neighbor",
    lda         = "Linear Discriminant Analysis",
    mlp         = "Multi-layer Perceptron",
    naive_bayes = "Naive Bayes",
    ranger      = "Random Forest",
    svm         = "Support Vector Machine",
    tabpfn      = "TabPFN",
    xgboost     = "XGBoost"
  )

  pick <- as.character(unlist(pick))
  if (identical(pick, "all")) return(all_methods)

  unknown <- setdiff(pick, names(all_methods))
  if (length(unknown))
    stop(sprintf("Unknown method(s): %s. Valid: %s.",
                 paste(unknown, collapse = ", "),
                 paste(names(all_methods), collapse = ", ")))
  all_methods[pick]
}

# ── Environment helpers ────────────────────────────────────────────────────────

#' Read a project-local .Renviron if it exists.
#'
#' Useful for projects that store tokens in a repo-level .Renviron rather than
#' the global ~/.Renviron (e.g. to keep credentials scoped to a single project
#' and out of the shell environment).
cfmdbench_read_renviron_if_exists <- function(root = ".") {
  path <- file.path(root, ".Renviron")
  if (file.exists(path)) readRenviron(path)
  invisible(NULL)
}

#' Configure the optional TabPFN (reticulate) or mlr3torch backends.
#'
#' TabPFN and the MLP are mutually exclusive because they require incompatible
#' Python environments: TabPFN needs a specific conda env managed by reticulate,
#' while mlr3torch uses R's own torch bindings. Both try to initialise a CUDA
#' context and conflict at the driver level when run in the same process.
#'
#' For TabPFN, the conda env name and root directory can be overridden per-
#' project via TABPFN_ENV_NAME and TABPFN_CONDA_ROOT in .Renviron. The HF_TOKEN
#' is required to download TabPFN weights from HuggingFace on the first run.
#'
#' Call this after packages are loaded but before any training begins.
#'
#' @param cfg             The merged config list from cfmdbench_load_config().
#' @param needs_tabpfn    Logical: is "tabpfn" in the selected methods?
#' @param needs_mlr3torch Logical: is "mlp" in the selected methods?
#' @param root            Project root used to look for a .Renviron file.
cfmdbench_setup_backends <- function(cfg, needs_tabpfn, needs_mlr3torch, root = ".") {
  if (needs_tabpfn && needs_mlr3torch)
    stop("Conflict: 'mlp' (mlr3torch) and 'tabpfn' (reticulate) cannot run ",
         "in the same R session. Remove one from methods$pick.")

  if (needs_tabpfn) {
    # Load any project-level token overrides before checking HF_TOKEN.
    cfmdbench_read_renviron_if_exists(root)

    token <- Sys.getenv("HF_TOKEN", unset = NA_character_)
    if (is.na(token) || !nzchar(token))
      stop("HF_TOKEN not set. Add it to ~/.Renviron or a project .Renviron.")
    Sys.setenv(HF_TOKEN = token)

    # Prevents CUDA OOM crashes when PyTorch allocates memory in large chunks.
    Sys.setenv(PYTORCH_CUDA_ALLOC_CONF = "expandable_segments:True")

    # Allow the conda environment name and root to be overridden per-project.
    env_name   <- Sys.getenv("TABPFN_ENV_NAME",   unset = "cfmdbench-tabpfn-gpu")
    conda_root <- Sys.getenv("TABPFN_CONDA_ROOT", unset = Sys.getenv("CONDA_PREFIX"))
    Sys.setenv(RETICULATE_MINICONDA_PATH = conda_root)
    reticulate::use_condaenv(env_name, required = TRUE)

    # Fail early with a clear error if the conda env is incomplete, rather
    # than letting a cryptic Python ImportError surface mid-training.
    missing_mods <- Filter(
      function(m) !reticulate::py_module_available(m),
      c("torch", "sklearn", "tabpfn")
    )
    if (length(missing_mods))
      stop(sprintf("Missing Python modules in '%s': %s",
                   env_name, paste(missing_mods, collapse = ", ")))

    reticulate::py_config()
  }

  if (needs_mlr3torch) {
    if (!torch::torch_is_installed()) {
      # torch::install_torch() downloads the libtorch and lantern binaries.
      # It must complete in a *fresh* R session — if torch is already loaded
      # (namespace locked), the post-install state variable cannot be updated
      # and you will see "cannot change value of locked binding for
      # '.torch_can_load'". The binaries will be on disk regardless; a session
      # restart is all that is needed.
      message("Installing R torch backend...")
      torch::install_torch()
      stop(
        "R torch binaries were just installed.\n",
        "Please restart your R session (Session \u2192 Restart R in RStudio) ",
        "and re-run from the libraries chunk.\n",
        "You will NOT need to call install_torch() again.",
        call. = FALSE
      )
    }
    if (!torch::cuda_is_available())
      message("CUDA not available — R torch will use CPU.")
  }

  invisible(NULL)
}

# ── Misc helpers ───────────────────────────────────────────────────────────────

#' Null-coalescing operator: return `x` if not NULL, else `y`.
`%||%` <- function(x, y) if (!is.null(x)) x else y
