pub mod cpal_mic;

use async_trait::async_trait;
use futures::stream::BoxStream;
use std::error::Error;

pub type AudioStream = BoxStream<'static, Vec<f32>>;

/// Cross-platform interface for system audio capture (the "them" speaker).
/// Implementations: WASAPI loopback (Windows), CoreAudio tap (Mac).
#[async_trait]
pub trait AudioCaptureService: Send + Sync {
    fn audio_level(&self) -> f32;
    async fn buffer_stream(&self) -> Result<AudioStream, Box<dyn Error + Send + Sync>>;
    fn finish_stream(&self);
    async fn stop(&self);
}

/// Microphone capture service — extends AudioCaptureService with device selection.
#[async_trait]
pub trait MicCaptureService: Send + Sync {
    fn audio_level(&self) -> f32;

    /// Returns a stream for the named device, or the system default if `device_name` is None.
    fn buffer_stream_for_device(&self, device_name: Option<&str>) -> AudioStream;

    async fn is_authorized(&self) -> bool;
    fn finish_stream(&self);
    async fn stop(&self);
}
