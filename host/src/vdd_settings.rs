//! Renders the bundled Virtual Display Driver's `vdd_settings.xml` so the
//! managed virtual display can offer the iPad's native resolution.
//!
//! The driver (VirtualDrivers/Virtual-Display-Driver v25.x) reads
//! `C:\VirtualDisplayDriver\vdd_settings.xml` at enable time; options absent
//! from the file fall back to driver defaults, so this writes a minimal
//! document: one monitor, a global refresh rate, and a resolution list led by
//! the client's native landscape mode. NEEDS_WINDOWS_VERIFY: the driver's
//! acceptance of these exact modes is a hardware-runbook item.

use std::io;
use std::path::Path;

/// A display mode for the virtual display's mode list.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct VddMode {
    pub width: u32,
    pub height: u32,
    pub refresh_hz: u32,
}

/// The modes to advertise for a client with the given native panel, best
/// first. The iPad reports portrait-native pixels; the desktop wants
/// landscape, so the long edge becomes the width. Odd dimensions are rounded
/// down — 4:2:0 video encoders need even sizes.
pub fn modes_for_client(screen_px_w: u16, screen_px_h: u16, refresh_hz: u8) -> Vec<VddMode> {
    let long = u32::from(screen_px_w.max(screen_px_h)) & !1;
    let short = u32::from(screen_px_w.min(screen_px_h)) & !1;
    let refresh = match refresh_hz {
        0 => 60,
        hz => u32::from(hz),
    };

    let mut modes = Vec::new();
    let mut push = |mode: VddMode| {
        if mode.width >= 640 && mode.height >= 480 && !modes.contains(&mode) {
            modes.push(mode);
        }
    };
    push(VddMode {
        width: long,
        height: short,
        refresh_hz: refresh,
    });
    if refresh != 60 {
        push(VddMode {
            width: long,
            height: short,
            refresh_hz: 60,
        });
    }
    // Safety net the driver definitely supports.
    push(VddMode {
        width: 1920,
        height: 1080,
        refresh_hz: 60,
    });
    modes
}

/// Render the settings document. Pure so tests can assert the exact bytes.
pub fn render(modes: &[VddMode]) -> String {
    let global_refresh = modes.first().map_or(60, |m| m.refresh_hz);
    let mut xml = String::with_capacity(512);
    xml.push_str("<?xml version=\"1.0\" encoding=\"utf-8\"?>\n");
    xml.push_str("<vdd_settings>\n");
    xml.push_str("    <monitors>\n        <count>1</count>\n    </monitors>\n");
    xml.push_str("    <global>\n");
    xml.push_str(&format!(
        "        <g_refresh_rate>{global_refresh}</g_refresh_rate>\n"
    ));
    xml.push_str("    </global>\n");
    xml.push_str("    <resolutions>\n");
    for mode in modes {
        xml.push_str(&format!(
            "        <resolution>\n            <width>{}</width>\n            \
             <height>{}</height>\n            <refresh_rate>{}</refresh_rate>\n        \
             </resolution>\n",
            mode.width, mode.height, mode.refresh_hz
        ));
    }
    xml.push_str("    </resolutions>\n");
    xml.push_str("    <gpu><friendlyname>default</friendlyname></gpu>\n");
    xml.push_str("    <logging><SendLogsThroughPipe>false</SendLogsThroughPipe><logging>false</logging><debuglogging>false</debuglogging></logging>\n");
    xml.push_str("    <colour><SDR10bit>false</SDR10bit><HDRPlus>false</HDRPlus><ColourFormat>RGB</ColourFormat></colour>\n");
    xml.push_str("    <cursor><HardwareCursor>true</HardwareCursor><CursorMaxY>128</CursorMaxY><CursorMaxX>128</CursorMaxX><AlphaCursorSupport>true</AlphaCursorSupport><XorCursorSupportLevel>2</XorCursorSupportLevel></cursor>\n");
    xml.push_str("    <edid><CustomEdid>false</CustomEdid><PreventSpoof>false</PreventSpoof><EdidCeaOverride>false</EdidCeaOverride></edid>\n");
    xml.push_str("</vdd_settings>\n");
    xml
}

/// Write atomically (tmp + rename) so the driver never reads a torn file.
/// Creates the directory if the driver hasn't made it yet.
pub fn write_to(path: &Path, modes: &[VddMode]) -> io::Result<()> {
    let parent = path.parent().ok_or_else(|| {
        io::Error::new(io::ErrorKind::InvalidInput, "settings path has no parent")
    })?;
    std::fs::create_dir_all(parent)?;
    let tmp = path.with_extension("xml.tmp");
    let generated = render(modes);
    let contents = match std::fs::metadata(path) {
        Ok(metadata) if metadata.len() > 256 * 1024 => {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "VDD settings too large"));
        }
        Ok(_) => merge_modes(&std::fs::read_to_string(path)?, &generated)?,
        Err(error) if error.kind() == io::ErrorKind::NotFound => generated,
        Err(error) => return Err(error),
    };
    std::fs::write(&tmp, contents)?;
    std::fs::rename(&tmp, path)
}

