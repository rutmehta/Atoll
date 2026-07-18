# NotchNook (lo.cafe) — Complete Research Summary

## What it is
NotchNook is a Swift/SwiftUI macOS utility by lo.cafe (developer known as "kinark", Brazilian) that turns the MacBook notch into a Dynamic Island-style hub. Hovering/clicking the notch expands it into "the Nook" — a panel of configurable widgets plus a files Tray with AirDrop. When collapsed, it renders "live activities" (album art + waveform, battery/Bluetooth events, calendar) on either side of the notch. It also replaces the macOS volume/brightness HUDs with notch-integrated indicators.

## Distribution, versions, requirements
- Requires macOS 14.6+; runs on Apple Silicon and Intel; built with Swift/SwiftUI; ~40-60 MB. Works on macOS 15 (fixes shipped for 15.4) and macOS 26 (adopts Liquid Glass styling in the Timer widget).
- NOT on the Mac App Store. Distributed via lo.cafe direct download, Setapp, and Homebrew cask `notchnook`. Sparkle-style auto-updater with silent reminder option.
- Pricing: $3/month subscription (2 devices) or $25 one-time (5 devices); 48-hour free trial (originally 24h); 15-day refund; license recovery portal; billing at pay.lo.cafe. 29+ localizations via Crowdin.
- Version timeline: 1.0 (mid-2024) → 1.1 (Jun 2024: Calendar, QuickPeek) → 1.2 (Aug 2024: auto-width nook, HUD replacement, global media) → 1.3 (Oct 2024: HUD replacement polish, lock button, keyboard nav) → 1.4 (Oct-Dec 2024: Notes widget, custom GIFs, fine-tuning) → 1.5.x (2025: AirDrop text/URLs, calendar overhaul, universal media restored) → 1.6.0 (Mar 2026: Timer + To-do widgets) → 1.6.1/1.6.2 (Jun 2026 polish) → mid-July 2026 major update (battery/Bluetooth live activities, multi-source media selector, draggable seek bar, tray stacking/persistence/clipboard).

## Core interaction model
Collapsed state looks exactly like the hardware notch (invisible). Hover reacts, click/hover/swipe (user-selectable trigger) expands into the Nook. Two-finger swipe gestures open/close the nook and skip tracks; closing has a "squeeze" animation. Scroll + horizontal mouse-wheel supported; keyboard navigation supported. A lock/pin button keeps the Nook open. After interacting, focus is restored to the previously focused window. Dragging a file toward the notch auto-expands it revealing Tray + AirDrop drop zones.

## Widgets (user-orderable, auto-width nook grows/scrolls to fit any number)
Media Player (universal now-playing: Apple Music, Spotify, YouTube, VLC, SoundCloud, browser media; album art, waveform, controls, draggable progress bar, multi-source selector, optional restrict-to-Music/Spotify), Calendar (EventKit; day view, swipe between days, calendar picker, exclude all-day/multi-day, click-to-open Calendar app), Mirror (webcam preview, mirroring toggle, external camera sources), Shortcuts (run macOS Shortcuts), Notes (quick notes; Esc support; export + full windows planned), Timer (1.6.0; wheel pickers, Liquid Glass), To-dos (1.6.0; favorites, complete, auto-archive). "Quick Apps" widget was long listed "coming soon". No weather widget, no system-stats widget, no clipboard-history widget, and NO AI features exist (competitor roundups claiming CPU/RAM stats or weather are inaccurate).

## Tray & AirDrop
Tray = temporary shelf: drag files/folders in (copies, original untouched; Option+drag moves), auto-stacking of multiple files, persistence across restarts, paste files from clipboard, Quick Look via Space, rename via Return/right-click, delete via Delete key or X, Shift multi-select, Cmd+C, right-click context menu (remove, AirDrop), drag out anywhere. AirDrop drop zone opens the AirDrop flow for files and also accepts text and URLs. Screenshots can be collected in the tray. Planned "Pipelines": user-definable drop actions (zip/unzip, image compress/resize, public links, terminal commands, shareable pipelines).

## Live activities & HUD
Collapsed-bar live activities: now playing (art + animated spectrograph that pauses when paused), QuickPeek on song change, calendar event live activity (auto-clears when event ends), battery state changes (charging/unplugged/full/low, animated), Bluetooth connect/disconnect. Master "Enable live activities" toggle; per-fullscreen-app behavior configurable; style effects (e.g., "vibration" visualizer style). HUD replacement moves volume/brightness (plus lock indicator) into the notch — requires Accessibility permission; option to show HUD on all screens; custom HUD fine-tuning.

