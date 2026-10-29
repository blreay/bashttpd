# 文件管理模式 — 设计文档

日期：2026-10-29
项目：bashttpd（单文件 bash HTTP 服务器）
方案：B（awk 注入 data 属性 + 前端 JS 切换 + 后端新增 POST 动作）

## 1. 目标

在现有目录浏览页面上增加一个"管理模式"，支持多选文件/文件夹并进行常见文件操作：

1. 【上传文件】按钮后增加一个模式切换按钮：只读模式下显示【管理】，点击进入管理模式；管理模式下显示【只读】，点击回到只读模式。
2. 管理模式下：
   - 每行前面出现复选框，可多选文件/文件夹。
   - 页面最下端出现一排按钮（务必一行）：新文件夹、复制、剪切、粘贴、删除、重命名。重命名仅在恰好选中 1 项时可用，选中多项时灰掉不可点。
   - 按 ESC 键回到只读模式（点【只读】按钮同样退出）。
3. 管理模式下表头前面出现一个全选框，点击可【全部选中】/【全部取消选中】；其状态随选择变化呈现【全部选中】【部分选中】【0 选中】三态；框后显示 `(X/Y)` 表示选中数/可选总数。

## 2. 约束与既有架构

- bashttpd 每个连接都是新进程，服务器内存无法跨请求保持状态 → 剪贴板存在浏览器 localStorage。
- 目录列表由 `serve_dir_with_tree()` 调 `tree -H` 后经 awk 改写成 HTML 表格；控件（CreateDir/Upload/Favorite 按钮 + 内联 `<script>`）由 `dir_controls()` 输出，经 awk 的 `BAS_CONTROLS` 注入。
- 已有 POST 框架：前端 fetch 带 `X-Bas-Action` / `X-Bas-Name` 头，底部 `case "$X_BAS_ACTION"` 分发到 `bas_do_mkdir` / `bas_do_upload` / `bas_do_favlist` / `bas_do_favadd`；统一用 `bas_post_reply CODE MSG [BODY]` 回复并退出；`resolve_local_dir URI` 把 URI 映射到本地目录并内置路径穿越防护。
- 不新增文件，改动集中在 `bashttpd` 的三处。

## 3. tree 输出实测（用于确定文件名提取方式）

`tree -H "/myhome/work" ... -L 1` 的条目行形如：

```
├── [drwxr-xr-x&nbsp;admin&nbsp;...&nbsp;Oct&nbsp;29&nbsp;18:34]&nbsp;&nbsp;&nbsp;&nbsp;<a href="/myhome/work/subdir/">subdir</a><br>
└── [-rw-r--r--&nbsp;admin&nbsp;...&nbsp;0&nbsp;Oct&nbsp;29&nbsp;18:34]&nbsp;&nbsp;&nbsp;&nbsp;<a href="/myhome/work/%E4%B8%AD%E6%96%87%E5%90%8D.md">中文名.md</a><br>
```

- `href` 是完整 URI 路径，百分号编码，目录带尾 `/`。
- 条目名 = href 去掉尾 `/` 后取最后一段（百分号编码）→ 正是后端 `urldecode` 所需格式。
- 第一行是当前目录自身（`href="/myhome/work/"`），需排除，见 §9。

## 4. 组件 1：表格行改造（awk in serve_dir_with_tree）

- 每行 `<tr>` 增加 `data-href="<编码名>"`（取 href 去尾斜杠后的最后一段）。
- 每行最前增加单元格：`<td class="bas-selcell"><input type="checkbox" class="bas-rowchk"></td>`。
- 表头行最前增加：`<td class="bas-selcell"><input type="checkbox" id="basSelAll"></td>`。
- 当前目录自身那一行（href == base，见 §9）：不加复选框、不计入可选总数、`data-self="1"`。
- 复选框始终存在于 DOM，靠 CSS 显隐：`body` 无 `bas-manage` class 时 `.bas-selcell input{display:none}`，有时 `display:inline`。切换模式只切一个 class，无需重渲染。

## 5. 组件 2：模式切换按钮与状态（dir_controls 的 HTML/JS）

- Upload 按钮后加 `<button id="basManageBtn">管理</button>`。
- 点击切换 `manageMode`：
  - 进入：`body.classList.add('bas-manage')`；按钮文字→【只读】；显示底部操作栏；`sessionStorage['basManage']='1'`。
  - 退出：移除 class；按钮文字→【管理】；隐藏操作栏；清空所有选中；`sessionStorage.removeItem('basManage')`。
- 模式存 `sessionStorage`，操作后 `location.reload()` 仍停留管理模式；页面加载时读取它恢复模式。
- ESC 键（`keydown`，`e.key==='Escape'`）退出管理模式。

## 6. 组件 3：底部操作栏（一行，仅管理模式可见）

按钮顺序：`新文件夹 | 复制 | 剪切 | 粘贴 | 删除 | 重命名`；用 `display:flex; white-space:nowrap` 固定于页面底部一行。

