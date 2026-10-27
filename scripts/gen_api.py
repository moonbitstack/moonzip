#!/usr/bin/env python3
# Copyright 2026 Leo Cheng
# SPDX-License-Identifier: Apache-2.0
#
# Generate docs/api.html from each package's `pkg.generated.mbti` and the `///`
# doc comments in its source. The output is committed; CI reruns this script and
# fails if `git diff --exit-code docs/api.html` is not empty, so the page and the
# interface can never drift apart.
#
# Run from anywhere inside the repository:
#     python3 scripts/gen_api.py
#
# No third-party packages, no network, no MoonBit toolchain required.

import os
import re
import sys

# --------------------------------------------------------------------- discovery

def repo_root():
    here = os.path.dirname(os.path.abspath(__file__))
    cur = here
    for _ in range(8):
        if os.path.exists(os.path.join(cur, "moon.mod")):
            return cur
        parent = os.path.dirname(cur)
        if parent == cur:
            break
        cur = parent
    sys.exit("gen_api.py: could not locate moon.mod (repo root)")

# Short name -> the specification the package implements. Shown as a subtitle.
SPECS = {
    "moonzip": "the root — checksums and the refuse signal",
    "deflate": "RFC 1951",
    "gzip": "RFC 1952",
    "zlib": "RFC 1950",
    "zip": "APPNOTE 6.3",
    "tar": "POSIX pax",
    "lz4": "block + frame",
    "snappy": "block + framing v2",
    "lzma": "LZMA SDK",
    "xz": "xz file format",
    "bzip2": "bzip2",
    "sevenz": "7z format",
    "zstd": "RFC 8878",
    "brotli": "RFC 7932",
}

# The order the formats are introduced in the guide and the homepage.
ORDER = ["moonzip", "deflate", "gzip", "zlib", "zip", "tar", "lz4", "snappy",
         "lzma", "xz", "bzip2", "sevenz", "zstd", "brotli"]

GITHUB = "https://github.com/moonbitstack/moonzip"

# A method whose name is one of these is mechanical glue from a derived trait.
# It still appears, but with a one-line note instead of a missing doc.
DERIVED = {
    "equal", "not_equal", "compare", "hash", "clone", "default",
    "to_string", "to_repr", "output", "from_json", "to_json",
    "op_add", "op_sub", "op_mul", "op_div", "next", "iterator_next",
    "debug_write", "from_bytes", "to_bytes",
}

# --------------------------------------------------------------------- doc parse

def strip_doc(line):
    """Turn a `///` or `///|` line into its text, dropping the marker."""
    s = line.strip()
    if s.startswith("///|"):
        s = s[4:]
    elif s.startswith("///"):
        s = s[3:]
    return s.strip()

def parse_source_docs(pkg_dir):
    """Return (item_doc, member_doc) keyed by name."""
    item_doc = {}
    member_doc = {}
    if not os.path.isdir(pkg_dir):
        return item_doc, member_doc

    for name in sorted(os.listdir(pkg_dir)):
        if not name.endswith(".mbt"):
            continue
        path = os.path.join(pkg_dir, name)
        with open(path, "r", encoding="utf-8") as fh:
            lines = fh.readlines()

        pending = None          # top-level doc lines (after a ///|)
        in_type = None         # current type whose body we are inside
        depth = 0
        member_pending = None   # doc lines for the next member in a type

        for raw in lines:
            s = raw.strip()
            if s.startswith("///|"):
                pending = [strip_doc(raw)]
                continue
            if s.startswith("///"):
                d = strip_doc(raw)
                if in_type is not None:
                    member_pending = (member_pending or []) + [d]
                elif pending is not None:
                    pending.append(d)
                continue

            # An ordinary declaration or body line.
            tm = re.match(r"^(?:pub|priv)?(?:\(all\)|\(open\))?\s*"
                          r"(?:enum|struct|suberror)\s+(\w+)", s)
            if tm and in_type is None:
                in_type = tm.group(1)
                if pending is not None:
                    item_doc[in_type] = pending
                    pending = None
                depth = s.count("{") - s.count("}")
                if depth <= 0:
                    in_type = None
                continue

            if in_type is not None:
                # A member (variant or field) line, with an optional doc.
                if (s and s != "}" and "derive" not in s
                        and not s.startswith("///")):
                    member = re.split(r"[\s(:]", s, maxsplit=1)[0]
                    member = member.replace("mut", "").strip()
                    if member and member_pending is not None:
                        member_doc["%s::%s" % (in_type, member)] = member_pending
                        member_pending = None
                depth += s.count("{") - s.count("}")
                if depth <= 0:
                    in_type = None
                continue

            # Top-level declaration outside any type body.
            key = top_key(s)
            if key is not None and pending is not None:
                item_doc[key] = pending
                pending = None

    return item_doc, member_doc

