#!/bin/bash
# ============================================================
# test.sh — bashttpd 文件管理 API 测试/操作工具 (双模式)
#
# 用法: ./test.sh [-m python|curl] [-U URL] <action> [参数...]
#       (option 必须放在 action 之前)
#
# options:
#   -m python|curl   与 bashttpd 的交互实现 (默认 python: 纯标准库内嵌实现, 不依赖 curl)
#   -U URL           服务地址 (默认 http://127.0.0.1:38080)
#
# 服务器无登录/会话 (bashttpd 不支持认证), 故无 login/cookie;
#   ping     探活: GET / 并识别 bashttpd (Server: Slash Bin Slash Bash)
#   download <URL路径> [本地保存路径]
#                    下载文件 (GET <URL路径>; 不给本地路径则按 URL 末段保存到当前目录)
#   upload <本地文件> [URL目录]  上传 (POST + X-Bas-Action: upload, raw body 等价 upload_stream)
#   upload_stream <本地文件> [URL目录]  同 upload (bashttpd 只支持 raw body, 保留与
#                    参考工具一致的入口; 大文件两种写法等价, 无 multipart 之分)
#   view <URL文件路径>  在线查看文本文件内容 (GET, 纯文本打到 stdout)
#   list <URL目录>      列出目录内容 (GET 目录页, tree HTML 解析成纯文本; ls 回退原样输出)
#   mkdir <名字> [URL目录]           在目录下建子目录 (X-Bas-Action: mkdir)
#   delete <名字>... [URL目录]       删除目录下若干条目 (X-Bas-Action: delete, body 每行一个名字)
#   rename <旧名> <新名> [URL目录]    重命名 (X-Bas-Action: rename)
#   copy <名字>... <源URL目录> <目标URL目录>   复制粘贴 (X-Bas-Action: paste + X-Bas-Op: copy)
#   cut <名字>... <源URL目录> <目标URL目录>   剪切粘贴 (X-Bas-Action: paste + X-Bas-Op: cut)
#   favorite [list|add] [URL目录]    收藏夹 (favlist 返回 JSON 数组 / favadd 收当前 URL;
#                    服务器只实现了 list/add, 没有 remove)
#   smoke                            冒烟测试: 全部 action 跑一遍, 输出 PASS/FAIL/SKIP
#   help                             本帮助
#
# 默认: URL=http://127.0.0.1:38080  URL目录=/ (即 DOCROOT)
# 环境变量: URL=  MODE=python|curl  REMOTE_DIR=smoke 使用的 URL 目录
# 所有网络操作执行前都会打印实际请求
# ============================================================
set -u

URL="${URL:-http://127.0.0.1:38080}"
MODE="${MODE:-python}"
REMOTE_DIR="${REMOTE_DIR:-/}"

usage() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; }

while getopts "m:U:h" opt; do
  case "$opt" in
    m) MODE="$OPTARG" ;;
    U) URL="${OPTARG%/}" ;;
    h) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
done
shift $((OPTIND - 1))

case "$MODE" in
  python|curl) ;;
  *) echo "[x] -m 只支持 python 或 curl (收到: $MODE)"; exit 1 ;;
esac

case "$URL" in
  http://*|https://*) ;;
  *) echo "[x] -U 需以 http(s):// 开头 (收到: $URL)"; exit 1 ;;
esac

