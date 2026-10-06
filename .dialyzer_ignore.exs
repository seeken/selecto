# Reviewed legacy Dialyzer baseline. Entries are location-specific and CI checks
# for unused filters, so fixed warnings must be removed and new warnings fail.
[
  {"lib/selecto/domain/choices.ex", :guard_fail, {706, 29}},
  {"lib/selecto/domain/choices.ex", :pattern_match_cov, {708, 8}},
  {"lib/selecto/domain_validator.ex", :pattern_match, 1},
  {"lib/selecto/field_resolver/parameterized_parser.ex", :pattern_match, {157, 8}},
  {"lib/selecto/verification/governed_query_composition.ex", :pattern_match, {314, 58}}
]
