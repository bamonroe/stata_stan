/*

Stata Stan
Version 20.0
rcstan 0.3.3
last modified: 08/26/2025
Author: Brian Albert Monroe
Email:  bmonroe3@gsu.edu

To run this software for the first time you must either:
(a) Have a working GCC compiler if running using Linux or MacOSX
(b) Have the Rtools software installed that matches the version of R you are using Windows

The program "update_R" will download the necessary R packages needed to run Stan, and install them in a local library named R_library in the current working directory.

This program only ever needs to be run once for a given platform. If a R_library directory exists because you were given this code as part of a reproducible package, you do not need to run "update_R"

The preferred way to run "update_R" is with an if statement in a main file:

if "$update" == "yes" {
	update_R
}


To have Stata Stan run a Stan model, the following globals need to be set, the values below are just examples:

global do_diagnostics "yes"      // "yes" to generate MCMC diagnostics
global use_inshell    "no"       // "yes" to download and use the "inshell" ado to run the code
global model   "rdu_prelec_bhm"  // the name of the stan file that is going to be passed to rstan, without the suffix
global chains  4                 // the number of MCMC chains to run in parallel
global warmup  5000              // the number of warmup iterations
global iter    15000             // the TOTAL number of iterations, INCLUSIVE of warmup

Optional globals, can be blank or omitted if you want to disregard them:
global covars      ""   // covariates for the hyper parameters, see a template with covariates
global extra_vars  ""   // extra variables from the Stata dataset that are passed into a extra_vars data block in stan
global stanopt_*        // arbitrary options can be passed to the stan command by filling in the suffix with the name of the option
                        // be warned that this only works well for values that don't need to be quoted

IF USING WINDOWS:
Make sure that the path to R_HOME in the gen_bat program below points to your R installation.
The default below epects a local portable version of R in the same directory as stanfit.do


CHANGELOG

Version 20.0: Update the required rcstan version
Version 19.1: Update the required rcstan version
Version 19.0: Automatically count the number of outcomes, assuming that there are the same number of outcomes in each option
Version 18.0: Added the ability to set stanopt_* globals which pass arbitrary options to the stan command in R
Version 17.0: Added set_R_cmd program to standardize the calls to R over all the other programs
Version 16.0: Added a program to stanfit.do to call the mcmc_diag function again from stata

*/

// This program generates the bat file for use with windows
capture program drop gen_bat
program define gen_bat
    tempname fp
    local bat_file "R_script.bat"
    file open `fp' using "`bat_file'", write replace

    local writer "file write `fp'"

    `writer' `"rem BASE_DIR is the absolute path of the file"' _n
    `writer' `"set "BASE_DIR=%~dp0""' _n
    `writer' `"rem remove trailing backslash (optional and aesthetic)"' _n
    `writer' `"set "BASE_DIR=%BASE_DIR:~0,-1%""' _n

    `writer' `"rem Set this to the location of the installation path of your R binary"' _n
    `writer' `"set "R_HOME=%BASE_DIR%\R-4.2.2-win-portable""' _n
    `writer' `"set "PATH=%R_HOME%\bin;%PATH%""' _n

    `writer' `"rem Run R (you can switch back to Rscript.exe if you want)"' _n
    `writer' `"start "Rscript for Stata-Stan" /W "%R_HOME%\bin\Rscript.exe" %*"' _n

    `writer' `"exit"' _n
    file close `fp'
end

// This sets the globals to run the tempfiles made for various commands
capture program drop set_R_cmd
program define set_R_cmd

	args fit_file

	if "$RPATH" != "" {
		local rcmd = "$RPATH"
	}
	else if c(os) == "MacOSX" {
		local rcmd = "/Library/Frameworks/R.framework/Resources/bin/R --vanilla -q"
	}
	else if c(os) == "Windows" {
		// Generate the batch file
		gen_bat
		local rcmd = "R_script.bat"
	}
	else {
		local rcmd = "R --vanilla -q"
	}

	if "$use_inshell" == "yes" {
		capture which inshell
		if _rc==111 ssc install inshell
		local scmd = "inshell"
	}
	else {
		if c(os) == "Windows" {
			local scmd = "shell start"
		}
		else {
			local scmd = "shell"
		}
	}

	// Escape all quotes carefully
	global Rshell "`scmd' `rcmd' -e"
	global Rcmd "fp <- file('R_runner.log', open = 'wt'); sink(fp); sink(fp, type = 'message'); source('`fit_file'', echo = TRUE); sink(type = 'message'); sink()"

