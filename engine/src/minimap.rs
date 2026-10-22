//! Reusable, non-key visual panels and their window-free CoreGraphics renderer.
//! Input is intercepted by the existing event tap; no panel becomes first responder.
use std::cell::RefCell;
use std::collections::{HashMap, VecDeque};
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, LazyLock, Mutex};

use crate::errors::{Error, Result};
use arc_swap::ArcSwap;
use objc2::rc::Retained;
use objc2::runtime::AnyObject;
use objc2::{AnyThread, DefinedClass, MainThreadMarker, MainThreadOnly, define_class, msg_send};
use objc2_app_kit::{
    NSApplicationActivationPolicy, NSBackingStoreType, NSBitmapImageFileType, NSBitmapImageRep,
    NSColor, NSFloatingWindowLevel, NSGraphicsContext, NSPanel, NSRunningApplication, NSView,
    NSVisualEffectBlendingMode, NSVisualEffectMaterial, NSVisualEffectState, NSVisualEffectView,
    NSWindowCollectionBehavior, NSWindowStyleMask, NSWorkspace,
};
use objc2_core_foundation::{
    CFDictionary, CFNumber, CFRetained, CFString, CFType, CGPoint, CGRect, CGSize,
};
use objc2_core_graphics::{
    CGBitmapContextCreate, CGBitmapContextCreateImage, CGColorSpace, CGContext, CGImage,
    CGInterpolationQuality, CGWindowListCopyWindowInfo, CGWindowListOption, kCGNullWindowID,
    kCGWindowAlpha, kCGWindowBounds, kCGWindowNumber, kCGWindowOwnerPID,
};
use objc2_foundation::{NSDictionary, NSPoint, NSRect, NSSize, NSString};

type Rgba = (f64, f64, f64, f64);
const ACCENT: Rgba = (92.0 / 255.0, 121.0 / 255.0, 245.0 / 255.0, 1.0);

#[derive(Clone, Debug, PartialEq)]
pub struct Tile {
    pub members: usize,
    pub selected: Option<usize>,
    pub tabbed: bool,
    pub pinned: bool,
    /// Process id of each member's app, in member order (for its icon).
    pub apps: Vec<Option<i32>>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct MapModel {
    pub tiles: Vec<Tile>,
    pub focus: usize,
    pub pin_color: Rgba,
    pub insertion: Option<usize>,
}

/// Geometry uses logical screen points. Overflow is clipped with focus in view.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Geometry {
    pub width: f64,
    pub height: f64,
    pub scale: f64,
    pub offset: f64,
}
impl Geometry {
    #[allow(clippy::cast_precision_loss)]
    pub fn new(model: &MapModel, display_width: f64) -> Self {
        let natural = (model.tiles.len() as f64 * 69.0 - 7.0).max(0.0) + 18.0;
        let limit = (display_width * 0.6).max(40.0);
        let scale = (limit / natural).clamp(0.55, 1.0);
        let width = (natural * scale).min(limit);
        let focus_center = (9.0 + model.focus as f64 * 69.0 + 31.0) * scale;
        let offset = (focus_center - width / 2.0).clamp(0.0, (natural * scale - width).max(0.0));
        Self {
            width,
            height: 64.0 * scale,
            scale,
            offset,
        }
    }
    #[allow(clippy::cast_precision_loss)]
    pub fn tile(self, index: usize) -> CGRect {
        rect(
            (9.0 + index as f64 * 69.0) * self.scale - self.offset,
            9.0 * self.scale,
            62.0 * self.scale,
            46.0 * self.scale,
        )
    }
}

pub fn rect(x: f64, y: f64, w: f64, h: f64) -> CGRect {
    CGRect::new(CGPoint::new(x, y), CGSize::new(w, h))
}
fn contains(r: CGRect, p: CGPoint) -> bool {
    p.x >= r.origin.x
        && p.y >= r.origin.y
        && p.x < r.origin.x + r.size.width
        && p.y < r.origin.y + r.size.height
}
fn fill(ctx: &CGContext, color: Rgba, r: CGRect) {
    CGContext::set_rgb_fill_color(Some(ctx), color.0, color.1, color.2, color.3);
    CGContext::fill_rect(Some(ctx), r);
}
#[allow(clippy::many_single_char_names)]
fn rounded(ctx: &CGContext, r: CGRect, radius: f64) {
    let c = Some(ctx);
    let (x, y, w, h) = (r.origin.x, r.origin.y, r.size.width, r.size.height);
    CGContext::begin_path(c);
    CGContext::move_to_point(c, x + radius, y);
    CGContext::add_arc_to_point(c, x + w, y, x + w, y + h, radius);
    CGContext::add_arc_to_point(c, x + w, y + h, x, y + h, radius);
    CGContext::add_arc_to_point(c, x, y + h, x, y, radius);
    CGContext::add_arc_to_point(c, x, y, x + w, y, radius);
    CGContext::close_path(c);
}

