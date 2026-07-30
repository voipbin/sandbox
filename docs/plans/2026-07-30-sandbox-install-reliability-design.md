# VoIPBin Sandbox — Install Reliability Fix (Call-Manager / Transcribe-Manager Crash Loops, Version Pin Refresh, Env Template Sync)

Status: DRAFT (Design Review Round 3, addressing Round 2 REQUEST_CHANGES)
Author: Hermes (CPO) with pchero (CEO/CTO)
Date: 2026-07-30
Repo: sandbox (fixes 2.1/2.2 land in monorepo; this doc is the sandbox-side design of record for the whole effort)

## 0. Mandate

A customer reported that installing VoIPBin via the sandbox failed. We do not have their
logs. **This document treats "call-manager's sentinel-manager crash loop is the customer's
failure" as a hypothesis, not a confirmed diagnosis** — it is the single most severe,
100%-reproducible failure found in a fresh clean-room install, and call-manager is core to
all call handling, so it is the leading candidate. Closing the loop with certainty requires
either the customer's logs or their confirmation after this fix ships; this document does
not claim that confirmation.

Goal: after this cycle, a fresh sandbox install reaches a stable, fully-running state (no
unexplained crash-looping containers) for a new self-hoster, the version/credential
bookkeeping that made this hard to diagnose is cleaned up, and the two monorepo-level bugs
found are fixed in a way that does not silently disable functionality. Everything this
document cannot verify without an interactive `sudo` session is deferred to §6, not hidden.

## 1. Reproduction findings (verified facts)

Full clean-room reproduction was run in this cycle: infra (db/redis/rabbitmq) up →
containerized alembic migration against the pinned Feb-21 dbscheme commit → full 44-service
`docker compose up -d` → `setup_test_customer.sh` against `https://localhost:8443`. Sudo-gated
steps (mkcert CA install, DNS forwarding, VoIP macvlan network setup) could not be exercised
in that session and are explicitly deferred (§6).

**Result: 40/44 containers healthy, 4 down** — 2 real bugs, 2 expected/sudo-gated (not new
findings).

| Container | Cause | Verdict |
|---|---|---|
| `voipbin-call-mgr` | `bin-call-manager/pkg/subscribehandler/main.go:124-134` (`subscribeHandler.Run()`): after `QueueCreate` (124-126), the loop over 4 targets (129-134) calls `QueueSubscribe`, which delegates to `QueueBind` (`bin-common-handler/pkg/rabbitmqhandler/queue.go:~90-98`; interface declared at `main.go:34-35`). The target list is built in `cmd/call-manager/main.go:180-185` and includes `commonoutline.QueueNameSentinelEvent` alongside asterisk-event-all/customer-event/flow-event. Sandbox's `docker-compose.yml` deliberately omits the `sentinel-manager` service (requires the Kubernetes API, crash-loops in Compose per its own inline comment), so that exchange is never declared, `QueueBind` returns an AMQP 404, and the wrapped error propagates to a `logrus.Fatalf` exit. Not sandbox-specific — **any non-Kubernetes Compose-based deployment of call-manager hits this**. Sentinel is last in the target list, so bindings 1-3 (asterisk-event-all, customer-event, flow-event) succeed before the 4th call fails and the channel is torn down — the failure is not "call-manager never subscribes to anything", it's "call-manager dies mid-subscribe, after already succeeding on 3 of 4, which the crash-loop then hides" (the `ConsumeMessage` goroutine at 137-141 never even gets a chance to start, since `Run()` returns the error before reaching it). | **Fatal, highest priority.** Leading hypothesis for the customer's reported failure (see §0). |
| `sandbox-transcribe-manager-1` | `bin-transcribe-manager/pkg/streaminghandler/main.go` (`NewStreamingHandler`, spans 83-130) already treats GCP/AWS client init failure as non-fatal (`log.Warnf`, continues) for each provider individually — that part already degrades gracefully. The actual fatal: if **both** providers end up nil, the function returns a bare `nil` interface (112-116), and `cmd/transcribe-manager/main.go:144-146` turns the `streamingHandler == nil` check into a returned error, unwinding to the same `logrus.Fatalf` exit path. Root cause: `init.sh`/`init_no_sudo.sh` generate a syntactically-present but unparseable dummy GCP private key (§2.4), so GCP init fails, and no AWS credentials are configured by default, so both are nil. Only `runStreaming(streamingHandler)` (`cmd/transcribe-manager/main.go:224`, calling `.Run()`) touches the interface at boot — `transcribehandler.NewTranscribeHandler` (`pkg/transcribehandler/main.go:99-119`) only stores it in a struct field at construction time, it does not call a method on it, so the earliest possible nil-dereference is inside `runStreaming`, with further ones at later per-request call sites in `transcribehandler`. | **Fatal, second priority.** Inconsistent with the *intent* already expressed in the per-provider warnings — the code clearly meant to support "degrade, don't crash" but stops short of it. |
| `voipbin-kamailio` | Requires the `KAMAILIO_EXTERNAL_IP` macvlan interface, only created by the sudo-gated `setup-voip-network.sh`. Expected, not run this session. | Not a bug, deferred to §6. |
| `voipbin-dns` (CoreDNS) | Requires `config/coredns/Corefile`, only generated by the sudo-gated DNS setup step. Expected, not run this session. | Not a bug, deferred to §6. |

