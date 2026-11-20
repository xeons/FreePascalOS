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
  Unicode normalization (NFC, NFD, NFKC, NFKD) for
  String.prototype.normalize, by the algorithm of UAX #15: full
  decomposition, canonical ordering by combining class, then canonical
  composition of starters with the marks after them (not across a
  mark of the same or a higher class).

  The tables are written here, not generated from the Unicode
  database, so they cover a part of it: the canonical decompositions of
  Latin-1, Latin Extended-A, the pinyin, Romanian and Vietnamese letters
  of Latin Extended-B and Latin Extended Additional, basic Greek with
  its tonos and dialytika letters, Cyrillic, the canonical singletons
  of those blocks (never composed), Hangul syllables (computed), the
  combining classes of the combining diacritical marks (U+0300-036F)
  and the Cyrillic ones; and the compatibility decompositions of
  Latin-1, the Latin ligatures and digraphs, the spaces, super- and
  subscripts, fractions, roman numerals, circled numbers, letterlike
  symbols, the Latin presentation forms and fullwidth ASCII. Other
  scripts' marks (Hebrew, Arabic, Indic...), Greek Extended, the rest of
  Latin Extended Additional and the CJK compatibility forms are left as
  they are.
}
unit Js.Normalization;

{$mode objfpc}{$H+}
{$R-}{$Q-}

interface

type
  TJsNormalForm = (nfC, nfD, nfKC, nfKD);

{ Text normalized to Form (UTF-16). }
function NormalizeText(const Text: UnicodeString; Form: TJsNormalForm): UnicodeString;
{ The canonical combining class of a code point (0 for those the tables
  do not know). }
function CombiningClass(CodePoint: LongWord): Byte;

implementation

uses
  SysUtils;

type
  TDecomposition = record
    CodePoint: LongWord;
    Parts: array of LongWord;
    { Decomposes but never composes back (singletons, non-starters). }
    Excluded: Boolean;
  end;

