#
# SessionDataViewer.R
#
# Copyright (C) 2022 by Posit Software, PBC
#
# Unless you have received this program directly from Posit Software pursuant
# to the terms of a commercial license agreement with Posit Software, then
# this program is licensed to you under the terms of version 3 of the
# GNU Affero General Public License. This program is distributed WITHOUT
# ANY EXPRESS OR IMPLIED WARRANTY, INCLUDING THOSE OF NON-INFRINGEMENT,
# MERCHANTABILITY OR FITNESS FOR A PARTICULAR PURPOSE. Please refer to the
# AGPL (http://www.gnu.org/licenses/agpl-3.0.txt) for more details.
#
#

# host environment for cached data; this allows us to continue to view data 
# even if the original object is deleted
.rs.setVar("CachedDataEnv", new.env(parent = emptyenv()))

# host environment for working data; this allows us to sort/filter/page the
# data without recomputing on the original object every time
.rs.setVar("WorkingDataEnv", new.env(parent = emptyenv()))

.rs.addFunction("subsetData", function(data, maxRows = -1, maxCols = -1)
{
   if (!is.na(maxRows) && maxRows != -1 && nrow(data) > maxRows)
      data <- head(data, n = maxRows)
   
   if (!is.na(maxCols) && maxCols != -1 && ncol(data) > maxCols)
      data <- data[1:maxCols]
   
   data
})

.rs.addFunction("formatDataColumn", function(x, start, len, ...)
{
   # extract the visible part of the column
   col <- x[start:min(NROW(x), start + len)]
   
   # if this object has a format method, use it. catch errors
   # and validate that the format method has given us something 'sane'
   formatted <- .rs.tryCatch(.rs.formatDataColumnDispatch(col, ...))
   if (is.character(formatted) && length(formatted) == length(col))
      return(formatted)
   
   # otherwise, delegate to internal methods
   if (is.numeric(col))
      .rs.formatDataColumnNumeric(col, ...)
   else if (is.list(col) && !is.data.frame(col))
      .rs.formatDataColumnList(col, ...)
   else
      .rs.formatDataColumnDefault(col, ...)
})

.rs.addFunction("formatDataColumnDispatch", function(col, ...)
{
   formatter <- NULL
   for (class in class(col))
   {
      formatter <- utils::getS3method(
         "format",
         class = class,
         optional = TRUE
      )
      if (!is.null(formatter))
         break
   }
   
   if (is.null(formatter))
      return(NULL)
   
   formatted <- formatter(col, trim = TRUE, justify = "none", ...)
   
   if (is.character(formatted) && length(formatted) == length(col))
      formatted[is.na(col)] <- NA
   
   formatted
   
})

.rs.addFunction("formatDataColumnNumeric", function(col, ...)
{
   # show numbers as doubles
   storage.mode(col) <- "double"
   
   # remember which values are NA 
   naVals <- is.na(col) 
   
   # format all the numeric values; this drops NAs (the na.encode option only
   # preserves NA for character cols)
   vals <- format(col, trim = TRUE, justify = "none", ...)
   
   # restore NA values if there were any
   if (any(naVals))
      vals[naVals] <- col[naVals]
   
   # return formatted values
   vals
})

.rs.addFunction("formatDataColumnList", function(col, ...)
{
   limit <- .rs.nullCoalesce(
      .rs.readUserPref("data_viewer_max_cell_size"),
      50L
   )
   
   # handle data.frame entries in a column
   # https://github.com/rstudio/rstudio/issues/14257
   for (i in seq_along(col))
   {
      if (is.data.frame(col[[i]]))
      {
         col[[i]] <- sprintf("<data.frame[%i x %i]>", nrow(col[[i]]), ncol(col[[i]]))
      }
      else
      {
         col[[i]] <- format(col[[i]])
      }
   }
   
   formatted <- as.character(col)
   na <- is.na(formatted)
   large <- !na & nchar(formatted) > limit
   formatted <- substr(formatted, 1, limit)
   formatted <- paste0(formatted, ifelse(large, " [...]", ""))
   formatted[na] <- NA_character_
   formatted
})

.rs.addFunction("formatDataColumnDefault", function(col, ...)
{
   # show everything else as characters
   as.character(col)
})

