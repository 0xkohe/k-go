module BINARY-INCREMENT-TM
  imports DOMAINS-SYNTAX
  imports LIST
  imports K-EQUAL
  imports BOOL

  
  // シンタックス定義
  syntax Symbol ::= "0" | "1" | "B"  // B はブランク記号
  syntax State ::= "q0" | "q1" | "q2" | "qf"  // 状態
  syntax Direction ::= "L" | "R" | "S"  // Left, Right, Stay
  
  //syntax Bool ::= isSymbolEqual(Symbol, Symbol) [function]
  //rule isSymbolEqual(S1:Symbol, S2:Symbol) => S1 ==K S2

  // テープの表現（リストとして）
  syntax Tape ::= List{Symbol, ""}
  
  // チューリングマシンのプログラム
  syntax Pgm ::= Tape
  
  configuration <T>
    <k> $PGM:Pgm </k>
    <tape> 
      <left> ListItem(B) .List </left>      // ヘッドの左側のテープ
      <current> B </current>     // 現在ヘッドが指している記号
      <right> .List ListItem(B)</right>     // ヘッドの右側のテープ
    </tape>
    <state> q0 </state>
    <result> .K </result>
  </T>


////  // 初期化規則
//　実行されてない
  rule <k> S1:Symbol Ss:Tape => Ss </k>
       <left> .List => .List </left>
       <current> B => S1 </current>
       <right> .List => .List </right>
       <state> q0 </state>
  
  rule <k> S1:Symbol Ss:Tape => Ss </k>
       <current> _Cu => S1 </current>
       <left> Ls => Ls ListItem(S1) </left>
       <state> q0 => q0 </state>
       //<right> Rs => Rs ListItem(S1) </right>
       requires S1 =/=K B
       //requires (S1 ==K 0) orBool (S1 ==K 1)
  
  rule <k> .Tape </k> 
  <state> q0 => q1 </state>
  
  //rule <k> .Tape => .K </k> [owise]
  
  // 状態遷移規則
  
  // q1: 加算処理
  // 0を見つけたら1に変更して完了
  rule <current> 0 => 1 </current>
       <left> Ls ListItem(_L) => Ls </left>
       <right> Rs => ListItem(1) Rs </right>
       <state> q1 => q2 </state>
    requires Ls =/=K .List
//  
  // 1を見つけたら0に変更してキャリー継続
  rule <current> 1 => L2</current>
       <left> Ls ListItem(L2) ListItem(_L1) => Ls ListItem(L2)</left>
       <right> Rs => ListItem(0) Rs </right>
       <state> q1 </state>
//  
  // 左端に到達（ブランク）したら1を追加
  rule <current> B </current>
       <right> Rs => ListItem(1) Rs </right>
       <state> q1 => q2 </state>

  rule <current> Cu => L2 </current>
       <left> Ls ListItem(L2) ListItem(L1) => Ls  ListItem(L2)</left>
       <right> Rs => ListItem(L1) Rs </right>
       <state> q2 </state>
       requires Cu ==K 0 orBool Cu ==K 1

  rule <current> B </current>
       <state> q2 => qf </state>
       
       
