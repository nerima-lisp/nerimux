# Workspace 縮約フェーズ 3 の要件

> **【キーバインドは supersede 済み】** 本書のキー表（`C-q F` / `C-q C-f` / `i` /
> `j/k` / `r` / `X` / `L` / `U` ほか）は magit 準拠への全面置換で無効になった。
> 現行のキーは `+HELP-VIEW-SECTIONS+`（`src/presentation/renderer/renderer-tui-kit-help.lisp`）
> と、それが記述する 3 つの実表 — `%HANDLE-CLIENT-UI-KEY-PAYLOAD`、
> `%WORKSPACE-PREFIX-DISPATCH`、`+TRANSIENT-DEFINITIONS+` — を正とする。
> 本書のキー表は「当時何を決めたか」の記録として残す。**現行仕様として読まないこと。**
> R5/R6/R7 の pane・fetch・worktree の**振る舞い**は今も有効で、変わったのは入口のキーだけ。

このファイルは、`docs/notes/workspace-ui-ux-design.md` が定義した UI/UX 契約と現在の
実装との差分を測り、21 巡のヒアリングで決めた作業要件である。`docs/notes/` にあるため
公開サイトには含まれない（`flake.nix:403` の docs fileset は `docs/mkdocs.yml` と
`docs/src` だけを見る）。

測定は 2026-08-21 の `main`（`9ccb4c5`）に対して行った。数値は当時のもので、着手前に
再測定すること。

**このセッションでは実装を行わない。この文書の確定までが範囲である。**

## 1. 決定事項

すべてユーザーの明示的な選択である。**再提案しないこと。**

### 1.1 方向

| 項目 | 決定 |
| --- | --- |
| pane 分割層 | **UI に配線する。** 真のマルチプレクサとして完成させる |
| 設定ファイル | **持たない。** 設定機構を全廃し、全てハードコードする |
| clipboard | **OSC 52 のみ。** paste buffer を持たない |
| 矢印キー | **判定を捨てる。** 移動は `j` / `k` / `h` / `l` と prefix のみ |
| multi-session | **削除。** session を 1 つに固定する |
| mouse | **完全に撤去する** |
| アラート | **全廃。** monitor-activity / bell / silence、visual-bell とも |
| tmux への言及 | **全部消す。** コメントの根拠は仕様の中身で書き直す |
| バージョン | 全完了後に **0.3.0** を切る |

### 1.2 削除するもの

prompt 編集 API、pipe-pane、hooks（全廃）、paste buffer、multi-session、mouse、
attention view、状態の永続化、dataflow optional system、`runtime-history.lisp`、
overlay / popup / menu、`runtime-timer.lisp`、`window-rotate`、`apply-named-layout`、
`tags` / `notes` / `recent-activity`、read-only attach（`-r`）、detach-others、
`remain-on-exit`、CLI の tmux 由来フラグ、benchmark の予算テスト。

### 1.3 残すもの

copy-mode（検索 `/` `n` `N` を含む）、global picker、overview / detail の 2 view、
server log、terminal emulator の周辺機能（DCS / OSC color / OSC uri / charset /
CSI replies / truecolor）。

emulator の周辺機能は「消せる機能」ではなく端末としての正しさである。CSI 応答を
返さないと TUI アプリが固まり、DCS を解釈しないと sixel が画面に漏れる。

### 1.4 固定する値

| 項目 | 値 |
| --- | --- |
| pane のシェル | `$SHELL`、未設定なら `/bin/sh` |
| pane の `$TERM` | `screen-256color`。加えて `COLORTERM=truecolor` を渡す |
| pane 終了時 | 即座に閉じる |
| scrollback | 10,000 行 |
| 分割サイズ | 常に 50/50 |
| window あたりの pane | 最大 4。超える分割要求は新しい window を作る |
| window / pane の番号 | 1 始まり |
| window の名前 | branch 名 + 連番 |
| tree の初期状態 | 全折りたたみ（organization の行のみ） |
| status line | 下に 1 行固定 |
| pane border | 細線、アクティブは色。ラベルなし |
| copy-mode | 選択は反転。行番号 OFF。検索は折り返す |
| 端末の最小サイズ | 40 x 10。下回ったら全画面の警告 |
| socket | `$TMPDIR` → `/tmp` の per-UID ディレクトリ（mode 0700）、名前は固定 |
| server log | 1 MB を超えていたら起動時に新規作成 |
| 複数 client | 許す。サイズは最小の client に合わせる |
| worktree の path | `<repo>.git/.worktrees/<作成時刻>-<start point の short sha>` |
| wt-create の start point | repository の既定 branch の先端 |
| 端末タイトル | `nerimux: <repository> — <worktree>` |

`$TERM` は emulator の実装に合わせた。SGR の truecolor は
`sgr.lisp:134-181` に実装済みで、`38;2;R;G;B` / `48;2` / `58;2` のセミコロン形式と
コロン形式（colourspace-id の読み飛ばしを含む）の両方を扱う。`screen` のままだと
8 色しか広告しないため、実装済みの能力を名乗れていなかった。

### 1.5 キー

`C-q` を本物の prefix に格上げする。prefix を受けた次のキーは必ず prefix table で
解決し、未束縛なら破棄する。

| prefix キー | action |
| --- | --- |
| `C-q -` | 上下に分割（区切り線が水平）。`layout.lisp` の `:v` |
| `C-q \|` | 左右に分割（区切り線が垂直）。`layout.lisp` の `:h` |
| `C-q x` | pane を閉じる |
| `C-q z` | zoom を切り替える |
| `C-q h/j/k/l` | pane のフォーカス移動 |
| `C-q n` / `C-q p` | **現在の worktree の** window を前後に循環 |
| `C-q F` | 選択中の repository を fetch |
| `C-q C-f` | 選択中の organization 配下を fetch |
| `C-q d` | detach |
| `C-q Q` | server を終了（確認ビュー経由） |
| `C-q C-q` | `:normal` へ戻る |

