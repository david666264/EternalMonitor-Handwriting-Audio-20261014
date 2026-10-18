//! WASAPI render sink for the already-installed Steam microphone pair.
//! COM objects and handles belong exclusively to this audio worker thread.

use std::ffi::c_void;
use std::ptr;
use std::time::{Duration, Instant};

use windows::core::{GUID, HRESULT, PCWSTR};
use windows::Win32::Devices::FunctionDiscovery::PKEY_Device_FriendlyName;
use windows::Win32::Foundation::{CloseHandle, HANDLE, WAIT_FAILED};
use windows::Win32::Media::Audio::Endpoints::IAudioEndpointVolume;
use windows::Win32::Media::Audio::*;
use windows::Win32::System::Com::StructuredStorage::PropVariantToStringAlloc;
use windows::Win32::System::Com::{
    CoCreateInstance, CoInitializeEx, CoTaskMemFree, CoUninitialize, CLSCTX_ALL,
    COINIT_MULTITHREADED, STGM_READ,
};
use windows::Win32::System::Threading::{CreateEventW, WaitForSingleObject};

use super::{protective_attenuation, FrameQueue, Upsampler, OUTPUT_CHANNELS, OUTPUT_FRAMES};

const PCM_GUID: GUID = GUID::from_u128(0x00000001_0000_0010_8000_00aa00389b71);
const POLICY_CLASS: GUID = GUID::from_u128(0x870af99c_171d_4f9e_af0d_e63df40c2bc9);
const POLICY_INTERFACE: GUID = GUID::from_u128(0xf8679f50_850a_41cf_9c72_430f290290c8);
const DEVICE_FAMILY: &str = "steam streaming microphone";

struct Apartment;
impl Apartment {
    fn enter() -> Result<Self, String> {
        unsafe { CoInitializeEx(None, COINIT_MULTITHREADED).ok().map_err(|e| e.to_string())?; }
        Ok(Self)
    }
}
impl Drop for Apartment {
    fn drop(&mut self) { unsafe { CoUninitialize(); } }
}

struct Event(HANDLE);
impl Drop for Event {
    fn drop(&mut self) { unsafe { let _ = CloseHandle(self.0); } }
}

struct OwnedFormat(*mut WAVEFORMATEX);
impl OwnedFormat {
    fn bytes(&self) -> Result<Vec<u8>, String> {
        if self.0.is_null() { return Err("Audio policy returned no endpoint format".into()); }
        let base = unsafe { self.0.read_unaligned() };
        if base.cbSize > 256 { return Err("Unexpected endpoint format extension".into()); }
        let count = std::mem::size_of::<WAVEFORMATEX>() + usize::from(base.cbSize);
        Ok(unsafe { std::slice::from_raw_parts(self.0.cast::<u8>(), count).to_vec() })
    }
}
impl Drop for OwnedFormat {
    fn drop(&mut self) { unsafe { CoTaskMemFree(Some(self.0.cast())); } }
}

// ABI declaration for the Windows audio policy COM interface, matching the
// existing output_route_windows module. No default endpoint method is exposed.
#[repr(C)]
struct PolicyVtable {
    query_interface: usize,
    add_ref: usize,
    release: unsafe extern "system" fn(*mut c_void) -> u32,
    get_mix: unsafe extern "system" fn(*mut c_void, PCWSTR, *mut *mut WAVEFORMATEX) -> HRESULT,
    get_device: unsafe extern "system" fn(*mut c_void, PCWSTR, i32, *mut *mut WAVEFORMATEX) -> HRESULT,
    reset_device: usize,
    set_device: unsafe extern "system" fn(*mut c_void, PCWSTR, *const WAVEFORMATEX, *const WAVEFORMATEX) -> HRESULT,
}

#[link(name = "ole32")]
extern "system" {
    #[link_name = "CoCreateInstance"]
    fn create_policy(class: *const GUID, outer: *mut c_void, context: u32,
                     interface: *const GUID, result: *mut *mut c_void) -> HRESULT;
}

