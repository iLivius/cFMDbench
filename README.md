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

cFMDbench provides a workflow for machine‑learning classification on metagenomic taxonomic profiles using the mlr3 ecosystem.The benchmark uses [cFMD](https://github.com/SegataLab/cFMD), the largest public food microbiome resource, enabling model training and comparisons on metagenomic data. The goals are didactic and testing: demonstrate data import, filtering, feature selection, tuning, and evaluation across multiple learners.

## Table of Contents
- [Installation](#installation)
- [Configuration](#configuration)
- [Run](#run)
- [Acknowledgements](#acknowledgements)
- [Citation](#citation)

## Installation

1) R environment

  Create an R‑focused Conda environment, then install core R packages with a script. Remaining packages will auto‑install at first run via pacman:

  ```bash
  # create the R env
  conda env create -f envs/r-env.yml
  conda activate Renv

  # install core R packages within Renv
  Rscript r/install_packages.R
  ```
  - *On first run, cFMDbench.qmd uses pacman to automatically install any missing R packages.*
  - *In Positron, select the R interpreter from the Renv Conda environment, e.g. path/to//miniconda3/envs/Renv/bin/R.*

2) TabPFN environment

  TabPFN is used through reticulate from R. Create a separate Conda environment; the example below targets GPU (CUDA) Torch:

  ```bash
  conda env create -f envs/tabpfn-gpu.yml
  ```
  - *Ensure reticulate uses this Conda environment when running tabpfn: cFMDbench.qmd reads the environment name and path from ~/.Renviron, see [Configuration](#configuration), below.*

## Configuration

These variables are not hard‑coded in cFMDbench.qmd. Define them in .Renviron. Provide a local file only on your machine.

Example ~/.Renviron:

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
- *Reload .Renviron by restarting your R session.*

## Run

This repository is currently for didactic and testing purposes. Recommended usage is interactive:
  
  - Open qmd/cFMDbench.qmd in Positron.
  - Select the R interpreter from the Renv Conda environment.
  - Run chunks to inspect data import, filtering, feature selection, model training, and evaluation.
  - Customize parameters in the cFMDbench.qmd (filters, resampling, hyperparameters, tuning). Add more learners as needed.

## Acknowledgements
- [MASTER](https://www.master-h2020.eu/) — Microbiome Applications for Sustainable food systems through Technologies and Enterprise.
- [DOMINO](https://www.domino-euproject.eu/) — Harnessing the potential of fermentation for healthy and sustainable foods.
- [FlavourFerm](https://www.flavourferm.eu/) — Unleashing the flavour potential of plant-based foods.
  
## Citation
- Carlino, Niccolò et al. “Unexplored microbial diversity from 2,500 food metagenomes and links with the human microbiome.” Cell vol. 187,20 (2024): 5775-5795.e15. doi:10.1016/j.cell.2024.07.039