def top_key(s):
    """The doc-map key for a top-level source declaration line."""
    m = re.match(r"^(?:pub|priv)?(?:\(all\)|\(open\))?\s*fn\s+([\w:]+)", s)
    if m:
        return m.group(1)
    m = re.match(r"^(?:pub|priv)?(?:\(all\)|\(open\))?\s*(?:enum|struct|suberror)\s+(\w+)", s)
    if m:
        return m.group(1)
    m = re.match(r"^type\s+(\w+)", s)
    if m:
        return m.group(1)
    m = re.match(r"^pub\s+impl\s+(\w+)\s+for\s+(\w+)", s)
    if m:
        return "impl@%s" % m.group(2)
    m = re.match(r"^pub\s+extend\s+(\w+)\s+with\s+(\w+)::", s)
    if m:
        return "extend@%s" % m.group(1)
    return None

# ------------------------------------------------------------------- mbti parse

def classify(text):
    s = text.strip()
    m = re.match(r"^(?:pub|priv)(?:\(all\)|\(open\))?\s+fn\s+([\w]+)::([\w]+)", s)
    if m:
        return ("method", m.group(1), m.group(2), text)
    m = re.match(r"^(?:pub|priv)(?:\(all\)|\(open\))?\s+fn\s+([\w]+)", s)
    if m:
        return ("fn", None, m.group(1), text)
    m = re.match(r"^(?:pub|priv)(?:\(all\)|\(open\))?\s+let\s+([\w]+)\s*:\s*(.*)$", s)
    if m:
        return ("let", None, m.group(1), text)
    m = re.match(r"^(?:pub|priv)(?:\(all\))?\s+struct\s+([\w]+)", s)
    if m:
        return ("struct", None, m.group(1), text)
    m = re.match(r"^(?:pub|priv)(?:\(all\))?\s+enum\s+([\w]+)", s)
    if m:
        return ("enum", None, m.group(1), text)
    m = re.match(r"^(?:pub|priv)(?:\(all\))?\s+suberror\s+([\w]+)", s)
    if m:
        return ("suberror", None, m.group(1), text)
    m = re.match(r"^type\s+([\w]+)", s)
    if m:
        return ("type", None, m.group(1), text)
    m = re.match(r"^pub\s+impl\s+(\w+)\s+for\s+(\w+)", s)
    if m:
        return ("impl", m.group(2), m.group(1), text)
    m = re.match(r"^pub\(open\)\s+trait\s+([\w]+)", s)
    if m:
        return ("trait", None, m.group(1), text)
    m = re.match(r"^pub\s+extend\s+([\w]+)\s+with\s+(\w+)::", s)
    if m:
        return ("extend", m.group(1), m.group(2), text)
    return None

def body_of(text):
    """Return the text between the first `{` and its matching `}`."""
    i = text.find("{")
    if i < 0:
        return ""
    depth = 0
    for j in range(i, len(text)):
        if text[j] == "{":
            depth += 1
        elif text[j] == "}":
            depth -= 1
            if depth == 0:
                return text[i + 1:j]
    return text[i + 1:]

def parse_mbti(path):
    with open(path, "r", encoding="utf-8") as fh:
        lines = fh.readlines()

    types = {}   # name -> dict
    fns = []     # free functions / values
    impls = {}   # type -> set of trait names

    i = 0
    n = len(lines)
    while i < n:
        line = lines[i]
        s = line.strip()
        if not s or (s.startswith("//") and not s.startswith("///")):
            i += 1
            continue
        if "{" in s and (s.count("{") > s.count("}") or "}" not in s):
            depth = s.count("{") - s.count("}")
            buf = [line]
            j = i + 1
            while j < n and depth > 0:
                buf.append(lines[j])
                depth += lines[j].count("{") - lines[j].count("}")
                j += 1
            text = "".join(buf)
            i = j
        else:
            text = line
            i += 1

        c = classify(text)
        if c is None:
            continue
        kind, owner, name, full = c

        if kind == "fn":
            fns.append({"kind": "fn", "name": name, "sig": full})
        elif kind == "let":
            fns.append({"kind": "let", "name": name, "sig": full})
        elif kind in ("struct", "enum", "suberror", "type", "trait"):
            body = body_of(text) if kind != "type" else ""
            t = types.setdefault(name, {"kind": kind, "name": name,
                                        "methods": [], "impls": set(),
                                        "sig": full, "body": body,
                                        "trait_methods": []})
            t["kind"] = kind
            t["sig"] = full
            t["body"] = body
            dm = re.search(r"derive\(([^)]*)\)", text)
            if dm:
                for tr in dm.group(1).split(","):
                    tr = tr.strip().split(".")[-1].strip()
                    if tr:
                        t["impls"].add(tr)
            if kind == "trait":
                for bl in body.splitlines():
                    bm = re.match(r"\s*fn\s+([\w]+)\s*\((.*)\)\s*(->\s*\S+)?", bl)
                    if bm:
                        t["trait_methods"].append(
                            (bm.group(1), bm.group(2), bm.group(3) or ""))
        elif kind == "method":
            t = types.setdefault(owner, {"kind": "type", "name": owner,
                                         "methods": [], "impls": set(),
                                         "sig": "type %s" % owner, "body": "",
                                         "trait_methods": []})
            t["methods"].append({"name": name, "sig": full})
        elif kind == "impl":
            impls.setdefault(owner, set()).add(name)
        elif kind == "extend":
            impls.setdefault(owner, set()).add(name)

    for t, traits in impls.items():
        if t in types:
            types[t]["impls"] = traits
    return {"types": types, "fns": fns}

