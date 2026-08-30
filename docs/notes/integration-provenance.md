# Integration provenance: deleted worktrees, deferred work, and verification baselines

> **Salvaged from the old `EXECUTION.md`.** The previous `EXECUTION.md` was a
> 407-line work journal that mostly duplicated git history (integrated work
> units, commit contents, diff/commit-inspection results); that part is not
> reproduced here since `git log` already carries it. This file keeps only
> what git history alone cannot reconstruct: why specific worktrees and
> branches were deleted, work that was deliberately deferred and why,
> authorization/verification checks that were actually performed, and the
> fact and scope of baselines that were red at integration time.
>
> **`EXECUTION.md` is gone as of 2026-08-31.** It held the parallel-execution
> runbook for the `packages/` reorganisation — W0 through W6 and the Phase 2
> preview. Every wave it directed is on main, so it had stopped being an
> instruction and started reading as an unstarted plan. Recover it with
> `git show 9742b8e:EXECUTION.md`; the repository standard also wants only
> `README.md` and `LICENSE` at the root.

## 1. 削除した worktree / branch とその由来

過去の統合セッションで削除した worktree / branch と、削除に至った理由。

| 対象 | 種別 | 削除理由 |
| --- | --- | --- |
| `.worktrees/20260817T134857-d1ea1c1` | worktree (detached, `d1ea1c1`) | 変更なし。main の祖先 commit と同一だった。 |
| `.worktrees/20260817T145609-d1ea1c1` | worktree (detached, `d1ea1c1`) | commit 差分なし。未追跡の `EXECUTION.md` 草稿（workspace UI/UX 仕様）のみ保持していたため、内容を `docs/notes/workspace-ui-ux-design.md` として保存した上で削除した。 |
| `.worktrees/20260817T164626-d1ea1c1` + `feat/rename-cl-prolog-dataflow-kit` | worktree + branch | 内容が origin/main とローカル main の両方から到達可能になったため。 |
| `.worktrees/20260818T-integration` + `integration/current-work-units` | worktree（conflict 未解決）+ branch | rename 作業とローカル main を統合した上で `workspace-overview`（§2 参照）を merge しようとして 5 ファイルが conflict したまま放置されていた。`workspace-overview` 自体の統合を保留したため、この試みは前提から不要になった。 |
| `.worktrees/20260818T054124-172a36a` | worktree (detached, `172a36a`) | 既に origin/main に含まれる merge commit を見ているだけで、固有の変更はなかった。 |
| `.worktrees/20260818T055112-02d8c09` + `sync/local-main-to-origin` | worktree + branch | PR #3 が merge 済みで、内容が main から到達可能になったため。remote branch は GitHub 側の自動削除設定で既に削除されていた。 |
| `.worktrees/20260821T101817-dcdd4fb` | worktree (detached, `dcdd4fb`) | 変更なし、固有の作業はなかった。 |
| `origin/update_flake_lock_action` | remote branch | 2026-08-17 作成の flake.lock 更新用ブランチで、workspace-only 化以前のツリーが前提だった。open PR もなく、main 側の lock が既に更新済みで陳腐化していた。定期 workflow が必要になれば再生成する。 |
| `fix/workspace-flow-repairs` | local + remote branch | PR #10 merge 済みで main から到達可能になったため。 |
| `feat/2026-modernization-sweep` | local branch | セッション序盤に誤って `origin/main` から切ったもの。固有 commit 0 件で、失われる作業はなかった。 |
| `.worktrees/20260825T105830-72ed86e` + `feat/2026-cl-modernization` | worktree + branch | 12 commit の作業場所。main へ fast-forward 済みで到達可能になったため。 |
| `.claude/worktrees/agent-ad661d28264190b8c` | worktree | renderer 作業を main へ merge済みだったため。 |
| `.worktrees/20260826T110109-ff18608` | worktree | verification 作業を origin/main へ反映済みだったため。 |
| `.worktrees/20260826T194620-0eca538` | worktree | 作業を origin/main へ反映済みだったため。 |
| `.worktrees/20260826T234726-35a41d6` | worktree | overview 作業を origin/main へ反映済みだったため。 |
| `feat/e2e-verification`, `feat/overview-redesign-pr2`, `feat/startup-ux-pr1`, `fix/frame-crlf`, `fix/verification-round-2`, `worktree-agent-ad661d28264190b8c` | local branch | いずれも main から到達可能になったため。 |
| `.worktrees/20260829T233033-106ba3a-w1-a` + `wave-a-w1-a`、`-w1-b1` + `wave-a-w1-b1`、`-w1-b2` + `wave-a-w1-b2`、`-w1-c` + `wave-a-w1-c`、`-w1-d` + `wave-a-w1-d`、`-w2-a` + `wave-a-w2-a`、`-w2-b` + `wave-a-w2-b`、`-w4-prep` + `wave-a-w4-prep`、`.worktrees/20260830T000401-wave-a-integration` + `wave-a-integration`、`.worktrees/20260830T011436-w3` + `w3-worktree-pane-decoupling`、`.worktrees/20260830T020916-0ee3dcb-w5-d` + `wave-b-w5-d`、`-w5-e` + `w6-bootstrap-separation`、`.worktrees/20260830T103130-bca1797`（detached、branch 無し） | worktree（+ branch） | `EXECUTION.md`（packages/ 再編・波計画）向けに割り当てられていたが、`git log origin/main` で確認したところ commit・未コミット変更のいずれも無く、割り当て後に着手されなかった。origin/main に対する固有 commit 0 件（`git rev-list --left-right --count origin/main...<branch>` で確認）。 |
| `.worktrees/20260829T223027-7adcf6d` + `w0-tests-rename-manifest-fix`、`.worktrees/20260830T020916-0ee3dcb-w5-c` + `wave-b-w5-c` | worktree + branch | 未コミットの変更が残っていたが、内容（`EXECUTION.md` および `src/application/picker/global-picker.lisp`）は origin/main の該当ファイルとバイト単位で同一だった。固有の未反映内容は無かった。 |
| `.worktrees/20260830T020916-0ee3dcb-w5-a` + `wave-b-w5-a`、`-w5-b` + `wave-b-w5-b`、`-w5-f` + `wave-b-w5-f`、`-w5-g` + `wave-b-w5-g`、`-w5-h` + `wave-b-w5-h` | worktree + branch | `EXECUTION.md` の Wave B / W5（facade 経由の `nerimux/model:` 参照をサブパッケージ参照へ置き換える作業）に対応する未コミット変更が残っていたが、`git log 0ee3dcb..origin/main` で確認した別経路（W5-a〜h 相当 + W5-z + W6 のコミット群）により、同じ作業が origin/main へ既に統合済みだった。差分の内容も同種の機械的シンボル置換に限られ（w5-a/b/f は 100%、w5-g/h も残りは同一種の `:use`/`:import-from` 再配分）、origin/main 側の版より粗い（例: w5-g の `package-application.lisp` diff は `:import-from` 節を重複記載していた）ことを確認した上で、固有の反映対象は無いと判断した。 |
| `.worktrees/20260830T110503-bca1797` + `feat/packages-reorg-phase2` | worktree + branch | packages/ 再編 Phase 2 の作業場所。PR #20 (`6d53a35`) として main へ merge 済み。 |
| `docs/2026-08-30-worktree-branch-cleanup` (local + origin) | branch | 上の 3 行を追記した作業単位そのもの。PR #21 (`89a98d5`) として main へ merge 済み。 |
| `/private/tmp/nerimux-perf-scratch/baseline-bca1797` | worktree (detached, `bca1797`) | Phase 2 のレビューで build/test 時間を移行前後で比較するために作った比較用。担当エージェントがセッション上限で中断し測定は未完。`git status` は空で、固有の作業は無かった。 |
| `docs/2026-08-29-worktree-branch-cleanup` (local + origin, `49ff67d`) | branch | **内容は main へ反映せず破棄した。** 2026-08-29 の棚卸し記録（detached worktree 4 件と `update_flake_lock_action` の削除理由）を `EXECUTION.md` の末尾へ追記する 38 行だったが、その `EXECUTION.md` は `1476d34` で作業日誌から packages/ 再編の手順書へ全面差し替えされており、追記先が別の文書になっていた。同種の記録は本ファイルが引き継いでいるため、手順書へ日誌を混ぜるより破棄が妥当と判断した。記録していた事実は「4 件の worktree はいずれも `7adcf6d` と同一で未コミット変更なし」「`update_flake_lock_action` は origin に存在せず対応 PR も無い使い捨てブランチ」の 2 点で、どちらも当時 main へ反映すべき作業を含んでいない。 |

