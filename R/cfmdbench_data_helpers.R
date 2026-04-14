#!/usr/bin/env Rscript
# cfmdbench_data_helpers.R
# Download, cache, and pre-process cFMD taxonomic profiles from GitHub.
# All network I/O is isolated here so the main notebook stays clean.

# ── GitHub API helpers ─────────────────────────────────────────────────────────

#' Build a GitHub Contents API URL pinned to a specific ref.
#'
#' Pinning to a ref (tag, commit, or branch) ensures reproducibility: the same
#' config always fetches the same data, regardless of later repo changes.
cfmdbench_gh_url <- function(repo, path, ref) {
  sprintf("https://api.github.com/repos/%s/contents/%s?ref=%s", repo, path, ref)
}

#' Return an httr auth header using the GITHUB_TOKEN env var.
#'
#' Authenticated requests get a much higher GitHub API rate limit (5000/hr vs
#' 60/hr for anonymous), which matters when fetching dozens of project files.
cfmdbench_gh_header <- function(token) {
  httr::add_headers(Authorization = paste("token", token))
}

#' List project folder names under `data_path` in the cFMD repo.
cfmdbench_list_projects <- function(repo, data_path, ref, token) {
  url  <- cfmdbench_gh_url(repo, data_path, ref)
  resp <- httr::GET(url, cfmdbench_gh_header(token))
  httr::stop_for_status(resp)
  vapply(httr::content(resp, as = "parsed"), function(x) x$name, character(1L))
}

# ── Per-project download ───────────────────────────────────────────────────────

#' Download a single project's taxonomic profile TSV with SHA-based caching.
#'
#' Caching works by comparing the file's SHA from the GitHub API against the
#' SHA stored in a local manifest (an RDS file updated after each batch). If
#' they match and the local TSV exists, the download is skipped entirely. This
#' avoids re-downloading unchanged files between runs while still picking up
#' genuine updates when the cFMD dataset is revised. The download is written
#' to a temporary file first and renamed on success, so a partial download
#' never corrupts the local cache.
#'
#' @param project    Project folder name (e.g. "HMP2").
#' @param repo       GitHub repo slug.
#' @param data_path  Sub-path inside the repo containing project folders.
#' @param ref        Git ref (tag / commit / branch) to pin the download to.
#' @param token      GitHub personal access token.
#' @param cache_dir  Local directory for cached TSV files.
#' @param cached_sha SHA stored in the manifest for this project (or NULL if
#'   this project has not been downloaded before).
#' @return A list(df = <data.frame or NULL>, sha = <string or NULL>).
cfmdbench_download_profile <- function(project, repo, data_path, ref, token,
                                       cache_dir, cached_sha = NULL) {
  file_path <- sprintf("%s/%s/%s_taxonomic_profiles.tsv", data_path, project, project)
  api_url   <- cfmdbench_gh_url(repo, file_path, ref)
  local_tsv <- file.path(cache_dir, paste0(project, "_taxonomic_profiles.tsv"))

  # The metadata call is cheap (JSON only) and gives us the current SHA and
  # the raw download URL without transferring the file itself.
  meta <- httr::GET(api_url, cfmdbench_gh_header(token))
  if (httr::status_code(meta) != 200L) {
    message(sprintf("Skipped (API %s): %s", httr::status_code(meta), project))
    return(NULL)
  }
  info <- httr::content(meta, as = "parsed")
  sha  <- info$sha
  raw  <- info$download_url

  # Only download if the local copy is missing or the remote SHA has changed.
  need_download <- !(file.exists(local_tsv) &&
                     !is.null(cached_sha) &&
                     identical(cached_sha, sha))

  if (need_download) {
    tmp  <- paste0(local_tsv, ".tmp")
    resp <- httr::GET(raw,
                      httr::write_disk(tmp, overwrite = TRUE),
                      httr::progress())
    if (httr::status_code(resp) != 200L) {
      message(sprintf("Skipped (download %s): %s", httr::status_code(resp), project))
      if (file.exists(tmp)) unlink(tmp)
      return(NULL)
    }
    file.rename(tmp, local_tsv)
    message("Downloaded: ", project)
  } else {
    message("Cached:     ", project)
  }

  df <- cfmdbench_parse_profile_tsv(local_tsv, project)
  list(df = df, sha = sha)
}

# ── TSV parsing ────────────────────────────────────────────────────────────────

