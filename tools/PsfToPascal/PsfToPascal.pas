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
  include file holding bitmaps for the printable ASCII characters.

    PsfToPascal <font.psf> <output.inc>

  The font must be 8 pixels wide. If the font has a Unicode table it is
  used to find the glyph for each ASCII character; otherwise glyph N is
  assumed to be character N.

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
  GlyphForCharacter: array[FirstPrintableCharacter..LastPrintableCharacter] of Integer;

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
begin
  if (CodePoint >= FirstPrintableCharacter) and (CodePoint <= LastPrintableCharacter) then
  begin
    if GlyphForCharacter[CodePoint] < 0 then
      GlyphForCharacter[CodePoint] := GlyphIndex;
  end;
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

{ Only single byte (ASCII) UTF-8 code points matter here; multi-byte
  sequences are skipped over. }
procedure ParseVersion2UnicodeTable;
var
  Offset: Integer;
  GlyphIndex: Integer;
  Value: Byte;
  InsideSequence: Boolean;
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
    end
    else if Value = Psf2SequenceStart then
      InsideSequence := True
    else if (not InsideSequence) and (Value < $80) then
      RecordMapping(Value, GlyphIndex);
  end;
end;

procedure BuildCharacterMap;
var
  Character: Integer;
begin
  for Character := FirstPrintableCharacter to LastPrintableCharacter do
    GlyphForCharacter[Character] := -1;

  if Font.HasUnicodeTable then
  begin
    if Font.IsVersion2 then
      ParseVersion2UnicodeTable
    else
      ParseVersion1UnicodeTable;
  end;

  for Character := FirstPrintableCharacter to LastPrintableCharacter do
  begin
    if GlyphForCharacter[Character] < 0 then
      GlyphForCharacter[Character] := Character;
  end;
end;

procedure WriteIncludeFile(const FileName, SourceName: string);
var
  Output: TextFile;
  Character: Integer;
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
  WriteLn(Output, '  is the leftmost pixel.');
  WriteLn(Output, '}');
  WriteLn(Output, '');
  WriteLn(Output, 'const');
  WriteLn(Output, '  ConsoleFontWidth = ', Font.Width, ';');
  WriteLn(Output, '  ConsoleFontHeight = ', Font.Height, ';');
  WriteLn(Output, '  ConsoleFontFirstCharacter = ', FirstPrintableCharacter, ';');
  WriteLn(Output, '  ConsoleFontLastCharacter = ', LastPrintableCharacter, ';');
  WriteLn(Output, '');
  WriteLn(Output, '  ConsoleFontGlyphs: array[ConsoleFontFirstCharacter..ConsoleFontLastCharacter,');
  WriteLn(Output, '    0..ConsoleFontHeight - 1] of Byte = (');

  for Character := FirstPrintableCharacter to LastPrintableCharacter do
  begin
    GlyphOffset := Font.GlyphDataOffset + GlyphForCharacter[Character] * Font.BytesPerGlyph;
    Line := '    (';
    for Row := 0 to Font.Height - 1 do
    begin
      Line := Line + '$' + IntToHex(FontBytes[GlyphOffset + Row], 2);
      if Row < Font.Height - 1 then
        Line := Line + ', ';
    end;
    Line := Line + ')';
    if Character < LastPrintableCharacter then
      Line := Line + ',';
    if Character = Ord('''') then
      Line := Line + ' { quote }'
    else if Character = Ord('{') then
      Line := Line + ' { left brace }'
    else if Character = Ord('}') then
      Line := Line + ' { right brace }'
    else
      Line := Line + ' { ' + Chr(Character) + ' }';
    WriteLn(Output, Line);
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
  WriteLn('Wrote ', ParamStr(2), ' (', Font.Width, 'x', Font.Height, ')');
end.