## 2. 保留にした作業単位とその理由

`workspace-overview` branch（commit `97ebf05`）とその worktree
（`.worktrees/20260817T154253-d1ea1c1`）は、organization/repository/worktree/pane
の全画面 overview と worktree 操作（attach/lock/unlock/delete/prune）を実装していたが、
統合を見送った。

見送った理由: 当時の main の `render-session-to-string` は既に client 単位の
`:overview`/`:detail`/`:attention` view（`client-conn-view`、cl-tui-kit ベースの
`renderer-tui-kit.lisp` 経由）を実装済みだった。`workspace-overview` は同じ関数名を
session 単位の `workspace-mode-p` 分岐で上書きしようとする、独立に書かれた別
アーキテクチャで、ドメインモデルも `nerimux/model`（main）と `nerimux/workspace`
（この branch）で重複していた。機械的な merge では両者の分岐ロジックが同じ入口を
奪い合い、正しく動作しないコードになるため、統合を見送った。次に着手する際は、
まず `client-conn-view` 方式と `workspace-mode-p` 方式のどちらを正とするかを決め、
選ばれなかった側の呼び出しグラフ（renderer、dispatch、ドメインモデル）を書き換える
前提で見積もる必要がある。

その後の確認: 上記の保留判断をした時点より後のセッションで、この branch と worktree
は、そのセッションの開始前の時点で既にどこにも存在しないことを確認した
（`git branch -a` に該当なし、`git cat-file -t 97ebf05` は "Not a valid object name"
で失敗）。保留を判断した経緯自体はこの記録として残すが、`workspace-overview` は現在
保持対象ではなく、再開すべき作業としても存在しない。