const
  { Code point, then what it decomposes to (hex, space separated). }
  CanonicalSource: array[0..361] of string = (
    '00C0 0041 0300', '00C1 0041 0301', '00C2 0041 0302', '00C3 0041 0303', '00C4 0041 0308', '00C5 0041 030A',
    '00C7 0043 0327', '00C8 0045 0300', '00C9 0045 0301', '00CA 0045 0302', '00CB 0045 0308', '00CC 0049 0300',
    '00CD 0049 0301', '00CE 0049 0302', '00CF 0049 0308', '00D1 004E 0303', '00D2 004F 0300', '00D3 004F 0301',
    '00D4 004F 0302', '00D5 004F 0303', '00D6 004F 0308', '00D9 0055 0300', '00DA 0055 0301', '00DB 0055 0302',
    '00DC 0055 0308', '00DD 0059 0301', '00E0 0061 0300', '00E1 0061 0301', '00E2 0061 0302', '00E3 0061 0303',
    '00E4 0061 0308', '00E5 0061 030A', '00E7 0063 0327', '00E8 0065 0300', '00E9 0065 0301', '00EA 0065 0302',
    '00EB 0065 0308', '00EC 0069 0300', '00ED 0069 0301', '00EE 0069 0302', '00EF 0069 0308', '00F1 006E 0303',
    '00F2 006F 0300', '00F3 006F 0301', '00F4 006F 0302', '00F5 006F 0303', '00F6 006F 0308', '00F9 0075 0300',
    '00FA 0075 0301', '00FB 0075 0302', '00FC 0075 0308', '00FD 0079 0301', '00FF 0079 0308',
    '0100 0041 0304', '0101 0061 0304', '0102 0041 0306', '0103 0061 0306', '0104 0041 0328', '0105 0061 0328',
    '0106 0043 0301', '0107 0063 0301', '0108 0043 0302', '0109 0063 0302', '010A 0043 0307', '010B 0063 0307',
    '010C 0043 030C', '010D 0063 030C', '010E 0044 030C', '010F 0064 030C', '0112 0045 0304', '0113 0065 0304',
    '0114 0045 0306', '0115 0065 0306', '0116 0045 0307', '0117 0065 0307', '0118 0045 0328', '0119 0065 0328',
    '011A 0045 030C', '011B 0065 030C', '011C 0047 0302', '011D 0067 0302', '011E 0047 0306', '011F 0067 0306',
    '0120 0047 0307', '0121 0067 0307', '0122 0047 0327', '0123 0067 0327', '0124 0048 0302', '0125 0068 0302',
    '0128 0049 0303', '0129 0069 0303', '012A 0049 0304', '012B 0069 0304', '012C 0049 0306', '012D 0069 0306',
    '012E 0049 0328', '012F 0069 0328', '0130 0049 0307', '0134 004A 0302', '0135 006A 0302', '0136 004B 0327',
    '0137 006B 0327', '0139 004C 0301', '013A 006C 0301', '013B 004C 0327', '013C 006C 0327', '013D 004C 030C',
    '013E 006C 030C', '0143 004E 0301', '0144 006E 0301', '0145 004E 0327', '0146 006E 0327', '0147 004E 030C',
    '0148 006E 030C', '014C 004F 0304', '014D 006F 0304', '014E 004F 0306', '014F 006F 0306', '0150 004F 030B',
    '0151 006F 030B', '0154 0052 0301', '0155 0072 0301', '0156 0052 0327', '0157 0072 0327', '0158 0052 030C',
    '0159 0072 030C', '015A 0053 0301', '015B 0073 0301', '015C 0053 0302', '015D 0073 0302', '015E 0053 0327',
    '015F 0073 0327', '0160 0053 030C', '0161 0073 030C', '0162 0054 0327', '0163 0074 0327', '0164 0054 030C',
    '0165 0074 030C', '0168 0055 0303', '0169 0075 0303', '016A 0055 0304', '016B 0075 0304', '016C 0055 0306',
    '016D 0075 0306', '016E 0055 030A', '016F 0075 030A', '0170 0055 030B', '0171 0075 030B', '0172 0055 0328',
    '0173 0075 0328', '0174 0057 0302', '0175 0077 0302', '0176 0059 0302', '0177 0079 0302', '0178 0059 0308',
    '0179 005A 0301', '017A 007A 0301', '017B 005A 0307', '017C 007A 0307', '017D 005A 030C', '017E 007A 030C',
    '01A0 004F 031B', '01A1 006F 031B', '01AF 0055 031B', '01B0 0075 031B', '01CD 0041 030C', '01CE 0061 030C',
    '01CF 0049 030C', '01D0 0069 030C', '01D1 004F 030C', '01D2 006F 030C', '01D3 0055 030C', '01D4 0075 030C',
    '01D5 00DC 0304', '01D6 00FC 0304', '01D7 00DC 0301', '01D8 00FC 0301', '01D9 00DC 030C', '01DA 00FC 030C',
    '01DB 00DC 0300', '01DC 00FC 0300', '01DE 00C4 0304', '01DF 00E4 0304', '01E6 0047 030C', '01E7 0067 030C',
    '01E8 004B 030C', '01E9 006B 030C', '01EA 004F 0328', '01EB 006F 0328', '01F4 0047 0301', '01F5 0067 0301',
    '01F8 004E 0300', '01F9 006E 0300', '0218 0053 0326', '0219 0073 0326', '021A 0054 0326', '021B 0074 0326',
    '0385 00A8 0301', '0386 0391 0301', '0388 0395 0301', '0389 0397 0301', '038A 0399 0301', '038C 039F 0301',
    '038E 03A5 0301', '038F 03A9 0301', '0390 03CA 0301', '03AA 0399 0308', '03AB 03A5 0308', '03AC 03B1 0301',
    '03AD 03B5 0301', '03AE 03B7 0301', '03AF 03B9 0301', '03B0 03CB 0301', '03CA 03B9 0308', '03CB 03C5 0308',
    '03CC 03BF 0301', '03CD 03C5 0301', '03CE 03C9 0301', '03D3 03D2 0301', '03D4 03D2 0308',
    '0400 0415 0300', '0401 0415 0308', '0403 0413 0301', '0407 0406 0308', '040C 041A 0301', '040D 0418 0300',
    '040E 0423 0306', '0419 0418 0306', '0439 0438 0306', '0450 0435 0300', '0451 0435 0308', '0453 0433 0301',
    '0457 0456 0308', '045C 043A 0301', '045D 0438 0300', '045E 0443 0306', '0476 0474 030F', '0477 0475 030F',
    '04C1 0416 0306', '04C2 0436 0306', '04D0 0410 0306', '04D1 0430 0306', '04D2 0410 0308', '04D3 0430 0308',
    '04D6 0415 0306', '04D7 0435 0306', '04DA 04D8 0308', '04DB 04D9 0308', '04DC 0416 0308', '04DD 0436 0308',
    '04DE 0417 0308', '04DF 0437 0308', '04E2 0418 0304', '04E3 0438 0304', '04E4 0418 0308', '04E5 0438 0308',
    '04E6 041E 0308', '04E7 043E 0308', '04EA 04E8 0308', '04EB 04E9 0308', '04EC 042D 0308', '04ED 044D 0308',
    '04EE 0423 0304', '04EF 0443 0304', '04F0 0423 0308', '04F1 0443 0308', '04F2 0423 030B', '04F3 0443 030B',
    '04F4 0427 0308', '04F5 0447 0308', '04F8 042B 0308', '04F9 044B 0308',
    '1EA0 0041 0323', '1EA1 0061 0323', '1EA2 0041 0309', '1EA3 0061 0309', '1EA4 00C2 0301', '1EA5 00E2 0301',
    '1EA6 00C2 0300', '1EA7 00E2 0300', '1EA8 00C2 0309', '1EA9 00E2 0309', '1EAA 00C2 0303', '1EAB 00E2 0303',
    '1EAC 1EA0 0302', '1EAD 1EA1 0302', '1EAE 0102 0301', '1EAF 0103 0301', '1EB0 0102 0300', '1EB1 0103 0300',
    '1EB2 0102 0309', '1EB3 0103 0309', '1EB4 0102 0303', '1EB5 0103 0303', '1EB6 1EA0 0306', '1EB7 1EA1 0306',
    '1EB8 0045 0323', '1EB9 0065 0323', '1EBA 0045 0309', '1EBB 0065 0309', '1EBC 0045 0303', '1EBD 0065 0303',
    '1EBE 00CA 0301', '1EBF 00EA 0301', '1EC0 00CA 0300', '1EC1 00EA 0300', '1EC2 00CA 0309', '1EC3 00EA 0309',
    '1EC4 00CA 0303', '1EC5 00EA 0303', '1EC6 1EB8 0302', '1EC7 1EB9 0302', '1EC8 0049 0309', '1EC9 0069 0309',
    '1ECA 0049 0323', '1ECB 0069 0323', '1ECC 004F 0323', '1ECD 006F 0323', '1ECE 004F 0309', '1ECF 006F 0309',
    '1ED0 00D4 0301', '1ED1 00F4 0301', '1ED2 00D4 0300', '1ED3 00F4 0300', '1ED4 00D4 0309', '1ED5 00F4 0309',
    '1ED6 00D4 0303', '1ED7 00F4 0303', '1ED8 1ECC 0302', '1ED9 1ECD 0302', '1EDA 01A0 0301', '1EDB 01A1 0301',
    '1EDC 01A0 0300', '1EDD 01A1 0300', '1EDE 01A0 0309', '1EDF 01A1 0309', '1EE0 01A0 0303', '1EE1 01A1 0303',
    '1EE2 01A0 0323', '1EE3 01A1 0323', '1EE4 0055 0323', '1EE5 0075 0323', '1EE6 0055 0309', '1EE7 0075 0309',
    '1EE8 01AF 0301', '1EE9 01B0 0301', '1EEA 01AF 0300', '1EEB 01B0 0300', '1EEC 01AF 0309', '1EED 01B0 0309',
    '1EEE 01AF 0303', '1EEF 01B0 0303', '1EF0 01AF 0323', '1EF1 01B0 0323', '1EF2 0059 0300', '1EF3 0079 0300',
    '1EF4 0059 0323', '1EF5 0079 0323', '1EF6 0059 0309', '1EF7 0079 0309', '1EF8 0059 0303', '1EF9 0079 0303');

  { Canonical decompositions that never compose back. }
  ExcludedSource: array[0..13] of string = (
    '0340 0300', '0341 0301', '0343 0313', '0344 0308 0301', '0374 02B9', '037E 003B', '0387 00B7', '2000 2002',
    '2001 2003', '2126 03A9', '212A 004B', '212B 00C5', '2329 3008', '232A 3009');

  CompatibilitySource: array[0..90] of string = (
    '00A0 0020', '00A8 0020 0308', '00AA 0061', '00AF 0020 0304', '00B2 0032', '00B3 0033', '00B4 0020 0301',
    '00B5 03BC', '00B8 0020 0327', '00B9 0031', '00BA 006F', '00BC 0031 2044 0034', '00BD 0031 2044 0032',
    '00BE 0033 2044 0034', '0132 0049 004A', '0133 0069 006A', '013F 004C 00B7', '0140 006C 00B7', '0149 02BC 006E',
    '017F 0073', '01C4 0044 017D', '01C5 0044 017E', '01C6 0064 017E', '01C7 004C 004A', '01C8 004C 006A',
    '01C9 006C 006A', '01CA 004E 004A', '01CB 004E 006A', '01CC 006E 006A', '2011 2010', '2024 002E',
    '2025 002E 002E', '2026 002E 002E 002E', '202F 0020', '2033 2032 2032', '203C 0021 0021', '205F 0020',
    '2070 0030', '2071 0069', '207A 002B', '207B 2212', '207C 003D', '207D 0028', '207E 0029', '207F 006E',
    '208A 002B', '208B 2212', '208C 003D', '208D 0028', '208E 0029', '2103 00B0 0043', '2109 00B0 0046',
    '2116 004E 006F', '2122 0054 004D', '2160 0049', '2161 0049 0049', '2162 0049 0049 0049', '2163 0049 0056',
    '2164 0056', '2165 0056 0049', '2166 0056 0049 0049', '2167 0056 0049 0049 0049', '2168 0049 0058',
    '2169 0058', '216A 0058 0049', '216B 0058 0049 0049', '216C 004C', '216D 0043', '216E 0044', '216F 004D',
    '2170 0069', '2171 0069 0069', '2172 0069 0069 0069', '2173 0069 0076', '2174 0076', '2175 0076 0069',
    '2176 0076 0069 0069', '2177 0076 0069 0069 0069', '2178 0069 0078', '2179 0078', '217A 0078 0069',
    '217B 0078 0069 0069', '217C 006C', '217D 0063', '217E 0064', '217F 006D', 'FB00 0066 0066', 'FB01 0066 0069',
    'FB02 0066 006C', 'FB03 0066 0066 0069', 'FB04 0066 0066 006C');

  HangulBase = $AC00;
  HangulCount = 11172;
  LeadBase = $1100;
  VowelBase = $1161;
  TrailBase = $11A7;
  VowelCount = 21;
  TrailCount = 28;

