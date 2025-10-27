# Boolean Semantics Refresh

## 概要
- `src/go/syntax/core.k` にて比較演算を Go 仕様に揃え、`<=`, `>=`, `!=` を追加。`&&`/`||` の優先順位は維持しつつ `seqstrict` を外して短絡評価へ対応しやすくした。
- `src/go/semantics/core.k` では整数・ブール比較の評価規則を拡充し、`context HOLE && _` / `context HOLE || _` を導入。左オペランドの値で右オペランドの評価要否を切り替えることで短絡を実現している。
- 新サンプル `src/go/codes/code-bool-ops` を追加し、比較演算の結果と短絡による副作用抑止を確認できるようにした。

## 具体例

### 比較演算の追加
```go
if 5 <= 2 { print(3); } else { print(4); }; // => 4
if true != false { print(1); };             // => 1
if 7 >= 7 { print(5); };                    // => 5
```

- これらはすべて AST レベルで `Exp "<=" Exp` 等として構文解析され、`core.k` の整数比較ルール (`<=Int` など) によって評価される。
- ブール比較は `B1 ==Bool B2`／`notBool (B1 ==Bool B2)` を経由するため、`true == false` が `false`、`true != false` が `true` と正しく判定される。

### AND/OR の短絡
`core.k` では
```k
context HOLE && _E:Exp
rule <k> true && E:Exp => E ... </k>
rule <k> false && _E:Exp => false ... </k>
```
のように evaluation context を宣言し、まず左オペランドのみを `HOLE` で評価させる仕組みを追加している。`||` も同様に `context HOLE || _` で定義しており、右側は必要な場合のみ評価される。`code-bool-ops` では以下のクロージャを利用して副作用の回数を観測している:

```go
var hits int = 0;
tick := func() bool {
  hits = hits + 1;
  return true;
};

if false && tick() { print(10); };
print(hits); // => 0
```

- `false && tick()` は左辺が `false` になった時点で `context HOLE && _` のルール `false && _ => false` が適用され、`tick()` が評価されないため `hits` は 0 のまま。
- `true && tick()` の場合は `true && E => E` ルールで右辺評価に進み、副作用が 1 回発生する。
- `true || tick()` は左辺の `true` で `true || _ => true` にマッチするので `tick()` を呼ばず、`false || tick()` は右辺評価に進む。

### 実行結果
コンテナ内で以下を実行すると、新挙動をまとめて確認できる:

```bash
docker compose exec k bash -c "cd go && kompile main.k"
docker compose exec k bash -c "cd go && krun codes/code-bool-ops --definition main-kompiled/"
```

`code-bool-ops` の標準出力は `0, 1, 4, 5, 8, 0, 11, 1, 12, 1, 13, 2`。途中で `hits` が `0 → 1 → 1 → 2` と増えていく様子で短絡の有無が分かる。
