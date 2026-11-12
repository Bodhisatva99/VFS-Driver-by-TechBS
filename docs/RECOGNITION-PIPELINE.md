# VFS491 recognition pipeline and Transaction 9 controls

## Evidence-based invariants

The archived upstream Validity proprietary driver source defines `VFS_PROPRIETARY_NR_ENROLL` as 1 and assigns `FP_IMG_COLORS_INVERTED | FP_IMG_V_FLIPPED` to the captured image. Transaction 5–8 kept those values. Transaction 9 continues to use one enrollment stage and the same image flags.

The bundled `FpImageDeviceClass` header documents 40 as the default Bozorth3 threshold. Transaction 9 assigns 40 explicitly so an implicit class default does not vary silently. Threshold changes are not part of this release.

## Why no speculative transformations are applied

Enrollment and verification pass through the same capture and image-construction function. The available logs establish that frames are delivered successfully, but they do not contain the actual grayscale samples or matcher minutiae/scores. Therefore they cannot establish whether the current false rejects are due to low-contrast frames, swipe speed/coverage, orientation, ridge extraction, template quality, or user swipe variation.

Changing rotation, mirroring, inversion, resizing, crop, enrollment stage count or matcher threshold without sample-level evidence would be an uncontrolled change. Lowering the matcher threshold can increase false accepts and is not used as a troubleshooting shortcut.

## Transaction 9 telemetry

The TOD backend logs only dimensions, payload size, min/max intensity, mean and standard deviation. It does not log image bytes or derived ridge/minutiae data.

`scripts/vfs491-image-diagnostics.py` collects multiple captures and reports:

- image dimensions and payload consistency;
- min/max and 5th/50th/95th intensity percentiles;
- mean, standard deviation and histogram entropy;
- dark/bright saturation proportions;
- row/column mean variation;
- horizontal/vertical mean absolute gradients;
- capture duration.

The utility emits metrics by default. It only writes raw PGM biometric images when the caller explicitly requests `--save-images`; output files are mode 0600 in a mode 0700 newly created directory.

## How to interpret the next evidence

- If frames have near-zero contrast or near-zero standard deviation, acquisition or helper output must be investigated before matching.
- If dimensions or quality metrics vary sharply for otherwise similar swipes, test swipe speed, direction and sensor coverage before modifying image processing.
- If metrics are stable but genuine verification still returns no-match, inspect libfprint image normalization/minutiae extraction and obtain matcher diagnostics from a build with suitable debug instrumentation.
- A different-finger rejection is required when evaluating any matcher change. A change that fixes genuine matches but also accepts different fingers is not acceptable.

No automatic quality threshold is enforced in Transaction 9 because a safe VFS491-specific operating range has not yet been measured.
