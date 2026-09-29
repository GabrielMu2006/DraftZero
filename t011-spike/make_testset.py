# -*- coding: utf-8 -*-
"""T-011 baseline test set generator.

Builds 31 drafts across 5 project threads + duplicates + filename traps + unrelated
singletons, per SPEC.md quality gate (>=5 threads, >=6 unrelated, zh/en mixed,
similar-filename-different-topic, different-filename-same-topic, short & long docs).

NOTE (A-007): this is a SPIKE baseline, not the final user-approved test set.
"""
import json, os, random

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "testset")

DOCS = {}

# ---------- Thread A: LLM Agent Benchmark 评测方案 (mixed zh/en, cross-language pairs) ----------
DOCS["Agent Benchmark 想法.md"] = ("A", """# Agent Benchmark 想法

最近一直在想一个问题：怎么比较不同大模型做长链条任务的真实水平。市面上的榜单大多考单轮问答，可我们真正关心的是模型能不能把一件多步的事从头做到尾。

我的初步想法是设计一套分级任务集。第一档是纯检索加转述，第二档要求跨文档综合，第三档让模型自己拆解目标、调用工具、遇到报错能自我修正。每一档单独计分，最后合成一个总分，但总分要给出各档权重，不能糊成一个数字。

评分标准也得先定下来。结果对不对是一层，过程是否浪费步骤是另一层。我倾向于两维分开看：完成率和平均步数。一个模型八步做对，另一个六步做对，不能只看对错。

先手工出三十道题试试水，重点看任务描述有没有歧义。题目本身写不清楚，测出来的差异没有意义。
""")

DOCS["模型测试 prompt.md"] = ("A", """# 模型测试 prompt 草稿

这是给评测集用的判分提示词，配合分级任务集一起用。

判分员角色：你是严格的评测员，只依据任务说明与评分细则打分，不被回答的语气和篇幅影响。

对第三档任务（多步工具调用），按下面的细则核对：
1. 最终结果与任务目标一致，给基础分。
2. 中途每多一次无意义的重试，扣过程分。
3. 遇到工具报错后能换路径完成，加稳健分。

输出格式固定为 JSON：completed、steps_used、robustness、comment 四个字段。comment 必须引用回答原文里的具体片段，不许写空话。

这套提示词要跟 benchmark 的每一档对齐，档位变了细则也要跟着改。
""")

DOCS["benchmark-v2.txt"] = ("A", """benchmark 方案第二版（对想法稿的修订）

删掉了原来“四档”的设计，改回三档，理由是第二档和第三档在我们内部试测里区分不开。

任务量：每档 40 题，其中中文 25 题、英文 15 题，任务描述不许出现与答案相同的关键词，防止背题。

计分改为：完成率为主指标，平均步数与自我修正次数作为并列的次指标。榜单不公布单一总分，只公布三档的雷达图。

下一步：找五个人各独立写八道题，交叉审题去掉歧义后再跑第一轮。
""")

DOCS["agent_eval_notes.md"] = ("A", """# Notes on evaluating LLM agents

Most leaderboards test single-turn QA, which tells us little about whether a model can carry a long task through to the end. I want a tiered task suite instead:

- Tier 1: retrieval plus restatement.
- Tier 2: synthesis across several documents.
- Tier 3: the model must decompose the goal, call tools, and recover from its own errors.

Score completion rate separately from process efficiency. A model that succeeds in eight steps is not the same as one that succeeds in six. Plan: hand-write thirty tasks first and check that every task statement is unambiguous before running anything.
""")

