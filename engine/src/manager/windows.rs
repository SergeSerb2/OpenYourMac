use accessibility_sys::{
    AXUIElementCreateApplication, AXUIElementRef, AXValueCreate, AXValueGetValue,
    kAXPositionAttribute, kAXRaiseAction, kAXSizeAttribute, kAXStandardWindowSubrole,
    kAXUnknownSubrole, kAXValueTypeCGPoint, kAXValueTypeCGSize, kAXWindowRole,
};
use bevy::ecs::component::Component;
use bevy::math::IRect;
use core::ptr::NonNull;
use derive_more::{DerefMut, with_trait::Deref};
use mockall::automock;
use objc2_core_foundation::{
    CFArray, CFBoolean, CFNumber, CFRetained, CFString, CFType, CGPoint, CGRect, CGSize,
    kCFBooleanFalse, kCFBooleanTrue,
};
use std::collections::HashMap;
use std::ptr::null_mut;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, LazyLock, Mutex, OnceLock, RwLock};
use std::thread;
use std::time::{Duration, Instant};
use stdext::function_name;
use stdext::sync::rw_lock::RwLockExt;
use tracing::{Level, debug, instrument, trace, warn};

use super::skylight::{
    _AXUIElementGetWindow, _SLPSSetFrontProcessWithOptions, AXUIElementCopyAttributeValue,
    AXUIElementPerformAction, AXUIElementSetAttributeValue, SLPSPostEventRecordTo,
    SLSWindowIteratorAdvance,
};
use crate::config::Config;
use crate::errors::{Error, Result};
use crate::manager::{Origin, Size, irect_from};
use crate::platform::{Pid, ProcessSerialNumber, WinID, macos_major_version};
use crate::util::{AXUIAttributes, AXUIWrapper, MacResult};

/// The per-PID lock covers the AX reads/writes and the count transition, while
/// unrelated applications can still move in parallel.
static ENHANCED_UI: LazyLock<Mutex<HashMap<Pid, Arc<Mutex<EnhancedUiState>>>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

#[derive(Default)]
struct EnhancedUiState {
    count: usize,
    restore_pending: bool,
}

struct EnhancedUiGuard {
    state: Arc<Mutex<EnhancedUiState>>,
    app: CFRetained<AXUIWrapper>,
}

impl Drop for EnhancedUiGuard {
    fn drop(&mut self) {
        let mut state = self
            .state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        state.count -= 1;
        if state.count == 0 {
            let result = unsafe {
                AXUIElementSetAttributeValue(
                    self.app.as_ptr(),
                    CFString::from_static_str("AXEnhancedUserInterface").as_ref(),
                    kCFBooleanTrue.unwrap(),
                )
            }
            .to_result(function_name!());
            // Keep the restoration obligation if the app temporarily stops answering.
            state.restore_pending = result.is_err();
            if let Err(err) = result {
                warn!("error restoring enhanced UI: {err}");
            }
        }
    }
}

/// macOS may partially apply an AX width increase when the requested right edge
/// would be far outside the display. Moving the partial result left by the
/// missing width before retrying gives `WindowServer` enough offscreen room.
///
/// Only retry when the first attempt actually grew the window. Fixed-size apps
/// otherwise look identical to this failure mode and must not be moved offscreen.
fn resize_staging_origin(
    previous_frame: IRect,
    actual_frame: IRect,
    target_width: i32,
) -> Option<Origin> {
    let actual_width = actual_frame.width();
    (actual_width > previous_frame.width() && actual_width < target_width).then(|| {
        actual_frame
            .min
            .with_x(actual_frame.min.x - (target_width - actual_width))
    })
}

#[derive(Debug)]
pub enum WindowPadding {
    Vertical(i32),
    Horizontal(i32),
}

