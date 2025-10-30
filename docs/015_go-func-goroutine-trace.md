# ゴルーチン実行トレース

このメモでは、`go func()` を複数回呼び出した上で通常の関数呼び出しも行うプログラムを題材に、現在の K 定義がどのように書き換え規則を適用していくかを追跡します。スケジューリングが非決定的になる理由と、`tid` がどのようにチャネル同期に利用されるかも確認します。

## サンプルプログラム

```go
package main

func printNum(n int) {
	print(n);
}

func main() {
	go func() { printNum(1); }();
	go func() { printNum(2); }();
	go func() { printNum(3); }();
	printNum(0);
}
```

## 関連ルール

- `go` 文で新しいスレッドを生成する規則: `src/go/semantics/concurrent.k:40`
- 関数リテラルをクロージャ値に変換: `src/go/semantics/func.k:32`
- クロージャ呼び出しで環境を復元し本体を実行: `src/go/semantics/func.k:77`
- スコープの push / pop: `src/go/semantics/core.k:24`
- `<threads>` セルが Bag として宣言されている箇所: `src/go/semantics/core.k:16`
- チャネル待ち行列で `tid` を参照する規則: `src/go/semantics/concurrent.k:109`, `src/go/semantics/concurrent.k:126`

## 初期構成

`src/go/semantics/core.k:16` の設定では、最初は `<threads>` セルに 1 つの `<thread>` だけが存在し、その `<k>` にはプログラム全体が順番に積まれています。`<nextTid>` は `1` なので、最初に生成されるゴルーチンは `tid = 1` を受け取ります。

```
<threads>
  <thread>
    <tid> 0 </tid>
    <k> ... program ... </k>
    ...
  </thread>
</threads>
<nextTid> 1 </nextTid>
```

## 書き換えの流れ

### 1. 最初の `go func()` に遭遇

メインスレッドが `go func() { printNum(1); }()` に到達すると、`src/go/semantics/concurrent.k:40` の規則がマッチします。

```
rule <thread> ... <k> go FCall:Exp => .K ... </k> ... </thread>
     (.Bag => <thread> ... <tid> N </tid> <k> FCall </k> ... </thread>)
     <nextTid> N:Int => N +Int 1 </nextTid>
```

- `go` キーワードは消費され、`go FCall` が `.K` になります。
- `.Bag => <thread> ... </thread>` により新しい `<thread>` セルが生成され、その `<k>` には元の呼び出し式 `func() { printNum(1); }()` が入ります。
- `<nextTid>` は `1` から `2` へ更新され、生成されたスレッドは `tid = 1` を持ちます。

同じ規則が 2 回繰り返し適用され、`tid = 2`, `tid = 3` を持つゴルーチンが追加されます。3 回目が終わった時点で `<threads>` には `tid = 0,1,2,3` の 4 スレッドが存在し、`<nextTid> = 4` になっています。

### 2. スケジューリングは非決定的

`<thread multiplicity="*" type="Set">` と宣言されているため（`src/go/semantics/core.k:16`）、`<threads>` セルは Bag（順序無し多重集合）として扱われ、任意の `<thread>` が選択されます。このため、K の実行では以下のような多様なインターリーブが発生し得ます。

- メインスレッドを最後まで実行してからゴルーチンを動かす。
- 4 つのスレッドすべてをラウンドロビンで進める。
- ゴルーチン同士で途中まで交互に実行して戻る。

どのパターンも正しい実行として扱われます。

### 3. ゴルーチン内部でクロージャを評価

スケジューラが `tid = 1` のスレッドを選ぶと、その `<k>` には `func() { printNum(1); }()` が入っています。`src/go/syntax/func.k:39` で関数呼び出しに `strict(1)` 属性が付いているため、まず関数式部分が評価されます。ここで `src/go/semantics/func.k:32` が適用されます。

```
rule <k> func Sig:FunctionSignature B:Block
      => funcVal(..., B, TEnv, Env, .Map) ... </k>
```

これにより関数リテラルは `funcVal(...)` へ書き換わり、現在の `<tenv>` と `<env>`（親スレッドからコピーされた環境）がクロージャとして捕捉されます。

### 4. クロージャ呼び出し

項は `funcVal(...)(.ArgList)` の形になり、`src/go/semantics/func.k:77` がマッチします。

```
rule <k> funcVal(PIs, PTs, RT, B, ClosTEnv, ClosEnv, _)(AL:ArgList)
      => enterScope(restoreClosureEnv(ClosTEnv, ClosEnv, .Map)
                    ~> bindParams(PIs, PTs, AL)
                    ~> B)
         ~> returnJoin(RT) ... </k>
```

重要な処理:

- `restoreClosureEnv` が捕捉した環境を現在の `<tenv>/<env>` に復元します（`src/go/semantics/func.k:84`）。
- 引数が空なので `bindParams` は即座に `.K` になります。
- `enterScope` はスコープスタックを push し、ブロック終了時に `exitScope` で pop します（`src/go/semantics/core.k:24`）。
- `B` には `{ printNum(1); }` が入っており、この後は通常の関数呼び出し規則（`src/go/semantics/func.k:29` など）で処理されます。

### 5. クロージャの終了

本体の実行を終えると `<k>` に `returnJoin(void)` が残り、`src/go/semantics/func.k:108` によって `.K` へ書き換えられます。

```
rule <k> returnJoin(void) => .K ... </k>
```

ゴルーチンの `<k>` が `.K` になるとそれ以上規則にマッチしなくなり、セルは非アクティブですが `<threads>` 内に残留します。

### 6. メインスレッドの `printNum(0)`

メインスレッドでの `printNum(0);` は標準の名前付き関数呼び出しとして扱われます。`src/go/semantics/func.k:29` が適用され、関数定義を `<fenv>` から取得し、スコープをセットアップして本体を実行します。ここでは特別な並行規則は関与しません。

スケジューリング次第で、`printNum(0)` がゴルーチンより前・途中・後に実行されるすべてのケースが許容されます。

## `tid` が必要な理由

スレッドの順序は Bag 構造により自由ですが、`tid` はチャネルで待機しているスレッドを特定するために必須です。

- 送信側がブロックする際、`src/go/semantics/concurrent.k:126` が `waitingSend(CId, V)` を `<k>` に残しつつ、チャネル状態に `sendItem(Tid, V)` を登録します。ここで `Tid` は `<thread>` の `<tid>` を参照しています。
- 受信側が到着すると、`src/go/semantics/concurrent.k:109` が待機キューから `sendItem(SendTid, V)` を取り出し、対応する `<tid> SendTid </tid>` を持つスレッドの `<k>` を `waitingSend` から実際の値 `V` に書き換えることで解除します。

このように `tid` がなければ、「どの待機スレッドを再開させるべきか」を識別できず、正しいチャネル同期が成り立ちません。

## まとめ

- `go` 文で新しい `<thread>` セルが生成され、呼び出し式は新スレッドの `<k>` に移されます。
- `<threads>` は Bag なので、実行順序は非決定的で公平性も保証されません。
- クロージャの作成と呼び出しは、メインスレッドでもゴルーチンでも同じ規則で処理されます。
- チャネル同期では `tid` が必須であり、待機中のゴルーチンの解除は `tid` に基づいて行われます。