# bashttpd 的服务端路径校验要求:
#   - 文件/目录名字不能含 '/' 或为 . / .. (否则 400)
#   - 'resolve_local_dir' 会拒绝含 '..' 的 URI, 且要求该 URI 命中
#     bashttpd.conf 中一条目录型规则 (serve_dir_or_file_from / serve_dir*)
# 千万注意: 传给 X-Bas-Name / X-Bas-New-Name 的名字以及 delete/paste body
# 里的名字都要 percent-encode (服务端 urldecode 后再校验).
enc() { python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"; }

urlencode_file() {
  # 把每行一个的原始名转成每行一个 percent-encoded 名 (delete/paste body 用)
  python3 -c 'import urllib.parse,sys
for l in sys.stdin.read().splitlines():
    if l: print(urllib.parse.quote(l, safe=""))'
}

# 取 URL 目录参数 (各 action 的最后一个可选参数); 未给则为 $REMOTE_DIR
last_dir() {
  if [ -n "${1:-}" ]; then printf '%s' "$1"; else printf '%s' "$REMOTE_DIR"; fi
}

# ============================================================
# python 模式: 内嵌纯标准库实现 (urllib, 无第三方依赖)
# ============================================================
pyexec() {
  BAS_URL="$URL" BAS_MODE_CID="$MODE" BAS_REMOTE_DIR="$REMOTE_DIR" \
  python3 - "$@" <<'PYEOF'
import json
import os
import re
import shutil
import sys
import urllib.error
import urllib.parse
import urllib.request

URL = os.environ["BAS_URL"].rstrip("/")
RDIR = os.environ.get("BAS_REMOTE_DIR", "/")


def die(msg, code=1):
    print("[x] %s" % msg, file=sys.stderr)
    sys.exit(code)


def quote(p):
    return urllib.parse.quote(p, safe="")


def host_is_local(u):
    h = urllib.parse.urlparse(u).hostname or ""
    return h in ("127.0.0.1", "localhost", "::1", "") or h == os.uname().nodename


def log_cmd(method, path, note=""):
    print("+ [python] %s %s%s%s" % (method, URL, path, ("  | " + note) if note else ""))


def http(method, path, data=None, headers=None):
    r = urllib.request.Request(URL + path, data=data, method=method,
                               headers=headers or {})
    try:
        resp = urllib.request.urlopen(r, timeout=300)
        return resp.getcode(), resp
    except urllib.error.HTTPError as e:
        return e.code, e
    except Exception as e:
        print("[x] 连接失败: %s" % e, file=sys.stderr)
        sys.exit(2)


def read_body(resp):
    try:
        return resp.read().decode("utf-8", "replace")
    except Exception:
        return ""


def check_uri_dir(d):
    """URL 目录统一成以 / 结尾; POST 目标 = 目录页的 URI."""
    if not d:
        d = RDIR
    if d and not d.startswith("/"):
        die("URL 目录必须以 / 开头 (收到: %s)" % d)
    if ".." in d:
        die("URL 目录不允许含 .. (服务端拒绝)")
    if not d.endswith("/"):
        d += "/"
    return d


def norm_uri_path(p):
    """文件类 URI (download/view): 不强制结尾斜杠."""
    if not p:
        die("缺少 URL 路径参数")
    if ".." in p:
        die("URL 路径不允许含 .. (服务端拒绝)")
    return p


# ---------- GET 类 ----------

def do_ping():
    log_cmd("GET", "/")
    code, resp = http("GET", "/")
    body = read_body(resp)
    print("HTTP %s" % code)
    if code == 200:
        srv = resp.headers.get("Server", "")
        if "Slash Bin Slash Bash" in srv:
            print("[i] 识别为 bashttpd (Server: %s), 页面 %d 字节" % (srv, len(body)))
        else:
            print("[!] 非 bashttpd 服务 (Server: %r), 仍返回 200" % srv)
    return 0 if code == 200 else 1


def do_download(remote, localf=None):
    remote = norm_uri_path(remote)
    log_cmd("GET", remote)
    code, resp = http("GET", remote)
    if code != 200:
        print("HTTP %s: %s" % (code, read_body(resp)[:200]))
        sys.exit(1)
    if not localf:
        localf = os.path.basename(urllib.parse.unquote(remote.split("?")[0])) or "bas_download"
    n = 0
    with open(localf, "wb") as f:
        shutil.copyfileobj(resp, f, 1 << 16)
        n = f.tell()
    resp.close()
    print("HTTP 200, %d bytes -> %s" % (n, localf))
    # 文本文件走 send_response (按行 \r\n 重发), 二进制走 raw cat; 都已实测字节一致,
    # 但保险起见用 Content-Length 校验
    cl = resp.headers.get("Content-Length")
    if cl and int(cl) != n:
        print("[!] Content-Length=%s 与实际读到的 %d 不一致" % (cl, n), file=sys.stderr)


def do_view(remote):
    remote = norm_uri_path(remote)
    log_cmd("GET", remote)
    code, resp = http("GET", remote)
    if code != 200:
        print("HTTP %s: %s" % (code, read_body(resp)[:200]))
        sys.exit(1)
    ct = resp.headers.get("Content-Type", "")
    if ct.startswith("text/html"):
        # 目录页 or html 文件; bashttpd 无 viewsrc, 提醒一下
        if b"Directory Tree" in resp.read(4096):
            print("[i] 该 URI 是目录页, bashttpd 无 viewsrc, 输出原始 HTML", file=sys.stderr)
    txt = resp.read().decode("utf-8", "replace")
    sys.stdout.write(txt)
    sys.stdout.flush()


def do_list(remote):
    d = check_uri_dir(remote)
    log_cmd("GET", d)
    code, resp = http("GET", d)
    body = resp.read() if code == 200 else b""
    ct = resp.headers.get("Content-Type", "")
    resp.close()
    if code != 200:
        print("HTTP %s: %s" % (code, read_body(resp) if isinstance(resp, str) else body[:200]))
        sys.exit(1)
    if ct.startswith("text/plain"):
        # ls 回退模式 (无 tree 命令): 原样输出
        shutil.copyfileobj(urllib.request.urlopen(URL + d), sys.stdout.buffer, 1 << 16)
        sys.stdout.flush()
        return
    # tree HTML 模式: 解析 <tr data-href=".."> 行成纯文本
    #   每行 7 列: checkbox(略) permissions user group size date name(含树形前缀+链接)
    html = body.decode("utf-8", "replace")
    print("total %d" % ((len(re.findall(r'<tr data-href="[^"]*"', html))) or 0))
    for m in re.finditer(r'<tr data-href="[^"]*">(.*?)</tr>', html):
        tds = re.findall(r'<td[^>]*>(.*?)</td>', m.group(1))
        if len(tds) < 7:
            continue
        perm, user, group, size, date, name_td = tds[1], tds[2], tds[3], tds[4], tds[5], tds[6]
        mm = re.search(r'<a href="([^"]*)">(.*)</a>', name_td)
        if mm:
            name = re.sub(r"<[^>]+>", "", mm.group(2)).strip()
        else:
            name = re.sub(r"<[^>]+>", "", name_td).strip()
        print("%s  %-8s %-8s %10s  %s  %s" % (perm, user, group, size, date, name))
    return


# ---------- POST (X-Bas-Action) 类 ----------

def post_action(d, action, name=None, name2=None, op=None, body=None, headers=None):
    """发一次 X-Bas-Action 请求, 返回 (code, text)."""
    d = check_uri_dir(d)
    h = {"X-Bas-Action": action}
    if name is not None:
        h["X-Bas-Name"] = quote(name)
    if name2 is not None:
        h["X-Bas-New-Name"] = quote(name2)
    if op is not None:
        h["X-Bas-Op"] = op
    if headers:
        h.update(headers)
    data = body.encode() if isinstance(body, str) else body
    log_cmd("POST", d, "action=%s%s%s%s%s" % (
        action,
        (" name=%s" % name) if name is not None else "",
        (" -> %s" % name2) if name2 is not None else "",
        (" op=%s" % op) if op is not None else "",
        (" [%s names]" % len(body.splitlines())) if body else ""))
    code, resp = http("POST", d, data=data, headers=h)
    txt = read_body(resp)
    print("%s" % txt)
    print("HTTP %s" % code)
    return code, txt


def act_expect_200(d, action, **kw):
    code, txt = post_action(d, action, **kw)
    if code != 200:
        sys.exit(1)
    return txt


def check_name(n):
    if not n or "/" in n or n in (".", ".."):
        die("文件/目录名字非法 (空 / 含 / / . / ..): %r" % n)


def do_upload(localf, rdir, _raw_placeholder=None):
    if not os.path.isfile(localf):
        die("本地文件不存在: %s" % localf)
    name = os.path.basename(localf)
    check_name(name)
    d = check_uri_dir(rdir)
    size = os.path.getsize(localf)
    log_cmd("POST", d, "upload %s -> %s (%d B, raw body)" % (localf, name, size))
    with open(localf, "rb") as f:
        code, resp = http("POST", d, data=f, headers={
            "X-Bas-Action": "upload",
            "X-Bas-Name": quote(name),
            "Content-Type": "application/octet-stream",
            "Content-Length": str(size),
        })
    txt = read_body(resp)
    print(txt)
    print("HTTP %s" % code)
    sys.exit(0 if code == 200 else 1)


def do_mkdir(name, rdir):
    check_name(name)
    act_expect_200(rdir, "mkdir", name=name)


def do_delete(names, rdir):
    names = [n for n in names if n]
    if not names:
        die("delete 至少给一个名字")
    for n in names:
        check_name(n)
    body = "\n".join(quote(n) for n in names) + "\n"
    act_expect_200(rdir, "delete", body=body)


def do_rename(old, new, rdir):
    check_name(old)
    check_name(new)
    act_expect_200(rdir, "rename", name=old, name2=new)


def do_paste(op, names, src, dst):
    names = [n for n in names if n]
    if not names:
        die("%s 至少给一个名字" % op)
    for n in names:
        check_name(n)
    if not src or not dst:
        die("用法: %s <名字>... <源URL目录> <目标URL目录>" % op)
    src_d = check_uri_dir(src)
    body = src_d + "\n" + "\n".join(quote(n) for n in names) + "\n"
    act_expect_200(dst, "paste", op=op, body=body)


def do_favorite(act="list", fp=None):
    d = check_uri_dir(fp if act == "add" else None)
    if act == "list":
        log_cmd("POST", d, "action=favlist")
        code, resp = http("POST", d, headers={"X-Bas-Action": "favlist"})
        txt = read_body(resp)
        print(txt)
        sys.exit(0 if code == 200 else 1)
    if act == "add":
        log_cmd("POST", d, "action=favadd")
        code, resp = http("POST", d, headers={"X-Bas-Action": "favadd"})
        txt = read_body(resp)
        print(txt)
        sys.exit(0 if code == 200 else 1)
    die("favorite 子命令: list | add! remove 服务器未实现")


# ---------- smoke ----------

def do_smoke():
    res = {"p": 0, "f": 0, "s": 0}

    def ok(m):
        print("  ✓ %s" % m); res["p"] += 1

    def ng(m, why):
        print("  ✗ %s (%s)" % (m, why)); res["f"] += 1

    def sk(m, why):
        print("  - %s (跳过: %s)" % (m, why)); res["s"] += 1

    d = check_uri_dir(None)
    print("== smoke(python) 目标: %s | 测试目录: %s ==" % (URL, d))

    # 0 ping
    print("-- 0. ping (GET /)")
    log_cmd("GET", "/")
    code, resp = http("GET", "/")
    body = read_body(resp)
    ok("ping 200") if code == 200 else ng("ping", "HTTP %s" % code)

    # 1 del target dir if exists, then mkdir smoke dir
    tag = "smoke-py"
    print("-- 1. mkdir %s" % tag)
    code, resp = http("GET", d)
    lst = read_body(resp) if code == 200 else ""
    if ('data-href="%s"' % quote(tag)) not in lst:
        code, _ = post_action(d, "mkdir", name=tag)
        ok("mkdir") if code == 200 else ng("mkdir", "HTTP %s" % code)
    else:
        sk("mkdir", "%s 已存在" % tag)
    sd = d + tag + "/"

    # 2 upload
    print("-- 2. upload (raw body + %s 名)" % tag)
    content = ("smoke-py-nei-rong" * 40).encode()
    upname = tag + "-f.txt"
    import tempfile
    fd, T = tempfile.mkstemp(prefix="bassmoke.", suffix=".txt")
    with os.fdopen(fd, "wb") as f:
        f.write(content)
    with open(T, "rb") as f:
        code, resp = http("POST", sd, data=f, headers={
            "X-Bas-Action": "upload", "X-Bas-Name": quote(upname),
            "Content-Type": "application/octet-stream",
            "Content-Length": str(os.path.getsize(T))})
    txt = read_body(resp)
    if code == 200 and "uploaded:" in txt:
        ok("upload")
    else:
        ng("upload", "HTTP %s %s" % (code, txt[:80]))
    try:
        os.remove(T)
    except Exception:
        pass

    # 2b upload 中文名
    print("-- 2b. upload 中文文件名")
    cname = quote("%s-中文名.txt" % tag)
    code, resp = http("POST", sd, data=b"zhong-wen", headers={
        "X-Bas-Action": "upload", "X-Bas-Name": cname,
        "Content-Type": "application/octet-stream",
        "Content-Length": "9"})
    txt = read_body(resp)
    ok("upload 中文名") if (code == 200 and "uploaded:" in txt) else ng("upload 中文名", "HTTP %s %s" % (code, txt[:80]))

    # 3 view / download 内容一致
    print("-- 3. GET (view) 内容一致性")
    code, resp = http("GET", sd + quote(upname))
    got = resp.read(); resp.close()
    if code == 200 and got == content:
        ok("view 内容一致")
    else:
        ng("view 内容一致", "HTTP %s got:%r" % (code, got[:30]))

    # 3b download 回环
    print("-- 3b. download 回环比对")
    import tempfile as _t
    fd2, T2 = _t.mkstemp(prefix="bassmoke.dl.")
    os.close(fd2)
    code, resp = http("GET", sd + quote(upname))
    with open(T2, "wb") as f:
        shutil.copyfileobj(resp, f)
    resp.close()
    same = open(T2, "rb").read() == content
    ok("download 回环一致") if (code == 200 and same) else ng("download 回环一致", "HTTP %s same=%s" % (code, same))
    os.remove(T2)

    # 3c 二进制回环
    print("-- 3c. 二进制文件回环")
    bin_content = bytes(range(256)) * 64
    bname = quote("%s-f.bin" % tag)
    code, resp = http("POST", sd, data=bin_content, headers={
        "X-Bas-Action": "upload", "X-Bas-Name": bname,
        "Content-Type": "application/octet-stream",
        "Content-Length": str(len(bin_content))})
    read_body(resp)
    code, resp = http("GET", sd + bname)
    got = resp.read(); resp.close()
    ok("二进制回环") if (code == 200 and got == bin_content) else ng("二进制回环", "HTTP %s len=%d" % (code, len(got)))

    # 4 list 能看到上传的文件
    print("-- 4. list 目录页包含上传文件")
    code, resp = http("GET", sd)
    lst = read_body(resp)
    found = ('href="%s"' % (quote(upname))) in lst or upname in lst
    # 路径中的引号是 percent-encoded 形式, 两种都查
    ok("list 包含文件") if (code == 200 and found) else ng("list 包含文件", "HTTP %s found=%s" % (code, found))

    # 5 rename
    print("-- 5. rename")
    nn = upname + ".renamed"
    code, _ = post_action(sd, "rename", name=upname, name2=nn)
    ok("rename") if code == 200 else ng("rename", "HTTP %s" % code)

    # 6 copy / cut paste
    print("-- 6. copy paste 到父目录")
    code, resp = http("GET", sd)
    # 直接 paste 到 d 目录下的 tag2 子目录
    code, _ = post_action(d, "mkdir", name=tag + "2")
    body = sd + "\n" + quote(nn) + "\n"
    code, _ = post_action(d + tag + "2/", "paste", op="copy", body=body)
    ok("paste copy") if code == 200 else ng("paste copy", "HTTP %s" % code)

    print("-- 6b. cut paste (move back)")
    body = d + tag + "2/" + "\n" + quote(nn) + "\n"
    code, _ = post_action(sd, "paste", op="cut", body=body)
    ok("paste cut") if code == 200 else ng("paste cut", "HTTP %s" % code)

    # 7 delete
    print("-- 7. delete (delete 两个 UTF 名 + renamed)")
    body = "\n".join([quote(nn), cname, bname, "no-such-no-eol"]) + "\n"
    code, txt = post_action(sd, "delete", body=body)
    # upname 已被 rename 掉; 再删 cname/bname 及不存在的名字: 不存在的会 fail
    if code == 200 and "failed 0" in txt.replace(". ", ". "):
        pass
    if code == 200:
        ok("delete %s" % txt)
    else:
        ng("delete", "HTTP %s" % code)

    # 8 favorite list/add
    print("-- 8. favorite (favlist / favadd)")
    log_cmd("POST", d, "action=favlist")
    code, resp = http("POST", d, headers={"X-Bas-Action": "favlist"})
    txt = read_body(resp)
    try:
        favs = json.loads(txt) if code == 200 else None
    except Exception:
        favs = None
    if code == 200 and isinstance(favs, list):
        ok("favlist 返回 JSON 数组 (%d 项)" % len(favs))
    else:
        ng("favlist", "HTTP %s %r" % (code, txt[:60]))
    # favadd 会写服务器工作目录的 favorite.json, 且服务器没有 remove,
    # 不能恢复原状. 因此只在能就地回滚时才真做:
    #   - URL 是本机时, 试探 ./favorite.json (bashttpd 服务器工作目录)
    #   - 否则跳过, 不污染用户收藏
    favfile = None
    if host_is_local(URL):
        cwd = os.path.dirname(os.path.abspath(sys.argv[0])) if sys.argv[0] else "."
        cand = os.path.join(cwd, "favorite.json")
        if os.path.exists(cand):
            favfile = cand
    if favs is None:
        sk("favadd", "favlist 不可用")
    elif favfile is None:
        sk("favadd", "非本机服务器或找不到 favorite.json, 避免污染收藏 (无 remove 无法恢复)")
    else:
        uri = d.rstrip("/") or "/"
        orig = open(favfile, "rb").read()
        try:
            add = (uri not in favs)
            if add:
                code, resp = http("POST", d, headers={"X-Bas-Action": "favadd"})
                txt = read_body(resp)
            else:
                code, txt = 200, "already in favorites (本地判定)"
            if code == 200 and ("added:" in txt or "already in favorites" in txt):
                ok("favadd")
            else:
                ng("favadd", "HTTP %s %r" % (code, txt[:60]))
        finally:
            # 回滚 favorite.json 到测试前状态
            with open(favfile, "wb") as f:
                f.write(orig)
            print("  [i] favorite.json 已回滚到测试前状态")

    # 9 405 / 400 语义
    print("-- 9. 错误码 (405 HEAD / 400 traversal / 400 bad name)")
    code, resp = http("HEAD", "/")
    read_body(resp) if hasattr(resp, "read") else None
    ok("HEAD -> 405") if code == 405 else ng("HEAD", "HTTP %s (期望 405)" % code)
    code, resp = http("GET", "/../etc/passwd")
    read_body(resp)
    ok(".. -> 400") if code == 400 else ng(".. 拒绝", "HTTP %s (期望 400)" % code)
    code, resp = http("POST", d, data=b"x", headers={"X-Bas-Action": "upload", "X-Bas-Name": "a/b"})
    read_body(resp)
    ok("bad name -> 400") if code == 400 else ng("bad name 拒绝", "HTTP %s (期望 400)" % code)

    # 10 清理: 删掉测试目录树
    print("-- 10. 清理")
    body = quote(tag) + "\n" + quote(tag + "2") + "\n"
    code, txt = post_action(d, "delete", body=body)
    ok("清理 delete") if code == 200 else ng("清理", "HTTP %s" % code)

    print("== 结果: PASS=%d FAIL=%d SKIP=%d ==" % (res["p"], res["f"], res["s"]))
    sys.exit(0 if res["f"] == 0 else 1)


cmd = sys.argv[1] if len(sys.argv) > 1 else "help"
a = sys.argv[2:]
if cmd == "ping":
    sys.exit(do_ping())
elif cmd in ("download", "view"):
    if not a:
        print("用法: %s <URL路径> [本地保存路径]" % cmd); sys.exit(1)
    if cmd == "download":
        do_download(a[0], a[1] if len(a) > 1 else None)
    else:
        do_view(a[0])
elif cmd in ("upload", "upload_stream"):
    if not a:
        print("用法: %s <本地文件> [URL目录, 默认 %s]" % (cmd, RDIR)); sys.exit(1)
    do_upload(a[0], a[1] if len(a) > 1 else RDIR)
elif cmd == "list":
    do_list(a[0] if a else RDIR)
elif cmd == "mkdir":
    if not a:
        print("用法: mkdir <名字> [URL目录]"); sys.exit(1)
    do_mkdir(a[0], a[1] if len(a) > 1 else RDIR)
elif cmd == "delete":
    if not a:
        print("用法: delete <名字>... [URL目录]"); sys.exit(1)
    do_delete(a[:-1] if len(a) > 1 else a, a[-1] if len(a) > 1 else RDIR)
elif cmd == "rename":
    if len(a) < 2:
        print("用法: rename <旧名> <新名> [URL目录]"); sys.exit(1)
    do_rename(a[0], a[1], a[2] if len(a) > 2 else RDIR)
elif cmd in ("copy", "cut"):
    if len(a) < 3:
        print("用法: %s <名字>... <源URL目录> <目标URL目录>" % cmd); sys.exit(1)
    # 最后一个参数是目标目录, 倒数第二个是源目录
    do_paste(cmd, a[:-2], a[-2], a[-1])
elif cmd == "favorite":
    do_favorite(a[0] if a else "list", a[1] if len(a) > 1 else None)
elif cmd == "smoke":
    do_smoke()
elif cmd in ("help", "-h", "--help"):
    print(__doc__ or "python模式子命令: ping/download/upload/upload_stream/view/list/mkdir/delete/rename/copy/cut/favorite/smoke")
else:
    print("python模式子命令: ping/download/upload/upload_stream/view/list/mkdir/delete/rename/copy/cut/favorite/smoke")
    sys.exit(1)
PYEOF
}

# ============================================================
# curl 模式辅助
# ============================================================
show_and_run() {
  echo "+ curl $*"
  curl "$@"
}

# 显示 + 执行, 且在 -o 的情形下打印响应码
curl_post_action() {
  # $1=URL目录  其余原样传 curl
  local d="$1"; shift
  show_and_run -sS -X POST "$@" "$URL$d" -w '\nHTTP %{http_code}\n'
}

cmd_ping() {
  if [ "$MODE" = python ]; then pyexec ping "$@"; return; fi
  local code srv
  code=$(curl -s -o /dev/null -w '%{http_code}' "$URL/")
  srv=$(curl -s -D - -o /dev/null "$URL/" | grep -i '^server:' | tr -d '\r')
  echo "HTTP $code | $srv"
  if [ "$code" = 200 ] && printf '%s' "$srv" | grep -q bashttpd; then :; fi
  case "$srv" in *Slash\ Bin\ Slash\ Bash*) echo "[i] 识别为 bashttpd";; *) echo "[!] Server 头非 bashttpd";; esac
  [ "$code" = 200 ]
}

