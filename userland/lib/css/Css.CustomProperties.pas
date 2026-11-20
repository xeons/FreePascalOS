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
  Custom properties (CSS Custom Properties for Cascading Variables
  Level 1 and 2): the computed set an element has, and var() and env()
  substitution.

  A set is immutable and reference counted; an element that declares no
  custom property shares its parent's set. Values are token lists
  (substituted already: a set never holds a var()).
}
unit Css.CustomProperties;

{$mode objfpc}
{$H+}

interface

uses
  Css.Atoms, Css.Tokens;

type
  TCssCustomProperties = class
  private
    FReferences: LongInt;
    FNames: array of TCssAtom;
    FValues: array of TCssTokenArray;
    FCount: Integer;
    function Search(Name: TCssAtom; out Index: Integer): Boolean;
  public
    constructor Create;
    function AddRef: TCssCustomProperties;
    procedure Release;
    { A modifiable copy (for building a child's set). }
    function Clone: TCssCustomProperties;
    function Find(Name: TCssAtom; out Tokens: TCssTokenArray): Boolean;
    procedure Put(Name: TCssAtom; const Tokens: TCssTokenArray);
    procedure Remove(Name: TCssAtom);
    function Count: Integer;
    function NameAt(Index: Integer): TCssAtom;
    function ValueAt(Index: Integer): TCssTokenArray;
    function Equals(Other: TCssCustomProperties): Boolean; reintroduce;
    function Bytes: PtrUInt;
  end;

  { Finds the value of a custom property while substituting; False if
    it has none (or is invalid). The style resolver supplies this to
    resolve an element's own custom properties in dependency order. }
  TCssVariableLookup = function(Name: TCssAtom; out Tokens: TCssTokenArray; Data: Pointer): Boolean;

{ Replaces every var() and env() in Tokens. False when a reference
  cannot be resolved and has no fallback (invalid at computed-value
  time). }
function SubstituteVariables(const Tokens: TCssTokenArray; Lookup: TCssVariableLookup; Data: Pointer;
  out Output: TCssTokenArray): Boolean;
{ The value of env(Name), False for unknown names. Hosts can set them. }
function EnvironmentVariable(const Name: string; out Tokens: TCssTokenArray): Boolean;
procedure SetEnvironmentVariable(const Name, Value: string);
{ Whether a token range has var() or env() in it (custom property values). }
function HasVariableReference(const Tokens: TCssTokenArray): Boolean;

implementation

uses
  SysUtils, Css.Tokenizer;

constructor TCssCustomProperties.Create;
begin
  inherited Create;
  FReferences := 1;
end;

function TCssCustomProperties.AddRef: TCssCustomProperties;
begin
  if Self <> nil then
    InterlockedIncrement(FReferences);
  Result := Self;
end;

procedure TCssCustomProperties.Release;
begin
  if Self = nil then
    Exit;
  if InterlockedDecrement(FReferences) = 0 then
    Free;
end;

function TCssCustomProperties.Clone: TCssCustomProperties;
var
  Index: Integer;
begin
  Result := TCssCustomProperties.Create;
  if Self = nil then
    Exit;
  SetLength(Result.FNames, FCount);
  SetLength(Result.FValues, FCount);
  for Index := 0 to FCount - 1 do
  begin
    Result.FNames[Index] := FNames[Index];
    Result.FValues[Index] := FValues[Index];
  end;
  Result.FCount := FCount;
end;

function TCssCustomProperties.Search(Name: TCssAtom; out Index: Integer): Boolean;
var
  Low, High, Middle: Integer;
begin
  Low := 0;
  High := FCount - 1;
  while Low <= High do
  begin
    Middle := (Low + High) div 2;
    if FNames[Middle] = Name then
    begin
      Index := Middle;
      Exit(True);
    end;
    if FNames[Middle] < Name then
      Low := Middle + 1
    else
      High := Middle - 1;
  end;
  Index := Low;
  Result := False;
end;

function TCssCustomProperties.Find(Name: TCssAtom; out Tokens: TCssTokenArray): Boolean;
var
  Index: Integer;
begin
  Tokens := nil;
  if Self = nil then
    Exit(False);
  Result := Search(Name, Index);
  if Result then
    Tokens := FValues[Index];
end;

procedure TCssCustomProperties.Put(Name: TCssAtom; const Tokens: TCssTokenArray);
var
  Index, Other: Integer;
begin
  if Search(Name, Index) then
  begin
    FValues[Index] := Tokens;
    Exit;
  end;
  if FCount >= Length(FNames) then
  begin
    SetLength(FNames, FCount * 2 + 4);
    SetLength(FValues, Length(FNames));
  end;
  for Other := FCount downto Index + 1 do
  begin
    FNames[Other] := FNames[Other - 1];
    FValues[Other] := FValues[Other - 1];
  end;
  FNames[Index] := Name;
  FValues[Index] := Tokens;
  Inc(FCount);
end;

procedure TCssCustomProperties.Remove(Name: TCssAtom);
var
  Index, Other: Integer;
begin
  if not Search(Name, Index) then
    Exit;
  for Other := Index to FCount - 2 do
  begin
    FNames[Other] := FNames[Other + 1];
    FValues[Other] := FValues[Other + 1];
  end;
  Dec(FCount);
  FValues[FCount] := nil;
end;

function TCssCustomProperties.Count: Integer;
begin
  if Self = nil then
    Result := 0
  else
    Result := FCount;
end;

function TCssCustomProperties.NameAt(Index: Integer): TCssAtom;
begin
  Result := FNames[Index];
end;

function TCssCustomProperties.ValueAt(Index: Integer): TCssTokenArray;
begin
  Result := FValues[Index];
end;

function SameTokens(const A, B: TCssTokenArray): Boolean;
var
  Index: Integer;
begin
  if Pointer(A) = Pointer(B) then
    Exit(True);
  if Length(A) <> Length(B) then
    Exit(False);
  for Index := 0 to High(A) do
    if (A[Index].Kind <> B[Index].Kind) or (A[Index].Text <> B[Index].Text) or
      (A[Index].Number <> B[Index].Number) then
      Exit(False);
  Result := True;
end;

function TCssCustomProperties.Equals(Other: TCssCustomProperties): Boolean;
var
  Index: Integer;
begin
  if Self = Other then
    Exit(True);
  if Count <> Other.Count then
    Exit(False);
  for Index := 0 to FCount - 1 do
    if (FNames[Index] <> Other.FNames[Index]) or not SameTokens(FValues[Index], Other.FValues[Index]) then
      Exit(False);
  Result := True;
end;

function TCssCustomProperties.Bytes: PtrUInt;
begin
  if Self = nil then
    Exit(0);
  Result := InstanceSize + PtrUInt(Length(FNames)) * (SizeOf(TCssAtom) + SizeOf(Pointer));
end;

{ ---- environment variables ---- }

var
  EnvironmentNames: array of string;
  EnvironmentValues: array of TCssTokenArray;

procedure SetEnvironmentVariable(const Name, Value: string);
var
  Index: Integer;
begin
  for Index := 0 to High(EnvironmentNames) do
    if EnvironmentNames[Index] = Name then
    begin
      EnvironmentValues[Index] := TokenizeCss(Value);
      Exit;
    end;
  SetLength(EnvironmentNames, Length(EnvironmentNames) + 1);
  SetLength(EnvironmentValues, Length(EnvironmentValues) + 1);
  EnvironmentNames[High(EnvironmentNames)] := Name;
  EnvironmentValues[High(EnvironmentValues)] := TokenizeCss(Value);
end;

function EnvironmentVariable(const Name: string; out Tokens: TCssTokenArray): Boolean;
var
  Index: Integer;
begin
  Tokens := nil;
  for Index := 0 to High(EnvironmentNames) do
    if EnvironmentNames[Index] = Name then
    begin
      Tokens := EnvironmentValues[Index];
      Exit(True);
    end;
  Result := False;
end;

function HasVariableReference(const Tokens: TCssTokenArray): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to High(Tokens) do
    if (Tokens[Index].Kind = tkFunction) and (AsciiSameText(Tokens[Index].Text, 'var') or
      AsciiSameText(Tokens[Index].Text, 'env')) then
      Exit(True);
  Result := False;
end;

{ ---- substitution ---- }

type
  TOutput = record
    Tokens: TCssTokenArray;
    Count: Integer;
  end;

procedure Append(var Output: TOutput; const Token: TCssToken);
begin
  if Output.Count >= Length(Output.Tokens) then
    SetLength(Output.Tokens, Output.Count * 2 + 16);
  Output.Tokens[Output.Count] := Token;
  Inc(Output.Count);
end;

{ Appends a token list (without its EOF). }
procedure AppendAll(var Output: TOutput; const Tokens: TCssTokenArray);
var
  Index: Integer;
begin
  for Index := 0 to High(Tokens) do
    if Tokens[Index].Kind <> tkEof then
      Append(Output, Tokens[Index]);
end;

function SubstituteRange(const Tokens: TCssTokenArray; First, Stop: Integer; Lookup: TCssVariableLookup;
  Data: Pointer; var Output: TOutput; Depth: Integer): Boolean; forward;

{ var(--name [, fallback]?) or env(name [, fallback]?) at Index. }
function SubstituteReference(const Tokens: TCssTokenArray; Index: Integer; Lookup: TCssVariableLookup;
  Data: Pointer; var Output: TOutput; Depth: Integer): Boolean;
var
  Position, Stop: Integer;
  IsEnvironment, HasFallback: Boolean;
  Name: string;
  Value: TCssTokenArray;
begin
  Result := False;
  if Depth > 64 then
    Exit;
  IsEnvironment := AsciiSameText(Tokens[Index].Text, 'env');
  Stop := Tokens[Index].Match;
  if (Stop < 0) or (Stop > High(Tokens)) then
    Stop := High(Tokens);
  Position := Index + 1;
  while (Position < Stop) and (Tokens[Position].Kind = tkWhitespace) do
    Inc(Position);
  if (Position >= Stop) or (Tokens[Position].Kind <> tkIdent) then
    Exit;
  Name := Tokens[Position].Text;
  if not IsEnvironment and not ((Length(Name) > 2) and (Name[1] = '-') and (Name[2] = '-')) then
    Exit;
  Inc(Position);
  while (Position < Stop) and (Tokens[Position].Kind = tkWhitespace) do
    Inc(Position);
  HasFallback := False;
  if Position < Stop then
  begin
    if Tokens[Position].Kind <> tkComma then
      Exit;
    HasFallback := True;
    Inc(Position);
  end;
  if IsEnvironment then
  begin
    if EnvironmentVariable(AsciiLowercase(Name), Value) then
    begin
      AppendAll(Output, Value);
      Exit(True);
    end;
  end
  else if Lookup(InternAtom(Name), Value, Data) then
  begin
    AppendAll(Output, Value);
    Exit(True);
  end;
  if HasFallback then
    Result := SubstituteRange(Tokens, Position, Stop, Lookup, Data, Output, Depth + 1);
end;

function SubstituteRange(const Tokens: TCssTokenArray; First, Stop: Integer; Lookup: TCssVariableLookup;
  Data: Pointer; var Output: TOutput; Depth: Integer): Boolean;
var
  Index, Last: Integer;
  Token: PCssToken;
begin
  Result := True;
  Index := First;
  while Index < Stop do
  begin
    Token := @Tokens[Index];
    if Token^.Kind = tkEof then
      Break;
    if (Token^.Kind = tkFunction) and (AsciiSameText(Token^.Text, 'var') or AsciiSameText(Token^.Text, 'env')) then
    begin
      if not SubstituteReference(Tokens, Index, Lookup, Data, Output, Depth) then
        Exit(False);
      Last := Token^.Match;
      if (Last < 0) or (Last >= Stop) then
        Index := Stop
      else
        Index := Last + 1;
      Continue;
    end;
    Append(Output, Token^);
    Inc(Index);
  end;
end;

function SubstituteVariables(const Tokens: TCssTokenArray; Lookup: TCssVariableLookup; Data: Pointer;
  out Output: TCssTokenArray): Boolean;
var
  Buffer: TOutput;
  Eof: TCssToken;
begin
  Output := nil;
  Buffer.Tokens := nil;
  Buffer.Count := 0;
  Result := SubstituteRange(Tokens, 0, Length(Tokens), Lookup, Data, Buffer, 0);
  if not Result then
    Exit;
  Eof := EofToken;
  Append(Buffer, Eof);
  SetLength(Buffer.Tokens, Buffer.Count);
  MatchBlocks(Buffer.Tokens);
  Output := Buffer.Tokens;
end;

procedure SetDefaultEnvironment;
begin
  SetEnvironmentVariable('safe-area-inset-top', '0px');
  SetEnvironmentVariable('safe-area-inset-right', '0px');
  SetEnvironmentVariable('safe-area-inset-bottom', '0px');
  SetEnvironmentVariable('safe-area-inset-left', '0px');
  SetEnvironmentVariable('safe-area-max-inset-top', '0px');
  SetEnvironmentVariable('safe-area-max-inset-right', '0px');
  SetEnvironmentVariable('safe-area-max-inset-bottom', '0px');
  SetEnvironmentVariable('safe-area-max-inset-left', '0px');
  SetEnvironmentVariable('titlebar-area-x', '0px');
  SetEnvironmentVariable('titlebar-area-y', '0px');
  SetEnvironmentVariable('titlebar-area-width', '0px');
  SetEnvironmentVariable('titlebar-area-height', '0px');
  SetEnvironmentVariable('keyboard-inset-top', '0px');
  SetEnvironmentVariable('keyboard-inset-right', '0px');
  SetEnvironmentVariable('keyboard-inset-bottom', '0px');
  SetEnvironmentVariable('keyboard-inset-left', '0px');
  SetEnvironmentVariable('keyboard-inset-width', '0px');
  SetEnvironmentVariable('keyboard-inset-height', '0px');
  SetEnvironmentVariable('scrollbar-inline-size', '0px');
end;

initialization
  SetDefaultEnvironment;
end.