#[automock]
pub trait WindowApi: Send + Sync {
    fn id(&self) -> WinID;
    fn frame(&self) -> IRect;
    fn element(&self) -> Option<CFRetained<AXUIWrapper>>;
    fn title(&self) -> Result<String>;
    /// Drops the cached title so the next [`Self::title`] reads it afresh.
    /// Called when the app reports the title changed.
    fn invalidate_title(&self);
    fn identifier(&self) -> Result<String>;
    fn child_role(&self) -> Result<bool>;
    fn role(&self) -> Result<String>;
    fn subrole(&self) -> Result<String>;
    fn is_minimized(&self) -> bool;
    fn is_full_screen(&self) -> bool;
    fn reposition(&mut self, origin: Origin);
    fn resize(&mut self, size: Size);
    fn update_frame(&mut self) -> Result<IRect>;
    fn focus_without_raise(
        &self,
        psn: ProcessSerialNumber,
        currently_focused: &Window,
        focused_psn: ProcessSerialNumber,
    );
    fn focus_with_raise(&self, psn: ProcessSerialNumber);
    /// Raises the window in the OS z-order without changing focus. Used to
    /// shuffle the floating-vs-tiled tier order. Best-effort: AX raise can't
    /// lift a window above another app's frontmost window.
    fn raise_without_focus(&self);
    fn pid(&self) -> Result<Pid>;
    fn set_padding(&mut self, padding: WindowPadding);
    fn horizontal_padding(&self) -> i32;
    fn vertical_padding(&self) -> i32;
    fn border_radius(&self) -> Option<f64>;
}

#[derive(Component, Deref, DerefMut)]
pub struct Window(
    #[deref]
    #[deref_mut]
    Box<dyn WindowApi>,
    FixedSizeEvidence,
);

#[derive(Default)]
struct FixedSizeEvidence {
    first: OnceLock<bool>,
    confirmed: AtomicBool,
}

impl Window {
    pub fn new(window: Box<dyn WindowApi>) -> Self {
        Window(window, FixedSizeEvidence::default())
    }
}

/// Retrieves the window ID (`WinID`) from an `AXUIElementRef`.
///
/// # Arguments
///
/// * `element_ref` - The `AXUIElementRef` to extract the window ID from.
///
/// # Returns
///
/// `Ok(WinID)` with the window ID if successful, otherwise `Err(Error)`.
pub fn ax_window_id(element_ref: AXUIElementRef) -> Result<WinID> {
    try_ax_window_id(element_ref).ok_or_else(|| {
        Error::InvalidInput(format!(
            "{}: Unable to get window id from element {element_ref:?}.",
            function_name!()
        ))
    })
}

/// Allocation-free variant of [`ax_window_id`].
///
/// [`crate::manager::bruteforce_windows`] calls this tens of thousands of times in
/// a row and discards nearly every result, so the error path must not format a
/// message it will only drop.
pub fn try_ax_window_id(element_ref: AXUIElementRef) -> Option<WinID> {
    let ptr = NonNull::new(element_ref)?;
    let mut window_id: WinID = 0;
    if unsafe { _AXUIElementGetWindow(ptr.as_ptr(), &mut window_id) } != 0 || window_id == 0 {
        return None;
    }
    Some(window_id)
}

// const CPS_ALL_WINDOWS: u32 = 0x100;
const CPS_USER_GENERATED: u32 = 0x200;
// const CPS_NO_WINDOWS: u32 = 0x400;

#[derive(Debug)]
pub struct WindowOS {
    id: WinID,
    ax_element: CFRetained<AXUIWrapper>,
    frame: IRect,
    vertical_padding: i32,
    horizontal_padding: i32,
    border_radius: OnceLock<Option<f64>>,
    pid: OnceLock<Result<Pid>>,
    app_reference: OnceLock<Option<CFRetained<AXUIWrapper>>>,
    /// The last title read off the element, cached because reading one is a
    /// synchronous cross-process call and many callers want it for every
    /// window at once.
    ///
    /// An `RwLock` rather than a `OnceLock` like its neighbours: a title can
    /// change, and [`Self::invalidate_title`] clears it when the app reports
    /// `kAXTitleChangedNotification`. Missing that notification is the one
    /// way this can go stale.
    title: RwLock<Option<String>>,
}

impl WindowOS {
    /// Creates a new `Window` instance using an empty configuration.
    /// Non-standard windows are rejected unless they match a `manage = true` rule.
    ///
    /// # Arguments
    ///
    /// * `element` - A `CFRetained<AXUIWrapper>` reference to the Accessibility UI element.
    ///
    /// # Returns
    ///
    /// `Ok(Window)` if the window is created successfully, otherwise `Err(Error)`.
    #[instrument(level = Level::TRACE, ret)]
    pub fn new(element: &CFRetained<AXUIWrapper>) -> Result<Self> {
        Self::new_with_config(element, &Config::default(), None)
    }

