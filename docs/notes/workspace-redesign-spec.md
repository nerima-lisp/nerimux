# Workspace 中心 UX 詳細設計

## 1. 目的

bare repository と detached worktree を、agent 作業の単位である `workspace` として扱う。利用者は worktree のパス、ブランチ名、pane の構成を意識せず、repository を選んで作業を開始できる。

UX の基準は Magit の「状態を一覧し、選択した対象に対して prefix command を実行する」操作感とする。ただし Orca、tmux、その他の外部 multiplexer には依存しない。

## 2. 用語と責務

```text
Repository
└── Workspace  (git worktree 1つ)
    ├── Agent  (0..1、Codex または Claude)
    └── Terminal (0..N)
```

- Repository: ghq 配下で検出された bare repository。
- Workspace: 作業のライフサイクル、git状態、agent、terminalを束ねる単位。
- Agent: workspaceで動くCodexまたはClaudeのプロセス。
- Terminal: workspaceのディレクトリをcwdにしたnerimux内蔵PTY。
- 完了: 利用者が明示的に設定する業務状態。プロセス終了とは別概念。
- prunable: worktreeを削除できる候補状態。完了だけではなく、attachmentがないことも必要。

## 3. Workspace 作成

1. Repository一覧で対象repositoryを選択する。
2. `n` を押す。
3. nerimuxが非同期で `git fetch origin` を実行する。
4. fetch成功後の `origin/main` を開始点としてdetached worktreeを作る。
5. worktree名は `YYYYMMDDTHHMMSS-<start-point short sha>` とする。
6. workspaceを一覧に追加し、agent割り当て画面を開く。
7. agent選択をキャンセルした場合は、作成したworkspaceを削除する。

利用者の入力はrepository選択以外不要とする。fetch中も一覧、既存workspace、terminalは操作可能である。fetch失敗時はworkspaceを作成せず、エラーと再試行操作を表示する。

## 4. Workspace 一覧

一覧は新しいworkspaceから順に表示する。agentが動作中であることを理由に並び順を変更しない。

各行には以下を表示する。

```text
● workspace-name   agent: Codex [running]   terminal: 2   git: clean
○ workspace-name   agent: Claude [done]      terminal: 0   git: dirty +3 -1
! workspace-name   agent: none               terminal: 0   git: missing
```

- agent状態: `running`, `exited`, `completed`, `none`。
- git状態: `clean`, `dirty`, `missing`, `conflict`。
- `completed` は利用者が明示的に完了にした状態。
- workspaceを再開した時点で `completed` は自動的に未完了へ戻す。

`Enter` は選択workspaceのagent画面を直接開く。agentがない場合はterminal画面を開き、terminalもない場合は割り当て操作を表示する。

## 5. Agent と Terminal

### Agent

- workspaceごとにagentは最大1つ。
- 起動時に `Codex` または `Claude` を選択する。
- 初期プロンプトは空欄で、起動後にagent画面から入力する。
- agentプロセスの終了理由は通常終了・異常終了で区別しない。
- 終了後は一覧に通常のagent状態として表示し、workspaceをprunable候補にする。
- agent実行中でも「完了」にできる。確認を表示したうえで、プロセスは停止せず状態だけ変更する。

### Terminal

- workspaceごとにterminalは複数作成できる。
- terminalはworkspaceのworktreeをcwdとして起動する。
- agent画面からterminalを追加すると、agentとterminalを50/50で分割する。
- 分割後は手動リサイズ可能。
- terminalをdetachしてもプロセスは終了させず、workspace内に残す。

## 6. 画面遷移とキー

```text
workspace overview
  ├─ Enter → agent / terminal view
  ├─ n     → workspace作成
  ├─ a     → agent割り当て
  ├─ t     → terminal追加
  ├─ c     → 完了 / 未完了切替
  ├─ p     → 選択workspaceをprune
  └─ P     → prune all

agent / terminal view
  ├─ C-q w → workspace overview
  ├─ C-q k → agent停止
  ├─ C-q t → terminal追加
  └─ C-q h/j/k/l → pane focus移動
```

`C-q w` でoverviewへ戻ってもagentとterminalは実行継続する。pane操作はtmux互換を目的にせず、workspace内のattachment操作として実装する。

## 7. 状態遷移

```text
CREATING → ACTIVE → COMPLETED → PRUNABLE
               │         │
               └─────────┘ (再開でACTIVE)
```

prunable判定は次の全条件を満たす場合のみ真とする。

1. workspaceが完了状態、またはagent終了後に自動削除候補化されている。
2. agentがattach中でない。
3. terminalがattach中でない。
4. worktreeが存在する。

dirtyなworkspaceは候補表示までは自動化するが、削除時に変更ファイル一覧を表示して個別確認を要求する。cleanなworkspaceは確認なしで削除する。削除対象のworktreeにattachmentが残っている場合は削除不可とする。

## 8. prune all

`P` は全repositoryの削除候補を走査する。

- cleanかつdetach済み: 即時削除。
- dirty: repository、workspace名、変更ファイル、agent最終状態を表示し、workspaceごとに確認。
- agentまたはterminalがattach中: 候補から除外し、理由を表示。
- missing: gitの管理情報を安全に修復できる場合のみ対象とし、通常のworktree削除とは区別する。
- 処理中もUIは操作可能。結果はイベントとして一覧へ反映する。

削除失敗時は対象を残し、失敗理由と再試行操作を表示する。部分成功を全成功として扱わない。

## 9. 非同期処理

fetch、repository scan、git status取得、worktree作成、pruneはUIスレッドをブロックしない。各処理は `queued / running / succeeded / failed` を持つ。

処理中の対象行にはspinnerと処理名を表示し、完了後に対象行だけ再描画する。古い結果が新しい操作結果を上書きしないよう、repository/workspaceごとの世代番号を検証する。

## 10. 受け入れ条件

- repository選択から、入力なしで `origin/main` 起点のdetached workspaceを作成できる。
- worktree名がtimestampと開始commit短縮ハッシュから生成される。
- fetch中も既存workspaceの閲覧とterminal操作が継続できる。
- workspace選択でagent画面へ直接遷移し、`C-q w`で一覧へ戻れる。
- agent 1つ、terminal複数の制約が守られる。
- agent実行中の完了操作、再開時の未完了化が動作する。
- attachment中のworkspaceがpruneされない。
- cleanのpruneは即時、dirtyのpruneは個別確認になる。
- `prune all` が全repositoryを対象にし、部分成功と失敗理由を表示する。
- Orcaとtmuxがなくても全機能が動作する。