`:normal` モードの素キーは現状のまま残す（`o` overview / `d` detail / `i` input /
`c` copy-mode / `r` refresh / `n` `X` `L` `U` / `C-p` picker / `j k h l` / `Enter`）。
attention view を削除するので `a` は解放される。

### 1.6 CLI

入口は `attach` / `server` / **`kill`** の 3 つ。グローバルフラグは **`-V` と `-h` だけ**
（`-r` を削除し、socket フラグ `-L` / `-S` も削除した結果）。「入口は 2 つだけ」という
現在の契約は変わるので README と `docs/src/` を更新する。

## 2. 現状の測定

`find src -name '*.lisp' | wc -l` が 159、合計 24,683 行。パッケージ 28、`t/` は 226 ファイル。

### 2.1 本番で壊れている経路

**入力が 1 バイトずつしか届かない。** クライアントは `%forward-stdin-byte`
（`client.lisp:34-37`）で stdin を 1 バイト読み `(msg-key (vector stdin-byte))` として
送るが、サーバは矢印キーを 3 バイト列 `#(27 91 65)` で判定する
（`server-multi-dispatch.lisp:854`）。`%client-key-sequence-p` は `equalp` なので
**本番では決して一致しない**。

- `:input` モードで矢印を押すと先頭の ESC が単独で届き、`:915` が input モード脱出と
  解釈する。**pane 内で矢印を押すと workspace に蹴り出される。**
- `:copy` モードでも同様に ESC で抜ける（`:943`）。

テストは緑である。3 バイト payload を `%handle-multi-key-message` へ直接渡しており
（`t/integration/server-multi-tests-message-dispatch.lisp:773`）、唯一の本番プロデューサ
である `client.lisp` を経由していない。

**server を停止する手段がない。** `%run-multi-server-loop`（`server-multi-loop.lisp:83-88`）
は `:quit` か `%exit-when-empty-p` でしか止まらないが、`:quit` を返す分岐が `src/` に
1 つもない（`server-multi-dispatch.lisp:1849` は docstring での言及のみ）。
`%exit-when-empty-p` は `*server-sessions*` が空になることを条件にするが、
`server-remove-session` の呼び出し元は 0 件で session は減らない。

**`pane-mark-startup-failure` が呼ばれていない。** `pane-core.lisp:96` に定義があるが
呼び出し元 0。兄弟の `pane-mark-output` / `pane-mark-bell` / `pane-mark-process-exit` は
`runtime-reader.lisp:43,45,91` から呼ばれている。この非対称は「不要」ではなく
「呼び忘れ」を示す。起動失敗は `%open-client-worktree-pane`（`:495`）が握り潰して
一過性のメッセージを出すだけで、状態として残らない。

**workspace UI の桁計算が文字数ベース。** emulator 側は `%place-wide-char`
（`char-write.lisp:33`）と `char-width` で全角を 2 セルとして扱うが、
`renderer-workspace.lisp` の `clip` は `(length text)` で判定する。日本語を含む path や
branch で桁がずれる。

**`-r`（read-only）は名前ほど read-only ではない。** 抑止するのは pane への入力だけ
（`server-multi-dispatch.lisp:80,920`）で、worktree の削除・prune・lock は通る。

### 2.2 実装はあるが到達できない

| 対象 | 位置 | 証拠 |
| --- | --- | --- |
| `window-split` | `domain/model/window-core.lisp:207` | `src/` 内の呼び出し元 0（`t/` に 17 件） |
| `window-remove-pane` | `domain/model/window-tree.lisp:104` | 同 0（`t/` に 24 件） |
| `window-zoom-toggle` | `domain/model/window-operations.lisp:125` | 同 0（`t/` に 12 件） |
| `window-rotate` | `domain/model/window-operations.lisp:78` | 同 0（`t/` に 16 件） |
| `window-resize-active` | `domain/model/window-operations.lisp:41` | 同 0（`t/` に 5 件） |
| `apply-named-layout` | `domain/model/window-layout.lisp` | 同 0（`t/` に 54 件） |
| `pipe-pane-open` | `application/commands/commands-pipe-pane.lisp:57` | 自ファイル外 0 |
| `prompt-start` | `presentation/prompt/prompt.lisp:54` | 呼び出し元 0 |
| `show-popup` / `show-menu` | `presentation/prompt/overlay.lisp`（`define-singleton-overlay:85` が生成） | 呼び出し元 0。`make-popup` / `make-menu` はテストのみ |
| `add-hook` | `domain/hooks/hooks.lisp:75` | 呼び出し元 0。`run-hooks` は 9 箇所から呼ばれるが常に空のレジストリを回す |
| `server-current-session` ほか 3 つ | `bootstrap/session-registry.lisp` | 呼び出し元 0。session は `server.lisp:177` で 1 つ作られるだけ |
| `add-message-log` / `*message-log*` | `bootstrap/runtime-history.lisp:8,29` | 外部参照 0 |
| `tags` / `notes` / `recent-activity` | 4 モデル | 読み書きが全て `runtime-lifecycle.lisp` の save / restore 経路の中（`:136-247`、`:523-595`） |

`prompt-start` が呼ばれないため `prompt-active-p` は常に NIL。これを読む renderer の
4 箇所（`renderer-compose-overlay.lisp:33`、`renderer-statusbar.lisp:122,150,201`）は
常に偽の分岐で、grep 上は live に見えるが到達しない。

popup / menu は `define-singleton-overlay` が `intern` で `SHOW-POPUP` /
`CLOSE-POPUP` / `POPUP-ACTIVE-P` を生成するため、素の grep では定義が見えない。
**生成マクロを読んで初めて死んでいると確定できる。**

paste buffer（`domain/buffer/buffer.lisp`）は書き込み専用。copy-mode の yank
（`commands-copy-mode-clip.lisp:90`）と OSC 52 受信ハンドラ（`buffer.lisp:130`）が
積むだけで、pane に貼り戻す経路がない。

