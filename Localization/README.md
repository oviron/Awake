# Localization

Awake follows the macOS language order. With a matching translation it uses
that language; otherwise it falls back to English. To choose a different
language for Awake alone, use **System Settings → General → Language & Region →
Applications**. The `awake` command follows the same setting.

Available: English (`en`), Russian (`ru`).

## Add a language

1. Copy `en.lproj` to a folder named after the language code, for example
   `de.lproj`, `pt-BR.lproj` or `zh-Hans.lproj`.
2. In `Localizable.strings`, translate only the text right of `=`:

   ```
   "Keep awake with lid closed" = "Wach bleiben bei geschlossenem Deckel";
   ```

   Keep every key. Keep each placeholder (`%@`, `%lld`, `%d`) of the English
   text; reorder them with positions such as `%2$@ … %1$@`. Write a literal
   percent sign as `%%` when the English text does.
3. `Localizable.stringsdict` holds plural forms. Give the
   [plural categories](https://www.unicode.org/cldr/charts/latest/supplemental/language_plural_rules.html)
   your language uses (`one`, `few`, `many`, `other`…). Omit the file if the
   language has no plural forms; `Localizable.strings` is then used.
4. Optional: `SudoInfoPlist.strings` translates the text of the administrator
   prompt shown when enabling Touch ID for sudo. See `ru.lproj` for an example.
5. Run the checks and preview the menu in your language:

   ```sh
   swift Tools/ProjectTool.swift check
   swift Tools/ProjectTool.swift preview
   ```

   The preview writes `menu-preview-<language>.png` next to the app. Keep labels
   short enough for the 340-point menu.

A new `.lproj` folder needs no code or project changes: the build copies every
folder and lists it in the app's `CFBundleLocalizations`.

## When the English text changes

`en.lproj/Localizable.strings` is generated from the Swift sources. After adding
or changing user-facing text, run:

```sh
swift Tools/ProjectTool.swift strings
```

Then update the same keys in every translation. `check` fails while the English
file is stale or a translation misses, adds or changes keys or placeholders.

In code, SwiftUI string literals (`Text("…")`, `Toggle("…")`) are localized
automatically. Text stored in a `String` uses `String(localized:)`; in the
`awake` command, add `bundle: .awake`. Use `Text(verbatim:)` for text that must
not be translated.