    /// Creates a new `Window` instance.
    ///
    /// # Arguments
    ///
    /// * `element` - A `CFRetained<AXUIWrapper>` reference to the Accessibility UI element.
    /// * `config` - The current Paneru configuration, used to evaluate window rules.
    /// * `bundle_id` - The bundle identifier of the owning application, if known.
    ///
    /// # Returns
    ///
    /// `Ok(Window)` if the window is created successfully, otherwise `Err(Error)`.
    #[instrument(level = Level::TRACE, ret)]
    pub fn new_with_config(
        element: &CFRetained<AXUIWrapper>,
        config: &Config,
        bundle_id: Option<&str>,
    ) -> Result<Self> {
        Self::new_before(element, config, bundle_id, None)
    }

    /// Discovery must not start another AX lookup after its scan budget expires.
    pub(super) fn new_before(
        element: &CFRetained<AXUIWrapper>,
        config: &Config,
        bundle_id: Option<&str>,
        deadline: Option<Instant>,
    ) -> Result<Self> {
        let before_lookup = || {
            if deadline.is_some_and(|deadline| Instant::now() >= deadline) {
                Err(Error::Generic(
                    "AX window discovery deadline exceeded".into(),
                ))
            } else {
                Ok(())
            }
        };
        before_lookup()?;
        let id = ax_window_id(element.as_ptr())?;
        let window = Self {
            id,
            ax_element: element.clone(),
            frame: IRect::default(),
            vertical_padding: 0,
            horizontal_padding: 0,
            border_radius: OnceLock::new(),
            pid: OnceLock::new(),
            app_reference: OnceLock::new(),
            title: RwLock::new(None),
        };

        // Read each attribute once, checking the shared scan budget before
        // every synchronous lookup (including constructor/diagnostic work).
        before_lookup()?;
        let role = window.role().ok();
        if role.as_deref() == Some("AXSheet") {
            return Err(Error::invalid_window("Ignoring attached AXSheet"));
        }
        before_lookup()?;
        let title = window.title().ok();
        let forced = title.as_deref().is_some_and(|title| {
            config
                .find_window_properties(title, bundle_id.unwrap_or_default())
                .iter()
                .any(|params| params.manage.is_some_and(|manage| manage))
        });
        before_lookup()?;
        let subrole = window.subrole().ok();
        before_lookup()?;
        if subrole.as_deref() == Some(kAXUnknownSubrole) && !forced {
            return Err(Error::invalid_window(&format!(
                "Ignoring AXUnknown window, id: {}, role {}, subrole {}",
                window.id(),
                role.as_deref().unwrap_or_default(),
                subrole.as_deref().unwrap_or_default(),
            )));
        }
        let real = subrole.as_deref() == Some(kAXStandardWindowSubrole)
            || role.as_deref() == Some("AXDialog")
            || (role.as_deref() == Some(kAXWindowRole)
                && matches!(
                    subrole.as_deref(),
                    Some("AXFloatingWindow" | "AXDialog" | "AXSystemDialog")
                ));
        if !real && !forced {
            return Err(Error::invalid_window(&format!(
                "Ignoring non-real window, id: {}, role {}, subrole {}",
                window.id(),
                role.as_deref().unwrap_or_default(),
                subrole.as_deref().unwrap_or_default(),
            )));
        }
        trace!(
            "created {} title: {} role: {} subrole: {}",
            window.id(),
            title.as_deref().unwrap_or_default(),
            role.as_deref().unwrap_or_default(),
            subrole.as_deref().unwrap_or_default(),
        );
        Ok(window)
    }

    fn app_reference(&self) -> Option<CFRetained<AXUIWrapper>> {
        self.app_reference
            .get_or_init(|| {
                self.pid()
                    .map(|pid| unsafe { AXUIElementCreateApplication(pid) })
                    .and_then(AXUIWrapper::from_retained)
                    .inspect_err(|err| warn!("error getting app reference: {err}"))
                    .ok()
            })
            .clone()
    }