mouse は入力の転送経路自体がない。`mouse` オプションは store して warn するだけ
（`config-option-side-effects.lisp:56-60`）で、pane 側アプリが CSI 1000 / 1006 を
要求しても届かない。

設計文書 §5.1 は picker の検索対象に tags を含めよと書いているが、
`global-picker.lisp` は tags を読んでいない。保存して復元するだけで、誰も設定できず
誰も検索しないフィールドだった。

### 2.3 設定機構の規模

| 対象 | ファイル数 | 行数 |
| --- | --- | --- |
| `application/config` | 14 | 1,425 |
| `domain/format` | 13 | 1,797 |
| `domain/options` | 5 | 1,064 |
| 合計 | 32 | 4,286 |

撤去に必要な書き換え：

- `get-option` の呼び出しが `domain/options` の外に **90 箇所、37 ファイル、56 オプション名**。
  **これが実コストであり、行数ではない。**
- `expand-format` / `expand-format-safe` が `domain/format` の外に 13 箇所。config を
  消せば renderer 8 + `runtime-reader-alerts.lisp` 1 に減り、アラート全廃で renderer
  8 箇所だけになる。テンプレートは全て定数になるので、engine ではなく手書きの合成に
  置き換えられる。

### 2.4 tmux 言及の分布

src に 292 箇所、83 ファイル。うち **147 箇所は削除予定のディレクトリの中**
（config 47 / options 58 / format 38 / hooks 1 / buffer 3）にあり、R1・R2 で自動的に消える。

残る約 141 箇所は bootstrap 52 / terminal 31 / model 33 / renderer 22 / copy-mode 1 /
infrastructure 2 で、大半が「なぜこの挙動なのか」を tmux の仕様で説明するコメントである。

`$TMUX_TMPDIR` はコメントではなく実際に読んでいる（`server.lisp:43`）。

### 2.5 契約に対して未実装

| 節 | 要求 | 現状 |
| --- | --- | --- |
| §6.1, §6.2 | worktree 行に `DIRTY` / `CONFLICT` / `AHEAD n` / `BEHIND n` を表示し、数値を丸めない | `renderer-tui-kit.lisp:251-256` の `cond` が 1 つだけ選ぶ。モデル（`worktree.lisp:15-18`）には値がある |
| §4.1 | tree に pane を表示する | `%workspace-tree-visible-entries`（`renderer-tui-kit.lisp:259`）は 3 階層で止まる |
| §4.3 | Enter で展開する | 常に全展開。折りたたみ状態を持たない |
| §4.2, §7.3 | `refreshing` / `stale` を表示する | 未実装（`src/` に該当文字列 0 件） |
| §8.5 | 削除前に path・branch・`DIRTY`・`LOCKED`・使用中 pane を提示して二重確認する | `X` がコマンド行に `wt-delete --confirm` を入れるだけ（`:812-816`）。Enter 一回で実行される |
| §10 | 失敗を多行ブロックで示す | 未実装 |
| §11 | 全 action を action menu からも到達可能にする | 存在しない。**R7.6 で条項を書き換える** |

## 3. 削除の連鎖

片方だけ消すと壊れる、あるいは片方を消すともう片方が自然に死ぬ組がある。
**着手前にこの節を読むこと。**

### 3.1 アラート全廃から始まる連鎖

```
アラート全廃 (R1.10)
  └→ runtime-reader-alerts.lisp (186 行) が消える
      └→ overlay.lisp の利用者が runtime-timer.lisp:21,28 と
         runtime-reader-alerts.lisp:116 の 2 つだけだったので、両方消える
          └→ popup / menu は元から死んでいる (2.2)
              └→ presentation/prompt/ が丸ごと消える
                 (prompt.lisp 300 行 + overlay.lisp 154 行)
                  └→ renderer-overlay.lisp (203 行、popup/menu 描画) が消える
                  └→ renderer-compose-overlay.lisp が空に近くなる
      └→ runtime-timer.lisp (121 行) の 3 つの仕事が全て消える
         (overlay 自動消去 / monitor-silence / status-interval 再描画)
          └→ status timer スレッドごと不要になる
```

status-interval の再描画が不要になるのは、新しい status line に時計を含めないため。
refresh 状態の表示（R6.2）は async コールバックが `%mark-dirty` を呼ぶので周期タイマーを
必要としない。

### 3.2 prompt 削除から始まる連鎖

```
prompt.lisp 削除 (R1.1)
  └→ runtime-history.lisp (121 行) が丸ごと死ぬ
     (*message-log* 側は外部参照 0、*prompt-history* 側の唯一の利用者が prompt.lisp)
      └→ cl-history-kit が未使用の依存になる
          └→ flake input / asd depends-on から外し、README を 12 → 11 に直す
```

### 3.3 永続化から始まる連鎖

```
永続化削除 (R1.8)
  └→ *runtime-recovery-items* の唯一の生産者 (%restore-runtime-state,
     runtime-lifecycle.lisp:711) が消える
      └→ attention view の復旧 UI (%recover-client-attention-item, :531) が
         生産者を失う → R1.7 と整合
  └→ tags / notes / recent-activity の読み書きが全て消える
      └→ 4 モデルの当該スロットが完全に dead になる (R1.13)
```

### 3.4 消してはいけないもの

- **attention の「モデル」は残す。** `worktree-attention-p` / `worktree-attention-reasons` /
  `organization-attention-count` は picker 6 箇所・`renderer-workspace.lisp` 7 箇所・
  `renderer-tui-kit.lisp` 4 箇所の `!` マークが使い、R6.1 の状態トークンもこれに乗る。
  消すのは view だけである。
- **mouse を消してもパーサの CSI 1000 / 1006 の「受け付けて無視する」は残す。**
  消すとシーケンスが画面に漏れる。
