# Execution record

このファイルは、作業単位を main に反映した記録として残す。実装の説明は
既存の reference docs に委ね、ここでは統合順序、検証結果、未解決の検証範囲を
記録する。

## 依頼された作業

- 現在の unstage / branch / worktree の内容を作業単位に分けて main に反映する。
- 反映が完了した worktree と branch は、対象を確認してから削除する。
- 一通りの反映後に docs を更新する。
- EXECUTION.md は削除せず保持する。
- 権限ごとのマトリックスと、実施したテストの詳細を Markdown に出力する。

元の未追跡の一時計画書は、保持指定を受ける前の統合準備中に削除されており、Git
履歴や残存 worktree から復元できなかった。そのため、このファイルを統合結果と
検証を残す保持用の記録として新たに追加した。元ファイルを保持できたとは扱わない。

## 統合した作業単位

統合先は main から作った一時 feature branch とし、main 自体では commit を作らず、
検証済みの feature tip を最後に fast-forward する。

| 作業単位 | 内容 | 統合 commit |
| --- | --- | --- |
| workspace runtime / picker | domain model、VCS port、runtime lifecycle、picker、TUI renderer と対応テスト | 8351773 feat: add workspace runtime and picker |
| flake lock action | 既存の lock 更新 branch から flake.lock の差分だけを現行 main に適用 | d22d722 chore: update flake.lock |
| workspace dependency lock | 新しい workspace input の評価に必要な lock エントリを追加 | 99134ba chore: lock workspace dependencies |
| docs / execution record | 権限マトリックス、テスト証跡、作業記録 | このファイルと docs/notes/permissions-and-verification.md |

最初の workspace 作業には実装、テスト、README と docs の更新を含めた。誤って生成
されたファイルは成果物に含めていない。

## 統合前のベースライン

現行 main の clean worktree で次を実行した。

~~~text
nix run .#test
~~~

結果は exit status 1、4436 total、4431 passed、1 skipped、0 todo、
4 failed、0 errored だった。失敗したのは次の既存 PTY ケースである。

- pty-suite > shell-echoes-command-output
- pty-suite > pty-write-accepts-octet-vector
- pty-suite > select-times-out-when-idle
- pty-suite > pty-child-exit-status-reports-signaled-kind

この結果を、統合後の回帰判定のベースラインとして扱う。テストが選択されている
ことは total が 0 でないことでも確認した。

## 統合後の検証

### フルテスト

統合後の clean worktree で、同じコマンドを二度実行した。

~~~text
nix run .#test
~~~

二回とも exit status 1 で、4487 total、4481 passed、1 skipped、
0 todo、5 failed、0 errored だった。workspace 側のテストが追加されたため、
ベースラインより選択数が 51 増えている。

二回とも失敗したのは、ベースラインと同じ4件に加えて次の1件だった。

- multi-socket-renders-live-pty-output

このテストは実 PTY に printf を書き込み、reader thread が screen model に出力を
反映した後、その文字列を socket frame として取得するシナリオである。ベースライン
でも shell output と octet-vector write の PTY ケースが失敗しており、新しい1件も
同じ live PTY 出力経路で失敗している。二回の同一結果は再現性の証拠だが、renderer
単独の回帰と断定する証拠ではない。今回の統合では、未切り分けの PTY 失敗を隠すための
実装変更やテストの弱体化は行っていない。

### 差分・commit 検査

- 統合前後の差分に対して git diff --check を実行し、空白エラーなし、exit status
  0 を確認した。
- workspace、lock、依存 lock の各 commit で commit hook の secret scan が走り、各回
  0 commits scanned 相当の検査成功と leak なしを確認した。
- lock の自動補完は cl-tui-kit と cl-vcs-kit の2 inputに限定され、実装 commit、
  既存 lock 差分、依存 lock 補完の3単位に分離されている。

## 権限の検証記録

権限の境界とテストの対応表は
[docs/notes/permissions-and-verification.md](docs/notes/permissions-and-verification.md)
に分離している。特に次の二つを混同しない。