# ----------------------------------------------------------------- rendering

def esc(s):
    return (s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))

def hl(sig):
    """Light syntax highlight for a MoonBit signature."""
    s = esc(sig)
    s = re.sub(r"//[^\n]*", lambda m: '<span class="tok-c">%s</span>' % m.group(0), s)
    s = re.sub(r"&quot;[^&]*?&quot;",
               lambda m: '<span class="tok-s">%s</span>' % m.group(0), s)
    kw = (r"\b(pub|pub\(all\)|pub\(open\)|fn|type|struct|enum|suberror|"
          r"raise|Self|derive|mut|impl|for|extend|with|trait|let|UInt32|"
          r"Bytes|Int32|Int64|String|Bool|Unit)\b")
    s = re.sub(kw, lambda m: '<span class="tok-k">%s</span>' % m.group(0), s)
    s = re.sub(r"(?<![>\w&quot;;&])[A-Z]\w*",
               lambda m: '<span class="tok-t">%s</span>' % m.group(0), s)
    return s

def parse_params(sig):
    """Return a list of param dicts from a function signature."""
    m = re.search(r"\(([^)]*)\)", sig)
    if not m:
        return []
    inner = m.group(1).strip()
    if not inner:
        return []
    out = []
    for part in inner.split(","):
        part = part.strip()
        if not part:
            continue
        if part.startswith("Self") or part == "self":
            continue
        default = None
        if "=" in part:
            part, default = part.split("=", 1)
            part = part.strip()
            default = default.strip()
        pkind = "pos"
        pname = part
        if "~" in pname:
            pkind = "lab"
            pname = pname.replace("~", "")
        elif "?" in pname:
            pkind = "opt"
            pname = pname.replace("?", "")
        ptype = ""
        if ":" in pname:
            pname, ptype = pname.split(":", 1)
            pname = pname.strip()
            ptype = ptype.strip()
        out.append({"name": pname, "kind": pkind, "type": ptype,
                    "default": default})
    return out

def parse_returns(sig):
    ret = None
    raises = None
    m = re.search(r"\)\s*(->\s*(.+?))(\s+raise\s+\S+)?$", sig, re.S)
    if m:
        ret = m.group(2).strip()
        if m.group(3):
            raises = m.group(3).split("raise", 1)[1].strip()
    else:
        m2 = re.search(r"\)\s+raise\s+(\S+)$", sig)
        if m2:
            raises = m2.group(1)
    return ret, raises

def render_doc(text):
    """Render a doc-comment block: fenced code becomes <pre>, prose becomes <p>."""
    if not text:
        return ""
    if isinstance(text, (list, tuple)):
        text = "\n".join(text)
    lines = text.split("\n")
    out = []
    i = 0
    n = len(lines)
    para = []
    while i < n:
        line = lines[i]
        if line.strip().startswith("```"):
            if para:
                out.append("<p>%s</p>" % inline("\n".join(para)))
                para = []
            lang = line.strip().strip("`").strip()
            code = []
            i += 1
            while i < n and not lines[i].strip().startswith("```"):
                code.append(lines[i])
                i += 1
            i += 1  # skip closing fence
            joined = "\n".join(code).rstrip("\n")
            label = ' <span class="ex-lang">%s</span>' % esc(lang) if lang and lang != "mbt" else ""
            out.append('<pre class="ex">%s<code>%s</code></pre>' %
                       (label, hl(joined)))
            continue
        if line.strip() == "":
            if para:
                out.append("<p>%s</p>" % inline("\n".join(para)))
                para = []
        else:
            para.append(line)
        i += 1
    if para:
        out.append("<p>%s</p>" % inline("\n".join(para)))
    return "\n".join(out)