- **通知（`%client-notify`）は overlay とは別機構。** `client-conn-message-log` +
  `pane-notify`（`:1249-1258`）なので、overlay 全廃の巻き添えにならない。
- **`pane-unread-output-p` / `pane-notification` は残す。** アラート全廃後も picker
  （`global-picker.lisp:339`）と `renderer-workspace.lisp:397` が読む。R6.7 で status
  line の pane タブにも出す。
- **`commands-core.lisp` と `commands-tokenizer.lisp` は残す。** `close-pane-pty` を
  `runtime-reader.lisp:96` と `server.lisp:194` が、`tokenize-command-string` を
  `server-multi-dispatch.lisp:1050` が使う。

## 4. 要件

### R1. 削除

> 完了・マージ済み。詳細は §5 冒頭の進捗メモを参照。

R1.1 `presentation/prompt/prompt.lisp` の編集 API を削除する。`prompt-active-p` を読む
renderer の 4 分岐も、常に偽であることを根拠に畳む。

R1.2 pipe-pane を削除する。`commands-pipe-pane.lisp`、`pane-core.lisp:17-20` の 4 スロット、
`pane-pipe-active-p`、`runtime-reader.lisp:40-41` の分岐、format 変数 `pane_pipe`。

R1.3 **`domain/hooks/` を全廃する。** 登録 API だけでなく `run-hooks` の 9 箇所の
呼び出しごと消す。`add-hook` の呼び出し元が 0 件なので、全て空のレジストリを回している。

R1.4 `domain/buffer/buffer.lisp` を削除する。R3 で clipboard 経路を組み替えた後に行う。

R1.5 **multi-session を削除する。** `session-registry.lisp` の group 連携
（`server-new-session-in-group`、`%link-session-to-group`、`%sync-group-session-windows`、
`%sync-peer-session-windows`、`%register-in-group-alist`、`%next-group-id`、
`%resolve-group-id`、`%sync-active-window`）と、呼び出し元 0 の `server-current-session` /
`server-remove-session` / `server-all-sessions`。session を 1 つに固定する。

R1.6 **mouse を撤去する。** `mouse` / `double-click-time` オプション、screen 側の
mouse モード保持、`%render-mouse-sequences`（`renderer-compose-overlay.lisp:103`）、
関連テスト。3.4 に従い CSI 1000 / 1006 の受理は残す。

R1.7 **attention view を削除する。** `:attention` client view、`a` キー、
`%workspace-attention-items` / `%refresh-client-attention` /
`%select-client-attention-relative` / `%focus-client-attention` /
`%recover-client-attention-item`、`%render-attention-widget`、
`render-workspace-attention-to-tui-string` / `-to-string`、UI コマンドの `:attention-*` 群。
3.4 に従いモデル側は残す。

R1.8 **状態の永続化を削除する。** `domain/persistence/runtime-state.lisp`、
`%save-runtime-state` / `%restore-runtime-state`、`server.lisp:26,29` の port 変数、
`server.lisp:178` と `server-multi-loop.lisp:89` の呼び出し。
**`%runtime-state-home` と `%runtime-log-path` は server log が使うので残す。**

R1.9 **dataflow optional system を削除する。** `src/dataflow`、`t/dataflow`、
`nerimux.asd` の `nerimux/dataflow-model` と `nerimux/dataflow`、`NERIMUX_TEST_SYSTEM` の
分岐、README と `docs/src/guide/sibling-libraries.md` の cl-dataflow-kit に関する記述。

R1.10 **アラートを全廃する。** `runtime-reader-alerts.lisp`、`runtime-timer.lisp`、
status timer スレッド、`presentation/prompt/`（prompt と overlay の両方）、
`renderer-overlay.lisp`。3.1 の連鎖に従う。

R1.11 **`runtime-history.lisp` を削除し、`cl-history-kit` の依存を外す。**
`flake.nix` の input、`nerimux.asd` の `depends-on`、README の兄弟ライブラリ一覧
（12 → 11）。3.2 の連鎖に従う。

R1.12 **`benchmark-workspace-overview` の予算テストをやめる。** 計測関数は `t/` へ移し、
製品パッケージからの export（`package-presentation.lisp:63`）を外す。回帰ゲートとしては
使わない。

R1.13 **`tags` / `notes` / `recent-activity` を 4 モデルから削除する。**
organization / repository / worktree / pane。3.3 の連鎖で参照が 0 になる。

R1.14 **`window-rotate` と `apply-named-layout` を削除する。** 分割が常に 50/50、
window あたり 4 pane という制約の下では使い道がない。

R1.15 **read-only attach（`-r`）を削除する。** `*client-read-only*`、protocol の
`+attach-flag-read-only+`、`client-conn-read-only-p` と 2 箇所の enforcement。

R1.16 **detach-others を削除する。** protocol の `:detach-other-clients` と
`client.lisp:107-108` の送信経路。

R1.17 **CLI のグローバルフラグを `-V` / `-h` だけにする。** `-L` `-S` `-r` `-2` `-D`
`-N` `-l` `-u` `-T` `-c` `-f` `-v` を削除する。`*cli-app*` の `:summary` も tmux を
名乗らない文言に直す。

**受け入れ条件**: 削除後に `nix flake check` が通り、削除対象を参照するテストは削除
されているか、残す振る舞いのテストへ書き換えられていること。テストが 1 件も選択され
ない状態を成功と見なさない。

### R2. 設定機構の全廃

> 大半が実装済みと見られる（§5 冒頭の進捗メモ参照）。個別項目は着手前に再確認すること。

R2.1 `application/config` を削除する。`.tmux.conf` / `$NERIMUX_CONF` /
`~/.config/nerimux/nerimux.conf` を読まない。`server.lisp` の `load-config-file` 呼び出しと
設定由来の警告出力も消える。

R2.2 `domain/options` を削除する。90 箇所の `get-option` を、それぞれの利用側に置いた
定数に置き換える。既定値は `options-registry-data.lisp` の宣言値を出発点とし、1.4 で
固定を決めた項目はその値に従う。**置き換えで既定値が変わる項目は個別に記録する。**