cmd_download() {
  if [ "$MODE" = python ]; then pyexec download "$@"; return; fi
  local remote="${1:?用法: download <URL路径> [本地保存路径]}"
  local localf="${2:-}"
  case "$remote" in
    ..*|*..*) echo "[x] URL 路径不允许含 .."; exit 1 ;;
  esac
  if [ -n "$localf" ]; then
    show_and_run -sS -o "$localf" -w 'HTTP %{http_code}, %{size_download} bytes\n' "$URL$remote"
  else
    show_and_run -sS -O "$URL$remote"
  fi
}

cmd_upload() {
  if [ "$MODE" = python ]; then pyexec upload "$@"; return; fi
  local f="${1:?用法: upload <本地文件> [URL目录, 默认 $REMOTE_DIR]}"
  local dir
  dir=$(last_dir "${2:-}")
  [ -f "$f" ] || { echo "[x] 本地文件不存在: $f"; exit 1; }
  case "$dir" in ..*|*..*) echo "[x] URL 目录不允许含 .."; exit 1 ;; esac
  show_and_run -sS -X POST \
    -H "X-Bas-Action: upload" \
    -H "X-Bas-Name: $(enc "$(basename "$f")")" \
    -H "Content-Type: application/octet-stream" \
    --data-binary "@$f" \
    "$URL$dir" -w '\nHTTP %{http_code}\n'
}

