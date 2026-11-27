#include <napi/native_api.h>
#include <quickjs.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <time.h>
#include <errno.h>

#define MAX_PENDING 16
#define FETCH_TIMEOUT_SEC 20

typedef struct {
  int used;
  int cancelled;
  int done;
  char *result;
} Pending;

typedef struct {
  pthread_mutex_t mutex;
  pthread_cond_t cond;
  Pending items[MAX_PENDING];
  napi_threadsafe_function tsfn;
} HostBridge;

typedef struct {
  int id;
  char *json;
} FetchPayload;

typedef struct {
  napi_async_work work;
  napi_deferred deferred;
  napi_threadsafe_function tsfn;
  char *script;
  char *result;
  char *error;
} EvalWork;

static HostBridge g_bridge;
static pthread_once_t g_once = PTHREAD_ONCE_INIT;

static void init_bridge(void) {
  pthread_mutex_init(&g_bridge.mutex, NULL);
  pthread_cond_init(&g_bridge.cond, NULL);
  g_bridge.tsfn = NULL;
  for (int i = 0; i < MAX_PENDING; i++) {
    g_bridge.items[i].used = 0;
    g_bridge.items[i].cancelled = 0;
    g_bridge.items[i].done = 0;
    g_bridge.items[i].result = NULL;
  }
}

static void pending_set_result(int id, const char *result) {
  if (id < 0 || id >= MAX_PENDING) {
    free((void *)result);
    return;
  }
  pthread_mutex_lock(&g_bridge.mutex);
  Pending *item = &g_bridge.items[id];
  if (!item->used || item->cancelled) {
    pthread_mutex_unlock(&g_bridge.mutex);
    free((void *)result);
    return;
  }
  free(item->result);
  item->result = strdup(result != NULL ? result : "{}");
  item->done = 1;
  pthread_cond_broadcast(&g_bridge.cond);
  pthread_mutex_unlock(&g_bridge.mutex);
}

static char *host_fetch_wait(int id) {
  struct timespec deadline;
  clock_gettime(CLOCK_REALTIME, &deadline);
  deadline.tv_sec += FETCH_TIMEOUT_SEC;

  pthread_mutex_lock(&g_bridge.mutex);
  Pending *item = &g_bridge.items[id];
  while (!item->done && !item->cancelled) {
    int rc = pthread_cond_timedwait(&g_bridge.cond, &g_bridge.mutex, &deadline);
    if (rc == ETIMEDOUT) break;
  }
  char *result;
  if (item->done && item->result != NULL && !item->cancelled) {
    result = strdup(item->result);
  } else {
    result = strdup("{\"__hostError\":\"host.fetch timeout\"}");
  }
  item->used = 0;
  item->cancelled = 0;
  item->done = 0;
  free(item->result);
  item->result = NULL;
  pthread_mutex_unlock(&g_bridge.mutex);
  return result;
}

static int host_fetch_alloc(void) {
  int id = -1;
  pthread_mutex_lock(&g_bridge.mutex);
  for (int i = 0; i < MAX_PENDING; i++) {
    if (!g_bridge.items[i].used) {
      g_bridge.items[i].used = 1;
      g_bridge.items[i].cancelled = 0;
      g_bridge.items[i].done = 0;
      free(g_bridge.items[i].result);
      g_bridge.items[i].result = NULL;
      id = i;
      break;
    }
  }
  pthread_mutex_unlock(&g_bridge.mutex);
  return id;
}

static JSValue js_host_fetch(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
  (void)this_val;
  if (argc < 1) {
    return JS_NewString(ctx, "{\"__hostError\":\"host.fetch requires a request object\"}");
  }
  const char *json = JS_ToCString(ctx, argv[0]);
  if (json == NULL) {
    return JS_NewString(ctx, "{\"__hostError\":\"host.fetch request is not a string\"}");
  }
  int id = host_fetch_alloc();
  if (id < 0) {
    JS_FreeCString(ctx, json);
    return JS_NewString(ctx, "{\"__hostError\":\"too many concurrent host.fetch calls\"}");
  }
  FetchPayload *payload = (FetchPayload *)malloc(sizeof(FetchPayload));
  if (payload == NULL) {
    JS_FreeCString(ctx, json);
    pending_set_result(id, "{\"__hostError\":\"out of memory\"}");
    char *err = host_fetch_wait(id);
    JSValue out = JS_NewString(ctx, err);
    free(err);
    return out;
  }
  payload->id = id;
  payload->json = strdup(json);
  JS_FreeCString(ctx, json);

  if (g_bridge.tsfn == NULL || payload->json == NULL) {
    free(payload->json);
    free(payload);
    pending_set_result(id, "{\"__hostError\":\"host.fetch bridge is not ready\"}");
    char *err = host_fetch_wait(id);
    JSValue out = JS_NewString(ctx, err);
    free(err);
    return out;
  }

  napi_status status = napi_call_threadsafe_function(g_bridge.tsfn, payload, napi_tsfn_blocking);
  if (status != napi_ok) {
    free(payload->json);
    free(payload);
    pending_set_result(id, "{\"__hostError\":\"host.fetch callback unavailable\"}");
    char *err = host_fetch_wait(id);
    JSValue out = JS_NewString(ctx, err);
    free(err);
    return out;
  }

  char *result = host_fetch_wait(id);
  JSValue out = JS_NewString(ctx, result);
  free(result);
  return out;
}