var
  Canonical: array of TDecomposition;
  Compatibility: array of TDecomposition;
  TablesReady: Boolean = False;

function ParseEntry(const Line: string; Excluded: Boolean): TDecomposition;
var
  Words: TStringArray;
  Index: Integer;
begin
  Words := Line.Split([' ']);
  Result.CodePoint := StrToInt('$' + Words[0]);
  Result.Parts := nil;
  SetLength(Result.Parts, Length(Words) - 1);
  for Index := 1 to High(Words) do
    Result.Parts[Index - 1] := StrToInt('$' + Words[Index]);
  Result.Excluded := Excluded or (Length(Result.Parts) = 1);
end;

procedure SortTable(var Table: array of TDecomposition);
var
  Index, Position: Integer;
  Entry: TDecomposition;
begin
  for Index := 1 to High(Table) do
  begin
    Entry := Table[Index];
    Position := Index - 1;
    while (Position >= 0) and (Table[Position].CodePoint > Entry.CodePoint) do
    begin
      Table[Position + 1] := Table[Position];
      Dec(Position);
    end;
    Table[Position + 1] := Entry;
  end;
end;

procedure PrepareTables;
var
  Index, Count: Integer;
begin
  if TablesReady then
    Exit;
  SetLength(Canonical, Length(CanonicalSource) + Length(ExcludedSource));
  Count := 0;
  for Index := 0 to High(CanonicalSource) do
  begin
    Canonical[Count] := ParseEntry(CanonicalSource[Index], False);
    Inc(Count);
  end;
  for Index := 0 to High(ExcludedSource) do
  begin
    Canonical[Count] := ParseEntry(ExcludedSource[Index], True);
    Inc(Count);
  end;
  SortTable(Canonical);
  SetLength(Compatibility, Length(CompatibilitySource));
  for Index := 0 to High(CompatibilitySource) do
    Compatibility[Index] := ParseEntry(CompatibilitySource[Index], True);
  SortTable(Compatibility);
  TablesReady := True;
