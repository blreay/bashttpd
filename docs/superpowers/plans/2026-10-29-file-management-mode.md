# 文件管理模式 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 bashttpd 的 tree 目录列表页面上增加"管理模式"：管理/只读切换、多选复选框、底部一行操作栏（新文件夹/复制/剪切/粘贴/删除/重命名）、表头三态全选框。

**Architecture:** 方案 B。改动集中在单文件 `bashttpd` 的三处：(1) `serve_dir_with_tree` 的 awk 阶段给每行注入 `data-href` 与复选框单元格、表头注入全选框；(2) `dir_controls` 输出的 HTML/CSS/JS 增加管理按钮、底部操作栏、管理模式交互；(3) 底部 POST 分发新增 `delete`/`rename`/`paste` 三个动作，复用既有 `bas_post_reply` / `resolve_local_dir` / `urldecode` 框架。剪贴板存浏览器 localStorage，模式状态存 sessionStorage。

**Tech Stack:** bash、awk（POSIX）、原生 JavaScript（fetch/localStorage/sessionStorage）、tree、ncat、curl。

**规格来源:** `docs/superpowers/specs/2026-10-29-file-management-mode-design.md`

**测试说明:** 本仓库无单元测试框架（见 CLAUDE.md）。验证方式为：`bash -n` 语法检查 + 启动真实服务用 `curl` 打目录列表/POST 动作并检查文件系统效果 + 浏览器手工走查。后端任务（1-3）用 curl 端到端验证；前端任务（4-7）用 `curl | grep` 验证注入的 HTML/JS 标记；任务 8 做浏览器手工走查。

**测试路由:** `bashttpd.conf` 有 `on_uri_match '^/myhome(.*)' serve_dir_or_file_from "$HOME"`，故 `$HOME/bastest` 对应 URI `/myhome/bastest/`。测试端口用 `8099`。

---

## 文件结构

只修改一个文件：`/home/admin/git/bashttpd/bashttpd`

| 区域 | 行号（改动前，约） | 职责 |
|---|---|---|
| `serve_dir_with_tree()` | 204-263 | awk 生成表格；本计划注入 `data-href`、复选框单元格、全选框、自身行标记 |
| `bas_do_upload()` 之后 | 415 之后插入 | 新增 `bas_do_delete` / `bas_do_rename` / `bas_do_paste` |
| `dir_controls()` | 503-633 | 控件 HTML/CSS/JS；本计划加管理按钮、操作栏、管理模式 JS |
| 请求头解析 `case` | 679-683 | 新增读取 `X-Bas-New-Name` / `X-Bas-Op` |
| POST 动作分发 `case` | 699-705 | 新增 `delete`/`rename`/`paste` 分支 |

---

## Task 1: 后端 delete 动作（含测试服务搭建）

**Files:**
- Modify: `/home/admin/git/bashttpd/bashttpd`（请求头解析 case、POST 分发 case、`bas_do_upload` 之后新增函数）

- [ ] **Step 1: 搭建测试服务与样例目录**

Run:
```bash
cd /home/admin/git/bashttpd
pkill -f 'ncat.*8099' 2>/dev/null; sleep 0.3
rm -rf ~/bastest && mkdir -p ~/bastest/sub && echo hello > ~/bastest/a.txt && echo world > ~/bastest/b.txt && touch ~/bastest/sub/c.txt
./start.sh 8099 >/tmp/bashttpd_test.log 2>&1 &
sleep 1
curl -s "http://localhost:8099/myhome/bastest/" | grep -c '<a href' 
```
Expected: 输出 ≥ 3（能看到目录列表，服务已起）。此服务在 Task 1-3 期间保持运行，Task 8 结束时关闭。

- [ ] **Step 2: 写验证命令，确认 delete 动作当前失败**

Run:
```bash
printf 'a.txt\nb.txt\n' | curl -s -X POST "http://localhost:8099/myhome/bastest/" \
  -H 'X-Bas-Action: delete' --data-binary @-
echo; ls ~/bastest
```
Expected: 回复 `400 unknown action: delete`；`ls` 仍显示 `a.txt b.txt sub`（未删除）。

- [ ] **Step 3: 新增请求头解析（为 Task 2/3 一并加好）**

用 Edit 修改 `/home/admin/git/bashttpd/bashttpd`。

old_string:
```
      "X-Bas-Action: "*) X_BAS_ACTION="${line#X-Bas-Action: }" ;;
      "X-Bas-Name: "*) X_BAS_NAME="${line#X-Bas-Name: }" ;;
   esac
```
new_string:
```
      "X-Bas-Action: "*) X_BAS_ACTION="${line#X-Bas-Action: }" ;;
      "X-Bas-Name: "*) X_BAS_NAME="${line#X-Bas-Name: }" ;;
      "X-Bas-New-Name: "*) X_BAS_NEW_NAME="${line#X-Bas-New-Name: }" ;;
      "X-Bas-Op: "*) X_BAS_OP="${line#X-Bas-Op: }" ;;
   esac
```

- [ ] **Step 4: 新增 `bas_do_delete` 函数**

用 Edit 在 `bas_do_upload()` 的结尾与 `# Favorite paths are stored` 注释之间插入函数。

old_string:
```
   bas_post_reply 500 "upload failed: $target"
}

# Favorite paths are stored in favorite.json (a JSON array of URI strings)
```
new_string:
```
   bas_post_reply 500 "upload failed: $target"
}

# Delete selected entries from the directory the requested URI maps to.
# The POST body carries one percent-encoded name per line.  Used by the
# "删除" button in manage mode.
bas_do_delete() {
   local dir name ok=0 fail=0
   [[ -n $BODY_FILE ]] || bas_post_reply 400 "empty body"
   dir=$(resolve_local_dir "$REQUEST_URI") || \
      bas_post_reply 500 "no directory rule for: $REQUEST_URI"
   while IFS= read -r name || [[ -n $name ]]; do
      [[ -z $name ]] && continue
      name=$(urldecode "$name")
      if [[ -z $name || $name == */* || $name == . || $name == .. ]]; then
         fail=$((fail + 1)); continue
      fi
      if rm -rf "${dir%/}/$name"; then ok=$((ok + 1)); else fail=$((fail + 1)); fi
   done < "$BODY_FILE"
   bas_post_reply 200 "deleted $ok, failed $fail"
}

# Favorite paths are stored in favorite.json (a JSON array of URI strings)
```

- [ ] **Step 5: 新增 delete 分发分支**

用 Edit 修改 POST 动作 case。