end

// This program downloads the necessary libraries into a local R_library. It will also update an already existing R_library.
capture program drop update_R
program define update_R

	capture mkdir "R_library"

	// Shell out to R to download the necessary libraries to run
	// We generate a temporary file that contains the necessary R commands
	// The below 'capture rm' command can be removed to inspect that these commands are accurate
	tempname fp
	local fit_file "stanfit_updater.R"
	file open `fp' using "`fit_file'", write replace

	local writer "file write `fp'"

	// Set repos
	`writer' "repos <- getOption('repos')" _n
	// One for general CRAN packages
	`writer' "repos['CRAN']     = 'https://cloud.r-project.org/'" _n
	// Mcstan
	`writer' "repos['Stan']     = 'https://mc-stan.org/r-packages/'" _n
	// B.A. Monroe repo, for rcstan
	`writer' "repos['bam_repo'] = 'https://bamonroe.github.io/drat/'" _n
	// Set them
	`writer' "options(repos = repos)" _n
	`writer' "rm(repos)" _n
	// Create a local directory for the R packages
	`writer' "libdir <- 'R_library'" _n
	`writer' "if (!dir.exists(libdir)) dir.create(libdir, recursive = TRUE)" _n
	`writer' ".libPaths(libdir)" _n
	`writer' ".libPaths()" _n
	// Update the packages
	`writer' "update.packages(ask = FALSE, checkBuilt = TRUE, lib.loc = libdir)" _n
	// Reinstall rcstan package
	`writer' "install.packages(c('rcstan'), lib = libdir)" _n
	// There's a Sleep command here just so it stays open for a bit
	`writer' "Sys.sleep(15)" _n

	file close `fp'

	// Create the Rshell and Rcmd globals
	set_R_cmd `fit_file'
	// Now run the local file
	$Rshell "$Rcmd"

	capture rm "`fit_file'"

end