# bashttpd 只吃 raw body (无 multipart), upload_stream 与 upload 完全等价;
# 保留入口是为了与参考工具的命令面一致.
cmd_upload_stream() { cmd_upload "$@"; }

cmd_view() {
  if [ "$MODE" = python ]; then pyexec view "$@"; return; fi
  local remote="${1:?用法: view <URL文件路径>}"
  case "$remote" in ..*|*..*) echo "[x] URL 路径不允许含 .."; exit 1 ;; esac
  show_and_run -sS "$URL$remote"
}

cmd_list() {
  if [ "$MODE" = python ]; then pyexec list "$@"; return; fi
  local remote
  remote=$(last_dir "${1:-}")
  case "$remote" in ..*|*..*) echo "[x] URL 目录不允许含 .."; exit 1 ;; esac
  local ct
  ct=$(curl -s -o /dev/null -w '%{content_type}' "$URL$remote")
  if printf '%s' "$ct" | grep -q '^text/plain'; then
    # ls 回退: 原样输出
    show_and_run -sS "$URL$remote"
    return
  fi
  # tree HTML: 解析 tr -> 纯文本
  show_and_run -sS "$URL$remote" | python3 -c '
import re,sys
html = sys.stdin.read()
rows = re.findall(r"<tr data-href=\"[^\"]*\">(.*?)</tr>", html)
print("total %d" % len(rows))
for r in rows:
    tds = re.findall(r"<td[^>]*>(.*?)</td>", r)
    if len(tds) < 7: continue
    perm,u,g,size,date = tds[1],tds[2],tds[3],tds[4],tds[5]
    m = re.search(r"<a href=\"[^\"]*\">(.*)</a>", tds[6])
    name = re.sub(r"<[^>]+>","",m.group(1)).strip() if m else re.sub(r"<[^>]+>","",tds[6]).strip()
    print("%s  %-8s %-8s %10s  %s  %s" % (perm,u,g,size,date,name))