DOCS["评测报告节选（长）.txt"] = ("A", """【以下为某评测报告正文节选，用于测试长文档摘录的归联】

三、任务集设计说明

本次评测采用三档分级任务集。第一档考察检索与转述能力，任务给定两份短文档，要求模型在不引入外部信息的前提下完成要点摘录；第二档考察跨文档综合，任务给定四到六份存在观点冲突的材料，要求模型输出一份带引用位置的综述；第三档考察自主规划，模型需要将一个模糊目标拆解为可执行步骤，在沙箱环境中调用提供的工具完成交付物，并对工具返回的报错做出处理。

四、判分方式

每档任务由两名标注员依据统一细则独立判分，分歧超过一档时提交仲裁。完成率定义为首轮尝试即达成任务目标的比例；过程效率以平均工具调用次数衡量；稳健性定义为遇到报错后仍能完成任务的子集上的完成率。三个指标分开呈现，不合成单一总分。

五、主要发现

在第三档任务上，各模型完成率均低于前两档，且中文任务的完成率整体低于英文任务。报错处理是主要失分点：超过一半的失败案例中，模型在第一次工具报错后重复同一调用，而不是更换路径。这一现象在长任务中更明显。

六、对下一轮的建议

建议扩充第三档的中文任务数量，并在任务描述中明确交付物格式，减少因格式理解不一致造成的判分争议。
""")

# ---------- Thread B: 小说《雨夜书店》(different filenames, same topic) ----------
DOCS["雨夜书店_第一章.md"] = ("B", """# 雨夜书店 · 第一章

雨是从傍晚开始下的。程澄把梯子架到书架顶层，取下一本蓝布面的旧账簿，封皮上还留着上一任店主写的编号。

风铃在这时候响了。她探头望去，门口站着一个收伞的年轻男人，肩头洇湿了一片。“随便看看？”她问。男人点点头，却在悬梯旁停下，盯着那本账簿看了很久。

“这本不卖。”她说。

男人笑了一下，从怀里取出一张泛黄的借书卡，放在柜台上。卡片的编号，和账簿扉页上的那一行，一模一样。
""")

DOCS["深夜灵感.txt"] = ("B", """深夜想到的几个片段，先记下来：

- 风铃要贯穿全书。第一章进门响一次，结尾她离开时再响一次，中间任何一次风铃响都不该是自然的风。
- 借书卡的设定再想想：每张卡的编号对应账簿里一个从未借出过的书名，这些书名连起来是店主留下的信。
- 男主角不要叫沈某了，太滥。就叫“顾一舟”，摆渡的意思，跟书店夜里给人避雨呼应。
- 第二章开头可以是停电，烛光下她翻账簿，发现最近一页的墨迹还没干透。
""")

DOCS["书店故事大纲.md"] = ("B", """# 《雨夜书店》故事大纲

一句话：一家只在雨夜营业的旧书店，账簿里记着所有未曾发生的事。

结构：三幕。第一幕，程澄接手书店，发现借书卡编号与账簿对不上的秘密；第二幕，顾一舟为寻找祖母的借书卡而来，两人开始按编号“还书”；第三幕，账簿最后一页写着程澄自己的名字，她必须决定是否把今晚从记录里划去。

基调：湿冷里带一点暖，超现实元素克制出现，所有异象最终都有人味的解释。
""")

DOCS["character_notes.md"] = ("B", """# 人物小传（草稿）

程澄，二十九岁，前古籍修复学徒。手稳，话少，习惯把所有情绪折进纸页里。接手书店不是继承，是抵债——她姨妈欠了人钱，把店押给了她。

顾一舟，三十二岁，夜班调度员，习惯在雨夜步行回家。祖母去世后留下一张从未用过的借书卡，编号奇怪。他起初只想弄清楚这张卡的来历。

店主（已故）：只在账簿边角的批注里出场。批注越来越潦草，最后一行是“别翻到最后一页”。
""")

# ---------- Thread C: 个人知识库应用"纸堆" ----------
DOCS["纸堆 README 草稿.md"] = ("C", """# 纸堆（PaperStack）README 草稿

纸堆是一个本地优先的个人知识库应用，所有笔记存在用户自己的磁盘上，没有账号，没有云。

核心设计有三条。第一，全文检索必须离线可用，索引随库保存在同一目录；第二，笔记之间的链接是双向的，删掉一篇笔记时反向链接会提示“来源已删除”而不是悄悄断掉；第三，导出永远是纯 Markdown 加附件文件夹，不用数据库格式锁住用户。

目标用户是在意数据归属的写作者和研究者。首版只做 macOS。
""")

