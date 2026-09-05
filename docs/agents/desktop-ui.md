# Desktop UI

## Accessibility

GPUI does not yet expose a screen-reader tree. Preserve keyboard operability,
system settings, and legibility:

- Every mouse control must be keyboard reachable and operable. Use `track_focus`
  with `tab_index`, `tab_group`, and `tab_stop`, show focus via `focus_visible`,
  and support conventional widget keys: arrows, `home`/`end`, `enter`/`space`,
  and `escape`.
- Honor reduce motion. `with_animation` respects `App::reduce_motion`; direct
  `window.request_animation_frame` calls for decorative motion must check
  `cx.reduce_motion()` and skip the request when enabled.
- Pair status colors with icons or text. Anything revealed on hover must also
  be reachable by keyboard focus. Meaning must not depend on motion alone.
- Keep text and icons legible in both themes. Extend interactive hit regions
  rather than shrinking controls to their glyphs.
