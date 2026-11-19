# Flute design system

Source of truth for the look. Code: `lib/app/theme.dart` (tokens and component themes). Read this before
changing a screen; change a token instead of a screen when you can.

## Principles

Researched from current mobile references (Bolderr "Atlas" study, Muzli's 2026 mobile UI patterns, Behance AI-assistant
case studies) and fitted to a minimalist launcher.

1. **Confidently quiet.** The canvas is near-black and everything is neutral. Exactly one thing per screen glows:
   the accent marks what is active, selected, primary or alive. If everything is teal, nothing is.
2. **Depth is luminance, not shadow.** Four tonal surfaces (`bg < surface < surfaceHigh < surfaceTop`) plus a 1 px hairline.
   Drop shadows do not read on dark; raised things get lighter, overlays get the lightest.
3. **The gradient is rationed.** `FluteGradients.signature` is for the voice orb, the creating-image canvas and the send button.
   Never a large surface.
4. **Thumb first.** Primary actions live in the bottom third (composer dock, sheet buttons). The top of the screen is for
   reading and for quiet, secondary controls. Secondary content goes in bottom sheets with a grabber, not new screens.
5. **Airy density.** 4 px scale, 16 px gutters, 24 px between sections, 48 dp targets, one primary action per screen.
6. **Motion explains.** State changes animate (180-320 ms, ease-out); gestures and confirmations give a light haptic;
   everything respects reduced motion (`motion(context, ms)`).
7. **Type does the hierarchy.** Inter for reading and controls, Inter Display (medium) for titles. Medium and semibold, never
   heavy, never light (Inter ships 400/500/600 here). The Home clock is the one thin thing (system Roboto).

## Tokens

| Role | Token | Value |
|---|---|---|
| Canvas | `FluteColors.bg` | `#050809` |
| Card, list tile | `FluteColors.surface` | `#0E1417` |
| Raised, input, sheet | `FluteColors.surfaceHigh` | `#151D21` |
| Overlay, menu, dialog, pressed | `FluteColors.surfaceTop` | `#1C262B` |
| Hairline / strong hairline | `line` / `lineStrong` | `#1F2A2F` / `#2E3C42` |
| Text | `text` / `textSecondary` / `muted` / `faint` | `#E8F1F2` / `#B7C5C9` / `#8A9BA0` / `#5E6E73` |
| Accent | `accent`, `accentSoft` (14 % tint), `onAccent` | `#5EEAD4`, `#245EEAD4`, `#00201B` |
| Warning / danger | `warn` / `danger` | `#F5B86B` / `#E39A8C` |
| Radii | `FluteRadius` | 10 / 14 / 20 / 28 / pill |
| Spacing | `FluteSpace` | 4 / 8 / 12 / 16 / 24 / 32 |
| Type | `FluteText` | display 30, title 21, heading 16, body 15, label 14, caption 12.5, overline 11.5 |

## Component rules

- **Buttons.** One `FilledButton` (accent) per screen is the primary action. Secondary is `OutlinedButton`; tertiary is
  `TextButton` (accent text). Destructive is a `TextButton` in `danger`, behind a confirmation.
- **Inputs.** Filled `surfaceHigh`, radius 14, no underline, accent ring on focus. Always a label (not only a hint).
- **Selection.** `SegmentedButton`/chips: selected = `accentSoft` fill with accent text; unselected = `surfaceHigh`.
- **Switches.** On = accent track. Nothing else on the row is accent.
- **Sheets and menus.** `surfaceHigh`/`surfaceTop`, radius 28 on top, grabber, hairline. Dialogs radius 28, `surfaceTop`.
- **Lists.** Group rows in a `surface` card with hairline separators; row = icon in a tinted square, title, one-line status, chevron.
- **Status.** Quiet text or a `CalmTag`; colour only for "needs you" (`warn`) or failure (`danger`).
- **Empty states.** One display line, one calm sentence, at most four suggestion chips.

## Do / don't

- Do use tokens. Don't write `Color(0x...)`, raw radii or raw font sizes in a screen.
- Do keep one accent element per screen region. Don't fill large areas with the accent or the gradient.
- Do add a haptic to primary confirmations. Don't hide a feature behind a gesture without a visible fallback.
