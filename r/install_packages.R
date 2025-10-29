# ensure CRAN mirror
if (is.null(getOption("repos")) || getOption("repos")[["CRAN"]] == "@CRAN@") {
  options(repos = c(CRAN = "https://cloud.r-project.org"))
}

pkgs <- c(
  # core framework
  "data.table","tidyverse","mlr3","mlr3learners","mlr3pipelines",
  "mlr3tuning","mlr3hyperband","mlr3viz","mlr3filters","mlr3fselect",
  "paradox","future","progressr",

  # learners
  "glmnet", "MASS", "kknn", "ranger", "e1071",
  "naivebayes", "xgboost", "smotefamily",

  # viz / analysis
  "ggplot2","plotly","cowplot","patchwork",
  "FactoMineR","factoextra","Rtsne","iml",
  "wordcloud","wordcloud2",

  # compositional
  "zCompositions","compositions",

  # utils / MLP
  "httr","jsonlite","torch","mlr3torch","reticulate"
)

missing <- setdiff(pkgs, rownames(installed.packages()))
if (length(missing)) install.packages(missing)

invisible(lapply(pkgs, require, character.only = TRUE))

if (!requireNamespace("remotes", quietly = TRUE)) install.packages("remotes")
remotes::install_github("mlr-org/mlr3extralearners")