.rs.addFunction("describeCols", function(x,
                                         maxRows = -1,
                                         maxCols = -1,
                                         maxFactors = 64,
                                         totalCols = -1)
{
   # subset the data if requested
   x <- .rs.subsetData(x, maxRows, maxCols)
   
   # get the variable labels, if any--labels may be provided either by this 
   # global attribute or by a 'label' attribute on an individual column (as in
   # e.g. Hmisc), which takes precedence if both are present
   colNames <- names(x)
   colLabels <- attr(x, "variable.labels", exact = TRUE)
   if (!is.character(colLabels)) 
      colLabels <- character()
   
   # we pass totalCols in the rownames col so we can pass this information
   # along when we retrieve column data, without changing the response format
   totalCols <- if (totalCols > 0) totalCols else ncol(x)
   
   # the first column is always the row names
   rowNameCol <- list(
      col_name        = .rs.scalar(""),
      col_type        = .rs.scalar("rownames"),
      col_min         = .rs.scalar(0),
      col_max         = .rs.scalar(0),
      col_search_type = .rs.scalar("none"),
      col_label       = .rs.scalar(""),
      col_vals        = "",
      col_type_r      = .rs.scalar(""),
      total_cols      = .rs.scalar(totalCols))
   
   # if there are no columns, bail out
   if (length(colNames) == 0) {
      return(rowNameCol)
   }
   
   # get the attributes for each column
   colAttrs <- lapply(seq_along(colNames), function(idx) {
      col_name <- if (idx <= length(colNames)) 
         colNames[idx] 
      else 
         as.character(idx)
      col_type <- "unknown"
      col_type_r <- "unknown"
      col_breaks <- c()
      col_counts <- c()
      col_vals <- ""
      col_search_type <- ""
      
      # extract label, if any, or use global label, if any
      label <- attr(x[[idx]], "label", exact = TRUE)
      col_label <- if (is.character(label))
      {
         label
      }
      else if (idx <= length(colLabels))
      {
         if (!is.null(names(colLabels)))
         {
            if (col_name %in% names(colLabels))
               colLabels[[col_name]]
            else
               ""
         }
         else
         {
            colLabels[[idx]]
         }
      }
      else
      {
         ""
      }
      
      # ensure that the column contains some scalar values we can examine 
      if (length(x[[idx]]) > 0)
      {
         val <- x[[idx]][[1]]
         col_type_r <- typeof(val)
         if (is.factor(val))
         {
            # we previously used the 'maxFactors' variable to try and guess
            # where a factor variable might have actually been intended to be
            # used as a character vector. nowdays, with stringsAsFactors = FALSE
            # being the default, this is no longer necessary and so we just
            # ignore the 'maxFactors' parameter.
            #
            # https://github.com/rstudio/rstudio/issues/14113
            col_type <- "factor"
            col_search_type <- "factor"
            col_vals <- levels(val)
         }
         # for histograms, we support only the base R numeric class and its derivatives;
         # is.numeric can return true for values that can only be manipulated using
         # packages that are currently loaded (e.g. bit64's integer64)
         else if (is.numeric(x[[idx]]) && !is.object(x[[idx]]))
         {
            # ignore missing and infinite values (i.e. let any filter applied
            # implicitly remove those values); if that leaves us with nothing,
            # treat this column as untyped since we can do no meaningful filtering
            # on it
            hist_vals <- x[[idx]][is.finite(x[[idx]])]
            if (length(hist_vals) > 1)
            {
               # create histogram for brushing -- suppress warnings as in rare cases
               # an otherwise benign integer overflow can occurs; see
               # https://github.com/rstudio/rstudio/issues/3232
               h <- suppressWarnings(graphics::hist(hist_vals, plot = FALSE))
               col_breaks <- h$breaks
               col_counts <- h$counts
               
               # record column type
               col_type <- "numeric"
               col_search_type <- "numeric"
            }
         }
         else if (inherits(x[[idx]], "integer64"))
         {
            col_type <- "numeric"
            col_search_type <- "character"
         }
         else if (is.character(val))
         {
            col_type <- "character"
            col_search_type <- "character"
         }
         else if (is.logical(val))
         {
            col_type <- "boolean"
            col_search_type <- "boolean"
         }
         else if (is.data.frame(val))
         {
            col_type <- "data.frame"
         }
         else if (is.list(val))
         {
            col_type <- "list"
         }
      }
      list(
         col_name        = .rs.scalar(col_name),
         col_type        = .rs.scalar(col_type),
         col_breaks      = as.character(col_breaks),
         col_counts      = col_counts,
         col_search_type = .rs.scalar(col_search_type),
         col_label       = .rs.scalar(col_label),
         col_vals        = col_vals,
         col_type_r      = .rs.scalar(col_type_r)
      )
   })
   c(list(rowNameCol), colAttrs)
})