static void call_js_cb(napi_env env, napi_value js_callback, void *context, void *data) {
  (void)context;
  FetchPayload *payload = (FetchPayload *)data;
  if (payload == NULL) return;
  if (env == NULL || js_callback == NULL) {
    pending_set_result(payload->id, "{\"__hostError\":\"host.fetch callback missing\"}");
    free(payload->json);
    free(payload);
    return;
  }
  napi_value argv[2];
  napi_value recv;
  napi_get_undefined(env, &recv);
  napi_create_int32(env, payload->id, &argv[0]);
  napi_create_string_utf8(env, payload->json != NULL ? payload->json : "{}", NAPI_AUTO_LENGTH, &argv[1]);
  napi_status status = napi_call_function(env, recv, js_callback, 2, argv, NULL);
  if (status != napi_ok) {
    pending_set_result(payload->id, "{\"__hostError\":\"host.fetch callback failed\"}");
  }
  free(payload->json);
  free(payload);
}

static napi_value MakeString(napi_env env, const char *text) {
  napi_value out = NULL;
  napi_create_string_utf8(env, text != NULL ? text : "", NAPI_AUTO_LENGTH, &out);
  return out;
}

static napi_value EvaluateSync(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value argv[1] = {0};
  napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
  if (argc < 1) return MakeString(env, "error: evaluate requires one string argument");

  size_t length = 0;
  napi_get_value_string_utf8(env, argv[0], NULL, 0, &length);
  char *script = (char *)malloc(length + 1);
  if (script == NULL) return MakeString(env, "error: out of memory");
  napi_get_value_string_utf8(env, argv[0], script, length + 1, &length);

  JSRuntime *rt = JS_NewRuntime();
  if (rt == NULL) {
    free(script);
    return MakeString(env, "error: JS_NewRuntime failed");
  }
  JS_SetMemoryLimit(rt, 16 * 1024 * 1024);
  JS_SetMaxStackSize(rt, 512 * 1024);
  JSContext *ctx = JS_NewContext(rt);
  if (ctx == NULL) {
    JS_FreeRuntime(rt);
    free(script);
    return MakeString(env, "error: JS_NewContext failed");
  }
  JSValue value = JS_Eval(ctx, script, length, "<napi>", JS_EVAL_TYPE_GLOBAL);
  const char *result = NULL;
  if (JS_IsException(value)) {
    JSValue exception = JS_GetException(ctx);
    result = JS_ToCString(ctx, exception);
    JS_FreeValue(ctx, exception);
  } else {
    result = JS_ToCString(ctx, value);
  }
  napi_value out = MakeString(env, result != NULL ? result : "error: JS_ToCString failed");
  if (result != NULL) JS_FreeCString(ctx, result);
  JS_FreeValue(ctx, value);
  JS_FreeContext(ctx);
  JS_FreeRuntime(rt);
  free(script);
  return out;
}

static void ExecuteEval(napi_env env, void *data) {
  (void)env;
  EvalWork *work = (EvalWork *)data;
  g_bridge.tsfn = work->tsfn;
  JSRuntime *rt = JS_NewRuntime();
  if (rt == NULL) {
    work->error = strdup("JS_NewRuntime failed");
    return;
  }
  JS_SetMemoryLimit(rt, 16 * 1024 * 1024);
  JS_SetMaxStackSize(rt, 512 * 1024);
  JSContext *ctx = JS_NewContext(rt);
  if (ctx == NULL) {
    JS_FreeRuntime(rt);
    work->error = strdup("JS_NewContext failed");
    return;
  }
  JS_SetContextOpaque(ctx, &g_bridge);
  JSValue global = JS_GetGlobalObject(ctx);
  JSValue host = JS_NewObject(ctx);
  JS_SetPropertyStr(ctx, host, "fetch", JS_NewCFunction(ctx, js_host_fetch, "fetch", 1));
  JS_SetPropertyStr(ctx, global, "host", host);
  JS_FreeValue(ctx, global);

  size_t length = strlen(work->script);
  JSValue value = JS_Eval(ctx, work->script, length, "source.js", JS_EVAL_TYPE_GLOBAL);
  if (JS_IsException(value)) {
    JSValue exception = JS_GetException(ctx);
    const char *text = JS_ToCString(ctx, exception);
    work->error = strdup(text != NULL ? text : "JS_Eval failed");
    if (text != NULL) JS_FreeCString(ctx, text);
    JS_FreeValue(ctx, exception);
  } else {
    const char *text = JS_ToCString(ctx, value);
    work->result = strdup(text != NULL ? text : "");
    if (text != NULL) JS_FreeCString(ctx, text);
  }
  JS_FreeValue(ctx, value);
  JS_FreeContext(ctx);
  JS_FreeRuntime(rt);
}

