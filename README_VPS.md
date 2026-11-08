# 🖥️ VPS 部署指南

本项目支持在 VPS 上通过一键脚本快速部署。针对配置较低的机器（如德鸡本身），推荐使用 **Python 本地部署** 模式以节省资源。

---

## 🛠️ 一键部署

使用以下命令进行安装。脚本执行后，终端输入 `dj` 即可唤起管理菜单。

```bash
wget https://raw.githubusercontent.com/dufei511/euserv_py/main/install.sh -O euserv_install.sh
chmod +x euserv_install.sh
./euserv_install.sh install
```