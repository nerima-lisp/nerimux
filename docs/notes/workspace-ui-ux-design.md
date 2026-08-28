# Workspace UI/UX 設計メモ（未統合）

このファイルは、未追跡のまま別 worktree に残っていた設計草稿を保存したものである。
`docs/notes/` にあるため公開サイトには含まれない（`mkdocs.yml` の `not_in_nav`）。

## 現状との関係

この文書が描く overview（第4章）と global picker（第5章）は、当初から共存する
別画面として設計されていた。実装では、この2つが独立した session で別々に進行し、
別々の organization/repository/worktree/pane ドメインモデルを持つに至った。

- **Global picker（第5章、`C-p`）** は `feat: add workspace runtime and picker`
  (commit `8351773`) として実装され、main に反映済みである。`client-conn-view`
  （`:overview`/`:detail`。`:attention` はR1.7で削除された）と `cl-tui-kit` ベースの
  `src/presentation/renderer/renderer-tui-kit.lisp` を使う。この経路の上で、
  第8章が要求するworktree操作のうちcreate/delete/status表示（`n`/`X`キー、
  `wt-create`/`wt-delete`コマンド）に加えて、**lock/unlock（第8.4節、`L`/`U`
  キー、`wt-lock`/`wt-unlock`コマンド）とdry-run-firstなprune（第8.6節、
  `:wt-prune` → `:wt-prune-confirm`）も実装済み**である
  （`src/infrastructure/vcs/vcs-worktree-operations.lisp`の`lock-worktree`/`unlock-worktree`/
  `prune-worktrees`と、`src/bootstrap/server-multi-dispatch.lisp`の
  `%client-lock-worktree`/`%client-unlock-worktree`/`%client-prune-worktrees`）。
  未統合として残るのは第4章の全画面overviewモードのみである。
- **Workspace overview（第4章、全画面）** は `workspace-overview` branch
  (commit `97ebf05`) として別実装されていた。当時の設計は
  `render-session-to-string` を session 単位の `workspace-mode-p` 分岐で
  上書きするもので、main の client 単位の view 方式と同じ入口を奪い合い、
  ドメインモデルも `nerimux/workspace` として独自に重複していた。そのため
  main への統合は保留した（`EXECUTION.md` の「2026-08-18 追加反映」
  セクションを参照）。**当時の記述は「branchとworktreeは削除せず保持している」
  だったが、現在の tree にはこの branch も worktree も存在しない**
  （`git branch -a` にも `git log --all` にもコミット `97ebf05` /
  `workspace-overview` は見当たらない）。保留の判断根拠は記録として残すが、
  実装そのものは失われており、再統合するなら第4章の記述から書き直す前提になる。

この文書は、第4章の全画面overviewが最終的にどちらの契約に従うべきかの参照として
残す。第5章の picker 経路については、lock/unlock/pruneまで実装済みであることを
含め、実装済みかどうかは本文中の記述ではなく、上記の現状注記と `EXECUTION.md` を
優先する。

---

# Bare repository + worktree execution UI/UX

この文書は、ghqで管理されたbare repositoryと、そのrepositoryに接続されたGit
worktreeを中心に、実行時のUI/UXを定義する。実装履歴ではなく、利用者が「どの
repositoryの、どのworktreeで、どのpaneを操作しているか」を失わないための運用
契約である。

本書でいう`repository`は、常にGitのbare repositoryを指す。かつてtmux互換層の
session persistenceが同じ語を別の意味で使っていたが、その層は削除された（R1）。
本書の各項目はworkspace UI/UXの契約であり、実装済みか追加実装が必要かは、
受け入れ条件と検証結果で判定する。

## 1. 目的と適用範囲

対象は次の操作である。

- ghqのrepository一覧を読み込み、workspaceとして階層表示する
- bare repositoryからworktreeを列挙し、既存のworktreeへ接続する
- worktreeの作成、切り替え、lock/unlock、削除、pruneを安全に実行する
- worktreeごとのpaneを開き、コマンドの実行場所を明示する
- dirty、conflict、missing、locked、prunableなどの注意状態を見落とさない

