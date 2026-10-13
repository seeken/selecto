# Reviewed legacy Dialyzer baseline. Entries are location-specific and CI checks
# for unused filters, so fixed warnings must be removed and new warnings fail.
[
  {"lib/selecto/domain_validator.ex", :pattern_match, 1},
  {"lib/selecto/field_resolver/parameterized_parser.ex", :pattern_match, {157, 8}}
]
