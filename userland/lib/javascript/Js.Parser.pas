{
  FreePascalOS
  Copyright (C) 2026 Brandon Scott

  This program is free software: you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation, either version 3 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this program.  If not, see <https://www.gnu.org/licenses/>.
}

{
  The parser: tokens to the syntax tree (Js.Ast), by recursive descent
  with precedence climbing for the binary operators.

  Cover grammars are parsed as expressions and turned into what they
  turn out to be: a parenthesised expression followed by => into arrow
  parameters, an array or object literal followed by = into a
  destructuring pattern. The references recorded while the arrow's
  parameters were still an expression move into the arrow's scope.

  Declarations go into their scopes as they are parsed (var into the
  function's scope, let, const and class into the block's), and every
  identifier into its scope's references, for Js.Scopes to resolve.

  Nesting is bounded (MaximumDepth) so that a hostile input cannot
  exhaust the Pascal stack; syntax errors raise EJsSyntaxError with
  the line and column.
}
unit Js.Parser;

{$mode objfpc}{$H+}

interface

uses
  SysUtils,
  Js.Lexer,
  Js.Ast,
  Js.LazyBodies;

const
  MaximumDepth = 400;

type
  { Where a token starts: what the hot parsing functions keep of their
    first token. }
  TJsSourceMark = record
    Start: Integer;
    Line: Integer;
    Column: Integer;
  end;

