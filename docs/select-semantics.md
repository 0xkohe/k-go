# Go Select 実装メモ

本ドキュメントでは、`select` 文の構文定義・評価パイプライン・代表的なテストケースを題材にした書き換え（rewrite）トレースを日本語で整理します。コード参照は以下の通りです。

- 構文: `src/go/syntax/concurrent.k`
- セマンティクス: `src/go/semantics/concurrent.k`
- テストサンプル: `src/go/codes/code-select-*.go`

## 1. 構文の概要

`src/go/syntax/concurrent.k:97-113` で `Statement` に `select` を追加しています。

```k
syntax SelectStmt ::= "select" "{" CommClauses "}"
syntax Statement ::= SelectStmt

syntax CommClauses ::= List{CommClause, ";"}
syntax CommClause ::= CommCase ":" Block
syntax CommCase ::= "case" SendStmt
                  | "case" Exp
                  | "case" Assignment
                  | "case" ShortVarDecl
                  | "default"
```

- 各節は必ずブロック `{ ... }` を伴う形で書かれる（Go でも許容される書き方）。
- `Exp` の再利用で `<- ch` や `v := <-ch`, `x, ok := <-ch` 等を表現する。
- `List{…,";"}` により case をセミコロンで区切り、パーサの曖昧性を排除しています。

## 2. セマンティクス: フェーズ構成

`src/go/semantics/concurrent.k:632-1120` で `select` の評価を 5 段階に分けています。

1. **節の正規化 (selectEval/selectBuildCases)**  
   `select { … } => selectEval(Clauses)` の後、各節を `EvalCase` 系 (`evalRecvCase` など) に変換します。上部にある context ルール (`selectBuildCases(... HOLE ...)`) でチャンネル式・送信式を 1 回だけ評価。

2. **ready 節の抽出 (selectCheckReady)**  
   `selectWithCases` が `selectCheckReady` を呼び、`List` と `default` 本体を返します。`chanState` を見て `size(Buf)` や `size(SendQ)` を使って即時実行可能か判定。

3. **節の選択 (selectChooseFrom)**  
   ready 節があれば即実行、default だけなら default、本当に何も無ければ `selectBlock` へ遷移。

4. **ブロッキングと解除 (selectBlock)**  
   元の節リストを保持したまま `<k>` に残り、チャンネルの変化を待つ。送信節はバッファや閉塞状態を再確認、受信節は `sendItem` があれば即座に `chanRecv` を発行して送信側を解放。

5. **ケース本体の実行 (executeSelectCase)**  
   ready 節を `chanSend`/`chanRecv` 等へ変換して既存のチャンネルルールに処理を任せる。

以下の節で代表的なサンプルを題材に、具体的な K ルールの適用順を追跡します。

## 3. 具体例: `code-select-recv-ready`

### 3.1 Go コード

```go
// src/go/codes/code-select-recv-ready
func main() {
  ch := make(chan int, 1)
  ch <- 3
  select {
  case v := <-ch: {
    print(v)
  }
  default: {
    print(99)
  }
  }
}
```

### 3.2 ルール適用の流れ

1. **`selectEval`** (`src/go/semantics/concurrent.k:692`)
   ```k
   select { case v := <-ch : {...}; default : {...} }
   => selectEval(Cases)
   ```
2. **`selectBuildCases`** (`701-755 行目`)
   - `case v := <-ch` は `evalRecvDeclCase(channel(CId,T), v, Body)` に正規化。
   - `default` は `evalDefaultCase(Body)` に変換。
   - nil チャンネルではないのでそのまま保持。

3. **`selectCheckReady`** (`839-909 行目`)
   - チャンネル状態 `chanState(SendQ:List, _RecvQ, Buf, Size, T, Closed)` を参照。
   - 既に `ch <- 3` でバッファに値が入っているため `size(Buf) > 0` が真。よって `evalRecvDeclCase` が ready リストに追加。
   - `default` は `hasDefault` フラグに登録。

4. **`selectChooseFrom`** (`965-983 行目`)
   - ready リストが非空なので最初のケースを選択し `executeSelectCase(evalRecvDeclCase(...))` に進む。

