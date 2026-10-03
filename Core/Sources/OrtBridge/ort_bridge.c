// ORT 推理桥实现（纯 C）。见 ort_bridge.h 说明。
#include "ort_bridge.h"

#include <dlfcn.h>
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "private/onnxruntime_c_api.h"

#define ORT_DIM 384
#define SIGNATURE "e5-small-int8-onnx-query-v1"

struct OrtEngine {
    void* dylib;
    const OrtApi* api;
    OrtEnv* env;
    OrtSession* session;
    OrtMemoryInfo* mem_info;
    pthread_mutex_t lock;
};

static int check_status(OrtEngine* e, OrtStatus* st, char* err, int err_len) {
    if (st != NULL) {
        const char* msg = e->api->GetErrorMessage(st);
        snprintf(err, (size_t)err_len, "%s", msg ? msg : "unknown ORT error");
        e->api->ReleaseStatus(st);
        return 1;
    }
    return 0;
}

static const OrtApi* load_api(const char* dylib_path, void** dylib_out, char* err, int err_len) {
    *dylib_out = dlopen(dylib_path, RTLD_NOW | RTLD_LOCAL);
    if (*dylib_out == NULL) {
        snprintf(err, (size_t)err_len, "dlopen failed: %s", dlerror());
        return NULL;
    }
    const OrtApiBase* (*get_base)(void) = (const OrtApiBase* (*)(void))dlsym(*dylib_out, "OrtGetApiBase");
    if (get_base == NULL) {
        snprintf(err, (size_t)err_len, "OrtGetApiBase not found");
        return NULL;
    }
    const OrtApiBase* base = get_base();
    return base->GetApi(ORT_API_VERSION);
}

int ort_engine_open(const char* dylib_path, const char* model_path, int intra_op_threads,
                    void** out, char* err, int err_len) {
    *out = NULL;
    OrtEngine* e = (OrtEngine*)calloc(1, sizeof(OrtEngine));
    if (e == NULL) { snprintf(err, (size_t)err_len, "oom"); return 2; }
    pthread_mutex_init(&e->lock, NULL);

    e->api = load_api(dylib_path, &e->dylib, err, err_len);
    if (e->api == NULL) { ort_engine_close(e); return 3; }

    if (check_status(e, e->api->CreateEnv(ORT_LOGGING_LEVEL_ERROR, "DraftZero", &e->env), err, err_len)) { ort_engine_close(e); return 4; }

    OrtSessionOptions* so = NULL;
    if (check_status(e, e->api->CreateSessionOptions(&so), err, err_len)) { ort_engine_close(e); return 5; }
    (void)e->api->SetIntraOpNumThreads(so, intra_op_threads);
    (void)e->api->SetSessionGraphOptimizationLevel(so, ORT_ENABLE_ALL);
    OrtStatus* st = e->api->CreateSession(e->env, model_path, so, &e->session);
    e->api->ReleaseSessionOptions(so);
    if (check_status(e, st, err, err_len)) { ort_engine_close(e); return 6; }

    if (check_status(e, e->api->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &e->mem_info), err, err_len)) { ort_engine_close(e); return 7; }

    *out = e;
    return 0;
}


// 建输入张量；数据缓冲由调用方保活（Run 期间）。
static OrtValue* make_tensor(OrtEngine* e, int64_t* data, int n, char* err, int err_len) {
    int64_t shape[2] = {1, (int64_t)n};
    OrtValue* v = NULL;
    OrtStatus* st = e->api->CreateTensorWithDataAsOrtValue(
        e->mem_info, data, (size_t)n * 8, shape, 2, ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &v);
    if (check_status(e, st, err, err_len)) return NULL;
    return v;
}

