#!/usr/bin/env Rscript
# cfmdbench_config_helpers.R
# Load, merge, and validate the cFMDbench YAML config; resolve runtime
# environments for optional backends (TabPFN, mlr3torch).

# ── Built-in defaults ──────────────────────────────────────────────────────────

cfmdbench_default_config <- function() {
  list(
    methods = list(
      pick = c("ranger", "xgboost")
    ),
    execution = list(
      seed                      = 42L,
      kfold                     = 10L,
      repeats                   = 5L,
      num_threads               = NULL,
      future_globals_max_size_gb = 2,
      term_min                  = 20,
      fast_tuning               = TRUE,
      learner_fallback          = FALSE
    ),
    dataset = list(
      id       = "cFMD",
      version  = "v1.3.0",
      target   = "category",
      run_date = ""
    ),
    data_source = list(
      repo                   = "SegataLab/cFMD",
      path                   = "cFMD_data",
      completeness_threshold = 99L,
      api_batch_size         = 10L
    ),
    preprocessing = list(
      min_samples_per_class = 25L,
      samples_to_keep       = 1,
      smote                 = "",
      filtering             = "minimal",
      selecting             = TRUE
    ),
    feature_selection = list(
      num_col = 100L,
      num_row = 100L
    ),
    visualisation = list(
      downsample_n   = 1000L,
      prevalence_min = 0.05,
      shap_n_samples = 100L,
      shap_n_features = 10L
    )
  )
}

# ── Config loading ─────────────────────────────────────────────────────────────

# Recursively merge two config lists; `user` wins on leaf conflicts.
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
cfmdbench_read_renviron_if_exists <- function(root = ".") {
  path <- file.path(root, ".Renviron")
  if (file.exists(path)) readRenviron(path)
  invisible(NULL)
}

#' Configure the optional TabPFN (reticulate) or mlr3torch backends.
#' Call after packages are loaded; before any training.
cfmdbench_setup_backends <- function(cfg, needs_tabpfn, needs_mlr3torch, root = ".") {
  if (needs_tabpfn && needs_mlr3torch)
    stop("Conflict: 'mlp' (mlr3torch) and 'tabpfn' (reticulate) cannot run ",
         "in the same R session. Remove one from methods$pick.")

  if (needs_tabpfn) {
    cfmdbench_read_renviron_if_exists(root)

    token <- Sys.getenv("HF_TOKEN", unset = NA_character_)
    if (is.na(token) || !nzchar(token))
      stop("HF_TOKEN not set. Add it to ~/.Renviron or a project .Renviron.")
    Sys.setenv(HF_TOKEN = token)

    Sys.setenv(PYTORCH_CUDA_ALLOC_CONF = "expandable_segments:True")

    env_name   <- Sys.getenv("TABPFN_ENV_NAME",   unset = "cfmdbench-tabpfn-gpu")
    conda_root <- Sys.getenv("TABPFN_CONDA_ROOT", unset = Sys.getenv("CONDA_PREFIX"))
    Sys.setenv(RETICULATE_MINICONDA_PATH = conda_root)
    reticulate::use_condaenv(env_name, required = TRUE)

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
      message("Installing R torch backend...")
      torch::install_torch()
    }
    if (!torch::cuda_is_available())
      message("CUDA not available — R torch will use CPU.")
  }

  invisible(NULL)
}

# ── Misc helpers ───────────────────────────────────────────────────────────────

#' Null-coalescing operator: return `x` if not NULL, else `y`.
`%||%` <- function(x, y) if (!is.null(x)) x else y