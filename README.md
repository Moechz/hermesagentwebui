# hermes-agent-webui (TOS packaging)

将上游 [hermes-webui](https://github.com/nesquena/hermes-webui)（Hermes
Agent 的 Python + 原生 JS 网页界面）封装为 **TerraMaster TOS 7 应用**
（Deb 包，App Center 安装），目标是上架官方应用商店。

本仓库是**打包/适配层**：不 fork 上游源码；上游以嵌套仓库形式放在
`upstream/hermes-webui/`（被 gitignore）。

## 目录结构

```text
AGENTS.md / HANDOFF.md     会话/交接入口（新会话先读）
upstream/hermes-webui/     上游浅克隆（不跟踪）
packaging/templates/       TOS 元数据与打包模板（骨架）
scripts/                   构建/校验脚本（骨架）
docs/                      TASK_STATE / DESIGN_DECISIONS / CHANGELOG
```

## 快速上手

```bash
# 更新上游（本机 GitHub 仅 SSH 可达）
git -C upstream/hermes-webui pull

# 查看当前状态与下一步
#   → 读 docs/TASK_STATE.md
```

## 状态

`0.0.0` 初始化。打包工作未开始；当前最关键的开放问题是 TOS 7 真机的
Python 运行时可用性与 Hermes Agent 本体的安装方式，
详见 `docs/TASK_STATE.md` §5。
