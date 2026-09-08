# Safety Model

RecoveryGuard is designed to fail closed.

## Automatic recovery is allowed only when

- the target queue has been reviewed
- the queue fingerprint matches the approved queue
- the engine fingerprint matches the approved engine
- the SharePoint site matches the approved site
- the write gate is armed
- the destination lookup is healthy
- the destination is unoccupied

## Automatic recovery must stop when

- authentication is invalid
- DNS/TCP/SharePoint health is unstable
- the state store cannot be written reliably
- a post-invocation result is ambiguous
- the reconciliation observations disagree
- the queue/engine hash changes
- a second Supervisor is detected
- an unexplained inflight record exists

## Conflict is not failure

An occupied destination is a protected outcome. The framework does not overwrite, delete, rename, or displace the existing object automatically.