def inline(text):
    s = esc(text)
    # [code](#anchor) and [code]
    s = re.sub(r"\[`([^`]+)`\]\(#([^)]+)\)",
               lambda m: '<a class="xref" href="#%s"><code>%s</code></a>'
               % (m.group(2), esc(m.group(1))), s)
    s = re.sub(r"\[`([^`]+)`\]",
               lambda m: "<code>%s</code>" % esc(m.group(1)), s)
    # bare `code`
    s = re.sub(r"`([^`]+)`", lambda m: "<code>%s</code>" % esc(m.group(1)), s)
    return s

def render_params(params):
    if not params:
        return ""
    rows = []
    for p in params:
        if p["kind"] == "lab":
            note = "labelled, default <code>%s</code>" % esc(p["default"])
        elif p["kind"] == "opt":
            note = "labelled, optional"
        else:
            note = "positional"
        rows.append(
            '<tr><td class="mono">%s</td><td class="mono">%s</td>'
            '<td>%s</td></tr>'
            % (esc(p["name"]), esc(p["type"]) or "—", note))
    return ('<div class="code-head">parameters</div>'
            '<table class="params"><tbody>%s</tbody></table>' % "".join(rows))

def render_fn(item, doc):
    sig = item["sig"]
    params = parse_params(sig)
    ret, raises = parse_returns(sig)
    name = item.get("name")
    html = ['<div class="api-item">']
    tag = "value" if item["kind"] == "let" else "fn"
    html.append('<h3 id="%s"><span class="ktag ktag--%s">%s</span>%s</h3>'
                % ("sym-" + re.sub(r"[^\w]", "-", name), tag, tag, esc(name)))
    html.append('<pre class="sig">%s</pre>' % hl(sig))
    if doc:
        html.append(render_doc(doc))
    else:
        if item["kind"] == "fn" and name in DERIVED:
            html.append('<p class="muted">Provided by a derived trait '
                        'implementation; the signature above is the whole of it.</p>')
    if params:
        html.append(render_params(params))
    notes = []
    if ret:
        notes.append("returns <code>%s</code>" % esc(ret))
    if raises:
        notes.append("raises <code>%s</code>" % esc(raises))
    if notes:
        html.append('<p class="returns">%s</p>' % " · ".join(notes))
    html.append("</div>")
    return "".join(html)

def render_type(t, item_doc, member_doc):
    name = t["name"]
    kind = t["kind"]
    tag = {"struct": "struct", "enum": "enum", "suberror": "error",
           "type": "type", "trait": "trait"}.get(kind, "type")
    html = ['<div class="api-item api-type">']
    html.append('<h3 id="sym-%s"><span class="ktag ktag--%s">%s</span>%s</h3>'
                % (esc(name), tag, tag, esc(name)))
    doc = item_doc.get(name)
    if doc:
        html.append(render_doc(doc))

    if kind == "struct":
        rows = []
        for line in t["body"].splitlines():
            line = line.strip()
            if not line or line.startswith("derive"):
                continue
            m = re.match(r"(?:mut\s+)?(\w+)\s*:\s*(.+)$", line)
            if m:
                fname = m.group(1)
                ftype = m.group(2).strip()
                fdoc = member_doc.get("%s::%s" % (name, fname))
                cell = '<td class="mono">%s</td><td class="mono">%s</td>' % (
                    esc(fname), esc(ftype))
                extra = ("<td>%s</td>" % render_doc(fdoc)) if fdoc else "<td></td>"
                rows.append("<tr>%s%s</tr>" % (cell, extra))
        if rows:
            html.append('<div class="code-head">fields</div>')
            html.append('<table class="fields"><tbody>%s</tbody></table>'
                        % "".join(rows))

    if kind == "suberror":
        rows = []
        for line in t["body"].splitlines():
            line = line.strip()
            if not line or line.startswith("derive"):
                continue
            vm = re.match(r"(\w+)(?:\(([^)]*)\))?", line)
            if vm:
                vname = vm.group(1)
                vargs = vm.group(2) or ""
                vdoc = member_doc.get("%s::%s" % (name, vname))
                cell = '<td class="mono">%s</td><td class="mono">%s</td>' % (
                    esc(vname), esc(vargs))
                extra = ("<td>%s</td>" % render_doc(vdoc)) if vdoc else "<td></td>"
                rows.append("<tr>%s%s</tr>" % (cell, extra))
        if rows:
            html.append('<div class="code-head">constructors</div>')
            html.append('<table class="fields"><tbody>%s</tbody></table>'
                        % "".join(rows))

    if kind == "enum":
        rows = []
        for line in t["body"].splitlines():
            line = line.strip()
            if not line or line.startswith("derive"):
                continue
            vm = re.match(r"(\w+)(?:\(([^)]*)\))?", line)
            if vm:
                vname = vm.group(1)
                vargs = vm.group(2) or ""
                vdoc = member_doc.get("%s::%s" % (name, vname))
                cell = '<td class="mono">%s</td><td class="mono">%s</td>' % (
                    esc(vname), esc(vargs))
                extra = ("<td>%s</td>" % render_doc(vdoc)) if vdoc else "<td></td>"
                rows.append("<tr>%s%s</tr>" % (cell, extra))
        if rows:
            html.append('<div class="code-head">variants</div>')
            html.append('<table class="fields"><tbody>%s</tbody></table>'
                        % "".join(rows))

    if kind == "trait" and t.get("trait_methods"):
        html.append('<div class="code-head">required methods</div>')
        for mname, margs, mret in t["trait_methods"]:
            sig = "fn %s(%s)%s" % (mname, margs.strip(),
                                   (" " + mret.strip()) if mret.strip() else "")
            html.append('<pre class="sig sig--trait">%s</pre>' % hl(sig))

    if t.get("methods"):
        html.append('<div class="code-head">methods</div>')
        for m in sorted(t["methods"], key=lambda x: x["name"]):
            params = parse_params(m["sig"])
            mdoc = item_doc.get("%s::%s" % (name, m["name"]))
            html.append('<div class="method">')
            html.append('<h4 id="sym-%s-%s">%s</h4>'
                        % (esc(name), esc(m["name"]), esc(m["name"])))
            html.append('<pre class="sig sig--method">%s</pre>' % hl(m["sig"]))
            if mdoc:
                html.append(render_doc(mdoc))
            elif m["name"] in DERIVED:
                html.append('<p class="muted">Derived trait glue.</p>')
            if params:
                html.append(render_params(params))
            ret, raises = parse_returns(m["sig"])
            notes = []
            if ret:
                notes.append("returns <code>%s</code>" % esc(ret))
            if raises:
                notes.append("raises <code>%s</code>" % esc(raises))
            if notes:
                html.append('<p class="returns">%s</p>' % " · ".join(notes))
            html.append('</div>')

    if t.get("impls"):
        traits = ", ".join(sorted(t["impls"]))
        html.append('<p class="implements">implements %s</p>' % esc(traits))
    html.append("</div>")
    return "".join(html)

