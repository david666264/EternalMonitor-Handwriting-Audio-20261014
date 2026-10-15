# Windows playback output during an iPad audio session

When Windows uses a silent virtual speaker as its default playback device,
loopback capture can send sound to the iPad without also playing it on the PC.
That device must only remain selected while the audio session is active.

The Windows host now supports an optional temporary playback route. It reads
`audio-output-route.json` from the same per-user directory as `settings.json`:

```json
{
  "target_render_id": "<virtual playback endpoint ID>",
  "roles": ["Console", "Multimedia"]
}
```

Endpoint IDs are machine-specific. Keep this configuration on the PC and never
copy it into source control. Start with the user's ordinary speaker or
headphones selected. Without this file, the host preserves its original audio
behavior and does not change playback defaults.

Before changing either playback role, the host snapshots both original outputs
and writes a recovery journal. The audio session then uses the virtual output.
Disconnecting the iPad, stopping streaming, disabling PC audio, or exiting the
host restores each original role. The explicit exit handler runs before the
program's final `process::exit`, which skips ordinary destructors.

The host changes no input endpoint, volume, or mute flag. The Communications
playback role stays unchanged unless explicitly listed in `roles`. If the user
selects another output during a session, automatic restoration respects that
choice, including video pipeline restarts in that same iPad session. A new
client audio session can acquire a new lease. If an original device is unavailable, the recovery journal remains so
restoration can be retried when it returns. An interrupted process is recovered
on the next host startup; another running host's journal is not taken over.

An older manual setup has no saved lease. First select the user's ordinary
speaker or headphones, then configure the virtual target. The host never
guesses or overwrites a manually selected virtual output without a journal.

Regression tests cover disconnect and explicit exit, independent role defaults,
Windows linking Console and Multimedia roles, manual user changes, missing
devices, failed journal writes, partial policy failures, stale audio-generation
leases, and recovery ownership. Windows uses its policy COM interface to change
playback defaults; if the OS rejects that interface, routing fails safely and
the ordinary current-output capture path remains available.
