use super::{Backend, Journal, Manager, RenderRole, RouteConfig};
use once_cell::sync::Lazy;
use parking_lot::Mutex;
use std::{ffi::c_void, fs, path::PathBuf};
use windows::core::{GUID, HRESULT, PCWSTR};
use windows::Win32::Foundation::CloseHandle;
use windows::Win32::Media::Audio::{
    eConsole, eMultimedia, eCommunications, eRender, IMMDeviceEnumerator,
    IMMEndpoint, MMDeviceEnumerator, DEVICE_STATE_ACTIVE, ERole,
};
use windows::Win32::System::Com::{
    CoCreateInstance, CoInitializeEx, CoTaskMemFree, CoUninitialize,
    CLSCTX_ALL, COINIT_MULTITHREADED,
};
use windows::Win32::System::Threading::{
    GetExitCodeProcess, OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION,
};
use windows::core::Interface;

static MANAGER: Lazy<Mutex<Manager<WindowsBackend>>> =
    Lazy::new(|| Mutex::new(Manager::new(WindowsBackend)));
const CONFIG_NAME: &str = "audio-output-route.json";
const JOURNAL_NAME: &str = "audio-output-route-active.json";

fn report(result: Result<(), String>) {
    if let Err(error) = result {
        tracing::warn!(%error, "Could not restore the temporary PC playback route");
    }
}

pub(super) fn acquire(session_id: u32) -> Option<u64> {
    match MANAGER.lock().acquire(session_id) {
        Ok(token) => token,
        Err(error) => {
            tracing::warn!(%error, "Temporary PC playback route unavailable; keeping current output");
            None
        }
    }
}
pub(super) fn release(token: u64) { report(MANAGER.lock().release(token)); }
pub(super) fn recover() { report(MANAGER.lock().recover()); }
pub(super) fn shutdown() {
    // A normal exit must wait for an in-flight acquire/release instead of
    // silently leaving its temporary output selected immediately before exit.
    if let Some(mut manager) = MANAGER.try_lock_for(std::time::Duration::from_secs(2)) {
        report(manager.shutdown());
    } else {
        tracing::warn!("Playback route cleanup lock timed out; recovery journal retained for next startup");
    }
}
pub(super) fn panic_cleanup() {
    // A panic inside this module may already hold the lock on this thread.
    // Never wait for ourselves; the write-ahead journal remains recoverable.
    if let Some(mut manager) = MANAGER.try_lock() { report(manager.shutdown()); }
}

struct Apartment(bool);
impl Apartment {
    fn enter() -> Result<Self, String> {
        let result = unsafe { CoInitializeEx(None, COINIT_MULTITHREADED) };
        if result == HRESULT(0x80010106u32 as i32) {
            // The GUI thread may already own an STA. The interfaces used here
            // can run there; only balance successful CoInitializeEx calls.
            return Ok(Self(false));
        }
        result.ok().map_err(|e| e.to_string())?;
        Ok(Self(true))
    }
}
impl Drop for Apartment {
    fn drop(&mut self) { if self.0 { unsafe { CoUninitialize(); } } }
}

fn role(role: RenderRole) -> ERole {
    match role {
        RenderRole::Console => eConsole,
        RenderRole::Multimedia => eMultimedia,
        RenderRole::Communications => eCommunications,
    }
}
fn wide(value: &str) -> Vec<u16> { value.encode_utf16().chain(Some(0)).collect() }
fn path(name: &str) -> Result<PathBuf, String> {
    crate::settings::app_data_dir().map(|dir| dir.join(name))
        .ok_or_else(|| "No per-user application data directory".into())
}
fn read_json<T: serde::de::DeserializeOwned>(name: &str) -> Result<Option<T>, String> {
    match fs::read(path(name)?) {
        Ok(bytes) => serde_json::from_slice(&bytes).map(Some).map_err(|e| e.to_string()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error.to_string()),
    }
}