/// Fills a rounded rectangle.
fn fill_rounded(ctx: &CGContext, color: Rgba, r: CGRect, radius: f64) {
    rounded(
        ctx,
        r,
        radius.min(r.size.width / 2.0).min(r.size.height / 2.0),
    );
    CGContext::set_rgb_fill_color(Some(ctx), color.0, color.1, color.2, color.3);
    CGContext::fill_path(Some(ctx));
}

/// Strokes a rounded rectangle.
fn stroke_rounded(ctx: &CGContext, color: Rgba, r: CGRect, radius: f64, width: f64) {
    rounded(
        ctx,
        r,
        radius.min(r.size.width / 2.0).min(r.size.height / 2.0),
    );
    CGContext::set_rgb_stroke_color(Some(ctx), color.0, color.1, color.2, color.3);
    CGContext::set_line_width(Some(ctx), width);
    CGContext::stroke_path(Some(ctx));
}

fn inset(r: CGRect, dx: f64, dy: f64) -> CGRect {
    rect(
        r.origin.x + dx,
        r.origin.y + dy,
        (r.size.width - 2.0 * dx).max(0.0),
        (r.size.height - 2.0 * dy).max(0.0),
    )
}

thread_local! {
    /// App icons by process id. Filled lazily on the main thread when tiles
    /// are drawn; `None` remembers apps without an icon.
    static ICONS: RefCell<HashMap<i32, Option<Retained<CGImage>>>> = RefCell::new(HashMap::new());
}

/// The icon of the app with `pid`, rendered once at 64 points and cached.
fn app_icon(pid: i32) -> Option<Retained<CGImage>> {
    ICONS.with(|icons| {
        let mut icons = icons.borrow_mut();
        if icons.len() > 256 {
            icons.clear();
        }
        icons
            .entry(pid)
            .or_insert_with(|| {
                let app = NSRunningApplication::runningApplicationWithProcessIdentifier(pid)?;
                let image = app.icon()?;
                let mut proposed = NSRect::new(NSPoint::new(0.0, 0.0), NSSize::new(64.0, 64.0));
                unsafe { image.CGImageForProposedRect_context_hints(&raw mut proposed, None, None) }
            })
            .clone()
    })
}

/// Draws an app icon centred on `center`. The map is drawn with a flipped
/// (y-down) transform, so the image is flipped back locally to stay upright.
fn draw_icon(ctx: &CGContext, pid: Option<i32>, center: CGPoint, size: f64, alpha: f64) {
    let Some(image) = pid.and_then(app_icon) else {
        return;
    };
    let c = Some(ctx);
    CGContext::save_g_state(c);
    CGContext::set_alpha(c, alpha);
    CGContext::set_interpolation_quality(c, CGInterpolationQuality::High);
    CGContext::translate_ctm(c, center.x - size / 2.0, center.y + size / 2.0);
    CGContext::scale_ctm(c, 1.0, -1.0);
    CGContext::draw_image(c, rect(0.0, 0.0, size, size), Some(&image));
    CGContext::restore_g_state(c);
}

fn center_of(r: CGRect) -> CGPoint {
    CGPoint::new(
        r.origin.x + r.size.width / 2.0,
        r.origin.y + r.size.height / 2.0,
    )
}

const TILE: Rgba = (1.0, 1.0, 1.0, 0.16);
const TILE_IN_FOCUS: Rgba = (1.0, 1.0, 1.0, 0.24);
const ACTIVE_FILL: Rgba = (ACCENT.0, ACCENT.1, ACCENT.2, 0.62);

