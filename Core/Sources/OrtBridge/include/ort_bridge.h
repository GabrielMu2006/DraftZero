#ifndef ORT_BRIDGE_H
#define ORT_BRIDGE_H

// ORT 推理桥（纯 C 实现）——e5-small ONNX 会话与单条前向。
//
// 为什么是 C：2026-10-04 基线发现同一 dylib/模型/参数下，C 宿主 Run 全程 ~24ms，
// 而 Swift 宿主进程（-O）每节点派发开销被放大 ~700x（见
// Windows/evidence/ENGINE-PERF-BASELINE-2026-10-03.md 附录）。会话逻辑整体
// 下沉到 C 翻译单元，Swift 只负责分词与编排。
//
// 线程模型： OrtEngine 内部持锁，embed 串行（与 C# E5OnnxEmbedder 同策略）。
// 生命周期：ort_engine_open → ort_embed* → ort_engine_close。

#include <stdint.h>

typedef struct OrtEngine OrtEngine; // 不完整类型；跨语言句柄以 void* 传递

/// dlopen 加载 dylib 并建会话（动态 shape，int64 输入）。
/// 返回 0 成功；失败时 err_buf 写入原因并返回非 0。
int ort_engine_open(const char* dylib_path,
                    const char* model_path,
                    int intra_op_threads,
                    void** out,
                    char* err_buf,
                    int err_buf_len);

/// 单条前向：ids/mask 长度 n（<=512），输出 384 维 L2 归一化向量
/// （attention-mask mean pooling，与 C# E5OnnxEmbedder 口径一致）。
/// 返回 0 成功。
int ort_embed(void* engine,
              const int64_t* input_ids,
              const int64_t* attention_mask,
              int n,
              float* out384,
              char* err_buf,
              int err_buf_len);

/// 引擎特征串（模型哈希前 16 位 + 前缀约定），供索引签名使用。
const char* ort_engine_signature(void);

void ort_engine_close(void* engine);

#endif /* ORT_BRIDGE_H */
