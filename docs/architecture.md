# Architecture

## Core control plane

RecoveryGuard uses a Supervisor/Worker model.

**Supervisor**
- owns process lifecycle
- runs bounded health probes
- detects stalled workers
- kills only the stalled worker, not the entire orchestration session
- requires reconciliation before retrying uncertain work

**Worker**
- processes one queue item at a time
- performs a strict destination lookup before any restore
- writes heartbeat and inflight state
- invokes the exact recycle-bin GUID
- persists a terminal result before advancing the checkpoint

**Probe**
- checks dependencies independently of the worker
- can validate DNS, TCP 443, SharePoint access, state-store I/O, and optional database connectivity

**Reconciler**
- independently observes recycle-bin state and destination state
- distinguishes committed, not committed, conflict, and unresolved outcomes

**Monitor**
- read-only
- tolerates transient file locks
- shows checkpoint, heartbeat, health, process liveness, results, and last event

## State machine

```text
QUEUE ITEM
  |
  +--> strict destination lookup
          |
          +--> exists ----------> CONFLICT / no write
          |
          +--> lookup error ----> ABORT BEFORE RESTORE
          |
          +--> absent
                  |
                  +--> restore exact GUID
                           |
                           +--> success ------> RESTORED
                           |
                           +--> ambiguous infrastructure outcome
                                      |
                                      +--> reconcile both sides
                                              |
                                              +--> recycle absent + destination exists
                                              |       -> COMMITTED
                                              |
                                              +--> recycle present + destination absent
                                              |       -> SAFE TO RETRY
                                              |
                                              +--> recycle present + destination exists
                                              |       -> CONFLICT
                                              |
                                              +--> unstable/unknown
                                                      -> HUMAN REVIEW
```

## Write gate

Production writes require two independent conditions:

1. `Safety.WriteEnabled = true`
2. a valid arm file that binds the reviewed queue and engine to the target environment

The arm binds the engine SHA-256, queue SHA-256, queue count, sequence range, first GUID, site URL, program version, client ID, and incident population.
