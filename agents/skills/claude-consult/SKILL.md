---
name: claude-consult
description: Ask a read-only Claude (default opus) for a design consultation or a second opinion from another agent such as Cursor, pi or Cline. Writes the question to a file, runs ~/.claude/scripts/claude-consult.sh, reads the answer file, and can continue the same discussion with --resume. Claude can only Read / Grep / Glob the repository. Use when asked to consult Claude, get Claude's opinion on a design, or review an approach before implementing.
metadata:
  kind: consult
  writes: "none (answer file only)"
---

# claude-consult

Cursor / pi / Cline などから、**読み取り専用の Claude** に設計相談・検討をさせるスキル。Claude 側は Read / Grep / Glob だけで、ファイル編集・シェル・MCP は使えない。回答はファイルと stdout で受け取り、`SESSION_ID` で相談を続けられる。

Claude Code 自身からは使わない（自分自身を呼ぶ形になる）。Claude Code では通常の設計相談の流れ（`ai-fallback.sh` など）に従う。

## 前提

- `~/.claude/scripts/claude-consult.sh` があり（`./sync-claude.sh` で配布）、`claude` と `jq` が PATH にある
- **相談したいリポジトリのルートで実行する。** Claude はそこを基準にファイルを読み、`--resume` も同じ cwd からでないとセッションが見つからない

## 手順

### 1. 相談を書く

作業ディレクトリの外（`/tmp` など）か、コミットされない場所にプロンプトファイルを作る。Claude はこの会話を知らないので、次を自己完結で書く。

- 目的と背景（何を作る・直すのか）
- 現状と制約（関係するファイルパスを具体的に。Claude が Read で読める）
- 聞きたいこと（案の比較、落とし穴、設計の妥当性など。1 回に 1 テーマ）
- 回答の形式の希望（結論を先に、理由、代替案、など）

秘密情報（API キー・個人情報）は書かない。

### 2. 実行する

```bash
~/.claude/scripts/claude-consult.sh {prompt_file}
~/.claude/scripts/claude-consult.sh -m sonnet {prompt_file}   # モデル指定（既定 opus）
```

- 長くかかる（数分〜）ので、使えるならバックグラウンドで実行して完了を待つ。タイムアウトは既定 20 分（`-t` か `CLAUDE_CONSULT_TIMEOUT`）
- 既定モデルは `CLAUDE_CONSULT_MODEL` でも変えられる
- stdout が回答本文。同じものが `{prompt_file の拡張子を除いた名前}.answer.md` に、生出力が同名の `.json` に残る
- stderr の `AI_MODEL=claude/{model}` と `SESSION_ID={id}` を控える

### 3. 続ける

追加の質問は新しいプロンプトファイルに書き、`SESSION_ID` を渡す。**同じ cwd から**実行すること。

```bash
~/.claude/scripts/claude-consult.sh -r {session_id} {followup_file}
```

### 4. 回答を扱う

- 回答は意見であって決定ではない。Claude は会話の文脈を知らないので、**根拠（ファイルパス・コードの引用）は自分で検証してから**採用する
- ユーザーに伝えるとき、または成果物に残すときは `利用AI: claude/{model}` を添える
- 失敗したとき（exit 1）は stderr の理由と `.json` を確認する。認証切れ・タイムアウト・空出力が多い。リトライは 1 回までにして、続かなければユーザーに報告する

## やらないこと

- この呼び出しでファイルは変更されない。実装は相談結果を踏まえて自分で行う
- プロンプトファイルを `claude -p` に直接渡さない（読み取り専用の制限が外れる）。必ずスクリプトを経由する
