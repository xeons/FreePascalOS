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
  Finding out what a document is encoded in:

  - BOM sniffing (Encoding Standard): EF BB BF, FE FF, FF FE;
  - the HTML encoding sniffing algorithm: the BOM, then the transport
    layer's charset (certain), then the meta prescan of the first 1024
    bytes (tentative), then the default, windows-1252 (tentative);
  - the prescan itself, with its "get an attribute" algorithm, and the
    algorithm for extracting an encoding from a meta element's content
    attribute (also used by the tree builder for a meta it inserts).
}
unit Web.Encoding.Sniffing;

{$mode objfpc}
{$H+}

interface

uses
  Web.Encoding.Labels;

const
  { How many bytes the prescan looks at. }
  PrescanLength = 1024;

type
  TEncodingConfidence = (ConfidenceTentative, ConfidenceCertain, ConfidenceIrrelevant);

{ BOM sniff: the encoding a byte order mark names and its length. }
function SniffByteOrderMark(Bytes: PByte; Count: SizeInt; out Encoding: TTextEncoding;
  out MarkLength: Integer): Boolean;
{ The meta prescan over the first bytes of a document. }
function PrescanForEncoding(Bytes: PByte; Count: SizeInt; out Encoding: TTextEncoding): Boolean;
{ The encoding named by a meta element's content attribute ("text/html;
  charset=koi8-r"), if any. }
function ExtractEncodingFromContent(const Content: string; out Encoding: TTextEncoding): Boolean;
{ The encoding sniffing algorithm over the first bytes (at least 1024 of
  them or all there are); TransportCharset is the Content-Type charset,
  '' if none. MarkLength is the length of a BOM to skip. }
function SniffHtmlEncoding(Bytes: PByte; Count: SizeInt; const TransportCharset: string;
  out Confidence: TEncodingConfidence; out MarkLength: Integer): TTextEncoding;

implementation

uses
  SysUtils;

function SniffByteOrderMark(Bytes: PByte; Count: SizeInt; out Encoding: TTextEncoding;
  out MarkLength: Integer): Boolean;
begin
  Encoding := TextEncodingUtf8;
  MarkLength := 0;
  if (Count >= 3) and (Bytes[0] = $EF) and (Bytes[1] = $BB) and (Bytes[2] = $BF) then
  begin
    MarkLength := 3;
    Exit(True);
  end;
  if (Count >= 2) and (Bytes[0] = $FE) and (Bytes[1] = $FF) then
  begin
    Encoding := TextEncodingUtf16Be;
    MarkLength := 2;
    Exit(True);
  end;
  if (Count >= 2) and (Bytes[0] = $FF) and (Bytes[1] = $FE) then
  begin
    Encoding := TextEncodingUtf16Le;
    MarkLength := 2;
    Exit(True);
  end;
  Result := False;
end;

type
  TPrescanner = record
    Bytes: PByte;
    Count: SizeInt;
    Position: SizeInt;
  end;

function IsSpaceByte(Value: Byte): Boolean; inline;
begin
  Result := Value in [$09, $0A, $0C, $0D, $20];
end;

function LowerByte(Value: Byte): Char; inline;
begin
  if Value in [Ord('A')..Ord('Z')] then
    Result := Chr(Value + 32)
  else
    Result := Chr(Value);
end;

function MatchesAt(var Scanner: TPrescanner; const Text: string): Boolean;
var
  Index: Integer;
begin
  if Scanner.Position + Length(Text) > Scanner.Count then
    Exit(False);
  for Index := 1 to Length(Text) do
    if LowerByte(Scanner.Bytes[Scanner.Position + Index - 1]) <> Text[Index] then
      Exit(False);
  Result := True;
end;

{ The prescan's "get an attribute": False when there is none (at a ">" or
  the end of the bytes). }
function GetAttribute(var Scanner: TPrescanner; out Name, Value: string): Boolean;
var
  Current, Quote: Byte;

  function AtEnd: Boolean;
  begin
    Result := Scanner.Position >= Scanner.Count;
  end;

