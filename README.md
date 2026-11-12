# 🐔 EUSERV 德鸡自动续期脚本

[![](https://img.shields.io/badge/Language-Python-blue.svg)](https://www.python.org/)
[![](https://img.shields.io/badge/Deployment-GitHub_Actions-orange.svg)]()
[![](https://img.shields.io/badge/Deployment-VPS-green.svg)]()

由于 EUserv 免费主机需要每月手动续期，本项目旨在实现**全自动续期**，支持 GitHub Actions 定时任务或 VPS 本地部署。

---

## ✨ 主要功能

* **全自动续期**：每天自动登录并检查是否有可续期的机器，达到时间自动触发续期逻辑。
* **多账号支持**：支持配置多个账号并行续期。
* **异常提醒**：登录失败或获取列表异常时，通过多种渠道发送通知提醒人工处理。
* **续期反馈**：续期成功后发送通知，告别遗忘。
* **域名邮箱适配**：支持登录邮箱与接收 PIN 码邮箱不一致的场景。

---

## 🚀 部署方式

### 方案 A：GitHub Actions 部署（推荐）

1.  **Fork 本仓库**：点击右上角 `Fork` 按钮到你的账户下。
2.  **配置 Secrets**：进入 `Settings` -> `Secrets and variables` -> `Actions`，点击 `New repository secret` 添加下方表格中的变量（工作流已内置 `contents: write` 权限，无需手动修改权限设置）。

### 方案 B：VPS 虚拟主机部署
* 详情请参阅：[VPS 部署指南](./README_VPS.md)。

---

## ⚙️ 配置变量 (Secrets)

| Secret 名称 | 是否必须 | 描述 |
| :--- | :---: | :--- |
| `EUSERV_EMAIL` | **是** | Euserv 登录邮箱。多账号请配置 `EUSERV_EMAIL2` 等。 |
| `EUSERV_PASSWORD` | **是** | Euserv 登录密码。多账号请配置 `EUSERV_PASSWORD2` 等。 |
| `EMAIL_PIN` | 否 | 接收 PIN 码的邮箱（未配置时默认使用登录邮箱）。多账号配置 `EMAIL_PIN2` 等。 |
| `EMAIL_PASS` | **否** | 接收 PIN 码邮箱的应用专用密码（需开启 IMAP）。多账号配置 `EMAIL_PASS2` 等。 |
| `TG_BOT_TOKEN` | 否 | Telegram Bot Token。 |
| `TG_CHAT_ID` | 否 | Telegram 用户 ID。 |
| `BARK_URL` | 否 | iOS Bark 推送地址。例如：`https://api.day.app/your_key/` |

---

## 📅 运行说明

1.  **首次运行**：配置完成后，务必手动在 `Actions` 页面执行一次工作流以激活脚本。
2.  **自动执行**：手动执行成功后，系统将按照定时任务自动运行。