end;

function FindIn(const Table: array of TDecomposition; CodePoint: LongWord): Integer;
var
  Low, High, Middle: Integer;
begin
  Low := 0;
  High := System.High(Table);
  while Low <= High do
  begin
    Middle := (Low + High) div 2;
    if Table[Middle].CodePoint = CodePoint then
      Exit(Middle);
    if Table[Middle].CodePoint < CodePoint then
      Low := Middle + 1
    else
      High := Middle - 1;
  end;
  Result := -1;
end;

function CombiningClass(CodePoint: LongWord): Byte;
begin
  case CodePoint of
    $0300..$0314, $033D..$0344, $0346, $034A..$034C, $0350..$0352, $0357, $035B, $0363..$036F, $0483..$0487:
      Result := 230;
    $0315, $031A, $0358: Result := 232;
    $0316..$0319, $031C..$0320, $0323..$0326, $0329..$0333, $0339..$033C, $0347..$0349, $034D, $034E,
    $0353..$0356, $0359, $035A:
      Result := 220;
    $031B: Result := 216;
    $0321, $0322, $0327, $0328: Result := 202;
    $0334..$0338: Result := 1;
    $0345: Result := 240;
    $035C, $035F, $0362: Result := 233;
    $035D, $035E, $0360, $0361: Result := 234;
  else
    Result := 0;
  end;