R2.3 `domain/format` を削除する。renderer の 8 箇所を、テンプレート展開ではなく直接の
文字列合成に書き換える。

R2.4 `renderer-style.lisp` の tmux style 文字列パーサ（`parse-style-string`、
`%split-style-tokens`、`%classify-color-name`、`%color-name-to-sgr-number` ほか）を削除し、
SGR を定数として持つ。出力側の `style-to-sgr` 相当は残る。

R2.5 pane を起動するシェルは `$SHELL`、未設定なら `/bin/sh`。子プロセスの環境には
`TERM=screen-256color` と `COLORTERM=truecolor` を渡す。

R2.6 pane のシェルが終了したら即座に pane を閉じる。`remain-on-exit` の banner 描画
（`%write-remain-on-exit-banner`）、parking spin loop（`runtime-reader.lisp:56-65`）、
pane の death record スロット（`pane-core.lisp:34` 付近）を削除する。

R2.7 socket path は `$TMPDIR` → `/tmp` の per-UID ディレクトリ（mode 0700）に固定の
名前で置く。**`$TMUX_TMPDIR` を読むのをやめる**（`server.lisp:43`）。
stale socket の unlink（`main-startup-socket.lisp:11-17`）は現状のまま維持する。

R2.8 server log は 1 MB を超えていたら起動時に新規作成する
（`main-startup-socket.lisp:77` の `:if-output-exists :append` を条件付きにする）。

**注意**: `history-limit` / `alternate-screen` / `scroll-on-clear` は `server.lisp:148-152`
で port に install されている。定数化すればこの間接層自体が不要になる。
**定数を返すだけの関数を残さないこと。**

**受け入れ条件**: `grep -rn 'get-option\|expand-format' src/` が 0 件。
`nix flake check` が通る。

### R3. clipboard を OSC 52 のみにする

> 大半が実装済みと見られる（§5 冒頭の進捗メモ参照）。個別項目は着手前に再確認すること。

R3.1 yank は `%maybe-copy-to-clipboard`（`commands-copy-mode-clip.lisp:74`）だけを行う。
`set-clipboard` オプションが消えるので無条件に送出する。

R3.2 `add-paste-buffer` と `%run-copy-command`（`copy-command` オプション由来）を削除する。

R3.3 pane から届いた OSC 52 はクライアント端末へ素通しする。copy-mode の yank と同じ
`screen-clipboard-queue` に載せる。nerimux 側には保持しない。

**受け入れ条件**: copy-mode で選択して `y` を押すとホスト端末のクリップボードに入ること。
pane 内のアプリが送った OSC 52 も同様に届くこと。`domain/buffer/` が存在しないこと。

### R4. 入力経路と prefix キー

> 大半が実装済みと見られる（§5 冒頭の進捗メモ参照）。個別項目は着手前に再確認すること。

R4.1 **矢印キー判定を削除する。** `%client-key-sequence-p` と、それを使う
`%handle-client-normal-key-payload` / `%handle-client-copy-key-payload` の分岐を消す。
移動は `j` / `k` / `h` / `l` に一本化する。クライアントの 1 バイト転送はそのままでよい。

R4.2 **ESC の特別扱いをやめる。** `:input` モードで ESC を pane へ通す（`:915` の分岐を
削除）。copy-mode の脱出は `q` に一本化する（`:943` の ESC 分岐を削除）。

R4.3 **テキスト入力モードだけ ESC を抑止する。** `:picker` と `:command` モードで、
ESC を受けたら直後の 2 バイトを捨てる最小の抑止を入れる。矢印を機能させるわけでは
ないので R4.1 と矛盾しない。狙いは `[A` が検索語へ混入するのを防ぐことだけである。

R4.4 **`C-q` を本物の prefix に格上げする。** 1.5 の表のとおりに束縛し、未束縛なら
破棄する。現在の「未束縛なら素通し」（`:96-107`）をやめる。

### R5. pane 分割と window

> 大半が実装済みと見られる（§5 冒頭の進捗メモ参照）。R5.5 は未確認。個別項目は
> 着手前に再確認すること。

R5.1 分割は常に 50/50。`%split-fits-p`（`window-core.lisp:86`）が入らないと判定した
ときはメッセージを出して何もしない。

R5.2 window あたりの pane は最大 4。**上限に達した状態での分割要求は、同じ worktree に
新しい window を作ってそこに pane を開く。**

R5.3 分割で作った pane は、その window を持つ worktree の path で起動する。
`worktree-add-pane` で worktree に登録し、overview の pane 数表示に反映する。

R5.4 pane を閉じたときの後始末。window 内の最後の pane を閉じたら window を閉じ、
worktree の pane 一覧から外す。フォーカスは同じ window の隣接 pane へ、window ごと
消えた場合は同じ worktree の別 window へ、それも無ければ overview へ戻す。

R5.5 worktree を「閉じる」専用手段は作らない。`C-q x` を繰り返せば R5.4 により window
ごと消える。

R5.6 **zoom を壊す操作は自動で解除する。** zoom 中の分割・フォーカス移動・window 移動・
pane を閉じる操作は、先に zoom を解除してから実行する。

R5.7 **pane の起動失敗を状態として残す。** `pane-mark-startup-failure`
（`pane-core.lisp:96`）を `%open-client-worktree-pane` の失敗経路（`:495`）から呼ぶ。
attention view を消すため、overview の `!` マークと状態トークンが唯一の恒久的な表示面に
なる。

R5.8 window の名前は branch 名 + 連番（`feat/phase3`、`feat/phase3 (2)`）。tree の
window 行に表示する。status line のタブは番号のみ。

**受け入れ条件**: 分割 → フォーカス移動 → 4 枚目で新 window → window 移動 → 閉じる →
最後の 1 枚を閉じる、の系列で window と worktree の pane 一覧が整合すること。
`:input` モード中に ESC が pane へ届くこと。prefix の未束縛キーが pane へ漏れないこと。

