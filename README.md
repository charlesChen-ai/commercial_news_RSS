# Multi-Source CN Finance Telegraph Viewer

一个本地可运行的多源财经快讯聚合工具：后端抓取并去重，前端持续刷新展示，支持来源标注、关键词筛选、沉浸阅读和展开状态记忆。

## Features

- 多源聚合：财联社、东方财富、新浪财经、华尔街见闻、同花顺
- 自动刷新：默认每 8 秒，可手动调整
- 去重策略（后端）：
  - `uid` 去重
  - 文本强去重（归一化后完全一致）
  - 标题完全重复去重（时间窗口）
  - 近似文本去重（10 分钟窗口 + 相似度阈值）
- 去重策略（前端）：
  - 拉新合并时标题重复拦截
  - 本地缓存加载时二次清洗
- 信息展示：
  - 来源彩色徽标
  - 重要等级标色（`A/B/C/N`）
  - 有标题条目默认折叠全文，点击展开
  - 刷新后保持已展开条目状态
- 沉浸模式：
  - 左侧控制面板可折叠
  - 折叠后右侧电报流占据主要视图

## Project Structure

```text
.
├── cls-telegraph-proxy.js         # Node.js 聚合代理（抓取、解析、去重、API）
├── cls-telegraph-auto-viewer.html # 自动刷新前端页面
├── cls-telegraph-copy-viewer.html # 手动粘贴版本（保留）
├── cls-telegraph-enhancer.user.js # 历史脚本（非主方案）
└── ios/CLSFeedApp                 # iOS SwiftUI 客户端（信息流 + 控制台）
```

## Architecture

1. 前端请求本地 `/api/telegraph`
2. 后端并发抓取各来源（`Promise.allSettled`）
3. 将不同来源规范化为统一字段
4. 执行分层去重并排序
5. 返回给前端渲染（附带来源健康状态与去重统计）

## Requirements

- Node.js `>= 18`（使用内置 `fetch`）
- 可访问公开财经站点网络环境

## Quick Start

```bash
cd /Users/chaos/Codes/cls
node cls-telegraph-proxy.js
```

浏览器打开：

- [http://127.0.0.1:8066/](http://127.0.0.1:8066/)

可选端口：

```bash
PORT=8080 node cls-telegraph-proxy.js
```

## API

### `GET /health`

健康检查。

### `GET /api/telegraph?limit=120&sources=cls,sina,wscn`

返回聚合后的快讯数据。

参数：

- `limit`：返回数量，范围 `20~500`，默认 `120`
- `sources`：可选，逗号分隔来源列表；支持 `cls,eastmoney,sina,wscn,ths`
  - 不传时默认全量来源

主要返回字段：

- `ok`：是否成功
- `items`：快讯列表（已去重）
- `sources`：每个来源抓取状态（`ok/count/error`）
- `dedupe`：去重统计（`before/afterUid/afterStrong/afterTitle/afterFuzzy`）
- `cached`：是否命中 3 秒短缓存

### `GET /api/ai/providers`

返回后端内置的 AI provider 预设（`id/label/defaultApiBase/defaultModel`）与默认配置。

### `POST /api/analyze`

请求体在原始快讯字段外支持 `ai` 配置覆盖：

```json
{
  "uid": "cls:123",
  "source": "cls",
  "time": "10:00:00",
  "title": "标题",
  "text": "正文",
  "ai": {
    "provider": "deepseek",
    "apiKey": "your-key",
    "apiBase": "https://api.deepseek.com/v1",
    "model": "deepseek-chat"
  }
}
```

说明：

- `provider` 支持：`deepseek/openai/gemini/custom`
- `apiKey` / `apiBase` / `model` 为空时会回退到环境变量默认值

`items` 单条字段：

- `uid`, `source`, `sourceName`
- `id`, `ctime`, `time`
- `title`, `text`, `author`, `level`, `url`

## Frontend Behavior

- 自动刷新时默认增量渲染，避免全屏闪烁
- 有标题内容默认仅展示标题，正文通过“展开全文”查看
- 已展开条目在刷新/重绘后自动恢复
- 支持来源筛选、关键词筛选、紧凑模式、清空缓存

## Dedupe Strategy

后端按以下顺序执行：

1. `uid` 去重
2. 强去重：标题+正文归一化完全一致
3. 标题去重：标题完全一致且处于时间窗口
4. 近似去重：短时间窗内进行相似度比较，结合数字特征防误杀

前端在合并和加载缓存时再补一层标题去重，降低历史缓存残留重复。

## Troubleshooting

- 某来源 `count=0`：
  - 先看 `/api/telegraph` 返回里该来源 `error`
  - 常见原因：站点风控、返回壳页面、结构变更
- 刷新太频繁导致失败：
  - 将刷新间隔调到 `12~20s`
- 页面内容看起来“重复”：
  - 先刷新一次让前端清理旧缓存
  - 再查看返回中的 `dedupe` 统计是否在下降

## Development

语法检查：

```bash
node --check cls-telegraph-proxy.js
```

本地接口快速检查：

```bash
curl -sS 'http://127.0.0.1:8066/api/telegraph?limit=50'
```

## AI Analysis Config (DeepSeek)

`/api/analyze` 默认按 DeepSeek OpenAI-compatible 接口调用：

- 默认 `OPENAI_API_BASE=https://api.deepseek.com/v1`
- 默认 `OPENAI_MODEL=deepseek-chat`

最简配置只需要：

```bash
export OPENAI_API_KEY=你的DeepSeekKey
```

可选覆盖：

```bash
export OPENAI_API_BASE=https://api.deepseek.com/v1
export OPENAI_MODEL=deepseek-chat
```

也可以在调用 `/api/analyze` 时通过请求体 `ai` 字段按用户维度动态覆盖（适合移动端多用户场景）。

## iOS App (SwiftUI)

项目路径：`ios/CLSFeedApp`

- Tab1「信息流」：展示聚合快讯流，支持下拉刷新、自动轮询、逐条 AI 分析
- Tab2「控制台」：配置服务地址、勾选信息源、选择 AI provider、输入 API Key、编辑 API Base 与模型名

> API Key 在 iOS 端存于 Keychain，再随分析请求下发给后端。

## Disclaimer

- 本项目仅用于技术学习与本地信息聚合演示
- 数据版权归原始信息源所有
- 请遵守目标站点服务条款与相关法律法规
