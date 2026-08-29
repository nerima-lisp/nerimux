# Permissions matrix and verification record

> **Historical document.** This recorded the ACL/permissions verification
> before the tmux command table and keystroke pipeline were removed (branch
> `feat/workspace-only-phase2`, commits `d3e8fc5`..`2a5fa47`). `server-access`
> — the read-write/read-only ACL command this file's matrix and test table
> are built around — no longer exists anywhere in the tree: it lived in
> `src/application/dispatch/commands/dispatch-commands-server.lisp`, which was
> deleted along with the rest of `src/application/dispatch/` (the whole tmux
> command table). Most of the file:line citations below (the dispatch,
> events, and command-test files) point at files that no longer exist;
> `grep -rn server-access src/` today finds only a leftover string in
> `*known-command-names*` (`src/application/config/config-commands.lisp`),
> which validates `bind-key` targets and does not implement anything.
>
> (That file has since been deleted with the rest of the key-table subsystem;
> the note is kept as the historical record of the audit.)
>
> What is still true today: `attach-session -r`'s wire flag
> (`+attach-flag-read-only+` in `src/infrastructure/net/protocol.lisp`) and
> the server's per-connection enforcement (`client-conn-read-only-p` in
> `src/bootstrap/server-multi-dispatch.lisp`, gating pane input at lines 80
> and 904) both still exist and still work if a connection's flags byte sets
> the bit. But nothing in the current CLI sets it any more — the surviving
> entry surface is `attach`/`server`/`-V`/`-h`
> (`src/bootstrap/main-startup-commands.lisp`), and `attach-session -r`
> parsing is gone with the rest of the command table. Nothing sets
> `*client-read-only*` to non-nil anywhere in the tree any more; it stays
> permanently `nil`. (`src/bootstrap/client.lisp`'s comment there described the
> old `attach-session -r` writer; it was corrected in the same change that added
> this note.) See
> The compatibility statement was intentionally removed with the obsolete
> command surface. The socket-directory boundary this
> file also describes (mode `0700`, per-user directory) is unaffected and is
> current — see [the published security model](../src/reference/security-model.md).
>
> The body below is left as-is, as a record of what was verified at the time
> it was written. Do not treat any file:line reference below as current.

この記録は、nerimux の「実際に接続を許す境界」、接続後の client mode、
server-access が保持する ACL モデルを分けて説明する。docs/mkdocs.yml の
方針により docs/notes/ は公開ナビに載せない作業記録である。

## 結論

実効的な最初の境界は server socket の親 directory である。socket directory は
per-user directory として mode 0700 で作られ、そこへ書き込めるプロセスは server
owner の権限でコマンドを実行できる。socket に到達した後の attach-session -r は
接続単位の pane input 制御であり、OS の socket 認証や multi-user authorization
の代替ではない。

server-access の :read-write / :read-only は command と config round-trip の
ために保持される ACL 状態である。現在の実装は single-user server を前提にしており、
この ACL list 自体が socket 接続を拒否する実効ゲートにはなっていない。

## 権限マトリックス

| 主体または状態 | 到達条件 | 画面・状態の閲覧 | pane への key / paste / mouse | server / client 操作 | 実効境界と注意点 |
| --- | --- | --- | --- | --- | --- |
| socket directory に到達できる OS process | per-user socket directory に書き込めること | server が返す対象範囲 | 通常 client と同じ protocol 能力 | server owner として実行可能 | OS の file permission が最重要の境界。socket に書ける主体を protocol 内の ACL だけで制限しない |
| socket directory に到達できない OS process | 0700 directory の外側など | server socket 経由では不可 | 不可 | 不可 | socket の場所を知っているだけでは接続できない。別の OS 権限昇格や直接 process access はこの表の範囲外 |
| 通常の attached client | attach frame に read-only flag なし | 接続中の screen / status / frame | 許可。pane の live 状態や pane option による追加制限は受ける | protocol が受け付ける通常の client 操作 | msg-attach の flags が read-only でない場合の通常経路 |
| attach-session -r の attached client | CLI の -r が attach frame の read-only bit になること | screen / status / server frame の受信 | 不可。key、paste、mouse の pane forwarding を抑止 | detach、resize など接続管理は read-only pane input と別管理。socket の server command 全体を認証する mode ではない | client-read-only を dispatch と input forwarding に bind する接続単位の制御 |
| server-access の :read-write entry | server-access -a USER または -w USER | ACL list 上で read-write と表示 | attach client の mode は変更しない | 実際の socket authorization は付与しない | single-user 実装の modeled ACL。通常 client の read/write 能力を自動生成する role ではない |
| server-access の :read-only entry | server-access -a -r USER または -r USER | ACL list 上で read-only と表示 | attach client の pane input は変更しない | 実際の socket authorization は付与しない | server-access の read-only と attach-session -r は別の状態である |
| pane の child process | server が PTY を fork して pane に関連付けること | 自分の stdout / stderr が PTY reader 経由で screen に反映 | 自分の stdin は client input の結果を受ける | socket access は child process の OS file permission 次第 | child process は ACL role ではない。PTY output は terminal emulator が解釈する入力データ |

### 実装上の根拠

- docs/src/reference/security-model.md:13-19 は socket directory mode 0700 を security
  boundary とし、socket に書ける主体が server owner として操作できることを明記する。
- src/application/dispatch/commands/dispatch-commands-server.lisp:3-16 は
  server-access を single-user の modeled ACL と説明し、permission value を
  :read-write / :read-only と定義する。
- src/application/dispatch/commands/dispatch-commands-server.lisp:49-56 は add、delete、
  list、-r、-w の command semantics を定義する。