#' Parse a taxonomic profile TSV, handling the malformed two-header variant
#' produced by some cFMD projects (empty first cell on line 1; true header on
#' line 2).
#'
#' The two-header format appears to be an artefact of certain export pipelines
#' in the cFMD dataset. Rather than patching the upstream files, we detect it
#' here: if line 1 starts with a tab and line 2 starts with "sample\t", we
#' skip line 1 and use line 2 as column names.
#'
#' @return A data.frame with a "Taxon" column and one column per sample,
#'   or NULL on parse failure.
cfmdbench_parse_profile_tsv <- function(local_tsv, project) {
  tryCatch({
    lines2 <- readLines(local_tsv, n = 2L, warn = FALSE)
    weird_header <- length(lines2) >= 2L &&
      grepl("^\t", lines2[1L]) &&
      grepl("^sample\t", lines2[2L])

    if (weird_header) {
      tmp       <- readr::read_tsv(local_tsv, col_names = FALSE,
                                   col_types = readr::cols(), show_col_types = FALSE)
      new_names <- as.character(tmp[2L, ])
      tmp       <- tmp[-c(1L, 2L), , drop = FALSE]
      names(tmp) <- new_names
      dplyr::rename(tmp, Taxon = 1L)
    } else {
      readr::read_tsv(local_tsv, col_types = readr::cols(),
                      show_col_types = FALSE) %>%
        dplyr::rename(Taxon = 1L)
    }
  }, error = function(e) {
    message("Failed to parse: ", project, " — ", e$message)
    NULL
  })
}

# ── Batch fetching ─────────────────────────────────────────────────────────────

#' Download all projects in batches with SHA-based caching and API rate limiting.
#'
#' Projects are processed in fixed-size batches with a 2-second pause between
#' them — a simple courtesy to the GitHub API that keeps request rates well
#' below the authenticated limit even for large datasets. The manifest is saved
#' after each batch, so progress is preserved if the run is interrupted midway.
#'
#' @param projects      Character vector of project names from cfmdbench_list_projects().
#' @param repo,data_path,ref,token  Forwarded to cfmdbench_download_profile().
#' @param cache_dir     Local cache directory for TSV files.
#' @param manifest_path RDS file mapping project names to their current SHAs.
#' @param batch_size    Number of projects per batch (2-second sleep between batches).
#' @return Named list of data.frames, one per successfully loaded project.
cfmdbench_fetch_profiles <- function(projects, repo, data_path, ref, token,
                                     cache_dir, manifest_path,
                                     batch_size = 10L) {
  manifest     <- if (file.exists(manifest_path)) readRDS(manifest_path) else list()
  profile_list <- list()
  batches      <- split(projects, ceiling(seq_along(projects) / batch_size))

  for (batch in batches) {
    message("Processing batch: ", paste(batch, collapse = ", "))

    for (project in batch) {
      result <- cfmdbench_download_profile(
        project, repo, data_path, ref, token, cache_dir,
        cached_sha = manifest[[project]]
      )
      if (!is.null(result)) {
        profile_list[[project]] <- result$df
        if (!is.null(result$sha)) manifest[[project]] <- result$sha
      }
    }

    saveRDS(manifest, manifest_path)
    Sys.sleep(2)          # gentle on the GitHub API
    closeAllConnections()
  }

  message("Loaded ", length(profile_list), " of ", length(projects), " profiles.")
  if (!length(profile_list))
    stop("No profiles loaded — check GITHUB_TOKEN and the dataset ref.")
  profile_list
}

# ── Data preparation ───────────────────────────────────────────────────────────

