# 云吞插件：Paperless-ngx 文档管理

开发流程见[插件开发指南](https://github.com/wontonapp/wonton-docs/blob/main/develop.md)。

[Paperless-ngx](https://docs.paperless-ngx.com/) 做成插件：扫描件、照片和 PDF 上传后 OCR（中文、英文），
按往来方、标签和保存路径归档，全文搜索。原件、OCR 件和索引在数据目录 `${WONTON_APP_DATA}/{data,media}`，批量导入往
宿主上的 `${WONTON_APP_DATA}/data/consume` 放文件（导入后原文件会删掉）。

应用发的信（找回密码、把文档发给家里人）走核心的内部邮箱，会出现在收件人的 Wonton 私聊里；外部邮箱收不到，会发送失败。

## 图标来源与许可

`icon.png` 使用 Paperless-ngx v3.4.0 的官方叶片标志，未用图片模型生成；来源、版权、处理方式、上游 GPL-3.0 全文和商标说明见 [NOTICE](NOTICE)。
可编辑源文件是 [`icon.svg`](icon.svg)，导出命令：
`rsvg-convert --width 512 --height 512 --output icon.png icon.svg`。
插件包自己的许可见 [LICENSE](LICENSE)。

## 先跑起来
## 核心升级

核心升级时容器会按新的签发方自动重建，不用重装；账号按已有的身份记录认回原账号，数据不动。

## 先跑起来

```bash
scripts/dev.sh up
scripts/dev.sh install
```

`up` 在本机起一套云吞并打印它的地址，用 `scripts/dev.sh token` 输出的用户令牌登录；`install` 列出插件要的权限，确认后
装上并打印插件网页的地址，打开直接经核心身份提供方登录（`sso: oidc`），不用再登录一次。

## 仓库里有什么

| 路径 | 内容 |
| --- | --- |
| `docker-compose.yml` | 插件本身：compose 加上 `x-wonton` 清单 |
| `icon.svg`、`web/` | 清单和 compose 引用的文件：图标、交给容器的配置和网页 |
| `screenshots/` | 商店详情页里的截图 |
| `scripts/check.sh` | 检查插件包，规则和安装时一样 |
| `scripts/dev.sh` | 开发环境：起一套云吞，装、重装、卸载插件，看日志 |
| `scripts/smoke-probes.sh` | `scripts/dev.sh smoke` 对这个插件逐项的探测 |
| `scripts/publish.sh` | 发布一个版本：构建自己的镜像、按摘要写回、打 tag、推送 |
| `AGENTS.md` | 给人和 AI 编程代理的规则 |
| `LICENSE`、`NOTICE` | 插件许可证、上游 GPL-3.0 许可证和商标声明 |
