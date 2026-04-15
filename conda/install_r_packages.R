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
  "callr", "coin", "compositions", "conflicted", "cowplot", "data.table",
  "emoa", "FactoMineR", "factoextra", "farff", "fastVoteR",
  "FSelectorRcpp", "future", "future.apply",
  "httr", "jsonlite",
  "glmnet", "MASS", "ranger", "naivebayes",
  "iml", "lgr", "mlr3fairness", "mlr3filters", "mlr3fselect",
  "mlr3hyperband", "mlr3learners", "mlr3oml", "mlr3pipelines",
  "mlr3torch", "mlr3tuning", "mlr3tuningspaces", "mlr3viz",
  "pacman", "paradox", "progressr", "stabm",
  "patchwork", "plotly", "Rtsne", "scales", "wordcloud", "wordcloud2",
  "vegan", "zCompositions",
  "magrittr", "readr", "remotes", "reticulate", "stringr", "tidyverse",
  "torch", "yaml"
)

# ── Conda-compiled packages ────────────────────────────────────────────────────
# Packages with compiled dependencies are installed via conda-forge to avoid
# toolchain mismatches. Falls back silently when not inside a Conda env.

install_via_conda <- function(packages) {
  conda_prefix <- Sys.getenv("CONDA_PREFIX", unset = "")
  conda_exe    <- Sys.getenv("CONDA_EXE",    unset = Sys.which("conda"))

  if (!nzchar(conda_prefix) || !nzchar(conda_exe) || !length(packages)) {
    return(invisible(FALSE))
  }

  message(
    "Installing compiled R packages from conda-forge: ",
    paste(packages, collapse = ", ")
  )

  status <- system2(
    conda_exe,
    c("install", "-y", "--freeze-installed",
      "-p", conda_prefix,
      "-c", "conda-forge",
      packages)
  )

  if (!identical(status, 0L)) {
    warning(
      "Conda installation failed for: ", paste(packages, collapse = ", "),
      ". Falling back to CRAN where possible."
    )
    return(invisible(FALSE))
  }
  invisible(TRUE)
}

conda_r_package_map <- c(
  igraph      = "r-igraph",
  kknn        = "r-kknn",
  smotefamily = "r-smotefamily",
  e1071       = "r-e1071",
  xgboost     = "r-xgboost"
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
    upgrade      = "never",
    dependencies = TRUE
  )
}

# ── Optional: R torch backend (only needed for the 'mlp' learner) ─────────────
if (identical(Sys.getenv("INSTALL_R_TORCH", unset = "0"), "1")) {
  if (!torch::torch_is_installed()) {
    torch::install_torch()
  }
}

# ── Post-install diagnostic ───────────────────────────────────────────────────
all_packages <- unique(c(
  cran_packages,
  names(conda_r_package_map),
  "mlr3", "mlr3extralearners"
))

is_available <- vapply(
  all_packages, requireNamespace, quietly = TRUE, FUN.VALUE = logical(1L)
)
ok  <- all_packages[ is_available]
bad <- all_packages[!is_available]

message("\n── Package check ───────────────────────────────────────────────")
message(sprintf("OK      (%d): %s", length(ok), paste(sort(ok), collapse = ", ")))
if (length(bad)) {
  message(
    sprintf("MISSING (%d): %s", length(bad), paste(sort(bad), collapse = ", "))
  )
  message("Re-run this script or install missing packages manually.")
} else {
  message("All packages present.")
}
message("────────────────────────────────────────────────────────────────")

message("R package bootstrap completed for the active Conda environment.")