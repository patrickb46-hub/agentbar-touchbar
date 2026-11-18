# 接入自己的 Agent / Writing a provider

AgentBar 只做两件事：**读状态**、**画出来**。所以接一个新工具只有两条路——让它推给 AgentBar，或者让 AgentBar 去读它的日志。

*AgentBar only reads state and renders it. To add a tool, either push state to AgentBar, or let AgentBar read that tool's logs.*

---

## 状态模型 / The state model

一张卡片 = 一个 `(provider, sessionId)`。AgentBar 需要的最小信息：

| 字段 | 类型 | 说明 |
|---|---|---|
| `provider` | String | 来源名，决定卡片底色。内置识别 `workbuddy` / `copilot` / `dsh` / `claude` / `codex`，其它按名字散列到柔和色 |
| `sessionId` | String | 会话标识，同 provider 内唯一 |
| `state` | String | `thinking` / `tool` / `waiting_approval` / `done` / `error` / `idle` |
| `project` | String? | 显示在卡片上的名字，默认取 `cwd` 最后一段 |
| `tool` | String? | 当前工具名，例如 `Bash` |
| `cwd` | String? | 工作目录。没有可跳转的深链时，点击会打开这个目录 |
| `turnStartedAt` | Int64? | 本轮开始时间（毫秒），用来算耗时 |
| `updatedAt` | Int64 | 最后一次更新（毫秒） |
| `jumpUrl` | String? | 点击跳转的 URL，例如 `workbuddy://chat/<id>` |
| `note` | String? | 备注，`note = "疑似"` 时界面显示「可能待确认」 |

`state` 语义：

- `thinking` 模型在想 / 在写
- `tool` 正在跑某个工具
- `waiting_approval` 卡在等人确认（会变琥珀色，出现「跳回会话」按钮）
- `done` 这一轮结束（保留约 60–90 秒，之后自然消失）
- `error` 出错
- `idle` 空闲（AgentBar 直接忽略，不占卡片）

---

## 方式一：一行命令上报 / `agentbar report`

任何能跑 shell 的地方都能用：

```bash
agentbar report \
  --provider mytool \
  --session "$SESSION_ID" \
  --state tool \
  --tool Bash \
  --cwd "$PWD" \
  --project "我的项目" \
  --since 1795042556000 \
  --jump "mytool://session/$SESSION_ID"
```

写进 `~/.agentbar/state/mytool-<session>.json`，10 分钟没有更新自动失效。

---

## 方式二：hook 模式 / `agentbar hook`

把工具的生命周期事件从 stdin 喂进来，AgentBar 自己映射状态：

| 事件 | 映射到 |
|---|---|
| `PreToolUse` | `tool`（带 `tool_name`） |
| `PostToolUse` | `thinking` |
| `UserPromptSubmit` | `thinking` |
| `Notification` | `waiting_approval` |
| `Stop` / `SessionEnd` | `done` |

```json
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "*", "hooks": [
        { "type": "command",
          "command": "/Users/you/Applications/AgentBar.app/Contents/MacOS/agentbar hook",
          "timeout": 3 }
      ]}
    ]
  }
}
```

用 `AGENTBAR_PROVIDER=mytool` 指定卡片颜色归属。`hook` 永远以 0 退出，**不会**阻塞或拦截你的工具调用。

*`agentbar hook` always exits 0 — it never blocks or vetoes a tool call.*

---

## 方式三：provider 脚本 / external provider scripts

把可执行脚本放进 `~/.agentbar/providers/`，AgentBar 每 2 秒调用一次，读它的 stdout：

```bash
#!/bin/bash
# ~/.agentbar/providers/mytool.sh
# 输出一个 JSON 对象，或对象数组；报错就 exit 1（AgentBar 会安静跳过）
printf '{"provider":"mytool","sessionId":"%s","state":"%s","project":"%s","updatedAt":%s}\n' \
  "$(cat /tmp/mytool-session 2>/dev/null || echo none)" \
  "$(cat /tmp/mytool-state 2>/dev/null || echo idle)" \
  "我的项目" "$(($(date +%s)*1000))"
```

Python 版：

```python
#!/usr/bin/env python3
import json, time, pathlib
p = pathlib.Path("/tmp/mytool-status.json")
state = json.loads(p.read_text()) if p.exists() else {"state": "idle"}
print(json.dumps({
    "provider": "mytool",
    "sessionId": state.get("id", "default"),
    "state": state["state"],
    "tool": state.get("tool"),
    "cwd": state.get("cwd"),
    "project": state.get("project"),
    "updatedAt": int(time.time() * 1000),
}))
```

约定：

- 必须输出**一行或多行 JSON**（数组也可以），字段见上面的状态模型
- `schema` 可选，当前为 `1`
- 脚本超过 3 秒没返回会被跳过这一轮
- 输出 `state: "idle"` 等于主动隐藏该卡片

---

## 一个完整的接入例子 / End-to-end example

假设你的工具在每轮开始时写一个文件，结束时删掉它：

```bash
# 开始干活
agentbar report --provider mytool --session run-42 --state thinking --cwd "$PWD"
# 调用工具前
agentbar report --provider mytool --session run-42 --state tool --tool Bash --cwd "$PWD"
# 需要人确认
agentbar report --provider mytool --session run-42 --state waiting_approval --cwd "$PWD" \
  --jump "mytool://run-42"
# 结束
agentbar report --provider mytool --session run-42 --state done --cwd "$PWD"
```

Touch Bar 上会依次出现：蓝点「思考中」→ 青色「执行中 · Bash」→ 琥珀「待确认 + 跳回会话」→ 绿点「已完成」，然后卡片淡出。

---

## 调试 / Debugging

```bash
agentbar dump                       # 看 AgentBar 现在认为每个 agent 是什么状态
agentbar probe --provider copilot   # 直接解析该工具的会话文件，忽略空闲/过期过滤
agentbar clean                      # 清掉所有上报文件
tail -f ~/.agentbar/agentbar.log    # 私有 API、宽度校准、点击命中都有记录
```