.rs.addFunction("describeColSlice", function(x,
                                             sliceStart = 1,
                                             sliceEnd = 1)
{
   totalCols <- ncol(x)
   if (is.null(totalCols) || totalCols == 0)
      return(NULL)
   
   if (sliceEnd > totalCols || sliceEnd < 1)
      sliceEnd <- totalCols
   
   if (sliceStart > totalCols || sliceStart < 1 || sliceStart > sliceEnd)
      sliceStart <- 1
   
   indices <- sliceStart:sliceEnd
   colSlice <- x[indices]
   
   # Make sure we preserve variable.labels if set.
   #
   # The structure of 'variable.labels' is not documented,
   # but it appears that the expectation is that it's a character
   # vector of the same length as 'x'.
   #
   # The vector can be optionally named (with names matching that of 'x'),
   # or it can be an unnamed vector -- in which case, the order of labels
   # needs to match the column order of 'x'.
   #
   # https://github.com/rstudio/rstudio/issues/14265
   colLabels <- attr(x, "variable.labels", exact = TRUE)
   if (!is.null(colLabels))
   {
      # Only subset 'variable.labels' if it's not named, since a named
      # attribute could potentially be in a different order than the
      # columns of 'x' itself. If 'variable.labels' is named, then all
      # we require is that it's a super-set of the names of 'x'.
      if (is.null(names(colLabels)))
         colLabels <- colLabels[indices]
      
      attr(colSlice, "variable.labels") <- colLabels
   }
      
   
   .rs.describeCols(colSlice, -1, -1, 64, totalCols)
})

.rs.addFunction("formatRowNames", function(x, start, len) 
{
   # check for a data.frame with compact row names
   if (.rs.hasCompactRowNames(x))
   {
      # the second element indicates the number of rows, and
      # is negative if they're so-called "automatic" row names
      info <- .row_names_info(x, type = 0L)
      n <- abs(info[[2L]])
      range <- seq(from = start, to = min(n, start + len))
      return(as.character(range))
   }
   
   # retrieve row names; use .row_names_info for data.frame so
   # we can detect internal non-character row names
   rowNames <- if (is.data.frame(x))
   {
      .row_names_info(x, type = 0L)
   }
   else
   {
      row.names(x)
   }
   
   # subset the retrieved row names
   rowNames <- rowNames[start:min(length(rowNames), start + len)]
   
   # encode strings as JSON to force quoting + handle escaping
   # this also lets us differentiate numeric (automatic) row names
   # from explicitly-set row names
   if (is.character(rowNames))
   {
      .rs.mapChr(rowNames, .rs.toJSON, unbox = TRUE)
   }
   else
   {
      as.character(rowNames)
   }
})

# wrappers for nrow/ncol which will report the class of object for which we
# fail to get dimensions along with the original error
.rs.addFunction("nrow", function(x)
{
   rows <- 0
   tryCatch({
      rows <- NROW(x)
   }, error = function(e) {
      stop("Failed to determine rows for object of class '", class(x), "': ", 
           e$message)
   })
   if (is.null(rows))
      0
   else
      rows
})

.rs.addFunction("ncol", function(x)
{
   cols <- 0
   tryCatch({
      cols <- NCOL(x)
   }, error = function(e) {
      stop("Failed to determine columns for object of class '", class(x), "': ", 
           e$message)
   })
   if (is.null(cols))
      0
   else
      cols
})

