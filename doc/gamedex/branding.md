# GameDex branding

The Apple AppIcon asset reuses the official GameDex 1.2.1 application icon from
its bundled asset catalog, extracted from the locally installed application.
macOS preserves the transparent icon; iOS uses an opaque charcoal backing.
The artwork remains the property of its original owner; the mGBA source license
does not grant rights to the GameDex branding.

The 2.0.0 variant uses a teal and violet recolor made with the built-in image
generation tool. The generated base contains no lettering. `icon/app-icon.svg`
composes the raster base and the separate `icon/version-overlay.svg` layer;
the “2” is an outlined SVG path, with no font dependency. Run
`tools/gamedex/build-icons.sh` (librsvg and ImageMagick required) to regenerate
all Apple icon sizes. iOS receives an opaque charcoal backing.

Recolor prompt: “Edit target: the provided GameDex app icon. Recolor ONLY:
replace the orange/coral upper gradient with teal/turquoise and the lower
purple wave with cool indigo/violet. Preserve the exact underlying charcoal
stacked handheld/controller symbol, outlines, positions, proportions, circle
silhouette, and wave geometry. Flat clean app icon, square 1024 by 1024. Keep
charcoal corners. No new elements. NO text, NO numerals, NO number 2, NO badge.
A numeral will be added separately as an SVG layer; do not generate it.”
