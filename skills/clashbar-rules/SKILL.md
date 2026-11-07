---
name: clashbar-rules
description: Inspect and change custom routing rules in the local ClashBar app when a user asks to route, block, replace, or remove traffic rules.
---

# ClashBar Rules

ClashBar must be running under the same macOS user. Use `python3` with the helper relative to this skill directory:

```bash
python3 "<skill-directory>/scripts/clashbar_rules.py" list
```

The JSON response contains the selected base configuration, custom changes with IDs, base and effective rules in match order, known policy names, and a `revision`. Policy names are collected from the base file and the app's current runtime state and may be incomplete when the core is stopped. It excludes subscription URLs and unrelated configuration. Read the current state before changing rules; use policy names from the response and clarify the intended target if it cannot be inferred. Added rules precede base rules, in the order shown. Changes apply only to the local core, not a selected remote target.

Modify one custom change at a time with the current revision. Use shell quoting for rule strings and policy names. The application validates the merged configuration with Mihomo and applies it to a running core; when the core is stopped, the validated configuration is saved for its next start. A failed operation reports an error; do not claim it was applied.

```bash
python3 "<skill-directory>/scripts/clashbar_rules.py" add --revision REVISION --operation add --value 'DOMAIN-SUFFIX,example.com,DIRECT'
python3 "<skill-directory>/scripts/clashbar_rules.py" add --revision REVISION --operation replace --original 'DOMAIN,example.com,DIRECT' --value 'DOMAIN,example.com,REJECT'
python3 "<skill-directory>/scripts/clashbar_rules.py" add --revision REVISION --operation delete --original 'DOMAIN,example.com,DIRECT'
python3 "<skill-directory>/scripts/clashbar_rules.py" update --revision REVISION --id RULE_ID --operation add --value 'DOMAIN,example.com,DIRECT'
python3 "<skill-directory>/scripts/clashbar_rules.py" remove --revision REVISION --id RULE_ID
```

`remove` removes the custom change; to remove a rule from the base configuration, add a change with operation `delete` and its exact base rule. `replace` also requires the exact original base rule. `update` replaces the entire identified custom change. The returned snapshot contains the new revision. On a conflict, read again and re-evaluate the user's intent before retrying. Do not edit ClashBar's state or effective files directly. Explain the resulting match and policy and whether the core was running.
