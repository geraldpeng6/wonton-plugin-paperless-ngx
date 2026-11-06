# shellcheck shell=bash
# Paperless-ngx：sso=oidc（allauth）；清单没有 mcp。

web_assert() { grep -qi 'paperless'; }   # 标准输入：应用真实页面

# 走完浏览器式 OIDC（allauth 的 SOCIALACCOUNT_LOGIN_ON_GET 默认关，provider 登录是确认页 + POST；
# 已登录时 /accounts/login/ 会 302 走，没有 CSRF 域，token 要从 provider 登录页取）→
# 302 到 Hydra（核心会话自动登录）→ 回调建会话 → 用应用自己的用户接口确认认出来的是用户超管。
identity_check() {
  local page tok users base
  base="${SMOKE_WEB_URL%/}"   # 网关 web_url 带尾斜杠，直接拼会得到 //accounts/...，拿不到真实页面
  page="$(curl -sS --noproxy '*' -b "$SMOKE_JAR" -c "$SMOKE_JAR" "$base/accounts/oidc/wonton/login/")" ||
    { echo "取 provider 登录页失败"; return 1; }
  tok="$(grep -oE 'name="csrfmiddlewaretoken" value="[^"]+"' <<<"$page" | sed 's/.*value="//; s/"//' | head -1)"
  [[ -n "$tok" ]] || { echo "provider 登录页没有 CSRF token"; return 1; }
  curl -sS --noproxy '*' -o /dev/null -L -b "$SMOKE_JAR" -c "$SMOKE_JAR" \
    -e "$base/accounts/oidc/wonton/login/" \
    --data-urlencode "csrfmiddlewaretoken=$tok" \
    "$base/accounts/oidc/wonton/login/" || { echo "OIDC 登录链失败"; return 1; }
  # 不用套件的 web_get：它把路径拼在带尾斜杠的 SMOKE_WEB_URL 后面，同样会出 //api/...
  users="$(curl -sS --noproxy '*' --fail-with-body -b "$SMOKE_JAR" -H 'Accept: application/json' "$base/api/users/")" ||
    { echo "GET /api/users/ 失败：$users"; return 1; }
  jq -e --arg u "$SMOKE_OWNER" 'any(.results[]; .username == $u and .is_superuser == true)' <<<"$users" >/dev/null ||
    { echo "用户列表里没有用户超管：$users"; return 1; }
}
