# ツールの実行コマンド（tool-routing.md の詳細）

`claude/rules/tool-routing.md` から**コマンド形と壊れやすい要素**だけを移したもの。ルール本文（いつ・誰に振るか）は tool-routing.md にある。手で叩いて切り分けるときに読む。

## ai-fallback.sh が内部で使うコマンド

手で叩いて切り分けるときの形。要素を外すと壊れる。**連鎖の先頭は Codex。OpenCode 系は v2（`opencode2`）が本線、v1（`opencode`）は代替、どちらも無ければ `pi`**。

```bash
# Codex（-m は codex:{model} のときだけ。成功時は -o のファイルを stdout に出す）
timeout -k 1m 20m codex exec -s read-only --ephemeral --skip-git-repo-check --color never -o {last_message_file} [-m {model}] -- "{research question}" < /dev/null
# v2
timeout -k 1m 20m opencode2 run --standalone --agent plan --print-logs --log-level error -m {model} "{research question}" < /dev/null
# v1
timeout -k 1m 20m opencode run --agent plan --print-logs --log-level ERROR -m {model} "{research question}" < /dev/null
```

| 要素 | 外すと壊れる理由 |
|------|-----------------|
| Codex の `-s read-only` **必須** | リサーチ・設計相談はファイルを書かない。`--full-auto` は codex-cli 0.164.0 に存在しない。`--ephemeral` はセッションファイルを残さない、`--skip-git-repo-check` は非 git cwd でも止めない |
| `--agent plan` **必須** | 既定の `build` は非対話実行だとパーミッション確認で**無言ハング**する（v1 で確認。v2 は `--auto` でも回避できるが、リサーチ用途では使わない）。stderr にも何も出ない |
| `--standalone`（v2） **必須** | v2 の `run` は既定で背景サービスに繋ぐ。`--standalone` で回ごとに専用サーバを立てる（前回の状態を引きずらない）。**サーバログが stderr に出るのも `--standalone` のときだけ**なので、429 の検知に必要 |
| `--log-level` の値は CLI ごとに違う | v2 は小文字（`error`）、v1 は大文字（`ERROR`）。間違えると理由が取れない |
| `< /dev/null` **必須** | stdin が**開いたパイプ**だと永久にハングする。`run_in_background: true` がまさにその状態（フォアグラウンドには自動で付くがバックグラウンドには付かない）。**バックグラウンド実行と必ずセット** |
| `2>/dev/null` を**付けない** | エラーを stderr に出しつつ **exit code 0** で終わる。潰すと「成功したのに出力が空」に見える |
| モデルは連鎖の 1 番目から | `openai/gpt-5.6-sol` は残高切れ（`insufficient_quota`）で**必ず失敗した**（課金が復活したら `AI_CHAIN` の先頭に戻す）。モデルを手で選ばず `ai-fallback.sh` に任せる |
| **バックグラウンド実行必須** | 込み入った質問は 10 分超。Bash ツールの既定 10 分で kill されると出力ゼロになり、ハングと見分けがつかない |
| `timeout -k 1m 20m` **必須** | 失敗後にプロセスが終わらないことがある（429 の後に MCP の認証待ちで止まり、完了通知が来ないまま待ち続けた）。`-k 1m` は SIGTERM で終わらないとき 1 分後に SIGKILL する。exit code 124（SIGTERM）/ 137（SIGKILL）はラッパーが次の候補へ回す |
| cwd は **git リポジトリ** | 非 git ディレクトリ（`/tmp` 等）だと起動時の `service=vcs` 初期化で無言ハングする |

- **完了はバックグラウンドタスクの完了通知で待つ。** `pgrep` / `tail --pid` で自前監視しない（`pgrep -f` は監視コマンド自身にマッチし、タイムアウトまで待ち続ける）
- 例外: 司令塔（`herdr-boss` skill）と PM（`pm-mode` skill）は子の完了を bg で待たない。報告は inbox と `herdr agent prompt` の 1 行で届く（`herdr-agent.sh delegate`）
- 空出力を quota と決めつけず、ログ（`~/.local/share/opencode/log/`）で確認する。v1 は 1 セッション 1 ファイル、v2 は `opencode.log` 1 本に追記するので、**実行前後の差分だけを見る**（ラッパーはファイルサイズを控えてから `tail -c` で差分を検索する）。v1 の正常系は `service=session` → `POST /session` → `service=snapshot` → `resolveTools` → `service=llm … stream` と進む。**`service=vcs … initialized` で止まっていれば stdin 詰まり**（`< /dev/null` 忘れ）で、非 git cwd と同じ見た目になる。`session_message.seq` の SQLite エラーは **v1 固有**（v2 は同じ DB で動く）で、モデルを替えても直らない（ラッパーは `--print-logs --log-level error` を付けて stderr に理由を出させ、その行を `skip: … (error)` の下に添える）
- 疎通確認: `echo 'Reply with exactly: PONG' | ~/.claude/scripts/ai-fallback.sh -`（先頭の Codex から試す。stderr の `AI_ENGINE=codex` で Codex が答えたと分かる）。OpenCode 単体は `opencode2 run --agent plan -m <model> "Reply with exactly: PONG"`（v2。v1 は `opencode run …`）。利用可能モデルは `opencode2 models` で確認できる