.rs.addFunction("toDataFrame", function(x, name, flatten)
{
   # force a non-subclassed data.frame -- this is necessary to ensure
   # that row names (or row numbers) are not dropped when subsetting
   # data, since those row names are used when generating cell-specific
   # callbacks (e.g. for viewing a cell of a list column)
   if (is.data.frame(x))
   {
      class(x) <- "data.frame"
   }
   
   # if it's not already a frame, coerce it to a frame
   if (!is.data.frame(x))
   {
      frame <- NULL
      # attempt to coerce to a data frame--this can throw errors in the case
      # where we're watching a named object in an environment and the user
      # replaces an object that can be coerced to a data frame with one that
      # cannot
      tryCatch(
         {
            # create a temporary frame to hold the value; this is necessary because
            # "x" is a function argument and therefore a promise whose value won't
            # be bound via substitute() below. we use a random-looking name so we 
            # can spot it later when relabeling columns.
            `__RSTUDIO_VIEWER_COLUMN__` <- x
            
            # perform the actual coercion in the global environment; this is 
            # necessary because we want to honor as.data.frame overrides of packages
            # which are loaded after tools:rstudio in the search path
            frame <- eval(substitute(as.data.frame(`__RSTUDIO_VIEWER_COLUMN__`, 
                                                   optional = TRUE)), 
                          envir = globalenv())
         },
         error = function(e)
         {
         })
      
      # as.data.frame uses the name of its argument to label unlabeled columns,
      # so label these back to the original name
      if (!is.null(frame) && !is.null(names(frame)))
         names(frame)[names(frame) == "__RSTUDIO_VIEWER_COLUMN__"] <- name
      x <- frame 
   }
   
   # if coercion was successful (or we started with a frame), flatten the frame
   # if necessary and requested
   if (is.data.frame(x)) {
      
      # generate column names if we didn't have any to start
      if (is.null(names(x)))
         names(x) <- paste("V", seq_along(x), sep = "")
      
      if (flatten)
         x <- .rs.flattenFrame(x)
      
      return(x)
   }
})

.rs.addFunction("multiCols", function(x) {
   fun <- function(col) is.data.frame(col) || is.matrix(col)
   which(vapply(x, fun, TRUE))
})

# given a 'data.frame' containing columns which themselves have
# multiple columns (e.g. matrices, data.frames), expand those columns
# such that we have a 'data.frame' with the nested columns e
.rs.addFunction("flattenFrame", function(x)
{
   # skip if we don't have any rectangular columns;
   # in this case, we can return the data as-is
   isRectangular <- vapply(x, function(column) {
      is.data.frame(column) || is.matrix(column)
   }, FUN.VALUE = logical(1))
   
   if (!any(isRectangular))
      return(x)
   
   # split into separate data.frames
   stack <- .rs.stack()
   .rs.enumerate(x, .rs.dataViewer.flatten, stack = stack)
   parts <- stack$data()
   
   # pull out pieces we need
   keys <- vapply(parts, `[[`, "name", FUN.VALUE = "character")
   vals <- lapply(parts, `[[`, "value")
   
   # turn it into a data.frame
   names(vals) <- keys
   attr(vals, "row.names") <- .set_row_names(length(vals[[1L]]))
   class(vals) <- "data.frame"
   
   # all done
   vals
})

.rs.addFunction("dataViewer.flatten", function(name, value, stack)
{
   if (is.matrix(value)) {
      .rs.dataViewer.flattenMatrix(name, value, stack)
   } else if (is.data.frame(value)) {
      .rs.dataViewer.flattenDataFrame(name, value, stack)
   } else {
      stack$push(list(name = name, value = value))
   }
})

.rs.addFunction("dataViewer.flattenMatrix", function(name, value, stack)
{
   colNames <- if (is.null(colnames(value)))
      as.character(seq_len(ncol(value)))
   else
      encodeString(colnames(value), quote = '"')
   
   for (i in seq_len(ncol(value))) {
      .rs.dataViewer.flatten(
         name  = sprintf("%s[, %s]", name, colNames[[i]]),
         value = value[, i, drop = TRUE],
         stack = stack
      )
   }
})

.rs.addFunction("dataViewer.flattenDataFrame", function(name, value, stack)
{
   # a data.frame should almost always have names, but check just in case
   colNames <- names(value)
   if (is.null(colNames))
      colNames <- sprintf("<%i>", seq_along(value))
   
   for (i in seq_along(value)) {
      .rs.dataViewer.flatten(
         name  = paste(name, colNames[[i]], sep = "$"),
         value = value[[i]],
         stack = stack
      )
   }
})