1. socket directory mode 0700 は実際に socket へ到達できるかを決める OS 境界。
2. server-access の :read-write / :read-only は現在の single-user 実装で状態を
   管理する ACL モデルであり、socket の認証境界そのものではない。
3. attach-session -r は接続単位の read-only state で、pane への key / paste / mouse
   入力を抑止する。ACL の :read-only と同じ仕組みではない。

検証対象には、ACL の add / modify / delete / list / reject、attach flag の wire
round-trip、connection slot への read-only state、read-only client の pane input
抑止、通常 client の write 経路を含めた。個々のテスト名とソース位置は上記 Markdown
に記載している。

## 完了条件と残りの注意点

- main へ反映する tip は、上記3つの実装・lock commitと docs commit を含むこと。
- main の更新は、更新前の main が想定値のままであることを確認した上で、fast-forward
  相当の ref 更新として行うこと。
- 統合済みの一時 branch と、その branch だけを参照する worktree は、最終 tip が main
  から到達可能であることを確認してから削除すること。
- 現在実行中の worktree は、実行中セッションを壊さないため削除対象にしない。
- PTY 5件の失敗が残っているため、テスト全体を green と報告してはならない。PTY
  実装または実行環境の切り分けは別作業として残る。

## 2026-08-18 追加反映

このセクションは、上記記録の続きとして、同じ依頼（unstage/branch/worktree を作業
単位で main に反映し、完了分は削除し、docs を更新する）を再度受けて行った作業を
記録する。

### 統合した作業単位

| 作業単位 | 内容 | 反映方法 |
| --- | --- | --- |
| ローカル main の origin 未反映分 | workspace runtime/picker、flake lock、依存 lock、このファイルを含む4 commit（8351773, d22d722, 99134ba, 02d8c09）が origin/main に一度も push されていなかった | `sync/local-main-to-origin` branch から PR #3 を作成し、GitHub 上で `origin/main`（`feat/rename-cl-prolog-dataflow-kit` の PR #2 merge 済み、172a36a）へ merge。commit `c095961`。ローカル main は `git merge --ff-only origin/main` で追従させ、main 自体への直接 commit は作らなかった。|
| `feat/rename-cl-prolog-dataflow-kit` | cl-prolog → cl-prolog-kit, cl-dataflow → cl-dataflow-kit の rename | 既に GitHub PR #2 で `origin/main` に merge 済みだった。上記 PR #3 で ローカル main に反映。worktree と branch を削除。|

### 保留にした作業単位

| 作業単位 | 内容 | 保留理由 |
| --- | --- | --- |
| `workspace-overview` branch (97ebf05) | organization/repository/worktree/pane の全画面 overview + worktree 操作 (attach/lock/unlock/delete/prune) | main の `render-session-to-string` は既に client 単位の `:overview`/`:detail`/`:attention` view（`client-conn-view`、cl-tui-kit ベースの `renderer-tui-kit.lisp` 経由）を実装済みで、`workspace-overview` は同じ関数名を session 単位の `workspace-mode-p` 分岐で上書きしようとする、独立して書かれた別アーキテクチャだった。ドメインモデルも `nerimux/model`（main）と `nerimux/workspace`（このbranch）で重複している。機械的な merge では両者の分岐ロジックが同じ入口を奪い合い、正しく動作しないコードになるため、今回は統合を見送った。branch と worktree (`20260817T154253-d1ea1c1`) は削除せず保持している(2026-08-19 節の註のとおり、この branch と worktree はその後消失しており、現在の保持対象ではない)。次に着手する際は、まず `client-conn-view` 方式と `workspace-mode-p` 方式のどちらを正とするかを決め、選ばれなかった側の呼び出しグラフ（renderer、dispatch、ドメインモデル）を書き換える前提で見積もること。|

### 削除した worktree / branch

