#!/usr/bin/env Rscript
#
# generate-prefs.R
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


# This script generates RStudio preference and state accessors for the R
# session (C++) and the front end (GWT Java) from JSON schema files. 
#
# To add a preference or state value, do the following:
#
# 1. Add your preference to the schema file (user-prefs-schema.json or user-state-schema.json)
# 2. In a terminal, navigate to this folder (src/gwt/tools)
# 3. Run this script: ./generate-prefs.R
# 4. Commit the .cpp, .hpp, and .java files the script changes

library(jsonlite)
library(renv)
library(stringi)

writeLines("Generating preferences...")

# Helper to capitalize a string
capitalize <- function(s) {
   paste0(toupper(substring(s, 1, 1)), substring(s, 2))
}

`%||%` <- function(x, y) if (is.null(x)) y else x

# Builds "enum" values in Java (really just named constants)
javaenum <- function(def, pref, type, indent) {
   java <- ""
   # Emit convenient enum constants if supplied
   if (!is.null(def[["enum"]])) {
      for (enumval in def[["enum"]]) {
         # Create syntactically valid variable name
         varname <- toupper(pref)
         valname <- toupper(gsub("[^A-Za-z0-9_]", "_", enumval))
         java <- paste0(java, indent,
            "public final static ", type, " ", varname, "_", 
            valname, " = \"", enumval, "\";\n"
         )
      }
      java <- paste0(java, "\n")
   }
   java
}

# Builds "enum" values in C++ (again, just named constants)
cppenum <- function(def, pref, type, indent) {
   cpp <- ""
   # Emit convenient enum constants if supplied
   if (!is.null(def[["enum"]])) {
      for (enumval in def[["enum"]]) {
         # Create syntactically valid variable name
         varname <- paste0("k", capitalize(pref))
         valname <- gsub("[^A-Za-z0-9_]", "_", enumval)
         valname <- gsub("_(.)", "\\U\\1\\E", valname, perl = TRUE)
         cpp <- paste0(cpp, indent,
            "#define ", varname, capitalize(valname), " \"", enumval, "\"\n")
      }
   }
   cpp
}

