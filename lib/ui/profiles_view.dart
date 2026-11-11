import 'package:flutter/material.dart';

import '../core/profiles/profiles.dart';
import 'app_model.dart';
import 'components.dart';
import 'glass.dart';
import 'profile_picture.dart';
import 'strings.dart';
import 'theme.dart';

/// A profile's round tile: its picture, or its initial on its colour lit from the top left;
/// the controller's light-bar strip in that colour under it on the picker. Home's top bar shows
/// the profile playing in a small one.
class ProfileTile extends StatelessWidget {
  const ProfileTile({super.key, required this.profile, required this.size, this.picture, this.focused = false});

  final LauncherProfile? profile;
  final double size;

  /// The profile's own picture on this computer ([ProfileStore.pictureOf]).
  final String? picture;
  final bool focused;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final color = LauncherProfiles.colorOf(profile);
    final initial = DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          center: const Alignment(-0.7, -0.7),
          radius: 0.9,
          colors: [Colors.white.withValues(alpha: 0.26), Colors.white.withValues(alpha: 0)],
        ),
      ),
      child: Center(
        child: Text(T.initial(profile?.name ?? ''), style: AppText.display(size * 0.42, weight: FontWeight.w600)),
      ),
    );
    // Small on Home: a hairline and a soft glow, not the picker's.
    final small = size < 60 * scale;
    return AnimatedContainer(
      duration: Motion.focus,
      curve: Motion.settle,
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [color, Color.lerp(color, Colors.black, 0.45)!],
        ),
        border: Border.all(
          color: Colors.white.withValues(alpha: focused ? 0.95 : (small ? 0.22 : 0.16)),
          width: (focused ? 4 : (small ? 1 : 1.5)) * scale,
        ),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: focused ? 0.6 : (small ? 0.35 : 0.22)),
            blurRadius: (focused ? 34 : (small ? 8 : 14)) * scale,
          ),
        ],
      ),
      child: picture == null
          ? initial
          : ClipOval(
              child: Image(
                // One decoded picture for every place it shows (it is only 256 pixels a side).
                image: ArtworkImage.provider(picture!, ProfilePicture.size),
                width: size,
                height: size,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => initial,
              ),
            ),
    );
  }
}

