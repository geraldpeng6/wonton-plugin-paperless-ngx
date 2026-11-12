# shellcheck shell=bash
# Paperless-ngx：sso=oidc（allauth）；清单没有 mcp。
# 数据：data_write 建一个带随机标记的标签（POST 要 CSRF 头），标记写进 $SMOKE_STATE（标记文件，data_write 覆盖写），
# data_check 按名字读回；升级和重装都不留应用会话，所以每次都重新登录一遍。
# DRF 的 SessionAuthentication 对写请求查 CSRF：头里的值和 csrftoken Cookie 一致，Referer 指本域。

web_assert() { grep -qi 'paperless'; }   # 标准输入：应用真实页面

paperless_base() {
  printf '%s' "${SMOKE_WEB_URL%/}"   # 网关 web_url 带尾斜杠，直接拼会得到 //accounts/...，拿不到真实页面
}

# 走完浏览器式 OIDC（allauth 的 SOCIALACCOUNT_LOGIN_ON_GET 默认关，provider 登录是确认页 + POST；
# 已登录时 /accounts/login/ 会 302 走，没有 CSRF 域，token 要从 provider 登录页取）→
# 302 到 Hydra（核心会话自动登录）→ 回调建应用会话。数据钩子跑在第一次会话建立之前，
# 进来先用 dweb 建核心会话（网关只认核心会话；核心会话 Cookie 要落在插件主机上，少一步后面全是 401）。
paperless_login() {
  local base page tok
  base="$(paperless_base)"
  # 首页 GET 会停在 provider 确认页（SOCIALACCOUNT_LOGIN_ON_GET 默认关，GET 不建会话），
  # 真正登录是下面这次带 CSRF 的 POST。
  dweb --fresh / >/dev/null || { echo "登录跳转走不通，建不了核心会话"; return 1; }
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
  printf '%s\n' "$marker" >"$SMOKE_STATE"
}

data_check() {
  local base marker resp
  base="$(paperless_base)"
  marker="$(cat "$SMOKE_STATE" 2>/dev/null)"
  [[ -n "$marker" ]] || { echo "SMOKE_STATE 里没有 data_write 留下的标记"; return 1; }
  paperless_login || return 1
  resp="$(curl -sS --noproxy '*' --fail-with-body -b "${SMOKE_JAR:-}" -H 'Accept: application/json' \
    "$base/api/tags/?name__iexact=$marker")" || { echo "读标签失败：$resp"; return 1; }
  jq -e --arg n "$marker" 'any(.results[]; .name == $n)' <<<"$resp" >/dev/null ||
    { echo "标记标签不见了：$(head -c 200 <<<"$resp")"; return 1; }
}

extra_check() { # 发信端到端：应用自己的「文档发邮件」把一封真实邮件发给用户内部邮箱（应用自己的发信路径），
	# 然后等核心把它投进用户的「Wonton」私聊（直接读通知房的消息，投递的最终证据）。
	local base marker csrf doc resp to wp mail
	base="$(paperless_base)"
	to="$SMOKE_OWNER_EMAIL"
	paperless_login || { echo "登录链没建立应用会话"; return 1; }
	csrf="$(paperless_csrf)"
	[[ -n "$csrf" ]] || { echo "登录后没有 csrftoken Cookie"; return 1; }
	# 传一个带标记标题的文档（消费是异步的，轮询到入库为止），再用应用的邮件接口发给用户。
	marker="wonton-smoke-$(head -c8 /dev/urandom | od -An -tx1 | tr -d ' \n')"
	mail="$(mktemp)"
	printf 'wonton smoke mail probe %s' "$marker" >"$mail"
	resp="$(curl -sS --noproxy '*' --fail-with-body -b "${SMOKE_JAR:-}" -e "$base/" \
		-H "X-CSRFToken: $csrf" -H 'Accept: application/json' \
		-F "document=@$mail" -F "title=$marker" \
		"$base/api/documents/post_document/")" ||
		{ rm -f "$mail"; echo "传文档失败：$(head -c 200 <<<"$resp")"; return 1; }
	for _ in 1 2 3 4 5 6 7 8 9 10; do
		doc="$(curl -sS --noproxy '*' --fail-with-body -b "${SMOKE_JAR:-}" -H 'Accept: application/json' \
			"$base/api/documents/")" || { rm -f "$mail"; echo "列文档失败：$(head -c 200 <<<"$doc")"; return 1; }
		doc="$(jq -r --arg m "$marker" '[.results[] | select(.title == $m)][0].id // empty' <<<"$doc")"
		[[ -n "$doc" ]] && break
		sleep 5
	done
	rm -f "$mail"
	[[ -n "$doc" ]] || { echo "文档 50 秒没入库（标题 $marker）"; return 1; }
	# 等待先挂后台再触发（模板的用法）：信进私聊是秒级投递，先等后发才等得到；标记在主题里，旧信不会误配。
	probes_owner_room_wait 120 "$marker" & wp=$!
	resp="$(curl -sS --noproxy '*' --fail-with-body -b "${SMOKE_JAR:-}" -e "$base/" \
		-H "X-CSRFToken: $csrf" -H 'Content-Type: application/json' -H 'Accept: application/json' \
		-d "$(jq -cn --arg to "$to" --arg m "$marker" --argjson d "$doc" \
			'{documents:[$d],addresses:$to,subject:("wonton smoke "+$m),message:("wonton smoke mail probe "+$m)}')" \
		"$base/api/documents/email/")" ||
		{ kill "$wp" 2>/dev/null; wait "$wp" 2>/dev/null; echo "发信接口失败：$(head -c 200 <<<"$resp")"; return 1; }
	grep -q 'Email sent\|sent' <<<"$resp" || { kill "$wp" 2>/dev/null; wait "$wp" 2>/dev/null; echo "应用报发送失败：$(head -c 200 <<<"$resp")"; return 1; }
	# 核心把信投进用户的「Wonton」私聊：房里出现这一封（标记在主题里）。
	wait "$wp" || { echo "文档邮件 120 秒没出现在用户的 Wonton 私聊（房里没这封信）"; return 1; }
	echo "文档邮件已进用户的 Wonton 私聊（Paperless-ngx：wonton smoke $marker）"
}
