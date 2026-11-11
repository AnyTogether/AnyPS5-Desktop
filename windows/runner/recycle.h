#ifndef RUNNER_RECYCLE_H_
#define RUNNER_RECYCLE_H_

// Delete game: a folder or a file into the Recycle Bin, where it can be put back from, with
// the shell's own IFileOperation. Nothing is ever deleted for good here: when Windows would
// destroy the item instead of recycling it (a drive without a Recycle Bin, a folder bigger than
// the bin may hold), the item is left untouched and the launcher asks again.
//
// The work happens on a thread of this library's own (a folder of tens of thousands of files
// takes its time), with no window and no question from Windows. A library of its own with a
// plain C face, as now_playing is: the runner is built without exceptions.

#ifdef __cplusplus
extern "C" {
#endif

enum {
  // In the Recycle Bin.
  kRecycleDone = 0,
  // Windows has no Recycle Bin for it where it is; nothing was touched.
  kRecycleNoBin = 1,
  // It could not be moved (in use, no permission, not there); nothing was removed for good.
  kRecycleFailed = 2,
};

// Called on the library's thread when the work is over, with one of the codes above.
typedef void (*RecycleFinished)(void* context, int code);

// Starts moving the absolute path (UTF-16, backslashes) to the Recycle Bin. Returns 0 when
// the thread could not be started; finished is then never called.
int RecycleStart(const wchar_t* path, RecycleFinished finished, void* context);

#ifdef __cplusplus
}
#endif

#endif  // RUNNER_RECYCLE_H_
