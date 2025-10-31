# Select文の実装

## 1. 概要

select文は、Goの並行プログラミングにおける中核的な機能で、複数のチャネル操作の中から準備が完了したものを選択して実行します。複数のgoroutineとチャネル間の同期・通信を柔軟に制御できる強力な制御構造です。

### 主な特徴

- 複数のチャネル送受信操作を多重化（multiplexing）
- 準備完了した操作の中から1つを非決定的に選択
- defaultケースによる非ブロッキング操作のサポート
- nil channelは決して選択されない（永久にブロック）

## 2. Go言語仕様

Go言語仕様によると、select文の実行は以下のステップで進行します：

```
SelectStmt = "select" "{" { CommClause } "}" .
CommClause = CommCase ":" StatementList .
CommCase   = "case" ( SendStmt | RecvStmt ) | "default" .
RecvStmt   = [ ExpressionList "=" | IdentifierList ":=" ] RecvExpr .
RecvExpr   = Expression .
```

### 実行ステップ

1. **評価フェーズ**: すべてのcaseについて、チャネル式と送信値の式を入場時に1回だけソース順に評価する。左辺の変数宣言や代入はこの時点では評価されない。

2. **選択フェーズ**: 1つ以上の通信が進行可能な場合、一様疑似ランダム選択で1つを選ぶ。どれも進行不可能でdefaultケースがある場合はdefaultを選択。defaultがない場合は少なくとも1つの通信が進行可能になるまでブロック。

3. **実行フェーズ**: 選択されたcaseの通信操作を実行。RecvStmtの場合は左辺を評価して受信値を代入。

4. **文リスト実行**: 選択されたcaseの文リストを実行。

## 3. K Framework実装の設計

### 3.1 構文定義

構文定義は `src/go/syntax/concurrent.k` (行88-115) に記述されています：

```k
syntax SelectStmt ::= "select" "{" CommClauses "}"
syntax CommClauses ::= List{CommClause, ";"}
syntax CommClause ::= CommCase ":" Block

syntax CommCase ::= "case" SendStmt        // case ch <- v
                  | "case" Exp             // case <-ch
                  | "case" Assignment      // case x = <-ch or x, y = <-ch
                  | "case" ShortVarDecl    // case x := <-ch or x, ok := <-ch
                  | "default"
```

サポートされるcaseの種類：

1. **送信case**: `case ch <- value`
2. **受信case（値を破棄）**: `case <-ch`
3. **受信case（代入）**: `case x = <-ch`
4. **受信case（短縮宣言）**: `case x := <-ch`
5. **受信case（ok付き）**: `case v, ok := <-ch`
6. **defaultケース**: `default`

### 3.2 セマンティクス実装

セマンティクスは `src/go/semantics/concurrent.k` (行632-1122) に実装されています。

#### 内部データ構造

評価されたcaseを表現するための内部型：

```k
syntax EvalCase ::= evalSendCase(ChanVal, K, K)           // channel, value, body
                  | evalRecvCase(ChanVal, K)              // channel, body
                  | evalRecvAssignCase(ChanVal, Id, K)    // channel, variable, body
                  | evalRecvDeclCase(ChanVal, Id, K)      // channel, variable, body
                  | evalRecvOkCase(ChanVal, Id, Id, K)    // channel, value var, ok var, body
                  | evalDefaultCase(K)                    // body
```

#### 実行フェーズ

select文の実行は4つの主要なフェーズに分かれています：

##### フェーズ1: 評価 (Evaluation)

```k
selectEval(Cases) => selectBuildCases(Cases, .List)
```

各caseを順番に評価し、`EvalCase`のリストを構築します。このフェーズでは：

- チャネル式を評価（`HOLE`を使ったcontext rulesで実現）
- 送信値の式を評価
- nil channelのcaseは除外（選択対象外）
- defaultケースは`evalDefaultCase`として保存

実装例（concurrent.k:656-683）：

```k
// チャネル式の評価を強制するcontext rules
context selectBuildCases(
          (case (HOLE:Exp <- _V:Exp) : _Body:Block) ; _Rest:CommClauses,
          _Acc:List)

// 評価後のcaseをリストに追加
rule <k> selectBuildCases(
        (case (Chan:ChanVal <- V) : Body:Block) ; Rest:CommClauses,
        Acc:List)
      => selectBuildCases(Rest, Acc ListItem(evalSendCase(Chan, V, Body))) ... </k>
```

##### フェーズ2: 準備チェック (Ready Check)

```k
selectWithCases(Cases:List) => selectCheckReady(Cases, .List, .K, Cases)
```

各caseが即座に実行可能かチェックし、準備完了リストを構築します：

**送信caseの準備判定**（concurrent.k:803-833）：