old_string:
```
      mkdir)  bas_do_mkdir ;;
      upload) bas_do_upload ;;
      favlist) bas_do_favlist ;;
```
new_string:
```
      mkdir)  bas_do_mkdir ;;
      upload) bas_do_upload ;;
      delete) bas_do_delete ;;
      favlist) bas_do_favlist ;;
```

- [ ] **Step 6: 语法检查**

Run: `bash -n /home/admin/git/bashttpd/bashttpd && echo SYNTAX_OK`
Expected: `SYNTAX_OK`

- [ ] **Step 7: 重启服务并验证 delete 生效**

Run:
```bash
pkill -f 'ncat.*8099'; sleep 0.5
cd /home/admin/git/bashttpd && ./start.sh 8099 >/tmp/bashttpd_test.log 2>&1 &
sleep 1
printf 'a.txt\nb.txt\n' | curl -s -X POST "http://localhost:8099/myhome/bastest/" \
  -H 'X-Bas-Action: delete' --data-binary @-
echo; ls ~/bastest
```
Expected: 回复 `200 deleted 2, failed 0`；`ls` 只剩 `sub`。

- [ ] **Step 8: 验证非法名被拒（含 `/` 的名字一律拒删，只删合法的单段名）**

Run:
```bash
echo hi > ~/bastest/keep.txt; echo bye > ~/bastest/del.txt
printf '../evil\ndel.txt\n/abs\n' | curl -s -X POST "http://localhost:8099/myhome/bastest/" \
  -H 'X-Bas-Action: delete' --data-binary @-
echo; ls ~/bastest; test -e ~/evil && echo "ESCAPED!" || echo "no escape"
```
Expected: 回复 `200 deleted 1, failed 2`——只有合法的单段名 `del.txt` 被删；`../evil` 与 `/abs` 含 `/` 被拒（计入 failed）。`~/bastest` 仍有 `keep.txt sub`、无 `del.txt`；输出 `no escape`（`$HOME/evil` 未被创建）。注意：管理模式只对当前目录的直接条目操作，名字永远是单段、不含 `/`，故含 `/` 的名字属于非法输入。

- [ ] **Step 9: Commit**

```bash
cd /home/admin/git/bashttpd
git add bashttpd
git commit -m "$(cat <<'EOF'
feat(bashttpd): add delete POST action for manage mode

New bas_do_delete reads percent-encoded names from the POST body and
rm -rf's each under the resolved directory, rejecting names containing
/ or equal to . / .. Also parse X-Bas-New-Name and X-Bas-Op headers for
upcoming rename/paste actions.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: 后端 rename 动作

**Files:**
- Modify: `/home/admin/git/bashttpd/bashttpd`（新增 `bas_do_rename`，分发 case）

- [ ] **Step 1: 写验证命令，确认 rename 当前失败**

Run:
```bash
echo data > ~/bastest/old.txt
curl -s -X POST "http://localhost:8099/myhome/bastest/" \
  -H 'X-Bas-Action: rename' -H 'X-Bas-Name: old.txt' -H 'X-Bas-New-Name: new.txt'
echo; ls ~/bastest
```
Expected: 回复 `400 unknown action: rename`；`old.txt` 仍在。

- [ ] **Step 2: 新增 `bas_do_rename` 函数**

用 Edit 在 `bas_do_delete` 之后插入。

old_string:
```
   bas_post_reply 200 "deleted $ok, failed $fail"
}

# Favorite paths are stored in favorite.json (a JSON array of URI strings)
```
new_string:
```
   bas_post_reply 200 "deleted $ok, failed $fail"
}

# Rename a single entry.  Old name arrives percent-encoded in X-Bas-Name,
# new name in X-Bas-New-Name.  Used by the "重命名" button in manage mode.
bas_do_rename() {
   local dir old new
   old=$(urldecode "${X_BAS_NAME:-}")
   new=$(urldecode "${X_BAS_NEW_NAME:-}")
   if [[ -z $old || $old == */* || $old == . || $old == .. ]]; then
      bas_post_reply 400 "bad old name: $old"
   fi
   if [[ -z $new || $new == */* || $new == . || $new == .. ]]; then
      bas_post_reply 400 "bad new name: $new"
   fi
   dir=$(resolve_local_dir "$REQUEST_URI") || \
      bas_post_reply 500 "no directory rule for: $REQUEST_URI"
   [[ -e "${dir%/}/$old" ]] || bas_post_reply 404 "not found: $old"
   [[ -e "${dir%/}/$new" ]] && bas_post_reply 403 "already exists: $new"
   if mv "${dir%/}/$old" "${dir%/}/$new"; then
      bas_post_reply 200 "renamed: $old -> $new"
   fi
   bas_post_reply 500 "rename failed: $old"
}

# Favorite paths are stored in favorite.json (a JSON array of URI strings)
```

- [ ] **Step 3: 新增 rename 分发分支**

用 Edit：

old_string:
```
      delete) bas_do_delete ;;
      favlist) bas_do_favlist ;;
```
new_string:
```
      delete) bas_do_delete ;;
      rename) bas_do_rename ;;
      favlist) bas_do_favlist ;;
```

- [ ] **Step 4: 语法检查**

Run: `bash -n /home/admin/git/bashttpd/bashttpd && echo SYNTAX_OK`
Expected: `SYNTAX_OK`

- [ ] **Step 5: 重启服务并验证 rename 生效**

Run:
```bash
pkill -f 'ncat.*8099'; sleep 0.5
cd /home/admin/git/bashttpd && ./start.sh 8099 >/tmp/bashttpd_test.log 2>&1 &
sleep 1
curl -s -X POST "http://localhost:8099/myhome/bastest/" \
  -H 'X-Bas-Action: rename' -H 'X-Bas-Name: old.txt' -H 'X-Bas-New-Name: new.txt'
echo; ls ~/bastest
```
Expected: 回复 `200 renamed: old.txt -> new.txt`；`ls` 显示 `new.txt`，无 `old.txt`。

- [ ] **Step 6: 验证重名与非法名**

Run:
```bash
echo x > ~/bastest/taken.txt
curl -s -X POST "http://localhost:8099/myhome/bastest/" -H 'X-Bas-Action: rename' -H 'X-Bas-Name: new.txt' -H 'X-Bas-New-Name: taken.txt'; echo
curl -s -X POST "http://localhost:8099/myhome/bastest/" -H 'X-Bas-Action: rename' -H 'X-Bas-Name: new.txt' -H 'X-Bas-New-Name: ../esc.txt'; echo
curl -s -X POST "http://localhost:8099/myhome/bastest/" -H 'X-Bas-Action: rename' -H 'X-Bas-Name: nope.txt' -H 'X-Bas-New-Name: z.txt'; echo
```
Expected: 依次 `403 already exists: taken.txt`、`400 bad new name: ../esc.txt`、`404 not found: nope.txt`；`new.txt` 与 `taken.txt` 均未变。

- [ ] **Step 7: Commit**

```bash
cd /home/admin/git/bashttpd
git add bashttpd
git commit -m "$(cat <<'EOF'
feat(bashttpd): add rename POST action for manage mode

