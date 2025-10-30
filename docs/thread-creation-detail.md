# スレッド新規作成の詳細解説

## スレッド作成の場所

スレッドの新規作成は **`src/go/semantics/concurrent.k` の38-54行目** で行われています。

## 完全なルール

```k
// Go statement: spawn a new thread to execute the function call
rule <thread>...
       <tid> _ParentTid </tid>
       <k> go FCall:Exp => .K ... </k>
       <tenv> TEnv </tenv>
       <env> Env </env>
     ...</thread>
     (.Bag =>
       <thread>...
         <tid> N </tid>
         <k> FCall </k>
         <tenv> TEnv </tenv>
         <env> Env </env>
         <envStack> .List </envStack>
         <tenvStack> .List </envStack>
         <scopeDecls> .List </scopeDecls>
       ...</thread>)
     <nextTid> N:Int => N +Int 1 </nextTid>
```

**ファイル**: `src/go/semantics/concurrent.k:38-54`

## ルールの詳細解説

### 1. マッチング条件（左辺）

#### 親スレッドの条件

```k
<thread>...
  <tid> _ParentTid </tid>
  <k> go FCall:Exp => .K ... </k>
  <tenv> TEnv </tenv>
  <env> Env </env>
...</thread>
```

**マッチする条件:**
- 任意のスレッド（`_ParentTid` はアンダースコア変数なのでどのTidでもマッチ）
- `<k>` セルに `go FCall` がある
- `FCall` は任意の式（通常は関数呼び出し）
- `TEnv` = 親スレッドの型環境を変数にバインド
- `Env` = 親スレッドの変数環境を変数にバインド

#### グローバル状態の条件

```k
<nextTid> N:Int => N +Int 1 </nextTid>
```

**マッチする条件:**
- `<nextTid>` セルから次のスレッドID `N` を読み取る
- 同時に `N +Int 1` に更新（アトミック操作）

### 2. 書き換え動作（右辺）

#### 親スレッドの更新

```k
<k> go FCall:Exp => .K ... </k>
```

**動作:**
- `go FCall` を `<k>` セルから削除（`.K` = 空の計算）
- 親スレッドは次の命令に進む
- `FCall` は評価されず、新スレッドに移動

#### 新スレッドの生成

```k
(.Bag =>
  <thread>...
    <tid> N </tid>
    <k> FCall </k>
    <tenv> TEnv </tenv>
    <env> Env </env>
    <envStack> .List </envStack>
    <tenvStack> .List </envStack>
    <scopeDecls> .List </scopeDecls>
  ...</thread>)
```

**動作:**
- `.Bag =>` は「空から新しいセルを生成」を意味
- 新しい `<thread>` セルを作成
- 各サブセルに値を設定：
  - `<tid>`: 新しいスレッドID `N`
  - `<k>`: 親から移動した `FCall`（ここから実行開始）
  - `<tenv>`: 親の型環境 `TEnv` をコピー
  - `<env>`: 親の変数環境 `Env` をコピー
  - `<envStack>`: 空のリストで初期化
  - `<tenvStack>`: 空のリストで初期化
  - `<scopeDecls>`: 空のリストで初期化

#### nextTidの更新

```k
<nextTid> N:Int => N +Int 1 </nextTid>
```

**動作:**
- 次回のスレッド生成に備えて `nextTid` をインクリメント

## K Frameworkの特殊構文

### `.Bag =>` 構文

```k
(.Bag => <thread>...</thread>)
```

これはK Frameworkの**セル生成構文**です：

- **左辺 `.Bag`**: 空のバッグ（何も存在しない状態）
- **右辺 `<thread>...</thread>`**: 新しいセルを生成
- **意味**: 「新しいスレッドセルを設定に追加する」

### `<thread>` セルの multiplicity

設定で `<thread multiplicity="*" type="Set">` と定義されているため：

- **`multiplicity="*"`**: 0個以上の thread セルが存在可能
- **`type="Set"`**: 順序は関係なく、集合として扱われる

これにより、`.Bag => <thread>...</thread>` で新しいスレッドを追加できます。

## 具体例で追跡

### 例: go printNum(42)

**初期状態:**
```k
<threads>
  <thread>
    <tid> 0 </tid>
    <k> go printNum(42); print(2); </k>
    <tenv> printNum |-> func(...) </tenv>
    <env> .Map </env>
  </thread>
</threads>
<nextTid> 1 </nextTid>
```

**ルールマッチング:**

```k
// 変数バインディング:
_ParentTid = 0
FCall = printNum(42)
TEnv = (printNum |-> func(...))
Env = .Map
N = 1
```

**書き換え後:**