/// "Who's playing?": every profile as a tile, the one in use first, and Add Profile.
class ProfilePickerView extends StatelessWidget {
  const ProfilePickerView({super.key, required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final tiles = model.profiles.book.pickerOrder;
    final flow = model.profileFlow;
    return LayerScrim(
      opacity: 0.74,
      child: Padding(
        padding: EdgeInsets.only(top: 120 * scale, bottom: 54 * scale),
        child: Column(
          children: [
            Text(
              T.upper(T.text('profileKicker')),
              style: AppText.display(
                13 * scale,
                weight: FontWeight.w700,
                color: model.accentChoice.color,
              ).copyWith(letterSpacing: 2.2 * scale),
            ),
            SizedBox(height: 10 * scale),
            Text(T.text('profileWhoIsPlaying'), style: AppText.display(60 * scale, weight: FontWeight.w300)),
            SizedBox(height: 8 * scale),
            Text(
              T.text(flow.atLaunch ? 'profilePickerSubtitleLaunch' : 'profilePickerSubtitle'),
              style: AppText.display(17 * scale, color: Colors.white.withValues(alpha: 0.62)),
            ),
            SizedBox(height: 70 * scale),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var index = 0; index < tiles.length; index++)
                  _PickerTile(
                    focused: flow.pickerIndex == index,
                    onTap: () {
                      flow.pickerIndex = index;
                      model.pickerCommand(Command.select);
                    },
                    avatar: LinkedProfileTile(
                      linked: tiles[index].mode == ProfileMode.online,
                      size: 168 * scale,
                      child: ProfileTile(
                        profile: tiles[index],
                        picture: model.profiles.pictureOf(tiles[index]),
                        size: 168 * scale,
                        focused: flow.pickerIndex == index,
                      ),
                    ),
                    strip: LauncherProfiles.colorOf(tiles[index]),
                    name: tiles[index].name,
                    line: _modeLine(
                      tiles[index],
                      current: tiles[index].id == model.currentProfile?.id && !flow.atLaunch,
                    ),
                  ),
                _PickerTile(
                  focused: flow.pickerIndex == tiles.length,
                  onTap: () {
                    flow.pickerIndex = tiles.length;
                    model.pickerCommand(Command.select);
                  },
                  avatar: _AddCircle(size: 168 * scale, focused: flow.pickerIndex == tiles.length),
                  strip: Colors.white.withValues(alpha: 0.3),
                  name: T.text('profileAdd'),
                ),
              ],
            ),
            const Spacer(),
            Wrap(
              spacing: 10 * scale,
              children: [
                Hint(keys: '← →', label: T.text('hintMove')),
                Hint(keys: 'Enter', glyph: PadGlyph.cross, label: T.text('profileHintPlay'), action: HintAction.select),
                if (!flow.atLaunch) ...[
                  Hint(keys: 'O', glyph: PadGlyph.triangle, label: T.text('profileManage'), action: HintAction.options),
                  Hint(keys: 'Esc', glyph: PadGlyph.circle, label: T.text('hintBack'), action: HintAction.back),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Under the name: the AnyTogether account a profile is linked to (its @handle, or AnyTogether
  /// while it has none yet), or Local for one that stays on this computer.
  Widget _modeLine(LauncherProfile profile, {required bool current}) {
    final online = profile.mode == ProfileMode.online;
    final text = online
        ? (profile.account == null ? T.text('profileOnlineTag') : '@${profile.account!.handle}')
        : T.text('profileOfflineTag');
    return Builder(
      builder: (context) {
        final scale = LayoutScale.of(context);
        final color = Colors.white.withValues(alpha: 0.62);
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (online)
              TogetherMark(size: 14 * scale)
            else
              Icon(Icons.computer_rounded, size: 13 * scale, color: color),
            SizedBox(width: 6 * scale),
            Flexible(
              child: Text(
                current ? '$text · ${T.text('profilePlayingNow')}' : text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.display(13 * scale, weight: FontWeight.w500, color: color),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// AnyTogether's mark: its two rings, on the blue, violet and mint of the website's.
class TogetherMark extends StatelessWidget {
  const TogetherMark({super.key, required this.size});

  final double size;

  @override
  Widget build(BuildContext context) => CustomPaint(size: Size.square(size), painter: const _RingsPainter());
}

class _RingsPainter extends CustomPainter {
  const _RingsPainter();

  static const colors = [Color(0xFF4F7CFF), Color(0xFFB65CFF), Color(0xFF2FE0C4)];

  @override
  void paint(Canvas canvas, Size size) {
    // The website's 32-unit drawing: rings of radius 8.5 at x 12 and 20, a 2.5 stroke.
    final unit = size.width / 32;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5 * unit
      ..shader = const LinearGradient(colors: colors, stops: [0, 0.55, 1]).createShader(Offset.zero & size);
    canvas
      ..drawCircle(Offset(12 * unit, 16 * unit), 8.5 * unit, paint)
      ..drawCircle(Offset(20 * unit, 16 * unit), 8.5 * unit, paint);
  }

  @override
  bool shouldRepaint(_RingsPainter oldDelegate) => false;
}

/// A profile's tile on the picker, with AnyTogether's mark on a small dark disc at its lower
/// right when the profile is linked to an account: which ones are online is seen at a glance.
/// A local profile's tile stays as it is.
class LinkedProfileTile extends StatelessWidget {
  const LinkedProfileTile({super.key, required this.linked, required this.size, required this.child});

  final bool linked;
  final double size;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!linked) return child;
    final scale = LayoutScale.of(context);
    final badge = size * 0.28;
    // On the circle's edge, down and to the right (45°).
    final centre = size / 2 + size / 2 * 0.7071;
    return SizedBox.square(
      dimension: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          child,
          Positioned(
            key: const ValueKey('together-badge'),
            left: centre - badge / 2,
            top: centre - badge / 2,
            child: Container(
              width: badge,
              height: badge,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFF0C0E16),
                border: Border.all(color: Colors.white.withValues(alpha: 0.18), width: 1.5 * scale),
                boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.45), blurRadius: 10 * scale)],
              ),
              alignment: Alignment.center,
              child: TogetherMark(size: badge * 0.62),
            ),
          ),
        ],
      ),
    );
  }
}

class _PickerTile extends StatelessWidget {
  const _PickerTile({
    required this.focused,
    required this.onTap,
    required this.avatar,
    required this.strip,
    required this.name,
    this.line,
  });

  final bool focused;
  final VoidCallback onTap;
  final Widget avatar;
  final Color strip;
  final String name;
  final Widget? line;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 23 * scale),
      child: Semantics(
        button: true,
        label: name,
        excludeSemantics: true,
        onTap: onTap,
        child: GestureDetector(
          onTap: onTap,
          child: AnimatedOpacity(
            opacity: focused ? 1 : 0.78,
            duration: Motion.focus,
            curve: Motion.settle,
            child: AnimatedScale(
              scale: focused ? 1.06 : 0.96,
              duration: Motion.focus,
              curve: Motion.settle,
              child: SizedBox(
                width: 190 * scale,
                child: Column(
                  children: [
                    avatar,
                    SizedBox(height: 18 * scale),
                    // The light bar of the profile's controller.
                    AnimatedContainer(
                      duration: Motion.focus,
                      curve: Motion.settle,
                      width: (focused ? 54 : 30) * scale,
                      height: 4 * scale,
                      decoration: BoxDecoration(
                        color: strip.withValues(alpha: focused ? 1 : 0.55),
                        borderRadius: BorderRadius.circular(2 * scale),
                      ),
                    ),
                    SizedBox(height: 18 * scale),
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.display(23 * scale, weight: focused ? FontWeight.w600 : FontWeight.w400),
                    ),
                    if (line != null) ...[SizedBox(height: 6 * scale), line!],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AddCircle extends StatelessWidget {
  const _AddCircle({required this.size, required this.focused});

  final double size;
  final bool focused;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    return AnimatedContainer(
      duration: Motion.focus,
      curve: Motion.settle,
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.white.withValues(alpha: focused ? 0.16 : 0.06),
        border: Border.all(
          color: Colors.white.withValues(alpha: focused ? 0.95 : 0.3),
          width: (focused ? 4 : 1.5) * scale,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.white.withValues(alpha: focused ? 0.22 : 0),
            blurRadius: 26 * scale,
          ),
        ],
      ),
      child: Icon(
        Icons.add_rounded,
        size: 56 * scale,
        color: Colors.white.withValues(alpha: focused ? 1 : 0.7),
      ),
    );
  }
}

/// Offline or online: two cards, the focused one lifted. The first start's last step and Add
/// Profile.
class ProfileModeCards extends StatelessWidget {
  const ProfileModeCards({super.key, required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _ModeCard(
          model: model,
          index: 0,
          icon: Icons.wifi_off_rounded,
          title: T.text('profileOfflineTitle'),
          lead: T.text('profileOfflineLead'),
          facts: [T.text('profileOfflineFact1'), T.text('profileOfflineFact2'), T.text('profileOfflineFact3')],
          tag: T.text('profileOfflineTag'),
        ),
        SizedBox(width: 28 * scale),
        _ModeCard(
          model: model,
          index: 1,
          icon: Icons.people_alt_rounded,
          title: T.text('profileOnlineTitle'),
          lead: T.text('profileOnlineLead'),
          facts: [T.text('profileOnlineFact1'), T.text('profileOnlineFact2'), T.text('profileOnlineFact3')],
          tag: T.text('profileOnlineTag'),
        ),
      ],
    );
  }
}

class _ModeCard extends StatelessWidget {
  const _ModeCard({
    required this.model,
    required this.index,
    required this.icon,
    required this.title,
    required this.lead,
    required this.facts,
    required this.tag,
  });

  final AppModel model;
  final int index;
  final IconData icon;
  final String title;
  final String lead;
  final List<String> facts;
  final String tag;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final focused = model.profileFlow.modeChoice == index;
    final ink = focused ? Colors.black : Colors.white;
    final chip = focused ? Colors.black.withValues(alpha: 0.08) : Colors.white.withValues(alpha: 0.1);
    void choose() {
      model.profileFlow.modeChoice = index;
      model.modeChoiceCommand(Command.select);
    }

    return Semantics(
      button: true,
      label: '$title. $lead',
      excludeSemantics: true,
      onTap: choose,
      child: GestureDetector(
        onTap: choose,
        child: AnimatedScale(
          scale: focused ? 1.03 : 0.98,
          duration: Motion.focus,
          curve: Motion.settle,
          child: AnimatedOpacity(
            opacity: focused ? 1 : 0.8,
            duration: Motion.focus,
            curve: Motion.settle,
            child: FocusRing(
              focused: focused,
              radius: 26 * scale,
              child: AnimatedContainer(
                duration: Motion.focus,
                curve: Motion.settle,
                width: 430 * scale,
                height: 380 * scale,
                padding: EdgeInsets.all(30 * scale),
                decoration: BoxDecoration(
                  color: focused ? Colors.white : Colors.white.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(26 * scale),
                  border: Border.all(color: Colors.white.withValues(alpha: focused ? 0 : 0.14)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 58 * scale,
                          height: 58 * scale,
                          decoration: BoxDecoration(shape: BoxShape.circle, color: chip),
                          child: Icon(icon, size: 26 * scale, color: ink),
                        ),
                        const Spacer(),
                        Container(
                          padding: EdgeInsets.symmetric(horizontal: 10 * scale, vertical: 5 * scale),
                          decoration: BoxDecoration(color: chip, borderRadius: BorderRadius.circular(20 * scale)),
                          child: Text(
                            T.upper(tag),
                            style: AppText.display(
                              11 * scale,
                              weight: FontWeight.w700,
                              color: ink,
                            ).copyWith(letterSpacing: 1.4 * scale),
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: 26 * scale),
                    Text(
                      title,
                      style: AppText.display(34 * scale, weight: FontWeight.w600, color: ink),
                    ),
                    SizedBox(height: 6 * scale),
                    Text(lead, style: AppText.display(16 * scale, color: ink.withValues(alpha: 0.72), height: 1.3)),
                    SizedBox(height: 24 * scale),
                    for (final fact in facts)
                      Padding(
                        padding: EdgeInsets.only(bottom: 11 * scale),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Padding(
                              padding: EdgeInsets.only(top: 2 * scale),
                              child: Icon(Icons.check_rounded, size: 15 * scale, color: ink.withValues(alpha: 0.7)),
                            ),
                            SizedBox(width: 10 * scale),
                            Expanded(
                              child: Text(
                                fact,
                                style: AppText.display(15 * scale, weight: FontWeight.w500, color: ink, height: 1.3),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Add Profile: a name, then offline or online.
class AddProfileView extends StatefulWidget {
  const AddProfileView({super.key, required this.model});

  final AppModel model;

  @override
  State<AddProfileView> createState() => _AddProfileViewState();
}

class _AddProfileViewState extends State<AddProfileView> {
  late final TextEditingController _name = TextEditingController(text: widget.model.profileFlow.name);
  final FocusNode _node = FocusNode(debugLabel: 'profile name');

  @override
  void initState() {
    super.initState();
    _node.addListener(_focusChanged);
  }

  @override
  void didUpdateWidget(AddProfileView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _follow();
  }

  /// The model says where the cursor is, as for a row's field: while the name is typed the keys
  /// are the field's (space, Backspace and the letters that are shortcuts elsewhere), and the
  /// launcher does not take the focus back.
  void _follow() {
    final editing = widget.model.editingRow == ProfileFlow.nameRow;
    if (editing && !_node.hasFocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.model.editingRow == ProfileFlow.nameRow) _node.requestFocus();
      });
    } else if (!editing && _node.hasFocus) {
      _node.unfocus();
    }
  }

  void _focusChanged() {
    final model = widget.model;
    if (_node.hasFocus) {
      if (model.editingRow != ProfileFlow.nameRow) model.startEditing(ProfileFlow.nameRow);
    } else if (model.editingRow == ProfileFlow.nameRow) {
      model.stopEditing();
    }
  }

  @override
  void dispose() {
    _node.removeListener(_focusChanged);
    // Left while the name was typed: the keys go back to the launcher.
    final model = widget.model;
    if (model.editingRow == ProfileFlow.nameRow) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (model.editingRow == ProfileFlow.nameRow) model.stopEditing();
      });
    }
    _node.dispose();
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final model = widget.model;
    final typing = model.editingRow == ProfileFlow.nameRow;
    return LayerScrim(
      opacity: 0.74,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 110 * scale, vertical: 80 * scale),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              T.upper(T.text('profileAdd')),
              style: AppText.display(
                13 * scale,
                weight: FontWeight.w700,
                color: model.accentChoice.color,
              ).copyWith(letterSpacing: 2.2 * scale),
            ),
            SizedBox(height: 10 * scale),
            Text(T.text('profileHowToPlay'), style: AppText.display(54 * scale, weight: FontWeight.w300)),
            SizedBox(height: 8 * scale),
            Text(
              T.text('profileHowToPlaySubtitle'),
              style: AppText.display(17 * scale, color: Colors.white.withValues(alpha: 0.62)),
            ),
            SizedBox(height: 34 * scale),
            AnimatedOpacity(
              opacity: model.profileFlow.modeChoice == 0 || typing ? 1 : 0.45,
              duration: Motion.focus,
              child: AnimatedContainer(
                duration: Motion.focus,
                width: 430 * scale,
                height: 56 * scale,
                // The accent's edge while the name is typed, as a row's field has.
                foregroundDecoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16 * scale),
                  border: Border.all(color: typing ? model.accentChoice.color : Colors.transparent, width: 1.5 * scale),
                ),
                child: Glass(
                  radius: 16 * scale,
                  padding: EdgeInsets.symmetric(horizontal: 20 * scale),
                  child: Row(
                    children: [
                      Icon(Icons.badge_outlined, size: 20 * scale, color: Colors.white.withValues(alpha: 0.6)),
                      SizedBox(width: 14 * scale),
                      Expanded(
                        child: TextField(
                          key: const ValueKey('profile-add-name'),
                          controller: _name,
                          focusNode: _node,
                          onChanged: (text) => model.profileFlow.name = text,
                          onSubmitted: (_) => model.stopEditing(),
                          style: AppText.display(20 * scale, weight: FontWeight.w500),
                          cursorColor: Colors.white,
                          decoration: InputDecoration.collapsed(
                            hintText: T.text('profileNameHint'),
                            hintStyle: AppText.display(20 * scale, color: Colors.white.withValues(alpha: 0.4)),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            SizedBox(height: 26 * scale),
            ProfileModeCards(model: model),
            const Spacer(),
            Wrap(
              spacing: 10 * scale,
              children: [
                Hint(keys: '← →', label: T.text('hintMove')),
                Hint(keys: 'Enter', glyph: PadGlyph.cross, label: T.text('hintSelect'), action: HintAction.select),
                Hint(keys: 'Esc', glyph: PadGlyph.circle, label: T.text('hintBack'), action: HintAction.back),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Home's profile list: under the picture at the top right, the other profiles (picture, name,
/// AnyTogether's mark on the ones linked to an account) and, last, Add profile. Hovering, clicking
/// or reaching the picture with the keys opens it; choosing a profile plays as it from then on.
class ProfileSwitcherList extends StatelessWidget {
  const ProfileSwitcherList({super.key, required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final others = model.switcherProfiles;
    // The entry the keys are on, from 0; none while only the pointer has the list open.
    final focused = model.focus.isSwitcher ? model.focus.index - 1 : -1;
    final list = MouseRegion(
      onEnter: (_) => model.showProfileList(),
      onExit: (_) => model.leaveProfileList(),
      child: SizedBox(
        width: 272 * scale,
        child: Glass(
          radius: 22 * scale,
          opacity: 0.62,
          floating: true,
          padding: EdgeInsets.all(8 * scale),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: EdgeInsetsDirectional.fromSTEB(12 * scale, 8 * scale, 12 * scale, 8 * scale),
                child: Text(
                  T.text('switchProfile'),
                  style: AppText.display(
                    12 * scale,
                    weight: FontWeight.w600,
                    color: Colors.white.withValues(alpha: 0.55),
                  ),
                ),
              ),
              for (final (index, profile) in others.indexed)
                _SwitcherEntry(
                  key: ValueKey('switcher-${profile.id}'),
                  focused: focused == index,
                  onTap: () => model.chooseFromProfileList(index),
                  // The profile's own colour, as the picker's light-bar strip.
                  strip: LauncherProfiles.colorOf(profile),
                  leading: LinkedProfileTile(
                    linked: profile.mode == ProfileMode.online,
                    size: 36 * scale,
                    child: ProfileTile(profile: profile, picture: model.profiles.pictureOf(profile), size: 36 * scale),
                  ),
                  label: profile.name,
                ),
              if (others.isNotEmpty)
                Container(
                  height: 1,
                  margin: EdgeInsets.symmetric(horizontal: 12 * scale, vertical: 6 * scale),
                  color: Colors.white.withValues(alpha: 0.1),
                ),
              _SwitcherEntry(
                key: const ValueKey('switcher-add'),
                focused: focused == others.length,
                onTap: () => model.chooseFromProfileList(others.length),
                leading: Builder(
                  builder: (context) {
                    final on = focused == others.length;
                    final ink = on ? LookScope.focusedInk(context) : Colors.white;
                    return Container(
                      width: 36 * scale,
                      height: 36 * scale,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: ink.withValues(alpha: on ? 0.7 : 0.3),
                          width: 1.5 * scale,
                        ),
                      ),
                      child: Icon(
                        Icons.add_rounded,
                        size: 22 * scale,
                        color: ink.withValues(alpha: on ? 1 : 0.8),
                      ),
                    );
                  },
                ),
                label: T.text('profileAdd'),
              ),
            ],
          ),
        ),
      ),
    );
    // Drops from the picture: grows a little from its top edge and settles, or only fades with
    // reduced motion.
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Motion.overlay,
      curve: Motion.reduced ? Curves.easeOut : Curves.easeOutBack,
      builder: (context, value, child) => Opacity(
        opacity: value.clamp(0.0, 1.0),
        child: Transform.scale(
          scale: Motion.reduced ? 1 : 0.92 + 0.08 * value,
          alignment: Alignment.topCenter,
          child: child,
        ),
      ),
      child: list,
    );
  }
}

/// One entry of Home's profile list: white under the keys' focus, lighter under the pointer.
class _SwitcherEntry extends StatelessWidget {
  const _SwitcherEntry({
    super.key,
    required this.focused,
    required this.onTap,
    required this.leading,
    required this.label,
    this.strip,
  });

  final bool focused;
  final VoidCallback onTap;
  final Widget leading;
  final String label;
  final Color? strip;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final glass = LookScope.isGlass(context);
    final ink = focused ? LookScope.focusedInk(context) : Colors.white;
    return Pressable(
      onTap: onTap,
      builder: (context, hovering) => AnimatedContainer(
        duration: Motion.focus,
        curve: Motion.settle,
        padding: EdgeInsetsDirectional.fromSTEB(8 * scale, 8 * scale, 14 * scale, 8 * scale),
        decoration: BoxDecoration(
          color: focused
              ? Colors.white.withValues(alpha: glass ? 0.92 : 1)
              : Colors.white.withValues(alpha: hovering ? 0.12 : 0),
          borderRadius: BorderRadius.circular(14 * scale),
        ),
        child: Row(
          children: [
            Container(
              width: 3 * scale,
              height: 22 * scale,
              decoration: BoxDecoration(
                color: strip ?? Colors.transparent,
                borderRadius: BorderRadius.circular(2 * scale),
              ),
            ),
            SizedBox(width: 8 * scale),
            leading,
            SizedBox(width: 12 * scale),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.display(16 * scale, weight: FontWeight.w600, color: ink),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