pane操作は実行面として維持する。一方、repositoryとworktreeのライフサイクルは
workspace面で扱い、pane操作と混ぜない。

### 1.1 起動と接続

workspace面の入口は`attach`である。引数なしではoverviewを開き、selectorを渡すと
初期選択を絞り込む。

```sh
nerimux attach
nerimux attach organization/repository
nerimux attach /path/to/worktree
```

期待結果は次のとおりである。

- `nerimux attach`: headless runtimeを起動または再利用し、thin clientでoverviewへ接続する。
- `organization/repository`: 該当repositoryまたは配下のworktreeへfocusする。
- `/path/to/worktree`: 指定pathのworktreeへfocusする。存在しない場合は、pathを修正する
  かpickerへ戻れるエラーを表示する。
- slashを含むselectorはorganization/repositoryとlocal worktree pathの両方として解決し、
  候補が複数ならpickerを候補で絞った状態で開く（R7.6）。
- `C-q d`はclientをdetachするが、runtimeとworktreeごとのpaneは保持する。

CLIの入口は`attach` / `server` / `kill`の3つで、グローバルフラグは`-V`と`-h`だけである
（1.6、R1.17）。引数なしの`nerimux`をtmux互換のstandalone entry pointとして残すという
当初の想定は実装されておらず、削除された。pane分割はworkspace面そのものに組み込まれて
おり（1.1「pane分割層はUIに配線する」）、互換専用の入口を別に用意する必要はない。

## 2. 利用者のメンタルモデル

workspaceは、次の順序で読む。上位の項目を選んだだけでは、bare repositoryを
作業ディレクトリとしてコマンド実行してはならない。

```text
organization
└── repository (bare repository / Git admin directory)
    ├── worktree (linked checkout / execution directory)
    │   ├── pane 1
    │   └── pane 2
    └── worktree
        └── pane 1
```

| 用語 | UI上の意味 | コマンド実行の扱い |
| --- | --- | --- |
| organization | hostと名前でまとめたrepositoryのグループ | 直接実行しない |
| repository | ghqから見つかったbare repositoryとその管理情報 | Git管理操作の対象。通常の作業ディレクトリにはしない |
| worktree | repositoryに接続されたcheckout | 通常のコマンド実行場所 |
| pane | worktreeに束縛された端末表示 | 選択中のworktreeを実行コンテキストとして使う |
| attention | 利用者の確認を要求する状態 | 行頭の記号と文字列の両方で示す |

画面上の現在地は、常に次の3要素で表現できなければならない。

```text
repository: $REPOSITORY
worktree:   $WORKTREE
pane:       $PANE
```

値が未選択の場合は、`repository: —`のように未選択を明示する。省略された値を
直前の選択から暗黙に引き継いではならない。

## 3. 非交渉のUX原則

1. **bare repositoryは実行場所ではない。** repository行では管理操作を提示し、作業
   コマンドは選択中のworktreeに対して実行する。
2. **パスを識別子として見せる。** worktree行にはbranchとpathを常に表示し、短縮表示
   した場合でもcopy操作から完全なpathを取得できるようにする。
3. **選択状態をrefreshで失わない。** refresh前後で同じstable IDが存在する場合は、同じ
   organization、repository、worktree、paneを再選択する。消滅した場合は選択解除と理由を
   表示する。
4. **破壊操作は対象を二重に確認する。** worktreeの削除ではpathとbranchを確認し、dirty
   またはpane使用中なら追加の確認を要求する。
5. **状態を色だけで伝えない。** `DIRTY`、`CONFLICT`、`MISSING`などの文字列と注意記号を
   色と併用する。
6. **staleな情報を成功に見せない。** refresh中は古い値を表示したまま、`refreshing`を
   付ける。取得できなかった値は空欄ではなく`unknown`またはエラーとして扱う。
7. **fetchを暗黙に行わない。** refreshはローカルのinventoryとstatusの再読込であり、
   networkを伴うfetchは明示的な別操作とする。
8. **エラーから復旧できる。** 失敗した操作、対象、原因、次に試せる操作を同じ画面に残す。

## 4. Workspace overview

### 4.1 レイアウト

