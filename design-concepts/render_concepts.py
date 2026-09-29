from PIL import Image, ImageDraw, ImageFont, ImageFilter
import random
from pathlib import Path

OUT = Path(__file__).resolve().parent
W, H = 1920, 1120
SANS = "/System/Library/Fonts/Hiragino Sans GB.ttc"
SERIF = "/System/Library/Fonts/Supplemental/Songti.ttc"
LATIN = "/System/Library/Fonts/Supplemental/Georgia.ttf"


def font(size, family="sans"):
    return ImageFont.truetype({"sans": SANS, "serif": SERIF, "latin": LATIN}[family], size)


def make(bg):
    im = Image.new("RGB", (W, H), bg)
    return im, ImageDraw.Draw(im)


def rect(d, box, fill, radius=0, outline=None, width=1):
    d.rounded_rectangle(box, radius=radius, fill=fill, outline=outline, width=width)


def t(d, pos, text, size=20, fill="#222222", family="sans", anchor=None, spacing=5):
    d.multiline_text(pos, text, font=font(size, family), fill=fill, anchor=anchor, spacing=spacing)


def pill(d, box, label, bg, fg, size=17, outline=None):
    rect(d, box, bg, (box[3]-box[1])//2, outline)
    cx = (box[0]+box[2])/2
    cy = (box[1]+box[3])/2
    t(d, (cx, cy), label, size, fg, anchor="mm")


def win(d, box, fill, stroke):
    rect(d, box, fill, 18, stroke, 2)
    x, y, _, _ = box
    for i, c in enumerate(("#E9A69C", "#E5C792", "#A9C7B6")):
        d.ellipse((x+25+i*22, y+24, x+36+i*22, y+35), fill=c)


def board_title(d, number, name, desc, bg_text, accent):
    t(d, (70, 46), f"DRAFT ZERO  /  DESIGN STUDY {number}", 19, accent, "latin")
    t(d, (70, 78), name, 46, bg_text, "serif")
    t(d, (425, 94), desc, 19, bg_text)


def footer(d, text, color, linecolor):
    d.line((70, 1039, 1850, 1039), fill=linecolor, width=2)
    t(d, (70, 1062), text, 18, color)


def save(im, name):
    im.save(OUT / name, optimize=True)


def concept_a():
    # Editorial archive: the project becomes a numbered finding aid.
    bg, ink, muted, line, brass = "#D9D6CC", "#282B27", "#666B65", "#C8C8BE", "#80602D"
    paper, spine, pale = "#F1F0E9", "#E7E6DC", "#E3E6DB"
    im, d = make(bg)
    board_title(d, "01", "索引档案", "像打开一册思想档案：分类、来路和演化在同一页可读。", ink, brass)
    # Main window
    win(d, (70, 173, 1305, 1007), paper, "#B8B9B0")
    d.line((70, 224, 1305, 224), fill=line, width=2)
    t(d, (166, 185), "DRAFT / ZERO", 22, ink, "latin")
    t(d, (1048, 187), "搜索思想", 17, muted)
    pill(d, (1182, 182, 1273, 215), "＋ 新稿", ink, paper, 16)
    # Custom spine, not macOS List
    rect(d, (72, 225, 323, 1005), spine)
    t(d, (113, 265), "索 引", 18, brass)
    for y, no, title, count in [
        (324,"01","草稿箱","12"),(398,"02","线索台","04"),
        (472,"03","想法项目","07"),(546,"04","待办","03"),
        (620,"05","封存","06")]:
        if no == "02":
            rect(d, (96, y-13, 301, y+50), "#D3D9CC", 8)
            d.rectangle((96, y-13, 100, y+50), fill=brass)
        t(d, (111, y), no, 18, brass, "latin")
        t(d, (152, y-3), title, 24, ink if no == "02" else muted)
        t(d, (275, y+3), count, 16, muted, "latin", "ra")
    d.line((105, 709, 294, 709), fill=line, width=2)
    t(d, (112, 741), "项目书签", 17, brass)
    t(d, (112, 789), "●  Agent Benchmark", 18, ink)
    t(d, (112, 830), "○  Ox Alpha", 18, muted)
    t(d, (112, 871), "○  写作系统", 18, muted)
    # work area
    t(d, (362, 260), "02  /  线索台", 21, brass)
    t(d, (362, 303), "有些草稿，已经在互相回应。", 32, ink, "serif")
    t(d, (363, 356), "4 条待确认的归类线索 · 由本机分析生成", 17, muted)
    d.line((362, 398, 1265, 398), fill=line, width=2)
    t(d, (363, 421), "今日发现", 18, brass)
    # proposed grouping card
    rect(d, (362, 463, 982, 733), "#FAFAF6", 10, line, 2)
    t(d, (392, 484), "建议归入  /  AGENT BENCHMARK", 17, brass)
    t(d, (392, 529), "同一个问题的三次靠近", 30, ink, "serif")
    t(d, (392, 580), "Agent Benchmark 想法.md", 20, ink)
    t(d, (392, 611), "Ox Alpha 测试.md", 20, ink)
    t(d, (392, 642), "benchmark-v2.txt", 20, ink)
    pill(d, (392, 679, 505, 718), "查看依据 →", pale, ink, 16)
    pill(d, (837, 679, 949, 718), "确认归类", ink, paper, 16)
    # evidence margin
    t(d, (1012, 471), "证据  01/03", 17, brass)
    d.line((1012, 507, 1260, 507), fill=line, width=2)
    t(d, (1012, 531), "共同词汇", 16, muted)
    t(d, (1012, 562), "agent / benchmark\n模型评测 / 数据集", 18, ink, spacing=11)
    d.line((1012, 649, 1260, 649), fill=line, width=2)
    t(d, (1012, 670), "关系：可能同属项目", 17, ink)
    t(d, (362, 784), "最近归档", 18, brass)
    for y, title, status in [(830,"模型测试 prompt.md","项目 · TODO"),(891,"一个写作系统的片段","项目 · 进行中")]:
        d.line((362, y-15, 1260, y-15), fill=line, width=1)
        t(d, (362, y), title, 22, ink, "serif")
        t(d, (1236, y+5), status, 17, brass, anchor="ra")
    # new draft full canvas
    win(d, (1340, 173, 1850, 1007), paper, "#B8B9B0")
    d.line((1340, 224, 1850, 224), fill=line, width=2)
    t(d, (1430, 189), "新建草稿", 18, muted)
    t(d, (1783, 189), "完成", 18, brass)
    t(d, (1390, 274), "未命名  /  001", 18, brass)
    t(d, (1390, 347), "给这个念头\n起个名字", 40, ink, "serif", spacing=11)
    d.line((1390, 470, 1798, 470), fill=line, width=2)
    t(d, (1390, 503), "写下第一句话…", 22, "#898D82", "serif")
    d.line((1390, 872, 1798, 872), fill=line, width=2)
    t(d, (1390, 889), "暂存于草稿箱  ·  可稍后归类", 17, muted)
    pill(d, (1671, 935, 1807, 981), "保存草稿 →", ink, paper, 17)
    footer(d, "关键词：档案索引 / 纸张连续性 / 来源证据     ·     推荐：阅读与整理密集型用户", muted, line)
    save(im, "01-editorial-archive.png")


def concept_b():
    # Thread map: topology replaces a list-first navigation model.
    bg, base, panel, card = "#1D2A2E", "#25363A", "#2D4145", "#34494C"
    ink, muted, line = "#E4E6DD", "#A9B8B4", "#496064"
    lime, coral, cyan = "#C9D98A", "#E7A894", "#86B7B1"
    im, d = make(bg)
    board_title(d, "02", "线索编织", "让关联建议成为主角：草稿像点，项目像线，确认后形成路径。", ink, lime)
    win(d, (70, 173, 1305, 1007), base, line)
    d.line((70, 226, 1305, 226), fill=line, width=2)
    t(d, (165, 187), "D / Z", 24, lime, "latin")
    for x, name, active in [(285,"收件" ,False),(385,"线索",True),(485,"项目",False),(585,"时间线",False)]:
        t(d, (x, 191), name, 19, ink if active else muted)
        if active: d.line((x, 224, x+40, 224), fill=lime, width=4)
    t(d, (1044, 191), "全局查找", 17, muted)
    pill(d, (1186, 183, 1273, 216), "＋ 捕捉", lime, base, 16)
    # Left mini rail with thematic hierarchy
    rect(d, (72, 227, 287, 1004), "#223236")
    t(d, (105, 260), "线索队列", 20, ink)
    t(d, (105, 304), "按确信程度查看", 16, muted)
    for y, no, a, b, active in [
        (367,"01","高关联","3 条",True),(443,"02","待观察","1 条",False),
        (519,"03","已确认","8 条",False),(595,"04","已忽略","2 条",False)]:
        if active: rect(d, (91,y-12,269,y+55), panel, 10)
        t(d, (107,y),no,17,lime,"latin")
        t(d,(149,y-3),a,20,ink if active else muted)
        t(d,(149,y+26),b,15,muted)
    d.line((102, 695, 261, 695), fill=line, width=1)
    t(d, (105, 722), "这周的轨迹", 17, lime)
    t(d, (105, 760), "5 篇新草稿", 18, ink)
    t(d, (105, 796), "2 个项目生长中", 18, muted)
    # Main topology
    t(d, (331, 264), "想法正在聚拢", 34, ink, "serif")
    t(d, (332, 314), "建议 01 / 04    ·    本机分析    ·    等待你的判断", 17, muted)
    # dotted topology lines
    d.line((530, 547, 739, 459), fill=lime, width=3)
    d.line((764, 484, 963, 575), fill=lime, width=3)
    d.line((550, 585, 741, 765), fill=coral, width=2)
    for x,y in [(530,547),(739,459),(963,575),(741,765)]:
        d.ellipse((x-6,y-6,x+6,y+6), fill=lime if y!=765 else coral)
    # nodes
    rect(d,(347,467,579,626),card,14,line,2)
    t(d,(370,486),"草稿  /  2026.09",15,cyan)
    t(d,(370,524),"Agent Benchmark\n想法.md",22,ink,"serif",spacing=8)
    t(d,(370,603),"可编辑文本 · 1.2k 字",15,muted)
    rect(d,(658,381,889,555),card,14,line,2)
    t(d,(681,400),"草稿  /  2026.09",15,cyan)
    t(d,(681,438),"Ox Alpha\n测试.md",22,ink,"serif",spacing=8)
    t(d,(681,522),"导入快照 · 0.9k 字",15,muted)
    rect(d,(892,524,1239,705),"#3B514E",14,lime,2)
    t(d,(917,547),"可能归入",16,lime)
    t(d,(917,585),"Agent Benchmark",27,ink,"serif")
    t(d,(917,635),"共同讨论 agent 评测框架与测试集。",17,muted)
    rect(d,(665,715,890,833),card,14,line,2)
    t(d,(688,739),"草稿  /  2026.08",15,coral)
    t(d,(688,775),"benchmark-v2.txt",21,ink,"serif")
    # action dock
    rect(d,(330,895,1257,969),"#304348",14,line,1)
    t(d,(355,917),"3 篇草稿 · 共同词汇 7 个 · 时间相近",18,ink)
    pill(d,(954,909,1070,953),"查看依据",card,ink,16)
    pill(d,(1080,909,1234,953),"确认成线 →",lime,base,16)
    # Inline creation canvas rather than form sheet
    win(d,(1340,173,1850,1007),base,line)
    d.line((1340,226,1850,226),fill=line,width=2)
    t(d,(1430,189),"捕捉一个想法",18,ink)
    t(d,(1782,189),"关闭 ×",17,muted)
    t(d,(1384,270),"NEW FRAGMENT  /  001",17,lime,"latin")
    t(d,(1383,338),"写下这个\n尚未完成的念头",37,ink,"serif",spacing=8)
    d.line((1384,465,1806,465),fill=line,width=2)
    t(d,(1384,501),"先写内容，标题可以晚些再取。",19,muted)
    t(d,(1384,553),"每一个想法都会保留来路，\n日后可以拆分、合并或再解释。",20,ink,"serif",spacing=12)
    rect(d,(1382,827,1807,884),panel,10)
    t(d,(1404,846),"↗  之后可加入现有项目",17,muted)
    pill(d,(1640,927,1807,976),"保存到草稿箱",lime,base,17)
    footer(d,"关键词：关系地图 / 线索证据 / 明确确认     ·     推荐：强调“Git for Ideas”差异化",muted,line)
    save(im,"02-thread-map.png")


def concept_c():
    # Living studio: a visual workspace without a permanent sidebar.
    bg, canvas, cream, ink = "#E2DED5", "#EAE6DB", "#F4F0E5", "#3E3A32"
    muted, line, ox, mint, blue = "#6B685F", "#CFC8B9", "#96503F", "#DCE5D5", "#DCE3E5"
    im, d = make(bg)
    board_title(d,"03","未完稿工作室","草稿先被捕捉，再以桌面上的材料堆栈组织；导航藏在顶栏。",ink,ox)
    win(d,(70,173,1305,1007),canvas,line)
    d.line((70,226,1305,226),fill=line,width=2)
    t(d,(165,185),"draft zero.",25,ink,"latin")
    for x,name,active in [(438,"草稿",True),(530,"关联",False),(622,"项目",False),(714,"演化",False)]:
        t(d,(x,190),name,19,ink if active else muted)
        if active: d.line((x,224,x+39,224),fill=ox,width=4)
    t(d,(1030,189),"搜索",17,muted)
    pill(d,(1158,181,1272,218),"＋ 记一笔",ox,cream,16)
    t(d,(106,262),"你的未完稿",43,ink,"serif")
    t(d,(108,323),"13 篇草稿   /   4 条待确认线索   /   3 个进行中项目",18,muted)
    d.line((106,371,1267,371),fill=line,width=2)
    # horizontal contextual chips, no static sidebar
    for box,label,active in [((106,396,211,436),"全部  13",True),((222,396,337,436),"未归类  5",False),((348,396,451,436),"最近编辑",False),((462,396,568,436),"待处理",False)]:
        pill(d,box,label,ink if active else cream,cream if active else muted,16,line if not active else None)
    t(d,(107,483),"最近捕捉",19,ox)
    t(d,(722,483),"项目桌面",19,ox)
    # asymmetric stack cards
    rect(d,(105,532,669,705),cream,12,line,2)
    rect(d,(105,532,112,705),ox)
    t(d,(132,552),"01  /  未归类 · 今天",16,ox)
    t(d,(132,595),"如果 Benchmark 不是一次测试，\n而是一条持续演化的判断链？",27,ink,"serif",spacing=8)
    t(d,(132,672),"一句话草稿  ·  继续写 →",16,muted)
    rect(d,(105,726,669,937),cream,12,line,2)
    rect(d,(105,726,112,937),"#64846F")
    t(d,(132,748),"02  /  AGENT BENCHMARK",16,"#64846F")
    t(d,(132,791),"模型测试 prompt.md",28,ink,"serif")
    t(d,(132,841),"“它衡量的是结果，还是过程？”",21,muted,"serif")
    pill(d,(132,882,320,921),"所属项目 · TODO",mint,ink,16)
    # project landscape
    rect(d,(717,531,1268,791),"#DCE5D5",12,"#BFCEBC",2)
    t(d,(742,554),"PROJECT  /  01",17,"#4E6D58","latin")
    t(d,(742,603),"Agent Benchmark",30,ink,"serif")
    t(d,(742,664),"由 5 篇草稿组成 · 2 次拆分 · 1 次合并",17,muted)
    d.line((742,705,1241,705),fill="#B8CAB6",width=2)
    d.line((754,740,837,740),fill="#4E6D58",width=2)
    for x in (754,795,837):
        d.ellipse((x-5,735,x+5,745),fill="#4E6D58")
    t(d,(874,727),"查看思想演化",20,"#4E6D58")
    rect(d,(717,809,1268,937),blue,12,"#C3CFD0",2)
    t(d,(742,831),"PROJECT  /  02",17,"#5A6E70","latin")
    t(d,(742,871),"Ox Alpha 的另一条路",25,ink,"serif")
    t(d,(742,907),"暂时封存 · 3 篇草稿",16,muted)
    # focus editor
    win(d,(1340,173,1850,1007),cream,line)
    d.line((1340,226,1850,226),fill=line,width=2)
    t(d,(1430,188),"返回草稿箱",18,muted)
    t(d,(1731,188),"···",25,muted)
    t(d,(1380,271),"新草稿  /  今天 09:41",17,ox)
    t(d,(1380,331),"想法从一句话开始",37,ink,"serif")
    d.line((1380,408,1808,408),fill=line,width=2)
    t(d,(1380,450),"写下现在能抓住的部分。",21,ink,"serif")
    t(d,(1380,497),"不必先想清楚项目、标签或结构；\n保存后，Draft Zero 会给出归类建议。",19,muted,"serif",spacing=11)
    rect(d,(1380,768,1808,849),"#E7E2D5",10)
    t(d,(1402,786),"草稿会自动保留编辑版本",17,muted)
    t(d,(1402,814),"保存草稿    ·    返回",16,ox)
    pill(d,(1647,932,1808,978),"保存并返回 →",ox,cream,17)
    footer(d,"关键词：自由捕捉 / 横向导航 / 项目工作台     ·     推荐：低学习成本与日常创作",muted,line)
    save(im,"03-living-studio.png")


def archive_shell(d, active):
    paper, spine, ink, muted, border, accent = "#F1F0E9", "#E7E6DC", "#282B27", "#666B65", "#C8C8BE", "#80602D"
    win(d, (70, 173, 1850, 1007), paper, "#B8B9B0")
    d.line((70, 226, 1850, 226), fill=border, width=2)
    t(d, (166, 185), "DRAFT / ZERO", 22, ink, "latin")
    t(d, (1510, 190), "搜索思想", 17, muted)
    pill(d, (1694, 181, 1813, 218), "＋ 新草稿", ink, paper, 16)
    rect(d, (72, 227, 326, 1005), spine)
    t(d, (112, 267), "索 引", 18, accent)
    for y, no, title, count in [(330, "01", "草稿箱", "13"), (411, "02", "线索台", "04"),
                                (492, "03", "想法项目", "07"), (573, "04", "TODO", "03"),
                                (654, "05", "暂时封存", "06")]:
        if no == active:
            rect(d, (96, y-13, 304, y+53), "#D3D9CC", 8)
            d.rectangle((96, y-13, 101, y+53), fill=accent)
        t(d, (111, y), no, 18, accent, "latin")
        t(d, (154, y-3), title, 23, ink if no == active else muted)
        t(d, (280, y+3), count, 15, muted, "latin", "ra")
    d.line((104, 746, 293, 746), fill=border, width=2)
    t(d, (112, 771), "项目书签", 17, accent)
    t(d, (112, 815), "●  Agent Benchmark", 18, ink)
    t(d, (112, 860), "○  Ox Alpha", 18, muted)
    t(d, (112, 905), "○  写作系统", 18, muted)


def archive_inbox():
    bg, paper, card, ink, muted, line, accent = "#D9D6CC", "#F1F0E9", "#FAFAF6", "#282B27", "#666B65", "#C8C8BE", "#80602D"
    im, d = make(bg)
    board_title(d, "01A", "杂稿收纳", "给半成品一个低压力的落脚点；项目待办与未归组草稿并排可见。", ink, accent)
    archive_shell(d, "01")
    t(d, (366, 257), "01  /  草稿箱", 21, accent)
    t(d, (366, 302), "所有未完成的，都先放在这里。", 34, ink, "serif")
    t(d, (367, 354), "13 份素材 · 5 份尚未归组 · 4 条归类建议等待确认", 18, muted)
    pill(d, (1653, 320, 1811, 363), "导入文件 / 链接", "#E3E6DB", ink, 16)
    d.line((366, 393, 1812, 393), fill=line, width=2)
    for box, label, selected in [((366, 418, 487, 459), "全部  13", True),
                                 ((498, 418, 645, 459), "未归组  5", False),
                                 ((656, 418, 803, 459), "最近编辑", False),
                                 ((814, 418, 969, 459), "来源快照", False)]:
        pill(d, box, label, ink if selected else paper, paper if selected else muted, 16, None if selected else line)
    t(d, (1373, 426), "按最近活动排序", 16, muted)
    # Main stack
    t(d, (366, 500), "草稿与半成品", 19, accent)
    rows = [
        (544, 665, "一句话 / 今天 09:41", "Benchmark 应该记录判断过程", "应用内新建  ·  未归组", "继续写 →"),
        (681, 802, "Prompt / 昨天", "模型测试 prompt.md", "本地 Markdown 副本  ·  属于 Agent Benchmark", "查看 →"),
        (818, 939, "PDF / 9 月 25 日", "关于评测维度的手稿.pdf", "只读快照  ·  无可用正文  ·  可手动归类", "查看 →"),
    ]
    for y1, y2, meta, title, detail, action in rows:
        rect(d, (366, y1, 1339, y2), card, 10, line, 2)
        t(d, (391, y1+16), meta, 15, accent)
        t(d, (391, y1+48), title, 25, ink, "serif")
        t(d, (391, y1+88), detail, 16, muted)
        t(d, (1298, y1+90), action, 16, accent, anchor="ra")
    # contextual task panel, status only applies to projects
    rect(d, (1364, 485, 1812, 939), "#E4E7DD", 12, "#C9D1C6", 2)
    t(d, (1390, 511), "继续推进", 22, ink, "serif")
    t(d, (1390, 556), "TODO 项目", 16, accent)
    d.line((1390, 591, 1785, 591), fill="#C3CCC0", width=1)
    t(d, (1390, 615), "Agent Benchmark", 21, ink, "serif")
    t(d, (1390, 650), "5 份草稿 · 上次编辑于昨天", 16, muted)
    d.line((1390, 698, 1785, 698), fill="#C3CCC0", width=1)
    t(d, (1390, 722), "小说片段集", 21, ink, "serif")
    t(d, (1390, 757), "3 份草稿 · 暂待整理", 16, muted)
    d.line((1390, 817, 1785, 817), fill="#C3CCC0", width=1)
    t(d, (1390, 839), "4 条线索可确认归类", 18, accent)
    t(d, (1390, 880), "去线索台查看依据 →", 17, ink)
    footer(d, "页面职责：捕捉 / 导入 / 找回 / 继续写     ·     TODO 是项目状态；一句话待办可作为文本草稿保存", muted, line)
    save(im, "01a-inbox.png")


def archive_evolution():
    bg, paper, card, ink, muted, line, accent = "#D9D6CC", "#F1F0E9", "#FAFAF6", "#282B27", "#666B65", "#C8C8BE", "#80602D"
    green = "#426C55"
    im, d = make(bg)
    board_title(d, "01B", "思维演化", "从草稿、版本与拆分合并，读回一个想法是怎样形成的。", ink, accent)
    archive_shell(d, "03")
    t(d, (366, 257), "03  /  项目档案  /  Agent Benchmark", 19, accent)
    t(d, (366, 301), "Agent Benchmark", 40, ink, "serif")
    pill(d, (754, 309, 865, 344), "进行中", "#DCE5D8", green, 16)
    t(d, (367, 357), "5 份草稿 · 2 次拆分 · 1 次合并 · 3 个文本版本", 17, muted)
    d.line((366, 399, 1812, 399), fill=line, width=2)
    for x, name, active in [(367,"成员",False),(474,"演化",True),(581,"关系证据",False)]:
        t(d, (x, 425), name, 19, ink if active else muted)
        if active: d.line((474, 459, 516, 459), fill=accent, width=4)
    # timeline area
    rect(d, (366, 487, 1362, 785), card, 11, line, 2)
    t(d, (391, 506), "已确认的演化路径", 17, accent)
    t(d, (1287, 508), "图形  /  文字", 16, muted, anchor="ra")
    # Solid confirmed edges; dashed candidate is separate below.
    d.line((628, 652, 796, 652), fill=green, width=3)
    d.line((1061, 652, 1180, 652), fill=green, width=3)
    for x in (628,796,1061,1180): d.ellipse((x-6,646,x+6,658),fill=green)
    rect(d, (398, 585, 628, 728), "#F1F0E9", 10, line, 2)
    t(d, (416, 602), "起点  /  9 月 10 日", 15, accent)
    t(d, (416, 645), "Agent Benchmark\n想法.md", 21, ink, "serif", spacing=7)
    t(d, (416, 704), "应用内文本 · v3", 14, muted)
    rect(d, (796, 585, 1061, 728), "#E4E9DE", 10, green, 2)
    t(d, (816, 602), "拆分  /  9 月 18 日", 15, green)
    t(d, (816, 645), "评测维度草稿.md", 21, ink, "serif")
    t(d, (816, 704), "从起点草稿拆出", 14, muted)
    rect(d, (1180, 585, 1335, 728), "#F1F0E9", 10, line, 2)
    t(d, (1197, 602), "合并  /  9 月 26 日", 14, accent)
    t(d, (1197, 649), "benchmark-\nv2.txt", 19, ink, "serif", spacing=7)
    t(d, (1197, 704), "保留两份源稿", 13, muted)
    # relationship inspector
    rect(d, (1385, 487, 1812, 947), "#E9E9DF", 11, line, 2)
    t(d, (1412, 512), "关系档案  /  02", 17, accent)
    t(d, (1412, 565), "一次拆分，\n留下了新的问题。", 28, ink, "serif", spacing=7)
    d.line((1412, 675, 1786, 675), fill=line, width=2)
    t(d, (1412, 698), "来源", 15, muted)
    t(d, (1412, 729), "Agent Benchmark 想法.md", 18, ink)
    t(d, (1412, 775), "关系说明", 15, muted)
    t(d, (1412, 806), "从测试方法中拆出评测维度，\n后续又进入第二版方案。", 18, ink, spacing=7)
    t(d, (1412, 901), "打开草稿与版本 →", 17, accent)
    # accessible event list, not merely a decorative diagram
    t(d, (366, 812), "事件记录", 18, accent)
    d.line((366, 847, 1362, 847), fill=line, width=1)
    t(d, (373, 863), "09.26", 16, muted, "latin")
    t(d, (470, 860), "合并为 benchmark-v2.txt  ·  两份来源保留", 18, ink)
    d.line((366, 899, 1362, 899), fill=line, width=1)
    t(d, (373, 915), "09.18", 16, muted, "latin")
    t(d, (470, 912), "从想法.md 拆出评测维度草稿  ·  可打开来源", 18, ink)
    footer(d, "页面职责：追溯 / 比较 / 解释     ·     图与可操作文字列表同步；系统建议与已确认关系分开", muted, line)
    save(im, "01b-evolution.png")


if __name__ == "__main__":
    OUT.mkdir(parents=True, exist_ok=True)
    concept_a()
    concept_b()
    concept_c()
    archive_inbox()
    archive_evolution()
    print("Rendered 5 concept boards to", OUT)