// Windows has no documented public API for changing the default playback
// device. IPolicyConfig is the existing Windows policy COM interface used by
// desktop audio switchers. Failure is non-fatal and never changes capture
// devices, endpoint volume or mute. Keep unused methods opaque and untouched.
const POLICY_CONFIG: GUID = GUID::from_u128(0x870af99c_171d_4f9e_af0d_e63df40c2bc9);
const I_POLICY_CONFIG: GUID = GUID::from_u128(0xf8679f50_850a_41cf_9c72_430f290290c8);
#[repr(C)]
struct PolicyVtable {
    query_interface: usize,
    add_ref: usize,
    release: unsafe extern "system" fn(*mut c_void) -> u32,
    unused_methods: [usize; 10],
    set_default_endpoint: unsafe extern "system" fn(*mut c_void, PCWSTR, ERole) -> HRESULT,
}
#[link(name = "ole32")]
extern "system" {
    #[link_name = "CoCreateInstance"]
    fn create_policy(clsid: *const GUID, outer: *mut c_void, context: u32,
        iid: *const GUID, result: *mut *mut c_void) -> HRESULT;
}
struct Policy(*mut c_void);
impl Policy {
    fn new() -> Result<Self, String> {
        let mut raw = std::ptr::null_mut();
        unsafe { create_policy(&POLICY_CONFIG, std::ptr::null_mut(), CLSCTX_ALL.0,
            &I_POLICY_CONFIG, &mut raw).ok().map_err(|e| e.to_string())?; }
        if raw.is_null() { return Err("Windows returned no playback policy interface".into()); }
        Ok(Self(raw))
    }
    fn vtable(&self) -> &PolicyVtable { unsafe { &**(self.0 as *const *const PolicyVtable) } }
    fn set(&self, endpoint: &str, output_role: ERole) -> Result<(), String> {
        let endpoint = wide(endpoint);
        unsafe { (self.vtable().set_default_endpoint)(self.0, PCWSTR(endpoint.as_ptr()), output_role)
            .ok().map_err(|e| e.to_string()) }
    }
}
impl Drop for Policy {
    fn drop(&mut self) { unsafe { (self.vtable().release)(self.0); } }
}

struct WindowsBackend;
impl Backend for WindowsBackend {
    fn config(&mut self) -> Result<Option<RouteConfig>, String> { read_json(CONFIG_NAME) }
    fn journal(&mut self) -> Result<Option<Journal>, String> { read_json(JOURNAL_NAME) }
    fn save(&mut self, journal: Option<&Journal>) -> Result<(), String> {
        let target = path(JOURNAL_NAME)?;
        if let Some(journal) = journal {
            fs::create_dir_all(target.parent().unwrap()).map_err(|e| e.to_string())?;
            let temporary = target.with_extension("json.tmp");
            let mut file = std::fs::File::create(&temporary).map_err(|e| e.to_string())?;
            use std::io::Write;
            file.write_all(&serde_json::to_vec_pretty(journal).map_err(|e| e.to_string())?)
                .and_then(|()| file.sync_all()).map_err(|e| e.to_string())?;
            drop(file);
            fs::rename(temporary, target).map_err(|e| e.to_string())
        } else {
            match fs::remove_file(target) {
                Ok(()) => Ok(()),
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
                Err(error) => Err(error.to_string()),
            }
        }
    }
    fn current(&mut self, output_role: RenderRole) -> Result<String, String> {
        let _apartment = Apartment::enter()?;
        unsafe {
            let enumerator: IMMDeviceEnumerator = CoCreateInstance(&MMDeviceEnumerator, None, CLSCTX_ALL)
                .map_err(|e| e.to_string())?;
            let device = enumerator.GetDefaultAudioEndpoint(eRender, role(output_role))
                .map_err(|e| e.to_string())?;
            let id = device.GetId().map_err(|e| e.to_string())?;
            let text = id.to_string().map_err(|e| e.to_string());
            CoTaskMemFree(Some(id.0.cast()));
            text
        }
    }
    fn available(&mut self, id: &str) -> Result<bool, String> {
        let _apartment = Apartment::enter()?;
        let id = wide(id);
        unsafe {
            let enumerator: IMMDeviceEnumerator = CoCreateInstance(&MMDeviceEnumerator, None, CLSCTX_ALL)
                .map_err(|e| e.to_string())?;
            let Ok(device) = enumerator.GetDevice(PCWSTR(id.as_ptr())) else { return Ok(false); };
            let endpoint: IMMEndpoint = device.cast().map_err(|e| e.to_string())?;
            Ok(device.GetState().map_err(|e| e.to_string())? == DEVICE_STATE_ACTIVE
                && endpoint.GetDataFlow().map_err(|e| e.to_string())? == eRender)
        }
    }
    fn set_default(&mut self, output_role: RenderRole, id: &str) -> Result<(), String> {
        let _apartment = Apartment::enter()?;
        Policy::new()?.set(id, role(output_role))
    }
    fn foreign_owner_running(&mut self, pid: u32) -> bool {
        if pid == std::process::id() { return false; }
        unsafe {
            let handle = match OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid) {
                Ok(handle) => handle,
                Err(error) => {
                    // Access denied means we cannot prove the owner is gone.
                    return error.code().0 != 0x80070057u32 as i32;
                }
            };
            let mut code = 0;
            let result = GetExitCodeProcess(handle, &mut code);
            let _ = CloseHandle(handle);
            result.is_err() || code == 259 // STILL_ACTIVE
        }
    }
}