## 3. 実施した権限・検証チェックの記録

- workspace runtime/picker、flake lock、workspace dependency lock の各 commit を
  作成した際、commit hook の secret scan が走り、各回 leak なしを確認した。
- 統合前後の差分に対して `git diff --check` を実行し、空白エラーなし・exit status 0
  を確認した。
- PR #3（ローカル main の origin 未反映分 4 commit を反映）は、ローカル (macOS
  aarch64/x86_64) と CI (GitHub Actions, `x86_64-linux`) の両方で `nix run .#test`
  相当を実行した上で merge された。CI 側では `renderer-suite/tui-kit` のベンチマーク
  テスト 1 件が赤だった（§4 参照）が、**ユーザーの判断により、この CI 失敗を記録した
  上で PR #3 を merge した**。予算値やテスト自体は変更しておらず、失敗を隠すための
  実装変更やテストの弱体化も行っていない。

## 4. 統合時点でベースラインが赤だった事実とその範囲

- **初回の統合前ベースライン**（当時の main の clean worktree、`nix run .#test`）:
  exit status 1、4436 total、4431 passed、1 skipped、0 todo、4 failed、0 errored。
  失敗していたのは次の既存 PTY ケース: `pty-suite > shell-echoes-command-output`、
  `pty-suite > pty-write-accepts-octet-vector`、`pty-suite > select-times-out-when-idle`、
  `pty-suite > pty-child-exit-status-reports-signaled-kind`。
- **その統合後の検証**（同じ木で `nix run .#test` を二度実行): 二回とも exit status 1、
  4487 total、4481 passed、1 skipped、0 todo、5 failed、0 errored（workspace 側の
  テスト追加で選択数が 51 増えている）。失敗は上記 4 件に加え
  `multi-socket-renders-live-pty-output` の 1 件。二回とも同じ結果だったが、これは
  再現性の証拠であって renderer 単独の回帰と断定する証拠ではないと当時記録されている
  （同じ live PTY 出力経路で既存の PTY ケースも失敗していたため）。
- **PR #3 の branch tip での検証**: ローカルでは exit status 0、4487 total、4486 passed、
  1 skipped、0 todo、0 failed、0 errored（前述の PTY 4 件はこの回では再現せず、環境
  依存の非決定性と判断された）。CI (`nix flake check`, `checks.x86_64-linux.default`)
  では `renderer-suite/tui-kit > keeps the mandatory overview scale within the initial
  and scroll budgets` が赤だった（`initial-frame-ms` が 116、予算 100、2 回連続で同じ
  結果・同じ margin）。このベンチマークテスト自体はこの統合より前から存在しており、
  origin へ push・CI 実行されたのはこの統合が初めてだった。ローカルでは同テストを
  含めて 0 failed だったため、CI ハードウェアの速度に対して 100ms の予算が厳しすぎる
  環境依存の失敗である可能性が高いが、確定はしていない。
- **別セッション**（実欠陥の修正とマクロ集約を行ったセッション）: `internal-call-check.pl`
  は exit 1 だったが、その回のベースラインと同一の 9 件で増減はなかった。原因は
  `define-window-records` マクロ経由で定義される `%split-spec-*` を、checker が
  `:conc-name` から学習できないことによる既知の偽陽性で、ゲートを緩めずにその状態の
  まま残された。フィルタ無しのフルスイートはそのマシンで実行不能（既知の SBCL GC
  デッドロック、そのセッションの変更とは無関係）で、canonical gate の
  `nix flake check` も同じ理由でそのセッションでは実行されなかった。
- **別セッション**（attach 導線の修復を行ったセッション）: ローカル (macOS) では
  テストスイートが実行不能（既知の SBCL 停止問題）だったため、検証は built binary を
  PTY で駆動する導線スイート（CLI フラグ/usage、server の socket 生成、attach
  自動起動、ツリー操作、pane 起動とシェル往復、detach/reattach、picker、セレクタ/パス
  attach、kill 拒否と `--force`、実 ghq ルート(92 リポジトリ)のカタログ描画、の 35
  項目）で代替された。単一走行で 34/35、残る 1 項目（picker Enter）も独立 3 走行で
  PASS を確認しており、揺らぎは記録済みの macOS 固有スレッド停止によるものと判断
  された。