type
  TJsParseGoal = (pgScript, pgFunctionBody, pgEval, pgModule);

  TJsParser = class
  private
    FLexer: TJsLexer;
    FArena: TJsAstArena;
    FToken: TJsToken;
    FPreviousLine: Integer;
    FPreviousFinish: Integer;
    FScope: TJsScope;
    FFunction: TJsFunctionInfo;
    FStrict: Boolean;
    FInGenerator: Boolean;
    FInAsync: Boolean;
    FInClassField: Boolean;
    { Parsing arrow parameters as a pattern: names are declared later. }
    FNoDeclare: Boolean;
    { A function expression comes right after '(': most likely invoked
      at once (an IIFE), so compiled eagerly rather than parsed twice. }
    FFunctionInParentheses: Boolean;
    { Where the first expression right inside parentheses starts: an
      arrow starting there, (() => ...), is most likely invoked at once
      too. }
    FParenthesizedStart: Integer;
    { What ParseFunction is told about the function it parses next: it
      is right inside parentheses. }
    FNextFunctionInParentheses: Boolean;
    { Where the function starts whose body is wanted though it compiles
      lazily (the function a lazy compilation parses again); 0: none. }
    FKeepBodyStart: Integer;
    FDepth: Integer;
    { The labels around the statement being parsed; those of the
      current function from FLabelBase on. }
    FLabels: array of UnicodeString;
    FLabelCount: Integer;
    FLabelBase: Integer;
    FLoopDepth: Integer;
    FSwitchDepth: Integer;
    FPrivateScopes: array of TJsScope;
    { Parsing a module (import.meta allowed throughout). }
    ModuleGoal: Boolean;
    procedure Fail(const Text: string);
    { The early errors of a regular expression literal: its flags and
      its pattern. }
    procedure CheckRegExpLiteral(const Pattern, Flags: UnicodeString);
    procedure FailAt(const Token: TJsToken; const Text: string);
    { The messages with a name are made here: a routine building one
      would need an exception frame for its strings on every call. }
    procedure FailRedeclared(const Token: TJsToken; const Name: UnicodeString);
    procedure FailUndefinedLabel(const Name: UnicodeString);
    procedure Unexpected;
    procedure Next;
    function PeekToken: TJsToken;
    function Accept(Kind: TJsTokenKind): Boolean;
    procedure Expect(Kind: TJsTokenKind);
    function IsIdentifierToken: Boolean;
    function IsContextual(Word: TJsWord): Boolean; inline;
    { The current identifier's name. }
    function TokenText: UnicodeString;
    { The current string token's value. }
    function StringText: UnicodeString;
    { Any identifier name, reserved words included (after a dot, as a
      key): put in Text, and the token is taken. }
    procedure TakeIdentifierName(var Text: UnicodeString);
    function IdentifierName: UnicodeString;
    procedure ConsumeSemicolon;
    procedure Enter;
    procedure Leave;
    function NewNode(Kind: TJsNodeKind): TJsNode;
    function NewNodeAt(Kind: TJsNodeKind; const Token: TJsToken): TJsNode;
    function NewNodeAtMark(Kind: TJsNodeKind; const Mark: TJsSourceMark): TJsNode; inline;
    function CurrentMark: TJsSourceMark; inline;
    function PushScope(Kind: TJsScopeKind): TJsScope;
    procedure PopScope;
    function NewIdentifier(const Name: UnicodeString; const Token: TJsToken): TJsNode;
    { An identifier of an interned name (TJsToken.Name). }
    function NewIdentifierAt(Name: Integer; const Token: TJsToken): TJsNode;
    function DeclareName(const Name: UnicodeString; Kind: TJsDeclarationKind; const Token: TJsToken): TJsVariable;
    procedure DeclarePatternNames(Pattern: TJsNode; Kind: TJsDeclarationKind);
    { The names of a let or const pattern count as initialised from here
      (references before this point check the dead zone). }
    procedure MarkInitialized(Pattern: TJsNode);
    procedure NameFunctionExpression(Info: TJsFunctionInfo);
    { A binding identifier: its interned name, the token taken. }
    function BindingIdentifier: Integer;
    function BindingIdentifierName: UnicodeString;

    { Statements }
    function ParseStatementListItem: TJsNode;
    function ParseStatement: TJsNode;
    function ParseStatementAtDepth: TJsNode;
    function ParseBlock(NewScope: Boolean = True): TJsNode;
    function ParseVariableStatement(Kind: TJsDeclarationKind; InFor: Boolean): TJsNode;
    function ParseIf: TJsNode;
    function ParseFor: TJsNode;
    function ParseWhile: TJsNode;
    function ParseDoWhile: TJsNode;
    function ParseReturn: TJsNode;
    function ParseBreakContinue(Kind: TJsNodeKind): TJsNode;
    function ParseThrow: TJsNode;
    function ParseTry: TJsNode;
    function ParseSwitch: TJsNode;
    function ParseWith: TJsNode;
    function ParseLabeledOrExpression: TJsNode;
    function ParseLabeledStatement: TJsNode;
    function ParseFunctionDeclaration(IsAsync: Boolean; DefaultExport: Boolean = False): TJsNode;
    function ParseClassDeclaration: TJsNode;
    function IsLetDeclaration: Boolean;

    { Modules }
    function ParseModuleItem: TJsNode;
    function ParseImportDeclaration: TJsNode;
    function ParseExportDeclaration: TJsNode;
    function ParseModuleSpecifier(out Json: Boolean): UnicodeString;
    function ParseImportAttributes: Boolean;
    function ParseModuleExportName(out IsString: Boolean): UnicodeString;
    procedure AddExportEntry(const Entry: TJsExportEntry);
    procedure AddLocalExport(const ExportName, LocalName: UnicodeString; const Token: TJsToken);
    procedure ExportBoundNames(Node: TJsNode; const Token: TJsToken);
    procedure FinishModuleExports;

    { Functions and classes }
    function ParseFunction(Kind: TJsFunctionKind; IsAsync, IsGenerator: Boolean;
      const Name: UnicodeString; const StartToken: TJsToken): TJsFunctionInfo;
    function ParseFunctionExpression(const StartToken: TJsToken): TJsNode;
    function ParseAsyncFunctionExpression(const StartToken: TJsToken): TJsNode;
    { Whether a function just parsed is released (compiled lazily, and
      not the function a lazy compilation wants). }
    function DiscardsBody(Info: TJsFunctionInfo): Boolean;
    procedure ParseParameters(Info: TJsFunctionInfo);
    procedure ParseFunctionBody(Info: TJsFunctionInfo);
    function ParsePrivateIn(NoIn: Boolean): TJsNode;
    function AsyncArrowParameterFollows: Boolean;
    function ParseAsyncArrowWithIdentifier(const Start: TJsSourceMark): TJsNode;
    function ParseArrowFunction(Parameters: TJsNode; IsAsync: Boolean; const StartToken: TJsSourceMark;
      ReferenceMark, ChildMark, NodeMark: Integer; OuterScope: TJsScope): TJsNode;
    procedure ParseArrowBody(Info: TJsFunctionInfo);
    function ParseClass(IsExpression: Boolean; const StartToken: TJsToken): TJsNode;
    function ParseClassMember(ClassNode: TJsNode; var InstanceInit, StaticInit: TJsFunctionInfo): TJsNode;
    function ParsePropertyKey(out Computed: Boolean; out KeyName: UnicodeString): TJsNode;
    function NewFieldInitializer(ClassNode: TJsNode; IsStatic: Boolean): TJsFunctionInfo;

    { Patterns }
    function ParseBindingTarget(Kind: TJsDeclarationKind): TJsNode;
    function ParseArrayBindingPattern(Kind: TJsDeclarationKind): TJsNode;
    function ParseObjectBindingPattern(Kind: TJsDeclarationKind): TJsNode;
    function ParseBindingElement(Kind: TJsDeclarationKind): TJsNode;
    function ToPattern(Node: TJsNode; Binding: Boolean): TJsNode;

    { Expressions }
    function ParseExpression(NoIn: Boolean = False): TJsNode;
    function ParseAssignment(NoIn: Boolean = False): TJsNode;
    function ParseAssignmentAtDepth(NoIn: Boolean): TJsNode;
    function ParseAssignmentOperator(Left: TJsNode; const Start: TJsSourceMark; NoIn: Boolean): TJsNode;
    function ParseConditional(NoIn: Boolean): TJsNode;
    function ParseBinary(MinimumPrecedence: Integer; NoIn: Boolean): TJsNode;
    function ParseUnary: TJsNode;
    function ParseUnaryAtDepth: TJsNode;
    function ParseUpdate: TJsNode;
    function ParseLeftHandSide: TJsNode;
    function ParseCallTail(Node: TJsNode; AllowCall: Boolean): TJsNode;
    { The name after . or ?. (a private name: its reference too). }
    procedure ParseMemberName(Member: TJsNode);
    function ParseArguments(Call: TJsNode): TJsNode;
    function ParsePrimary: TJsNode;
    function ParseIdentifierReference: TJsNode;
    function ParseArrayLiteral: TJsNode;
    function ParseObjectLiteral: TJsNode;
    function ParseTemplate(Tagged: Boolean): TJsNode;
    function ParseParenthesized: TJsNode;
    function ParseNew: TJsNode;
    function ParseYield(NoIn: Boolean): TJsNode;
    function IsSimpleAssignmentTarget(Node: TJsNode): Boolean;
  public
    constructor Create(const Source: UnicodeString; Arena: TJsAstArena);
    destructor Destroy; override;
    { The whole program; Strict as if it began with "use strict". }
    function ParseProgram(Strict: Boolean; Goal: TJsParseGoal = pgScript): TJsNode;
    { A direct eval's code, inside the scopes around the call (Outer:
      the innermost). }
    function ParseEval(Strict: Boolean; Outer: TJsScope): TJsNode;
    { A lazily compiled function, parsed again from its parameter list
      (an arrow: from its start) at the position given, inside the
      scopes around it (Outer: the innermost). }
    function ParseLazyFunction(Start, Line, Column: Integer; Outer: TJsScope; Kind: TJsFunctionKind;
      IsAsync, IsGenerator, Strict, HasSelfName: Boolean; const Name: UnicodeString): TJsFunctionInfo;
    { The source text between two positions (Function.prototype.toString). }
    function SourceText(Start, Finish: Integer): UnicodeString;
  end;

implementation

uses
  Js.RegExpCompiler;

const
  { Placeholder for "()" and "(...rest)" before =>. }
  ArrowParametersFlag = $8000;

constructor TJsParser.Create(const Source: UnicodeString; Arena: TJsAstArena);
begin
  inherited Create;
  FLexer := TJsLexer.Create(Source);
  FArena := Arena;
end;

destructor TJsParser.Destroy;
begin
  FLexer.Free;
  inherited Destroy;
end;

function TJsParser.SourceText(Start, Finish: Integer): UnicodeString;
begin
  Result := FLexer.SourceText(Start, Finish);
end;

procedure TJsParser.CheckRegExpLiteral(const Pattern, Flags: UnicodeString);
var
  Index: Integer;
  Seen: UnicodeString;
begin
  Seen := '';
  for Index := 1 to Length(Flags) do
  begin
    if (Pos(Flags[Index], 'dgimsuvy') = 0) or (Pos(Flags[Index], Seen) > 0) then
      Fail('Invalid regular expression flags');
    Seen := Seen + Flags[Index];
  end;
  if (Pos('u', Flags) > 0) and (Pos('v', Flags) > 0) then
    Fail('Invalid regular expression flags');
  { The v flag's set notation is checked when the literal runs. }
  if Pos('v', Flags) > 0 then
    Exit;
  try
    ValidateRegExp(Pattern, Pos('i', Flags) > 0, Pos('u', Flags) > 0);
  except
    on Error: ERegExpSyntax do
      Fail(Error.Message);
  end;
end;

procedure TJsParser.Fail(const Text: string);
begin
  raise EJsSyntaxError.CreateAt(Text, FToken.Line, FToken.Column);
end;

procedure TJsParser.FailAt(const Token: TJsToken; const Text: string);
begin
  raise EJsSyntaxError.CreateAt(Text, Token.Line, Token.Column);
end;

procedure TJsParser.FailRedeclared(const Token: TJsToken; const Name: UnicodeString);
begin
  FailAt(Token, 'Identifier ''' + string(Name) + ''' has already been declared');
end;

procedure TJsParser.FailUndefinedLabel(const Name: UnicodeString);
begin
  Fail('Undefined label ''' + string(Name) + '''');
end;

procedure TJsParser.Unexpected;
begin
  if FToken.Kind = tkEnd then
    Fail('Unexpected end of input')
  else if FToken.Kind in [tkIdentifier, tkPrivateName] then
    Fail('Unexpected identifier ''' + string(TokenText) + '''')
  else if FToken.Kind in [tkString, tkTemplate] then
    Fail('Unexpected string')
  else
    Fail('Unexpected token ' + TokenKindName(FToken.Kind));
end;

procedure TJsParser.Next;
begin
  FPreviousLine := FToken.Line;
  FPreviousFinish := FToken.Finish;
  FLexer.Next(FToken);
  if (FToken.Kind = tkPrivateName) and (FFunction <> nil) then
    FFunction.UsesPrivateNames := True;
end;

function TJsParser.PeekToken: TJsToken;
var
  Position, Line, LineStart: Integer;
begin
  FLexer.SavePosition(Position, Line, LineStart);
  FLexer.Next(Result);
  FLexer.RestorePosition(Position, Line, LineStart);
end;

function TJsParser.Accept(Kind: TJsTokenKind): Boolean;
begin
  Result := FToken.Kind = Kind;
  if Result then
    Next;
end;

procedure TJsParser.Expect(Kind: TJsTokenKind);
begin
  if FToken.Kind <> Kind then
    Unexpected;
  Next;
end;

function TJsParser.IsIdentifierToken: Boolean;
begin
  if FToken.Kind <> tkIdentifier then
    Exit(False);
  { A reserved word spelled with escapes is still reserved (12.7.2). }
  if FToken.Escaped and FLexer.IsReservedName(FToken.Name) then
    Exit(False);
  case FToken.Word of
    jwImplements, jwInterface, jwPackage, jwPrivate, jwProtected, jwPublic, jwStatic, jwLet:
      Result := not FStrict;
    jwYield:
      Result := not (FInGenerator or FStrict);
    jwAwait:
      Result := not FInAsync;
  else
    Result := True;
  end;
end;

function TJsParser.IsContextual(Word: TJsWord): Boolean;
begin
  Result := (FToken.Kind = tkIdentifier) and (FToken.Word = Word) and not FToken.Escaped;
end;

function TJsParser.TokenText: UnicodeString;
begin
  if FToken.Name >= 0 then
    Result := FLexer.Names[FToken.Name]
  else
    Result := '';
end;

function TJsParser.StringText: UnicodeString;
begin
  Result := '';
  FLexer.DecodeString(FToken, Result);
end;

procedure TJsParser.TakeIdentifierName(var Text: UnicodeString);
begin
  { Reserved words are interned names too. }
  if (FToken.Kind <> tkIdentifier) and not (FToken.Kind in [tkBreak..tkWith]) then
    Unexpected;
  Text := FLexer.Names[FToken.Name];
  Next;
end;

function TJsParser.IdentifierName: UnicodeString;
begin
  Result := '';
  TakeIdentifierName(Result);
end;

procedure TJsParser.ConsumeSemicolon;
begin
  if FToken.Kind = tkSemicolon then
  begin
    Next;
    Exit;
  end;
  if (FToken.Kind = tkRightBrace) or (FToken.Kind = tkEnd) or FToken.NewlineBefore then
    Exit;
  Unexpected;
end;

procedure TJsParser.Enter;
begin
  Inc(FDepth);
  if FDepth > MaximumDepth then
    Fail('Too much nesting');
end;

procedure TJsParser.Leave;
begin
  Dec(FDepth);
end;

function TJsParser.NewNode(Kind: TJsNodeKind): TJsNode;
begin
  Result := FArena.NewNode(Kind, FToken.Line, FToken.Column);
end;

function TJsParser.NewNodeAt(Kind: TJsNodeKind; const Token: TJsToken): TJsNode;
begin
  Result := FArena.NewNode(Kind, Token.Line, Token.Column);
end;

function TJsParser.NewNodeAtMark(Kind: TJsNodeKind; const Mark: TJsSourceMark): TJsNode;
begin
  Result := FArena.NewNode(Kind, Mark.Line, Mark.Column);
end;

function TJsParser.CurrentMark: TJsSourceMark;
begin
  Result.Start := FToken.Start;
  Result.Line := FToken.Line;
  Result.Column := FToken.Column;
end;

function TJsParser.PushScope(Kind: TJsScopeKind): TJsScope;
begin
  Result := TJsScope.Create;
  FArena.Own(Result);
  Result.Kind := Kind;
  Result.Parent := FScope;
  if FScope <> nil then
    FScope.AddChild(Result);
  if Kind in [skScript, skFunction, skEval, skModule] then
    Result.FunctionScope := Result
  else
    Result.FunctionScope := FScope.FunctionScope;
  Result.Func := FFunction;
  FScope := Result;
end;

procedure TJsParser.PopScope;
begin
  FScope := FScope.Parent;
end;

function TJsParser.NewIdentifier(const Name: UnicodeString; const Token: TJsToken): TJsNode;
begin
  Result := NewNodeAt(nkIdentifier, Token);
  Result.Text := Name;
  Result.Number := Token.Start;
  FScope.AddReference(Result);
end;

function TJsParser.NewIdentifierAt(Name: Integer; const Token: TJsToken): TJsNode;
begin
  Result := NewNodeAt(nkIdentifier, Token);
  Result.Text := FLexer.Names[Name];
  Result.Number := Token.Start;
  FScope.AddReference(Result);
end;

function TJsParser.DeclareName(const Name: UnicodeString; Kind: TJsDeclarationKind; const Token: TJsToken): TJsVariable;
var
  Target: TJsScope;
  Existing: TJsVariable;
  Walk: TJsScope;
begin
  Result := nil;
  if FNoDeclare then
    Exit;
  if FStrict and ((Name = 'eval') or (Name = 'arguments')) and (Kind <> dkImplicit) then
    FailAt(Token, 'Unexpected eval or arguments in strict mode');
  if Kind = dkVar then
  begin
    { Hoisted to the function; a lexical binding of the name on the
      way up is a redeclaration. }
    Walk := FScope;
    while Walk <> Walk.FunctionScope do
    begin
      Existing := Walk.Find(Name);
      if (Existing <> nil) and Existing.IsLexical then
        FailRedeclared(Token, Name);
      Walk := Walk.Parent;
    end;
    Target := FScope.FunctionScope;
  end
  else
    Target := FScope;
  Existing := Target.Find(Name);
  if Existing <> nil then
  begin
    if (Kind in [dkLet, dkConst, dkClass]) or (Existing.IsLexical and (Kind <> dkImplicit)) then
    begin
      if not ((Existing.Kind = dkParameter) and (Kind = dkVar)) then
        FailRedeclared(Token, Name);
    end;
    if (Kind = dkFunction) and (Existing.Kind in [dkVar, dkParameter, dkFunction]) then
      Existing.Kind := dkFunction;
    Exit(Existing);
  end;
  Result := Target.Declare(Name, Kind, Token.Start);
end;

procedure TJsParser.DeclarePatternNames(Pattern: TJsNode; Kind: TJsDeclarationKind);
var
  Index: Integer;
  Token: TJsToken;
begin
  if Pattern = nil then
    Exit;
  case Pattern.Kind of
    nkIdentifier:
      begin
        Token := Default(TJsToken);
        Token.Line := Pattern.Line;
        Token.Column := Pattern.Column;
        Token.Start := Trunc(Pattern.Number);
        DeclareName(Pattern.Text, Kind, Token);
      end;
    nkArrayPattern:
      for Index := 0 to Pattern.Count - 1 do
        DeclarePatternNames(Pattern.List[Index], Kind);
    nkObjectPattern:
      for Index := 0 to Pattern.Count - 1 do
        if Pattern.List[Index].Kind = nkRest then
          DeclarePatternNames(Pattern.List[Index].A, Kind)
        else
          DeclarePatternNames(Pattern.List[Index].B, Kind);
    nkAssignPattern, nkRest:
      DeclarePatternNames(Pattern.A, Kind);
  end;
end;

procedure TJsParser.MarkInitialized(Pattern: TJsNode);
var
  Index: Integer;
  Variable: TJsVariable;
begin
  if Pattern = nil then
    Exit;
  case Pattern.Kind of
    nkIdentifier:
      begin
        Variable := FScope.Find(Pattern.Text);
        if (Variable <> nil) and Variable.IsLexical then
          Variable.DeclarationStart := FPreviousFinish;
      end;
    nkArrayPattern:
      for Index := 0 to Pattern.Count - 1 do
        MarkInitialized(Pattern.List[Index]);
    nkObjectPattern:
      for Index := 0 to Pattern.Count - 1 do
        if Pattern.List[Index].Kind = nkRest then
          MarkInitialized(Pattern.List[Index].A)
        else
          MarkInitialized(Pattern.List[Index].B);
    nkAssignPattern, nkRest:
      MarkInitialized(Pattern.A);
  end;
end;

{ A named function expression sees its own name (unless something in
  it declares the name). }
procedure TJsParser.NameFunctionExpression(Info: TJsFunctionInfo);
begin
  if (Info.Name <> '') and (Info.Scope.Find(Info.Name) = nil) then
    Info.SelfVariable := Info.Scope.Declare(Info.Name, dkImplicit, 0);
end;

function TJsParser.BindingIdentifier: Integer;
begin
  if not IsIdentifierToken then
  begin
    if (FToken.Kind = tkIdentifier) and (FToken.Word = jwYield) and not FInGenerator and not FStrict then
    else if (FToken.Kind = tkIdentifier) and (FToken.Word = jwAwait) and not FInAsync then
    else
      Unexpected;
  end;
  Result := FToken.Name;
  Next;
end;

function TJsParser.BindingIdentifierName: UnicodeString;
begin
  Result := FLexer.Names[BindingIdentifier];
end;

{ Programs }

function TJsParser.ParseProgram(Strict: Boolean; Goal: TJsParseGoal): TJsNode;
var
  Info: TJsFunctionInfo;
  Statement: TJsNode;
  Directives: Boolean;
begin
  Info := TJsFunctionInfo.Create;
  FArena.Own(Info);
  Info.Kind := fkScript;
  if Goal = pgModule then
  begin
    { Modules are strict, and await may appear at their top level. }
    Info.Kind := fkModule;
    Strict := True;
    FInAsync := True;
    ModuleGoal := True;
    Info.ModuleSyntax := TJsModuleSyntax.Create;
    FArena.Own(Info.ModuleSyntax);
  end;
  Info.IsStrict := Strict;
  FFunction := Info;
  FStrict := Strict;
  Next;
  Result := NewNode(nkProgram);
  if Goal = pgEval then
    Result.Scope := PushScope(skEval)
  else if Goal = pgModule then
    Result.Scope := PushScope(skModule)
  else
    Result.Scope := PushScope(skScript);
  Info.Scope := Result.Scope;
  Result.Func := Info;
  Directives := True;
  while FToken.Kind <> tkEnd do
  begin
    if Directives then
    begin
      if FLexer.IsUseStrict(FToken) then
      begin
        if PeekToken.Kind in [tkSemicolon, tkRightBrace, tkEnd] then
        begin
          FStrict := True;
          Info.IsStrict := True;
        end;
      end
      else if FToken.Kind <> tkString then
        Directives := False;
    end;
    if Goal = pgModule then
      Statement := ParseModuleItem
    else
      Statement := ParseStatementListItem;
    if Directives and ((Statement.Kind <> nkExpressionStatement) or (Statement.A.Kind <> nkString)) then
      Directives := False;
    Result.Add(Statement);
  end;
  if Goal = pgModule then
    FinishModuleExports;
  PopScope;
end;

function TJsParser.ParseLazyFunction(Start, Line, Column: Integer; Outer: TJsScope; Kind: TJsFunctionKind;
  IsAsync, IsGenerator, Strict, HasSelfName: Boolean; const Name: UnicodeString): TJsFunctionInfo;
var
  StartToken: TJsToken;
  Node: TJsNode;
begin
  FScope := Outer;
  FFunction := Outer.Func;
  FStrict := Strict;
  FLexer.RestorePosition(Start, Line, Start - Column + 1);
  Next;
  StartToken := FToken;
  FKeepBodyStart := StartToken.Start;
  if Kind = fkArrow then
  begin
    Node := ParseAssignment;
    if (Node.Kind <> nkFunction) or (Node.Func = nil) then
      Fail('Internal error: lazy function');
    Exit(Node.Func);
  end;
  Result := ParseFunction(Kind, IsAsync, IsGenerator, Name, StartToken);
  if HasSelfName then
    NameFunctionExpression(Result);
end;

function TJsParser.ParseEval(Strict: Boolean; Outer: TJsScope): TJsNode;
begin
  FScope := Outer;
  Result := ParseProgram(Strict, pgEval);
end;

{ Modules }

function TJsParser.ParseModuleItem: TJsNode;
begin
  if (FToken.Kind = tkImport) and not (PeekToken.Kind in [tkLeftParen, tkDot]) then
    Exit(ParseImportDeclaration);
  if FToken.Kind = tkExport then
    Exit(ParseExportDeclaration);
  Result := ParseStatementListItem;
end;

{ The attributes after a module specifier (with, type json): True for
  JSON. }
function TJsParser.ParseImportAttributes: Boolean;
var
  Key, Value: UnicodeString;
  Seen: array of UnicodeString;
  Index: Integer;
begin
  Result := False;
  if not ((FToken.Kind = tkWith) or (IsContextual(jwAssert) and not FToken.NewlineBefore)) then
    Exit;
  Next;
  Expect(tkLeftBrace);
  Seen := nil;
  while FToken.Kind <> tkRightBrace do
  begin
    if FToken.Kind = tkString then
    begin
      Key := StringText;
      Next;
    end
    else
      Key := IdentifierName;
    for Index := 0 to High(Seen) do
      if Seen[Index] = Key then
        Fail('Import attribute has duplicate key ''' + string(Key) + '''');
    SetLength(Seen, Length(Seen) + 1);
    Seen[High(Seen)] := Key;
    Expect(tkColon);
    if FToken.Kind <> tkString then
      Unexpected;
    Value := StringText;
    Next;
    if Key <> 'type' then
      Fail('Unsupported import attribute ''' + string(Key) + '''');
    if Value = 'json' then
      Result := True
    else
      Fail('Unsupported module type ''' + string(Value) + '''');
    if not Accept(tkComma) then
      Break;
  end;
  Expect(tkRightBrace);
end;

function TJsParser.ParseModuleSpecifier(out Json: Boolean): UnicodeString;
begin
  if FToken.Kind <> tkString then
    Unexpected;
  Result := StringText;
  Next;
  Json := ParseImportAttributes;
end;

{ An identifier name or a string (export a as "b c"). }
function TJsParser.ParseModuleExportName(out IsString: Boolean): UnicodeString;
var
  Index: Integer;
begin
  IsString := FToken.Kind = tkString;
  if not IsString then
    Exit(IdentifierName);
  Result := StringText;
  { Lone surrogates are not allowed in export names. }
  Index := 1;
  while Index <= Length(Result) do
  begin
    if (Ord(Result[Index]) >= $D800) and (Ord(Result[Index]) <= $DBFF) then
    begin
      if (Index = Length(Result)) or (Ord(Result[Index + 1]) < $DC00) or (Ord(Result[Index + 1]) > $DFFF) then
        Fail('Invalid module export name: contains unpaired surrogate');
      Inc(Index);
    end
    else if (Ord(Result[Index]) >= $DC00) and (Ord(Result[Index]) <= $DFFF) then
      Fail('Invalid module export name: contains unpaired surrogate');
    Inc(Index);
  end;
  Next;
end;

function IsReservedImportName(const Name: UnicodeString): Boolean;
begin
  Result := (Name = 'eval') or (Name = 'arguments') or (Name = 'await') or (Name = 'yield') or (Name = 'let') or
    (Name = 'static') or (Name = 'implements') or (Name = 'interface') or (Name = 'package') or
    (Name = 'private') or (Name = 'protected') or (Name = 'public');
end;

function TJsParser.ParseImportDeclaration: TJsNode;
type
  TPendingImport = record
    ImportName: UnicodeString;
    LocalName: UnicodeString;
    IsNamespace: Boolean;
    Token: TJsToken;
  end;
var
  Syntax: TJsModuleSyntax;
  Pending: array of TPendingImport;
  Specifier, ImportName: UnicodeString;
  Json, IsString, NeedsMore: Boolean;
  Request, Index: Integer;
  NameToken: TJsToken;
  Variable: TJsVariable;

  procedure AddPending(const AImportName, ALocalName: UnicodeString; ANamespace: Boolean; const AToken: TJsToken);
  begin
    SetLength(Pending, Length(Pending) + 1);
    Pending[High(Pending)].ImportName := AImportName;
    Pending[High(Pending)].LocalName := ALocalName;
    Pending[High(Pending)].IsNamespace := ANamespace;
    Pending[High(Pending)].Token := AToken;
  end;

begin
  Syntax := FFunction.ModuleSyntax;
  if (FFunction.Kind <> fkModule) or (FScope <> FScope.FunctionScope) then
    Fail('Unexpected token ''import''');
  Result := NewNode(nkEmpty);
  Next;
  Pending := nil;
  if FToken.Kind = tkString then
  begin
    Specifier := ParseModuleSpecifier(Json);
    Syntax.AddRequest(Specifier, Json);
    ConsumeSemicolon;
    Exit;
  end;
  NeedsMore := True;
  if FToken.Kind = tkIdentifier then
  begin
    NameToken := FToken;
    AddPending('default', BindingIdentifierName, False, NameToken);
    NeedsMore := Accept(tkComma);
  end;
  if NeedsMore then
  begin
    if FToken.Kind = tkStar then
    begin
      Next;
      if not IsContextual(jwAs) then
        Unexpected;
      Next;
      NameToken := FToken;
      AddPending('*', BindingIdentifierName, True, NameToken);
    end
    else if FToken.Kind = tkLeftBrace then
    begin
      Next;
      while FToken.Kind <> tkRightBrace do
      begin
        NameToken := FToken;
        ImportName := ParseModuleExportName(IsString);
        if IsContextual(jwAs) then
        begin
          Next;
          NameToken := FToken;
          AddPending(ImportName, BindingIdentifierName, False, NameToken);
        end
        else
        begin
          if IsString or (NameToken.Kind <> tkIdentifier) or IsReservedImportName(ImportName) then
            FailAt(NameToken, 'Unexpected reserved word');
          AddPending(ImportName, ImportName, False, NameToken);
        end;
        if not Accept(tkComma) then
          Break;
      end;
      Expect(tkRightBrace);
    end
    else
      Unexpected;
  end;
  if not IsContextual(jwFrom) then
    Unexpected;
  Next;
  Specifier := ParseModuleSpecifier(Json);
  ConsumeSemicolon;
  Request := Syntax.AddRequest(Specifier, Json);
  for Index := 0 to High(Pending) do
  begin
    Variable := DeclareName(Pending[Index].LocalName, dkImport, Pending[Index].Token);
    Syntax.AddImport(Request, Pending[Index].ImportName, Pending[Index].LocalName, Pending[Index].IsNamespace,
      Variable);
  end;
end;

procedure TJsParser.AddExportEntry(const Entry: TJsExportEntry);
var
  Syntax: TJsModuleSyntax;
begin
  Syntax := FFunction.ModuleSyntax;
  if Syntax.HasExport(Entry.ExportName) then
    raise EJsSyntaxError.CreateAt('Duplicate export of ''' + string(Entry.ExportName) + '''', Entry.Line,
      Entry.Column);
  Syntax.AddExport(Entry);
end;

procedure TJsParser.AddLocalExport(const ExportName, LocalName: UnicodeString; const Token: TJsToken);
var
  Entry: TJsExportEntry;
begin
  Entry := Default(TJsExportEntry);
  Entry.ExportName := ExportName;
  Entry.LocalName := LocalName;
  Entry.Request := -1;
  Entry.Line := Token.Line;
  Entry.Column := Token.Column;
  AddExportEntry(Entry);
end;

{ The names a declaration binds, each exported under its own name. }
procedure TJsParser.ExportBoundNames(Node: TJsNode; const Token: TJsToken);

  procedure FromPattern(Pattern: TJsNode);
  var
    Index: Integer;
  begin
    if Pattern = nil then
      Exit;
    case Pattern.Kind of
      nkIdentifier: AddLocalExport(Pattern.Text, Pattern.Text, Token);
      nkArrayPattern:
        for Index := 0 to Pattern.Count - 1 do
          FromPattern(Pattern.List[Index]);
      nkObjectPattern:
        for Index := 0 to Pattern.Count - 1 do
          if Pattern.List[Index].Kind = nkRest then
            FromPattern(Pattern.List[Index].A)
          else
            FromPattern(Pattern.List[Index].B);
      nkAssignPattern, nkRest:
        FromPattern(Pattern.A);
    end;
  end;

var
  Index: Integer;
begin
  case Node.Kind of
    nkVariables:
      for Index := 0 to Node.Count - 1 do
        FromPattern(Node.List[Index].A);
    nkFunctionDeclaration:
      AddLocalExport(Node.Func.Name, Node.Func.Name, Token);
    nkClassDeclaration:
      AddLocalExport(Node.Text, Node.Text, Token);
  else
    FailAt(Token, 'Unexpected token ''export''');
  end;
end;

function TJsParser.ParseExportDeclaration: TJsNode;
type
  TPendingExport = record
    LocalName: UnicodeString;
    ExportName: UnicodeString;
    LocalIsString: Boolean;
    Token: TJsToken;
  end;
var
  Syntax: TJsModuleSyntax;
  StartToken, NameToken, Peeked: TJsToken;
  Pending: array of TPendingExport;
  Entry: TJsExportEntry;
  Specifier: UnicodeString;
  Json, IsString: Boolean;
  Request, Index: Integer;
  Variable: TJsVariable;
  Expression: TJsNode;
begin
  Syntax := FFunction.ModuleSyntax;
  if (FFunction.Kind <> fkModule) or (FScope <> FScope.FunctionScope) then
    Fail('Unexpected token ''export''');
  StartToken := FToken;
  Next;
  Entry := Default(TJsExportEntry);
  Entry.Line := StartToken.Line;
  Entry.Column := StartToken.Column;
  case FToken.Kind of
    tkStar:
      begin
        Next;
        Result := NewNode(nkEmpty);
        if IsContextual(jwAs) then
        begin
          Next;
          Entry.ExportName := ParseModuleExportName(IsString);
          if not IsContextual(jwFrom) then
            Unexpected;
          Next;
          Specifier := ParseModuleSpecifier(Json);
          Entry.Request := Syntax.AddRequest(Specifier, Json);
          Entry.ImportName := '*';
          Entry.IsNamespace := True;
          AddExportEntry(Entry);
        end
        else
        begin
          if not IsContextual(jwFrom) then
            Unexpected;
          Next;
          Specifier := ParseModuleSpecifier(Json);
          Request := Syntax.AddRequest(Specifier, Json);
          SetLength(Syntax.StarExports, Length(Syntax.StarExports) + 1);
          Syntax.StarExports[High(Syntax.StarExports)] := Request;
        end;
        ConsumeSemicolon;
      end;
    tkLeftBrace:
      begin
        Next;
        Pending := nil;
        while FToken.Kind <> tkRightBrace do
        begin
          SetLength(Pending, Length(Pending) + 1);
          Pending[High(Pending)].Token := FToken;
          Pending[High(Pending)].LocalName := ParseModuleExportName(IsString);
          Pending[High(Pending)].LocalIsString := IsString;
          if IsContextual(jwAs) then
          begin
            Next;
            Pending[High(Pending)].ExportName := ParseModuleExportName(IsString);
          end
          else
            Pending[High(Pending)].ExportName := Pending[High(Pending)].LocalName;
          if not Accept(tkComma) then
            Break;
        end;
        Expect(tkRightBrace);
        Result := NewNode(nkEmpty);
        if IsContextual(jwFrom) then
        begin
          Next;
          Specifier := ParseModuleSpecifier(Json);
          Request := Syntax.AddRequest(Specifier, Json);
          for Index := 0 to High(Pending) do
          begin
            Entry.ExportName := Pending[Index].ExportName;
            Entry.Request := Request;
            Entry.ImportName := Pending[Index].LocalName;
            Entry.Line := Pending[Index].Token.Line;
            Entry.Column := Pending[Index].Token.Column;
            AddExportEntry(Entry);
          end;
        end
        else
          for Index := 0 to High(Pending) do
          begin
            if Pending[Index].LocalIsString or (Pending[Index].Token.Kind <> tkIdentifier) then
              FailAt(Pending[Index].Token, 'Unexpected export name');
            AddLocalExport(Pending[Index].ExportName, Pending[Index].LocalName, Pending[Index].Token);
          end;
        ConsumeSemicolon;
      end;
    tkDefault:
      begin
        Next;
        NameToken := FToken;
        if FToken.Kind = tkFunction then
        begin
          Result := ParseFunctionDeclaration(False, True);
          AddLocalExport('default', Result.A.Text, NameToken);
          Exit;
        end;
        if IsContextual(jwAsync) then
        begin
          Peeked := PeekToken;
          if (Peeked.Kind = tkFunction) and not Peeked.NewlineBefore then
          begin
            Next;
            Result := ParseFunctionDeclaration(True, True);
            AddLocalExport('default', Result.A.Text, NameToken);
            Exit;
          end;
        end;
        if (FToken.Kind = tkClass) and (PeekToken.Kind = tkIdentifier) then
        begin
          Result := ParseClassDeclaration;
          AddLocalExport('default', Result.Text, NameToken);
          Exit;
        end;
        Expression := ParseAssignment;
        ConsumeSemicolon;
        Variable := DeclareName('*default*', dkLet, NameToken);
        if Variable <> nil then
          Variable.DeclarationStart := 0;
        Result := NewNodeAt(nkExport, StartToken);
        Result.A := Expression;
        Result.B := NewIdentifier('*default*', NameToken);
        AddLocalExport('default', '*default*', NameToken);
      end;
    tkVar:
      begin
        NameToken := FToken;
        Result := ParseVariableStatement(dkVar, False);
        ExportBoundNames(Result, NameToken);
      end;
    tkConst:
      begin
        NameToken := FToken;
        Result := ParseVariableStatement(dkConst, False);
        ExportBoundNames(Result, NameToken);
      end;
    tkFunction, tkClass:
      begin
        NameToken := FToken;
        Result := ParseStatementListItem;
        ExportBoundNames(Result, NameToken);
      end;
  else
    NameToken := FToken;
    if IsLetDeclaration then
      Result := ParseVariableStatement(dkLet, False)
    else if IsContextual(jwAsync) and (PeekToken.Kind = tkFunction) then
      Result := ParseStatementListItem
    else
    begin
      Unexpected;
      Result := nil;
    end;
    ExportBoundNames(Result, NameToken);
  end;
end;

{ After the whole module: each local export names a declaration; one
  naming an import re-exports what was imported. }
procedure TJsParser.FinishModuleExports;
var
  Syntax: TJsModuleSyntax;
  Index, ImportIndex: Integer;
  Variable: TJsVariable;
  Kept: array of TJsExportEntry;
  Entry: TJsExportEntry;
begin
  Syntax := FFunction.ModuleSyntax;
  Kept := nil;
  for Index := 0 to High(Syntax.LocalExports) do
  begin
    Entry := Syntax.LocalExports[Index];
    Variable := FScope.Find(Entry.LocalName);
    if Variable = nil then
      raise EJsSyntaxError.CreateAt('Export ''' + string(Entry.LocalName) + ''' is not defined in module',
        Entry.Line, Entry.Column);
    if Variable.Kind = dkImport then
    begin
      for ImportIndex := 0 to High(Syntax.Imports) do
        if Syntax.Imports[ImportIndex].LocalName = Entry.LocalName then
        begin
          Entry.Request := Syntax.Imports[ImportIndex].Request;
          Entry.ImportName := Syntax.Imports[ImportIndex].ImportName;
          Entry.IsNamespace := Syntax.Imports[ImportIndex].IsNamespace;
          Break;
        end;
      SetLength(Syntax.IndirectExports, Length(Syntax.IndirectExports) + 1);
      Syntax.IndirectExports[High(Syntax.IndirectExports)] := Entry;
      Continue;
    end;
    Entry.Variable := Variable;
    SetLength(Kept, Length(Kept) + 1);
    Kept[High(Kept)] := Entry;
  end;
  Syntax.LocalExports := Kept;
end;


{ Statements }

function TJsParser.IsLetDeclaration: Boolean;
var
  Peeked: TJsToken;
begin
  Result := False;
  if not IsContextual(jwLet) then
    Exit;
  Peeked := PeekToken;
  if Peeked.Kind in [tkLeftBracket, tkLeftBrace] then
    Exit(True);
  if Peeked.Kind = tkIdentifier then
    Exit(not Peeked.NewlineBefore or FStrict or True);
  if (Peeked.Kind in [tkBreak..tkWith]) and FStrict then
    Exit(True);
end;

function TJsParser.ParseStatementListItem: TJsNode;
var
  Peeked: TJsToken;
begin
  case FToken.Kind of
    tkFunction:
      Exit(ParseFunctionDeclaration(False));
    tkClass:
      Exit(ParseClassDeclaration);
    tkConst:
      begin
        Result := ParseVariableStatement(dkConst, False);
        Exit;
      end;
    tkImport:
      if not (PeekToken.Kind in [tkLeftParen, tkDot]) then
        Fail('Cannot use import statement outside a module');
    tkExport:
      Fail('Unexpected token ''export''');
  end;
  if IsLetDeclaration then
    Exit(ParseVariableStatement(dkLet, False));
  if IsContextual(jwAsync) then
  begin
    Peeked := PeekToken;
    if (Peeked.Kind = tkFunction) and not Peeked.NewlineBefore then
    begin
      Next;
      Exit(ParseFunctionDeclaration(True));
    end;
  end;
  Result := ParseStatement;
end;

{ The depth is counted without an exception frame: after a syntax
  error the parser is not used again. }
function TJsParser.ParseStatement: TJsNode;
begin
  Enter;
  Result := ParseStatementAtDepth;
  Leave;
end;

function TJsParser.ParseStatementAtDepth: TJsNode;
begin
  case FToken.Kind of
    tkLeftBrace: Result := ParseBlock;
    tkSemicolon:
      begin
        Result := NewNode(nkEmpty);
        Next;
      end;
    tkVar: Result := ParseVariableStatement(dkVar, False);
    tkIf: Result := ParseIf;
    tkFor: Result := ParseFor;
    tkWhile: Result := ParseWhile;
    tkDo: Result := ParseDoWhile;
    tkReturn: Result := ParseReturn;
    tkBreak: Result := ParseBreakContinue(nkBreak);
    tkContinue: Result := ParseBreakContinue(nkContinue);
    tkThrow: Result := ParseThrow;
    tkTry: Result := ParseTry;
    tkSwitch: Result := ParseSwitch;
    tkWith: Result := ParseWith;
    tkDebugger:
      begin
        Result := NewNode(nkDebugger);
        Next;
        ConsumeSemicolon;
      end;
    tkFunction:
      begin
        if FStrict then
          Fail('In strict mode code, functions can only be declared at top level or inside a block');
        Result := ParseFunctionDeclaration(False);
      end;
    tkClass, tkConst:
      begin
        Unexpected;
        Result := nil;
      end;
  else
    if IsLetDeclaration and (PeekToken.Kind = tkLeftBracket) then
      Fail('Lexical declaration cannot appear in a single-statement context');
    Result := ParseLabeledOrExpression;
  end;
end;

function TJsParser.ParseBlock(NewScope: Boolean): TJsNode;
begin
  Result := NewNode(nkBlock);
  Expect(tkLeftBrace);
  if NewScope then
    Result.Scope := PushScope(skBlock);
  while FToken.Kind <> tkRightBrace do
  begin
    if FToken.Kind = tkEnd then
      Unexpected;
    Result.Add(ParseStatementListItem);
  end;
  Next;
  if NewScope then
    PopScope;
end;

function TJsParser.ParseVariableStatement(Kind: TJsDeclarationKind; InFor: Boolean): TJsNode;
var
  Declarator: TJsNode;
begin
  Result := NewNode(nkVariables);
  Result.Flags := Ord(Kind);
  Next;
  repeat
    Declarator := NewNode(nkDeclarator);
    Declarator.A := ParseBindingTarget(Kind);
    if Accept(tkAssign) then
    begin
      Declarator.B := ParseAssignment(InFor);
      MarkInitialized(Declarator.A);
    end
    else if not InFor then
    begin
      if Kind = dkConst then
        Fail('Missing initializer in const declaration');
      if Declarator.A.Kind <> nkIdentifier then
        Fail('Missing initializer in destructuring declaration');
    end;
    Result.Add(Declarator);
  until not Accept(tkComma);
  if not InFor then
    ConsumeSemicolon;
end;

function TJsParser.ParseIf: TJsNode;
begin
  Result := NewNode(nkIf);
  Next;
  Expect(tkLeftParen);
  Result.A := ParseExpression;
  Expect(tkRightParen);
  Result.B := ParseStatement;
  if Accept(tkElse) then
    Result.C := ParseStatement;
end;

function TJsParser.ParseWhile: TJsNode;
begin
  Result := NewNode(nkWhile);
  Next;
  Expect(tkLeftParen);
  Result.A := ParseExpression;
  Expect(tkRightParen);
  Inc(FLoopDepth);
  Result.D := ParseStatement;
  Dec(FLoopDepth);
end;

function TJsParser.ParseDoWhile: TJsNode;
begin
  Result := NewNode(nkDoWhile);
  Next;
  Inc(FLoopDepth);
  Result.D := ParseStatement;
  Dec(FLoopDepth);
  Expect(tkWhile);
  Expect(tkLeftParen);
  Result.A := ParseExpression;
  Expect(tkRightParen);
  Accept(tkSemicolon);
end;

function TJsParser.ParseFor: TJsNode;
var
  StartToken: TJsToken;
  Init: TJsNode;
  IsAwait: Boolean;
  Kind: TJsDeclarationKind;
  Scope: TJsScope;
begin
  StartToken := FToken;
  Next;
  IsAwait := False;
  if IsContextual(jwAwait) and FInAsync then
  begin
    IsAwait := True;
    if FFunction.Kind = fkModule then
      FFunction.IsAsync := True;
    Next;
  end;
  Expect(tkLeftParen);
  Scope := PushScope(skFor);
  Init := nil;
  if FToken.Kind = tkSemicolon then
  else if (FToken.Kind = tkVar) or (FToken.Kind = tkConst) or IsLetDeclaration then
  begin
    if FToken.Kind = tkVar then
      Kind := dkVar
    else if FToken.Kind = tkConst then
      Kind := dkConst
    else
      Kind := dkLet;
    Init := ParseVariableStatement(Kind, True);
  end
  else
    Init := ParseExpression(True);
  if (Init <> nil) and (IsContextual(jwOf) or (FToken.Kind = tkIn)) then
  begin
    if FToken.Kind = tkIn then
      Result := NewNodeAt(nkForIn, StartToken)
    else
      Result := NewNodeAt(nkForOf, StartToken);
    if IsAwait then
      Result.Flags := ForFlagAwait;
    if Init.Kind = nkVariables then
    begin
      if Init.Count <> 1 then
        Fail('Invalid left-hand side in for loop: must have a single binding');
      if (Init.List[0].B <> nil) and ((Result.Kind = nkForOf) or FStrict or (Init.Flags <> Ord(dkVar)) or
        (Init.List[0].A.Kind <> nkIdentifier)) then
        Fail('for-in loop variable declaration may not have an initializer');
    end
    else
      Init := ToPattern(Init, False);
    Next;
    Result.A := Init;
    if Result.Kind = nkForOf then
      Result.B := ParseAssignment
    else
      Result.B := ParseExpression;
    Expect(tkRightParen);
  end
  else
  begin
    if IsAwait then
      Unexpected;
    Result := NewNodeAt(nkFor, StartToken);
    Result.A := Init;
    Expect(tkSemicolon);
    if FToken.Kind <> tkSemicolon then
      Result.B := ParseExpression;
    Expect(tkSemicolon);
    if FToken.Kind <> tkRightParen then
      Result.C := ParseExpression;
    Expect(tkRightParen);
  end;
  Result.Scope := Scope;
  Inc(FLoopDepth);
  Result.D := ParseStatement;
  Dec(FLoopDepth);
  PopScope;
end;

function TJsParser.ParseReturn: TJsNode;
begin
  if FFunction.Kind in [fkScript, fkModule] then
    Fail('Illegal return statement');
  Result := NewNode(nkReturn);
  Next;
  if not (FToken.Kind in [tkSemicolon, tkRightBrace, tkEnd]) and not FToken.NewlineBefore then
    Result.A := ParseExpression;
  ConsumeSemicolon;
end;

function TJsParser.ParseBreakContinue(Kind: TJsNodeKind): TJsNode;
var
  Index: Integer;
  Found: Boolean;
begin
  Result := NewNode(Kind);
  Next;
  if (FToken.Kind = tkIdentifier) and not FToken.NewlineBefore then
  begin
    Result.Text := FLexer.Names[FToken.Name];
    Found := False;
    for Index := FLabelBase to FLabelCount - 1 do
      if FLabels[Index] = Result.Text then
        Found := True;
    if not Found then
      FailUndefinedLabel(Result.Text);
    Next;
  end
  else if (Kind = nkContinue) and (FLoopDepth = 0) then
    Fail('Illegal continue statement: no surrounding iteration statement')
  else if (Kind = nkBreak) and (FLoopDepth = 0) and (FSwitchDepth = 0) then
    Fail('Illegal break statement');
  ConsumeSemicolon;
end;

function TJsParser.ParseThrow: TJsNode;
begin
  Result := NewNode(nkThrow);
  Next;
  if FToken.NewlineBefore then
    Fail('Illegal newline after throw');
  Result.A := ParseExpression;
  ConsumeSemicolon;
end;

function TJsParser.ParseTry: TJsNode;
begin
  Result := NewNode(nkTry);
  Next;
  Result.A := ParseBlock;
  if FToken.Kind = tkCatch then
  begin
    Next;
    Result.Scope := PushScope(skCatch);
    if Accept(tkLeftParen) then
    begin
      Result.B := ParseBindingTarget(dkCatch);
      Expect(tkRightParen);
    end;
    Result.C := ParseBlock;
    PopScope;
  end;
  if Accept(tkFinally) then
    Result.D := ParseBlock;
  if (Result.C = nil) and (Result.D = nil) then
    Fail('Missing catch or finally after try');
end;

function TJsParser.ParseSwitch: TJsNode;
var
  CaseNode: TJsNode;
  HasDefault: Boolean;
begin
  Result := NewNode(nkSwitch);
  Next;
  Expect(tkLeftParen);
  Result.A := ParseExpression;
  Expect(tkRightParen);
  Expect(tkLeftBrace);
  Result.Scope := PushScope(skSwitch);
  Inc(FSwitchDepth);
  HasDefault := False;
  while FToken.Kind <> tkRightBrace do
  begin
    CaseNode := NewNode(nkCase);
    if Accept(tkDefault) then
    begin
      if HasDefault then
        Fail('More than one default clause in switch statement');
      HasDefault := True;
    end
    else
    begin
      Expect(tkCase);
      CaseNode.A := ParseExpression;
    end;
    Expect(tkColon);
    while not (FToken.Kind in [tkCase, tkDefault, tkRightBrace, tkEnd]) do
      CaseNode.Add(ParseStatementListItem);
    Result.Add(CaseNode);
  end;
  Next;
  Dec(FSwitchDepth);
  PopScope;
end;

function TJsParser.ParseWith: TJsNode;
begin
  if FStrict then
    Fail('Strict mode code may not include a with statement');
  Result := NewNode(nkWith);
  Next;
  Expect(tkLeftParen);
  Result.A := ParseExpression;
  Expect(tkRightParen);
  { The body's names are looked up in the object first: a scope whose
    environment holds it. }
  Result.Scope := PushScope(skBlock);
  Result.Scope.WithVariable := Result.Scope.Declare('%with', dkImplicit, 0);
  Result.Scope.WithVariable.Captured := True;
  Result.B := ParseStatement;
  PopScope;
end;

function TJsParser.ParseLabeledOrExpression: TJsNode;
var
  StartToken: TJsToken;
  Expression: TJsNode;
begin
  if (FToken.Kind = tkIdentifier) and (PeekToken.Kind = tkColon) and IsIdentifierToken then
    Exit(ParseLabeledStatement);
  StartToken := FToken;
  Expression := ParseExpression;
  Result := NewNodeAt(nkExpressionStatement, StartToken);
  Result.A := Expression;
  ConsumeSemicolon;
end;

{ label: statement (the current token is the label). }
function TJsParser.ParseLabeledStatement: TJsNode;
begin
  Result := NewNode(nkLabeled);
  Result.Text := FLexer.Names[FToken.Name];
  Next;
  Next;
  if FLabelCount >= Length(FLabels) then
    SetLength(FLabels, Length(FLabels) * 2 + 4);
  FLabels[FLabelCount] := Result.Text;
  Inc(FLabelCount);
  if FToken.Kind = tkFunction then
  begin
    if FStrict then
      Fail('In strict mode code, functions can only be declared at top level or inside a block');
    Result.A := ParseFunctionDeclaration(False);
  end
  else
  begin
    { A labelled statement that is not a loop still takes break. }
    Inc(FSwitchDepth);
    Result.A := ParseStatement;
    Dec(FSwitchDepth);
  end;
  Dec(FLabelCount);
end;

function TJsParser.ParseFunctionDeclaration(IsAsync: Boolean; DefaultExport: Boolean): TJsNode;
var
  StartToken, NameToken: TJsToken;
  IsGenerator: Boolean;
  Name, BindingName: UnicodeString;
  Variable: TJsVariable;
  Kind: TJsDeclarationKind;
  Outer, AnnexScope: TJsScope;
  Existing: TJsVariable;
  Blocked: Boolean;
begin
  StartToken := FToken;
  Expect(tkFunction);
  IsGenerator := Accept(tkStar);
  NameToken := FToken;
  if DefaultExport and (FToken.Kind = tkLeftParen) then
  begin
    { export default function (): bound as *default*, named default. }
    Name := 'default';
    BindingName := '*default*';
  end
  else
  begin
    Name := BindingIdentifierName;
    BindingName := Name;
  end;
  Result := NewNodeAt(nkFunctionDeclaration, StartToken);
  if FScope = FScope.FunctionScope then
    Kind := dkFunction
  else
    Kind := dkFunction;
  if FScope <> FScope.FunctionScope then
  begin
    { A block's function: lexical in the block. }
    Existing := FScope.Find(Name);
    if (Existing <> nil) and (FStrict or (Existing.Kind <> dkFunction) or not Existing.IsPlainBlockFunction or
      IsAsync or IsGenerator) then
      FailRedeclared(NameToken, Name);
    if Existing <> nil then
      Variable := Existing
    else
    begin
      Variable := FScope.Declare(Name, dkFunction, NameToken.Start);
      Variable.IsPlainBlockFunction := not IsAsync and not IsGenerator;
    end;
    Variable.Kind := dkFunction;
    if not FStrict and not IsAsync and not IsGenerator then
    begin
      { Annex B: also a var of the function, when that does not clash
        with a lexical binding on the way. }
      Blocked := False;
      Outer := FScope.Parent;
      while Outer <> FScope.FunctionScope do
      begin
        Existing := Outer.Find(Name);
        if (Existing <> nil) and Existing.IsLexical then
          Blocked := True;
        Outer := Outer.Parent;
      end;
      AnnexScope := FScope.FunctionScope;
      Existing := AnnexScope.Find(Name);
      if (Existing <> nil) and Existing.IsLexical then
        Blocked := True;
      if not Blocked then
      begin
        if Existing = nil then
        begin
          Existing := AnnexScope.Declare(Name, dkVar, NameToken.Start);
          Existing.IsAnnexB := True;
        end;
        Result.Name := Name;
      end;
    end;
  end
  else
    DeclareName(BindingName, Kind, NameToken);
  Result.Func := ParseFunction(fkNormal, IsAsync, IsGenerator, Name, StartToken);
  Result.A := NewIdentifier(BindingName, NameToken);
  { The reference belongs to the declaring scope, not the function. }
end;

function TJsParser.ParseClassDeclaration: TJsNode;
var
  StartToken: TJsToken;
begin
  StartToken := FToken;
  Result := ParseClass(False, StartToken);
  Result.Kind := nkClassDeclaration;
  MarkInitialized(Result.B);
end;

{ Functions }

function TJsParser.DiscardsBody(Info: TJsFunctionInfo): Boolean;
begin
  Result := CompilesLazily(Info) and (Info.SourceStart <> FKeepBodyStart);
end;

{ The parser's state is restored on the way out without an exception
  frame: after a syntax error the parser is not used again. }
function TJsParser.ParseFunction(Kind: TJsFunctionKind; IsAsync, IsGenerator: Boolean;
  const Name: UnicodeString; const StartToken: TJsToken): TJsFunctionInfo;
var
  SavedFunction: TJsFunctionInfo;
  SavedStrict, SavedGenerator, SavedAsync, SavedClassField: Boolean;
  SavedLabelBase, SavedLoop, SavedSwitch: Integer;
  NodeMark: Integer;
begin
  NodeMark := FArena.NodeCount;
  Result := TJsFunctionInfo.Create;
  FArena.Own(Result);
  Result.Name := Name;
  Result.Kind := Kind;
  Result.InParentheses := FNextFunctionInParentheses;
  FNextFunctionInParentheses := False;
  Result.IsAsync := IsAsync;
  Result.IsGenerator := IsGenerator;
  Result.SourceStart := StartToken.Start;
  Result.Line := StartToken.Line;
  Result.Column := StartToken.Column;
  SavedFunction := FFunction;
  SavedStrict := FStrict;
  SavedGenerator := FInGenerator;
  SavedAsync := FInAsync;
  SavedClassField := FInClassField;
  SavedLabelBase := FLabelBase;
  SavedLoop := FLoopDepth;
  SavedSwitch := FSwitchDepth;
  FFunction := Result;
  FLabelBase := FLabelCount;
  FLoopDepth := 0;
  FSwitchDepth := 0;
  FInClassField := False;
  Result.IsStrict := FStrict;
  Result.Scope := PushScope(skFunction);
  FInGenerator := IsGenerator;
  FInAsync := IsAsync;
  Result.ParametersStart := FToken.Start;
  Result.ParametersLine := FToken.Line;
  Result.ParametersColumn := FToken.Column;
  ParseParameters(Result);
  ParseFunctionBody(Result);
  Result.SourceFinish := FPreviousFinish;
  PopScope;
  FFunction := SavedFunction;
  if Result.UsesPrivateNames and (FFunction <> nil) then
    FFunction.UsesPrivateNames := True;
  FStrict := SavedStrict;
  FInGenerator := SavedGenerator;
  FInAsync := SavedAsync;
  FInClassField := SavedClassField;
  FLabelBase := SavedLabelBase;
  FLoopDepth := SavedLoop;
  FSwitchDepth := SavedSwitch;
  { Compiled from its source when called: its nodes are not needed. }
  if DiscardsBody(Result) then
    DiscardLazyBody(FArena, Result, NodeMark);
end;

procedure TJsParser.ParseParameters(Info: TJsFunctionInfo);
var
  Parameter: TJsNode;
  Counting: Boolean;
begin
  Expect(tkLeftParen);
  Info.HasSimpleParameters := True;
  Counting := True;
  while FToken.Kind <> tkRightParen do
  begin
    if FToken.Kind = tkEllipsis then
    begin
      Parameter := NewNode(nkRest);
      Next;
      Parameter.A := ParseBindingTarget(dkParameter);
      Info.HasSimpleParameters := False;
      Counting := False;
      if FToken.Kind <> tkRightParen then
        Fail('Rest parameter must be last formal parameter');
    end
    else
    begin
      Parameter := ParseBindingElement(dkParameter);
      if Parameter.Kind <> nkIdentifier then
        Info.HasSimpleParameters := False;
      if Parameter.Kind = nkAssignPattern then
        Counting := False;
    end;
    if Counting then
      Inc(Info.Length);
    if Info.ParameterCount >= Length(Info.Parameters) then
      SetLength(Info.Parameters, Length(Info.Parameters) * 2 + 4);
    Info.Parameters[Info.ParameterCount] := Parameter;
    Inc(Info.ParameterCount);
    if FToken.Kind <> tkRightParen then
      Expect(tkComma);
  end;
  Next;
  if Info.Kind = fkGetter then
  begin
    if Info.ParameterCount <> 0 then
      Fail('Getter must not have any formal parameters');
  end
  else if Info.Kind = fkSetter then
    if Info.ParameterCount <> 1 then
      Fail('Setter must have exactly one formal parameter');
end;

procedure TJsParser.ParseFunctionBody(Info: TJsFunctionInfo);
var
  Directives: Boolean;
  Statement: TJsNode;
begin
  Expect(tkLeftBrace);
  Directives := True;
  while FToken.Kind <> tkRightBrace do
  begin
    if FToken.Kind = tkEnd then
      Unexpected;
    if Directives then
    begin
      if FLexer.IsUseStrict(FToken) then
      begin
        if not Info.HasSimpleParameters then
          Fail('Illegal ''use strict'' directive in function with non-simple parameter list');
        FStrict := True;
        Info.IsStrict := True;
      end
      else if FToken.Kind <> tkString then
        Directives := False;
    end;
    Statement := ParseStatementListItem;
    if Directives and ((Statement.Kind <> nkExpressionStatement) or (Statement.A.Kind <> nkString)) then
      Directives := False;
    if Info.BodyCount >= Length(Info.Body) then
      SetLength(Info.Body, Length(Info.Body) * 2 + 8);
    Info.Body[Info.BodyCount] := Statement;
    Inc(Info.BodyCount);
  end;
  Next;
end;

{ The arrow's parameters were parsed as an expression from NodeMark
  (a node count) on, in OuterScope from its reference and child counts
  on. }
function TJsParser.ParseArrowFunction(Parameters: TJsNode; IsAsync: Boolean; const StartToken: TJsSourceMark;
  ReferenceMark, ChildMark, NodeMark: Integer; OuterScope: TJsScope): TJsNode;
var
  Info: TJsFunctionInfo;
  Scope: TJsScope;
  Index, Count: Integer;
  Parameter: TJsNode;
  SavedFunction: TJsFunctionInfo;
  Counting: Boolean;
begin
  if FToken.NewlineBefore then
    Fail('Unexpected token ''=>''');
  Expect(tkArrow);
  Info := TJsFunctionInfo.Create;
  FArena.Own(Info);
  Info.Kind := fkArrow;
  Info.IsAsync := IsAsync;
  Info.IsStrict := FStrict;
  Info.InParentheses := StartToken.Start = FParenthesizedStart;
  Info.SourceStart := StartToken.Start;
  Info.Line := StartToken.Line;
  Info.Column := StartToken.Column;
  SavedFunction := FFunction;
  FFunction := Info;
  Scope := PushScope(skFunction);
  Info.Scope := Scope;
  { The parameters were parsed as an expression in the outer scope:
    their references and any functions in them move in here. }
  for Index := ReferenceMark to OuterScope.ReferenceCount - 1 do
    Scope.AddReference(OuterScope.References[Index]);
  OuterScope.ReferenceCount := ReferenceMark;
  for Index := ChildMark to OuterScope.ChildCount - 1 do
    if OuterScope.Children[Index] <> Scope then
    begin
      OuterScope.Children[Index].Parent := Scope;
      Scope.AddChild(OuterScope.Children[Index]);
    end;
  OuterScope.ChildCount := ChildMark;
  OuterScope.AddChild(Scope);
  { The parameter list. }
  if Parameters = nil then
    Count := 0
  else if Parameters.Kind = nkSequence then
    Count := Parameters.Count
  else
    Count := 1;
  SetLength(Info.Parameters, Count);
  Info.HasSimpleParameters := True;
  Counting := True;
  for Index := 0 to Count - 1 do
  begin
    if Parameters.Kind = nkSequence then
      Parameter := Parameters.List[Index]
    else
      Parameter := Parameters;
    Parameter := ToPattern(Parameter, True);
    if Parameter.Kind <> nkIdentifier then
      Info.HasSimpleParameters := False;
    if Parameter.Kind in [nkAssignPattern, nkRest] then
      Counting := False;
    if Counting then
      Inc(Info.Length);
    DeclarePatternNames(Parameter, dkParameter);
    Info.Parameters[Info.ParameterCount] := Parameter;
    Inc(Info.ParameterCount);
  end;
  ParseArrowBody(Info);
  PopScope;
  FFunction := SavedFunction;
  if Info.UsesPrivateNames and (FFunction <> nil) then
    FFunction.UsesPrivateNames := True;
  { Compiled from its source when called: neither its parameters nor
    its body are needed. }
  if DiscardsBody(Info) then
    DiscardLazyBody(FArena, Info, NodeMark);
  Result := NewNodeAtMark(nkFunction, StartToken);
  Result.Func := Info;
end;

{ After =>: a block or an expression. }
procedure TJsParser.ParseArrowBody(Info: TJsFunctionInfo);
var
  SavedStrict, SavedGenerator, SavedAsync: Boolean;
  SavedLabelBase, SavedLoop, SavedSwitch: Integer;
begin
  SavedStrict := FStrict;
  SavedGenerator := FInGenerator;
  SavedAsync := FInAsync;
  SavedLabelBase := FLabelBase;
  SavedLoop := FLoopDepth;
  SavedSwitch := FSwitchDepth;
  FLabelBase := FLabelCount;
  FLoopDepth := 0;
  FSwitchDepth := 0;
  FInGenerator := False;
  FInAsync := Info.IsAsync;
  if FToken.Kind = tkLeftBrace then
    ParseFunctionBody(Info)
  else
    Info.ExpressionBody := ParseAssignment;
  Info.SourceFinish := FPreviousFinish;
  FStrict := SavedStrict;
  FInGenerator := SavedGenerator;
  FInAsync := SavedAsync;
  FLabelBase := SavedLabelBase;
  FLoopDepth := SavedLoop;
  FSwitchDepth := SavedSwitch;
end;

{ Classes }

function TJsParser.NewFieldInitializer(ClassNode: TJsNode; IsStatic: Boolean): TJsFunctionInfo;
var
  SavedScope: TJsScope;
begin
  Result := TJsFunctionInfo.Create;
  FArena.Own(Result);
  Result.Kind := fkClassFieldInitializer;
  Result.IsStrict := True;
  Result.ClassNode := ClassNode;
  Result.HasSimpleParameters := True;
  SavedScope := FScope;
  Result.Scope := PushScope(skFunction);
  Result.Scope.Func := Result;
  FScope := SavedScope;
end;

function TJsParser.ParsePropertyKey(out Computed: Boolean; out KeyName: UnicodeString): TJsNode;
begin
  Computed := False;
  KeyName := '';
  case FToken.Kind of
    tkString:
      begin
        Result := NewNode(nkString);
        FLexer.DecodeString(FToken, Result.Text);
        KeyName := Result.Text;
        Next;
      end;
    tkNumber:
      begin
        Result := NewNode(nkNumber);
        Result.Number := FToken.Number;
        Next;
      end;
    tkBigInt:
      begin
        Result := NewNode(nkBigInt);
        FLexer.DecodeBigInt(FToken, Result.Text);
        Result.Number := FToken.Number;
        Next;
      end;
    tkLeftBracket:
      begin
        Next;
        Computed := True;
        Result := ParseAssignment;
        Expect(tkRightBracket);
      end;
    tkPrivateName:
      begin
        Result := NewNode(nkPrivateName);
        Result.Text := '#' + FLexer.Names[FToken.Name];
        KeyName := Result.Text;
        Next;
      end;
  else
    Result := NewNode(nkString);
    TakeIdentifierName(KeyName);
    Result.Text := KeyName;
  end;
end;

function TJsParser.ParseClassMember(ClassNode: TJsNode; var InstanceInit, StaticInit: TJsFunctionInfo): TJsNode;
var
  StartToken: TJsToken;
  IsStatic, IsAsync, IsGenerator, Computed: Boolean;
  Kind: TJsFunctionKind;
  KeyName: UnicodeString;
  Key: TJsNode;
  Peeked: TJsToken;
  Init: TJsFunctionInfo;
  SavedScope: TJsScope;
  SavedFunction: TJsFunctionInfo;
  SavedClassField, SavedAsync, SavedGenerator: Boolean;
  Block: TJsNode;
  FunctionNode: TJsNode;

  function NextIsKeyStart: Boolean;
  begin
    Peeked := PeekToken;
    Result := not (Peeked.Kind in [tkLeftParen, tkAssign, tkSemicolon, tkRightBrace]) and
      not (Peeked.NewlineBefore and not (Peeked.Kind in [tkLeftBracket, tkStar]) and False);
  end;

begin
  StartToken := FToken;
  Result := NewNode(nkClassMember);
  IsStatic := False;
  IsAsync := False;
  IsGenerator := False;
  Kind := fkMethod;
  if IsContextual(jwStatic) and NextIsKeyStart then
  begin
    Next;
    IsStatic := True;
    Result.Flags := Result.Flags or PropertyFlagStatic;
    if FToken.Kind = tkLeftBrace then
    begin
      { A static initialization block: part of the static initializer. }
      if StaticInit = nil then
        StaticInit := NewFieldInitializer(ClassNode, True);
      SavedScope := FScope;
      SavedFunction := FFunction;
      SavedClassField := FInClassField;
      SavedAsync := FInAsync;
      SavedGenerator := FInGenerator;
      FScope := StaticInit.Scope;
      FFunction := StaticInit;
      FInClassField := True;
      FInAsync := False;
      FInGenerator := False;
      Block := ParseBlock;
      FScope := SavedScope;
      FFunction := SavedFunction;
      FInClassField := SavedClassField;
      FInAsync := SavedAsync;
      FInGenerator := SavedGenerator;
      Result.Flags := Result.Flags or PropertyFlagStaticBlock;
      Result.B := Block;
      Exit;
    end;
  end;
  if IsContextual(jwAsync) then
  begin
    Peeked := PeekToken;
    if not (Peeked.Kind in [tkLeftParen, tkAssign, tkSemicolon, tkRightBrace]) and not Peeked.NewlineBefore then
    begin
      Next;
      IsAsync := True;
    end;
  end;
  if FToken.Kind = tkStar then
  begin
    Next;
    IsGenerator := True;
  end;
  if (IsContextual(jwGet) or IsContextual(jwSet)) and not IsAsync and not IsGenerator then
  begin
    Peeked := PeekToken;
    if not (Peeked.Kind in [tkLeftParen, tkAssign, tkSemicolon, tkRightBrace]) then
    begin
      if FToken.Word = jwGet then
      begin
        Kind := fkGetter;
        Result.Flags := Result.Flags or PropertyFlagGetter;
      end
      else
      begin
        Kind := fkSetter;
        Result.Flags := Result.Flags or PropertyFlagSetter;
      end;
      Next;
    end;
  end;
  Key := ParsePropertyKey(Computed, KeyName);
  if Computed then
    Result.Flags := Result.Flags or PropertyFlagComputed;
  if Key.Kind = nkPrivateName then
  begin
    Result.Flags := Result.Flags or PropertyFlagPrivate;
    if KeyName = '#constructor' then
      Fail('Classes may not have a private field named ''#constructor''');
  end;
  Result.A := Key;
  if FToken.Kind = tkLeftParen then
  begin
    Result.Flags := Result.Flags or PropertyFlagMethod;
    if (not IsStatic) and (not Computed) and (Key.Kind = nkString) and (KeyName = 'constructor') then
    begin
      if (Kind <> fkMethod) or IsAsync or IsGenerator then
        Fail('Class constructor may not be an accessor, generator or async');
      if ClassNode.A <> nil then
        Kind := fkDerivedConstructor
      else
        Kind := fkClassConstructor;
      Result.Flags := Result.Flags or PropertyFlagProto;
    end;
    FunctionNode := NewNodeAt(nkFunction, StartToken);
    FunctionNode.Func := ParseFunction(Kind, IsAsync, IsGenerator, KeyName, StartToken);
    FunctionNode.Func.ClassNode := ClassNode;
    { The constructor takes the class's name. }
    if Kind in [fkClassConstructor, fkDerivedConstructor] then
      FunctionNode.Func.Name := '';
    Result.B := FunctionNode;
    Exit;
  end;
  { A field. }
  if IsAsync or IsGenerator or (Kind <> fkMethod) then
    Unexpected;
  if (not Computed) and (Key.Kind = nkString) and ((KeyName = 'constructor') or
    (IsStatic and (KeyName = 'prototype'))) then
    Fail('Classes may not have a field named ''' + string(KeyName) + '''');
  Result.Flags := Result.Flags or PropertyFlagField;
  if IsStatic then
  begin
    if StaticInit = nil then
      StaticInit := NewFieldInitializer(ClassNode, True);
    Init := StaticInit;
  end
  else
  begin
    if InstanceInit = nil then
      InstanceInit := NewFieldInitializer(ClassNode, False);
    Init := InstanceInit;
  end;
  if Accept(tkAssign) then
  begin
    SavedScope := FScope;
    SavedFunction := FFunction;
    SavedClassField := FInClassField;
    SavedAsync := FInAsync;
    SavedGenerator := FInGenerator;
    FScope := Init.Scope;
    FFunction := Init;
    FInClassField := True;
    FInAsync := False;
    FInGenerator := False;
    Result.B := ParseAssignment;
    FScope := SavedScope;
    FFunction := SavedFunction;
    FInClassField := SavedClassField;
    FInAsync := SavedAsync;
    FInGenerator := SavedGenerator;
  end;
  ConsumeSemicolon;
end;

function TJsParser.ParseClass(IsExpression: Boolean; const StartToken: TJsToken): TJsNode;
var
  NameToken: TJsToken;
  Name: UnicodeString;
  ClassScope: TJsScope;
  Member: TJsNode;
  SavedStrict: Boolean;
  InstanceInit, StaticInit: TJsFunctionInfo;
  Index: Integer;
  Inner: TJsVariable;
  Initializer: TJsNode;
begin
  Expect(tkClass);
  Result := NewNodeAt(nkClass, StartToken);
  Name := '';
  NameToken := FToken;
  if IsIdentifierToken or ((FToken.Kind = tkIdentifier) and (FToken.Word = jwAwait) and not FInAsync) then
  begin
    Name := TokenText;
    Next;
  end
  else if not IsExpression then
    Unexpected;
  Result.Text := Name;
  SavedStrict := FStrict;
  FStrict := True;
  if (Name <> '') and not IsExpression then
  begin
    DeclareName(Name, dkClass, NameToken);
    Result.B := NewIdentifier(Name, NameToken);
  end;
  ClassScope := PushScope(skClass);
  Result.Scope := ClassScope;
  if Name <> '' then
  begin
    Inner := ClassScope.Declare(Name, dkClassInner, NameToken.Start);
    Inner.DeclarationStart := MaxInt;
  end;
  if Accept(tkExtends) then
    Result.A := ParseLeftHandSide;
  Expect(tkLeftBrace);
  InstanceInit := nil;
  StaticInit := nil;
  while FToken.Kind <> tkRightBrace do
  begin
    if Accept(tkSemicolon) then
      Continue;
    if FToken.Kind = tkEnd then
      Unexpected;
    Member := ParseClassMember(Result, InstanceInit, StaticInit);
    if (Member.Flags and PropertyFlagPrivate) <> 0 then
    begin
      { The private name: a hidden constant of the class scope. }
      if (Member.Flags and (PropertyFlagField or PropertyFlagStatic)) = 0 then
      begin
        { Instance private methods are installed by the initializer. }
        if InstanceInit = nil then
          InstanceInit := NewFieldInitializer(Result, False);
      end;
      if ClassScope.Find(Member.A.Text) = nil then
        ClassScope.Declare(Member.A.Text, dkConst, 0).Captured := True
      else if (Member.Flags and (PropertyFlagGetter or PropertyFlagSetter)) = 0 then
        Fail('Identifier ''' + string(Member.A.Text) + ''' has already been declared');
    end;
    Result.Add(Member);
  end;
  Next;
  { The initializers are functions of the class scope. }
  if InstanceInit <> nil then
  begin
    Initializer := NewNodeAt(nkFunction, StartToken);
    Initializer.Func := InstanceInit;
    Result.C := Initializer;
  end;
  if StaticInit <> nil then
  begin
    Initializer := NewNodeAt(nkFunction, StartToken);
    Initializer.Func := StaticInit;
    Result.D := Initializer;
  end;
  PopScope;
  FStrict := SavedStrict;
end;

{ Patterns }

function TJsParser.ParseBindingTarget(Kind: TJsDeclarationKind): TJsNode;
var
  StartToken: TJsToken;
  Name: Integer;
begin
  case FToken.Kind of
    tkLeftBracket:
      Result := ParseArrayBindingPattern(Kind);
    tkLeftBrace:
      Result := ParseObjectBindingPattern(Kind);
  else
    StartToken := FToken;
    Name := BindingIdentifier;
    if (Kind in [dkLet, dkConst]) and (StartToken.Word = jwLet) then
      FailAt(StartToken, 'let is disallowed as a lexically bound name');
    DeclareName(FLexer.Names[Name], Kind, StartToken);
    Result := NewIdentifierAt(Name, StartToken);
  end;
end;

function TJsParser.ParseArrayBindingPattern(Kind: TJsDeclarationKind): TJsNode;
var
  Element: TJsNode;
begin
  Result := NewNode(nkArrayPattern);
  Next;
  while FToken.Kind <> tkRightBracket do
  begin
    if FToken.Kind = tkComma then
    begin
      Result.Add(NewNode(nkHole));
      Next;
      Continue;
    end;
    if FToken.Kind = tkEllipsis then
    begin
      Element := NewNode(nkRest);
      Next;
      Element.A := ParseBindingTarget(Kind);
      Result.Add(Element);
      Break;
    end;
    Result.Add(ParseBindingElement(Kind));
    if FToken.Kind <> tkRightBracket then
      Expect(tkComma);
  end;
  Expect(tkRightBracket);
end;

function TJsParser.ParseObjectBindingPattern(Kind: TJsDeclarationKind): TJsNode;
var
  StartToken: TJsToken;
  Name: Integer;
  Element, Key, Property_: TJsNode;
  Computed: Boolean;
  KeyName: UnicodeString;
begin
  Result := NewNode(nkObjectPattern);
  Next;
  while FToken.Kind <> tkRightBrace do
  begin
    if FToken.Kind = tkEllipsis then
    begin
      Element := NewNode(nkRest);
      Next;
      StartToken := FToken;
      Name := BindingIdentifier;
      DeclareName(FLexer.Names[Name], Kind, StartToken);
      Element.A := NewIdentifierAt(Name, StartToken);
      Result.Add(Element);
      Break;
    end;
    Property_ := NewNode(nkProperty);
    StartToken := FToken;
    Key := ParsePropertyKey(Computed, KeyName);
    Property_.A := Key;
    if Computed then
      Property_.Flags := PropertyFlagComputed;
    if Accept(tkColon) then
      Property_.B := ParseBindingElement(Kind)
    else
    begin
      if (Key.Kind <> nkString) or (StartToken.Kind <> tkIdentifier) then
        Unexpected;
      if (KeyName = 'yield') and (FInGenerator or FStrict) or (KeyName = 'await') and FInAsync then
        Unexpected;
      DeclareName(KeyName, Kind, StartToken);
      Element := NewIdentifier(KeyName, StartToken);
      if FToken.Kind = tkAssign then
      begin
        Next;
        Property_.B := NewNodeAt(nkAssignPattern, StartToken);
        Property_.B.A := Element;
        Property_.B.B := ParseAssignment;
      end
      else
        Property_.B := Element;
      Property_.Flags := Property_.Flags or PropertyFlagShorthand;
    end;
    Result.Add(Property_);
    if FToken.Kind <> tkRightBrace then
      Expect(tkComma);
  end;
  Expect(tkRightBrace);
end;

function TJsParser.ParseBindingElement(Kind: TJsDeclarationKind): TJsNode;
var
  Target: TJsNode;
  StartToken: TJsToken;
begin
  StartToken := FToken;
  Target := ParseBindingTarget(Kind);
  if FToken.Kind = tkAssign then
  begin
    Next;
    Result := NewNodeAt(nkAssignPattern, StartToken);
    Result.A := Target;
    Result.B := ParseAssignment;
  end
  else
    Result := Target;
end;

function TJsParser.IsSimpleAssignmentTarget(Node: TJsNode): Boolean;
begin
  case Node.Kind of
    nkIdentifier:
      Result := not (FStrict and ((Node.Text = 'eval') or (Node.Text = 'arguments')));
    nkMember, nkSuperMember:
      Result := True;
    nkCall:
      Result := not FStrict;
  else
    Result := False;
  end;
end;

{ An expression parsed under a cover grammar, as a pattern. }
function TJsParser.ToPattern(Node: TJsNode; Binding: Boolean): TJsNode;
var
  Index: Integer;
  Element: TJsNode;
begin
  Result := Node;
  case Node.Kind of
    nkIdentifier:
      begin
        if FStrict and ((Node.Text = 'eval') or (Node.Text = 'arguments')) then
          raise EJsSyntaxError.CreateAt('Unexpected eval or arguments in strict mode', Node.Line, Node.Column);
      end;
    nkMember, nkSuperMember:
      if Binding then
        raise EJsSyntaxError.CreateAt('Invalid destructuring target', Node.Line, Node.Column);
    nkArray:
      begin
        Node.Kind := nkArrayPattern;
        for Index := 0 to Node.Count - 1 do
        begin
          Element := Node.List[Index];
          if Element.Kind = nkSpread then
          begin
            if Index <> Node.Count - 1 then
              raise EJsSyntaxError.CreateAt('Rest element must be last element', Element.Line, Element.Column);
            if Element.A.Kind = nkAssign then
              raise EJsSyntaxError.CreateAt('Rest element may not have a default initializer', Element.Line,
                Element.Column);
            Element.Kind := nkRest;
            Element.A := ToPattern(Element.A, Binding);
          end
          else if Element.Kind <> nkHole then
            Node.List[Index] := ToPattern(Element, Binding);
        end;
      end;
    nkObject:
      begin
        Node.Kind := nkObjectPattern;
        for Index := 0 to Node.Count - 1 do
        begin
          Element := Node.List[Index];
          if (Element.Flags and PropertyFlagSpread) <> 0 then
          begin
            { An object rest takes a name or a property, not a pattern. }
            if Element.A.Kind in [nkArray, nkObject, nkAssign] then
              raise EJsSyntaxError.CreateAt('Invalid rest element', Element.Line, Element.Column);
            Element.Kind := nkRest;
            Element.A := ToPattern(Element.A, Binding);
          end
          else
          begin
            if (Element.Flags and (PropertyFlagMethod or PropertyFlagGetter or PropertyFlagSetter)) <> 0 then
              raise EJsSyntaxError.CreateAt('Invalid destructuring assignment target', Element.Line, Element.Column);
            Element.B := ToPattern(Element.B, Binding);
          end;
        end;
      end;
    nkAssign:
      begin
        if Node.Op <> tkAssign then
          raise EJsSyntaxError.CreateAt('Invalid destructuring assignment target', Node.Line, Node.Column);
        Node.Kind := nkAssignPattern;
        Node.A := ToPattern(Node.A, Binding);
      end;
    nkAssignPattern:
      Node.A := ToPattern(Node.A, Binding);
    nkRest:
      Node.A := ToPattern(Node.A, Binding);
    nkSpread:
      begin
        Node.Kind := nkRest;
        Node.A := ToPattern(Node.A, Binding);
      end;
    nkArrayPattern, nkObjectPattern:
      ;
  else
    raise EJsSyntaxError.CreateAt('Invalid destructuring assignment target', Node.Line, Node.Column);
  end;
end;

{ Expressions }

function TJsParser.ParseExpression(NoIn: Boolean): TJsNode;
var
  Sequence: TJsNode;
begin
  Result := ParseAssignment(NoIn);
  if FToken.Kind = tkComma then
  begin
    Sequence := NewNode(nkSequence);
    Sequence.Line := Result.Line;
    Sequence.Column := Result.Column;
    Sequence.Add(Result);
    while Accept(tkComma) do
      Sequence.Add(ParseAssignment(NoIn));
    Result := Sequence;
  end;
end;

function TJsParser.ParseYield(NoIn: Boolean): TJsNode;
begin
  if FInClassField then
    Fail('Yield expression not allowed in formal parameter');
  Result := NewNode(nkYield);
  Next;
  if FToken.NewlineBefore then
    Exit;
  if Accept(tkStar) then
  begin
    Result.Flags := YieldFlagDelegate;
    Result.A := ParseAssignment(NoIn);
    Exit;
  end;
  if not (FToken.Kind in [tkRightParen, tkRightBracket, tkRightBrace, tkComma, tkSemicolon, tkColon, tkEnd,
    tkIn]) and not ((FToken.Kind = tkIdentifier) and (FToken.Word = jwOf)) then
    Result.A := ParseAssignment(NoIn);
end;

{ After async: an identifier on the same line (async x => ...). }
function TJsParser.AsyncArrowParameterFollows: Boolean;
var
  Peeked: TJsToken;
begin
  Peeked := PeekToken;
  Result := not Peeked.NewlineBefore and (Peeked.Kind = tkIdentifier);
end;

{ async x => ...: from async (the current token) on. }
function TJsParser.ParseAsyncArrowWithIdentifier(const Start: TJsSourceMark): TJsNode;
var
  ReferenceMark, ChildMark, NodeMark: Integer;
  OuterScope: TJsScope;
  ParameterToken: TJsToken;
  Left: TJsNode;
begin
  { The function's source starts at async (toString, and parsing it
    again when it is compiled lazily). }
  Next;
  ReferenceMark := FScope.ReferenceCount;
  ChildMark := FScope.ChildCount;
  NodeMark := FArena.NodeCount;
  OuterScope := FScope;
  ParameterToken := FToken;
  Left := NewIdentifierAt(BindingIdentifier, ParameterToken);
  if FToken.Kind <> tkArrow then
    Unexpected;
  Result := ParseArrowFunction(Left, True, Start, ReferenceMark, ChildMark, NodeMark, OuterScope);
end;

{ The depth is counted without an exception frame: after a syntax
  error the parser is not used again. }
function TJsParser.ParseAssignment(NoIn: Boolean): TJsNode;
begin
  Enter;
  Result := ParseAssignmentAtDepth(NoIn);
  Leave;
end;

function TJsParser.ParseAssignmentAtDepth(NoIn: Boolean): TJsNode;
var
  Start: TJsSourceMark;
  StartIsIdentifier, StartIsAsync: Boolean;
  ReferenceMark, ChildMark, NodeMark: Integer;
  OuterScope: TJsScope;
  Left, Arguments: TJsNode;
  Index: Integer;
begin
  Start := CurrentMark;
  StartIsIdentifier := FToken.Kind = tkIdentifier;
  StartIsAsync := StartIsIdentifier and (FToken.Word = jwAsync);
  if StartIsIdentifier and (FToken.Word = jwYield) and FInGenerator and not FToken.Escaped then
    Exit(ParseYield(NoIn));
  { async arrow functions: async x => ..., async (x) => ... }
  if IsContextual(jwAsync) and AsyncArrowParameterFollows then
    Exit(ParseAsyncArrowWithIdentifier(Start));
  ReferenceMark := FScope.ReferenceCount;
  ChildMark := FScope.ChildCount;
  NodeMark := FArena.NodeCount;
  OuterScope := FScope;
  Left := ParseConditional(NoIn);
  if FToken.Kind = tkArrow then
  begin
    if (Left.Kind = nkIdentifier) and StartIsIdentifier and (Left.Flags and NodeFlagParenthesized = 0) then
      Exit(ParseArrowFunction(Left, False, Start, ReferenceMark, ChildMark, NodeMark, OuterScope));
    if ((Left.Flags and NodeFlagParenthesized) <> 0) or ((Left.Flags and ArrowParametersFlag) <> 0) then
      Exit(ParseArrowFunction(Left, False, Start, ReferenceMark, ChildMark, NodeMark, OuterScope));
    if (Left.Kind = nkCall) and (Left.A.Kind = nkIdentifier) and (Left.A.Text = 'async') and StartIsAsync then
    begin
      Arguments := NewNode(nkSequence);
      for Index := 0 to Left.Count - 1 do
        Arguments.Add(Left.List[Index]);
      Exit(ParseArrowFunction(Arguments, True, Start, ReferenceMark, ChildMark, NodeMark, OuterScope));
    end;
    Unexpected;
  end;
  if (Left.Flags and ArrowParametersFlag) <> 0 then
    Unexpected;
  if FToken.Kind in [tkAssign..tkQuestionQuestionAssign] then
    Exit(ParseAssignmentOperator(Left, Start, NoIn));
  Result := Left;
end;

{ Left, then an assignment operator (the current token). }
function TJsParser.ParseAssignmentOperator(Left: TJsNode; const Start: TJsSourceMark; NoIn: Boolean): TJsNode;
var
  Op: TJsTokenKind;
begin
  Op := FToken.Kind;
  if Op = tkAssign then
  begin
    if Left.Kind in [nkArray, nkObject] then
      Left := ToPattern(Left, False)
    else if not IsSimpleAssignmentTarget(Left) then
      Fail('Invalid left-hand side in assignment');
  end
  else if not IsSimpleAssignmentTarget(Left) or (Left.Kind = nkCall) and
    (Op in [tkAndAndAssign, tkOrOrAssign, tkQuestionQuestionAssign]) then
    Fail('Invalid left-hand side in assignment');
  Next;
  Result := NewNodeAtMark(nkAssign, Start);
  Result.Op := Op;
  Result.A := Left;
  Result.B := ParseAssignment(NoIn);
end;

function TJsParser.ParseConditional(NoIn: Boolean): TJsNode;
var
  Node: TJsNode;
begin
  Result := ParseBinary(0, NoIn);
  if FToken.Kind = tkQuestion then
  begin
    Node := NewNode(nkConditional);
    Node.Line := Result.Line;
    Node.Column := Result.Column;
    Next;
    Node.A := Result;
    Node.B := ParseAssignment(False);
    Expect(tkColon);
    Node.C := ParseAssignment(NoIn);
    Result := Node;
  end;
end;

function BinaryPrecedence(Kind: TJsTokenKind; NoIn: Boolean): Integer;
begin
  case Kind of
    tkQuestionQuestion: Result := 1;
    tkOrOr: Result := 2;
    tkAndAnd: Result := 3;
    tkBar: Result := 4;
    tkCaret: Result := 5;
    tkAmpersand: Result := 6;
    tkEqual, tkNotEqual, tkStrictEqual, tkStrictNotEqual: Result := 7;
    tkLess, tkGreater, tkLessEqual, tkGreaterEqual, tkInstanceof: Result := 8;
    tkIn:
      if NoIn then
        Result := 0
      else
        Result := 8;
    tkShiftLeft, tkShiftRight, tkShiftRightUnsigned: Result := 9;
    tkPlus, tkMinus: Result := 10;
    tkStar, tkSlash, tkPercent: Result := 11;
    tkStarStar: Result := 12;
  else
    Result := 0;
  end;
end;

{ #name in object }
function TJsParser.ParsePrivateIn(NoIn: Boolean): TJsNode;
var
  StartToken: TJsToken;
  PrivateName: UnicodeString;
begin
  StartToken := FToken;
  PrivateName := '#' + FLexer.Names[FToken.Name];
  Next;
  Next;
  Result := NewNodeAt(nkPrivateIn, StartToken);
  Result.A := NewIdentifier(PrivateName, StartToken);
  Result.B := ParseBinary(9, NoIn);
end;

function TJsParser.ParseBinary(MinimumPrecedence: Integer; NoIn: Boolean): TJsNode;
var
  Precedence: Integer;
  Op: TJsTokenKind;
  Right, Node: TJsNode;
  StartToken: TJsSourceMark;
begin
  StartToken := CurrentMark;
  if (FToken.Kind = tkPrivateName) and (PeekToken.Kind = tkIn) then
    Result := ParsePrivateIn(NoIn)
  else
    Result := ParseUnary;
  while True do
  begin
    Op := FToken.Kind;
    Precedence := BinaryPrecedence(Op, NoIn);
    if (Precedence = 0) or (Precedence <= MinimumPrecedence) then
      Break;
    if (Op = tkStarStar) and (Result.Kind = nkUnary) and ((Result.Flags and NodeFlagParenthesized) = 0) then
      Fail('Unary operator used immediately before exponentiation expression');
    Next;
    if Op = tkStarStar then
      Right := ParseBinary(Precedence - 1, NoIn)
    else
      Right := ParseBinary(Precedence, NoIn);
    if Op in [tkAndAnd, tkOrOr, tkQuestionQuestion] then
    begin
      { ?? does not mix with && or || unparenthesised. }
      if (Op = tkQuestionQuestion) and ((((Result.Kind = nkLogical) and (Result.Op <> tkQuestionQuestion))
        and ((Result.Flags and NodeFlagParenthesized) = 0)) or ((Right.Kind = nkLogical) and
        (Right.Op <> tkQuestionQuestion) and ((Right.Flags and NodeFlagParenthesized) = 0))) then
        Fail('Unexpected token ''??''');
      if (Op <> tkQuestionQuestion) and (((Result.Kind = nkLogical) and (Result.Op = tkQuestionQuestion)
        and ((Result.Flags and NodeFlagParenthesized) = 0)) or ((Right.Kind = nkLogical) and
        (Right.Op = tkQuestionQuestion) and ((Right.Flags and NodeFlagParenthesized) = 0))) then
        Fail('Unexpected token');
      Node := NewNodeAtMark(nkLogical, StartToken);
    end
    else
      Node := NewNodeAtMark(nkBinary, StartToken);
    Node.Op := Op;
    Node.A := Result;
    Node.B := Right;
    Result := Node;
  end;
end;

{ The depth is counted without an exception frame: after a syntax
  error the parser is not used again. }
function TJsParser.ParseUnary: TJsNode;
begin
  Enter;
  Result := ParseUnaryAtDepth;
  Leave;
end;

function TJsParser.ParseUnaryAtDepth: TJsNode;
var
  StartToken: TJsSourceMark;
  Op: TJsTokenKind;
begin
  StartToken := CurrentMark;
  case FToken.Kind of
    tkBang, tkTilde, tkPlus, tkMinus, tkTypeof, tkVoid, tkDelete:
      begin
        Op := FToken.Kind;
        Next;
        Result := NewNodeAtMark(nkUnary, StartToken);
        Result.Op := Op;
        Result.A := ParseUnary();
        if (Op = tkDelete) and FStrict and (Result.A.Kind = nkIdentifier) then
          Fail('Delete of an unqualified identifier in strict mode.');
        if (Op = tkDelete) and (Result.A.Kind = nkMember) and ((Result.A.Flags and MemberFlagPrivate) <> 0) then
          Fail('Private fields can not be deleted');
      end;
    tkPlusPlus, tkMinusMinus:
      begin
        Op := FToken.Kind;
        Next;
        Result := NewNodeAtMark(nkUpdate, StartToken);
        Result.Op := Op;
        Result.Flags := UpdateFlagPrefix;
        Result.A := ParseUnary();
        if not IsSimpleAssignmentTarget(Result.A) then
          Fail('Invalid left-hand side expression in prefix operation');
      end;
  else
    { A class field's initializer is not async (FInAsync is off in
      it): await there can only be in an async arrow inside it, where
      it is that arrow's. }
    if IsContextual(jwAwait) and FInAsync then
    begin
      if FFunction.Kind = fkModule then
        FFunction.IsAsync := True;
      Next;
      Result := NewNodeAtMark(nkAwait, StartToken);
      Result.A := ParseUnary();
    end
    else
      Result := ParseUpdate;
  end;
end;

function TJsParser.ParseUpdate: TJsNode;
var
  Node: TJsNode;
begin
  Result := ParseLeftHandSide;
  if (FToken.Kind in [tkPlusPlus, tkMinusMinus]) and not FToken.NewlineBefore then
  begin
    if not IsSimpleAssignmentTarget(Result) then
      Fail('Invalid left-hand side expression in postfix operation');
    Node := NewNode(nkUpdate);
    Node.Line := Result.Line;
    Node.Column := Result.Column;
    Node.Op := FToken.Kind;
    Node.A := Result;
    Next;
    Result := Node;
  end;
end;

function TJsParser.ParseArguments(Call: TJsNode): TJsNode;
var
  Spread: TJsNode;
begin
  Expect(tkLeftParen);
  while FToken.Kind <> tkRightParen do
  begin
    if FToken.Kind = tkEllipsis then
    begin
      Spread := NewNode(nkSpread);
      Next;
      Spread.A := ParseAssignment;
      Call.Add(Spread);
    end
    else
      Call.Add(ParseAssignment);
    if FToken.Kind <> tkRightParen then
      Expect(tkComma);
  end;
  Next;
  Result := Call;
end;

function TJsParser.ParseNew: TJsNode;
var
  StartToken: TJsToken;
  Callee: TJsNode;
begin
  StartToken := FToken;
  Expect(tkNew);
  if FToken.Kind = tkDot then
  begin
    Next;
    if not IsContextual(jwTarget) then
      Unexpected;
    if FFunction.Kind = fkScript then
    begin
      { new.target outside of functions is only valid in arrow chains
        inside functions; checked when resolving. }
    end;
    Next;
    Result := NewNodeAt(nkNewTarget, StartToken);
    FScope.AddReference(Result);
    Exit;
  end;
  if FToken.Kind = tkNew then
    Callee := ParseNew()
  else
  begin
    if FToken.Kind = tkImport then
      Fail('Cannot use new with import');
    Callee := ParsePrimary;
    Callee := ParseCallTail(Callee, False);
  end;
  Result := NewNodeAt(nkNew, StartToken);
  Result.A := Callee;
  if FToken.Kind = tkLeftParen then
    ParseArguments(Result);
end;

function TJsParser.ParseLeftHandSide: TJsNode;
var
  StartToken: TJsSourceMark;
begin
  StartToken := CurrentMark;
  if FToken.Kind = tkNew then
    Result := ParseNew
  else if FToken.Kind = tkSuper then
  begin
    Next;
    if FToken.Kind = tkLeftParen then
    begin
      Result := NewNodeAtMark(nkSuperCall, StartToken);
      ParseArguments(Result);
    end
    else if Accept(tkDot) then
    begin
      Result := NewNodeAtMark(nkSuperMember, StartToken);
      TakeIdentifierName(Result.Text);
    end
    else if Accept(tkLeftBracket) then
    begin
      Result := NewNodeAtMark(nkSuperMember, StartToken);
      Result.A := ParseExpression;
      Expect(tkRightBracket);
    end
    else
    begin
      Unexpected;
      Result := nil;
    end;
    FFunction.UsesSuper := True;
    FScope.AddReference(Result);
  end
  else if (FToken.Kind = tkImport) then
  begin
    Next;
    if Accept(tkDot) then
    begin
      if not IsContextual(jwMeta) then
        Unexpected;
      if not ModuleGoal then
        Fail('Cannot use ''import.meta'' outside a module');
      Next;
      Result := NewNodeAtMark(nkImportMeta, StartToken);
      Result := ParseCallTail(Result, True);
      Exit;
    end;
    Result := NewNodeAtMark(nkDynamicImport, StartToken);
    Expect(tkLeftParen);
    Result.A := ParseAssignment;
    if Accept(tkComma) and (FToken.Kind <> tkRightParen) then
    begin
      Result.B := ParseAssignment;
      Accept(tkComma);
    end;
    Expect(tkRightParen);
  end
  else
    Result := ParsePrimary;
  Result := ParseCallTail(Result, True);
end;

procedure TJsParser.ParseMemberName(Member: TJsNode);
var
  NameToken: TJsToken;
  Name: UnicodeString;
begin
  if FToken.Kind = tkPrivateName then
  begin
    NameToken := FToken;
    Name := '#' + FLexer.Names[FToken.Name];
    Next;
    Member.Flags := Member.Flags or MemberFlagPrivate;
    Member.B := NewIdentifier(Name, NameToken);
    Member.Text := Name;
  end
  else
    TakeIdentifierName(Member.Text);
end;

function TJsParser.ParseCallTail(Node: TJsNode; AllowCall: Boolean): TJsNode;
var
  Member, Call, Chain: TJsNode;
  InOptionalChain: Boolean;
  StartLine, StartColumn: Integer;
begin
  Result := Node;
  InOptionalChain := False;
  StartLine := Node.Line;
  StartColumn := Node.Column;
  while True do
  begin
    case FToken.Kind of
      tkDot:
        begin
          Next;
          Member := FArena.NewNode(nkMember, StartLine, StartColumn);
          Member.A := Result;
          ParseMemberName(Member);
          Result := Member;
        end;
      tkQuestionDot:
        begin
          if not AllowCall then
            Fail('Invalid optional chain from new expression');
          Next;
          InOptionalChain := True;
          if FToken.Kind = tkLeftParen then
          begin
            Call := FArena.NewNode(nkCall, StartLine, StartColumn);
            Call.A := Result;
            Call.Flags := MemberFlagOptional;
            ParseArguments(Call);
            Result := Call;
          end
          else if Accept(tkLeftBracket) then
          begin
            Member := FArena.NewNode(nkMember, StartLine, StartColumn);
            Member.A := Result;
            Member.B := ParseExpression;
            Member.Flags := MemberFlagComputed or MemberFlagOptional;
            Expect(tkRightBracket);
            Result := Member;
          end
          else if FToken.Kind = tkTemplate then
            Fail('Invalid tagged template on optional chain')
          else
          begin
            Member := FArena.NewNode(nkMember, StartLine, StartColumn);
            Member.A := Result;
            Member.Flags := MemberFlagOptional;
            ParseMemberName(Member);
            Result := Member;
          end;
        end;
      tkLeftBracket:
        begin
          Next;
          Member := FArena.NewNode(nkMember, StartLine, StartColumn);
          Member.A := Result;
          Member.B := ParseExpression;
          Member.Flags := MemberFlagComputed;
          Expect(tkRightBracket);
          Result := Member;
        end;
      tkLeftParen:
        begin
          if not AllowCall then
            Break;
          Call := FArena.NewNode(nkCall, StartLine, StartColumn);
          Call.A := Result;
          if (Result.Kind = nkIdentifier) and (Result.Text = 'eval') and not InOptionalChain then
          begin
            { A direct eval (when eval is the intrinsic at run time). }
            Call.Flags := Call.Flags or CallFlagDirectEval;
            Call.Scope := FScope;
            FScope.AddReference(Call);
            FFunction.ContainsDirectEval := True;
          end;
          ParseArguments(Call);
          Result := Call;
        end;
      tkTemplate:
        begin
          if InOptionalChain then
            Fail('Invalid tagged template on optional chain');
          Call := FArena.NewNode(nkTaggedTemplate, StartLine, StartColumn);
          Call.A := Result;
          Call.B := ParseTemplate(True);
          Result := Call;
        end;
    else
      Break;
    end;
  end;
  if InOptionalChain then
  begin
    Chain := FArena.NewNode(nkOptionalChain, StartLine, StartColumn);
    Chain.A := Result;
    Result := Chain;
  end;
end;

function TJsParser.ParseTemplate(Tagged: Boolean): TJsNode;
var
  Piece: TJsNode;
begin
  Result := NewNode(nkTemplate);
  while True do
  begin
    if FToken.Kind <> tkTemplate then
      Unexpected;
    if FToken.InvalidEscape and not Tagged then
      Fail('Invalid escape sequence in template');
    Piece := NewNode(nkString);
    FLexer.DecodeTemplate(FToken, Piece.Text, Piece.Name);
    if FToken.InvalidEscape then
      Piece.Flags := 1;
    Result.Add(Piece);
    if FToken.TemplateTail then
    begin
      Next;
      Break;
    end;
    Next;
    Result.Add(ParseExpression);
    if FToken.Kind <> tkRightBrace then
      Unexpected;
    FLexer.ScanTemplate(FToken);
  end;
end;

function TJsParser.ParseArrayLiteral: TJsNode;
var
  Spread: TJsNode;
begin
  Result := NewNode(nkArray);
  Next;
  while FToken.Kind <> tkRightBracket do
  begin
    if FToken.Kind = tkComma then
    begin
      Result.Add(NewNode(nkHole));
      Next;
      Continue;
    end;
    if FToken.Kind = tkEllipsis then
    begin
      Spread := NewNode(nkSpread);
      Next;
      Spread.A := ParseAssignment;
      Result.Add(Spread);
    end
    else
      Result.Add(ParseAssignment);
    if FToken.Kind <> tkRightBracket then
      Expect(tkComma);
  end;
  Next;
end;

function TJsParser.ParseObjectLiteral: TJsNode;
var
  Property_: TJsNode;
  StartToken, Peeked: TJsToken;
  Computed, IsAsync, IsGenerator: Boolean;
  KeyName: UnicodeString;
  Kind: TJsFunctionKind;
  FunctionNode, Value: TJsNode;
  HasProto: Boolean;
begin
  Result := NewNode(nkObject);
  Next;
  HasProto := False;
  while FToken.Kind <> tkRightBrace do
  begin
    StartToken := FToken;
    Property_ := NewNode(nkProperty);
    if FToken.Kind = tkEllipsis then
    begin
      Next;
      Property_.Flags := PropertyFlagSpread;
      Property_.A := ParseAssignment;
      Result.Add(Property_);
      if FToken.Kind <> tkRightBrace then
        Expect(tkComma);
      Continue;
    end;
    IsAsync := False;
    IsGenerator := False;
    Kind := fkMethod;
    if IsContextual(jwAsync) then
    begin
      Peeked := PeekToken;
      if not (Peeked.Kind in [tkLeftParen, tkColon, tkComma, tkRightBrace, tkAssign]) and not Peeked.NewlineBefore then
      begin
        Next;
        IsAsync := True;
      end;
    end;
    if FToken.Kind = tkStar then
    begin
      Next;
      IsGenerator := True;
    end;
    if (IsContextual(jwGet) or IsContextual(jwSet)) and not IsAsync and not IsGenerator then
    begin
      Peeked := PeekToken;
      if not (Peeked.Kind in [tkLeftParen, tkColon, tkComma, tkRightBrace, tkAssign]) then
      begin
        if FToken.Word = jwGet then
        begin
          Kind := fkGetter;
          Property_.Flags := PropertyFlagGetter;
        end
        else
        begin
          Kind := fkSetter;
          Property_.Flags := PropertyFlagSetter;
        end;
        Next;
      end;
    end;
    Property_.A := ParsePropertyKey(Computed, KeyName);
    if Property_.A.Kind = nkPrivateName then
      Unexpected;
    if Computed then
      Property_.Flags := Property_.Flags or PropertyFlagComputed;
    if FToken.Kind = tkLeftParen then
    begin
      Property_.Flags := Property_.Flags or PropertyFlagMethod;
      FunctionNode := NewNodeAt(nkFunction, StartToken);
      FunctionNode.Func := ParseFunction(Kind, IsAsync, IsGenerator, KeyName, StartToken);
      Property_.B := FunctionNode;
    end
    else if (Kind <> fkMethod) or IsAsync or IsGenerator then
      Unexpected
    else if Accept(tkColon) then
    begin
      Property_.B := ParseAssignment;
      if (not Computed) and (KeyName = '__proto__') then
      begin
        if HasProto then
          Fail('Duplicate __proto__ fields are not allowed in object literals');
        HasProto := True;
        Property_.Flags := Property_.Flags or PropertyFlagProto;
      end;
    end
    else
    begin
      { Shorthand (name) or the cover form (name = value). }
      if (StartToken.Kind <> tkIdentifier) or Computed then
        Unexpected;
      if ((KeyName = 'yield') and (FInGenerator or FStrict)) or ((KeyName = 'await') and FInAsync) then
        Unexpected;
      Value := NewIdentifierAt(StartToken.Name, StartToken);
      Property_.Flags := Property_.Flags or PropertyFlagShorthand;
      if FToken.Kind = tkAssign then
      begin
        Next;
        Property_.B := NewNodeAt(nkAssign, StartToken);
        Property_.B.Op := tkAssign;
        Property_.B.A := Value;
        Property_.B.B := ParseAssignment;
      end
      else
        Property_.B := Value;
    end;
    Result.Add(Property_);
    if FToken.Kind <> tkRightBrace then
      Expect(tkComma);
  end;
  Next;
end;

function TJsParser.ParseParenthesized: TJsNode;
var
  StartToken: TJsToken;
  Sequence, Rest: TJsNode;
  SavedStart: Integer;
begin
  StartToken := FToken;
  Expect(tkLeftParen);
  if FToken.Kind = tkRightParen then
  begin
    Next;
    if FToken.Kind <> tkArrow then
      Unexpected;
    Result := NewNodeAt(nkSequence, StartToken);
    Result.Flags := ArrowParametersFlag;
    Exit;
  end;
  Sequence := NewNodeAt(nkSequence, StartToken);
  FFunctionInParentheses := FToken.Kind = tkFunction;
  while True do
  begin
    if FToken.Kind = tkEllipsis then
    begin
      Rest := NewNode(nkRest);
      Next;
      { Declared when the arrow is made, in its scope. }
      FNoDeclare := True;
      Rest.A := ParseBindingTarget(dkParameter);
      FNoDeclare := False;
      Sequence.Add(Rest);
      Expect(tkRightParen);
      if FToken.Kind <> tkArrow then
        Unexpected;
      Sequence.Flags := ArrowParametersFlag;
      Exit(Sequence);
    end;
    if Sequence.Count = 0 then
    begin
      SavedStart := FParenthesizedStart;
      FParenthesizedStart := FToken.Start;
      Sequence.Add(ParseAssignment);
      FParenthesizedStart := SavedStart;
    end
    else
      Sequence.Add(ParseAssignment);
    if FToken.Kind = tkComma then
    begin
      Next;
      if FToken.Kind = tkRightParen then
      begin
        { (a, b,) => only as arrow parameters. }
        Next;
        if FToken.Kind <> tkArrow then
          Unexpected;
        Sequence.Flags := ArrowParametersFlag;
        Exit(Sequence);
      end;
      Continue;
    end;
    Break;
  end;
  Expect(tkRightParen);
  if Sequence.Count = 1 then
    Result := Sequence.List[0]
  else
    Result := Sequence;
  Result.Flags := Result.Flags or NodeFlagParenthesized;
end;

function TJsParser.ParsePrimary: TJsNode;
var
  StartToken, Peeked: TJsToken;
begin
  StartToken := FToken;
  case FToken.Kind of
    tkIdentifier:
      begin
        if IsContextual(jwAsync) then
        begin
          Peeked := PeekToken;
          if (Peeked.Kind = tkFunction) and not Peeked.NewlineBefore then
            Exit(ParseAsyncFunctionExpression(StartToken));
        end;
        Result := ParseIdentifierReference;
      end;
    tkNumber:
      begin
        if FToken.LegacyOctal and FStrict then
          Fail('Octal literals are not allowed in strict mode.');
        Result := NewNode(nkNumber);
        Result.Number := FToken.Number;
        Next;
      end;
    tkBigInt:
      begin
        Result := NewNode(nkBigInt);
        FLexer.DecodeBigInt(FToken, Result.Text);
        Result.Number := FToken.Number;
        Next;
      end;
    tkString:
      begin
        if FToken.LegacyOctal and FStrict then
          Fail('Octal escape sequences are not allowed in strict mode.');
        Result := NewNode(nkString);
        FLexer.DecodeString(FToken, Result.Text);
        Next;
      end;
    tkTemplate:
      Result := ParseTemplate(False);
    tkSlash, tkSlashAssign:
      begin
        FLexer.ScanRegExp(FToken);
        Result := NewNode(nkRegExp);
        FLexer.DecodeRegExp(FToken, Result.Text, Result.Name);
        CheckRegExpLiteral(Result.Text, Result.Name);
        Next;
      end;
    tkThis:
      begin
        Result := NewNode(nkThis);
        FScope.AddReference(Result);
        Next;
      end;
    tkNull:
      begin
        Result := NewNode(nkNull);
        Next;
      end;
    tkTrue:
      begin
        Result := NewNode(nkTrue);
        Next;
      end;
    tkFalse:
      begin
        Result := NewNode(nkFalse);
        Next;
      end;
    tkLeftBracket:
      Result := ParseArrayLiteral;
    tkLeftBrace:
      Result := ParseObjectLiteral;
    tkLeftParen:
      Result := ParseParenthesized;
    tkFunction:
      Result := ParseFunctionExpression(StartToken);
    tkClass:
      Result := ParseClass(True, StartToken);
    tkNew:
      Result := ParseNew;
  else
    Unexpected;
    Result := nil;
  end;
end;

{ An identifier as an expression (the current token). }
function TJsParser.ParseIdentifierReference: TJsNode;
var
  StartToken: TJsToken;
begin
  if not IsIdentifierToken then
  begin
    if (FToken.Word = jwLet) and not FStrict then
    else if (FToken.Word = jwYield) and not FInGenerator and not FStrict then
    else if (FToken.Word = jwAwait) and not FInAsync then
    else if (FToken.Word = jwStatic) and not FStrict then
    else
      Unexpected;
  end;
  StartToken := FToken;
  Next;
  Result := NewIdentifierAt(StartToken.Name, StartToken);
end;

{ function [*] [name] (parameters) body as an expression, from function
  (StartToken, a copy: the current token moves on). }
function TJsParser.ParseFunctionExpression(const StartToken: TJsToken): TJsNode;
var
  Name: UnicodeString;
  InParentheses, IsGenerator: Boolean;
begin
  InParentheses := FFunctionInParentheses;
  FFunctionInParentheses := False;
  Next;
  Result := NewNodeAt(nkFunction, StartToken);
  FNextFunctionInParentheses := InParentheses;
  IsGenerator := Accept(tkStar);
  Name := '';
  if FToken.Kind = tkIdentifier then
  begin
    if IsGenerator and (FToken.Word = jwYield) then
      Unexpected;
    Name := BindingIdentifierName;
  end;
  Result.Func := ParseFunction(fkNormal, False, IsGenerator, Name, StartToken);
  Result.Func.IsExpression := True;
  NameFunctionExpression(Result.Func);
end;

{ async function [*] [name] (parameters) body as an expression, from async
  (StartToken, a copy). }
function TJsParser.ParseAsyncFunctionExpression(const StartToken: TJsToken): TJsNode;
var
  Name: UnicodeString;
  IsGenerator: Boolean;
begin
  Next;
  Next;
  Result := NewNodeAt(nkFunction, StartToken);
  IsGenerator := Accept(tkStar);
  Name := '';
  if IsGenerator then
  begin
    if IsIdentifierToken or (FToken.Kind = tkIdentifier) and (FToken.Word = jwYield) then
      Name := BindingIdentifierName;
  end
  else if FToken.Kind = tkIdentifier then
  begin
    if FToken.Word = jwAwait then
      Unexpected;
    Name := BindingIdentifierName;
  end;
  Result.Func := ParseFunction(fkNormal, True, IsGenerator, Name, StartToken);
  Result.Func.IsExpression := True;
  NameFunctionExpression(Result.Func);
end;

end.
