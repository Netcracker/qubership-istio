# istio-dashboard-adapter

An APM package that teaches the agent how the Istio Grafana dashboards
in this repository differ from the upstream ones, and how to reproduce
those differences on a fresh import.

The dashboards under `helm-templates/qubership-istio/dashboards` are
upstream Istio's `pilot-dashboard.gen.json` and
`ztunnel-dashboard.gen.json` with three adaptations:

- **resource-limit overlays** on the CPU and memory panels, drawn as a
  red reference line;
- **a cluster selector** - a `cluster` variable and a `cluster="$cluster"`
  matcher on every query, for a Grafana that serves several clusters;
- **one panel removed** - `Injection`, which only ever fills under sidecar
  mode. `Push Errors` and `Validation` stay: they look broken but are not,
  and the skill explains why an empty one means a healthy cluster.

## Install

```sh
apm install ./agent-packages/istio-dashboard-adapter --target claude
```

This deploys the package's primitives into the consuming repo:
the skill into `.claude/skills/` and the instruction into
`.claude/rules/`, which Claude Code reads directly, so no `CLAUDE.md` is
generated. Re-run it to pick up a new version.

## What you get

- An instruction that fires when you edit a Grafana dashboard `*.json`.
- The [`SKILL.md`](.apm/skills/istio-dashboard-adapter/SKILL.md) - the
  three adaptations step by step, and the reasoning behind each one,
  including why `Validation` is kept although it usually shows nothing.

## Usage

Automatic - the instruction triggers the skill whenever the agent works
on a Grafana dashboard `*.json` in this repository.

On demand - invoke the `istio-dashboard-adapter` skill by name.

## When it matters most

On a version bump. Importing a dashboard from a newer Istio release
silently reverts all three adaptations at once, and the loss is easy to
miss: the dashboard still renders, it just stops showing limits, stops
honouring the cluster selector, and grows back the panel that can never
fill. Read the skill before the import, and diff after it.