struct Policy(*mut c_void);
impl Policy {
    fn new() -> Result<Self, String> {
        let mut raw = ptr::null_mut();
        unsafe {
            create_policy(&POLICY_CLASS, ptr::null_mut(), CLSCTX_ALL.0,
                          &POLICY_INTERFACE, &mut raw).ok().map_err(|e| e.to_string())?;
        }
        if raw.is_null() { return Err("Windows returned no audio policy interface".into()); }
        Ok(Self(raw))
    }
    fn vtable(&self) -> &PolicyVtable { unsafe { &**(self.0 as *const *const PolicyVtable) } }
    fn format(&self, id: &[u16], device: bool) -> Result<Vec<u8>, String> {
        let mut raw = ptr::null_mut();
        let result = unsafe {
            if device {
                (self.vtable().get_device)(self.0, PCWSTR(id.as_ptr()), 0, &mut raw)
            } else {
                (self.vtable().get_mix)(self.0, PCWSTR(id.as_ptr()), &mut raw)
            }
        };
        result.ok().map_err(|e| e.to_string())?;
        OwnedFormat(raw).bytes()
    }
    fn set(&self, id: &[u16], device: &[u8], mix: Option<&[u8]>) -> Result<(), String> {
        unsafe {
            (self.vtable().set_device)(self.0, PCWSTR(id.as_ptr()), device.as_ptr().cast(),
                mix.map_or(ptr::null(), |bytes| bytes.as_ptr().cast()))
                .ok().map_err(|e| e.to_string())
        }
    }
}
impl Drop for Policy {
    fn drop(&mut self) { unsafe { (self.vtable().release)(self.0); } }
}

fn wide(value: &str) -> Vec<u16> { value.encode_utf16().chain(Some(0)).collect() }

fn device_id(device: &IMMDevice) -> Result<Vec<u16>, String> {
    unsafe {
        let id = device.GetId().map_err(|e| e.to_string())?;
        let text = id.to_string().map_err(|e| e.to_string());
        CoTaskMemFree(Some(id.0.cast()));
        text.map(|text| wide(&text))
    }
}

fn device_name(device: &IMMDevice) -> Result<String, String> {
    unsafe {
        let properties = device.OpenPropertyStore(STGM_READ).map_err(|e| e.to_string())?;
        let value = properties.GetValue(&PKEY_Device_FriendlyName).map_err(|e| e.to_string())?;
        let name = PropVariantToStringAlloc(&value).map_err(|e| e.to_string())?;
        let text = name.to_string().map_err(|e| e.to_string());
        CoTaskMemFree(Some(name.0.cast()));
        text
    }
}

fn find_device(enumerator: &IMMDeviceEnumerator, flow: EDataFlow) -> Result<IMMDevice, String> {
    unsafe {
        let devices = enumerator.EnumAudioEndpoints(flow, DEVICE_STATE_ACTIVE).map_err(|e| e.to_string())?;
        let mut found = None;
        for index in 0..devices.GetCount().map_err(|e| e.to_string())? {
            let device = devices.Item(index).map_err(|e| e.to_string())?;
            if device_name(&device)?.to_lowercase().contains(DEVICE_FAMILY) {
                if found.is_some() { return Err("Multiple active Steam microphone endpoints are ambiguous".into()); }
                found = Some(device);
            }
        }
        found.ok_or_else(|| "The Steam microphone render/capture pair is not active".into())
    }
}

fn format_bytes(float: bool) -> [u8; 40] {
    let mut bytes = [0u8; 40];
    bytes[0..2].copy_from_slice(&0xfffeu16.to_le_bytes());
    bytes[2..4].copy_from_slice(&2u16.to_le_bytes());
    bytes[4..8].copy_from_slice(&48000u32.to_le_bytes());
    bytes[8..12].copy_from_slice(&384000u32.to_le_bytes());
    bytes[12..14].copy_from_slice(&8u16.to_le_bytes());
    bytes[14..16].copy_from_slice(&32u16.to_le_bytes());
    bytes[16..18].copy_from_slice(&22u16.to_le_bytes());
    bytes[18..20].copy_from_slice(&32u16.to_le_bytes());
    bytes[20..24].copy_from_slice(&3u32.to_le_bytes());
    // KSDATAFORMAT_SUBTYPE_PCM / IEEE_FLOAT in Windows GUID byte order.
    bytes[24..40].copy_from_slice(&[if float { 3 } else { 1 }, 0, 0, 0, 0, 0,
                                   0x10, 0, 0x80, 0, 0, 0xaa, 0, 0x38, 0x9b, 0x71]);
    bytes
}

