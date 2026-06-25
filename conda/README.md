# Conda Environments

This folder contains two Conda environment specifications and the R package
bootstrap script.

- `cfmdbench-r.yml` — the R-side environment used to open and render the
  Quarto notebook from Positron, VS Code, RStudio, or the terminal.
- `cfmdbench-tabpfn-gpu.yml` — the Python environment used only when the
  workflow runs `tabpfn` through `reticulate`.
- `install_r_packages.R` — installs/checks the default R package set in the
  active Conda environment. Optional learner bridges are installed only when
  explicitly requested.

## Recommended setup

Create the R environment first:

```bash
conda env create -f conda/cfmdbench-r.yml
conda activate cfmdbench-r
Rscript conda/install_r_packages.R
```

The default command is enough for the `ranger` and `xgboost` workflow. If you
plan to use the `mlp` learner, also install the R torch backend:

```bash
INSTALL_R_TORCH=1 Rscript conda/install_r_packages.R
```

Create the TabPFN GPU environment and install the R learner bridge only if you
plan to use `tabpfn`:

```bash
INSTALL_TABPFN_R=1 Rscript conda/install_r_packages.R
conda env create -f conda/cfmdbench-tabpfn-gpu.yml
```

Point the workflow to the Python environment and your HuggingFace token via
`~/.Renviron` or a project-level `.Renviron`:

```
TABPFN_CONDA_ROOT=/path/to/miniconda3
TABPFN_ENV_NAME=cfmdbench-tabpfn-gpu
HF_TOKEN=hf_xxx
```

The GitHub token needed to download the cFMD dataset must also be set:

```
GITHUB_TOKEN=ghp_xxx
```

## Notes

- The R environment is the main environment for this repository.
- The TabPFN environment is optional. Methods such as `ranger` and `xgboost`
  work without it.
- `mlr3extralearners`, R `torch`, Java/Weka, and h2o-related learner
  dependencies are not part of the default install path.
- Run `install_r_packages.R` from `cfmdbench-r`, not Conda `base`; the script
  exits early if `base` is active.
- GPU support is strongly recommended for TabPFN; repeated resampling on CPU
  is practical but much slower.
- The old `envs/` directory (pre-refactor) contained a fully-pinned monolithic
  environment. It has been superseded by this minimal specification +
  `install_r_packages.R`, which is easier to recreate across platforms.

## RStudio users

The project includes a `cFMDbench.Rproj` file. Open it from a
conda-activated terminal so RStudio inherits the conda R binary, library
paths, and Quarto installation:

```bash
conda activate cfmdbench-r
rstudio cFMDbench.Rproj &
```

RStudio will read the project `.Rprofile` on startup, which prepends the
conda library to `.libPaths()`. Quarto chunks run against the same conda R
process, and `reticulate` resolves the TabPFN env via `CONDA_PREFIX`.

> **Do not** open RStudio from a desktop shortcut or application launcher —
> those bypass conda activation and R will fall back to the system library.

To avoid typing the activation command every time, add an alias to
`~/.bashrc` or `~/.bash_aliases`:

```bash
alias cfmdbench='conda activate cfmdbench-r && rstudio /path/to/cFMDbench/cFMDbench.Rproj &'
```

## VS Code users (Linux)

When VS Code runs on a local notebook but the project lives on a server, use
Remote SSH and open the remote project folder. Commands such as `conda activate`,
`Rscript conda/install_r_packages.R`, and `quarto render` should run in the
remote terminal.

The VS Code R extension can spawn R as a direct subprocess without activating
the Conda environment first, so `.libPaths()` may point to the system R library
instead of the Conda env library. The project `.Rprofile` corrects this
automatically when R starts in the project root and `CONDA_PREFIX` is set.

A workspace settings template is provided at `.vscode/settings.json.example`.
Copy it and fill in your actual Conda path:

```bash
cp .vscode/settings.json.example .vscode/settings.json
# then edit settings.json and replace /path/to/miniconda3 with:
conda activate cfmdbench-r && echo $CONDA_PREFIX
```

`.vscode/settings.json` is gitignored because it contains machine-specific
absolute paths. Never commit it — use the `.example` file as the shared
reference instead.
