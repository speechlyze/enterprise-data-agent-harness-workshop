# Part 8: Identity-Aware Authorization with DDS

By default the agent sees every row and column the `AGENT` DB user has been granted — it inherits the database user'''s privileges, period. **Real deployments need the trust boundary to follow the human in the loop**, not the DB user the agent runs as. A jailbroken prompt that gets the model to issue `SELECT * FROM SUPPLYCHAIN.cargo_items` should still come back filtered for the operator.

**Oracle Deep Data Security (DDS)** in Oracle AI Database 26ai moves that boundary into the database kernel. You declare row, column, and cell-level rules in **declarative SQL**, and the engine enforces them transparently — no matter what SQL the agent constructs.

```
end_user (real human or upstream caller)
       │  identity propagated via DBMS_SESSION.SET_CONTEXT
       ▼
AGENT (database user)  ──── DDS policies evaluated by kernel ────▶ rows/cols filtered before tool sees them
```

The agent doesn'''t decide what it can see — the database does.

## What We'''re Demoing

Two end-users on the `SUPPLYCHAIN` schema:

| End-user | Authorized oceans | Clearance | Should see |
|---|---|---|---|
| `apac.fleet@acme.com` | PACIFIC + INDIAN | STANDARD | only voyages in those oceans; `unit_value_cents` masked to `NULL` |
| `cfo@acme.com` | ALL | EXECUTIVE | every voyage; declared cargo values visible |

Three policies on `SUPPLYCHAIN`:

1. **Row policy** on `voyages` — only rows whose `ocean_region` is in the user'''s authorized oceans.
2. **Column policy** on `cargo_items` — `unit_value_cents` is hidden (returned as `NULL`) unless clearance is `EXECUTIVE`.
3. **Legacy bypass** — when `EDA_CTX.END_USER` is `NULL`, all rows/columns are visible. This keeps the §5 demos working unchanged.

## What'''s Pre-Built

Everything except the demo. The setup cell creates:

- **`AGENT.agent_authorizations`** — `(end_user, auth_region)` rows. Maersk EMEA fleet manager is authorized for ATLANTIC + MEDITERRANEAN; CFO is authorized for `ALL`.
- **`AGENT.agent_clearances`** — `(end_user, clearance)` rows. STANDARD or EXECUTIVE.
- **`EDA_CTX` namespace** — bound to a procedure `AGENT.set_eda_ctx(end_user, clearance)`. Only that procedure can write to the namespace, so a hostile agent can'''t `SET_CONTEXT` itself an executive clearance.
- **Row policy on `voyages.ocean_region`** — checks `EDA_CTX.END_USER` against `agent_authorizations`.
- **Column mask on `cargo_items.unit_value_cents`** — returns `NULL` unless clearance is `EXECUTIVE`.

The notebook tries the declarative `CREATE DATA SECURITY POLICY` syntax first; if the running image doesn'''t ship that surface yet, it falls back to `DBMS_RLS` — the kernel-level row/column security mechanism that DDS layers on top of. The semantics are identical.

## Identity Propagation

```
END-USER picks persona in app:  "Use As: cfo@acme.com"
       │
       ▼
APPLICATION  → agent_turn(end_user="cfo@acme.com", clearance="EXECUTIVE", …)
       │
       ▼
AGENT (calls set_eda_ctx() at the start of the turn)
       │
       ▼
ORACLE KERNEL: SYS_CONTEXT('"'"'EDA_CTX'"'"', '"'"'END_USER'"'"') = '"'"'cfo@acme.com'"'"'
                SYS_CONTEXT('"'"'EDA_CTX'"'"', '"'"'CLEARANCE'"'"') = '"'"'EXECUTIVE'"'"'
       │
       ▼
Every SELECT in this session is rewritten by the kernel to apply the row policy + column mask.
       │
       ▼
tool_run_sql receives the filtered result set. Same prompt, same generated SQL, *different* result per identity.
```

## How `agent_turn` Wraps This Up

The pre-built version of `agent_turn` (re-defined in §6 of the notebook) takes two extra parameters:

```python
def agent_turn(user_query: str, thread_id: str = "default",
               max_iterations: int = 8, budget_seconds: float = 360.0,
               verbose: bool = True,
               end_user: str | None = None,
               clearance: str | None = None) -> str:
    """As before, plus per-turn identity propagation into Oracle DDS via EDA_CTX."""
    set_identity(end_user, clearance)
    if verbose and end_user:
        print(f"  [identity: end_user={end_user!r} clearance={clearance!r}]")
    try:
        return _prior_agent_turn(user_query, thread_id=thread_id, ...)
    finally:
        set_identity(None)  # don'''t leak identity to the next caller
```