#' Merge per-project profiles, split metadata from taxa rows, filter samples by
#' completeness, and transpose to a sample × feature tibble.
#'
#' The raw profiles arrive as feature × sample matrices (rows = taxa or
#' metadata fields, columns = samples). The final transposition converts them
#' to the sample × feature layout expected by mlr3 and most modelling code.
#'
#' Taxa rows are distinguished from metadata rows by two complementary
#' heuristics applied to the Taxon column:
#'
#'   1. Label-based: the string contains a rank prefix (k__, p__, etc.),
#'      a pipe separator (QIIME-style lineages), or a semicolon (Greengenes).
#'   2. Content-based: more than 90% of the row's values parse as numeric.
#'      This catches taxa rows that lack standard prefixes.
#'
#' Rows matching either heuristic are treated as taxa; everything else is
#' treated as sample-level metadata (category, type, subtype, etc.).
#'
#' @param profile_list         Named list from cfmdbench_fetch_profiles().
#' @param completeness_threshold Minimum per-sample taxa abundance sum (percent,
#'   default 99). Controlled by data_source.completeness_threshold in config.yaml.
#' @return A tibble (samples × features) ready for the preprocessing chunks.
cfmdbench_prepare_data <- function(profile_list, completeness_threshold = 99L) {
  merged      <- purrr::reduce(profile_list, dplyr::full_join, by = "Taxon")
  sample_cols <- setdiff(names(merged), "Taxon")
  message("Merged: ", nrow(merged), " rows × ", ncol(merged), " cols.")

  taxon_chr <- as.character(merged$Taxon)

  # Heuristic 1: taxa rows carry standard rank or lineage separators.
  is_taxa_by_label <-
    grepl("^(?:[dkpcofgs]__|k__)", taxon_chr) |
    grepl("\\|",  taxon_chr) |
    grepl(";", taxon_chr, fixed = TRUE)

  # Heuristic 2: rows where almost all values are numeric are abundance data,
  # not categorical metadata.
  num_ok_frac    <- apply(merged[sample_cols], 1L,
                          function(r) mean(!is.na(suppressWarnings(as.numeric(r)))))
  is_taxa_by_num <- num_ok_frac > 0.9
  is_taxa        <- is_taxa_by_label | is_taxa_by_num

  metadata  <- merged[!is_taxa, , drop = FALSE]
  taxa_only <- merged[ is_taxa, , drop = FALSE]
  message("Taxa rows: ", nrow(taxa_only), " | metadata rows: ", nrow(metadata))

  if (!nrow(taxa_only))
    stop("No taxa rows detected after merge — check the dataset ref.")

  # Coerce taxa columns to numeric, replace NA with 0.
  for (nm in sample_cols) {
    taxa_only[[nm]] <- suppressWarnings(as.numeric(taxa_only[[nm]]))
    taxa_only[[nm]][is.na(taxa_only[[nm]])] <- 0
  }

  # Drop samples whose total abundance falls below the threshold. These are
  # typically samples with poor sequencing depth or incomplete profiles that
  # would distort relative-abundance comparisons.
  col_sums   <- colSums(taxa_only[sample_cols], na.rm = TRUE)
  good_samps <- names(col_sums[col_sums >= completeness_threshold])
  if (!length(good_samps))
    stop("No samples meet completeness_threshold = ", completeness_threshold, ".")
  message("Kept ", length(good_samps), " samples with >= ",
          completeness_threshold, "% completeness.")

  taxa_filt <- taxa_only[, c("Taxon", good_samps), drop = FALSE] %>%
    dplyr::mutate(dplyr::across(dplyr::all_of(good_samps), as.character))
  meta_filt <- metadata[, c("Taxon", good_samps), drop = FALSE]

  # Reunite metadata and taxa rows before transposing so the entire matrix
  # goes through the same operation in one step.
  filtered <- dplyr::bind_rows(meta_filt, taxa_filt)

  # Transpose: each sample becomes a row, each taxon / metadata field becomes
  # a column. make.unique handles any duplicate Taxon strings arising from
  # joining profiles across projects.
  transposed    <- t(filtered[-1L])
  tab           <- as.data.frame(transposed)
  colnames(tab) <- make.unique(as.character(filtered$Taxon))

  sample_ids <- rownames(tab)
  if (is.null(sample_ids)) sample_ids <- as.character(seq_len(nrow(tab)))

  # Avoid a name collision if a metadata field happens to be called "sample".
  if ("sample" %in% names(tab))
    tab <- dplyr::rename(tab, sample_meta = sample)

  tab <- tibble::as_tibble(tab)
  tab$sample <- sample_ids

  # Re-level categorical metadata columns alphabetically so factor levels are
  # consistent across projects that may have exported categories in different
  # orders. This matters for mlr3 task creation and plotting.
  meta_cols <- names(tab)[!startsWith(names(tab), "k__")]
  tab <- dplyr::mutate(tab, dplyr::across(
    dplyr::all_of(meta_cols),
    ~ if (is.character(.x) || is.factor(.x))
        factor(.x, levels = sort(unique(.x)))
      else .x
  ))

  tab
}

# ── High-level entry point ─────────────────────────────────────────────────────

#' Download and prepare the full cFMD dataset.
#'
#' This is the only function called directly from the main notebook (import
#' chunk). It reads GITHUB_TOKEN from the environment, delegates downloading
#' to cfmdbench_fetch_profiles(), and data preparation to cfmdbench_prepare_data().
#' The lower-level helpers are exposed mainly for debugging individual projects.
#'
#' On first run, all profiles are downloaded and cached. On subsequent runs,
#' only profiles whose SHA has changed on GitHub are re-fetched; everything
#' else is loaded from the local cache_dir.
#'
#' Key parameters come from config.yaml (data_source section):
#'   - repo / path / ref  → which GitHub repo and version to fetch
#'   - completeness_threshold → how strict to be about incomplete samples
#'   - api_batch_size     → how many projects to fetch per API round
#'
#' @param repo                   GitHub repo slug (e.g. "SegataLab/cFMD").
#' @param data_path              Sub-path containing project folders.
#' @param ref                    Git ref (tag, commit, or branch).
#' @param cache_dir              Local cache directory for TSV files.
#' @param manifest_path          RDS file mapping project names to file SHAs.
#' @param completeness_threshold Minimum per-sample taxa sum (percent).
#' @param batch_size             Projects fetched per API batch.
#' @return A tidy tibble (samples × features) ready for the preprocessing chunks.
cfmdbench_load_data <- function(repo, data_path, ref,
                                cache_dir, manifest_path,
                                completeness_threshold = 99L,
                                batch_size = 10L) {
  token <- Sys.getenv("GITHUB_TOKEN")
  if (!nzchar(token))
    stop("GITHUB_TOKEN not set. Add it to ~/.Renviron or a project .Renviron.")

  dir.create(cache_dir, recursive = TRUE, showWarnings = FALSE)

  projects     <- cfmdbench_list_projects(repo, data_path, ref, token)
  profile_list <- cfmdbench_fetch_profiles(
    projects, repo, data_path, ref, token,
    cache_dir, manifest_path, batch_size
  )

  cfmdbench_prepare_data(profile_list, completeness_threshold)
}