bas_do_rename takes old/new percent-encoded names via X-Bas-Name and
X-Bas-New-Name, rejects names with / or . / .., 404s when the source is
missing and 403s when the target exists.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: 后端 paste 动作（复制/剪切粘贴）

**Files:**
- Modify: `/home/admin/git/bashttpd/bashttpd`（新增 `bas_do_paste`，分发 case）

- [ ] **Step 1: 写验证命令，确认 paste 当前失败**

Run:
```bash
rm -rf ~/bastest && mkdir -p ~/bastest/src ~/bastest/dst
echo f1 > ~/bastest/src/f1.txt; echo f2 > ~/bastest/src/f2.txt
printf '/myhome/bastest/src\nf1.txt\nf2.txt\n' | curl -s -X POST "http://localhost:8099/myhome/bastest/dst/" \
  -H 'X-Bas-Action: paste' -H 'X-Bas-Op: copy' --data-binary @-
echo; ls ~/bastest/dst
```
Expected: 回复 `400 unknown action: paste`；`dst` 为空。

- [ ] **Step 2: 新增 `bas_do_paste` 函数**

用 Edit 在 `bas_do_rename` 之后插入。

old_string:
```
   bas_post_reply 500 "rename failed: $old"
}

# Favorite paths are stored in favorite.json (a JSON array of URI strings)
```
new_string:
```
   bas_post_reply 500 "rename failed: $old"
}

# Copy or cut-paste entries into the directory the requested URI maps to.
# X-Bas-Op is 'copy' or 'cut'.  The POST body's first line is the source
# directory URI (percent-encoded, resolved like a request URI); remaining
# lines are percent-encoded entry names.  Used by the "粘贴" button.
bas_do_paste() {
   local src_uri src dst op name ok=0 skip=0 fail=0
   op="${X_BAS_OP:-}"
   [[ $op == copy || $op == cut ]] || bas_post_reply 400 "bad op: $op"
   [[ -n $BODY_FILE ]] || bas_post_reply 400 "empty body"
   dst=$(resolve_local_dir "$REQUEST_URI") || \
      bas_post_reply 500 "no directory rule for: $REQUEST_URI"
   src_uri=$(head -n1 "$BODY_FILE")
   src=$(resolve_local_dir "$src_uri") || \
      bas_post_reply 500 "no directory rule for source: $src_uri"
   while IFS= read -r name || [[ -n $name ]]; do
      [[ -z $name ]] && continue
      name=$(urldecode "$name")
      if [[ -z $name || $name == */* || $name == . || $name == .. ]]; then
         fail=$((fail + 1)); continue
      fi
      [[ -e "${src%/}/$name" ]] || { fail=$((fail + 1)); continue; }
      [[ -e "${dst%/}/$name" ]] && { skip=$((skip + 1)); continue; }
      if [[ $op == copy ]]; then
         cp -a "${src%/}/$name" "${dst%/}/$name" && ok=$((ok + 1)) || fail=$((fail + 1))
      else
         mv "${src%/}/$name" "${dst%/}/$name" && ok=$((ok + 1)) || fail=$((fail + 1))
      fi
   done < <(tail -n +2 "$BODY_FILE")
   bas_post_reply 200 "pasted $ok, skipped $skip, failed $fail"
}

# Favorite paths are stored in favorite.json (a JSON array of URI strings)
```

- [ ] **Step 3: 新增 paste 分发分支**

用 Edit：

old_string:
```
      rename) bas_do_rename ;;
      favlist) bas_do_favlist ;;
```
new_string:
```
      rename) bas_do_rename ;;
      paste)  bas_do_paste ;;
      favlist) bas_do_favlist ;;
```

- [ ] **Step 4: 语法检查**

Run: `bash -n /home/admin/git/bashttpd/bashttpd && echo SYNTAX_OK`
Expected: `SYNTAX_OK`

- [ ] **Step 5: 重启服务并验证 copy 粘贴**

Run:
```bash
pkill -f 'ncat.*8099'; sleep 0.5
cd /home/admin/git/bashttpd && ./start.sh 8099 >/tmp/bashttpd_test.log 2>&1 &
sleep 1
printf '/myhome/bastest/src\nf1.txt\nf2.txt\n' | curl -s -X POST "http://localhost:8099/myhome/bastest/dst/" \
  -H 'X-Bas-Action: paste' -H 'X-Bas-Op: copy' --data-binary @-
echo; ls ~/bastest/dst; ls ~/bastest/src
```
Expected: 回复 `200 pasted 2, skipped 0, failed 0`；`dst` 有 `f1.txt f2.txt`；`src` 仍保留两文件（copy 不删源）。

- [ ] **Step 6: 验证重名跳过**

Run:
```bash
echo changed > ~/bastest/src/f1.txt
printf '/myhome/bastest/src\nf1.txt\nf2.txt\n' | curl -s -X POST "http://localhost:8099/myhome/bastest/dst/" \
  -H 'X-Bas-Action: paste' -H 'X-Bas-Op: copy' --data-binary @-
echo; cat ~/bastest/dst/f1.txt
```
Expected: 回复 `200 pasted 0, skipped 2, failed 0`；`dst/f1.txt` 内容仍是第一次的 `f1`（未被覆盖）。

- [ ] **Step 7: 验证 cut 粘贴（移动，删源）**

Run:
```bash
rm -rf ~/bastest/dst2 && mkdir -p ~/bastest/dst2
printf '/myhome/bastest/src\nf2.txt\n' | curl -s -X POST "http://localhost:8099/myhome/bastest/dst2/" \
  -H 'X-Bas-Action: paste' -H 'X-Bas-Op: cut' --data-binary @-
echo; ls ~/bastest/dst2; ls ~/bastest/src
```
Expected: 回复 `200 pasted 1, skipped 0, failed 0`；`dst2` 有 `f2.txt`；`src` 只剩 `f1.txt`（源已移走）。

- [ ] **Step 8: 验证非法 op 与非法名**