    /// Keep enhanced UI disabled until the last operation on this app completes.
    fn disable_enhanced_ui(&self) -> Option<EnhancedUiGuard> {
        let pid = self.pid().ok()?;
        let app = self.app_reference()?;
        let state = ENHANCED_UI
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .entry(pid)
            .or_default()
            .clone();
        let mut transition = state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if transition.count == 0 && !transition.restore_pending {
            let attr = CFString::from_static_str("AXEnhancedUserInterface");
            // False and failed queries are transient. Neither proves that this
            // app will never need the workaround on a later operation.
            if !app
                .get_attribute::<CFBoolean>(&attr)
                .is_ok_and(|v| CFBoolean::value(&v))
            {
                return None;
            }
            unsafe {
                AXUIElementSetAttributeValue(app.as_ptr(), attr.as_ref(), kCFBooleanFalse.unwrap())
            }
            .to_result(function_name!())
            .inspect_err(|err| warn!("error disabling enhanced UI: {err}"))
            .ok()?;
            transition.restore_pending = true;
        }
        transition.count += 1;
        drop(transition);
        Some(EnhancedUiGuard { state, app })
    }

    fn set_ax_position(&mut self, origin: Origin) -> Result<()> {
        let mut point = CGPoint::new(
            f64::from(origin.x + self.horizontal_padding),
            f64::from(origin.y + self.vertical_padding),
        );
        let position_ref = unsafe {
            AXValueCreate(
                kAXValueTypeCGPoint,
                NonNull::from(&mut point).as_ptr().cast(),
            )
        };
        let position = AXUIWrapper::from_retained(position_ref)?;
        unsafe {
            AXUIElementSetAttributeValue(
                self.ax_element.as_ptr(),
                CFString::from_static_str(kAXPositionAttribute).as_ref(),
                position.as_ref(),
            )
        }
        .to_result(function_name!())?;
        let size = self.frame.size();
        self.frame.min = origin;
        self.frame.max = origin + size;
        Ok(())
    }

    fn set_ax_size(&mut self, size: Size) -> Result<()> {
        let width_padding = 2 * self.horizontal_padding;
        let height_padding = 2 * self.vertical_padding;
        let mut cgsize = CGSize::new(
            f64::from(size.x - width_padding),
            f64::from(size.y - height_padding),
        );
        let size_ref = unsafe {
            AXValueCreate(
                kAXValueTypeCGSize,
                NonNull::from(&mut cgsize).as_ptr().cast(),
            )
        };
        let size_value = AXUIWrapper::from_retained(size_ref)?;
        unsafe {
            AXUIElementSetAttributeValue(
                self.ax_element.as_ptr(),
                CFString::from_static_str(kAXSizeAttribute).as_ref(),
                size_value.as_ref(),
            )
        }
        .to_result(function_name!())?;
        self.frame.max = self.frame.min + size;
        Ok(())
    }

    /// Makes the window the key window for its application by sending synthesized events.
    ///
    /// # Arguments
    ///
    /// * `psn` - The process serial number of the application.
    fn make_key_window(&self, psn: &ProcessSerialNumber) {
        // Reason: On macOS 14 (Sonoma), CGSEncodeEventRecord serializes the raw event
        // buffer via NSKeyedArchiver, misinterpreting 0xFF fill as an ObjC class pointer,
        // causing SIGABRT. See https://github.com/karinushka/paneru/issues/123
        if macos_major_version() == 14 {
            debug!("make_key_window: skipped on macOS 14 (Sonoma) to prevent crash");
            return;
        }
        let window_id = self.id();
        let mut event_bytes = [0u8; 0xf8];
        event_bytes[0x04] = 0xf8;
        event_bytes[0x3a] = 0x10;
        event_bytes[0x3c..0x40].copy_from_slice(&window_id.to_ne_bytes());
        event_bytes[0x20..0x30].fill(0xff);

        event_bytes[0x08] = 0x01;
        unsafe { SLPSPostEventRecordTo(psn, event_bytes.as_ptr().cast()) };

        event_bytes[0x08] = 0x02;
        unsafe { SLPSPostEventRecordTo(psn, event_bytes.as_ptr().cast()) };
    }
}

impl WindowApi for WindowOS {
    /// Returns the ID of the window.
    ///
    /// # Returns
    ///
    /// The window ID as `WinID`.
    fn id(&self) -> WinID {
        self.id
    }

    /// Returns the current frame (`CGRect`) of the window.
    ///
    /// # Returns
    ///
    /// The window's frame as `CGRect`.
    fn frame(&self) -> IRect {
        self.frame
    }

