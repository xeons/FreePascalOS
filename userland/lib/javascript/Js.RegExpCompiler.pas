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
  Regular expressions: pattern text to a program for the backtracking
  matcher (Js.RegExpMatcher).

  The ECMAScript pattern grammar with its Annex B leniency when the u
  (or v) flag is off: alternatives, quantifiers (greedy and lazy,
  counted), groups (capturing, named, non-capturing), back references
  by number and name, character classes with ranges and the class
  escapes, \p for general categories, assertions (^ $ \b \B),
  lookahead and lookbehind. A lookbehind's body is compiled to match
  backwards: its terms in reverse order, each reading the character
  before the position.

  The program is an array of words: an instruction and its operands.
  Counted repetition keeps a counter per quantifier; the body of a loop
  that matched the empty string ends the loop (no endless loops).
}
unit Js.RegExpCompiler;

{$mode objfpc}{$H+}

interface

uses
  SysUtils;

const
  RxChar = 1;            { direction, code }
  RxAny = 2;             { direction }
  RxClass = 3;           { direction, class index }
  RxLineStart = 4;
  RxLineEnd = 5;
  RxWordBoundary = 6;    { negated }
  RxSplit = 7;           { first, second }
  RxJump = 8;            { target }
  RxSave = 9;            { slot }
  RxResetCaptures = 10;  { first group, last group }
  RxBackReference = 11;  { direction, group }
  RxLook = 12;           { kind (0 ahead, 1 not ahead, 2 behind, 3 not behind), end }
  RxRepeatStart = 13;    { counter }
  RxRepeatLoop = 14;     { counter, minimum, maximum (-1 none), greedy, exit }
  RxRepeatEnd = 15;      { counter, position register, loop head }
  RxMatch = 16;
  RxSavePosition = 17;   { position register }
  RxNamedBackReference = 18; { direction, first group, last group }

  ForwardDirection = 0;
  BackwardDirection = 1;

type
  TRxRange = record
    First: LongWord;
    Last: LongWord;
  end;

  { A Unicode property test (\p): a general category set. }
  TRxProperty = record
    Categories: LongWord;
    Negated: Boolean;
  end;

  TRxClass = class
  public
    Ranges: array of TRxRange;
    Properties: array of TRxProperty;
    Negated: Boolean;
    procedure AddRange(First, Last: LongWord);
    procedure AddClass(Other: TRxClass);
    procedure AddProperty(Categories: LongWord; Negated_: Boolean);
    procedure Normalize;
    function Contains(Code: LongWord): Boolean;
  end;

  TRxGroupName = record
    Name: UnicodeString;
    Group: Integer;
  end;

  TRxProgram = class
  public
    Code: array of LongInt;
    Classes: array of TRxClass;
    GroupCount: Integer;
    GroupNames: array of TRxGroupName;
    CounterCount: Integer;
    PositionRegisterCount: Integer;
    IgnoreCase: Boolean;
    Multiline: Boolean;
    DotAll: Boolean;
    Unicode: Boolean;
    destructor Destroy; override;
    { The group of a name (several groups may share a name in
      different alternatives): -1 when none. }
    function GroupOf(const Name: UnicodeString): Integer;
  end;

  ERegExpSyntax = class(Exception);

{ Compiles the pattern; raises ERegExpSyntax for a bad pattern. }
function CompileRegExp(const Pattern: UnicodeString; IgnoreCase, Multiline, DotAll, Unicode: Boolean): TRxProgram;

{ Case mapping for case-insensitive matching. }
function CanonicalizeCase(Code: LongWord; Unicode: Boolean): LongWord;
function IsRxWordCharacter(Code: LongWord; IgnoreCase, Unicode: Boolean): Boolean;
function CategoryMask(Code: LongWord): LongWord;

implementation

uses
  Character,
  Js.CaseMapping;

