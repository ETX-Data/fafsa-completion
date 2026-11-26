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
# TIGER/Line districts; school district counts if overlap >= LEG_MIN_SHARE of either area
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

# ---- FSA FAFSA completion by high school -----------------------------------
# Source: https://studentaid.gov/data-center/student/application-volume/fafsa-completion-high-school
library(readxl)
fsa_dir <- "fsa_download"
dir.create(fsa_dir, showWarnings = FALSE)
fsa_xls <- file.path(fsa_dir, "TX.xls")
if (!file.exists(fsa_xls)) {
  download.file("https://studentaid.gov/sites/default/files/fsawg/datacenter/library/fafsabyhs/TX.xls",
                fsa_xls, mode = "wb")
}
lea_json <- file.path(fsa_dir, "tx_lea_directory_2023.json")
if (!file.exists(lea_json)) {
  download.file("https://educationdata.urban.org/api/v1/school-districts/ccd/directory/2023/?fips=48",
                lea_json, mode = "wb")
}
lea_xwalk <- fromJSON(lea_json)$results %>%
  transmute(leaid = as.character(leaid), id = as.integer(sub("^TX-", "", state_leaid))) %>%
  filter(!is.na(id))

fsa_num <- function(x) suppressWarnings(as.numeric(gsub(",", "", x)))
read_fsa <- function(sheet) {
  hdr <- read_excel(fsa_xls, sheet = sheet, col_names = FALSE, n_max = 4, .name_repair = "unique_quiet")
  d <- read_excel(fsa_xls, sheet = sheet, col_names = FALSE, skip = 4, col_types = "text", .name_repair = "unique_quiet")
  list(hdr = hdr, d = d)
}
as_of <- function(hdr, col) trimws(gsub("\\s+", " ", sub("^Through ", "", hdr[[col]][3])))

# Class of 2026 now, class of 2025 a year ago
s_main <- read_fsa("TX School Level Data")
stopifnot(grepl("2026 / 2027", s_main$hdr[[5]][2]), grepl("2025 / 2026", s_main$hdr[[7]][2]))
schools <- s_main$d %>%
  transmute(code = ...1, leaid = substr(...1, 1, 7), c26 = fsa_num(...6), c25 = fsa_num(...8))
# Class of 2027 now, class of 2026 a year ago
s_now <- read_fsa("TX 2027-28 Cycle")
stopifnot(grepl("2027 / 2028", s_now$hdr[[5]][2]), grepl("2026 / 2027", s_now$hdr[[7]][2]))
now <- s_now$d %>%
  transmute(code = ...1, leaid = substr(...1, 1, 7), c27 = fsa_num(...6), c27_prev = fsa_num(...8))
state_now <- filter(now, code == "--")
s_dist <- read_fsa("TX District Level Data")
dist_bins <- s_dist$d %>% transmute(leaid = ...1, pct26 = ...4, pct25 = ...5) %>% filter(grepl("^48", leaid))

sum_na <- function(x) if (all(is.na(x))) NA_real_ else sum(x, na.rm = TRUE)
fsa_dist <- full_join(
  schools %>% filter(grepl("^48[0-9]{10}$", code)) %>%
    group_by(leaid) %>% summarise(c26 = sum_na(c26), c25 = sum_na(c25), sup = sum(is.na(c26)), n_hs = n(), .groups = "drop"),
  now %>% filter(grepl("^48[0-9]{10}$", code)) %>%
    group_by(leaid) %>% summarise(c27 = sum_na(c27), c27_prev = sum_na(c27_prev), .groups = "drop"),
  by = "leaid") %>%
  full_join(dist_bins, by = "leaid") %>%
  inner_join(lea_xwalk, by = "leaid")

fsa_out <- list(
  as_of = as_of(s_main$hdr, 5), prev_as_of = as_of(s_main$hdr, 7),
  state = list(c27 = state_now$c27, c27_prev = state_now$c27_prev,
               c26 = schools$c26[schools$code == "--"], c25 = schools$c25[schools$code == "--"]),
  cols = c("id", "c25", "c26", "pct25", "pct26", "c27", "c27_prev", "n_hs", "sup"),
  rows = fsa_dist %>% select(id, c25, c26, pct25, pct26, c27, c27_prev, n_hs, sup)
)
write_json(fsa_out, "docs/data/fsa.json", dataframe = "values", auto_unbox = TRUE, na = "null", digits = NA)

# ---- Checks ------------------------------------------------------------------
message("FSA (", fsa_out$as_of, "): ", nrow(fsa_dist), " districts matched to TEA IDs; ",
        sum(!dist_bins$leaid %in% lea_xwalk$leaid), " FSA districts unmatched; ",
        sum(!fsa_dist$id %in% fafsa$id), " matched but not in the TEA data")
message("Legislative districts: ", length(leg_members$house), " House, ",
        length(leg_members$senate), " Senate (TIGER ", tiger_year, ")")
message("fafsa.json: ", nrow(fafsa), " rows; ", n_distinct(fafsa$id), " districts (",
        n_distinct(fafsa$id[fafsa$sector == "Charter"]), " charters)")
message("Map districts without long-table data: ", sum(!districts$id %in% fafsa$id))
message("Long-table ISDs without a map shape: ",
        n_distinct(setdiff(fafsa$id[fafsa$sector != "Charter"], districts$id)))