DOCS["note-app-features.txt"] = ("C", """PaperStack feature list (working notes)

- Local-first: the library is a plain folder of markdown files, no account, no cloud sync in v1.
- Full-text search must work fully offline; the search index ships with the library folder.
- Bidirectional links; deleting a note keeps backlinks visible as "source deleted" instead of silently breaking them.
- Export: plain markdown plus an attachments folder. No proprietary database.
- Target: macOS first, writers and researchers who care about data ownership.
""")

DOCS["本地优先同步方案.md"] = ("C", """# 本地优先的同步/备份方案（内部讨论稿）

纸堆不做云同步，但用户会用 iCloud Drive 或网盘整库备份，这带来并发写冲突问题。

方案：每个笔记文件独立，任何写入先写临时文件再原子替换；检测到同 mtime 冲突时保留两份并弹出“冲突副本”，绝不自动合并正文。索引文件不进备份目录，标记为可重建——用户换电脑后第一件事就是重建索引，不丢任何笔记内容。

冲突副本的 UI 文案参考“可能重复”队列的措辞，让用户并排比较后自己决定。
""")

DOCS["知识库竞品笔记.md"] = ("C", """# 知识库竞品试用笔记

试用了一圈主流知识库工具，记几个跟我们定位的差异点。

甲工具：同步做得最好，但库是私有数据库格式，导出永远不完整，跟纸堆“导出即纯 Markdown”正好相反。乙工具：链接和图谱做得花哨，可搜索必须联网走它的服务，本地优先是假的。丙工具：最接近我们的理念，可惜没有双向链接，删除笔记时反向引用直接消失。

结论：纸堆的差异点就定在“离线全文检索 + 可追溯的删除”，这两条竞品没有同时做到的。
""")

# ---------- Thread D: 家庭烘焙 ----------
DOCS["面包笔记.md"] = ("D", """# 面包笔记

这个月的经验：客厅温度二十度左右时，直接法一次发酵要两个半小时，不能照配方写的九十分钟。面团状态比时间可靠，发到两倍大、指洞不回缩才算好。

欧包的割包角度试出来了，刀刃倾斜四十五度，一刀到底不要犹豫，割口才炸得开。蒸汽还是要用铸铁锅焖，烤前二百三十度带盖二十分钟，再开盖两百一十度上色。

下次想试天然酵母，先把葡萄干酵种养起来。
""")

DOCS["sourdough schedule.txt"] = ("D", """Sourdough weekend schedule (draft)

Friday night: feed the starter, target doubling in 6-8 hours at room temp.
Saturday morning: autolyse flour and water for 1 hour, add starter and salt, then four sets of stretch and folds every 30 minutes.
Bulk ferment until 50% rise, shape, cold retard in the fridge overnight.
Sunday: bake in a preheated dutch oven, 230C covered for 20 minutes, then uncovered until deep brown.
Notes: the kitchen is cold in winter, watch the dough, not the clock.
""")

DOCS["周末烘焙计划.txt"] = ("D", """周末烘焙计划

周六上午：乡村欧包一条，按面包笔记里的时间和温度来，蒸汽用铸铁锅。
周六下午：给妈烤一炉玛德琳，贝壳模记得先抹油撒粉。
周日：空出来，如果欧包成功就趁热拍照片记档，失败就写失败原因。

采购：高筋粉、黑麦粉、黄油、柠檬（玛德琳皮屑用）。
""")

