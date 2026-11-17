use std::{ffi::CStr, fs::{File, OpenOptions}, io::{self, Write, Seek, SeekFrom}, os::raw::c_char, slice};

pub struct Recorder { file: File, rate: u32, bytes: u32, checkpoint: u32, error: bool, level: f32 }

fn header(file: &mut File, rate: u32, bytes: u32) -> io::Result<()> {
    file.seek(SeekFrom::Start(0))?;
    file.write_all(b"RIFF")?;
    file.write_all(&(36u32 + bytes).to_le_bytes())?;
    file.write_all(b"WAVEfmt ")?;
    file.write_all(&16u32.to_le_bytes())?;
    file.write_all(&1u16.to_le_bytes())?;
    file.write_all(&1u16.to_le_bytes())?;
    file.write_all(&rate.to_le_bytes())?;
    file.write_all(&(rate * 2).to_le_bytes())?;
    file.write_all(&2u16.to_le_bytes())?;
    file.write_all(&16u16.to_le_bytes())?;
    file.write_all(b"data")?;
    file.write_all(&bytes.to_le_bytes())?;
    file.seek(SeekFrom::End(0))?;
    Ok(())
}

#[no_mangle]
pub unsafe extern "C" fn lr_open(path: *const c_char, rate: u32) -> *mut Recorder {
    if path.is_null() || rate == 0 || rate > 192000 { return std::ptr::null_mut(); }
    let Ok(path) = CStr::from_ptr(path).to_str() else { return std::ptr::null_mut(); };
    let Ok(mut file) = OpenOptions::new().write(true).create_new(true).open(path) else { return std::ptr::null_mut(); };
    if header(&mut file, rate, 0).is_err() { return std::ptr::null_mut(); }
    Box::into_raw(Box::new(Recorder {file, rate, bytes: 0, checkpoint: 0, error: false, level: 0.0}))
}

#[no_mangle]
pub unsafe extern "C" fn lr_write(rec: *mut Recorder, samples: *const f32, count: usize) -> i32 {
    if rec.is_null() || samples.is_null() { return -1; }
    let r = &mut *rec;
    if r.error || count > 1_000_000 || (r.bytes as u64 + count as u64 * 2) > (u32::MAX as u64 - 36) { r.error = true; return -1; }
    let samples = slice::from_raw_parts(samples, count);
    let mut pcm = Vec::with_capacity(count * 2);
    let mut power = 0.0f64;
    for &sample in samples {
        let s = if sample.is_finite() { sample.clamp(-1.0, 1.0) } else { 0.0 };
        power += (s as f64).powi(2);
        pcm.extend_from_slice(&((s * 32767.0).round() as i16).to_le_bytes());
    }
    r.level = if count == 0 { 0.0 } else { (power / count as f64).sqrt() as f32 };
    if r.file.write_all(&pcm).is_err() { r.error = true; return -1; }
    r.bytes += pcm.len() as u32;
    if r.bytes - r.checkpoint >= r.rate * 2 {
        if header(&mut r.file, r.rate, r.bytes).and_then(|_| r.file.sync_data()).is_err() { r.error = true; return -1; }
        r.checkpoint = r.bytes;
    }
    0
}

#[no_mangle]
pub unsafe extern "C" fn lr_level(rec: *const Recorder) -> f32 { if rec.is_null() { 0.0 } else { (*rec).level } }

#[no_mangle]
pub unsafe extern "C" fn lr_close(rec: *mut Recorder) -> i32 {
    if rec.is_null() { return -1; }
    let mut r = Box::from_raw(rec);
    let failed = r.error;
    if header(&mut r.file, r.rate, r.bytes).and_then(|_| r.file.sync_all()).is_err() || failed { -1 } else { 0 }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CString;
    #[test]
    fn writes_pcm_and_updates_header_before_close() {
        let path = std::env::temp_dir().join(format!("lecture-test-{}.wav", std::process::id()));
        let _ = std::fs::remove_file(&path);
        let name = CString::new(path.to_str().unwrap()).unwrap();
        unsafe {
            let r = lr_open(name.as_ptr(), 16000); assert!(!r.is_null());
            assert!(lr_open(name.as_ptr(), 16000).is_null());
            let data = vec![0.5f32; 16000];
            assert_eq!(lr_write(r, data.as_ptr(), data.len()), 0);
            let bytes = std::fs::read(&path).unwrap();
            assert_eq!(&bytes[..4], b"RIFF");
            assert_eq!(u32::from_le_bytes(bytes[40..44].try_into().unwrap()), 32000);
            assert!((lr_level(r) - 0.5).abs() < 0.001);
            assert_eq!(lr_close(r), 0);
        }
        std::fs::remove_file(path).unwrap();
    }
    #[test]
    fn clips_audio_and_handles_nonfinite_samples() {
        let path = std::env::temp_dir().join(format!("lecture-clipping-{}.wav", std::process::id()));
        let _ = std::fs::remove_file(&path);
        let name = CString::new(path.to_str().unwrap()).unwrap();
        unsafe {
            let r = lr_open(name.as_ptr(), 48000);
            assert!(!r.is_null());
            let samples = [2.0f32, -2.0, f32::NAN, f32::INFINITY];
            assert_eq!(lr_write(r, samples.as_ptr(), samples.len()), 0);
            assert_eq!(lr_close(r), 0);
        }
        let bytes = std::fs::read(&path).unwrap();
        let pcm: Vec<i16> = bytes[44..].chunks_exact(2).map(|s| i16::from_le_bytes([s[0], s[1]])).collect();
        assert_eq!(pcm, [32767, -32767, 0, 0]);
        assert_eq!(u32::from_le_bytes(bytes[40..44].try_into().unwrap()), 8);
        std::fs::remove_file(path).unwrap();
    }
}
