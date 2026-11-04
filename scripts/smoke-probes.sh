# Paperless-ngx：sso=oidc（allauth）；清单没有 mcp。
SSO=oidc
MCP=0

web_assert() { grep -qi 'paperless'; }   # 标准输入：应用真实页面

# 走完浏览器式 OIDC：allauth 登录页取 CSRF → POST provider 登录 → Hydra（核心会话自动登录）→
# 应用回调建会话 → 用应用自己的用户接口确认认出来的是用户超管。
identity_check() {
  local page tok users
  page="$(curl -sS --noproxy '*' -b "$SMOKE_JAR" -c "$SMOKE_JAR" "$SMOKE_WEB_URL/accounts/login/?next=/")" ||
    { echo "取登录页失败"; return 1; }
  tok="$(grep -oE 'name="csrfmiddlewaretoken" value="[^"]+"' <<<"$page" | sed 's/.*value="//; s/"//' | head -1)"
  [[ -n "$tok" ]] || { echo "登录页没有 CSRF token"; return 1; }
  curl -sS --noproxy '*' -o /dev/null -L -b "$SMOKE_JAR" -c "$SMOKE_JAR" \
    -e "$SMOKE_WEB_URL/accounts/login/?next=/" \
    --data-urlencode "csrfmiddlewaretoken=$tok" \
    "$SMOKE_WEB_URL/accounts/oidc/wonton/login/?process=&next=%2F" || { echo "OIDC 登录链失败"; return 1; }
  users="$(web_get /api/users/ -H 'Accept: application/json')" || { echo "GET /api/users/ 失败：$users"; return 1; }
  jq -e --arg u "$SMOKE_OWNER" 'any(.results[]; .username == $u and .is_superuser == true)' <<<"$users" >/dev/null ||
    { echo "用户列表里没有用户超管：$users"; return 1; }
}
