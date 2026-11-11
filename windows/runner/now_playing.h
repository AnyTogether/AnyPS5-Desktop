#ifndef RUNNER_NOW_PLAYING_H_
#define RUNNER_NOW_PLAYING_H_

#include <stddef.h>
#include <stdint.h>

// What a media player on this computer plays, from Windows' system media transport controls
// (GlobalSystemMediaTransportControlsSessionManager): the session Windows itself calls the
// current one, whichever player it belongs to. Written in C++/WinRT, which needs exceptions,
// so it is a library of its own with a plain C face (the runner is built without them).
//
// Everything Windows is asked happens on a thread of this library's own. The calls here never
// wait for it: NowPlayingRead copies what was read last.

#ifdef __cplusplus
extern "C" {
#endif

typedef struct NowPlaying NowPlaying;

// Called on the library's thread each time what NowPlayingRead gives has changed.
typedef void (*NowPlayingChanged)(void* context);

typedef struct NowPlayingTrack {
  // 0: no player has a session (or Windows has no such thing); the rest is then empty.
  int present;
  // 0 while paused.
  int playing;
  // UTF-8, never null while present; artist and player may be empty.
  char* title;
  char* artist;
  char* player;
  // The cover as the player gave it (PNG or JPEG), null when it gave none.
  uint8_t* artwork;
  size_t artwork_size;
} NowPlayingTrack;

enum {
  kNowPlayingPlayPause = 0,
  kNowPlayingNext = 1,
  kNowPlayingPrevious = 2,
};

// Null when the thread could not be started.
NowPlaying* NowPlayingCreate(NowPlayingChanged changed, void* context);
void NowPlayingDestroy(NowPlaying* now_playing);

// Follows the current session by Windows' own events, or stops: nothing is read while off.
void NowPlayingWatch(NowPlaying* now_playing, int on);

// One of the commands above, to the current session.
void NowPlayingCommand(NowPlaying* now_playing, int command);

// Copies what was read last into track; give it back with NowPlayingFree.
void NowPlayingRead(NowPlaying* now_playing, NowPlayingTrack* track);
void NowPlayingFree(NowPlayingTrack* track);

#ifdef __cplusplus
}
#endif

#endif  // RUNNER_NOW_PLAYING_H_