```k
<threads>
  <thread>  // 親スレッド
    <tid> 0 </tid>
    <k> print(2); </k>  // go printNum(42) が削除された
    <tenv> printNum |-> func(...) </tenv>
    <env> .Map </env>
  </thread>

  <thread>  // 新スレッド（生成された！）
    <tid> 1 </tid>
    <k> printNum(42) </k>  // ここから実行開始
    <tenv> printNum |-> func(...) </tenv>  // 親からコピー
    <env> .Map </env>  // 親からコピー
    <envStack> .List </envStack>  // 初期化
    <tenvStack> .List </tenvStack>  // 初期化
    <scopeDecls> .List </scopeDecls>  // 初期化
  </thread>
</threads>
<nextTid> 2 </nextTid>  // インクリメントされた
```

## なぜ環境をコピーするのか

### 環境のコピー

```k
<tenv> TEnv </tenv>
<env> Env </env>
```

**理由:**
- Goroutineは親の変数にアクセスできる必要がある
- クロージャのキャプチャを実現

**例:**
```go
func main() {
    x := 10
    go func() {
        print(x)  // 親のxにアクセス
    }()
}
```

### スタックの初期化

```k
<envStack> .List </envStack>
<tenvStack> .List </tenvStack>
<scopeDecls> .List </scopeDecls>
```

**理由:**
- 新スレッドは独立したスコープスタックを持つ
- 親のネストしたスコープを引き継がない

## 複数のGoroutine生成

**コード:**
```go
go worker(1)
go worker(2)
go worker(3)
```

**実行フロー:**

### ステップ1: 最初のgoroutine生成
```k
<k> go worker(1); go worker(2); go worker(3); </k>
```
→ ルール適用 →
```k
<threads>
  <thread tid=0> <k> go worker(2); go worker(3); </k> </thread>
  <thread tid=1> <k> worker(1) </k> </thread>  // 新規作成
</threads>
<nextTid> 2 </nextTid>
```

### ステップ2: 2番目のgoroutine生成
```k
<k> go worker(2); go worker(3); </k>
```
→ ルール適用 →
```k
<threads>
  <thread tid=0> <k> go worker(3); </k> </thread>
  <thread tid=1> <k> worker(1) </k> </thread>
  <thread tid=2> <k> worker(2) </k> </thread>  // 新規作成
</threads>
<nextTid> 3 </nextTid>
```

### ステップ3: 3番目のgoroutine生成
```k
<k> go worker(3); </k>
```
→ ルール適用 →
```k
<threads>
  <thread tid=0> <k> .K </k> </thread>  // 完了
  <thread tid=1> <k> worker(1) </k> </thread>
  <thread tid=2> <k> worker(2) </k> </thread>
  <thread tid=3> <k> worker(3) </k> </thread>  // 新規作成
</threads>
<nextTid> 4 </nextTid>
```

## スレッド生成の特徴

### 1. 即座に実行可能

新しいスレッドは生成された瞬間から実行可能です。次のステップで：
- 親スレッドの続きを実行
- 新スレッドの `FCall` を実行

どちらが先に実行されるかは**非決定的**です。

### 2. 環境の共有（ストア経由）

```k
// 親スレッド
<env> x |-> 0 </env>

// 新スレッド（環境をコピー）
<env> x |-> 0 </env>

// 共有ストア
<store> 0 |-> 10 </store>
```

両スレッドが同じロケーション（0）を参照するため、同じ変数にアクセスできます。

### 3. スレッドID管理

```k
<nextTid> N:Int => N +Int 1 </nextTid>
```

- スレッドIDは単調増加
- 衝突なし
- 各スレッドは一意のIDを持つ

## スレッド削除

スレッドはいつ削除されるのか？

**現在の実装では、スレッドは削除されません。**

スレッドが終了すると：
```k
<thread>
  <tid> 1 </tid>
  <k> .K </k>  // 空 = 実行完了
  ...
</thread>
```

`<k>` が空になったスレッドは、それ以上ルールにマッチしないため、**実質的に非アクティブ**になります。

### 将来の拡張: スレッド回収

```k
// 終了したスレッドを削除
rule (<thread>
       <tid> _Tid </tid>
       <k> .K </k>
       ...
     </thread> => .Bag)
```

このルールを追加すれば、終了したスレッドを設定から削除できます。

## まとめ

### スレッド作成の場所
**`src/go/semantics/concurrent.k:38-54`**

### 作成のメカニズム
1. **マッチング**: `go FCall` を検出
2. **環境キャプチャ**: 親の TEnv, Env を取得
3. **新セル生成**: `.Bag => <thread>...` で追加
4. **ID割り当て**: `nextTid` から取得してインクリメント

### 重要なポイント
- ✅ 環境をコピーして変数アクセスを可能に
- ✅ スタックは初期化して独立させる
- ✅ 新スレッドは即座に実行可能
- ✅ スレッドIDは一意で単調増加

---

**K Framework の `.Bag =>` 構文がスレッド作成の核心**です。この構文により、実行時に動的にスレッドを追加できます。
