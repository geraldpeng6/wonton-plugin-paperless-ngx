# shellcheck shell=bash
# Paperless-ngx：sso=oidc（allauth）；清单没有 mcp。
# 数据：data_write 建一个带随机标记的标签（POST 要 CSRF 头），标记写进 $SMOKE_STATE（标记文件，data_write 覆盖写），
# data_check 按名字读回；升级和重装都不留应用会话，所以每次都重新登录一遍。
# DRF 的 SessionAuthentication 对写请求查 CSRF：头里的值和 csrftoken Cookie 一致，Referer 指本域。

web_assert() { grep -qi 'paperless'; }   # 标准输入：应用真实页面

paperless_base() {
  printf '%s' "${SMOKE_WEB_URL%/}"   # 网关 web_url 带尾斜杠，直接拼会得到 //accounts/...，拿不到真实页面
}

# 核心会话 Cookie：数据钩子跑在第一次会话建立之前，自己登录（网关只认核心会话）。
smoke_core_login() { # <jar> <插件地址>：先拿核心会话 Cookie，再走一次插件首页的登录跳转——
  # 网关的会话 Cookie 要落在插件主机上，应用的登录链和接口才认（两步都要，少一步后面全是 401）。
  local base token
  base="${E2E_BASE:-${SMOKE_BASE:-}}"
  token="${E2E_TOKEN:-${SMOKE_TOKEN:-}}"
  [[ -n "$base" && -n "$token" && -n "${2:-}" ]] || { echo "没有核心地址、主人令牌或插件地址"; return 1; }
  curl -sS --noproxy '*' -o /dev/null -b "$1" -c "$1" \
    --data-urlencode "token=$token" "$base/_wonton/login" &&
    curl -sS --noproxy '*' -o /dev/null -L -b "$1" -c "$1" -H 'Accept: text/html' "${2%/}/"
}