fn recommended_device_format(bytes: &[u8]) -> bool {
    if bytes.len() < 40 { return false; }
    let base = unsafe { bytes.as_ptr().cast::<WAVEFORMATEX>().read_unaligned() };
    base.wFormatTag == 0xfffe && base.nChannels == 2 && base.nSamplesPerSec == 48000
        && base.wBitsPerSample == 32 && base.nBlockAlign == 8 && base.nAvgBytesPerSec == 384000
        && base.cbSize >= 22 && bytes[18..20] == 32u16.to_le_bytes()
        && bytes[20..24] == 3u32.to_le_bytes()
        && unsafe { bytes.as_ptr().add(24).cast::<GUID>().read_unaligned() } == PCM_GUID
}

struct FormatSnapshot {
    id: Vec<u16>,
    device: Vec<u8>,
    mix: Vec<u8>,
    changed: bool,
}

struct FormatTransaction {
    policy: Policy,
    snapshots: Vec<FormatSnapshot>,
    committed: bool,
}
impl FormatTransaction {
    fn new(render: &IMMDevice, capture: &IMMDevice) -> Result<Self, String> {
        let policy = Policy::new()?;
        let mut transaction = Self { policy, snapshots: Vec::new(), committed: false };
        // Save both descriptions before the first mutation. A startup failure
        // restores changed formats, leaving all other audio settings untouched.
        for device in [render, capture] {
            let id = device_id(device)?;
            transaction.snapshots.push(FormatSnapshot {
                device: transaction.policy.format(&id, true)?,
                mix: transaction.policy.format(&id, false)?, id, changed: false,
            });
        }
        let target = format_bytes(false);
        for snapshot in &mut transaction.snapshots {
            if !recommended_device_format(&snapshot.device) {
                transaction.policy.set(&snapshot.id, &target, None)?;
                snapshot.changed = true;
            }
        }
        for snapshot in &transaction.snapshots {
            if !recommended_device_format(&transaction.policy.format(&snapshot.id, true)?) {
                return Err("Steam microphone endpoint formats did not take effect".into());
            }
        }
        Ok(transaction)
    }
    fn commit(&mut self) { self.committed = true; }
}
impl Drop for FormatTransaction {
    fn drop(&mut self) {
        if !self.committed {
            for snapshot in self.snapshots.iter().rev().filter(|snapshot| snapshot.changed) {
                if let Err(error) = self.policy.set(&snapshot.id, &snapshot.device, Some(&snapshot.mix)) {
                    tracing::warn!(%error, "Could not restore a Steam microphone endpoint format after startup failure");
                }
            }
        }
    }
}

struct Render {
    writer: IAudioRenderClient,
    client: IAudioClient,
    render_volume: IAudioEndpointVolume,
    capture_volume: IAudioEndpointVolume,
    event: Event,
    buffer_frames: u32,
    attenuation: f32,
    gain_checked: Instant,
}
impl Render {
    fn open() -> Result<Self, String> {
        unsafe {
            let enumerator: IMMDeviceEnumerator = CoCreateInstance(&MMDeviceEnumerator, None, CLSCTX_ALL)
                .map_err(|e| e.to_string())?;
            let render = find_device(&enumerator, eRender)?;
            let capture = find_device(&enumerator, eCapture)?;
            let mut formats = FormatTransaction::new(&render, &capture)?;
            let client: IAudioClient = render.Activate(CLSCTX_ALL, None).map_err(|e| e.to_string())?;
            let desired = format_bytes(true);
            client.Initialize(AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_EVENTCALLBACK,
                              100_000, 0, desired.as_ptr().cast(), None).map_err(|e| e.to_string())?;
            let buffer_frames = client.GetBufferSize().map_err(|e| e.to_string())?;
            if buffer_frames == 0 || buffer_frames > 4800 {
                return Err("Steam microphone render buffer is invalid or exceeds 100 ms".into());
            }
            let event = Event(CreateEventW(None, false, false, None).map_err(|e| e.to_string())?);
            client.SetEventHandle(event.0).map_err(|e| e.to_string())?;
            let writer: IAudioRenderClient = client.GetService().map_err(|e| e.to_string())?;
            let render_volume: IAudioEndpointVolume = render.Activate(CLSCTX_ALL, None).map_err(|e| e.to_string())?;
            let capture_volume: IAudioEndpointVolume = capture.Activate(CLSCTX_ALL, None).map_err(|e| e.to_string())?;
            let attenuation = protective_attenuation(
                render_volume.GetMasterVolumeLevel().map_err(|e| e.to_string())?,
                capture_volume.GetMasterVolumeLevel().map_err(|e| e.to_string())?);
            if attenuation == 0.0 { return Err("Steam microphone endpoint gain is invalid".into()); }
            // Prime only this virtual render buffer. The PC playback route,
            // levels, mutes, permissions, and capture defaults are untouched.
            writer.GetBuffer(buffer_frames).map_err(|e| e.to_string())?;
            writer.ReleaseBuffer(buffer_frames, AUDCLNT_BUFFERFLAGS_SILENT.0 as u32)
                .map_err(|e| e.to_string())?;
            client.Start().map_err(|e| e.to_string())?;
            formats.commit();
            tracing::info!(rate = 48000, channels = 2, attenuation,
                           "USB microphone Windows recording output active");
            Ok(Self { writer, client, render_volume, capture_volume, event,
                      buffer_frames, attenuation, gain_checked: Instant::now() })
        }
    }