static void CompleteEval(napi_env env, napi_status status, void *data) {
  EvalWork *work = (EvalWork *)data;
  if (status == napi_ok && work->error == NULL) {
    napi_value value;
    napi_create_string_utf8(env, work->result != NULL ? work->result : "", NAPI_AUTO_LENGTH, &value);
    napi_resolve_deferred(env, work->deferred, value);
  } else {
    napi_value message;
    napi_value error;
    napi_create_string_utf8(env, work->error != NULL ? work->error : "evaluateAsync failed", NAPI_AUTO_LENGTH, &message);
    napi_create_error(env, NULL, message, &error);
    napi_reject_deferred(env, work->deferred, error);
  }
  if (work->tsfn != NULL) {
    napi_release_threadsafe_function(work->tsfn, napi_tsfn_release);
  }
  napi_delete_async_work(env, work->work);
  free(work->script);
  free(work->result);
  free(work->error);
  free(work);
}

static napi_value EvaluateAsync(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value argv[2] = {0};
  napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
  if (argc < 2) {
    napi_throw_type_error(env, NULL, "evaluateAsync(script, onFetch) requires two arguments");
    return NULL;
  }
  napi_valuetype callback_type;
  napi_typeof(env, argv[1], &callback_type);
  if (callback_type != napi_function) {
    napi_throw_type_error(env, NULL, "evaluateAsync onFetch must be a function");
    return NULL;
  }

  size_t length = 0;
  napi_get_value_string_utf8(env, argv[0], NULL, 0, &length);
  char *script = (char *)malloc(length + 1);
  if (script == NULL) {
    napi_throw_error(env, NULL, "out of memory");
    return NULL;
  }
  napi_get_value_string_utf8(env, argv[0], script, length + 1, &length);

  napi_value promise;
  napi_deferred deferred;
  napi_create_promise(env, &deferred, &promise);
  napi_threadsafe_function tsfn;
  napi_status create_status = napi_create_threadsafe_function(
      env, argv[1], NULL, "hostFetch", 0, 1, NULL, NULL, NULL, call_js_cb, &tsfn);
  if (create_status != napi_ok) {
    free(script);
    napi_throw_error(env, NULL, "failed to create host.fetch bridge");
    return NULL;
  }

  EvalWork *work = (EvalWork *)calloc(1, sizeof(EvalWork));
  if (work == NULL) {
    free(script);
    napi_release_threadsafe_function(tsfn, napi_tsfn_release);
    napi_throw_error(env, NULL, "out of memory");
    return NULL;
  }
  work->script = script;
  work->deferred = deferred;
  work->tsfn = tsfn;
  napi_value resource_name;
  napi_create_string_utf8(env, "quickjsEvaluate", NAPI_AUTO_LENGTH, &resource_name);
  napi_create_async_work(env, NULL, resource_name, ExecuteEval, CompleteEval, work, &work->work);
  napi_queue_async_work(env, work->work);
  return promise;
}

static napi_value ResolveFetch(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value argv[2] = {0};
  napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
  if (argc < 2) return MakeString(env, "error");
  int32_t id = -1;
  napi_get_value_int32(env, argv[0], &id);
  size_t length = 0;
  napi_get_value_string_utf8(env, argv[1], NULL, 0, &length);
  char *result = (char *)malloc(length + 1);
  if (result == NULL) return MakeString(env, "error");
  napi_get_value_string_utf8(env, argv[1], result, length + 1, &length);
  pending_set_result(id, result);
  free(result);
  return MakeString(env, "ok");
}

static napi_value Init(napi_env env, napi_value exports) {
  pthread_once(&g_once, init_bridge);
  napi_property_descriptor desc[] = {
      {"evaluate", NULL, EvaluateSync, NULL, NULL, NULL, napi_default, NULL},
      {"evaluateAsync", NULL, EvaluateAsync, NULL, NULL, NULL, napi_default, NULL},
      {"resolveFetch", NULL, ResolveFetch, NULL, NULL, NULL, napi_default, NULL},
  };
  napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
  return exports;
}

static napi_module quickjsModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = NULL,
    .nm_register_func = Init,
    .nm_modname = "quickjs_spike",
    .nm_priv = NULL,
    .reserved = {0},
};

__attribute__((constructor)) void RegisterQuickjsSpike(void) {
  napi_module_register(&quickjsModule);
}