標準画面は、header、tree、footerの3領域で構成する。treeはorganization → repository →
worktree → window → paneの5階層で、初期状態は全折りたたみ（organizationの行のみ）である
（R6.3）。以下は展開後の例を示す。

```text
┌ Workspace  [overview]  refresh: ready  context: $WORKTREE ─────────────┐
│ ! org-host/name                                                         │
│   └ ! repo-specification                         [3 worktrees]          │
│     ├ ! feature — $WORKTREE                  DIRTY AHEAD 2  [pane 2]    │
│     │ └ w1: feature (1)                                                 │
│     │   ├ pane/1 shell                                                  │
│     │   └ pane/2 test                                                   │
│     ├   main — $OTHER_WORKTREE                     CLEAN  [pane 1]      │
│     └   missing — $MISSING_WORKTREE              MISSING                │
├─────────────────────────────────────────────────────────────────────────┤
│ j/k select  Enter open/close  C-p picker  r refresh  o overview  d detail│
└─────────────────────────────────────────────────────────────────────────┘
```

### 4.2 Header

headerには、現在のmode、refresh状態、実行コンテキストを表示する。viewは`overview`と
`detail`の2つのみであり、attention viewは削除された（R1.7）。attentionの`!`マークは
モデル側の状態として残り、tree・picker・status lineに表示される（3.4）。

- `overview`: organizationからpaneまでの階層を表示する
- `detail`: 選択対象のfull path、branch、HEAD、statusを表示する
- `refreshing`: inventoryまたはstatusを更新中であることを示す
- `stale`: 最後の更新に失敗し、表示値が古いことを示す

### 4.3 Treeと選択

- 初期選択はworkspaceの最初のorganizationではなく、前回のstable IDまたは指定された
  worktreeを優先する。
- organizationを選択してEnterを押すと配下を展開し、repositoryを選択してEnterを押すと
  worktree一覧を展開する。
- worktreeを選択してEnterを押すと、そのworktreeに接続されたpaneを再利用する。paneが
  なければ新しいpaneを作成する。
- repositoryを選択した状態でEnterを押した場合、bare repositoryへ移動せず、worktreeの
  選択または作成へ進む。
- windowまたはpaneを選択してEnterを押すと、そこへフォーカスしてdetailへ移る（R6.3）。
- paneの選択は実行コンテキストを変更するが、repositoryやworktreeの状態を変更しない。

## 5. Global picker

`C-p`で、organization、repository、worktree、paneを横断して検索する。

### 5.1 表示と検索

pickerの既定検索はliteral検索とし、明示的な操作でregex検索へ切り替える。
検索対象には、表示ラベルだけでなく次の属性を含める。`tags`フィールドはモデルから
削除されたため検索対象から外れる（R1.13）。windowはpicker上の種別を持たず、検索対象にも
含めない — pickerが横断するのはorganization/repository/worktree/paneの階層のみである。

- organization: host、name
- repository: specification、local path、remote
- worktree: branch、path、HEAD、status
- pane: pane番号、title、起動コマンド、shell

表示ラベルは種別を推測できる形式にする。

| 種別 | 表示ラベルの形式 |
| --- | --- |
| organization | `host/name` |
| repository | `specification — local-path` |
| worktree | `branch — path` |
| pane | `pane/N title` |

検索結果はorganization、repository、worktree、paneの階層順に並べ、attention状態の
対象には`!`を付ける。一致しない場合は空画面にせず、検索語と`clear query`を表示する。

### 5.2 Pickerからの遷移

- organization、repository、worktreeを選ぶとoverviewの該当行へ戻る。
- worktreeを選ぶと、そのpathを検査してからpaneをattachまたは作成する。
- paneを選ぶと、既存paneへattachする。
- missingなworktreeを選んだ場合はattachを試みず、detail画面で修復またはpruneを提示する。
- pickerの検索語やregex設定は、閉じた後のworkspace操作には持ち越さない。

## 6. 状態表示の契約

### 6.1 状態トークン