- src/bootstrap/main-startup-flags.lisp:63-67 と
  src/bootstrap/main-startup-commands.lisp:44-49 は CLI の -r を
  client-read-only に変換する。
- src/bootstrap/client.lisp:109-112 は attach flag を msg-attach の flags byte に
  搬送する。
- src/bootstrap/server-multi-dispatch.lisp:37-40 は flags byte から connection 単位の
  read-only slot を復元し、同ファイル :72-92 は client key dispatch に
  client-read-only を bind する。
- src/presentation/events/events-loop-timers.lisp:128-129,174-178、
  src/presentation/events/events-mouse-passthrough.lisp:23-25、
  src/application/dispatch/handlers/dispatch-handlers.lisp:214-215 は key、paste、
  mouse、prefix の pane write を read-only 時に抑止する leaf guard である。
- src/infrastructure/net/protocol.lisp:162-182 は attach payload の optional flags と
  read-only bit を wire protocol として定義する。

## 権限関連テスト

以下は nix run .#test の full suite に含めて実行したテスト群である。ソース位置は
「何を検証しているか」を追跡するための証跡であり、個別のテストだけを実行したという
意味ではない。

| 観点 | テスト | 検証内容 |
| --- | --- | --- |
| ACL add | tests/unit/application/commands/commands-tests-d.lisp:111-121 server-access-add-permission-table | default add が :read-write、-r add が :read-only になること |
| ACL modify | tests/unit/application/commands/commands-tests-d.lisp:124-139 | -w による既存 entry の変更と、未知 user を勝手に作らないこと |
| ACL delete/list | tests/unit/application/commands/commands-tests-d.lisp:142-163 | delete が対象だけを消し、list が overlay に name と permission を出すこと |
| ACL reject | tests/unit/application/commands/commands-tests-d.lisp:166-176 | 未実装 flag / extra positional を拒否し、ACL list を変更しないこと |
| wire round-trip | tests/unit/infrastructure/net/protocol-tests.lisp:83-100 | read-only attach flag の encode/decode と、flags 省略時の zero/default |
| wire layout | tests/unit/infrastructure/net/protocol-binary-layout-tests.lisp:105-120,159-171 | read-only bit が bit zero であること、4/5 byte payload の decode |
| connection state | tests/integration/server-multi-tests-message-dispatch.lisp:401-416 | attach flag が connection slot に入り、plain attach で解除されること |
| connection input gate | tests/integration/server-multi-tests-message-dispatch.lisp:418-430 | read-only connection の printable key が pane write にならないこと |
| event forwarding | tests/unit/presentation/events/events-tests-h.lisp:84-119 | read-only では synchronized forwarding が no-op、通常時は write 経路を通ること |
| session/pane dispatch | tests/unit/application/dispatch/dispatch-tests-session-d.lisp:165-187、tests/unit/application/dispatch/dispatch-tests-pane-window-prefix.lisp | read-only client の prefix / pane-window input 抑止 |
| startup parsing | tests/unit/bootstrap/main-tests.lisp | attach startup flag が read-only client state になること |

## 実施したテストと結果

### 1. ベースライン

実装を統合する前の clean main worktree で次を実行した。

~~~text
nix run .#test
~~~

exit status は 1。選択件数は 4436 で、4431 passed、1 skipped、0 todo、
4 failed、0 errored だった。失敗は次の4件である。

~~~text
pty-suite > shell-echoes-command-output
pty-suite > pty-write-accepts-octet-vector
pty-suite > select-times-out-when-idle
pty-suite > pty-child-exit-status-reports-signaled-kind
~~~

### 2. 実装・lock 統合後の full suite

同じコマンドを統合後に二度実行した。

~~~text
nix run .#test
nix run .#test
~~~

二回とも exit status は 1。各回の結果は 4487 total、4481 passed、
1 skipped、0 todo、5 failed、0 errored だった。新しいテストを含むため、
ベースラインから選択件数が 51 増えている。

二回とも失敗した5件は、ベースラインの4件と次の新規シナリオである。

~~~text
multi-socket-renders-live-pty-output
~~~

新規シナリオは、実 PTY に shell command を書き込み、reader loop、screen model、
socket frame の順に live output が現れることを確認する。失敗は screen text に marker
が見つからない assertion だった。ベースラインの PTY write / shell echo 失敗と同じ
実行経路に依存するため、二度の再現は確認できたが、renderer 単独の回帰とは切り分け
られていない。PTY の既知失敗を理由に test を skip したり、timeout を緩めたりはして
いない。

### 3. 差分と成果物の検査

| コマンドまたは検査 | 結果 |
| --- | --- |
| git diff --check | exit status 0。統合差分に whitespace error なし |
| workspace commit hook の secret scan | 各 commit で scan 実行、leak なし |
| git cherry-pick を作業単位ごとに実行 | workspace、既存 lock、依存 lock の各 commit が conflict なしで適用 |
| lock の評価 | workspace input の不足分だけを依存 lock commit に分離 |

## 判定と未解決事項

- 権限マトリックスに記載した ACL、wire flag、connection state、input suppression の
  テストは full suite の選択範囲に含まれ、全体結果の passed 側に含まれている。
- full suite 自体は exit status 1 であり、green ではない。ベースラインから継続する
  4件に加え、live PTY output を利用する新規1件が同じ条件で再現している。
- 新規失敗の修正は今回の統合作業の範囲に含めていない。実装回帰と PTY / shell 実行
  環境の差を、失敗を隠さずに別途切り分ける必要がある。
- docs/notes/ は公開 site の nav 外にあるため、このマトリックスを公開ドキュメント
  に載せる場合は、別途 docs/src/ のページ追加と nav 更新が必要になる。