Run:
```bash
printf '/myhome/bastest/src\nf1.txt\n' | curl -s -X POST "http://localhost:8099/myhome/bastest/dst2/" -H 'X-Bas-Action: paste' -H 'X-Bas-Op: bogus' --data-binary @-; echo
printf '/myhome/bastest/src\n../esc.txt\n' | curl -s -X POST "http://localhost:8099/myhome/bastest/dst2/" -H 'X-Bas-Action: paste' -H 'X-Bas-Op: copy' --data-binary @-; echo
ls ~/bastest
```
Expected: 第一条 `400 bad op: bogus`；第二条 `200 pasted 0, skipped 0, failed 1`；`~/bastest` 下没有出现 `esc.txt`。

- [ ] **Step 9: Commit**

```bash
cd /home/admin/git/bashttpd
git add bashttpd
git commit -m "$(cat <<'EOF'
feat(bashttpd): add paste POST action for manage mode

bas_do_paste copies (cp -a) or cuts (mv) entries from a source directory
URI (first body line) into the directory the request URI maps to. Op comes
from X-Bas-Op. Existing targets are skipped, illegal names rejected; the
reply summarizes pasted/skipped/failed counts.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: awk 注入 data-href / 复选框单元格 / 全选框 / 自身行标记

**Files:**
- Modify: `/home/admin/git/bashttpd/bashttpd:204-263`（`serve_dir_with_tree`）

- [ ] **Step 1: 写验证命令，确认当前列表无这些标记**

Run:
```bash
curl -s "http://localhost:8099/myhome/bastest/src/" | grep -c -E 'data-href=|bas-rowchk|basSelAll|data-self='
```
Expected: `0`（当前尚无注入）。

- [ ] **Step 2: 替换整个 `serve_dir_with_tree` 函数**

用 Edit 修改 `/home/admin/git/bashttpd/bashttpd`。

old_string:
```
serve_dir_with_tree()
{
   local dir="$1" tree_vers tree_opts basehref x

   add_response_header "Content-Type" "text/html; charset=utf-8"

   # The --du option was added in 1.6.0.
   read x tree_vers x < <(tree --version)
   [[ $tree_vers == v1.6* ]] && tree_opts="--du"

	## fix one bug to list root dir of DOCROOT
   ## The awk stage injects the breadcrumb / [ .. ] / button lines and
   ## rewrites the tree entry lines as an HTML table with one <td> per
   ## independent column (permissions, user, group, size, date, name),
   ## each left-aligned.  The tree-drawing prefix is kept inside the
   ## name cell.
   send_response_ok_exit < \
      <({ tree -H "${2%/}" --charset=utf-8 -apsthugDF --dirsfirst  -L 1 $tree_opts -D "$dir"; } | \
         BAS_CRUMBS="$(dir_crumbs "$2")" BAS_CONTROLS="$(dir_controls)" awk '
            {
               line = $0
               if (line ~ /<h1>Directory Tree<\/h1>/) {
                  print line
                  print "\t" ENVIRON["BAS_CRUMBS"] "<br>"
                  print "\t<a href=\"../\">[&nbsp;..&nbsp;]</a>"
                  print ENVIRON["BAS_CONTROLS"]
                  next
               }
               if (line ~ /\]&nbsp;&nbsp;&nbsp;&nbsp;<a/) {
                  p = index(line, "[")
                  q = index(substr(line, p), "]")
                  inner = substr(line, p + 1, q - 2)
                  gsub(/(&nbsp;)+/, "\\&nbsp;", inner)
                  nf = split(inner, f, /&nbsp;/)
                  if (nf < 7) {
                     if (intbl) { print "</table>"; intbl = 0 }
                     print line
                     next
                  }
                  if (!intbl) {
                     print "</p>"
                     print "<table cellspacing=\"4\" cellpadding=\"0\">"
                     print "<tr>" td("permissions") td("user") td("group") td("size") td("date") td("name") "</tr>"
                     intbl = 1
                  }
                  pre = substr(line, 1, p - 1)
                  tail = substr(line, p + q - 1)
                  sub(/^\]/, "", tail)
                  sub(/^(&nbsp;)+/, "", tail)
                  sub(/<br>$/, "", tail)
                  print "<tr>" td(f[1]) td(f[2]) td(f[3]) td(f[4]) td(f[5] " " f[6] " " f[7]) td(pre " " tail) "</tr>"
                  next
               }
               if (intbl) { print "</table>"; intbl = 0 }
               print line
            }
            END { if (intbl) print "</table>" }
            function td(x) { return "<td style=\"text-align:left;white-space:nowrap;padding-right:16px\">" x "</td>" }
         ')
}
```
new_string:
```
serve_dir_with_tree()
{
   local dir="$1" tree_vers tree_opts base_href x

   add_response_header "Content-Type" "text/html; charset=utf-8"

   # The --du option was added in 1.6.0.
   read x tree_vers x < <(tree --version)
   [[ $tree_vers == v1.6* ]] && tree_opts="--du"

   # Base URI used for tree hrefs, breadcrumbs, and self-row detection.
   base_href="${2%%\?*}"; base_href="${base_href%/}"

	## fix one bug to list root dir of DOCROOT
   ## The awk stage injects the breadcrumb / [ .. ] / button lines and
   ## rewrites the tree entry lines as an HTML table with one <td> per
   ## independent column (permissions, user, group, size, date, name),
   ## each left-aligned.  The tree-drawing prefix is kept inside the
   ## name cell.  Each entry row also carries data-href (its percent-
   ## encoded name) and a leading selection cell holding a checkbox; the
   ## header row carries a select-all checkbox plus a (X/Y) count span.
   ## The row for the current directory itself is marked data-self="1"
   ## and gets no checkbox so it can never be selected/operated on.
   send_response_ok_exit < \
      <({ tree -H "$base_href" --charset=utf-8 -apsthugDF --dirsfirst  -L 1 $tree_opts -D "$dir"; } | \
         BAS_BASE="$base_href" BAS_CRUMBS="$(dir_crumbs "$2")" BAS_CONTROLS="$(dir_controls)" awk '
            {
               line = $0
               if (line ~ /<h1>Directory Tree<\/h1>/) {
                  print line
                  print "\t" ENVIRON["BAS_CRUMBS"] "<br>"
                  print "\t<a href=\"../\">[&nbsp;..&nbsp;]</a>"
                  print ENVIRON["BAS_CONTROLS"]
                  next
               }
               if (line ~ /\]&nbsp;&nbsp;&nbsp;&nbsp;<a/) {
                  p = index(line, "[")
                  q = index(substr(line, p), "]")
                  inner = substr(line, p + 1, q - 2)
                  gsub(/(&nbsp;)+/, "\\&nbsp;", inner)
                  nf = split(inner, f, /&nbsp;/)
                  if (nf < 7) {
                     if (intbl) { print "</table>"; intbl = 0 }
                     print line
                     next
                  }
                  if (!intbl) {
                     print "</p>"
                     print "<table cellspacing=\"4\" cellpadding=\"0\">"
                     print "<tr>" selcell("<input type=\"checkbox\" id=\"basSelAll\"><span id=\"basSelCount\"></span>") td("permissions") td("user") td("group") td("size") td("date") td("name") "</tr>"
                     intbl = 1
                  }
                  href = ""
                  if (match(line, /href="[^"]*"/)) href = substr(line, RSTART + 6, RLENGTH - 7)
                  hs = href; sub(/\/$/, "", hs)
                  nh = split(hs, seg, "/")
                  enc = seg[nh]
                  isSelf = (hs == ENVIRON["BAS_BASE"]) ? 1 : 0
                  pre = substr(line, 1, p - 1)
                  tail = substr(line, p + q - 1)
                  sub(/^\]/, "", tail)
                  sub(/^(&nbsp;)+/, "", tail)
                  sub(/<br>$/, "", tail)
                  if (isSelf) {
                     print "<tr data-self=\"1\">" selcell("") td(f[1]) td(f[2]) td(f[3]) td(f[4]) td(f[5] " " f[6] " " f[7]) td(pre " " tail) "</tr>"
                  } else {
                     print "<tr data-href=\"" enc "\">" selcell("<input type=\"checkbox\" class=\"bas-rowchk\">") td(f[1]) td(f[2]) td(f[3]) td(f[4]) td(f[5] " " f[6] " " f[7]) td(pre " " tail) "</tr>"
                  }
                  next
               }
               if (intbl) { print "</table>"; intbl = 0 }
               print line
            }
            END { if (intbl) print "</table>" }
            function td(x) { return "<td style=\"text-align:left;white-space:nowrap;padding-right:16px\">" x "</td>" }
            function selcell(x) { return "<td class=\"bas-selcell\">" x "</td>" }
         ')
}
```

- [ ] **Step 3: 语法检查**

Run: `bash -n /home/admin/git/bashttpd/bashttpd && echo SYNTAX_OK`
Expected: `SYNTAX_OK`

- [ ] **Step 4: 重启服务并验证注入标记**

Run:
```bash
pkill -f 'ncat.*8099'; sleep 0.5
cd /home/admin/git/bashttpd && ./start.sh 8099 >/tmp/bashttpd_test.log 2>&1 &
sleep 1
curl -s "http://localhost:8099/myhome/bastest/src/" > /tmp/list.html
echo "selAll:  $(grep -c 'id="basSelAll"' /tmp/list.html)"
echo "rowchk:  $(grep -c 'class="bas-rowchk"' /tmp/list.html)"
echo "datahref:$(grep -c 'data-href=' /tmp/list.html)"
echo "dataself:$(grep -c 'data-self="1"' /tmp/list.html)"
echo "selcount:$(grep -c 'id="basSelCount"' /tmp/list.html)"
grep -o 'data-href="[^"]*"' /tmp/list.html
```
Expected: `selAll:1`、`rowchk:≥1`（src 里的文件数）、`datahref:≥1`、`dataself:1`（当前目录自身行）、`selcount:1`；`data-href` 列表里出现 `f1.txt`（不含自身目录名 `src`）。

- [ ] **Step 5: 验证中文名编码与自身行不带复选框**

Run:
```bash
touch ~/bastest/src/中文.txt
curl -s "http://localhost:8099/myhome/bastest/src/" > /tmp/list2.html
grep -o 'data-href="[^"]*"' /tmp/list2.html
# 自身行：有 data-self 且其单元格内无 checkbox
grep -o '<tr data-self="1"><td class="bas-selcell"></td>' /tmp/list2.html
```
Expected: `data-href` 中出现 `%E4%B8%AD%E6%96%87.txt`（中文被百分号编码）；自身行匹配到空的选择单元格（`<td class="bas-selcell"></td>`，无 input）。

- [ ] **Step 6: Commit**

```bash
cd /home/admin/git/bashttpd
git add bashttpd
git commit -m "$(cat <<'EOF'
feat(bashttpd): inject selection cells and data-href into dir listing