def render_package(short, pkg):
    types = pkg["types"]
    fns = pkg["fns"]
    item_doc = pkg["item_doc"]
    member_doc = pkg["member_doc"]
    spec = SPECS.get(short, "")
    parts = ['<section id="pkg-%s" class="pkg">' % esc(short)]
    parts.append('<h2><span class="num">%s</span>%s'
                 % (esc(short),
                    ' <em class="spec">— %s</em>' % esc(spec) if spec else ""))
    parts.append('<div class="pkg-grid">')

    type_names = sorted(types.keys())
    # Errors and types first, then free functions.
    for tn in type_names:
        parts.append(render_type(types[tn], item_doc, member_doc))
    for f in sorted(fns, key=lambda x: x["name"]):
        parts.append(render_fn(f, item_doc.get(f["name"])))
    parts.append("</div></section>")
    return "".join(parts)

# ----------------------------------------------------------------------- shell

PAGE_CSS = """
:root {
  --paper: #F2EFE7; --paper-deep: #E7E2D5; --ink: #191C1B; --ink-soft: #4A4F4B;
  --ink-faint: #7C817B; --rust: #A8481F; --moss: #345745; --gold: #8A6614;
  --line: #CDC6B4; --code-bg: #E9E4D6; --mark: #F0DFAE;
  --shadow: 0 1px 0 rgba(25,28,27,.06), 0 12px 32px -24px rgba(25,28,27,.5);
}
html[data-theme="dark"] {
  --paper: #0E1110; --paper-deep: #151A18; --ink: #E8E4D9; --ink-soft: #B3B0A5;
  --ink-faint: #7E8279; --rust: #E08050; --moss: #7FB79A; --gold: #D9B356;
  --line: #2C3230; --code-bg: #151A18; --mark: #3A3220;
  --shadow: 0 1px 0 rgba(0,0,0,.5), 0 18px 40px -28px rgba(0,0,0,.9);
}
* { box-sizing: border-box; }
html { scroll-behavior: smooth; }
body {
  margin: 0; background: var(--paper); color: var(--ink);
  font: 400 16px/1.65 ui-sans-serif, -apple-system, "Segoe UI", "Noto Sans", sans-serif;
  -webkit-font-smoothing: antialiased;
}
::selection { background: var(--mark); color: var(--ink); }
.serif { font-family: ui-serif, "Iowan Old Style", "Palatino Linotype", Palatino, Georgia, serif; }
.mono { font-family: ui-monospace, "SF Mono", "JetBrains Mono", "Cascadia Mono", Menlo, Consolas, monospace; }

/* custom scrollbar — the standard property lives inside @supports so Chrome,
   which ignores ::-webkit-scrollbar once scrollbar-color is set, still gets it */
@supports not selector(::-webkit-scrollbar) {
  * { scrollbar-color: var(--ink-faint) var(--paper-deep); scrollbar-width: thin; }
}
::-webkit-scrollbar { width: 11px; height: 11px; }
::-webkit-scrollbar-track { background: var(--paper-deep); }
::-webkit-scrollbar-thumb { background: var(--line); border-radius: 7px; border: 3px solid var(--paper-deep); }
::-webkit-scrollbar-thumb:hover { background: var(--ink-faint); }

/* the spine */
.spine {
  position: fixed; inset: 0 auto 0 0; width: 76px;
  border-right: 1px solid var(--line); display: flex; flex-direction: column;
  align-items: center; padding: 22px 0; gap: 16px; z-index: 40; background: var(--paper);
}
.spine__mark { width: 30px; height: 30px; flex: none; }
.spine__mark rect { fill: var(--ink); }
.spine__mark path { stroke: var(--gold); }
.spine__word { writing-mode: vertical-rl; text-orientation: mixed; letter-spacing: .34em;
  text-transform: uppercase; font: 500 10px/1 ui-monospace, monospace; color: var(--ink-faint); }
.spine__rule { flex: 1; width: 1px; background: var(--line); }
.spine a.spine__gh { width: 34px; height: 34px; border: 1px solid var(--line); border-radius: 50%;
  display: grid; place-items: center; color: var(--ink-soft); }
.spine a.spine__gh:hover { border-color: var(--ink-faint); color: var(--ink); }
.spine__theme { width: 34px; height: 34px; border: 1px solid var(--line); border-radius: 50%;
  background: transparent; color: var(--ink-soft); cursor: pointer; display: grid; place-items: center; font-size: 13px; }
.spine__theme:hover { border-color: var(--ink-faint); color: var(--ink); }
.shell { margin-left: 76px; }
@media (max-width: 760px) {
  .spine { position: static; width: auto; flex-direction: row; height: 56px; padding: 0 16px; }
  .spine__word { writing-mode: horizontal-tb; letter-spacing: .2em; }
  .spine__rule { flex: 1; height: 1px; width: auto; }
  .shell { margin-left: 0; }
}

/* header */
.head { padding: 72px 7vw 0; }
.head__inner { max-width: 1120px; }
.eyebrow { font: 500 11px/1 ui-monospace, monospace; letter-spacing: .28em; text-transform: uppercase; color: var(--rust); margin: 0 0 22px; }
.head h1 { margin: 0; font-family: ui-serif, "Iowan Old Style", Palatino, Georgia, serif;
  font-size: clamp(44px, 8vw, 92px); line-height: .92; letter-spacing: -.03em; font-weight: 400; }
.head h1 em { font-style: italic; color: var(--moss); }
.head__lede { max-width: 52ch; margin: 26px 0 0; font-size: clamp(16px,2vw,19px); color: var(--ink-soft); }
.head__lede b { color: var(--ink); font-weight: 600; }

/* package index */
.toc { position: sticky; top: 0; z-index: 30; background: color-mix(in srgb, var(--paper) 92%, transparent);
  backdrop-filter: blur(6px); border-bottom: 1px solid var(--line); padding: 12px 7vw;
  display: flex; flex-wrap: wrap; gap: 8px 14px; align-items: baseline; }
.toc a { font: 500 12px/1 ui-monospace, monospace; color: var(--ink-soft); text-decoration: none;
  border: 1px solid var(--line); border-radius: 2px; padding: 6px 11px; }
.toc a:hover { color: var(--ink); border-color: var(--ink-faint); }
.toc .toc__lead { font: 500 10px/1 ui-monospace, monospace; letter-spacing: .2em; text-transform: uppercase; color: var(--ink-faint); }

/* packages */
.pkg { padding: 64px 7vw 0; }
.pkg h2 { margin: 0 0 6px; font-family: ui-serif, Georgia, serif; font-weight: 400; font-size: clamp(26px,3.4vw,40px); letter-spacing: -.02em; }
.pkg h2 .num { display: block; font: 400 11px/1 ui-monospace, monospace; letter-spacing: .3em; color: var(--rust); margin-bottom: 14px; }
.pkg h2 .spec { font: 400 13px/1.4 ui-monospace, monospace; color: var(--ink-faint); letter-spacing: 0; font-style: normal; }
.pkg-grid { margin-top: 34px; border-top: 1px solid var(--line); }

/* api items */
.api-item { padding: 26px 0; border-bottom: 1px solid var(--line); }
.api-item h3 { margin: 0 0 12px; font: 500 19px/1.3 ui-monospace, monospace; letter-spacing: -.01em; display: flex; align-items: center; gap: 12px; }
.ktag { font: 500 9px/1 ui-monospace, monospace; letter-spacing: .16em; text-transform: uppercase;
  border: 1px solid currentColor; border-radius: 2px; padding: 3px 6px; flex: none; }
.ktag--fn, .ktag--method { color: var(--moss); }
.ktag--struct, .ktag--type { color: var(--gold); }
.ktag--enum { color: var(--rust); }
.ktag--error { color: var(--rust); }
.ktag--trait { color: var(--ink-soft); }
.ktag--value { color: var(--moss); }
.api-type h3 { font-size: 22px; }

pre.sig { margin: 0; padding: 16px 18px; background: var(--code-bg); border: 1px solid var(--line);
  border-radius: 2px; overflow-x: auto; font: 400 13px/1.7 ui-monospace, "SF Mono", Menlo, Consolas, monospace;
  tab-size: 2; white-space: pre; }
pre.ex { margin: 14px 0 0; padding: 16px 18px; background: var(--code-bg); border: 1px solid var(--line);
  border-radius: 2px; overflow-x: auto; font: 400 13px/1.7 ui-monospace, "SF Mono", Menlo, Consolas, monospace;
  position: relative; }
pre.ex .ex-lang { position: absolute; top: 8px; right: 12px; font: 500 9px/1 ui-monospace, monospace;
  letter-spacing: .16em; text-transform: uppercase; color: var(--ink-faint); }
pre.ex code { font: inherit; }

.tok-k { color: var(--rust); }
.tok-s { color: var(--moss); }
.tok-c { color: var(--ink-faint); font-style: italic; }
.tok-t { color: var(--gold); }

.api-item p { margin: 12px 0 0; max-width: 72ch; color: var(--ink-soft); font-size: 14.5px; }
.api-item p code, .fields td code, .params td code, .returns code, .implements code {
  font-family: ui-monospace, "SF Mono", Menlo, Consolas, monospace; font-size: .9em;
  background: var(--code-bg); padding: 1px 5px; border-radius: 2px; border: 1px solid var(--line); }
.xref { color: var(--moss); text-decoration: none; border-bottom: 1px solid var(--line); }
.xref:hover { border-color: var(--moss); }
.muted { color: var(--ink-faint); font-style: italic; }
.returns { color: var(--ink-faint); font-size: 13px; }
.implements { margin-top: 14px; font: 500 11px/1 ui-monospace, monospace; letter-spacing: .1em;
  text-transform: uppercase; color: var(--ink-faint); }

.code-head { font: 500 10px/1 ui-monospace, monospace; letter-spacing: .2em; text-transform: uppercase;
  color: var(--ink-faint); margin: 18px 0 8px; }
table.fields, table.params { width: 100%; border-collapse: collapse; font-size: 13.5px; }
table.fields td, table.params td { text-align: left; padding: 9px 12px 9px 0; vertical-align: top; border-top: 1px solid var(--line); }
table.fields td:first-child, table.params td:first-child { width: 22%; }
table.fields td:nth-child(2), table.params td:nth-child(2) { width: 30%; color: var(--ink-soft); }
.method { margin: 18px 0 0; padding-left: 18px; border-left: 2px solid var(--line); }
.method h4 { margin: 0 0 8px; font: 500 15px/1 ui-monospace, monospace; color: var(--ink); }
pre.sig--method, pre.sig--trait { font-size: 12.5px; padding: 12px 14px; }

footer { padding: 54px 7vw 70px; border-top: 1px solid var(--line); display: flex; flex-wrap: wrap; gap: 18px 40px; align-items: baseline;
  font: 400 12px/1.8 ui-monospace, monospace; color: var(--ink-faint); }
footer b { color: var(--ink); font-weight: 600; }
footer a { color: var(--ink-soft); text-decoration: none; border-bottom: 1px solid var(--line); }
footer a:hover { color: var(--ink); border-color: var(--ink); }
"""