| トークン | 意味 | 注意状態 |
| --- | --- | --- |
| `BARE` | repositoryがbareである、またはbare管理情報を表す | 種別であり、単独では異常ではない |
| `CLEAN` | worktreeに未コミット変更がない | なし |
| `DIRTY` | worktreeに未コミット変更がある | あり |
| `CONFLICT` | conflictまたは解決が必要な状態がある | あり |
| `AHEAD N` | upstreamよりN commit進んでいる | 確認を促す |
| `BEHIND N` | upstreamよりN commit遅れている | 確認を促す |
| `LOCKED` | worktreeがlockされている | 削除前にunlockを提示 |
| `PRUNABLE` | Gitが不要なworktree管理情報として検出した | prune候補 |
| `MISSING` | 登録pathが存在しない、または読めない | 修復またはpruneが必要 |
| `NO-WORKTREE` | repositoryに実行可能なworktreeがない | 作成を提示 |
| `UNKNOWN` | statusを取得できていない | staleと原因を表示 |

### 6.2 集約ルール

- worktreeの`CONFLICT`、`DIRTY`、`MISSING`、`PRUNABLE`はrepositoryへ伝播する。
- repository配下のattentionが1件でもあれば、repository行と上位organization行に`!`を付ける。
- `AHEAD`と`BEHIND`は数値を保持する。単なる`CHANGED`への丸めは行わない。値はローカルの
  remote-tracking refから読むため、**最後に明示的にfetchした時点からの差**であり、fetch
  を実行しない限り更新されない（R7.5、`C-q F` / `C-q C-f`）。これは7.1「fetchを暗黙に
  行わない」および14「対象外」の自動fetch禁止と矛盾しない — fetchは常に利用者の明示操作
  である。
- `BARE`はrepositoryの種別表示として使い、worktreeの健康状態と同列に扱わない。
- status取得失敗時に`CLEAN`を仮定してはならない。

### 6.3 Pathの表示

- headerとdetailではfull pathを表示する。
- treeとpickerでは幅に応じて中間を省略し、末尾の識別可能な部分を残す。
- 省略されたpathには省略記号を付け、copy actionで元の値を取得できるようにする。
- bare repositoryの管理pathとworktreeの実行pathを同じフィールドに表示しない。

## 7. Inventoryとrefresh

### 7.1 情報源

workspaceは次の3つを別々の情報源として扱う。

1. ghq: repositoryのinventory
2. bare repository: linked worktreeの登録情報
3. worktree: 実ファイル、branch、HEAD、status

一つの情報源が失敗しても、他の情報源から得た対象を消去しない。例えばworktreeの
pathが消えていても、repositoryから返された登録情報を`MISSING`として残す。

### 7.2 Adapterが実行する代表コマンド

以下のshell変数は、UIが選択済みの値を解決したものを示す。

```sh
GHQ_ROOT="$(ghq root)"
REPOSITORY="$GHQ_ROOT/$REPOSITORY_NAME"
WORKTREE="$WORKTREE_PATH"

ghq list --full-path
git --git-dir="$REPOSITORY" rev-parse --is-bare-repository
git --git-dir="$REPOSITORY" worktree list --porcelain
git -C "$WORKTREE" status --short --branch
```

期待結果は、ghqのfull path、bare判定の`true`、空でないworktree inventory、選択worktreeの
branch/statusである。どれか一つでも取得できない場合は、全体を成功扱いにせず対象単位で
`UNKNOWN`または`stale`を表示する。

実装は各コマンドのraw outputをUIに直接渡さず、organization、repository、worktree、
statusのモデルへ変換する。`git worktree list --porcelain`の`locked`、`prunable`、
missing相当の情報は失わない。

### 7.3 Refreshの挙動

- 初期表示はinventory、worktree list、statusの順に読み込み、各段階をloadingとして示す。
- refreshは非同期に実行し、UI入力と既存paneをブロックしない。
- refresh開始時のツリーを維持し、完了した対象から置き換える。
- 選択対象が消えた場合は、最も近い親へ移動し、「対象が消えた」理由を表示する。
- 失敗した対象は`UNKNOWN`または`stale`として残し、前回の成功値と失敗時の状態を区別する。
- 同じrepositoryの同時refreshを重複実行しない。

