# AGENTS.md

## Git / PR 運用

- 生成 AI エージェント使用時は、そのエージェント名を PR ラベルに付けること。
  - Codex 使用時は `codex` ラベルを付ける。
  - Cursor 使用時は `cursor` ラベルを付ける。
- 生成 AI エージェントがコミットする場合は、Co-author として自身の名前を付けること。
  - Codex: `Co-authored-by: Codex <noreply@openai.com>`
  - Claude: `Co-authored-by: Claude <noreply@anthropic.com>`
- 生成 AI エージェントは PR のマージをしてはいけない。
- 生成 AI エージェントは GitHub Actions の手動実行をしてはいけない。
