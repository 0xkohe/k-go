# なぜGoroutineは非決定的に動作するのか - ルール適用の観点から

## K Frameworkのルール適用メカニズム

K Frameworkでは、**複数のルールが同時にマッチする場合、どのルールを適用するかは非決定的**です。

## 具体例で理解する

### 例: 3つのGoroutineが並行実行

**コード:**
```go
func main() {
    go worker(1);
    go worker(2);
    go worker(3);
}
```

### ステップ1: Goroutine生成後の状態

3つのgoroutineが生成された後の設定：

```k
<threads>
  <thread>  // メインスレッド
    <tid> 0 </tid>
    <k> .K </k>  // すでに完了
  </thread>

  <thread>  // worker(1)
    <tid> 1 </tid>
    <k> print(1); ~> exitScope ~> exitScope ~> returnJoin(void) </k>
  </thread>

  <thread>  // worker(2)
    <tid> 2 </tid>
    <k> print(2); ~> exitScope ~> exitScope ~> returnJoin(void) </k>
  </thread>

  <thread>  // worker(3)
    <tid> 3 </tid>
    <k> print(3); ~> exitScope ~> exitScope ~> returnJoin(void) </k>
  </thread>
</threads>
```

### ステップ2: print()ルールのマッチング

`print(n)` のルールは以下のように定義されています：

```k
rule <k> print(I:Int) => .K ... </k>
     <out> ... (.List => ListItem(I)) </out>
```

**重要ポイント**: このルールには `<tid>` の指定がありません！

### ステップ3: 複数のマッチング

この時点で、**3つのルールインスタンスが同時にマッチ**します：

#### マッチング1: スレッド1のprint
```k
rule <thread>...
       <tid> 1 </tid>
       <k> print(1) => .K ... </k>
     ...</thread>
     <out> ... (.List => ListItem(1)) </out>
```

#### マッチング2: スレッド2のprint
```k
rule <thread>...
       <tid> 2 </tid>
       <k> print(2) => .K ... </k>
     ...</thread>
     <out> ... (.List => ListItem(2)) </out>
```

#### マッチング3: スレッド3のprint
```k
rule <thread>...
       <tid> 3 </tid>
       <k> print(3) => .K ... </k>
     ...</thread>
     <out> ... (.List => ListItem(3)) </out>
```

### ステップ4: 非決定的選択

**K Frameworkは、これらの3つのマッチングから1つを非決定的に選択します。**

#### 選択肢A: スレッド1を実行
```k
<out> ListItem(1) </out>
<thread tid=1> <k> exitScope ~> ... </k> </thread>
<thread tid=2> <k> print(2); ~> ... </k> </thread>  // まだ待機中
<thread tid=3> <k> print(3); ~> ... </k> </thread>  // まだ待機中
```

次のステップでは、スレッド2とスレッド3のprint()がマッチ → 再び非決定的選択

#### 選択肢B: スレッド2を実行
```k
<out> ListItem(2) </out>
<thread tid=1> <k> print(1); ~> ... </k> </thread>  // まだ待機中
<thread tid=2> <k> exitScope ~> ... </k> </thread>
<thread tid=3> <k> print(3); ~> ... </k> </thread>  // まだ待機中
```

#### 選択肢C: スレッド3を実行
```k
<out> ListItem(3) </out>
<thread tid=1> <k> print(1); ~> ... </k> </thread>  // まだ待機中
<thread tid=2> <k> print(2); ~> ... </k> </thread>  // まだ待機中
<thread tid=3> <k> exitScope ~> ... </k> </thread>
```

## なぜ非決定的なのか：技術的理由

### 1. セル変数の暗黙的マッチング

ルール定義で `<thread>...` と書くと、K Frameworkは**どの thread セルにもマッチ**します：

```k
// このルールは
rule <k> print(I:Int) => .K ... </k>
     <out> ... (.List => ListItem(I)) </out>

// 実際には以下のように展開される
rule <threads>
       <thread>
         <tid> _Tid:Int </tid>  // どのTidでもマッチ！
         <k> print(I:Int) => .K ... </k>
         ...
       </thread>
       ...  // 他のthreadは無視
     </threads>
     <out> ... (.List => ListItem(I)) </out>
```

`_Tid:Int` は**アンダースコア変数**で、「どんな値でもマッチするが、値を使わない」という意味です。

### 2. multiplicity="*" の効果

設定で `<thread multiplicity="*">` と定義しているため、`<threads>` セルには**任意の数の `<thread>` セルが存在**できます。

K Frameworkのマッチングアルゴリズムは：
1. 全てのスレッドをスキャン
2. ルールにマッチするスレッドを全て見つける
3. その中から1つを**非決定的に**選択

### 3. 優先度やスケジューリングの不在

現在の実装では、スレッドの実行優先度やスケジューリングポリシーを定義していません。

もし優先度を定義したい場合：
```k
<thread>
  <tid> ... </tid>
  <priority> 10 </priority>  // 優先度を追加
  ...
</thread>

// 高優先度を優先するルール
rule <k> ... </k>
     <tid> Tid </tid>
     <priority> P </priority>
  requires P ==Int maxPriority()
  [priority(10)]  // このルールを優先的に適用
```

