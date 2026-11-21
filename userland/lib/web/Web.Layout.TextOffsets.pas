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
  Offsets between a text node's data and the text its box shows (white
  space collapsed, leading spaces dropped, text-transform applied): the
  DOM's offsets (UTF-16 code units of the source) against byte offsets
  of the rendered text, for ranges and the selection (script's ranges
  get rectangles, the user's selection becomes a DOM range and back).

  The two are walked side by side a character at a time: white space in
  the source that the rendered text has no white space for was
  collapsed away; otherwise a character stands for a character (a case
  mapping that changes the number of characters is off by those).
}
unit Web.Layout.TextOffsets;

{$mode objfpc}
{$H+}

interface

{ The rendered byte offset (0 based) for a source offset in UTF-16 code
  units. }
function SourceToRenderedOffset(const Source, Rendered: string; SourceOffset: Integer): Integer;
{ The source offset (UTF-16 code units) for a rendered byte offset. }
function RenderedToSourceOffset(const Source, Rendered: string; RenderedOffset: Integer): Integer;

implementation

function CharacterBytes(Lead: Char): Integer; inline;
begin
  if Ord(Lead) < $80 then
    Result := 1
  else if Ord(Lead) >= $F0 then
    Result := 4
  else if Ord(Lead) >= $E0 then
    Result := 3
  else if Ord(Lead) >= $C0 then
    Result := 2
  else
    Result := 1;
end;

function IsSpace(C: Char): Boolean; inline;
begin
  Result := C in [' ', #9, #10, #12, #13];
end;

type
  TWalk = record
    SourceByte, RenderedByte, SourceUnits: Integer;
  end;

{ One step: moves the source, the rendered text or both by a character. }
procedure Step(const Source, Rendered: string; var Walk: TWalk);
var
  SourceBytes: Integer;
  SourceSpace, RenderedSpace, SourceLeft, RenderedLeft: Boolean;
begin
  SourceLeft := Walk.SourceByte < Length(Source);
  RenderedLeft := Walk.RenderedByte < Length(Rendered);
  SourceSpace := SourceLeft and IsSpace(Source[Walk.SourceByte + 1]);
  RenderedSpace := RenderedLeft and IsSpace(Rendered[Walk.RenderedByte + 1]);
  if SourceLeft and (not RenderedLeft or (SourceSpace and not RenderedSpace)) then
  begin
    { Collapsed away. }
    SourceBytes := CharacterBytes(Source[Walk.SourceByte + 1]);
    Inc(Walk.SourceByte, SourceBytes);
    if SourceBytes = 4 then
      Inc(Walk.SourceUnits, 2)
    else
      Inc(Walk.SourceUnits);
    Exit;
  end;
  if RenderedLeft and (not SourceLeft or (RenderedSpace and not SourceSpace)) then
  begin
    Inc(Walk.RenderedByte, CharacterBytes(Rendered[Walk.RenderedByte + 1]));
    Exit;
  end;
  SourceBytes := CharacterBytes(Source[Walk.SourceByte + 1]);
  Inc(Walk.SourceByte, SourceBytes);
  if SourceBytes = 4 then
    Inc(Walk.SourceUnits, 2)
  else
    Inc(Walk.SourceUnits);
  Inc(Walk.RenderedByte, CharacterBytes(Rendered[Walk.RenderedByte + 1]));
end;

function SourceToRenderedOffset(const Source, Rendered: string; SourceOffset: Integer): Integer;
var
  Walk: TWalk;
begin
  Walk.SourceByte := 0;
  Walk.RenderedByte := 0;
  Walk.SourceUnits := 0;
  while (Walk.SourceUnits < SourceOffset) and ((Walk.SourceByte < Length(Source)) or
    (Walk.RenderedByte < Length(Rendered))) do
  begin
    if Walk.SourceByte >= Length(Source) then
      Break;
    Step(Source, Rendered, Walk);
  end;
  Result := Walk.RenderedByte;
  if Result > Length(Rendered) then
    Result := Length(Rendered);
end;

function RenderedToSourceOffset(const Source, Rendered: string; RenderedOffset: Integer): Integer;
var
  Walk: TWalk;
begin
  Walk.SourceByte := 0;
  Walk.RenderedByte := 0;
  Walk.SourceUnits := 0;
  while (Walk.RenderedByte < RenderedOffset) and (Walk.RenderedByte < Length(Rendered)) do
    Step(Source, Rendered, Walk);
  { Source white space right after the place belongs before it. }
  Result := Walk.SourceUnits;
end;

end.