## Non-notch & multi-display
On notchless/external displays renders a smaller centered virtual-notch "handler" with identical functions (can be disabled per non-notch screens); multi-monitor supported; live-activity bar height adjustable on non-notch displays; MacStories criticized that it always looks like a notch on externals.

## Customization
Open trigger (click/hover/swipe), gesture toggles (open/close, media gestures, "Allow Gestures"), notch blend/hide/accentuate, width/height fine-tuning, corner shape values, rounded vs standard buttons, custom GIFs inside the notch, per-widget sizes + Tray size, widget reorder, spacing/transparency/padding, hide media bar in fullscreen, disable Nook entirely, resizable settings window. Permissions needed: Accessibility (HUD), Calendar, Camera, Automation (Spotify/Music control); Digital Trends noted it asks for extensive permissions.

## Known limitations (useful for clone parity)
Early versions: no volume slider in media widget, no Podcasts.app/QuickTime detection, calendar can't be opened (fixed 1.5.1), no bulk tray selection (fixed 1.2.5), built-in webcam only (external sources added 1.3-1.4), now-playing preview can overlap fullscreen content, collapse animation sometimes rough. Feature requests still open/planned: Add-to-Library button for Spotify/Apple Music, HUD replacement without Accessibility permission, prevent focus stealing, expanded notes windows, Pipelines.