.rs.addFunction("applyTransform", function(x, filtered, search, cols, dirs)
{
   # mark encoding on character inputs if not already marked
   filtered <- vapply(filtered, function(colfilter) {
      if (Encoding(colfilter) == "unknown") 
         Encoding(colfilter) <- "UTF-8"
      colfilter
   }, "")
   
   if (Encoding(search) == "unknown")
      Encoding(search) <- "UTF-8"
   
   # coerce argument to data frame--data.table objects (for example) report that
   # they're data frames, but don't actually support the subsetting operations
   # needed for search/sort/filter without an explicit cast
   #
   # similarly, we need to convert tibbles to regular data.frames so that we can
   # properly invoke the list / data viewer on filtered rows
   x <- .rs.toDataFrame(x, "transformed", TRUE)
   
   # apply columnwise filters
   for (i in seq_along(filtered))
   {
      if (nchar(filtered[i]) > 0 && length(x[[i]]) > 0)
      {
         # split filter--string format is "type|value" (e.g. "numeric|12-25") 
         filter <- strsplit(filtered[i], split = "|", fixed = TRUE)[[1]]
         if (length(filter) < 2) 
         {
            # no filter type information
            next
         }
         filtertype <- filter[1]
         filterval <- filter[2]
         
         # apply filter appropriate to type
         if (identical(filtertype, "factor")) 
         {
            # apply factor filter: convert to numeric values and discard missing
            filterval <- as.numeric(filterval)
            matches <- as.numeric(x[[i]]) == filterval
            matches[is.na(matches)] <- FALSE
            x <- x[matches, , drop = FALSE]
         }
         else if (identical(filtertype, "character"))
         {
            # apply character filter: non-case-sensitive prefix
            # use PCRE and the special \Q and \E escapes to ensure no characters in
            # the search expression are interpreted as regexes 
            x <- x[grepl(paste("\\Q", filterval, "\\E", sep = ""), x[[i]], 
                         perl = TRUE, ignore.case = TRUE), , 
                   drop = FALSE]
         } 
         else if (identical(filtertype, "numeric"))
         {
            # apply numeric filter, range ("2-32") or equality ("15")
            filterval <- as.numeric(strsplit(filterval, "_")[[1]])
            if (length(filterval) > 1)
               # range filter
               x <- x[is.finite(x[[i]]) & x[[i]] >= filterval[1] & x[[i]] <= filterval[2], , drop = FALSE]
            else
               # equality filter
               x <- x[is.finite(x[[i]]) & x[[i]] == filterval, , drop = FALSE]
         }
         else if (identical(filtertype, "boolean")) 
         {
            filterval <- isTRUE(filterval == "TRUE")
            matches <- x[[i]] == filterval
            matches[is.na(matches)] <- FALSE
            x <- x[matches, , drop = FALSE]
         }
      }
   }
   
   # apply global search
   if (!is.null(search) && nchar(search) > 0)
   {
      # get columns for search
      searchColumns <- unclass(x)
      
      # also apply on row names if available
      if (is.data.frame(x))
      {
         info <- .row_names_info(x, type = 0L)
         if (is.character(info))
         {
            searchColumns[[length(searchColumns) + 1]] <- info
         }
      }
      
      # apply global search on data columns
      pattern <- paste0("\\Q", search, "\\E")
      matches <- lapply(searchColumns, function(column) {
         grepl(pattern, column, perl = TRUE, ignore.case = TRUE)
      })
      
      # collapse into single vector
      matches <- Reduce(`|`, matches)
      
      # update based on matches
      x <- x[matches, , drop = FALSE]
      
   }
   
   # apply sort
   if (length(cols) > 0)
   {
      vals <- list()
      for (i in length(cols))
      {
         idx <- cols[[i]]
         if (length(x[[idx]]) > 0)
         {
            if (identical(dirs[[i]], "asc"))
            {
               vals <- append(vals, list(x[[idx]]))
            }
            else
            {
               vals <- append(vals, list(-xtfrm(x[[idx]])))
            }
         }
      }
      
      if (length(vals) > 0)
      {
         x <- x[do.call(order, vals), , drop = FALSE]
      }
   }
   
   return(x)
})