begin
  Name := '';
  Value := '';
  while not AtEnd and (IsSpaceByte(Scanner.Bytes[Scanner.Position]) or (Scanner.Bytes[Scanner.Position] = $2F)) do
    Inc(Scanner.Position);
  if AtEnd or (Scanner.Bytes[Scanner.Position] = $3E) then
    Exit(False);
  { The name. }
  while True do
  begin
    if AtEnd then
      Exit(False);
    Current := Scanner.Bytes[Scanner.Position];
    if (Current = $3D) and (Name <> '') then
    begin
      Inc(Scanner.Position);
      Break;
    end;
    if IsSpaceByte(Current) then
    begin
      while not AtEnd and IsSpaceByte(Scanner.Bytes[Scanner.Position]) do
        Inc(Scanner.Position);
      if AtEnd then
        Exit(False);
      if Scanner.Bytes[Scanner.Position] <> $3D then
        Exit(True);
      Inc(Scanner.Position);
      Break;
    end;
    if Current in [$2F, $3E] then
      Exit(True);
    Name := Name + LowerByte(Current);
    Inc(Scanner.Position);
  end;
  { The value. }
  while not AtEnd and IsSpaceByte(Scanner.Bytes[Scanner.Position]) do
    Inc(Scanner.Position);
  if AtEnd then
    Exit(False);
  Current := Scanner.Bytes[Scanner.Position];
  if Current in [$22, $27] then
  begin
    Quote := Current;
    Inc(Scanner.Position);
    while True do
    begin
      if AtEnd then
        Exit(False);
      Current := Scanner.Bytes[Scanner.Position];
      Inc(Scanner.Position);
      if Current = Quote then
        Exit(True);
      Value := Value + LowerByte(Current);
    end;
  end;
  if Current = $3E then
    Exit(True);
  Value := Value + LowerByte(Current);
  Inc(Scanner.Position);
  while True do
  begin
    if AtEnd then
      Exit(False);
    Current := Scanner.Bytes[Scanner.Position];
    if IsSpaceByte(Current) or (Current = $3E) then
      Exit(True);
    Value := Value + LowerByte(Current);
    Inc(Scanner.Position);
  end;
end;

type
  TNeedPragma = (PragmaUnknown, PragmaNeeded, PragmaNotNeeded);

{ The attributes of a meta element; True with the encoding it declares. }
function ScanMetaAttributes(var Scanner: TPrescanner; out Encoding: TTextEncoding): Boolean;
var
  Seen: array of string;
  Name, Value: string;
  GotPragma, HaveCharset, Duplicate: Boolean;
  NeedPragma: TNeedPragma;
  Charset: TTextEncoding;
  Index: Integer;
begin
  Seen := nil;
  GotPragma := False;
  NeedPragma := PragmaUnknown;
  HaveCharset := False;
  Charset := TextEncodingUtf8;
  Encoding := TextEncodingUtf8;
  while GetAttribute(Scanner, Name, Value) do
  begin
    Duplicate := False;
    for Index := 1 to Length(Seen) do
      if Seen[Index - 1] = Name then
        Duplicate := True;
    if Duplicate then
      Continue;
    SetLength(Seen, Length(Seen) + 1);
    Seen[High(Seen)] := Name;
    if Name = 'http-equiv' then
    begin
      if Value = 'content-type' then
        GotPragma := True;
    end
    else if Name = 'content' then
    begin
      if not HaveCharset and ExtractEncodingFromContent(Value, Charset) then
      begin
        HaveCharset := True;
        NeedPragma := PragmaNeeded;
      end;
    end
    else if Name = 'charset' then
    begin
      HaveCharset := EncodingForLabel(Value, Charset);
      NeedPragma := PragmaNotNeeded;
    end;
  end;
  if NeedPragma = PragmaUnknown then
    Exit(False);
  if (NeedPragma = PragmaNeeded) and not GotPragma then
    Exit(False);
  if not HaveCharset then
    Exit(False);
  if Charset in [TextEncodingUtf16Be, TextEncodingUtf16Le] then
    Charset := TextEncodingUtf8;
  if Charset = TextEncodingXUserDefined then
    Charset := TextEncodingWindows1252;
  Encoding := Charset;
  Result := True;
end;

procedure SkipPast(var Scanner: TPrescanner; Value: Byte);
begin
  while (Scanner.Position < Scanner.Count) and (Scanner.Bytes[Scanner.Position] <> Value) do
    Inc(Scanner.Position);
end;

function PrescanForEncoding(Bytes: PByte; Count: SizeInt; out Encoding: TTextEncoding): Boolean;
var
  Scanner: TPrescanner;
  Name, Value: string;
  Next: Byte;
