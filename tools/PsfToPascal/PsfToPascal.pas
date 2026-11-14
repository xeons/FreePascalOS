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
  PsfToPascal: converts a PC Screen Font (PSF1 or PSF2) into a Pascal
  include file holding bitmaps for the characters the kernel console
  draws: printable ASCII, Latin-1 (U+00A0 to U+00FF) and the few other
  characters French and German text needs (OE ligatures, Y with
  diaeresis, the euro sign).

    PsfToPascal <font.psf> <output.inc>

  The font must be 8 pixels wide. Its Unicode table is used to find the
  glyph for each character; without one, glyph N is taken for code
  point N (and characters past the glyphs are left out). The include
  file lists the code points in ascending order next to their glyphs.

  This is a host tool, built with the normal Free Pascal runtime library.
}
program PsfToPascal;

{$mode objfpc}
{$H+}

uses
  SysUtils;

const
  Psf1MagicByte0 = $36;
  Psf1MagicByte1 = $04;
  Psf1ModeHas512Glyphs = $01;
  Psf1ModeHasUnicodeTable = $02;
  Psf1ModeHasSequences = $04;
  Psf1Separator = $FFFF;
  Psf1SequenceStart = $FFFE;

  Psf2Magic = $864AB572;
  Psf2FlagHasUnicodeTable = $01;
  Psf2Separator = $FF;
  Psf2SequenceStart = $FE;

  FirstPrintableCharacter = 32;
  LastPrintableCharacter = 126;
  FirstLatin1Character = $A0;
  LastLatin1Character = $FF;
  ExtraCharacters: array[0..3] of LongWord = ($152, $153, $178, $20AC);
  MaximumWanted = 256;

type
  TFontDescription = record
    GlyphCount: Integer;
    BytesPerGlyph: Integer;
    Height: Integer;
    Width: Integer;
    GlyphDataOffset: Integer;
    UnicodeTableOffset: Integer;
    HasUnicodeTable: Boolean;
    IsVersion2: Boolean;
  end;

var
  FontBytes: TBytes;
  Font: TFontDescription;
  { The code points wanted, ascending, and the glyph of each (-1: none). }
  WantedCodePoints: array[0..MaximumWanted - 1] of LongWord;
  GlyphForWanted: array[0..MaximumWanted - 1] of Integer;
  WantedCount: Integer;

procedure Fail(const Message: string);
begin
  WriteLn(StdErr, 'error: ', Message);
  Halt(1);
end;

function ReadLongWordAt(Offset: Integer): LongWord;
begin
  Result := LongWord(FontBytes[Offset]) or
    (LongWord(FontBytes[Offset + 1]) shl 8) or
    (LongWord(FontBytes[Offset + 2]) shl 16) or
    (LongWord(FontBytes[Offset + 3]) shl 24);
end;

function ReadWordAt(Offset: Integer): Word;
begin
  Result := Word(FontBytes[Offset]) or (Word(FontBytes[Offset + 1]) shl 8);
end;

procedure LoadFile(const FileName: string);
var
  InputFile: File;
  FileSize: Int64;
begin
  AssignFile(InputFile, FileName);
  Reset(InputFile, 1);
  FileSize := System.FileSize(InputFile);
  SetLength(FontBytes, FileSize);
  if FileSize > 0 then
    BlockRead(InputFile, FontBytes[0], FileSize);
  CloseFile(InputFile);
end;

procedure ParseHeader;
var
  Mode: Byte;
  Flags: LongWord;
begin
  if Length(FontBytes) < 4 then
    Fail('file is too small to be a PSF font');

  if (FontBytes[0] = Psf1MagicByte0) and (FontBytes[1] = Psf1MagicByte1) then
  begin
    Mode := FontBytes[2];
    Font.IsVersion2 := False;
    Font.BytesPerGlyph := FontBytes[3];
    Font.Height := Font.BytesPerGlyph;
    Font.Width := 8;
    if (Mode and Psf1ModeHas512Glyphs) <> 0 then
      Font.GlyphCount := 512
    else
      Font.GlyphCount := 256;
    Font.GlyphDataOffset := 4;
    Font.HasUnicodeTable := (Mode and (Psf1ModeHasUnicodeTable or Psf1ModeHasSequences)) <> 0;
  end
  else if ReadLongWordAt(0) = Psf2Magic then
  begin
    Font.IsVersion2 := True;
    Font.GlyphDataOffset := Integer(ReadLongWordAt(8));
    Flags := ReadLongWordAt(12);
    Font.GlyphCount := Integer(ReadLongWordAt(16));
    Font.BytesPerGlyph := Integer(ReadLongWordAt(20));
    Font.Height := Integer(ReadLongWordAt(24));
    Font.Width := Integer(ReadLongWordAt(28));
    Font.HasUnicodeTable := (Flags and Psf2FlagHasUnicodeTable) <> 0;
  end
  else
    Fail('not a PSF1 or PSF2 font');

  if Font.Width <> 8 then
    Fail('only 8 pixel wide fonts are supported');

  Font.UnicodeTableOffset := Font.GlyphDataOffset + Font.GlyphCount * Font.BytesPerGlyph;
  if Font.UnicodeTableOffset > Length(FontBytes) then
    Fail('glyph data is truncated');