# returns envName as an environment, or NULL if the conversion failed
.rs.addFunction("safeAsEnvironment", function(envName)
{
   env <- NULL
   tryCatch(
      {
         env <- as.environment(envName)
      }, 
      error = function(e) { })
   env
})

.rs.addFunction("findDataFrame", function(envName, objName, cacheKey, cacheDir) 
{
   env <- NULL
   
   # mark encoding on cache directory 
   if (Encoding(cacheDir) == "unknown")
      Encoding(cacheDir) <- "UTF-8"
   
   # do we have an object name? if so, check in a named environment
   if (!is.null(objName) && nchar(objName) > 0) 
   {
      if (is.null(envName) || identical(envName, "R_GlobalEnv") || 
          nchar(envName) == 0)
      {
         # global environment
         env <- globalenv()
      }
      else 
      {
         env <- .rs.safeAsEnvironment(envName)
         if (is.null(env))
            env <- emptyenv()
      }
      
      # if the object exists in this environment, return it (avoid creating a
      # temporary here)
      if (exists(objName, where = env, inherits = FALSE))
      {
         # attempt to coerce the object to a data frame--note that a null return
         # value here may indicate that the object exists in the environment but
         # is no longer a data frame (we want to fall back on the cache in this
         # case)
         dataFrame <- .rs.toDataFrame(get(objName, envir = env, inherits = FALSE), 
                                      objName, TRUE)
         if (!is.null(dataFrame)) 
            return(dataFrame)
      }
   }
   
   if (.rs.isNonEmptyScalarString(cacheKey))
   {
      # if the object exists in the cache environment, return it. objects
      # in the cache environment have already been coerced to data frames.
      if (exists(cacheKey, where = .rs.CachedDataEnv, inherits = FALSE))
         return(get(cacheKey, envir = .rs.CachedDataEnv, inherits = FALSE))
      
      # perhaps the object has been saved? attempt to load it into the
      # cached environment
      cacheFile <- file.path(cacheDir, paste(cacheKey, "Rdata", sep = "."))
      if (file.exists(cacheFile))
      {
         status <- try(load(cacheFile, envir = .rs.CachedDataEnv), silent = TRUE)
         if (inherits(status, "try-error"))
            return(NULL)
         
         if (exists(cacheKey, where = .rs.CachedDataEnv, inherits = FALSE))
            return(get(cacheKey, envir = .rs.CachedDataEnv, inherits = FALSE))
      }
   }
   
   # failure
   return(NULL)
})

# given a name, return the first environment on the search list that contains
# an object bearing that name. 
.rs.addFunction("findViewingEnv", function(name)
{
   # default to searching from the global environment
   env <- globalenv()
   
   # attempt to find a call frame from which View was invoked; this will allow
   # us to locate viewing environments further in the call stack
   # (e.g. in the debugger)
   for (i in seq_along(sys.calls()))
   {
      if (identical(deparse(sys.call(i)[[1]]), "View"))
      {
         env <- sys.frame(i - 1)
         break
      }
   }
   
   # NOTE: we previously looked through the parent environments of
   # the associated frame to find the actual environment hosting the
   # object being viewed, but this caused problems when attempting
   # to track object mutations. for example, the 'mtcars' dataset is
   # defined in 'package:datasets', but attempting to modify that
   # object would actually create that modified object in the R global
   # environment. for that reason, it's best to track objects from the
   # top-level environment where they were found, as that's where
   # "modified" versions of that object will be generated
   env
})

# attempts to determine whether the View(...) function the user has an 
# override (i.e. it's not the handler RStudio uses)
.rs.addFunction("isViewOverride", function()
{
   # check to see if View has been overridden: find the View() call in the 
   # stack and examine the function being evaluated there
   for (i in seq_along(sys.calls()))
   {
      if (identical(deparse(sys.call(i)[[1]]), "View"))
      {
         # the first statement in the override function should be a call to 
         # .rs.callAs
         return(!identical(deparse(body(sys.function(i))[[1]]), ".rs.callAs"))
      }
   }
   
   # if we can't find View on the callstack, presume the common case (no
   # override)
   FALSE
})

