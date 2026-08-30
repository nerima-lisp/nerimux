# Workspace UX 再設計 作業指示書

## 1. 実装方針

`docs/notes/workspace-redesign-spec.md` を唯一のUX受け入れ基準とする。既存のworkspace-only構成、PTY、TUI renderer、VCS adapterは再利用し、利用者のメンタルモデルと状態遷移をworkspace中心へ統一する。

Orca、tmux、外部GUI、repository固有の設定には依存を追加しない。

## 2. 作業単位

### Phase 0: ベースライン確認

- 現在のテストコマンド、formatter、package構成を確認する。
- 既存のworkspace、pane、VCS、dispatch、rendererの責務を一覧化する。
- 変更前のテストを実行し、失敗を記録する。
- 共有worktreeを変更せず、専用のfeature worktreeで作業する。

完了条件: 実行したコマンド、選択テスト数、既存失敗、対象ファイルが記録されていること。

### Phase 1: ドメインモデル

対象: workspace、agent、terminal、attachment、lifecycle state。

- workspaceをrepository配下の第一級オブジェクトにする。
- agent最大1、terminal無制限をモデルで保証する。
- `completed` と `prunable` を別状態として表現する。
- attachment数とプロセス生存状態を分離する。
- 再開時のcompleted解除を一箇所の遷移規則にする。

検証:

- 状態遷移unit test
- agent重複作成拒否test
- attachment中のprune拒否test
- 再開時のcompleted解除test

### Phase 2: Git / VCS adapter

- bare repositoryからremote default branchを解決する。
- `git fetch origin` 後に `origin/main` のcommitを確定する。
- detached worktree作成コマンドを実装する。
- timestamp-basehash名を一箇所で生成する。
- worktree削除、dirty判定、missing判定、prune候補判定を分離する。
- fetch結果が空、refが存在しない、fetch失敗の場合を明示的に返す。

検証:

- known bare repository fixtureでorigin/main起点を確認
- worktree path/nameの形式test
- dirty/clean/missing/attachment各状態のfixture test
- fetch失敗時にworktreeが残らないことのtest

### Phase 3: 非同期ジョブとイベント

- fetch、scan、status、create、pruneをjobとして扱う。
- UI threadで同期VCSコマンドを実行しない。
- jobに対象IDと世代番号を付与する。
- stale resultを破棄する。
- 成功、失敗、部分成功をイベントとしてrendererへ通知する。

検証:

- fetch中にoverview操作が継続するintegration test
- 古いjob結果が新しい状態を上書きしないtest
- prune allの部分成功test

### Phase 4: Workspace overview

- repository → workspace → attachment の階層を基本表示にする。
- workspaceは新しい順に並べる。
- agent稼働中を並び順の優先条件にしない。
- git状態、agent状態、terminal数、prunable理由を一行で表示する。
- `Enter` でagent/terminal viewへ直接遷移する。

検証:

- 空のrepository一覧
- workspaceなし
- agentあり / terminalのみ / attachmentなし
- dirty、missing、conflict
- 新旧workspace順序

### Phase 5: Agent / terminal view

- Codex / Claude選択UIを追加する。
- workspace作成直後に `Agent / Terminal` の起動対象を選択できるようにする。
- `Terminal` 選択時はagentなしの通常shellをworktreeのcwdで起動する。
- 後から `a` でagent、`t` でterminalを追加できる。
- Claudeを `claude --dangerously-skip-permissions`、Codexを `codex --dangerously-bypass-approvals-and-sandbox` で起動する。
- 作成後のキャンセルでworkspaceを削除する。
- agentとterminalを50/50で初期分割する。
- `C-q w` をoverview遷移に割り当てる。
- `C-q k` でagent停止確認を表示する。
- overviewへ戻ってもPTYとagentを維持する。

検証:

- agent起動、停止、再attach
- terminal複数作成
- workspace作成直後の通常terminal起動
- 通常terminalから後続agentを追加
- Claude / Codexの起動コマンド検証
- agent実行中のoverview遷移
- `C-q w` 往復
- attach後のprune拒否

### Phase 6: 完了とprune

- explicit complete操作を追加する。
- agent実行中でも確認付きでcomplete可能にする。
- complete直後にprunable候補へ反映する。
- workspace再開で未完了へ戻す。
- clean pruneを即時実行する。
- dirty pruneは変更ファイル一覧つき個別確認にする。
- `prune all` を全repository対象で実装する。

検証:

- 実行中agentのcomplete
- dirty workspaceの確認キャンセル
- clean workspaceのprune
- `prune all` の全対象走査
- attachment中の除外
- 削除失敗後の再表示

### Phase 7: ドキュメントと互換性整理

- getting startedの操作表を新keymapへ更新する。
- architectureのpane説明をworkspace attachmentの責務に合わせる。
- tmux/Orcaが必須に見える説明を削除または補足する。
- 旧keymapと新keymapが混在していないことを検索で確認する。

検証:

```text
rg -n "C-q w|C-q k|prune all|origin/main|timestamp|Orca|tmux" docs src tests
```

## 3. 実装上の禁止事項

- agent終了をworkspace完了と自動解釈しない。
- attachment中のworktreeを削除しない。
- dirty削除を暗黙に実行しない。
- fetch中にUIをブロックしない。
- agent稼働状態だけで一覧順を変更しない。
- 外部のOrcaまたはtmuxをランタイム依存にしない。
- 既存の失敗テストを、timeout延長やskipで隠さない。

## 4. 最終ゲート

以下を順番に実行する。

1. formatter / parser
2. 変更対象unit test
3. VCS integration test
4. agent / terminal lifecycle integration test
5. prune all integration test
6. 全テスト
7. ドキュメント内の旧仕様検索

各ゲートについて、コマンド、exit status、実行されたテスト数、未解決の失敗を報告する。テストが選択数0の場合は成功扱いにしない。

## 5. 完了報告フォーマット

```text
status: success | warning | error
summary: 実装した範囲
evidence:
  - verified: file:line または command
verification:
  - command: ...
    exit: 0
gaps:
  - 未実装または検証できなかった事項
```
