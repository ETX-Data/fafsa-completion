library(sf)
library(dplyr)
library(tidyr)
library(rmapshaper)
library(jsonlite)

dir.create("docs/data", recursive = TRUE, showWarnings = FALSE)

raw <- st_read("fafsa_districts_2026.geojson", quiet = TRUE) %>%
  mutate(community_type = na_if(trimws(community_type), ""))

year_cols <- "^(fafsa_completed|total_graduates|fafsa_completion_rate)_(\\d{4}_\\d{4})$"

wide <- raw %>%
  st_drop_geometry() %>%
  distinct(district_id, .keep_all = TRUE) %>%
  select(id = district_id, name = NAME, county = county_name, type = community_type,
         matches(year_cols))

# Charter-inclusive table, if exported
if (file.exists("fafsa_long.csv")) {
  fafsa <- read.csv("fafsa_long.csv", check.names = FALSE, fileEncoding = "UTF-8-BOM") %>%
    transmute(name = gsub("\\b(C?)isd\\b", "\\1ISD", tools::toTitleCase(tolower(district_name)), ignore.case = TRUE),
              county = county_name, type = na_if(trimws(community_type), ""),
              sector = Sector, year = gsub("_", "-", as.character(year)),
              completed = fafsa_completed, grads = total_graduates, rate = fafsa_completion_rate)
} else {
  fafsa <- wide %>%
    pivot_longer(matches(year_cols), names_to = c(".value", "year"), names_pattern = year_cols) %>%
    transmute(name, county, type, sector = "Traditional ISD", year = sub("_", "-", year),
              completed = fafsa_completed, grads = total_graduates, rate = fafsa_completion_rate)
}

fafsa <- filter(fafsa, !is.na(completed) | !is.na(grads))
write_json(fafsa, "docs/data/fafsa.json", digits = 4, na = "null")

map_rates <- wide %>%
  pivot_longer(matches(year_cols), names_to = c(".value", "year"), names_pattern = year_cols) %>%
  transmute(id, key = sub("_", "-", year), rate = fafsa_completion_rate,
            completed = fafsa_completed, grads = total_graduates) %>%
  pivot_wider(names_from = key, values_from = c(rate, completed, grads), names_sep = "_")

districts <- raw %>%
  select(id = district_id, name = NAME, county = county_name, type = community_type,
         students = total_students, econ = stu_pct_economically_disadvantaged,
         grad4 = F4_yr_longitudinal_graduation_rate_class_of_2022_district_exc) %>%
  left_join(map_rates, by = "id") %>%
  st_make_valid() %>%
  ms_simplify(keep = 0.04, keep_shapes = TRUE)

unlink("docs/data/districts.geojson")
st_write(districts, "docs/data/districts.geojson", quiet = TRUE,
         layer_options = c("COORDINATE_PRECISION=4", "RFC7946=YES"))
