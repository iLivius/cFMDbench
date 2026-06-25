#!/usr/bin/env Rscript
# Install/check the R packages used by the default cFMDbench workflow inside the
# active Conda environment. Optional learner backends are installed only when
# explicitly requested via environment variables.
#
# Usage:
#   conda activate cfmdbench-r
#   Rscript conda/install_r_packages.R
#
# Optional backends:
#   INSTALL_R_TORCH=1 Rscript conda/install_r_packages.R
#   INSTALL_TABPFN_R=1 Rscript conda/install_r_packages.R

options(repos = c(CRAN = "https://cloud.r-project.org"))

cran_dependencies <- c("Depends", "Imports", "LinkingTo")
install_r_torch  <- identical(Sys.getenv("INSTALL_R_TORCH",  unset = "0"), "1")
install_tabpfn_r <- identical(Sys.getenv("INSTALL_TABPFN_R", unset = "0"), "1")

message("Optional R torch backend: ", if (install_r_torch) "enabled" else "disabled")
message("Optional TabPFN R bridge: ", if (install_tabpfn_r) "enabled" else "disabled")

cran_packages <- c(
  "callr", "coin", "compositions", "conflicted", "cowplot", "data.table",
  "emoa", "FactoMineR", "factoextra", "farff", "fastVoteR",
  "FSelectorRcpp", "future", "future.apply",
  "httr", "jsonlite",
  "glmnet", "MASS", "ranger", "naivebayes",
  "iml", "lgr", "mlr3filters", "mlr3fselect",
  "mlr3hyperband", "mlr3learners", "mlr3pipelines",
  "mlr3tuning", "mlr3tuningspaces", "mlr3viz",
  "paradox", "progressr", "stabm",
  "patchwork", "plotly", "Rtsne", "scales", "wordcloud", "wordcloud2",
  "vegan", "zCompositions",
  "magrittr", "readr", "remotes", "reticulate", "stringr", "tidyverse",
  "yaml"
)

if (install_r_torch) {
  cran_packages <- unique(c(cran_packages, "mlr3torch", "torch"))
}

# Packages with compiled native dependencies should come from conda-forge. This
# avoids mixing Conda compilers with system headers/libraries, which is the class
# of failure seen when nanonext links against mismatched mbedTLS libraries.
conda_r_package_map <- c(
  data.table       = "r-data.table",
  e1071            = "r-e1071",
  glmnet           = "r-glmnet",
  igraph           = "r-igraph",
  kknn             = "r-kknn",
  mirai            = "r-mirai",
  mlr3             = "r-mlr3",
  mlr3filters      = "r-mlr3filters",
  mlr3fselect      = "r-mlr3fselect",
  mlr3hyperband    = "r-mlr3hyperband",
  mlr3learners     = "r-mlr3learners",
  mlr3pipelines    = "r-mlr3pipelines",
  mlr3tuning       = "r-mlr3tuning",
  mlr3tuningspaces = "r-mlr3tuningspaces",
  mlr3viz          = "r-mlr3viz",
  nanonext         = "r-nanonext",
  paradox          = "r-paradox",
  ranger           = "r-ranger",
  rpart            = "r-rpart",
  smotefamily      = "r-smotefamily",
  xgboost          = "r-xgboost"
)

ensure_conda_env <- function() {
  conda_prefix <- Sys.getenv("CONDA_PREFIX", unset = "")
  conda_exe    <- Sys.getenv("CONDA_EXE", unset = Sys.which("conda"))

  if (!nzchar(conda_prefix)) {
    stop(
      "No active Conda environment detected. Run:\n",
      "  conda activate cfmdbench-r\n",
      "  Rscript conda/install_r_packages.R",
      call. = FALSE
    )
  }
  if (identical(Sys.getenv("CONDA_DEFAULT_ENV", unset = ""), "base")) {
    stop(
      "The active Conda environment is 'base'. Run:\n",
      "  conda activate cfmdbench-r\n",
      "  Rscript conda/install_r_packages.R",
      call. = FALSE
    )
  }
  if (!nzchar(conda_exe)) {
    stop("Cannot find the conda executable in CONDA_EXE or PATH.", call. = FALSE)
  }

  list(prefix = conda_prefix, exe = conda_exe)
}

install_via_conda <- function(packages) {
  if (!length(packages)) return(invisible(TRUE))

  conda <- ensure_conda_env()
  message(
    "Installing compiled R packages from conda-forge: ",
    paste(packages, collapse = ", ")
  )

  status <- system2(
    conda$exe,
    c("install", "-y", "--freeze-installed",
      "-p", conda$prefix,
      "-c", "conda-forge",
      packages)
  )

  if (!identical(status, 0L)) {
    stop(
      "Conda installation failed for: ", paste(packages, collapse = ", "), "\n",
      "Resolve this Conda error before falling back to source R builds.",
      call. = FALSE
    )
  }
  invisible(TRUE)
}

missing_conda_pkgs <- names(conda_r_package_map)[!vapply(
  names(conda_r_package_map),
  requireNamespace, quietly = TRUE, FUN.VALUE = logical(1L)
)]

invisible(ensure_conda_env())
install_via_conda(unname(conda_r_package_map[missing_conda_pkgs]))

missing_cran <- cran_packages[!vapply(
  cran_packages,
  requireNamespace, quietly = TRUE, FUN.VALUE = logical(1L)
)]

if (length(missing_cran)) {
  message(
    "Installing remaining CRAN packages with dependencies limited to ",
    paste(cran_dependencies, collapse = ", "), ": ",
    paste(missing_cran, collapse = ", ")
  )
  install.packages(missing_cran, dependencies = cran_dependencies)
}

if (install_tabpfn_r && !requireNamespace("mlr3extralearners", quietly = TRUE)) {
  if (!requireNamespace("remotes", quietly = TRUE)) {
    install.packages("remotes", dependencies = cran_dependencies)
  }
  remotes::install_github(
    "mlr-org/mlr3extralearners@*release",
    upgrade      = "never",
    dependencies = cran_dependencies
  )
}

if (install_r_torch) {
  if (!requireNamespace("torch", quietly = TRUE)) {
    stop("Package 'torch' was not installed; re-run with INSTALL_R_TORCH=1.", call. = FALSE)
  }
  if (!torch::torch_is_installed()) {
    torch::install_torch()
  }
}

all_packages <- unique(c(
  cran_packages,
  names(conda_r_package_map),
  "mlr3"
))

if (install_tabpfn_r) {
  all_packages <- unique(c(all_packages, "mlr3extralearners"))
}

is_available <- vapply(
  all_packages, requireNamespace, quietly = TRUE, FUN.VALUE = logical(1L)
)
ok  <- all_packages[ is_available]
bad <- all_packages[!is_available]

message("\n-- Package check ------------------------------------------------")
message(sprintf("OK      (%d): %s", length(ok), paste(sort(ok), collapse = ", ")))
if (length(bad)) {
  message(
    sprintf("MISSING (%d): %s", length(bad), paste(sort(bad), collapse = ", "))
  )
  stop("Package bootstrap incomplete.", call. = FALSE)
}

message("All required packages are present.")
message("R package bootstrap completed for the active Conda environment.")