const
  { Scripts by their blocks (an approximation of the Script property:
    the characters of a block shared with other scripts count for the
    block's script). Names and aliases, then the ranges. }
  ScriptTable: array[0..37] of string = (
    'Latin Latn:0041-005A,0061-007A,00AA,00BA,00C0-00D6,00D8-00F6,00F8-02B8,02E0-02E4,1D00-1D25,1D2C-1D5C,' +
      '1D62-1D65,1D6B-1D77,1D79-1DBE,1E00-1EFF,2071,207F,2090-209C,212A,212B,2132,214E,2160-2188,2C60-2C7F,' +
      'A722-A787,A78B-A7FF,AB30-AB5A,AB5C-AB64,FB00-FB06,FF21-FF3A,FF41-FF5A',
    'Greek Grek:0370-0373,0375-0377,037A-037D,037F,0384,0386,0388-03E1,03F0-03FF,1D26-1D2A,1D5D-1D61,1D66-1D6A,' +
      '1DBF,1F00-1FFE,2126,AB65',
    'Cyrillic Cyrl:0400-0484,0487-052F,1C80-1C88,1D2B,1D78,2DE0-2DFF,A640-A69F,FE2E,FE2F',
    'Armenian Armn:0531-0556,0559-058A,058D-058F,FB13-FB17',
    'Hebrew Hebr:0591-05C7,05D0-05EA,05EF-05F4,FB1D-FB4F',
    'Arabic Arab:0600-0604,0606-060B,060D-061A,061C-061E,0620-063F,0641-064A,0656-066F,0671-06DC,06DE-06FF,' +
      '0750-077F,0870-089F,08A0-08FF,FB50-FDFF,FE70-FEFC',
    'Syriac Syrc:0700-074F,0860-086A',
    'Thaana Thaa:0780-07B1',
    'Devanagari Deva:0900-0950,0955-0963,0966-097F,A8E0-A8FF',
    'Bengali Beng:0980-09FE',
    'Gurmukhi Guru:0A01-0A76',
    'Gujarati Gujr:0A81-0AFF',
    'Oriya Orya:0B01-0B77',
    'Tamil Taml:0B82-0BFA,11FC0-11FFF',
    'Telugu Telu:0C00-0C7F',
    'Kannada Knda:0C80-0CF3',
    'Malayalam Mlym:0D00-0D7F',
    'Sinhala Sinh:0D81-0DF4,111E1-111F4',
    'Thai Thai:0E01-0E3A,0E40-0E5B',
    'Lao Laoo:0E81-0EDF',
    'Tibetan Tibt:0F00-0FD4,0FD9,0FDA',
    'Myanmar Mymr:1000-109F,A9E0-A9FE,AA60-AA7F',
    'Georgian Geor:10A0-10FF,1C90-1CBF,2D00-2D2D',
    'Hangul Hang:1100-11FF,302E,302F,3131-318E,3200-321E,3260-327E,A960-A97C,AC00-D7A3,D7B0-D7FB,FFA0-FFDC',
    'Ethiopic Ethi:1200-139F,2D80-2DDE,AB01-AB2E',
    'Cherokee Cher:13A0-13FD,AB70-ABBF',
    'Khmer Khmr:1780-17F9,19E0-19FF',
    'Mongolian Mong:1800-1801,1804,1806-18AA',
    'Hiragana Hira:3041-3096,309D-309F,1B001-1B11F,1F200',
    'Katakana Kana:30A1-30FA,30FD-30FF,31F0-31FF,32D0-32FE,3300-3357,FF66-FF6F,FF71-FF9D,1B000',
    'Bopomofo Bopo:02EA,02EB,3105-312F,31A0-31BF',
    'Han Hani:2E80-2E99,2E9B-2EF3,2F00-2FD5,3005,3007,3021-3029,3038-303B,3400-4DBF,4E00-9FFF,F900-FA6D,' +
      'FA70-FAD9,20000-2A6DF,2A700-2EBE0,2F800-2FA1D,30000-3134A',
    'Yi Yiii:A000-A48C,A490-A4C6',
    'Tifinagh Tfng:2D30-2D67,2D6F,2D70,2D7F',
    'Coptic Copt Qaac:03E2-03EF,2C80-2CF3,2CF9-2CFF',
    'Runic Runr:16A0-16EA,16EE-16F8',
    'Inherited Zinh Qaai:0300-036F,0485,0486,064B-0655,0670,1AB0-1ACE,1CD0-1CD2,1CD4-1CE0,1DC0-1DFF,200C,200D,' +
      '20D0-20F0,FE00-FE0F,FE20-FE2D,E0100-E01EF',
    'Common Zyyy:0000-0040,005B-0060,007B-00A9,00AB-00B9,00BB-00BF,00D7,00F7,02B9-02DF,02E5-02E9,02EC-02FF,0374,' +
      '037E,0385,0387,0605,060C,061B,061F,0640,06DD,0964,0965,0E3F,10FB,16EB-16ED,2000-200B,200E-2064,2066-2070,' +
      '2074-207E,2080-208E,20A0-20C0,2100-2125,2127-2129,212C-2131,2133-214D,214F-215F,2189-218B,2190-2426,' +
      '2440-244A,2460-27FF,2900-2B73,2B76-2B95,2B97-2BFF,2E00-2E5D,3000-3004,3006,3008-3020,3030-3037,303C-303F,' +
      'FE10-FE19,FE30-FE52,FE54-FE66,FE68-FE6B,FEFF,FF01-FF20,FF3B-FF40,FF5B-FF65,FF70,FF9E,FF9F,FFE0-FFE6,' +
      'FFE8-FFEE,FFF9-FFFD,1F000-1F0FF,1F300-1FAFF');

{ Adds the ranges of the script Name (or alias) to Target; False for a
  script the table does not have. }
function AddScriptRanges(Target: TRxClass; const Name: UnicodeString): Boolean;
var
  Index, Colon, Separator: Integer;
  Names, Ranges, Item: string;
  Items: TStringArray;
  Low, High: LongWord;
begin
  for Index := 0 to System.High(ScriptTable) do
  begin
    Colon := Pos(':', ScriptTable[Index]);
    Names := ' ' + Copy(ScriptTable[Index], 1, Colon - 1) + ' ';
    if Pos(' ' + string(Name) + ' ', Names) = 0 then
      Continue;
    Ranges := Copy(ScriptTable[Index], Colon + 1, MaxInt);
    Items := Ranges.Split([',']);
    for Item in Items do
    begin
      Separator := Pos('-', Item);
      if Separator > 0 then
      begin
        Low := StrToInt('$' + Copy(Item, 1, Separator - 1));
        High := StrToInt('$' + Copy(Item, Separator + 1, MaxInt));
      end
      else
      begin
        Low := StrToInt('$' + Item);
        High := Low;
      end;
      Target.AddRange(Low, High);
    end;
    Exit(True);
  end;
  Result := False;
end;

const
  MaximumRepeat = 1000000000;

{ General categories as bits (TUnicodeCategory order). }
function CategoryMask(Code: LongWord): LongWord;
var
  Category: TUnicodeCategory;
begin
  if Code > $FFFF then
  begin
    { Supplementary planes: letters unless private use. }
    if (Code >= $F0000) then
      Exit(LongWord(1) shl Ord(TUnicodeCategory.ucPrivateUse));
    Exit(LongWord(1) shl Ord(TUnicodeCategory.ucOtherLetter));
  end;
  Category := TCharacter.GetUnicodeCategory(WideChar(Code));
  Result := LongWord(1) shl Ord(Category);
end;

function CanonicalizeCase(Code: LongWord; Unicode: Boolean): LongWord;
var
  Mapped: UnicodeString;
begin
  if Code < 128 then
  begin
    if (Code >= Ord('a')) and (Code <= Ord('z')) then
      Exit(Code - 32);
    Exit(Code);
  end;
  if (Code > $FFFF) or IsSurrogateUnit(Code) then
    Exit(Code);
  if Unicode then
  begin
    Mapped := TCharacter.ToUpper(UnicodeString(WideChar(Code)));
    Mapped := TCharacter.ToLower(Mapped);
    if Length(Mapped) = 1 then
      Exit(Ord(Mapped[1]));
    Exit(Code);
  end;
  Mapped := TCharacter.ToUpper(UnicodeString(WideChar(Code)));
  if (Length(Mapped) <> 1) or ((Ord(Mapped[1]) < 128) and (Code >= 128)) then
    Exit(Code);
  Result := Ord(Mapped[1]);
end;

function IsRxWordCharacter(Code: LongWord; IgnoreCase, Unicode: Boolean): Boolean;
begin
  Result := ((Code >= Ord('a')) and (Code <= Ord('z'))) or ((Code >= Ord('A')) and (Code <= Ord('Z'))) or
    ((Code >= Ord('0')) and (Code <= Ord('9'))) or (Code = Ord('_'));
  if not Result and IgnoreCase and Unicode then
    Result := (Code = $017F) or (Code = $212A);
end;

{ TRxClass }

procedure TRxClass.AddRange(First, Last: LongWord);
begin
  SetLength(Ranges, Length(Ranges) + 1);
  Ranges[High(Ranges)].First := First;
  Ranges[High(Ranges)].Last := Last;
end;

procedure TRxClass.AddClass(Other: TRxClass);
var
  Index: Integer;
  Complement: TRxClass;
  Previous: LongWord;
begin
  if Other.Negated then
  begin
    { The complement of the other's ranges. }
    Complement := TRxClass.Create;
    try
      Other.Normalize;
      Previous := 0;
      for Index := 0 to High(Other.Ranges) do
      begin
        if Other.Ranges[Index].First > Previous then
          Complement.AddRange(Previous, Other.Ranges[Index].First - 1);
        Previous := Other.Ranges[Index].Last + 1;
      end;
      if Previous <= $10FFFF then
        Complement.AddRange(Previous, $10FFFF);
      for Index := 0 to High(Complement.Ranges) do
        AddRange(Complement.Ranges[Index].First, Complement.Ranges[Index].Last);
    finally
      Complement.Free;
    end;
  end
  else
    for Index := 0 to High(Other.Ranges) do
      AddRange(Other.Ranges[Index].First, Other.Ranges[Index].Last);
  for Index := 0 to High(Other.Properties) do
    AddProperty(Other.Properties[Index].Categories, Other.Properties[Index].Negated);
end;

procedure TRxClass.AddProperty(Categories: LongWord; Negated_: Boolean);
begin
  SetLength(Properties, Length(Properties) + 1);
  Properties[High(Properties)].Categories := Categories;
  Properties[High(Properties)].Negated := Negated_;
end;

procedure TRxClass.Normalize;
var
  Index, Position, Best: Integer;
  Swap: TRxRange;
  Merged: array of TRxRange;
  Count: Integer;
begin
  for Index := 0 to High(Ranges) do
  begin
    Best := Index;
    for Position := Index + 1 to High(Ranges) do
      if Ranges[Position].First < Ranges[Best].First then
        Best := Position;
    Swap := Ranges[Index];
    Ranges[Index] := Ranges[Best];
    Ranges[Best] := Swap;
  end;
  Merged := nil;
  Count := 0;
  for Index := 0 to High(Ranges) do
  begin
    if (Count > 0) and (Ranges[Index].First <= Merged[Count - 1].Last + 1) then
    begin
      if Ranges[Index].Last > Merged[Count - 1].Last then
        Merged[Count - 1].Last := Ranges[Index].Last;
      Continue;
    end;
    SetLength(Merged, Count + 1);
    Merged[Count] := Ranges[Index];
    Inc(Count);
  end;
  Ranges := Merged;
end;

function TRxClass.Contains(Code: LongWord): Boolean;
var
  Low, High, Middle, Index: Integer;
  Mask: LongWord;
begin
  Result := False;
  Low := 0;
  High := System.High(Ranges);
  while Low <= High do
  begin
    Middle := (Low + High) div 2;
    if Code < Ranges[Middle].First then
      High := Middle - 1
    else if Code > Ranges[Middle].Last then
      Low := Middle + 1
    else
    begin
      Result := True;
      Break;
    end;
  end;
  if not Result and (Length(Properties) > 0) then
  begin
    Mask := CategoryMask(Code);
    for Index := 0 to System.High(Properties) do
      if ((Properties[Index].Categories and Mask) <> 0) <> Properties[Index].Negated then
      begin
        Result := True;
        Break;
      end;
  end;
  if Negated then
    Result := not Result;
end;

{ TRxProgram }

destructor TRxProgram.Destroy;
var
  Index: Integer;
begin
  for Index := 0 to High(Classes) do
    Classes[Index].Free;
  inherited Destroy;
end;

function TRxProgram.GroupOf(const Name: UnicodeString): Integer;
var
  Index: Integer;
begin
  for Index := 0 to High(GroupNames) do
    if GroupNames[Index].Name = Name then
      Exit(GroupNames[Index].Group);
  Result := -1;
end;

{ The compiler }

type
  TNodeKind = (rnEmpty, rnChar, rnAny, rnClass, rnSequence, rnAlternation, rnGroup, rnRepeat, rnLineStart,
    rnLineEnd, rnWordBoundary, rnBackReference, rnNamedBackReference, rnLook);

  TRxNode = class
  public
    Kind: TNodeKind;
    Code: LongWord;
    ClassIndex: Integer;
    Children: array of TRxNode;
    Group: Integer;
    Minimum, Maximum: Integer;
    Greedy: Boolean;
    Negated: Boolean;
    LookKind: Integer;
    Name: UnicodeString;
    FirstGroup, LastGroup: Integer;
    destructor Destroy; override;
    procedure Add(Child: TRxNode);
  end;

  TRxCompiler = class
  private
    FPattern: UnicodeString;
    FPosition: Integer;
    FProgram: TRxProgram;
    FUnicode: Boolean;
    FIgnoreCase: Boolean;
    FGroupCount: Integer;
    FNames: array of UnicodeString;
    FHasNamedGroups: Boolean;
    procedure Fail(const Message: string);
    function AtEnd: Boolean; inline;
    function Peek(Offset: Integer = 0): LongWord;
    function NextCodePoint: LongWord;
    function Accept(Character: WideChar): Boolean;
    procedure ScanGroups;
    function ParseDisjunction: TRxNode;
    function ParseAlternative: TRxNode;
    function ParseTerm: TRxNode;
    function ParseAtom: TRxNode;
    function ParseQuantifier(Atom: TRxNode): TRxNode;
    function ParseClass: TRxNode;
    function ParseClassAtom(Target: TRxClass; out Single: LongWord; out IsSingle: Boolean): Boolean;
    function ParseEscapeCode(InClass: Boolean; out Code: LongWord): Boolean;
    function ClassEscape(Letter: WideChar; Target: TRxClass): Boolean;
    function PropertyEscape(Negated: Boolean; Target: TRxClass): Boolean;
    function ParseGroupName: UnicodeString;
    function ParseDecimal(out Value: Integer): Boolean;
    function AddClass(Target: TRxClass): Integer;
    function GroupsIn(Node: TRxNode; out First, Last: Integer): Boolean;
    procedure Emit(Value: LongInt);
    procedure Generate(Node: TRxNode; Direction: Integer);
  public
    constructor Create(const Pattern: UnicodeString; Target: TRxProgram);
    procedure Compile;
  end;

destructor TRxNode.Destroy;
var
  Index: Integer;
begin
  for Index := 0 to High(Children) do
    Children[Index].Free;
  inherited Destroy;
end;

procedure TRxNode.Add(Child: TRxNode);
begin
  SetLength(Children, Length(Children) + 1);
  Children[High(Children)] := Child;
end;

function NewNode(Kind: TNodeKind): TRxNode;
begin
  Result := TRxNode.Create;
  Result.Kind := Kind;
  Result.ClassIndex := -1;
  Result.Group := -1;
end;

constructor TRxCompiler.Create(const Pattern: UnicodeString; Target: TRxProgram);
begin
  inherited Create;
  FPattern := Pattern;
  FPosition := 1;
  FProgram := Target;
  FUnicode := Target.Unicode;
  FIgnoreCase := Target.IgnoreCase;
end;

procedure TRxCompiler.Fail(const Message: string);
begin
  raise ERegExpSyntax.Create('Invalid regular expression: /' + string(FPattern) + '/: ' + Message);
end;

function TRxCompiler.AtEnd: Boolean;
begin
  Result := FPosition > Length(FPattern);
end;

function TRxCompiler.Peek(Offset: Integer): LongWord;
begin
  if FPosition + Offset <= Length(FPattern) then
    Result := Ord(FPattern[FPosition + Offset])
  else
    Result := $FFFFFFFF;
end;

function TRxCompiler.NextCodePoint: LongWord;
var
  Second: LongWord;
begin
  Result := Ord(FPattern[FPosition]);
  Inc(FPosition);
  if FUnicode and (Result >= $D800) and (Result <= $DBFF) and not AtEnd then
  begin
    Second := Ord(FPattern[FPosition]);
    if (Second >= $DC00) and (Second <= $DFFF) then
    begin
      Result := $10000 + ((Result - $D800) shl 10) + (Second - $DC00);
      Inc(FPosition);
    end;
  end;
end;

function TRxCompiler.Accept(Character: WideChar): Boolean;
begin
  Result := (not AtEnd) and (FPattern[FPosition] = Character);
  if Result then
    Inc(FPosition);
end;

{ Counts the capturing groups and collects their names. }
procedure TRxCompiler.ScanGroups;
var
  Index: Integer;
  InClass: Boolean;
  Name: UnicodeString;
  Close: Integer;
begin
  Index := 1;
  InClass := False;
  FGroupCount := 0;
  while Index <= Length(FPattern) do
  begin
    case FPattern[Index] of
      '\': Inc(Index);
      '[': InClass := True;
      ']': InClass := False;
      '(':
        if not InClass then
        begin
          if (Index < Length(FPattern)) and (FPattern[Index + 1] = '?') then
          begin
            if (Index + 2 <= Length(FPattern)) and (FPattern[Index + 2] = '<') and (Index + 3 <= Length(FPattern)) and
              (FPattern[Index + 3] <> '=') and (FPattern[Index + 3] <> '!') then
            begin
              Inc(FGroupCount);
              Close := Index + 3;
              while (Close <= Length(FPattern)) and (FPattern[Close] <> '>') do
                Inc(Close);
              Name := Copy(FPattern, Index + 3, Close - Index - 3);
              SetLength(FNames, FGroupCount + 1);
              FNames[FGroupCount] := Name;
              FHasNamedGroups := True;
            end;
          end
          else
          begin
            Inc(FGroupCount);
            SetLength(FNames, FGroupCount + 1);
            FNames[FGroupCount] := '';
          end;
        end;
    end;
    Inc(Index);
  end;
end;

function TRxCompiler.ParseDisjunction: TRxNode;
var
  Alternation: TRxNode;
begin
  Result := ParseAlternative;
  if Accept('|') then
  begin
    Alternation := NewNode(rnAlternation);
    Alternation.Add(Result);
    repeat
      Alternation.Add(ParseAlternative);
    until not Accept('|');
    Result := Alternation;
  end;
end;

function TRxCompiler.ParseAlternative: TRxNode;
var
  Term: TRxNode;
begin
  Result := NewNode(rnSequence);
  while not AtEnd and (FPattern[FPosition] <> '|') and (FPattern[FPosition] <> ')') do
  begin
    Term := ParseTerm;
    if Term <> nil then
      Result.Add(Term);
  end;
end;

function TRxCompiler.ParseTerm: TRxNode;
var
  Look: TRxNode;
  Character: WideChar;
begin
  Character := FPattern[FPosition];
  case Character of
    '^':
      begin
        Inc(FPosition);
        Exit(NewNode(rnLineStart));
      end;
    '$':
      begin
        Inc(FPosition);
        Exit(NewNode(rnLineEnd));
      end;
    '\':
      if (Peek(1) = Ord('b')) or (Peek(1) = Ord('B')) then
      begin
        Result := NewNode(rnWordBoundary);
        Result.Negated := Peek(1) = Ord('B');
        Inc(FPosition, 2);
        Exit;
      end;
    '(':
      if (Peek(1) = Ord('?')) and ((Peek(2) = Ord('=')) or (Peek(2) = Ord('!')) or
        ((Peek(2) = Ord('<')) and ((Peek(3) = Ord('=')) or (Peek(3) = Ord('!'))))) then
      begin
        Look := NewNode(rnLook);
        if Peek(2) = Ord('<') then
        begin
          if Peek(3) = Ord('=') then
            Look.LookKind := 2
          else
            Look.LookKind := 3;
          Inc(FPosition, 4);
        end
        else
        begin
          if Peek(2) = Ord('=') then
            Look.LookKind := 0
          else
            Look.LookKind := 1;
          Inc(FPosition, 3);
        end;
        Look.Add(ParseDisjunction);
        if not Accept(')') then
          Fail('Unterminated group');
        { Annex B: a lookahead may be quantified without u. }
        if (Look.LookKind < 2) and not FUnicode and not AtEnd and
          (FPattern[FPosition] in ['*', '+', '?', '{']) then
          Exit(ParseQuantifier(Look));
        Exit(Look);
      end;
  end;
  Result := ParseQuantifier(ParseAtom);
end;

function TRxCompiler.ParseDecimal(out Value: Integer): Boolean;
var
  Start: Integer;
  Wide: Int64;
begin
  Start := FPosition;
  Wide := 0;
  while (not AtEnd) and (FPattern[FPosition] >= '0') and (FPattern[FPosition] <= '9') do
  begin
    Wide := Wide * 10 + Ord(FPattern[FPosition]) - Ord('0');
    if Wide > MaximumRepeat then
      Wide := MaximumRepeat;
    Inc(FPosition);
  end;
  Value := Wide;
  Result := FPosition > Start;
end;

function TRxCompiler.ParseQuantifier(Atom: TRxNode): TRxNode;
var
  Minimum, Maximum: Integer;
  Start: Integer;
  Repeat_: TRxNode;
begin
  Result := Atom;
  if AtEnd or (Atom = nil) then
    Exit;
  case FPattern[FPosition] of
    '*':
      begin
        Minimum := 0;
        Maximum := -1;
        Inc(FPosition);
      end;
    '+':
      begin
        Minimum := 1;
        Maximum := -1;
        Inc(FPosition);
      end;
    '?':
      begin
        Minimum := 0;
        Maximum := 1;
        Inc(FPosition);
      end;
    '{':
      begin
        Start := FPosition;
        Inc(FPosition);
        if not ParseDecimal(Minimum) then
        begin
          if FUnicode then
            Fail('Incomplete quantifier');
          FPosition := Start;
          Exit;
        end;
        Maximum := Minimum;
        if Accept(',') then
        begin
          if not ParseDecimal(Maximum) then
            Maximum := -1;
        end;
        if not Accept('}') then
        begin
          if FUnicode then
            Fail('Incomplete quantifier');
          FPosition := Start;
          Exit;
        end;
        if (Maximum >= 0) and (Maximum < Minimum) then
          Fail('numbers out of order in {} quantifier');
      end;
  else
    Exit;
  end;
  if Atom.Kind in [rnLineStart, rnLineEnd, rnWordBoundary] then
    Fail('Nothing to repeat');
  if (Atom.Kind = rnLook) and (Atom.LookKind >= 2) then
    Fail('Invalid quantifier');
  Repeat_ := NewNode(rnRepeat);
  Repeat_.Minimum := Minimum;
  Repeat_.Maximum := Maximum;
  Repeat_.Greedy := not Accept('?');
  Repeat_.Add(Atom);
  Result := Repeat_;
end;

function TRxCompiler.ParseGroupName: UnicodeString;
var
  Start: Integer;
begin
  Start := FPosition;
  while (not AtEnd) and (FPattern[FPosition] <> '>') do
    Inc(FPosition);
  if AtEnd then
    Fail('Invalid capture group name');
  Result := Copy(FPattern, Start, FPosition - Start);
  Inc(FPosition);
  if Result = '' then
    Fail('Invalid capture group name');
end;

function TRxCompiler.ParseAtom: TRxNode;
var
  Character: WideChar;
  Group: TRxNode;
  Name: UnicodeString;
  Code: LongWord;
  Number, Saved: Integer;
  Target: TRxClass;
begin
  Character := FPattern[FPosition];
  case Character of
    '.':
      begin
        Inc(FPosition);
        Exit(NewNode(rnAny));
      end;
    '(':
      begin
        Inc(FPosition);
        if Accept('?') then
        begin
          if Accept(':') then
          begin
            Group := NewNode(rnGroup);
            Group.Group := -1;
          end
          else if Accept('<') then
          begin
            Name := ParseGroupName;
            Group := NewNode(rnGroup);
            Inc(FProgram.GroupCount);
            Group.Group := FProgram.GroupCount;
            Group.Name := Name;
            SetLength(FProgram.GroupNames, Length(FProgram.GroupNames) + 1);
            FProgram.GroupNames[High(FProgram.GroupNames)].Name := Name;
            FProgram.GroupNames[High(FProgram.GroupNames)].Group := Group.Group;
          end
          else
          begin
            Fail('Invalid group');
            Group := nil;
          end;
        end
        else
        begin
          Group := NewNode(rnGroup);
          Inc(FProgram.GroupCount);
          Group.Group := FProgram.GroupCount;
        end;
        Group.Add(ParseDisjunction);
        if not Accept(')') then
          Fail('Unterminated group');
        Exit(Group);
      end;
    ')':
      Fail('Unmatched '')''');
    '[':
      Exit(ParseClass);
    '*', '+', '?':
      Fail('Nothing to repeat');
    '{':
      if FUnicode then
        Fail('Lone quantifier brackets');
    '}', ']':
      if FUnicode then
        Fail('Lone quantifier brackets');
    '\':
      begin
        Inc(FPosition);
        if AtEnd then
          Fail('\ at end of pattern');
        Character := FPattern[FPosition];
        { Back references }
        if (Character >= '1') and (Character <= '9') then
        begin
          Saved := FPosition;
          ParseDecimal(Number);
          if Number <= FGroupCount then
          begin
            Result := NewNode(rnBackReference);
            Result.Group := Number;
            Exit;
          end;
          if FUnicode then
            Fail('Invalid escape');
          FPosition := Saved;
        end;
        if (Character = 'k') and (FUnicode or FHasNamedGroups) then
        begin
          Inc(FPosition);
          if not Accept('<') then
            Fail('Invalid named reference');
          Name := ParseGroupName;
          Result := NewNode(rnNamedBackReference);
          Result.Name := Name;
          Exit;
        end;
        if Character in ['d', 'D', 'w', 'W', 's', 'S'] then
        begin
          Inc(FPosition);
          Target := TRxClass.Create;
          ClassEscape(Character, Target);
          Result := NewNode(rnClass);
          Result.ClassIndex := AddClass(Target);
          Exit;
        end;
        if ((Character = 'p') or (Character = 'P')) and FUnicode then
        begin
          Inc(FPosition);
          Target := TRxClass.Create;
          PropertyEscape(Character = 'P', Target);
          Result := NewNode(rnClass);
          Result.ClassIndex := AddClass(Target);
          Exit;
        end;
        ParseEscapeCode(False, Code);
        Result := NewNode(rnChar);
        Result.Code := Code;
        Exit;
      end;
  end;
  Result := NewNode(rnChar);
  Result.Code := NextCodePoint;
end;

{ After the backslash: the code a character escape stands for. }
function TRxCompiler.ParseEscapeCode(InClass: Boolean; out Code: LongWord): Boolean;
var
  Character: WideChar;
  Value, Digit: LongWord;
  Count: Integer;
  Lead, Trail: LongWord;
  Saved: Integer;

  function HexDigit(Position: Integer): Integer;
  begin
    if Position > Length(FPattern) then
      Exit(-1);
    case FPattern[Position] of
      '0'..'9': Result := Ord(FPattern[Position]) - Ord('0');
      'a'..'f': Result := Ord(FPattern[Position]) - Ord('a') + 10;
      'A'..'F': Result := Ord(FPattern[Position]) - Ord('A') + 10;
    else
      Result := -1;
    end;
  end;

begin
  Result := True;
  Character := FPattern[FPosition];
  Inc(FPosition);
  case Character of
    'f': Code := 12;
    'n': Code := 10;
    'r': Code := 13;
    't': Code := 9;
    'v': Code := 11;
    'b':
      if InClass then
        Code := 8
      else
        Code := Ord('b');
    '-':
      Code := Ord('-');
    'c':
      begin
        if (not AtEnd) and (FPattern[FPosition] in ['a'..'z', 'A'..'Z']) then
        begin
          Code := Ord(FPattern[FPosition]) mod 32;
          Inc(FPosition);
        end
        else if (not FUnicode) and InClass and (not AtEnd) and (FPattern[FPosition] in ['0'..'9', '_']) then
        begin
          Code := Ord(FPattern[FPosition]) mod 32;
          Inc(FPosition);
        end
        else
        begin
          if FUnicode then
            Fail('Invalid unicode escape');
          Dec(FPosition);
          Code := Ord('\');
        end;
      end;
    '0':
      if (AtEnd or not (FPattern[FPosition] in ['0'..'9'])) then
        Code := 0
      else if FUnicode then
        Fail('Invalid decimal escape')
      else
      begin
        { Legacy octal. }
        Code := 0;
        Dec(FPosition);
        Count := 0;
        while (Count < 3) and (not AtEnd) and (FPattern[FPosition] in ['0'..'7']) and (Code * 8 + 7 < 256) do
        begin
          Code := Code * 8 + LongWord(Ord(FPattern[FPosition]) - Ord('0'));
          Inc(FPosition);
          Inc(Count);
        end;
      end;
    '1'..'7':
      begin
        if FUnicode then
          Fail('Invalid escape');
        Code := Ord(Character) - Ord('0');
        Count := 1;
        while (Count < 3) and (not AtEnd) and (FPattern[FPosition] in ['0'..'7']) and (Code * 8 + 7 < 256) do
        begin
          Code := Code * 8 + LongWord(Ord(FPattern[FPosition]) - Ord('0'));
          Inc(FPosition);
          Inc(Count);
        end;
      end;
    'x':
      if (HexDigit(FPosition) >= 0) and (HexDigit(FPosition + 1) >= 0) then
      begin
        Code := HexDigit(FPosition) * 16 + HexDigit(FPosition + 1);
        Inc(FPosition, 2);
      end
      else
      begin
        if FUnicode then
          Fail('Invalid escape');
        Code := Ord('x');
      end;
    'u':
      if FUnicode and (Peek = Ord('{')) then
      begin
        Inc(FPosition);
        Value := 0;
        Count := 0;
        while HexDigit(FPosition) >= 0 do
        begin
          Value := Value * 16 + LongWord(HexDigit(FPosition));
          if Value > $10FFFF then
            Fail('Invalid Unicode escape');
          Inc(FPosition);
          Inc(Count);
        end;
        if (Count = 0) or not Accept('}') then
          Fail('Invalid Unicode escape');
        Code := Value;
      end
      else if (HexDigit(FPosition) >= 0) and (HexDigit(FPosition + 1) >= 0) and (HexDigit(FPosition + 2) >= 0) and
        (HexDigit(FPosition + 3) >= 0) then
      begin
        Lead := 0;
        for Count := 0 to 3 do
          Lead := Lead * 16 + LongWord(HexDigit(FPosition + Count));
        Inc(FPosition, 4);
        Code := Lead;
        { 😀 in unicode mode is one code point. }
        if FUnicode and (Lead >= $D800) and (Lead <= $DBFF) and (Peek = Ord('\')) and (Peek(1) = Ord('u')) then
        begin
          Saved := FPosition;
          Inc(FPosition, 2);
          Trail := 0;
          Digit := 0;
          for Count := 0 to 3 do
            if HexDigit(FPosition + Count) < 0 then
              Digit := 1
            else
              Trail := Trail * 16 + LongWord(HexDigit(FPosition + Count));
          if (Digit = 0) and (Trail >= $DC00) and (Trail <= $DFFF) then
          begin
            Inc(FPosition, 4);
            Code := $10000 + ((Lead - $D800) shl 10) + (Trail - $DC00);
          end
          else
            FPosition := Saved;
        end;
      end
      else
      begin
        if FUnicode then
          Fail('Invalid Unicode escape');
        Code := Ord('u');
      end;
  else
    if FUnicode and not (Character in ['^', '$', '\', '.', '*', '+', '?', '(', ')', '[', ']', '{', '}', '|', '/']) then
      Fail('Invalid escape');
    Dec(FPosition);
    Code := NextCodePoint;
  end;
end;

function TRxCompiler.ClassEscape(Letter: WideChar; Target: TRxClass): Boolean;
var
  Inner: TRxClass;
begin
  Result := True;
  Inner := TRxClass.Create;
  try
    case Letter of
      'd', 'D':
        Inner.AddRange(Ord('0'), Ord('9'));
      'w', 'W':
        begin
          Inner.AddRange(Ord('a'), Ord('z'));
          Inner.AddRange(Ord('A'), Ord('Z'));
          Inner.AddRange(Ord('0'), Ord('9'));
          Inner.AddRange(Ord('_'), Ord('_'));
          if FIgnoreCase and FUnicode then
          begin
            Inner.AddRange($017F, $017F);
            Inner.AddRange($212A, $212A);
          end;
        end;
      's', 'S':
        begin
          Inner.AddRange(9, 13);
          Inner.AddRange(32, 32);
          Inner.AddRange($A0, $A0);
          Inner.AddRange($1680, $1680);
          Inner.AddRange($2000, $200A);
          Inner.AddRange($2028, $2029);
          Inner.AddRange($202F, $202F);
          Inner.AddRange($205F, $205F);
          Inner.AddRange($3000, $3000);
          Inner.AddRange($FEFF, $FEFF);
        end;
    end;
    Inner.Negated := Letter in ['D', 'W', 'S'];
    Target.AddClass(Inner);
  finally
    Inner.Free;
  end;
end;

function TRxCompiler.PropertyEscape(Negated: Boolean; Target: TRxClass): Boolean;
var
  Name, Value: UnicodeString;
  EqualsAt: Integer;
  Mask: LongWord;

  function Bit(Category: TUnicodeCategory): LongWord;
  begin
    Result := LongWord(1) shl Ord(Category);
  end;

begin
  Result := True;
  if not Accept('{') then
    Fail('Invalid property name');
  Name := '';
  while (not AtEnd) and (FPattern[FPosition] <> '}') do
  begin
    Name := Name + FPattern[FPosition];
    Inc(FPosition);
  end;
  if not Accept('}') then
    Fail('Invalid property name');
  EqualsAt := Pos('=', Name);
  if EqualsAt > 0 then
  begin
    Value := Copy(Name, EqualsAt + 1, MaxInt);
    Name := Copy(Name, 1, EqualsAt - 1);
    if (Name <> 'General_Category') and (Name <> 'gc') then
    begin
      { Scripts (by blocks: see ScriptTable). }
      if ((Name = 'Script') or (Name = 'sc') or (Name = 'Script_Extensions') or (Name = 'scx')) then
      begin
        if not AddScriptRanges(Target, Value) then
          Fail('Invalid property name');
        if Negated then
          Target.Negated := not Target.Negated;
        Exit;
      end;
      Fail('Invalid property name');
    end;
    Name := Value;
  end;
  Mask := 0;
  if (Name = 'L') or (Name = 'Letter') then
    Mask := Bit(TUnicodeCategory.ucUppercaseLetter) or Bit(TUnicodeCategory.ucLowercaseLetter) or
      Bit(TUnicodeCategory.ucTitlecaseLetter) or Bit(TUnicodeCategory.ucModifierLetter) or
      Bit(TUnicodeCategory.ucOtherLetter)
  else if (Name = 'Lu') or (Name = 'Uppercase_Letter') then
    Mask := Bit(TUnicodeCategory.ucUppercaseLetter)
  else if (Name = 'Ll') or (Name = 'Lowercase_Letter') then
    Mask := Bit(TUnicodeCategory.ucLowercaseLetter)
  else if (Name = 'Lt') or (Name = 'Titlecase_Letter') then
    Mask := Bit(TUnicodeCategory.ucTitlecaseLetter)
  else if (Name = 'Lm') or (Name = 'Modifier_Letter') then
    Mask := Bit(TUnicodeCategory.ucModifierLetter)
  else if (Name = 'Lo') or (Name = 'Other_Letter') then
    Mask := Bit(TUnicodeCategory.ucOtherLetter)
  else if (Name = 'M') or (Name = 'Mark') then
    Mask := Bit(TUnicodeCategory.ucNonSpacingMark) or Bit(TUnicodeCategory.ucCombiningMark) or
      Bit(TUnicodeCategory.ucEnclosingMark)
  else if (Name = 'Mn') or (Name = 'Nonspacing_Mark') then
    Mask := Bit(TUnicodeCategory.ucNonSpacingMark)
  else if (Name = 'N') or (Name = 'Number') then
    Mask := Bit(TUnicodeCategory.ucDecimalNumber) or Bit(TUnicodeCategory.ucLetterNumber) or
      Bit(TUnicodeCategory.ucOtherNumber)
  else if (Name = 'Nd') or (Name = 'Decimal_Number') or (Name = 'digit') then
    Mask := Bit(TUnicodeCategory.ucDecimalNumber)
  else if (Name = 'P') or (Name = 'Punctuation') or (Name = 'punct') then
    Mask := Bit(TUnicodeCategory.ucConnectPunctuation) or Bit(TUnicodeCategory.ucDashPunctuation) or
      Bit(TUnicodeCategory.ucOpenPunctuation) or Bit(TUnicodeCategory.ucClosePunctuation) or
      Bit(TUnicodeCategory.ucInitialPunctuation) or Bit(TUnicodeCategory.ucFinalPunctuation) or
      Bit(TUnicodeCategory.ucOtherPunctuation)
  else if (Name = 'S') or (Name = 'Symbol') then
    Mask := Bit(TUnicodeCategory.ucMathSymbol) or Bit(TUnicodeCategory.ucCurrencySymbol) or
      Bit(TUnicodeCategory.ucModifierSymbol) or Bit(TUnicodeCategory.ucOtherSymbol)
  else if (Name = 'Sm') or (Name = 'Math_Symbol') then
    Mask := Bit(TUnicodeCategory.ucMathSymbol)
  else if (Name = 'Sc') or (Name = 'Currency_Symbol') then
    Mask := Bit(TUnicodeCategory.ucCurrencySymbol)
  else if (Name = 'Z') or (Name = 'Separator') then
    Mask := Bit(TUnicodeCategory.ucSpaceSeparator) or Bit(TUnicodeCategory.ucLineSeparator) or
      Bit(TUnicodeCategory.ucParagraphSeparator)
  else if (Name = 'Zs') or (Name = 'Space_Separator') then
    Mask := Bit(TUnicodeCategory.ucSpaceSeparator)
  else if (Name = 'C') or (Name = 'Other') then
    Mask := Bit(TUnicodeCategory.ucControl) or Bit(TUnicodeCategory.ucFormat) or Bit(TUnicodeCategory.ucSurrogate) or
      Bit(TUnicodeCategory.ucPrivateUse) or Bit(TUnicodeCategory.ucUnassigned)
  else if (Name = 'Cc') or (Name = 'Control') or (Name = 'cntrl') then
    Mask := Bit(TUnicodeCategory.ucControl)
  else if (Name = 'Alphabetic') or (Name = 'Alpha') then
    Mask := Bit(TUnicodeCategory.ucUppercaseLetter) or Bit(TUnicodeCategory.ucLowercaseLetter) or
      Bit(TUnicodeCategory.ucTitlecaseLetter) or Bit(TUnicodeCategory.ucModifierLetter) or
      Bit(TUnicodeCategory.ucOtherLetter) or Bit(TUnicodeCategory.ucLetterNumber)
  else if (Name = 'White_Space') or (Name = 'space') then
  begin
    ClassEscape('s', Target);
    if Negated then
      Target.Negated := not Target.Negated;
    Exit;
  end
  else if Name = 'ASCII' then
  begin
    Target.AddRange(0, 127);
    if Negated then
      Target.Negated := not Target.Negated;
    Exit;
  end
  else if Name = 'Any' then
  begin
    Target.AddRange(0, $10FFFF);
    if Negated then
      Target.Negated := not Target.Negated;
    Exit;
  end
  else
    Fail('Invalid property name');
  Target.AddProperty(Mask, Negated);
end;

{ One class atom: a single code point (Single) or a class escape added
  to Target. False at ']'. }
function TRxCompiler.ParseClassAtom(Target: TRxClass; out Single: LongWord; out IsSingle: Boolean): Boolean;
var
  Character: WideChar;
begin
  Result := True;
  IsSingle := False;
  Single := 0;
  Character := FPattern[FPosition];
  if Character = '\' then
  begin
    Inc(FPosition);
    if AtEnd then
      Fail('\ at end of pattern');
    Character := FPattern[FPosition];
    if Character in ['d', 'D', 'w', 'W', 's', 'S'] then
    begin
      Inc(FPosition);
      ClassEscape(Character, Target);
      Exit;
    end;
    if ((Character = 'p') or (Character = 'P')) and FUnicode then
    begin
      Inc(FPosition);
      PropertyEscape(Character = 'P', Target);
      Exit;
    end;
    ParseEscapeCode(True, Single);
    IsSingle := True;
    Exit;
  end;
  Single := NextCodePoint;
  IsSingle := True;
end;

function TRxCompiler.ParseClass: TRxNode;
var
  Target: TRxClass;
  First, Last: LongWord;
  FirstSingle, LastSingle: Boolean;
  Saved: Integer;
begin
  Inc(FPosition);
  Target := TRxClass.Create;
  if Accept('^') then
    Target.Negated := True;
  while True do
  begin
    if AtEnd then
    begin
      Target.Free;
      Fail('Unterminated character class');
    end;
    if FPattern[FPosition] = ']' then
    begin
      Inc(FPosition);
      Break;
    end;
    ParseClassAtom(Target, First, FirstSingle);
    if (not AtEnd) and (FPattern[FPosition] = '-') and (Peek(1) <> Ord(']')) and (Peek(1) <> $FFFFFFFF) then
    begin
      Saved := FPosition;
      Inc(FPosition);
      ParseClassAtom(Target, Last, LastSingle);
      if FirstSingle and LastSingle then
      begin
        if Last < First then
        begin
          Target.Free;
          Fail('Range out of order in character class');
        end;
        Target.AddRange(First, Last);
        Continue;
      end;
      if FUnicode then
      begin
        Target.Free;
        Fail('Invalid character class');
      end;
      { Annex B: a class escape at either end makes the dash literal. }
      if FirstSingle then
        Target.AddRange(First, First);
      Target.AddRange(Ord('-'), Ord('-'));
      if LastSingle then
        Target.AddRange(Last, Last);
      if Saved = 0 then;
      Continue;
    end;
    if FirstSingle then
      Target.AddRange(First, First);
  end;
  Result := NewNode(rnClass);
  Result.ClassIndex := AddClass(Target);
end;

function TRxCompiler.AddClass(Target: TRxClass): Integer;
var
  Index: Integer;
  Count: Integer;
  Code, Upper, Lower: LongWord;
  Mapped: UnicodeString;
  Extra: TRxClass;
begin
  if FIgnoreCase then
  begin
    { Add the other case of each member (ranges up to a size). }
    Extra := TRxClass.Create;
    try
      for Index := 0 to High(Target.Ranges) do
      begin
        if Target.Ranges[Index].Last - Target.Ranges[Index].First > 2000 then
          Continue;
        Code := Target.Ranges[Index].First;
        while Code <= Target.Ranges[Index].Last do
        begin
          if (Code <= $FFFF) and not IsSurrogateUnit(Code) then
          begin
            Mapped := TCharacter.ToUpper(UnicodeString(WideChar(Code)));
            if Length(Mapped) = 1 then
            begin
              Upper := Ord(Mapped[1]);
              if Upper <> Code then
                Extra.AddRange(Upper, Upper);
            end;
            Mapped := TCharacter.ToLower(UnicodeString(WideChar(Code)));
            if Length(Mapped) = 1 then
            begin
              Lower := Ord(Mapped[1]);
              if Lower <> Code then
                Extra.AddRange(Lower, Lower);
            end;
          end;
          Inc(Code);
        end;
      end;
      for Index := 0 to High(Extra.Ranges) do
        Target.AddRange(Extra.Ranges[Index].First, Extra.Ranges[Index].Last);
    finally
      Extra.Free;
    end;
  end;
  Target.Normalize;
  Count := Length(FProgram.Classes);
  SetLength(FProgram.Classes, Count + 1);
  FProgram.Classes[Count] := Target;
  Result := Count;
end;

function TRxCompiler.GroupsIn(Node: TRxNode; out First, Last: Integer): Boolean;
var
  Index, ChildFirst, ChildLast: Integer;
begin
  First := MaxInt;
  Last := -1;
  if (Node.Kind = rnGroup) and (Node.Group > 0) then
  begin
    First := Node.Group;
    Last := Node.Group;
  end;
  for Index := 0 to High(Node.Children) do
    if GroupsIn(Node.Children[Index], ChildFirst, ChildLast) then
    begin
      if ChildFirst < First then
        First := ChildFirst;
      if ChildLast > Last then
        Last := ChildLast;
    end;
  Result := Last >= 0;
end;

procedure TRxCompiler.Emit(Value: LongInt);
var
  Count: Integer;
begin
  Count := Length(FProgram.Code);
  SetLength(FProgram.Code, Count + 1);
  FProgram.Code[Count] := Value;
end;

procedure TRxCompiler.Generate(Node: TRxNode; Direction: Integer);
var
  Index, SplitAt, JumpAt, Counter, PositionRegister, LoopHead, ExitPatch, First, Last: Integer;
  Patches: array of Integer;
  OtherDirection: Integer;
begin
  case Node.Kind of
    rnEmpty: ;
    rnChar:
      begin
        Emit(RxChar);
        Emit(Direction);
        if FIgnoreCase then
          Emit(LongInt(CanonicalizeCase(Node.Code, FUnicode)))
        else
          Emit(LongInt(Node.Code));
      end;
    rnAny:
      begin
        Emit(RxAny);
        Emit(Direction);
      end;
    rnClass:
      begin
        Emit(RxClass);
        Emit(Direction);
        Emit(Node.ClassIndex);
      end;
    rnSequence:
      if Direction = ForwardDirection then
        for Index := 0 to High(Node.Children) do
          Generate(Node.Children[Index], Direction)
      else
        for Index := High(Node.Children) downto 0 do
          Generate(Node.Children[Index], Direction);
    rnAlternation:
      begin
        Patches := nil;
        for Index := 0 to High(Node.Children) do
        begin
          if Index < High(Node.Children) then
          begin
            Emit(RxSplit);
            SplitAt := Length(FProgram.Code);
            Emit(SplitAt + 2);
            Emit(0);
            Generate(Node.Children[Index], Direction);
            Emit(RxJump);
            SetLength(Patches, Length(Patches) + 1);
            Patches[High(Patches)] := Length(FProgram.Code);
            Emit(0);
            FProgram.Code[SplitAt + 1] := Length(FProgram.Code);
          end
          else
            Generate(Node.Children[Index], Direction);
        end;
        for Index := 0 to High(Patches) do
          FProgram.Code[Patches[Index]] := Length(FProgram.Code);
      end;
    rnGroup:
      begin
        if Node.Group > 0 then
        begin
          Emit(RxSave);
          if Direction = ForwardDirection then
            Emit(Node.Group * 2)
          else
            Emit(Node.Group * 2 + 1);
        end;
        Generate(Node.Children[0], Direction);
        if Node.Group > 0 then
        begin
          Emit(RxSave);
          if Direction = ForwardDirection then
            Emit(Node.Group * 2 + 1)
          else
            Emit(Node.Group * 2);
        end;
      end;
    rnRepeat:
      begin
        if (Node.Minimum = 1) and (Node.Maximum = 1) then
        begin
          Generate(Node.Children[0], Direction);
          Exit;
        end;
        if (Node.Maximum = 0) then
          Exit;
        Counter := FProgram.CounterCount;
        Inc(FProgram.CounterCount);
        PositionRegister := FProgram.PositionRegisterCount;
        Inc(FProgram.PositionRegisterCount);
        Emit(RxRepeatStart);
        Emit(Counter);
        LoopHead := Length(FProgram.Code);
        Emit(RxRepeatLoop);
        Emit(Counter);
        Emit(Node.Minimum);
        Emit(Node.Maximum);
        Emit(Ord(Node.Greedy));
        ExitPatch := Length(FProgram.Code);
        Emit(0);
        Emit(RxSavePosition);
        Emit(PositionRegister);
        if GroupsIn(Node.Children[0], First, Last) then
        begin
          Emit(RxResetCaptures);
          Emit(First);
          Emit(Last);
        end;
        Generate(Node.Children[0], Direction);
        Emit(RxRepeatEnd);
        Emit(Counter);
        Emit(PositionRegister);
        Emit(LoopHead);
        FProgram.Code[ExitPatch] := Length(FProgram.Code);
      end;
    rnLineStart:
      Emit(RxLineStart);
    rnLineEnd:
      Emit(RxLineEnd);
    rnWordBoundary:
      begin
        Emit(RxWordBoundary);
        Emit(Ord(Node.Negated));
      end;
    rnBackReference:
      begin
        Emit(RxBackReference);
        Emit(Direction);
        Emit(Node.Group);
      end;
    rnNamedBackReference:
      begin
        First := MaxInt;
        Last := -1;
        for Index := 0 to High(FProgram.GroupNames) do
          if FProgram.GroupNames[Index].Name = Node.Name then
          begin
            if FProgram.GroupNames[Index].Group < First then
              First := FProgram.GroupNames[Index].Group;
            if FProgram.GroupNames[Index].Group > Last then
              Last := FProgram.GroupNames[Index].Group;
          end;
        if Last < 0 then
          Fail('Invalid named capture referenced');
        Emit(RxNamedBackReference);
        Emit(Direction);
        Emit(First);
        Emit(Last);
      end;
    rnLook:
      begin
        Emit(RxLook);
        Emit(Node.LookKind);
        JumpAt := Length(FProgram.Code);
        Emit(0);
        if Node.LookKind >= 2 then
          OtherDirection := BackwardDirection
        else
          OtherDirection := ForwardDirection;
        Generate(Node.Children[0], OtherDirection);
        Emit(RxMatch);
        FProgram.Code[JumpAt] := Length(FProgram.Code);
      end;
  end;
end;

procedure TRxCompiler.Compile;
var
  Root: TRxNode;
begin
  ScanGroups;
  Root := ParseDisjunction;
  try
    if not AtEnd then
      Fail('Unmatched '')''');
    Emit(RxSave);
    Emit(0);
    Generate(Root, ForwardDirection);
    Emit(RxSave);
    Emit(1);
    Emit(RxMatch);
  finally
    Root.Free;
  end;
end;

function CompileRegExp(const Pattern: UnicodeString; IgnoreCase, Multiline, DotAll, Unicode: Boolean): TRxProgram;
var
  Compiler: TRxCompiler;
begin
  Result := TRxProgram.Create;
  Result.IgnoreCase := IgnoreCase;
  Result.Multiline := Multiline;
  Result.DotAll := DotAll;
  Result.Unicode := Unicode;
  Compiler := TRxCompiler.Create(Pattern, Result);
  try
    try
      Compiler.Compile;
    except
      Result.Free;
      raise;
    end;
  finally
    Compiler.Free;
  end;
end;

end.