/// Shared by the real `NSView` and render-minimap. No AX or window calls here.
///
/// One rounded tile per column on a frosted bar: stacked columns are split
/// into slices, tabbed columns carry a row of tab pills, the focused column
/// gets an accent outline, and pinned columns a small badge in the pin colour.
#[allow(clippy::cast_precision_loss)]
fn draw_map(ctx: &CGContext, model: &MapModel, geometry: Geometry) {
    let c = Some(ctx);
    let s = geometry.scale;
    CGContext::save_g_state(c);
    let bar = rect(0.0, 0.0, geometry.width, geometry.height);
    CGContext::clip_to_rect(c, bar);
    fill_rounded(ctx, (0.10, 0.10, 0.12, 0.74), bar, 14.0 * s);
    stroke_rounded(
        ctx,
        (1.0, 1.0, 1.0, 0.10),
        inset(bar, 0.5, 0.5),
        13.5 * s,
        1.0,
    );

    for (i, tile) in model.tiles.iter().enumerate() {
        let r = geometry.tile(i);
        let focused = i == model.focus;
        if tile.tabbed {
            draw_tabbed_tile(ctx, tile, r, focused, s);
        } else {
            draw_stacked_tile(ctx, tile, r, focused, s);
        }
        if focused {
            stroke_rounded(ctx, ACCENT, inset(r, -1.5 * s, -1.5 * s), 8.0 * s, 2.0 * s);
        }
        if tile.pinned {
            draw_pin_badge(ctx, model.pin_color, r, s);
        }
    }

    if let Some(slot) = model.insertion {
        let x = (9.0 + slot as f64 * 69.0 - 3.5) * s - geometry.offset;
        fill_rounded(
            ctx,
            ACCENT,
            rect(x - 1.5 * s, 6.0 * s, 3.0 * s, 52.0 * s),
            1.5 * s,
        );
    }
    CGContext::restore_g_state(c);
}

/// A plain or stacked column: one slice per member, the active one in accent.
#[allow(clippy::cast_precision_loss)]
fn draw_stacked_tile(ctx: &CGContext, tile: &Tile, r: CGRect, focused: bool, s: f64) {
    let members = tile.members.max(1);
    let gap = 3.0 * s;
    let slice_h = (r.size.height - gap * (members - 1) as f64) / members as f64;
    for member in 0..members {
        let slice = rect(
            r.origin.x,
            r.origin.y + member as f64 * (slice_h + gap),
            r.size.width,
            slice_h.max(s),
        );
        let color = if focused && (members == 1 || tile.selected == Some(member)) {
            ACTIVE_FILL
        } else if focused {
            TILE_IN_FOCUS
        } else {
            TILE
        };
        fill_rounded(
            ctx,
            color,
            slice,
            if members == 1 { 6.0 * s } else { 4.0 * s },
        );
        let icon = if members == 1 {
            (r.size.height * 0.62).min(28.0 * s)
        } else {
            (slice.size.height * 0.74)
                .min(r.size.width * 0.5)
                .min(22.0 * s)
        };
        let alpha = if focused { 1.0 } else { 0.88 };
        let pid = tile.apps.get(member).copied().flatten();
        draw_icon(ctx, pid, center_of(slice), icon, alpha);
    }
}

/// A tabbed column: one body with a row of tab pills along its top edge.
#[allow(clippy::cast_precision_loss)]
fn draw_tabbed_tile(ctx: &CGContext, tile: &Tile, r: CGRect, focused: bool, s: f64) {
    fill_rounded(ctx, if focused { ACTIVE_FILL } else { TILE }, r, 6.0 * s);
    let count = tile.members.clamp(1, 6);
    let pad = 6.0 * s;
    let gap = 3.0 * s;
    let pill_w = ((r.size.width - 2.0 * pad - gap * (count - 1) as f64) / count as f64).max(s);
    for index in 0..count {
        let pill = rect(
            r.origin.x + pad + index as f64 * (pill_w + gap),
            r.origin.y + 6.0 * s,
            pill_w,
            4.0 * s,
        );
        let alpha = if tile.selected == Some(index) {
            0.92
        } else {
            0.38
        };
        fill_rounded(ctx, (1.0, 1.0, 1.0, alpha), pill, 2.0 * s);
    }
    // The visible member's app, centred in the body under the pills.
    let body = rect(
        r.origin.x,
        r.origin.y + 12.0 * s,
        r.size.width,
        r.size.height - 12.0 * s,
    );
    let visible = tile.selected.unwrap_or(0);
    let icon = (body.size.height * 0.72).min(24.0 * s);
    let alpha = if focused { 1.0 } else { 0.88 };
    let pid = tile.apps.get(visible).copied().flatten();
    draw_icon(ctx, pid, center_of(body), icon, alpha);
}