//  
//  rule <current> 0 => B </current>
//       <left> .List </left>
//       <right> Rs => 0 Rs </right>
//       <state> q1 => q2 </state>
//  
//  rule <current> 1 => B </current>
//       <left> .List </left>
//       <right> Rs => 1 Rs </right>
//       <state> q1 => q2 </state>
//  
//  // q2: 左端に戻る
//  rule <current> 0 => 0 </current>
//       <left> Ls L => Ls </left>
//       <right> Rs => L Rs </right>
//       <state> q2 </state>
//    requires Ls =/=K .List
//  
//  rule <current> 1 => 1 </current>
//       <left> Ls L => Ls </left>
//       <right> Rs => L Rs </right>
//       <state> q2 </state>
//    requires Ls =/=K .List
//  
//  // 左端のブランクに到達したら完了
//  rule <current> B => S </current>
//       <left> .List </left>
//       <right> S Rs => Rs </right>
//       <state> q2 => qf </state>
//  
//  rule <current> S </current>
//       <left> .List </left>
//       <state> q2 => qf </state>
//    requires S ==K 0 orBool S ==K 1
//  
//  // 最終状態で結果を保存
//  rule <state> qf </state>
//       <left> Ls </left>
//       <current> C </current>
//       <right> Rs </right>
//       <result> .K => buildTape(Ls, C, Rs) </result>
//  
//  // ヘルパー関数：テープを構築
//  syntax Tape ::= buildTape(List, Symbol, List) [function]
//  rule buildTape(.List, C, Rs) => C reverseList(Rs)
//  rule buildTape(L Ls, C, Rs) => buildTape(Ls, L, C Rs)
//  
//  syntax Tape ::= reverseList(List) [function]
//  rule reverseList(.List) => .Tape
//  rule reverseList(L Ls) => reverseList(Ls) L
//
//endmodule
//
//// テストモジュール
//module TURING-MACHINE-ADD-ONE-TEST
//  imports TURING-MACHINE-ADD-ONE
//  
//  syntax Pgm ::= "test1" | "test2" | "test3" | "test4"
//  
//  // テストケース
//  rule test1 => 1 0 1 0      // 1010 + 1 = 1011
//  rule test2 => 1 0 1 1      // 1011 + 1 = 1100
//  rule test3 => 1 1 1        // 111 + 1 = 1000
//  rule test4 => 0            // 0 + 1 = 1
  


// ==== BINARY-INCREMENT-TM ====
//module BINARY-INCREMENT-TM
//  syntax Bit   ::= "0" | "1"
//  syntax Sym   ::= Bit | "_"            // ブランクも 1 文字として扱う
//  syntax Tape  ::= List{Sym,""}         // ヘッド右側・左側を同じ型で表現
//  syntax State ::= "qSeekEnd" | "qCarry" | "halt"
//
//  // コンフィギュレーション
//  configuration
//    <machine>
//      //<state>  $S:State </state>        // 初期状態
//      <state>  qSeekEnd         </state>  // 初期状態
//      <left>   $LS:Tape         </left>   // ヘッド左側（左端がリスト末尾）
//      <head>   $H:Sym           </head>   // 現在読んでいるシンボル
//      <right>  $RS:Tape         </right>  // ヘッド右側（先頭が隣接セル）
//    </machine>
//
//   //-----------------------------
//   // テープ移動の補助マクロ
//   //-----------------------------
//   syntax KItem ::= moveRight | moveLeft
// 
//   rule <machine> <left> LS </left> <head> H </head> (<right> Sym RS </right>) </machine>
//        moveRight
//     => <machine> <left> LS H </left> <head> Sym </head> <right> RS </right> </machine>
// 
//   rule <machine> (<left> LS Sym </left>) <head> H </head> <right> RS </right>
//        moveLeft
//     => <machine> <left> LS </left> <head> Sym </head> <right> H RS </right> </machine>
// 
//   //-----------------------------
//   // 1. 右端（ブランク）を探すフェーズ
//   //-----------------------------
//   rule <machine>
//          <state> qSeekEnd </state>
//          <head> "_" </head>
//        </machine>
//     => moveLeft
//     ~> <machine> <state> qCarry </state> </machine>
// 
//   rule <machine>
//          <state> qSeekEnd </state>
//          <head> B:Bit </head>
//        </machine>
//     => moveRight
//     ~> <machine> <state> qSeekEnd </state> </machine>
// 
//   //-----------------------------
//   // 2. キャリー処理フェーズ
//   //-----------------------------
//   // 2-a 0 に遭遇したら 1 に書き換えて終了
//   rule <machine>
//          <state> qCarry </state>
//          <head> "0" </head>
//        </machine>
//     => <machine> <head> "1" </head> <state> halt </state> </machine>
// 
//   // 2-b 1 に遭遇したら 0 に書き換えてさらに左へ
//   rule <machine>
//          <state> qCarry </state>
//          <head> "1" </head>
//        </machine>
//     => <machine> <head> "0" </head> </machine>
//     ~> moveLeft
//     ~> <machine> <state> qCarry </state> </machine>
// 
//   // 2-c 左端ブランクに達したら 1 を書き足して終了
//   rule <machine>
//          <state> qCarry </state>
//          <head> "_" </head>
//        </machine>
//     => <machine> <head> "1" </head> <state> halt </state> </machine>
endmodule