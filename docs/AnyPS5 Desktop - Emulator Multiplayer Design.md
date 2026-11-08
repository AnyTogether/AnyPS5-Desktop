# AnyPS5 Desktop emulator multiplayer design

## Proposed first release

Extend **Share Play** to support remote couch multiplayer on Windows. The host
runs one emulator and keeps the save. The host selects Share Play from the
in-game Quick Menu, invites a friend and grants Player 2. The guest watches the
game stream and plays through the controller on their computer. The guest needs
the launcher and an AnyTogether account. The game and emulator run on the host.

Crash Team Racing split-screen is the first target. It exercises local
competitive play with an independently controlled second seat. Follow with a
PS2 title that supports two local players and LittleBigPlanet couch co-op. Add
more seats only as each core and title proves it can accept them.

## Three different multiplayer models

| Model | What it reuses | Main constraint |
| --- | --- | --- |
| Share Play for local multiplayer | Invitations, WebRTC media, TURN, and host-granted controller seats | The guest's video and inputs cross the network. The game must already support local multiplayer. |
| Two-copy link cable or LAN | AnyTogether discovery and the [Play Together session model](../lib/ui/together_play.dart) | Every player needs a compatible copy. Each core has to expose the console's serial or network interface. |
| Synchronized emulator netplay | Invitations, and a core's verified serialization and replay support where available | A separate emulator runs on each PC. Core, content, firmware, settings and initial state must agree. Desync detection and recovery need their own design. |

The [PS5 peer mesh](../lib/core/online/online_peer_mesh.dart) connects peers for
the PS5 engine's virtual LAN. Reuse its session concepts for a later emulator
networking spike. The current RPCS3 preview keeps offline peer traffic on
loopback. PS3 LAN and RPCN are separate from the Share Play proposal and need
their own approval and testing. The [RPCS3 Libretro feature list](https://docs.libretro.com/library/rpcs3/#features)
lists frontend netplay and save states as unsupported.

## Media and input boundaries

Reuse the [Share Play model](../lib/ui/share_play_model.dart) for invites,
signaling, relay credentials, admission and the life of the call. It currently
captures an external window through [the WebRTC adapter](../lib/ui/share_webrtc.dart).
The [embedded host](../windows/runner/retro_core_host.cpp) already receives game
frames and PCM. First prove that a bounded native frame feed can supply a
Windows WebRTC video track. A Flutter texture ID is insufficient. Keep the most
recent frame, bound audio buffering, and only activate capture while hosting.
Send the game texture and game audio so the guest receives no launcher menus,
notifications or desktop audio.

Use [SharePadRouter](../lib/core/together/share_play.dart) for host seat grants.
The [embedded session](../lib/ui/embedded_retro_game.dart) currently sends only
Player 1. Add an input sink keyed by the active session and player port. Keep
P1 local and enable P2 when the host grants the seat. Ignore packets for an old
session or grant and discard reordered input. Clear the port immediately on
revocation, disconnect or session stop. A short timeout clears input if the
release packet is lost. Reconnecting requires a fresh seat grant. Guest input
stays within the game and cannot open the host's Quick Menu or launch another
title.

## Acceptance for the first playable test

- Two Windows PCs on separate networks can invite, join and play a full CTR
  split-screen race. Exercise both direct and relayed calls.
- Verify separate P1 and P2 steering, one guest seat, no stuck inputs after a
  drop, and an immediate stop when the host revokes control.
- Verify the stream carries game video and audio. Open the host Quick Menu and
  confirm the guest receives only the game surface.
- Record capture-to-display and input response delay, frame pacing and stalls.
  Use the observed delay in a race to decide whether the first version is ready.
- Check that standalone PS5 Share Play still works, and run the existing
  [seat authorization tests](../test/core/share_play_test.dart) and
  [launcher invite tests](../test/ui/share_play_test.dart).

Phone Remote Play can consume the same game-only media and input interfaces
after the first desktop guest path works.
