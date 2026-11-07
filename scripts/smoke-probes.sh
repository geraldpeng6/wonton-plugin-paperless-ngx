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

data_write() {
  local base marker csrf resp
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
  printf '%s\n' "$marker" >"${SMOKE_STATE:?}"
}

data_check() {
  local base marker resp
  base="$(paperless_base)"
  marker="$(cat "${SMOKE_STATE:-}" 2>/dev/null)"
  [[ -n "$marker" ]] || { echo "SMOKE_STATE 标记文件是空的（data_write 没跑过？）"; return 1; }
  paperless_login || return 1
  resp="$(curl -sS --noproxy '*' --fail-with-body -b "${SMOKE_JAR:-}" -H 'Accept: application/json' \
    "$base/api/tags/?name__iexact=$marker")" || { echo "读标签失败：$resp"; return 1; }
  jq -e --arg n "$marker" 'any(.results[]; .name == $n)' <<<"$resp" >/dev/null ||
    { echo "标记标签不见了：$(head -c 200 <<<"$resp")"; return 1; }
}