```k
rule <k> selectCheckReady(
        ListItem(evalSendCase(Chan, V, Body)) Rest:List,
        Ready:List, Default:K, Orig:List)
      => selectCheckReady(Rest, Ready ListItem(evalSendCase(Chan, V, Body)),
                         Default, Orig) ... </k>
     <channels>...
       chanId(Chan) |-> chanState(_SendQ:List, RecvQ, Buf, Size, _T, Closed)
     ...</channels>
  requires (Closed ==Bool true)           // closedチャネル（panicになる）
    orBool (size(Buf) <Int Size)          // バッファに空きがある
    orBool (size(RecvQ) >Int 0)           // 待機中の受信者がいる
```

**受信caseの準備判定**（concurrent.k:834-864）：

```k
rule <k> selectCheckReady(
        ListItem(evalRecvCase(Chan, Body)) Rest:List,
        Ready:List, Default:K, Orig:List)
      => selectCheckReady(Rest, Ready ListItem(evalRecvCase(Chan, Body)),
                         Default, Orig) ... </k>
     <channels>...
       chanId(Chan) |-> chanState(SendQ:List, _RecvQ, Buf, _Size, _T, Closed)
     ...</channels>
  requires (size(Buf) >Int 0)             // バッファに値がある
    orBool (size(SendQ:List) >Int 0)      // 待機中の送信者がいる
    orBool (Closed ==Bool true)           // チャネルが閉じている
```

##### フェーズ3: 選択 (Selection)

```k
selectChooseFrom(Ready:List, Default:K, Orig:List)
```

準備完了リストから1つを選択します：

1. **準備完了caseがある場合**（concurrent.k:965-969）:
   ```k
   rule <k> selectChooseFrom(ListItem(Case:EvalCase) _Rest:List, _Default:K, _Orig:List)
         => executeSelectCase(Case) ... </k>
   ```
   最初の要素を選択（K Frameworkのnon-determinismで実際にはランダム）

2. **準備完了caseがなく、defaultがある場合**（concurrent.k:971-976）:
   ```k
   rule <k> selectChooseFrom(.List, Default:K, _Orig:List)
         => executeSelectCase(evalDefaultCase(Default)) ... </k>
     requires hasDefault(Default)
   ```

3. **準備完了caseがなく、defaultもない場合**（concurrent.k:978-983）:
   ```k
   rule <k> selectChooseFrom(.List, Default:K, Orig:List)
         => selectBlock(Orig, Orig) ... </k>
     requires notBool hasDefault(Default)
   ```
   ブロッキングフェーズへ移行

##### フェーズ4a: 実行 (Execution)

選択されたcaseを実行します（concurrent.k:1104-1120）：

```k
// 送信caseの実行
rule <k> executeSelectCase(evalSendCase(Chan, V, Body))
      => chanSend(Chan, V) ~> Body ... </k>

// 受信caseの実行
rule <k> executeSelectCase(evalRecvCase(Chan, Body))
      => chanRecv(Chan) ~> Body ... </k>

// 受信+代入caseの実行
rule <k> executeSelectCase(evalRecvAssignCase(Chan, X, Body))
      => X = chanRecv(Chan) ~> Body ... </k>

// 受信+短縮宣言caseの実行
rule <k> executeSelectCase(evalRecvDeclCase(Chan, X, Body))
      => X := chanRecv(Chan) ~> Body ... </k>

// 受信+ok付きcaseの実行
rule <k> executeSelectCase(evalRecvOkCase(Chan, V, Ok, Body))
      => (V, Ok) := recvWithOk(Chan) ~> Body ... </k>

// defaultケースの実行
rule <k> executeSelectCase(evalDefaultCase(Body))
      => Body ... </k>
```

##### フェーズ4b: ブロッキング (Blocking)

準備完了caseがなく、defaultもない場合、いずれかの操作が可能になるまで待機します（concurrent.k:985-1103）。

ブロッキングフェーズでは、元のcaseリストを走査し、状態変化を検出：

```k
syntax KItem ::= selectBlock(List, List)  // current list, original list
```

**ブロッキング中の状態変化検出**:

```k
// 送信caseが準備完了になった
rule <thread>...
       <tid> _Tid </tid>
       <k> selectBlock(_L1:List ListItem(evalSendCase(Chan, _V, _Body)) _L2:List, Orig:List)
        => selectCheckReady(Orig, .List, .K, Orig) ... </k>
     ...</thread>
     <channels>...
       chanId(Chan) |-> chanState(_SendQBlock:List, RecvQ, Buf, Size, _T, Closed)
     ...</channels>
  requires (Closed ==Bool true)
    orBool (size(Buf) <Int Size)
    orBool (size(RecvQ) >Int 0)
```

状態変化を検出したら、再度フェーズ2（準備チェック）から実行します。

**直接実行可能な場合**:

一部のケースでは、ブロッキング中に直接実行可能になります：