**A third service may be silently degraded rather than genuinely healthy.**
`timeline-manager` (`docker-compose.yml:~1155`) reads `CLICKHOUSE_ADDRESS=${CLICKHOUSE_ADDRESS:-}`
with no ClickHouse service defined anywhere in `docker-compose.yml`, and sandbox `CLAUDE.md`
itself documents timeline-manager as "requires ClickHouse". Its healthcheck only probes
`:2112/metrics` (the generic Prometheus port every manager exposes), which can report healthy
independent of whether its actual ClickHouse-backed functionality works. This was not
separately confirmed broken in this cycle's reproduction — it reported healthy — but it is
flagged here explicitly rather than silently counted as a clean pass, since the same
"loud crash beats silent degradation" argument this document makes for call-manager and
transcribe-manager applies here too. Out of scope to fix this cycle (§4); noted so the §3
pass criterion isn't read as stronger than it is.

**Version drift is not implicated.** `versions.lock` pins the Feb-21 monorepo commit while
monorepo HEAD is now Jul-30 (~5 months). Migrations against the Feb-21 pin completed with
zero errors, and both fatal bugs above were confirmed to exist unchanged at current monorepo
HEAD (`a0438c1f2`). Bumping the pin alone would not have fixed the customer's install.

**Dummy GCP credential is mounted into 3 services, not just transcribe-manager**
(`docker-compose.yml:529` api-manager, `:989` rag-manager, `:1193` transcribe-manager, all
`${GOOGLE_APPLICATION_CREDENTIALS:-./config/dummy-gcp-credentials.json}`). Confirmed in this
session's reproduction that **api-manager and rag-manager stayed healthy** with the same
unparseable credential — both are lazy-init on that path (only touched when a
GCS/RAG-embedding feature is actually invoked, not at process boot), so they are not in
scope for this cycle. Only transcribe-manager parses it eagerly at startup.

**Env var audit**: no genuinely required variable was found missing or broken. See §2.5 for
the concrete `.env.template` sync plan.

The customer/agent bootstrap flow fixed in PR #7 (da0c1cd) — customer create → agent password
set → JWT login → billing plan → extensions — was re-verified working with **no regression**.

## 2. Scope

### 2.1 monorepo `bin-call-manager` — sentinel-manager subscribe fix

**Rejected approach 1: "log the error and continue".** `QueueBind` failure with AMQP 404
closes the underlying channel, which all four subscribe targets share on one subscribe
queue — leaving call-manager deaf to whichever targets bind *after* the failing one
(sentinel is last, so this specific ordering would only lose sentinel itself today, but the
approach is fragile to future target-list reordering and does nothing to prevent the crash
in the first place, since the loop still hits the same 404).