def build_html(packages):
    toc = ['<nav class="toc" aria-label="Packages">',
           '<span class="toc__lead">packages</span>']
    for short in packages:
        toc.append('<a href="#pkg-%s">%s</a>' % (esc(short), esc(short)))
    toc.append('</nav>')

    sections = []
    for short in packages:
        sections.append(render_package(short, packages[short]))

    body = "\n".join(toc) + "\n" + "\n".join(sections)
    return (
        '<!doctype html>\n<html lang="en">\n<head>\n'
        '<meta charset="utf-8">\n'
        '<meta name="viewport" content="width=device-width, initial-scale=1">\n'
        '<title>moonzip — API reference</title>\n'
        '<meta name="description" content="The full public interface of moonzip, '
        'generated from each package. One format per package.">\n'
        '<link rel="icon" href="data:image/svg+xml,<svg xmlns=\'http://www.w3.org/2000/svg\' '
        'viewBox=\'0 0 32 32\'><rect width=\'32\' height=\'32\' fill=\'%23191C1B\'/>'
        '<path d=\'M6 10h20M6 16h14M6 22h20\' stroke=\'%23C99A2E\' stroke-width=\'3\'/></svg>">\n'
        '<style>' + PAGE_CSS + '</style>\n</head>\n<body>\n'
        '<nav class="spine" aria-label="Site">\n'
        '<svg class="spine__mark" viewBox="0 0 32 32" aria-hidden="true">'
        '<rect width="32" height="32"></rect>'
        '<path d="M6 10h20M6 16h14M6 22h20" fill="none" stroke-width="3"></path></svg>\n'
        '<span class="spine__word">moonzip</span>\n'
        '<span class="spine__rule"></span>\n'
        '<a class="spine__gh" href="__GH__" title="GitHub" aria-label="GitHub">'
        '<svg width="17" height="17" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true">'
        '<path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 '
        '0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 '
        '1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 '
        '0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 '
        '2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 '
        '3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.01 8.01 0 0 0 16 8c0-4.42-3.58-8-8-8z"/>'
        '</svg></a>\n'
        '<button class="spine__theme" id="theme" title="Switch theme" aria-label="Switch theme">\u25d0</button>\n'
        '</nav>\n'
        '<div class="shell">\n'
        '<header class="head"><div class="head__inner">\n'
        '<p class="eyebrow">MoonBit · the interface</p>\n'
        '<h1>Every entry<br><em>point.</em></h1>\n'
        '<p class="head__lede">The whole public surface, one block per format. '
        'Generated from each package by <code>moon info</code> and the <code>///</code> '
        'comments in its source, so what you read is what the compiler checks. '
        'New here? Read <a class="xref" href="guide.html">the guide</a> first.</p>\n'
        '</div></header>\n'
        + body +
        '<footer>\n'
        '<span><b>moonzip</b> — Apache-2.0</span>\n'
        '<span>Leo Cheng</span>\n'
        '<span><a href="__GH__">github.com/moonbitstack/moonzip</a></span>\n'
        '<span style="margin-left:auto"><a href="index.html">home</a> · '
        '<a href="guide.html">guide</a> · generated by scripts/gen_api.py</span>\n'
        '</footer>\n'
        '</div>\n'
        '<script>\n'
        '(function () {\n'
        '  const html = document.documentElement;\n'
        '  const saved = localStorage.getItem("moonzip-theme");\n'
        '  if (saved) html.dataset.theme = saved;\n'
        '  document.getElementById("theme").addEventListener("click", () => {\n'
        '    const now = html.dataset.theme === "dark" ? "light"\n'
        '      : html.dataset.theme === "light" ? "dark"\n'
        '      : (matchMedia("(prefers-color-scheme: dark)").matches ? "light" : "dark");\n'
        '    html.dataset.theme = now;\n'
        '    localStorage.setItem("moonzip-theme", now);\n'
        '  });\n'
        '})();\n'
        '</script>\n'
        '</body>\n</html>\n'
    ).replace("__GH__", GITHUB)

