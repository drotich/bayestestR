#' Generate posterior distributions weighted across models
#'
#' Extract posterior samples of parameters, weighted across models.
#' Weighting is done by comparing posterior model probabilities, via \code{\link{bayesfactor_models}}.
#'
#' @param missing An optional numeric value to use if a model does not contain a parameter that appears in other models. Defaults to 0.
#' @inheritParams bayesfactor_models
#' @inheritParams bayesfactor_inclusion
#' @inheritParams bayesfactor_parameters
#'
#' @details
#' Note that across models some parameters might play different roles. For example,
#' the parameter \code{A} plays a different role in the model \code{Y ~ A + B} (where it is a main effect)
#' than it does in the model \code{Y ~ A + B + A:B} (where it is a simple effect). In many cases centering
#' of predictors (mean subtracting for continuous variables, and effects coding via \code{contr.sum} or
#' orthonormal coding via {\code{\link{contr.bayes}}} for factors) can reduce this issue. In any case
#' you should be mindful of this issue.
#' \cr\cr
#' See \code{\link{bayesfactor_models}} details for more info on passed models.
#' \cr\cr
#' Note that for \code{BayesFactor} models, posterior samples cannot be generated from intercept only models.
#' \cr\cr
#' This function is similar in function to \code{brms::\link[brms]{posterior_average}}.
#'
#' @return A data frame with posterior distributions (weighted accross models) .
#'
#' @seealso \code{\link{bayesfactor_inclusion}} for Bayesian model averaging.
#'
#' @examples
#' \donttest{
#' library(rstanarm)
#' library(see)
#'
#' stan_m0 <- stan_glm(extra ~ 1, data = sleep,
#'                     family = gaussian(),
#'                     refresh=0,
#'                     diagnostic_file = file.path(tempdir(), "df0.csv"))
#'
#' stan_m1 <- stan_glm(extra ~ group, data = sleep,
#'                     family = gaussian(),
#'                     refresh=0,
#'                     diagnostic_file = file.path(tempdir(), "df1.csv"))
#'
#'
#' res <- weighted_posteriors(stan_m0, stan_m1)
#'
#' plot(eti(res))
#'
#' # With BayesFactor and brms
#' library(BayesFactor)
#' library(brms)
#'
#' BFmods <- anovaBF(extra ~ group + ID, sleep, whichRandom = "ID")
#'
#' res <- weighted_posteriors(BFmods)[1:3]
#' plot(eti(res))
#'
#' # Compare to brms::posterior_average
#' fit1 <- brm(rating ~ treat + period + carry,
#'             data = inhaler,
#'             save_all_pars = TRUE)
#' fit2 <- brm(rating ~ period + carry,
#'             data = inhaler,
#'             save_all_pars = TRUE)
#'
#' res_BT <- weighted_posteriors(fit1, fit2)
#' res_brms <- brms::posterior_average(fit1, fit2, weights = "marglik", missing = 0)[, 1:4]
#'
#' plot(eti(res_BT))
#' plot(eti(res_brms))
#' }
#'
#' @references
#' \itemize{
#'   \item Clyde, M., Desimone, H., & Parmigiani, G. (1996). Prediction via orthogonalized model mixing. Journal of the American Statistical Association, 91(435), 1197-1208.
#'   \item Hinne, M., Gronau, Q. F., van den Bergh, D., and Wagenmakers, E. (2019, March 25). A conceptual introduction to Bayesian Model Averaging. \doi{10.31234/osf.io/wgb64}
#'   \item Rouder, J. N., Haaf, J. M., & Vandekerckhove, J. (2018). Bayesian inference for psychology, part IV: Parameter estimation and Bayes factors. Psychonomic bulletin & review, 25(1), 102-113.
#'   \item van den Bergh, D., Haaf, J. M., Ly, A., Rouder, J. N., & Wagenmakers, E. J. (2019). A cautionary note on estimating effect size.
#' }
#'
#' @export
weighted_posteriors <- function(..., prior_odds = NULL, missing = 0, verbose = TRUE) {
  UseMethod("weighted_posteriors")
}