# 走完浏览器式 OIDC（allauth 的 SOCIALACCOUNT_LOGIN_ON_GET 默认关，provider 登录是确认页 + POST；
# 已登录时 /accounts/login/ 会 302 走，没有 CSRF 域，token 要从 provider 登录页取）→
# 302 到 Hydra（核心会话自动登录）→ 回调建应用会话。冒烟的数据钩子跑在第一次会话建立之前，进来先建核心会话。
paperless_login() {
  local base page tok
  base="$(paperless_base)"
  # 首页 GET 会停在 provider 确认页（SOCIALACCOUNT_LOGIN_ON_GET 默认关，GET 不建会话），
  # 真正登录是下面这次带 CSRF 的 POST。
  smoke_core_login "${SMOKE_JAR:-}" "$base" || return 1
  page="$(curl -sS --noproxy '*' -b "${SMOKE_JAR:-}" -c "${SMOKE_JAR:-}" "$base/accounts/oidc/wonton/login/")" ||
    { echo "取 provider 登录页失败"; return 1; }
  tok="$(grep -oE 'name="csrfmiddlewaretoken" value="[^"]+"' <<<"$page" | sed 's/.*value="//; s/"//' | head -1)"
  if [[ -n "$tok" ]]; then
    curl -sS --noproxy '*' -o /dev/null -L -b "${SMOKE_JAR:-}" -c "${SMOKE_JAR:-}" \
      -e "$base/accounts/oidc/wonton/login/" --data-urlencode "csrfmiddlewaretoken=$tok" \
      "$base/accounts/oidc/wonton/login/" || { echo "OIDC 登录链失败"; return 1; }
  elif [[ -z "$(paperless_csrf)" ]]; then
    # 已经登录时 provider 页 302，没有 CSRF 域；注销确认页照常渲染表单，用它把 csrftoken 拿下来。
    curl -sS --noproxy '*' -o /dev/null -b "${SMOKE_JAR:-}" -c "${SMOKE_JAR:-}" "$base/accounts/logout/"
  fi
}
# csrftoken Cookie 的值（Cookie 罐是 Netscape 格式，第 6 列是名字、第 7 列是值）。
paperless_csrf() {
  awk -F'\t' '$6 == "csrftoken" { print $7 }' "${SMOKE_JAR:?}" | tail -1
}

identity_check() {
  local base users
  base="$(paperless_base)"
  paperless_login || return 1
  # 不用套件的 web_get：它把路径拼在带尾斜杠的 SMOKE_WEB_URL 后面，同样会出 //api/...
  users="$(curl -sS --noproxy '*' --fail-with-body -b "${SMOKE_JAR:-}" -H 'Accept: application/json' "$base/api/users/")" ||
    { echo "GET /api/users/ 失败：$users"; return 1; }
  jq -e --arg u "$SMOKE_OWNER" 'any(.results[]; .username == $u and .is_superuser == true)' <<<"$users" >/dev/null ||
    { echo "用户列表里没有用户超管：$users"; return 1; }
}

marker_file() { # SMOKE_STATE 在冒烟套件里是目录、在 e2e 里是文件，标记放它旁边，两种都能用
	if [[ -d "$SMOKE_STATE" ]]; then
		printf '%s' "$SMOKE_STATE/paperless-marker"
	else
		printf '%s' "${SMOKE_STATE}.paperless-marker"
	fi
}

data_write() {
  local base marker resp
  base="$(paperless_base)"
  paperless_login || return 1
  csrf="$(paperless_csrf)"
  [[ -n "$csrf" ]] || { echo "登录后没有 csrftoken Cookie"; return 1; }
  marker="wonton-smoke-$(head -c8 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  resp="$(curl -sS --noproxy '*' --fail-with-body -b "${SMOKE_JAR:-}" -e "$base/" \
    -H "X-CSRFToken: $csrf" -H 'Content-Type: application/x-www-form-urlencoded' -H 'Accept: application/json' \
    --data-urlencode "name=$marker" "$base/api/tags/")" || { echo "建标签失败：$resp"; return 1; }
  jq -e --arg n "$marker" '.name == $n' <<<"$resp" >/dev/null 2>&1 ||
    { echo "标签没建成：$(head -c 200 <<<"$resp")"; return 1; }
  printf '%s\n' "$marker" >"$(marker_file)"
}

data_check() {
  local base marker resp
  base="$(paperless_base)"
  marker="$(cat "$(marker_file)" 2>/dev/null)"
  [[ -n "$marker" ]] || { echo "SMOKE_STATE 标记文件是空的（data_write 没跑过？）"; return 1; }
  paperless_login || return 1
  resp="$(curl -sS --noproxy '*' --fail-with-body -b "${SMOKE_JAR:-}" -H 'Accept: application/json' \
    "$base/api/tags/?name__iexact=$marker")" || { echo "读标签失败：$resp"; return 1; }
  jq -e --arg n "$marker" 'any(.results[]; .name == $n)' <<<"$resp" >/dev/null ||
    { echo "标记标签不见了：$(head -c 200 <<<"$resp")"; return 1; }
}

# ---------- 发信（notify，规范 0.11）----------
pl_core() { # 核心容器：Mailpit 的别名和 API 密码都在它的网络上/数据目录里
	docker ps --format '{{.Names}}' | grep -xE "wonton-${SMOKE_INSTANCE:-}--core" | head -1
}

pl_mailpit() { # <path>：调 Mailpit API（basic core:<密码>）。主路照核心自己的冒烟：在核心网络里
	# 打 mailpit.wonton.internal:8025；兜底用应用容器的 wget（它的网络里也有这个别名）。
	local core pw dd out webc
	core="$(pl_core)" || return 1
	if declare -F read_env >/dev/null; then dd="$(read_env WONTON_DATA_DIR)"; else dd="$(probes_setting WONTON_DATA_DIR)"; fi
	pw="$(docker exec "$core" cat "$dd/core/mailpit/api-password" 2>/dev/null)"
	[[ -n "${pw:-}" ]] || { echo "读不到 Mailpit API 密码（核心数据目录 core/mailpit/api-password）"; return 1; }
	out="$(docker run --rm --network "container:$core" curlimages/curl:8.23.0 \
		-s -u "core:$pw" "http://mailpit.wonton.internal:8025$1" 2>&1)"
	if jq -e '.messages' <<<"$out" >/dev/null 2>&1 || [[ "$out" == "{"* ]]; then
		printf '%s' "$out"; return 0
	fi
	webc="$(docker ps --format '{{.Names}}' | grep "$SMOKE_INSTANCE" | grep 'paperless' | head -1)"
	[[ -n "$webc" ]] || { echo "Mailpit 主路没拿到 JSON：$(head -c 200 <<<"$out")"; return 1; }
	docker exec "$webc" wget -qO- --header "Authorization: Basic $(printf 'core:%s' "$pw" | base64 | tr -d '\n')" \
		"http://smtp.wonton.internal:8025$1" 2>&1
}

pl_mailpit_wait() { # <from> <to> [次数=20]：等一封 From/To 对上的信进 Mailpit
	local from="$1" to="$2" n="${3:-20}" i out
	for ((i = 0; i < n; i++)); do
		out="$(pl_mailpit "/api/v1/messages?limit=100")" || { sleep 3; continue; }
		jq -e --arg f "$from" --arg t "$to" \
			'.messages | any(.From.Address == $f and any(.To[]; .Address == $t))' <<<"$out" >/dev/null 2>&1 && return 0
		sleep 3
	done
	return 1
}

pl_mailpit_wait_gone() { # <to> [次数=20]：等收件人的信从 Mailpit 里消失（核心投进私聊后会把信删掉）
	local to="$1" n="${2:-20}" i out
	for ((i = 0; i < n; i++)); do
		out="$(pl_mailpit "/api/v1/messages?limit=100")" || { sleep 3; continue; }
		jq -e --arg t "$to" '(.messages | map(select(.To[].Address == $t)) | length) == 0' <<<"$out" >/dev/null 2>&1 && return 0
		sleep 3
	done
	return 1
}

extra_check() { # 发信端到端：应用自己的「文档发邮件」把一封真实邮件发进内部邮箱，核心投进主人私聊后取走删除
	local base marker csrf doc resp to
	base="$(paperless_base)"
	to="${SMOKE_OWNER:-owner}@wonton.internal"
	paperless_login || { echo "登录链没建立应用会话"; return 1; }
	csrf="$(paperless_csrf)"
	[[ -n "$csrf" ]] || { echo "登录后没有 csrftoken Cookie"; return 1; }
	# 传一个带标记标题的文档（消费是异步的，轮询到入库为止），再用应用的邮件接口发给主人。
	marker="wonton-mail-$(head -c8 /dev/urandom | od -An -tx1 | tr -d ' \n')"
	printf 'wonton e2e mail probe %s' "$marker" >"$(marker_file).mail"
	resp="$(curl -sS --noproxy '*' --fail-with-body -b "${SMOKE_JAR:-}" -e "$base/" \
		-H "X-CSRFToken: $csrf" -H 'Accept: application/json' \
		-F "document=@$(marker_file).mail" -F "title=$marker" \
		"$base/api/documents/post_document/")" ||
		{ echo "传文档失败：$(head -c 200 <<<"$resp")"; return 1; }
	for _ in 1 2 3 4 5 6 7 8 9 10; do
		doc="$(curl -sS --noproxy '*' --fail-with-body -b "${SMOKE_JAR:-}" -H 'Accept: application/json' \
			"$base/api/documents/")" || { echo "列文档失败：$(head -c 200 <<<"$doc")"; return 1; }
		doc="$(jq -r --arg m "$marker" '[.results[] | select(.title == $m)][0].id // empty' <<<"$doc")"
		[[ -n "$doc" ]] && break
		sleep 5
	done
	[[ -n "$doc" ]] || { echo "文档 50 秒没入库（标题 $marker）"; return 1; }
	resp="$(curl -sS --noproxy '*' --fail-with-body -b "${SMOKE_JAR:-}" -e "$base/" \
		-H "X-CSRFToken: $csrf" -H 'Content-Type: application/json' -H 'Accept: application/json' \
		-d "$(jq -cn --arg to "$to" --arg m "$marker" --argjson d "$doc" \
			'{documents:[$d],addresses:$to,subject:("wonton e2e "+$m),message:("wonton e2e mail probe "+$m)}')" \
		"$base/api/documents/email/")" ||
		{ echo "发信接口失败：$(head -c 200 <<<"$resp")"; return 1; }
	grep -q 'Email sent\|sent' <<<"$resp" || { echo "应用报发送失败：$(head -c 200 <<<"$resp")"; return 1; }
	# 信进内部邮箱：From 是 WONTON_MAIL_FROM（com.paperless-ngx.paperless-ngx@plugins.wonton.internal）。
	pl_mailpit_wait "com.paperless-ngx.paperless-ngx@plugins.wonton.internal" "$to" 20 ||
		{ echo "邮件 60 秒没进 Mailpit：$(pl_mailpit '/api/v1/messages?limit=5' | head -c 300)"; return 1; }
	echo "文档邮件已进内部邮箱（To=$to）"
	# 核心投进收件人私聊后把信从 Mailpit 删掉：信箱里没有这封信 = 已投递。
	pl_mailpit_wait_gone "$to" 20 ||
		{ echo "邮件一直留在 Mailpit：核心没把它投进主人私聊（投完才会删）"; return 1; }
	echo "核心已把信投进主人的 Wonton 私聊（Mailpit 里已删除）"
}
