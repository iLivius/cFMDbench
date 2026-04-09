#!/usr/bin/env Rscript
# Install the R packages used by the cFMDbench workflow into the active Conda
# environment. Run this after creating and activating cfmdbench-r.
#
# Usage:
#   conda activate cfmdbench-r
#   Rscript conda/install_r_packages.R
#
# To also install the R torch backend (required only for the 'mlp' learner):
#   INSTALL_R_TORCH=1 Rscript conda/install_r_packages.R

options(repos = c(CRAN = "https://cloud.r-project.org"))

cran_packages <- c(
  # Core framework
  "callr", "coin", "compositions", "conflicted", "cowplot", "data.table",
  "emoa", "FactoMineR", "factoextra", "farff", "fastVoteR",
  "FSelectorRcpp", "future", "future.apply",
  # Network / data
  "httr", "jsonlite",
  # Learner backends
  "glmnet", "MASS", "ranger", "e1071", "naivebayes", "xgboost",
  # mlr3 ecosystem
  "iml", "lgr", "mlr3fairness", "mlr3filters", "mlr3fselect",
  "mlr3hyperband", "mlr3learners", "mlr3oml", "mlr3pipelines",
  "mlr3torch", "mlr3tuning", "mlr3tuningspaces", "mlr3viz",
  "pacman", "paradox", "progressr", "stabm",
  # Visualisation
  "patchwork", "plotly", "Rtsne", "scales", "wordcloud", "wordcloud2",
  # Compositional / ecological
  "vegan", "zCompositions",
  # Utilities
  "magrittr", "readr", "remotes", "reticulate", "stringr", "tidyverse",
  "torch", "yaml"
)

# ── Conda-compiled packages ────────────────────────────────────────────────────
# igraph, kknn, and smotefamily have compiled dependencies that are easiest to
# satisfy through conda-forge. The function below installs them that way and
# skips the conda call entirely when not in a Conda environment.

install_via_conda <- function(packages) {
  conda_prefix <- Sys.getenv("CONDA_PREFIX", unset = "")
  conda_exe    <- Sys.getenv("CONDA_EXE",    unset = Sys.which("conda"))

  if (!nzchar(conda_prefix) || !nzchar(conda_exe) || !length(packages)) {
    return(invisible(FALSE))
  }

  message("Installing compiled R packages from conda-forge: ",
          paste(packages, collapse = ", "))

  status <- system2(
    conda_exe,
    c("install", "-y", "--freeze-installed",
      "-p", conda_prefix,
      "-c", "conda-forge",
      packages)
  )

  if (!identical(status, 0L)) {
    warning("Conda installation failed for: ", paste(packages, collapse = ", "),
            ". Falling back to CRAN where possible.")
    return(invisible(FALSE))
  }
  invisible(TRUE)
}

conda_r_package_map <- c(
  igraph      = "r-igraph",
  kknn        = "r-kknn",
  smotefamily = "r-smotefamily"
)

missing_conda_pkgs <- names(conda_r_package_map)[!vapply(
  names(conda_r_package_map),
  requireNamespace, quietly = TRUE, FUN.VALUE = logical(1L)
)]

if (length(missing_conda_pkgs)) {
  install_via_conda(unname(conda_r_package_map[missing_conda_pkgs]))
}

# ── CRAN packages ──────────────────────────────────────────────────────────────
missing_cran <- cran_packages[!vapply(
  cran_packages,
  requireNamespace, quietly = TRUE, FUN.VALUE = logical(1L)
)]

if (length(missing_cran)) {
  install.packages(missing_cran, dependencies = TRUE)
}

# ── GitHub packages ────────────────────────────────────────────────────────────
if (!requireNamespace("mlr3extralearners", quietly = TRUE)) {
  remotes::install_github(
    "mlr-org/mlr3extralearners@*release",
    upgrade     = "never",
    dependencies = TRUE
  )
}

# ── Optional: R torch backend (only needed for the 'mlp' learner) ──────────────
if (identical(Sys.getenv("INSTALL_R_TORCH", unset = "0"), "1")) {
  if (!torch::torch_is_installed()) {
    torch::install_torch()
  }
}

message("R package bootstrap completed for the active Conda environment.")