The awk stage now adds a leading .bas-selcell to every row (checkbox for
entries, empty for the current-directory self row) and a select-all
checkbox plus (X/Y) count span in the header. Each entry row carries
data-href with its percent-encoded name for the manage-mode JS to use.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: dir_controls 增加管理按钮、CSS、底部操作栏

**Files:**
- Modify: `/home/admin/git/bashttpd/bashttpd:503-633`（`dir_controls`）

- [ ] **Step 1: 写验证命令，确认当前无管理控件**

Run:
```bash
curl -s "http://localhost:8099/myhome/bastest/src/" | grep -c -E 'basManageBtn|basActionBar|bas-selcell input'
```
Expected: `0`。

- [ ] **Step 2: 在 Upload 按钮后插入【管理】按钮**

用 Edit 修改 `dir_controls` 的 HTML。

old_string:
```
<button style="font-family:sans-serif;" onclick="document.getElementById('basFileInput').click()">Upload</button>
<button style="font-family:sans-serif;" onclick="basToggleFavMenu(event)">Favorite</button>
<input id="basFileInput" type="file" multiple style="display:none">
<span id="basStatus" style="font-family:monospace;"></span>
<br>
```
new_string:
```
<button style="font-family:sans-serif;" onclick="document.getElementById('basFileInput').click()">Upload</button>
<button style="font-family:sans-serif;" id="basManageBtn" onclick="basToggleManage()">管理</button>
<button style="font-family:sans-serif;" onclick="basToggleFavMenu(event)">Favorite</button>
<input id="basFileInput" type="file" multiple style="display:none">
<span id="basStatus" style="font-family:monospace;"></span>
<style>
.bas-selcell input{display:none;}
body.bas-manage .bas-selcell input{display:inline-block;}
#basActionBar button{font-family:sans-serif;}
#basActionBar button:disabled{color:#aaa;cursor:default;}
</style>
<div id="basActionBar" style="display:none;position:fixed;left:0;bottom:0;width:100%;box-sizing:border-box;background:#f0f0f0;border-top:1px solid #999;padding:6px 10px;z-index:200;">
  <span style="display:flex;gap:6px;white-space:nowrap;align-items:center;">
    <button onclick="basMkdir()">新文件夹</button>
    <button id="basBtnCopy" onclick="basCopy()">复制</button>
    <button id="basBtnCut" onclick="basCut()">剪切</button>
    <button id="basBtnPaste" onclick="basPaste()">粘贴</button>
    <button id="basBtnDelete" onclick="basDelete()">删除</button>
    <button id="basBtnRename" onclick="basRename()">重命名</button>
  </span>
</div>
<br>
```

