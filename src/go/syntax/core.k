/*
Semicolons¶
The formal syntax uses semicolons ";" as terminators in a number of productions. Go programs may omit most of these semicolons using the following two rules:

When the input is broken into tokens, a semicolon is automatically inserted into the token stream immediately after a line's final token if that token is
an identifier
an integer, floating-point, imaginary, rune, or string literal
one of the keywords break, continue, fallthrough, or return
one of the operators and punctuation ++, --, ), ], or }
To allow complex statements to occupy a single line, a semicolon may be omitted before a closing ")" or "}".
To reflect idiomatic use, code examples in this document elide semicolons using these rules.
*/

requires "domains.md"

module GO-SYNTAX
  imports UNSIGNED-INT-SYNTAX
  imports BOOL-SYNTAX
  imports ID-SYNTAX

  syntax TopDecl
  syntax TopDecls ::= List{TopDecl, ";"}
  syntax Program ::= "package" "main" TopDecls "func" "main" "(" ")" Block TopDecls

  // Go specification: Block = "{" StatementList "}" .
  syntax Block   ::= "{" StatementList ";" "}"

  // Go specification: StatementList = { Statement ";" } .
  syntax StatementList ::= List{Statement, ";"}

  syntax Type ::= "int" | "bool"

  // Go specification: ExpressionList = Expression { "," Expression } .
  syntax ExpressionList ::= List{Exp, ","}

  // Go specification: IdentifierList = identifier { "," identifier } .
  syntax IdentifierList ::= List{Id, ","}

  // Go specification: SimpleStmt = EmptyStmt | ExpressionStmt | SendStmt | IncDecStmt | Assignment | ShortVarDecl .
  // Note: EmptyStmt and ExpressionStmt are not explicitly represented to avoid parsing ambiguities
  syntax SimpleStmt ::= Assignment | ShortVarDecl | IncDecStmt

  // Go specification: Assignment = ExpressionList assign_op ExpressionList .
  // Simplified: only single assignment with "=" operator for now
  syntax Assignment ::= Id "=" Exp [strict(2)]

  // Go specification: ShortVarDecl = IdentifierList ":=" ExpressionList .
  // Simplified: only single variable declaration for now
  syntax ShortVarDecl ::= Id ":=" Exp [strict(2)]

  // Go specification: IncDecStmt = Expression ( "++" | "--" ) .
  // Simplified: only Id for now (will expand to Expression later)
  syntax IncDecStmt ::= Id "++" | Id "--"

  syntax Statement ::= SimpleStmt | Print | Block | IfStmt | ForStmt | BreakStmt | ContinueStmt
                     | "var" Id Type "=" Exp  [strict(3)]

  syntax Print ::= "print" "(" Exp ")" [strict]

  syntax Exp ::= Int | Bool | Id | "(" Exp ")" [bracket]
               > "!" Exp [seqstrict]
               | "-" Exp [seqstrict]
               > left:
                 Exp "*" Exp [left, seqstrict]
               | Exp "/" Exp [left, seqstrict]
               | Exp "%" Exp [left, seqstrict]
               > left:
                 Exp "+" Exp [left, seqstrict]
               | Exp "-" Exp [left, seqstrict]
               > non-assoc:
                 Exp "<"  Exp [seqstrict]
               | Exp ">"  Exp [seqstrict]
               | Exp "==" Exp [seqstrict]
               > left:
                 Exp "&&" Exp [left, seqstrict]
               | Exp "||" Exp [left, seqstrict]

  // Go specification: IfStmt = "if" [ SimpleStmt ";" ] Expression Block [ "else" ( IfStmt | Block ) ] .
  syntax IfStmt ::= "if" Exp Block                                   [strict(1)]
                  | "if" Exp Block "else" Block                       [strict(1)]
                  | "if" Exp Block "else" IfStmt                      [strict(1)]
                  | "if" SimpleStmt ";" Exp Block
                  | "if" SimpleStmt ";" Exp Block "else" Block
                  | "if" SimpleStmt ";" Exp Block "else" IfStmt

  // Go specification: ForStmt = "for" [ Condition | ForClause | RangeClause ] Block .
  // Go specification: Condition = Expression .
  syntax ForStmt ::= "for" Block                      // infinite loop
                   | "for" Condition Block            // condition-only loop
                   | "for" ForClause Block            // for clause with init;condition;post

  syntax Condition ::= Exp

  syntax BreakStmt ::= "break"
  syntax ContinueStmt ::= "continue"

  // Go specification: ForClause = [ InitStmt ] ";" [ Condition ] ";" [ PostStmt ] .
  // Go specification: InitStmt = SimpleStmt .
  // Go specification: PostStmt = SimpleStmt .
  syntax ForClause ::= SimpleStmt ";" Exp ";" SimpleStmt  // init; condition; post
                     | SimpleStmt ";" ";" SimpleStmt      // init; ; post
                     | SimpleStmt ";" Exp ";"             // init; condition;
                     | ";" Exp ";" SimpleStmt             // ; condition; post
                     | ";" ";" SimpleStmt                 // ; ; post
                     | ";" Exp ";"                        // ; condition;
                     | SimpleStmt ";" ";"                 // init; ;
                     | ";" ";"                            // ; ;
endmodule