.rs.addFunction("viewHook", function(original, x, title) {
   
   # remember the expression from which the data was generated
   expr <- deparse(substitute(x), backtick = TRUE)
   
   # generate title if necessary (from deparsed expr)
   if (missing(title))
      title <- paste(expr[1])
   
   # collapse expr for serialization
   expr <- paste(expr, collapse = " ")
   
   name <- ""
   env <- emptyenv()
   
   if (.rs.isViewOverride()) 
   {
      # if the View() invoked wasn't our own, we have no way of knowing what's
      # been done to the data since the user invoked View() on it, so just view
      # a snapshot of the data
      name <- title
   }
   else if (is.name(substitute(x)))
   {
      # if the argument is the name of a variable, we can monitor it in its
      # environment, and don't need to make a copy for viewing
      name <- paste(deparse(substitute(x)))
      env <- .rs.findViewingEnv(name)
   }
   
   # is this a function? if it is, view as a function instead
   if (is.function(x)) 
   {
      # check the source refs to see if we can open the file itself instead of
      # opening a read-only source viewer
      srcref <- .rs.getSrcref(x)
      if (!is.null(srcref))
      {
         srcfile <- attr(srcref, "srcfile", exact = TRUE)
         filename <- .rs.nullCoalesce(srcfile$filename, "")
         if (!identical(filename, "~/.active-rstudio-document") &&
             file.exists(filename))
         {
            # the srcref points to a valid file--go there 
            .Call("rs_jumpToFunction",
                  normalizePath(filename, winslash = "/"),
                  srcref[[1]],
                  srcref[[5]],
                  TRUE,
                  PACKAGE = "(embedding)")
            
            return(invisible(NULL))
         }
      }
      
      # either this function doesn't have a source reference or its source
      # reference points to a file we can't locate on disk--show a deparsed
      # version of the function
      
      # remove package qualifiers from function name
      title <- sub("^[^:]+:::?", "", title)
      
      # infer environment location
      namespace <- .rs.environmentName(environment(x))
      if (identical(namespace, "R_EmptyEnv") || identical(namespace, ""))
         namespace <- "viewing"
      else if (identical(namespace, "R_GlobalEnv"))
         namespace <- ".GlobalEnv"
      invisible(.Call("rs_viewFunction", x, title, namespace, PACKAGE = "(embedding)"))
      return(invisible(NULL))
   }
   else if (inherits(x, "vignette"))
   {
      file.edit(file.path(x$Dir, "doc", x$File))
      return(invisible(NULL))
   }
   
   # delegate to object explorer if this is an 'explorable' object
   if (.rs.dataViewer.shouldUseObjectExplorer(x))
   {
      view <- .rs.explorer.viewObject(x, title = title, envir = env)
      return(invisible(view))
   }
   
   # convert Pandas DataFrames to R data.frames
   if (inherits(x, "pandas.core.frame.DataFrame"))
      x <- reticulate::py_to_r(x)
   
   # test for coercion to data frame--the goal of this expression is just to
   # raise an error early if the object can't be made into a frame; don't
   # require that we can generate row/col names
   coerced <- x
   eval(
      expr = substitute(as.data.frame(coerced, optional = TRUE)),
      envir = globalenv()
   )
   
   # save a copy into the cached environment
   cacheKey <- .rs.addCachedData(force(x), name)
   
   if (!.rs.isNonEmptyScalarString(cacheKey))
      return(invisible(NULL))
   
   # call viewData 
   invisible(.Call("rs_viewData", x, expr, title, name, env, cacheKey, FALSE))
})

.rs.registerReplaceHook("View", "utils", .rs.viewHook)

.rs.addFunction("dataViewer.shouldUseObjectExplorer", function(object)
{
   if (inherits(object, c("function", "vignette")))
      return(FALSE)
   
   # prefer data viewer for pandas DataFrames
   if (inherits(object, "pandas.core.frame.DataFrame"))
      return(FALSE)
   
   # don't explore regular data.frames
   isTabular <-
      is.data.frame(object) ||
      is.matrix(object) ||
      is.table(object)
   
   if (isTabular)
      return(FALSE)
   
   # other objects are worth using object explorer for
   TRUE
})

.rs.addFunction("viewDataFrame", function(x, title, preview) {
   cacheKey <- .rs.addCachedData(force(x), "")
   if (.rs.isNonEmptyScalarString(cacheKey))
      invisible(.Call("rs_viewData", x, "", title, "", emptyenv(), cacheKey, preview))
})