### R6. 表示

> 大半が実装済みと見られる（§5 冒頭の進捗メモ参照）。個別項目は着手前に再確認すること。

R6.1 worktree 行に複数の状態トークンを表示する。`MISSING` / `BARE` / `LOCKED` /
`PRUNABLE` / `DIRTY` / `CONFLICT` / `AHEAD n` / `BEHIND n` を併記し、`AHEAD` と `BEHIND` は
数値を保持する。該当なしは `CLEAN`、status を取得できていない場合は `UNKNOWN` とし、
`CLEAN` を仮定しない（設計文書 §6.2）。

R6.2 **refresh 状態を表示する。** refresh 中は古い値を残したまま `refreshing` を付け、
失敗した対象は `stale` / `UNKNOWN` として残す。VCS の refresh は既に async
（`refresh-workspace-organizations-async`）なので、状態を conn に持って描画すればよい。
**初回スキャン中は空の tree と `scanning...` を出す**（`server-multi.lisp:231` で開始）。

R6.3 tree を org → repo → worktree → **window → pane** の 5 階層にする。
**初期状態は全折りたたみ（organization の行のみ）**とし、Enter で開閉する。
開閉状態は refresh をまたいで保ち、server が生きている間は detach / attach をまたいでも
保つ。永続化はしない。

- org / repo 行の Enter は展開・折りたたみ。
- worktree 行の Enter は**直前にいた window / pane に戻る**（worktree ごとに最後に
  フォーカスした pane を覚える）。無ければ新しい pane を作る。
- window / pane 行の Enter はそこへフォーカスして detail へ移る。

> **2026-08-29 追記**: 上記の5階層（org → repo → worktree → window → pane、
> Enterでの開閉）という形は、section-based overview redesignにより
> Attention / Active / Repositoriesの3固定sectionモデルへ置き換わった
> （実装済み・main反映済み）。repository行はcollapsedが既定で`l`/`Tab`が
> 展開し、worktree行の`Tab`はpane/changed files/recent commitsをinline展開
> する。R6.3が要求した「5階層」というtree構造そのものは、もはや現在の
> 実装が従う契約ではない。詳細は`docs/notes/workspace-ui-ux-design.md`の
> 「現状との関係」への同日追記、および
> `src/presentation/renderer/renderer-workspace-tree.lisp`のヘッダコメント
> を参照。

R6.4 破壊操作（worktree の delete / prune、server の終了）と**操作の失敗**は
全画面の確認ビューを経由する。**描画は cl-tui-kit の widget で行う**（popup / menu の
枠描画は R1.10 で削除するため）。worktree 削除では repository、worktree path、branch、
状態トークン、使用中 pane 数を並べ、`y` / `n` で答える。`LOCKED` なら unlock を促して
続行しない。primary worktree と bare repository を対象として提示しない。

```
┌ WORKTREE DELETE ───────────────────────────┐
│ repository: nerima-lisp/nerimux            │
│ worktree:   .worktrees/20260821T013000-9cc │
│ branch:     feat/phase3                    │
│ state:      DIRTY  AHEAD 2                 │
│ panes:      2 open                         │
│                                            │
│ y 実行   n 中止                             │
└────────────────────────────────────────────┘
```

失敗時は設計文書 §10 の 5 項目（operation / repository / worktree / reason / next）を
同じビューに並べる。

R6.5 status line を下に 1 行固定で置き、次の 3 ブロックを並べる。時計は含めない。

- 左: attention マーク、repository、worktree、状態トークン
- 中: window タブとその中の pane タブ（`[w1: 1 2*][w2: 1]` 形式。`*` がアクティブ）
- 右: 直近の通知 1 件（次の操作で上書きする）

未選択の要素は `—` と明示し、省略された値を直前の選択から暗黙に引き継がない
（設計文書 §2）。`client-conn-message-log` は 64 件保持のままとし、表示だけ 1 件にする。
**幅に入り切らないときは 通知 → タブ → repository 名 の順に削る**（設計文書 §11 に従い、
最後まで残るのは branch と状態トークン）。

R6.6 pane border は細線、アクティブな pane の境界を色で示す。border 上にラベルを
出さない。`pane-border-status` / `pane-border-format` の描画経路を削除する。

R6.7 pane の未読出力を status line の pane タブに `!` で示す（`[w1: 1 2*!3]`）。
アラートを全廃した分をここで補う。

R6.8 copy-mode は選択を反転で示し、行番号は出さない。検索は折り返す。位置表示は
`[12/3400] /pattern 2/7` 形式の固定文字列とし、200 文字超の format テンプレートと
`mode-style` の間接参照を消す。

R6.9 **桁計算を表示幅ベースに直す。** `renderer-workspace.lisp` の `clip` ほか、tree /
status line / 確認ビューのクリップで emulator の `char-width` を使う。

R6.10 端末が 40 x 10 を下回ったら、全画面に `terminal too small (need 40x10)` だけを
描く。resize で自動復帰する。

R6.11 クライアント端末のタイトルを `nerimux: <repository> — <worktree>` に設定する。

R6.12 **action menu は実装しない。** `:` コマンド行を §11 の「keymap 以外の到達手段」と
認め、`:` の直後にコマンド名の一覧を補完表示する。

**受け入れ条件**: R6.3 で初期表示が organization 行のみになるため、1000 repository の
初期描画コストは大きく下がる。ただし R1.12 で予算テストをやめるので、これを回帰ゲート
にはしない。

### R7. VCS 操作

> 大半が実装済みと見られる（§5 冒頭の進捗メモ参照。R7.1–R7.6 すべてが `vcs.lisp`
> のコメントに要件番号として引用されている）。個別項目は着手前に再確認すること。

