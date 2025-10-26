# クロージャの環境と Loc/Store の挙動

`Loc` ベースのストア共有がクロージャでどう働くかを示すミニプログラムです。`x` は 1 つのロケーションを通じて保持され、クロージャ呼び出しでも直接その値を読み書きします。

## サンプルプログラム

```go
package main

func main() {
  var x int = 1
  f := func() int {
    x = x + 1
    return x
  }

  print(f()) // => 2
  x = 0
  print(f()) // => 1
}
```

## 適用される主なルール

| フェーズ | ルール | 説明 |
| --- | --- | --- |
| 変数宣言 | `var X int = I` (`src/go/semantics/core.k:58-64`) | `<env>` に `x ↦ L0`、`<store>` に `L0 ↦ 1` を格納し、`<nextLoc>` を進めます。 |
| 関数リテラル評価 | `func … => funcVal(…, TEnv, Env, …)` (`src/go/semantics/func.k:68-78`) | クロージャ値に現在の `<env>`/`<tenv>` をキャプチャします。ここで `x` の `Loc` も保持されます。 |
| 短縮宣言 | `X := funcVal(…)` (`src/go/semantics/core.k:112-118`) | 新しい場所 `L1` を確保し、`f` が `funcVal` を指すように `<env>` と `<store>` を更新します。 |
| クロージャ呼び出し | `funcVal(…)(Args)` (`src/go/semantics/func.k:83-101`) | `restoreClosureEnv` でキャプチャ時の `<env>` を再インストールし、共有 `<store>` を通じて `x` を操作します。 |
| 代入/参照 | `X = Exp`・`X => V` (`src/go/semantics/core.k:119-134`, `196-204`) | すべて `x ↦ L0` を用いて `<store>[L0]` を読み書きするため、クロージャの内部・外部から同じ変数を共有できます。 |

## 挙動の要点

- クロージャは `<env>`（Id→Loc）をそのまま保持し、呼び出し時に `restoreClosureEnv` で再設定するため、スタックの復元だけではなく「環境そのものの差し替え」が行われます。
- `<store>` は単一で共有されるため、`Loc` が一致すればどこからでも同じ値にアクセスできます。上の例だと `x` は常に位置 `L0` に存在し、`f()` からの `x = x + 1` も `main` 側の `x = 0` も同じセルを書き換えます。
- これにより Go と同じく、クロージャはキャプチャした変数を参照として扱えます。
