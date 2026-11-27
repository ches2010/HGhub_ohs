#include <napi/native_api.h>
#include <quickjs.h>
#include <stdlib.h>
#include <string.h>

static napi_value MakeString(napi_env env, const char *text) {
  napi_value out = NULL;
  napi_create_string_utf8(env, text != NULL ? text : "", NAPI_AUTO_LENGTH, &out);
  return out;
}

static napi_value Eval(napi_env env, napi_callback_info info) {
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

static napi_value Init(napi_env env, napi_value exports) {
  napi_property_descriptor desc[] = {
      {"evaluate", NULL, Eval, NULL, NULL, NULL, napi_default, NULL},
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