/// Round badge in the pin colour on the tile's top-right corner.
fn draw_pin_badge(ctx: &CGContext, color: Rgba, r: CGRect, s: f64) {
    let size = 12.0 * s;
    let badge = rect(
        r.origin.x + r.size.width - size * 0.75,
        r.origin.y - size * 0.25,
        size,
        size,
    );
    fill_rounded(
        ctx,
        (0.10, 0.10, 0.12, 0.9),
        inset(badge, -1.5 * s, -1.5 * s),
        size,
    );
    fill_rounded(ctx, color, badge, size / 2.0);
    fill_rounded(
        ctx,
        (1.0, 1.0, 1.0, 0.95),
        inset(badge, size * 0.32, size * 0.32),
        size,
    );
}

#[derive(Clone, Debug, PartialEq)]
pub enum Content {
    Map(MapModel, Geometry),
    Pin(Rgba),
    Tabs { titles: Vec<String>, active: usize },
}
#[derive(Debug)]
struct ViewIvars {
    content: RefCell<Content>,
}
define_class!(
    #[unsafe(super(NSView))]
    #[thread_kind = MainThreadOnly]
    #[name = "OYMStripVisualView"]
    #[ivars = ViewIvars]
    #[derive(Debug)]
    struct VisualView;
    impl VisualView {
        #[unsafe(method(isFlipped))]
        fn is_flipped(&self)->bool { true }
        #[unsafe(method(needsPanelToBecomeKey))]
        fn needs_key(&self)->bool { false }
        #[unsafe(method(drawRect:))]
        fn draw_rect(&self,_dirty:NSRect) {
            let Some(graphics)=NSGraphicsContext::currentContext() else {return;};
            let ctx=graphics.CGContext();
            let bounds=self.bounds();
            match &*self.ivars().content.borrow() {
                Content::Map(model,geometry)=>draw_map(&ctx,model,*geometry),
                Content::Pin(color)=>fill(&ctx,*color,bounds),
                Content::Tabs{titles,active}=>draw_tabs(&ctx,bounds,titles,*active),
            }
        }
    }
);
#[allow(clippy::cast_precision_loss)]
fn draw_tabs(ctx: &CGContext, bounds: NSRect, titles: &[String], active: usize) {
    use objc2_app_kit::{NSFont, NSParagraphStyle};
    use objc2_foundation::{NSAttributedString, NSMutableCopying};
    let width = bounds.size.width / titles.len().max(1) as f64;
    fill(
        ctx,
        (0.11, 0.11, 0.13, 0.94),
        rect(0.0, 0.0, bounds.size.width, 24.0),
    );
    for (i, title) in titles.iter().enumerate() {
        let x = i as f64 * width;
        let is_active = i == active;
        if is_active {
            fill(ctx, (1.0, 1.0, 1.0, 0.10), rect(x, 0.0, width, 24.0));
            fill(
                ctx,
                ACCENT,
                rect(x + 6.0, 22.0, (width - 12.0).max(1.0), 2.0),
            );
        } else if i > 0 && i != active + 1 {
            fill(ctx, (1.0, 1.0, 1.0, 0.12), rect(x, 6.0, 1.0, 12.0));
        }
        let font = NSFont::systemFontOfSize(11.0);
        let color = NSColor::colorWithWhite_alpha(1.0, if is_active { 0.94 } else { 0.62 });
        let paragraph = NSParagraphStyle::defaultParagraphStyle().mutableCopy();
        unsafe {
            let _: () = msg_send![&paragraph,setLineBreakMode:4isize];
        }
        let keys = [
            NSString::from_str("NSFont"),
            NSString::from_str("NSColor"),
            NSString::from_str("NSParagraphStyle"),
        ];
        let attrs = NSDictionary::from_slices(
            &[&*keys[0], &*keys[1], &*keys[2]],
            &[
                &*font as &AnyObject,
                &*color as &AnyObject,
                &*paragraph as &AnyObject,
            ],
        );
        let label = NSString::from_str(title);
        let text = unsafe {
            NSAttributedString::initWithString_attributes(
                NSAttributedString::alloc(),
                &label,
                Some(&attrs),
            )
        };
        unsafe {
            let _: () = msg_send![&text,drawInRect:rect(x+7.0,4.0,(width-14.0).max(1.0),16.0)];
        }
    }
}

