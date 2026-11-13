// Checks the clip player's libanyps5_mpv.so (linux/mpv_shim) the way the launcher uses it:
// media_kit opens the system's libmpv first (from Dart, RTLD_LAZY, its own names in its order)
// and makes a player; the plugin then calls libmpv through libanyps5_mpv.so, which has to reach
// that same libmpv. Without a libmpv, each of its functions has to fail cleanly, not crash.
//
//   mpv-shim-check <path to libanyps5_mpv.so> with      the system has a libmpv: calls go to it
//   mpv-shim-check <path to libanyps5_mpv.so> without   it has none: calls fail with an error
//
// CI builds it on the Ubuntu 22.04 runner (cc mpv-shim-check.c -ldl) and runs it on clean
// Ubuntu 22.04 and 24.04 (packaging/linux/check-libmpv.sh). No libmpv headers: the few types
// it needs are written out here as libmpv's client.h and render.h define them.
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define MPV_ERROR_UNINITIALIZED (-3)
#define MPV_FORMAT_STRING 1
#define MPV_FORMAT_NODE 6
#define MPV_RENDER_PARAM_INVALID 0
#define MPV_RENDER_PARAM_API_TYPE 1

typedef struct {
  int type;
  void *data;
} render_param;

typedef struct {
  union {
    char *string;
    int64_t int64;
    double double_;
    void *list;
  } u;
  int format;
} node;

static int failures = 0;

static void expect(int ok, const char *what) {
  printf("  %s %s\n", ok ? "ok  " : "FAIL", what);
  if (!ok) failures++;
}

int main(int argc, char **argv) {
  if (argc != 3 || (strcmp(argv[2], "with") != 0 && strcmp(argv[2], "without") != 0)) {
    fprintf(stderr, "usage: mpv-shim-check <libanyps5_mpv.so> with|without\n");
    return 2;
  }
  const int with = strcmp(argv[2], "with") == 0;

  // As media_kit does (NativeLibrary.ensureInitialized).
  const char *names[] = {"libmpv.so", "libmpv.so.2", "libmpv.so.1"};
  void *mpv = NULL;
  const char *opened = NULL;
  for (unsigned i = 0; i < sizeof names / sizeof *names && mpv == NULL; i++) {
    mpv = dlopen(names[i], RTLD_LAZY | RTLD_LOCAL);
    if (mpv != NULL) opened = names[i];
  }
  printf("system libmpv: %s\n", opened ? opened : "none");
  expect(with ? mpv != NULL : mpv == NULL, with ? "the system has a libmpv" : "the system has no libmpv");

  // As the launcher loads it: a library its plugin links, in the global scope.
  void *shim = dlopen(argv[1], RTLD_NOW | RTLD_GLOBAL);
  if (shim == NULL) {
    printf("  FAIL %s\n", dlerror());
    return 1;
  }
  int (*set_option)(void *, const char *, const char *) =
      (int (*)(void *, const char *, const char *))dlsym(shim, "mpv_set_option_string");
  int (*get_property)(void *, const char *, int, void *) =
      (int (*)(void *, const char *, int, void *))dlsym(shim, "mpv_get_property");
  void (*free_node)(node *) = (void (*)(node *))dlsym(shim, "mpv_free_node_contents");
  int (*render_create)(void **, void *, render_param *) =
      (int (*)(void **, void *, render_param *))dlsym(shim, "mpv_render_context_create");
  void (*render_callback)(void *, void (*)(void *), void *) =
      (void (*)(void *, void (*)(void *), void *))dlsym(shim, "mpv_render_context_set_update_callback");
  int (*render)(void *, render_param *) = (int (*)(void *, render_param *))dlsym(shim, "mpv_render_context_render");
  void (*render_free)(void *) = (void (*)(void *))dlsym(shim, "mpv_render_context_free");
  expect(set_option && get_property && free_node && render_create && render_callback && render && render_free,
         "libanyps5_mpv.so has the seven functions the plugin calls");
  if (failures) return 1;

  char sw[] = "sw";
  render_param params[] = {{MPV_RENDER_PARAM_API_TYPE, sw}, {MPV_RENDER_PARAM_INVALID, NULL}};

  if (!with) {
    expect(set_option(NULL, "vo", "libmpv") == MPV_ERROR_UNINITIALIZED, "mpv_set_option_string fails");
    char *text = NULL;
    expect(get_property(NULL, "mpv-version", MPV_FORMAT_STRING, &text) == MPV_ERROR_UNINITIALIZED && text == NULL,
           "mpv_get_property fails");
    void *context = (void *)1;
    expect(render_create(&context, NULL, params) == MPV_ERROR_UNINITIALIZED && context == NULL,
           "mpv_render_context_create fails and gives no context");
    expect(render(NULL, params) == MPV_ERROR_UNINITIALIZED, "mpv_render_context_render fails");
    free_node(NULL);
    render_callback(NULL, NULL, NULL);
    render_free(NULL);
    expect(1, "the functions without a result do nothing");
  } else {
    void *(*create)(void) = (void *(*)(void))dlsym(mpv, "mpv_create");
    int (*initialize)(void *) = (int (*)(void *))dlsym(mpv, "mpv_initialize");
    void (*destroy)(void *) = (void (*)(void *))dlsym(mpv, "mpv_terminate_destroy");
    void (*mpv_free)(void *) = (void (*)(void *))dlsym(mpv, "mpv_free");
    void *player = create ? create() : NULL;
    expect(player != NULL, "mpv_create (the system's libmpv) makes a player");
    if (player == NULL) return 1;
    expect(set_option(player, "vo", "libmpv") == 0, "mpv_set_option_string reaches it");
    expect(set_option(player, "ao", "null") == 0, "mpv_set_option_string again");
    expect(initialize(player) == 0, "mpv_initialize");
    char *version = NULL;
    expect(get_property(player, "mpv-version", MPV_FORMAT_STRING, &version) == 0 && version != NULL,
           "mpv_get_property reaches it");
    if (version) {
      printf("  mpv-version: %s\n", version);
      mpv_free(version);
    }
    node value;
    memset(&value, 0, sizeof value);
    expect(get_property(player, "mpv-version", MPV_FORMAT_NODE, &value) == 0 && value.format == MPV_FORMAT_STRING,
           "mpv_get_property as a node");
    free_node(&value);
    void *context = NULL;
    const int made = render_create(&context, player, params);
    expect(made == 0 && context != NULL, "mpv_render_context_create (software) reaches it");
    if (context) {
      render_callback(context, NULL, NULL);
      render_free(context);
    }
    destroy(player);
  }
  if (failures) {
    printf("libanyps5_mpv.so: %d failed\n", failures);
    return 1;
  }
  printf("libanyps5_mpv.so: every check passed\n");
  return 0;
}