R7.1 **明示的な fetch を追加する。** `C-q F` で選択中の repository、`C-q C-f` で
選択中の organization 配下を fetch し、完了後に status を refresh する。
cl-vcs-kit の `vcs-fetch`（`vcs-commands-operation.lisp:103`、`vcs-worktree` と同じ
生成系）を `%vcs-call "VCS-FETCH"` で呼び、他の VCS 操作と同じ async 経路
（`%run-vcs-operation-async`）に乗せる。進行中の同一対象への重複実行を抑止する。

R7.2 worktree の作成 path を `<repo>.git/.worktrees/<作成時刻>-<start point の short sha>`
に固定する。時刻は `%Y%m%dT%H%M%S`。**衝突したら連番を付ける**（`-2`、`-3`）。
`%resolve-worktree-path`（`vcs.lisp:450-470`）の `path-template` 引数を削除する。

R7.3 start point の既定は repository の既定 branch（`origin/HEAD` が指す branch）の
先端とする。fetch していなければ古い先端になるので、R7.1 との併用が前提である。

R7.4 **`wt-create` は常に新規 branch を作る。** `new-branch-p` の分岐と、既存 branch を
接続する経路を削除する。設計文書 §8.2 の branch occupied チェックも不要になる。

R7.5 `AHEAD n` / `BEHIND n` の値は cl-vcs-kit の `VCS-STATUS-STRUCTURED`
（`vcs.lisp:344-349`）から来る。これはローカルの remote-tracking ref を読むので、
**最後に fetch した時点からの差**である。設計文書 §3.7（refresh は fetch を伴わない）と
§14（自動 fetch は対象外）は維持する。

R7.6 `nerimux attach <selector>` で slash を含む selector が organization/repository と
local path の両方に解決したときは、**picker を候補で絞った状態で開く**。
cwd による worktree 自動選択（`server-multi-dispatch.lisp:320-329`）は現状のまま。

### R8. server のライフサイクル

> 大半が実装済みと見られる（§5 冒頭の進捗メモ参照。R8.1–R8.4 すべてがコード・
> テストのコメントに要件番号として引用されている）。個別項目は着手前に再確認すること。

R8.1 **CLI に `nerimux kill` を追加する。** socket 経由で `*running*` を落とす。
**生きている pane があれば拒否し、pane 一覧を出して非 0 で終了する。**
`--force` を付けたときだけ実行し、pane には **SIGHUP を送って数秒待ち、
残っていれば SIGKILL** する。

R8.2 `C-q Q` でも終了できる。R6.4 の確認ビューで生きている pane 数を提示してから実行する。

R8.3 `exit-empty` / `exit-unattached` は両方 OFF 相当の定数とする。detach しても runtime と
pane は残る。

R8.4 複数 client の同時 attach を許す。**共有サイズは最小の client に合わせる。**

### R9. 品質ゲートと構成

> R9.1–R9.3 は実装済みと見られる（§5 冒頭の進捗メモ参照）。R9.4/R9.5 は未確認。

R9.1 **層検査を `::` も検出するよう強化する。** `system-composition-tests.lisp` の
source-text layering guard（`:82`）に、`nerimux/xxx::yyy` 形式の参照を層違反として
検出する規則を足す。以前 upward 違反 4 件が緑のまま隠れていた。

R9.2 **実 PTY テストを別 ASDF system（`nerimux/pty-test`）に分ける。**
`nix flake check` は `nerimux/test` だけを回す。

R9.3 **PTY テストを決定的に作り直す。** 非決定性の原因（タイミング依存の sleep、
出力の待ち方）を特定して直す。別スイートに分けるのは切り分けのためであって、
放置するためではない。

R9.4 CI は ubuntu-latest のまま。macOS は手元で `nix flake check` を回す運用とし、
`docs/src/guide/development-rules.md` に明記する。

R9.5 パッケージは削除で 28 → 21 に減る（buffer / config / format / hooks / options /
persistence / prompt が消える）。**さらなる統廃合は R1・R2 完了後に実際の依存グラフを
見て判断する。**

### R10. ドキュメント

> 未確認。R10.1 が列挙した 6 ページに加え、現在 `docs/src/reference/security-model.md`
> が存在する（この節が書かれた時点にはなかったページ）。個別項目は着手前に再確認すること。

R10.1 **tmux への言及を全部落とす。** the compatibility reference page を削除し、
`docs/src/guide/configuration.md` を削除する。残るのは index / getting-started /
architecture / sibling-libraries / development-rules / benchmarks の 6 つ。

R10.2 **src のコメントからも tmux への言及を消す。** R1・R2 後に残る約 141 箇所を、
仕様の中身で書き直す（「`split-window -f` と同じ」→「新しい pane を window 全幅に伸ばす」）。

R10.3 README を更新する。CLI 入口 3 つ、設定を持たないこと、兄弟ライブラリ 11、
`nix build` / `nix run .#test` / `nix run .#test-pty`。

R10.4 `docs/src/benchmarks.md` から予算テストの記述を外す。

## 5. 作業順序

> **進捗（2026-08-22 追記）**: R1 は完了し、`feat/phase3-r1-deletions` ブランチが
> PR #8（マージコミット `8e5a399`）として `main` に入った。R1.1–R1.17 は個別に
> ツリーへ照合済み（例: `pipe-pane` / `get-option` / `domain/hooks` へのソース参照が
> 0 件、`docs/src/reference/security-model.md` が read-only attach の不在を明記）。
>
> 同じブランチの一連のコミット（`d023a3f` 設定機構全廃、`70c7bab` prefix 配線、
> `608a18e` 5階層tree、`bcaa747` 状態トークン、`7b8b100` VCS操作、`43111e5` kill、
> ほか）で、R2–R9 の大半もあわせて実装済みになっている。`grep -rhoE 'R[0-9]+\.[0-9]+'
> src t` で、R2.2–R2.8・R3.1–R3.3・R4.1–R4.4・R5.1–R5.4・R5.6–R5.8・R6.1–R6.12・
> R7.1–R7.6・R8.1–R8.4・R9.1–R9.3 が要件番号としてコード・テストのコメントに
> そのまま引用されているのを確認できる。R2.1（`application/config` 削除）は
> ディレクトリの不在で、R1.13（tags/notes/recent-activity 削除）はモデルへの
> 実参照 0 件で、それぞれ別途確認した。
>
> 未確認のまま残るのは R5.5（専用の worktree クローズ手段を作らない、という
> 「作らない」判断そのものの確認）、R9.4/R9.5（CI 運用と package 数の実測）、
> R10 全体（ドキュメント側。`docs/src/` は現在 7 ページあり、R10.1 が列挙した
> 6 ページ + `reference/security-model.md`）である。
>
> **本節末尾の指示どおり「R1 を終えた時点で一度ベースラインを取り直し、R2 の
> 見積もりをやり直すこと」はまだ行われていない。このメモはその代わりにはならない
> ——着手前に個別項目を現在のツリーに対して再確認すること。**