| 対象 | 種別 | 削除理由 |
| --- | --- | --- |
| `.worktrees/20260817T134857-d1ea1c1` | worktree (detached, d1ea1c1) | 変更なし、main の祖先 commit と同一。 |
| `.worktrees/20260817T145609-d1ea1c1` | worktree (detached, d1ea1c1) | commit 差分なし。未追跡の EXECUTION.md 草稿（workspace UI/UX 仕様）のみ保持していたため、`docs/notes/workspace-ui-ux-design.md` として保存した上で削除。 |
| `.worktrees/20260817T164626-d1ea1c1` + `feat/rename-cl-prolog-dataflow-kit` | worktree + branch | 内容は origin/main と今回のローカル main 両方から到達可能になったため。 |
| `.worktrees/20260818T-integration` + `integration/current-work-units` | worktree (conflict 未解決) + branch | rename 作業とローカル main を統合済みの上で `workspace-overview` を merge しようとして 5 ファイルが conflict したまま放置されていた。`workspace-overview` の統合自体を保留したため、この試みは前提から不要になった。 |
| `.worktrees/20260818T054124-172a36a` | worktree (detached, 172a36a) | 既に origin/main に含まれる merge commit を見ているだけで、固有の変更なし。 |
| `.worktrees/20260818T055112-02d8c09` + `sync/local-main-to-origin` | worktree + branch | PR #3 が merge 済みで、内容が main から到達可能になったため。remote branch は GitHub 側の自動削除設定で既に削除されていた。 |

保持: `workspace-overview` branch とその worktree (`.worktrees/20260817T154253-d1ea1c1`)。理由は上記「保留にした作業単位」を参照。

### 検証

PR #3 のブランチ tip に対して、ローカル (aarch64/x86_64 の macOS 開発機) と CI
(GitHub Actions, `x86_64-linux`) の両方で `nix run .#test` 相当を実行した。

- ローカル: exit status 0、4487 total、4486 passed、1 skipped、0 todo、
  0 failed、0 errored。前回記録した PTY 4件の失敗はこの回では再現しなかった
  （テスト内容・実装は今回変更していないため、環境依存の非決定性と考えられる。
  再現条件の切り分けは別作業として残る）。
- CI: `nix flake check` が `checks.x86_64-linux.default` で fail。原因は
  `renderer-suite/tui-kit > keeps the mandatory overview scale within the
  initial and scroll budgets` の 1 件で、`initial-frame-ms` が 116（予算 100）
  だった。2 回連続で同じ結果・同じ margin。このベンチマークテストは
  `8351773`（前回セッションの実装、今回の変更内容には含まれない）に既に存在し、
  origin へ push されたのは今回の PR #3 が初めてであり、CI で実行されたのも
  今回が初めてだった。ローカルでは同テストを含めて 0 failed だったため、CI
  ハードウェアの速度に対して 100ms の予算が厳しすぎる環境依存の失敗である
  可能性が高いが、確定はしていない。予算値やテスト自体は変更していない。
  ユーザーの判断により、この CI 失敗を記録した上で PR #3 を merge した。

この CI 失敗の原因切り分けと、必要であれば予算値の見直しは、別作業として残る。
今回の統合では、この失敗を隠すための実装変更やテストの弱体化は行っていない。

## 2026-08-19 workspace-only 化

このセクションは、上記までの記録とは別のセッション・別の作業単位を記録する。
上記の PTY テストのベースラインおよび CI ベンチマーク失敗の記述、直前セクションの
「保留にした作業単位」に書かれた `workspace-overview` branch の保持状態は、この
セッションの開始時点で既に古い。`workspace-overview` branch と、それを指していた
worktree (`.worktrees/20260817T154253-d1ea1c1`) は、このセッション開始前の時点で
既にどこにも存在しないことを確認した
(`git branch -a` に該当なし、`git cat-file -t 97ebf05` は `Not a valid object
name` で失敗)。保持を判断した経緯自体は上記セクションの記録として残すが、現在の
保持対象ではない。

この節は branch `feat/workspace-only-phase2` 上の5 commitを記録する
(`git log --oneline 9082bf7^..HEAD` で再現できる)。