5. **`executeSelectCase`** (`1113 行目`)
   - `evalRecvDeclCase` は `X := chanRecv(Chan) ~> Body` に展開。
   - その後は既存の `chanRecv` ルール（302–342 行目）が発火し、バッファから値を取り出し `v := 3` を環境へ登録。
   - ケース本体 `{ print(v); }` が `<k>` に残っているため `print(3)` が実行され、出力リスト `ListItem(3)` が得られる。

## 4. 具体例: `code-select-send-ready`

### 4.1 Go コード

```go
// src/go/codes/code-select-send-ready
func main() {
  ch := make(chan int, 1)
  select {
  case ch <- 5: {
    print(7)
  }
  default: {
    print(99)
  }
  }
  x := <-ch
  print(x)
}
```

### 4.2 ルール適用

1. **正規化**: `evalSendCase(channel(CId,T), 5, { print(7); })` と `evalDefaultCase(...)` が得られる。
2. **`selectCheckReady`** (`803-819 行目`)
   - `chanState` が `size(Buf) < Size` を満たす（バッファ幅 1 に対して空なので 0 < 1）。
   - 受信待ちもいないがバッファに空きがあるため send 節は ready。
3. **`selectChooseFrom`** → `executeSelectCase(evalSendCase(...))`
   - `chanSend(channel(...), 5) ~> Body` に展開。
   - `chanSend` のルール（226 行目など）が値 5 をバッファに格納。
   - ケース本体 `{ print(7); }` が実行され `7` が出力。
4. 以降の `x := <-ch` は既存の `chanRecv` 処理によって `5` を取り出し、`print(x)` で `5` が出力される。

## 5. 具体例: `code-select-blocking-go`

### 5.1 Go コード

```go
// src/go/codes/code-select-blocking-go
func send(ch chan int) {
  ch <- 10
}

func main() {
  ch := make(chan int)
  go send(ch)
  select {
  case v := <-ch: {
    print(v)
  }
  }
}
```

### 5.2 実行トレース

1. **節の正規化**: `evalRecvDeclCase(channel(CId,int), v, { print(v); })` のみが得られる。
2. **ready 判定**: チャンネルは unbuffered（Size=0）で送信待ちもいないため、`selectCheckReady` は ready 節なし。`selectChooseFrom` が `selectBlock` に遷移。
3. **送信 goroutine**: `ch <- 10` を評価すると、
   ```k
   chanState(.List, .List, .List, 0, int, false)
   => chanState(.List ListItem(sendItem(tid, 10)), .List, .List, 0, int, false)
   ```
   となり、送信側は `waitingSend` 状態で停止。
4. **`selectBlock` での手続き**:
   - 1014–1024 行目のルールがマッチし、
     ```k
     selectBlock(ListItem(evalRecvDeclCase(...)) Rest, Orig)
     => v := chanRecv(channel(CId,int)) ~> Body
     ```
     に書き換わる。
   - 併せて `waitingSend` を `.K` にして送信 goroutine を解除。
5. **`chanRecv` の適用**:
   - `chanRecv(channel(CId,int))` のルール（342 行目）が `sendItem` を取り除き、値 10 を返して `v := 10` を束縛。
   - ケース本体 `{ print(v); }` が実行され、出力 `ListItem(10)` を得る。
6. `executeSelectCase` はフェーズ 4 で直接 `chanRecv` を生成したため呼ばれません。既存のチャンネル受信処理に委ねる形で select 本体が終了します。

## 6. テスト実行コマンド

以下で今回参照したサンプルをまとめて確認できます。

```bash
docker compose exec k bash -c "cd go && kompile main.k"
docker compose exec k bash -c "cd go && krun codes/code-select-default"
docker compose exec k bash -c "cd go && krun codes/code-select-send-ready"
docker compose exec k bash -c "cd go && krun codes/code-select-recv-ready"
docker compose exec k bash -c "cd go && krun codes/code-select-blocking-go"
```

新しいケースを追加する場合は `src/go/codes/` 以下に Go ファイルと `.expected` を用意し、同じ手順で `krun` すれば挙動を追跡できます。