- [ ] **Step 3: 语法检查**

Run: `bash -n /home/admin/git/bashttpd/bashttpd && echo SYNTAX_OK`
Expected: `SYNTAX_OK`

- [ ] **Step 4: 重启服务并验证 HTML 标记**

Run:
```bash
pkill -f 'ncat.*8099'; sleep 0.5
cd /home/admin/git/bashttpd && ./start.sh 8099 >/tmp/bashttpd_test.log 2>&1 &
sleep 1
curl -s "http://localhost:8099/myhome/bastest/src/" > /tmp/list3.html
echo "manageBtn:$(grep -c 'id="basManageBtn"' /tmp/list3.html)"
echo "actionBar:$(grep -c 'id="basActionBar"' /tmp/list3.html)"
echo "cssSelcell:$(grep -c '.bas-selcell input{display:none' /tmp/list3.html)"
for id in basBtnCopy basBtnCut basBtnPaste basBtnDelete basBtnRename; do echo "$id:$(grep -c "id=\"$id\"" /tmp/list3.html)"; done
```
Expected: 全部为 `1`。

- [ ] **Step 5: Commit**

```bash
cd /home/admin/git/bashttpd
git add bashttpd
git commit -m "$(cat <<'EOF'
feat(bashttpd): add manage button, CSS and bottom action bar

Adds a 管理/只读 toggle button after Upload, CSS that hides selection
checkboxes until body.bas-manage, and a fixed single-row bottom action
bar (新文件夹/复制/剪切/粘贴/删除/重命名) shown only in manage mode.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: 管理模式交互 JS（切换/ESC/选择/三态全选/计数/按钮启用）

**Files:**
- Modify: `/home/admin/git/bashttpd/bashttpd`（`dir_controls` 内既有 IIFE，末尾 `})();` 之前）

- [ ] **Step 1: 写验证命令，确认当前无管理 JS**

Run:
```bash
curl -s "http://localhost:8099/myhome/bastest/src/" | grep -c -E 'basToggleManage = function|basEnterManage|basSelCount'
```
Expected: `basSelCount` 已有（来自 awk），但 `window.basToggleManage` 函数体计数为 `0`。记录当前值。

- [ ] **Step 2: 在既有 IIFE 末尾插入管理模式 JS**

用 Edit。锚点是 `basAddFav` 函数结束到 IIFE 结束这一段。

old_string:
```
   function basAddFav(cb) {
      status.textContent = 'adding current path to favorites ...';
      fetch(base, { method: 'POST', headers: { 'X-Bas-Action': 'favadd' } })
         .then(function (r) {
            return r.text().then(function (t) {
               status.textContent = r.status + ' ' + t;
               if (cb) cb();
            });
         })
         .catch(function (e) { status.textContent = 'error: ' + e; });
   }
})();
```
new_string:
```
   function basAddFav(cb) {
      status.textContent = 'adding current path to favorites ...';
      fetch(base, { method: 'POST', headers: { 'X-Bas-Action': 'favadd' } })
         .then(function (r) {
            return r.text().then(function (t) {
               status.textContent = r.status + ' ' + t;
               if (cb) cb();
            });
         })
         .catch(function (e) { status.textContent = 'error: ' + e; });
   }

   // ---- File management mode ----
   var manageMode = false;
   function basRows() {
      return Array.prototype.slice.call(document.querySelectorAll('tr[data-href]'));
   }
   function basSelected() {
      return basRows().filter(function (tr) {
         var c = tr.querySelector('.bas-rowchk');
         return c && c.checked;
      });
   }
   function basSelectedNames() {
      return basSelected().map(function (tr) { return tr.getAttribute('data-href'); });
   }
   function basEnable(id, on) {
      var b = document.getElementById(id);
      if (b) b.disabled = !on;
   }
   function basClipGet() {
      try { var s = localStorage.getItem('basClipboard'); return s ? JSON.parse(s) : null; }
      catch (e) { return null; }
   }
   function basClipSet(o) { try { localStorage.setItem('basClipboard', JSON.stringify(o)); } catch (e) {} }
   function basClipClear() { try { localStorage.removeItem('basClipboard'); } catch (e) {} }
   function basUpdateUI() {
      var rows = basRows(), total = rows.length, n = basSelected().length;
      var all = document.getElementById('basSelAll');
      if (all) {
         all.disabled = (total === 0);
         all.checked = (total > 0 && n === total);
         all.indeterminate = (n > 0 && n < total);
      }
      var cnt = document.getElementById('basSelCount');
      if (cnt) cnt.textContent = '(' + n + '/' + total + ')';
      var clip = basClipGet();
      basEnable('basBtnCopy', n >= 1);
      basEnable('basBtnCut', n >= 1);
      basEnable('basBtnDelete', n >= 1);
      basEnable('basBtnRename', n === 1);
      basEnable('basBtnPaste', !!(clip && clip.files && clip.files.length));
   }
   function basEnterManage() {
      manageMode = true;
      document.body.classList.add('bas-manage');
      var b = document.getElementById('basManageBtn'); if (b) b.textContent = '只读';
      var ab = document.getElementById('basActionBar'); if (ab) ab.style.display = 'block';
      try { sessionStorage.setItem('basManage', '1'); } catch (e) {}
   }
   function basExitManage() {
      manageMode = false;
      document.body.classList.remove('bas-manage');
      var b = document.getElementById('basManageBtn'); if (b) b.textContent = '管理';
      var ab = document.getElementById('basActionBar'); if (ab) ab.style.display = 'none';
      basRows().forEach(function (tr) { var c = tr.querySelector('.bas-rowchk'); if (c) c.checked = false; });
      var all = document.getElementById('basSelAll'); if (all) { all.checked = false; all.indeterminate = false; }
      try { sessionStorage.removeItem('basManage'); } catch (e) {}
   }
   window.basToggleManage = function () {
      if (manageMode) basExitManage(); else basEnterManage();
      basUpdateUI();
   };
   function basPostReload(action, headers, body, busyMsg) {
      status.textContent = busyMsg;
      var h = { 'X-Bas-Action': action }, k;
      for (k in headers) { if (Object.prototype.hasOwnProperty.call(headers, k)) h[k] = headers[k]; }
      var opt = { method: 'POST', headers: h };
      if (body != null) { h['Content-Type'] = 'text/plain'; opt.body = body; }
      fetch(base, opt).then(function (r) {
         return r.text().then(function (t) {
            status.textContent = r.status + ' ' + t;
            if (r.ok) setTimeout(function () { location.reload(); }, 800);
            basUpdateUI();
         });
      }).catch(function (e) { status.textContent = 'error: ' + e; });
   }
   window.basCopy = function () {
      var names = basSelectedNames();
      if (!names.length) return;
      basClipSet({ op: 'copy', dir: base, files: names });
      status.textContent = '已复制 ' + names.length + ' 项，去目标目录粘贴';
      basUpdateUI();
   };
   window.basCut = function () {
      var names = basSelectedNames();
      if (!names.length) return;
      basClipSet({ op: 'cut', dir: base, files: names });
      status.textContent = '已剪切 ' + names.length + ' 项，去目标目录粘贴';
      basUpdateUI();
   };
   window.basPaste = function () {
      var clip = basClipGet();
      if (!clip || !clip.files || !clip.files.length) return;
      var body = clip.dir + '\n' + clip.files.join('\n');
      if (clip.op === 'cut') basClipClear();
      basPostReload('paste', { 'X-Bas-Op': clip.op }, body, '粘贴 ' + clip.files.length + ' 项 ...');
   };
   window.basDelete = function () {
      var names = basSelectedNames();
      if (!names.length) return;
      var disp = names.map(function (n) { try { return decodeURIComponent(n); } catch (e) { return n; } });
      if (!confirm('确定删除以下 ' + names.length + ' 项？此操作不可恢复：\n' + disp.join('\n'))) return;
      basPostReload('delete', {}, names.join('\n'), '删除 ' + names.length + ' 项 ...');
   };
   window.basRename = function () {
      var sel = basSelected();
      if (sel.length !== 1) return;
      var enc = sel[0].getAttribute('data-href');
      var cur; try { cur = decodeURIComponent(enc); } catch (e) { cur = enc; }
      var nn = prompt('重命名为:', cur);
      if (nn === null) return;
      if (!nn || /[\/\x00]/.test(nn) || nn === '.' || nn === '..') { status.textContent = '无效名称'; return; }
      basPostReload('rename', { 'X-Bas-Name': enc, 'X-Bas-New-Name': encodeURIComponent(nn) }, null, '重命名 ' + cur + ' -> ' + nn + ' ...');
   };
   function basInitManage() {
      var all = document.getElementById('basSelAll');
      if (all) all.addEventListener('change', function () {
         var ck = all.checked;
         basRows().forEach(function (tr) { var c = tr.querySelector('.bas-rowchk'); if (c) c.checked = ck; });
         basUpdateUI();
      });
      basRows().forEach(function (tr) {
         var c = tr.querySelector('.bas-rowchk');
         if (c) c.addEventListener('change', basUpdateUI);
      });
      document.addEventListener('keydown', function (e) {
         if (e.key === 'Escape' && manageMode) { basExitManage(); basUpdateUI(); }
      });
      try { if (sessionStorage.getItem('basManage') === '1') basEnterManage(); } catch (e) {}
      basUpdateUI();
   }
   if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', basInitManage);
   else basInitManage();
})();
```

- [ ] **Step 3: 语法检查**

Run: `bash -n /home/admin/git/bashttpd/bashttpd && echo SYNTAX_OK`
Expected: `SYNTAX_OK`

- [ ] **Step 4: 重启服务并验证 JS 注入**

Run:
```bash
pkill -f 'ncat.*8099'; sleep 0.5
cd /home/admin/git/bashttpd && ./start.sh 8099 >/tmp/bashttpd_test.log 2>&1 &
sleep 1
curl -s "http://localhost:8099/myhome/bastest/src/" > /tmp/list4.html
for pat in 'window.basToggleManage' 'function basEnterManage' 'function basExitManage' 'window.basCopy' 'window.basCut' 'window.basPaste' 'window.basDelete' 'window.basRename' 'basInitManage' "e.key === 'Escape'"; do
  echo "$pat : $(grep -c "$pat" /tmp/list4.html)"