```k
// 送信者が現れた場合、直接受信
rule <thread>...
       <tid> _Tid </tid>
       <k> selectBlock(ListItem(evalRecvCase(Chan, Body)) _Rest:List, _Orig:List)
        => chanRecv(Chan) ~> Body ... </k>
     ...</thread>
     <channels>...
       chanId(Chan) |-> chanState(
         (ListItem(sendItem(_SendTid:Int, _SV)) _SendRest:List),
         _RecvQ, .List, _Size, _T, false)
     ...</channels>
```

### 3.3 nil Channelの扱い

nil channelに対する操作は決して進行しないため、評価フェーズで除外されます（concurrent.k:757-791）：

```k
// nil channel への送信caseを除外
rule <k> selectBuildCases(
        (case (_Nil:FuncVal <- _) : _Body:Block) ; Rest:CommClauses,
        Acc:List)
      => selectBuildCases(Rest, Acc) ... </k>

// nil channel からの受信caseを除外
rule <k> selectBuildCases(
        (case (<- _Nil:FuncVal) : _Body:Block) ; Rest:CommClauses,
        Acc:List)
      => selectBuildCases(Rest, Acc) ... </k>
```

このため、すべてのcaseがnil channelでdefaultがない場合、空のリストが生成され、永久にブロックします。

## 4. 実行例とルール適用

### 4.1 例1: 受信準備完了ケース

#### コード (code-select-recv-ready)

```go
package main

func main() {
  ch := make(chan int, 1);
  ch <- 3;
  select {
  case v := <-ch: {
    print(v);
  };
  default: {
    print(99);
  }
  };
}
```

#### 実行ステップ

1. **初期化**:
   - `ch := make(chan int, 1)` → バッファサイズ1のチャネルを作成
   - `ch <- 3` → チャネルにバッファに3を送信（非ブロッキング）
   - チャネル状態: `chanState(.List, .List, ListItem(3), 1, int, false)`

2. **フェーズ1: 評価** (`selectEval` → `selectBuildCases`):
   ```
   select { case v := <-ch: {...}; default: {...} }
   ↓
   selectEval(cases)
   ↓
   selectBuildCases(cases, .List)
   ```

   - **case v := <-ch の評価**:
     - チャネル式 `ch` を評価 → `channel(0, int)` (仮にID=0)
     - context rule (行677-679) により `ch` が評価される
     - 評価結果を構築（行733-739）:
       ```k
       rule selectBuildCases(
         (case (v := <- channel(0, int)) : {print(v)}) ; Rest,
         Acc)
       => selectBuildCases(Rest, Acc ListItem(evalRecvDeclCase(channel(0, int), v, {print(v)})))
       ```

   - **default の評価** (行749-755):
     ```k
     rule selectBuildCases(
       (default : {print(99)}) ; .CommClauses,
       ListItem(evalRecvDeclCase(...)))
     => selectBuildCases(.CommClauses,
          ListItem(evalRecvDeclCase(channel(0, int), v, {print(v)}))
          ListItem(evalDefaultCase({print(99)})))
     ```

   - **評価完了** (行698-699):
     ```k
     rule selectBuildCases(.CommClauses, Acc)
       => selectWithCases(Acc)
     ```

   結果:
   ```
   selectWithCases(
     ListItem(evalRecvDeclCase(channel(0, int), v, {print(v)}))
     ListItem(evalDefaultCase({print(99)}))
   )
   ```

3. **フェーズ2: 準備チェック** (`selectWithCases` → `selectCheckReady`):
   ```
   selectWithCases(cases)
   ↓
   selectCheckReady(cases, .List, .K, cases)
   ```

   - **受信caseのチェック** (行896-913):
     ```k
     rule selectCheckReady(
       ListItem(evalRecvDeclCase(channel(0, int), v, body)) Rest,
       .List, .K, Orig)
     => selectCheckReady(Rest,
          ListItem(evalRecvDeclCase(channel(0, int), v, body)),
          .K, Orig)
     ```

     チャネル状態をチェック:
     ```
     <channels>... 0 |-> chanState(.List, .List, ListItem(3), 1, int, false) ...</channels>
     ```

     準備判定: `size(Buf) >Int 0` → **true**（バッファに値がある）

     → **準備完了リストに追加**

   - **defaultのチェック** (行958-963):
     ```k
     rule selectCheckReady(
       ListItem(evalDefaultCase(body)) .List,
       Ready, _Default, Orig)
     => selectCheckReady(.List, Ready, body, Orig)
     ```

     → **デフォルトボディを保存**

   - **チェック完了** (行796-801):
     ```k
     rule selectCheckReady(.List, Ready, Default, Orig)
       => selectChooseFrom(Ready, Default, Orig)
     ```

   結果:
   ```
   selectChooseFrom(
     ListItem(evalRecvDeclCase(channel(0, int), v, {print(v)})),
     {print(99)},
     原リスト
   )
   ```