// A borderless nonactivating panel explicitly refuses both main and key status.
define_class!(
    #[unsafe(super(NSPanel, objc2_app_kit::NSWindow, objc2_app_kit::NSResponder))]
    #[thread_kind = MainThreadOnly]
    #[name = "OYMVisualPanel"]
    #[derive(Debug)]
    struct VisualPanel;
    impl VisualPanel {
        #[unsafe(method(canBecomeKeyWindow))]
        fn can_key(&self)->bool { false }
        #[unsafe(method(canBecomeMainWindow))]
        fn can_main(&self)->bool { false }
    }
);

pub struct Panel {
    window: Retained<VisualPanel>,
    view: Retained<VisualView>,
    effect: Retained<NSVisualEffectView>,
    content: Content,
    pub frame: CGRect,
    visible: bool,
}
impl Panel {
    fn new(mtm: MainThreadMarker, content: Content) -> Self {
        let frame = rect(0.0, 0.0, 1.0, 1.0);
        let window: Retained<VisualPanel> = unsafe {
            msg_send![VisualPanel::alloc(mtm),initWithContentRect:frame,styleMask:NSWindowStyleMask::Borderless|NSWindowStyleMask::NonactivatingPanel,backing:NSBackingStoreType::Buffered,defer:false]
        };
        window.setOpaque(false);
        window.setBackgroundColor(Some(&NSColor::clearColor()));
        window.setIgnoresMouseEvents(true);
        window.setHasShadow(false);
        window.setHidesOnDeactivate(false);
        window.setBecomesKeyOnlyIfNeeded(true);
        window.setLevel(NSFloatingWindowLevel + 2);
        window.setCollectionBehavior(
            NSWindowCollectionBehavior::CanJoinAllSpaces
                | NSWindowCollectionBehavior::Stationary
                | NSWindowCollectionBehavior::IgnoresCycle
                | NSWindowCollectionBehavior::FullScreenNone,
        );
        let effect = NSVisualEffectView::initWithFrame(NSVisualEffectView::alloc(mtm), frame);
        effect.setMaterial(NSVisualEffectMaterial::HUDWindow);
        effect.setBlendingMode(NSVisualEffectBlendingMode::BehindWindow);
        effect.setState(NSVisualEffectState::Active);
        effect.setWantsLayer(true);
        if let Some(layer) = effect.layer() {
            layer.setCornerRadius(12.0);
            layer.setMasksToBounds(true);
        }
        let allocated = VisualView::alloc(mtm).set_ivars(ViewIvars {
            content: RefCell::new(content.clone()),
        });
        let view: Retained<VisualView> = unsafe { msg_send![super(allocated),initWithFrame:frame] };
        effect.addSubview(&view);
        window.setContentView(Some(&effect));
        Self {
            window,
            view,
            effect,
            content,
            frame,
            visible: false,
        }
    }
    pub fn id(&self) -> u32 {
        u32::try_from(self.window.windowNumber()).unwrap_or_default()
    }
    pub fn update(
        &mut self,
        frame: CGRect,
        content: Content,
        opacity: f64,
        interactive: bool,
        screen_height: f64,
    ) {
        let local = rect(0.0, 0.0, frame.size.width, frame.size.height);
        self.window.setLevel(NSFloatingWindowLevel + 2);
        if let Some(layer) = self.effect.layer() {
            layer.setCornerRadius(if matches!(content, Content::Map(..)) {
                12.0
            } else {
                0.0
            });
        }
        if self.content != content {
            *self.view.ivars().content.borrow_mut() = content.clone();
            self.content = content;
            self.view.setNeedsDisplay(true);
        }
        if self.frame != frame {
            self.window.setFrame_display(
                rect(
                    frame.origin.x,
                    screen_height - frame.origin.y - frame.size.height,
                    frame.size.width,
                    frame.size.height,
                ),
                true,
            );
            self.view.setFrame(local);
            self.effect.setFrame(local);
            self.frame = frame;
        }
        self.window.setIgnoresMouseEvents(!interactive);
        self.window.setAlphaValue(opacity);
        if !self.visible {
            self.window.orderFrontRegardless();
            self.visible = true;
        }
    }
    /// Keep a tab bar directly above its own window, below foreign windows
    /// that cover it. The event tap also checks `WindowServer` order at click time.
    pub fn follow_window(&mut self, owner: i32) {
        self.window.setLevel(objc2_app_kit::NSNormalWindowLevel);
        self.window
            .orderWindow_relativeTo(objc2_app_kit::NSWindowOrderingMode::Above, owner as isize);
    }
    pub fn opacity(&mut self, value: f64) {
        self.window.setAlphaValue(value);
    }
    pub fn hide(&mut self) {
        if self.visible {
            self.window.orderOut(None::<&AnyObject>);
            self.visible = false;
        }
    }
}
impl Drop for Panel {
    fn drop(&mut self) {
        self.hide();
    }
}

