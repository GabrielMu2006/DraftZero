#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""按 GRDB 的存储约定向 Draft Zero 沙盒库种入冒烟测试草稿（仅本机冒烟用）。"""
import sqlite3, uuid, sys, os

DB = os.path.expanduser("~/Library/Containers/com.draftzero.app/Data/Library/Application Support/DraftZero/DraftZero.sqlite")

docs = [
    ("Agent 评测的想法", "想给大模型做一套分级评测任务集，第一档考检索转述，第二档考跨文档综合，第三档要求自主拆解目标并调用工具。每档单独计分，完成率和平均步数分开看。"),
    ("评测打分 prompt", "判分员只依据任务说明与细则打分。多步工具调用任务：结果一致给基础分，无意义重试扣过程分，报错后换路径完成加稳健分，输出 JSON 格式并引用原文。"),
    ("benchmark 第二版", "评测方案修订：改回三档，每档四十题，中英文混合，任务描述不出现答案关键词。完成率为主指标，榜单只公布雷达图不合成总分。"),
    ("周末采购清单", "鸡蛋、洋葱、蒜、小葱，生抽补一瓶，猫砂买大袋，快递纸箱下周回收。"),
]

conn = sqlite3.connect(DB)
cur = conn.cursor()
cur.execute("DELETE FROM draftVersion")
cur.execute("DELETE FROM indexChunk")
cur.execute("DELETE FROM indexStatus")
cur.execute("DELETE FROM candidatePair")
cur.execute("DELETE FROM draft")
import time
ref = time.time() - 978307200  # timeIntervalSinceReferenceDate
for title, content in docs:
    uid = uuid.uuid4()
    blob = uid.bytes
    cur.execute(
        "INSERT INTO draft (id, title, content, isEditable, hasExtractableText, sourceType, sourceLocation, sourceLabel, snapshotFileURL, fingerprint, sourceVersionSha, importedAt)"
        " VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
        (blob, title, content, 1, 1, "manual", None, None, None, None, None, ref))
    cur.execute(
        "INSERT INTO draftVersion (id, draftId, content, origin, createdAt) VALUES (?,?,?,?,?)",
        (uuid.uuid4().bytes, blob, content, "initial", ref))
conn.commit()
cur.execute("SELECT COUNT(*) FROM draft")
print("drafts in db:", cur.fetchone()[0])
conn.close()