## チャネル通信での非決定性

### 送信側の競合

**コード:**
```go
ch := make(chan int)
go sender1(ch, 100)
go sender2(ch, 200)
value := <-ch
```

**状態:**
```k
<threads>
  <thread>  // メイン
    <tid> 0 </tid>
    <k> waitingRecv(0) ~> ... </k>
  </thread>

  <thread>  // sender1
    <tid> 1 </tid>
    <k> chanSend(channel(0, int), 100) ~> ... </k>
  </thread>

  <thread>  // sender2
    <tid> 2 </tid>
    <k> chanSend(channel(0, int), 200) ~> ... </k>
  </thread>
</threads>

<channels>
  0 |-> chanState(.List, ListItem(0), int)  // メインが受信待ち
</channels>
```

### 送信ルールの2つのマッチング

#### マッチング1: sender1が送信
```k
rule <thread>...
       <tid> 1 </tid>  // sender1
       <k> chanSend(channel(0, int), 100) => .K ... </k>
     ...</thread>
     <channels>...
       0 |-> (chanState(_SendQ, (ListItem(0) RecvRest:List), int)
            => chanState(_SendQ, RecvRest, int))
     ...</channels>
     <thread>...
       <tid> 0 </tid>  // メイン
       <k> waitingRecv(0) => 100 ... </k>  // 100を受信！
     ...</thread>
```

#### マッチング2: sender2が送信
```k
rule <thread>...
       <tid> 2 </tid>  // sender2
       <k> chanSend(channel(0, int), 200) => .K ... </k>
     ...</thread>
     <channels>...
       0 |-> (chanState(_SendQ, (ListItem(0) RecvRest:List), int)
            => chanState(_SendQ, RecvRest, int))
     ...</channels>
     <thread>...
       <tid> 0 </tid>  // メイン
       <k> waitingRecv(0) => 200 ... </k>  // 200を受信！
     ...</thread>
```

**K Frameworkの選択**: どちらのマッチングを選ぶかは非決定的
- 選択肢A → メインは100を受信
- 選択肢B → メインは200を受信

## 実際のルール適用の追跡

### デバッグモードで確認

K Frameworkの `--debugger` オプションを使うと、ルール適用を追跡できます：

```bash
krun codes/code-goroutine-race --debugger
```

デバッガでは：
1. 現在マッチする全てのルールが表示される
2. どのルールを適用するか選択できる
3. ステップごとに状態を確認できる

### trace 出力

```bash
krun codes/code-goroutine-race --trace
```

これにより、適用されたルールの順序が出力されます。

## 決定的実行の実装方法

非決定性を制御したい場合の実装例：

### 方法1: スレッドIDの順序で実行

```k
configuration
  <currentTid> 0 </currentTid>  // 現在実行中のスレッドID
  <threads> ... </threads>

// 現在のスレッドIDのみ実行を許可
rule <k> K:K => K' ... </k>
     <tid> Tid </tid>
     <currentTid> Tid </currentTid>
  requires canStep(K)

// スレッド切り替え
rule <currentTid> Tid => Tid +Int 1 </currentTid>
  requires threadFinished(Tid)
```

### 方法2: ラウンドロビン

```k
rule <k> yield => .K ... </k>
     <tid> Tid </tid>
     <currentTid> Tid => nextTid(Tid) </currentTid>

syntax Int ::= nextTid(Int) [function]
rule nextTid(Tid) => (Tid +Int 1) modInt totalThreads()
```

### 方法3: 明示的なスケジューラ

```k
<scheduler>
  <queue> ListItem(1) ListItem(2) ListItem(3) </queue>
  <running> 0 </running>
</scheduler>

rule <running> OldTid => NewTid </running>
     <queue> (ListItem(NewTid) => .List) Rest </queue>
  requires threadBlocked(OldTid)
```

## まとめ

### 非決定性の原因

1. **複数のマッチング**: 複数のスレッドで同じルールがマッチ
2. **暗黙的な選択**: K Frameworkはどれを選ぶか決定しない
3. **スケジューラの不在**: 実行順序を制御するメカニズムがない

### 非決定性の効果

- ✅ **正確なモデル**: 実際のgoroutineの動作を反映
- ✅ **バグ検出**: `--search` で全実行パスを探索
- ⚠️ **デバッグ困難**: 実行ごとに結果が変わる可能性

### K Frameworkの動作

```
状態S → ルールマッチング → [R1, R2, R3, ...] → 非決定的選択 → 状態S'
                                                        ↓
                                                   R2を選択
                                                        ↓
                                                     状態S2'
```

この非決定的選択により、異なる実行パスが生成されます。

---

**結論**: 非決定性は、K Frameworkの基本的なルールマッチングメカニズムから自然に生じます。複数のスレッドが存在し、それぞれが独立してルールにマッチできる場合、どのスレッドのルールを先に適用するかは非決定的になります。
