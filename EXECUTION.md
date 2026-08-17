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
