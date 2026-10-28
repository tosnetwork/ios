# Legacy recovery keyboard readiness

The `ee55d120` hosted CI run `40684751709` failed before pasting its public
recovery fixture. Its original iPhone SE 3 / iOS 26.2 result video shows the system
slide-typing introduction covering the keyboard, with the text “Speed up your
typing by sliding your finger across the letters to compose a word.” and Continue.
The original paste-readiness predicate could not become true.

The test helper now dismisses only that exact introduction inside the keyboard,
using its Continue button, before applying the original predicate:
`keyboard.exists && paste.isHittable && paste.frame.maxY <= keyboard.frame.minY`.
Its five-second timeout and assertion remain unchanged. A failed predicate also
retains the UI hierarchy for diagnosis. No product code, simulator preferences,
CI test selection or rejection assertion is weakened.

Local root-Make validation used two new SE 3 simulators on iOS 26.5 with the same
offline RPC setting as CI. The original helper passed (34.684s), and the repaired
helper passed (36.143s). Neither fresh device showed the introduction, so this is
a normal-layout regression result, **not** a reproduced negative control or proof
that the new system-tip selector was hit. Local iOS 26.5 is not hosted iOS 26.2.
No tutorial was mocked or system preference changed to manufacture a failure.
The latest repair head still needs hosted-CI verification; if no introduction
appears there either, a normal pass must not be reported as selector-hit evidence.

Raw CI artifacts, video frames, both local xcresults/logs, exact original/fixed
source hashes and `ios-ci-tip-local-validation.json` are retained under
`/Users/tomisetsu/validation/mobile-quantum-handoff/`, outside Git. Both dedicated
local simulators are shut down; existing device data was not erased.