pub struct VisualPanels {
    pub panels: Vec<Panel>,
    pub mtm: MainThreadMarker,
}
impl VisualPanels {
    pub fn new(mtm: MainThreadMarker) -> Self {
        Self {
            panels: Vec::new(),
            mtm,
        }
    }
    pub fn panel(&mut self, index: usize, content: &Content) -> &mut Panel {
        while self.panels.len() <= index {
            self.panels.push(Panel::new(self.mtm, content.clone()));
        }
        &mut self.panels[index]
    }
    pub fn hide_from(&mut self, index: usize) {
        for panel in self.panels.iter_mut().skip(index) {
            panel.hide();
        }
    }
}

#[derive(Clone, Copy, Debug)]
pub enum PointerPhase {
    Down,
    Drag,
    Up,
    Cancel,
}
#[derive(Clone, Copy, Debug)]
pub struct PointerInput {
    pub phase: PointerPhase,
    pub point: CGPoint,
    pub target: usize,
}
#[derive(Clone, Debug, PartialEq)]
pub struct HitRegion {
    pub frame: CGRect,
    pub panel: u32,
    pub owner: u32,
    pub target: usize,
}
static HITS: LazyLock<ArcSwap<Vec<HitRegion>>> =
    LazyLock::new(|| ArcSwap::from_pointee(Vec::new()));
static INPUT: Mutex<VecDeque<PointerInput>> = Mutex::new(VecDeque::new());
static CAPTURE: Mutex<Option<usize>> = Mutex::new(None);
static INPUT_PENDING: AtomicBool = AtomicBool::new(false);
#[derive(Clone)]
struct Occluder {
    number: u32,
    own: bool,
    frame: CGRect,
}
thread_local! {
    static BOUNDS_KEYS: [CFRetained<CFString>; 4] = ["X", "Y", "Width", "Height"].map(CFString::from_static_str);
}
struct HitOcclusion {
    frame: CGRect,
    visible: Option<CGRect>,
    blocked: Vec<CGRect>,
}
static OCCLUSION: LazyLock<ArcSwap<HashMap<usize, HitOcclusion>>> =
    LazyLock::new(|| ArcSwap::from_pointee(HashMap::new()));

pub fn has_input() -> bool {
    INPUT_PENDING.load(Ordering::Acquire)
}
pub fn has_hits() -> bool {
    !HITS.load().is_empty()
}
pub static HELD: AtomicBool = AtomicBool::new(false);
/// False when the platform had to fall back to a keyboard-only tap.
pub static POINTER_AVAILABLE: AtomicBool = AtomicBool::new(false);