begin
  Encoding := TextEncodingUtf8;
  if Count > PrescanLength then
    Count := PrescanLength;
  Scanner.Bytes := Bytes;
  Scanner.Count := Count;
  Scanner.Position := 0;
  while Scanner.Position < Scanner.Count do
  begin
    if MatchesAt(Scanner, '<!--') then
    begin
      { To the ">" of a "-->", whose dashes may be those of "<!--". }
      Inc(Scanner.Position, 2);
      while (Scanner.Position + 2 < Scanner.Count) and not ((Scanner.Bytes[Scanner.Position] = $2D) and
        (Scanner.Bytes[Scanner.Position + 1] = $2D) and (Scanner.Bytes[Scanner.Position + 2] = $3E)) do
        Inc(Scanner.Position);
      if Scanner.Position + 2 >= Scanner.Count then
        Exit(False);
      Inc(Scanner.Position, 2);
    end
    else if MatchesAt(Scanner, '<meta') and (Scanner.Position + 5 < Scanner.Count) and
      (IsSpaceByte(Scanner.Bytes[Scanner.Position + 5]) or (Scanner.Bytes[Scanner.Position + 5] = $2F)) then
    begin
      Inc(Scanner.Position, 6);
      if ScanMetaAttributes(Scanner, Encoding) then
        Exit(True);
      Continue;
    end
    else if (Scanner.Bytes[Scanner.Position] = $3C) and (Scanner.Position + 1 < Scanner.Count) then
    begin
      Next := Scanner.Bytes[Scanner.Position + 1];
      if (LowerByte(Next) in ['a'..'z']) or ((Next = $2F) and (Scanner.Position + 2 < Scanner.Count) and
        (LowerByte(Scanner.Bytes[Scanner.Position + 2]) in ['a'..'z'])) then
      begin
        while (Scanner.Position < Scanner.Count) and not (IsSpaceByte(Scanner.Bytes[Scanner.Position]) or
          (Scanner.Bytes[Scanner.Position] = $3E)) do
          Inc(Scanner.Position);
        while GetAttribute(Scanner, Name, Value) do
          ;
      end
      else if Next in [$21, $2F, $3F] then
        SkipPast(Scanner, $3E);
    end;
    Inc(Scanner.Position);
  end;
  Result := False;
end;

function ExtractEncodingFromContent(const Content: string; out Encoding: TTextEncoding): Boolean;
var
  Position, Start: SizeInt;
  Lower: string;
  Quote: Char;
begin
  Encoding := TextEncodingUtf8;
  Lower := LowerCase(Content);
  Position := 1;
  while True do
  begin
    Start := Pos('charset', Copy(Lower, Position, MaxInt));
    if Start = 0 then
      Exit(False);
    Position := Position + Start - 1 + 7;
    while (Position <= Length(Content)) and (Content[Position] in [#9, #10, #12, #13, ' ']) do
      Inc(Position);
    if (Position <= Length(Content)) and (Content[Position] = '=') then
      Break;
  end;
  Inc(Position);
  while (Position <= Length(Content)) and (Content[Position] in [#9, #10, #12, #13, ' ']) do
    Inc(Position);
  if Position > Length(Content) then
    Exit(False);
  if Content[Position] in ['"', ''''] then
  begin
    Quote := Content[Position];
    Start := Position + 1;
    Position := Start;
    while (Position <= Length(Content)) and (Content[Position] <> Quote) do
      Inc(Position);
    if Position > Length(Content) then
      Exit(False);
    Exit(EncodingForLabel(Copy(Content, Start, Position - Start), Encoding));
  end;
  Start := Position;
  while (Position <= Length(Content)) and not (Content[Position] in [#9, #10, #12, #13, ' ', ';']) do
    Inc(Position);
  Result := EncodingForLabel(Copy(Content, Start, Position - Start), Encoding);
end;

function SniffHtmlEncoding(Bytes: PByte; Count: SizeInt; const TransportCharset: string;
  out Confidence: TEncodingConfidence; out MarkLength: Integer): TTextEncoding;
begin
  if SniffByteOrderMark(Bytes, Count, Result, MarkLength) then
  begin
    Confidence := ConfidenceCertain;
    Exit;
  end;
  MarkLength := 0;
  if (TransportCharset <> '') and EncodingForLabel(TransportCharset, Result) then
  begin
    Confidence := ConfidenceCertain;
    Exit;
  end;
  Confidence := ConfidenceTentative;
  if PrescanForEncoding(Bytes, Count, Result) then
    Exit;
  Result := TextEncodingWindows1252;
end;

end.