end;

procedure RecordMapping(CodePoint: LongWord; GlyphIndex: Integer);
var
  Index: Integer;
begin
  for Index := 0 to WantedCount - 1 do
    if (WantedCodePoints[Index] = CodePoint) and (GlyphForWanted[Index] < 0) then
      GlyphForWanted[Index] := GlyphIndex;
end;

procedure AddWanted(CodePoint: LongWord);
begin
  WantedCodePoints[WantedCount] := CodePoint;
  GlyphForWanted[WantedCount] := -1;
  Inc(WantedCount);
end;

procedure ParseVersion1UnicodeTable;
var
  Offset: Integer;
  GlyphIndex: Integer;
  Value: Word;
  InsideSequence: Boolean;
begin
  Offset := Font.UnicodeTableOffset;
  GlyphIndex := 0;
  InsideSequence := False;

  while (Offset + 1 < Length(FontBytes)) and (GlyphIndex < Font.GlyphCount) do
  begin
    Value := ReadWordAt(Offset);
    Inc(Offset, 2);

    if Value = Psf1Separator then
    begin
      Inc(GlyphIndex);
      InsideSequence := False;
    end
    else if Value = Psf1SequenceStart then
      InsideSequence := True
    else if not InsideSequence then
      RecordMapping(Value, GlyphIndex);
  end;
end;

{ The table holds UTF-8 encoded code points; sequences (combining
  forms) are skipped over. }
procedure ParseVersion2UnicodeTable;
var
  Offset: Integer;
  GlyphIndex: Integer;
  Value: Byte;
  InsideSequence: Boolean;
  CodePoint: LongWord;
  Continuation: Integer;
begin
  Offset := Font.UnicodeTableOffset;
  GlyphIndex := 0;
  InsideSequence := False;

  while (Offset < Length(FontBytes)) and (GlyphIndex < Font.GlyphCount) do
  begin
    Value := FontBytes[Offset];
    Inc(Offset);

    if Value = Psf2Separator then
    begin
      Inc(GlyphIndex);
      InsideSequence := False;
      Continue;
    end;
    if Value = Psf2SequenceStart then
    begin
      InsideSequence := True;
      Continue;
    end;
    { Decode one UTF-8 character. }
    if Value < $80 then
    begin
      CodePoint := Value;
      Continuation := 0;
    end
    else if (Value and $E0) = $C0 then
    begin
      CodePoint := Value and $1F;
      Continuation := 1;
    end
    else if (Value and $F0) = $E0 then
    begin
      CodePoint := Value and $0F;
      Continuation := 2;
    end
    else
    begin
      CodePoint := Value and $07;
      Continuation := 3;
    end;
    while (Continuation > 0) and (Offset < Length(FontBytes)) do
    begin
      CodePoint := (CodePoint shl 6) or (FontBytes[Offset] and $3F);
      Inc(Offset);
      Dec(Continuation);
    end;
    if not InsideSequence then
      RecordMapping(CodePoint, GlyphIndex);
  end;
end;

procedure BuildCharacterMap;
var
  Character: LongWord;
  Index: Integer;
  Kept: Integer;
