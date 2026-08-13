# render-pass

The measured UI audit proven on digitally-undressed PR #90. Run when the
operator reports rendering issues, contrast problems, or asks for a mobile
and desktop render audit of any web surface. Every claim is measured, never
eyeballed. Animation behavior is caught by disabling reduce-motion at test
time, since headless Chrome defaults to reduce and hides real motion.

Use when the operator asks: rendering audit, contrast check, mobile and
desktop sweep, accessibility audit, or reports rendering bugs.

## The setup

Clone the target repository. Serve it locally via `php -S localhost:8000` or
the repo's dev server command. Drive a real headless Chrome instance via
puppeteer-core. Do NOT use the Chrome DevTools remote debugging port - it
reports simulated values, not real rendering. Use real computed styles from
the running page.

## The sweep, per viewport

Test at three widths: 390 (mobile), 768 (tablet), 1440 (desktop). For each
width, perform all checks below.

1. MOTION DEFAULTS. Set `prefers-reduced-motion: no-preference` on the test
   environment. Headless defaults to `reduce` and hides animation behavior
   entirely. Verify that motion works and does not break layout.

2. SCROLL WIDTH EQUALS CLIENT WIDTH. At every viewport, measure
   `document.scrollWidth` and `document.clientWidth`. They must match. If
   scrollWidth exceeds clientWidth, horizontal scroll is present and is a
   defect unless intentional. Prove intention with a comment.

3. STICKY ELEMENT SPACE RESERVE. For every sticky header, sticky footer, or
   fixed button bar, verify it reserves space. Use one of these patterns:
   
   - Scrollable ancestor has `scroll-padding-top` or `scroll-padding-bottom`
     matching the element height.
   - A lane or margin reserves space for floating buttons.
   - Content flow accounts for the fixed element height.

4. CONTRAST RATIO MEASUREMENT. For every claim of contrast or color change,
   MEASURE it. Do not eyeball. Do not hand-compute hex values. Use the WCAG
   2.1 luminance formula on resolved computed styles. Compose ancestor
   backgrounds using alpha blending. The formula:

   ```
   L = 0.2126 * R + 0.7152 * G + 0.0722 * B
   (after gamma-correcting each channel: 
    if channel <= 0.03928, divide by 12.92; else ((channel + 0.055) / 1.055) ^ 2.4)
   contrast = (L_light + 0.05) / (L_dark + 0.05)
   ```

   Report the before ratio and after ratio for every change. Verify that
   after >= 4.5 (AA) or >= 7.0 (AAA) as the design requires.

## Proof and reversion

For every fix, prove it CAN FAIL. Stash the patch. Measure again. Verify the
before state comes back. Unstash. Measure one more time. Confirm the fix is
present. This proves the fix is real and not a measurement artifact.

## Reframing, not deletion

Fix by reframing never deleting. The reference standard is 253 additions and
0 deletions. If your fix deletes lines, reframe the approach. Example: instead
of removing a background, add a `color: transparent;` or a `background:
inherit;`. Reframing preserves debugging and shows intent.

## Report shape

Report two screenshots per fix: before and after. State the viewport width,
the change claimed, and the MEASURED contrast ratio or scrollWidth evidence.
If a reported problem did not reproduce at any viewport or did not appear in
computed styles, state plainly: ALREADY HONEST. Do not hide unreproducible
findings.
