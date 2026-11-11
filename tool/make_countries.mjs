// Remakes assets/countries.json: the countries AnyTogether accepts (ISO 3166-1 alpha-2, the list
// in AnyTogether's packages/shared/src/profile.ts) by their name in each of the launcher's
// languages, in that language's own alphabetical order. The names and the order are ICU's (CLDR),
// read through Node's Intl, so nothing here is translated by hand.
//
//   node tool/make_countries.mjs
//
// Run it again after a language file is added to assets/l10n. A language ICU has no country names
// for takes the ones of the language named in `standIns`, else English.
import { readdirSync, writeFileSync } from "node:fs";

const codes =
  "AD AE AF AG AI AL AM AO AQ AR AS AT AU AW AX AZ BA BB BD BE BF BG BH BI BJ BL BM BN BO BQ BR BS BT BV BW BY BZ CA CC CD CF CG CH CI CK CL CM CN CO CR CU CV CW CX CY CZ DE DJ DK DM DO DZ EC EE EG EH ER ES ET FI FJ FK FM FO FR GA GB GD GE GF GG GH GI GL GM GN GP GQ GR GS GT GU GW GY HK HM HN HR HT HU ID IE IL IM IN IO IQ IR IS IT JE JM JO JP KE KG KH KI KM KN KP KR KW KY KZ LA LB LC LI LK LR LS LT LU LV LY MA MC MD ME MF MG MH MK ML MM MN MO MP MQ MR MS MT MU MV MW MX MY MZ NA NC NE NF NG NI NL NO NP NR NU NZ OM PA PE PF PG PH PK PL PM PN PR PS PT PW PY QA RE RO RS RU RW SA SB SC SD SE SG SH SI SJ SK SL SM SN SO SR SS ST SV SX SY SZ TC TD TF TG TH TJ TK TL TM TN TO TR TT TV TW TZ UA UG UM US UY UZ VA VC VE VG VI VN VU WF WS YE YT ZA ZM ZW".split(
    " ",
  );

// Bhojpuri has no country names in CLDR: Hindi's, in the same script.
const standIns = { bho: "hi" };

const languages = readdirSync(new URL("../assets/l10n/", import.meta.url))
  .filter((name) => name.endsWith(".json"))
  .map((name) => name.slice(0, -".json".length))
  .sort();

const out = {};
for (const language of languages) {
  // ICU may know a language and still have no country names for it.
  const known = new Intl.DisplayNames([language], { type: "region", fallback: "none" }).of("DE") !== undefined;
  const locale = known ? language : (standIns[language] ?? "en");
  const names = new Intl.DisplayNames([locale], { type: "region", fallback: "none" });
  const english = new Intl.DisplayNames(["en"], { type: "region" });
  const collator = new Intl.Collator(locale);
  out[language] = codes
    .map((code) => [code, names.of(code) ?? english.of(code) ?? code])
    .sort((a, b) => collator.compare(a[1], b[1]));
}
const lines = Object.entries(out).map(([language, list]) => `  ${JSON.stringify(language)}: ${JSON.stringify(list)}`);
writeFileSync(new URL("../assets/countries.json", import.meta.url), `{\n${lines.join(",\n")}\n}\n`);
console.log(`${languages.length} languages, ${codes.length} countries`);
