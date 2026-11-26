library(sf)
library(dplyr)
library(tidyr)
library(rmapshaper)
library(jsonlite)

# Run from the project root (open fafsa-completion.Rproj).
# Inputs: Esri exports in esri_download/
#   fafsa_districts_2026      - ISD boundaries with wide FAFSA columns (map)
#   fafsa_completion_long     - one row per district x year, ISDs + charters, no geometry
in_dir <- "esri_download"
read_esri <- function(name) {
  gj <- file.path(in_dir, paste0(name, ".geojson"))
  src <- if (file.exists(gj)) gj else paste0("/vsizip/", file.path(in_dir, paste0(name, ".zip")))
  st_read(src, quiet = TRUE)
}

dir.create("docs/data", recursive = TRUE, showWarnings = FALSE)

# ---- Long table: ISDs + charters -------------------------------------------
long <- read_esri("fafsa_completion_long") %>%
  st_drop_geometry() %>%
  filter(!is.na(district_id)) %>%
  mutate(id = as.integer(district_id),
         community_type = na_if(trimws(community_type), ""),
         Sector = coalesce(na_if(trimws(Sector), ""), "Traditional ISD"))

nice_name <- function(x) gsub("\\b(C?)isd\\b", "\\1ISD", tools::toTitleCase(tolower(x)), ignore.case = TRUE)

fafsa <- long %>%
  transmute(id, name = nice_name(district_name), county = county_name, type = community_type,
            sector = Sector, year, completed = fafsa_completed, grads = total_graduates,
            rate = fafsa_completion_rate) %>%
  filter(!is.na(completed) | !is.na(grads)) %>%
  arrange(name, year)

write_json(fafsa, "docs/data/fafsa.json", digits = 4, na = "null")

# ---- Profiles: latest year's TAPR snapshot per district --------------------
rate_wide <- fafsa %>%
  select(id, year, rate) %>%
  pivot_wider(names_from = year, values_from = rate)

long %>%
  arrange(id, desc(year)) %>%
  distinct(id, .keep_all = TRUE) %>%
  left_join(transmute(rate_wide, id, rate_change_2223_to_2425 = `2024-2025` - `2022-2023`), by = "id") %>%
  mutate(district_id = id) %>%
  select(-id, -year, -district_name, -fafsa_completed, -total_graduates, -fafsa_completion_rate,
         -any_of(c("district_num", "ObjectId", "esc_region_str"))) %>%
  { list(cols = names(.), rows = .) } %>%
  write_json("docs/data/profiles.json", dataframe = "values", auto_unbox = TRUE, digits = NA, na = "null")

# ---- Map: ISD boundaries (charters have none) ------------------------------
map_rates <- fafsa %>%
  transmute(id, year, rate, completed, grads) %>%
  pivot_wider(names_from = year, values_from = c(rate, completed, grads), names_sep = "_")

districts_full <- read_esri("fafsa_districts_2026") %>%
  mutate(community_type = na_if(trimws(community_type), "")) %>%
  select(id = district_id, name = NAME, county = county_name, type = community_type) %>%
  mutate(id = as.integer(id)) %>%
  st_make_valid()

districts <- districts_full %>%
  left_join(map_rates, by = "id") %>%
  ms_simplify(keep = 0.04, keep_shapes = TRUE)

unlink("docs/data/districts.geojson")
st_write(districts, "docs/data/districts.geojson", quiet = TRUE,
         layer_options = c("COORDINATE_PRECISION=4", "RFC7946=YES"))

# ---- Texas House & Senate districts -----------------------------------------
# Census TIGER/Line state legislative districts (downloaded once into tiger_download/).
# A school district counts as serving a legislative district when their overlap is at
# least LEG_MIN_SHARE of either one's area (or it is the school district's largest
# overlap), so a school district can serve several and vice versa.
tiger_year <- 2026
LEG_MIN_SHARE <- 0.05
tiger_dir <- "tiger_download"
dir.create(tiger_dir, showWarnings = FALSE)
read_tiger <- function(kind) {
  f <- file.path(tiger_dir, sprintf("tl_%d_48_%s.zip", tiger_year, kind))
  if (!file.exists(f)) {
    download.file(sprintf("https://www2.census.gov/geo/tiger/TIGER%d/%s/%s",
                          tiger_year, toupper(kind), basename(f)), f, mode = "wb")
  }
  st_read(paste0("/vsizip/", f), quiet = TRUE)
}

leg <- bind_rows(
  read_tiger("sldl") %>% transmute(chamber = "house", district = as.integer(SLDLST)),
  read_tiger("sldu") %>% transmute(chamber = "senate", district = as.integer(SLDUST))
) %>%
  filter(!is.na(district), district > 0, district < 900) %>%  # drop "ZZZ" water-only parts
  st_transform(3083) %>%
  st_make_valid() %>%
  mutate(leg_area = as.numeric(st_area(geometry)))

sd_area <- districts_full %>%
  st_transform(3083) %>%
  group_by(id) %>% summarise(.groups = "drop") %>%
  mutate(sd_area = as.numeric(st_area(geometry)))

overlap <- st_intersection(select(sd_area, id, sd_area), leg) %>%
  mutate(a = as.numeric(st_area(geometry)), share = a / sd_area, leg_share = a / leg_area) %>%
  st_drop_geometry() %>%
  group_by(id, chamber) %>%
  filter(share >= LEG_MIN_SHARE | leg_share >= LEG_MIN_SHARE | share == max(share)) %>%
  ungroup() %>%
  arrange(chamber, district, id)

leg_members <- lapply(c(house = "house", senate = "senate"), function(ch) {
  o <- filter(overlap, chamber == ch)
  lapply(split(o$id, o$district), unique)
})
write_json(leg_members, "docs/data/legislative.json", auto_unbox = FALSE)

leg_map <- leg %>%
  select(chamber, district) %>%
  st_transform(4326) %>%
  ms_simplify(keep = 0.02, keep_shapes = TRUE)
unlink("docs/data/legislative.geojson")
st_write(leg_map, "docs/data/legislative.geojson", quiet = TRUE,
         layer_options = c("COORDINATE_PRECISION=4", "RFC7946=YES"))

# ---- Checks ------------------------------------------------------------------
message("Legislative districts: ", length(leg_members$house), " House, ",
        length(leg_members$senate), " Senate (TIGER ", tiger_year, ")")
message("fafsa.json: ", nrow(fafsa), " rows; ", n_distinct(fafsa$id), " districts (",
        n_distinct(fafsa$id[fafsa$sector == "Charter"]), " charters)")
message("Map districts without long-table data: ", sum(!districts$id %in% fafsa$id))
message("Long-table ISDs without a map shape: ",
        n_distinct(setdiff(fafsa$id[fafsa$sector != "Charter"], districts$id)))