end;

{ Ranges of compatibility mappings computed rather than listed. }
function CompatibilityRange(CodePoint: LongWord; var Output: array of LongWord; out Count: Integer): Boolean;
begin
  Result := True;
  Count := 1;
  case CodePoint of
    $2002..$200A, $3000: Output[0] := $20;
    $2074..$2079: Output[0] := CodePoint - $2074 + $34;
    $2080..$2089: Output[0] := CodePoint - $2080 + $30;
    $FF01..$FF5E: Output[0] := CodePoint - $FF01 + $21;
    $2460..$2468: Output[0] := CodePoint - $2460 + $31;
    $2469..$2473:
      begin
        Output[0] := $30 + (CodePoint - $2460 + 1) div 10;
        Output[1] := $30 + (CodePoint - $2460 + 1) mod 10;
        Count := 2;
      end;
    $FB05:
      begin
        Output[0] := $17F;
        Output[1] := $74;
        Count := 2;
      end;
    $FB06:
      begin
        Output[0] := $73;
        Output[1] := $74;
        Count := 2;
      end;
  else
    Result := False;
  end;
end;

type
  TPointList = array of LongWord;

procedure AppendPoint(var Points: TPointList; var Count: Integer; CodePoint: LongWord);
begin
  if Count >= Length(Points) then
    SetLength(Points, Length(Points) * 2 + 16);
  Points[Count] := CodePoint;
  Inc(Count);
end;

procedure Decompose(CodePoint: LongWord; Compatible: Boolean; var Points: TPointList; var Count: Integer);
var
  Index, Part, RangeCount: Integer;
  SyllableIndex: LongWord;
  Range: array[0..3] of LongWord;
begin
  if (CodePoint >= HangulBase) and (CodePoint < HangulBase + HangulCount) then
  begin
    SyllableIndex := CodePoint - HangulBase;
    AppendPoint(Points, Count, LeadBase + SyllableIndex div (VowelCount * TrailCount));
    AppendPoint(Points, Count, VowelBase + (SyllableIndex mod (VowelCount * TrailCount)) div TrailCount);
    if SyllableIndex mod TrailCount <> 0 then
      AppendPoint(Points, Count, TrailBase + SyllableIndex mod TrailCount);
    Exit;
  end;
  Index := FindIn(Canonical, CodePoint);
  if Index >= 0 then
  begin
    for Part := 0 to High(Canonical[Index].Parts) do
      Decompose(Canonical[Index].Parts[Part], Compatible, Points, Count);
    Exit;
  end;
  if Compatible then
  begin
    Index := FindIn(Compatibility, CodePoint);
    if Index >= 0 then
    begin
      for Part := 0 to High(Compatibility[Index].Parts) do
        Decompose(Compatibility[Index].Parts[Part], True, Points, Count);
      Exit;
    end;
    if CompatibilityRange(CodePoint, Range, RangeCount) then
    begin
      for Part := 0 to RangeCount - 1 do
        Decompose(Range[Part], True, Points, Count);
      Exit;
    end;
  end;
  AppendPoint(Points, Count, CodePoint);