done
```
Expected: 每项均 `≥1`。

- [ ] **Step 5: Commit**

```bash
cd /home/admin/git/bashttpd
git add bashttpd
git commit -m "$(cat <<'EOF'
feat(bashttpd): add manage-mode JS (toggle, selection, ops)

Implements 管理/只读 toggle (button + ESC), per-row and tri-state
select-all with (X/Y) count, button enable rules, localStorage
clipboard for copy/cut/paste, confirm-guarded delete, single-selection
rename via prompt, and sessionStorage mode persistence across reloads.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: 前后端联调冒烟（curl 模拟前端调用序列）

**Files:** 无改动（纯验证）。若发现问题，回到对应 Task 修复。

- [ ] **Step 1: 模拟"新文件夹"（复用 mkdir）**

Run:
```bash
curl -s -X POST "http://localhost:8099/myhome/bastest/" -H 'X-Bas-Action: mkdir' -H "X-Bas-Name: $(printf %s '新目录' | jq -sRr @uri 2>/dev/null || echo '%E6%96%B0%E7%9B%AE%E5%BD%95')"; echo
ls ~/bastest
```
Expected: `200 created: 新目录`；`ls` 显示 `新目录`。（无 jq 时用后面写死的编码。）

- [ ] **Step 2: 模拟完整 copy→paste→delete→rename 序列**

Run:
```bash
# 准备
rm -rf ~/bastest && mkdir -p ~/bastest/A ~/bastest/B && echo x > ~/bastest/A/x.txt
B="http://localhost:8099/myhome/bastest"
# copy A/x.txt -> B
printf '/myhome/bastest/A\nx.txt\n' | curl -s -X POST "$B/B/" -H 'X-Bas-Action: paste' -H 'X-Bas-Op: copy' --data-binary @-; echo
# rename B/x.txt -> y.txt
curl -s -X POST "$B/B/" -H 'X-Bas-Action: rename' -H 'X-Bas-Name: x.txt' -H 'X-Bas-New-Name: y.txt'; echo
# cut A/x.txt -> B  (target y.txt not conflicting since name is x.txt)
printf '/myhome/bastest/A\nx.txt\n' | curl -s -X POST "$B/B/" -H 'X-Bas-Action: paste' -H 'X-Bas-Op: cut' --data-binary @-; echo
# delete B/y.txt
printf 'y.txt\n' | curl -s -X POST "$B/B/" -H 'X-Bas-Action: delete' --data-binary @-; echo
echo "A:"; ls ~/bastest/A; echo "B:"; ls ~/bastest/B
```
Expected: 四条回复依次为 `pasted 1, skipped 0, failed 0` / `renamed: x.txt -> y.txt` / `pasted 1, skipped 0, failed 0` / `deleted 1, failed 0`；最终 `A` 为空、`B` 只剩 `x.txt`。