def main():
    root = repo_root()
    src = os.path.join(root, "src")
    pkgs = []
    for base, dirs, files in os.walk(src):
        rel = os.path.relpath(base, src)
        parts = [] if rel == "." else rel.split(os.sep)
        if any(p.startswith((".", "_")) for p in parts) or "examples" in parts:
            continue
        if "pkg.generated.mbti" in files and "moon.pkg" in files:
            short = "moonzip" if rel == "." else os.path.basename(base)
            pkgs.append((short, base))

    # Stable order: curated first, rest alphabetical.
    def order_key(p):
        short = p[0]
        if short in ORDER:
            return (0, ORDER.index(short))
        return (1, short)
    pkgs.sort(key=order_key)

    packages = {}
    for short, base in pkgs:
        mbti = os.path.join(base, "pkg.generated.mbti")
        parsed = parse_mbti(mbti)
        item_doc, member_doc = parse_source_docs(base)
        parsed["item_doc"] = item_doc
        parsed["member_doc"] = member_doc
        packages[short] = parsed

    html = build_html(packages)
    out = os.path.join(root, "docs", "api.html")
    with open(out, "w", encoding="utf-8") as fh:
        fh.write(html)
    print("wrote %s (%d packages)" % (out, len(packages)))

if __name__ == "__main__":
    main()