    /// Returns the accessibility element of the window.
    ///
    /// # Returns
    ///
    /// A `CFRetained<AXUIWrapper>` representing the accessibility element.
    fn element(&self) -> Option<CFRetained<AXUIWrapper>> {
        Some(self.ax_element.clone())
    }

    /// Retrieves the title of the window.
    ///
    /// # Returns
    ///
    /// `Ok(String)` with the window title if successful, otherwise `Err(Error)`.
    fn title(&self) -> Result<String> {
        if let Some(cached) = self.title.force_read().clone() {
            return Ok(cached);
        }
        let title = self.ax_element.title()?;
        *self.title.force_write() = Some(title.clone());
        Ok(title)
    }

    fn invalidate_title(&self) {
        self.title.force_write().take();
    }

    fn identifier(&self) -> Result<String> {
        self.ax_element.identifier()
    }

    /// Returns true if the window has a child role.
    fn child_role(&self) -> Result<bool> {
        let role = self.role()?;
        Ok(["AXSheet", "AXDrawer"]
            .iter()
            .any(|axrole| axrole.eq(&role)))
    }

    /// Retrieves the role of the window (e.g., "`AXWindow`").
    ///
    /// # Returns
    ///
    /// `Ok(String)` with the window role if successful, otherwise `Err(Error)`.
    fn role(&self) -> Result<String> {
        self.ax_element.role()
    }

    /// Retrieves the subrole of the window (e.g., "`AXStandardWindow`").
    ///
    /// # Returns
    ///
    /// `Ok(String)` with the window subrole if successful, otherwise `Err(Error)`.
    fn subrole(&self) -> Result<String> {
        self.ax_element.subrole()
    }

    #[instrument(level = Level::DEBUG, ret)]
    fn is_minimized(&self) -> bool {
        self.ax_element.minimized().is_ok_and(|minimized| minimized)
    }

    fn is_full_screen(&self) -> bool {
        self.ax_element.full_screen().unwrap_or(false)
    }

    #[instrument(level = Level::TRACE)]
    fn reposition(&mut self, origin: Origin) {
        if self.frame.min == origin {
            trace!("already in position.");
            return;
        }
        let _enhanced_ui = self.disable_enhanced_ui();
        if let Err(err) = self.set_ax_position(origin) {
            warn!(window = self.id, "error setting AX position: {err}");
        }
    }

    #[instrument(level = Level::TRACE)]
    fn resize(&mut self, size: Size) {
        if self.frame.size() == size {
            trace!("already correct size.");
            return;
        }
        let previous_frame = self.frame;
        let target_origin = previous_frame.min;
        let _enhanced_ui = self.disable_enhanced_ui();
        if let Err(err) = self.set_ax_size(size) {
            warn!(window = self.id, "error setting AX size: {err}");
            return;
        }

        let mut previous_observed_frame = previous_frame;
        let mut staged = false;
        for attempt in 1..=3 {
            let Ok(actual_frame) = self.update_frame() else {
                break;
            };
            let Some(staging_origin) =
                resize_staging_origin(previous_observed_frame, actual_frame, size.x)
            else {
                break;
            };
            debug!(
                attempt,
                requested_width = size.x,
                actual_width = actual_frame.width(),
                staging_x = staging_origin.x,
                "retrying partially constrained AX resize from an offscreen origin"
            );
            staged = true;
            previous_observed_frame = actual_frame;
            if let Err(err) = self
                .set_ax_position(staging_origin)
                .and_then(|()| self.set_ax_size(size))
            {
                warn!(window = self.id, "error staging AX resize: {err}");
                break;
            }
        }

        if staged {
            if let Ok(final_frame) = self.update_frame() {
                debug!(
                    requested_width = size.x,
                    actual_width = final_frame.width(),
                    "completed staged AX resize"
                );
            }
            if let Err(err) = self.set_ax_position(target_origin) {
                warn!(
                    window = self.id,
                    "error restoring AX position after resize: {err}"
                );
            }
        }
    }