4. **フェーズ3: 選択** (`selectChooseFrom`):

   準備完了リストが空でないため、最初の要素を選択（行965-969）:
   ```k
   rule selectChooseFrom(
     ListItem(evalRecvDeclCase(channel(0, int), v, {print(v)})) _Rest,
     _Default, _Orig)
   => executeSelectCase(evalRecvDeclCase(channel(0, int), v, {print(v)}))
   ```

5. **フェーズ4: 実行** (`executeSelectCase`):

   選択されたcaseを実行（行1113-1114）:
   ```k
   rule executeSelectCase(evalRecvDeclCase(channel(0, int), v, {print(v)}))
     => v := chanRecv(channel(0, int)) ~> {print(v)}
   ```

   - `v := chanRecv(channel(0, int))` を実行:
     - チャネルから値を受信（concurrent.k:311-335のバッファ受信ルール）
     - バッファから値を取り出す: `ListItem(3)` → `3`
     - `v := 3` を実行して変数 `v` を宣言・初期化

   - `{print(v)}` を実行:
     - `print(3)` → 出力: `3`

#### 期待される出力

```
3
```

defaultケースではなく、準備完了していた受信caseが選択されます。

### 4.2 例2: 送信準備完了ケース

#### コード (code-select-send-ready)

```go
package main

func main() {
  ch := make(chan int, 1);
  select {
  case ch <- 5: {
    print(7);
  };
  default: {
    print(99);
  }
  };
  x := <-ch;
  print(x);
}
```

#### 実行ステップ

1. **初期化**:
   - `ch := make(chan int, 1)` → バッファサイズ1のチャネルを作成
   - チャネル状態: `chanState(.List, .List, .List, 1, int, false)`
   - バッファは空

2. **フェーズ1: 評価** (`selectBuildCases`):

   - **case ch <- 5 の評価**:
     - チャネル式の評価 (context rule 行656-663):
       ```k
       context selectBuildCases(
         (case (HOLE:Exp <- _V:Exp) : _Body) ; _Rest, _Acc)
       ```
       `ch` → `channel(0, int)` (仮にID=0)

     - 送信値の評価 (context rule 行660-663):
       ```k
       context selectBuildCases(
         (case (_Chan:Exp <- HOLE:Exp) : _Body) ; _Rest, _Acc)
       ```
       `5` → `5`

     - caseの構築 (行701-707):
       ```k
       rule selectBuildCases(
         (case (channel(0, int) <- 5) : {print(7)}) ; Rest,
         .List)
       => selectBuildCases(Rest,
            ListItem(evalSendCase(channel(0, int), 5, {print(7)})))
       ```

   - **default の評価**:
     ```k
     rule selectBuildCases(
       (default : {print(99)}) ; .CommClauses,
       ListItem(evalSendCase(...)))
     => selectBuildCases(.CommClauses,
          ListItem(evalSendCase(channel(0, int), 5, {print(7)}))
          ListItem(evalDefaultCase({print(99)})))
     ```

   結果:
   ```
   selectWithCases(
     ListItem(evalSendCase(channel(0, int), 5, {print(7)}))
     ListItem(evalDefaultCase({print(99)}))
   )
   ```

3. **フェーズ2: 準備チェック** (`selectCheckReady`):

   - **送信caseのチェック** (行803-820):
     ```k
     rule selectCheckReady(
       ListItem(evalSendCase(channel(0, int), 5, {print(7)})) Rest,
       .List, .K, Orig)
     => selectCheckReady(Rest,
          ListItem(evalSendCase(channel(0, int), 5, {print(7)})),
          .K, Orig)
     ```

     チャネル状態:
     ```
     <channels>... 0 |-> chanState(.List, .List, .List, 1, int, false) ...</channels>
     ```

     準備判定条件（行817-819）:
     ```
     requires (Closed ==Bool true)           // false
       orBool (size(Buf) <Int Size)          // 0 < 1 → true ✓
       orBool (size(RecvQ) >Int 0)           // false
     ```

     → **準備完了**（バッファに空きがある）

   結果:
   ```
   selectChooseFrom(
     ListItem(evalSendCase(channel(0, int), 5, {print(7)})),
     {print(99)},
     原リスト
   )
   ```

4. **フェーズ3: 選択**:

   準備完了リストから最初の要素を選択（行965-969）:
   ```k
   rule selectChooseFrom(
     ListItem(evalSendCase(channel(0, int), 5, {print(7)})) _Rest,
     _Default, _Orig)
   => executeSelectCase(evalSendCase(channel(0, int), 5, {print(7)}))
   ```