`set_identity(end_user, clearance)` calls `AGENT.set_eda_ctx(end_user, clearance)` via PL/SQL, which writes to the `EDA_CTX` namespace. The `try/finally` ensures the identity is cleared even if the loop raises — no identity bleed across calls.

## The two-identity demo (just run)

Ask the same natural-language question as the **CFO** (sees all oceans, executive clearance) and as the **APAC fleet manager** (Pacific + Indian only, no cargo values). The agent constructs whatever SQL it likes; the database filters it.

The question:

```python
q = ("How many voyages do we have in each ocean region, and what'''s the total "
     "declared cargo value (in USD) currently in transit?")
```

**Solution:**

```python
dds_thread_cfo  = "demo-dds-cfo"
dds_thread_apac = "demo-dds-apac"

print("=" * 70)
print("ASKED AS CFO (clearance=EXECUTIVE, regions=ALL)")
print("=" * 70)
print(agent_turn(q, thread_id=dds_thread_cfo,
                 end_user="cfo@acme.com", clearance="EXECUTIVE"))

print("\n" + "=" * 70)
print("ASKED AS APAC fleet (clearance=STANDARD, regions=PACIFIC+INDIAN)")
print("=" * 70)
print(agent_turn(q, thread_id=dds_thread_apac,
                 end_user="apac.fleet@acme.com", clearance="STANDARD"))
```

Compare the answers. The CFO sees four ocean regions and a real dollar total. The APAC fleet manager sees only PACIFIC + INDIAN, and the cargo-value column comes back masked — the agent will note in its answer that it can'''t compute the total because the values are `NULL`.

The agent code is **identical** between the two calls. Only the `end_user` parameter changes. Authorization stops being an application-layer concern.

## Same SQL, Two Identities — The Probe

The notebook also runs a `probe()` helper that bypasses the agent entirely and runs raw SQL under each identity:

```python
probe("CEO sees all oceans", "ceo@acme.com", "EXECUTIVE",
      "SELECT ocean_region, COUNT(*) FROM SUPPLYCHAIN.voyages GROUP BY ocean_region")
probe("APAC fleet sees PACIFIC + INDIAN only", "apac.fleet@acme.com", "STANDARD",
      "SELECT ocean_region, COUNT(*) FROM SUPPLYCHAIN.voyages GROUP BY ocean_region")
```

This proves DDS is doing the work in the kernel — not in some Python pre-filter — because the same `SELECT` text returns different rows depending only on `EDA_CTX.END_USER`.

## Key Takeaways — Part 8

- **Move the trust boundary into the kernel.** A jailbroken prompt that synthesizes `SELECT * FROM cargo_items` should still come back filtered for the *human* in the loop — not the AGENT DB user. The agent doesn'''t decide what it can see; the database does.
- **Identity propagates via application context.** `DBMS_SESSION.SET_CONTEXT('"'"'EDA_CTX'"'"', '"'"'END_USER'"'"', ...)` is the single channel. DDS / DBMS_RLS row policies read from it on every query, transparently to the agent code.
- **TRUSTED PROCEDURE clause prevents self-elevation.** Only `AGENT.set_eda_ctx` can write to `EDA_CTX`. The agent can'''t bypass DDS by calling `DBMS_SESSION.SET_CONTEXT` from inside a tool — the namespace rejects writes from any other procedure.
- **Same SQL, two identities, different rows.** Persona changes outside the agent; the agent code is unchanged. Authorization stops being an application-layer concern.

## Troubleshooting

**`ORA-00900` / `ORA-00901` / `ORA-02000` on `CREATE DATA SECURITY POLICY`** — Your Oracle image predates the declarative DDS surface. The notebook automatically falls back to `DBMS_RLS` — same semantics, harder to read. Confirm with `SELECT BANNER_FULL FROM v$version`.

**Both identities return the same rows** — Check that `set_identity` actually wrote to `EDA_CTX`:

```python
with agent_conn.cursor() as cur:
    cur.execute("SELECT SYS_CONTEXT('"'"'EDA_CTX'"'"', '"'"'END_USER'"'"'), SYS_CONTEXT('"'"'EDA_CTX'"'"', '"'"'CLEARANCE'"'"') FROM dual")
    print(cur.fetchone())
```

If both come back `None`, the procedure call failed silently. Re-run the §6 setup cell.

**APAC fleet sees `unit_value_cents` values, not `NULL`** — The column policy didn'''t apply. Check `DDS_AVAILABLE` is `True` after the policy-creation cell. If it'''s `False`, neither path (declarative or `DBMS_RLS`) succeeded; check the cell'''s output for the underlying error.
