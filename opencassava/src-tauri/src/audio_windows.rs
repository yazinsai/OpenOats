//! WASAPI loopback capture — streams system audio as 16kHz f32 mono chunks.
//! On non-Windows platforms this module still compiles but provides a no-op stub.

use async_trait::async_trait;
use opencassava_core::audio::{AudioCaptureService, AudioStream};
use std::error::Error;

#[cfg(target_os = "windows")]
mod wasapi_impl {
    use super::*;
    use std::sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    };
    use tokio::sync::mpsc;
    use windows::Win32::Devices::Properties::DEVPKEY_Device_FriendlyName;
    use windows::Win32::System::Com::STGM_READ;
    use windows::Win32::System::Variant::VT_LPWSTR;
    use windows::{
        core::{PROPVARIANT, PWSTR},
        Win32::Devices::Properties::DEVPROPKEY,
        Win32::Media::Audio::*,
        Win32::System::Com::*,
        Win32::UI::Shell::PropertiesSystem::PROPERTYKEY,
    };

    const TARGET_RATE: u32 = 16_000;

    pub struct WasapiLoopback {
        finished: Arc<AtomicBool>,
        audio_level: Arc<std::sync::Mutex<f32>>,
        device_name: Option<String>,
    }

    unsafe impl Send for WasapiLoopback {}
    unsafe impl Sync for WasapiLoopback {}

    impl WasapiLoopback {
        pub fn new(device_name: Option<&str>) -> Self {
            Self {
                finished: Arc::new(AtomicBool::new(false)),
                audio_level: Arc::new(std::sync::Mutex::new(0.0)),
                device_name: device_name.map(str::to_owned),
            }
        }
    }

    #[async_trait]
    impl AudioCaptureService for WasapiLoopback {
        fn audio_level(&self) -> f32 {
            *self.audio_level.lock().unwrap()
        }

        async fn buffer_stream(&self) -> Result<AudioStream, Box<dyn Error + Send + Sync>> {
            let finished = self.finished.clone();
            let level_arc = self.audio_level.clone();
            let device_name_inner = self.device_name.clone();
            let (tx, rx) = mpsc::channel::<Vec<f32>>(200);

            std::thread::spawn(move || {
                unsafe {
                    if CoInitializeEx(None, COINIT_MULTITHREADED).is_err() {
                        log::error!("WASAPI: CoInitializeEx failed");
                        return;
                    }

                    let enumerator: IMMDeviceEnumerator =
                        match CoCreateInstance(&MMDeviceEnumerator, None, CLSCTX_ALL) {
                            Ok(e) => e,
                            Err(e) => {
                                log::error!("WASAPI: enumerator: {e}");
                                return;
                            }
                        };

                    let device = if let Some(ref name) = device_name_inner {
                        find_device_by_name(&enumerator, name).unwrap_or_else(|| {
                            log::warn!(
                                "System audio device '{}' not found, falling back to default",
                                name
                            );
                            enumerator
                                .GetDefaultAudioEndpoint(eRender, eConsole)
                                .expect("no default render endpoint")
                        })
                    } else {
                        match enumerator.GetDefaultAudioEndpoint(eRender, eConsole) {
                            Ok(d) => d,
                            Err(e) => {
                                log::error!("WASAPI: GetDefaultAudioEndpoint: {e}");
                                return;
                            }
                        }
                    };

                    let audio_client: IAudioClient = match device.Activate(CLSCTX_ALL, None) {
                        Ok(c) => c,
                        Err(e) => {
                            log::error!("WASAPI: Activate: {e}");
                            return;
                        }
                    };

                    let mix_fmt_ptr = match audio_client.GetMixFormat() {
                        Ok(f) => f,
                        Err(e) => {
                            log::error!("WASAPI: GetMixFormat: {e}");
                            return;
                        }
                    };
                    let mix_fmt = &*mix_fmt_ptr;

                    // Initialize in loopback mode (AUDCLNT_STREAMFLAGS_LOOPBACK)
                    const REFTIMES_PER_SEC: i64 = 10_000_000;
                    if let Err(e) = audio_client.Initialize(
                        AUDCLNT_SHAREMODE_SHARED,
                        AUDCLNT_STREAMFLAGS_LOOPBACK,
                        REFTIMES_PER_SEC,
                        0,
                        mix_fmt_ptr,
                        None,
                    ) {
                        log::error!("WASAPI: Initialize: {e}");
                        return;
                    }

                    let capture_client: IAudioCaptureClient = match audio_client.GetService() {
                        Ok(c) => c,
                        Err(e) => {
                            log::error!("WASAPI: GetService: {e}");
                            return;
                        }
                    };

                    if let Err(e) = audio_client.Start() {
                        log::error!("WASAPI: Start: {e}");
                        return;
                    }

                    let src_rate = mix_fmt.nSamplesPerSec;
                    let channels = mix_fmt.nChannels as usize;
                    let bits = mix_fmt.wBitsPerSample;
                    log::info!("WASAPI loopback: {}Hz {}ch {}bit", src_rate, channels, bits);

                    loop {
                        if finished.load(Ordering::Relaxed) {
                            break;
                        }

                        std::thread::sleep(std::time::Duration::from_millis(10));

                        let packet_len = match capture_client.GetNextPacketSize() {
                            Ok(n) => n,
                            Err(_) => break,
                        };
                        if packet_len == 0 {
                            continue;
                        }

                        let mut data_ptr = std::ptr::null_mut();
                        let mut frames = 0u32;
                        let mut flags = 0u32;
                        if capture_client
                            .GetBuffer(&mut data_ptr, &mut frames, &mut flags, None, None)
                            .is_err()
                        {
                            break;
                        }

                        let sample_count = frames as usize * channels;
                        let mono: Vec<f32> = if bits == 32 {
                            let slice =
                                std::slice::from_raw_parts(data_ptr as *const f32, sample_count);
                            slice
                                .chunks(channels)
                                .map(|c| c.iter().sum::<f32>() / channels as f32)
                                .collect()
                        } else if bits == 16 {
                            let slice =
                                std::slice::from_raw_parts(data_ptr as *const i16, sample_count);
                            slice
                                .chunks(channels)
                                .map(|c| {
                                    c.iter().map(|&s| s as f32 / 32768.0).sum::<f32>()
                                        / channels as f32
                                })
                                .collect()
                        } else {
                            vec![]
                        };

                        let _ = capture_client.ReleaseBuffer(frames);

                        if mono.is_empty() {
                            continue;
                        }

                        // Update RMS level
                        let rms =
                            (mono.iter().map(|s| s * s).sum::<f32>() / mono.len() as f32).sqrt();
                        *level_arc.lock().unwrap() = rms;

                        // Resample to 16kHz if needed
                        let resampled = if src_rate != TARGET_RATE {
                            resample_linear(&mono, src_rate, TARGET_RATE)
                        } else {
                            mono
                        };

                        tx.blocking_send(resampled).ok();
                    }

                    let _ = audio_client.Stop();
                    CoUninitialize();
                }
            });

            Ok(Box::pin(tokio_stream::wrappers::ReceiverStream::new(rx)))
        }

        fn finish_stream(&self) {
            self.finished
                .store(true, std::sync::atomic::Ordering::Relaxed);
        }

        async fn stop(&self) {
            self.finish_stream();
        }
    }

    /// Simple linear resampler (quality sufficient for voice).
    fn resample_linear(samples: &[f32], src_rate: u32, dst_rate: u32) -> Vec<f32> {
        if src_rate == dst_rate {
            return samples.to_vec();
        }
        let ratio = src_rate as f64 / dst_rate as f64;
        let dst_len = (samples.len() as f64 / ratio) as usize;
        (0..dst_len)
            .map(|i| {
                let src_pos = i as f64 * ratio;
                let lo = src_pos as usize;
                let hi = (lo + 1).min(samples.len() - 1);
                let frac = src_pos - lo as f64;
                samples[lo] * (1.0 - frac as f32) + samples[hi] * frac as f32
            })
            .collect()
    }

    fn property_key_from_devprop(key: DEVPROPKEY) -> PROPERTYKEY {
        PROPERTYKEY {
            fmtid: key.fmtid,
            pid: key.pid,
        }
    }

    unsafe fn friendly_name_from_propvariant(prop: &PROPVARIANT) -> Option<String> {
        let raw = prop.as_raw();
        let vt = raw.Anonymous.Anonymous.vt;
        if vt != VT_LPWSTR.0 {
            return None;
        }

        PWSTR(raw.Anonymous.Anonymous.Anonymous.pwszVal)
            .to_string()
            .ok()
    }

    /// Find a render device by its friendly name. Returns None if not found.
    unsafe fn find_device_by_name(
        enumerator: &IMMDeviceEnumerator,
        name: &str,
    ) -> Option<IMMDevice> {
        let collection = enumerator
            .EnumAudioEndpoints(eRender, DEVICE_STATE_ACTIVE)
            .ok()?;
        let count = collection.GetCount().ok()?;
        let friendly_name_key = property_key_from_devprop(DEVPKEY_Device_FriendlyName);
        for i in 0..count {
            if let Ok(device) = collection.Item(i) {
                if let Ok(store) = device.OpenPropertyStore(STGM_READ) {
                    if let Ok(prop) = store.GetValue(&friendly_name_key) {
                        let matched =
                            friendly_name_from_propvariant(&prop).as_deref() == Some(name);
                        if matched {
                            return Some(device);
                        }
                    }
                }
            }
        }
        None
    }

    /// Returns friendly names of all active render (output/loopback) endpoints.
    pub fn list_render_devices() -> Vec<String> {
        unsafe {
            let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
            let enumerator: IMMDeviceEnumerator =
                match CoCreateInstance(&MMDeviceEnumerator, None, CLSCTX_ALL) {
                    Ok(e) => e,
                    Err(_) => return vec![],
                };
            let collection =
                match enumerator.EnumAudioEndpoints(eRender, DEVICE_STATE_ACTIVE) {
                    Ok(c) => c,
                    Err(_) => return vec![],
                };
            let count = collection.GetCount().unwrap_or(0);
            let friendly_name_key = property_key_from_devprop(DEVPKEY_Device_FriendlyName);
            let mut names = Vec::new();
            for i in 0..count {
                if let Ok(device) = collection.Item(i) {
                    if let Ok(store) = device.OpenPropertyStore(STGM_READ) {
                        if let Ok(prop) = store.GetValue(&friendly_name_key) {
                            if let Some(name) = friendly_name_from_propvariant(&prop) {
                                names.push(name);
                            }
                        }
                    }
                }
            }
            names
        }
    }

    pub use WasapiLoopback as SystemAudioCapture;
}

/// Stub for non-Windows platforms.
#[cfg(not(target_os = "windows"))]
mod wasapi_impl {
    use super::*;
    use futures::stream;

    pub struct SystemAudioCapture;

    impl SystemAudioCapture {
        pub fn new(_device_name: Option<&str>) -> Self {
            Self
        }
    }

    pub fn list_render_devices() -> Vec<String> {
        vec![]
    }

    #[async_trait]
    impl AudioCaptureService for SystemAudioCapture {
        fn audio_level(&self) -> f32 {
            0.0
        }
        async fn buffer_stream(&self) -> Result<AudioStream, Box<dyn Error + Send + Sync>> {
            Ok(Box::pin(stream::empty()))
        }
        fn finish_stream(&self) {}
        async fn stop(&self) {}
    }
}

pub use wasapi_impl::SystemAudioCapture;
pub use wasapi_impl::list_render_devices;