5. **フェーズ4: 実行**:

   送信caseの実行（行1104-1105）:
   ```k
   rule executeSelectCase(evalSendCase(channel(0, int), 5, {print(7)}))
     => chanSend(channel(0, int), 5) ~> {print(7)}
   ```

   - `chanSend(channel(0, int), 5)` を実行:
     - バッファに空きがあるため非ブロッキング送信（concurrent.k:253-261）
     - チャネル状態を更新:
       ```
       chanState(.List, .List, .List, 1, int, false)
       → chanState(.List, .List, ListItem(5), 1, int, false)
       ```

   - `{print(7)}` を実行:
     - `print(7)` → 出力: `7`

6. **select後の処理**:

   - `x := <-ch` を実行:
     - バッファから値を受信: `5`
     - `x := 5`

   - `print(x)` を実行:
     - 出力: `5`

#### 期待される出力

```
7
5
```

送信caseが準備完了しているため、defaultではなく送信caseが選択されます。

### 4.3 例3: defaultケース

#### コード (code-select-default)

```go
package main

func main() {
  ch := make(chan int);
  select {
  case <-ch: {
    print(1);
  };
  default: {
    print(2);
  }
  };
}
```

#### 実行ステップ

1. **初期化**:
   - `ch := make(chan int)` → **unbuffered** channel（バッファサイズ0）
   - チャネル状態: `chanState(.List, .List, .List, 0, int, false)`

2. **フェーズ1: 評価**:

   - **case <-ch の評価** (行709-715):
     ```k
     rule selectBuildCases(
       (case (<- channel(0, int)) : {print(1)}) ; Rest,
       .List)
     => selectBuildCases(Rest,
          ListItem(evalRecvCase(channel(0, int), {print(1)})))
     ```

   - **default の評価**:
     ```k
     rule selectBuildCases(
       (default : {print(2)}) ; .CommClauses,
       ListItem(evalRecvCase(...)))
     => selectBuildCases(.CommClauses,
          ListItem(evalRecvCase(channel(0, int), {print(1)}))
          ListItem(evalDefaultCase({print(2)})))
     ```

   結果:
   ```
   selectWithCases(
     ListItem(evalRecvCase(channel(0, int), {print(1)}))
     ListItem(evalDefaultCase({print(2)}))
   )
   ```

3. **フェーズ2: 準備チェック**:

   - **受信caseのチェック** (行834-864):
     ```k
     rule selectCheckReady(
       ListItem(evalRecvCase(channel(0, int), {print(1)})) Rest,
       .List, .K, Orig)
     => ...
     ```

     チャネル状態:
     ```
     <channels>... 0 |-> chanState(.List, .List, .List, 0, int, false) ...</channels>
     ```

     準備判定条件（行848-850）:
     ```
     requires (size(Buf) >Int 0)           // 0 > 0 → false
       orBool (size(SendQ) >Int 0)         // 0 > 0 → false
       orBool (Closed ==Bool true)         // false
     ```

     このルールは適用されず、**準備未完了ルール**（行852-864）が適用:
     ```k
     rule selectCheckReady(
       ListItem(evalRecvCase(channel(0, int), {print(1)})) Rest,
       Ready, Default, Orig)
     => selectCheckReady(Rest, Ready, Default, Orig)  // Readyに追加しない
     ```

     → **準備未完了**（バッファ空、送信者なし、未closed）

   - **defaultのチェック**:
     defaultボディを保存

   結果:
   ```
   selectChooseFrom(
     .List,                    // 準備完了リストは空
     {print(2)},               // defaultボディ
     原リスト
   )
   ```

4. **フェーズ3: 選択**:

   準備完了リストが空でdefaultがある場合（行971-976）:
   ```k
   rule selectChooseFrom(.List, {print(2)}, _Orig)
     => executeSelectCase(evalDefaultCase({print(2)}))
     requires hasDefault({print(2)})  // true
   ```

5. **フェーズ4: 実行**:

   defaultケースの実行（行1119-1120）:
   ```k
   rule executeSelectCase(evalDefaultCase({print(2)}))
     => {print(2)}
   ```

   - `print(2)` → 出力: `2`

#### 期待される出力

```
2
```

unbufferedチャネルにバッファも送信者もないため、受信caseは準備未完了となり、defaultケースが選択されます。

### 4.4 例4: ブロッキングとgoroutine

#### コード (code-select-blocking-go)

```go
package main

func send(ch chan int) {
  ch <- 10;
}

func main() {
  ch := make(chan int);
  go send(ch);
  select {
  case v := <-ch: {
    print(v);
  }
  };
}
```

このコードは、defaultケースがない場合のブロッキング動作を示します。

#### 実行ステップ

1. **初期化**:
   - `ch := make(chan int)` → unbufferedチャネル
   - チャネル状態: `chanState(.List, .List, .List, 0, int, false)`

2. **Goroutine起動**:
   - `go send(ch)` → 新しいスレッド（tid=1と仮定）を作成
   - スレッド1は `send(ch)` を実行開始
   - メインスレッド（tid=0）は並行して継続