**Rejected approach 2 (this document's own Round-1→2 draft): "add `ExchangeDeclare` to the
`Rabbit`/`SockHandler` interface, call it with hand-matched kind/durability parameters
before the bind".** Round-2 review correctly caught two problems: (a) `ExchangeDeclare`
is defined only on the unexported `amqpChannel`/`*rabbit` types
(`bin-common-handler/pkg/rabbitmqhandler/main.go` interface section, `exchange.go:10`),
not reachable through `SockHandler` — implementing this literally means extending a
`bin-common-handler` public interface, which per root `CLAUDE.md` triggers a
verification pass across all 37 consumer services, a scope this document never accounted
for; (b) hand-matching exchange kind/durability risks an AMQP 406 `PRECONDITION_FAILED`
on any mismatch with how sentinel-manager itself declares the exchange, which closes the
channel — the exact failure mode this fix exists to avoid.

**Chosen approach**: `SockHandler` (which `subscribeHandler` already holds as
`h.sockHandler`) already exposes `TopicCreate(name string) error`
(`bin-common-handler/pkg/sockhandler/main.go:20`), which internally calls
`ExchangeDeclare(name, "fanout", true, false, false, false, nil)`
(`rabbitmqhandler/topic.go:5-12`). This is **exactly** how sentinel-manager declares the
same exchange today: `bin-sentinel-manager/cmd/sentinel-manager/main.go:93` constructs a
`notifyhandler.NewNotifyHandler(...)`, whose constructor
(`bin-common-handler/pkg/notifyhandler/main.go:112-122`) calls
`sockHandler.TopicCreate(string(queueEvent))` for the event queue it owns. Calling
`h.sockHandler.TopicCreate(string(target))` for the sentinel target before (or as part of)
the existing `QueueSubscribe` loop in `pkg/subscribehandler/main.go` therefore requires
**no interface change** (the method is already on `SockHandler`) and gets kind/durability
parity **by construction**, not by hand-matching. If sentinel-manager is deployed, its own
`TopicCreate` call already made this a no-op declare (idempotent, matching params); if it
is not deployed (sandbox, or any non-K8s deployment), call-manager's `TopicCreate` call
declares the exchange itself and the subsequent bind/subscribe succeeds. Scope this call to
the sentinel target specifically (not all four), since the other three targets' owning
services are always present in every deployment shape this fix needs to support.

**Acceptance criterion**: after the fix, call-manager must still receive and process ARI
events end-to-end — verified by confirming an actual call/ARI event flows through in the
clean-room verification (§3), not merely "container does not restart".

**Doc-sync obligation**: this touches `pkg/subscribehandler/main.go`, so
`bin-call-manager/docs/architecture.md` (if it documents the subscribe-target list /
failure behavior) must be updated in the same PR.

### 2.2 monorepo `bin-transcribe-manager` — graceful STT-unavailable degradation

**Chosen approach** (simplified from the Round-1→2 draft per Round-2 feedback that a
separate nil-checking null-object added complexity without benefit): change
`NewStreamingHandler` itself to return a working no-op/disabled implementation of the
`StreamingHandler` interface instead of a bare `nil` when both providers are unavailable —
i.e. add an exported constructor path (e.g. `streaminghandler.NewDisabledStreamingHandler()`,
or fold the disabled case into `NewStreamingHandler`'s existing return so callers never see
a nil sentinel at all). This removes the `streamingHandler == nil` check in
`cmd/transcribe-manager/main.go:144-146` entirely — there is no longer a nil interface for
`runStreaming` or any `transcribehandler` call site to dereference, by construction, not by
adding guards at every call site.

**Defined behavior when STT is disabled**: any transcribe API request that would start
real-time streaming STT returns a clear, documented error (e.g. `STT_NOT_CONFIGURED`) from
the disabled implementation's `Run()`/streaming methods, rather than hanging, panicking, or
silently no-op'ing. Non-streaming transcribe-manager functionality (if any exists
independent of the streaming handler) is unaffected.

**Doc-sync obligation**: `bin-transcribe-manager/CLAUDE.md` currently documents "at least
one provider must be configured at startup" as an intentional invariant. This design
**reverses that invariant** — it must be rewritten in the same PR, along with the
failure-mode section of `docs/operations.md`, to describe the new
degrade-instead-of-crash behavior and the `STT_NOT_CONFIGURED` API error.

### 2.3 sandbox `versions.lock` refresh — sequencing and count reconciliation

**Resolved sequencing**, three explicit phases, run in order:

1. **Phase A (this cycle, first)**: land 2.1 and 2.2 as monorepo PRs, through the standard
   monorepo review loop (CLAUDE.md policy: minimum 3 code-review rounds, until 2 consecutive
   approvals). Verification during this phase does **not** use `docker compose build`
   (sandbox's `docker-compose.yml` has no `build:` stanzas anywhere — every service is a
   digest-pinned `image:` reference, and the Dockerfiles live in the monorepo, not here).
   Instead: build `call-manager` and `transcribe-manager` images directly in the monorepo
   worktree using its own build tooling, tag them locally (e.g.
   `voipbin/bin-call-manager:local-fix`), and apply a `docker-compose.local-fix.yml`
   override (same layering mechanism sandbox already uses for
   `docker-compose.test.yml`: `docker compose -f docker-compose.yml -f
   docker-compose.local-fix.yml up -d`) that replaces just those two services' `image:`
   value with the local tag. This override file is a throwaway verification artifact for
   Phase A, not committed to the sandbox repo.
2. **Phase B (after Phase A merges to monorepo main and CI publishes images at that merge
   commit)**: regenerate `versions.lock` targeting that merge commit (or monorepo HEAD at
   that point, whichever is later — default to HEAD, since the version refresh itself is
   in scope this cycle, not just the two fixed services).
3. **Phase C**: rerun the full clean-room procedure (§3) against the Phase-B `versions.lock`,
   using the registry-pinned images like a real customer install would, confirming the fix
   survives the full pin-and-pull path, not just a local build.

**Count reconciliation (44 services vs. 39 pinned images)**: 44 compose services break down
as 4 third-party-image services (`db`, `redis`, `rabbitmq`, `coredns` — not tracked in
`versions.lock`) + 40 `voipbin`-owned-image services. Those 40 map to 38 *distinct* images,
since the three `asterisk-*-proxy` services share one `voip-asterisk-proxy` image. The 39th
pinned image, `voipbin/bin-sentinel-manager`, corresponds to zero deployed services — it is
still built and tagged in CI (monorepo builds all services, not just the ones sandbox
deploys) and versions.lock has always pinned it defensively even though sandbox doesn't run
it. The generator (below) keeps pinning it: it costs nothing to track, and stops being a
surprise gap the day sandbox does add a lightweight sentinel-manager stub (not this cycle,
§4).

**Reusable generator script**:
- Path: `scripts/generate-versions-lock.sh`.
- Input: a target monorepo git ref (commit SHA or branch), read from an argument (default:
  monorepo's current `main` HEAD via `git ls-remote`/local checkout).
- Process: for each of the 39 `voipbin/*` images currently tracked in `versions.lock`,
  resolve the nearest registry tag at-or-before the target commit (mirroring how the
  original ancestry pin was built for da0c1cd), pull it, record its resolved sha256 digest
  and source git commit SHA.
- Output: a regenerated `versions.lock` with the same schema as today's (`target_commit`,
  `images`, `image_source_tags`, plus a new `generated_by: scripts/generate-versions-lock.sh`
  field so a hand-edited lock is visually distinguishable from a generated one going
  forward).
- Fallback behavior: if a service has no registry tag at or before the target commit, keep
  that service's current pinned digest unchanged and print an explicit warning line — never
  silently pin to an unrelated/newer tag.
- Idempotency: running it twice against the same target with no new merges produces a
  byte-identical `versions.lock` (excluding a `generated` timestamp field).
- Out of scope for this cycle: wiring this into CI as an automatic drift-detector. Worth
  doing later; not blocking this fix.

### 2.4 sandbox dummy GCP credential — explicit non-goal, not silently dropped

This cycle does **not** change the dummy credential's shape/validity. The fix in §2.2 makes
transcribe-manager tolerate it (and any other absent/invalid STT credential) without
crashing, which is the actual requirement — a real self-hoster who wants working STT still
needs to supply real credentials via `.env`, same as today. api-manager and rag-manager
already tolerate the dummy credential (§1) and need no change.

### 2.5 sandbox `.env.template` sync — concrete, resolvable spec

Per-variable resolution, three categories:
- **Add to template** (generated by `init.sh` today but undocumented): `BASE_HOSTNAME`,
  `API_URL`, `WEBSOCKET_URL`, `REGISTRAR_URL`, `REGISTRAR_DOMAIN`, `CONFERENCE_URL`,
  `CONFERENCE_DOMAIN` — document with their actual generated defaults (from `CLAUDE.md`'s
  own table, which already has correct values).