'
}

post_action_curl() {
  # $1=URL目录 $2=action  其余 -H/-d/--data-binary 透传
  local d="$1" act="$2"; shift 2
  curl -sS -X POST -H "X-Bas-Action: $act" "$@" "$URL$d" -w '\nHTTP %{http_code}\n'
}

cmd_mkdir() {
  if [ "$MODE" = python ]; then pyexec mkdir "$@"; return; fi
  local name="${1:?用法: mkdir <名字> [URL目录]}"
  local dir
  dir=$(last_dir "${2:-}")
  case "$dir" in ..*|*..*) echo "[x] URL 目录不允许含 .."; exit 1 ;; esac
  echo "+ curl -X POST -H 'X-Bas-Action: mkdir' -H 'X-Bas-Name: $(enc "$name")' $URL$dir"
  post_action_curl "$dir" mkdir -H "X-Bas-Name: $(enc "$name")"
}

cmd_delete() {
  if [ "$MODE" = python ]; then pyexec delete "$@"; return; fi
  [ $# -ge 1 ] || { echo "用法: delete <名字>... [URL目录]"; exit 1; }
  local dir
  if [ $# -ge 2 ]; then dir=$(last_dir "${!#}"); set -- "${@:1:$#-1}"; else dir=$(last_dir ""); fi
  case "$dir" in ..*|*..*) echo "[x] URL 目录不允许含 .."; exit 1 ;; esac
  local body=""
  local n
  for n in "$@"; do body+="$(enc "$n")
"; done
  echo "+ curl -X POST -H 'X-Bas-Action: delete' --data-binary <names> $URL$dir"
  printf '%s' "$body" > /tmp/bas-test-del.$$
  post_action_curl "$dir" delete --data-binary "@/tmp/bas-test-del.$$"
  rm -f /tmp/bas-test-del.$$
}

cmd_rename() {
  if [ "$MODE" = python ]; then pyexec rename "$@"; return; fi
  [ $# -ge 2 ] || { echo "用法: rename <旧名> <新名> [URL目录]"; exit 1; }
  local old="$1" new="$2"
  local dir
  dir=$(last_dir "${3:-}")
  case "$dir" in ..*|*..*) echo "[x] URL 目录不允许含 .."; exit 1 ;; esac
  echo "+ curl -X POST -H 'X-Bas-Action: rename' -H 'X-Bas-Name: $(enc "$old")' -H 'X-Bas-New-Name: $(enc "$new")' $URL$dir"
  post_action_curl "$dir" rename -H "X-Bas-Name: $(enc "$old")" -H "X-Bas-New-Name: $(enc "$new")"
}

cmd_copy() { cmd_paste_impl copy "$@"; }
cmd_cut()  { cmd_paste_impl cut "$@"; }
cmd_paste_impl() {
  if [ "$MODE" = python ]; then
    # pyexec 分发时按 copy/cut 走 do_paste
    pyexec "$1" "${@:2}"
    return
  fi
  local op="$1"; shift
  [ $# -ge 3 ] || { echo "用法: $op <名字>... <源URL目录> <目标URL目录>"; exit 1; }
  local dst="${!#}" src="${@: -2:1}"
  set -- "${@:1:$#-2}"
  local body="$src
"
  local n
  for n in "$@"; do body+="$(enc "$n")
"; done
  echo "+ curl -X POST -H 'X-Bas-Action: paste' -H 'X-Bas-Op: $op' --data-binary <body> $URL$dst"
  printf '%s' "$body" > /tmp/bas-test-paste.$$
  post_action_curl "$dst" paste -H "X-Bas-Op: $op" --data-binary "@/tmp/bas-test-paste.$$"
  rm -f /tmp/bas-test-paste.$$
}

cmd_favorite() {
  if [ "$MODE" = python ]; then pyexec favorite "$@"; return; fi
  local act="${1:-list}"
  local dir
  case "$act" in
    list)
      dir=$(last_dir "")
      echo "+ curl -X POST -H 'X-Bas-Action: favlist' $URL$dir"
      post_action_curl "$dir" favlist
      ;;
    add)
      dir=$(last_dir "${2:-}")
      echo "+ curl -X POST -H 'X-Bas-Action: favadd' $URL$dir"
      post_action_curl "$dir" favadd
      ;;
    remove)
      echo "[x] 服务器未实现 favorite remove (只有 favlist/favadd)"; exit 1 ;;
    *)
      echo "favorite 子命令: list | add [URL目录] (remove 服务器未实现)"; exit 1 ;;
  esac
}

