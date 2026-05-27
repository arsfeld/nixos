# Compound YAML Schema — Category Mapping

Maps `problem_type` values to `docs/solutions/` subdirectories.

## Bug track categories

| problem_type | category directory |
|---|---|
| build_error | build-errors/ |
| test_failure | test-failures/ |
| runtime_error | runtime-errors/ |
| performance_issue | performance-issues/ |
| database_issue | database-issues/ |
| security_issue | security-issues/ |
| ui_bug | ui-bugs/ |
| integration_issue | integration-issues/ |
| logic_error | logic-errors/ |
| config_error | config-errors/ |
| dependency_issue | dependency-issues/ |

## Knowledge track categories

| problem_type | category directory |
|---|---|
| architecture_pattern | architecture-patterns/ |
| design_pattern | design-patterns/ |
| tooling_decision | tooling-decisions/ |
| workflow_pattern | workflow-patterns/ |
| best_practice | best-practices/ |
| gotcha | gotchas/ |

## YAML Safety Rules

When writing YAML frontmatter:
1. Always quote string values that contain `:` followed by a space (e.g., `title: "Nix: fixing flake lock conflicts"`)
2. Always quote string values that contain `#` to prevent silent comment truncation
3. Array items with special characters should be quoted individually
4. Use `---` as the YAML document separator (opening and closing)