pub fn set_hits(hits: Vec<HitRegion>) {
    if **HITS.load() != hits {
        HITS.store(Arc::new(hits));
        refresh_occlusion();
    }
}
pub fn take_input() -> VecDeque<PointerInput> {
    INPUT
        .lock()
        .map(|mut q| {
            INPUT_PENDING.store(false, Ordering::Release);
            std::mem::take(&mut *q)
        })
        .unwrap_or_default()
}
pub fn capturing() -> bool {
    CAPTURE.lock().is_ok_and(|capture| capture.is_some())
}
pub fn cancel_input() {
    HELD.store(false, Ordering::Relaxed);
    if let Ok(mut capture) = CAPTURE.lock() {
        *capture = None;
    }
    if let Ok(mut input) = INPUT.lock() {
        INPUT_PENDING.store(true, Ordering::Release);
        input.push_back(PointerInput {
            phase: PointerPhase::Cancel,
            point: CGPoint::ZERO,
            target: 0,
        });
    }
}

/// Refresh on the ECS main thread when hits change and while panels are
/// interactive. The HID callback never calls `WindowServer` or allocates CF keys.
pub fn refresh_occlusion() {
    if !has_hits() {
        OCCLUSION.store(Arc::new(HashMap::new()));
        return;
    }
    let Some(list) = CGWindowListCopyWindowInfo(
        CGWindowListOption::OptionOnScreenOnly | CGWindowListOption::ExcludeDesktopElements,
        kCGNullWindowID,
    ) else {
        OCCLUSION.store(Arc::new(HashMap::new()));
        return;
    };
    let list = unsafe { list.cast_unchecked::<CFDictionary<CFString, CFType>>() };

    let occluders: Vec<Occluder> = BOUNDS_KEYS.with(|keys| {
        list.iter()
            .filter_map(|dict| {
                let number = dict
                    .get(unsafe { kCGWindowNumber })?
                    .downcast::<CFNumber>()
                    .ok()?
                    .as_i32()?;
                let number = u32::try_from(number).ok()?;
                let own = dict
                    .get(unsafe { kCGWindowOwnerPID })
                    .and_then(|v| v.downcast::<CFNumber>().ok())
                    .and_then(|n| n.as_i32())
                    .is_some_and(|pid| u32::try_from(pid) == Ok(std::process::id()));
                let alpha = dict
                    .get(unsafe { kCGWindowAlpha })
                    .and_then(|v| v.downcast::<CFNumber>().ok())
                    .and_then(|n| n.as_f64())
                    .unwrap_or(1.0);
                if alpha <= 0.0 {
                    return None;
                }
                let bounds = dict
                    .get(unsafe { kCGWindowBounds })?
                    .downcast::<CFDictionary>()
                    .ok()?;
                let bounds = unsafe { bounds.cast_unchecked::<CFString, CFNumber>() };
                let value = |i: usize| {
                    bounds
                        .get(&keys[i])
                        .and_then(|n| n.as_f64())
                        .unwrap_or_default()
                };
                Some(Occluder {
                    number,
                    own,
                    frame: rect(value(0), value(1), value(2), value(3)),
                })
            })
            .collect()
    });
    // Resolve global z-order once here. A tap only looks up the target and
    // the few foreign rectangles intersecting that target, never every window.
    let cache = HITS
        .load()
        .iter()
        .map(|hit| {
            let mut visible = None;
            let mut blocked = Vec::new();
            for window in &occluders {
                if window.number == hit.panel && hit.owner == 0 {
                    visible = Some(hit.frame);
                    break;
                }
                if window.own {
                    continue;
                }
                if window.number == hit.owner {
                    visible = intersection(hit.frame, window.frame);
                    break;
                }
                if let Some(frame) = intersection(hit.frame, window.frame) {
                    blocked.push(frame);
                }
            }
            (
                hit.target,
                HitOcclusion {
                    frame: hit.frame,
                    visible,
                    blocked,
                },
            )
        })
        .collect();
    OCCLUSION.store(Arc::new(cache));
}

/// Cached z-order rejects foreign windows above the panel or tab owner.
fn unobscured(hit: &HitRegion, point: CGPoint) -> bool {
    OCCLUSION.load().get(&hit.target).is_some_and(|cached| {
        cached.frame == hit.frame
            && cached.visible.is_some_and(|frame| contains(frame, point))
            && !cached.blocked.iter().any(|frame| contains(*frame, point))
    })
}

fn intersection(a: CGRect, b: CGRect) -> Option<CGRect> {
    let left = a.origin.x.max(b.origin.x);
    let top = a.origin.y.max(b.origin.y);
    let right = (a.origin.x + a.size.width).min(b.origin.x + b.size.width);
    let bottom = (a.origin.y + a.size.height).min(b.origin.y + b.size.height);
    (right > left && bottom > top).then(|| rect(left, top, right - left, bottom - top))
}