依存の向きで決まる。

1. **R1**（削除）— 他に依存しない。§3 の連鎖に従い、アラート → overlay → popup/menu →
   prompt の順にまとめて消す。R1.4 だけは R3 の後。
2. **R2**（設定機構の全廃）— R5 が触る `window-core.lisp` / `pane-geometry.lisp` /
   `window-tree.lisp` は `get-option` を読んでいる。先に定数化すると差分が小さくなる。
3. **R3**（clipboard）— R2 の `set-clipboard` / `copy-command` 撤去と同時でもよい。
4. **R4**（入力経路と prefix）— R5 の前提。
5. **R5**（pane 分割と window）— R6.3 の 5 階層は window を前提にする。
6. **R6**（表示）— R6.1 / R6.4 / R6.9 は独立なので前倒し可能。
7. **R7**（VCS 操作）— 独立。
8. **R8**（server ライフサイクル）— 独立。
9. **R9 / R10** — 各段階で並行して進める。R10.2 は R1・R2 完了後。

R2 が最大の作業単位である。90 箇所 37 ファイルに触るため単一 commit にせず、
オプション群ごと（statusbar 系、border 系、copy-mode 系、terminal 系）に分ける。

**R1 を終えた時点で一度ベースラインを取り直し、R2 の見積もりをやり直すこと。**
全完了後に 0.3.0 を切る。

## 6. 検証

canonical なゲートは `nix flake check`。darwin でしか実行できない点と、manifest に
登録済みかつ untracked のファイルがスイート全体を落とす点に注意する（flake は
git-tracked なファイルしか見ない）。

- **テストが選択されていること。** `total` が 0 でないことを毎回確認する。
- **ベースラインを先に取る。** 単発の緑を回帰の証拠として使わない。
- **本番のプロデューサを経由して確認する。** 2.1 の入力バグは、テストが
  `%handle-multi-key-message` を直接叩いて `client.lisp` を迂回したために緑のまま
  隠れていた。**新規機能は「クライアントが送るバイト列」から駆動する統合テストを
  1 本以上持つ。** 単体テストは従来どおり関数単位で網羅する。
- **`intern` やマクロで生成されるシンボルは grep に映らない。** popup / menu が
  そうだった。生成側のマクロを読んでから判断する。
- **削除では行単位のスクリプト操作が括弧を壊す。** `nerimux.asd` の `:components` と
  `defpackage` の `:export` は特に危険。

## 7. 設計文書側の書き換え

`docs/notes/workspace-ui-ux-design.md` は実装より先に書かれた契約なので、今回の決定と
食い違う条項がある。**実装を文書に合わせるのではなく、決定に従って文書を直す。**

- §1.1 の「引数なしの `nerimux` は tmux 互換の standalone entry point として残す」—
  standalone は既に削除済み。
- §1.1 の selector 曖昧時「対象を選ばせる」— R7.6 の picker 起動に具体化する。
- §5.1 の picker 検索対象から `tags` を落とす（R1.13 でフィールドごと消える）。
  window は検索対象に含めない。
- §6.1 / §6.2 の状態トークンは R6.1 のとおり実装する。`AHEAD` / `BEHIND` の意味は
  R7.5 で定義する。
- §9 の keymap 表（`o` / `d` / `a` / `i` / `c` / 矢印）— attention view 削除、矢印削除、
  prefix 格上げを反映する。
- §10 のエラー表示は R6.4 の確認ビューに集約する。
- §11 の「すべての action は keymap だけでなく action menu から到達できる」—
  R6.12 に従い `:` コマンド行を代替と定める。
- §14 の対象外リストは維持する（自動 fetch / pull / push、自動 merge / rebase、
  自動 stash / discard、bare repository の物理削除）。R7.1 の fetch は**明示操作**
  なので §14 と矛盾しない。

## 8. 受け入れた上で記録するリスク

いずれもユーザーが承知の上で選んだ結果である。実装時に「バグでは」と蒸し返さないこと。

- **小さい client を切る手段がない。** 複数 client 可 × サイズは最小に合わせる ×
  detach-others 削除 の組み合わせにより、小さい端末が繋ぎっぱなしだと大きい端末が
  縮んだままになる。逃げ道は小さい端末側の `C-q d` か `nerimux kill` のみ。
- **枠描画を消してから枠付きビューを作る。** `renderer-overlay.lisp` の枠描画を削除した
  上で、R6.4 の確認ビューを cl-tui-kit の widget で描き直す。cl-tui-kit に必要な widget が
  あるかは未確認で、無ければ枠なしの行ベースに落とす。
- **window 名の用途が tree 行だけ。** status line のタブは番号のみなので、branch 名 +
  連番の window 名は tree にしか出ず、worktree 行の branch 表示と重複して見える。
- **`AHEAD` / `BEHIND` は fetch するまで古い。** R7.5 のとおり意味を定義したが、
  `C-q F` を押さない限り値は動かない。

## 9. 未決事項

なし。21 巡のヒアリングで全項目を確定した。