| commit | 内容 |
| --- | --- |
| `9082bf7` | reasoning/dataflow の read-model を optional system として切り出す |
| `d3e8fc5` | tmux control mode (`-C`) を削除する |
| `3a78ce1` | CLI のエントリ面を `attach`/`server` に縮小する |
| `5379e4f` | tmux keystroke と command の fallthrough を削除する |
| `2a5fa47` | tmux command table と keystroke pipeline を削除する |

この5 commitの結果、nerimux は workspace-only (organization → repository →
worktree → pane) のマルチプレクサになった。除去されたのは次の各要素である。

- tmux command table 全体 (`src/application/dispatch/`)。`%cmd-*` handler、
  dispatch table、`dispatch-command` を含む。
- tmux keystroke pipeline (`src/presentation/events/`)。prefix key、key
  table、mouse dispatch、CPS key-stream parser を含む。
- control mode (`-C` / `nerimux control`)。
- 単体で動く standalone multiplexer。引数なしの `nerimux` は usage を出して
  非 0 で終了する。
- `attach`/`server` 以外の CLI subcommand。`new-session`、`has-session`、
  `kill-server`、`list-sessions` などは CLI からもコマンドプロンプトからも
  解決しない。
- `src/bootstrap/client-command.lisp`、`src/reasoning/command-rulebase.lisp`。

`find src -name '*.lisp' | wc -l` は今日時点で 181、`find t -name '*.lisp' |
wc -l` は 240 を返す。統合直前の状態からの差分は
`git diff --shortstat 9082bf7^..HEAD` で確認できる (このセッションで実行した
結果は 240 files changed, 1164 insertions(+), 26592 deletions(-))。

この削除に伴い、以下の2点は「実装が消えた」ケースと「配線だけ失われ実装は残る」
ケースを分けて確認する必要があった。

1. `server-access`(read-write/read-only の ACL command) は
   `src/application/dispatch/commands/dispatch-commands-server.lisp` ごと
   完全に削除された。`grep -rn server-access src/` は
   `src/application/config/config-commands.lisp` の `*known-command-names*`
   (bind-key target を検証する文字列リスト) にしか一致せず、実装は存在しない。
2. `attach-session -r` は wire flag (`+attach-flag-read-only+`,
   `src/infrastructure/net/protocol.lisp`) と server 側の per-connection
   enforcement (`client-conn-read-only-p`,
   `src/bootstrap/server-multi-dispatch.lisp`) の両方をそのまま残している。
   削除されたのは CLI 側の `-r` flag parsing だけであり、`*client-read-only*`
   (`src/bootstrap/runtime.lisp`) を non-nil にする経路がどこにもなくなった。
   つまり「削除」ではなく「配線を失って到達不能になった」状態である。
   （2026-08-23 註: この wire flag と enforcement はその後完全に削除された。
   `grep -rn "client-conn-read-only-p\|attach-flag-read-only" src/ t/` は
   0 件。現状は `docs/src/reference/security-model.md` が正。）

この区別と、影響を受けた他の claim (dispatch/events 由来の Sprint 1〜3 の各
機能) の詳細な突き合わせは `docs/notes/permissions-and-verification.md` の
冒頭注記と `docs/notes/coverage-audit-history.md` の該当箇所の "Since
removed" 注記、および公開ドキュメントの
`docs/src/reference/compatibility.md`(Removed節。2026-08-23 註: このファイルは
その後削除され現存しない) と
`docs/src/reference/security-model.md`(No access control beyond the socket
boundary節) に記録した。`docs/src/reference/security-model.md` は
`nix build .#docs`(`mkdocs build --strict`) で exit code 0 を確認済み。

## 2026-08-23 attach 導線の修復

このセクションは、全導線を実バイナリで駆動する E2E 検証で見つかった欠陥の
修復と、その main への反映・掃除を記録する。

### 統合した作業単位

すべて PR #10 (`fix/workspace-flow-repairs`、merge commit `0710baf`) の
1 commit = 1 作業単位。