/// Called on the main event tap. Only a captured left-button sequence is swallowed.
pub fn pointer(phase: PointerPhase, point: CGPoint) -> bool {
    // Resolve the candidate and cached occlusion before taking capture's lock.
    let down = if matches!(phase, PointerPhase::Down) {
        HITS.load()
            .iter()
            .find(|hit| contains(hit.frame, point) && unobscured(hit, point))
            .map(|hit| hit.target)
    } else {
        None
    };
    let Ok(mut capture) = CAPTURE.lock() else {
        return false;
    };
    let target = if matches!(phase, PointerPhase::Down) {
        down
    } else {
        *capture
    };
    let Some(target) = target else {
        return false;
    };
    if matches!(phase, PointerPhase::Down) {
        *capture = Some(target);
    }
    if matches!(phase, PointerPhase::Up | PointerPhase::Cancel) {
        *capture = None;
    }
    drop(capture);
    if let Ok(mut input) = INPUT.lock() {
        if matches!(phase, PointerPhase::Drag)
            && input
                .back()
                .is_some_and(|i| matches!(i.phase, PointerPhase::Drag))
        {
            input.pop_back();
        }
        if input.len() < 128 {
            INPUT_PENDING.store(true, Ordering::Release);
            input.push_back(PointerInput {
                phase,
                point,
                target,
            });
        }
    }
    true
}

/// Hidden diagnostic. It intentionally never constructs NSApplication/NSWindow,
/// installs taps, starts Bevy, queries AX, or loads a user's configuration.
#[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
pub fn render_diagnostic(path: &Path) -> Result<()> {
    // Real running apps, so the render shows real icons.
    let pids: Vec<i32> = NSWorkspace::sharedWorkspace()
        .runningApplications()
        .iter()
        .filter(|app| app.activationPolicy() == NSApplicationActivationPolicy::Regular)
        .map(|app| app.processIdentifier())
        .collect();
    let pid = |n: usize| (!pids.is_empty()).then(|| pids[n % pids.len()]);
    let model = MapModel {
        tiles: (0..6)
            .map(|i| Tile {
                apps: (0..4).map(|m| pid(i * 4 + m)).collect(),
                members: if i == 1 {
                    3
                } else if i == 3 {
                    4
                } else {
                    1
                },
                selected: if i == 2 { Some(0) } else { None },
                tabbed: i == 3,
                pinned: i == 0,
            })
            .collect(),
        focus: 2,
        pin_color: (76.0 / 255.0, 154.0 / 255.0, 1.0, 1.0),
        insertion: None,
    };
    let geometry = Geometry::new(&model, 1440.0);
    let space = CGColorSpace::new_device_rgb()
        .ok_or_else(|| Error::Generic("cannot create RGB space".into()))?;
    let ctx = unsafe {
        CGBitmapContextCreate(
            std::ptr::null_mut(),
            (geometry.width * 3.0).ceil() as usize,
            (geometry.height * 3.0).ceil() as usize,
            8,
            0,
            Some(&space),
            1,
        )
    }
    .ok_or_else(|| Error::Generic("cannot create bitmap context".into()))?;
    CGContext::scale_ctm(Some(&ctx), 3.0, 3.0);
    CGContext::translate_ctm(Some(&ctx), 0.0, geometry.height);
    CGContext::scale_ctm(Some(&ctx), 1.0, -1.0);
    draw_map(&ctx, &model, geometry);
    let image = CGBitmapContextCreateImage(Some(&ctx))
        .ok_or_else(|| Error::Generic("cannot create bitmap image".into()))?;
    let bitmap = NSBitmapImageRep::initWithCGImage(NSBitmapImageRep::alloc(), &image);
    let data = unsafe {
        bitmap.representationUsingType_properties(NSBitmapImageFileType::PNG, &NSDictionary::new())
    }
    .ok_or_else(|| Error::Generic("cannot encode PNG".into()))?;
    if !data.writeToFile_atomically(&NSString::from_str(&path.to_string_lossy()), true) {
        return Err(Error::IO(format!("cannot write {}", path.display())));
    }
    println!("{}", path.display());
    Ok(())
}
