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
  The text a page shows, as painted: every text run of the display list
  (Web.Paint.DisplayList) with its place in the document (CSS pixels,
  inner scroll offsets applied; fixed runs in viewport coordinates),
  so the web view can map the pointer to a place in the text, select,
  copy and find. A text-shadow's copy of a run is not listed twice.

  A position is a run and a byte offset in it (0 to its length). The
  page's text flattened for copying and finding joins the runs in
  painting order, with a line break where a run starts a new line.
  Character places within a run come from the font's glyph placement
  (kerning included) plus the run's letter and word spacing, as the
  painter draws them. Text in a transformed or sticky group is placed
  where it is shown (WebView.TextGroups): the pointer is mapped into the
  group to find a place, and a range's rectangles out of it.
}
unit WebView.TextIndex;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Web.Layout.Boxes,
  Web.Text.FontInstances,
  Web.Paint.DisplayList,
  WebView.TextGroups;

type
  TTextPosition = record
    Run: Integer;
    Offset: Integer;
  end;

  TTextRunEntry = record
    Box: TTextBox;
    Font: TTextFont;
    { 1 based, bytes of Box.Text. }
    TextStart, TextLength: Integer;
    X, Y, Width, Height: Single;
    SpaceExtra, LetterExtra: Single;
    Fixed: Boolean;
    { The innermost transform or sticky group (TTextGroups), -1: none. }
    Group: Integer;
    { Where each byte offset starts (relative to X), made when first
      needed: TextLength + 1 entries. }
    Places: array of Single;
  end;
  PTextRunEntry = ^TTextRunEntry;

  TTextRectangle = record
    X, Y, Width, Height: Single;
    Fixed: Boolean;
  end;
  TTextRectangleArray = array of TTextRectangle;

  { A match of find: [Start, Finish]. }
  TTextMatch = record
    Start, Finish: TTextPosition;
  end;
  TTextMatchArray = array of TTextMatch;

  TPageTextIndex = class
  private
    FRuns: array of TTextRunEntry;
    FCount: Integer;
    FFlat: string;
    FFlatStarts: array of Integer;
    FFlatValid: Boolean;
    FGroups: TTextGroups;
    procedure AddRun(List: TDisplayList; constref Item: TDisplayItem; Fixed: Boolean);
    procedure EnsurePlaces(Index: Integer);
    procedure EnsureFlat;
    function StartsLine(Index: Integer): Boolean;
    function FlatToPosition(FlatIndex: Integer): TTextPosition;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Clear;
    { Lists the text runs of List. }
    procedure Build(List: TDisplayList);
    { The nearest place in the text to a document point (CSS px; fixed
      runs are compared at the point less the scroll offset, grouped
      runs in their group's coordinates). Run -1 when the page has no
      text. }
    function PositionAt(X, Y: Single; constref View: TTextViewport): TTextPosition;
    { The X of a byte offset of a run, relative to the run's X. }
    function OffsetPlace(Run, Offset: Integer): Single;
    function Run(Index: Integer): PTextRunEntry;
    function RunText(Index: Integer): string;
    { -1, 0 or 1. }
    class function Compare(constref A, B: TTextPosition): Integer; static;
    { The text from A to B (in either order), lines broken. }
    function TextBetween(constref A, B: TTextPosition): string;
    { The rectangles (document CSS px; viewport px for fixed runs) A to
      B covers, one per run, where View shows them. }
    function RangeRectangles(constref A, B: TTextPosition; constref View: TTextViewport): TTextRectangleArray;
    { The first match of Needle after From (forward) or before it, as
      [MatchStart, MatchEnd]; wraps around once. }
    function Find(const Needle: string; constref From: TTextPosition; Forward, MatchCase: Boolean;
      out MatchStart, MatchEnd: TTextPosition): Boolean;
    { The same, and whether it wrapped: the match is before From
      (forward) or after it (backward), found from the other end. }
    function FindWrapping(const Needle: string; constref From: TTextPosition; Forward, MatchCase: Boolean;
      out MatchStart, MatchEnd: TTextPosition; out Wrapped: Boolean): Boolean;
    { Every match of Needle in the page (not overlapping), in order; at
      most Limit of them. }
    function AllMatches(const Needle: string; MatchCase: Boolean; Limit: Integer): TTextMatchArray;
    { The whole page's text. }
    function AllText: string;
    function FirstPosition: TTextPosition;
    function LastPosition: TTextPosition;
    { The word around a position (double click). }
    procedure WordAround(constref Position: TTextPosition; out WordStart, WordEnd: TTextPosition);
    { The line around a position (triple click): the runs from the last
      one starting a line at or before it to the one before the next. }
    procedure LineAround(constref Position: TTextPosition; out LineStart, LineEnd: TTextPosition);
    property Count: Integer read FCount;
  end;

function TextPosition(Run, Offset: Integer): TTextPosition;

implementation

uses
  Math;

function TextPosition(Run, Offset: Integer): TTextPosition;
begin
  Result.Run := Run;
  Result.Offset := Offset;
end;

{ The bytes of the UTF-8 character starting with Lead. }
function CharacterBytes(Lead: Byte): Integer;
begin
  if Lead < $80 then
    Result := 1
  else if Lead >= $F0 then
    Result := 4
  else if Lead >= $E0 then
    Result := 3
  else if Lead >= $C0 then
    Result := 2
  else
    Result := 1;
end;

constructor TPageTextIndex.Create;
begin
  inherited Create;
  FGroups := TTextGroups.Create;
end;

destructor TPageTextIndex.Destroy;
begin
  FGroups.Free;
  inherited Destroy;
end;

procedure TPageTextIndex.Clear;
begin
  FGroups.Clear;
  FRuns := nil;
  FCount := 0;
  FFlat := '';
  FFlatStarts := nil;
  FFlatValid := False;
end;

procedure TPageTextIndex.AddRun(List: TDisplayList; constref Item: TDisplayItem; Fixed: Boolean);
var
  TextRun: TTextRun;
  Entry: PTextRunEntry;
begin
  TextRun := List.Texts[Item.Index];
  if (TextRun.Box = nil) or (TextRun.TextLength <= 0) then
    Exit;
  { A text-shadow's copy comes just before the text itself: the text
    replaces it. }
  if (FCount > 0) and (FRuns[FCount - 1].Box = TextRun.Box) and (FRuns[FCount - 1].TextStart = TextRun.TextStart) then
    Dec(FCount);
  if FCount = Length(FRuns) then
    SetLength(FRuns, Max(64, FCount * 2));
  Entry := @FRuns[FCount];
  Entry^.Box := TextRun.Box;
  Entry^.Font := TextRun.Font;
  Entry^.TextStart := TextRun.TextStart;
  Entry^.TextLength := TextRun.TextLength;
  Entry^.X := Item.X;
  Entry^.Y := Item.Y;
  Entry^.Width := Item.Width;
  Entry^.Height := Item.Height;
  Entry^.SpaceExtra := TextRun.SpaceExtra;
  Entry^.LetterExtra := TextRun.LetterExtra;
  Entry^.Fixed := Fixed;
  Entry^.Group := FGroups.Current;
  Entry^.Places := nil;
  Inc(FCount);
end;

procedure TPageTextIndex.Build(List: TDisplayList);
var
  Index, FixedDepth: Integer;
  Item: PDisplayItem;
begin
  Clear;
  FixedDepth := 0;
  for Index := 0 to List.Count - 1 do
  begin
    Item := @List.Items[Index];
    case Item^.Kind of
      diPushFixed:
        Inc(FixedDepth);
      diPopFixed:
        if FixedDepth > 0 then
          Dec(FixedDepth);
      diPushTransform:
        FGroups.PushTransform(List.Transforms[Item^.Index]);
      diPushSticky:
        FGroups.PushSticky(List.Stickies[Item^.Index], Item^.X, Item^.Y, Item^.Width, Item^.Height, FixedDepth > 0);
      diPopTransform, diPopSticky:
        FGroups.Pop;
      diText:
        AddRun(List, Item^, FixedDepth > 0);
    end;
  end;
end;

function TPageTextIndex.Run(Index: Integer): PTextRunEntry;
begin
  Result := @FRuns[Index];
end;

function TPageTextIndex.RunText(Index: Integer): string;
begin
  Result := Copy(FRuns[Index].Box.Text, FRuns[Index].TextStart, FRuns[Index].TextLength);
end;

procedure TPageTextIndex.EnsurePlaces(Index: Integer);
var
  Entry: PTextRunEntry;
  Glyphs: TPlacedGlyphArray;
  GlyphCount, Glyph, Offset, Bytes, Spaces, Characters, Fill: Integer;
  Text: string;
  Width, Place: Single;
begin
  Entry := @FRuns[Index];
  if Entry^.Places <> nil then
    Exit;
  SetLength(Entry^.Places, Entry^.TextLength + 1);
  Glyphs := nil;
  Text := Entry^.Box.Text;
  Width := Entry^.Font.PlaceGlyphs(Text, Entry^.TextStart, Entry^.TextLength, Glyphs, GlyphCount);
  Offset := 0;
  Glyph := 0;
  Spaces := 0;
  Characters := 0;
  while Offset < Entry^.TextLength do
  begin
    if Glyph < GlyphCount then
      Place := Glyphs[Glyph].X
    else
      Place := Width;
    Place := Place + Spaces * Entry^.SpaceExtra + Characters * Entry^.LetterExtra;
    Bytes := CharacterBytes(Ord(Text[Entry^.TextStart + Offset]));
    for Fill := 0 to Bytes - 1 do
      if Offset + Fill <= Entry^.TextLength then
        Entry^.Places[Offset + Fill] := Place;
    if Text[Entry^.TextStart + Offset] = ' ' then
      Inc(Spaces);
    Inc(Characters);
    Inc(Glyph);
    Inc(Offset, Bytes);
  end;
  Entry^.Places[Entry^.TextLength] := Max(Entry^.Width, Width + Spaces * Entry^.SpaceExtra +
    Characters * Entry^.LetterExtra);
end;

function TPageTextIndex.OffsetPlace(Run, Offset: Integer): Single;
begin
  EnsurePlaces(Run);
  Offset := EnsureRange(Offset, 0, FRuns[Run].TextLength);
  Result := FRuns[Run].Places[Offset];
end;

function TPageTextIndex.PositionAt(X, Y: Single; constref View: TTextViewport): TTextPosition;
var
  Index, Best, Offset, Bytes: Integer;
  Entry: PTextRunEntry;
  PointX, PointY, Distance, BestDistance, DeltaX, DeltaY, Middle, BestX: Single;
  Text: string;
begin
  Result := TextPosition(-1, 0);
  Best := -1;
  BestX := X;
  BestDistance := MaxSingle;
  for Index := 0 to FCount - 1 do
  begin
    Entry := @FRuns[Index];
    PointX := X;
    PointY := Y;
    if Entry^.Fixed then
    begin
      PointX := X - View.ScrollX;
      PointY := Y - View.ScrollY;
    end;
    if (Entry^.Group >= 0) and not FGroups.ToGroup(Entry^.Group, View, PointX, PointY) then
      Continue;
    DeltaY := 0;
    if PointY < Entry^.Y then
      DeltaY := Entry^.Y - PointY
    else if PointY > Entry^.Y + Entry^.Height then
      DeltaY := PointY - (Entry^.Y + Entry^.Height);
    DeltaX := 0;
    if PointX < Entry^.X then
      DeltaX := Entry^.X - PointX
    else if PointX > Entry^.X + Entry^.Width then
      DeltaX := PointX - (Entry^.X + Entry^.Width);
    { Lines count before columns: the line under the pointer wins. }
    Distance := DeltaY * 1000 + DeltaX;
    if Distance < BestDistance then
    begin
      BestDistance := Distance;
      Best := Index;
      BestX := PointX;
      if Distance = 0 then
        Break;
    end;
  end;
  if Best < 0 then
    Exit;
  Entry := @FRuns[Best];
  PointX := BestX;
  EnsurePlaces(Best);
  Text := Entry^.Box.Text;
  Offset := 0;
  while Offset < Entry^.TextLength do
  begin
    Bytes := CharacterBytes(Ord(Text[Entry^.TextStart + Offset]));
    Middle := (Entry^.Places[Offset] + Entry^.Places[Min(Offset + Bytes, Entry^.TextLength)]) / 2;
    if PointX - Entry^.X < Middle then
      Break;
    Inc(Offset, Bytes);
  end;
  Result := TextPosition(Best, Offset);
end;

class function TPageTextIndex.Compare(constref A, B: TTextPosition): Integer;
begin
  if A.Run <> B.Run then
    Result := Sign(A.Run - B.Run)
  else
    Result := Sign(A.Offset - B.Offset);
end;

function TPageTextIndex.StartsLine(Index: Integer): Boolean;
var
  Previous, Current: PTextRunEntry;
begin
  if Index = 0 then
    Exit(False);
  Previous := @FRuns[Index - 1];
  Current := @FRuns[Index];
  Result := (Current^.Y >= Previous^.Y + Previous^.Height * 0.6) or
    (Current^.Y + Current^.Height <= Previous^.Y + Previous^.Height * 0.4) or
    (Current^.X + 0.5 < Previous^.X);
end;

function TPageTextIndex.TextBetween(constref A, B: TTextPosition): string;
var
  First, Last: TTextPosition;
  Index, FromOffset, ToOffset: Integer;
begin
  Result := '';
  if (FCount = 0) or (A.Run < 0) or (B.Run < 0) then
    Exit;
  if Compare(A, B) <= 0 then
  begin
    First := A;
    Last := B;
  end
  else
  begin
    First := B;
    Last := A;
  end;
  for Index := First.Run to Last.Run do
  begin
    FromOffset := 0;
    ToOffset := FRuns[Index].TextLength;
    if Index = First.Run then
      FromOffset := First.Offset;
    if Index = Last.Run then
      ToOffset := Last.Offset;
    if (Index > First.Run) and StartsLine(Index) then
      Result := TrimRight(Result) + LineEnding;
    if ToOffset > FromOffset then
      Result := Result + Copy(FRuns[Index].Box.Text, FRuns[Index].TextStart + FromOffset, ToOffset - FromOffset);
  end;
end;

function TPageTextIndex.RangeRectangles(constref A, B: TTextPosition; constref View: TTextViewport):
  TTextRectangleArray;
var
  First, Last: TTextPosition;
  Index, FromOffset, ToOffset, Used: Integer;
  Left, Right: Single;
begin
  Result := nil;
  if (FCount = 0) or (A.Run < 0) or (B.Run < 0) or (Compare(A, B) = 0) then
    Exit;
  if Compare(A, B) < 0 then
  begin
    First := A;
    Last := B;
  end
  else
  begin
    First := B;
    Last := A;
  end;
  SetLength(Result, Last.Run - First.Run + 1);
  Used := 0;
  for Index := First.Run to Last.Run do
  begin
    FromOffset := 0;
    ToOffset := FRuns[Index].TextLength;
    if Index = First.Run then
      FromOffset := First.Offset;
    if Index = Last.Run then
      ToOffset := Last.Offset;
    if ToOffset <= FromOffset then
      Continue;
    Left := OffsetPlace(Index, FromOffset);
    Right := OffsetPlace(Index, ToOffset);
    Result[Used].X := FRuns[Index].X + Left;
    Result[Used].Y := FRuns[Index].Y;
    Result[Used].Width := Right - Left;
    Result[Used].Height := FRuns[Index].Height;
    Result[Used].Fixed := FRuns[Index].Fixed;
    if FRuns[Index].Group >= 0 then
      FGroups.RectangleToPage(FRuns[Index].Group, View, Result[Used].X, Result[Used].Y, Result[Used].Width,
        Result[Used].Height);
    Inc(Used);
  end;
  SetLength(Result, Used);
end;

procedure TPageTextIndex.EnsureFlat;
var
  Index: Integer;
begin
  if FFlatValid then
    Exit;
  FFlat := '';
  SetLength(FFlatStarts, FCount);
  for Index := 0 to FCount - 1 do
  begin
    if StartsLine(Index) then
      FFlat := FFlat + #10;
    FFlatStarts[Index] := Length(FFlat);
    FFlat := FFlat + RunText(Index);
  end;
  FFlatValid := True;
end;

function TPageTextIndex.FlatToPosition(FlatIndex: Integer): TTextPosition;
var
  Low_, High_, Middle: Integer;
begin
  { The last run starting at or before FlatIndex (0 based). }
  Low_ := 0;
  High_ := FCount - 1;
  while Low_ < High_ do
  begin
    Middle := (Low_ + High_ + 1) div 2;
    if FFlatStarts[Middle] <= FlatIndex then
      Low_ := Middle
    else
      High_ := Middle - 1;
  end;
  Result := TextPosition(Low_, EnsureRange(FlatIndex - FFlatStarts[Low_], 0, FRuns[Low_].TextLength));
end;

function TPageTextIndex.Find(const Needle: string; constref From: TTextPosition; Forward, MatchCase: Boolean;
  out MatchStart, MatchEnd: TTextPosition): Boolean;
var
  Wrapped: Boolean;
begin
  Result := FindWrapping(Needle, From, Forward, MatchCase, MatchStart, MatchEnd, Wrapped);
end;

{ The match at a flat index (0 based) of Count bytes, a match ending
  where a run starts ending at the end of the run before. }
procedure MatchAt(Index: TPageTextIndex; FlatIndex, Count: Integer; out MatchStart, MatchEnd: TTextPosition);
begin
  MatchStart := Index.FlatToPosition(FlatIndex);
  MatchEnd := Index.FlatToPosition(FlatIndex + Count);
  if (MatchEnd.Offset = 0) and (MatchEnd.Run > MatchStart.Run) then
    MatchEnd := TextPosition(MatchEnd.Run - 1, Index.FRuns[MatchEnd.Run - 1].TextLength);
end;

function TPageTextIndex.AllMatches(const Needle: string; MatchCase: Boolean; Limit: Integer): TTextMatchArray;
var
  Haystack, Wanted: string;
  Found, MatchCount: Integer;
begin
  Result := nil;
  if (Needle = '') or (FCount = 0) or (Limit <= 0) then
    Exit;
  EnsureFlat;
  Haystack := FFlat;
  Wanted := Needle;
  if not MatchCase then
  begin
    Haystack := LowerCase(Haystack);
    Wanted := LowerCase(Wanted);
  end;
  MatchCount := 0;
  Found := Pos(Wanted, Haystack);
  while (Found > 0) and (MatchCount < Limit) do
  begin
    if MatchCount = Length(Result) then
      SetLength(Result, MatchCount * 2 + 8);
    MatchAt(Self, Found - 1, Length(Wanted), Result[MatchCount].Start, Result[MatchCount].Finish);
    Inc(MatchCount);
    Found := Pos(Wanted, Haystack, Found + Length(Wanted));
  end;
  SetLength(Result, MatchCount);
end;

function TPageTextIndex.FindWrapping(const Needle: string; constref From: TTextPosition; Forward, MatchCase: Boolean;
  out MatchStart, MatchEnd: TTextPosition; out Wrapped: Boolean): Boolean;
var
  Haystack, Wanted: string;
  Start, Found, Candidate: Integer;
begin
  Result := False;
  Wrapped := False;
  MatchStart := TextPosition(-1, 0);
  MatchEnd := MatchStart;
  if (Needle = '') or (FCount = 0) then
    Exit;
  EnsureFlat;
  Haystack := FFlat;
  Wanted := Needle;
  if not MatchCase then
  begin
    Haystack := LowerCase(Haystack);
    Wanted := LowerCase(Wanted);
  end;
  if From.Run >= 0 then
    Start := FFlatStarts[EnsureRange(From.Run, 0, FCount - 1)] + From.Offset
  else if Forward then
    Start := 0
  else
    Start := Length(Haystack);
  Found := 0;
  if Forward then
  begin
    { Pos is 1 based; Start is the 0 based index matches may begin at. }
    Found := Pos(Wanted, Haystack, Start + 1);
    if Found = 0 then
    begin
      Found := Pos(Wanted, Haystack);
      Wrapped := (Found > 0) and (From.Run >= 0);
    end;
  end
  else
  begin
    Candidate := Pos(Wanted, Haystack);
    while (Candidate > 0) and (Candidate - 1 + Length(Wanted) <= Start) do
    begin
      Found := Candidate;
      Candidate := Pos(Wanted, Haystack, Candidate + 1);
    end;
    if Found = 0 then
    begin
      while Candidate > 0 do
      begin
        Found := Candidate;
        Candidate := Pos(Wanted, Haystack, Candidate + 1);
      end;
      Wrapped := (Found > 0) and (From.Run >= 0);
    end;
  end;
  if Found = 0 then
    Exit;
  MatchAt(Self, Found - 1, Length(Wanted), MatchStart, MatchEnd);
  Result := True;
end;

function TPageTextIndex.AllText: string;
begin
  if FCount = 0 then
    Exit('');
  Result := TextBetween(FirstPosition, LastPosition);
end;

function TPageTextIndex.FirstPosition: TTextPosition;
begin
  if FCount = 0 then
    Result := TextPosition(-1, 0)
  else
    Result := TextPosition(0, 0);
end;

function TPageTextIndex.LastPosition: TTextPosition;
begin
  if FCount = 0 then
    Result := TextPosition(-1, 0)
  else
    Result := TextPosition(FCount - 1, FRuns[FCount - 1].TextLength);
end;

function IsWordByte(Character: Char): Boolean;
begin
  Result := (Character in ['0'..'9', 'A'..'Z', 'a'..'z', '_', '-', '''']) or (Ord(Character) >= $80);
end;

procedure TPageTextIndex.WordAround(constref Position: TTextPosition; out WordStart, WordEnd: TTextPosition);
var
  Text: string;
  First, Last: Integer;
begin
  WordStart := Position;
  WordEnd := Position;
  if (Position.Run < 0) or (Position.Run >= FCount) then
    Exit;
  Text := RunText(Position.Run);
  First := Position.Offset;
  Last := Position.Offset;
  while (First > 0) and IsWordByte(Text[First]) do
    Dec(First);
  while (Last < Length(Text)) and IsWordByte(Text[Last + 1]) do
    Inc(Last);
  WordStart := TextPosition(Position.Run, First);
  WordEnd := TextPosition(Position.Run, Last);
end;

procedure TPageTextIndex.LineAround(constref Position: TTextPosition; out LineStart, LineEnd: TTextPosition);
var
  First, Last: Integer;
begin
  LineStart := Position;
  LineEnd := Position;
  if (Position.Run < 0) or (Position.Run >= FCount) then
    Exit;
  First := Position.Run;
  while (First > 0) and not StartsLine(First) do
    Dec(First);
  Last := Position.Run;
  while (Last + 1 < FCount) and not StartsLine(Last + 1) do
    Inc(Last);
  LineStart := TextPosition(First, 0);
  LineEnd := TextPosition(Last, FRuns[Last].TextLength);
end;

end.