3. **フェーズ1-2: 評価と準備チェック**:

   メインスレッドでselect文を評価:

   - **評価結果**:
     ```
     selectWithCases(
       ListItem(evalRecvDeclCase(channel(0, int), v, {print(v)}))
     )
     ```

   - **準備チェック**:

     この時点でのチャネル状態により2つのシナリオがあります：

     **シナリオA: goroutineがまだ送信していない場合**

     チャネル状態: `chanState(.List, .List, .List, 0, int, false)`

     準備判定:
     ```
     requires (size(Buf) >Int 0)           // false
       orBool (size(SendQ) >Int 0)         // false
       orBool (Closed ==Bool true)         // false
     ```

     → **準備未完了**

     **シナリオB: goroutineが既に送信を試みている場合**

     goroutineが先に `ch <- 10` を実行し、ブロック:
     - チャネル状態: `chanState(ListItem(sendItem(1, 10)), .List, .List, 0, int, false)`
     - スレッド1: `waitingSend(0, 10)` 状態でブロック中

     準備判定:
     ```
     requires (size(Buf) >Int 0)           // false
       orBool (size(SendQ) >Int 0)         // 1 > 0 → true ✓
       orBool (Closed ==Bool true)         // false
     ```

     → **準備完了**

4. **フェーズ3-4: 選択と実行**:

   **シナリオA: ブロッキング**

   準備完了リストが空で、defaultもないため（行978-983）:
   ```k
   rule selectChooseFrom(.List, .K, Orig)
     => selectBlock(Orig, Orig)
     requires notBool hasDefault(.K)
   ```

   **ブロッキングフェーズに突入**:

   `selectBlock` は状態変化を監視します。並行して実行中のgoroutineが送信を試みると：

   - goroutineが `ch <- 10` を実行
   - チャネル状態が更新: `chanState(ListItem(sendItem(1, 10)), .List, .List, 0, int, false)`

   ブロッキングループで状態変化を検出（行1000-1025）:
   ```k
   rule <thread>...
          <tid> 0 </tid>  // メインスレッド
          <k> selectBlock(
               ListItem(evalRecvCase(channel(0, int), {print(v)})) _Rest,
               _Orig)
           => chanRecv(channel(0, int)) ~> {print(v)} ... </k>
        ...</thread>
        <channels>...
          0 |-> chanState(
            (ListItem(sendItem(1, 10)) _SendRest:List),
            _RecvQ, .List, 0, int, false)
        ...</channels>
   ```

   待機中の送信者がいるため、直接受信を実行:
   - `chanRecv` が送信者との直接ハンドオフを実行（concurrent.k:336-348）
   - スレッド1の `waitingSend(0, 10)` を解決
   - メインスレッドは値 `10` を受信

   **シナリオB: 即座に実行**

   準備完了リストに要素があるため、即座に実行:
   ```k
   executeSelectCase(evalRecvDeclCase(channel(0, int), v, {print(v)}))
   => v := chanRecv(channel(0, int)) ~> {print(v)}
   ```

   - `chanRecv` が待機中の送信者から直接受信
   - スレッド1の `waitingSend` を解決
   - `v := 10` → `print(v)` → 出力: `10`

#### 期待される出力

```
10
```

いずれのシナリオでも、goroutineからの送信が完了し、値が正しく受信されます。この例は、select文がブロッキングして、他のgoroutineの操作を待機できることを示します。

## 5. 実装の特徴

### 5.1 4フェーズ設計の利点

1. **Goの仕様への忠実な実装**:
   - 仕様の実行ステップを直接的にモデル化
   - 各フェーズが仕様の1ステップに対応

2. **明確な関心の分離**:
   - 評価（Evaluation）: 式の計算のみに集中
   - 準備チェック（Ready Check）: チャネル状態の検査のみ
   - 選択（Selection）: 選択ロジックのみ
   - 実行（Execution）: 通信と文の実行のみ

3. **デバッグの容易性**:
   - 各フェーズの状態を個別に検査可能
   - ルールの適用順序が明確

### 5.2 選択の決定性に関する制限

**重要**: 現在の実装では、複数の準備完了caseがある場合、**常に最初のcase（ソース順で最初に評価されたcase）が選択されます**。これはGoの仕様が要求する「一様疑似ランダム選択」とは異なります。

```k
rule <k> selectChooseFrom(ListItem(Case:EvalCase) _Rest:List, _Default:K, _Orig:List)
      => executeSelectCase(Case) ... </k>
```

このルールのパターン `ListItem(Case) _Rest` は、リストの**先頭要素**にのみマッチします。K Frameworkのリストパターンマッチングでは、`_Rest`は「残りの要素」を意味するだけで、リストの任意の位置にマッチするわけではありません。

#### 検証例