FEATURES:
- CORE: Invisible-at-rest design — collapsed state looks identical to the hardware notch; app draws a black window merged with the notch that only reveals itself on interaction, using no menu bar space for its UI
- CORE: Hover-to-react, click/hover/swipe-to-expand — moving the cursor onto the notch highlights it; the expansion trigger is user-selectable in settings between click, hover, or swipe
- CORE: Expanded 'Nook' panel — notch animates open into a widget dashboard; auto-width expansion grows the panel to fit however many widgets are enabled, with horizontal scrolling when widgets exceed available width (v1.2)
- CORE: Smooth open/close animations with a 'squeeze' effect when swiping closed; natural spring-style transitions (v1.2/1.2.7)
- CORE: Lock/pin button inside the Nook keeps it open so it doesn't auto-collapse; repositioned in v1.4.1 to avoid accidental clicks
- CORE: Window focus restoration — after interacting with the Nook, keyboard focus returns to the previously active app window (v1.2); 'never steal focus' is a further planned item
- CORE: Keyboard navigation within the Nook (improved v1.3) and horizontal mouse scroll wheel support (v1.1)
- GESTURES: Two-finger swipe down/up on the notch opens/closes the Nook; separate settings toggles for 'notch open/close' gesture, 'media control' gesture, and a master 'Allow Gestures' toggle (all default-on, restored in v1.6.2)
- GESTURES: Two-finger horizontal swipe on the collapsed notch/media area skips to next/previous track
- WIDGET SYSTEM: User can enable/disable widgets and rearrange their order; per-widget size adjustment and Tray size adjustment to balance visibility vs minimalism
- MEDIA WIDGET: Now-playing card with large album artwork, track title/artist, play/pause and next/previous controls
- MEDIA WIDGET: Universal/global media detection — controls media from any app (Apple Music, Spotify, YouTube in browser, VLC, SoundCloud, Spotify podcasts), not just Music/Spotify (v1.2, restored in v1.5.1); settings option to restrict detection/control to only Apple Music or only Spotify
- MEDIA WIDGET: Fully draggable progress/seek bar to scrub forward/backward in music and videos with real-time progress tracking (mid-2026 update)
- MEDIA WIDGET: Multi-source Now Playing selector to switch between simultaneous audio sources (mid-2026 update)
- MEDIA WIDGET: Early limitations to be aware of: no volume slider in the widget; Podcasts.app and QuickTime Player were not detected (Macworld, 2024) — clone should decide whether to match or exceed
- MEDIA LIVE ACTIVITY: When music plays with notch collapsed, album artwork thumbnail appears on left of notch and an animated audio waveform/spectrograph on the right (Dynamic Island style), widening the notch slightly; spectrograph animation pauses when playback pauses
- MEDIA LIVE ACTIVITY: 'QuickPeek' — brief automatic peek/expansion showing track info when the song changes (v1.1/1.2.4)
- LIVE ACTIVITIES: Master 'Enable live activities' settings toggle to turn the collapsed-bar animations off entirely
- LIVE ACTIVITIES: Battery live activity — automatically shows animated notch indicators for charging started, power disconnected, battery full, and low battery (mid-2026 update; was a 'planned' roadmap item with 21 upvotes before shipping)
- LIVE ACTIVITIES: Bluetooth live activity — visual notch notification when Bluetooth devices connect or disconnect (mid-2026 update)
- LIVE ACTIVITIES: Calendar live activity — upcoming event surfaced at the notch; automatically cleans up/disappears after the event ends (v1.5.5)
- LIVE ACTIVITIES: Configurable live-activity behavior when a fullscreen app is active (mid-2026 update); earlier: option to hide the media bar in fullscreen (v1.4.x) and notch becomes visible on hover while in fullscreen (v1.4.4)
- LIVE ACTIVITIES: Style/effect options for the live-activity visualizer (e.g. a 'vibration' style effect exists per feedback board)
- CALENDAR WIDGET: Day-at-a-glance list of upcoming events pulled from macOS Calendar (EventKit); added in v1.1
- CALENDAR WIDGET: Swipe left/right within the widget to move between days/dates
- CALENDAR WIDGET: Calendar selection — choose which calendars are shown (v1.4.3), with select-all and clear-selection buttons (v1.5.1)
- CALENDAR WIDGET: Options to exclude all-day and multi-day events; improved event time formatting (v1.5.1)
- CALENDAR WIDGET: Click an event to open the Calendar app (v1.5.1; earlier versions couldn't launch Calendar)
- CALENDAR WIDGET: Correct timezone handling and repeating/recurring meeting display (fixed v1.2)
- MIRROR WIDGET: One-click webcam preview ('FaceTime mirror') for checking appearance before calls; circular preview; camera session properly closes on collapse (fixed v1.4)
- MIRROR WIDGET: Toggle to flip/mirror the camera image (v1.4.x)
- MIRROR WIDGET: Multiple mirror sources — support for selecting external cameras, not just built-in webcam (v1.3 'multiple mirror source support', completed v1.4 'external mirror source')
- SHORTCUTS WIDGET: Buttons to trigger user-selected macOS Shortcuts (from the Shortcuts app) directly from the Nook — usable as a quick app/automation launcher
- NOTES WIDGET: Quick scratch notes typed directly in the Nook without leaving the current window (v1.4); Escape key dismisses/works in notes (v1.5.5); note export and full note windows are announced/planned
- TIMER WIDGET: Countdown timer added in v1.6.0 (Mar 2026) — wheel-style duration pickers with haptic-like feedback, progressive blur, smooth animations, and Liquid Glass styling on macOS 26 (polished in v1.6.1)
- TO-DO WIDGET: Task list added in v1.6.0 — create tasks, favorite/star important ones, tap to complete, automatic archiving of finished tasks (was 'coming soon' throughout 2024-2025)
- PLANNED WIDGET: 'Quick Apps' (app launcher) shown as 'Coming soon' in the widget picker — never confirmed shipped; include for parity decisions
- TRAY (file shelf): Drag files/folders onto the notch — it auto-expands mid-drag revealing two drop zones: Tray and AirDrop
- TRAY: Dropping a file stores a temporary copy (original file is NOT moved or deleted); acts as a cross-app/cross-desktop staging shelf
- TRAY: Option(⌥)+drag to MOVE files into the tray instead of copying (mid-2026 update)
- TRAY: Automatic stacking when multiple files are dragged in at once (mid-2026 update)
- TRAY: Tray contents persist across app restarts (mid-2026 update)
- TRAY: Add files directly from the clipboard (paste into tray) (mid-2026 update)
- TRAY: File management shortcuts — Delete key or corner X to remove; Spacebar for Quick Look preview; Cmd+C to copy; Shift-click multi-select; Return or right-click to rename; drag-and-drop out to any app (v1.2.5 tray overhaul)
- TRAY: Right-click context menu on tray items with Remove and AirDrop actions (v1.3)
- TRAY: Works as a screenshot collector (drag screenshots in from different sources); tray width defaults aligned to Nook width to reduce accidental dismissal (v1.5.5)
- AIRDROP: Dedicated AirDrop drop zone in the expanded notch — drop a file to immediately invoke the macOS AirDrop share flow
- AIRDROP: AirDrop accepts dragged text selections and URLs, not just files (v1.5.1)
- PLANNED 'PIPELINES': announced custom drop actions — zip/unzip, image compression/resizing, generate public share links, run terminal commands on dropped files, with user-created shareable pipelines (announced by dev in iMore interview; still roadmap)
- HUD REPLACEMENT: Replaces macOS's center-screen volume and brightness square overlays with slim indicators integrated into/next to the notch (v1.2/1.3); includes a lock indicator replacement; requires Accessibility permission (a request to do it without Accessibility is 'in review' on the feedback board)
- HUD REPLACEMENT: Settings toggle to show the HUD indicator on all connected screens or only the main one (v1.4.3); custom HUD fine-tuning ranges expanded (v1.4.2); custom HUD no longer blocks notch interactions (fixed v1.4.x)
- NON-NOTCH SUPPORT: On Macs/displays without a notch, renders a smaller centered virtual notch 'handler' (about half size) at the top of the screen with the exact same functionality; per-screen option to disable the handler on non-notched screens (v1.1)
- MULTI-DISPLAY: Multi-monitor support — notch/handler and HUD can appear across displays; live-activities bar height adjustable for non-notch displays (v1.3); MacStories criticism: it always looks like a notch even on external displays (no floating-island style)
- FULLSCREEN BEHAVIOR: When an app is fullscreen the notch UI hides; hover reveals it (v1.4.4); option to hide media bar in fullscreen; fullscreen live-activity visibility fixed on non-notched screens (v1.5.1/1.5.5); per-fullscreen behavior customization for live activities (mid-2026)
- CUSTOMIZATION: Notch appearance — blend, hide, or accentuate the notch; adjustable overall notch/Nook size, width and height fine-tuning (v1.4), shape/corner-radius values, rounded vs standard button styles (v1.4)
- CUSTOMIZATION: Custom GIFs — user can pick personal GIFs to display inside/around the notch area (v1.4.4)
- CUSTOMIZATION: Layout spacing, transparency, and padding between widgets are adjustable (HowToGeek)
- CUSTOMIZATION: Option to fully disable the Nook expansion (v1.1), and separately disable live activities, gestures, HUD replacement — everything is individually toggleable
- SETTINGS APP: Dedicated settings window (redesigned v1.1, reorganized sections, resizable with corrupt-size auto-recovery in mid-2026 update); settings sections cover General, widgets, gestures, HUD, screens, media sources, calendar selection
- LOCALIZATION: 29+ languages, community-translated via Crowdin (multi-language support since v1.2)
- UPDATES: Built-in auto-updater (Sparkle-style) with silent update reminders (v1.1; auto-update fixed v1.2.6); active development cadence with public changelog and feedback/roadmap board at feedback.notchnook.cafe (Featurebase: changelog, feature requests with statuses Planned/In Progress/In Review/Shipped, upvotes, email subscriptions)
- PERMISSIONS: Requests Accessibility (HUD replacement + media keys), Calendar (EventKit), Camera (mirror), Automation/AppleScript (Spotify & Apple Music control); reviewers note the permission list is extensive — plan a granular onboarding that requests permissions per-feature
- PERFORMANCE: Marketed and reviewed as lightweight — Swift/SwiftUI native, low CPU/battery use; multiple releases dedicated to memory-leak and CPU fixes (v1.2.1, v1.4, v1.4.3) and animation performance; known perf issue report: vibration-style effect on multi-monitor setups
- PLATFORM: Requires macOS 14.6 or later; universal binary (Apple Silicon + Intel); tested/fixed against macOS 15.x and macOS 26 (Liquid Glass adoption); ~40-60 MB app size
- DISTRIBUTION: Direct download from lo.cafe (not in Mac App Store), Setapp listing, Homebrew cask 'notchnook'; bundle id lo.cafe.NotchNook
- LICENSING/TRIAL: 48-hour free trial (was 24h at v1.1); $3/month subscription activates 2 devices; $25 one-time license activates 5 devices; 15-day refund window; license recovery portal; device reset via support email; billing portal at pay.lo.cafe; periodic 35% promo coupons
- EXPLICITLY ABSENT (do not copy from competitor roundups): no weather widget, no CPU/RAM/system-stats widgets, no clipboard-history manager (user-requested only), no Pomodoro-branded mode (plain timer only), no notification mirroring, and no AI features of any kind as of v1.6.2 (July 2026)
- OPEN FEATURE REQUESTS on official board (useful clone roadmap): battery live activity (since shipped), Add-to-Library button for Spotify/Apple Music, HUD replacement without Accessibility permission, keep-open when moving tray→nook, prevent focus stealing, expanded notes windows, name-and-display-space handling