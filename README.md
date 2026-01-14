# cFMDbench

*ML classification on cFMD taxonomic profiles with mlr3. Quarto workflow. Conda envs. For teaching and testing.*

[![R](https://img.shields.io/badge/R-276DC3?style=for-the-badge&logo=r&logoColor=white)](https://www.r-project.org/)
[![mlr3](https://img.shields.io/badge/mlr3-0A0A0A?style=for-the-badge)](https://mlr3.mlr-org.com/)
[![Python](https://img.shields.io/badge/Python-3776AB?style=for-the-badge&logo=python&logoColor=white)](https://www.python.org/)
[![scikit-learn](https://img.shields.io/badge/scikit--learn-F7931E?style=for-the-badge&logo=scikitlearn&logoColor=white)](https://scikit-learn.org/)
[![Torch](https://img.shields.io/badge/Torch-EE4C2C?style=for-the-badge&logo=pytorch&logoColor=white)](https://pytorch.org/)
[![Conda](https://img.shields.io/badge/Conda-44A833?style=for-the-badge&logo=anaconda&logoColor=white)](https://docs.conda.io/)
[![Quarto](https://img.shields.io/badge/Quarto-3D5A80?style=for-the-badge&logo=quarto&logoColor=white)](https://quarto.org/)
[![Positron](https://img.shields.io/badge/Positron-3C6E71?style=for-the-badge&logo=posit&logoColor=white)](https://posit.co/positron/)

## Rationale

`cFMDbench` provides a workflow for machine‑learning classification on metagenomic taxonomic profiles using the [mlr3](https://mlr3.mlr-org.com/) ecosystem. The benchmark uses [cFMD](https://github.com/SegataLab/cFMD), the largest public food microbiome resource, enabling model training and comparisons on metagenomic data. The goals are didactic and testing: demonstrate data import, filtering, feature selection, tuning, and evaluation across multiple learners.

## Table of Contents
- [Installation](#installation)
- [Configuration](#configuration)
- [Run](#run)
- [cFMDbench roadmap](#cfmdbench-roadmap)
- [Acknowledgements](#acknowledgements)
- [Citation](#citation)

## Installation

### 1) R environment
    
  Create an R‑focused Conda environment, then install core R packages with a script. Remaining packages will auto‑install at first run via pacman:

  ```bash
  # create the R env
  conda env create -f envs/r-env.yml
  conda activate Renv

  # install core R packages within Renv
  Rscript r/install_packages.R
  ```
  - *On first run, `cFMDbench.qmd` uses pacman to automatically install any missing R packages.*
  - *In Positron, select the R interpreter from the `Renv` Conda environment, e.g. path/to//miniconda3/envs/Renv/bin/R.*

### 2) TabPFN environment

  [TabPFN](https://github.com/PriorLabs/TabPFN) is used through reticulate from R. Create a separate Conda environment; the example below targets GPU (CUDA) Torch:

  ```bash
  conda env create -f envs/tabpfn-gpu.yml
  ```
  - *Ensure reticulate uses this Conda environment when running tabpfn: `cFMDbench.qmd` reads the environment name and path from `~/.Renviron`, see [Configuration](#configuration), below.*
  - *To run the latest model (November 2025), i.e. TabPFN-2.5, further effort is required. Please follow indications [here](https://huggingface.co/Prior-Labs/tabpfn_2_5).*

## Configuration

These variables are not hard‑coded in `cFMDbench.qmd`. Define them in .Renviron. Provide a local file only on your machine.

Example `~/.Renviron`:

```bash
# use a GitHub Personal Access Token
GITHUB_TOKEN=ghp_your_personal_access_token_here

# working directory for temporary data and produced artifacts
CFMD_BENCH_WORKDIR=/absolute/path/to/your/workdir

# name of the Conda env that holds TabPFN + Python deps
TABPFN_ENV_NAME=tabpfn-gpu

# Conda root where the TabPFN env lives
TABPFN_CONDA_ROOT=/absolute/path/to/miniconda3
```
- *Reload `.Renviron` by restarting your R session.*

## Run

This repository is currently for didactic and testing purposes. Recommended usage is interactive:
  
  - Open `qmd/cFMDbench.qmd` in [Positron](https://positron.posit.co/).
  - Select the R interpreter from the `Renv` Conda environment.
  - Run chunks to inspect data import, filtering, feature selection, model training, and evaluation.
  - Customize parameters in the `cFMDbench.qmd` (filters, resampling, hyperparameters, tuning). Add more learners as needed.

## cFMDbench roadmap

Below is a compact description of every code chunk and its role in the analysis.

A quick glance at selected outputs from the workflow, based on chosen learners, is also provided:

- **Setup PATH** — Reads `CFMD_BENCH_WORKDIR` from `~/.Renviron` and sets the working directory.

- **Methods and Libraries** — Choose which learners to tune and loads R packages accordingly, while `pacman` auto-installs any missing ones.

- **Set Parameters** — Global run switches: fast/accurate mode, logging, seed, source `GITHUB_TOKEN`, define filter threshold, SMOTE method, and target.

- **Import Data** — Imports cFMD taxonomic profiles, handles filtering, harmonizes metadata, builds combined tables.
  > Note: after importing all taxonomic profiles from cFMD v1.2.1 and initial filtering, 3,252 metagenomes were combined, featuring 4,058 taxa.

- **Visualize Data I** — Quick exploratory data analysis plots of class balance, number of samples and product type per food category, *etc* (Figure 1-3).

  ![Figure 1](output/figures/Fig1.svg)

  ### <p align="left"><i>Figure 1: Sample counts by food category, with the number of distinct types per category.</i></p>

  ![Figure 2](output/figures/Fig2.svg)

  ### <p align="left"><i>Figure 2: Sample counts by dairy type.</i></p>

  ![Figure 3](output/figures/Fig3.svg)

  ### <p align="left"><i>Figure 3: Wordcloud of cheese subtypes.</i></p>

- **Pre-Process I** — Drop categories with too few samples, based on a threshold and infer classification metrics.

- **Visualize Data II** — Data transformation, PCA and related plots, t-SNE plot.

- **Define Task** — Builds the `mlr3` classification task with target, features, and resampling splits (train/test) (Figure 4).

  ![Figure 4](output/figures/Fig4.svg)

  ### <p align="left"><i>Figure 4: Distribution of samples across food categories in the train set (80% split).</i></p>

- **Pre-Process II** — `mlr3pipelines` graph for robustification, scaling, encoding, correlation|variance|info gain, smoting, scaling, etc.

- **Feature Selection** — Runs simple (`Random Forest` importance) or ensemble feature selection (i.e. generates consensus feature ranking based on `Rpart`, `RF`, `SVM`, and `XGBoost`). Optional.
  > Note: in this example, a simple feature-importance filter with Random Forest reduced the feature space from 4,058 taxa to 146. All learners were then tuned and evaluated using only this reduced set on the training split.

- **Visualize Data III** — Post-FS diagnostics and ordination (e.g., t-SNE) on the training set (Figure 5).

  ![Figure 5](output/figures/Fig5.svg)

  ### <p align="left"><i>Figure 5: t-SNE plot based on train set data and selected features.</i></p>

- **Train Learners** — Defines learners, sets hyperparams and run tuning instances with `k-fold` or `repeated k-fold` cross validation. `LODO` will be implemented soon.
  > Note: both MLP and TabPFN in the script can run on CPU-only or CPU+GPU. GPU mode accelerates training substantially.

- **Benchmark** — Benchmarks tuned learners on the training split; collects metrics (accuracy, balanced accuracy, logloss) (Figure 6-7).
  > ### Benchmark on 80% split train set and selected features (10-fold cross validation)

  | method                 | accuracy | balanced accuracy | logloss | tuning time* |
  |------------------------|---------:|------------------:|--------:|-------------:|
  | Random Forest          | 0.9644   | 0.8665            | 0.2904  | ~10 min      |
  | Support Vector Machine | 0.9244   | 0.7573            | 0.2779  | ~20 min      |
  | TabPFN                 | 0.9687   | 0.9416            | 0.1384  | ~4 min       |
  | XGBoost                | 0.9711   | 0.8951            | 0.1079  | ~80 min      |

  > *On a workstation with AMD Ryzen Threadripper (32 cores), 256 GB RAM, and NVIDIA GeForce RTX 4090.

  ![Figure 6](output/figures/Fig6.svg)

  ### <p align="left"><i>Figure 6: Performance by learner across multiple metrics.</i></p>

  ![Figure 7](output/figures/Fig7.svg)

  ### <p align="left"><i>Figure 7: Best tuned learner selected by balanced accuracy. Panels show, from left to right: absolute counts of TRUE/FALSE predictions per class; relative composition of TRUE/FALSE per class; confusion matrix plot.</i></p>

- **Prediction** — Fits tuned learners on train, predicts on test; stores predictions and match/ratio tables (Figure 8).
  > ### Performance of tuned learners on 20% split test set
  
  | method                 | accuracy | balanced accuracy | logloss |
  |------------------------|---------:|------------------:|--------:|
  | Random Forest          | 0.9636   | 0.8670            | 0.2327  |
  | Support Vector Machine | 0.9272   | 0.7858            | 0.2816  |
  | TabPFN                 | 0.9573   | 0.9260            | 0.1591  |
  | XGBoost                | 0.9794   | 0.9063            | 0.0879  |

  > ### TRUE/FALSE prediction counts and ratios
    **Random Forest**
    | match |   n | ratio |
    |:-----:|----:|------:|
    | FALSE |  23 | 0.04  |
    | TRUE  | 609 | 0.96  |

    **Support Vector Machine**
    | match |   n | ratio |
    |:-----:|----:|------:|
    | FALSE |  46 | 0.07  |
    | TRUE  | 586 | 0.93  |

    **TabPFN**
    | match |   n | ratio |
    |:-----:|----:|------:|
    | FALSE |  27 | 0.04  |
    | TRUE  | 605 | 0.96  |

    **XGBoost**
    | match |   n | ratio |
    |:-----:|----:|------:|
    | FALSE |  13 | 0.02  |
    | TRUE  | 619 | 0.98  |

  ![Figure 8](output/figures/Fig8.svg)

  ### <p align="left"><i>Figure 8: Relative composition of TRUE/FALSE predictions by each learner across food categories.</i></p>

- **Performance Comparison** — Aggregates and formats train/test performances of tuned learners using multiple metrics (Figure 9).

  ![Figure 9](output/figures/Fig9.svg)

    ### <p align="left"><i>Figure 9: For each model, bars show the test–train performance difference across classification metrics, indicating over/under-fitting.</i></p>

- **Feature Importance** — Model explainability: permutation importance or `SHAP` (Figure 10).

  ![Figure 10](output/figures/Fig10.svg)

    ### <p align="left"><i>Figure 10: Example of class-specific SHAP contribution for XGBoost, based on 100 samples and 10 features.</i></p>

## Acknowledgements
- [MASTER](https://www.master-h2020.eu/) — Microbiome Applications for Sustainable food systems through Technologies and Enterprise.
- [DOMINO](https://www.domino-euproject.eu/) — Harnessing the potential of fermentation for healthy and sustainable foods.
- [FlavourFerm](https://www.flavourferm.eu/) — Unleashing the flavour potential of plant-based foods.
  
## Citation
- Carlino, Niccolò et al. “Unexplored microbial diversity from 2,500 food metagenomes and links with the human microbiome.” Cell vol. 187,20 (2024): 5775-5795.e15. doi:10.1016/j.cell.2024.07.039