次のコードを実行すると、常に `1` が出力されます（ch2からの受信は選択されない）：

```go
func main() {
  ch1 := make(chan int, 1);
  ch2 := make(chan int, 1);
  ch1 <- 1;
  ch2 <- 2;
  select {
  case v1 := <-ch1: {
    print(v1);  // 常にこちらが選択される
  };
  case v2 := <-ch2: {
    print(v2);  // 選択されない
  }
  };
}
```

#### なぜ非決定的選択が実装されていないか

K Frameworkで真の非決定的選択を実装するには：

1. **リストの任意位置へのマッチ**: `L1 ListItem(Case) L2` というパターンが必要だが、K Frameworkのパターンマッチングコンパイラがこれをサポートしていない（内部エラーが発生）

2. **代替アプローチが必要**:
   - ヘルパー関数で準備完了リストからランダムに1つを選択
   - 外部の乱数生成機構を使用
   - 準備完了リストをシャッフルしてから先頭を選択

#### 実装への影響

この制限により：

- **決定的な動作**: 同じ初期状態から常に同じcaseが選択される
- **テストの容易性**: 再現性のあるテスト実行が可能（利点でもある）
- **仕様との乖離**: Goの並行プログラムで公平性（fairness）を期待するコードは期待通りに動作しない可能性がある

実際のGoランタイムでは、複数の準備完了caseがある場合に一様疑似ランダムに選択することで、特定のcaseへの偏りを防ぎ、飢餓（starvation）を回避しています。

### 5.3 Blocking vs Polling

実装はブロッキングとポーリングのハイブリッドアプローチ：

**ブロッキング的側面**:
- `selectBlock` 状態でスレッドは明示的な進行を停止
- 他のスレッドの操作を待機

**ポーリング的側面**:
- ブロッキング中、定期的にチャネル状態をチェック
- 状態変化を検出したら、準備チェックフェーズを再実行

これはK Frameworkのrewritingモデルに適した設計で、真のスレッドブロッキングを実装することなく、Goのブロッキングセマンティクスを実現します。

### 5.4 優先度ルールとの統合

select文の実装は、既存のチャネル操作の優先度ルールを再利用：

- `chanSend` / `chanRecv` は既存のルール（Priority 0-5）を使用
- `executeSelectCase` で通常のチャネル操作に委譲
- select特有のロジックと通常のチャネルロジックが明確に分離

これにより：
- コードの重複を排除
- チャネルセマンティクスの一貫性を保証
- メンテナンス性の向上

### 5.5 nil Channelの最適化

nil channelは決して進行しないため、評価フェーズで除外することで効率化：

```k
rule <k> selectBuildCases(
        (case (_Nil:FuncVal <- _) : _Body:Block) ; Rest:CommClauses, Acc:List)
      => selectBuildCases(Rest, Acc) ... </k>
```

利点：
- 準備チェックフェーズでnil channelを考慮する必要がない
- 選択フェーズでのマッチングパターンが簡潔
- ランタイムオーバーヘッドの削減

### 5.6 Context Rulesによる評価制御

式の評価タイミングを正確に制御するため、context rulesを活用：

```k
context selectBuildCases(
          (case (HOLE:Exp <- _V:Exp) : _Body:Block) ; _Rest:CommClauses,
          _Acc:List)
```

このアプローチにより：
- チャネル式が送信値より先に評価されることを保証
- Goの仕様（「ソース順に評価」）を厳密に実装
- strict attributeよりも細かい制御が可能

## 6. 制約と将来の拡張

### 6.1 現在の制約

1. **選択の決定性（最重要の制限）**:
   - **複数の準備完了caseがある場合、常に最初のcaseが選択される**
   - Goの仕様が要求する「一様疑似ランダム選択」が実装されていない
   - 原因: K Frameworkのリストパターンマッチングの制限（`ListItem(Case) _Rest`は先頭のみにマッチ）
   - 影響:
     - 公平性（fairness）が保証されない
     - 特定のcaseが飢餓（starvation）を起こす可能性
     - 実際のGoプログラムとは異なる動作をする場合がある
   - 回避策: 準備完了リストをランダムシャッフルするヘルパー関数の追加が必要

2. **パフォーマンス**:
   - ポーリングベースのアプローチはオーバーヘッドがある
   - 大量のgoroutineがブロックする場合、スケーラビリティに課題
   - 実際のGoランタイムのような最適化（epoll等）は未実装

3. **エラー処理の簡略化**:
   - panic実装が基本的（単に停止するのみ）
   - スタックトレースやrecoverメカニズムなし

4. **構文制約**:
   - 各caseにBlock（`{...}`）が必須
   - Goの標準では単一文も許可されるが、実装ではブロックを要求

### 6.2 将来の拡張可能性

