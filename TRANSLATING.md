# Translating AnyPS5

Every AnyPS5 app reads the texts it shows from plain JSON files, one per language. No
programming is needed to add a language: you add one file, and the app lists the language in
**Settings › Language**. This guide covers all three apps; their files are alike and follow the
same rules.

| App | Its files |
|---|---|
| Windows/Linux launcher | [`assets/l10n`](assets/l10n) in this repository |
| Mac launcher | [`tools/macos/launcher/l10n`](https://github.com/AnyTogether/AnyPS5-ARM/tree/main/tools/macos/launcher/l10n) in AnyPS5-ARM |
| Phone app (AnyPS5 Remote) | [`mobile/assets/l10n`](https://github.com/AnyTogether/AnyPS5-ARM/tree/main/mobile/assets/l10n) in AnyPS5-ARM |

`en.json` is English, the source every other language is translated from.

The Windows/Linux launcher has these languages so far:

| Language | File | Translated by |
|---|---|---|
| Turkish | `tr.json` | the AnyPS5 team |
| German, Spanish, French, Portuguese, Indonesian, Russian, Japanese | `de`, `es`, `fr`, `pt`, `id`, `ru`, `ja` | VK |
| Hindi, Bengali, Bhojpuri, Arabic, Urdu | `hi`, `bn`, `bho`, `ar`, `ur` | VK |
| Czech, Danish, Hungarian, Norwegian, Romanian, Swedish, Filipino, Malay | `cs`, `da`, `hu`, `no`, `ro`, `sv`, `fil`, `ms` | VK |
| Simplified Chinese, Traditional Chinese, Korean, Khmer, Lao, Amharic | `zh-Hans`, `zh-Hant`, `ko`, `km`, `lo`, `am` | VK |
| Polish | `pl` | QguAr71 |

Arabic and Urdu read right to left: the launcher's screens are mirrored for them, and ← and → follow
what the screen shows. A new file for another language written right to left (Persian, Hebrew) is
mirrored too.
The launcher starts in the computer's language the first time when it has a file for it. Chinese
follows the script or region (zh-Hant for Taiwan, Hong Kong and Macau). Norwegian Bokmål and
Nynorsk read `no.json`, and Tagalog reads `fil.json`.
Improvements to any of these files are welcome, the same way as a new language. A hosted Weblate project is coming, where several people can translate one language
at once in the browser; until then, translate the files as below. The files stay the same
either way, so nothing you do now is lost.

## Add a language

1. Copy `en.json` and name the copy after your language's code: `de.json` for German, `fr.json`
   for French, `pt-BR.json` for Brazilian Portuguese, `zh-Hant.json` for Traditional Chinese. Use
   the two-letter [ISO 639-1 code](https://en.wikipedia.org/wiki/List_of_ISO_639_language_codes),
   with a region or script after a dash only when you need one.
2. Translate the text after each colon. Leave the part before the colon (the key) exactly as it
   is.

   ```json
   "languageName": "Deutsch",
   "back": "Zurück",
   "gamesFound": "%d Spiele gefunden",
   ```

3. `languageName` comes first: it is your language's name in the language itself (`Deutsch`, not
   `German`), and how it appears in Settings.

You do not have to translate everything at once. A text you leave out (delete its line) or have
not reached yet is shown in English, so a half-done file already works.

### The language games start in

When a game's own language setting follows the launcher, the game starts in the console
language of the launcher's language. The launcher finds it from the file's name: `de.json`
starts games in German, `pt-BR.json` in Portuguese (Brazil), `es-419.json` in Spanish (Latin
America). The console has these languages: Japanese, English (US and UK), French, Spanish (Spain
and Latin America), German, Italian, Dutch, Portuguese (Portugal and Brazil), Russian, Korean,
Chinese (Traditional and Simplified), Finnish, Swedish, Danish, Norwegian, Polish, Turkish and
Arabic. A language the console does not have starts games in English. Nothing about it goes in
the file.

### Numbers

Three texts are about numbers rather than words:

- `numberGroupSeparator` goes between thousands: `,` in English (12,345), `.` in Turkish
  (12.345), a space in French.
- `numberDecimalSeparator` is the decimal mark: `.` in English (1.5 GB), `,` in Turkish
  (1,5 GB).
- `percent` places the percent sign: `%@%%` in English (85%), `%%%@` in Turkish (%85).

The Mac launcher has none of the three: it writes numbers the way macOS does for the language's
code.

## Rules for the texts

- **Keep the keys.** Only the text on the right of the colon is yours to change. A key the
  English file does not have (often a typo) is an error.
- **Keep the placeholders.** They are filled in by the app:
  - `%@` is a word or a name (a game, a version, a person),
  - `%d` is a number,
  - `%%` is a percent sign.

  Each text needs the same placeholders as its English text, no more and no fewer. Where your
  sentence needs them in another order, number them: `%1$@` is the first one, `%2$@` the
  second. English `"Starting %2$@ with %1$@"` becomes Turkish `"%1$@ ile %2$@ başlıyor"`. The
  Mac launcher also has `%02d` (a number with two digits) and `%.1f` (a number with one
  decimal): keep them as they are.
- **Keep the JSON.** Every text is in double quotes and every line but the last ends with a
  comma. A double quote inside a text is written `\"`. Many editors (and GitHub, see below)
  point out a missing quote or comma.
- **Save as UTF-8.** An editor or script that saves in another encoding turns every letter it
  cannot write (é, ü, ñ, ç) into a question mark: `Espa?ol` instead of `Español`. Windows
  PowerShell 5's `Set-Content` and `Out-File` do this unless given `-Encoding utf8`. Check your
  file's `languageName` after saving.
- **End descriptions as sentences.** A text whose key ends in `Detail`, `Hint`, `Subtitle`,
  `Text`, `Note`, `Description`, `Info` or `Explanation` is a sentence under a title or a row, and
  ends with `.`, `!`, `?`, `…` or `:` (or your script's own mark, such as `。`, `।`, `؟` or `۔`). Titles,
  buttons and labels do not.
- Words such as AnyPS5, AnyTogether, DualSense, Steam, GitHub and file names stay as they are.

### The same keys in every app

A key means the same text in each app that has it, so a translation of one file carries over to
the others: copy your texts for the keys another app's `en.json` has too, then translate the
rest. Some texts say Mac in the Mac launcher where the Windows/Linux one says PC (`stepRelink`,
`themesOnMac`): translate each file's own English.

## Try it

**In a released launcher**, with no building: put your file in the launcher's `Languages`
folder (create it if it is not there) and start the launcher again.

- Windows: `%APPDATA%\AnyPS5\Languages` (type it into the File Explorer address bar)
- Linux: `~/.config/AnyPS5/Languages`
- Mac: `~/Library/Application Support/AnyPS5/Languages` (in Finder, **Go › Go to Folder…**)

Open **Settings › Language** and choose your language. A file there comes before the built-in
one of the same code, so you can try a changed `tr.json` the same way. A text your file does not
have yet still shows the built-in translation. If your language does not
appear, the file is not valid JSON: the check below says where. A file made for an older
launcher, with an `"@meta"` part at the top, still works there; for the repository, replace it
with a `languageName` line.

**The phone app** has no such folder. It shows the language the launcher uses when it has a
file for it, else English; to see a translation on the phone, build the app from the source with
the file in `mobile/assets/l10n` (`flutter run` in `mobile/`).

**From the source**, if you build an app yourself: put the file in its folder from the table
above and run the app (`flutter run` for the Windows/Linux launcher and the phone app,
`swift run` in `tools/macos/launcher` for the Mac launcher).

## The check

Each pull request runs a check of the files: valid JSON, one flat object of texts with no key twice, a name that
is a language code, no key English lacks, English's placeholders in each text, descriptions that
end as sentences. It also shows how
much of each language is translated, for example
`de: 92.4 % translated (1174 of 1270, 96 shown in English)`.

- Windows/Linux launcher: `dart run tool/check_translations.dart` in this repository.
- Phone app: `dart run tool/check_translations.dart` in `mobile/` of AnyPS5-ARM.
- Mac launcher: `swift test --filter "LanguageCheckTests|LanguageFilesTests"` in `tools/macos/launcher` of AnyPS5-ARM.

## Send it in

Without git, in the browser:

1. Open the app's folder from the table above on GitHub and choose **Add file › Create new
   file** (or **Upload files** to drop in the file you made). GitHub offers to make a copy of the
   project (a fork) for you; accept it.
2. Name the file (`de.json`), paste or upload its contents, and choose **Commit changes**, then
   **Propose changes** and **Create pull request**.
3. The checks run on the pull request. If the language check fails, open its details: each
   problem names the key, and what is wrong with it. Fix it in the same file on your fork (the
   pencil icon) and the checks run again.

With git, the usual way: a branch with your file, pushed to your fork, and a pull request.

## When new texts appear

New features bring new keys in `en.json`. Until they are translated they show in English. To
catch up, compare your file with `en.json` (GitHub's **History** of `en.json` shows what was
added), copy the new lines into your file and translate them. The order of the lines does not
matter. A key removed from English has to go from your file too: the check names it.

Maintainers: setting up the Weblate project is in [docs/WEBLATE.md](docs/WEBLATE.md).

Maintainers: the tests read the languages from `assets/l10n`, so a new file needs no test edit. It
does change the screenshots of the language grid (`first_start_language_en.png`,
`first_start_language_tr.png`, `onboarding_language.png`) and adds `update_notice_<code>.png`:
remake them on CI with `gh workflow run ci.yml -R AnyTogether/AnyPS5-Desktop --ref <branch> -f
update_goldens=true` and commit the changed images to the pull request. A failing test in a file
with goldens stops that run before it uploads them.