- [ ] **Step 3: 若任一步不符预期**

回到对应 Task（1=delete、2=rename、3=paste、6=mkdir 复用）检查代码，修复后重跑本 Task。全部通过再继续。

- [ ] **Step 4: Commit（无代码改动则跳过）**

如本 Task 触发过修复，提交：
```bash
cd /home/admin/git/bashttpd && git add -A && git commit -m "fix(bashttpd): address issues found in manage-mode smoke test

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```
否则不提交。

---

## Task 8: 浏览器手工走查 + 收尾

**Files:** 无改动（验证 + 清理）。

- [ ] **Step 1: 打开目录列表页**

Run:
```bash
rm -rf ~/bastest && mkdir -p ~/bastest/docs && echo a > ~/bastest/one.txt && echo b > ~/bastest/two.txt && echo c > ~/bastest/docs/three.md
echo "浏览: http://localhost:8099/myhome/bastest/"
```
在浏览器打开 `http://localhost:8099/myhome/bastest/`。

- [ ] **Step 2: 走查清单（逐项确认）**

- 只读模式：每行**无**复选框；底部**无**操作栏；Upload 后有【管理】按钮。
- 点【管理】→ 按钮文字变【只读】；每行前出现复选框；页面底部出现一行操作栏，顺序为 `新文件夹 复制 剪切 粘贴 删除 重命名`，且**在一行**。
- 表头最前出现全选框，后面显示 `(0/3)`（one.txt/two.txt/docs 共 3 项，当前目录自身行不计入）。
- 勾选 1 项 → 表头框变为**部分选中**（indeterminate），计数 `(1/3)`；此时【重命名】可用，【复制/剪切/删除】可用，【粘贴】灰（剪贴板空）。
- 勾选 2 项 → 计数 `(2/3)`；【重命名】**灰掉不可点**。
- 点表头全选框 → 全部勾选，框为**全选**态，计数 `(3/3)`；再点 → 全部取消，计数 `(0/3)`。
- 【复制】选中项 → 状态栏提示"已复制 N 项"；进入 `docs/` 子目录 → 【粘贴】可用 → 点击 → 文件出现在 docs 下（copy 不删源）。
- 【剪切】+ 粘贴 → 源目录文件消失（移动）。
- 【删除】→ 弹出 confirm 且**列出文件名** → 确定后文件被删。
- 【重命名】（单选）→ 弹出 prompt **预填当前名** → 改名后列表更新。
- 【新文件夹】→ prompt 输入名 → 新目录出现。
- 管理模式中按 **ESC** → 回到只读模式（复选框/操作栏消失，按钮变回【管理】）。
- 管理模式下执行一次删除（会 reload）→ reload 后**仍处于管理模式**（sessionStorage 生效）。
- 中文文件名：`touch ~/bastest/中文文件.txt` 后刷新，勾选它做重命名/删除，均正常。

- [ ] **Step 3: 记录并修复走查中发现的问题**

若某项不符，定位到对应 Task 的代码修复，`bash -n` 后重启服务重测，并提交修复。

- [ ] **Step 4: 关闭测试服务并清理**

Run:
```bash
pkill -f 'ncat.*8099'; rm -rf ~/bastest /tmp/list*.html /tmp/bashttpd_test.log
echo cleaned
```
Expected: `cleaned`，无残留 8099 进程（`pgrep -f 'ncat.*8099'` 无输出）。

- [ ] **Step 5: 最终语法与提交状态检查**

Run:
```bash
bash -n /home/admin/git/bashttpd/bashttpd && echo SYNTAX_OK
cd /home/admin/git/bashttpd && git status --short && git log --oneline -6
```
Expected: `SYNTAX_OK`；`git status` 干净（无未提交改动）；log 显示 Task 1-6（及可能的修复）提交。

---

## Self-Review 记录

**规格覆盖检查（对照 spec 各节）:**
- §1.1 管理/只读切换按钮 → Task 5（按钮 HTML）+ Task 6（`basToggleManage`/文字切换）。✔
- §1.2 每行复选框、底部一行操作栏、六按钮功能、ESC 退出 → Task 4（复选框单元格）+ Task 5（操作栏一行 flex/nowrap）+ Task 6（ESC、各操作 JS）+ Task 1/2/3（delete/rename/paste 后端）+ mkdir 复用。✔
- §1.2 重命名单选可用/多选灰 → Task 6 `basEnable('basBtnRename', n===1)`。✔
- §1.3 表头三态全选框 + `(X/Y)` → Task 4（`basSelAll`/`basSelCount`）+ Task 6（`basUpdateUI` 三态与计数）。✔
- §4 data-href/selcell/自身行 → Task 4。✔
- §5 sessionStorage 模式保持 + ESC → Task 6。✔
- §6 剪贴板 localStorage、按钮启用规则 → Task 6。✔
- §8 后端三动作 + 两头 → Task 1/2/3。✔
- §9 自身行不可选 → Task 4（`data-self`，无 checkbox）+ Task 6（`basRows` 只选 `tr[data-href]`，自身行无 data-href 自动排除）。✔
- §10 逐项跳过策略 → Task 3（paste skip 计数）；403/400/404 → Task 1/2/3 验证步骤。✔

**占位符扫描:** 无 TBD/TODO；每个代码步骤含完整代码或精确 Edit 锚点；每个验证步骤含确切命令与期望输出。✔

**类型/命名一致性:** `data-href`（awk 产出）↔ `getAttribute('data-href')`（JS）↔ body 行（后端 `urldecode`）一致；`bas-rowchk`/`basSelAll`/`basSelCount`/`bas-selcell`/`bas-manage`/`basManageBtn`/`basActionBar`/`basBtnCopy|Cut|Paste|Delete|Rename` 在 Task 4/5/6 间命名统一；后端 `X-Bas-Op`/`X-Bas-New-Name` 在 Task 1 Step 3 解析、Task 2/3 使用一致；`bas_post_reply`/`resolve_local_dir`/`urldecode` 均为既有函数。✔