1. **真の非決定的選択の実装（最優先）**:

   現在の決定的選択を改善するための具体的なアプローチ：

   **アプローチA: リストシャッフル関数**:
   ```k
   syntax List ::= shuffleList(List, Int) [function]  // List, seed

   rule <k> selectChooseFrom(Ready:List, Default:K, Orig:List)
         => selectChooseFrom(shuffleList(Ready, $RANDOM), Default, Orig) ... </k>
     requires size(Ready) >Int 1
     [priority(10)]
   ```

   **アプローチB: インデックスベース選択**:
   ```k
   syntax Int ::= randomInt(Int) [function, hook(INT.random)]
   syntax K ::= selectAt(List, Int) [function]

   rule selectChooseFrom(Ready:List, Default:K, Orig:List)
     => executeSelectCase(selectAt(Ready, randomInt(size(Ready))))
     requires size(Ready) >Int 0
   ```

   **実装の利点**:
   - Goの仕様に準拠した動作
   - 公平性の保証
   - 飢餓の回避
   - より現実的な並行プログラムのシミュレーション

2. **明示的な選択ポリシー**:
   ```k
   syntax SelectPolicy ::= "random" | "priority" | "fifo"
   syntax SelectStmt ::= "select" SelectPolicy "{" CommClauses "}"
   ```
   テストやデバッグ用に選択戦略を指定可能に
   - `random`: 一様疑似ランダム（Goの標準）
   - `priority`: ソース順（現在の実装）
   - `fifo`: 最も長く待機しているcaseを選択

3. **タイムアウトサポート**:
   ```go
   select {
   case v := <-ch:
       // ...
   case <-time.After(1 * time.Second):
       // timeout
   }
   ```
   時間ベースの操作をサポート

3. **統計情報の収集**:
   - 各caseが選択された回数
   - ブロッキング時間
   - パフォーマンスプロファイリング用

4. **より効率的なブロッキング**:
   - イベント駆動型アプローチ
   - 状態変化時の明示的な通知メカニズム
   - スケーラビリティの向上

5. **デバッグサポート**:
   ```k
   syntax KItem ::= selectTrace(List)  // 実行履歴を記録
   ```
   select文の実行過程を詳細にトレース

### 6.3 テスト拡張

現在のテストケースに加え、以下のようなケースを追加可能：

1. **複数の準備完了case**:
   - 非決定的選択の検証
   - すべてのcaseが選択される可能性の確認

2. **大規模並行性**:
   - 多数のgoroutineとselect文
   - スケーラビリティテスト

3. **ネストしたselect**:
   ```go
   select {
   case v := <-ch1:
       select {
       case ch2 <- v:
       case <-ch3:
       }
   }
   ```

4. **クローズドチャネルとselect**:
   - クローズされたチャネルの優先度
   - ok値の検証

## 7. まとめ

このselect文の実装は、K Frameworkの強力な書き換えシステムとパターンマッチングを活用し、Goの並行制御構造の多くの側面を形式的にモデル化しています。

**主要な設計決定**:

1. **4フェーズ設計**: 仕様の実行ステップを直接モデル化し、理解しやすく保守しやすい実装
2. **既存インフラの再利用**: チャネル操作の優先度ルールを活用し、コードの重複を排除
3. **Context rulesによる制御**: 評価順序をGoの仕様通りに厳密に制御
4. **ブロッキングセマンティクス**: ポーリングベースのアプローチでGoのブロッキング動作を実現

**既知の制限**:

1. **決定的選択**: 複数の準備完了caseがある場合、常に最初のcaseが選択される（Goの仕様では一様疑似ランダム）
2. **公平性の欠如**: 特定のcaseが飢餓状態に陥る可能性がある
3. **K Frameworkの制約**: リストパターンマッチングの制限により、真の非決定的選択が困難

**適用範囲**:

この実装は以下の用途に適しています：

- **教育**: select文の動作原理とセマンティクスの理解
- **形式検証**: 単一の準備完了caseまたはdefaultケースを含むプログラムの検証
- **デバッグ**: 決定的な動作により再現性のあるテスト実行が可能
- **セマンティクス研究**: Goの並行制御構造の形式的な定義

一方、以下の用途には現状では不適切です：

- **実際のGoプログラムの完全なシミュレーション**: 選択の決定性により動作が異なる可能性
- **公平性が重要なプログラムの検証**: 飢餓や不公平な選択の検出が不可能
- **パフォーマンス測定**: ポーリングベースの実装により実際のGoランタイムとは異なる

**今後の改善方向**:

最優先の改善は、ランダム選択機構の追加です。これにより、実装はGoの仕様により忠実となり、より広範な並行プログラムの検証に利用可能となります。

この実装は、K Frameworkを使った言語セマンティクスの形式化の良い例であり、select文という複雑な並行制御構造を明確で検証可能な方法で表現しています。制限はあるものの、Go言語のセマンティクスの研究と教育に有用なリソースとなります。
