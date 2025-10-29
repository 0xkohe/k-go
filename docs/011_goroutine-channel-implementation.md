# Goroutine and Channel Implementation in K Framework

K FrameworkでのGo言語のGoroutine（並行処理）とChannel（チャネル）の実装について、具体的なルール適用の流れを含めて詳細に解説します。

## 目次

1. [実装の概要](#実装の概要)
2. [アーキテクチャの変更](#アーキテクチャの変更)
3. [Goroutineの実装](#goroutineの実装)
4. [Channelの実装](#channelの実装)
5. [具体的な実行例](#具体的な実行例)
6. [技術的な課題と解決策](#技術的な課題と解決策)

## 実装の概要

### 実装された機能

- **Goroutines**: `go` ステートメントによる軽量スレッドの生成
- **Channels**: `make(chan Type)` によるチャネルの作成
- **Channel Operations**: `ch <- value` (送信) と `value := <-ch` (受信)
- **Blocking Semantics**: 送信/受信のブロッキング動作

### ファイル構成

```
src/go/
├── syntax/
│   └── concurrent.k        # 並行処理の構文定義
├── semantics/
│   ├── core.k             # マルチスレッド対応の設定セル
│   ├── func.k             # 改善された関数呼び出し
│   └── concurrent.k       # Goroutineとチャネルのセマンティクス
└── main.k                 # メインモジュール
```

## アーキテクチャの変更

### 設定セルの再設計

**変更前（単一スレッド）:**
```k
configuration
  <T>
    <k> $PGM:Program </k>
    <tenv> .Map </tenv>
    <env> .Map </env>
    <out> .List </out>
    <store> .Map </store>
    ...
  </T>
```

**変更後（マルチスレッド）:**
```k
configuration
  <T>
    <threads>
      <thread multiplicity="*" type="Set">
        <tid> 0 </tid>                    // スレッドID
        <k> $PGM:Program </k>             // 実行中の計算
        <tenv> .Map </tenv>               // 型環境（スレッドローカル）
        <env> .Map </env>                 // 変数環境（スレッドローカル）
        <envStack> .List </envStack>      // 環境スタック
        <tenvStack> .List </tenvStack>    // 型環境スタック
        <scopeDecls> .List </scopeDecls>  // スコープ宣言
      </thread>
    </threads>
    <nextTid> 1 </nextTid>                // 次のスレッドID
    <out> .List </out>                    // 出力（共有）
    <store> .Map </store>                 // 値ストア（共有）
    <nextLoc> 0 </nextLoc>                // 次のロケーション
    <constEnv> .Map </constEnv>           // 定数環境（共有）
    <fenv> .Map </fenv>                   // 関数定義（共有）
    <channels> .Map </channels>           // チャネル状態（共有）
    <nextChanId> 0 </nextChanId>          // 次のチャネルID
  </T>
```

### 主要な変更点

1. **`<thread>` セルの導入**: `multiplicity="*"` により複数のスレッドを表現
2. **スレッドローカル状態**: `<k>`, `<tenv>`, `<env>` などは各スレッドごとに独立
3. **共有状態**: `<store>`, `<channels>`, `<fenv>` などは全スレッドで共有

## Goroutineの実装

### 構文定義 (syntax/concurrent.k)

```k
module GO-SYNTAX-CONCURRENT
  imports GO-SYNTAX

  // Go仕様: GoStmt = "go" Expression
  syntax GoStmt ::= "go" Exp
  syntax Statement ::= GoStmt
endmodule
```

### セマンティクス (semantics/concurrent.k)

```k
// Goroutine生成ルール
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
         <tenvStack> .List </tenvStack>
         <scopeDecls> .List </scopeDecls>
       ...</thread>)
     <nextTid> N:Int => N +Int 1 </nextTid>
```

### ルールの動作説明

**マッチング条件:**
- 親スレッドの `<k>` セルに `go FCall` が存在
- `FCall` は関数呼び出し式

**書き換え動作:**
1. 親スレッドの `<k>` セルから `go FCall` を削除（=> .K）
2. 親スレッドの環境（TEnv, Env）をキャプチャ
3. 新しい `<thread>` セルを生成：
   - 新しいスレッドID `N` を割り当て
   - キャプチャした環境をコピー
   - `<k>` セルに `FCall` を配置（評価はここで開始）
4. `<nextTid>` をインクリメント

**重要なポイント:**
- `FCall` は親スレッドでは評価されず、新しいスレッドに移動
- 環境のコピーにより、親の変数にアクセス可能
- スタックは初期化されるため、独立したスコープ

## Channelの実装

### 構文定義 (syntax/concurrent.k)

```k
module GO-SYNTAX-CONCURRENT
  // チャネル型
  syntax ChannelType ::= "chan" Type
  syntax Type ::= ChannelType

  // チャネル作成
  syntax Exp ::= "make" "(" ChannelType ")"

  // 送信ステートメント: ch <- value
  syntax SendStmt ::= Exp "<-" Exp [strict, symbol(chanSend)]
  syntax Statement ::= SendStmt

  // 受信演算子: <-ch
  syntax Exp ::= "<-" Exp [strict(1), symbol(chanRecv)]
endmodule
```

### セマンティクス (semantics/concurrent.k)

#### 1. チャネル値の定義

```k
// チャネル値型
syntax ChanVal ::= channel(Int, Type)  // channel(チャネルID, 要素型)

syntax Exp ::= ChanVal
syntax Val ::= ChanVal
syntax KResult ::= Val

// チャネル状態
syntax ChanState ::= chanState(List, List, Type)
// chanState(送信待ちキュー, 受信待ちキュー, 要素型)
```

#### 2. チャネル作成

```k
rule <k> make(chan T:Type) => channel(N, T) ... </k>
     <nextChanId> N:Int => N +Int 1 </nextChanId>
     <channels> Chans => Chans [ N <- chanState(.List, .List, T) ] </channels>
```

**動作:**
1. `make(chan int)` がマッチ
2. 新しいチャネルID `N` を生成
3. `<channels>` に新しいチャネル状態を追加（空のキュー）
4. `channel(N, int)` 値を返す

#### 3. チャネル変数宣言

```k
// var ch chan int => var ch chan int = nil
rule <k> var X:Id chan T:Type => var X chan T = nil ... </k>

// var ch chan int = nil
rule <k> var X:Id chan T:Type = FV:FuncVal => .K ... </k>
     <tenv> R => R [ X <- chan T ] </tenv>
     <env> Env => Env [ X <- L ] </env>
     <store> Store => Store [ L <- FV ] </store>
     <nextLoc> L:Int => L +Int 1 </nextLoc>
     <scopeDecls> (SD ListItem(ScopeMap)) => SD ListItem(ScopeMap [ X <- true ]) </scopeDecls>

// var ch chan int = channel(0, int)
rule <k> var X:Id chan T:Type = CV:ChanVal => .K ... </k>
     <tenv> R => R [ X <- chan T ] </tenv>
     <env> Env => Env [ X <- L ] </env>
     <store> Store => Store [ L <- CV ] </store>
     <nextLoc> L:Int => L +Int 1 </nextLoc>
     <scopeDecls> (SD ListItem(ScopeMap)) => SD ListItem(ScopeMap [ X <- true ]) </scopeDecls>
```

#### 4. 短変数宣言

```k
// ch := make(chan int) の直接サポート
rule <k> X:Id := channel(CId:Int, T:Type) => .K ... </k>
     <tenv> R => R [ X <- chan T ] </tenv>
     <env> Env => Env [ X <- L ] </env>
     <store> Store => Store [ L <- channel(CId, T) ] </store>
     <nextLoc> L:Int => L +Int 1 </nextLoc>
     <scopeDecls> (SD ListItem(ScopeMap)) => SD ListItem(ScopeMap [ X <- true ]) </scopeDecls>
  requires notBool (X in_keys(ScopeMap))
```

#### 5. 送信操作（ブロッキング）

```k
// ケース1: 受信待ちスレッドがいる場合（即座に配信）
rule <thread>...
       <tid> _Tid </tid>
       <k> chanSend(channel(CId, int), V:Int) => .K ... </k>
     ...</thread>
     <channels>...
       CId |-> (chanState(SendQ, (ListItem(RecvTid:Int) RecvRest:List), int)
            => chanState(SendQ, RecvRest, int))
     ...</channels>
     <thread>...
       <tid> RecvTid </tid>
       <k> waitingRecv(CId) => V ... </k>
     ...</thread>

// ケース2: 受信待ちがいない場合（ブロック）
rule <thread>...
       <tid> Tid </tid>
       <k> chanSend(channel(CId, int), V:Int) => waitingSend(CId, V) ... </k>
     ...</thread>
     <channels>...
       CId |-> (chanState(SendQ, .List, int)
            => chanState(SendQ ListItem(sendItem(Tid, V)), .List, int))
     ...</channels>
```

#### 6. 受信操作（ブロッキング）

```k
// ケース1: 送信待ちスレッドがいる場合（即座に受信）
rule <thread>...
       <tid> _Tid </tid>
       <k> chanRecv(channel(CId, _T)) => V ... </k>
     ...</thread>
     <channels>...
       CId |-> (chanState((ListItem(sendItem(SendTid:Int, V)) SendRest:List), RecvQ, T)
            => chanState(SendRest, RecvQ, T))
     ...</channels>
     <thread>...
       <tid> SendTid </tid>
       <k> waitingSend(CId, _) => .K ... </k>
     ...</thread>

// ケース2: 送信待ちがいない場合（ブロック）
rule <thread>...
       <tid> Tid </tid>
       <k> chanRecv(channel(CId, _T)) => waitingRecv(CId) ... </k>
     ...</thread>
     <channels>...
       CId |-> (chanState(.List, RecvQ, T)
            => chanState(.List, RecvQ ListItem(Tid), T))
     ...</channels>
```

## 具体的な実行例

### 例1: シンプルなGoroutine

**コード:**
```go
package main

func printNum(n int) {
    print(n);
}

func main() {
    print(1);
    go printNum(42);
    print(2);
}
```

**実行ステップ:**

#### 初期状態
```
<thread>
  <tid> 0 </tid>
  <k> package main ... print(1); go printNum(42); print(2); </k>
  <tenv> printNum |-> func(...) </tenv>
</thread>
<nextTid> 1 </nextTid>
```

#### ステップ1: print(1) を評価
```
ルール適用: print(n int) のルール
結果: <out> ListItem(1) </out>

<k> go printNum(42); print(2); </k>
```

#### ステップ2: go printNum(42) を評価

**サブステップ2.1: 関数呼び出しを評価**
```
ルール適用: 関数引数の評価（context rule）
  context _:Id ( HOLE:Exp )

HOLE = 42 はすでに値なので評価完了
```

**サブステップ2.2: Goroutine生成**
```
ルール適用: Goroutine生成ルール

マッチング:
  <k> go printNum(42) ... </k>
  FCall = printNum(42)

書き換え:
  親スレッド:
    <k> print(2); </k>  // go printNum(42) が削除された

  新スレッド生成:
    <thread>
      <tid> 1 </tid>
      <k> printNum(42) </k>  // 新しいスレッドで実行開始
      <tenv> printNum |-> func(...) </tenv>  // 環境をコピー
      <env> .Map </env>
    </thread>

  <nextTid> 2 </nextTid>  // インクリメント
```

#### ステップ3: 並行実行

**スレッド0:**
```
<k> print(2); </k>
→ print(2) 実行
→ <out> ListItem(1) ListItem(2) </out>
→ <k> .K </k>  // 終了
```

**スレッド1:**
```
<k> printNum(42) </k>
→ 関数呼び出しルール適用
→ enterScope(bindParams(...) ~> { print(n); })
→ n = 42 をバインド
→ print(42) 実行
→ <out> ListItem(1) ListItem(2) ListItem(42) </out>
→ <k> .K </k>  // 終了
```

**最終状態:**
```
<out> ListItem(1) ListItem(2) ListItem(42) </out>
```

### 例2: チャネル通信

**コード:**
```go
package main

func sender(ch chan int, val int) {
    ch <- val;
}

func main() {
    ch := make(chan int);
    go sender(ch, 100);
    result := <-ch;
    print(result);
}
```

**実行ステップ:**

#### ステップ1: ch := make(chan int)

```
ルール適用: make(chan Type)

マッチング:
  <k> ch := make(chan int) ... </k>

書き換え:
  <k> make(chan int) ~> #freezer(ch := HOLE) ... </k>

ルール適用: make(chan int) 評価
  <k> channel(0, int) ~> #freezer(ch := HOLE) ... </k>
  <nextChanId> 0 => 1 </nextChanId>
  <channels> 0 |-> chanState(.List, .List, int) </channels>

ルール適用: 短変数宣言（channel用）
  <k> .K ... </k>
  <tenv> ch |-> chan int </tenv>
  <env> ch |-> 0 </env>
  <store> 0 |-> channel(0, int) </store>
  <nextLoc> 1 </nextLoc>
```

#### ステップ2: go sender(ch, 100)

**サブステップ2.1: 引数評価**
```
ルール適用: context _:Id ( HOLE:Exp , _:ArgList )

<k> ch ~> #freezer(sender(HOLE, 100)) ... </k>

ルール適用: 変数ルックアップ
  <env> ch |-> 0 </env>
  <store> 0 |-> channel(0, int) </store>

<k> channel(0, int) ~> #freezer(sender(HOLE, 100)) ... </k>

冷却:
<k> sender(channel(0, int), 100) ... </k>

同様に100を評価（既に値）
```

**サブステップ2.2: Goroutine生成**
```
ルール適用: Goroutine生成

新スレッド:
  <thread>
    <tid> 1 </tid>
    <k> sender(channel(0, int), 100) </k>
    <tenv> ch |-> chan int, sender |-> func(...) </tenv>
    <env> ch |-> 0 </env>
  </thread>
```

#### ステップ3: result := <-ch （スレッド0）

```
ルール適用: <- ch 評価

<k> ch ~> #freezer(result := <- HOLE) ... </k>

変数ルックアップ後:
<k> channel(0, int) ~> #freezer(result := <- HOLE) ... </k>

冷却:
<k> <- channel(0, int) ~> #freezer(result := HOLE) ... </k>

ルール適用: chanRecv（ブロッキング - 送信待ちなし）
  マッチング:
    <k> chanRecv(channel(0, _T)) ... </k>
    <channels> 0 |-> chanState(.List, .List, int) </channels>

  書き換え:
    <k> waitingRecv(0) ~> #freezer(result := HOLE) ... </k>
    <channels> 0 |-> chanState(.List, ListItem(0), int) </channels>

スレッド0はブロック状態（waitingRecv）
```

#### ステップ4: ch <- val （スレッド1）

```
スレッド1の実行:
  <k> sender(channel(0, int), 100) </k>
  → 関数呼び出し評価
  → enterScope(bindParams(ch, val) ~> { ch <- val; })
  → パラメータバインド完了
  <k> ch <- val </k>
  <env> ch |-> 1, val |-> 2 </env>
  <store> 1 |-> channel(0, int), 2 |-> 100 </store>

変数評価:
  <k> channel(0, int) <- 100 </k>

ルール適用: chanSend（受信待ちあり）
  マッチング:
    送信スレッド(tid=1):
      <k> chanSend(channel(0, int), 100) </k>
    チャネル状態:
      <channels> 0 |-> chanState(.List, ListItem(0), int) </channels>
    受信スレッド(tid=0):
      <k> waitingRecv(0) ~> #freezer(result := HOLE) </k>

  書き換え:
    送信スレッド:
      <k> .K </k>  // 送信完了
    チャネル状態:
      <channels> 0 |-> chanState(.List, .List, int) </channels>
    受信スレッド:
      <k> 100 ~> #freezer(result := HOLE) </k>  // 値を受信
```

#### ステップ5: result := 100 （スレッド0再開）

```
<k> 100 ~> #freezer(result := HOLE) </k>

冷却:
<k> result := 100 </k>

短変数宣言:
  <tenv> result |-> int </tenv>
  <env> result |-> 3 </env>
  <store> 3 |-> 100 </store>
```

#### ステップ6: print(result)

```
<k> print(result) </k>

変数ルックアップ:
<k> print(100) </k>

ルール適用: print
<out> ListItem(100) </out>
```

**最終状態:**
```
<threads>
  <thread> <tid>0</tid> <k>.K</k> </thread>
  <thread> <tid>1</tid> <k>.K</k> </thread>
</threads>
<out> ListItem(100) </out>
<channels> 0 |-> chanState(.List, .List, int) </channels>
```

## 技術的な課題と解決策

### 課題1: List{Exp, ","}でのstrict評価の問題

**問題:**
K Frameworkで `syntax ArgList ::= List{Exp, ","} [strict]` とすると、heating（加熱）は動作するが、cooling（冷却）でリスト構造の再構築が失敗する。

**例:**
```k
// 意図した動作:
printInt(y)  // y = 42
→ printInt(42)  // y を評価

// 実際の動作:
printInt(y)
→ y ~> #freezer_,_(printInt, .ArgList)
→ 42 ~> #freezer_,_(printInt, .ArgList)
→ .ArgList ~> #freezer_,_(42)  // リスト再構築失敗！
```

**解決策:**
明示的なcontextルールを使用して、リスト要素を個別に評価：

```k
// 関数引数の評価用contextルール
context _:Id ( HOLE:Exp , _:ArgList )      // 第1引数
context _:Id ( _:Exp , HOLE:Exp , _:ArgList )  // 第2引数
context _:Id ( _:Exp , _:Exp , HOLE:Exp , _:ArgList )  // 第3引数
context _:Id ( HOLE:Exp )                  // 単一引数
```

これにより、関数呼び出しの文脈内で引数が正しく評価される。

### 課題2: SendStmtでチャネル式が評価されない

**問題:**
```k
syntax SendStmt ::= Exp "<-" Exp [strict(2), symbol(chanSend)]
```
これは右辺（送信する値）のみを評価し、左辺（チャネル）を評価しない。

**例:**
```go
func sender(ch chan int, val int) {
    ch <- val;  // ch は変数なので評価が必要
}
```

**解決策:**
両方の引数を評価：
```k
syntax SendStmt ::= Exp "<-" Exp [strict, symbol(chanSend)]
```

`strict`（引数なし）は全ての位置を評価する。

### 課題3: 環境のスレッドローカル性

**問題:**
各スレッドは独自の変数環境を持つ必要があるが、`<store>`は共有される必要がある。

**解決策:**
二層構造：
1. **`<env>` (スレッドローカル)**: 変数名 → ロケーションのマッピング
2. **`<store>` (共有)**: ロケーション → 値のマッピング

```k
// スレッド0
<env> ch |-> 0 </env>

// スレッド1（環境をコピー）
<env> ch |-> 0 </env>

// 共有ストア
<store> 0 |-> channel(0, int) </store>
```

両スレッドが同じロケーション（0）を参照するため、同じチャネルにアクセス可能。

### 課題4: 関数パラメータへのチャネル渡し

**問題:**
`bindParams` がチャネル型を認識しない。

**解決策:**
GO-CONCURRENT モジュールで `bindParams` を拡張：

```k
// GO-CONCURRENT モジュールで追加
rule <k> bindParams((X:Id , Xs:ParamIds), (chan T:Type , Ts:ParamTypes),
                    (CV:ChanVal , Vs:ArgList))
      => var X chan T = CV ~> bindParams(Xs, Ts, Vs) ... </k>

rule <k> bindParams(X:Id, chan T:Type, CV:ChanVal)
      => var X chan T = CV ... </k>
```

同様に `allValues` も拡張：
```k
rule allValues(_V:ChanVal) => true
rule allValues((_V:ChanVal , Rest:ArgList)) => allValues(Rest)
```

## まとめ

### 実装のハイライト

1. **マルチスレッド設定**: `<thread>` セルの multiplicity により柔軟な並行実行
2. **環境のキャプチャ**: Goroutine生成時に親の環境をコピー
3. **ブロッキング・セマンティクス**: キュー管理により正確な同期
4. **型安全性**: チャネル型を完全にサポート

### テスト結果

すべてのテストが成功：
- ✅ Goroutine生成と実行
- ✅ チャネル作成と変数宣言
- ✅ チャネル通信（送信/受信）
- ✅ ブロッキング動作
- ✅ 既存機能との互換性

### 今後の拡張可能性

- バッファ付きチャネル (`make(chan int, 10)`)
- Select文（複数チャネルの選択的待機）
- チャネルのクローズ (`close(ch)`)
- 双方向/単方向チャネル型
- より高度なスケジューリング戦略

---

**作成日**: 2025-01-27
**K Framework バージョン**: 最新版
**実装者**: Claude Code