    fn update_gain(&mut self) -> Result<(), String> {
        if self.gain_checked.elapsed() < Duration::from_secs(1) { return Ok(()); }
        self.gain_checked = Instant::now();
        self.attenuation = unsafe { protective_attenuation(
            self.render_volume.GetMasterVolumeLevel().map_err(|e| e.to_string())?,
            self.capture_volume.GetMasterVolumeLevel().map_err(|e| e.to_string())?) };
        if self.attenuation == 0.0 { return Err("Steam microphone endpoint gain is invalid".into()); }
        Ok(())
    }

    fn write(&mut self, queue: &FrameQueue, current: &mut [f32; OUTPUT_FRAMES * OUTPUT_CHANNELS],
             cursor: &mut usize, upsampler: &mut Upsampler) -> Result<(), String> {
        unsafe {
            if WaitForSingleObject(self.event.0, 10) == WAIT_FAILED {
                return Err(windows::core::Error::from_win32().to_string());
            }
            if queue.closed.load(std::sync::atomic::Ordering::Acquire) { return Ok(()); }
            self.update_gain()?;
            let padding = self.client.GetCurrentPadding().map_err(|e| e.to_string())?;
            if padding > self.buffer_frames { return Err("Invalid WASAPI microphone padding".into()); }
            let available = self.buffer_frames - padding;
            if available == 0 { return Ok(()); }
            let raw = self.writer.GetBuffer(available).map_err(|e| e.to_string())?;
            if raw.is_null() {
                let _ = self.writer.ReleaseBuffer(available, AUDCLNT_BUFFERFLAGS_SILENT.0 as u32);
                return Err("WASAPI returned no microphone render buffer".into());
            }
            let output = std::slice::from_raw_parts_mut(raw.cast::<f32>(), available as usize * OUTPUT_CHANNELS);
            let mut produced_frames = 0;
            while produced_frames < available as usize {
                if *cursor == OUTPUT_FRAMES {
                    if let Some(packet) = queue.pop_at(Instant::now()) {
                        *current = upsampler.convert(&packet.samples);
                        *cursor = 0;
                    } else {
                        // One queue check per empty WASAPI buffer, not one
                        // mutex/clock operation for every silent sample.
                        output[produced_frames * OUTPUT_CHANNELS..].fill(0.0);
                        upsampler.silence();
                        break;
                    }
                }
                let count = (OUTPUT_FRAMES - *cursor).min(available as usize - produced_frames);
                let source = &current[*cursor * OUTPUT_CHANNELS..(*cursor + count) * OUTPUT_CHANNELS];
                let target = &mut output[produced_frames * OUTPUT_CHANNELS..(produced_frames + count) * OUTPUT_CHANNELS];
                for (target, source) in target.iter_mut().zip(source) {
                    *target = source * self.attenuation;
                }
                *cursor += count;
                produced_frames += count;
            }
            self.writer.ReleaseBuffer(available, 0).map_err(|e| e.to_string())?;
            Ok(())
        }
    }
}
impl Drop for Render {
    fn drop(&mut self) {
        unsafe {
            let _ = self.client.Stop();
            let _ = self.client.Reset();
        }
    }
}

pub(super) fn run(queue: &FrameQueue) -> Result<(), String> {
    let _apartment = Apartment::enter()?;
    if queue.closed.load(std::sync::atomic::Ordering::Acquire) { return Ok(()); }
    let mut render = Render::open()?;
    let mut upsampler = Upsampler::default();
    let mut current = [0f32; OUTPUT_FRAMES * OUTPUT_CHANNELS];
    let mut cursor = OUTPUT_FRAMES;
    while !queue.closed.load(std::sync::atomic::Ordering::Acquire) {
        render.write(queue, &mut current, &mut cursor, &mut upsampler)?;
    }
    Ok(())
}