# ============================================================
# smoke (curl 模式): 逐 action 验证
# ============================================================
cmd_smoke() {
  if [ "$MODE" = python ]; then pyexec smoke; return; fi
  local d tag sd pass=0 fail=0 skip=0 code body upname T
  d="${REMOTE_DIR%/}/"
  tag="smoke-cl"
  sd="$d$tag/"
  ok() { echo "  ✓ $1"; pass=$((pass+1)); }
  ng() { echo "  ✗ $1 ($2)"; fail=$((fail+1)); }
  sk() { echo "  - $1 (跳过: $2)"; skip=$((skip+1)); }
  T=$(mktemp)
  printf 'smoke-cl-%s-%s' "$(date +%s)" "$$" > "$T"

  echo "== smoke(curl) 目标: $URL | 测试目录: $sd =="

  echo "-- 0. ping"
  code=$(curl -s -o /dev/null -w '%{http_code}' "$URL/")
  [ "$code" = 200 ] && ok "ping 200" || ng "ping" "HTTP $code"

  echo "-- 1. mkdir"
  if curl -s "$URL$d" | grep -q "data-href=\"$(enc "$tag")\""; then
    sk "mkdir" "$tag 已存在"
  else
    code=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "X-Bas-Action: mkdir" -H "X-Bas-Name: $(enc "$tag")" "$URL$d")
    [ "$code" = 200 ] && ok "mkdir" || ng "mkdir" "HTTP $code"
  fi

  echo "-- 2. upload"
  upname="$tag-f.txt"
  code=$(curl -s -o /tmp/bas-sm1 -w '%{http_code}' -X POST \
    -H "X-Bas-Action: upload" -H "X-Bas-Name: $(enc "$upname")" \
    --data-binary "@$T" "$URL$sd")
  [ "$code" = 200 ] && ok "upload" || ng "upload" "HTTP $code $(cat /tmp/bas-sm1)"

  echo "-- 2b. upload 中文文件名"
  code=$(curl -s -o /tmp/bas-sm2 -w '%{http_code}' -X POST \
    -H "X-Bas-Action: upload" -H "X-Bas-Name: $(enc "$tag-中文名.txt")" \
    --data-binary "zhong-wen" "$URL$sd")
  [ "$code" = 200 ] && ok "upload 中文名" || ng "upload 中文名" "HTTP $code $(cat /tmp/bas-sm2)"

  echo "-- 3. view 内容一致"
  body=$(curl -s "$URL$sd$(enc "$upname")")
  [ "$body" = "$(cat "$T")" ] && ok "view 内容一致" || ng "view 内容一致" "内容不同: $body"

  echo "-- 3b. download 回环"
  curl -s -o /tmp/bas-sm.dl "$URL$sd$(enc "$upname")"
  cmp -s "$T" /tmp/bas-sm.dl && ok "download 回环一致" || ng "download 回环" "cmp 失败"

  echo "-- 3c. 二进制回环"
  head -c 4096 /dev/urandom > /tmp/bas-sm.bin
  code=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
    -H "X-Bas-Action: upload" -H "X-Bas-Name: $(enc "$tag-f.bin")" \
    --data-binary "@/tmp/bas-sm.bin" "$URL$sd")
  curl -s -o /tmp/bas-sm.bin2 "$URL$sd$(enc "$tag-f.bin")"
  if [ "$code" = 200 ] && cmp -s /tmp/bas-sm.bin /tmp/bas-sm.bin2; then ok "二进制回环"; else ng "二进制回环" "HTTP $code cmp 失败"; fi

  echo "-- 4. list 包含上传文件"
  curl -s "$URL$sd" | grep -q "data-href" && ok "list 页可用" || ng "list 页", "无表格行"

  echo "-- 5. rename"
  code=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
    -H "X-Bas-Action: rename" -H "X-Bas-Name: $(enc "$upname")" -H "X-Bas-New-Name: $(enc "$upname.rn")" \
    "$URL$sd")
  [ "$code" = 200 ] && ok "rename" || ng "rename" "HTTP $code"

  echo "-- 5b. rename 后旧名 404"
  code=$(curl -s -o /dev/null -w '%{http_code}' "$URL$sd$(enc "$upname")")
  [ "$code" = 404 ] && ok "rename 后旧名 404" || ng "rename 后旧名 404" "HTTP $code (期望 404)"

  echo "-- 6. copy paste"
  curl -s -o /dev/null -X POST -H "X-Bas-Action: mkdir" -H "X-Bas-Name: $(enc "${tag}2")" "$URL$d"
  printf '%s\n%s\n' "$sd" "$(enc "$upname.rn")" > /tmp/bas-sm.paste
  code=$(curl -s -o /tmp/bas-sm.p1 -w '%{http_code}' -X POST \
    -H "X-Bas-Action: paste" -H "X-Bas-Op: copy" --data-binary "@/tmp/bas-sm.paste" "$URL$d${tag}2/")
  [ "$code" = 200 ] && ok "paste copy" || ng "paste copy" "HTTP $code $(cat /tmp/bas-sm.p1)"

  echo "-- 6b. cut paste"
  printf '%s\n%s\n' "$d${tag}2/" "$(enc "$upname.rn")" > /tmp/bas-sm.paste
  code=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
    -H "X-Bas-Action: paste" -H "X-Bas-Op: cut" --data-binary "@/tmp/bas-sm.paste" "$URL$sd")
  [ "$code" = 200 ] && ok "paste cut" || ng "paste cut" "HTTP $code"

  echo "-- 7. delete"
  printf '%s\n' "$(enc "$upname.rn")" "$(enc "$tag-f.bin")" "$(enc "$tag-中文名.txt")" > /tmp/bas-sm.del
  code=$(curl -s -o /tmp/bas-sm.d1 -w '%{http_code}' -X POST \
    -H "X-Bas-Action: delete" --data-binary "@/tmp/bas-sm.del" "$URL$sd")
  [ "$code" = 200 ] && ok "delete" || ng "delete" "HTTP $code $(cat /tmp/bas-sm.d1)"

  echo "-- 8. favorite"
  code=$(curl -s -o /tmp/bas-sm.fav -w '%{http_code}' -X POST -H "X-Bas-Action: favlist" "$URL$d")
  if [ "$code" = 200 ] && python3 -c 'import json,sys; json.load(open(sys.argv[1]))' /tmp/bas-sm.fav 2>/dev/null; then
    ok "favlist JSON"
  else
    ng "favlist" "HTTP $code: $(head -c 60 /tmp/bas-sm.fav)"
  fi
  # favadd 写服务器 favorite.json 且服务器无 remove, 只在本机可回滚时才真做
  FAVF="$(cd "$(dirname "$0")" && pwd)/favorite.json"
  case "$URL" in
    *127.0.0.1*|*localhost*)
      if [ -f "$FAVF" ]; then
        cp "$FAVF" /tmp/bas-sm.fav.bak
        code=$(curl -s -o /tmp/bas-sm.fav2 -w '%{http_code}' -X POST -H "X-Bas-Action: favadd" "$URL$sd")
        if [ "$code" = 200 ] && grep -qE "(added:|already in favorites)" /tmp/bas-sm.fav2; then
          ok "favadd"
        else
          ng "favadd" "HTTP $code: $(cat /tmp/bas-sm.fav2)"
        fi
        cp /tmp/bas-sm.fav.bak "$FAVF"
        echo "  [i] favorite.json 已回滚到测试前状态"
      else
        sk "favadd" "本机未找到 favorite.json, 无法回滚, 避免污染收藏"
      fi
      ;;
    *)
      sk "favadd" "远端服务器: favadd 无 remove 无法恢复, 跳过"
      ;;
  esac

  echo "-- 9. 错误码"
  code=$(curl -s -o /dev/null -w '%{http_code}' -I "$URL/")
  [ "$code" = 405 ] && ok "HEAD -> 405" || ng "HEAD 405" "HTTP $code"
  # curl 默认会规范化掉 .. (变成 /etc/passwd -> 404), 必须原样发
  code=$(curl --path-as-is -s -o /dev/null -w '%{http_code}' "$URL/../etc/passwd")
  [ "$code" = 400 ] && ok ".. -> 400" || ng ".. 400" "HTTP $code"
  code=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "X-Bas-Action: upload" -H "X-Bas-Name: a%2Fb" --data-binary x "$URL$d")
  [ "$code" = 400 ] && ok "bad name -> 400" || ng "bad name 400" "HTTP $code"

  echo "-- 10. 清理"
  printf '%s\n%s\n' "$(enc "$tag")" "$(enc "${tag}2")" > /tmp/bas-sm.del
  code=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "X-Bas-Action: delete" --data-binary "@/tmp/bas-sm.del" "$URL$d")
  [ "$code" = 200 ] && ok "清理" || ng "清理", "HTTP $code"

  rm -f "$T" /tmp/bas-sm1 /tmp/bas-sm2 /tmp/bas-sm.dl /tmp/bas-sm.bin /tmp/bas-sm.bin2 /tmp/bas-sm.paste /tmp/bas-sm.p1 /tmp/bas-sm.d1 /tmp/bas-sm.fav /tmp/bas-sm.fav2 /tmp/bas-sm.del

  echo "== 结果: PASS=$pass FAIL=$fail SKIP=$skip =="
  [ "$fail" -eq 0 ]
}

# ============================================================
# 统一入口: action 分发 (python 模式经 pyexec, curl 模式直接跑)
# ============================================================
ACTION="${1:-help}"
[ $# -gt 0 ] && shift
case "$ACTION" in
  ping)          cmd_ping "$@" ;;
  download)      cmd_download "$@" ;;
  upload)        cmd_upload "$@" ;;
  upload_stream) cmd_upload_stream "$@" ;;
  view)          cmd_view "$@" ;;
  list)          cmd_list "$@" ;;
  mkdir)         cmd_mkdir "$@" ;;
  delete)        cmd_delete "$@" ;;
  rename)        cmd_rename "$@" ;;
  copy)          cmd_copy "$@" ;;
  cut)           cmd_cut "$@" ;;
  favorite)      cmd_favorite "$@" ;;
  smoke)         cmd_smoke "$@" ;;
  help|-h|--help) usage ;;
  *) echo "未知 action: $ACTION"; echo; usage; exit 1 ;;
esac
