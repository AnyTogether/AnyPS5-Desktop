part of 'app_model.dart';

/// Settings' search: a field over the sections that keeps only the settings whose title or
/// description (in the language shown) has every word typed, from every section at once. The
/// keys reach it with ↑ from the first row or Ctrl+F, a controller with ↑ from the first row or
/// the first section; ✕ (Enter) types, ↓ goes to what it found, ○ (Esc) clears it.
extension SettingsSearch on AppModel {
  static const searchRow = 'settings-search';

  /// Whether a search is shown instead of the sections.
  bool get searchingSettings => settingsQuery.trim().isNotEmpty;

  /// The field, as a text row: each letter typed narrows the list at once; Enter goes to it.
  PanelRow get settingsSearchField => PanelRow(
    id: searchRow,
    title: '',
    kind: TextRow(
      settingsQuery,
      setSettingsQuery,
      submit: () {
        settingsSearchFocused = false;
        panelSections = false;
        panelRow = 0;
        _skipToFocusable();
        _changed();
      },
      hint: T.text('settingsSearchPrompt'),
    ),
  );

  void setSettingsQuery(String text) {
    final was = searchingSettings;
    settingsQuery = text;
    final now = searchingSettings;
    if (!was && now) _categoryBeforeSearch = panelCategory;
    panelCategory = now ? 0 : _categoryBeforeSearch;
    panelSections = false;
    editingValue = null;
    panelRow = 0;
    _skipToFocusable();
    _changed();
  }

  /// The field takes the keys (Ctrl+F, a click, ✕ on it).
  void startSettingsSearch() {
    if (overlay != Layer.settings) open(Layer.settings);
    settingsSearchFocused = true;
    panelSections = false;
    editingValue = null;
    startEditing(searchRow);
  }

  /// Back to the sections as they were: the search emptied.
  void clearSettingsSearch() {
    if (!searchingSettings) return;
    setSettingsQuery('');
  }

  /// Settings as shown: the sections, or while searching one list of what matches.
  List<PanelCategory> _searchedSettings(List<PanelCategory> sections) {
    if (!searchingSettings) return sections;
    final words = _fold(settingsQuery).split(RegExp(r'\s+')).where((word) => word.isNotEmpty).toList();
    final seen = <String>{};
    final found = <PanelRow>[];
    final searchable = [...sections, if (system == HostSystem.windows) ..._emulatorMenu.searchSections()];
    for (final section in searchable) {
      for (final row in section.rows) {
        if (!row.focusable || row.title.isEmpty) continue;
        final text = _fold('${row.title} ${row.detail ?? ''} ${section.id.startsWith('retro-') ? section.title : ''}');
        if (!words.every(text.contains) || !seen.add(row.id)) continue;
        // Where it lives, before what it says.
        found.add(
          PanelRow(
            id: row.id,
            title: row.title,
            detail: row.detail == null ? section.title : '${section.title} · ${row.detail}',
            kind: row.kind,
            glyph: row.glyph,
            person: row.person,
            level: row.level,
          ),
        );
      }
    }
    return [
      PanelCategory(
        id: 'search',
        title: T.text('settings'),
        rows: found.isEmpty
            ? [
                PanelRow(
                  id: 'search-none',
                  title: T.format('settingsSearchNone', [settingsQuery.trim()]),
                  kind: const InfoRow(''),
                ),
              ]
            : found,
      ),
    ];
  }

  /// A command while the field has the focus (not typing in it). True when it was handled here.
  bool _searchCommand(Command command) {
    if (overlay != Layer.settings || !settingsSearchFocused) return false;
    switch (command) {
      case Command.select:
        sounds.play(Cue.select);
        startEditing(searchRow);
      case Command.down:
        settingsSearchFocused = false;
        panelSections = false;
        panelRow = 0;
        _skipToFocusable();
        sounds.play(Cue.move);
        _changed();
      case Command.back:
        if (searchingSettings) {
          sounds.play(Cue.back);
          clearSettingsSearch();
        } else {
          settingsSearchFocused = false;
          closeOverlay();
        }
      case Command.options:
        settingsSearchFocused = false;
        closeOverlay();
      default:
        break;
    }
    return true;
  }

  /// ↑ at the top of the rows (or of the sections): onto the field.
  void _toSearch() {
    settingsSearchFocused = true;
    panelSections = false;
    editingValue = null;
    sounds.play(Cue.move);
    _changed();
  }

  /// Lower case, with the dotted capital I's combining dot dropped and the dotless i read as i,
  /// so a word typed with either i matches (Turkish has both).
  static String _fold(String text) => text.toLowerCase().replaceAll('\u0307', '').replaceAll('\u0131', 'i');
}
