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
  Fonts for SVG text: where a character's outline comes from.

  A TSvgFontSource answers, for an element's computed style and a code
  point, an outline font and its glyph. The default one, for SVG files
  shown as images (which may be decoded on any thread), uses the
  system's TrueType fonts from SvgFontDirectory: DejaVu Sans, or DejaVu
  Sans Mono for monospace families, bold from weight 600; each file is
  read once (under a lock) and kept. An embedder with its own font
  matching (libweb, for inline SVG) gives a document its own source.
}
unit Svg.Fonts;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Font.Outlines,
  Css.ComputedStyle;

type
  TSvgFontSource = class
  public
    { False when no font has the character (it is then skipped). }
    function GlyphFor(Style: TCssComputedStyle; CodePoint: LongWord; out Font: TOutlineFont;
      out Glyph: LongWord): Boolean; virtual; abstract;
  end;

  TSvgSystemFontSource = class(TSvgFontSource)
  public
    function GlyphFor(Style: TCssComputedStyle; CodePoint: LongWord; out Font: TOutlineFont;
      out Glyph: LongWord): Boolean; override;
  end;

var
  { Where the system's font families are (the host tools point it at
    userland/fonts). }
  SvgFontDirectory: string = '/lib/fonts';

{ The process's default font source. }
function SystemSvgFontSource: TSvgFontSource;

implementation

uses
  Classes,
  Css.Values,
  Css.Keywords,
  Css.PropertyIds,
  Css.ComputedValues,
  Font.TrueType;

type
  TFontSlot = (SlotSans, SlotSansBold, SlotMono, SlotMonoBold);

const
  SlotPaths: array[TFontSlot] of string = ('dejavu-sans/DejaVuSans.ttf', 'dejavu-sans/DejaVuSans-Bold.ttf',
    'dejavu-sans-mono/DejaVuSansMono.ttf', 'dejavu-sans-mono/DejaVuSansMono-Bold.ttf');

var
  FontLock: TRTLCriticalSection;
  Fonts: array[TFontSlot] of TOutlineFont;
  Tried: array[TFontSlot] of Boolean;
  SystemSource: TSvgFontSource;

function ReadFileBytes(const Path: string): TBytes;
var
  Stream: TFileStream;
begin
  Result := nil;
  try
    Stream := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
    try
      SetLength(Result, Stream.Size);
      if Length(Result) > 0 then
        Stream.ReadBuffer(Result[0], Length(Result));
    finally
      Stream.Free;
    end;
  except
    Result := nil;
  end;
end;

function FontInSlot(Slot: TFontSlot): TOutlineFont;
var
  Data: TBytes;
begin
  EnterCriticalSection(FontLock);
  try
    if not Tried[Slot] then
    begin
      Tried[Slot] := True;
      Data := ReadFileBytes(IncludeTrailingPathDelimiter(SvgFontDirectory) + SlotPaths[Slot]);
      if Data <> nil then
        Fonts[Slot] := LoadTrueTypeFont(Data);
    end;
    Result := Fonts[Slot];
  finally
    LeaveCriticalSection(FontLock);
  end;
end;

function WantsMonospace(Style: TCssComputedStyle): Boolean;
var
  Families: PCssComputedValue;
  Index: Integer;
  Item: TCssValue;
  Name: string;
begin
  Result := False;
  Families := Style.Value(cpFontFamily);
  if (Families^.Kind <> cvValue) or (Families^.Data = nil) then
    Exit;
  for Index := 0 to Families^.Data.Count - 1 do
  begin
    Item := Families^.Data.Items[Index];
    if Item.Kind = vkKeyword then
      Exit(Item.Keyword in [kwMonospace, kwUiMonospace]);
    Name := LowerCase(Item.Text);
    if (Pos('mono', Name) > 0) or (Pos('courier', Name) > 0) or (Pos('consol', Name) > 0) then
      Exit(True);
  end;
end;

function TSvgSystemFontSource.GlyphFor(Style: TCssComputedStyle; CodePoint: LongWord; out Font: TOutlineFont;
  out Glyph: LongWord): Boolean;
var
  Bold: Boolean;
  Slot: TFontSlot;
begin
  Glyph := 0;
  Bold := (Style <> nil) and (Style.Value(cpFontWeight)^.Number >= 600);
  if (Style <> nil) and WantsMonospace(Style) then
    Slot := SlotMono
  else
    Slot := SlotSans;
  if Bold then
    Slot := Succ(Slot);
  Font := FontInSlot(Slot);
  if (Font = nil) and Bold then
    Font := FontInSlot(Pred(Slot));
  if (Font = nil) and (Slot in [SlotMono, SlotMonoBold]) then
    Font := FontInSlot(SlotSans);
  if Font = nil then
    Exit(False);
  Glyph := Font.GlyphOf(CodePoint);
  Result := Glyph <> 0;
end;

function SystemSvgFontSource: TSvgFontSource;
begin
  Result := SystemSource;
end;

procedure FreeFonts;
var
  Slot: TFontSlot;
begin
  for Slot := Low(TFontSlot) to High(TFontSlot) do
    FreeAndNil(Fonts[Slot]);
end;

initialization
  InitCriticalSection(FontLock);
  SystemSource := TSvgSystemFontSource.Create;

finalization
  SystemSource.Free;
  FreeFonts;
  DoneCriticalSection(FontLock);

end.
