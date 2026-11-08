# Skland device state

This is the technical contract for the profile-owned Skland device state. The normal setup remains token-only; users do not need to create this state manually.

## Configuration shape

After a successful local run, a Skland profile may contain managed state like this:

```json
{
    "platform": "skland",
    "console_name": "skland-main",
    "token": "...",
    "device": {
        "id": "B...",
        "seed": "..."
    }
}
```

`device.id` is the fast path: when it exists, the script uses it directly and does not call the Shumei device-profile service. `device.seed` is persistent recovery material. It deterministically rebuilds the synthetic fingerprint identity material, but it does not calculate a dId locally; the dId returned by Shumei remains authoritative.

## State transitions

| `device.id` | `device.seed` | Behavior |
|---|---|---|
| Present | Present | Use the configured dId directly. |
| Present | Missing | Use the configured dId directly. Recovery is unavailable if the dId later becomes invalid. |
| Missing | Present | Warn, rebuild the fingerprint from the seed, register with Shumei, and continue with the returned dId. |
| Missing | Missing, local run | Generate a seed, register the device, and save both `id` and `seed` to `sign.json`. |
| Missing | Missing, GitHub Actions | Fail before creating an ephemeral device. Provision the state locally first. |

The state is owned by the profile. Profiles are cached independently unless they explicitly opt into a shared `device_ref`.

## Recovery of a rejected dId

When Skland explicitly rejects a configured dId and the profile still has a seed, the script:

1. Rebuilds the synthetic fingerprint identity from the seed.
2. Registers it with Shumei.
3. Uses the returned dId as a replacement.
4. Retries authentication once.
5. Persists the replacement state when the configuration source is writable.

The implementation only treats an auth failure as device recovery when its message explicitly identifies a device, dId, or fingerprint rejection. Generic token, timestamp, and other auth errors remain failures.

## Automated runners

A runner with `device.seed` but no `device.id` can recover for the current run. The runner may be able to modify its temporary `sign.json`, but it cannot update the source `CHECK_SECRET` automatically. Run locally once and update the stored configuration to avoid re-registration.

If both `device.id` and `device.seed` are absent in GitHub Actions, the script refuses to create a new random device because that identity would not survive the next run.

Keep the local configuration file writable so the first-run state and replacement dIds can be saved.