# Master function to generate code from JSON schema path
generate <- function(schemaPath, className) {
   
   # Extract prefs from JSON schema
   schema <- jsonlite::read_json(schemaPath)
   prefs <- schema$properties

   java <- ""   # The contents of the Java file we'll be creating
   javaConstants <- ""   # The contents of the Java constants (i18n) file we'll be creating
   javaProperties <- ""  # The contents of the Java properties (i18n) file we'll be creating
   cpp <- ""    # The contents of the C++ file we'll be creating
   hpp <- ""    # The contents of the C++ header file we'll be creating
   r <- ""      # The contents of the R file we'll be creating

   # DEBUG: Text prepended to all i18n outputs (so we can spot which is being displayed, if any)
   prefixDefault <- ""
   prefixProperties <- ""

   # Components
   
   # R starts with copyright header
   r <- renv:::heredoc('
      #
      # SessionUserPrefValues.R
      #
      # Copyright (C) 2025 by Posit Software, PBC
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
      # This file was automatically generated -- please do not modify it by hand.
      #
      
      .rs.setVar("uiPrefs", new.env(parent = emptyenv()))
   ')

   # A list in C++ of all preference keys, as a function
   cpplist <- paste0("std::vector<std::string> ", className, "::allKeys()\n{\n",
                     "   return std::vector<std::string>({\n")

   # A Java function that syncs every pref
   javasync <- "   public void syncPrefs(String layer, JsObject source)\n   {\n"

   # A Java function that lists every pref
   javalist <- paste0("   public List<PrefValue<?>> allPrefs()\n   {\n",
               "      ArrayList<PrefValue<?>> prefs = new ArrayList<PrefValue<?>>();\n");
   
   # C++ string constants for preference names
   cppstrings <- ""
   
   for (pref in names(prefs)) {
      
      # Convert the preference name from camel case to snake case
      camel <- gsub("_(.)", "\\U\\1\\E", pref, perl = TRUE)
      def <- prefs[[pref]]

      # Prefs with enumReadable values must have valid enum entry of equal length
      if (!is.null(def[["enumReadable"]]) &&
          (is.null(def[["enum"]]) || length(def[["enumReadable"]]) != length(def[["enum"]]))) {

         warningMsg <- sprintf("\nPreference \"%s\" does not have [[enum]] and [[enumReadable]] of equal length and will be skipped (not generated)", pref)
         cat(warningMsg)
         next
      }
      
      # Convert JSON schema type to corresponding Java type
      type <- def[["type"]]
      if (type == "object") {
         # Rich objects are converted to JavaScript native types
         type <- capitalize(camel) 
      } else if (type == "numeric" || type == "number") {
         # Numerics (not integers) become Double objects
         type <- "Double"
      } else if (type == "array") {
         # Arrays are presumed to be arrays of strings (we do not currently support
         # other types)
         type <- "JsArrayString"
      } else {
         # For all other types, we uppercase the type name to get a class name
         type <- capitalize(type)
      }
      
      # Map JSON schema types to Java and C++ data types
      preftype <- def[["type"]]
      if (identical(preftype, "boolean")) {
         preftype <- "bool"
         cpptype <- "bool"
      } else if (identical(preftype, "numeric") || identical(preftype, "number")) {
         preftype <- "dbl"
         cpptype <- "double"
      } else if (identical(preftype, "array")) {
         preftype <- "object"
         cpptype <- "core::json::Array"
      } else if (identical(preftype, "integer")) {
         preftype <- "integer"
         cpptype <- "int"
      } else if (identical(preftype, "string")) {
         preftype <- if (!is.null(def[["enum"]])) "enumeration" else "string"
         cpptype <- "std::string"
      } else if (identical(preftype, "object")) {
         preftype <- "object"
         cpptype <- "core::json::Object"
      }
      
      # Format the default value for the preference
      defaultval <- as.character(def[["default"]])
      if (identical(def[["type"]], "string")) {
         # Quote string defaults
         defaultval <- paste0("\"", defaultval, "\"")
      } else if (identical(def[["type"]], "boolean")) {
         # Convert Booleans from R-style (TRUE, FALSE) to Java style (true, false)
         defaultval <- tolower(defaultval)
      } else if (identical(def[["type"]], "numeric") || 
                 identical(def[["type"]], "number")) {
         # Ensure floating point numbers have a decimal
         if (!grepl(".", defaultval, fixed = TRUE)) {
            defaultval <- paste0(defaultval, ".0")
         }
      } else if (identical(def[["type"]], "array")) {
         # We currently only support string arrays
         defaultval <- sapply(defaultval, function(d) { 
            paste0("\"", d, "\"")}
         )
         defaultval <- paste0("JsArrayUtil.createStringArray(", paste(defaultval, collapse = ", "), ")")
      } else if (identical(def[["type"]], "object")) {
         # No current mechanism for construction default objects
         defaultval <- "null"
      }
      
      # Define a C++ string constant for this preference name
      cppstrings <- paste0(cppstrings,
                           "#define k", capitalize(camel), " \"", pref, "\"\n")
      cppstrings <- paste0(cppstrings, cppenum(def, camel, type, ""))
      cpplist <- paste0(cpplist, "      k", capitalize(camel), ",\n")

      # Create a Java (and C++) comment header for the preference
      comment <- paste0(
         "   /**\n",
         "    * ", def[["description"]], "\n",
         "    */\n")

      # Create a Java/GWT Properties file header for the preference
      commentProperties <- paste0(
         "# ", def[["description"]], "\n")

      # Add title and description entries for the java constants file
      prefTitle <- if (is.null(def[["title"]])) "" else def[["title"]]
      javaConstants <- paste0(javaConstants,
         comment,
         "   @DefaultStringValue(\"", prefixDefault, prefTitle, "\")\n",
         "   String ", camel, "Title", "();\n",
         "   @DefaultStringValue(\"", prefixDefault, def[["description"]], "\")\n",
         "   String ", camel, "Description", "();\n")

      if (!is.null(def[["enumReadable"]]))
      {
         javaConstants <- paste0(javaConstants,
                                 paste0(mapply(function (enumVal, enumReadable) {
                                    paste0(
                                       "   @DefaultStringValue(\"", prefixDefault, enumReadable, "\")\n",
                                       "   String ", camel, "Enum_", gsub("[^A-Za-z0-9_]", "_", enumVal), "();"
                                    )
                                 }, def[["enum"]], def[["enumReadable"]]), collapse = "\n"
                                 ), "\n"
         )
      }

      javaConstants <- paste0(javaConstants, "\n")

      # Add title and description entries for the java properties file
      javaProperties <- paste0(javaProperties,
         commentProperties,
         camel, "Title = ", prefixProperties, prefTitle, "\n",
         camel, "Description = ", prefixProperties, def[["description"]], "\n")

      if (!is.null(def[["enumReadable"]]))
      {
         javaProperties <- paste0(javaProperties,
                                  paste0(mapply(function (enumVal, enumReadable) {
                                     paste0(
                                        camel, "Enum_", gsub("[^A-Za-z0-9_]", "_", enumVal), "=", prefixProperties, enumReadable
                                     )
                                  }, def[["enum"]], def[["enumReadable"]]), collapse = "\n"
                                  ), "\n"
         )
      }

      javaProperties <- paste0(javaProperties, "\n")

      prefTitle <- paste0("_constants.", camel, "Title()")
      prefDescription <- paste0("_constants.", camel, "Description()")
      java <- paste0(java,
         comment,
         "   public PrefValue<", type, "> ", camel, "()\n",
         "   {\n",
         "      return ", preftype, "(\n         \"", pref, "\",\n",
                       "         ", prefTitle, ", \n",
                       "         ", prefDescription, ", \n")
      if (!is.null(def[["enum"]]))
      {
         java <- paste0(java, "         new String[] {\n",
                        paste(lapply(def[["enum"]], function(enumval) {
                           toupper(paste0("            ",
                                          pref,
                                          "_",
                                          gsub("[^A-Za-z0-9_]", "_", enumval)))
                        }), collapse = ",\n"),
                        "\n         },\n")
      }
      java <- paste0(java, 
                       "         ", defaultval)
      if (!is.null(def[["enumReadable"]]))
      {
         java <- paste0(java, ",\n", "         new String[] {\n",
                        paste(lapply(def[["enum"]], function(enumval) {
                           paste0("            _constants.", camel, "Enum_", gsub("[^A-Za-z0-9_]", "_", enumval), "()")
                        }), collapse = ",\n"),
                        "\n         }")
      }
      java <- paste0(java, ");\n   }\n\n")
      synctype <- if (identical(preftype, "enumeration")) "String" else capitalize(preftype)
      javasync <- paste0(javasync,
         "      if (source.hasKey(\"", pref, "\"))\n",
         "         ", camel, "().setValue(layer, source.get", synctype, "(\"", 
                pref, "\"));\n")
      javalist <- paste0(javalist,
         "      prefs.add(", camel, "());\n")

      
      # Add C++ header and implementation accessors for the preferences
      hpp <- paste0(hpp, comment,
                    "   ", cpptype, " ", camel, "();\n")
      hpp <- paste0(hpp, 
                    "   core::Error set", capitalize(camel), "(", cpptype, " val);\n\n")
      cpp <- paste0(cpp, 
         "/**\n",
         " * ", def[["description"]], "\n",
         " */\n",
         cpptype, " ", className, "::", camel, "()\n",
         "{\n",
         "   return readPref<", cpptype, ">(\"", pref, "\");\n",
         "}\n\n",
         "core::Error ", className, "::set", capitalize(camel), "(", cpptype, " val)\n",
         "{\n",
         "   return writePref(\"", pref, "\", val);\n",
         "}\n\n")
      
      # Emit JSNI for object types
      if (identical(def[["type"]], "object")) {
         java <- paste0(java,
            "   public static class ", type, " extends JavaScriptObject\n",
            "   {\n",
            "      protected ", type, "() {} \n\n")
         props <- def[["properties"]]
         for (prop in names(props)) {
            
            propdef <- props[[prop]]
            propname <- gsub("(^|_)(.)", "\\U\\2\\E", prop, perl = TRUE)
            proptype <- propdef[["type"]]
            
            default <- propdef[["default"]] %||% def[["default"]][[prop]]
            if (!is.null(default))
               default <- paste(" ||", jsonlite::toJSON(default, auto_unbox = TRUE))
            
            if (identical(proptype, "object")) {
               proptype <- "JavaScriptObject"
            } else if (identical(proptype, "array")) {
               proptype <- "JsArrayString"
               default <- default %||% " || []"
               if (!is.null(propdef[["items"]])) {
                  enumtype <- capitalize(propdef[["items"]][["type"]])
                  java <- paste0(java, javaenum(propdef[["items"]], propname, 
                                                enumtype, "      "))
               }
            } else if (identical(proptype, "string")) {
               proptype <- "String"
               default <- default %||% " || \"\""
            } else if (identical(proptype, "integer")) {
               proptype <- "int"
               default <- default %||% " || 0"
            } else if (identical(proptype, "number")) {
               proptype <- "double"
               default <- default %||% " || 0"
            } else if (identical(proptype, "boolean")) {
               default <- default %||% " || false"
            } else {
               default <- ""
            }
            
            java <- paste0(java,
              "      public final native ", proptype, " get",  propname, "() /*-{\n",
              "         return this && this.", prop, default, ";\n",
              "      }-*/;\n\n")
            cppstrings <- paste0(cppstrings,
                                 "#define k", capitalize(camel), propname, " \"", prop, "\"\n")
         }
         java <- paste0(java, "   }\n\n")
      }
      
      # Add enums if present
      java <- paste0(java, javaenum(def, pref, type, "   "))
      
      # generate code for R wrapper
      fmt <- renv:::heredoc('
         %s
         #
         %s
         .rs.uiPrefs$%s <- list(
            get = function() { .rs.getUserPref("%s") },
            set = function(value) { .rs.setUserPref("%s", value) },
            clear = function() { .rs.clearUserPref("%s") }
         )
      ')
      
      rtitle <- paste(paste("#", strwrap(def$title, width = 80)), collapse = "\n")
      rdesc <- paste(paste("#", strwrap(def$description, width = 80)), collapse = "\n")
      rcode <- sprintf(fmt, rtitle, rdesc, camel, pref, pref, pref)
      r <- paste(r, rcode, sep = "\n\n")
   }
   
   # Close off blocks and lists
   cpplist <- paste0(cpplist, "   });\n}\n")
   cpp <- paste0(cpp, cpplist)
   hpp <- paste0(cppstrings, "\n",
                 "class ", className, ": public Preferences\n", 
                 "{\n",
                 "public:\n",
                 "   static std::vector<std::string> allKeys();\n",
                 hpp,
                 "};\n")
   javasync <- paste0(javasync, "   }\n")
   java <- paste0(java, javasync)
   javalist <- paste0(javalist, "      return prefs;\n   }\n")
   java <- paste0(java, javalist)
   
   # Return computed Java and C++ code
   list(
      java = java,
      javaConstants = javaConstants,
      javaProperties = javaProperties,
      cpp = cpp,
      hpp = hpp,
      r = r
   )
}

# Generate preferences
result <- generate("../../cpp/session/resources/schema/user-prefs-schema.json",
                   "UserPrefValues")
template <- readLines("prefs/UserPrefsAccessor.java")
writeLines(gsub("%PREFS%", result$java, template), 
           con = "../src/org/rstudio/studio/client/workbench/prefs/model/UserPrefsAccessor.java")
template <- readLines("prefs/UserPrefsAccessorConstants.java")
writeLines(gsub("%PREFS%", result$javaConstants, template),
           con = "../src/org/rstudio/studio/client/workbench/prefs/model/UserPrefsAccessorConstants.java")
template <- readLines("prefs/UserPrefsAccessorConstants_en.properties")
writeLines(gsub("%PREFS%", result$javaProperties, template),
           con = "../src/org/rstudio/studio/client/workbench/prefs/model/UserPrefsAccessorConstants_en.properties")
template <- readLines("prefs/UserPrefValues.hpp")
writeLines(gsub("%PREFS%", result$hpp, template), 
           con = "../../cpp/session/include/session/prefs/UserPrefValues.hpp")
template <- readLines("prefs/UserPrefValues.cpp")
writeLines(gsub("%PREFS%", result$cpp, template), 
           con = "../../cpp/session/prefs/UserPrefValues.cpp")
writeLines(result$r, con = "../../cpp/session/modules/SessionUserPrefValues.R")

# Generate state
result <- generate("../../cpp/session/resources/schema/user-state-schema.json",
                   "UserStateValues")
javaTemplate <- readLines("prefs/UserStateAccessor.java")
writeLines(gsub("%STATE%", result$java, javaTemplate), 
           con = "../src/org/rstudio/studio/client/workbench/prefs/model/UserStateAccessor.java")
javaTemplate <- readLines("prefs/UserStateAccessorConstants.java")
writeLines(gsub("%STATE%", result$javaConstants, javaTemplate),
           con = "../src/org/rstudio/studio/client/workbench/prefs/model/UserStateAccessorConstants.java")
javaTemplate <- readLines("prefs/UserStateAccessorConstants_en.properties")
writeLines(gsub("%STATE%", result$javaProperties, javaTemplate),
           con = "../src/org/rstudio/studio/client/workbench/prefs/model/UserStateAccessorConstants_en.properties")
template <- readLines("prefs/UserStateValues.hpp")
writeLines(gsub("%STATE%", result$hpp, template), 
           con = "../../cpp/session/include/session/prefs/UserStateValues.hpp")
template <- readLines("prefs/UserStateValues.cpp")
writeLines(gsub("%STATE%", result$cpp, template), 
           con = "../../cpp/session/prefs/UserStateValues.cpp")

writeLines("Preference generation complete.")

