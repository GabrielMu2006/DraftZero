import ApplicationServices
import AppKit
import Foundation

// DraftZero AX 审计：递归走 AX 树，检查可交互元素的可读名称、角色与动作。
func attr(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
    var v: CFTypeRef?
    AXUIElementCopyAttributeValue(e, name as CFString, &v)
    return v
}
func str(_ v: CFTypeRef?) -> String { v as? String ?? "" }

var issues: [String] = []
var counts: [String: Int] = [:]
var path: [String] = []

func role(_ e: AXUIElement) -> String { str(attr(e, kAXRoleAttribute)) }
func label(_ e: AXUIElement) -> String {
    let t = str(attr(e, kAXTitleAttribute))
    let d = str(attr(e, kAXDescriptionAttribute))
    let v = str(attr(e, kAXValueAttribute))
    return t.isEmpty ? (d.isEmpty ? v : d) : t
}

func walk(_ e: AXUIElement) {
    let r = role(e)
    if !r.isEmpty { counts[r, default: 0] += 1 }
    let interactive = ["AXButton", "AXCheckBox", "AXPopUpButton", "AXMenuButton", "AXRadioButton", "AXLink", "AXTabGroup", "AXSlider", "AXTextField", "AXTextArea"]
    if interactive.contains(r) {
        let l = label(e)
        var actionsBox: CFArray?
        AXUIElementCopyActionNames(e, &actionsBox)
        let actions = (actionsBox as? [String]) ?? []
        if l.trimmingCharacters(in: .whitespaces).isEmpty {
            issues.append("EMPTY_LABEL role=\(r) path=\(path.suffix(3).joined(separator: ">")) actions=\(actions)")
        }
        if (r == "AXButton" || r == "AXCheckBox") && actions.isEmpty {
            issues.append("NO_ACTIONS role=\(r) label=\(l)")
        }
    }
    path.append(r)
    if let kids = attr(e, kAXChildrenAttribute) as? [AXUIElement] {
        for k in kids { walk(k) }
    }
    if !path.isEmpty { path.removeLast() }
}

guard CommandLine.arguments.count > 1, let pid = Int32(CommandLine.arguments[1]) else {
    fputs("usage: audit <pid>\n", stderr); exit(2)
}
let app = AXUIElementCreateApplication(pid)
walk(app)
print("== role counts ==")
for (r, c) in counts.sorted(by: { $0.key < $1.key }) { print("\(r): \(c)") }
print("\n== issues (\(issues.count)) ==")
for i in issues { print(i) }