end;

{ Canonical ordering: marks sorted by class between starters (stable). }
procedure ReorderMarks(var Points: TPointList; Count: Integer);
var
  Index, Position: Integer;
  Point: LongWord;
  PointClass: Byte;
begin
  for Index := 1 to Count - 1 do
  begin
    Point := Points[Index];
    PointClass := CombiningClass(Point);
    if PointClass = 0 then
      Continue;
    Position := Index - 1;
    while (Position >= 0) and (CombiningClass(Points[Position]) > PointClass) do
    begin
      Points[Position + 1] := Points[Position];
      Dec(Position);
    end;
    Points[Position + 1] := Point;
  end;
end;

{ The primary composite of a pair (0: none). }
function ComposePair(First, Second: LongWord): LongWord;
var
  Index: Integer;
begin
  if (First >= LeadBase) and (First < LeadBase + 19) and (Second >= VowelBase) and (Second < VowelBase + VowelCount) then
    Exit(HangulBase + ((First - LeadBase) * VowelCount + (Second - VowelBase)) * TrailCount);
  if (First >= HangulBase) and (First < HangulBase + HangulCount) and ((First - HangulBase) mod TrailCount = 0) and
    (Second > TrailBase) and (Second < TrailBase + TrailCount) then
    Exit(First + (Second - TrailBase));
  for Index := 0 to High(Canonical) do
    if not Canonical[Index].Excluded and (Canonical[Index].Parts[0] = First) and
      (Canonical[Index].Parts[1] = Second) then
      Exit(Canonical[Index].CodePoint);
  Result := 0;
end;

procedure Compose(var Points: TPointList; var Count: Integer);
var
  Index, Output, Starter: Integer;
  LastClass, PointClass: Integer;
  Composite: LongWord;
begin
  if Count = 0 then
    Exit;
  Starter := -1;
  LastClass := 256;
  if CombiningClass(Points[0]) = 0 then
  begin
    Starter := 0;
    LastClass := 0;
  end;
  Output := 1;
  for Index := 1 to Count - 1 do
  begin
    PointClass := CombiningClass(Points[Index]);
    if (Starter >= 0) and ((LastClass < PointClass) or ((LastClass = 0) and (Output - 1 = Starter))) then
    begin
      Composite := ComposePair(Points[Starter], Points[Index]);
      if Composite <> 0 then
      begin
        Points[Starter] := Composite;
        Continue;
      end;
    end;
    if PointClass = 0 then
      Starter := Output;
    LastClass := PointClass;
    Points[Output] := Points[Index];
    Inc(Output);
  end;
  Count := Output;
end;

function NormalizeText(const Text: UnicodeString; Form: TJsNormalForm): UnicodeString;
var
  Points: TPointList;
  Count, Index: Integer;
  CodePoint: LongWord;
  Plain: Boolean;
begin
  { Nothing below U+00A0 changes. }
  Plain := True;
  for Index := 1 to Length(Text) do
    if Ord(Text[Index]) >= $A0 then
    begin
      Plain := False;
      Break;
    end;
  if Plain then
    Exit(Text);
  PrepareTables;
  Points := nil;
  Count := 0;
  Index := 1;
  while Index <= Length(Text) do
  begin
    CodePoint := Ord(Text[Index]);
    if (CodePoint >= $D800) and (CodePoint <= $DBFF) and (Index < Length(Text)) and (Ord(Text[Index + 1]) >= $DC00) and
      (Ord(Text[Index + 1]) <= $DFFF) then
    begin
      CodePoint := $10000 + ((CodePoint - $D800) shl 10) + (Ord(Text[Index + 1]) - $DC00);
      Inc(Index);
    end;
    Decompose(CodePoint, Form in [nfKC, nfKD], Points, Count);
    Inc(Index);
  end;
  ReorderMarks(Points, Count);
  if Form in [nfC, nfKC] then
    Compose(Points, Count);
  Result := '';
  for Index := 0 to Count - 1 do
  begin
    CodePoint := Points[Index];
    if CodePoint >= $10000 then
    begin
      Dec(CodePoint, $10000);
      Result := Result + WideChar($D800 + (CodePoint shr 10)) + WideChar($DC00 + (CodePoint and $3FF));
    end
    else
      Result := Result + WideChar(CodePoint);
  end;
end;

end.