    /// Updates the internal `frame` of the window by querying its current position and size from the Accessibility API.
    /// It also updates the `width_ratio`.
    ///
    /// # Arguments
    ///
    /// * `display_bounds` - An optional `CGRect` representing the bounds of the display the window is on.
    ///
    /// # Returns
    ///
    /// `Ok(())` if the frame is updated successfully, otherwise `Err(Error)`.
    fn update_frame(&mut self) -> Result<IRect> {
        let window_ref = self.ax_element.as_ptr();

        let position = unsafe {
            let mut position_ref: *mut CFType = null_mut();
            AXUIElementCopyAttributeValue(
                window_ref,
                CFString::from_static_str(kAXPositionAttribute).as_ref(),
                &mut position_ref,
            )
            .to_result(function_name!())?;
            AXUIWrapper::from_retained(position_ref)?
        };
        let size = unsafe {
            let mut size_ref: *mut CFType = null_mut();
            AXUIElementCopyAttributeValue(
                window_ref,
                CFString::from_static_str(kAXSizeAttribute).as_ref(),
                &mut size_ref,
            )
            .to_result(function_name!())?;
            AXUIWrapper::from_retained(size_ref)?
        };

        let mut frame = CGRect::default();
        unsafe {
            AXValueGetValue(
                position.as_ptr(),
                kAXValueTypeCGPoint,
                NonNull::from(&mut frame.origin).as_ptr().cast(),
            );
            AXValueGetValue(
                size.as_ptr(),
                kAXValueTypeCGSize,
                NonNull::from(&mut frame.size).as_ptr().cast(),
            );
        }
        // if (CGRectEqualToRect(new_frame, window->frame)) {
        //     debug("%s:DEBOUNCED %s %d\n", __FUNCTION__, window->application->name, window->id);
        // }
        self.frame = irect_from(frame);

        self.frame.min.x -= self.horizontal_padding;
        self.frame.min.y -= self.vertical_padding;
        self.frame.max.x += self.horizontal_padding;
        self.frame.max.y += self.vertical_padding;

        Ok(self.frame)
    }

    /// Focuses the window without raising it. This involves sending specific events to the process.
    ///
    /// # Arguments
    ///
    /// * `currently_focused` - A reference to the currently focused window.
    #[instrument(level = Level::DEBUG, skip(currently_focused))]
    fn focus_without_raise(
        &self,
        psn: ProcessSerialNumber,
        currently_focused: &Window,
        focused_psn: ProcessSerialNumber,
    ) {
        let window_id = self.id();
        debug!("{window_id}");
        if focused_psn == psn {
            let mut event_bytes = [0u8; 0xf8];
            event_bytes[0x04] = 0xf8;
            event_bytes[0x08] = 0x0d;

            event_bytes[0x8a] = 0x02;
            event_bytes[0x3c..0x40].copy_from_slice(&currently_focused.id().to_ne_bytes());
            unsafe {
                SLPSPostEventRecordTo(&focused_psn, event_bytes.as_ptr().cast());
            }

            // Artificially delay the activation. This is necessary because some
            // applications appear to be confused if both of the events appear instantaneously.
            thread::sleep(Duration::from_millis(20));

            event_bytes[0x8a] = 0x01;
            event_bytes[0x3c..0x40].copy_from_slice(&window_id.to_ne_bytes());
            unsafe {
                SLPSPostEventRecordTo(&psn, event_bytes.as_ptr().cast());
            }
        }

        unsafe {
            _SLPSSetFrontProcessWithOptions(&psn, window_id, CPS_USER_GENERATED);
        }
        self.make_key_window(&psn);
    }

    /// Focuses the window and raises it to the front.
    #[instrument(level = Level::DEBUG)]
    fn focus_with_raise(&self, psn: ProcessSerialNumber) {
        let window_id = self.id();
        unsafe {
            _SLPSSetFrontProcessWithOptions(&psn, window_id, CPS_USER_GENERATED);
        }
        self.make_key_window(&psn);
        let element_ref = self.ax_element.as_ptr();
        let action = CFString::from_static_str(kAXRaiseAction);
        unsafe { AXUIElementPerformAction(element_ref, &action) };
    }

    #[instrument(level = Level::DEBUG)]
    fn raise_without_focus(&self) {
        let element_ref = self.ax_element.as_ptr();
        let action = CFString::from_static_str(kAXRaiseAction);
        unsafe { AXUIElementPerformAction(element_ref, &action) };
    }