- **Keep in template, annotate as compose-internal-default** (documented today, not written
  by `init.sh`, but genuinely consumed via `${VAR:-default}` in `docker-compose.yml` with a
  matching default — verified line-by-line for each): `DB_HOST`/`DB_PORT`
  (docker-compose.yml:379), `REDIS_HOST`/`REDIS_PORT` (:458-460), `RABBITMQ_HOST`/`RABBITMQ_PORT`
  (:129, :131-132), `KAMAILIO_DB_HOST`/`KAMAILIO_REDIS_HOST` (:183, :196),
  `RTPENGINE_PORT_MIN`/`RTPENGINE_PORT_MAX` (:287, :292),
  `RTPENGINE_LISTEN_HTTP` (:129). Add a one-line comment next to each: "compose default is
  used unless you override this — see Track A externalization,
  `docs/plans/2026-07-05-production-grade-horizontal-scale-design.md`, for the multi-host
  case."
- **Mark dead, do not imply overridable**: `RTPENGINE_INTERFACE`. `.env.template:76`
  documents `RTPENGINE_INTERFACE=any`, but `docker-compose.yml:128` sets it unconditionally
  to `pub/${RTPENGINE_EXTERNAL_IP:-127.0.0.1};priv/10.100.0.201` — not a `${VAR:-default}`
  read, a hard override. Setting `RTPENGINE_INTERFACE` in `.env` has no effect today.
  Either delete the line from the template or mark it explicitly
  `# currently ignored — docker-compose.yml hardcodes this from RTPENGINE_EXTERNAL_IP`, so
  the template never documents a control path that doesn't exist.