DOCS["烘焙书摘录（长）.md"] = ("D", """【以下为某烘焙书章节摘录，测试长文档摘录归联】

关于发酵，最重要的一课是学会观察面团而不是钟表。配方给出的时间永远基于作者厨房的温度，而你的厨房在冬天和夏天可能是两个世界。判断的标准只有三个：体积增长到原来的大致倍数、表面出现气泡、指孔测试时面团缓慢回弹但不完全填平。

蒸汽在烘烤前段的作用是保持表皮柔软，让面团充分膨胀，也就是所谓“烤箱反弹”。家用条件下获得蒸汽最简单的办法是带盖铸铁锅：预热时连同锅盖一起加热，入锅后前二十分钟盖紧，之后开盖让水分散去、表皮上色。

割包不是装饰。割口决定了面团膨胀时从哪里裂开，一刀利落地斜向切入，深度约半厘米，Angle 保持稳定，犹豫的刀会拖出面团的黏性，让裂口参差不齐。刚练手时宁可用剪，也不要慢慢锯。

天然酵种的培养没有神秘之处：等比例的面粉和水，每天喂养，头几天丢掉一部分再喂，直到酵母菌稳定到喂后八小时内稳定翻倍。失败的头号原因是不耐烦——第三天闻起来像指甲油的气味是正常的，那是杂菌的前奏，继续喂就会过去。
""")

# ---------- Thread E: 播客「慢速代码」 ----------
DOCS["播客选题清单.md"] = ("E", """# 播客「慢速代码」选题清单

定位：给独立开发者的长访谈节目，每期聊一个人怎么把小软件做成能养活自己的生意。

已定选题：
1. 做记事本应用做到第五年的单人开发者——聊聊定价和用户邮件。
2. 从大厂辞职做 Mac 效率工具的前同事——聊聊第一批一千个用户怎么来的。
3. 周更十年的技术博客作者——写作怎么反哺开发。

待定：做游戏不如做工具赚钱吗？想找个独立游戏人聊聊。
""")

DOCS["podcast_episode_outline.txt"] = ("E", """Episode 1 outline - the notebook app, five years in

Cold open: the developer reads one of the nicest user emails out loud.
Segment 1: how the app started as a weekend hack and why it stayed small.
Segment 2: pricing - one-time purchase vs subscription, what the numbers actually look like after five years.
Segment 3: answering user email as a product practice; the "source deleted" backlink story as an example of detail work.
Outro: what "slow code" means - shipping less, but shipping for a decade.
""")

DOCS["嘉宾邀请话术.md"] = ("E", """# 嘉宾邀请邮件模板

主题：播客「慢速代码」邀请——聊你的独立开发故事

正文要点：先说明节目定位（长访谈、不快问快答、成片前嘉宾可以审听）；再具体提一件对方作品里我们真正用过并喜欢的细节，绝不群发模板腔；最后给出录制时长（九十分钟内）和可以改期三次的诚意。

跟进节奏：首封无回复七天后跟进一次，只跟一次，不追扰。
""")

DOCS["第一期脚本草稿.md"] = ("E", """# 第一期脚本草稿（记事本应用开发者）

开场白：这档节目叫「慢速代码」，因为我们相信小软件可以慢慢长大。今天嘉宾做一款记事本应用，做了五年，没有融资，没有团队。

第一段从那封邮件开始。他收到过一封用户来信，说这款应用陪她写完了整本博士论文。他没有把这封信裱起来，而是把它贴在工位上，上面标注了一行小字：这就是第五年的意义。

中间段聊定价。一次买断六十块，五年没涨过价，理由是“老用户是种子”。数据：买断转化率不高，但退款率几乎为零。

结尾抛出下一期预告。
""")

# ---------- Filename traps (share surface words with threads, but unrelated) ----------
DOCS["prompt 练习册.md"] = ("U", """# 写作 prompt 练习册

给自己开的自由写作练习，每天十分钟，不停笔。

今天的题目：写一个你只见过一次的人。要求不出现外貌描写，只通过他挑选蔬菜的动作来写。

明天的题目：把今天公交车上听到的半句话补全成一个故事的开头。
（注：这是手写练习，与任何模型或软件无关。）
""")

