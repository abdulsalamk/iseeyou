# Limited hazard-alert prototype

Research only. Not a certified navigation or mobility aid, and never a replacement
for cane, guide dog or assistance. False negatives can cause harm.

## Capability boundary

The original camera, YOLO model, main-thread results, detection confidence control,
centre-region overlay, privacy and performance metrics are retained. Hazard
assessment uses all model results independently of the display slider.

The candidate trapezoid narrows from x=0.18–0.82 at the image bottom to
x=0.40–0.60 at y=0.55 (Vision coordinates). Object bottom-edge intersection is
only candidate geometry. Confidence and image area are gates, not distance.
There is no calibrated distance, ground segmentation, camera pose/motion provider,
floor-contact detector or verified free-space model in this delivery.

Live HazardContext consequently stays unknown and hazard-warning speech abstains even when
enabled. An explicitly labelled object-description preview and Test voice button
provide audible development testing without claiming that detections are hazards.
Preview uses the same confirmation/repeat policy, with an 80% confidence gate;
it never says stop, clear, safe, trip hazard or a numerical distance.
The two speech modes are mutually exclusive. The floor/supported/occluded, stable-pose, walking and imminent-evidence
inputs are seams for a future validated provider; they are not inferred from
object labels. No UI control lets users claim that unknown evidence is verified.
The direction “ahead” refers only to the candidate corridor, never a verified
safe alternative route.

Validated floor intersection plus likely interaction can produce caution.
Urgent requires an additional explicit imminent-interaction signal; bounding-box
size alone cannot supply that signal. Synthetic wall inputs exercise this seam;
the bundled COCO model does not detect a generic wall. SurfaceHazardProviding
declares validated capabilities, with an empty implementation today. Stairs,
kerbs, drop-offs, holes and uneven surfaces are not detected.

## Policy and lifecycle

Tracks match label and IoU >= 0.35 with one-to-one assignment. Caution needs
0.7 seconds of repeated evidence; urgent needs 0.2 seconds. A match gap over
0.3 seconds, empty/uncertain evidence or changed severity restarts confirmation.
A frame gap over 0.5 seconds or clock regression resets history.
An eight-second global repeat hold supplies output hysteresis despite track
jitter/reappearance. Urgent escalation bypasses that hold after confirmation.
Loss of evidence clears candidate confirmation immediately: it never asserts
that a route is clear. This intentionally favours abstention over continuity
through occlusion and can miss hazards.

Speech never queues behind an existing utterance. Urgent cancels current speech.
Stop, scene background, disappearance, speech/sensitivity changes, inference
failure and audio interruption cancel speech and clear temporal history.
Session generation checks reject old in-flight results after stop/restart.
Frames older than 500 ms and delayed main-thread deliveries are suppressed.
Audio route behaviour, VoiceOver coexistence and interruptions require device
testing; no private audio-session category or microphone use is added.

## Deterministic test matrix

All rows below are XCTest source coverage, **not executed results** in this Linux
environment. Swift, Xcode and an iOS SDK are unavailable here.

| Input | Expected |
| --- | --- |
| Same teddy geometry, supported vs floor evidence | Silence vs trip caution |
| Side chair vs floor chair blocking corridor | Silence vs caution |
| Synthetic wall + validated imminent interaction | Urgent after confirmation |
| Unknown depth/contact, occlusion, stationary/unknown motion, unstable pose | Silence |
| High bottom edge, tiny footprint, low confidence | Silence |
| Single-frame/jittering/temporarily absent observations | Confirmation or suppression |
| Repeated confirmed evidence | Eight-second repeat hold |
| Caution then sustained urgent | Escalation inside cooldown |
| Clock regression, dropped frames, reset | Confirmation restarts |
| Stop/background reset and speech off | Cancel audio, clear history |
| Surface provider unavailable | No capabilities or surface events |

Run the README Xcode build and simulator test commands on a Mac. Run tests under
Thread Sanitizer as well, then manually exercise start/stop/start, permission
denial/retry, background during inference, interruptions and audio routing.
The speech spy tests the cancellation contract; it does not validate AVFoundation
audio on a device. The UI and camera lifecycle integration need runtime testing.

## Illustrative decision trace (synthetic, no user video)

```text
camera: chair confidence=90% -> silence: Camera pose unknown or changing
fixture: teddy supported -> silence: Floor contact unverified, supported or occluded
fixture: teddy floor, walking, stable -> caution: Trip hazard ahead
policy: t=0.0..0.6 -> suppressed: temporal confirmation
policy: t=0.8 -> speak: Trip hazard ahead
policy: t=0.9 -> suppressed: repeat cooldown
fixture: imminent obstacle t=1.0..1.3 -> urgent: Obstacle ahead, stop
stop/background -> reset; cancel audio
```

These are expected states, not captured execution logs or performance results.
No screenshots or raw camera frames were collected.

## Next sensing step and supervised evaluation

First validate a timestamp-aligned floor/support segmentation and pose/motion
provider, then depth/ground-plane intersection, before wiring HazardContext.
See DEPTH_PLAN.md for metric-model conversion and calibration gates. Partial
occlusion must explicitly lower evidence quality. A dedicated validated surface
model is required for hazards outside COCO; do not relabel COCO detections.

Use supervised staged indoor fixtures with a sighted assistant and independent
ground truth, never navigation trials. Include identical soft objects on sofa
and floor, left/centre/right chairs, occlusion, lighting, phone tilt, stationary
user and orientation changes. Record true/false actionable alerts and missed
hazards with denominators; derive precision/recall and false alerts per minute.
Measure time from ground-truth hazard onset to audible alert, battery/energy,
memory and thermal behaviour during sustained runs. Frame age and inference
duration are not alert latency. Record device/OS/model versions and compare
sensitivity settings on held-out trials.

No precision, recall, false-alert rate, missed-hazard rate, audio latency, battery
or thermal result is measured for this change. Live alert recall is effectively
zero while evidence remains unknown. This draft is an incremental foundation,
not completion of reliable live path-aware hazard detection.