- 新文件夹：prompt 输入名 → POST `mkdir`（复用 `bas_do_mkdir`）。
- 复制：选中项写入 localStorage 剪贴板 `{op:'copy', dir:当前URI, files:[编码名...]}`；状态栏提示"已复制 N 项，去目标目录粘贴"。
- 剪切：同上，`op:'cut'`。
- 粘贴：读剪贴板 → POST `paste`（目标=当前目录；body 第一行=源目录 URI，其余行=编码名；op 走 `X-Bas-Op` 头）；剪切粘贴成功后清空剪贴板。
- 删除：confirm 列出将删除的名字 → POST `delete`（body 每行一个编码名）。
- 重命名：仅当恰好选中 1 项时可用；prompt 预填当前名 → POST `rename`（`X-Bas-Name`=旧名，`X-Bas-New-Name`=新名）。

按钮启用规则（选中变化时实时刷新）：
- 复制/剪切/删除：≥1 选中才可用。
- 重命名：=1 选中才可用，否则灰掉（`disabled`）。
- 粘贴：剪贴板非空才可用。
- 新文件夹：管理模式下始终可用。

## 7. 组件 4：表头全选框

- 三态：全选（`checked`）、部分选中（`indeterminate=true`）、0 选中（`unchecked`）。
- 点击：未全选→全选所有可选行；已全选→全不选。
- 框后显示 `(X/Y)`：X=已选数，Y=可选行总数（不含自身行），随选择实时更新。
- 任一复选框变化都重算表头三态与 `(X/Y)`。

## 8. 后端动作（新增 3 个 + 2 个头）

请求头解析处新增读取：`X-Bas-New-Name`、`X-Bas-Op`。
`case "$X_BAS_ACTION"` 新增分支：`delete` / `rename` / `paste`。

共用校验：名字以百分号编码传输，后端 `urldecode` 后必须非空、不含 `/`、不是 `.` 或 `..`；目录一律经 `resolve_local_dir` 解析（已防穿越）。

- `bas_do_delete`：读 `BODY_FILE` 每行一个编码名 → 逐个 `rm -rf "$dir/$name"`；返回成功/失败汇总。
- `bas_do_rename`：`X-Bas-Name`=旧名，`X-Bas-New-Name`=新名；目标已存在→403；否则 `mv "$dir/$old" "$dir/$new"`。
- `bas_do_paste`：`X-Bas-Op`=copy|cut；body 第一行=源目录 URI（编码），其余行=编码名；源目录经 `resolve_local_dir` 解析，目标目录=当前 `REQUEST_URI` 解析结果；逐个 `cp -a`（copy）或 `mv`（cut）；某项目标已存在→跳过该项、继续其余项，并在汇总消息里报告（策略见 §10）。

## 9. 边界情况

- 当前目录自身行：`href` 等于 base（去尾斜杠后与传入 tree 的 `${2%/}` 一致）。该行 `data-self="1"`，不加复选框、不计入 Y、不可选中，避免误删/误改当前目录本身。
- 中文/Unicode 文件名：href 已百分号编码，全链路保持编码，后端 `urldecode`。
- 粘贴到源目录自身：copy 会因目标已存在而报错/跳过；cut 到自身为无操作，汇总里说明。
- 空目录：Y=0，全选框禁用，`(0/0)`。

## 10. 错误处理

- 沿用 `bas_post_reply CODE MSG` + 前端 `status.textContent = CODE + ' ' + text`。
- 名字非法→400；`resolve_local_dir` 失败→500；rename/paste 目标已存在→403；fs 操作失败→500。
- 粘贴多文件的"目标已存在"策略：**逐项处理**，存在的项跳过并计入汇总消息，不中断其余项（保持与批量上传/删除一致的"尽量做完"语义）。
- 前端：无选中或剪贴板空时对应按钮 `disabled`，点击无副作用。

## 11. 测试

- `bash -n bashttpd` 语法检查。
- `./start.sh` 起服务；`curl` 一个目录列表，`grep` 确认：`data-href`、表头全选框 `id="basSelAll"`、行复选框 `class="bas-rowchk"`、底部操作栏 HTML、【管理】按钮均存在；确认自身行带 `data-self="1"` 且无复选框。
- 浏览器手工走查：
  - 管理/只读切换、按钮文字变化、ESC 退出、刷新后模式保持。
  - 单选/多选/全选三态与 `(X/Y)` 计数。
  - 新文件夹、复制→跨目录粘贴、剪切→粘贴（剪贴板清空）、删除（confirm 列表）、重命名（单选可用/多选灰掉）。
  - 重名粘贴/重命名的 403 提示。
- 边界：中文文件名、嵌套目录、空目录、粘贴到自身目录。

## 12. 非目标（YAGNI）

- 不做拖拽移动、不做上传进度条增强、不做多选重命名、不做服务器端剪贴板、不改 `ls` 纯文本回退路径（仅 tree 路径支持管理模式）。
