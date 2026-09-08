# Self-hosted Flutter fallback fonts

Unmodified Noto Sans KR and Noto Sans Symbols 2 WOFF2 subsets referenced by
Flutter 3.47.2's `font_fallback_data.dart`. Originally distributed at
`https://fonts.gstatic.com/s/` and covered by the accompanying SIL OFL licenses.

The bootstrap points Flutter's fallback loader here, including text styles
which use engine fallback instead of the app's bundled NotoSansKR family.
No runtime font requests to Google are required for Korean or these symbols.
Other scripts/emoji are not bundled; missing fallbacks return 404 locally.

To refresh, review the pinned SDK and licenses, then run:
`node tool/vendor_flutter_fonts.cjs /path/to/flutter`