// This program rank orders lotteries for use with RDU code. This is
// potentially something that ought to be done in Stan in the generated data
// block
capture program drop rankinst
program define rankinst
qui {

	// I guess this is a factorial sort. It will always take (`nouts' - 1)!
	// steps. It's faster than quicksort for `nouts' < 5, and I didn't feel like
	// programming quicksort. In any case, this is a one time operation. The
	// compute time to rank is negligible compared to the time to estimate.

	local nouts = 0
	foreach vname of varlist opt1_out*  {
		local nouts = `nouts' + 1
	}

	// Create a couple marker variables to keep track of the currently best
	// outcome
	tempvar m1 p1 m2 p2
	generate double `m1' = 0
	generate double `p1' = 0

	generate double `m2' = 0
	generate double `p2' = 0

	// Still only allowing 2 options
	forvalues opt = 1/2 {
		local bottom 2
		while `bottom' <= `nouts' {
			forvalues i = `nouts'(-1)`bottom' {

				local j = `i' - 1

				replace `m1' = opt`opt'_out`i'
				replace `m2' = opt`opt'_out`j'
				replace `p1' = opt`opt'_prob`i'
				replace `p2' = opt`opt'_prob`j'

				replace `m1' = opt`opt'_out`j'  if opt`opt'_out`j' > opt`opt'_out`i'
				replace `m2' = opt`opt'_out`i'  if opt`opt'_out`j' > opt`opt'_out`i'
				replace `p1' = opt`opt'_prob`j' if opt`opt'_out`j' > opt`opt'_out`i'
				replace `p2' = opt`opt'_prob`i' if opt`opt'_out`j' > opt`opt'_out`i'

				replace opt`opt'_out`i'  = `m2'
				replace opt`opt'_out`j'  = `m1'
				replace opt`opt'_prob`i' = `p2'
				replace opt`opt'_prob`j' = `p1'
			}
			local ++bottom
		}
	}

	// Ensure we don't have 0 outcomes or negative probabilities
	forvalues i = 1/`nouts' {
		replace opt1_out`i'  = 0.01 if opt1_out`i' == 0
		replace opt2_out`i'  = 0.01 if opt2_out`i' == 0

		replace opt1_prob`i' = 0 if opt1_prob`i' <= 0
		replace opt2_prob`i' = 0 if opt2_prob`i' <= 0
	}

	replace Max  = 0.01 if Max == 0
	replace Min  = 0.01 if Min == 0
	}
end


// Be very very careful what you put into your globals. These values are sent
// directly to the shell and can cause damage if you deviate from the
// prescribed templates
capture program drop stanfit
program define stanfit

	// Rank-order the data
	rankinst

	// The file name for the model
	local fname "'$model.stan'"

	// Temporary files for current data and posterior
	local input "__bam_dat"
	local post  "__bam_post"

	// Save an appropriate dataset
	save `input', replace

	local diag "FALSE"
	if "$do_diagnostics" == "yes" | "$do_diagnostics" == "TRUE" {
		local diag "TRUE"
	}

	// If there are no covars specified, then make it empty
	// Otherwise, surround in single quotes
	if "$covars" == "" {
		local covars ""
	}
	else {
		local covars "'$covars'"
	}

	// If there's no extra vars specified, then make it NULL
	// Otherwise, surround in single quotes
	if "$extra_vars" == "" {
		local extra_vars "NULL"
	}
	else {
		local extra_vars "'$extra_vars'"
	}

	// Set Stan options that we want defaults for, and for which we do require the
	// stanopt_ prefix
	local chains_default = 2
	local iter_default = 10000
	local warmup_default = `iter_default' / 2

	foreach stanopt in chains warmup iter {
		if "${`stanopt'}" != "" {
			global stanopt_`stanopt' "${`stanopt'}"
		}
		else if "``stanopt'_default'" != "" {
			global stanopt_`stanopt' "``stanopt'_default'"
		}
	}

	// Generate the stan_opts local by finding all globals with the stanopt_* prefix
	local stan_opts "list("
	local names : all globals "stanopt*"
	foreach line in `names' {
		local opt = substr("`line'", 9, .)
		local stan_opts "`stan_opts'`opt' = ${stanopt_`opt'}, "
	}
	local stan_opts = substr("`stan_opts'", 1, strlen("`stan_opts'") - 2)
	local stan_opts "`stan_opts')"

	// Shell out to R to do the posterior fitting
	tempname fp
	local fit_file "stanfit_run_r_file.R"
	file open `fp' using "`fit_file'", write replace

	local writer "file write `fp'"

	`writer' ".libPaths('./R_library')" _n
	`writer' "library(rcstan)" _n
	`writer' "fit_to_dta('`input'.dta', '`post'.dta'," _n
	`writer' "  stan_file  = `fname'," _n
	`writer' "  covars     = `covars'," _n
	`writer' "  diag       = `diag'," _n
	`writer' "  extra_vars = `extra_vars'," _n
	`writer' "  stan_opts  = `stan_opts'" _n
	`writer' ")" _n

	file close `fp'

	// Create the Rshell and Rcmd globals
	set_R_cmd `fit_file'
	// Now run the local file
	$Rshell "$Rcmd"

	capture rm "`fit_file'"

	// Load the posterior and save to match the model
	use `post', clear

	// Delete the temporary data files
	//capture rm `input'.dta
	//capture rm `post'.dta

end

capture program drop stan_diagnostics
program define stan_diagnostics
	// The file name for the model
	local fname "'$model.Rda'"

	// Shell out to R to do the posterior fitting
	tempname fp
	local fit_file "stanfit_run_diagnostics.R"
	file open `fp' using "`fit_file'", write replace

	local writer "file write `fp'"

	`writer' ".libPaths('./R_library')" _n
	`writer' "library(rcstan)" _n
	`writer' "load(`fname')" _n
	`writer' "rcstan::mcmc_diag(rcfit)" _n

	file close `fp'

	// Create the Rshell and Rcmd globals
	set_R_cmd `fit_file'
	// Now run the local file
	$Rshell "$Rcmd"

	capture rm "`fit_file'"
end