.rs.addFunction("initializeDataViewer", function(server) {
   if (server) {
      .rs.registerReplaceHook("edit", "utils", function(original, name, ...) {
         if (is.data.frame(name) || is.matrix(name))
            stop("Editing of data frames and matrixes is not supported in RStudio.", call. = FALSE)
         else
            original(name, ...)
      })
   }
})

.rs.addFunction("addCachedData", function(obj, objName) 
{
   cacheKey <- .Call("rs_generateShortUuid")
   .rs.assignCachedData(cacheKey, obj, objName)
   cacheKey
})

.rs.addFunction("assignCachedData", function(cacheKey, obj, objName) 
{
   # coerce to data frame before assigning, and don't assign if we can't coerce
   frame <- .rs.toDataFrame(obj, objName, TRUE)
   if (!is.null(frame) &&
       .rs.isNonEmptyScalarString(cacheKey))
      assign(cacheKey, frame, .rs.CachedDataEnv)
})

.rs.addFunction("removeCachedData", function(cacheKey, cacheDir)
{
   # mark encoding on cache directory 
   if (Encoding(cacheDir) == "unknown")
      Encoding(cacheDir) <- "UTF-8"
   
   if (.rs.isNonEmptyScalarString(cacheKey))
   {
      # remove data from the cache environment
      if (exists(".rs.CachedDataEnv") &&
          exists(cacheKey, where = .rs.CachedDataEnv, inherits = FALSE))
         rm(list = cacheKey, envir = .rs.CachedDataEnv, inherits = FALSE)
      
      # remove data from the cache directory
      cacheFile <- file.path(cacheDir, paste(cacheKey, "Rdata", sep = "."))
      if (file.exists(cacheFile))
         file.remove(cacheFile)
      
      # remove any working data
      .rs.removeWorkingData(cacheKey)
   }
   invisible(NULL)
})

.rs.addFunction("saveCachedData", function(cacheDir)
{
   # mark encoding on cache directory 
   if (Encoding(cacheDir) == "unknown")
      Encoding(cacheDir) <- "UTF-8"
   
   # no work to do if we have no cache
   if (!exists(".rs.CachedDataEnv")) 
      return(invisible(NULL))
   
   # save each active cache file from the cache environment
   lapply(ls(.rs.CachedDataEnv), function(cacheKey) {
      if (.rs.isNonEmptyScalarString(cacheKey))
         save(list = cacheKey, 
              file = file.path(cacheDir, paste(cacheKey, "Rdata", sep = ".")),
              envir = .rs.CachedDataEnv)
   })
   
   # clean the cache environment
   # can generate warnings if .rs.CachedDataEnv disappears (we call this on
   # shutdown); suppress these
   suppressWarnings(rm(list = ls(.rs.CachedDataEnv), where = .rs.CachedDataEnv))
   
   invisible(NULL)
})

.rs.addFunction("findWorkingData", function(cacheKey)
{
   if (.rs.isNonEmptyScalarString(cacheKey) &&
       exists(".rs.WorkingDataEnv") &&
       exists(cacheKey, where = .rs.WorkingDataEnv, inherits = FALSE))
      get(cacheKey, envir = .rs.WorkingDataEnv, inherits = FALSE)
   else
      NULL
})

.rs.addFunction("removeWorkingData", function(cacheKey)
{
   if (.rs.isNonEmptyScalarString(cacheKey) &&
       exists(".rs.WorkingDataEnv") &&
       exists(cacheKey, where = .rs.WorkingDataEnv, inherits = FALSE))
      rm(list = cacheKey, envir = .rs.WorkingDataEnv, inherits = FALSE)
   invisible(NULL)
})

.rs.addFunction("assignWorkingData", function(cacheKey, obj)
{
   if (.rs.isNonEmptyScalarString(cacheKey))
      assign(cacheKey, obj, .rs.WorkingDataEnv)
})

.rs.addFunction("findGlobalData", function(name)
{
   if (exists(name, envir = globalenv()))
   {
      if (inherits(get(name, envir = globalenv()), "data.frame"))
         return(name)
   }
   invisible("")
})

.rs.addFunction("isNonEmptyScalarString", function(x)
{
   is.character(x) && length(x) == 1 && nzchar(x)
})