    fn pid(&self) -> Result<Pid> {
        self.pid
            .get_or_init(|| {
                let pid: Pid = unsafe {
                    NonNull::new_unchecked(self.ax_element.as_ptr::<Pid>())
                        .byte_add(0x10)
                        .read()
                };
                (pid != 0).then_some(pid).ok_or(Error::InvalidInput(format!(
                    "can not get pid from {:?}.",
                    self.ax_element
                )))
            })
            .clone()
    }

    fn set_padding(&mut self, padding: WindowPadding) {
        match padding {
            WindowPadding::Vertical(padding) => self.vertical_padding = padding,
            WindowPadding::Horizontal(padding) => self.horizontal_padding = padding,
        }
    }

    fn horizontal_padding(&self) -> i32 {
        self.horizontal_padding
    }

    fn vertical_padding(&self) -> i32 {
        self.vertical_padding
    }

    // Based on:
    // - https://github.com/y3owk1n/rift/blob/cca067145f0282b532e848bb63d26a38c61f3c14/src/sys/window_server.rs#L175
    // - https://github.com/FelixKratz/JankyBorders/blob/a56a76a8a6ed77325f03655b23fcf525144d120b/src/windows.c#L67
    #[allow(clippy::cast_precision_loss)]
    fn border_radius(&self) -> Option<f64> {
        *self.border_radius.get_or_init(|| {
            let iterator = super::window_iterator_for_id(self.id)?;
            if !unsafe { SLSWindowIteratorAdvance(&raw const *iterator) } {
                return None;
            }

            let radii_ref = unsafe {
                // Load the function dynamicaly, because it exists only on macOS 26.x
                let s = c"SLSWindowIteratorGetCornerRadii";
                let p = libc::dlsym(libc::RTLD_DEFAULT, s.as_ptr());
                if p.is_null() {
                    return None;
                }
                let f: unsafe extern "C" fn(*const CFType) -> *mut CFArray<CFNumber> =
                    std::mem::transmute(p);
                f(&raw const *iterator)
            };
            let radii: CFRetained<CFArray<CFNumber>> =
                unsafe { CFRetained::from_raw(NonNull::new(radii_ref)?) };
            if radii.is_empty() {
                return None;
            }
            // Get first corner radius (usually all corners are the same)
            radii.get(0)?.as_i64().map(|v| v as f64)
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stages_partially_applied_width_growth() {
        let previous = IRect::new(-400, 40, 400, 640);
        let actual = IRect::new(-400, 40, 2416, 640);

        assert_eq!(
            resize_staging_origin(previous, actual, 4112),
            Some(Origin::new(-1696, 40))
        );

        let nearly_complete = IRect::new(-2056, 40, 2016, 640);
        assert_eq!(
            resize_staging_origin(actual, nearly_complete, 4112),
            Some(Origin::new(-2096, 40))
        );
    }

    #[test]
    fn does_not_stage_fixed_size_or_completed_resizes() {
        let fixed = IRect::new(0, 40, 230, 448);
        assert_eq!(resize_staging_origin(fixed, fixed, 4112), None);

        let previous = IRect::new(0, 40, 800, 640);
        let completed = IRect::new(0, 40, 4112, 640);
        assert_eq!(resize_staging_origin(previous, completed, 4112), None);
    }
}

/// Why a window floats or tiles. User decisions are never subject to retries.
#[derive(Component, Clone, Copy, Debug, PartialEq, Eq)]
pub enum FloatReason {
    DefaultTile,
    RuleTile,
    UserTile,
    Rule,
    User,
    FixedSize,
    Dialog,
    OwnApp,
}
impl FloatReason {
    pub fn floating(self) -> bool {
        matches!(
            self,
            Self::Rule | Self::User | Self::FixedSize | Self::Dialog | Self::OwnApp
        )
    }
    pub fn automatic(self) -> bool {
        matches!(self, Self::DefaultTile | Self::FixedSize | Self::Dialog)
    }
}

/// AX diagnostics are read only on the main thread. An absent/failed resize
/// query is unknown, not proof of a fixed-size window. Explicit tile rules win
/// over defaults; our own settings windows always float.
#[allow(clippy::too_many_lines)]
pub fn classify_float(
    window: &Window,
    bundle_id: &str,
    floating_rule: Option<bool>,
    config: &Config,
) -> FloatReason {
    if bundle_id == "com.openyourmac.OpenYourMac" {
        return FloatReason::OwnApp;
    }
    if let Some(floating) = floating_rule {
        return if floating {
            FloatReason::Rule
        } else {
            FloatReason::RuleTile
        };
    }
    let Some(element) = window.element() else {
        return FloatReason::DefaultTile;
    };
    let subrole = window.subrole().unwrap_or_default();
    let role = window.role().unwrap_or_default();
    let get = |name: &str| {
        element
            .get_attribute::<CFType>(&CFString::from_str(name))
            .ok()
    };
    let modal = element
        .get_attribute::<CFBoolean>(&CFString::from_str("AXModal"))
        .is_ok_and(|v| CFBoolean::value(&v));
    let fixed = non_resizable(&element);
    let first_fixed = *window.1.first.get_or_init(|| fixed);
    if !config.float_dialogs() {
        return FloatReason::DefaultTile;
    }
    {
        // Native tab controls are stronger evidence than generic panel controls.
        let native_tabs = element
            .get_attribute::<CFArray<AXUIWrapper>>(&CFString::from_str("AXTabs"))
            .is_ok_and(|tabs| !tabs.is_empty());
        let quicklook = bundle_id.to_ascii_lowercase().contains("quicklook")
            || window
                .identifier()
                .is_ok_and(|id| id.to_ascii_lowercase().contains("quicklook"));
        if quicklook {
            return FloatReason::Dialog;
        }
        let frame = window.frame();
        let center = CGPoint::new(f64::from(frame.center().x), f64::from(frame.center().y));
        let mut display = objc2_core_graphics::CGMainDisplayID();
        let mut count = 0;
        unsafe {
            objc2_core_graphics::CGGetDisplaysWithPoint(
                center,
                1,
                &raw mut display,
                &raw mut count,
            );
        }
        let screen = objc2_core_graphics::CGDisplayBounds(display);
        let near_display = f64::from(frame.width()) >= screen.size.width * 0.8
            && f64::from(frame.height()) >= screen.size.height * 0.8;
        let small = f64::from(frame.width()) < screen.size.width * 0.7
            && f64::from(frame.height()) < screen.size.height * 0.7;
        let app = window.pid().ok().and_then(|pid| {
            AXUIWrapper::from_retained(unsafe { AXUIElementCreateApplication(pid) }).ok()
        });
        let siblings = app
            .and_then(|app| app.windows().ok())
            .map(|windows| windows.len());
        let sole_normal = !modal && subrole == kAXStandardWindowSubrole && siblings == Some(1);
        let attached = element
            .get_attribute::<AXUIWrapper>(&CFString::from_str("AXParent"))
            .is_ok_and(|parent| parent.role().is_ok_and(|r| r == kAXWindowRole));
        let panel = matches!(
            subrole.as_str(),
            "AXDialog" | "AXSystemDialog" | "AXFloatingWindow"
        ) || matches!(role.as_str(), "AXSheet" | "AXDialog");
        if !native_tabs
            && !near_display
            && !sole_normal
            && (panel
                || modal
                || attached
                || (small
                    && get("AXMinimizeButton").is_none()
                    && siblings.is_some_and(|n| n > 1)
                    && !subrole.is_empty()
                    && subrole != kAXStandardWindowSubrole
                    && subrole != kAXUnknownSubrole))
        {
            return FloatReason::Dialog;
        }
    }
    if first_fixed && fixed && window.1.confirmed.load(Ordering::Relaxed) {
        FloatReason::FixedSize
    } else {
        FloatReason::DefaultTile
    }
}

impl Window {
    /// The first scheduled recheck supplies the second resizability sample.
    /// Focus, passthrough and config property reads cannot confirm admission.
    pub(crate) fn confirm_fixed_size(&self) {
        let confirmed = self.1.first.get().copied().unwrap_or(false)
            && self
                .element()
                .is_some_and(|element| non_resizable(&element));
        self.1.confirmed.store(confirmed, Ordering::Relaxed);
    }
}

fn non_resizable(element: &AXUIWrapper) -> bool {
    let mut resizable = 0u8;
    let size_attr = CFString::from_static_str(kAXSizeAttribute);
    (unsafe {
        accessibility_sys::AXUIElementIsAttributeSettable(
            element.as_ptr(),
            CFRetained::as_ptr(&size_attr).as_ptr().cast(),
            &raw mut resizable,
        )
    }) == 0
        && resizable == 0
}
