//! A temporary lease on Windows playback defaults. No volume, mute or capture
//! endpoint is changed. Routing is opt-in through a local configuration file.

use serde::{Deserialize, Serialize};

#[cfg(windows)]
#[path = "output_route_windows.rs"]
mod native;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum RenderRole {
    Console,
    Multimedia,
    Communications,
}

fn default_roles() -> Vec<RenderRole> {
    vec![RenderRole::Console, RenderRole::Multimedia]
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RouteConfig {
    pub target_render_id: String,
    #[serde(default = "default_roles")]
    pub roles: Vec<RenderRole>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RoleOutput {
    pub role: RenderRole,
    pub device_id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct Journal {
    owner_pid: u32,
    target_render_id: String,
    previous: Vec<RoleOutput>,
}

trait Backend {
    fn config(&mut self) -> Result<Option<RouteConfig>, String>;
    fn journal(&mut self) -> Result<Option<Journal>, String>;
    fn save(&mut self, journal: Option<&Journal>) -> Result<(), String>;
    fn current(&mut self, role: RenderRole) -> Result<String, String>;
    fn available(&mut self, id: &str) -> Result<bool, String>;
    fn set_default(&mut self, role: RenderRole, id: &str) -> Result<(), String>;
    fn foreign_owner_running(&mut self, pid: u32) -> bool;
}

struct Manager<B> {
    backend: B,
    next_token: u64,
    active: Option<(u64, Journal)>,
    active_session: Option<u32>,
    user_overrode_session: Option<u32>,
}

impl<B: Backend> Manager<B> {
    fn new(backend: B) -> Self {
        Self { backend, next_token: 0, active: None, active_session: None, user_overrode_session: None }
    }

    /// Restore only defaults still pointing at our target. A user choosing a
    /// different output during a session always wins. Keep a failed restore in
    /// the journal so the next startup can retry when the device returns.
    fn restore(&mut self, mut journal: Journal) -> Result<(), String> {
        let mut pending = Vec::new();
        let mut failure = None;
        // Snapshot every role before the first write. Windows can link default
        // roles together, so reading role B after changing A can otherwise
        // mistake our own write for a user's deliberate output selection.
        let current: Vec<_> = journal.previous.iter()
            .map(|previous| self.backend.current(previous.role)).collect();
        for (previous, current) in journal.previous.into_iter().zip(current) {
            let result = (|| {
                if current? != journal.target_render_id {
                    return Ok(());
                }
                if !self.backend.available(&previous.device_id)? {
                    return Err("Original playback output is unavailable".into());
                }
                self.backend.set_default(previous.role, &previous.device_id)
            })();
            if let Err(error) = result {
                pending.push(previous);
                failure = Some(error);
            }
        }
        journal.previous = pending;
        self.backend.save(if journal.previous.is_empty() { None } else { Some(&journal) })?;
        failure.map_or(Ok(()), Err)
    }

    fn recover(&mut self) -> Result<(), String> {
        if let Some(journal) = self.backend.journal()? {
            if self.backend.foreign_owner_running(journal.owner_pid) {
                return Err("Another host owns the playback route".into());
            }
            return self.restore(journal);
        }
        Ok(())
    }

    fn acquire(&mut self, session_id: u32) -> Result<Option<u64>, String> {
        if self.user_overrode_session == Some(session_id) { return Ok(None); }
        self.user_overrode_session = None;
        let Some(config) = self.backend.config()? else { return Ok(None); };
        if !self.backend.available(&config.target_render_id)? {
            return Err("Configured playback output is unavailable".into());
        }
        let old = self.active.as_ref().map(|(_, journal)| journal.clone())
            .or(self.backend.journal()?);
        if old.as_ref().is_some_and(|j| self.backend.foreign_owner_running(j.owner_pid)) {
            return Err("Another host owns the playback route".into());
        }
        if old.as_ref().is_some_and(|j| j.target_render_id != config.target_render_id) {
            return Err("A previous playback route still needs restoration".into());
        }
        let mut previous = Vec::new();
        for role in config.roles {
            if previous.iter().any(|entry: &RoleOutput| entry.role == role) { continue; }
            let current = self.backend.current(role)?;
            let original = if current == config.target_render_id {
                old.as_ref().filter(|j| j.target_render_id == config.target_render_id)
                    .and_then(|j| j.previous.iter().find(|p| p.role == role))
                    .map(|p| p.device_id.clone())
            } else { Some(current) };
            if let Some(device_id) = original.filter(|id| id != &config.target_render_id) {
                if !self.backend.available(&device_id)? {
                    return Err("Original playback output is unavailable".into());
                }
                previous.push(RoleOutput { role, device_id });
            }
        }
        if previous.is_empty() { return Ok(None); }
        let journal = Journal {
            owner_pid: std::process::id(),
            target_render_id: config.target_render_id,
            previous,
        };
        // Persist before the first OS mutation, so a crash during even a
        // partially successful role switch is recoverable.
        self.backend.save(Some(&journal))?;
        for previous in &journal.previous {
            if let Err(error) = self.backend.set_default(previous.role, &journal.target_render_id) {
                self.active = None;
                let _ = self.restore(journal);
                return Err(error);
            }
        }
        self.next_token += 1;
        self.active = Some((self.next_token, journal));
        self.active_session = Some(session_id);
        Ok(Some(self.next_token))
    }

    fn release(&mut self, token: u64) -> Result<(), String> {
        if self.active.as_ref().is_some_and(|(active, _)| *active == token) {
            let (_, journal) = self.active.take().unwrap();
            if journal.previous.iter().any(|previous| self.backend.current(previous.role)
                .is_ok_and(|current| current != journal.target_render_id)) {
                // Video generations can restart without a new iPad handshake.
                // Do not reclaim an output the user changed during that same
                // audio session when its replacement generation opens WASAPI.
                self.user_overrode_session = self.active_session;
            }
            self.active_session = None;
            self.restore(journal)?;
        }
        Ok(())
    }

    fn shutdown(&mut self) -> Result<(), String> {
        if let Some((_, journal)) = self.active.take() {
            self.restore(journal)
        } else if let Some(journal) = self.backend.journal()? {
            if self.backend.foreign_owner_running(journal.owner_pid) {
                return Err("Another host owns the playback route".into());
            }
            self.restore(journal)
        } else { Ok(()) }
    }
}

pub struct OutputRouteLease {
    #[cfg(windows)]
    token: Option<u64>,
}

impl Default for OutputRouteLease {
    fn default() -> Self {
        Self {
            #[cfg(windows)]
            token: None,
        }
    }
}

impl OutputRouteLease {
    pub fn acquire(_session_id: u32) -> Self {
        #[cfg(windows)]
        return Self { token: native::acquire(_session_id) };
        #[cfg(not(windows))]
        Self {}
    }
}

impl Drop for OutputRouteLease {
    fn drop(&mut self) {
        #[cfg(windows)]
        if let Some(token) = self.token.take() { native::release(token); }
    }
}

pub fn recover_previous_run() {
    #[cfg(windows)]
    native::recover();
}

/// Explicitly called before process::exit, which deliberately skips Drop.
pub fn restore_before_exit() {
    #[cfg(windows)]
    native::shutdown();
}

/// Panic cleanup cannot wait for a route lock the panicking thread may own.
pub fn restore_after_panic() {
    #[cfg(windows)]
    native::panic_cleanup();
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Fake {
        config: Option<RouteConfig>, journal: Option<Journal>, outputs: Vec<RoleOutput>,
        writes: usize, switches: usize, fail_save: bool, absent: Vec<String>, foreign: bool,
        link_multimedia: bool, fail_role_once: Option<RenderRole>,
    }
    impl Default for Fake {
        fn default() -> Self {
            Self {
                config: Some(RouteConfig { target_render_id: "virtual".into(), roles: default_roles() }),
                journal: None,
                outputs: vec![RoleOutput { role: RenderRole::Console, device_id: "speaker".into() },
                    RoleOutput { role: RenderRole::Multimedia, device_id: "headphones".into() },
                    RoleOutput { role: RenderRole::Communications, device_id: "call-speaker".into() }],
                writes: 0, switches: 0, fail_save: false, absent: vec![], foreign: false,
                link_multimedia: false, fail_role_once: None,
            }
        }
    }
    impl Backend for Fake {
        fn config(&mut self) -> Result<Option<RouteConfig>, String> { Ok(self.config.clone()) }
        fn journal(&mut self) -> Result<Option<Journal>, String> { Ok(self.journal.clone()) }
        fn save(&mut self, journal: Option<&Journal>) -> Result<(), String> {
            if self.fail_save { return Err("disk full".into()); }
            self.writes += 1; self.journal = journal.cloned(); Ok(())
        }
        fn current(&mut self, role: RenderRole) -> Result<String, String> {
            Ok(self.outputs.iter().find(|p| p.role == role).unwrap().device_id.clone())
        }
        fn available(&mut self, id: &str) -> Result<bool, String> { Ok(!self.absent.iter().any(|a| a == id)) }
        fn set_default(&mut self, role: RenderRole, id: &str) -> Result<(), String> {
            assert!(self.writes > 0, "must persist recovery before changing Windows");
            if self.fail_role_once == Some(role) {
                self.fail_role_once = None;
                return Err("policy failure".into());
            }
            self.switches += 1;
            self.outputs.iter_mut().find(|p| p.role == role).unwrap().device_id = id.into();
            if self.link_multimedia && role == RenderRole::Console {
                self.outputs.iter_mut().find(|p| p.role == RenderRole::Multimedia).unwrap().device_id = id.into();
            }
            Ok(())
        }
        fn foreign_owner_running(&mut self, _pid: u32) -> bool { self.foreign }
    }
    #[test]
    fn disconnect_restores_each_original_role_without_touching_communications() {
        let mut manager = Manager::new(Fake::default());
        let original = manager.backend.outputs.clone();
        let token = manager.acquire(11).unwrap().unwrap();
        assert_eq!(manager.backend.current(RenderRole::Console).unwrap(), "virtual");
        assert_eq!(manager.backend.current(RenderRole::Communications).unwrap(), "call-speaker");
        manager.release(token).unwrap();
        assert_eq!(manager.backend.outputs, original);
        assert!(manager.backend.journal.is_none());
    }
    #[test]
    fn explicit_exit_restores_even_without_dropping_the_audio_stage() {
        let mut manager = Manager::new(Fake::default());
        let token = manager.acquire(11).unwrap().unwrap();
        manager.shutdown().unwrap();
        manager.release(token).unwrap();
        assert_eq!(manager.backend.current(RenderRole::Console).unwrap(), "speaker");
        assert_eq!(manager.backend.switches, 4);
    }
    #[test]
    fn manual_output_change_wins_over_automatic_restoration() {
        let mut manager = Manager::new(Fake::default());
        let token = manager.acquire(11).unwrap().unwrap();
        manager.backend.set_default(RenderRole::Console, "user-speaker").unwrap();
        manager.release(token).unwrap();
        assert_eq!(manager.backend.current(RenderRole::Console).unwrap(), "user-speaker");
        assert_eq!(manager.backend.current(RenderRole::Multimedia).unwrap(), "headphones");
    }
    #[test]
    fn video_generation_restart_cannot_reclaim_a_user_overridden_session() {
        let mut manager = Manager::new(Fake::default());
        let token = manager.acquire(11).unwrap().unwrap();
        manager.backend.set_default(RenderRole::Console, "user-speaker").unwrap();
        manager.release(token).unwrap();
        assert!(manager.acquire(11).unwrap().is_none());
        assert_eq!(manager.backend.current(RenderRole::Console).unwrap(), "user-speaker");
        let next = manager.acquire(12).unwrap().unwrap();
        assert_eq!(manager.backend.current(RenderRole::Console).unwrap(), "virtual");
        manager.release(next).unwrap();
        assert_eq!(manager.backend.current(RenderRole::Console).unwrap(), "user-speaker");
    }
    #[test]
    fn disk_failure_prevents_any_route_change() {
        let mut manager = Manager::new(Fake { fail_save: true, ..Fake::default() });
        assert!(manager.acquire(11).is_err());
        assert_eq!(manager.backend.switches, 0);
    }
    #[test]
    fn missing_original_device_keeps_recovery_journal_until_it_returns() {
        let mut manager = Manager::new(Fake::default());
        let token = manager.acquire(11).unwrap().unwrap();
        manager.backend.absent.push("speaker".into());
        assert!(manager.release(token).is_err());
        assert_eq!(manager.backend.journal.as_ref().unwrap().previous.len(), 1);
        manager.backend.absent.clear();
        manager.recover().unwrap();
        assert_eq!(manager.backend.current(RenderRole::Console).unwrap(), "speaker");
        assert!(manager.backend.journal.is_none());
    }
    #[test]
    fn stale_generation_cannot_release_a_newer_lease() {
        let mut manager = Manager::new(Fake::default());
        let old = manager.acquire(11).unwrap().unwrap();
        let new = manager.acquire(11).unwrap().unwrap();
        manager.release(old).unwrap();
        assert_eq!(manager.backend.current(RenderRole::Console).unwrap(), "virtual");
        manager.release(new).unwrap();
        assert_eq!(manager.backend.current(RenderRole::Console).unwrap(), "speaker");
    }
    #[test]
    fn no_configuration_does_not_change_defaults() {
        let mut manager = Manager::new(Fake { config: None, ..Fake::default() });
        manager.recover().unwrap();
        assert!(manager.acquire(11).unwrap().is_none());
        assert_eq!(manager.backend.switches, 0);
    }
    #[test]
    fn unowned_virtual_default_is_not_guessed_or_overwritten() {
        let mut backend = Fake::default();
        backend.outputs[0].device_id = "virtual".into();
        backend.outputs[1].device_id = "virtual".into();
        let mut manager = Manager::new(backend);
        manager.recover().unwrap();
        assert!(manager.acquire(11).unwrap().is_none());
        manager.shutdown().unwrap();
        assert_eq!(manager.backend.current(RenderRole::Console).unwrap(), "virtual");
        assert_eq!(manager.backend.current(RenderRole::Communications).unwrap(), "call-speaker");
        assert_eq!(manager.backend.switches, 0);
        assert!(manager.backend.journal.is_none());
    }
    #[test]
    fn another_running_host_is_never_displaced() {
        let mut manager = Manager::new(Fake::default());
        manager.acquire(11).unwrap();
        manager.backend.foreign = true;
        assert!(manager.recover().is_err());
        assert_eq!(manager.backend.current(RenderRole::Console).unwrap(), "virtual");
    }
    #[test]
    fn linked_windows_roles_are_snapshotted_before_either_direction_changes() {
        let mut manager = Manager::new(Fake { link_multimedia: true, ..Fake::default() });
        let token = manager.acquire(11).unwrap().unwrap();
        let journal = manager.backend.journal.as_ref().unwrap();
        assert_eq!(journal.previous[0].device_id, "speaker");
        assert_eq!(journal.previous[1].device_id, "headphones");
        manager.release(token).unwrap();
        assert_eq!(manager.backend.current(RenderRole::Console).unwrap(), "speaker");
        assert_eq!(manager.backend.current(RenderRole::Multimedia).unwrap(), "headphones");
    }
    #[test]
    fn partial_policy_switch_rolls_back_without_leaving_a_virtual_default() {
        let mut manager = Manager::new(Fake {
            link_multimedia: true, fail_role_once: Some(RenderRole::Multimedia), ..Fake::default()
        });
        assert!(manager.acquire(11).is_err());
        assert_eq!(manager.backend.current(RenderRole::Console).unwrap(), "speaker");
        assert_eq!(manager.backend.current(RenderRole::Multimedia).unwrap(), "headphones");
        assert!(manager.backend.journal.is_none());
    }
    #[test]
    fn exit_without_an_owned_lease_does_not_change_a_manual_virtual_default() {
        let mut manager = Manager::new(Fake::default());
        manager.backend.outputs[0].device_id = "virtual".into();
        manager.shutdown().unwrap();
        assert_eq!(manager.backend.current(RenderRole::Console).unwrap(), "virtual");
        assert_eq!(manager.backend.switches, 0);
    }
}