begin
  WantedCount := 0;
  for Character := FirstPrintableCharacter to LastPrintableCharacter do
    AddWanted(Character);
  for Character := FirstLatin1Character to LastLatin1Character do
    AddWanted(Character);
  for Index := Low(ExtraCharacters) to High(ExtraCharacters) do
    AddWanted(ExtraCharacters[Index]);

  if Font.HasUnicodeTable then
  begin
    if Font.IsVersion2 then
      ParseVersion2UnicodeTable
    else
      ParseVersion1UnicodeTable;
  end
  else
    for Index := 0 to WantedCount - 1 do
      if WantedCodePoints[Index] < LongWord(Font.GlyphCount) then
        GlyphForWanted[Index] := Integer(WantedCodePoints[Index]);

  { Characters the font lacks are left out. }
  Kept := 0;
  for Index := 0 to WantedCount - 1 do
    if GlyphForWanted[Index] >= 0 then
    begin
      WantedCodePoints[Kept] := WantedCodePoints[Index];
      GlyphForWanted[Kept] := GlyphForWanted[Index];
      Inc(Kept);
    end;
  WantedCount := Kept;
end;

function DescribeCodePoint(CodePoint: LongWord): string;
begin
  if (CodePoint >= FirstPrintableCharacter) and (CodePoint <= LastPrintableCharacter) and
     not (Chr(CodePoint) in ['''', '{', '}']) then
    Result := Chr(CodePoint)
  else
    Result := 'U+' + IntToHex(CodePoint, 4);
end;

procedure WriteIncludeFile(const FileName, SourceName: string);
var
  Output: TextFile;
  Index: Integer;
  Row: Integer;
  GlyphOffset: Integer;
  Line: string;
begin
  AssignFile(Output, FileName);
  Rewrite(Output);

  WriteLn(Output, '{');
  WriteLn(Output, '  Console font bitmaps, generated by tools/PsfToPascal from');
  WriteLn(Output, '  ', ExtractFileName(SourceName), '. Do not edit by hand; run "make font".');
  WriteLn(Output, '');
  WriteLn(Output, '  Each glyph is ', Font.Height, ' rows of one byte; the most significant bit');
  WriteLn(Output, '  is the leftmost pixel. ConsoleFontCodePoints lists the character of each');
  WriteLn(Output, '  glyph, in ascending order.');
  WriteLn(Output, '}');
  WriteLn(Output, '');
  WriteLn(Output, 'const');
  WriteLn(Output, '  ConsoleFontWidth = ', Font.Width, ';');
  WriteLn(Output, '  ConsoleFontHeight = ', Font.Height, ';');
  WriteLn(Output, '  ConsoleFontGlyphCount = ', WantedCount, ';');
  WriteLn(Output, '');
  WriteLn(Output, '  ConsoleFontCodePoints: array[0..ConsoleFontGlyphCount - 1] of Word = (');
  Line := '   ';
  for Index := 0 to WantedCount - 1 do
  begin
    Line := Line + ' $' + IntToHex(WantedCodePoints[Index], 4);
    if Index < WantedCount - 1 then
      Line := Line + ',';
    if (Length(Line) > 80) or (Index = WantedCount - 1) then
    begin
      WriteLn(Output, Line);
      Line := '   ';
    end;
  end;
  WriteLn(Output, '  );');
  WriteLn(Output, '');
  WriteLn(Output, '  ConsoleFontGlyphs: array[0..ConsoleFontGlyphCount - 1, 0..ConsoleFontHeight - 1] of Byte = (');
  for Index := 0 to WantedCount - 1 do
  begin
    GlyphOffset := Font.GlyphDataOffset + GlyphForWanted[Index] * Font.BytesPerGlyph;
    Line := '    (';
    for Row := 0 to Font.Height - 1 do
    begin
      Line := Line + '$' + IntToHex(FontBytes[GlyphOffset + Row], 2);
      if Row < Font.Height - 1 then
        Line := Line + ', ';
    end;
    Line := Line + ')';
    if Index < WantedCount - 1 then
      Line := Line + ',';
    WriteLn(Output, Line + ' { ' + DescribeCodePoint(WantedCodePoints[Index]) + ' }');
  end;
  WriteLn(Output, '  );');
  CloseFile(Output);
end;

begin
  if ParamCount <> 2 then
  begin
    WriteLn('usage: PsfToPascal <font.psf> <output.inc>');
    Halt(2);
  end;

  LoadFile(ParamStr(1));
  ParseHeader;
  BuildCharacterMap;
  WriteIncludeFile(ParamStr(2), ParamStr(1));
  WriteLn('Wrote ', ParamStr(2), ' (', Font.Width, 'x', Font.Height, ', ', WantedCount, ' characters)');
end.