#' @export
#' @rdname weighted_posteriors
#' @importFrom insight get_parameters
weighted_posteriors.stanreg <- function(..., prior_odds = NULL, missing = 0, verbose = TRUE,
                              effects = c("fixed", "random", "all"),
                              component = c("conditional", "zi", "zero_inflated", "all"),
                              parameters = NULL){
  Mods <- list(...)
  effects <- match.arg(effects)
  component <- match.arg(component)

  # Get Bayes factors
  BFMods <- bayesfactor_models(..., denominator = 1, verbose = verbose)

  # Compute posterior model probabilities
  prior_odds <- c(1, prior_odds)
  posterior_odds <- prior_odds * BFMods$BF
  priorProbs <- prior_odds / sum(prior_odds)
  postProbs <- posterior_odds / sum(posterior_odds)

  # Compute weighted number of samples
  nsamples <- min(sapply(Mods, .total_samps))
  weighted_samps <- round(nsamples * postProbs)

  # extract parameters
  params <- lapply(Mods, insight::get_parameters,
                   effects = effects,
                   component = component,
                   parameters = parameters)

  .weighted_posteriors(params, weighted_samps, missing)
}

#' @export
#' @rdname weighted_posteriors
weighted_posteriors.brmsfit <- weighted_posteriors.stanreg

#' @export
#' @rdname weighted_posteriors
weighted_posteriors.BFBayesFactor <- function(..., prior_odds = NULL, missing = 0, verbose = TRUE){
  Mods <- c(...)

  # Get Bayes factors
  BFMods <- bayesfactor_models(Mods, verbose = verbose)

  # Compute posterior model probabilities
  prior_odds <- c(1, prior_odds)
  posterior_odds <- prior_odds * BFMods$BF
  priorProbs <- prior_odds / sum(prior_odds)
  postProbs <- posterior_odds / sum(posterior_odds)

  # Compute weighted number of samples
  nsamples <- 4000
  weighted_samps <- round(nsamples * postProbs)

  # extract parameters
  params <- lapply(seq_len(length(Mods@numerator)), function(mi){
    BayesFactor::posterior(Mods, iterations = nsamples, index = mi, progress = FALSE)
  })

  mod_0 <- try(BayesFactor::posterior(1/Mods[1], iterations = nsamples, progress = FALSE),
               silent = TRUE)
  if (inherits(mod_0, "try-error")) {
    if (!grepl("Sampling from intercept-only", mod_0)) stop(mod_0)
    warning("Cannot sample from BFBayesFactor model with intercept only (model prob = ",
            round(postProbs[1],2),
            "). Ommiting the intercept model.")
    postProbs <- postProbs[-1] / sum(postProbs[-1])
    weighted_samps <- round(nsamples * postProbs)
  } else {
    mod_0 <- list(params[[1]])
    params <- c(mod_0,params)
  }

  params <- lapply(params, as.data.frame)

  .weighted_posteriors(params, weighted_samps, missing)
}

.weighted_posteriors <- function(params, weighted_samps, missing) {
  par_names <- unique(unlist(sapply(params, colnames), recursive = TRUE))

  for (m in seq_along(weighted_samps)) {
    temp_params <- params[[m]]
    temp_params <- temp_params[sample(nrow(temp_params),size = weighted_samps[m]), ,drop = FALSE]

    # If any parameters not estimated in the model, they are assumed to be 0 (the default value of `missing`)
    temp_params[, setdiff(par_names, colnames(temp_params))] <- missing

    params[[m]] <- temp_params
  }

  # combine all
  do.call("rbind", params)
}

#' @keywords internal
#' @importFrom insight find_algorithm
.total_samps <- function(mod){
  x <- insight::find_algorithm(mod)
  x$chains * (x$iterations - x$warmup)
}