## 8. Worktree操作のUIフロー

### 8.1 既存worktreeを開く

1. pickerまたはtreeでworktreeを選択する。
2. pathの存在とreadabilityを検査する。
3. `MISSING`でなければ既存paneを再利用し、なければpaneを作成する。
4. paneの起動directoryを選択worktreeに設定する。
5. headerへrepository、worktree、paneのfull contextを表示する。

bare repositoryのpathを選択した場合は、worktree選択へ戻し、bare directoryでshellを
起動してはならない。

### 8.2 worktreeを作成する

repository選択時の`n`キー、または`:`コマンド行の`wt-create`から開始する（action menuは
実装しない、R6.12・11節）。作成前にbranch、start point、pathをpreviewする。

```sh
git --git-dir="$REPOSITORY" worktree add -b "$BRANCH" "$WORKTREE" "$START_POINT"
```

期待結果は、指定pathにlinked worktreeが作成され、refresh後にbranchとpathを持つ新しい行が
選択されることである。

`wt-create`は常に新規branchを作る。既存branchへ接続する経路は無い（R7.4）ため、branchが
別worktreeで使用中かどうかの衝突チェックも不要である。

成功時は自動的にrefreshし、新しいworktreeを選択してpane作成またはattachへ進む。失敗時は
入力値、Gitのエラー、再試行可能な修正方法を表示し、部分的に作成されたpathを成功扱いにしない。

### 8.3 worktreeを切り替える

切り替えはcheckoutではなく、対象worktreeへのattachである。

- 現在paneの実行directoryを変更して別worktreeを装わない。
- 選択worktreeごとにpaneを保持し、再選択時は既存paneへ戻る。
- dirtyなworktreeから離れること自体は妨げないが、未保存変更をheaderに残す。

### 8.4 lock/unlock

移動や外部ツールとの併用で一時的にworktreeを保護する場合は、detail画面からlockする。
lock理由を表示し、削除操作ではunlockが必要であることを明示する。

```sh
git --git-dir="$REPOSITORY" worktree lock --reason "$LOCK_REASON" "$WORKTREE"
git --git-dir="$REPOSITORY" worktree unlock "$WORKTREE"
```

期待結果は、lock後の`worktree list --porcelain`に`locked`と理由が現れ、unlock後のrefreshで
`LOCKED`が消えることである。unlockに失敗した場合は、lock理由とGitのエラーを残したまま
削除操作を続行しない。

### 8.5 worktreeを削除する

通常の削除は、選択したlinked worktreeに対して次のGit操作を使う。

```sh
git --git-dir="$REPOSITORY" worktree remove "$WORKTREE"
```

期待結果は、確認したlinked worktreeだけが削除され、refresh後に一覧から消えることである。
primary worktreeやbare repositoryを対象にした操作は実行されない。

削除前に次をすべて満たすことを確認する。

- 選択対象がrepository本体ではなくlinked worktreeである
- pathとbranchが確認ダイアログに表示されている
- `LOCKED`ならunlock方法を提示している
- `DIRTY`または`CONFLICT`なら状態と追加確認を表示している
- 使用中のpaneがあれば、detachまたはpane終了を先に選択させている

primary worktreeやbare repositoryを削除対象として提示してはならない。force削除は通常
フローに置かず、pathを再入力する復旧用actionとしてのみ提供する。削除完了後は自動refreshし、
消えたworktreeを選択状態に残さない。

### 8.6 pruneと修復

`MISSING`または`PRUNABLE`の対象では、まずdry-run結果を表示する。

```sh
git --git-dir="$REPOSITORY" worktree prune --dry-run
git --git-dir="$REPOSITORY" worktree prune
```

期待結果は、dry-runで対象pathが先に表示され、確認後のpruneとrefreshで不要な登録情報だけが
一覧から消えることである。

pruneは自動実行しない。dry-runに含まれるpathと、paneや利用者の作業が残っていないことを
確認してから実行する。prune後はinventoryとworktree listを再取得する。

## 9. Keymapとaction