int ort_embed(void* handle, const int64_t* input_ids, const int64_t* attention_mask,
              int n, float* out384, char* err, int err_len) {
    OrtEngine* e = (OrtEngine*)handle;
    if (e == NULL) { snprintf(err, (size_t)err_len, "engine null"); return 1; }
    pthread_mutex_lock(&e->lock);

    int64_t ids[512], mask[512], tt[512];
    if (n > 512) n = 512;
    for (int i = 0; i < n; i++) { ids[i] = input_ids[i]; mask[i] = attention_mask[i]; tt[i] = 0; }

    OrtValue* t1 = make_tensor(e, ids, n, err, err_len);
    OrtValue* t2 = t1 ? make_tensor(e, mask, n, err, err_len) : NULL;
    OrtValue* t3 = t2 ? make_tensor(e, tt, n, err, err_len) : NULL;
    OrtValue* output = NULL;
    int rc = 0;
    if (t3 == NULL) { rc = 1; goto done; }

    {
        const char* in_names[] = {"input_ids", "attention_mask", "token_type_ids"};
        const char* out_names[] = {"last_hidden_state"};
        OrtValue* inputs[3] = {t1, t2, t3};
        OrtStatus* st = e->api->Run(e->session, NULL, in_names, (const OrtValue* const*)inputs, 3,
                                    out_names, 1, &output);
        if (check_status(e, st, err, err_len)) { rc = 1; goto done; }
    }

    {
        float* data = NULL;
        if (check_status(e, e->api->GetTensorMutableData(output, (void**)&data), err, err_len)) { rc = 1; goto done; }
        OrtTensorTypeAndShapeInfo* info = NULL;
        int64_t dims[3] = {0, 0, 0};
        if (check_status(e, e->api->GetTensorTypeAndShape(output, &info), err, err_len)) { rc = 1; goto done; }
        size_t dim_count = 0;
        if (check_status(e, e->api->GetDimensionsCount(info, &dim_count), err, err_len)) { e->api->ReleaseTensorTypeAndShapeInfo(info); rc = 1; goto done; }
        if (check_status(e, e->api->GetDimensions(info, dims, dim_count), err, err_len)) { e->api->ReleaseTensorTypeAndShapeInfo(info); rc = 1; goto done; }
        e->api->ReleaseTensorTypeAndShapeInfo(info);
        int64_t tokens = dim_count >= 2 ? dims[dim_count - 2] : 0;
        // attention-mask mean pooling + L2（np.clip 求和/计数口径，与 C# 一致）
        double pooled[ORT_DIM];
        for (int h = 0; h < ORT_DIM; h++) pooled[h] = 0.0;
        double mask_sum = 0;
        for (int64_t t = 0; t < tokens; t++) {
            if (attention_mask[t] == 0) continue;
            mask_sum += 1;
            for (int h = 0; h < ORT_DIM; h++) pooled[h] += data[(size_t)t * ORT_DIM + h];
        }
        if (mask_sum < 1e-9) mask_sum = 1e-9;
        double norm = 0;
        for (int h = 0; h < ORT_DIM; h++) { pooled[h] /= mask_sum; norm += pooled[h] * pooled[h]; }
        norm = norm < 1e-12 ? 1e-12 : sqrt(norm);
        for (int h = 0; h < ORT_DIM; h++) out384[h] = (float)(pooled[h] / norm);
    }

done:
    if (output) e->api->ReleaseValue(output);
    if (t3) e->api->ReleaseValue(t3);
    if (t2) e->api->ReleaseValue(t2);
    if (t1) e->api->ReleaseValue(t1);
    pthread_mutex_unlock(&e->lock);
    return rc;
}

const char* ort_engine_signature(void) { return SIGNATURE; }

void ort_engine_close(void* handle) {
    OrtEngine* e = (OrtEngine*)handle;
    if (e == NULL) return;
    if (e->mem_info) e->api->ReleaseMemoryInfo(e->mem_info);
    if (e->session) e->api->ReleaseSession(e->session);
    if (e->env) e->api->ReleaseEnv(e->env);
    if (e->dylib) dlclose(e->dylib);
    pthread_mutex_destroy(&e->lock);
    free(e);
}