// VDD's canonical XML uses fixed, attribute-free sections for mode settings.
// Copy their replacement bytes without interpreting entities or touching
// unrelated GPU, cursor, colour, logging or future driver settings. A
// noncanonical file fails closed rather than silently losing preferences.
fn section_bounds(xml: &str, tag: &str) -> io::Result<std::ops::Range<usize>> {
    let open = format!("<{tag}>");
    let close = format!("</{tag}>");
    if xml.matches(&open).count() != 1 || xml.matches(&close).count() != 1 {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "Ambiguous VDD mode section"));
    }
    let start = xml.find(&open).unwrap();
    let end = xml.find(&close).unwrap() + close.len();
    if end < start + open.len() {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "Invalid VDD section order"));
    }
    Ok(start..end)
}

fn merge_modes(existing: &str, generated: &str) -> io::Result<String> {
    if existing.matches("<vdd_settings>").count() != 1
        || existing.matches("</vdd_settings>").count() != 1
    {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "Unsupported VDD document"));
    }
    let mut merged = existing.to_string();
    for tag in ["monitors", "global", "resolutions"] {
        let before = section_bounds(&merged, tag)?;
        let after = section_bounds(generated, tag)?;
        merged.replace_range(before, &generated[after]);
    }
    // Upgrade the old minimal file with official driver defaults, while
    // preserving the user's values whenever those sections already exist.
    for tag in ["gpu", "colour", "cursor", "edid"] {
        if !merged.contains(&format!("<{tag}>")) && !merged.contains(&format!("<{tag} ")) {
            let defaults = section_bounds(generated, tag)?;
            let at = merged.find("</vdd_settings>").unwrap();
            merged.insert_str(at, &format!("    {}\n", &generated[defaults]));
        }
    }
    Ok(merged)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ipad_portrait_panel_becomes_landscape_lead_mode() {
        // iPad Pro 11" M4: 1668x2420 portrait native, 120 Hz.
        let modes = modes_for_client(1668, 2420, 120);
        assert_eq!(
            modes[0],
            VddMode {
                width: 2420,
                height: 1668,
                refresh_hz: 120
            }
        );
        assert_eq!(
            modes[1],
            VddMode {
                width: 2420,
                height: 1668,
                refresh_hz: 60
            },
            "a 60 Hz variant backs up high-refresh panels"
        );
        assert_eq!(
            modes[2],
            VddMode {
                width: 1920,
                height: 1080,
                refresh_hz: 60
            }
        );
    }

    #[test]
    fn odd_dimensions_are_evened_for_420_encoders() {
        let modes = modes_for_client(1667, 2421, 60);
        assert_eq!(modes[0].width, 2420);
        assert_eq!(modes[0].height, 1666);
    }

    #[test]
    fn nonsense_panels_still_yield_the_safety_mode() {
        let modes = modes_for_client(0, 0, 0);
        assert_eq!(
            modes,
            vec![VddMode {
                width: 1920,
                height: 1080,
                refresh_hz: 60
            }]
        );
    }

    #[test]
    fn render_produces_the_driver_schema() {
        let xml = render(&modes_for_client(1668, 2420, 120));
        assert!(xml.starts_with("<?xml version=\"1.0\" encoding=\"utf-8\"?>"));
        assert!(xml.contains("<vdd_settings>"));
        assert!(xml.contains("<count>1</count>"));
        assert!(xml.contains("<g_refresh_rate>120</g_refresh_rate>"));
        assert!(xml.contains(
            "<width>2420</width>\n            <height>1668</height>\n            \
             <refresh_rate>120</refresh_rate>"
        ));
        assert!(xml.ends_with("</vdd_settings>\n"));
    }

    #[test]
    fn write_is_atomic_and_creates_the_directory() {
        let dir = std::env::temp_dir().join(format!("vdd-settings-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let path = dir.join("nested").join("vdd_settings.xml");
        write_to(&path, &modes_for_client(1668, 2420, 120)).expect("write settings");
        let written = std::fs::read_to_string(&path).expect("read back");
        assert!(written.contains("<width>2420</width>"));
        assert!(!path.with_extension("xml.tmp").exists(), "tmp cleaned up");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn matching_panel_preserves_driver_preferences_and_future_sections() {
        let original = render(&modes_for_client(1920, 1080, 60))
            .replace("<friendlyname>default</friendlyname>", "<friendlyname>User GPU choice</friendlyname>")
            .replace("<HardwareCursor>true</HardwareCursor>", "<HardwareCursor>false</HardwareCursor>")
            .replace("</vdd_settings>", "<future><custom>keep me</custom></future></vdd_settings>");
        let changed = merge_modes(&original, &render(&modes_for_client(2048, 2732, 120))).unwrap();
        assert!(changed.contains("<width>2732</width>"));
        assert!(changed.contains("<g_refresh_rate>120</g_refresh_rate>"));
        assert!(changed.contains("<friendlyname>User GPU choice</friendlyname>"));
        assert!(changed.contains("<HardwareCursor>false</HardwareCursor>"));
        assert!(changed.contains("<future><custom>keep me</custom></future>"));
    }

    #[test]
    fn ambiguous_mode_configuration_is_not_overwritten() {
        let original = render(&modes_for_client(1920, 1080, 60))
            .replace("</vdd_settings>", "<global></global></vdd_settings>");
        assert!(merge_modes(&original, &render(&modes_for_client(2048, 2732, 120))).is_err());
    }
}