`C-q`は本物のprefixである（1.5、R4.4）。prefixを受けた次のキーは9.1の表で解決し、
未束縛なら破棄する — pane内のアプリへ素通しさせない。`:normal`モードの素キーは9.2の表で
解決する。attention viewの削除（R1.7）により`a`は解放され、矢印キーの判定は削除された
（R4.1）ため、選択移動は`j` / `k` / `h` / `l`とprefixだけに一本化されている。

### 9.1 Prefix（`C-q`）action

| prefixキー | action | 制約 |
| --- | --- | --- |
| `C-q -` | 選択中paneの window を上下に分割 | 分割不可なら何もせずメッセージのみ |
| `C-q \|` | 選択中paneの window を左右に分割 | 同上 |
| `C-q x` | 選択中のpaneを閉じる | windowの最後の1枚ならwindowごと閉じる |
| `C-q z` | zoomを切り替える | zoom中の他操作は先にzoomを解除してから実行する |
| `C-q h` / `j` / `k` / `l` | paneのフォーカスを隣へ移動 | zoomを解除してから移動 |
| `C-q n` / `C-q p` | 現在のworktreeのwindowを前後に循環 | windowが1つ以下なら何もしない |
| `C-q F` | 選択中のrepositoryをfetch | 同一対象への重複実行は抑止する |
| `C-q C-f` | 選択中のorganization配下をfetch | 同上 |
| `C-q d` | detach | runtimeとworktreeごとのpaneは保持する |
| `C-q Q` | serverを終了 | 10節の確認ビュー経由（R6.4） |
| `C-q C-q` | `:normal`へ戻る | 唯一、pane/windowの有無を問わない操作 |

### 9.2 `:normal`モードの素キー

| キー | workspaceでの意味 | 制約 |
| --- | --- | --- |
| `C-p` | global pickerを開く | literal検索から開始 |
| `o` | overviewへ移動 | |
| `d` | detailへ移動 | |
| `j` / `k` / `h` / `l` | 選択移動 | 展開状態を保持 |
| `Enter` | 選択対象を開く/閉じる | organization・repository行は展開/折りたたみ、worktree行は直前のpaneへ接続（無ければ作成）、window/pane行はそこへフォーカス（R6.3） |
| `n` | worktree作成 | repository選択時のみ有効 |
| `X` | worktree削除 | 確認完了時のみ実行 |
| `L` / `U` | lock / unlock | 選択worktreeのみ |
| `r` | refresh | 進行中の同一refreshは重複させない |
| `i` | input modeへ入る | 選択中paneへキー入力を転送する |
| `c` | copy-modeへ入る | 検索・選択・yankはcopy-mode内のキーで行う |
| `:` | command入力 | 直後にコマンド名の一覧を補完表示する（R6.12、11節） |

pane内の操作はこのkeymapと衝突しないよう、`:normal`モードとpane側のモード（`:input` /
`:copy`）を区別する。

## 10. Loading、エラー、復旧

エラーは、R6.4の確認ビュー（`cl-tui-kit`のwidgetで描く全画面ビュー）に、operation /
repository / worktree / reason / nextの5項目を並べて表示する。破壊操作の確認と操作失敗の
表示は同じ描画経路を共有する — popup/menuの専用枠描画は削除されたため（R1.10）、確認
ビューが唯一の恒久的なフィードバック面になる。

```text
[WORKTREE OPERATION BLOCKED]
operation: remove
repository: $REPOSITORY
worktree:   $WORKTREE
reason:     worktree is locked
next:       unlock the worktree, then refresh
```

| 状況 | 表示 | 提示する復旧 |
| --- | --- | --- |
| ghq inventory失敗 | `inventory stale` | retry、設定確認 |
| bare判定失敗 | `repository unknown` | repository path確認、再scan |
| worktree path消失 | `MISSING` | path確認、prune preview |
| dirty worktreeの削除 | `DIRTY` | detail確認、追加確認、cancel |
| lockされたworktreeの削除 | `LOCKED` | unlock、またはcancel |
| pane起動失敗 | `pane unavailable` | error保持、別pane作成、retry |
| status取得中断 | `UNKNOWN / stale` | retry。`CLEAN`にはしない |

