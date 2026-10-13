# Contributing

Thanks for helping. A few rules keep the kit small and consistent.

## Agents are generated

Never edit `plugins/*/agents/*.md` by hand. Each agent file is built from
one role body and one variant entry:

- the body: `shared/agents/<role>.body.md`;
- the variant: an entry in `shared/agents/variants.json` with `plugin`,
  `name`, `body`, `description`, `model`, `effort` and `tools`.

Edit those, then regenerate and check:

```bash
python3 tools/build_agents.py
python3 tools/build_agents.py --check
```

Two agents that share a body (a cheap and a strong variant) must stay
identical apart from their frontmatter; that is why they are generated.

## The config loader is shared

`shared/studio_config.py` is copied into every plugin's `scripts/`. Edit
the source only, then:

```bash
python3 tools/sync_shared.py
python3 tools/sync_shared.py --check
```

A new config key goes into `config/studio.schema.json` with its default
and description, into the loader's `DEFAULTS` (a test checks they match),
into `config/studio.example.json` when it helps, and into the module page
under `docs/modules/`.

## Skills

- Every new `SKILL.md` stays under 8 KB. The procedure goes in `SKILL.md`;
  recipes, background and rare cases go in that skill's `reference/*.md`,
  named from the step that needs them.
- Keep every trigger word in the `description`.
- Agent names in skills are always the namespaced form
  (`studio-core:builder`). Script paths are always
  `${CLAUDE_PLUGIN_ROOT}/scripts/<name>`. The copy-in installer rewrites
  both.
- Skills read config through `studio_config.py get`, never a hard-coded
  path or command.

## Tests

Run everything before you open a pull request:

```bash
bash tests/run_all.sh
python3 tools/build_agents.py --check
python3 tools/sync_shared.py --check
claude plugin validate . --strict
```

A new script gets a test in `tests/` (`<name>_test.sh` or
`<name>_test.py`; `run_all.sh` picks it up). Scripts are standard library
Python 3.9 or plain bash 3.2, so they run on a stock macOS.

## No project-specific content

The kit is generic. Do not add product names, company or person names,
account or channel ids, absolute home paths, internal ticket or decision
ids, or wording tied to one business or platform. Examples use
placeholder ids such as `T-1` or `T-12`. A lesson from your own project is
welcome when it is told generically: what failed, and the rule it left.

## Style

Plain, direct English. Short sentences. No hype.