DOCS["模型测试记录_0712.txt"] = ("U", """意式咖啡机压力测试记录 0712

换了新的粉碗之后重新测萃取。九bar压力下25秒出液36克，味道偏酸，判断是研磨偏粗。调细两格后27秒38克，酸甜平衡好了很多。

结论：这台机器的室温稳定性比压力参数更影响出品，冬天要先空放水暖机。
""")

# ---------- Duplicate pair ----------
DOCS["面包笔记_备份.txt"] = ("D", """# 面包笔记

这个月的经验：客厅温度二十度左右时，直接法一次发酵要两个半小时，不能照配方写的九十分钟。面团状态比时间可靠，发到两倍大、指洞不回缩才算好。

欧包的割包角度试出来了，刀刃倾斜四十五度，一刀到底不要犹豫，割口才炸得开。蒸汽还是要用铸铁锅焖，烤前二百三十度带盖二十分钟，再开盖两百一十度上色。

下次想试天然酵母，先把葡萄干酵种养起来。""")

# ---------- Unrelated singletons ----------
DOCS["购物清单.txt"] = ("U", """购物清单

鸡蛋、洋葱、蒜、小葱
生抽补一瓶，厨房纸
猫砂（大袋）
快递纸箱攒着下周回收
""")

DOCS["旅行装箱清单.md"] = ("U", """# 出发前装箱

证件：身份证、护照（看签证有效期！）
电子：相机、两块电池、充电器、转换插头
衣物按七晚配，雨具必带
出发前关燃气、关窗、喂猫托付邻居
""")

DOCS["健身计划.txt"] = ("U", """秋冬训练安排

周一/周四：下肢，深蹲主项5x5
周二/周五：上肢推拉
周三：慢跑四十分钟，配速放到能说话
腰伤没好透前不练硬拉
""")

DOCS["会议纪要_社区业委会.md"] = ("U", """# 业委会会议纪要（九月）

1. 电梯维保合同续签，两家报价对比后选乙方，差价在预算内。
2. 地库照明改造分两期，一期先做 B 区。
3. 绿化补种方案公示七天后再表决。
4. 下次会议十月第三个周二。
""")

DOCS["tax checklist.txt"] = ("U", """Q3 bookkeeping checklist

- Reconcile bank feed, flag any transaction without a receipt.
- Separate the equipment purchase (new monitor) into fixed assets.
- Check the invoice for the design contractor includes their tax ID.
- Set aside the estimated payment before the deadline.
""")

DOCS["装修报价对比.md"] = ("U", """# 装修报价对比

A 公司：全包二十一万八，含两个卫生间洁具，工期九十天；水电改造按实结算，单价偏高。
B 公司：半包十六万，主材自购，工期一百天，合同写明增项不超总价百分之五。
待办：让两家都补一份防水质保年限的书面说明再定。
""")

EXPECTED_DUPLICATE = ("面包笔记_备份.txt", "面包笔记.md")

def main():
    os.makedirs(ROOT, exist_ok=True)
    ground = {"note": "T-011 spike baseline (A-007: pending product-owner approval)",
              "threads": {}, "duplicates": [], "unrelated": []}
    for name, (group, body) in DOCS.items():
        with open(os.path.join(ROOT, name), "w", encoding="utf-8") as f:
            f.write(body)
        if group == "U":
            ground["unrelated"].append(name)
        else:
            ground["threads"].setdefault(group, []).append(name)
    ground["duplicates"].append(list(EXPECTED_DUPLICATE))
    with open(os.path.join(os.path.dirname(ROOT), "groundtruth.json"), "w", encoding="utf-8") as f:
        json.dump(ground, f, ensure_ascii=False, indent=2)
    n = len(DOCS)
    print(f"wrote {n} docs; threads={ {k: len(v) for k, v in ground['threads'].items()} }, unrelated={len(ground['unrelated'])}")

if __name__ == "__main__":
    main()