- **Drift check**: add `scripts/check-env-template-sync.sh`, run manually for now (CI
  wiring out of scope, same as §2.3's generator) — greps `init.sh`'s `.env`
  heredoc/write calls for variable names, greps `.env.template` for documented variable
  names, and prints any variable present in one but not the other, exit non-zero if any
  found (excluding the compose-internal-default and dead-var sets above, which are
  intentionally template-only or template-stale by design, not drift).

## 3. Verification plan

**Phase A verification (locally-built images via override file, §2.3):**
- Build `call-manager` and `transcribe-manager` from the fix branch in the monorepo
  worktree, tag locally, apply `docker-compose.local-fix.yml` in the clean-room
  `docker compose up -d` run per §2.3.
- Confirm `voipbin-call-mgr` and `sandbox-transcribe-manager-1` reach a running,
  non-restarting state.
- **Confirm call-manager still processes ARI events** — drive a test call or synthetic ARI
  event through and confirm call-manager's logs show it consumed from the
  asterisk-event-all queue, satisfying §2.1's acceptance criterion.
- **Confirm transcribe-manager's disabled-STT behavior is correct** — issue a
  transcribe-start API request against it with the dummy credential in place and confirm it
  returns the defined `STT_NOT_CONFIGURED`-class error rather than hanging, panicking, or
  silently no-op'ing.
- Rerun `setup_test_customer.sh`, confirm no regression.

**Phase C verification (registry-pinned images, §2.3, after monorepo merge + versions.lock
refresh):**
- Full clean-room procedure (infra → migration → full `docker compose up -d`) against the
  refreshed `versions.lock`.
- **Pass criterion**: only `voipbin-kamailio` and `voipbin-dns` are down, both attributable
  solely to the sudo-gated setup not having run in this session (§1, §6) — not "zero
  containers down", which is unachievable without sudo.
- Confirm image pulls succeed for all 39 pinned images at the new target commit (including
  `bin-sentinel-manager`, per §2.3's count reconciliation); any fallback-pin exceptions are
  documented in the regenerated `versions.lock` and called out explicitly in the PR
  description, not buried.

Deferred, sudo-gated verification: see §6.

## 4. Non-goals

- Not implementing `sentinel-manager` itself in sandbox — it remains an intentional,
  documented Kubernetes-only exclusion. (§2.3 keeps pinning its image defensively, which is
  not the same as deploying it.)
- Not changing the dummy GCP credential's content/validity (§2.4).
- Not fixing `timeline-manager`'s ClickHouse-dependent functionality or its healthcheck
  blind spot (§1) — flagged, not silently dropped, but out of scope this cycle.
- Not touching secrets storage — plaintext `.env` stays as-is (decided this cycle: the
  meaningful risk is backup-archive exposure, out of scope here).
- Track A (horizontal-scale enablement) is already complete and out of scope.
- Not a general Track B (install-parity hardening: TLS lifecycle, scheduled backup,
  monitoring stack, public DNS) — that remains a separate, not-yet-started body of work.
- Not wiring §2.3's generator or §2.5's drift check into CI as an automated recurring job —
  both ship as manually-invoked scripts this cycle; CI automation is explicitly future work.

## 5. Risks

- **R1 — production behavior regression from making sentinel-subscribe non-fatal.** In a
  real Kubernetes deployment where sentinel-manager legitimately should be running, the
  `TopicCreate`-before-subscribe fix (§2.1) means a genuine sentinel-manager outage or
  misconfiguration now starts call-manager successfully instead of crash-looping loudly —
  `EventSMPodDeleted`-driven pod-recovery (`bin-call-manager/pkg/callhandler/event.go:85`)
  would silently stop working with no crash to signal it. **Mitigation is honestly
  limited**: `ExchangeDeclare`/`TopicCreate` is idempotent and returns no
  created-vs-already-existed signal, so call-manager cannot distinguish "sentinel-manager
  is up and already declared this" from "I just declared it because nobody else did" at
  declare time — the metric/warn-log mitigation floated in an earlier draft of this
  document is not implementable on that signal and is withdrawn. The workable mitigation is
  a runtime liveness signal instead of a declare-time one: track a
  last-sentinel-event-received timestamp and expose it as a gauge/health field, so an
  operator who expects sentinel events can alert on "no sentinel event in N minutes" — this
  is a monorepo-PR-scope addition to consider, not blocking sandbox's fix from shipping if
  deferred. Same shape applies to §2.2: the `STT_NOT_CONFIGURED` API-level error is the
  primary mitigation for callers, but there is no standing "STT is disabled" health/metric
  signal for an operator who isn't actively calling the API.
- **R2 — version refresh safety is not the same claim as "drift didn't cause this bug".**
  §1 shows the 5-month drift did not cause the two bugs fixed here. It does not show that
  bumping 39 images across 5 months of monorepo history is itself risk-free. Phase C's
  verification (§3) only checks for crash loops and the customer-bootstrap flow; it does
  not exercise real SIP/call flow (deferred, §6). The refresh can plausibly introduce
  breakage that this verification cannot detect until the deferred sudo-gated pass runs.
- **R3 — rollback plan.** If Phase C's refreshed `versions.lock` regresses something:
  `git revert` the versions.lock commit restores the Feb-21 pin immediately (sandbox side,
  no dependency on anything else). If either monorepo fix (2.1/2.2) regresses something
  post-merge: standard monorepo PR revert; since Phase B's `versions.lock` refresh depends
  on Phase A having merged, reverting a Phase-A monorepo PR after Phase B already shipped a
  lock pointing past it would require re-running Phase B's generator against the pre-revert
  commit as well — call this out explicitly in the Phase-B PR description so it isn't a
  surprise later.
- **R4 — hypothesis, not confirmed diagnosis.** We do not have the customer's logs. This
  fix addresses the most severe, 100%-reproducible failure found, which is a strong
  candidate, not a confirmed match to the specific customer report.

## 6. Deferred verification (sudo-gated, end of this cycle)

Requires an interactive `sudo` password, not available in the session that produced this
design and its reproduction (§0, §1) — requires pchero to run directly or supply results
from:

- Full `sudo ./scripts/start.sh` (mkcert CA, DNS forwarding, VoIP macvlan network).
- Real SIP registration / call flow (`softphone.py`, `test_call.py`).
- Browser-based admin/talk/meet UI check.

Until this runs, "fixed" in §3 means "no unexplained crash loops observed, ARI events and
STT-disabled behavior verified" — it does not mean "verified working for real SIP calls"
(also noted in R2 above). This gap is explicit, not hidden.
