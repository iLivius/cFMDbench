#!/usr/bin/env Rscript
# cfmdbench_data_helpers.R
# Download, cache, and pre-process cFMD taxonomic profiles from GitHub.
# All network I/O is isolated here so the main notebook stays clean.

# ── GitHub API helpers ─────────────────────────────────────────────────────────

#' Build a GitHub Contents API URL pinned to a specific ref.
cfmdbench_gh_url <- function(repo, path, ref) {
  sprintf("https://api.github.com/repos/%s/contents/%s?ref=%s", repo, path, ref)
}

#' Return an httr auth header using the GITHUB_TOKEN env var.
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
#' @param project  Project folder name (e.g. "HMP2").
#' @param repo     GitHub repo slug.
#' @param data_path Sub-path inside the repo containing project folders.
#' @param ref      Git ref (tag / commit / branch).
#' @param token    GitHub personal access token.
#' @param cache_dir Local directory for cached TSV files.
#' @param cached_sha SHA stored in the manifest for this project (or NULL).
#' @return A list(df = <data.frame or NULL>, sha = <string or NULL>).
cfmdbench_download_profile <- function(project, repo, data_path, ref, token,
                                       cache_dir, cached_sha = NULL) {
  file_path <- sprintf("%s/%s/%s_taxonomic_profiles.tsv", data_path, project, project)
  api_url   <- cfmdbench_gh_url(repo, file_path, ref)
  local_tsv <- file.path(cache_dir, paste0(project, "_taxonomic_profiles.tsv"))

  # Metadata call: get current SHA and raw download URL
  meta <- httr::GET(api_url, cfmdbench_gh_header(token))
  if (httr::status_code(meta) != 200L) {
    message(sprintf("Skipped (API %s): %s", httr::status_code(meta), project))
    return(NULL)
  }
  info <- httr::content(meta, as = "parsed")
  sha  <- info$sha
  raw  <- info$download_url

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
#' @param projects     Character vector of project names from cfmdbench_list_projects().
#' @param repo,data_path,ref,token  Passed through to cfmdbench_download_profile().
#' @param cache_dir    Local cache directory.
#' @param manifest_path  Path to the RDS manifest of project -> SHA mappings.
#' @param batch_size   Number of projects per batch (2-second sleep between batches).
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
#' @param profile_list Named list from cfmdbench_fetch_profiles().
#' @param completeness_threshold Minimum per-sample taxa sum (percent, default 99).
#' @return A tibble with columns: sample, <metadata cols>, <k__... taxon cols>.
cfmdbench_prepare_data <- function(profile_list, completeness_threshold = 99L) {
  merged      <- purrr::reduce(profile_list, dplyr::full_join, by = "Taxon")
  sample_cols <- setdiff(names(merged), "Taxon")
  message("Merged: ", nrow(merged), " rows × ", ncol(merged), " cols.")

  taxon_chr <- as.character(merged$Taxon)

  # Identify taxa rows by rank prefixes / separators and numeric content
  is_taxa_by_label <-
    grepl("^(?:[dkpcofgs]__|k__)", taxon_chr) |
    grepl("\\|",  taxon_chr) |
    grepl(";", taxon_chr, fixed = TRUE)

  num_ok_frac    <- apply(merged[sample_cols], 1L,
                          function(r) mean(!is.na(suppressWarnings(as.numeric(r)))))
  is_taxa_by_num <- num_ok_frac > 0.9
  is_taxa        <- is_taxa_by_label | is_taxa_by_num

  metadata  <- merged[!is_taxa, , drop = FALSE]
  taxa_only <- merged[ is_taxa, , drop = FALSE]
  message("Taxa rows: ", nrow(taxa_only), " | metadata rows: ", nrow(metadata))

  if (!nrow(taxa_only))
    stop("No taxa rows detected after merge — check the dataset ref.")

  # Coerce taxa columns to numeric, replace NA with 0
  for (nm in sample_cols) {
    taxa_only[[nm]] <- suppressWarnings(as.numeric(taxa_only[[nm]]))
    taxa_only[[nm]][is.na(taxa_only[[nm]])] <- 0
  }

  # Filter samples by completeness
  col_sums   <- colSums(taxa_only[sample_cols], na.rm = TRUE)
  good_samps <- names(col_sums[col_sums >= completeness_threshold])
  if (!length(good_samps))
    stop("No samples meet completeness_threshold = ", completeness_threshold, ".")
  message("Kept ", length(good_samps), " samples with >= ",
          completeness_threshold, "% completeness.")

  taxa_filt <- taxa_only[, c("Taxon", good_samps), drop = FALSE] %>%
    dplyr::mutate(dplyr::across(dplyr::all_of(good_samps), as.character))
  meta_filt <- metadata[, c("Taxon", good_samps), drop = FALSE]

  filtered <- dplyr::bind_rows(meta_filt, taxa_filt)

  # Transpose to sample × feature
  transposed  <- t(filtered[-1L])
  tab         <- as.data.frame(transposed)
  colnames(tab) <- make.unique(as.character(filtered$Taxon))

  sample_ids <- rownames(tab)
  if (is.null(sample_ids)) sample_ids <- as.character(seq_len(nrow(tab)))

  if ("sample" %in% names(tab))
    tab <- dplyr::rename(tab, sample_meta = sample)

  tab <- tibble::as_tibble(tab)
  tab$sample <- sample_ids

  # Re-level categorical metadata columns
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
#' Reads GITHUB_TOKEN from the environment. Caches downloaded TSVs in
#' `cache_dir` and tracks file SHAs in `manifest_path` to avoid redundant
#' re-downloads.
#'
#' @param repo                   GitHub repo slug (e.g. "SegataLab/cFMD").
#' @param data_path              Sub-path containing project folders.
#' @param ref                    Git ref (tag, commit, or branch).
#' @param cache_dir              Local cache directory for TSV files.
#' @param manifest_path          RDS file mapping project names to file SHAs.
#' @param completeness_threshold Minimum per-sample taxa sum (percent).
#' @param batch_size             Projects fetched per API batch.
#' @return A tidy tibble (samples × features) ready for pre-processing.
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