`branch occupied`（branchが別worktreeで使用中）は対象外になった。`wt-create`は常に新規
branchを作るため（R7.4）、既存branchへ接続する経路自体が無くなり、衝突チェックの出番が
ない。

操作の失敗はtreeを空にして隠してはならない。失敗した対象、最後に成功した情報、再試行
actionを残す。

## 11. Accessibilityと狭い画面への対応

- 注意状態は色、記号、文字列の3つのうち少なくとも文字列ともう1つで表す。
- action menuは実装しない（R6.12）。すべてのactionはkeymapに加え、`:`コマンド行から
  到達できる。`:`の直後にコマンド名の一覧を補完表示し、keymap以外の到達手段とする。
- pathを省略する場合は末尾を優先し、detailとcopyでは完全な値を提供する。
- loading中も選択行の位置を安定させ、更新のたびに画面を先頭へ戻さない。
- pickerでは種別をlabelとiconの両方で区別し、iconを描画できない環境でもlabelだけで判別できる。
- terminal幅が狭い場合は、paneの詳細よりworktreeのbranch、pathの末尾、注意状態を優先する。

## 12. 実装境界と状態遷移

UIはGitの出力形式を直接解釈せず、次の責務に分ける。

```text
ghq adapter ───────┐
bare Git adapter ──┼─> organization/repository/worktree model ─> overview/picker/detail
status adapter ────┘                         │
                                             └─> pane attach / command context
```

stable IDはpathの表示文字列とは別に保持する。最低限、organization、repository、worktree、
paneをそれぞれ一意に再選択できる値を持つ。次の状態遷移では、UIを先に成功状態へ変更しない。

```text
idle
  -> loading
  -> ready
  -> stale (read failure)
  -> mutating
  -> ready (mutation + refresh success)
  -> error (mutation failure, previous state retained)
```

VCS adapterは、inventory、worktree列挙、status、create、lock、unlock、delete、prune、scanを
別操作として公開する。
UIはmutation完了を待たずに成功表示せず、mutation後のrefreshで実状態を確認してから選択を更新する。

## 13. 受け入れ条件

実装を完了とみなすには、少なくとも次を満たす。

- bare repositoryをorganization → repositoryとして表示し、直接の実行先にしない
- repository配下に複数worktreeと各paneを表示できる
- worktree行にbranch、path、状態トークンを表示できる
- global pickerでrepository、worktree、paneを検索して該当位置へ移動できる
- refresh後も存在するstable IDの選択を保持できる
- `MISSING`、`LOCKED`、`PRUNABLE`、`DIRTY`、`CONFLICT`を空欄や成功として扱わない
- worktree作成後にrefreshし、実在するworktreeへattachできる
- primary worktree、bare repository、pane使用中の対象を無確認で削除できない
- mutation失敗時にtreeと前回の状態を保持し、対象と復旧方法を表示できる
- 狭い画面でもpath末尾、branch、attention状態を判別できる

文書または実装の検証では、まず次を実行する。

```sh
git diff --check
nix flake check
```

期待結果は、空白エラーがなく、formatter、docs、選択されたtest systemを含むflake checkが
成功することである。untrackedな文書を検証するときは、`git diff --check`だけに依存せず、
文書自身のfenceと末尾空白も検査する。

bare repository操作のコマンド例は、実在の利用者データを変更せず、一時directoryに作った
bare repositoryとworktreeで実行する。テストが選択対象を持たない場合は成功とみなさず、
inventory、worktree list、statusがそれぞれ非空であることを確認する。

## 14. 対象外

- remoteの自動fetch、pull、push
- worktree間の変更を自動mergeまたは自動rebaseすること
- dirtyな変更の自動stash、discard、削除
- bare repository自体の物理削除
- paneの中身をworkspaceのstatus情報として推測すること

これらは別の明示的な操作仕様と確認フローが必要であり、workspace overviewの暗黙動作には
含めない。`C-q F` / `C-q C-f`（1.5、R7.1）は利用者が明示的に叩くfetchであり、ここで
禁じる「自動fetch」ではない — refreshからは独立した別操作であることに変わりはない。