| commit | 内容 |
| --- | --- |
| `eb47977` | `organization-recompute-counts` の `mapcan` が worktree リストを破壊的連結し、同一 organization に 2 個目のリポジトリが入ると循環リスト化してカタログスキャンが無限ループしていたのを修正 |
| `471c37d` | attach の server 自動起動が argv[0] を再実行していたのを修正。SBCL の C ランタイムは消費済みの `--core` を `*posix-argv*` から除去するため、Nix ラッパー構成では素の SBCL REPL が起動し自動起動は一度も動作していなかった |
| `7dba857` | serve loop が select の readiness 1 回につき 1 フレームしか読まず、1 回の read(2) でストリームバッファに合体吸収された後続フレーム(attach 直後の `:attach-target` など)が次のキー入力まで放置されていたのを、`listen` によるドレインで修正 |
| `d8bfe0f` | ghq ルート内の読めないリポジトリ 1 個でスキャン全体が中断しカタログが無言で空になっていたのを、エントリ単位で隔離し missing フラグ表示に変更 |
| `877fe28` | カタログはスキャン完了時点で存在するのに、全リポジトリの status 取得完了まで画面が dirty にならず「scanning...」のままだったのを、`:on-catalog` フックで即時描画に変更 |

### 検証

- ローカル (macOS) ではテストスイートが実行不能(既知の SBCL 停止問題)の
  ため、検証は「built binary を PTY で駆動する導線スイート」で行った:
  CLI フラグ/usage、server の socket 生成、attach 自動起動、ツリー操作、
  pane 起動とシェル往復、detach/reattach、picker、セレクタ/パス attach、
  kill 拒否と `--force`、実 ghq ルート(92 リポジトリ)のカタログ描画、の
  35 項目。単一走行で 34/35、残る 1 項目 (picker Enter) も独立 3 走行で
  PASS を確認した。揺らぎは記録済みの macOS 固有スレッド停止によるもの。
- `scripts/checks` の静的検査 4 種と `nix build .` はローカルで exit 0。
- canonical gate は PR #10 の CI (`nix flake check`, x86_64-linux) で pass。

### 削除した worktree / branch

| 対象 | 種別 | 削除理由 |
| --- | --- | --- |
| `.worktrees/20260821T101817-dcdd4fb` | worktree (detached, dcdd4fb) | 変更なし、固有の作業なし。 |
| `origin/update_flake_lock_action` | remote branch | 2026-08-17 作成の flake.lock 更新で、workspace-only 化以前のツリーが前提。open PR もなく、main 側の lock が既に更新済みで陳腐化していた。定期 workflow が必要になれば再生成する。 |
| `fix/workspace-flow-repairs` | local + remote branch | PR #10 merge 済みで main から到達可能。 |

作業に使った worktree (`.worktrees/20260823T003126-08c9aa0`) と docs branch
は、この記録を含む docs 反映が main に到達したのを確認してから削除する。

### 残る注意点

- `t/e2e/e2e-smoke.lisp` は削除済みの standalone mode と `C-b` prefix を
  前提にしており、現在のエントリ面では成立しない。`attach`/`C-q d` 前提の
  書き直しが別作業として残る(docs/src/getting-started.md にも現状を記載)。
- `nerimux kill` の拒否メッセージ先頭に wire プロトコルの status token
  (`DENIED`) がそのまま混入して表示される。表示崩れのみの軽微な問題。
- 修正 5 件はいずれも既存の単体スイートでは到達できない形の欠陥だった
  (単一リポジトリのフィクスチャ、ラッパー経由でのみ発現、TCP セグメント
  分割依存、実環境の壊れたクローンが必要)。回帰テスト化は別作業として残る。
- バージョン表記が三つ巴で食い違っている: `nerimux -V` は 0.1.0、
  `nerimux.asd` は 0.3.0、最新 tag は v0.2.0。どれを正とするかの整理が
  別作業として残る(README のピン例は最新 tag の v0.2.0 に合わせた)。
- `src/presentation/renderer/renderer.lisp` ヘッダの "File layout" 一覧が
  現在のファイル構成と一致していない(コメントのみの陳腐化)。
